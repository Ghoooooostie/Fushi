/// 阅读器在线翻译的通用模型：目标语言、引擎标识、结果与失败。
///
/// 本层是纯 Dart（`fushi_engine` 禁止 import `package:flutter`，有 purity guard），
/// 所以这里用不了 `@immutable` 标注——不变性靠「`const` 构造 + 字段全 `final`」表达，
/// 与同包 `ai/ai_chat_client.dart` 的 `AiChatMessage` 同手法。
library;

/// 译文的目标语言。
///
/// **源语言一律交给引擎自动检测**（彩云 `trans_type` 的前半段恒为 `auto`）。理由：
/// 手指定源语言在阅读器里没有可靠来源——日文书里夹带的英文标题、注释性汉字词、
/// 引文都可能共振，而自动检测正是各家引擎针对「整段正文」的默认路径。
enum TranslationTargetLanguage {
  simplifiedChinese('zh'),
  english('en'),
  japanese('ja');

  const TranslationTargetLanguage(this.storageValue);

  /// 落库用的稳定字符串。
  ///
  /// 与 `VideoFitMode.storageValue`（app 侧 `preferences_repository.dart`）同范式：
  /// **键永不随枚举改名漂移**——已经写进用户 SQLite 的值，在枚举项改名之后仍要能被
  /// 认回来。所以这里存的是字符串常量，不是 `name`、也不是枚举序号。
  final String storageValue;

  /// 认不出的值一律回 [simplifiedChinese]（本功能的既定默认值）。
  static TranslationTargetLanguage fromStorage(String? value) {
    for (final TranslationTargetLanguage item in values) {
      if (item.storageValue == value) return item;
    }
    return simplifiedChinese;
  }
}

/// 翻译引擎标识。
///
/// 新增一个引擎要做三件事（与 `AiFeatureAssignments` 的意图一致：让「加引擎」这件
/// 事必须同时面对路由、UI 与持久化三处，不会漏一处）：
///   1. 在这里加枚举项 + [storageValue]；
///   2. 在 `translation_client.dart` 的路由表补一个 case；
///   3. app 侧设置 UI 加选项（见 `ReaderSettings` 的翻译段）。
enum TranslationEngineId {
  /// 彩云小译网页版：免 key、免 Gauss signature、用户零配置即可用。
  caiyun('caiyun'),

  /// 复用 app 现有 AI 提供商设置的 LLM 翻译（`AiChatClient`）。质量最好，但需要
  /// 用户已经在 AI 设置里配过至少一个可用提供商。
  llm('llm');

  const TranslationEngineId(this.storageValue);

  /// 落库键，语义同 [TranslationTargetLanguage.storageValue]。
  final String storageValue;

  /// 认不出一律回 [caiyun]：它是唯一**零配置可用**的引擎，回落到这里不会把
  /// 用户卡在「翻译点了没反应」。
  static TranslationEngineId fromStorage(String? value) {
    for (final TranslationEngineId item in values) {
      if (item.storageValue == value) return item;
    }
    return caiyun;
  }
}

/// 一次翻译的成果。
class TranslationResult {
  const TranslationResult({
    required this.sourceText,
    required this.translatedText,
    required this.engineId,
    required this.targetLanguage,
  });

  /// 原文。回传是为了让回填侧能对着 JS 传来的 targetId 二次校验，避免队列并发时
  /// 「译文落到另一段原文上」（换行、换章的那一瞬间最容易发生）。
  final String sourceText;

  /// 译文。空串不算成功——空串对回填侧就是「一段空白块」，只会把失败推迟成
  /// UI 上的怪现象，所以在调用层就判死。
  final String translatedText;

  final TranslationEngineId engineId;

  final TranslationTargetLanguage targetLanguage;

  @override
  String toString() =>
      'TranslationResult(${engineId.storageValue} -> ${targetLanguage.storageValue})';
}

/// 翻译失败。[message] 是**已脱敏**的短文案，可以直接进 UI——绝不含 token、
/// 完整 URL 或响应体原文（后两者都可能回显凭据）。
class TranslationFailure implements Exception {
  const TranslationFailure(this.message);

  final String message;

  /// 重试有可能成功的失败：网络抖动、限流、服务端 5xx。
  ///
  /// 401/403（凭据失效）**不在**这个集合里——它由 [Translator.reset] 专门处理：
  /// 弃掉缓存的 JWT 重取一次，而不是盲目重试同一个必失败的请求。
  ///
  /// `http_429`（Too Many Requests）**必须在集合里**：网页翻译端点（彩云）的实际
  /// 限流响应就是它，而 `_decodeBody` 抛的是拼接出来的 `http_429` 而不是字面量
  /// `rate_limited`。漏了这一条意味着「限流一次 = 这段直接失败」，集中出现在读到
  /// 十几段之后 —— 症状正是「翻译到一半就停了」（BUG-3369）。
  bool get isRetryable =>
      message == 'network_error' ||
      message == 'rate_limited' ||
      message == 'http_429' ||
      message == 'http_408' ||
      message == 'http_425' ||
      message.startsWith('http_5');

  @override
  String toString() => 'TranslationFailure: $message';
}
