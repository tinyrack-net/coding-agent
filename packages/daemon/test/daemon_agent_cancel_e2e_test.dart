import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('cancel agent settles a running provider across v2 WebSocket', () async {
    final home = Directory.systemTemp.createTempSync('daemon-agent-cancel-');
    addTearDown(() => _deleteDirectoryEventually(home));
    const agentId = 'agent-cancel-e2e';
    await AgentStore(dataDir: home.path).save(
      const PersistedAgent(
        summary: AgentSummary(
          agentId: agentId,
          title: 'Cancelable',
          cwd: '.',
          provider: 'codex',
          model: 'gpt-5.4',
          mode: AgentMode.normal,
          runState: AgentRunState.idle,
          createdAtMs: 1,
        ),
        archived: false,
        epoch: 1,
        lastSeq: 0,
        items: [],
      ),
    );
    final provider = _CancelClient();
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: home.path),
      dataDir: home.path,
      host: '127.0.0.1',
      port: 0,
      agentClients: {'codex': provider},
      log: (_) {},
    );
    addTearDown(handle.stop);
    await handle.manager.prompt(agentId, 'keep working');
    expect(handle.manager.hasActiveAgentRun(agentId), isTrue);

    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${handle.server.port}/ws'),
    );
    await channel.ready;
    addTearDown(channel.sink.close);
    final frames = channel.stream
        .where((frame) => frame is String)
        .map((frame) => jsonDecode(frame as String) as Map<String, Object?>)
        .asBroadcastStream();
    channel.sink.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'agent-cancel-e2e',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await frames.firstWhere((frame) => frame['status'] == 'server_info');

    Future<CancelAgentResponse> cancel(String id, String requestId) async {
      final response = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == CancelAgentResponse.type &&
            ((frame['message'] as Map)['payload'] as Map)['requestId'] ==
                requestId,
      );
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': CancelAgentRequest(
            agentId: id,
            requestId: requestId,
          ).toJson(),
        }),
      );
      return CancelAgentResponse.fromJson(
        ((await response)['message'] as Map).cast<String, Object?>(),
      );
    }

    final response = await cancel(agentId, 'cancel');
    expect(response.error, isNull);
    expect(response.agent, isNotNull);
    expect(
      PaseoAgentSnapshotCodec.decode(response.agent!).runState,
      AgentRunState.idle,
    );
    expect(provider.session.interrupted, isTrue);
    expect(handle.manager.hasActiveAgentRun(agentId), isFalse);

    channel.sink.add(
      jsonEncode({
        'type': 'session',
        'message': const CancelAgentRequest(agentId: agentId).toJson(),
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(provider.session.interruptCount, 1);

    final missing = await cancel('missing', 'missing');
    expect(missing.agent, isNull);
    expect(missing.error, contains('no agent missing'));
  });
}

final class _CancelClient implements AgentClient {
  final _CancelSession session = _CancelSession();

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
  }) async => session;
}

final class _CancelSession implements AgentSession {
  final _events = StreamController<ProviderEvent>.broadcast();
  int interruptCount = 0;
  bool get interrupted => interruptCount > 0;

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {}

  @override
  Future<void> interrupt() async {
    interruptCount++;
    scheduleMicrotask(
      () => _events.add(const TurnFailed(error: 'interrupted')),
    );
  }

  @override
  Future<void> dispose() => _events.close();
}

Future<void> _deleteDirectoryEventually(Directory directory) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (!directory.existsSync()) return;
    try {
      await directory.delete(recursive: true);
      return;
    } on PathAccessException {
      if (attempt == 39) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
