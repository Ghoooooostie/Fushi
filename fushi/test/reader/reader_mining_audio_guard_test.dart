import 'package:flutter_test/flutter_test.dart';

import '../pages/reader_fushi_page_source_corpus.dart';
import '../helpers/source_guard.dart';

void main() {
  group('reader mining context guard', () {
    test('passes selection sentenceOffset to Anki sentence renderer', () {
      final String source = readReaderPageSource();

      expect(
        source,
        contains('_cachedSentenceOffset'),
        reason:
            'Reader mining must keep the JS sentenceOffset; normalized book '
            'offsets are not valid character positions inside the sentence.',
      );
      expect(
        source,
        contains('_cachedSentenceOffset = data.sentenceOffset'),
        reason:
            'The value passed to AnkiMiningContext.sentenceOffset must come '
            'from ReaderSelectionData.sentenceOffset.',
      );
      // TODO-644 / BUG-357：sentenceOffset 现在经 await 前快照局部值传入（消除并发
      // 查词在 extractAudioSegment 的 await 处改写 _cachedSentenceOffset 的 race）。
      // 快照仍源自 JS 的 _cachedSentenceOffset，语义不变。
      expect(
        source,
        contains('final int? snapshotSentenceOffset = _cachedSentenceOffset'),
        reason:
            'AnkiMiningContext.sentenceOffset must be snapshotted from the JS '
            '_cachedSentenceOffset BEFORE the extractAudioSegment await, so a '
            'concurrent lookup cannot overwrite it mid-prepare.',
      );
      expect(
        source,
        contains('sentenceOffset: snapshotSentenceOffset'),
        reason:
            'AnkiMiningContext.sentenceOffset is consumed as a sentence-local '
            'character offset; it must read the pre-await snapshot, not the '
            'shared mutable member.',
      );
      expect(
        source,
        isNot(contains('sentenceOffset: _cachedSentenceRange?.offset')),
        reason:
            'Whole-book normalized offsets must not be reused as sentence-local '
            'character offsets.',
      );
    });

    test('uses a unique temporary file for every sentence-audio clip', () {
      final String source = readReaderPageSource();

      expect(
        source,
        contains('createTempSync('),
        reason:
            'Sentence-audio mining should not reuse a fixed temp filename that '
            'a later mining request can overwrite before Anki stores it.',
      );
      expect(
        source,
        isNot(contains("'mine_sentence_audio.aac'")),
        reason: 'Fixed mine_sentence_audio.aac reuses one file for all cards.',
      );
    });

    test('exports complete sentence audio range instead of padding one cue', () {
      final String source = readReaderPageSource();

      expect(
        source,
        contains('final AudioPlaybackRange? clip = miningSentenceAudioRange('),
        reason:
            'Card sentence audio must resolve the selected sentence to a full '
            'audio range, not export only the lookup cue.',
      );
      // TODO-393：句子音频区间解析下沉到参数化 helper _sentenceAudioRangeFor，当前句
      // 经 _currentSentenceAudioRange 把归一化 offset/length 传进去。
      expect(
        source,
        contains('sentenceNormCharOffset: normOffset'),
        reason:
            'The parametrized helper takes the sentence normalized offset; the '
            'current-sentence path feeds the resolved span offset into it.',
      );
      // TODO-1278：offset/length 主锚改走单一真相源 _miningSpanRange()（句级 span 缺失时
      // 回退选区级 span），与收藏 / 制卡历史归一，消除导出误报「跨章」。
      expect(
        source,
        contains('normOffset: span?.offset'),
        reason:
            'The current-sentence audio span now comes from _miningSpanRange() '
            '(sentence range, falling back to the selection range) — the '
            'strongest signal for the full current-sentence audio span.',
      );
      expect(
        source,
        contains('normLength: span?.length'),
        reason:
            'Without sentence length, the reader falls back to a single cue and '
            'can cut off sentences split across multiple cues; the length now '
            'comes from the shared _miningSpanRange() fallback (TODO-1278).',
      );
      expect(
        source,
        isNot(contains('kMiningSentenceAudioTailPaddingMs')),
        reason: 'Fixed tail padding is not a complete-sentence range resolver.',
      );
    });

    test('does not gate sentence audio on a non-null lookup cue (BUG-172)', () {
      final String source = readReaderPageSource();

      // Audiobook cue alignment leaves gaps: a word can fall in covered-but-
      // uncued text so _lookupCue is null while the sentence is still spanned by
      // surrounding cues. The mining gate must not require a cue; it must try the
      // sentence-span range whenever audio files exist.
      expect(
        source,
        isNot(contains('if (cue != null && audioFiles != null) {')),
        reason:
            'Gating sentence audio on `cue != null` silently drops sentence '
            'audio for gap words; resolve by sentence span instead.',
      );
      // The only extra condition allowed besides "audio files exist" is the
      // user's explicit per-card "no audio" choice from advanced mining
      // (MiningRequestOverrides.omitAudio) — never the lookup cue.
      expect(
        source,
        contains(
          'if (audioFiles != null && !(overrides?.omitAudio ?? false)) {',
        ),
        reason:
            'Sentence-audio mining should attempt a clip whenever audio files '
            'exist (unless the user opted out for this card) and let '
            'miningSentenceAudioRange decide if a range is found.',
      );
      expect(
        source,
        contains('if (clip != null &&'),
        reason:
            'miningSentenceAudioRange is now nullable; the reader must null-check '
            'the clip before extracting a segment.',
      );
    });

    test('makes the TTS sentence audio really exist before cutting it', () {
      final String source = readReaderPageSource();

      // 朗读会话的 audioFiles[i] 是「合成后才会存在」的缓存路径，制卡必须先让它就绪。
      expect(
        source,
        contains(
          'Future<({String path, int? durationMs})?> _resolveSentenceAudioInput(',
        ),
        reason:
            '制卡取句子音频输入必须过一个「先确保存在」的解析步骤（BUG: '
            'sentence audio export failed: input audio file does not exist）。',
      );
      expect(
        source,
        contains('await readAlong.ensureSentenceAudio(index)'),
        reason: 'TTS 朗读会话里必须按需合成那一句，再拿真实路径去裁。',
      );
      // 只钉制卡这一块（有声书片段导出 audioFiles 用法在 audiobook.part.dart，
      // 与本条无关，不能让它的 `inputPath: inputFile.path` 干扰这里的负向断言）。
      final int cutIndex = source.indexOf(
        'final File inputFile = audioFiles[clip.audioFileIndex]',
      );
      final int branchIndex = source.indexOf(
        '} else if (cue == null) {',
        cutIndex,
      );
      expect(cutIndex, greaterThanOrEqualTo(0));
      expect(branchIndex, greaterThan(cutIndex));
      final String cutBlock = source.substring(cutIndex, branchIndex);
      expect(
        cutBlock,
        contains('inputPath: ready.path'),
        reason: 'ffmpeg 的输入必须是就绪后的真实路径，不能是拼出来的「将来路径」。',
      );
      expect(
        cutBlock,
        isNot(contains('inputPath: inputFile.path')),
        reason: '直接把 audioFiles[i] 喂 ffmpeg 会在未合成句上早退并把整张卡判死。',
      );
      expect(
        source,
        contains('ReaderFushi.mineEntry.sentenceAudioUnavailable'),
        reason: '拿不到句子音频时要留下可查的日志，而不是静默丢音频。',
      );
    });

    test('locates the TTS sentence audio by body text, not by drifting '
        'coordinates', () {
      final String source = readReaderPageSource();

      // 真机实测：阅读器坐标与朗读分句归一化不同源，坐标区间完全重合却是另一句
      // （card「こんな土地に…」→ 单元「ルイジェルドは…」）。定位必须落到正文文本上。
      expect(
        source,
        contains('readAlong.sentenceRangeByText('),
        reason: 'TTS 会话里必须按正文文本定位句子音频，坐标只用来给重复句消歧。',
      );
      expect(
        source,
        contains('readAlong.unitCoversSentence('),
        reason: '文本也定位不到时必须校验坐标结果，不能拿一个念别的句子的单元凑数。',
      );
      expect(
        source,
        contains('sentenceAudioUntrusted'),
        reason: '确认不可信后必须走「不带音频出卡」的降级，而不是照裁。',
      );
      expect(
        source,
        contains('ReaderFushi.mineEntry.sentenceAudioMismatch'),
        reason: '被拒绝的错配要落日志，可查为什么这张卡没有句子音频。',
      );
    });

    test('aborts mining when requested sentence-audio export fails', () {
      final String source = readReaderPageSource();

      expect(
        source,
        contains('bool requestedSentenceAudioClip = false'),
        reason:
            'The reader must remember that a real sentence-audio clip was '
            'requested; otherwise ffmpeg failures become silent no-audio cards.',
      );
      expect(
        source,
        contains('requestedSentenceAudioClip = true'),
        reason:
            'The failure guard should only fire after a clip range and output '
            'path were actually chosen.',
      );
      expect(
        source,
        contains(
          'if (requestedSentenceAudioClip && sentenceAudioPath == null)',
        ),
        reason:
            'A requested but failed sentence-audio export must stop card mining '
            'with a visible error instead of continuing as a success.',
      );
      expect(
        source,
        contains('card_export_failed_detail'),
        reason: 'The stopped path must be user-visible, not just logged.',
      );
      expect(
        source,
        contains('String? sentenceAudioFailure'),
        reason:
            'The reader must preserve the ffmpeg failure summary for the '
            'visible no-audio-card guard.',
      );
      expect(
        source,
        contains('onFailure: (String summary)'),
        reason:
            'TtsChannel/extractor diagnostics should flow back to the '
            'reader mining path.',
      );
      expect(
        source,
        contains(r'sentence audio export failed: $sentenceAudioFailure'),
        reason:
            'The visible error should include executable/fallback/0xC000007B '
            'details instead of a generic no-audio message.',
      );

      final int guardIndex = source.indexOf(
        'if (requestedSentenceAudioClip && sentenceAudioPath == null)',
      );
      // 回看会话（BUG-2503）走 review.mine，普通路径仍是 repo.mineEntry；两条腿在
      // 同一个三元里，锚 `outcome = review == null` 那一行。
      final int mineIndex = source.indexOf('outcome = review == null');
      expect(guardIndex, greaterThanOrEqualTo(0));
      expect(mineIndex, greaterThan(guardIndex));
    });

    // TODO-811: when audio files exist but no sentence-audio range resolves
    // (gap word, no lookup cue, text fallback also empty) the card is still made
    // but WITHOUT sentence audio. That used to be a debugPrint-only silent drop -
    // the exact symptom users reported for local audiobooks. The card must now
    // tell the user no sentence audio was attached instead of silently dropping.
    test('surfaces a toast when no sentence-audio range resolves (TODO-811)', () {
      final String source = readReaderPageSource();

      expect(
        compactCode(source),
        contains(
          compactCode(
            'FushiToast.show(msg: t.card_mined_without_sentence_audio,',
          ),
        ),
        reason:
            'A card created with audio files present but no resolvable sentence '
            'range must visibly tell the user no sentence audio was attached, '
            'not silently produce an audio-less card.',
      );
      final int branchIndex = source.indexOf('} else if (cue == null) {');
      // 从该分支之后开始找：句子音频「不可用」的降级提示（BUG-3652）在这条分支之前，
      // 从全串首个匹配算会把那次提示当成这里的证据。
      final int toastIndex = source.indexOf(
        't.card_mined_without_sentence_audio',
        branchIndex,
      );
      expect(branchIndex, greaterThanOrEqualTo(0));
      expect(
        toastIndex,
        greaterThan(branchIndex),
        reason: 'The toast must live inside the no-range gap branch.',
      );
    });
  });
}
