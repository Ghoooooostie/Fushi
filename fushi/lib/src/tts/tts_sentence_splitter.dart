import 'package:fushi/src/lookup/sentence_extraction.dart';

/// 切分结果：原文中的一句及其在章节纯文本中的 [normCharStart, normCharEnd)。
class TtsSentence {
  const TtsSentence({
    required this.text,
    required this.normCharStart,
    required this.normCharEnd,
  });

  final String text;
  final int normCharStart;
  final int normCharEnd;
}

/// 把章节纯文本切成句子列表，偏移与 [EpubBook.chapterPlainText] 对齐。
///
/// 分隔符表与阅读器 / [extractSentenceAt] 保持一致，避免高亮坐标错位。
/// 切分策略：以 [kSentenceDelimiters] 为句尾，并把紧随其后的 [kTrailingSentenceChars]
/// 并入本句；跳过纯空白片段。
List<TtsSentence> splitChapterIntoSentences(String plainText) {
  final List<TtsSentence> sentences = <TtsSentence>[];
  if (plainText.isEmpty) return sentences;

  int sentenceStart = 0;
  for (int i = 0; i < plainText.length; i++) {
    final String ch = plainText[i];
    if (!kSentenceDelimiters.contains(ch)) continue;

    int sentenceEnd = i + 1;
    while (sentenceEnd < plainText.length &&
        kTrailingSentenceChars.contains(plainText[sentenceEnd])) {
      sentenceEnd++;
    }

    final String raw = plainText.substring(sentenceStart, sentenceEnd);
    final String trimmed = raw.trim();
    if (trimmed.isNotEmpty) {
      // 偏移以 trimmed 文本在 plainText 中的真实位置为准。
      final int leading = raw.length - raw.trimLeft().length;
      sentences.add(
        TtsSentence(
          text: trimmed,
          normCharStart: sentenceStart + leading,
          normCharEnd: sentenceStart + leading + trimmed.length,
        ),
      );
    }
    sentenceStart = sentenceEnd;
  }

  // 末尾没有句尾标点的残留文本也作为一句。
  if (sentenceStart < plainText.length) {
    final String raw = plainText.substring(sentenceStart);
    final String trimmed = raw.trim();
    if (trimmed.isNotEmpty) {
      final int leading = raw.length - raw.trimLeft().length;
      sentences.add(
        TtsSentence(
          text: trimmed,
          normCharStart: sentenceStart + leading,
          normCharEnd: sentenceStart + leading + trimmed.length,
        ),
      );
    }
  }

  return sentences;
}
