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
/// 失败的段落另有一条：**永不永久放弃，但必须按阶梯冷却**。一次失败只是把它放进冷却
/// 池、算好下次重试时刻；连续失败时连请求间隔一起拉长（429/5xx/超时的还翻倍），端点
/// 缓过来就自动补上，不需要用户做任何操作。旧的「失败 4 次永久冷却」会让端点一次抖动
/// 变成「整章后半段再也不翻译」（BUG-3369），用限流保护换了阅读连续性，得不偿失。
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

/// 每段失败后的**重试等待时长**。返回「这段还要等多久才允许再试一次」。
///
/// [failureCode] 是 [ReaderTranslationFailure.code]，[attempts] 是该段累计失败次数
/// （首次失败时 = 1）。调用方用它排下一次重试的时刻。
typedef ReaderTranslationCooldown = Duration Function(
  String failureCode,
  int attempts,
);

/// 失败∞次也**不永久放弃**（BUG-3369：旧的「失败 4 次永久冷却」让整章后半段再也
/// 翻译不出来，用户看到的就是「翻到一半就不翻了」）；但每次失败的等待必须按阶梯
/// 拉长，否则正在限流的端点会被越打越糟。
///
/// 阶梯：2s → 5s → 15s → 30s → 60s → 60s …；限流类失败（429 / rate_limited /
/// timeout）翻倍——端点明确说了「慢点」，就该真的慢点。
Duration defaultReaderTranslationCooldown(String failureCode, int attempts) {
  const List<Duration> steps = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];
  const Duration cap = Duration(seconds: 60);
  final int index = (attempts < 1 ? 1 : attempts) - 1;
  final Duration base = index < steps.length ? steps[index] : cap;
  final bool throttled = failureCode == 'http_429' ||
      failureCode == 'rate_limited' ||
      failureCode == 'timeout';
  return throttled ? base * 2 : base;
}

/// 翻译失败。[code] 是可直接显示的短码（`network_error` / `http_401` / ...），
/// 不含 URL 与响应体——那些可能回显凭据。
class ReaderTranslationFailure implements Exception {
  const ReaderTranslationFailure(this.code);

  final String code;

  @override
  String toString() => 'ReaderTranslationFailure: $code';
}

/// 一段过去失败过的段落此刻的状态。
class _FailedEntry {
  _FailedEntry({required this.target, required this.attempts, required this.nextAttemptAt});

  final ReaderTranslationTarget target;
  int attempts;
  DateTime nextAttemptAt;

  /// 已经被重排回队列（正在等 / 正在飞）。带上这个标记才不会丢掉累计失败次数，
  /// 又不会被 [flushRetries] 反复重排。
  bool requeued = false;
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

/// 两次翻译请求之间的最小间隔（健康状态）：网页翻译端点（彩云）有速率限制，不打节流
/// 会瞬间打爆 → 触发限流失败 → 整章不翻。用户反馈「是不是翻译太快了」即此。
const Duration kMinRequestInterval = Duration(milliseconds: 800);

/// [kMinRequestInterval] 在连续失败时可被拉到的上限：再慢也不越过这道线，否则端点
/// 恢复了用户也要干等。
const Duration kMaxRequestInterval = Duration(seconds: 8);

/// 段落队列调度器。
class ReaderTranslationCoordinator {
  ReaderTranslationCoordinator({
    required this.fetch,
    this.maxCachedEntries = 300,
    this.onOutcome,
    this.cooldown = defaultReaderTranslationCooldown,
    this.minRequestInterval = kMinRequestInterval,
    this.maxRequestInterval = kMaxRequestInterval,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 注入的翻译实现。
  final ReaderTranslationFetch fetch;

  /// 译文缓存的条目上限。超过后丢掉最早的一半（近似 LRU，用 Map 的插入顺序）。
  final int maxCachedEntries;

  /// 出队结局的回流口。调用方据此把译文回填到 WebView。
  ///
  /// 故意不是构造期 `final`：scheduler 允许注入一个已构造好的实例（测试要用自定义
  /// 冷却策略），那时它的回流口必须能被改写，否则译文没有出口、测试只会看到「什么
  /// 都没发生」。
  void Function(ReaderTranslationOutcome outcome)? onOutcome;

  /// 失败重试的等待策略。默认 [defaultReaderTranslationCooldown]，测试可换掉。
  final ReaderTranslationCooldown cooldown;

  /// 时钟注入点。由此[flushRetries] 的到期判定可以在测试里被确定性推进，
  /// 不必真的睡几十秒。
  final DateTime Function() _now;

  final List<ReaderTranslationTarget> _queue = <ReaderTranslationTarget>[];
  final Set<String> _queuedIds = <String>{};
  final Set<String> _inFlightIds = <String>{};

  /// 失败过的段落 → 它的重试时刻与已失败次数。**永不永久冷却**：每次到达
  /// [nextAttemptAt] 就再排一次（等待时长按 [cooldown] 阶梯增长）。
  ///
  /// 旧的 `_failureCount` + `_maxRetries = 4` 就是 BUG-3369 的成因：读到十几段后端点
  /// 抖一下，这些段各自攒满 4 次失败后就被判死刑，整章后半段再也不会有译文，而用户
  /// 侧没有任何提示——表现为「翻译到一半就不翻了」。
  final Map<String, _FailedEntry> _failed = <String, _FailedEntry>{};

  /// 失败段落池的上限。只有在**整章大量段落持续失败**的极端情况下才会触到；触到时
  /// 丢最早进池的那批（它们的下一次重试排在最后、最不急着救），保住队列有界。
  static const int _maxFailedEntries = 200;

  /// 连续失败次数（跨段落计数）。只用来控制节流节奏：连续失败说明端点正在不好过，
  /// 必须放慢而不是维持原速率猛打；**任何一次成功就归零**。
  int _consecutiveFailures = 0;

  /// 正文 → 译文。Map 保持插入顺序，用于近似 LRU 的淘汰。
  final Map<String, String> _cache = <String, String>{};

  bool _draining = false;

  /// 两次翻译请求之间的最小间隔（健康状态）：网页翻译端点（彩云）有速率限制，不打
  /// 节流会瞬间打爆 → 触发限流失败 → 整章不翻。用户反馈「是不是翻译太快了」即此。
  ///
  /// 与 [maxRequestInterval] 一样做成可注入：真实速率限制策略只有运行期才知道，
  /// 测试要能把它关掉，否则每段后面都得真睡一秒。
  final Duration minRequestInterval;

  /// 连续失败时节流的上限：再慢也不越过这道线，否则端点恢复了用户也要干等。
  final Duration maxRequestInterval;

  /// 上次真正发出请求的时刻，用于节流。
  DateTime? _lastRequestAt;

  /// 世代号。每次 [cancel] 自增：换了章，此前发出去的在途请求回来时会被判作废。
  int _generation = 0;

  int get generation => _generation;

  int get pendingCount => _queue.length;

  int get inFlightCount => _inFlightIds.length;

  int get cachedCount => _cache.length;

  bool get isIdle => _queue.isEmpty && _inFlightIds.isEmpty;

  /// 还有失败段落等着重试（冷却还没到期、也没被重排的才算）。
  bool get hasPendingRetry => _failed.values.any((_FailedEntry e) => !e.requeued);

  /// 下一次重试可以开始的时刻。没有待重试段落时为 null。
  ///
  /// 调用方（scheduler）据此安排定时器：到点了自然就来重排，**不需要用户再去滚一下**。
  DateTime? get nextRetryAt {
    DateTime? earliest;
    for (final _FailedEntry entry in _failed.values) {
      if (entry.requeued) continue;
      final DateTime at = entry.nextAttemptAt;
      if (earliest == null || at.isBefore(earliest)) earliest = at;
    }
    return earliest;
  }

  /// 当前的请求节流间隔：连续失败越多越慢，成功后回到 [minRequestInterval]。
  Duration get requestInterval {
    if (_consecutiveFailures <= 0) return minRequestInterval;
    final int shift = _consecutiveFailures > 4 ? 4 : _consecutiveFailures;
    final Duration scaled = minRequestInterval * (1 << shift);
    return scaled > maxRequestInterval ? maxRequestInterval : scaled;
  }

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
      // ① 已在队列 / 在飞的不重复排；② 冷却还没过的段不重复排——它留在失败池里，
      //    到期由 [flushRetries] 自己回来（用户不滚动也会回来，这是「连续翻译」的关键）。
      if (_queuedIds.contains(target.id) || _inFlightIds.contains(target.id)) {
        continue;
      }
      // 冷却中的段跳过；**已被 [flushRetries] 重排的段要放行** —— 它就靠这次入队
      // 重新回到队列里（条目留在池里只是为了让累计失败次数跟到下一次尝试）。
      final _FailedEntry? cooling = _failed[target.id];
      if (cooling != null && !cooling.requeued) continue;

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

  /// 把**已经到点**的失败段落重新排回队列。返回这次重排了几段。
  ///
  /// 由 scheduler 在定时器到点时调用（失败的那一刻就算好下一次时刻）。把重排放在
  /// 这里而不是等下一次滚动——用户可能只是停着读，这一屏失败的那几段要自己回来。
  Future<int> flushRetries() async {
    if (_failed.isEmpty) return 0;
    final DateTime now = _now();
    final List<ReaderTranslationTarget> due = <ReaderTranslationTarget>[];
    for (final _FailedEntry entry in _failed.values) {
      if (entry.requeued || entry.nextAttemptAt.isAfter(now)) continue;
      entry.requeued = true;
      due.add(entry.target);
    }
    if (due.isEmpty) return 0;
    // 条目**留在池里**（只是标了已重排）：累计失败次数要靠它带给下一次尝试，冷却阶梯
    // 才不会每次重排都从 2s 从头开始。真正出队那一刻由 `_drain` 摘掉。
    await enqueue(due);
    return due.length;
  }

  /// 换章 / 重排：作废队列与在途请求。
  ///
  /// 失败池一起清：那里的 id 属于**上一份文档**，DOM 重建后即使撞到同名 id 也不是同一
  /// 段了，重排只会白白往已经不存在的元素上发请求。
  ///
  /// [keepFailed] 保留下来只为语义完整：换了目标语言时用 [reset] 清缓存与失败池。
  void cancel({bool keepFailed = true}) {
    _generation++;
    _queue.clear();
    _queuedIds.clear();
    _failed.clear();
    if (!keepFailed) {
      _consecutiveFailures = 0;
    }
  }

  /// 清空一切（含缓存与失败池）：换了目标语言时用，否则会直接拿旧语言的译文回填。
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
        // 这一段此前失败过的次数：成功的一方开局是 0，重试的一方带着旧账进来，
        // 这样「第 N 次失败」的冷却阶梯是跨重试累积的，不会每次重排都从头开始。
        final int previousAttempts = _failed.remove(target.id)?.attempts ?? 0;
        try {
          // 节流：确保距上次请求至少 [requestInterval]，避免瞬间打爆彩云的速率限制
          // （用户反馈「是不是翻译太快了」即此——太快会触发限流失败，后续段段失败、
          // 整章不翻）。连续失败时间隔逐级拉长，端点缓过来之前不去添乱。
          final DateTime now = _now();
          if (_lastRequestAt != null) {
            final Duration since = now.difference(_lastRequestAt!);
            final Duration interval = requestInterval;
            if (since < interval) {
              await Future.delayed(interval - since);
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
          _lastRequestAt = _now();
        }

        _inFlightIds.remove(target.id);

        // 换章期间完成的结果一概丢弃：目标段落已经不在文档里了，回填会命中别的
        // 元素（DOM 重建后 id 可能指向完全不同的段落）。
        if (ownGeneration != _generation) continue;

        if (translated != null && translated.trim().isNotEmpty) {
          _consecutiveFailures = 0;
          _remember(target.text, translated);
          _emit(
            ReaderTranslationOutcome.success(
              targetId: target.id,
              translatedText: translated,
            ),
          );
        } else {
          // 失败只进「冷却池」，不进棺材：算下一次重试时刻，到点由 [flushRetries]
          // 自动重排。旧的「失败 N 次永久冷却」会把整章后半段锁死到会话结束——
          // 那才是用户看到的「翻译到一半就不翻了」（BUG-3369）。
          final String code = failureCode ?? 'empty_response';
          _noteFailure(target, code, previousAttempts);
          _emit(
            ReaderTranslationOutcome.failure(
              targetId: target.id,
              failureCode: code,
            ),
          );
        }
      }
    } finally {
      _draining = false;
    }
  }

  /// 记一次失败：attempts + 1，按 [cooldown] 算出下一次可以重试的时刻。
  void _noteFailure(ReaderTranslationTarget target, String code, int previousAttempts) {
    _consecutiveFailures++;
    final int attempts = previousAttempts + 1;
    _failed[target.id] = _FailedEntry(
      target: target,
      attempts: attempts,
      nextAttemptAt: _now().add(cooldown(code, attempts)),
    );
    if (_failed.length > _maxFailedEntries) {
      // 极端情况（整章持续失败）下的有界保证：丢最早进池的那批。
      final List<String> oldest = _failed.keys
          .take(_failed.length - _maxFailedEntries)
          .toList(growable: false);
      for (final String id in oldest) {
        _failed.remove(id);
      }
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
