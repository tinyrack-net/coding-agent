import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:agent_daemon/src/voice/stt_debug.dart';
import 'package:agent_daemon/src/voice/stt_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('defaults to English and exposes the resolved provider', () async {
    final provider = _FakeSttProvider([const TranscriptionResult(text: 'hi')]);
    final manager = SttManager(
      sessionId: 's1',
      logger: _RecordingLogger(),
      resolveStt: () => provider,
      environment: const {},
    );

    final result = await manager.transcribe(
      Uint8List(2),
      'audio/pcm;rate=24000',
    );

    expect(manager.getProvider(), same(provider));
    expect(provider.parameters?.language, 'en');
    expect(result.text, 'hi');
    expect(result.byteLength, 2);
    expect(result.format, 'audio/pcm;rate=24000');
    expect(provider.session.closeCalls, 1);
  });

  test(
    'uses configured language and preserves single-final metadata',
    () async {
      const logprobs = [
        LogprobToken(token: 'hello', logprob: -0.5, bytes: [1, 2]),
      ];
      final provider = _FakeSttProvider([
        const TranscriptionResult(
          text: 'hello world',
          language: 'fr',
          logprobs: logprobs,
          avgLogprob: -0.5,
          isLowConfidence: false,
        ),
      ]);
      var clockCalls = 0;
      final times = [
        DateTime.utc(2026, 7, 29),
        DateTime.utc(2026, 7, 29, 0, 0, 0, 125),
      ];
      final manager = SttManager(
        sessionId: 's1',
        logger: _RecordingLogger(),
        resolveStt: () => provider,
        language: 'fr',
        now: () => times[clockCalls++],
        environment: const {},
      );

      final result = await manager.transcribe(
        Uint8List(4),
        'audio/pcm;rate=24000',
      );

      expect(provider.parameters?.language, 'fr');
      expect(result.text, 'hello world');
      expect(result.language, 'fr');
      expect(result.logprobs, same(logprobs));
      expect(result.avgLogprob, -0.5);
      expect(result.isLowConfidence, isNull);
      expect(result.duration, 125);
      expect(result.transcription.toJson(), {
        'text': 'hello world',
        'language': 'fr',
        'duration': 125.0,
        'logprobs': [
          {
            'token': 'hello',
            'logprob': -0.5,
            'bytes': [1, 2],
          },
        ],
        'avgLogprob': -0.5,
      });
    },
  );

  test('filters a low-confidence final while retaining metadata', () async {
    final provider = _FakeSttProvider([
      const TranscriptionResult(
        text: 'um',
        language: 'en',
        avgLogprob: -10,
        isLowConfidence: true,
      ),
    ]);
    final manager = SttManager(
      sessionId: 's1',
      logger: _RecordingLogger(),
      resolveStt: () => provider,
      environment: const {},
    );

    final result = await manager.transcribe(
      Uint8List(2),
      'audio/pcm;rate=24000',
      metadata: const TranscriptionMetadata(label: 'turn'),
    );

    expect(result.text, '');
    expect(result.isLowConfidence, isTrue);
    expect(result.avgLogprob, -10);
    expect(result.byteLength, 2);
  });

  test(
    'batches one-second PCM chunks and concatenates ordered finals',
    () async {
      final provider = _FakeSttProvider([
        const TranscriptionResult(
          text: 'alpha',
          language: 'en',
          isLowConfidence: false,
        ),
        const TranscriptionResult(
          text: 'beta',
          language: 'en',
          isLowConfidence: false,
        ),
        const TranscriptionResult(
          text: 'gamma',
          language: 'en',
          isLowConfidence: false,
        ),
      ]);
      final manager = SttManager(
        sessionId: 's1',
        logger: _RecordingLogger(),
        resolveStt: () => provider,
        batchCommitEverySeconds: 1,
        environment: const {},
      );
      final threeSeconds = Uint8List(24000 * 2 * 3);

      final result = await manager.transcribe(
        threeSeconds,
        'audio/pcm;rate=24000',
      );

      expect(result.text, 'alpha beta gamma');
      expect(result.language, 'en');
      expect(result.logprobs, isNull);
      expect(result.byteLength, threeSeconds.length);
      expect(provider.session.appended.map((chunk) => chunk.length), [
        48000,
        48000,
        48000,
      ]);
      expect(provider.session.commitCalls, 3);
    },
  );

  test('zero batch interval commits once after all appended chunks', () async {
    final provider = _FakeSttProvider([
      const TranscriptionResult(text: 'complete'),
    ]);
    final manager = SttManager(
      sessionId: 's1',
      logger: _RecordingLogger(),
      resolveStt: () => provider,
      batchCommitEverySeconds: 0,
      environment: const {},
    );

    final result = await manager.transcribe(
      Uint8List(48000 * 2),
      'audio/pcm;rate=24000',
    );

    expect(result.text, 'complete');
    expect(provider.session.appended, hasLength(2));
    expect(provider.session.commitCalls, 1);
  });

  test(
    'timeout returns available partial transcript and logs counts',
    () async {
      final logger = _RecordingLogger();
      final provider = _FakeSttProvider(
        const [],
        partialTranscript: 'available words',
      );
      final manager = SttManager(
        sessionId: 's1',
        logger: logger,
        resolveStt: () => provider,
        finalTimeout: const Duration(milliseconds: 10),
        environment: const {},
      );

      final result = await manager.transcribe(
        Uint8List(2),
        'audio/pcm;rate=24000',
        metadata: const TranscriptionMetadata(label: 'timeout-case'),
      );

      expect(result.text, 'available words');
      expect(logger.warningMessages, [
        'Timed out waiting for final STT segments; returning available '
            'transcripts',
      ]);
      expect(logger.warningFields.single, {
        'expectedFinals': 1,
        'receivedFinals': 0,
        'label': 'timeout-case',
      });
      expect(provider.session.closeCalls, 1);
    },
  );

  test(
    'session errors reject transcription and always close session',
    () async {
      final provider = _FakeSttProvider(
        const [],
        commitError: StateError('stream failed'),
      );
      final manager = SttManager(
        sessionId: 's1',
        logger: _RecordingLogger(),
        resolveStt: () => provider,
        environment: const {},
      );

      await expectLater(
        manager.transcribe(Uint8List(2), 'audio/pcm;rate=24000'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'stream failed',
          ),
        ),
      );
      expect(provider.session.closeCalls, 1);
    },
  );

  test('normalizes non-error session failures', () async {
    final provider = _FakeSttProvider(const [], commitError: 'socket closed');
    final manager = SttManager(
      sessionId: 's1',
      logger: _RecordingLogger(),
      resolveStt: () => provider,
      environment: const {},
    );

    await expectLater(
      manager.transcribe(Uint8List(2), 'audio/pcm;rate=24000'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'socket closed',
        ),
      ),
    );
  });

  test('accepts a final transcript before commit metadata', () async {
    final provider = _FakeSttProvider([
      const TranscriptionResult(text: 'early final', language: 'en'),
    ], transcriptBeforeCommit: true);
    final manager = SttManager(
      sessionId: 's1',
      logger: _RecordingLogger(),
      resolveStt: () => provider,
      environment: const {},
    );

    final result = await manager.transcribe(
      Uint8List(2),
      'audio/pcm;rate=24000',
    );

    expect(result.text, 'early final');
    expect(result.language, 'en');
  });

  test('WAV input is extracted and mismatched PCM is resampled', () async {
    final provider = _FakeSttProvider([
      const TranscriptionResult(text: 'resampled'),
    ]);
    final manager = SttManager(
      sessionId: 's1',
      logger: _RecordingLogger(),
      resolveStt: () => provider,
      environment: const {},
    );
    final wav = _wav(_pcm16([0, 1000, 2000, 3000]), sampleRate: 12000);

    final result = await manager.transcribe(wav, 'audio/wav');

    expect(result.text, 'resampled');
    expect(provider.session.appended.single.length, greaterThan(8));
    expect(result.byteLength, wav.length);
  });

  test('unsupported audio and missing provider use frozen errors', () async {
    final provider = _FakeSttProvider([
      const TranscriptionResult(text: 'unused'),
    ]);
    final manager = SttManager(
      sessionId: 's1',
      logger: _RecordingLogger(),
      resolveStt: () => provider,
      environment: const {},
    );
    await expectLater(
      manager.transcribe(Uint8List(2), 'audio/webm'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'Unsupported audio format for STT: audio/webm',
        ),
      ),
    );

    final missing = SttManager(
      sessionId: 's1',
      logger: _RecordingLogger(),
      resolveStt: () => null,
      environment: const {},
    );
    expect(missing.getProvider(), isNull);
    await expectLater(
      missing.transcribe(Uint8List(2), 'audio/pcm'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'STT not configured',
        ),
      ),
    );
  });

  test(
    'debug persistence failures warn but do not fail transcription',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'tinyrack-stt-manager-',
      );
      try {
        final blockingFile = File(p.join(temporary.path, 'not-a-directory'));
        await blockingFile.writeAsString('x');
        final logger = _RecordingLogger();
        final provider = _FakeSttProvider([
          const TranscriptionResult(text: 'still works'),
        ]);
        final manager = SttManager(
          sessionId: 's1',
          logger: logger,
          resolveStt: () => provider,
          debugPersister: SttDebugAudioPersister(
            debugDirectory: blockingFile.path,
          ),
          environment: const {},
        );

        final result = await manager.transcribe(
          Uint8List(2),
          'audio/pcm;rate=24000',
        );

        expect(result.text, 'still works');
        expect(logger.warningMessages, ['Failed to persist debug audio']);
      } finally {
        await temporary.delete(recursive: true);
      }
    },
  );

  test('resolves branded batch interval with validation', () {
    expect(resolveSttBatchCommitEverySeconds(const {}), 15);
    expect(
      resolveSttBatchCommitEverySeconds(const {
        'TINYRACK_STT_BATCH_COMMIT_EVERY_SECONDS': '1.5',
      }),
      1.5,
    );
    expect(
      resolveSttBatchCommitEverySeconds(const {
        'TINYRACK_STT_BATCH_COMMIT_EVERY_SECONDS': '0',
      }),
      0,
    );
    for (final invalid in ['-1', 'NaN', 'Infinity', 'bad']) {
      expect(
        resolveSttBatchCommitEverySeconds({
          'TINYRACK_STT_BATCH_COMMIT_EVERY_SECONDS': invalid,
        }),
        15,
      );
    }
  });

  test('cleanup remains a safe no-op extension point', () {
    final manager = SttManager(
      sessionId: 's1',
      logger: _RecordingLogger(),
      resolveStt: () => null,
      environment: const {},
    );
    expect(manager.cleanup, returnsNormally);
  });

  test('constructor resolves process defaults when overrides are omitted', () {
    final manager = SttManager(
      sessionId: 's1',
      logger: _RecordingLogger(),
      resolveStt: () => null,
    );
    expect(manager.cleanup, returnsNormally);
  });
}

final class _FakeSttProvider implements SpeechToTextProvider {
  _FakeSttProvider(
    this.results, {
    this.partialTranscript,
    this.commitError,
    this.transcriptBeforeCommit = false,
  }) : session = _FakeSttSession(
         results,
         partialTranscript: partialTranscript,
         commitError: commitError,
         transcriptBeforeCommit: transcriptBeforeCommit,
       );

  final List<TranscriptionResult> results;
  final String? partialTranscript;
  final Object? commitError;
  final bool transcriptBeforeCommit;
  final _FakeSttSession session;
  SpeechSessionParameters? parameters;

  @override
  String get id => 'fake';

  @override
  StreamingTranscriptionSession createSession(
    SpeechSessionParameters parameters,
  ) {
    this.parameters = parameters;
    return session;
  }
}

final class _FakeSttSession implements StreamingTranscriptionSession {
  _FakeSttSession(
    this.results, {
    this.partialTranscript,
    this.commitError,
    this.transcriptBeforeCommit = false,
  });

  final List<TranscriptionResult> results;
  final String? partialTranscript;
  final Object? commitError;
  final bool transcriptBeforeCommit;
  final StreamController<StreamingTranscriptionCommittedEvent> _committed =
      StreamController.broadcast(sync: true);
  final StreamController<StreamingTranscriptionEvent> _transcripts =
      StreamController.broadcast(sync: true);
  final StreamController<Object?> _errors = StreamController.broadcast(
    sync: true,
  );
  final List<Uint8List> appended = [];
  int connectCalls = 0;
  int commitCalls = 0;
  int clearCalls = 0;
  int closeCalls = 0;
  String? _previousSegmentId;

  @override
  int get requiredSampleRate => 24000;

  @override
  Stream<StreamingTranscriptionCommittedEvent> get committedEvents =>
      _committed.stream;

  @override
  Stream<StreamingTranscriptionEvent> get transcriptEvents =>
      _transcripts.stream;

  @override
  Stream<Object?> get errors => _errors.stream;

  @override
  Future<void> connect() async {
    connectCalls += 1;
  }

  @override
  void appendPcm16(List<int> pcm16le) {
    appended.add(Uint8List.fromList(pcm16le));
  }

  @override
  void commit() {
    commitCalls += 1;
    if (commitError != null) {
      _errors.add(commitError);
      return;
    }
    final segmentId = 'seg-$commitCalls';
    final index = commitCalls - 1;
    if (index < results.length) {
      final result = results[index];
      final transcript = StreamingTranscriptionEvent(
        segmentId: segmentId,
        transcript: result.text,
        isFinal: true,
        language: result.language,
        logprobs: result.logprobs,
        avgLogprob: result.avgLogprob,
        isLowConfidence: result.isLowConfidence,
      );
      if (transcriptBeforeCommit) _transcripts.add(transcript);
      _committed.add(
        StreamingTranscriptionCommittedEvent(
          segmentId: segmentId,
          previousSegmentId: _previousSegmentId,
        ),
      );
      if (!transcriptBeforeCommit) _transcripts.add(transcript);
    } else if (partialTranscript != null) {
      _committed.add(
        StreamingTranscriptionCommittedEvent(
          segmentId: segmentId,
          previousSegmentId: _previousSegmentId,
        ),
      );
      _transcripts.add(
        StreamingTranscriptionEvent(
          segmentId: segmentId,
          transcript: partialTranscript!,
          isFinal: false,
        ),
      );
    } else {
      _committed.add(
        StreamingTranscriptionCommittedEvent(
          segmentId: segmentId,
          previousSegmentId: _previousSegmentId,
        ),
      );
    }
    _previousSegmentId = segmentId;
  }

  @override
  void clear() {
    clearCalls += 1;
  }

  @override
  void close() {
    closeCalls += 1;
  }
}

final class _RecordingLogger implements SpeechLogger {
  final List<String> warningMessages = [];
  final List<Map<String, Object?>> warningFields = [];

  @override
  SpeechLogger child(Map<String, Object?> context) => this;

  @override
  void debug(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void error(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void info(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void warning(String message, {Map<String, Object?> fields = const {}}) {
    warningMessages.add(message);
    warningFields.add(fields);
  }
}

Uint8List _pcm16(List<int> samples) {
  final output = Uint8List(samples.length * 2);
  final bytes = ByteData.sublistView(output);
  for (var index = 0; index < samples.length; index += 1) {
    bytes.setInt16(index * 2, samples[index], Endian.little);
  }
  return output;
}

Uint8List _wav(Uint8List pcm, {required int sampleRate}) {
  final output = Uint8List(44 + pcm.length);
  final bytes = ByteData.sublistView(output);
  output.setRange(0, 4, 'RIFF'.codeUnits);
  bytes.setUint32(4, 36 + pcm.length, Endian.little);
  output.setRange(8, 12, 'WAVE'.codeUnits);
  output.setRange(12, 16, 'fmt '.codeUnits);
  bytes
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  output.setRange(36, 40, 'data'.codeUnits);
  bytes.setUint32(40, pcm.length, Endian.little);
  output.setRange(44, output.length, pcm);
  return output;
}
