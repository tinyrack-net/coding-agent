import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_daemon/src/voice/speech_provider.dart';
import 'package:agent_daemon/src/voice/turn_detection_provider.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _agentId = '00000000-0000-4000-8000-000000000002';

void main() {
  test('v2 WebSocket owns and cleans its frozen voice session', () async {
    final home = Directory.systemTemp.createTempSync('daemon-voice-session-');
    addTearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
    });
    await AgentStore(dataDir: home.path).save(
      const PersistedAgent(
        summary: AgentSummary(
          agentId: _agentId,
          title: 'Voice E2E',
          cwd: '.',
          provider: 'fake',
          model: 'fake-model',
          mode: AgentMode.normal,
          runState: AgentRunState.idle,
          createdAtMs: 1,
          systemPrompt: 'Base prompt',
        ),
        archived: false,
        epoch: 1,
        lastSeq: 0,
        items: [],
      ),
    );
    final client = _VoiceClient();
    final detector = _TurnProvider();
    final stt = _SttProvider();
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: home.path),
      dataDir: home.path,
      host: '127.0.0.1',
      port: 0,
      agentClients: {'fake': client},
      resolveVoiceTts: () => _TtsProvider(),
      resolveVoiceStt: () => stt,
      resolveVoiceTurnDetection: () => detector,
      log: (_) {},
    );
    addTearDown(handle.stop);

    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${handle.server.port}/ws'),
    );
    await channel.ready;
    final frames = channel.stream
        .where((frame) => frame is String)
        .map((frame) => jsonDecode(frame as String) as Map<String, Object?>)
        .asBroadcastStream();
    channel.sink.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'voice-e2e',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await frames.firstWhere((frame) => frame['status'] == 'server_info');

    final responseFuture = frames.firstWhere(
      (frame) =>
          frame['type'] == 'session' &&
          (frame['message'] as Map?)?['type'] == 'set_voice_mode_response',
    );
    channel.sink.add(
      jsonEncode({
        'type': 'session',
        'message': const SetVoiceModeMessage(
          enabled: true,
          agentId: _agentId,
          requestId: 'voice-e2e-enable',
        ).toJson(),
      }),
    );
    final response = ((await responseFuture)['message'] as Map)
        .cast<String, Object?>();
    expect((response['payload'] as Map)['accepted'], isTrue);
    expect(
      handle.manager.get(_agentId)!.systemPrompt,
      contains('<paseo_voice_mode>'),
    );
    expect(client.systemPrompts.last, contains('<paseo_voice_mode>'));
    expect(detector.sessions, hasLength(1));
    expect(stt.sessions, hasLength(1));

    await channel.sink.close();
    await _waitFor(
      () => handle.manager
          .get(_agentId)!
          .systemPrompt!
          .contains('voice mode is now off'),
    );

    expect(detector.sessions.single.closed, isTrue);
    expect(stt.sessions.single.closed, isTrue);
    expect(client.systemPrompts.last, contains('voice mode is now off'));
  });
}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for voice session cleanup');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _VoiceClient implements AgentClient {
  final List<String?> systemPrompts = [];

  @override
  Future<AgentSession> createSession({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
  }) async {
    systemPrompts.add(systemPrompt);
    return _VoiceAgentSession();
  }
}

final class _VoiceAgentSession implements AgentSession {
  final _events = StreamController<ProviderEvent>.broadcast();

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {}

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> dispose() => _events.close();
}

final class _TurnProvider implements TurnDetectionProvider {
  final List<_TurnSession> sessions = [];

  @override
  String get id => 'fake-vad';

  @override
  TurnDetectionSession createSession(
    TurnDetectionSessionParameters parameters,
  ) {
    final session = _TurnSession();
    sessions.add(session);
    return session;
  }
}

final class _TurnSession implements TurnDetectionSession {
  final _started = StreamController<void>.broadcast();
  final _stopped = StreamController<void>.broadcast();
  final _errors = StreamController<Object?>.broadcast();
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
  void appendPcm16(Uint8List pcm16le) {}

  @override
  void flush() {}

  @override
  void reset() {}

  @override
  void close() => closed = true;
}

final class _SttProvider implements SpeechToTextProvider {
  final List<_SttSession> sessions = [];

  @override
  String get id => 'fake-stt';

  @override
  StreamingTranscriptionSession createSession(
    SpeechSessionParameters parameters,
  ) {
    final session = _SttSession();
    sessions.add(session);
    return session;
  }
}

final class _SttSession implements StreamingTranscriptionSession {
  final _committed =
      StreamController<StreamingTranscriptionCommittedEvent>.broadcast();
  final _transcripts =
      StreamController<StreamingTranscriptionEvent>.broadcast();
  final _errors = StreamController<Object?>.broadcast();
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

final class _TtsProvider implements TextToSpeechProvider {
  @override
  Future<SpeechStreamResult> synthesizeSpeech(String text) async =>
      SpeechStreamResult(
        stream: Stream<List<int>>.value([1, 2, 3]),
        format: 'audio/mpeg',
      );
}
