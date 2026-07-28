import 'dart:async';

import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:agent_daemon/src/voice/speech_types.dart';
import 'package:test/test.dart';

void main() {
  test('transcription result round-trips every frozen confidence field', () {
    const result = TranscriptionResult(
      text: 'hello',
      language: 'en',
      duration: 1.25,
      logprobs: [
        LogprobToken(token: 'hello', logprob: -0.25, bytes: [104, 105.5]),
      ],
      avgLogprob: -0.25,
      isLowConfidence: false,
    );

    expect(result.toJson(), {
      'text': 'hello',
      'language': 'en',
      'duration': 1.25,
      'logprobs': [
        {
          'token': 'hello',
          'logprob': -0.25,
          'bytes': [104, 105.5],
        },
      ],
      'avgLogprob': -0.25,
      'isLowConfidence': false,
    });
    expect(
      TranscriptionResult.fromJson(result.toJson()).toJson(),
      result.toJson(),
    );
  });

  test('transcription result preserves omitted optional fields', () {
    const result = TranscriptionResult(text: '');
    expect(result.toJson(), {'text': ''});
    expect(TranscriptionResult.fromJson(result.toJson()).toJson(), {
      'text': '',
    });
  });

  test('streaming event models preserve segment ordering and metadata', () {
    const committed = StreamingTranscriptionCommittedEvent(
      segmentId: 'segment-2',
      previousSegmentId: 'segment-1',
    );
    const transcript = StreamingTranscriptionEvent(
      segmentId: 'segment-2',
      transcript: 'partial',
      isFinal: false,
      language: 'ko',
      logprobs: [LogprobToken(token: 'part', logprob: -1)],
      avgLogprob: -1,
      isLowConfidence: true,
    );

    expect(
      StreamingTranscriptionCommittedEvent.fromJson(
        committed.toJson(),
      ).toJson(),
      committed.toJson(),
    );
    expect(
      StreamingTranscriptionEvent.fromJson(transcript.toJson()).toJson(),
      transcript.toJson(),
    );
    expect(
      const StreamingTranscriptionCommittedEvent(
        segmentId: 'first',
        previousSegmentId: null,
      ).toJson(),
      {'segmentId': 'first', 'previousSegmentId': null},
    );
  });

  test('speech model boundaries reject malformed values', () {
    expect(
      () => LogprobToken.fromJson(const {'token': 'x', 'logprob': 'bad'}),
      throwsFormatException,
    );
    expect(
      () => LogprobToken.fromJson(const {
        'token': 'x',
        'logprob': -1,
        'bytes': [1, 'bad'],
      }),
      throwsFormatException,
    );
    expect(
      () => TranscriptionResult.fromJson(const {
        'text': 'x',
        'logprobs': [1],
      }),
      throwsFormatException,
    );
    expect(
      () => StreamingTranscriptionCommittedEvent.fromJson(const {
        'segmentId': 1,
        'previousSegmentId': null,
      }),
      throwsFormatException,
    );
    expect(
      () => StreamingTranscriptionEvent.fromJson(const {
        'segmentId': 's',
        'transcript': 'x',
        'isFinal': 'yes',
      }),
      throwsFormatException,
    );
  });

  test(
    'STT provider exposes PCM lifecycle and typed broadcast events',
    () async {
      final logger = _RecordingLogger();
      final provider = _FakeSttProvider('custom-stt');
      final session = provider.createSession(
        SpeechSessionParameters(
          logger: logger,
          language: 'en',
          prompt: 'names: Paseo, Tinyrack',
        ),
      );
      final committed = <StreamingTranscriptionCommittedEvent>[];
      final transcripts = <StreamingTranscriptionEvent>[];
    final errors = <Object?>[];
      final subscriptions = [
        session.committedEvents.listen(committed.add),
        session.transcriptEvents.listen(transcripts.add),
        session.errors.listen(errors.add),
      ];

      expect(provider.id, 'custom-stt');
      expect(provider.parameters?.logger, same(logger));
      expect(provider.parameters?.language, 'en');
      expect(provider.parameters?.prompt, 'names: Paseo, Tinyrack');
      expect(session.requiredSampleRate, 24000);

      await session.connect();
      session.appendPcm16(const [1, 2, 3, 4]);
      session.commit();
      session.clear();
      session.emitError(StateError('network'));
      await Future<void>.delayed(Duration.zero);
      session.close();

      expect(session.connectCalls, 1);
      expect(session.appended, [
        [1, 2, 3, 4],
      ]);
      expect(session.commitCalls, 1);
      expect(session.clearCalls, 1);
      expect(session.closeCalls, 1);
      expect(committed.single.toJson(), {
        'segmentId': 'segment-1',
        'previousSegmentId': null,
      });
      expect(transcripts.single.toJson(), {
        'segmentId': 'segment-1',
        'transcript': 'hello',
        'isFinal': true,
      });
      expect(errors.single, isA<StateError>());

      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      await session.dispose();
    },
  );

  test('speech stream destruction is asynchronous and idempotent', () async {
    var destroys = 0;
    final result = SpeechStreamResult(
      stream: const Stream.empty(),
      format: 'mp3',
      onDestroy: () async {
        await Future<void>.delayed(Duration.zero);
        destroys += 1;
      },
    );

    expect(result.destroyed, isFalse);
    await result.destroy();
    await result.destroy();

    expect(result.destroyed, isTrue);
    expect(destroys, 1);
  });

  test('requested speech providers match the frozen schema', () {
    const providers = RequestedSpeechProviders(
      dictationStt: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: false,
        enabled: true,
      ),
      voiceTurnDetection: RequestedSpeechProvider(
        provider: SpeechProviderId.local,
        explicit: true,
      ),
      voiceStt: RequestedSpeechProvider(
        provider: SpeechProviderId.openai,
        explicit: true,
        enabled: false,
      ),
      voiceTts: RequestedSpeechProvider(
        provider: SpeechProviderId.openai,
        explicit: false,
        enabled: true,
      ),
    );

    expect(providers.toJson(), {
      'dictationStt': {'provider': 'local', 'explicit': false, 'enabled': true},
      'voiceTurnDetection': {'provider': 'local', 'explicit': true},
      'voiceStt': {'provider': 'openai', 'explicit': true, 'enabled': false},
      'voiceTts': {'provider': 'openai', 'explicit': false, 'enabled': true},
    });
    expect(
      RequestedSpeechProviders.fromJson(providers.toJson()).toJson(),
      providers.toJson(),
    );
  });

  test(
    'requested provider boundaries reject unknown and incomplete values',
    () {
      expect(
        () => RequestedSpeechProvider.fromJson(const {
          'provider': 'custom',
          'explicit': true,
        }),
        throwsFormatException,
      );
      expect(
        () => RequestedSpeechProvider.fromJson(const {
          'provider': 'local',
          'explicit': 'yes',
        }),
        throwsFormatException,
      );
      expect(
        () => RequestedSpeechProviders.fromJson(const {
          'dictationStt': {'provider': 'local', 'explicit': true},
        }),
        throwsFormatException,
      );
    },
  );

  test('null speech logger supports child and all log levels', () {
    const logger = NullSpeechLogger();
    final child = logger.child(const {'component': 'stt'});

    expect(child, same(logger));
    child.debug('debug');
    child.info('info');
    child.warning('warning');
    child.error('error');
  });
}

final class _RecordingLogger implements SpeechLogger {
  @override
  SpeechLogger child(Map<String, Object?> context) => this;

  @override
  void debug(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void error(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void info(String message, {Map<String, Object?> fields = const {}}) {}

  @override
  void warning(String message, {Map<String, Object?> fields = const {}}) {}
}

final class _FakeSttProvider implements SpeechToTextProvider {
  _FakeSttProvider(this.id);

  @override
  final String id;
  SpeechSessionParameters? parameters;

  @override
  _FakeTranscriptionSession createSession(SpeechSessionParameters parameters) {
    this.parameters = parameters;
    return _FakeTranscriptionSession();
  }
}

final class _FakeTranscriptionSession implements StreamingTranscriptionSession {
  final StreamController<StreamingTranscriptionCommittedEvent> _committed =
      StreamController.broadcast();
  final StreamController<StreamingTranscriptionEvent> _transcripts =
      StreamController.broadcast();
  final StreamController<Object?> _errors = StreamController.broadcast();

  int connectCalls = 0;
  int commitCalls = 0;
  int clearCalls = 0;
  int closeCalls = 0;
  final List<List<int>> appended = [];

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
    appended.add(List<int>.from(pcm16le));
  }

  @override
  void commit() {
    commitCalls += 1;
    _committed.add(
      const StreamingTranscriptionCommittedEvent(
        segmentId: 'segment-1',
        previousSegmentId: null,
      ),
    );
    _transcripts.add(
      const StreamingTranscriptionEvent(
        segmentId: 'segment-1',
        transcript: 'hello',
        isFinal: true,
      ),
    );
  }

  @override
  void clear() {
    clearCalls += 1;
  }

  @override
  void close() {
    closeCalls += 1;
  }

  void emitError(Object error) {
    _errors.add(error);
  }

  Future<void> dispose() async {
    await Future.wait([
      _committed.close(),
      _transcripts.close(),
      _errors.close(),
    ]);
  }
}
