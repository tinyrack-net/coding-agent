import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/src/voice/audio_debug.dart';
import 'package:agent_daemon/src/voice/recordings_debug.dart';
import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:agent_daemon/src/voice/stt_debug.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('infers frozen audio extensions and sanitizes filename segments', () {
    expect(inferAudioExtension(null), 'webm');
    expect(inferAudioExtension('audio/ogg'), 'ogg');
    expect(inferAudioExtension('audio/mpeg;codec=mp3'), 'mp3');
    expect(inferAudioExtension('audio/x-wav'), 'wav');
    expect(inferAudioExtension('audio/aac'), 'm4a');
    expect(inferAudioExtension('video/mp4'), 'mp4');
    expect(inferAudioExtension('audio/flac'), 'flac');
    expect(inferAudioExtension('application/octet-stream'), 'webm');
    expect(sanitizeForFilename(null, 'fallback'), 'fallback');
    expect(sanitizeForFilename('a/b:c d', 'fallback'), 'a_b_c_d');
    expect(sanitizeForFilename('x' * 70, 'fallback'), 'x' * 64);
  });

  test('resolves explicit and dictation-wide recording directories', () {
    final explicit = resolveRecordingsDebugDir(
      explicitEnvironmentName: 'TINYRACK_STT_DEBUG_AUDIO_DIR',
      environment: const {
        'TINYRACK_STT_DEBUG_AUDIO_DIR': ' relative-recordings ',
      },
      cwd: p.join(Directory.current.path, 'ignored'),
    );
    expect(explicit, p.normalize(p.absolute('relative-recordings')));

    final fromFlag = resolveRecordingsDebugDir(
      explicitEnvironmentName: 'TINYRACK_STT_DEBUG_AUDIO_DIR',
      environment: const {'TINYRACK_DICTATION_DEBUG': ' YES '},
      cwd: p.join(Directory.current.path, 'workspace'),
    );
    expect(
      fromFlag,
      p.normalize(
        p.absolute(
          p.join(Directory.current.path, 'workspace', '.debug', 'recordings'),
        ),
      ),
    );
    expect(
      resolveRecordingsDebugDir(
        explicitEnvironmentName: 'TINYRACK_STT_DEBUG_AUDIO_DIR',
        environment: const {'TINYRACK_DICTATION_DEBUG': 'off'},
        cwd: Directory.current.path,
      ),
      isNull,
    );
    for (final value in ['1', 'true', 'yes', 'on']) {
      expect(
        isTinyrackDictationDebugEnabled({'TINYRACK_DICTATION_DEBUG': value}),
        isTrue,
      );
    }
  });

  test('persists metadata-rich debug audio and announces only once', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'tinyrack-stt-debug-',
    );
    try {
      final logger = _RecordingLogger();
      final persister = SttDebugAudioPersister(
        debugDirectory: temporary.path,
        now: () => DateTime.utc(2026, 7, 29, 1, 2, 3, 456),
      );
      const metadata = DebugAudioMetadata(
        sessionId: 'session/1',
        agentId: 'agent:2',
        requestId: 'request 3',
        label: 'voice/input',
        format: 'audio/wav',
      );

      final first = await persister.persist(
        Uint8List.fromList([1, 2, 3]),
        metadata,
        logger,
      );
      final second = await persister.persist(
        Uint8List.fromList([4]),
        metadata,
        logger,
      );

      expect(first, isNotNull);
      expect(second, first);
      expect(
        p.basename(first!),
        '2026-07-29T01-02-03-456Z_agent_2_voice_input_request_3.wav',
      );
      expect(p.basename(p.dirname(first)), 'session_1');
      expect(await File(first).readAsBytes(), [4]);
      expect(logger.infoMessages, ['Raw audio capture enabled']);
      expect(logger.infoFields.single, {'debugDir': temporary.path});
    } finally {
      await temporary.delete(recursive: true);
    }
  });

  test('disabled debug persistence is a no-op', () async {
    final logger = _RecordingLogger();
    final persister = SttDebugAudioPersister(debugDirectory: null);

    expect(
      await persister.persist(
        Uint8List.fromList([1]),
        const DebugAudioMetadata(sessionId: 's', format: 'audio/pcm'),
        logger,
      ),
      isNull,
    );
    expect(logger.infoMessages, isEmpty);
  });
}

final class _RecordingLogger implements SpeechLogger {
  final List<String> infoMessages = [];
  final List<Map<String, Object?>> infoFields = [];

  @override
  SpeechLogger child(Map<String, Object?> context) => this;

  @override
  void debug(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void error(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void info(String message, {Map<String, Object?> fields = const {}}) {
    infoMessages.add(message);
    infoFields.add(fields);
  }

  @override
  void warning(String message, {Map<String, Object?> fields = const {}}) {}
}
