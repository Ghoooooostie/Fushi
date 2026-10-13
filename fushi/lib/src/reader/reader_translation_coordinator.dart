/// 阅读器翻译队列的调度核心。
///
/// ## 为什么单独拎一层，且不 import Flutter、不做 IO
///
/// 「队列、去重、缓存、换章作废」是纯逻辑：只要能注入一个假的翻译函数，整套行为
/// 都能用 `package:test` 跑出来，不需要 WebView、不需要网络、不需要 binding。真实翻译
/// 由 `packages/fushi_engine/lib/translation/` 负责，本页面逻辑才上层打交道。
///
/// 分层的目的是把这四条**容易出错且难以手测**的不变量钉死：
///   1. **同一段落不会被排两次**（在飞的也算）；
///   2. **同一段正文不会被译第二遍**（跨章节 / 来回滚动都按正文做 key）；
///   3. **一次只飞一个请求**——用户只会看当前这屏，串行才不会出现「第十段比第一段
///      先回来」这种乱序感；
///   4. **换章后旧章的在途结果必须丢弃**，否则会出现「上一章的译文插到这一章的段落上」，
///      而且很难复现。
///
/// 失败的段落另有一条：**本次会话不再重试**。否则用户每滚一次都会把同一段失败的
/// 译文重打一遍，API 限流或凭据失效时会越滚越糟（这一点是协调层比原实现多做的）。
library;

import 'dart:async';

/// 一个待译段落。[id] 只在单次文档生命周期内稳定（由 JS 侧分配），用于回填定位；
/// [text] 才是跨章去重与缓存的依据。
class ReaderTranslationTarget {
  const ReaderTranslationTarget({required this.id, required this.text});

  final String id;
  final String text;

  @override
  String toString() => 'ReaderTranslationTarget($id)';
}

/// 翻译失败。[code] 是可直接显示的短码（`network_error` / `http_401` / ...），
/// 不含 URL 与响应体——那些可能回显凭据。
class ReaderTranslationFailure implements Exception {
  const ReaderTranslationFailure(this.code);

  final String code;

  @override
  String toString() => 'ReaderTranslationFailure: $code';
}

/// 一次出队的结局。成功带 [translatedText]，失败带 [failureCode]，二者恰有一个非空。
class ReaderTranslationOutcome {
  ReaderTranslationOutcome.success({
    required this.targetId,
    required this.translatedText,
  }) : failureCode = null;

  ReaderTranslationOutcome.failure({
    required this.targetId,
    required this.failureCode,
  }) : translatedText = null;

  final String targetId;
  final String? translatedText;
  final String? failureCode;

  bool get isSuccess => translatedText != null;
}

/// 真实翻译动作：返回译文，失败抛 [ReaderTranslationFailure]。
typedef ReaderTranslationFetch = Future<String> Function(String text);

/// 段落队列调度器。
class ReaderTranslationCoordinator {
  ReaderTranslationCoordinator({
    required this.fetch,
    this.maxCachedEntries = 300,
    this.onOutcome,
  });

  /// 注入的翻译实现。
  final ReaderTranslationFetch fetch;

  /// 译文缓存的条目上限。超过后丢掉最早的一半（近似 LRU，用 Map 的插入顺序）。
  final int maxCachedEntries;

  /// 出队结局的回流口。调用方据此把译文回填到 WebView。
  final void Function(ReaderTranslationOutcome outcome)? onOutcome;

  final List<ReaderTranslationTarget> _queue = <ReaderTranslationTarget>[];
  final Set<String> _queuedIds = <String>{};
  final Set<String> _inFlightIds = <String>{};

  /// 每个段落 id 的失败次数。达到 [_maxRetries] 后才进入「永久冷却」，
  /// 此前允许滚动重新 collect 时重试——端点限流 / 抖动恢复后能自愈，
  /// 而不是像旧的 `_failedIds` 那样一次失败就判死刑
  /// （BUG：看着看着整章不翻）。
  final Map<String, int> _failureCount = <String, int>{};

  /// 单段失败重试上限；超过后该段本会话冷却（避免对持续失效端点无限重试）。
  static const int _maxRetries = 4;

  /// 正文 → 译文。Map 保持插入顺序，用于近似 LRU 的淘汰。
  final Map<String, String> _cache = <String, String>{};

  bool _draining = false;

  /// 两次翻译请求之间的最小间隔：网页翻译端点（彩云）有速率限制，不打节流会
  /// 瞬间打爆 → 触发限流失败 → 整章不翻。用户反馈「是不是翻译太快了」即此。
  static const Duration _minRequestInterval = Duration(milliseconds: 800);

  /// 上次真正发出请求的时刻，用于节流。
  DateTime? _lastRequestAt;

  /// 世代号。每次 [cancel] 自增：换了章，此前发出去的在途请求回来时会被判作废。
  int _generation = 0;

  int get generation => _generation;

  int get pendingCount => _queue.length;

  int get inFlightCount => _inFlightIds.length;

  int get cachedCount => _cache.length;

  bool get isIdle => _queue.isEmpty && _inFlightIds.isEmpty;

  /// 缓存 key：压缩掉空白差异。
  ///
  /// 同一段正文在重排后可能带着不同的换行 / 多空格（书籍 HTML 千奇百怪），按原样做 key
  /// 会让同一段被反复翻译；差一个空格就 cache miss 的话，缓存等于没有。
  String cacheKeyFor(String text) =>
      text.trim().replaceAll(RegExp(r'\s+'), ' ');

  String? peekCache(String text) => _cache[cacheKeyFor(text)];

  /// 投递一批待译段落。已缓存的立即以成功结局回流；其余入队。
  Future<void> enqueue(List<ReaderTranslationTarget> targets) async {
    for (final ReaderTranslationTarget target in targets) {
      if (target.text.trim().isEmpty) continue;
      // ① 已达重试上限的段本会话冷却；② 已在队列 / 在飞的不重复排。
      if ((_failureCount[target.id] ?? 0) >= _maxRetries) continue;
      if (_queuedIds.contains(target.id) || _inFlightIds.contains(target.id)) {
        continue;
      }

      final String? cached = peekCache(target.text);
      if (cached != null) {
        _emit(
          ReaderTranslationOutcome.success(
            targetId: target.id,
            translatedText: cached,
          ),
        );
        continue;
      }

      _queuedIds.add(target.id);
      _queue.add(target);
    }
    if (_queue.isNotEmpty) {
      unawaited(_drain());
    }
  }

  /// 换章 / 重排：作废队列与在途请求。
  ///
  /// [keepFailed] = false 时连「失败冷却」一起清空：换了目标语言之后，之前因为网络抖动
  /// 失败的段落应当可以再试一次。
  void cancel({bool keepFailed = true}) {
    _generation++;
    _queue.clear();
    _queuedIds.clear();
    if (!keepFailed) {
      _failureCount.clear();
    }
  }

  /// 清空一切（含缓存与失败冷却）：换了目标语言时用，否则会直接拿旧语言的译文回填。
  void reset() {
    cancel(keepFailed: false);
    _cache.clear();
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final int ownGeneration = _generation;
        final ReaderTranslationTarget target = _queue.removeAt(0);
        _queuedIds.remove(target.id);
        _inFlightIds.add(target.id);

        String? translated;
        String? failureCode;
        try {
          // 节流：确保距上次请求至少 [_minRequestInterval]，避免瞬间打爆彩云的
          // 速率限制（用户反馈「是不是翻译太快了」即此——太快会触发限流失败，
          // 后续段段失败、整章不翻）。
          final DateTime now = DateTime.now();
          if (_lastRequestAt != null) {
            final Duration since = now.difference(_lastRequestAt!);
            if (since < _minRequestInterval) {
              await Future.delayed(_minRequestInterval - since);
            }
          }
          // 关键修复：网页翻译端点（彩云）偶发挂起时不返回也不报错，会永久阻塞
          // 整个 drain 循环 → 表现为「前面翻了后面突然全停」。强制 20s 超时，
          // 超时按失败处理，保证循环一定能继续推进后续段落。
          translated = await fetch(target.text).timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw const ReaderTranslationFailure('timeout'),
          );
        } on ReaderTranslationFailure catch (failure) {
          failureCode = failure.code;
        } catch (_) {
          // 兜底未知异常：真实翻译层可能抛出形状之外的东西。给它一个统一码，
          // 而不是让异常逃出 drain 循环把整个队列卡死。
          failureCode = 'unknown';
        } finally {
          // 无论成败都更新节流时间戳，失败重试也保持节流节奏。
          _lastRequestAt = DateTime.now();
        }

        _inFlightIds.remove(target.id);

        // 换章期间完成的结果一概丢弃：目标段落已经不在文档里了，回填会命中别的
        // 元素（DOM 重建后 id 可能指向完全不同的段落）。
        if (ownGeneration != _generation) continue;

        if (translated != null && translated.trim().isNotEmpty) {
          _remember(target.text, translated);
          _emit(
            ReaderTranslationOutcome.success(
              targetId: target.id,
              translatedText: translated,
            ),
          );
        } else {
          // 不再「一次失败永久冷却」：记一次失败，达到 [_maxRetries] 才冷却，
          // 此前滚动重新 collect 到该段会再次入队重试（端点恢复即自愈）。
          _failureCount[target.id] = (_failureCount[target.id] ?? 0) + 1;
          _emit(
            ReaderTranslationOutcome.failure(
              targetId: target.id,
              failureCode: failureCode ?? 'empty_response',
            ),
          );
        }
      }
    } finally {
      _draining = false;
    }
  }

  void _remember(String source, String translated) {
    final String key = cacheKeyFor(source);
    _cache.remove(key); // 重插入，维持 Map 的「最近使用在后」顺序
    _cache[key] = translated;
    if (_cache.length > maxCachedEntries) {
      final int drop = _cache.length - (maxCachedEntries ~/ 2);
      final List<String> oldest = _cache.keys
          .take(drop)
          .toList(growable: false);
      for (final String key in oldest) {
        _cache.remove(key);
      }
    }
  }

  void _emit(ReaderTranslationOutcome outcome) {
    final void Function(ReaderTranslationOutcome)? sink = onOutcome;
    if (sink == null) return;
    sink(outcome);
  }
}
