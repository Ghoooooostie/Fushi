import 'package:fushi/src/tts/edge_tts_engine.dart';
import 'package:fushi/src/tts/tts_engine.dart';
import 'package:fushi/src/tts/tts_models.dart';
import 'package:fushi/src/tts/volcano_tts_engine.dart';

/// 内置 TTS 引擎的统一入口。
///
/// 调用方通过 [engines] 拿到全部可用引擎，通过 [resolve] 按 id 取引擎实例。
/// 所有引擎都是无状态对象，可自由构造；音色列表需要网络时由调用方异步获取。
class TtsEngineRegistry {
  TtsEngineRegistry._();

  static final TtsEngineRegistry instance = TtsEngineRegistry._();

  final List<TtsEngine> engines = <TtsEngine>[
    EdgeTtsEngine(),
    VolcanoTtsEngine(),
  ];

  TtsEngine? resolve(String? engineId) {
    if (engineId == null || engineId.isEmpty) return engines.first;
    for (final TtsEngine engine in engines) {
      if (engine.id == engineId) return engine;
    }
    return engines.first;
  }

  /// 找一个与 [engineId] 同引擎的默认音色；若保存的音色 id 已不在列表，回退到
  /// 该引擎第一个可用音色。
  Future<TtsVoice> resolveVoice({
    required String engineId,
    required String? voiceId,
  }) async {
    final TtsEngine? engine = resolve(engineId);
    if (engine == null) {
      return const TtsVoice(id: '', displayName: 'Default');
    }
    final List<TtsVoice> voices = await engine.getVoices();
    if (voices.isEmpty) {
      return TtsVoice(id: '', displayName: 'Default', engineId: engine.id);
    }
    if (voiceId != null && voiceId.isNotEmpty) {
      for (final TtsVoice voice in voices) {
        if (voice.id == voiceId) return voice;
      }
    }
    return voices.first;
  }
}
