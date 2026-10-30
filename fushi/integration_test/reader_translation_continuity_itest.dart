// 段落对照翻译的**设备端**连续性验证（BUG-3369）。
//
// 报障原始路径：非 AI 翻译（彩云网页版引擎）打开后，译到十几段就停住，后面的段落
// 再也不出译文。老代码里失败段落要么一次限流就被判死（`http_429` 不在可重试集合），
// 要么攒满 4 次失败就本次会话永久冷却，而**重试的唯一入口是用户滚动**——用户读到
// 一半停下来看时，那一屏的空白就被钉死到会话结束。
//
// 设备复测因此分两拍：
//   ① **负载拍**：连续翻章，真实地一段段往下读，把请求量顶到彩云限流的量级
//      （`scan` / `ok` / `fail` 三路日志 + DOM 里 `.fushi-reader-translation`
//      节点数同步取证）。
//   ② **静默拍**：**什么都不做**地干等 70s。这一拍才是考场：修复前失败段落只能等
//      用户滚动才重排，这一拍里日志会彻底断流；修复后调度器自己轮询把冷却到期的
//      段落排回队列，日志会继续出 `retry requeued=N` → `ok`。
//
// 运行（需已连接设备 / 模拟器；epub 先推到设备）：
//   adb push <book.epub> /data/local/tmp/yume.epub     # 或应用外部目录
//   flutter build apk --debug -t integration_test/reader_translation_continuity_itest.dart
//   adb install -r build/app/outputs/flutter-apk/app-debug.apk
//   adb shell am start -n <pkg>/app.fushi.reader.MainActivity
//   adb logcat | grep -E "translation-itest|fushi-translation"
//
// 可选 define：
//   TRANSLATION_EPUB_PATH=<绝对路径>      直接指定 epub（否则自动探测落点）
//   TRANSLATION_SILENT_SECONDS=70         静默拍长度
//   TRANSLATION_LOAD_TURNS=3              负载拍的翻章次数
import 'dart:io';

import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 待译 epub 的显式路径（--dart-define=TRANSLATION_EPUB_PATH=...）。
///
/// 空串时走 [_resolveEpubPath] 的自动落点探测。刻意**不**给默认值：宿主 shell
/// （MSYS / Git Bash）会把以 `/` 开头的 define 值当 POSIX 路径改写，写死一个
/// 绝对路径反而最容易踩这种静默转换（实测被改成了 PortableGit 安装根下面）。
const String _kEpubPath = String.fromEnvironment('TRANSLATION_EPUB_PATH');

/// 静默拍长度（秒）：这一拍里测试**不碰任何输入**。
const int _kSilentSeconds =
    int.fromEnvironment('TRANSLATION_SILENT_SECONDS', defaultValue: 70);

/// 负载拍的翻章次数（每次之间留 [_kLoadTurnGapSeconds] 让译文落地）。
const int _kLoadTurns =
    int.fromEnvironment('TRANSLATION_LOAD_TURNS', defaultValue: 3);

/// 负载拍两次翻章之间的静置时长（秒）。
const int _kLoadTurnGapSeconds =
    int.fromEnvironment('TRANSLATION_LOAD_TURN_GAP', defaultValue: 20);

/// 一条设备侧日志。
class _Line {
  _Line(this.at, this.message);

  final DateTime at;
  final String message;
}

/// 按「显式 define → 应用可写目录 → adb 落点」的顺序找 epub。
///
/// 直接用 `adb push` 的三个落点：`getExternalStorageDirectory()`
/// （`/sdcard/Android/data/<pkg>/files`，免权限）、应用文档目录，以及
/// `/data/local/tmp`（`adb push` 默认可写、对 app 可读）。都不在就跳过测试——
/// 设备复测不该因为「素材没推上去」而假红。
Future<String?> _resolveEpubPath() async {
  if (_kEpubPath.isNotEmpty && File(_kEpubPath).existsSync()) {
    return _kEpubPath;
  }
  final List<String> candidates = <String>[];
  try {
    final Directory? external = await getExternalStorageDirectory();
    if (external != null) candidates.add('${external.path}/yume.epub');
    final Directory docs = await getApplicationDocumentsDirectory();
    candidates.add('${docs.path}/yume.epub');
  } catch (_) {
    // path_provider 在部分平台上没实现；那就只认显式 define 和 adb 落点。
  }
  candidates.add('/data/local/tmp/yume.epub');
  for (final String candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// 直连彩云端点，把**原始异常**打到 logcat。
///
/// 引擎把所有网络异常都收敛成一个 `network_error`（见 `CaiyunWebTranslator._post`
/// 的 catch-all：不回显原始异常是为了不泄漏 header 里的 token）。这在产品里是对的，
/// 但排查时会把「DNS 不通」「TLS 握手失败」「代理拦了」全压成同一个码。取证阶段
/// 必须看到原始异常，否则没法判断一次设备复测究竟验到了什么。
Future<void> _probeCaiyunEndpoint() async {
  const String url = 'https://api.interpreter.caiyunai.com/v1/user/jwt/generate';
  HttpClient? client;
  try {
    client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
    final HttpClientRequest request =
        await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 12));
    final HttpClientResponse response =
        await request.close().timeout(const Duration(seconds: 12));
    debugPrint('[translation-itest] 网络探针 status=${response.statusCode} '
        '（只要不是异常就说明 HTTPS 通）');
    await response.drain<void>();
  } catch (error) {
    debugPrint('[translation-itest] 网络探针异常 '
        '${error.runtimeType}: $error');
  } finally {
    client?.close(force: true);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '段落对照翻译：静默期也继续出译文，失败后自己接上（BUG-3369）',
    (WidgetTester tester) async {
      final String? epubPath = await _resolveEpubPath();
      if (epubPath == null) {
        markTestSkipped('设备上看不到待译 epub（define=$_kEpubPath，'
            '另试了应用外部/文档目录与 /data/local/tmp/yume.epub）');
        return;
      }
      debugPrint('[translation-itest] epub=$epubPath');

      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: 'Home 必须先渲染出来');

      // 先探一次端点：结论写进 logcat，用来解释后面那些 fail 码的成色。
      await _probeCaiyunEndpoint();

      final AppModel appModel = await readyAppModel(tester);

      // 与报障配置一致：段落对照翻译开 + 彩云网页版引擎 + 简体中文。
      // 开书前写，阅读器建调度器时读的就是这份设置。
      await ReaderFushiSource.instance.setTranslationEnabled(true);
      await ReaderFushiSource.instance.setTranslationEngineId('caiyun');
      await ReaderFushiSource.instance.setTranslationTargetLanguage('zh');

      // 拦下 `[fushi-translation]`，同时照常转发（转发用的是原本的 debugPrint，
      // 这样 logcat 里也能看到完整时间线）。
      final List<_Line> lines = <_Line>[];
      final DebugPrintCallback originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null && message.startsWith('[fushi-translation]')) {
          lines.add(_Line(DateTime.now(), message));
        }
        originalDebugPrint(message, wrapWidth: wrapWidth);
      };
      addTearDown(() => debugPrint = originalDebugPrint);

      final String bookKey = await EpubImporter.importFromPath(
        db: appModel.database,
        filePath: epubPath,
        fileName: 'yume.epub',
      );
      debugPrint('[translation-itest] imported bookKey=$bookKey');

      await openBookViaProductionPath(tester, bookKey);

      // 等阅读器文档真正就绪（`fushi_content_ready` 是 reader 的权威信号）。
      final Finder contentReady =
          find.byKey(const ValueKey<String>('fushi_content_ready'));
      bool ready = false;
      for (int i = 0; i < 120 && !ready; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        ready = contentReady.evaluate().isNotEmpty;
      }
      expect(ready, isTrue, reason: '阅读器文档必须就绪（fushi_content_ready）');

      final Future<dynamic> Function(String)? eval =
          ReaderFushiPage.debugEvaluateJavascript;
      expect(eval, isNotNull,
          reason: 'ReaderFushiPage.debugEvaluateJavascript 未装配（非 debug 构建？）');

      /// 当前章节文件名（`document.baseURI` 的末段），用来判断翻章有没有落地。
      Future<String> chapterFile() async {
        final dynamic raw =
            await eval!('(document.baseURI || "").split("/").pop()');
        return raw?.toString() ?? '';
      }

      /// DOM 里已经插进去的译文节点数——**用户真正看到的**译文条数。
      Future<int> domTranslationCount() async {
        final dynamic raw = await eval!(
            'document.querySelectorAll(".fushi-reader-translation").length');
        return int.tryParse(raw?.toString() ?? '') ?? 0;
      }

      /// 翻一章（走阅读器真实的 `onBoundarySwipe` 通道），等章节真的落地。
      Future<bool> turnChapter(String dir) async {
        final String from = await chapterFile();
        await eval!(
            "window.flutter_inappwebview.callHandler('onBoundarySwipe', '$dir');"
            ' true');
        for (int i = 0; i < 120; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          final String to = await chapterFile();
          if (to.isNotEmpty && to != from) return true;
        }
        return false;
      }

      /// 干等 [seconds] 秒，期间**不产生任何输入**。
      Future<void> idle(int seconds) async {
        for (int i = 0; i < seconds * 2; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
      }

      final DateTime openedAt = DateTime.now();
      debugPrint('[translation-itest] 起始章节=${await chapterFile()} '
          '已有译文=${await domTranslationCount()}');

      // ── ① 负载拍：真实地往下读，把请求量顶起来 ──────────────────────
      for (int turn = 0; turn < _kLoadTurns; turn++) {
        await idle(_kLoadTurnGapSeconds);
        final bool moved = await turnChapter('forward');
        debugPrint('[translation-itest] 负载拍 翻章#${turn + 1} moved=$moved '
            '章节=${await chapterFile()} 译文=${await domTranslationCount()}');
      }
      await idle(_kLoadTurnGapSeconds);

      // ── ② 静默拍：从这一刻起，一个输入都不给 ────────────────────────
      final int silentStartIndex = lines.length;
      final int domAtSilentStart = await domTranslationCount();
      debugPrint('[translation-itest] 静默拍开始 '
          '章节=${await chapterFile()} 译文=$domAtSilentStart');
      await idle(_kSilentSeconds);
      final int domAtSilentEnd = await domTranslationCount();

      // ── 取证 ────────────────────────────────────────────────────────
      int countWhere(Iterable<_Line> source, bool Function(String m) test) =>
          source.where((_Line l) => test(l.message)).length;

      final int scanCount = countWhere(lines, (String m) => m.contains(' scan '));
      final int okCount = countWhere(lines, (String m) => m.contains(' ok '));
      final int failCount = countWhere(lines, (String m) => m.contains(' fail '));
      final int retryCount =
          countWhere(lines, (String m) => m.contains(' retry '));

      final List<_Line> silentLines = lines.skip(silentStartIndex).toList();
      final int silentOk =
          countWhere(silentLines, (String m) => m.contains(' ok '));
      final int silentFail =
          countWhere(silentLines, (String m) => m.contains(' fail '));
      final int silentRetry =
          countWhere(silentLines, (String m) => m.contains(' retry '));

      int lastFailIndex = -1;
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].message.contains(' fail ')) lastFailIndex = i;
      }
      final int okAfterLastFail = lastFailIndex < 0
          ? 0
          : countWhere(lines.skip(lastFailIndex + 1),
              (String m) => m.contains(' ok '));

      debugPrint('[translation-itest] ===== 设备取证 =====');
      debugPrint('[translation-itest] 窗口=${DateTime.now().difference(openedAt).inSeconds}s '
          'scan=$scanCount ok=$okCount fail=$failCount retry=$retryCount');
      debugPrint('[translation-itest] 静默拍 ok=$silentOk fail=$silentFail '
          'retry=$silentRetry DOM $domAtSilentStart -> $domAtSilentEnd');
      for (final _Line line in lines) {
        debugPrint('[translation-itest]   '
            '+${line.at.difference(openedAt).inSeconds}s ${line.message}');
      }
      debugPrint('[translation-itest] ===== 取证结束 =====');

      expect(scanCount, greaterThan(0),
          reason: 'JS 收集一遍都没跑：阅读器文档 / WebView 没起来');
      expect(domAtSilentEnd, greaterThanOrEqualTo(6),
          reason: '观察窗结束时分章里只有 $domAtSilentEnd 条译文落地（ok=$okCount '
              'fail=$failCount）——翻译没成片出来');
      expect(okCount, greaterThanOrEqualTo(6),
          reason: '观察窗内只成功 $okCount 段（fail=$failCount）');

      // 核心断言：只要出现过失败，最后一次失败之后**必须还有译文落地**。
      // 这正是 BUG-3369 的旧行为判据（限流一次判死 / 失败 4 次永久冷却 + 只有滚动
      // 才重排 → 最后一次失败之后译文再也不出现）。
      if (failCount > 0) {
        expect(okAfterLastFail, greaterThan(0),
            reason: '最后一次失败之后不再有译文落地（fail=$failCount '
                'retry=$retryCount 静默拍 ok=$silentOk retry=$silentRetry）——'
                '失败后又停死了');
      } else {
        debugPrint('[translation-itest] 本轮未触发失败路径，重试分支未被覆盖');
      }

      // 静默拍判据：不给任何输入，译文条数还得往上走（或至少仍在重试）。
      // 全成功的情况下静默拍本就没有待办，故只在「静默拍开头/期间有失败」时硬断言。
      if (silentFail > 0) {
        expect(silentOk, greaterThan(0),
            reason: '静默拍（零输入 ${_kSilentSeconds}s）里失败之后一条译文都没补上：'
                'retry=$silentRetry —— 重试没有自己站起来');
      }
    },
  );
}
