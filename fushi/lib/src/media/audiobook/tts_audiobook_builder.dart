import 'dart:async';
import 'dart:io';

import 'package:fushi/src/tts/tts_audio_concat.dart';
import 'package:fushi/src/tts/tts_engine.dart';
import 'package:fushi/src/tts/tts_models.dart';
import 'package:fushi/src/tts/tts_sentence_splitter.dart';
import 'package:fushi/src/tts/tts_synthesizer.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_book.dart';

import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/audiobook_session_launcher.dart';

/// TTS 实时朗读的一批合成结果。
///
/// [isFirst] = true 的批次用于启动会话（立即播放），其余批次在后台合成完成后
/// 通过 [AudiobookPlayerController.appendAudioSources] 追加到正在播放的会话。
class TtsSynthesisBatch {
  const TtsSynthesisBatch({
    required this.files,
    required this.cues,
    required this.isFirst,
  });

  final List<File> files;
  final List<AudioCue> cues;
  final bool isFirst;
}

/// 用内置 TTS 引擎把 EPUB 单章实时合成为「有声书会话」。
///
/// 与一次性合成整章不同，本构建器走**流式**路线：
/// 1. 取章节纯文本并按阅读器口径分句（瞬时）；
/// 2. 先合成前 [initialBatchSize] 句并立即产出，供调用方启动会话、立刻开播；
/// 3. 后台逐批合成剩余句子并产出，调用方追加到正在播放的会话。
///
/// 每句独立为一个音频文件，cue 采用「文件内坐标」（`startMs=0`、`endMs=句时长`、
/// `audioFileIndex` = 全局句序），直接匹配 [AudiobookPlayerController] 的多文件
/// cue 体系，从而复用现有的上一句/下一句/同步高亮/进度条。
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

  /// 分句（瞬时，无网络/IO）。
  Future<List<TtsSentence>> split() async {
    final String plainText = epubBook.chapterPlainText(chapterIndex);
    if (plainText.trim().isEmpty) return const <TtsSentence>[];
    return splitChapterIntoSentences(plainText);
  }

  /// 合成 [sentences] 的 [start]..[end) 区间为一句一文件，并构造对应 cue。
  /// [fileBase] 是该批第一句在全书中的音频文件下标（TTS 场景即全局句序）。
  Future<(List<File>, List<AudioCue>)> synthesizeRange(
    List<TtsSentence> sentences,
    int start,
    int end,
    int fileBase,
  ) async {
    final int count = end - start;
    if (count <= 0) return (const <File>[], const <AudioCue>[]);
    final List<String> texts =
        sentences.sublist(start, end).map((TtsSentence s) => s.text).toList();
    final List<File> files = await _synthesizer.synthesizeBatch(texts, engine, param);

    final List<int> durationsMs = await Future.wait<int>(
      files.map((File f) async {
        final int? d = await probeAudioDurationMs(f.path);
        return d ?? 3000;
      }),
    );

    final String chapterHref = epubBook.chapters[chapterIndex].href;
    final List<AudioCue> cues = <AudioCue>[];
    for (int k = 0; k < count; k++) {
      final int i = start + k;
      final TtsSentence sentence = sentences[i];
      final int durationMs = durationsMs[k];
      final AudioCue cue = AudioCue()
        ..bookKey = bookKey
        ..chapterHref = chapterHref
        ..sentenceIndex = i
        ..id = i
        ..textFragmentId = SubtitleRematchCodec.encodeHit(
          sectionIndex: chapterIndex,
          normCharStart: sentence.normCharStart,
          normCharEnd: sentence.normCharEnd,
        )
        ..text = sentence.text
        ..startMs = 0
        ..endMs = durationMs
        ..audioFileIndex = fileBase + k;
      cues.add(cue);
    }
    return (files, cues);
  }

  /// 流式合成：先产出首批（可立即播放），随后逐批产出供追加。
  ///
  /// [startSentenceIndex] 为起始句下标（章节内全局句序）；手势「从当前句开始朗读」
  /// 时传入被点句的索引，否则从 0（章首）开始。[audioFileIndex] 始终从 0 起在本
  /// 会话内连续编号（只合成 start 之后的句）。
  ///
  /// [onProgress] 的 `completed` 是已合成句数（含首批），`total` 是总句数。
  Stream<TtsSynthesisBatch> synthesize({
    int startSentenceIndex = 0,
    int initialBatchSize = 3,
    int batchSize = 8,
    void Function(int completed, int total)? onProgress,
  }) async* {
    final List<TtsSentence> sentences = await split();
    if (sentences.isEmpty) return;
    final int total = sentences.length;
    if (startSentenceIndex >= total) return;
    onProgress?.call(startSentenceIndex, total);

    int cursor = startSentenceIndex;
    int fileBase = 0;
    final int firstEnd = (cursor + initialBatchSize).clamp(0, total);
    if (firstEnd <= cursor) return;
    final (List<File> firstFiles, List<AudioCue> firstCues) =
        await synthesizeRange(sentences, cursor, firstEnd, fileBase);
    fileBase = firstEnd - cursor;
    onProgress?.call(firstEnd, total);
    yield TtsSynthesisBatch(
      files: firstFiles,
      cues: firstCues,
      isFirst: true,
    );

    cursor = firstEnd;
    while (cursor < total) {
      final int end = (cursor + batchSize).clamp(0, total);
      final (List<File> files, List<AudioCue> cues) =
          await synthesizeRange(sentences, cursor, end, fileBase);
      fileBase += end - cursor;
      onProgress?.call(end, total);
      yield TtsSynthesisBatch(files: files, cues: cues, isFirst: false);
      cursor = end;
    }
  }

  /// 由一批合成结果构造可直接喂给 [AudiobookSession.start] 的启动请求。
  AudiobookSessionStartRequest buildRequest(
    List<File> files,
    List<AudioCue> cues,
  ) {
    final Audiobook syntheticAudiobook = Audiobook()
      ..bookKey = bookKey
      ..audioPaths = files.map((File f) => f.path).toList()
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
      audioFiles: files,
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
