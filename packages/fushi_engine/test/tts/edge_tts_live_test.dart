import 'dart:io';

import 'package:fushi_engine/tts/providers/edge_tts_provider.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:test/test.dart';

/// 真网络验收：微软 Edge 非官方接口的「声音列表」与「合成」到底还通不通。
///
/// 这是逆向的非官方入口，微软随时可能改主机或拒绝旧版本号，离线单测挡不住；
/// 只有真打一次才知道。默认整组跳过（CI 不联网），本地跑：
///   $env:FUSHI_LIVE_TTS=1
///   flutter test test/tts/edge_tts_live_test.dart
/// 失败时把 [log] 打出来：引擎层只往里放可公开的错误码与 HTTP 状态。
const String _liveEnv = 'FUSHI_LIVE_TTS';

bool get _live =>
    (Platform.environment[_liveEnv] ?? '').trim().toLowerCase() == '1';

TtsHost _host(List<String> log) =>
    TtsHost(httpClientFactory: () => HttpClient(), log: log.add);

void main() {
  group('Edge TTS live endpoint', () {
    test('voices list is reachable and carries ja-JP neural voices', () async {
      final List<String> log = <String>[];
      final EdgeTtsProvider p = EdgeTtsProvider(
        voice: 'ja-JP-NanamiNeural',
        host: _host(log),
      );
      final List<TtsVoice> voices = await p.listVoices();
      // ignore: avoid_print
      print('[live] voices=${voices.length} log=$log');
      expect(voices, isNotEmpty);
      expect(
        voices.map((TtsVoice v) => v.id),
        contains('ja-JP-NanamiNeural'),
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('synthesize writes a non-trivial mp3', () async {
      final Directory dir = Directory.systemTemp.createTempSync('edge_live_');
      final String out = '${dir.path}${Platform.pathSeparator}a.mp3';
      final List<String> log = <String>[];
      final EdgeTtsProvider p = EdgeTtsProvider(
        voice: 'ja-JP-NanamiNeural',
        host: _host(log),
      );
      final TtsResult r = await p.synthesize(
        '今日は、いい天気ですね。',
        outputPath: out,
        cancel: TtsCancelToken(),
      );
      final File f = File(out);
      // ignore: avoid_print
      print(
        '[live] format=${r.format.name} bytes=${f.existsSync() ? f.lengthSync() : -1}'
        ' boundaries=${r.boundaries.length} log=$log',
      );
      expect(r.format, TtsAudioFormat.mp3);
      expect(f.existsSync(), isTrue);
      expect(f.lengthSync(), greaterThan(1024));
      dir.deleteSync(recursive: true);
    }, timeout: const Timeout(Duration(seconds: 60)));
  }, skip: _live ? null : 'set $_liveEnv=1 to hit the real endpoint');
}
