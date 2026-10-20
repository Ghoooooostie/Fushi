import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_translation_coordinator.dart';
import 'package:fushi/src/reader/reader_translation_scheduler.dart';
import 'package:fushi_engine/translation/translation_client.dart';
import 'package:fushi_engine/translation/translation_models.dart';
import 'package:fushi_engine/translation/translator.dart';

/// 假的 WebView 求值：记录每次调用的 JS，并按脚本返回预设结果。
class _FakeWebView {
  final List<String> calls = <String>[];

  /// 按「JS 里包含的片段」匹配返回值。
  final Map<String, dynamic> responses = <String, dynamic>{};

  /// 求值耗时。真实 evaluateJavascript 要过一次 platform channel，绝不会瞬时完成；
  /// 测「迟到结果被丢弃」时必须把它调大，否则 await 在同一个微任务里就回来了，
  /// cancel 永远赶不上（测试会假绿）。
  Duration evalDelay = Duration.zero;

  Future<dynamic> evaluate(String source) async {
    calls.add(source);
    if (evalDelay > Duration.zero) {
      await Future<void>.delayed(evalDelay);
    }
    for (final MapEntry<String, dynamic> entry in responses.entries) {
      if (source.contains(entry.key)) return entry.value;
    }
    return null;
  }

  Iterable<String> callsContaining(String needle) =>
      calls.where((String c) => c.contains(needle));
}

/// 假的翻译引擎：可控地成功 / 失败，并记录被译的正文。
class _FakeEngine {
  final List<String> translated = <String>[];

  /// 真实发出的请求次数（含失败的那些）。只数 [translated] 会漏掉失败尝试，
  /// 「失败后自动重试」这类断言就无从下笔。
  int attempts = 0;
  String result = '这是译文';
  bool fail = false;

  Future<String> translate(String text) async {
    attempts++;
    if (fail) {
      throw const TranslationFailure('network_error');
    }
    translated.add(text);
    return result;
  }
}

void main() {
  setUp(() {});

  group('防抖', () {
    test('连续调用只跑一次扫描', () async {
      final _FakeWebView web = _FakeWebView();
      final _FakeEngine engine = _FakeEngine();
      web.responses['collectVisibleTargets'] = '[]';
      final ReaderTranslationScheduler scheduler = _build(web, engine)
        ..enabled = true;

      scheduler.scheduleVisibleScan();
      scheduler.scheduleVisibleScan();
      scheduler.scheduleVisibleScan();
      expect(
        web.callsContaining('collectVisibleTargets'),
        isEmpty,
        reason: '定时器还没到点',
      );

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(web.callsContaining('collectVisibleTargets'), hasLength(1));
    });

    test('关闭时不扫描也不发请求', () async {
      final _FakeWebView web = _FakeWebView();
      final _FakeEngine engine = _FakeEngine();
      web.responses['collectVisibleTargets'] = '[{"id":"a","text":"正文"}]';
      final ReaderTranslationScheduler scheduler = _build(web, engine)
        ..enabled = false;

      scheduler.scheduleVisibleScan();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(web.callsContaining('collectVisibleTargets'), isEmpty);
      expect(engine.translated, isEmpty);
    });
  });

  group('换章作废', () {
    test('扫描期间换章，这次结果不再入队', () async {
      final _FakeWebView web = _FakeWebView();
      final _FakeEngine engine = _FakeEngine();
      web.responses['collectVisibleTargets'] = '[{"id":"a","text":"旧章正文"}]';

      // 让 evaluate 慢到能在它「在飞」的这段窗口里插进一次换章。
      web.evalDelay = const Duration(milliseconds: 150);
      final ReaderTranslationScheduler scheduler = _build(web, engine)
        ..enabled = true;

      scheduler.scheduleVisibleScan();
      // 350ms 去抖到点 → 发出 evaluate（还要跑 150ms）→ 此刻换章。
      await Future<void>.delayed(const Duration(milliseconds: 380));
      scheduler.cancelForNavigation();
      // 等迟到的 evaluate 回来：世代号已变，这份清单必须整份丢弃。
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(engine.translated, isEmpty, reason: '换章后旧文档的段落清单必须整份丢弃');
    });

    test('cancel 之后还能继续扫描（下一次导航照常工作）', () async {
      final _FakeWebView web = _FakeWebView();
      final _FakeEngine engine = _FakeEngine();
      web.responses['collectVisibleTargets'] = '[{"id":"a","text":"正文"}]';
      final ReaderTranslationScheduler scheduler = _build(web, engine)
        ..enabled = true;

      scheduler.cancelForNavigation();
      scheduler.scheduleVisibleScan();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(engine.translated, <String>['正文']);
    });
  });

  group('回填与异常收敛', () {
    test('成功译文被插回对应段落', () async {
      final _FakeWebView web = _FakeWebView();
      final _FakeEngine engine = _FakeEngine();
      web.responses['collectVisibleTargets'] = '[{"id":"p1","text":"原文段落"}]';
      final ReaderTranslationScheduler scheduler = _build(web, engine)
        ..enabled = true;

      scheduler.scheduleVisibleScan();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(engine.translated, <String>['原文段落']);
      final Iterable<String> applied = web.callsContaining('applyTranslation');
      expect(applied, hasLength(1));
      expect(applied.single, contains('p1'));
      expect(applied.single, contains('这是译文'));
    });

    test('引擎失败不插入任何东西，也不会炸掉整条链路', () async {
      final _FakeWebView web = _FakeWebView();
      final _FakeEngine engine = _FakeEngine()..fail = true;
      web.responses['collectVisibleTargets'] = '[{"id":"p1","text":"原文段落"}]';
      final ReaderTranslationScheduler scheduler = _build(web, engine)
        ..enabled = true;

      scheduler.scheduleVisibleScan();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(web.callsContaining('applyTranslation'), isEmpty);
    });

    test('段落失败后不滚动也会自己重试，端点恢复即回填（BUG-3369）', () async {
      final _FakeWebView web = _FakeWebView();
      final _FakeEngine engine = _FakeEngine()..fail = true;
      web.responses['collectVisibleTargets'] = '[{"id":"p1","text":"原文段落"}]';

      // 零冷却 + 60ms 轮询：让「失败 → 自动重试」这条链在测试里几秒内走完。
      final ReaderTranslationScheduler scheduler = _build(
        web,
        engine,
        retryPoll: const Duration(milliseconds: 60),
        coordinator: ReaderTranslationCoordinator(
          fetch: (String text) => engine.translate(text),
          cooldown: (String code, int attempts) => Duration.zero,
        ),
      )..enabled = true;

      scheduler.scheduleVisibleScan();
      await Future<void>.delayed(const Duration(milliseconds: 450));
      // 第一次失败：什么也没插，而且**期间一次都没滚动过** —— 旧实现到这里就停死了，
      // 重试只能等用户下一次滚动来重新 collect。
      expect(web.callsContaining('applyTranslation'), isEmpty);

      engine.fail = false; // 端点恢复
      for (int i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (web.callsContaining('applyTranslation').isNotEmpty) break;
      }

      expect(engine.attempts, greaterThan(1), reason: '失败段被自动重排');
      final Iterable<String> applied = web.callsContaining('applyTranslation');
      expect(applied, hasLength(1));
      expect(applied.single, contains('p1'));
    });

    test('换章之后不再对旧文档的重试段落发请求', () async {
      final _FakeWebView web = _FakeWebView();
      final _FakeEngine engine = _FakeEngine()..fail = true;
      web.responses['collectVisibleTargets'] = '[{"id":"p1","text":"原文段落"}]';
      final ReaderTranslationScheduler scheduler = _build(
        web,
        engine,
        retryPoll: const Duration(milliseconds: 60),
        coordinator: ReaderTranslationCoordinator(
          fetch: (String text) => engine.translate(text),
          cooldown: (String code, int attempts) => Duration.zero,
        ),
      )..enabled = true;

      scheduler.scheduleVisibleScan();
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(engine.attempts, 1, reason: '失败的那一次也算一次尝试');

      // 换章：失败池清空，重试轮询不再有内容可排。
      scheduler.cancelForNavigation();
      engine.fail = false;
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(engine.attempts, 1, reason: '旧文档的段落不该被重排');
    });

    test('换目标语言会清空缓存（同一段不会拿旧语言译文顶上）', () async {
      final _FakeWebView web = _FakeWebView();
      final _FakeEngine engine = _FakeEngine();
      web.responses['collectVisibleTargets'] = '[{"id":"a","text":"同一段"}]';
      final ReaderTranslationScheduler scheduler = _build(web, engine)
        ..enabled = true;

      scheduler.scheduleVisibleScan();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(engine.translated, <String>['同一段']);

      scheduler.applySettings(
        enabled: true,
        engineId: TranslationEngineId.caiyun,
        target: TranslationTargetLanguage.english,
      );
      scheduler.scheduleVisibleScan();
      // 段与段之间至少 800ms 节流，第二次请求要等过这道间隔才发出去；这里是真实
      // 定时器，只能等（旧写法只等 120ms，这个断言一直是红的）。
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 1000));

      expect(engine.translated, <String>[
        '同一段',
        '同一段',
      ], reason: '目标语言变了，同一段必须重译');
    });
  });

  group('JS 回传解析', () {
    test('畸形回传被当成空列表，不会让阅读器出问题', () async {
      final _FakeWebView web = _FakeWebView();
      final _FakeEngine engine = _FakeEngine();
      web.responses['collectVisibleTargets'] = '这不是 JSON';
      final ReaderTranslationScheduler scheduler = _build(web, engine)
        ..enabled = true;

      scheduler.scheduleVisibleScan();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(engine.translated, isEmpty);
    });

    test('字段类型不对的条目被跳过，好的条目仍然处理', () async {
      final _FakeWebView web = _FakeWebView();
      final _FakeEngine engine = _FakeEngine();
      web.responses['collectVisibleTargets'] =
          '[{"id":123,"text":"坏"},{"id":"ok","text":"好的正文"}]';
      final ReaderTranslationScheduler scheduler = _build(web, engine)
        ..enabled = true;

      scheduler.scheduleVisibleScan();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(engine.translated, <String>['好的正文']);
    });
  });
}

/// 走**真实的** [TranslationClient] 路由，只把引擎换成假的：这样连「没装配的引擎 →
/// engine_not_configured」那条路径也在测试覆盖范围内，而不是被替身绕过去。
ReaderTranslationScheduler _build(
  _FakeWebView web,
  _FakeEngine engine, {
  Duration retryPoll = kReaderTranslationRetryPoll,
  ReaderTranslationCoordinator? coordinator,
}) =>
    ReaderTranslationScheduler(
      evaluate: web.evaluate,
      client: TranslationClient(
        translators: <TranslationEngineId, Translator>{
          TranslationEngineId.caiyun: _FakeTranslator(engine),
        },
      ),
      retryPoll: retryPoll,
      coordinator: coordinator,
    );

/// 假的翻译引擎实现：成功 / 失败由 [_FakeEngine] 决定。
class _FakeTranslator extends Translator {
  _FakeTranslator(this._engine);

  final _FakeEngine _engine;

  @override
  TranslationEngineId get id => TranslationEngineId.caiyun;

  @override
  Future<TranslationResult> translate(
    String text, {
    TranslationTargetLanguage target =
        TranslationTargetLanguage.simplifiedChinese,
  }) async {
    final String translated = await _engine.translate(text);
    return TranslationResult(
      sourceText: text,
      translatedText: translated,
      engineId: id,
      targetLanguage: target,
    );
  }
}
