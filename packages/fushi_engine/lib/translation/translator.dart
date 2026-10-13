/// 翻译引擎的统一接口。
///
/// 只有「给定原文 + 目标语言，给我译文」这一件事，不含队列、不含缓存、不含 UI
/// 策略——那些属于协调层（app 侧 `reader_translation_coordinator.dart`）。分层理由
/// 与来源实现一致：引擎层可以有 IO，协调层保持无 IO 才好单测。
library;

import 'package:fushi_engine/translation/translation_models.dart';

/// 一个可用的翻译引擎。
abstract class Translator {
  const Translator();

  /// 自己在 [TranslationEngineId] 里的标识，回填结果时要写回 [TranslationResult]。
  TranslationEngineId get id;

  /// 译一段正文。
  ///
  /// [text] 由调用方保证非空：空原文对任何引擎都是一个浪费掉的往返。
  /// [sourceLanguage] 不作为参数——源语言检测交给引擎（见
  /// [TranslationTargetLanguage] 的注释）。
  ///
  /// 失败一律抛 [TranslationFailure]。成功**不允许**返回空或纯空白译文：那对上层
  /// 等于「引擎什么也没给」，当成功返回只会把失败推迟成 UI 上的空白块。
  Future<TranslationResult> translate(
    String text, {
    TranslationTargetLanguage target =
        TranslationTargetLanguage.simplifiedChinese,
  });

  /// 丢弃一次性凭据。
  ///
  /// 网页翻译类引擎的 JWT 是会过期的短命凭据；`401/403` 时先调 [reset] 再重试一次，
  /// 正是来源实现对 `needreinit` 的处理（`FreeWebTranslationCatalog`：先
  /// `translator.reset()` 再 `translator.translate(text)`）。默认空实现给不需要凭据的
  /// 引擎（如 LLM）——那里的凭据就是用户自己配的 API Key，重取没有意义。
  void reset() {}

  /// 释放持有的出站客户端，由 `TranslationClient.close` 在阅读器 dispose 时调一次。
  ///
  /// 默认空实现给「不独占资源」的引擎；持有 `http.Client` 的实现应当覆写它——
  /// 不关的话底层 socket 会一直挂着，多次进出阅读器能攒出一堆空闲连接。出站装配
  /// 本来就收敛在 `app_http.dart` 一处，客户端的生命周期也该有明确归属，不能靠 GC。
  Future<void> close() async {}
}
