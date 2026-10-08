import 'package:flutter/material.dart';
import 'package:fushi/src/tts/tts_engine.dart';
import 'package:fushi/src/tts/tts_engine_registry.dart';
import 'package:fushi/src/tts/tts_models.dart';
import 'package:fushi/utils.dart';

/// TTS 引擎 / 音色 / 语速 / 预加载句数 设置弹窗。
///
/// 返回 [TtsSettingsResult] 表示确认；返回 null 表示取消。
class TtsSettingsDialog extends StatefulWidget {
  const TtsSettingsDialog({
    super.key,
    required this.engineId,
    required this.voiceId,
    required this.speed,
    required this.pitch,
    required this.preloadSentences,
  });

  final String engineId;
  final String voiceId;
  final double speed;
  final double pitch;
  final int preloadSentences;

  @override
  State<TtsSettingsDialog> createState() => _TtsSettingsDialogState();
}

class _TtsSettingsDialogState extends State<TtsSettingsDialog> {
  late TtsEngine _engine;
  List<TtsVoice> _voices = <TtsVoice>[];
  late String _voiceId;
  late double _speed;
  late double _pitch;
  late int _preloadSentences;
  bool _loadingVoices = true;
  String? _voiceLoadError;

  @override
  void initState() {
    super.initState();
    _engine = TtsEngineRegistry.instance.resolve(widget.engineId)!;
    _voiceId = widget.voiceId;
    _speed = widget.speed;
    _pitch = widget.pitch;
    _preloadSentences = widget.preloadSentences;
    _loadVoices();
  }

  Future<void> _loadVoices() async {
    setState(() {
      _loadingVoices = true;
      _voiceLoadError = null;
    });
    try {
      final List<TtsVoice> voices = await _engine.getVoices();
      if (!mounted) return;
      setState(() {
        _voices = voices;
        _loadingVoices = false;
        if (voices.isNotEmpty &&
            !voices.any((TtsVoice v) => v.id == _voiceId)) {
          _voiceId = voices.first.id;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _voiceLoadError = e.toString();
        _loadingVoices = false;
      });
    }
  }

  void _onEngineChanged(TtsEngine? engine) {
    if (engine == null || engine.id == _engine.id) return;
    setState(() {
      _engine = engine;
      _voiceId = '';
      _voices = <TtsVoice>[];
    });
    _loadVoices();
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    final Color errorColor = Theme.of(context).colorScheme.error;

    return AlertDialog(
      title: Text(t.tts_settings_title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // 引擎选择
              Text(t.tts_engine, style: textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: TtsEngineRegistry.instance.engines.map((TtsEngine e) {
                  return ChoiceChip(
                    label: Text(e.displayName),
                    selected: e.id == _engine.id,
                    onSelected: (_) => _onEngineChanged(e),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),

              // 音色选择
              Text(t.tts_voice, style: textTheme.titleSmall),
              const SizedBox(height: 8),
              if (_loadingVoices)
                const Center(child: CircularProgressIndicator())
              else if (_voiceLoadError != null)
                Text(
                  '${t.tts_voice_load_failed}: $_voiceLoadError',
                  style: textTheme.bodySmall?.copyWith(color: errorColor),
                )
              else if (_voices.isEmpty)
                Text(t.tts_no_voices, style: textTheme.bodySmall)
              else
                DropdownButton<String>(
                  isExpanded: true,
                  value: _voices.any((TtsVoice v) => v.id == _voiceId)
                      ? _voiceId
                      : null,
                  hint: Text(t.tts_select_voice),
                  items: _voices.map((TtsVoice voice) {
                    return DropdownMenuItem<String>(
                      value: voice.id,
                      child: Text(voice.displayName),
                    );
                  }).toList(),
                  onChanged: (String? value) {
                    if (value != null) {
                      setState(() => _voiceId = value);
                    }
                  },
                ),
              const SizedBox(height: 16),

              // 语速
              Row(
                children: <Widget>[
                  Expanded(child: Text(t.tts_speed)),
                  Text('${_speed.toStringAsFixed(2)}x'),
                ],
              ),
              Slider(
                value: _speed.clamp(_engine.minSpeed, _engine.maxSpeed),
                min: _engine.minSpeed,
                max: _engine.maxSpeed,
                divisions: ((_engine.maxSpeed - _engine.minSpeed) * 10).round(),
                onChanged: (double value) {
                  setState(() => _speed = value);
                },
              ),

              // 音高（仅 Edge 支持）
              if (_engine.supportsPitch) ...<Widget>[
                Row(
                  children: <Widget>[
                    Expanded(child: Text(t.tts_pitch)),
                    Text('${_pitch.toStringAsFixed(0)}%'),
                  ],
                ),
                Slider(
                  value: _pitch.clamp(-50, 50),
                  min: -50,
                  max: 50,
                  divisions: 20,
                  onChanged: (double value) {
                    setState(() => _pitch = value);
                  },
                ),
              ],

              // 预加载句数
              Row(
                children: <Widget>[
                  Expanded(child: Text(t.tts_preload_sentences)),
                  Text('$_preloadSentences ${t.tts_sentences_unit}'),
                ],
              ),
              Slider(
                value: _preloadSentences.toDouble().clamp(1, 20),
                min: 1,
                max: 20,
                divisions: 19,
                onChanged: (double value) {
                  setState(() => _preloadSentences = value.round());
                },
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(result),
          child: Text(t.book_css_editor_save),
        ),
      ],
    );
  }

  TtsSettingsResult get result => TtsSettingsResult(
    engineId: _engine.id,
    voiceId: _voiceId,
    speed: _speed,
    pitch: _pitch,
    preloadSentences: _preloadSentences,
  );
}

class TtsSettingsResult {
  const TtsSettingsResult({
    required this.engineId,
    required this.voiceId,
    required this.speed,
    required this.pitch,
    required this.preloadSentences,
  });

  final String engineId;
  final String voiceId;
  final double speed;
  final double pitch;
  final int preloadSentences;
}
