import 'dart:typed_data';

/// 内置 TTS 引擎的一句话参数（语速 / 音高 / 音色）。
///
/// [speed] 是倍率：0.5 = 半速，1.0 = 原速，2.0 = 倍速。各引擎内部再转成各自协议
/// 的速率单位（Edge 的 SSML `rate`、火山 REST 的字段等）。
class TtsParam {
  const TtsParam({required this.voice, this.speed = 1.0, this.pitch = 0.0});

  final TtsVoice voice;
  final double speed;
  final double pitch;

  TtsParam copyWith({TtsVoice? voice, double? speed, double? pitch}) {
    return TtsParam(
      voice: voice ?? this.voice,
      speed: speed ?? this.speed,
      pitch: pitch ?? this.pitch,
    );
  }
}

/// 一个可用音色。
class TtsVoice {
  const TtsVoice({
    required this.id,
    required this.displayName,
    this.locale,
    this.gender,
    this.engineId,
  });

  final String id;
  final String displayName;

  /// 语言标签，如 `ja-JP`、`zh-CN`、`en-US`。
  final String? locale;

  /// 性别提示（Male/Female/Neutral）。
  final String? gender;

  /// 该音色所属的引擎 id，避免调用方串引擎。
  final String? engineId;
}

/// TTS 合成结果。
class TtsResult {
  const TtsResult({
    required this.audioBytes,
    required this.mimeType,
    this.suggestedExtension,
  });

  final Uint8List audioBytes;

  /// 如 `audio/mpeg`、`audio/wav`。
  final String mimeType;

  /// 建议文件扩展名（不带点），如 `mp3`、`wav`。
  final String? suggestedExtension;
}
