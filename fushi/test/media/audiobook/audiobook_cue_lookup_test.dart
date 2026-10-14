import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 真机 ANR（2026-10-15 07:25:01，app.fushi.reader.dev）：main 线程 state=R、
/// 104% user CPU、栈顶 `[anon:dart-code]`，卡在 `Input dispatching timed out`。
///
/// 根因：TTS 朗读把「全书每句一条」灌进 cue 表（reader_fushi/audiobook.part.dart 的
/// `setChapterCues(ttsCues)` / `setAllBookCues(ttsCues)`），几十万条；而每个 125ms
/// 播放 tick 都对这张表做 O(N) 扫描：
///   - `_chapterCuesForAudioFile` = `_chapterCues.where(...).toList()` 整表过滤；
///   - `_chapterCues.indexOf(cue)` 整表找下标；
///   - `cueAtCurrentPositionInBook` 整表扫 `_allBookCues`。
/// 三次 O(N) × 每秒 8 tick × N≈几十万 → 主线程被拖死，UI 不再响应。
///
/// 修法：cue 表按 (audioFileIndex, startMs) 排好，一个文件的 cue 是连续一段，
/// 用二分取 span；段结果按文件缓存。本测试钉住**正确性**（别把 span 取错）与
/// **缓存**（tick 里不再整表扫）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const int kFiles = 20000;
  const int kPerFile = 2;

  AudioCue cue(int fileIndex, int startMs) => AudioCue()
    ..id = fileIndex * 100 + startMs
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = fileIndex * 100 + startMs
    ..textFragmentId = 'cue-$fileIndex-$startMs'
    ..text = 'cue $fileIndex $startMs'
    ..startMs = startMs
    ..endMs = startMs + 1000
    ..audioFileIndex = fileIndex;

  List<AudioCue> allCues() => <AudioCue>[
    for (int f = 0; f < kFiles; f++)
      for (int i = 0; i < kPerFile; i++) cue(f, i * 1000),
  ];

  // 注意：AudioCue 的 == 是同一性比较，测试必须用**灌进去的那一批实例**去查，
  // 重新生成一批同字段的 cue 是查不到的（与生产代码同一条约束）。
  AudiobookPlayerController controllerWith(List<AudioCue> cues) {
    final AudiobookPlayerController c = AudiobookPlayerController();
    addTearDown(c.dispose);
    c.setChapterCues(cues);
    c.setAllBookCues(cues);
    return c;
  }

  test('file cue slice only contains that file\'s cues, in order', () {
    final AudiobookPlayerController c = controllerWith(allCues());

    expect(
      c.fileCuesForAudioFileForTesting(0).map((AudioCue e) => e.startMs),
      <int>[0, 1000],
    );
    expect(
      c.fileCuesForAudioFileForTesting(12345).map((AudioCue e) => e.startMs),
      <int>[0, 1000],
    );
    // 越界文件 → 空段，不是异常。
    expect(c.fileCuesForAudioFileForTesting(kFiles), isEmpty);
    expect(c.fileCuesForAudioFileForTesting(-1), isEmpty);
  });

  test('file cue slices are cached, so a tick is a map lookup', () {
    final AudiobookPlayerController c = controllerWith(allCues());

    final List<AudioCue> a = c.fileCuesForAudioFileForTesting(777);
    final List<AudioCue> b = c.fileCuesForAudioFileForTesting(777);
    expect(identical(a, b), isTrue);

    // 换 cue 列表后缓存必须失效，否则换章会拿到上一章的段。
    c.setChapterCues(<AudioCue>[cue(0, 0)]);
    expect(c.fileCuesForAudioFileForTesting(777), isEmpty);
  });

  test('cue index maps the in-file index back to the global table', () {
    final List<AudioCue> cues = allCues();
    final AudiobookPlayerController c = controllerWith(cues);

    // 全局下标 = 文件下标 * 每文件条数 + 文件内第几条。
    for (final int f in <int>[0, 1, 9999, kFiles - 1]) {
      for (int i = 0; i < kPerFile; i++) {
        expect(
          c.chapterCueIndexOfForTesting(cues[f * kPerFile + i]),
          f * kPerFile + i,
        );
      }
    }
    // 不在表里的 cue（别的文件）→ -1，不会误映射成别人的下标。
    expect(c.chapterCueIndexOfForTesting(cue(5, 5000)), -1);
  });

  test('cueAtCurrentPositionInBook still resolves the right sentence', () {
    final AudiobookPlayerController c = controllerWith(allCues());

    // 未 seek 时播放器停在文件 0 位置 0 → 首句。
    expect(c.cueAtCurrentPositionInBook()?.audioFileIndex, 0);
    expect(c.cueAtCurrentPositionInBook()?.startMs, 0);
  });

  test('repeated per-tick lookups over a whole-book cue table stay cheap', () {
    final List<AudioCue> cues = allCues();
    final AudiobookPlayerController c = controllerWith(cues);

    final Stopwatch sw = Stopwatch()..start();
    for (int i = 0; i < 1000; i++) {
      final int f = i % kFiles;
      c.fileCuesForAudioFileForTesting(f);
      c.chapterCueIndexOfForTesting(cues[f * kPerFile]);
      c.cueAtCurrentPositionInBook();
    }
    sw.stop();

    // 退化回 O(N) 的话这里会是「几万 × 几千次」量级，远超 2s。给足余量只防回归。
    expect(
      sw.elapsedMilliseconds,
      lessThan(2000),
      reason: 'tick 路径不该再是 O(全书句数)：实测 ${sw.elapsedMilliseconds}ms',
    );
  });
}
