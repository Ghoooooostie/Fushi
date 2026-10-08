import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi/src/tts/tts_engine.dart';
import 'package:fushi/src/tts/tts_models.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// TTS 音频缓存 + 并行合成调度。
///
/// 缓存键综合了引擎、音色、语速、音高和文本，命中时直接读文件。合成按
/// [concurrency] 并发执行，避免一次性建立过多 WebSocket/HTTP 连接。
class TtsSynthesizer {
  TtsSynthesizer({this.concurrency = 3});

  final int concurrency;

  /// 缓存目录；首次访问时创建。
  Directory? _cacheDir;

  Future<Directory> _getCacheDir() async {
    final Directory? dir = _cacheDir;
    if (dir != null) return dir;
    final Directory appDir = await getApplicationSupportDirectory();
    final Directory cache = Directory(path.join(appDir.path, 'tts_cache'));
    if (!cache.existsSync()) {
      await cache.create(recursive: true);
    }
    _cacheDir = cache;
    return cache;
  }

  /// 单条缓存路径。
  Future<String> _cachePath(
    TtsEngine engine,
    TtsParam param,
    String text,
  ) async {
    final Directory cache = await _getCacheDir();
    final String hash = _cacheKey(engine.id, param, text);
    final String ext = _extensionFor(engine, param);
    return path.join(cache.path, '${engine.id}_$hash.$ext');
  }

  static String _cacheKey(String engineId, TtsParam param, String text) {
    final String raw =
        '$engineId|${param.voice.id}|${param.speed}|'
        '${param.pitch}|$text';
    return md5.convert(utf8.encode(raw)).toString();
  }

  static String _extensionFor(TtsEngine engine, TtsParam param) {
    // 目前 Edge/火山都返回 MP3；系统引擎可能返回 WAV/AIFF，按需扩展。
    return 'mp3';
  }

  /// 合成单条文本；优先命中缓存。
  ///
  /// 返回缓存文件 [File]。失败时抛异常。
  Future<File> synthesize(String text, TtsEngine engine, TtsParam param) async {
    final String cachePath = await _cachePath(engine, param, text);
    final File file = File(cachePath);
    if (file.existsSync() && file.lengthSync() > 0) {
      return file;
    }

    final TtsResult result = await engine.synthesize(text, param);
    await file.writeAsBytes(result.audioBytes, flush: true);
    return file;
  }

  /// 批量合成，带并发限制与进度回调。
  ///
  /// [onProgress] 参数为 (已完成数, 总数)。
  Future<List<File>> synthesizeBatch(
    List<String> texts,
    TtsEngine engine,
    TtsParam param, {
    void Function(int completed, int total)? onProgress,
  }) async {
    final List<File> results = List<File>.filled(texts.length, File(''));
    int completed = 0;

    Future<File> runTask(int index) async {
      try {
        final File file = await synthesize(texts[index], engine, param);
        results[index] = file;
        completed++;
        onProgress?.call(completed, texts.length);
        return file;
      } catch (e) {
        completed++;
        onProgress?.call(completed, texts.length);
        rethrow;
      }
    }

    // 分桶并发：每桶 [concurrency] 个，桶内 Future.wait，桶间顺序执行。
    // 这样比流式 pool 简单，且能控制峰值连接数。
    for (int i = 0; i < texts.length; i += concurrency) {
      final int end = (i + concurrency < texts.length)
          ? i + concurrency
          : texts.length;
      final List<Future<File>> bucket = <Future<File>>[
        for (int j = i; j < end; j++) runTask(j),
      ];
      await Future.wait(bucket);
    }

    return results;
  }

  /// 清除全部 TTS 缓存。
  Future<void> clearCache() async {
    final Directory cache = await _getCacheDir();
    if (cache.existsSync()) {
      await cache.delete(recursive: true);
    }
    _cacheDir = null;
  }
}
