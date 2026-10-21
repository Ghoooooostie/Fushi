import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/media/audiobook/tts/tts_read_along.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

/// 制卡取句子音频（`sentence audio export failed: input audio file does not
/// exist: .../tts_cache/<key>.audio`）。
///
/// 朗读会话交给有声书播放器的 `audioFiles[i]` 是按缓存键拼出来的「将来路径」
/// （`TtsReadAlong._filesFor` → `TtsSynthesisScheduler.audioPathOf`）：只有读到的
/// 句子（含预取窗口内）才真有文件。制卡若直接把它当 ffmpeg 输入，在没读到的句子上
/// 必然早退成「文件不存在」并把整张卡判死。这里锁住 [TtsReadAlong
/// .ensureSentenceAudio]：先把那一句真正合成出来，再交出真实路径。
Uint8List _wav() {
  const int dataBytes = 3200;
  final ByteData b = ByteData(44 + dataBytes);
  void ascii(int at, String s) {
    for (int i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 1, Endian.little);
  b.setUint32(24, 16000, Endian.little);
  b.setUint32(28, 32000, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  return b.buffer.asUint8List();
}

class _MemoryPrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values[key] ?? defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async {
    values[key] = value;
  }
}

/// 假引擎：[hang] = 请求一直挂着直到被取消；[fail] = 立刻以网络失败告终。
class _FakeProvider extends TtsProvider {
  _FakeProvider(this.owner);

  final _FakeDescriptor owner;
  bool hang = false;
  bool fail = false;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: true,
    needsCredential: false,
    maxConcurrency: 2,
  );

  @override
  Future<TtsResult> synthesize(
    String text, {
    required String outputPath,
    required TtsCancelToken cancel,
  }) async {
    owner.calls.add(text);
    if (fail) {
      throw const TtsFailure(TtsFailureCode.network, 'boom');
    }
    if (hang) {
      final Completer<void> cancelled = Completer<void>();
      cancel.onCancel(cancelled.complete);
      await cancelled.future;
      throw const TtsFailure(TtsFailureCode.cancelled);
    }
    await File(outputPath).writeAsBytes(_wav());
    return const TtsResult(format: TtsAudioFormat.wav);
  }

  @override
  Future<void> dispose() async {}
}

class _FakeDescriptor extends TtsProviderDescriptor {
  final List<String> calls = <String>[];
  bool hang = false;
  bool fail = false;

  @override
  String get id => 'fake';

  @override
  bool get isAvailable => true;

  @override
  TtsCapabilities get capabilities => const TtsCapabilities(
    timing: TtsTimingGranularity.sentence,
    online: true,
    needsCredential: false,
    maxConcurrency: 2,
    maxInputLength: 300,
  );

  @override
  List<TtsParamSpec> get params => const <TtsParamSpec>[
    TtsParamSpec(key: 'voice', kind: TtsParamKind.voice, required: true),
  ];

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) => _FakeProvider(this)
    ..hang = hang
    ..fail = fail;
}

TtsVoicePreset _preset() => const TtsVoicePreset(
  id: 'a',
  providerId: 'fake',
  name: 'Voice A',
  params: <String, String>{'voice': 'A'},
);

TtsBookPlan _plan(int count) => TtsBookPlan(<TtsPlanSentence>[
  for (int i = 0; i < count; i++)
    TtsPlanSentence(
      section: 0,
      href: 'c.xhtml',
      text: '句$i',
      spokenText: 'あああ$i',
      matchStart: i * 10,
      matchEnd: i * 10 + 10,
      studyStart: i * 10,
      studyEnd: i * 10 + 10,
    ),
]);

Future<void> _until(
  bool Function() condition, {
  Duration limit = const Duration(seconds: 10),
}) async {
  final DateTime deadline = DateTime.now().add(limit);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $limit');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory root;
  late TtsAudioCache cache;
  final List<TtsReadAlong> live = <TtsReadAlong>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tts_sentence_audio_test');
    cache = TtsAudioCache(root: root);
  });

  tearDown(() async {
    for (final TtsReadAlong r in live) {
      await r.debugScheduler.dispose();
    }
    live.clear();
    await root.delete(recursive: true);
  });

  TtsReadAlong newSession({required _FakeDescriptor descriptor}) {
    final TtsReadAlong readAlong = TtsReadAlong.debugCreate(
      plan: _plan(12),
      preset: _preset(),
      descriptor: descriptor,
      cache: cache,
      host: const TtsHost(),
      store: TtsPresetStore(_MemoryPrefs()),
    );
    live.add(readAlong);
    return readAlong;
  }

  test('synthesizes a not-yet-read sentence on demand before handing out the '
      'clip input path', () async {
    final _FakeDescriptor descriptor = _FakeDescriptor();
    final TtsReadAlong readAlong = newSession(descriptor: descriptor);
    // 只预取 1 句：第 9 句远在读到的范围之外，磁盘上还没有它的文件（用户报障现场）。
    readAlong.debugScheduler.setLookahead(1);
    await readAlong.debugScheduler.ensure(0);

    final String futurePath = readAlong.debugScheduler.audioPathOf(9);
    expect(
      File(futurePath).existsSync(),
      isFalse,
      reason: '前提：未读到的句子缓存文件确实不存在（复现报障现象）。',
    );

    final TtsSentenceAudio? audio = await readAlong.ensureSentenceAudio(9);

    expect(audio?.path, futurePath);
    expect(
      audio?.durationMs,
      greaterThan(0),
      reason:
          '必须同时给出真实时长：cue 上的时长在未合成时是按字数估的，'
          '裁剪区间照它走会裁短 / 多裁。',
    );
    expect(
      File(futurePath).existsSync(),
      isTrue,
      reason: '制卡拿到路径后必须能真的读到文件，否则 ffmpeg 仍会早退。',
    );
  });

  test(
    'returns null immediately once the scheduler stopped on a failure',
    () async {
      final _FakeDescriptor descriptor = _FakeDescriptor()..fail = true;
      final TtsReadAlong readAlong = newSession(descriptor: descriptor);
      // 失败后调度不再发起新合成：ensure 的等待者不会被完成，只能靠 failure 判定。
      // 这个 future 要到 tearDown 的 dispose 才以 cancelled 结束，挂个空错误处理，
      // 免得它变成未捕获的异步错误把测试判红。
      unawaited(
        readAlong.debugScheduler
            .ensure(0)
            .then<void>((_) {}, onError: (Object _, StackTrace __) {}),
      );
      await _until(() => readAlong.debugScheduler.failure != null);

      final Stopwatch watch = Stopwatch()..start();
      final TtsSentenceAudio? audio = await readAlong.ensureSentenceAudio(
        5,
        timeout: const Duration(seconds: 10),
      );

      expect(audio, isNull);
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: '调度已停时不能空等超时——直接返回 null 让制卡降级。',
      );
    },
  );

  test(
    'returns null when the on-demand synthesis does not finish in time',
    () async {
      final _FakeDescriptor descriptor = _FakeDescriptor()..hang = true;
      final TtsReadAlong readAlong = newSession(descriptor: descriptor);

      final TtsSentenceAudio? audio = await readAlong.ensureSentenceAudio(
        3,
        timeout: const Duration(milliseconds: 300),
      );

      expect(audio, isNull, reason: '挂在途的合成不能把制卡一起挂住。');
    },
  );

  test('sentenceRangeByText picks the unit whose text IS the card sentence, '
      'even when the coordinates point at a different one', () async {
    // 真机形态复刻（`無職転生` 第 25 章）：卡片句的 span 与某个单元的 match 区间
    // **完全重合**，可那个单元念的是另一句——两套归一化不同源导致的整章漂移。
    const String cardSentence = 'こんな土地に閉じ込められれば、魔族だって戦争を起こすだろう。';
    const String otherSentence = 'ルイジェルドは走りだしてから、五分もしないうちに帰ってくる。';
    final _FakeDescriptor descriptor = _FakeDescriptor();
    final TtsReadAlong readAlong = TtsReadAlong.debugCreate(
      plan: TtsBookPlan(<TtsPlanSentence>[
        _sentence(otherSentence, matchStart: 1269, matchEnd: 1297),
        _sentence(cardSentence, matchStart: 5000, matchEnd: 5028),
      ]),
      preset: _preset(),
      descriptor: descriptor,
      cache: cache,
      host: const TtsHost(),
      store: TtsPresetStore(_MemoryPrefs()),
    );
    live.add(readAlong);

    // 坐标落在单元 0（念别的句子的那个）。
    final AudioPlaybackRange? range = readAlong.sentenceRangeByText(
      sentence: cardSentence,
      sectionIndex: 0,
      normCharOffset: 1269,
    );

    expect(range?.audioFileIndex, 1, reason: '必须按正文文本落到真正念这一句的单元。');
    expect(
      readAlong.unitCoversSentence(index: 0, sentence: cardSentence),
      isFalse,
      reason: '坐标定位的结果必须能被文本校验挡下来（否则又给一张错音频的卡）。',
    );
    expect(
      readAlong.unitCoversSentence(index: 1, sentence: cardSentence),
      isTrue,
    );
  });

  test(
    'sentenceRangeByText returns null when no unit speaks the sentence',
    () async {
      final TtsReadAlong readAlong = newSession(descriptor: _FakeDescriptor());
      expect(
        readAlong.sentenceRangeByText(
          sentence: '这本书里根本没有的一句话',
          sectionIndex: 0,
          normCharOffset: 0,
        ),
        isNull,
        reason: '定位不到就该让制卡降级，不能用坐标硬凑一个单元。',
      );
    },
  );
}

TtsPlanSentence _sentence(
  String text, {
  required int matchStart,
  required int matchEnd,
}) => TtsPlanSentence(
  section: 0,
  href: 'c.xhtml',
  text: text,
  spokenText: text,
  matchStart: matchStart,
  matchEnd: matchEnd,
  studyStart: matchStart,
  studyEnd: matchEnd,
);
