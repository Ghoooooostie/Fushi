import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_translation_coordinator.dart';

ReaderTranslationTarget _t(String id, String text) =>
    ReaderTranslationTarget(id: id, text: text);

/// 让 drain 的微任务链跑完。一次队列推进涉及多个 await 边界，单拍不够。
Future<void> settle([int times = 6]) async {
  for (int i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Harness {
  _Harness({
    int maxCachedEntries = 300,
    this.manualClock = false,
    this.throttled = false,
  }) {
    coordinator = ReaderTranslationCoordinator(
      fetch: (String text) async {
        calls.add(text);
        final ReaderTranslationFailure? failure = nextFailure;
        if (failure != null) {
          nextFailure = null;
          throw failure;
        }
        final Completer<String> completer = Completer<String>();
        _pending[text] = completer;
        return completer.future;
      },
      onOutcome: outcomes.add,
      maxCachedEntries: maxCachedEntries,
      // 默认关掉节流：段与段之间真睡 800ms 会把测试拖成几秒一个，且不必要。
      // 只有专门测「连续失败拉长间隔」的那一条才打开（[throttled]）。
      minRequestInterval: throttled ? kMinRequestInterval : Duration.zero,
      maxRequestInterval: throttled ? kMaxRequestInterval : Duration.zero,
      now: () => manualClock ? _now : DateTime.now(),
    );
  }

  final List<String> calls = <String>[];
  final List<ReaderTranslationOutcome> outcomes = <ReaderTranslationOutcome>[];
  final Map<String, Completer<String>> _pending = <String, Completer<String>>{};
  ReaderTranslationFailure? nextFailure;
  final bool manualClock;

  /// 是否用真实的请求节流间隔（默认关）。
  final bool throttled;

  /// 手动时钟读数。冷却有可能长达几十秒，真睡是把测试拖死，只能推时钟。
  DateTime _now = DateTime.utc(2026, 10, 19, 12);

  late final ReaderTranslationCoordinator coordinator;

  void advance(Duration step) => _now = _now.add(step);

  bool complete(String text, [String value = '译文']) {
    final Completer<String>? pending = _pending.remove(text);
    if (pending == null) return false;
    // 手动时钟：一次往返总要花点时间，推 1s 让「请求节流间隔」在测试里不是障碍
    // （否则每一段后面都要真睡 800ms，测试就跑不动了）。
    if (manualClock) advance(const Duration(seconds: 1));
    pending.complete(value);
    return true;
  }

  ReaderTranslationOutcome? outcomeFor(String id) {
    for (final ReaderTranslationOutcome outcome in outcomes) {
      if (outcome.targetId == id) return outcome;
    }
    return null;
  }

  /// 这一段**最后一次**的结局。同一段可能先失败后成功，只看第一条会误判成还失败着。
  ReaderTranslationOutcome? lastOutcomeFor(String id) {
    ReaderTranslationOutcome? found;
    for (final ReaderTranslationOutcome outcome in outcomes) {
      if (outcome.targetId == id) found = outcome;
    }
    return found;
  }
}

void main() {
  group('去重：同一段落不排两次', () {
    test('已在队列中的同一 id 再次入队会被丢弃', () async {
      final _Harness h = _Harness();
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', '正文A')]);
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', '正文A')]);
      await settle();
      h.complete('正文A');
      await settle();

      expect(h.calls, <String>['正文A']); // 只发了一次请求
      expect(h.coordinator.pendingCount, 0);
    });

    test('在飞的请求还没回来时，重复入队也不算新的一段', () async {
      final _Harness h = _Harness();
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', '正文A')]);
      await settle(); // 已进入 in-flight
      expect(h.coordinator.inFlightCount, 1);

      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', '正文A')]);
      await settle();

      expect(h.calls, <String>['正文A']);
      expect(h.coordinator.inFlightCount, 1);
    });
  });

  group('缓存：按正文做 key', () {
    test('不同 id、同一正文只译一次（跨章也成立）', () async {
      final _Harness h = _Harness();
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', '同一段正文')]);
      await settle();
      h.complete('同一段正文', '这段的译文');
      await settle();

      // 换章之后同一段正文重新露面（id 是新的）。
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('b', '同一段正文')]);
      await settle();

      expect(h.calls, <String>['同一段正文']);
      expect(h.outcomeFor('b')?.translatedText, '这段的译文');
    });

    test('只有空白差异的正文视为同一段', () async {
      final _Harness h = _Harness();
      await h.coordinator.enqueue(<ReaderTranslationTarget>[
        _t('a', '  正文\n\n  A  '),
      ]);
      await settle();
      h.complete('  正文\n\n  A  ', '译文');
      await settle();

      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('b', '正文 A')]);
      await settle();

      expect(h.calls, hasLength(1));
    });

    test('超限后淘汰最旧的一半而不是全丢', () async {
      final _Harness h = _Harness(maxCachedEntries: 4);
      for (int i = 0; i < 6; i++) {
        final String text = '正文$i';
        await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('t$i', text)]);
        await settle();
        h.complete(text, '译$i');
        await settle();
      }
      expect(h.coordinator.cachedCount, lessThanOrEqualTo(4));
      expect(h.coordinator.cachedCount, greaterThan(0));
    });
  });

  group('串行：一次只飞一个', () {
    test('三段同时入队，任一时刻只有一个在飞', () async {
      // 手动时钟：段与段之间有 800ms 节流，真睡会让这个测试原地等一秒多。
      final _Harness h = _Harness(manualClock: true);
      await h.coordinator.enqueue(<ReaderTranslationTarget>[
        _t('a', 'A'),
        _t('b', 'B'),
        _t('c', 'C'),
      ]);
      await settle();

      expect(h.coordinator.inFlightCount, 1);
      expect(h.calls, <String>['A']); // 第二段还没发出去

      h.complete('A');
      await settle();
      expect(h.calls, <String>['A', 'B']);
      expect(h.coordinator.inFlightCount, 1);
    });

    test('全部完成后回到 idle', () async {
      final _Harness h = _Harness();
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', 'A')]);
      await settle();
      h.complete('A');
      await settle();

      expect(h.coordinator.isIdle, isTrue);
      expect(h.outcomes, hasLength(1));
    });
  });

  group('换章：在途结果必须作废', () {
    test('cancel 之后回来的译文不再回填', () async {
      final _Harness h = _Harness();
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', 'A')]);
      await settle();

      final int before = h.coordinator.generation;
      h.coordinator.cancel();
      expect(h.coordinator.generation, before + 1);
      expect(h.coordinator.pendingCount, 0);

      h.complete('A', '旧章的译文');
      await settle();

      // 关键：DOM 已经换了，id 可能撞到新章完全不同的段落上，回填就是脏数据。
      expect(h.outcomes, isEmpty);
    });

    test('cancel 清掉失败重试池：旧文档的段落不该被排进新文档', () async {
      final _Harness h = _Harness(manualClock: true);
      h.nextFailure = const ReaderTranslationFailure('http_500');
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', 'A')]);
      await settle();
      expect(h.coordinator.hasPendingRetry, isTrue);

      h.coordinator.cancel();

      // DOM 已经重建，这里的 id 就算撞到新章的某个段落也不是同一段了。
      expect(h.coordinator.hasPendingRetry, isFalse);
      expect(await h.coordinator.flushRetries(), 0);
    });

    test('cancel 不清缓存：滚回来还得立刻有译文', () async {
      final _Harness h = _Harness();
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', 'A')]);
      await settle();
      h.complete('A', '译A');
      await settle();

      h.coordinator.cancel();
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('b', 'A')]);
      await settle();

      expect(h.calls, <String>['A']); // 命中缓存，没再发请求
      expect(h.outcomeFor('b')?.translatedText, '译A');
    });
  });

  group('失败：按阶梯冷却后自动重试（BUG-3369）', () {
    test('冷却期内重复入队不再重打同一段', () async {
      final _Harness h = _Harness(manualClock: true);
      h.nextFailure = const ReaderTranslationFailure('network_error');
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', 'A')]);
      await settle();

      expect(h.outcomeFor('a')?.failureCode, 'network_error');
      expect(h.coordinator.hasPendingRetry, isTrue);

      // 用户原地滚一下手 —— 同一段又被 collect 上来。此刻还在冷却窗口里（2s）。
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', 'A')]);
      await settle();

      // 用户每滚一次都重发同一个刚刚失败的端点请求，会把 API 打得越来越糟。
      expect(h.calls, <String>['A']);
    });

    test('冷却到期后 flushRetries 会把这一段重新排进来', () async {
      final _Harness h = _Harness(manualClock: true);
      h.nextFailure = const ReaderTranslationFailure('network_error');
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', 'A')]);
      await settle();
      expect(h.calls, <String>['A']);

      final DateTime? next = h.coordinator.nextRetryAt;
      expect(next, isNotNull);

      // 还在冷却期内：flush 什么也不做。
      await h.coordinator.flushRetries();
      expect(h.calls, <String>['A']);

      h.advance(const Duration(seconds: 3));
      expect(await h.coordinator.flushRetries(), 1);

      // 重试成功：这次请求真的发出去了，而且译文回填到同一个段落上。
      h.complete('A', '译文A');
      await settle();
      expect(h.calls, <String>['A', 'A']);
      expect(h.lastOutcomeFor('a')?.translatedText, '译文A');
      expect(h.coordinator.hasPendingRetry, isFalse);
    });

    test('再失败一次：冷却阶梯变长，且不会被判死刑', () async {
      final _Harness h = _Harness(manualClock: true);

      // 第一次失败：t0 → 冷却 2s。
      h.nextFailure = const ReaderTranslationFailure('network_error');
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', 'A')]);
      await settle();

      // 冷却到期后重试，又失败： attempts=2 → 冷却 5s。
      h.advance(const Duration(seconds: 3));
      h.nextFailure = const ReaderTranslationFailure('network_error');
      await h.coordinator.flushRetries();
      await settle();

      // 旧实现在这里已经离「判死刑」（4 次）只差两步，且只剩唯一的滚动重试入口；
      // 现在它是「待重试 + 更长的等待」，端点缓过来就自己补上。
      expect(h.coordinator.hasPendingRetry, isTrue);
      final DateTime? next = h.coordinator.nextRetryAt;
      expect(next, isNotNull);
      expect(
        next!.difference(DateTime.utc(2026, 10, 19, 12)),
        const Duration(seconds: 8), // 3s（推过的时钟）+ 5s 阶梯
      );

      // 推到下一次到期：这一段又被排进来，这次成功。
      h.advance(const Duration(seconds: 5));
      expect(await h.coordinator.flushRetries(), 1);
      h.complete('A', '译文A');
      await settle();
      expect(h.lastOutcomeFor('a')?.translatedText, '译文A');
      expect(h.coordinator.hasPendingRetry, isFalse);
    });

    test('限流类失败（429）冷却翻倍', () async {
      final _Harness h = _Harness(manualClock: true);
      h.nextFailure = const ReaderTranslationFailure('http_429');
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', 'A')]);
      await settle();

      expect(
        h.coordinator.nextRetryAt!.difference(DateTime.utc(2026, 10, 19, 12)),
        const Duration(seconds: 4), // 2s 阶梯翻倍
      );
    });

    test('连续失败拉长请求间隔，成功即恢复', () async {
      final _Harness h = _Harness(manualClock: true, throttled: true);
      expect(h.coordinator.requestInterval, const Duration(milliseconds: 800));

      h.nextFailure = const ReaderTranslationFailure('http_429');
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', 'A')]);
      await settle();
      expect(h.coordinator.requestInterval, const Duration(milliseconds: 1600));

      h.advance(const Duration(seconds: 5));
      await h.coordinator.flushRetries();
      h.complete('A', '译文A');
      await settle();
      expect(h.coordinator.requestInterval, const Duration(milliseconds: 800));
    });

    test('未知异常也被收敛成码，不会把队列卡死', () async {
      final _Harness h = _Harness();
      final ReaderTranslationCoordinator c = ReaderTranslationCoordinator(
        fetch: (String _) async => throw StateError('boom'),
        onOutcome: h.outcomes.add,
      );
      await c.enqueue(<ReaderTranslationTarget>[_t('a', 'A')]);
      await settle();

      expect(h.outcomeFor('a')?.failureCode, 'unknown');
      expect(c.isIdle, isTrue);
    });

    test('reset 之后失败冷却与缓存一起清空（换了目标语言要靠它）', () async {
      final _Harness h = _Harness(manualClock: true);
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', 'A')]);
      await settle();
      h.complete('A', '中文译文');
      await settle();
      expect(h.coordinator.cachedCount, 1);

      h.coordinator.reset();
      expect(h.coordinator.cachedCount, 0);

      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('b', 'A')]);
      await settle();
      expect(h.calls, <String>['A', 'A']); // 目标语言换了，必须重译
    });
  });

  group('边界', () {
    test('空文本与纯空白不入队', () async {
      final _Harness h = _Harness();
      await h.coordinator.enqueue(<ReaderTranslationTarget>[
        _t('a', ''),
        _t('b', '   '),
      ]);
      await settle();
      expect(h.calls, isEmpty);
      expect(h.coordinator.pendingCount, 0);
    });

    test('引擎返回空译文视为失败，不进缓存', () async {
      final _Harness h = _Harness();
      await h.coordinator.enqueue(<ReaderTranslationTarget>[_t('a', 'A')]);
      await settle();
      h.complete('A', '   ');
      await settle();

      expect(h.outcomeFor('a')?.failureCode, 'empty_response');
      expect(h.coordinator.cachedCount, 0);
    });
  });
}
