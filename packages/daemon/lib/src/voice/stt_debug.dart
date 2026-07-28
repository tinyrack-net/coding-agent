import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'audio_debug.dart';
import 'speech_provider.dart';

final class DebugAudioMetadata {
  const DebugAudioMetadata({
    required this.sessionId,
    required this.format,
    this.agentId,
    this.requestId,
    this.label,
  });

  final String sessionId;
  final String? agentId;
  final String? requestId;
  final String? label;
  final String format;
}

final class SttDebugAudioPersister {
  SttDebugAudioPersister({
    required this.debugDirectory,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final String? debugDirectory;
  final DateTime Function() _now;
  bool _announced = false;

  Future<String?> persist(
    Uint8List audio,
    DebugAudioMetadata metadata,
    SpeechLogger logger,
  ) async {
    final debugDirectory = this.debugDirectory;
    if (debugDirectory == null) return null;

    if (!_announced) {
      logger.info(
        'Raw audio capture enabled',
        fields: {'debugDir': debugDirectory},
      );
      _announced = true;
    }

    final folder = p.join(
      debugDirectory,
      sanitizeForFilename(metadata.sessionId, 'session'),
    );
    await Directory(folder).create(recursive: true);

    final parts = [_timestamp(_now())];
    if (metadata.agentId != null) {
      parts.add(sanitizeForFilename(metadata.agentId, 'agent'));
    }
    if (metadata.label != null) {
      parts.add(sanitizeForFilename(metadata.label, 'source'));
    }
    if (metadata.requestId != null) {
      parts.add(sanitizeForFilename(metadata.requestId, 'request'));
    }

    final extension = inferAudioExtension(metadata.format);
    final filePath = p.join(folder, '${parts.join('_')}.$extension');
    await File(filePath).writeAsBytes(audio, flush: true);
    return filePath;
  }
}

String _timestamp(DateTime value) {
  final utc = value.toUtc();
  String two(int number) => number.toString().padLeft(2, '0');
  String three(int number) => number.toString().padLeft(3, '0');
  final iso =
      '${utc.year.toString().padLeft(4, '0')}-'
      '${two(utc.month)}-${two(utc.day)}T'
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}.'
      '${three(utc.millisecond)}Z';
  return iso.replaceAll(RegExp(r'[:.]'), '-');
}
