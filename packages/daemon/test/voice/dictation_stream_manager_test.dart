import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/src/voice/dictation_debug.dart';
import 'package:agent_daemon/src/voice/dictation_stream_manager.dart';
import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('dictation stream manager', () {
    test('starts provider with language and frozen prompt', () async {
      final harness = _Harness(language: 'pt');
      await harness.start('d1');

      expect(harness.session.connected, isTrue);
      expect(harness.provider.lastLanguage, 'pt');
      expect(
        harness.provider.lastPrompt,
        startsWith('Transcribe only what the speaker says.'),
      );
      expect(harness.messages.single, {
        'type': DictationStreamAckMessage.type,
        'payload': {'dictationId': 'd1', 'ackSeq': -1},
      });
    });

    test('reports unavailable, factory, and connection failures', () async {
      final unavailable = _Harness(providerAvailable: false);
      await unavailable.start('missing');
      expect(_message(unavailable.messages, 'dictation_stream_error'), {
        'type': 'dictation_stream_error',
        'payload': {
          'dictationId': 'missing',
          'error': 'Dictation STT not configured',
          'retryable': false,
        },
      });

      final factory = _Harness(throwOnCreate: true);
      await factory.start('factory');
      expect(
        _payload(factory.messages, 'dictation_stream_error')['retryable'],
        isFalse,
      );

      final connection = _Harness();
      connection.session.throwOnConnect = true;
      await connection.start('connect');
      expect(
        _payload(connection.messages, 'dictation_stream_error')['retryable'],
        isTrue,
      );
      expect(connection.session.closed, isTrue);
    });

    test(
      'forwards out-of-order chunks losslessly and acknowledges gaps',
      () async {
        final harness = _Harness();
        await harness.start('ordered');
        await harness.chunk('ordered', 1, _pcm(2000, 4));
        expect(_acks(harness.messages), [-1, -1]);
        expect(harness.session.appended, isEmpty);

        await harness.chunk('ordered', 0, _pcm(1000, 4));
        expect(_acks(harness.messages), [-1, -1, 1]);
        expect(harness.session.appended, [_pcm(1000, 4), _pcm(2000, 4)]);

        await harness.chunk('ordered', 0, _pcm(3000, 4));
        expect(_acks(harness.messages).last, 1);
        expect(harness.session.appended, hasLength(2));
      },
    );

    test('resamples input and rejects mismatched formats', () async {
      final resampled = _Harness(requiredSampleRate: 8000);
      await resampled.start('resample', rate: 16000);
      await resampled.chunk(
        'resample',
        0,
        _pcm(1000, 160),
        format: 'audio/pcm;rate=16000;bits=16',
      );
      expect(
        resampled.session.appended.single.length,
        lessThan(_pcm(1000, 160).length),
      );

      final mismatch = _Harness();
      await mismatch.start('mismatch');
      await mismatch.chunk(
        'mismatch',
        0,
        _pcm(1000, 4),
        format: 'audio/pcm;rate=8000;bits=16',
      );
      await mismatch.settle();
      expect(
        _payload(mismatch.messages, 'dictation_stream_error')['retryable'],
        isFalse,
      );
      expect(mismatch.session.closed, isTrue);
    });

    test('auto-commits speech and clears silence windows', () async {
      final speech = _Harness(autoCommitSeconds: 0.001);
      await speech.start('speech');
      await speech.chunk('speech', 0, _pcm(2000, 32));
      expect(speech.session.commitCalls, 1);

      final silence = _Harness(autoCommitSeconds: 0.001);
      await silence.start('silence');
      await silence.chunk('silence', 0, _pcm(0, 32));
      expect(silence.session.commitCalls, 0);
      expect(silence.session.clearCalls, 1);
    });

    test('assembles committed final transcript in commit order', () async {
      final harness = _Harness(autoCommitSeconds: 1);
      await harness.start('segmented', rate: 24000);
      await harness.chunk('segmented', 0, _pcm(2000, 24000));
      expect(harness.session.commitCalls, 1);
      harness.session
        ..emitCommitted('seg-1')
        ..emitTranscript('seg-1', 'hello', true);

      await harness.chunk('segmented', 1, _pcm(2000, 12000));
      await harness.manager.handleFinish('segmented', 1);
      expect(harness.session.commitCalls, 2);
      harness.session
        ..emitCommitted('seg-2')
        ..emitTranscript('seg-2', 'world', true);
      await harness.settle();

      expect(
        _payload(harness.messages, 'dictation_stream_final')['text'],
        'hello world',
      );
      expect(harness.session.closed, isTrue);
      expect(
        harness.messages
            .where((message) => message['type'] == 'dictation_stream_partial')
            .map((message) => (message['payload']! as Map)['text']),
        ['hello', 'hello world'],
      );
    });

    test('tolerates buffer-too-small after finish', () async {
      final harness = _Harness(finalTimeout: const Duration(seconds: 5));
      await harness.start('small', rate: 24000);
      await harness.chunk('small', 0, _pcm(2000, 2400));
      harness.session.emitTranscript('seg-1', 'hello world', true);
      await harness.manager.handleFinish('small', 0);
      harness.session.emitError(
        StateError('Error committing input audio buffer: buffer too small'),
      );
      await harness.settle();
      expect(
        harness.messages.where(
          (message) => message['type'] == 'dictation_stream_error',
        ),
        isEmpty,
      );
      expect(
        _payload(harness.messages, 'dictation_stream_final')['text'],
        'hello world',
      );
    });

    test('fails fast when finish reports audio that never arrived', () async {
      final harness = _Harness();
      await harness.start('empty');
      await harness.manager.handleFinish('empty', 0);
      expect(
        _payload(harness.messages, 'dictation_stream_error')['error'],
        contains('no audio chunks were received'),
      );
      expect(harness.session.closed, isTrue);
    });

    test(
      'adapts timeout for segments, pending audio, and missing seq',
      () async {
        final harness = _Harness(finalTimeout: const Duration(seconds: 5));
        await harness.start('timeout', rate: 24000);
        await harness.chunk('timeout', 0, _pcm(2000, 2400));
        harness.session
          ..emitCommitted('seg-pending')
          ..emitTranscript('dangling', 'hel', false);
        await harness.manager.handleFinish('timeout', 2);

        final timeoutMs =
            _payload(
                  harness.messages,
                  'dictation_stream_finish_accepted',
                )['timeoutMs']
                as int;
        expect(timeoutMs, greaterThan(35000));
        expect(harness.timeout.delay.inMilliseconds, timeoutMs);
      },
    );

    test('timeout emits retryable error and cleans up', () async {
      final harness = _Harness(finalTimeout: const Duration(seconds: 5));
      await harness.start('timeout');
      await harness.chunk('timeout', 0, _pcm(2000, 100));
      await harness.manager.handleFinish('timeout', 0);
      harness.timeout.fire();
      await harness.settle();
      expect(
        _payload(harness.messages, 'dictation_stream_error'),
        containsPair('error', 'Timed out waiting for final transcription'),
      );
      expect(harness.session.closed, isTrue);
    });

    test('drops a dangling non-final transcript after silence tail', () async {
      final harness = _Harness();
      await harness.start('tail', rate: 24000);
      await harness.chunk('tail', 0, _pcm(2000, 2400));
      harness.session
        ..emitCommitted('seg-1')
        ..emitTranscript('seg-1', 'hello', true);
      await harness.chunk('tail', 1, _pcm(0, 2400));
      harness.session.emitTranscript('dangling', '', false);
      await harness.manager.handleFinish('tail', 1);
      await harness.settle();
      expect(harness.session.clearCalls, greaterThan(0));
      expect(
        _payload(harness.messages, 'dictation_stream_final')['text'],
        'hello',
      );
    });

    test('append and commit failures report errors and close stream', () async {
      final append = _Harness();
      await append.start('append');
      append.session.throwOnAppend = true;
      await append.chunk('append', 0, _pcm(1000, 4));
      await append.settle();
      expect(
        _payload(append.messages, 'dictation_stream_error')['retryable'],
        isTrue,
      );

      final commit = _Harness();
      await commit.start('commit');
      await commit.chunk('commit', 0, _pcm(1000, 4));
      commit.session.throwOnCommit = true;
      await commit.manager.handleFinish('commit', 0);
      await commit.settle();
      expect(
        _payload(commit.messages, 'dictation_stream_error')['retryable'],
        isTrue,
      );
    });

    test('cancel, replacement, and cleanup close active sessions', () async {
      final harness = _Harness();
      await harness.start('cancel');
      harness.manager.handleCancel('cancel');
      expect(harness.session.closed, isTrue);

      final replacement = _Harness();
      await replacement.start('same');
      final first = replacement.session;
      replacement.replaceSession();
      await replacement.start('same');
      expect(first.closed, isTrue);
      replacement.manager.cleanupAll();
      expect(replacement.session.closed, isTrue);
    });

    test('unknown chunk and finish emit retryable errors', () async {
      final harness = _Harness();
      await harness.chunk('unknown', 0, _pcm(1, 1));
      await harness.manager.handleFinish('unknown', 0);
      expect(
        harness.messages.where(
          (message) => message['type'] == 'dictation_stream_error',
        ),
        hasLength(2),
      );
    });

    test('session errors and malformed base64 clean up the stream', () async {
      final sessionError = _Harness();
      await sessionError.start('session-error');
      sessionError.session.emitError(StateError('transport failed'));
      await sessionError.settle();
      expect(
        _payload(sessionError.messages, 'dictation_stream_error')['error'],
        contains('transport failed'),
      );
      expect(sessionError.session.closed, isTrue);

      final malformed = _Harness();
      await malformed.start('malformed');
      await malformed.manager.handleChunk(
        dictationId: 'malformed',
        seq: 0,
        audioBase64: '*not-base64*',
        format: 'audio/pcm;rate=24000;bits=16',
      );
      expect(
        _payload(malformed.messages, 'dictation_stream_error')['retryable'],
        isFalse,
      );
      expect(malformed.session.closed, isTrue);
    });

    test('silence-only stream finalizes with empty text', () async {
      final harness = _Harness();
      await harness.start('silence-final');
      await harness.chunk('silence-final', 0, _pcm(0, 2400));
      await harness.manager.handleFinish('silence-final', 0);
      await harness.settle();
      expect(_payload(harness.messages, 'dictation_stream_final')['text'], '');
    });

    test('production timeout can be scheduled and cancelled', () async {
      final harness = _Harness(
        useSystemTimeout: true,
        environment: const {
          'TINYRACK_DICTATION_AUTO_COMMIT_SECONDS': 'invalid',
        },
      );
      await harness.start('system-timeout');
      await harness.chunk('system-timeout', 0, _pcm(2000, 100));
      await harness.manager.handleFinish('system-timeout', 0);
      harness.manager.handleCancel('system-timeout');
      expect(harness.session.closed, isTrue);
    });

    test('debug capture annotates final and activity messages', () async {
      final temporary = await Directory.systemTemp.createTemp(
        'tinyrack-dictation-manager-debug-',
      );
      try {
        final harness = _Harness(
          environment: {'TINYRACK_DICTATION_DEBUG_AUDIO_DIR': temporary.path},
        );
        await harness.start('debug-final');
        await harness.chunk('debug-final', 0, _pcm(2000, 100));
        await harness.manager.handleFinish('debug-final', 0);
        harness.session
          ..emitCommitted('segment-1')
          ..emitTranscript('segment-1', 'captured', true);
        await harness.waitForMessage('dictation_stream_final');

        final finalPayload = _payload(
          harness.messages,
          'dictation_stream_final',
        );
        final path = finalPayload['debugRecordingPath']! as String;
        expect(
          (await File(path).readAsBytes()).take(4),
          orderedEquals('RIFF'.codeUnits),
        );
        expect(
          _payload(harness.messages, 'activity_log')['content'],
          'Saved dictation audio: $path',
        );
      } finally {
        await temporary.delete(recursive: true);
      }
    });
  });

  group('dictation debug audio', () {
    test('writes ordered chunks and a combined WAV in one folder', () async {
      final temporary = await Directory.systemTemp.createTemp(
        'tinyrack-dictation-debug-',
      );
      try {
        final logger = _RecordingLogger();
        final store = DictationDebugAudioStore(
          environment: {'TINYRACK_DICTATION_DEBUG_AUDIO_DIR': temporary.path},
          cwd: temporary.path,
          now: () => DateTime.utc(2026, 7, 29, 1, 2, 3, 456),
        );
        final writer = store.createChunkWriter(
          sessionId: 'session/1',
          dictationId: 'dictation:2',
          logger: logger,
        )!;
        await writer.writeChunk(2, Uint8List.fromList([1, 2]));
        final combined = await store.persist(
          Uint8List.fromList([82, 73, 70, 70]),
          const DictationDebugAudioMetadata(
            sessionId: 'session/1',
            dictationId: 'dictation:2',
            format: 'audio/wav',
          ),
          logger,
          chunkWriterFolder: writer.folder,
        );
        expect(
          p.basename(writer.folder),
          '2026-07-29T01-02-03-456Z_dictation_2',
        );
        expect(
          await File(p.join(writer.folder, 'chunk_000002.pcm')).readAsBytes(),
          [1, 2],
        );
        expect(p.basename(combined!), 'combined.wav');
        expect(logger.infoMessages, ['Dictation audio capture enabled']);
      } finally {
        await temporary.delete(recursive: true);
      }
    });

    test('disabled store does no filesystem work', () async {
      final store = DictationDebugAudioStore(
        environment: const {},
        cwd: Directory.current.path,
      );
      final logger = _RecordingLogger();
      expect(
        store.createChunkWriter(
          sessionId: 's',
          dictationId: 'd',
          logger: logger,
        ),
        isNull,
      );
      expect(
        await store.persist(
          Uint8List(0),
          const DictationDebugAudioMetadata(
            sessionId: 's',
            dictationId: 'd',
            format: 'audio/wav',
          ),
          logger,
        ),
        isNull,
      );
    });
  });
}

final class _Harness {
  _Harness({
    this.language = 'en',
    this.providerAvailable = true,
    this.throwOnCreate = false,
    int requiredSampleRate = 24000,
    double? autoCommitSeconds,
    Duration finalTimeout = defaultDictationFinalTimeout,
    this.useSystemTimeout = false,
    this.environment = const {'TINYRACK_DICTATION_DEBUG': 'false'},
  }) : session = _FakeSession(requiredSampleRate),
       _autoCommitSeconds = autoCommitSeconds,
       _finalTimeout = finalTimeout {
    provider = _FakeProvider(this);
    manager = _createManager();
  }

  final String language;
  final bool providerAvailable;
  final bool throwOnCreate;
  final double? _autoCommitSeconds;
  final Duration _finalTimeout;
  final bool useSystemTimeout;
  final Map<String, String> environment;
  late _FakeSession session;
  late final _FakeProvider provider;
  late final DictationStreamManager manager;
  final List<Map<String, Object?>> messages = [];
  late _ManualTimeout timeout;

  DictationStreamManager _createManager() {
    return DictationStreamManager(
      logger: const NullSpeechLogger(),
      emit: messages.add,
      sessionId: 'session-1',
      resolveStt: () => providerAvailable ? provider : null,
      language: language,
      autoCommitSeconds: _autoCommitSeconds,
      finalTimeout: _finalTimeout,
      environment: environment,
      scheduleTimeout: useSystemTimeout
          ? null
          : (delay, callback) {
              timeout = _ManualTimeout(delay, callback);
              return timeout;
            },
      createActivityId: useSystemTimeout ? null : () => 'activity-1',
      now: () => DateTime.utc(2026, 7, 29),
    );
  }

  Future<void> start(String id, {int rate = 24000}) =>
      manager.handleStart(id, 'audio/pcm;rate=$rate;bits=16');

  Future<void> chunk(String id, int seq, Uint8List bytes, {String? format}) {
    return manager.handleChunk(
      dictationId: id,
      seq: seq,
      audioBase64: base64Encode(bytes),
      format: format ?? 'audio/pcm;rate=24000;bits=16',
    );
  }

  void replaceSession() {
    session = _FakeSession(session.requiredSampleRate);
  }

  Future<void> settle() async {
    for (var index = 0; index < 6; index += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> waitForMessage(String type) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!messages.any((message) => message['type'] == type)) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Timed out waiting for $type');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }
}

final class _FakeProvider implements SpeechToTextProvider {
  _FakeProvider(this.harness);
  final _Harness harness;
  String? lastLanguage;
  String? lastPrompt;

  @override
  String get id => 'fake';

  @override
  StreamingTranscriptionSession createSession(
    SpeechSessionParameters parameters,
  ) {
    if (harness.throwOnCreate) throw StateError('create failed');
    lastLanguage = parameters.language;
    lastPrompt = parameters.prompt;
    return harness.session;
  }
}

final class _FakeSession implements StreamingTranscriptionSession {
  _FakeSession(this.requiredSampleRate);
  @override
  final int requiredSampleRate;
  final committed =
      StreamController<StreamingTranscriptionCommittedEvent>.broadcast(
        sync: true,
      );
  final transcripts = StreamController<StreamingTranscriptionEvent>.broadcast(
    sync: true,
  );
  final errorController = StreamController<Object?>.broadcast(sync: true);
  final List<Uint8List> appended = [];
  bool connected = false;
  bool closed = false;
  bool throwOnConnect = false;
  bool throwOnAppend = false;
  bool throwOnCommit = false;
  int commitCalls = 0;
  int clearCalls = 0;

  void emitCommitted(String segmentId) {
    committed.add(
      StreamingTranscriptionCommittedEvent(
        segmentId: segmentId,
        previousSegmentId: null,
      ),
    );
  }

  void emitTranscript(String segmentId, String transcript, bool isFinal) {
    transcripts.add(
      StreamingTranscriptionEvent(
        segmentId: segmentId,
        transcript: transcript,
        isFinal: isFinal,
      ),
    );
  }

  void emitError(Object error) => errorController.add(error);

  @override
  Stream<StreamingTranscriptionCommittedEvent> get committedEvents =>
      committed.stream;
  @override
  Stream<StreamingTranscriptionEvent> get transcriptEvents =>
      transcripts.stream;
  @override
  Stream<Object?> get errors => errorController.stream;

  @override
  Future<void> connect() async {
    if (throwOnConnect) throw StateError('connect failed');
    connected = true;
  }

  @override
  void appendPcm16(List<int> pcm16le) {
    if (throwOnAppend) throw StateError('append failed');
    appended.add(Uint8List.fromList(pcm16le));
  }

  @override
  void commit() {
    commitCalls += 1;
    if (throwOnCommit) throw StateError('commit failed');
  }

  @override
  void clear() => clearCalls += 1;
  @override
  void close() => closed = true;
}

final class _ManualTimeout implements DictationTimeoutHandle {
  _ManualTimeout(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  bool cancelled = false;
  void fire() {
    if (!cancelled) callback();
  }

  @override
  void cancel() => cancelled = true;
}

Uint8List _pcm(int sample, int count) {
  final output = Uint8List(count * 2);
  final bytes = ByteData.sublistView(output);
  for (var index = 0; index < count; index += 1) {
    bytes.setInt16(index * 2, sample, Endian.little);
  }
  return output;
}

Map<String, Object?> _message(
  List<Map<String, Object?>> messages,
  String type,
) => messages.firstWhere((message) => message['type'] == type);

Map<String, Object?> _payload(
  List<Map<String, Object?>> messages,
  String type,
) => _message(messages, type)['payload']! as Map<String, Object?>;

List<int> _acks(List<Map<String, Object?>> messages) => messages
    .where((message) => message['type'] == 'dictation_stream_ack')
    .map((message) => (message['payload']! as Map)['ackSeq']! as int)
    .toList();

final class _RecordingLogger implements SpeechLogger {
  final List<String> infoMessages = [];
  @override
  SpeechLogger child(Map<String, Object?> context) => this;
  @override
  void debug(String message, {Map<String, Object?> fields = const {}}) {}
  @override
  void error(String message, {Map<String, Object?> fields = const {}}) {}
  @override
  void info(String message, {Map<String, Object?> fields = const {}}) =>
      infoMessages.add(message);
  @override
  void warning(String message, {Map<String, Object?> fields = const {}}) {}
}
