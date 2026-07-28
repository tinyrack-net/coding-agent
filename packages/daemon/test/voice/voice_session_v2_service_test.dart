import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_daemon/src/server/connection.dart';
import 'package:agent_daemon/src/server/voice_session_v2_service.dart';
import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:agent_daemon/src/voice/turn_detection_provider.dart';
import 'package:agent_daemon/src/voice/voice_bridge_registry.dart';
import 'package:agent_daemon/src/voice/voice_session.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

const _agentId = '00000000-0000-4000-8000-000000000001';
const _pcmFormat = 'audio/pcm;rate=16000;bits=16';

void main() {
  test('uses process defaults when voice runtime paths are omitted', () async {
    final service = VoiceSessionV2Service(
      createHost: (_) => _FakeHost(),
      resolveTts: () => null,
      resolveStt: () => null,
      resolveTurnDetection: () => null,
      voiceBridge: VoiceBridgeRegistry(),
    );

    expect(service.activeSessionCount, 0);
    await service.dispose();
  });

  test('ignores messages outside the frozen voice session surface', () async {
    final harness = _Harness();

    expect(
      await harness.service.handle(harness.connection, {
        'type': 'agent_create_request',
      }),
      isFalse,
    );
    expect(harness.service.activeSessionCount, 0);

    await harness.dispose();
  });

  test('reports derived readiness before loading or mutating an agent', () async {
    final harness = _Harness(speechReady: false);

    expect(
      await harness.service.handle(
        harness.connection,
        const SetVoiceModeMessage(
          enabled: true,
          agentId: _agentId,
          requestId: 'voice-1',
        ).toJson(),
      ),
      isTrue,
    );

    expect(harness.host.loadedIds, isEmpty);
    expect(harness.host.reloads, isEmpty);
    expect(harness.message('set_voice_mode_response')['payload'], {
      'requestId': 'voice-1',
      'enabled': false,
      'agentId': null,
      'accepted': false,
      'error':
          'Realtime voice is unavailable: turn-detection service is not ready.',
      'reasonCode': 'turn_detection_unavailable',
      'retryable': false,
      'missingModelIds': <Object?>[],
    });

    await harness.dispose();
  });

  test(
    'routes every frozen voice message and cleans connection state',
    () async {
      final harness = _Harness();

      await harness.service.handle(
        harness.connection,
        const SetVoiceModeMessage(
          enabled: true,
          agentId: _agentId,
          requestId: 'voice-2',
        ).toJson(),
      );
      expect(
        harness.message('set_voice_mode_response')['payload'],
        containsPair('accepted', true),
      );
      expect(
        harness.host.reloads.single.systemPrompt,
        contains('<paseo_voice_mode>'),
      );

      await harness.service.handle(
        harness.connection,
        VoiceAudioChunkMessage(
          audio: base64Encode(Uint8List(128)),
          format: _pcmFormat,
          isLast: false,
        ).toJson(),
      );
      expect(harness.detector.appendedBytes, greaterThan(0));

      await harness.service.handle(
        harness.connection,
        const AbortRequestMessage().toJson(),
      );
      await harness.service.handle(
        harness.connection,
        const AudioPlayedMessage(id: 'missing-audio').toJson(),
      );
      await harness.service.handle(
        harness.connection,
        const DictationStreamStartMessage(
          dictationId: 'dictation-1',
          format: _pcmFormat,
        ).toJson(),
      );
      await harness.service.handle(
        harness.connection,
        DictationStreamChunkMessage(
          dictationId: 'dictation-1',
          seq: 0,
          audio: base64Encode(Uint8List(128)),
          format: _pcmFormat,
        ).toJson(),
      );
      await harness.service.handle(
        harness.connection,
        const DictationStreamFinishMessage(
          dictationId: 'dictation-1',
          finalSeq: 0,
        ).toJson(),
      );
      await harness.service.handle(
        harness.connection,
        const DictationStreamCancelMessage(dictationId: 'dictation-1').toJson(),
      );

      expect(harness.message('dictation_stream_ack'), isNotEmpty);
      expect(harness.message('dictation_stream_finish_accepted'), isNotEmpty);
      expect(harness.service.activeSessionCount, 1);

      await harness.service.onConnectionClosed(harness.connection);

      expect(harness.service.activeSessionCount, 0);
      expect(harness.detector.closed, isTrue);
      expect(harness.sttSessions, isNotEmpty);
      expect(harness.sttSessions.every((session) => session.closed), isTrue);
      expect(
        harness.host.reloads.last.systemPrompt,
        allOf(startsWith('Base prompt'), contains('voice mode is now off')),
      );

      await harness.dispose();
    },
  );

  test(
    'keeps malformed boundaries fatal and contains runtime failures',
    () async {
      final harness = _Harness();

      expect(
        () => harness.service.handle(harness.connection, {
          'type': SetVoiceModeMessage.type,
          'enabled': 'yes',
        }),
        throwsFormatException,
      );

      harness.host.reloadError = StateError('reload failed');
      expect(
        await harness.service.handle(
          harness.connection,
          const SetVoiceModeMessage(enabled: true, agentId: _agentId).toJson(),
        ),
        isTrue,
      );
      expect(
        harness.message('activity_log')['payload'],
        containsPair('content', 'Error: reload failed'),
      );

      await harness.dispose();
    },
  );

  test('isolates sessions and dispose awaits in-flight cleanup', () async {
    final harness = _Harness();
    final second = harness.createConnection('voice-connection-2');

    await harness.service.handle(
      harness.connection,
      const SetVoiceModeMessage(
        enabled: true,
        agentId: _agentId,
        requestId: 'first',
      ).toJson(),
    );
    await harness.service.handle(
      second,
      const SetVoiceModeMessage(
        enabled: true,
        agentId: _agentId,
        requestId: 'second',
      ).toJson(),
    );
    expect(harness.service.activeSessionCount, 2);

    final cleanup = harness.service.onConnectionClosed(harness.connection);
    await harness.service.dispose();
    await cleanup;

    expect(harness.service.activeSessionCount, 0);
    expect(harness.host.reloads, hasLength(4));
  });
}

final class _Harness {
  _Harness({bool speechReady = true})
    : host = _FakeHost(),
      detector = _FakeDetector(),
      sttSessions = [],
      sent = [] {
    connection = createConnection('voice-connection-1');
    final detectorProvider = _FakeDetectorProvider(detector);
    final sttProvider = _FakeSttProvider(sttSessions);
    service = VoiceSessionV2Service(
      createHost: (connection) => _ConnectionHost(host, connection),
      resolveTts: () => speechReady ? _FakeTtsProvider() : null,
      resolveStt: () => speechReady ? sttProvider : null,
      resolveTurnDetection: () => speechReady ? detectorProvider : null,
      voiceBridge: VoiceBridgeRegistry(),
      environment: const {},
      cwd: '.',
    );
  }

  final _FakeHost host;
  final _FakeDetector detector;
  final List<_FakeSttSession> sttSessions;
  final List<Map<String, Object?>> sent;
  late final VoiceSessionV2Service service;
  late final Connection connection;

  Connection createConnection(String id) => Connection.external(
    frames: const Stream.empty(),
    send: (value) {
      if (value is String) {
        sent.add((jsonDecode(value) as Map).cast<String, Object?>());
      }
    },
    close: (_, __) {},
    id: id,
    transport: 'direct',
    externalSessionKey: null,
    relayConnectionId: null,
  );

  Map<String, Object?> message(String type) => sent
      .map((envelope) => envelope['message'])
      .whereType<Map>()
      .map((message) => message.cast<String, Object?>())
      .lastWhere((message) => message['type'] == type);

  Future<void> dispose() => service.dispose();
}

final class _FakeHost implements VoiceSessionHost {
  final List<String> loadedIds = [];
  final List<VoiceSessionAgentOverrides> reloads = [];
  Object? reloadError;

  @override
  void emit(Map<String, Object?> message) {
    throw StateError('Host must be wrapped for its connection');
  }

  @override
  Future<VoiceSessionAgent> loadAgent(String agentId) async {
    loadedIds.add(agentId);
    return const VoiceSessionAgent(id: _agentId, systemPrompt: 'Base prompt');
  }

  @override
  Future<VoiceSessionAgent> reloadAgentSession(
    String agentId,
    VoiceSessionAgentOverrides overrides,
  ) async {
    if (reloadError case final error?) throw error;
    reloads.add(overrides);
    return VoiceSessionAgent(id: agentId, systemPrompt: overrides.systemPrompt);
  }

  @override
  Future<void> sendSpokenInput(String agentId, String text) async {}

  @override
  Future<void> interruptAgentIfRunning(String agentId) async {}

  @override
  bool hasActiveAgentRun(String? agentId) => false;
}

final class _ConnectionHost implements VoiceSessionHost {
  const _ConnectionHost(this.delegate, this.connection);

  final _FakeHost delegate;
  final Connection connection;

  @override
  void emit(Map<String, Object?> message) =>
      connection.sendJson({'type': 'session', 'message': message});

  @override
  Future<VoiceSessionAgent> loadAgent(String agentId) =>
      delegate.loadAgent(agentId);

  @override
  Future<VoiceSessionAgent> reloadAgentSession(
    String agentId,
    VoiceSessionAgentOverrides overrides,
  ) => delegate.reloadAgentSession(agentId, overrides);

  @override
  Future<void> sendSpokenInput(String agentId, String text) =>
      delegate.sendSpokenInput(agentId, text);

  @override
  Future<void> interruptAgentIfRunning(String agentId) =>
      delegate.interruptAgentIfRunning(agentId);

  @override
  bool hasActiveAgentRun(String? agentId) =>
      delegate.hasActiveAgentRun(agentId);
}

final class _FakeDetectorProvider implements TurnDetectionProvider {
  const _FakeDetectorProvider(this.session);

  final _FakeDetector session;

  @override
  String get id => 'fake-vad';

  @override
  TurnDetectionSession createSession(
    TurnDetectionSessionParameters parameters,
  ) => session;
}

final class _FakeDetector implements TurnDetectionSession {
  final _started = StreamController<void>.broadcast(sync: true);
  final _stopped = StreamController<void>.broadcast(sync: true);
  final _errors = StreamController<Object?>.broadcast(sync: true);
  int appendedBytes = 0;
  bool closed = false;

  @override
  int get requiredSampleRate => 16000;

  @override
  Stream<void> get speechStartedEvents => _started.stream;

  @override
  Stream<void> get speechStoppedEvents => _stopped.stream;

  @override
  Stream<Object?> get errors => _errors.stream;

  @override
  Future<void> connect() async {}

  @override
  void appendPcm16(Uint8List pcm16le) => appendedBytes += pcm16le.length;

  @override
  void flush() {}

  @override
  void reset() {}

  @override
  void close() => closed = true;
}

final class _FakeSttProvider implements SpeechToTextProvider {
  const _FakeSttProvider(this.sessions);

  final List<_FakeSttSession> sessions;

  @override
  String get id => 'fake-stt';

  @override
  StreamingTranscriptionSession createSession(
    SpeechSessionParameters parameters,
  ) {
    final session = _FakeSttSession();
    sessions.add(session);
    return session;
  }
}

final class _FakeSttSession implements StreamingTranscriptionSession {
  final _committed =
      StreamController<StreamingTranscriptionCommittedEvent>.broadcast(
        sync: true,
      );
  final _transcripts = StreamController<StreamingTranscriptionEvent>.broadcast(
    sync: true,
  );
  final _errors = StreamController<Object?>.broadcast(sync: true);
  bool closed = false;

  @override
  int get requiredSampleRate => 16000;

  @override
  Stream<StreamingTranscriptionCommittedEvent> get committedEvents =>
      _committed.stream;

  @override
  Stream<StreamingTranscriptionEvent> get transcriptEvents =>
      _transcripts.stream;

  @override
  Stream<Object?> get errors => _errors.stream;

  @override
  Future<void> connect() async {}

  @override
  void appendPcm16(List<int> pcm16le) {}

  @override
  void commit() {}

  @override
  void clear() {}

  @override
  void close() => closed = true;
}

final class _FakeTtsProvider implements TextToSpeechProvider {
  @override
  Future<SpeechStreamResult> synthesizeSpeech(String text) async =>
      SpeechStreamResult(
        stream: Stream<List<int>>.value([1, 2, 3]),
        format: 'audio/mpeg',
      );
}
