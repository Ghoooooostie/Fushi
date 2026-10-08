import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:fushi/src/tts/tts_engine.dart';
import 'package:fushi/src/tts/tts_models.dart';
import 'package:web_socket_channel/io.dart';

/// 微软 Edge 在线 TTS（Edge 浏览器「大声朗读」同款接口）。
///
/// 实现参考 LunaTranslator `tts/edgetts.py`：先取 voice list，再用 WebSocket
/// 发送 SSML 并接收 MP3 流。
class EdgeTtsEngine extends TtsEngine {
  static const String _baseUrl = 'speech.platform.bing.com';
  static const String _trustedClientToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const String _chromiumFullVersion = '144.0.7559.133';
  static const int _winEpochSeconds = 11644473600;

  static final RegExp _endPathPattern = RegExp(r'Path:turn\.end');
  static final RegExp _audioHeaderPattern = RegExp(r'Path:audio\r?\n');

  @override
  String get id => 'edge_tts';

  @override
  String get displayName => 'Microsoft Edge TTS';

  @override
  bool get supportsPitch => true;

  @override
  double get minSpeed => 0.5;

  @override
  double get maxSpeed => 2.0;

  @override
  Future<List<TtsVoice>> getVoices() async {
    final String secMsGec = _generateSecMsGec();
    final String majorVersion = _chromiumFullVersion.split('.').first;
    final Uri url = Uri.https(
      _baseUrl,
      '/consumer/speech/synthesize/readaloud/voices/list',
      <String, String>{
        'trustedclienttoken': _trustedClientToken,
        'Sec-MS-GEC': secMsGec,
        'Sec-MS-GEC-Version': '1-$_chromiumFullVersion',
      },
    );

    final Map<String, String> headers = <String, String>{
      'User-Agent': _edgeUserAgent(majorVersion),
      'Accept-Language': 'en-US,en;q=0.9',
      'Authority': _baseUrl,
      'Sec-CH-UA':
          '" Not;A Brand";v="99", "Microsoft Edge";v="$majorVersion", '
          '"Chromium";v="$majorVersion"',
      'Sec-CH-UA-Mobile': '?0',
      'Accept': '*/*',
      'Sec-Fetch-Site': 'none',
      'Sec-Fetch-Mode': 'cors',
      'Sec-Fetch-Dest': 'empty',
    };

    final http.Response response = await http.get(url, headers: headers);
    if (response.statusCode != 200) {
      throw Exception('Edge voice list failed: ${response.statusCode}');
    }
    final List<dynamic> list = jsonDecode(response.body) as List<dynamic>;
    return list
        .map((dynamic item) {
          final Map<String, dynamic> map = item as Map<String, dynamic>;
          final String shortName = map['ShortName'] as String? ?? '';
          final String friendlyName =
              map['FriendlyName'] as String? ?? shortName;
          final String? locale = map['Locale'] as String?;
          final String? gender = map['Gender'] as String?;
          if (shortName.isEmpty) return null;
          return TtsVoice(
            id: shortName,
            displayName: friendlyName,
            locale: locale,
            gender: gender,
            engineId: id,
          );
        })
        .whereType<TtsVoice>()
        .toList();
  }

  @override
  Future<TtsResult> synthesize(String text, TtsParam param) async {
    final String ssml = _buildSsml(text, param);
    final List<int> audioBytes = await _transferMsTtsData(ssml);
    return TtsResult(
      audioBytes: Uint8List.fromList(audioBytes),
      mimeType: 'audio/mpeg',
      suggestedExtension: 'mp3',
    );
  }

  String _buildSsml(String text, TtsParam param) {
    // 对齐 LunaTranslator basettsclass.createSSML：
    // pitch 取 -50%~50% 映射到 percentage；speed 映射到 rate percentage。
    final int pitchPct = (param.pitch * 5).round();
    final int ratePct;
    if (param.speed > 0) {
      ratePct = (param.speed * 10).round();
    } else {
      ratePct = (param.speed * 5).round();
    }

    final String escapedText = _xmlEscape(text);
    String prosody =
        "<prosody pitch='$pitchPct%' rate='$ratePct%'>$escapedText</prosody>";
    if (param.voice.id.isNotEmpty) {
      prosody = "<voice name='${_xmlEscape(param.voice.id)}'>$prosody</voice>";
    }
    return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
        "xml:lang='en-US'>$prosody</speak>";
  }

  Future<List<int>> _transferMsTtsData(String ssml) async {
    final String majorVersion = _chromiumFullVersion.split('.').first;
    final String connectionId = _randomUuid().replaceAll('-', '');
    final Uri wsUrl = Uri.https(
      _baseUrl,
      '/consumer/speech/synthesize/readaloud/edge/v1',
      <String, String>{
        'TrustedClientToken': _trustedClientToken,
        'Sec-MS-GEC': _generateSecMsGec(),
        'Sec-MS-GEC-Version': '1-$_chromiumFullVersion',
        'ConnectionId': connectionId,
      },
    );

    final Map<String, dynamic> headers = <String, dynamic>{
      'Pragma': 'no-cache',
      'Cache-Control': 'no-cache',
      'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
      'User-Agent': _edgeUserAgent(majorVersion),
      'Accept-Language': 'en-US,en;q=0.9',
    };

    final IOWebSocketChannel channel = IOWebSocketChannel.connect(
      Uri.parse('wss://${wsUrl.host}${wsUrl.path}?${wsUrl.query}'),
      headers: headers,
    );

    try {
      await channel.ready;
    } catch (e) {
      await channel.sink.close();
      throw Exception('Edge TTS WebSocket connect failed: $e');
    }

    final String date = _rfc7231Date();

    // 1. 发送 speech.config
    channel.sink.add(
      'X-Timestamp:$date\r\n'
      'Content-Type:application/json; charset=utf-8\r\n'
      'Path:speech.config\r\n\r\n'
      '{"context":{"synthesis":{"audio":{"metadataoptions":{'
      '"sentenceBoundaryEnabled":false,"wordBoundaryEnabled":true},'
      '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n',
    );

    // 2. 发送 SSML
    final String requestId = _randomUuid().replaceAll('-', '');
    channel.sink.add(
      'X-RequestId:$requestId\r\n'
      'Content-Type:application/ssml+xml\r\n'
      'X-Timestamp:${_xTimestamp()}Z\r\n'
      'Path:ssml\r\n\r\n'
      '$ssml',
    );

    final List<int> buffer = <int>[];
    await for (final dynamic message in channel.stream) {
      late final List<int> data;
      if (message is String) {
        data = utf8.encode(message);
      } else if (message is List<int>) {
        data = message;
      } else {
        continue;
      }
      final String head = String.fromCharCodes(data.take(2));
      if (head == '\x03\xef') {
        final String errorText = String.fromCharCodes(data.skip(2));
        await channel.sink.close();
        throw Exception('Edge TTS error: $errorText');
      }
      final String textPreview = String.fromCharCodes(data);
      if (_endPathPattern.hasMatch(textPreview)) {
        break;
      }
      final Match? headerMatch = _audioHeaderPattern.firstMatch(textPreview);
      if (headerMatch != null) {
        final int start = headerMatch.end;
        buffer.addAll(data.sublist(start));
      }
    }

    await channel.sink.close();
    return buffer;
  }

  static String _generateSecMsGec() {
    // Windows file time epoch，按 5 分钟取整。
    final double unixSec = DateTime.now().toUtc().millisecondsSinceEpoch / 1000;
    double ticks = unixSec + _winEpochSeconds;
    ticks -= ticks % 300;
    ticks *= 1e7;
    final String strToHash = '${ticks.round()}$_trustedClientToken';
    final Digest digest = sha256.convert(ascii.encode(strToHash));
    return digest.toString().toUpperCase();
  }

  static String _edgeUserAgent(String majorVersion) {
    return 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/$majorVersion.0.0.0 Safari/537.36 '
        'Edg/$majorVersion.0.0.0';
  }

  static String _xmlEscape(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static String _randomUuid() {
    final Random random = Random();
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < 36; i++) {
      if (i == 8 || i == 13 || i == 18 || i == 23) {
        sb.write('-');
      } else {
        final int r = random.nextInt(16);
        sb.write(r.toRadixString(16));
      }
    }
    return sb.toString();
  }

  static String _rfc7231Date() {
    // Edge 服务端只要求一个合理的日期格式；这里用 IMF-fixdate 近似。
    final DateTime now = DateTime.now().toUtc();
    const List<String> weekdays = <String>[
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
      'Sun',
    ];
    const List<String> months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final String day = now.day.toString().padLeft(2, '0');
    final String hour = now.hour.toString().padLeft(2, '0');
    final String minute = now.minute.toString().padLeft(2, '0');
    final String second = now.second.toString().padLeft(2, '0');
    return '${weekdays[now.weekday - 1]}, $day ${months[now.month - 1]} '
        '${now.year} $hour:$minute:$second GMT';
  }

  static String _xTimestamp() {
    // 格式：YYYY-MM-DDThh:mm:ss.sssZ（时区固定 UTC，小时按美国习惯 -1 修正）。
    final DateTime now = DateTime.now().toUtc();
    final int correctedHour = (now.hour - 1) % 24;
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}T'
        '${two(correctedHour)}:${two(now.minute)}:${two(now.second)}.'
        '${three(now.millisecond)}Z';
  }
}
