/// LLM 翻译：把 app 里已经配好的 AI 提供商（`AiProviderConfig` + `AiChatClient`）
/// 当成翻译引擎用。
///
/// 存在的理由是「同一个 generate 有两条完全不同的诉求」：彩云免配置、随取随用，但
/// 只会做字面对译；LLM 译得准、能给语境义，前提是用户已经在 AI 设置里配过一个可用
/// 提供商。两者并存，由用户在阅读器里选。
library;

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/translation/translation_models.dart';
import 'package:fushi_engine/translation/translator.dart';

/// LLM 引擎单次调用的输出上限。
///
/// 比 `AiChatClient` 默认的 2048 小：翻译的输出量约等于输入量，而队列一次只投喂一个
/// 段落（通例几十到几百字），截到这里既够用，也避免模型跑偏时无谓地生成几千字
/// 拖慢整条队列——队列的服务目标是「尽快把译文填进正在看的这一屏」。
const int kLlmTranslationMaxTokens = 1024;

/// [TranslationEngineId.llm] 的实现。
class LlmTranslator extends Translator {
  LlmTranslator({
    required this.provider,
    AiChatClient? chatClient,
    this.maxTokens = kLlmTranslationMaxTokens,
  }) : _chat = chatClient ?? AiChatClient();

  /// 由调用方从 app 的 AI 设置里解析出来的目标提供商。
  ///
  /// 每次 [translate] 都重新读调用方持有的引用：用户在设置页改了 key / 换提供商之后，
  /// 不需要额外通知翻译层。
  final AiProviderConfig provider;

  final AiChatClient _chat;

  final int maxTokens;

  @override
  TranslationEngineId get id => TranslationEngineId.llm;

  @override
  Future<TranslationResult> translate(
    String text, {
    TranslationTargetLanguage target =
        TranslationTargetLanguage.simplifiedChinese,
  }) async {
    late final String translated;
    try {
      translated = await _chat.complete(
        provider: provider,
        maxTokens: maxTokens,
        messages: <AiChatMessage>[
          AiChatMessage.system(_systemPromptFor(target)),
          AiChatMessage.user(text),
        ],
      );
    } on AiChatFailure catch (failure) {
      // AiChatFailure 与 TranslationFailure 用的是同一套码空间
      // （provider_not_configured / empty_response / network_error / http_5xx），
      // 直接搬运即可：上层的重试判据照旧生效，不会因为这是 LLM 引擎就另写一套。
      throw TranslationFailure(failure.message);
    }
    return TranslationResult(
      sourceText: text,
      translatedText: translated.trim(),
      engineId: id,
      targetLanguage: target,
    );
  }

  /// LLM 的凭据是用户自己配的 API Key，重取没有意义——这里没有可 reset 的东西，
  /// 保留 [Translator.reset] 的默认空实现。

  @override
  Future<void> close() async => _chat.close();
}

/// 固定的翻译系统提示词。
///
/// 「只输出译文」这一句是必需的：附带解释的模型输出会被直接当成译文插进正文中，
/// 用户看到的是一大块比原文还长的乱码。要求保留换行也有理由——译文作为**紧邻的块**
/// 插回原文下面，段落内部结构留存才能让眼睛对得上。
String _systemPromptFor(TranslationTargetLanguage target) =>
    'You are a translation engine. Translate the user\'s text into '
    '${_labelFor(target)}. Output the translation only: no explanation, '
    'no notes, no transliteration, no surrounding quotes. Preserve the '
    'paragraph and line breaks of the original.';

String _labelFor(TranslationTargetLanguage target) => switch (target) {
  TranslationTargetLanguage.simplifiedChinese => 'Simplified Chinese',
  TranslationTargetLanguage.english => 'English',
  TranslationTargetLanguage.japanese => 'Japanese',
};
