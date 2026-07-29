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
  test('send and wait cross the real daemon WebSocket lifecycle', () async {
    final home = Directory.systemTemp.createTempSync('daemon-agent-send-');
    addTearDown(() => _deleteDirectoryEventually(home));
    final store = AgentStore(dataDir: home.path);
    for (final entry in const [
      (id: 'agent-complete', archived: true),
      (id: 'agent-permission', archived: false),
      (id: 'agent-error', archived: false),
      (id: 'agent-timeout', archived: false),
    ]) {
      await store.save(
        PersistedAgent(
          summary: AgentSummary(
            agentId: entry.id,
            title: entry.id,
            cwd: '.',
            provider: 'codex',
            model: 'gpt-5.4',
            mode: AgentMode.normal,
            runState: entry.archived
                ? AgentRunState.closed
                : AgentRunState.idle,
            createdAtMs: 1,
            archivedAt: entry.archived ? '2026-07-29T00:00:00.000Z' : null,
          ),
          archived: entry.archived,
          epoch: 1,
          lastSeq: 0,
          items: const [],
        ),
      );
    }
    final provider = _SendClient();
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: home.path),
      dataDir: home.path,
      host: '127.0.0.1',
      port: 0,
      agentClients: {'codex': provider},
      log: (_) {},
    );
    addTearDown(handle.stop);

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
          clientId: 'agent-send-e2e',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await frames.firstWhere((frame) => frame['status'] == 'server_info');

    Future<Map<String, Object?>> rpc(
      Map<String, Object?> request,
      String responseType,
    ) async {
      final response = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == responseType &&
            (((frame['message'] as Map)['payload'] as Map)['requestId']) ==
                request['requestId'],
      );
      channel.sink.add(jsonEncode({'type': 'session', 'message': request}));
      return ((await response)['message'] as Map).cast<String, Object?>();
    }

    Future<SendAgentMessageResponse> send(
      String agentId,
      String text,
      String messageId,
    ) async {
      final request = SendAgentMessageRequest(
        requestId: 'send-$agentId-$messageId',
        agentId: agentId,
        text: text,
        messageId: messageId,
      ).toJson();
      return SendAgentMessageResponse.fromJson(
        await rpc(request, SendAgentMessageResponse.type),
      );
    }

    Future<WaitForFinishResponse> wait(
      String agentId, {
      int timeoutMs = 1000,
    }) async {
      final request = WaitForFinishRequest(
        requestId: 'wait-$agentId-$timeoutMs',
        agentId: agentId,
        timeoutMs: timeoutMs,
      ).toJson();
      return WaitForFinishResponse.fromJson(
        await rpc(request, WaitForFinishResponse.type),
      );
    }

    final completed = await send(
      'agent-comp',
      'complete this',
      'message-complete',
    );
    expect(completed.accepted, isTrue);
    expect(completed.agentId, 'agent-complete');
    final completedWait = await wait('agent-comp');
    expect(completedWait.status, WaitForFinishStatus.idle);
    expect(completedWait.finalAgent?['archivedAt'], isNull);
    expect(handle.manager.get('agent-complete'), isNotNull);

    final duplicate = await send(
      'agent-complete',
      'must not run twice',
      'message-complete',
    );
    expect(duplicate.accepted, isTrue);
    expect(provider.promptCount, 1);

    expect(
      (await send(
        'agent-permission',
        'request permission',
        'message-permission',
      )).accepted,
      isTrue,
    );
    final permissionWait = await wait('agent-permission');
    expect(permissionWait.status, WaitForFinishStatus.permission);
    expect(permissionWait.finalAgent?['status'], 'running');
    expect(permissionWait.finalAgent?['pendingPermissions'], isNotEmpty);

    expect(
      (await send('agent-error', 'fail later', 'message-error')).accepted,
      isTrue,
    );
    final errorWait = await wait('agent-error');
    expect(errorWait.status, WaitForFinishStatus.error);
    expect(errorWait.error, 'provider exploded');

    expect(
      (await send('agent-timeout', 'keep running', 'message-timeout')).accepted,
      isTrue,
    );
    final timeoutWait = await wait('agent-timeout', timeoutMs: 10);
    expect(timeoutWait.status, WaitForFinishStatus.timeout);
    expect(timeoutWait.finalAgent?['status'], 'running');

    expect(
      (await send(
        'agent-timeout',
        'complete replacement',
        'message-replacement',
      )).accepted,
      isTrue,
    );
    expect(provider.interruptCount, 1);
    expect((await wait('agent-timeout')).status, WaitForFinishStatus.idle);
  });
}

final class _SendClient implements AgentClient {
  int promptCount = 0;
  int interruptCount = 0;

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
  }) async => _SendSession(this);
}

final class _SendSession implements AgentSession {
  _SendSession(this.client);

  final _SendClient client;
  final _events = StreamController<ProviderEvent>.broadcast();

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {
    client.promptCount++;
    if (text == 'complete this' || text == 'complete replacement') {
      scheduleMicrotask(() => _events.add(const TurnCompleted()));
    } else if (text == 'request permission') {
      Future<void>.delayed(
        const Duration(milliseconds: 5),
        () => _events.add(
          PermissionRequested(
            permissionId: 'permission-e2e',
            toolName: 'Bash',
            detail: const PlainTextDetail(label: 'Command', text: 'git status'),
            respond:
                (
                  _, {
                  message,
                  selectedActionId,
                  updatedInput,
                  updatedPermissions,
                  interrupt,
                }) async {},
          ),
        ),
      );
    } else if (text == 'fail later') {
      Future<void>.delayed(
        const Duration(milliseconds: 5),
        () => _events.add(const TurnFailed(error: 'provider exploded')),
      );
    }
  }

  @override
  Future<void> interrupt() async {
    client.interruptCount++;
    _events.add(const TurnFailed(error: 'interrupted'));
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
