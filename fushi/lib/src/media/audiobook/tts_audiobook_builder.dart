import 'dart:async';
import 'dart:io';

import 'package:fushi/src/tts/tts_audio_concat.dart';
import 'package:fushi/src/tts/tts_engine.dart';
import 'package:fushi/src/tts/tts_models.dart';
import 'package:fushi/src/tts/tts_sentence_splitter.dart';
import 'package:fushi/src/tts/tts_synthesizer.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/audiobook_session_launcher.dart';

/// 用内置 TTS 引擎把 EPUB 单章合成为「有声书会话启动材料」。
///
/// 流程：
/// 1. 取章节纯文本并按阅读器口径分句；
/// 2. 并行合成每句音频（带缓存）；
/// 3. ffmpeg 把所有单句 MP3 拼成一章音频；
/// 4. 按拼接后各句时长构造 [AudioCue]；
/// 5. 返回可直接喂给 [AudiobookSession.start] 的 [AudiobookSessionStartRequest]。
///
/// TODO：当前版本会合成整章后再启动；后续可按「预加载句数」先启动前 N 句、后台
/// 续合剩余句子并热更新 cue 列表。
class TtsAudiobookBuilder {
  TtsAudiobookBuilder({
    required this.bookKey,
    required this.chapterIndex,
    required this.epubBook,
    required this.engine,
    required this.param,
    this.title,
    this.author,
    this.coverPath,
  });

  final String bookKey;
  final int chapterIndex;
  final EpubBook epubBook;
  final TtsEngine engine;
  final TtsParam param;
  final String? title;
  final String? author;
  final String? coverPath;

  final TtsSynthesizer _synthesizer = TtsSynthesizer();

  /// 合成的唯一身份，用于缓存目录与位置键。
  String get _sessionKey {
    final String chapterHref = epubBook.chapters[chapterIndex].href;
    String safe(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9_.\-]'), '_');
    return 'tts_${safe(engine.id)}_${safe(param.voice.id)}_${param.speed}_'
        '${safe(bookKey)}_${safe(chapterHref)}';
  }

  /// 构建启动材料。失败时返回 null 并已记录日志。
  Future<AudiobookSessionStartRequest?> build({
    void Function(int completed, int total)? onProgress,
  }) async {
    final String plainText = epubBook.chapterPlainText(chapterIndex);
    if (plainText.trim().isEmpty) return null;

    final List<TtsSentence> sentences = splitChapterIntoSentences(plainText);
    if (sentences.isEmpty) return null;

    try {
      onProgress?.call(0, sentences.length);
      final List<String> texts = sentences
          .map((TtsSentence s) => s.text)
          .toList();
      final List<File> audioFiles = await _synthesizer.synthesizeBatch(
        texts,
        engine,
        param,
        onProgress: onProgress,
      );

      final Directory cache = await _sessionCacheDir();
      final String concatPath = path.join(cache.path, 'chapter.mp3');
      final String? outputPath = await concatenateMp3Files(
        audioFiles.map((File f) => f.path).toList(),
        concatPath,
      );
      if (outputPath == null) return null;

      final List<AudioCue> cues = await _buildCues(
        sentences: sentences,
        sentenceFiles: audioFiles,
      );

      return _buildRequest(File(outputPath), cues);
    } catch (e, stack) {
      ErrorLogService.instance.log('TtsAudiobookBuilder.build', e, stack);
      return null;
    }
  }

  Future<Directory> _sessionCacheDir() async {
    final Directory appDir = await getApplicationSupportDirectory();
    final Directory dir = Directory(
      path.join(appDir.path, 'tts_session', _sessionKey),
    );
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<List<AudioCue>> _buildCues({
    required List<TtsSentence> sentences,
    required List<File> sentenceFiles,
  }) async {
    final List<int> durationsMs = await Future.wait(
      sentenceFiles.map((File f) async {
        return await probeAudioDurationMs(f.path) ?? 3000;
      }),
    );

    final List<AudioCue> cues = <AudioCue>[];
    int currentMs = 0;
    final String chapterHref = epubBook.chapters[chapterIndex].href;
    for (int i = 0; i < sentences.length; i++) {
      final TtsSentence sentence = sentences[i];
      final int durationMs = durationsMs[i];
      final AudioCue cue = AudioCue()
        ..bookKey = bookKey
        ..chapterHref = chapterHref
        ..sentenceIndex = i
        ..textFragmentId = SubtitleRematchCodec.encodeHit(
          sectionIndex: chapterIndex,
          normCharStart: sentence.normCharStart,
          normCharEnd: sentence.normCharEnd,
        )
        ..text = sentence.text
        ..startMs = currentMs
        ..endMs = currentMs + durationMs
        ..audioFileIndex = 0;
      cues.add(cue);
      currentMs += durationMs;
    }
    return cues;
  }

  AudiobookSessionStartRequest _buildRequest(
    File audioFile,
    List<AudioCue> cues,
  ) {
    final Audiobook syntheticAudiobook = Audiobook()
      ..bookKey = bookKey
      ..audioPaths = <String>[audioFile.path]
      ..alignmentFormat = 'json'
      ..alignmentPath = '';

    return AudiobookSessionStartRequest(
      info: SessionBookInfo(
        bookKey: bookKey,
        audiobook: syntheticAudiobook,
        title: title ?? epubBook.title,
        mediaIdentifier: 'fushi://book/$bookKey/tts/$chapterIndex',
        isSrtBookSource: false,
        author: author,
        coverPath: coverPath,
        statsMediaKey: bookKey,
      ),
      audioFiles: <File>[audioFile],
      prefs: const SessionPrefs(
        followAudio: true,
        delayMs: 0,
        speed: 1.0,
        positionMs: 0,
        imagePauseSec: 0,
        volume: 1.0,
      ),
      persist: SessionPersistCallbacks(
        onPositionWrite: (_, __) async {},
        onDelayPersist: (_) async {},
        onSpeedPersist: (_) async {},
        onVolumePersist: (_) async {},
        onImagePausePersist: (_) async {},
        onFollowAudioPersist: (_) async {},
      ),
      cues: cues,
    );
  }
}
