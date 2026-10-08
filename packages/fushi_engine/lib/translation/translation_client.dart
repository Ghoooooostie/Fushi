/// 翻译的统一入口：按 [TranslationEngineId] 路由到具体引擎，并负责**重试策略**。
///
/// 引擎本身只管「发一次请求」，重试集中在这里，理由和来源实现一致：是否值得重来
/// 一次取决于**失败的性质**（凭据过期 vs 服务端报错 vs 请求本身有问题），而这段判断
/// 对任何引擎都一样，散到各引擎里就会长出 14 份各写一半的版本。
library;

import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/translation/caiyun_web_translator.dart';
import 'package:fushi_engine/translation/llm_translator.dart';
import 'package:fushi_engine/translation/translation_models.dart';
import 'package:fushi_engine/translation/translator.dart';
import 'package:http/http.dart' as http;

/// 面向 UI / 队列的翻译总入口。
class TranslationClient {
  TranslationClient({required Map<TranslationEngineId, Translator> translators})
    : _translators = Map<TranslationEngineId, Translator>.unmodifiable(
        translators,
      );

  /// 常规装配：彩云（免 key，总是可用）+ LLM（仅在 [llmProvider] 已配好时有意义）。
  ///
  /// [caiyunClient] 是测试注入点，走 `package:http/testing.dart` 的 MockClient。
  factory TranslationClient.standard({
    AiProviderConfig? llmProvider,
    http.Client? caiyunClient,
  }) {
    return TranslationClient(
      translators: <TranslationEngineId, Translator>{
        TranslationEngineId.caiyun: CaiyunWebTranslator(client: caiyunClient),
        if (llmProvider != null)
          TranslationEngineId.llm: LlmTranslator(provider: llmProvider),
      },
    );
  }

  final Map<TranslationEngineId, Translator> _translators;

  bool supports(TranslationEngineId id) => _translators.containsKey(id);

  /// 译一段正文，失败抛 [TranslationFailure]。
  Future<TranslationResult> translate(
    TranslationEngineId engineId,
    String text, {
    TranslationTargetLanguage target =
        TranslationTargetLanguage.simplifiedChinese,
  }) async {
    final Translator? translator = _translators[engineId];
    if (translator == null) {
      // 典型场合：用户选了 LLM，但 AI 设置里没有一个可用提供商。这属于配置问题，
      // 重试一万次也一样，所以不当成重试able。
      throw const TranslationFailure('engine_not_configured');
    }
    // 空原文直接挡住：它只会浪费一次往返，而且回填侧拿空原文也无从校验。
    if (text.trim().isEmpty) {
      throw const TranslationFailure('empty_response');
    }

    try {
      return await translator.translate(text, target: target);
    } on TranslationFailure catch (failure) {
      if (!_shouldRetry(failure)) rethrow;
      translator.reset();
      // 第二次就不兜了：再失败说明这不是「抖一下」，而是真正的错误，让它原样抛给
      // UI 显示。只重试一层已经足够吃掉「JWT 恰好在这一刻过期」这类瞬态问题，
      // 盖两层只会把真正的错误藏起来。
      return translator.translate(text, target: target);
    }
  }

  /// 释放各引擎持有的出站客户端，在阅读器 dispose 时调一次。
  Future<void> close() async {
    for (final Translator translator in _translators.values) {
      await translator.close();
    }
  }
}

/// 这一次失败值不值得「原样再来一次」。
///
/// 只重试**有可能成功**的失败，是与「信息 email:重试」的根本区别：
///   - `401/403`：网页翻译的 JWT 过期——[Translator.reset] 掉凭据重取，路径就通了；
///   - `network_error` / `rate_limited` / `http_5xx`：抖一下再来一次常常就好了；
///   - 其余（`400/404`、`empty_response`、`bad_response`）：说明请求本身或服务端契约
///     有问题，重发同样的请求会得到同样的结果。
bool _shouldRetry(TranslationFailure failure) {
  final String message = failure.message;
  return message == 'http_401' || message == 'http_403' || failure.isRetryable;
}
