import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show FfmpegFailureReporter;
import 'package:path/path.dart' as path;

import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 把多个 MP3 文件用 ffmpeg concat demuxer 拼成一条音频。
///
/// 输入文件必须是相同编码（MP3、同采样率/声道）才能 `-acodec copy`。
/// 失败时返回 null（不抛异常）。
Future<String?> concatenateMp3Files(
  List<String> inputPaths,
  String outputPath, {
  FfmpegFailureReporter? onFailure,
}) async {
  if (inputPaths.isEmpty) return null;
  if (inputPaths.length == 1) {
    // 只有一句时直接复制，避免 ffmpeg concat 开销。
    final File single = File(inputPaths.single);
    if (!single.existsSync()) return null;
    await single.copy(outputPath);
    return outputPath;
  }

  final Directory tempDir = Directory(
    path.join(
      Directory.systemTemp.path,
      'fushi_tts_concat_${DateTime.now().millisecondsSinceEpoch}',
    ),
  );
  await tempDir.create(recursive: true);
  final File listFile = File(path.join(tempDir.path, 'concat_list.txt'));

  try {
    final StringBuffer list = StringBuffer();
    for (final String p in inputPaths) {
      // ffmpeg concat demuxer 要求路径中的单引号转义成 '''
      final String escaped = p.replaceAll("'", "'\\''");
      list.writeln("file '$escaped'");
    }
    await listFile.writeAsString(list.toString(), encoding: utf8);

    final FfmpegBackend backend = resolveFfmpegBackend();
    final FfmpegRunResult result = await backend.run(<String>[
      '-y',
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'concat',
      '-safe',
      '0',
      '-i',
      listFile.path,
      '-acodec',
      'copy',
      outputPath,
    ], const Duration(seconds: 30));

    if (result.returnCode != 0 || !File(outputPath).existsSync()) {
      onFailure?.call(result.failureSummary);
      ErrorLogService.instance.log(
        'tts_audio_concat',
        'concat failed: ${result.failureSummary}',
        StackTrace.current,
      );
      return null;
    }
    return outputPath;
  } on ProcessException catch (e, stack) {
    ErrorLogService.instance.log('tts_audio_concat', e, stack);
    return null;
  } catch (e, stack) {
    ErrorLogService.instance.log('tts_audio_concat', e, stack);
    return null;
  } finally {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  }
}

/// 用 ffprobe 探测单个音频文件的时长（毫秒）。
///
/// 失败时返回 null，调用方通常可用 0 或默认值兜底。
Future<int?> probeAudioDurationMs(String inputPath) async {
  try {
    final FfmpegBackend backend = resolveFfmpegBackend();
    final FfmpegRunResult result = await backend.runProbe(<String>[
      '-v',
      'quiet',
      '-print_format',
      'json',
      '-show_entries',
      'format=duration',
      inputPath,
    ], const Duration(seconds: 10));
    if (result.returnCode != 0) return null;
    final Object? decoded = jsonDecode(result.output);
    if (decoded is! Map) return null;
    final Object? format = decoded['format'];
    if (format is! Map) return null;
    final double? seconds = double.tryParse(format['duration'].toString());
    if (seconds == null) return null;
    return (seconds * 1000).round();
  } catch (e, stack) {
    ErrorLogService.instance.log('probeAudioDurationMs', e, stack);
    return null;
  }
}
