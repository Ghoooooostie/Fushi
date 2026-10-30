/// 翻译调度的 app 侧装配：把**引擎**、**队列**、**WebView** 三件事缝起来。
///
/// ## 为什么单独一层
///
/// 引擎（`packages/fushi_engine/lib/translation/`）不知道 WebView 存在；队列
/// （[ReaderTranslationCoordinator]）刻意不许碰 IO；网页脚本
/// （[ReaderTranslationScripts]）只是一段字符串。真要把它们接起来，还得负责三件
/// 「容易错且必须调试才能发现」的事：
///
///   1. **防抖**：滚动会在几十毫秒里连着触发，每次都收集一遍可见段落等于在滚动期间
///      持续发 HTTP。这里用 **trailing debounce**（滚动停下才动），而不是 leading ——
///      用户会连续翻好几屏，中间那些屏没必要译。
///   2. **迟到的 eval 必须丢弃**：换章 / 重排之后，之前发出的 `collectVisibleTargets`
///      结果可能才回来，拿它去 enqueue 会把上一章的段落排进这一章的队列。用世代号
///      拦住。
///   3. **引擎异常要收敛成码**：真实引擎抛的是 `TranslationFailure`，队列层认的是
///      [ReaderTranslationFailure]，且 UI 只需要一个短码。
///
/// [evaluate] 可注入（测试里换成记录调用的假函数），所以这些行为都能真跑出来，不需要
/// WebView。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:fushi_engine/translation/translation_client.dart';
import 'package:fushi_engine/translation/translation_models.dart';
import 'package:fushi/src/reader/reader_translation_coordinator.dart';
import 'package:fushi/src/reader/reader_translation_scripts.dart';

/// 滚动停止多久之后才真正去收集当屏可见段落。
///
/// 350ms 是读过就忘的量级：比一次连贯滚动的间隙略长（滚动事件通常几十毫秒一个），
/// 又短到用户抬手就能看到译文开始出现。
const Duration kReaderTranslationDebounce = Duration(milliseconds: 350);

/// 前瞻窗口（px）：除可见区域外，再往下多收这么多像素内的段落。
///
/// 只往前、**不往后**：已经读过的段落在往回滚之前不会再露面，而用户下一步一定是往下
/// 读多一点。这是「预取下几段」和「别浪费请求」之间的折中点。
const int kReaderTranslationAheadPx = 600;

/// 一次扫描最多收多少段。
///
/// 上限存在的理由是排序：队列是串行的，第十段要等前九段译完。把整章几十段都排进去，
/// 用户正在看的最后一段会排在队尾等几十个请求。一屏能读懂的段落本来就不超过十来个。
const int kReaderTranslationMaxPerScan = 12;

/// 失败段落的重试轮询间隔下限。
///
/// 与上层的协调层冷却阶梯是两个东西：那边管「这段第 N 次失败要等多久」，这边管「多久
/// 去看一次有没有到期的段落」。取 2s 是让它明显短于最短冷却（2s 网络失败 / 4s 限流），
/// 又不会轮询得太密。
const Duration kReaderTranslationRetryPoll = Duration(seconds: 2);

/// WebView 求值动作。`reader_fushi_page.dart` 传的是
/// `_controller.evaluateJavascript(source: ...)`。
typedef ReaderTranslationEval = Future<dynamic> Function(String source);

/// 翻译调度器。
class ReaderTranslationScheduler {
  ReaderTranslationScheduler({
    required ReaderTranslationEval evaluate,
    required TranslationClient client,
    this.debounce = kReaderTranslationDebounce,
    this.aheadPx = kReaderTranslationAheadPx,
    this.maxPerScan = kReaderTranslationMaxPerScan,
    this.retryPoll = kReaderTranslationRetryPoll,
    ReaderTranslationCoordinator? coordinator,
  })  : _evaluate = evaluate,
        _client = client {
    // 注入的协调层（测试要用自定义冷却策略）也要挂上同一个回流口，否则译文没有出口。
    _coordinator = coordinator ?? ReaderTranslationCoordinator(fetch: _fetch);
    _coordinator.onOutcome = _onOutcome;
  }

  final ReaderTranslationEval _evaluate;

  /// 出站翻译客户端。**故意做成可变**：阅读器的每次「文档就绪」
  /// （开书、翻章、切卷、重分页、宽变、设置热更）都会走阅读器页的
  /// `_ensureTranslation` 重建一个新 `TranslationClient` 并 **关闭**旧的
  /// （`_translationClient?.close()`）。而这个调度器是**跨章复用**的
  /// （`_translation ?? ReaderTranslationScheduler(...)`），若仍持有那个已被关闭的
  /// 旧客户端，下一次 `translate()` 必失败——表现为「第一卷能译，翻到第二卷 /
  /// 下一章之后整屏空白，重试也救不回来」。
  /// 复用时由 [attachClient] 把客户端同步成当前这一份（新建时两者本就一致），
  /// 保证翻译永远打到「还活着」的客户端上。
  TranslationClient _client;

  /// 复用已有调度器时，把它的出站客户端同步成当前这一份。见 [_client] 的注释。
  void attachClient(TranslationClient client) {
    _client = client;
  }

  final Duration debounce;
  final int aheadPx;
  final int maxPerScan;

  /// 重试轮询的间隔下限（测试注入点；真实值见 [kReaderTranslationRetryPoll]）。
  final Duration retryPoll;

  late final ReaderTranslationCoordinator _coordinator;
  Timer? _timer;

  /// 失败段落的重试轮询定时器。`cancelForNavigation` 会把它连同失败池一起清掉：
  /// 换了章之后旧 id 已经不属于当前文档，再重排也只是给已经不存在的段落发请求。
  Timer? _retryTimer;

  /// 世代号：[cancelForNavigation] 自增。过期的 eval 结果与回填一律丢弃。
  int _navGeneration = 0;

  TranslationEngineId _engineId = TranslationEngineId.caiyun;
  TranslationTargetLanguage _target = TranslationTargetLanguage.simplifiedChinese;

  /// 翻译总开关。关掉时不再扫描，也不再发请求（已插的译文由 `clear` 决定是否保留）。
  bool enabled = false;

  int get pendingCount => _coordinator.pendingCount;

  int get inFlightCount => _coordinator.inFlightCount;

  bool get hasPendingTimer => _timer != null;

  /// 应用一次设置（开关 / 引擎 / 目标语言 / 外观）。
  ///
  /// 换了**目标语言**必须 [clearTranslations] 并重排：缓存里存的是旧语言的译文，
  /// 不重来会出现「同一段一会儿中文一会儿英文」。
  void applySettings({
    required bool enabled,
    required TranslationEngineId engineId,
    required TranslationTargetLanguage target,
  }) {
    final bool languageChanged = target != _target;
    this.enabled = enabled;
    _engineId = engineId;
    _target = target;
    if (!enabled) {
      stop();
      return;
    }
    if (languageChanged) {
      _coordinator.reset();
    }
    // 重新打开翻译（同一语言）时，上次会话里还在冷却的段落要接着重来，否则它们
    // 要等下一次滚动才可能被重新收集。
    if (_coordinator.hasPendingRetry) _scheduleRetryFlush();
  }

  /// 文档就绪：让 JS 侧按当前 config 装一次样式与显隐。
  Future<void> installForDocument() =>
      _evaluate(ReaderTranslationScripts.installInvocation());

  /// 样式热更新（颜色 / 不透明度 / 显隐）：改完立刻生效，不翻章也不需要重新译。
  Future<void> applyStyleLive({
    required String color,
    required double opacity,
    required bool visible,
  }) =>
      _evaluate(ReaderTranslationScripts.liveUpdateInvocation(
        color: color,
        opacity: opacity,
        visible: visible,
      ));

  Future<void> setVisible(bool visible) =>
      _evaluate(ReaderTranslationScripts.setVisibleInvocation(visible));

  /// 清空已插译文。[resetIds] = 连段落 id 一起抹（换了目标语言后必须彻底重来）。
  Future<void> clearTranslations({bool resetIds = false}) =>
      _evaluate(ReaderTranslationScripts.clearInvocation(resetIds: resetIds));

  /// 滚动 / 翻页落定后调用：排一次当屏扫描（trailing debounce）。
  void scheduleVisibleScan() {
    if (!enabled) return;
    _timer?.cancel();
    _timer = Timer(debounce, _runScan);
  }

  /// 换章 / 重排：作废在途请求与待扫描定时器。
  ///
  /// 不动译文缓存——同一段落滚回来还得立刻有译文。
  void cancelForNavigation() {
    _navGeneration++;
    stop();
    _coordinator.cancel();
  }

  /// 取消待执行的扫描（保留世代号不变）。退出阅读器 / 临时关闭翻译时用。
  void stop() {
    _timer?.cancel();
    _timer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  /// 失败后挂一个重试轮询：失败了才挂，**不需要用户再去滚一下**。
  ///
  /// 这段自主性是 BUG-3369 的另一半修复。旧实现里失败段落只有「用户滚动 → 重新
  /// collect → 再入队」这一条重来的路，而用户读到一半往往就停在那儿看——于是那一屏
  /// 的空白会被钉到永久冷却为止。等待时长取「下一次到期时刻」与 [retryPoll] 的较大值，
  /// 端点越快恢复回来得越早。
  void _scheduleRetryFlush() {
    if (!enabled || _retryTimer != null) return;
    final DateTime now = DateTime.now();
    Duration delay = retryPoll;
    final DateTime? next = _coordinator.nextRetryAt;
    if (next != null) {
      final Duration wait = next.difference(now);
      if (wait > delay) delay = wait;
    }
    _retryTimer = Timer(delay, _runRetryFlush);
  }

  Future<void> _runRetryFlush() async {
    _retryTimer = null;
    if (!enabled) return;
    if (!_coordinator.hasPendingRetry) return;
    final int requeued = await _coordinator.flushRetries();
    // 真机取证锚点：这一段是「失败之后自己站起来」的那一跳。日志里出现
    // `retry requeued=N` 就说明不是靠用户滚动触发的，是调度器自己把冷却到期的
    // 段落排回了队列（BUG-3369 的修复点之二）。
    debugPrint('[fushi-translation] retry requeued=$requeued');
    if (_coordinator.hasPendingRetry) _scheduleRetryFlush();
  }

  Future<void> _runScan() async {
    _timer = null;
    if (!enabled) return;
    final int ownGeneration = _navGeneration;

    final dynamic raw = await _evaluate(
      ReaderTranslationScripts.collectVisibleTargetsInvocation(
        aheadPx: aheadPx,
        limit: maxPerScan,
      ),
    );
    // 期间换了章：这份清单属于旧文档，id 可能撞到新章的别的段落上。
    if (ownGeneration != _navGeneration) return;

    final List<ReaderTranslationTarget> targets = _parseTargets(raw);
    // 真机取证锚点：`adb logcat | grep fushi-translation`。每次落定扫描一行，
    // 直接暴露「收集到了几段」——收集恒为 0 / 恒为章首段落这类几何判定错误，
    // 在这里一眼可见，不必再靠「没日志」反推。
    //
    // raw 预览（2.10.0 排查期加的）用来区分「JS 根本没扫到段落」与「扫到了但
    // 请求失败」——两者在界面上都是「什么都没出现」，只有回传能分开。
    final String rawPreview = raw is String ? raw : '$raw';
    debugPrint(
      '[fushi-translation] scan targets=${targets.length} '
      'rawLen=${rawPreview.length} '
      'raw=${rawPreview.substring(0, rawPreview.length > 500 ? 500 : rawPreview.length)}',
    );
    if (targets.isEmpty) return;
    await _coordinator.enqueue(targets);
  }

  Future<String> _fetch(String text) async {
    try {
      final TranslationResult result = await _client.translate(
        _engineId,
        text,
        target: _target,
      );
      return result.translatedText;
    } on TranslationFailure catch (failure) {
      // 码空间已经对齐（network_error / http_5xx / empty_response / ...），
      // 直接搬运，让队列层的失败冷却照常生效。
      throw ReaderTranslationFailure(failure.message);
    } catch (_) {
      throw const ReaderTranslationFailure('unknown');
    }
  }

  Future<void> _onOutcome(ReaderTranslationOutcome outcome) async {
    final String? translated = outcome.translatedText;
    if (translated == null) {
      // 失败只在本段留出空白，不打 UI 骚扰用户；但打一行日志，便于真机用
      // `adb logcat` 抓 `[fushi-translation]` 定位失败码（http_401 / http_429 / ...）。
      debugPrint(
        '[fushi-translation] fail id=${outcome.targetId} '
        'code=${outcome.failureCode} engine=${_engineId.storageValue}',
      );
      // 关键：挂上自主重试。用户的屏幕上这一屏可能永远不再滚动（他就在这一页读），
      // 光等下一次 collect 等于把这一屏判了死刑。
      _scheduleRetryFlush();
      return;
    }
    // 真机取证锚点：译文每一次真正落地都留一行，配合上面的 `scan` / `fail` /
    // `retry` 就能在 `adb logcat` 里把「译了多少段、断在哪、有没有自己接上」
    // 完整读出来（BUG-3369 的设备复测口径）。
    debugPrint(
      '[fushi-translation] ok id=${outcome.targetId} '
      'chars=${translated.length} engine=${_engineId.storageValue}',
    );
    await _evaluate(
      ReaderTranslationScripts.applyTranslationInvocation(
        outcome.targetId,
        translated,
      ),
    );
  }

  /// 解析 JS 回传的 `[{id, text}]`。JS 侧已经保证是 JSON 文本。
  ///
  /// 任何形状问题都当空列表处理：翻译是**增强**功能，绝不能因为一段畸形回传把阅读器
  /// 拖出问题。
  List<ReaderTranslationTarget> _parseTargets(dynamic raw) {
    if (raw is! String || raw.isEmpty) return const <ReaderTranslationTarget>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List<Object?>) return const <ReaderTranslationTarget>[];
      final List<ReaderTranslationTarget> out = <ReaderTranslationTarget>[];
      for (final Object? item in decoded) {
        if (item is! Map<String, Object?>) continue;
        final Object? id = item['id'];
        final Object? text = item['text'];
        if (id is! String || text is! String) continue;
        out.add(ReaderTranslationTarget(id: id, text: text));
      }
      return out;
    } catch (_) {
      return const <ReaderTranslationTarget>[];
    }
  }
}
