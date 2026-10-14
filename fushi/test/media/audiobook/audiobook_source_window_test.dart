// ignore_for_file: experimental_member_use
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_controller.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// TTS 朗读把「全书每一句」做成一个 StreamAudioSource 整列交给 just_audio 时，
/// ExoPlayer 会给**每个** child 建 MediaSourceHolder + MaskingMediaSource，
/// Android 256MB 堆上直接 OOM（实测 app.fushi.reader.dev：
/// `OutOfMemoryError ... 85KB until OOM` @ `ConcatenatingMediaSource.<init>`）。
///
/// 修法：只维护一段滚动窗口，播放器里的 child 数封顶在
/// [AudiobookPlayerController.kSourceWindowSize]；于是「播放器 child 下标」
/// 不再等于「全局文件下标」，两者之间靠 `_fileIndexAt` / `_playerIndexAt` 映射。
///
/// 本测试钉住三件事：
///  1. 交给播放器的源数被封顶（不是全书句数），短列表行为不变；
///  2. 跳到窗口外的句子会重建窗口，且 seek 的是窗口内下标；
///  3. 播放推进到窗口尾部会向前滚动，滚动后当前句没变。
///
/// 断言口径：控制器用 `preload: false` 载入，just_audio 停在 idle 播放器上、
/// 假平台不会被激活（既有的 multifile 测试同样是这个前提），所以不钉平台请求，
/// 钉控制器自己可观察的窗口状态。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const int kWindow = AudiobookPlayerController.kSourceWindowSize;
  const int kLead = AudiobookPlayerController.kSourceWindowLead;

  group('source window math', () {
    test('short source lists are not windowed at all', () {
      expect(
        AudiobookPlayerController.shouldWindowSourcesTesting(kWindow),
        isFalse,
      );
      expect(
        AudiobookPlayerController.shouldWindowSourcesTesting(kWindow + 1),
        isTrue,
      );
    });

    test('anchor near the head clamps the window to the first source', () {
      expect(
        AudiobookPlayerController.windowStartForTesting(
          anchorFileIndex: 0,
          sourceCount: 5000,
        ),
        0,
      );
      expect(
        AudiobookPlayerController.windowStartForTesting(
          anchorFileIndex: 5,
          sourceCount: 5000,
        ),
        0,
      );
    });

    test('anchor in the middle keeps `lead` sentences behind it', () {
      expect(
        AudiobookPlayerController.windowStartForTesting(
          anchorFileIndex: 1000,
          sourceCount: 5000,
        ),
        1000 - kLead,
      );
    });

    test('anchor near the tail never overruns the end of the book', () {
      expect(
        AudiobookPlayerController.windowStartForTesting(
          anchorFileIndex: 4999,
          sourceCount: 5000,
        ),
        5000 - kWindow,
      );
    });

    test('window always ends inside the book', () {
      for (final int anchor in <int>[0, 1, 29, 30, 31, 99, 100]) {
        final int start = AudiobookPlayerController.windowStartForTesting(
          anchorFileIndex: anchor,
          sourceCount: 100,
        );
        expect(start, greaterThanOrEqualTo(0));
        expect(start + kWindow, lessThanOrEqualTo(100));
      }
    });

    test('a source list shorter than the window has a single window', () {
      expect(
        AudiobookPlayerController.windowStartForTesting(
          anchorFileIndex: 7,
          sourceCount: 10,
        ),
        0,
      );
    });
  });

  group('load() caps what reaches the player', () {
    test('200 TTS sentence sources → only one window is handed over', () async {
      _installPlatform();
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);

      c.setAllBookCues(_cues(200));
      await c.load(
        audiobook: _audiobook(),
        audioFiles: _files(200),
        audioSources: _sources(200),
      );

      expect(c.sourceWindowStartForTesting, 0);
      expect(c.sourceWindowLengthForTesting, kWindow);
      expect(c.playerSequenceLengthForTesting, kWindow);
      expect(c.playerSequenceLengthForTesting, lessThan(200));
    });

    test('a source list inside the window keeps the old whole-list behaviour',
        () async {
      _installPlatform();
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);

      await c.load(
        audiobook: _audiobook(),
        audioFiles: _files(20),
        audioSources: _sources(20),
      );

      expect(c.sourceWindowLengthForTesting, 0, reason: '不窗口化');
      expect(c.playerSequenceLengthForTesting, 20);
    });
  });

  group('global file index survives the window', () {
    test('jumping to sentence 150 rebuilds the window around it', () async {
      _installPlatform();
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);

      c.setAllBookCues(_cues(200));
      await c.load(
        audiobook: _audiobook(),
        audioFiles: _files(200),
        audioSources: _sources(200),
      );
      expect(c.sourceWindowStartForTesting, 0);

      await c.restoreToFileOffset(fileIndex: 150, positionMs: 0);

      expect(c.sourceWindowStartForTesting, 150 - kLead);
      expect(c.playerSequenceLengthForTesting, kWindow);
      // 窗口内下标 + 窗口起点 = 原来的全局句子下标。
      expect(
        c.fileIndexAtForTesting(150 - (150 - kLead)),
        150,
      );
    });

    test('a jump inside the window does not rebuild it', () async {
      _installPlatform();
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);

      c.setAllBookCues(_cues(200));
      await c.load(
        audiobook: _audiobook(),
        audioFiles: _files(200),
        audioSources: _sources(200),
      );
      final Object? before = c.currentCue;

      await c.restoreToFileOffset(fileIndex: 12, positionMs: 0);

      expect(c.sourceWindowStartForTesting, 0);
      expect(c.sourceWindowLengthForTesting, kWindow);
      expect(c.currentCue, before);
    });
  });

  group('rolling the window', () {
    test('no roll while the current sentence is far from the tail', () async {
      _installPlatform();
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);

      await c.load(
        audiobook: _audiobook(),
        audioFiles: _files(200),
        audioSources: _sources(200),
      );

      await c.maybeRollWindowForTesting(5);

      expect(c.sourceWindowStartForTesting, 0);
      expect(c.sourceWindowLengthForTesting, kWindow);
    });

    test('near the tail the window drops played sentences and refills',
        () async {
      _installPlatform();
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);

      await c.load(
        audiobook: _audiobook(),
        audioFiles: _files(200),
        audioSources: _sources(200),
      );

      await c.maybeRollWindowForTesting(25);

      expect(c.sourceWindowStartForTesting, 25 - kLead);
      expect(c.sourceWindowLengthForTesting, kWindow);
      // 滚动后同一句：player 下标变了，全局句子下标不变。
      expect(c.fileIndexAtForTesting(25 - (25 - kLead)), 25);
    });

    test('at the very end the window stops growing', () async {
      _installPlatform();
      final AudiobookPlayerController c = AudiobookPlayerController();
      addTearDown(c.dispose);

      await c.load(
        audiobook: _audiobook(),
        audioFiles: _files(50),
        audioSources: _sources(50),
      );
      await c.maybeRollWindowForTesting(49);

      // 50 句：起点封顶在 50 - 30 = 20，窗口仍是 30，不越界。
      expect(c.sourceWindowStartForTesting, 50 - kWindow);
      expect(c.sourceWindowLengthForTesting, kWindow);
      // 再滚一次也不动（已经在书末）。
      await c.maybeRollWindowForTesting(49);
      expect(c.sourceWindowStartForTesting, 50 - kWindow);
      expect(c.sourceWindowLengthForTesting, kWindow);
    });
  });
}

AudioCue _cue(int fileIndex) => AudioCue()
  ..id = fileIndex
  ..bookKey = 'book'
  ..chapterHref = 'chapter'
  ..sentenceIndex = fileIndex
  ..textFragmentId = 'cue-$fileIndex'
  ..text = 'cue $fileIndex'
  ..startMs = 0
  ..endMs = 1000
  ..audioFileIndex = fileIndex;

List<AudioCue> _cues(int count) =>
    List<AudioCue>.generate(count, _cue, growable: false);

Audiobook _audiobook() => Audiobook()
  ..bookKey = 'book'
  ..audioPaths = const <String>[]
  ..audioRoot = null
  ..alignmentFormat = 'srt'
  ..alignmentPath = '';

List<File> _files(int count) {
  final Directory dir = Directory.systemTemp.createTempSync('window_src_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return List<File>.generate(
    count,
    (int i) {
      final File f = File('${dir.path}${Platform.pathSeparator}$i.mp3');
      f.writeAsBytesSync(const <int>[0]);
      return f;
    },
    growable: false,
  );
}

List<AudioSource> _sources(int count) =>
    List<AudioSource>.generate(count, (int i) => _SentenceSource(i));

/// 与 TtsSentenceAudioSource 同形态（StreamAudioSource，按下标取音频），
/// 但不带真调度器：只用来验证「送进播放器的数量」。
class _SentenceSource extends StreamAudioSource {
  _SentenceSource(this.index) : super(tag: 'tts:$index');

  final int index;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    const List<int> bytes = <int>[0, 1, 2, 3];
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: bytes.length,
      offset: 0,
      stream: Stream<List<int>>.value(bytes),
      contentType: 'audio/mpeg',
    );
  }
}

void _installPlatform() {
  const MethodChannel ch = MethodChannel('com.ryanheise.audio_session');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (_) async => null);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null);
  });
  final JustAudioPlatform prev = JustAudioPlatform.instance;
  JustAudioPlatform.instance = _FakePlatform();
  addTearDown(() => JustAudioPlatform.instance = prev);
}

/// `preload: false` 载入时 just_audio 不会激活平台；这个替身只为挡掉
/// `disposeAllPlayers` 之类的 MethodChannel 调用，不参与断言。
class _FakePlatform extends JustAudioPlatform {
  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async =>
      _FakePlayer(request.id);

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async =>
      DisposePlayerResponse();

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
    DisposeAllPlayersRequest request,
  ) async =>
      DisposeAllPlayersResponse();
}

class _FakePlayer extends AudioPlayerPlatform {
  _FakePlayer(super.id);

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      const Stream<PlaybackEventMessage>.empty();

  @override
  Future<LoadResponse> load(LoadRequest request) async =>
      LoadResponse(duration: const Duration(seconds: 100));

  @override
  Future<SeekResponse> seek(SeekRequest request) async => SeekResponse();

  @override
  Future<PlayResponse> play(PlayRequest request) async => PlayResponse();

  @override
  Future<PauseResponse> pause(PauseRequest request) async => PauseResponse();

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async =>
      DisposeResponse();
}
