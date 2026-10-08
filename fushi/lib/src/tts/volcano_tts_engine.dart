import 'dart:convert';

import 'package:fushi/src/tts/tts_engine.dart';
import 'package:fushi/src/tts/tts_models.dart';
import 'package:http/http.dart' as http;

/// 火山引擎在线 TTS（浏览器翻译扩展接口）。
///
/// 实现参考 LunaTranslator `tts/huoshantts.py`：POST 文本 + speaker id，取 base64
/// MP3 音频。该接口无需鉴权，但依赖火山对扩展来源的可用性。
class VolcanoTtsEngine extends TtsEngine {
  static const String _endpoint =
      'https://translate.volcengine.com/crx/tts/v1/';

  /// 各语言下可用的 speaker id。键小写语言码，值按「优先默认」排序。
  static const Map<String, List<String>> _voicesByLang = <String, List<String>>{
    'en': <String>[
      'en_male_adam',
      'tts.other.BV027_streaming',
      'en_male_bob',
      'tts.other.BV032_TOBI_streaming',
      'tts.other.BV516_streaming',
      'en_female_sarah',
    ],
    'ja': <String>['jp_male_satoshi', 'jp_female_mai'],
    'zh': <String>[
      'zh_male_rap',
      'zh_male_zhubo',
      'zh_female_zhubo',
      'tts.other.BV021_streaming',
      'tts.other.BV026_streaming',
      'tts.other.BV025_streaming',
      'zh_female_sichuan',
      'zh_male_xiaoming',
      'zh_female_qingxin',
      'zh_female_story',
    ],
    'ko': <String>['kr_male_gye', 'tts.other.BV059_streaming'],
    'pt': <String>['pt_female_alice', 'tts.other.BV531_streaming'],
    'es': <String>['es_male_george', 'tts.other.BV065_streaming'],
    'id': <String>['id_female_noor', 'tts.other.BV160_streaming'],
    'de': <String>['de_female_sophie'],
    'fr': <String>['fr_male_enzo', 'tts.other.BV078_streaming'],
    'ms': <String>['tts.other.BV092_streaming'],
    'vi': <String>['tts.other.BV075_streaming', 'tts.other.BV074_streaming'],
    'ru': <String>['tts.other.BV068_streaming'],
    'tr': <String>['tts.other.BV083_streaming'],
    'it': <String>['tts.other.BV087_streaming'],
    'ar': <String>['tts.other.BV570_streaming'],
  };

  static const Map<String, String> _displayNames = <String, String>{
    'en_male_adam': '美式男声',
    'tts.other.BV027_streaming': '美式女声',
    'en_male_bob': '英式男声',
    'tts.other.BV032_TOBI_streaming': '英式女声',
    'tts.other.BV516_streaming': '澳洲男声',
    'en_female_sarah': '澳洲女声',
    'zh_male_rap': '嘻哈歌手',
    'zh_male_zhubo': '男主播',
    'zh_female_zhubo': '女主播',
    'tts.other.BV021_streaming': '东北男声',
    'tts.other.BV026_streaming': '粤语男声',
    'tts.other.BV025_streaming': '台湾女声',
    'zh_female_sichuan': '四川女声',
    'zh_male_xiaoming': '影视配音',
    'zh_female_qingxin': '清新女声',
    'zh_female_story': '少儿故事',
    'jp_male_satoshi': '日语男声',
    'jp_female_mai': '日语女声',
    'kr_male_gye': '韩语男声',
    'tts.other.BV059_streaming': '韩语女声',
    'es_male_george': '西语男声',
    'tts.other.BV065_streaming': '西语女声',
    'pt_female_alice': '葡语女声',
    'tts.other.BV531_streaming': '葡语男声',
    'id_female_noor': '印尼女声',
    'tts.other.BV160_streaming': '印尼男声',
    'de_female_sophie': '德语女声',
    'fr_male_enzo': '法语男声',
    'tts.other.BV078_streaming': '法语女声',
    'tts.other.BV092_streaming': '马来女声',
    'tts.other.BV075_streaming': '越南男声',
    'tts.other.BV074_streaming': '越南女声',
    'tts.other.BV068_streaming': '俄语女声',
    'tts.other.BV083_streaming': '土耳其男声',
    'tts.other.BV087_streaming': '意语男声',
    'tts.other.BV570_streaming': '阿语男声',
  };

  @override
  String get id => 'volcano_tts';

  @override
  String get displayName => 'Volcano TTS';

  @override
  bool get supportsSpeed => false;

  @override
  bool get supportsPitch => false;

  @override
  Future<List<TtsVoice>> getVoices() async {
    final List<TtsVoice> voices = <TtsVoice>[];
    _voicesByLang.forEach((String lang, List<String> ids) {
      for (final String voiceId in ids) {
        voices.add(
          TtsVoice(
            id: voiceId,
            displayName: '[$lang] ${_displayNames[voiceId] ?? voiceId}',
            locale: _toLocale(lang),
            engineId: id,
          ),
        );
      }
    });
    return voices;
  }

  @override
  Future<TtsResult> synthesize(String text, TtsParam param) async {
    String speaker = param.voice.id;
    final String? voiceLang = _langOf(speaker);
    final String? textLang = _detectLang(text);
    // 如果音色语言与文本语言明显不匹配，退回到该语言第一个音色。
    if (voiceLang != null &&
        textLang != null &&
        voiceLang != textLang &&
        _voicesByLang.containsKey(textLang)) {
      speaker = _voicesByLang[textLang]!.first;
    }

    final http.Response response = await http.post(
      Uri.parse(_endpoint),
      headers: <String, String>{
        'authority': 'translate.volcengine.com',
        'accept': 'application/json, text/plain, */*',
        'accept-language': 'zh-CN,zh;q=0.9',
        'origin': 'chrome-extension://klgfhbdadaspgppeadghjjemk',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'none',
        'content-type': 'application/json; charset=UTF-8',
      },
      body: jsonEncode(<String, String>{'text': text, 'speaker': speaker}),
    );

    if (response.statusCode != 200) {
      throw Exception('Volcano TTS failed: ${response.statusCode}');
    }

    final Map<String, dynamic> json =
        jsonDecode(response.body) as Map<String, dynamic>;
    final Map<String, dynamic>? audio = json['audio'] as Map<String, dynamic>?;
    final String? data = audio?['data'] as String?;
    if (data == null || data.isEmpty) {
      throw Exception('Volcano TTS returned empty audio');
    }

    return TtsResult(
      audioBytes: base64Decode(data),
      mimeType: 'audio/mpeg',
      suggestedExtension: 'mp3',
    );
  }

  String? _langOf(String voiceId) {
    for (final MapEntry<String, List<String>> entry in _voicesByLang.entries) {
      if (entry.value.contains(voiceId)) return entry.key;
    }
    return null;
  }

  String? _detectLang(String text) {
    // 极简化：按首个字符的 Unicode 区块猜测。TTS 调用前通常已知书籍语言，
    // 这里只做兜底，避免把日语句子送到中文音色。
    for (final int rune in text.runes.take(20)) {
      if (rune >= 0x3040 && rune <= 0x309F) return 'ja';
      if (rune >= 0x4E00 && rune <= 0x9FFF) return 'zh';
      if (rune >= 0xAC00 && rune <= 0xD7AF) return 'ko';
      if ((rune >= 0x0041 && rune <= 0x007A) ||
          (rune >= 0x00C0 && rune <= 0x024F)) {
        return 'en';
      }
    }
    return null;
  }

  String _toLocale(String lang) {
    switch (lang) {
      case 'ja':
        return 'ja-JP';
      case 'zh':
        return 'zh-CN';
      case 'ko':
        return 'ko-KR';
      case 'en':
        return 'en-US';
      case 'pt':
        return 'pt-BR';
      case 'es':
        return 'es-ES';
      case 'id':
        return 'id-ID';
      case 'de':
        return 'de-DE';
      case 'fr':
        return 'fr-FR';
      case 'ms':
        return 'ms-MY';
      case 'vi':
        return 'vi-VN';
      case 'ru':
        return 'ru-RU';
      case 'tr':
        return 'tr-TR';
      case 'it':
        return 'it-IT';
      case 'ar':
        return 'ar-SA';
    }
    return lang;
  }
}
