import 'package:fushi/src/tts/tts_models.dart';

/// 内置 TTS 引擎抽象。
///
/// 所有引擎都是「纯 Dart + HTTP/WebSocket」，不依赖原生通道，因此五端可用（含
/// Linux）。调用方通过 [id] 区分引擎，通过 [displayName] 展示给用户。
abstract class TtsEngine {
  String get id;
  String get displayName;

  /// 是否允许调节语速。
  bool get supportsSpeed => true;

  /// 是否允许调节音高。
  bool get supportsPitch => false;

  /// 语速可调范围（倍率）。UI 滑杆用。
  double get minSpeed => 0.5;
  double get maxSpeed => 2.0;

  /// 默认语速。
  double get defaultSpeed => 1.0;

  /// 枚举该引擎当前可用的音色。
  ///
  /// 在线引擎走网络请求；离线/系统引擎可同步返回。失败时返回空列表，调用方
  /// 降级到默认音色。
  Future<List<TtsVoice>> getVoices();

  /// 把 [text] 合成为音频。
  ///
  /// [text] 已经过调用方预处理（通常是一句，不超过各引擎单条长度限制）。
  /// 失败时抛异常；调用方负责 catch 并降级或提示。
  Future<TtsResult> synthesize(String text, TtsParam param);
}
