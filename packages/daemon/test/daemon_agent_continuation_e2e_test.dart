import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test(
    'workspace first-agent continuation crosses daemon assembly',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'daemon-agent-continuation-',
      );
      addTearDown(() async {
        for (var attempt = 0; attempt < 20 && temp.existsSync(); attempt++) {
          try {
            await temp.delete(recursive: true);
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      });
      final repository = Directory(
        '${temp.path}${Platform.pathSeparator}repository',
      )..createSync();
      await File(
        '${repository.path}${Platform.pathSeparator}tinyrack.json',
      ).writeAsString(
        '{"worktree":{'
        '"setup":["echo setup > setup-marker.txt"],'
        '"terminals":[{"name":"Dev","command":'
        '"echo terminal > terminal-marker.txt"}]}}',
      );
      await _git(['init', '-b', 'main'], repository.path);
      await _git(['add', '.'], repository.path);
      await _git([
        '-c',
        'user.name=Test',
        '-c',
        'user.email=test@example.com',
        'commit',
        '-m',
        'initial',
      ], repository.path);
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: temp.path,
        agentClients: {'test': _Client()},
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
            clientId: 'continuation-e2e',
            clientType: WebSocketClientType.cli,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      await frames.firstWhere((frame) => frame['status'] == 'server_info');

      final workspaceFuture = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == 'workspace.create.response',
      );
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': WorkspaceCreateRequest(
            requestId: 'create-workspace',
            source: WorktreeWorkspaceCreateSource(
              cwd: repository.path,
              action: WorktreeCreateAction.branchOff,
              refName: 'main',
              branchName: 'feature',
            ),
            firstAgentContext: const {'prompt': 'fix it'},
          ).toJson(),
        }),
      );
      final workspace = WorkspaceCreateResponse.fromJson(
        Map<String, Object?>.from((await workspaceFuture)['message'] as Map),
      ).workspace!;
      final setupMarker = File(
        '${workspace.workspaceDirectory}'
        '${Platform.pathSeparator}setup-marker.txt',
      );
      expect(setupMarker.existsSync(), isFalse);

      bool isCompletedTool(Map<String, Object?> frame, String name) {
        if (frame['type'] != 'session' || frame['message'] is! Map) {
          return false;
        }
        final message = Map<String, Object?>.from(frame['message'] as Map);
        if (message['type'] != 'agent_stream' || message['payload'] is! Map) {
          return false;
        }
        final payload = Map<String, Object?>.from(message['payload'] as Map);
        if (payload['event'] is! Map) return false;
        final event = Map<String, Object?>.from(payload['event'] as Map);
        if (event['type'] != 'timeline' || event['item'] is! Map) return false;
        final item = Map<String, Object?>.from(event['item'] as Map);
        return item['type'] == 'tool_call' &&
            item['name'] == name &&
            item['status'] == 'completed' &&
            item['error'] == null;
      }

      final setupStreamFuture = frames.firstWhere(
        (frame) => isCompletedTool(frame, 'paseo_worktree_setup'),
      );
      final terminalsStreamFuture = frames.firstWhere(
        (frame) => isCompletedTool(frame, 'paseo_worktree_terminals'),
      );
      final parent = await handle.manager.createAgent(
        cwd: workspace.workspaceDirectory,
        provider: 'test',
        model: 'fake',
        mode: AgentMode.fullAccess,
        modeId: 'trusted',
        workspaceId: workspace.id,
      );
      final agentFuture = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == 'agent.create.response' &&
            (frame['message'] as Map?)?['requestId'] == 'create-agent',
      );
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': RpcRequest(
            type: MessageTypes.agentCreateRequest,
            requestId: 'create-agent',
            payload: {
              'cwd': workspace.workspaceDirectory,
              'workspaceId': workspace.id,
              'provider': 'test',
              'model': 'fake',
              'mode': 'normal',
              'projectPath': workspace.projectRootPath,
              'branch': 'feature',
              'isWorktree': true,
              'parentAgentId': parent.agentId,
              'initialPrompt': 'Start after bootstrap',
              'clientMessageId': 'first-client-message',
            },
          ).toJson(),
        }),
      );
      final agentFrame =
          RpcFrame.fromJson(
                Map<String, Object?>.from(
                  (await agentFuture)['message'] as Map,
                ),
              )
              as RpcResponse;
      expect(agentFrame.error, isNull);
      final agent = AgentSummary.fromJson(
        agentFrame.payload['agent'] as Map<String, Object?>,
      );
      expect(agent.title, 'Start after bootstrap');
      expect(agent.currentModeId, 'trusted');
      final terminalMarker = File(
        '${workspace.workspaceDirectory}'
        '${Platform.pathSeparator}terminal-marker.txt',
      );
      await _waitUntil(
        () => setupMarker.existsSync() && terminalMarker.existsSync(),
      );
      await _waitUntil(
        () => handle.manager
            .fetchTimeline(agent.agentId)
            .items
            .whereType<UserMessageItem>()
            .isNotEmpty,
      );
      await setupStreamFuture;
      await terminalsStreamFuture;

      final timeline = handle.manager.fetchTimeline(agent.agentId).items;
      final tools = timeline.whereType<ToolCallItem>().toList();
      expect(tools.map((item) => item.toolName), [
        'paseo_worktree_setup',
        'paseo_worktree_terminals',
      ]);
      expect(
        tools.every((item) => item.status == ToolCallStatus.success),
        isTrue,
      );
      expect(handle.terminals.list().single['workspaceId'], workspace.id);
      final firstMessage = timeline.whereType<UserMessageItem>().single;
      expect(firstMessage.id, 'first-client-message');
      expect(firstMessage.text, 'Start after bootstrap');
      expect(
        timeline.indexOf(firstMessage),
        greaterThan(
          timeline.lastIndexWhere(
            (item) =>
                item is ToolCallItem &&
                item.toolName == 'paseo_worktree_terminals',
          ),
        ),
      );

      final fetchFuture = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] ==
                'fetch_agent_timeline_response' &&
            ((frame['message'] as Map?)?['payload'] as Map?)?['requestId'] ==
                'fetch-timeline',
      );
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': {
            'type': 'fetch_agent_timeline_request',
            'requestId': 'fetch-timeline',
            'agentId': agent.agentId,
            'direction': 'tail',
            'limit': 0,
            'projection': 'canonical',
          },
        }),
      );
      final fetchMessage = Map<String, Object?>.from(
        (await fetchFuture)['message'] as Map,
      );
      final fetchPayload = Map<String, Object?>.from(
        fetchMessage['payload'] as Map,
      );
      expect(fetchPayload['direction'], 'tail');
      expect(fetchPayload['projection'], 'canonical');
      expect(fetchPayload['reset'], isFalse);
      expect(fetchPayload['error'], isNull);
      expect(
        Map<String, Object?>.from(fetchPayload['agent'] as Map)['id'],
        agent.agentId,
      );
      final entries = (fetchPayload['entries'] as List)
          .cast<Map>()
          .map((entry) => Map<String, Object?>.from(entry))
          .toList();
      final fetchedTools = entries
          .map((entry) => Map<String, Object?>.from(entry['item'] as Map))
          .where((item) => item['type'] == 'tool_call')
          .toList();
      expect(fetchedTools.map((item) => item['name']), [
        'paseo_worktree_setup',
        'paseo_worktree_setup',
        'paseo_worktree_terminals',
        'paseo_worktree_terminals',
      ]);
      expect(fetchedTools.map((item) => item['status']), [
        'running',
        'completed',
        'running',
        'completed',
      ]);
      expect(
        entries.every(
          (entry) =>
              entry['seqStart'] == entry['seqEnd'] &&
              (entry['sourceSeqRanges'] as List).length == 1,
        ),
        isTrue,
      );

      final projectedFuture = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] ==
                'fetch_agent_timeline_response' &&
            ((frame['message'] as Map?)?['payload'] as Map?)?['requestId'] ==
                'fetch-projected',
      );
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': {
            'type': 'fetch_agent_timeline_request',
            'requestId': 'fetch-projected',
            'agentId': agent.agentId,
            'direction': 'tail',
            'limit': 0,
          },
        }),
      );
      final projectedPayload = Map<String, Object?>.from(
        Map<String, Object?>.from(
              (await projectedFuture)['message'] as Map,
            )['payload']
            as Map,
      );
      expect(projectedPayload['projection'], 'projected');
      final projectedTools = (projectedPayload['entries'] as List)
          .cast<Map>()
          .map((entry) => Map<String, Object?>.from(entry))
          .where(
            (entry) =>
                Map<String, Object?>.from(entry['item'] as Map)['type'] ==
                'tool_call',
          )
          .toList();
      expect(projectedTools, hasLength(2));
      expect(
        projectedTools.map(
          (entry) => Map<String, Object?>.from(entry['item'] as Map)['status'],
        ),
        everyElement('completed'),
      );
      expect(
        projectedTools.map((entry) => entry['collapsed']),
        everyElement(contains('tool_lifecycle')),
      );

      Future<Map<String, Object?>> fetchWindow(
        String requestId, {
        required String direction,
        required Map<String, Object?> cursor,
        int limit = 1,
        String projection = 'canonical',
      }) async {
        final future = frames.firstWhere(
          (frame) =>
              frame['type'] == 'session' &&
              (frame['message'] as Map?)?['type'] ==
                  'fetch_agent_timeline_response' &&
              ((frame['message'] as Map?)?['payload'] as Map?)?['requestId'] ==
                  requestId,
        );
        channel.sink.add(
          jsonEncode({
            'type': 'session',
            'message': {
              'type': 'fetch_agent_timeline_request',
              'requestId': requestId,
              'agentId': agent.agentId,
              'direction': direction,
              'cursor': cursor,
              'limit': limit,
              'projection': projection,
            },
          }),
        );
        return Map<String, Object?>.from(
          Map<String, Object?>.from((await future)['message'] as Map)['payload']
              as Map,
        );
      }

      final epoch = fetchPayload['epoch'] as String;
      final window = Map<String, Object?>.from(fetchPayload['window'] as Map);
      final maxSeq = window['maxSeq'] as int;
      final minSeq = window['minSeq'] as int;
      final stale = await fetchWindow(
        'fetch-stale',
        direction: 'after',
        cursor: {'epoch': 'stale-epoch', 'seq': maxSeq},
      );
      expect(stale['reset'], isTrue);
      expect(stale['staleCursor'], isTrue);
      expect(stale['gap'], isFalse);
      expect(stale['entries'], hasLength(1));
      expect(stale['hasNewer'], isFalse);

      final exhausted = await fetchWindow(
        'fetch-exhausted',
        direction: 'after',
        cursor: {'epoch': epoch, 'seq': maxSeq},
      );
      expect(exhausted['entries'], isEmpty);
      expect(exhausted['hasOlder'], isTrue);
      expect(exhausted['hasNewer'], isFalse);

      final beforeStart = await fetchWindow(
        'fetch-before-start',
        direction: 'before',
        cursor: {'epoch': epoch, 'seq': minSeq},
      );
      expect(beforeStart['entries'], isEmpty);
      expect(beforeStart['hasOlder'], isFalse);
      expect(beforeStart['hasNewer'], isTrue);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'agent create couples worktree bootstrap and one-shot auto-archive',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'daemon-agent-create-lifecycle-',
      );
      addTearDown(() async {
        for (var attempt = 0; attempt < 20 && temp.existsSync(); attempt++) {
          try {
            await temp.delete(recursive: true);
          } on FileSystemException {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      });
      final repository = Directory(
        '${temp.path}${Platform.pathSeparator}repository',
      )..createSync();
      await File(
        '${repository.path}${Platform.pathSeparator}tracked.txt',
      ).writeAsString('initial');
      await _git(['init', '-b', 'main'], repository.path);
      await _git(['add', '.'], repository.path);
      await _git([
        '-c',
        'user.name=Test',
        '-c',
        'user.email=test@example.com',
        'commit',
        '-m',
        'initial',
      ], repository.path);
      final client = _Client();
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: temp.path,
        agentClients: {'test': client, 'opencode': client},
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
            clientId: 'create-lifecycle-e2e',
            clientType: WebSocketClientType.cli,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      await frames.firstWhere((frame) => frame['status'] == 'server_info');

      final responseFuture = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == 'agent.create.response' &&
            (frame['message'] as Map?)?['requestId'] == 'direct-create',
      );
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': RpcRequest(
            type: MessageTypes.agentCreateRequest,
            requestId: 'direct-create',
            payload: {
              'cwd': repository.path,
              'provider': 'test',
              'model': 'fake',
              'mode': 'normal',
              'initialPrompt': 'Implement direct lifecycle',
              'worktree': {
                'mode': 'branch-off',
                'newBranch': 'direct-lifecycle',
                'base': 'main',
              },
              'autoArchive': true,
            },
          ).toJson(),
        }),
      );
      final response =
          RpcFrame.fromJson(
                Map<String, Object?>.from(
                  (await responseFuture)['message'] as Map,
                ),
              )
              as RpcResponse;
      expect(response.error, isNull);
      final agent = AgentSummary.fromJson(
        response.payload['agent'] as Map<String, Object?>,
      );
      expect(agent.workspaceId, isNotNull);
      expect(agent.cwd, isNot(repository.path));
      expect(Directory(agent.cwd).existsSync(), isTrue);
      expect(agent.branch, 'direct-lifecycle');
      expect(agent.isWorktree, isTrue);
      await _waitUntil(
        () => handle.manager
            .fetchTimeline(agent.agentId)
            .items
            .whereType<UserMessageItem>()
            .isNotEmpty,
      );
      expect(client.sessions, hasLength(1));

      client.sessions.single.emit(const TurnCompleted());
      client.sessions.single.emit(const TurnCompleted());
      await _waitUntil(
        () =>
            handle.manager.get(agent.agentId)?.archivedAt != null &&
            !Directory(agent.cwd).existsSync(),
      );

      expect(handle.manager.get(agent.agentId)?.archivedAt, isNotNull);
      expect(handle.terminals.listV2(workspaceId: agent.workspaceId), isEmpty);

      final failedResponseFuture = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == 'agent.create.response' &&
            (frame['message'] as Map?)?['requestId'] == 'failed-create',
      );
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': RpcRequest(
            type: MessageTypes.agentCreateRequest,
            requestId: 'failed-create',
            payload: {
              'cwd': repository.path,
              'provider': 'missing-provider',
              'model': 'fake',
              'mode': 'normal',
              'worktree': {
                'mode': 'branch-off',
                'newBranch': 'failed-create',
                'base': 'main',
              },
            },
          ).toJson(),
        }),
      );
      final failedResponse =
          RpcFrame.fromJson(
                Map<String, Object?>.from(
                  (await failedResponseFuture)['message'] as Map,
                ),
              )
              as RpcResponse;
      expect(failedResponse.error, isNotNull);
      expect(
        Directory(
          '${temp.path}${Platform.pathSeparator}worktrees'
          '${Platform.pathSeparator}failed-create',
        ).existsSync(),
        isFalse,
      );

      final conflictResponseFuture = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == 'agent.create.response' &&
            (frame['message'] as Map?)?['requestId'] == 'conflicting-create',
      );
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': RpcRequest(
            type: MessageTypes.agentCreateRequest,
            requestId: 'conflicting-create',
            payload: {
              'cwd': repository.path,
              'provider': 'test',
              'model': 'fake',
              'mode': 'normal',
              'git': <String, Object?>{},
              'worktree': {
                'mode': 'branch-off',
                'newBranch': 'conflicting-create',
              },
            },
          ).toJson(),
        }),
      );
      final conflictResponse =
          RpcFrame.fromJson(
                Map<String, Object?>.from(
                  (await conflictResponseFuture)['message'] as Map,
                ),
              )
              as RpcResponse;
      expect(
        conflictResponse.error?.message,
        contains('worktree cannot be combined with git options'),
      );
      expect(
        Directory(
          '${temp.path}${Platform.pathSeparator}worktrees'
          '${Platform.pathSeparator}conflicting-create',
        ).existsSync(),
        isFalse,
      );

      final providerPolicyResponseFuture = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == 'agent.create.response' &&
            (frame['message'] as Map?)?['requestId'] == 'provider-policy',
      );
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': RpcRequest(
            type: MessageTypes.agentCreateRequest,
            requestId: 'provider-policy',
            payload: {
              'cwd': repository.path,
              'provider': 'opencode',
              'model': 'fake',
              'mode': 'normal',
              'modeId': 'full-access',
              'features': {'auto_accept': false, 'custom': 'kept'},
            },
          ).toJson(),
        }),
      );
      final providerPolicyResponse =
          RpcFrame.fromJson(
                Map<String, Object?>.from(
                  (await providerPolicyResponseFuture)['message'] as Map,
                ),
              )
              as RpcResponse;
      expect(providerPolicyResponse.error, isNull);
      final providerPolicyAgent = AgentSummary.fromJson(
        providerPolicyResponse.payload['agent'] as Map<String, Object?>,
      );
      expect(providerPolicyAgent.currentModeId, 'build');
      expect(providerPolicyAgent.featureValues, {
        'auto_accept': true,
        'custom': 'kept',
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Future<void> _git(List<String> args, String cwd) async {
  final result = await Process.run('git', args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw StateError('git $args failed: ${result.stderr}');
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('agent continuation did not finish');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

final class _Client implements AgentClient {
  final sessions = <_Session>[];

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
    final session = _Session();
    sessions.add(session);
    return session;
  }
}

final class _Session implements AgentSession {
  final _events = StreamController<ProviderEvent>.broadcast();

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> dispose() => _events.close();

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> prompt(String text) async {}

  void emit(ProviderEvent event) => _events.add(event);
}
