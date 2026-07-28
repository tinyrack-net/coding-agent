import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'audio_debug.dart';
import 'recordings_debug.dart';
import 'speech_provider.dart';

final class TtsDebugAudioMetadata {
  const TtsDebugAudioMetadata({
    required this.sessionId,
    required this.groupId,
    required this.format,
  });

  final String sessionId;
  final String groupId;
  final String format;
}

final class TtsDebugAudioStore {
  TtsDebugAudioStore({
    required Map<String, String> environment,
    required String cwd,
    DateTime Function()? now,
  }) : debugDirectory = resolveRecordingsDebugDir(
         explicitEnvironmentName: 'TINYRACK_TTS_DEBUG_AUDIO_DIR',
         environment: environment,
         cwd: cwd,
       ),
       _now = now ?? DateTime.now;

  final String? debugDirectory;
  final DateTime Function() _now;
  bool _announced = false;

  bool get enabled => debugDirectory != null;

  Future<String?> persist(
    Uint8List audio,
    TtsDebugAudioMetadata metadata,
    SpeechLogger logger,
  ) async {
    final debugDirectory = this.debugDirectory;
    if (debugDirectory == null) return null;
    if (!_announced) {
      logger.info(
        'TTS audio capture enabled',
        fields: {'debugDir': debugDirectory},
      );
      _announced = true;
    }
    final folder = p.join(
      debugDirectory,
      sanitizeForFilename(metadata.sessionId, 'session'),
    );
    await Directory(folder).create(recursive: true);
    final filename =
        '${_timestamp(_now())}_${sanitizeForFilename(metadata.groupId, 'tts')}.${inferAudioExtension(metadata.format)}';
    final path = p.join(folder, filename);
    await File(path).writeAsBytes(audio, flush: true);
    return path;
  }
}

String _timestamp(DateTime value) {
  final utc = value.toUtc();
  String two(int number) => number.toString().padLeft(2, '0');
  String three(int number) => number.toString().padLeft(3, '0');
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${two(utc.month)}-${two(utc.day)}T'
      '${two(utc.hour)}-${two(utc.minute)}-${two(utc.second)}-'
      '${three(utc.millisecond)}Z';
}
