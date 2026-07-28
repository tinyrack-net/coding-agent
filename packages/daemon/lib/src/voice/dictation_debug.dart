import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'audio_debug.dart';
import 'recordings_debug.dart';
import 'speech_provider.dart';

String? _announcedDirectory;

final class DictationDebugAudioMetadata {
  const DictationDebugAudioMetadata({
    required this.sessionId,
    required this.dictationId,
    required this.format,
  });

  final String sessionId;
  final String dictationId;
  final String format;
}

final class DictationDebugChunkWriter {
  DictationDebugChunkWriter({required this.folder});

  final String folder;
  bool _folderCreated = false;
  Future<void> _pending = Future<void>.value();

  Future<void> writeChunk(int seq, Uint8List pcm16) {
    final copy = Uint8List.fromList(pcm16);
    final operation = _pending.then((_) async {
      if (!_folderCreated) {
        await Directory(folder).create(recursive: true);
        _folderCreated = true;
      }
      final paddedSeq = seq.toString().padLeft(6, '0');
      await File(
        p.join(folder, 'chunk_$paddedSeq.pcm'),
      ).writeAsBytes(copy, flush: true);
    });
    _pending = operation.catchError((_) {});
    return operation;
  }

  Future<void> drain() => _pending;
}

final class DictationDebugAudioStore {
  DictationDebugAudioStore({
    required Map<String, String> environment,
    required String cwd,
    DateTime Function()? now,
  }) : debugDirectory = resolveRecordingsDebugDir(
         explicitEnvironmentName: 'TINYRACK_DICTATION_DEBUG_AUDIO_DIR',
         environment: environment,
         cwd: cwd,
       ),
       _now = now ?? DateTime.now;

  final String? debugDirectory;
  final DateTime Function() _now;

  DictationDebugChunkWriter? createChunkWriter({
    required String sessionId,
    required String dictationId,
    required SpeechLogger logger,
  }) {
    final debugDirectory = this.debugDirectory;
    if (debugDirectory == null) return null;
    _announce(debugDirectory, logger);
    final folder = p.join(
      debugDirectory,
      sanitizeForFilename(sessionId, 'session'),
      '${_timestamp(_now())}_${sanitizeForFilename(dictationId, 'dictation')}',
    );
    return DictationDebugChunkWriter(folder: folder);
  }

  Future<String?> persist(
    Uint8List audio,
    DictationDebugAudioMetadata metadata,
    SpeechLogger logger, {
    String? chunkWriterFolder,
  }) async {
    final debugDirectory = this.debugDirectory;
    if (debugDirectory == null) return null;
    _announce(debugDirectory, logger);
    final folder =
        chunkWriterFolder ??
        p.join(
          debugDirectory,
          sanitizeForFilename(metadata.sessionId, 'session'),
        );
    await Directory(folder).create(recursive: true);
    final filename = chunkWriterFolder != null
        ? 'combined.${inferAudioExtension(metadata.format)}'
        : '${_timestamp(_now())}_${sanitizeForFilename(metadata.dictationId, 'dictation')}.${inferAudioExtension(metadata.format)}';
    final filePath = p.join(folder, filename);
    await File(filePath).writeAsBytes(audio, flush: true);
    return filePath;
  }

  void _announce(String debugDirectory, SpeechLogger logger) {
    if (_announcedDirectory == debugDirectory) return;
    logger.info(
      'Dictation audio capture enabled',
      fields: {'debugDir': debugDirectory},
    );
    _announcedDirectory = debugDirectory;
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
