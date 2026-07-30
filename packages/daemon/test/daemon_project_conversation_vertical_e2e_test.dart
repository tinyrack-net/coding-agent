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
    'project add creates a local workspace and completes its first conversation',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'daemon-project-conversation-',
      );
      addTearDown(() => _deleteDirectoryEventually(temp));
      final project = Directory('${temp.path}${Platform.pathSeparator}project')
        ..createSync();
      await File(
        '${project.path}${Platform.pathSeparator}README.md',
      ).writeAsString('# vertical journey\n');
      await _git(['init', '-b', 'main'], project.path);
      await _git(['add', 'README.md'], project.path);
      await _git([
        '-c',
        'user.name=Test',
        '-c',
        'user.email=test@example.com',
        'commit',
        '-m',
        'initial',
      ], project.path);
      final projectRootPath = await project.resolveSymbolicLinks();

      final provider = _CompletingClient();
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        dataDir: temp.path,
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
            clientId: 'project-conversation-e2e',
            clientType: WebSocketClientType.cli,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      await frames.firstWhere((frame) => frame['status'] == 'server_info');

      Future<Map<String, Object?>> request(
        Map<String, Object?> message,
        String responseType,
      ) async {
        final requestId = message['requestId'];
        final response = frames.firstWhere((frame) {
          if (frame['type'] != 'session' || frame['message'] is! Map) {
            return false;
          }
          final session = (frame['message'] as Map).cast<String, Object?>();
          if (session['type'] != responseType) return false;
          final payload = session['payload'];
          return session['requestId'] == requestId ||
              payload is Map && payload['requestId'] == requestId;
        });
        channel.sink.add(jsonEncode({'type': 'session', 'message': message}));
        return ((await response)['message'] as Map).cast<String, Object?>();
      }

      final added = ProjectAddResponse.fromJson(
        await request(
          ProjectAddRequest(
            cwd: projectRootPath,
            requestId: 'project-add',
          ).toJson(),
          ProjectAddResponse.type,
        ),
      );
      expect(added.error, isNull);
      expect(added.project?.projectRootPath, projectRootPath);
      expect(added.project?.projectKind, WorkspaceProjectKind.git);

      final createdWorkspace = WorkspaceCreateResponse.fromJson(
        await request(
          WorkspaceCreateRequest(
            requestId: 'workspace-create',
            source: DirectoryWorkspaceCreateSource(
              path: projectRootPath,
              projectId: added.project!.projectId,
            ),
          ).toJson(),
          'workspace.create.response',
        ),
      );
      expect(createdWorkspace.error, isNull);
      final workspace = createdWorkspace.workspace!;
      expect(workspace.workspaceDirectory, projectRootPath);
      expect(workspace.workspaceKind, WorkspaceKind.localCheckout);

      const prompt = 'Reply deterministically and finish.';
      const clientMessageId = 'vertical-first-message';
      final createRequest = CreateAgentRequest(
        requestId: 'agent-create',
        config: CreateAgentSessionConfig(
          provider: 'codex',
          cwd: workspace.workspaceDirectory,
          title: 'Vertical conversation',
          hasTitle: true,
        ),
        workspaceId: workspace.id,
        initialPrompt: prompt,
        clientMessageId: clientMessageId,
      );
      final createdAgentMessage = await request(
        createRequest.toJson(),
        'status',
      );
      final createdAgent =
          CreateAgentStatus.fromJson(createdAgentMessage) as AgentCreatedStatus;
      expect(createdAgent.agent['workspaceId'], workspace.id);
      final agentId = createdAgent.agentId;

      FetchAgentResponse fetchedAgent;
      do {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        fetchedAgent = FetchAgentResponse.fromJson(
          await request(
            FetchAgentRequest(
              requestId: 'agent-fetch-${DateTime.now().microsecondsSinceEpoch}',
              agentId: agentId,
            ).toJson(),
            FetchAgentResponse.type,
          ),
        );
      } while (fetchedAgent.agent?.runState != AgentRunState.idle);
      expect(fetchedAgent.error, isNull);
      expect(fetchedAgent.agent?.workspaceId, workspace.id);
      expect(fetchedAgent.agent?.runState, AgentRunState.idle);

      final directory = FetchAgentsResponse.fromJson(
        await request(
          const FetchAgentsRequest(
            requestId: 'agents-fetch',
            activeScope: true,
          ).toJson(),
          FetchAgentsResponse.type,
        ),
      );
      final directoryAgent = directory.entries
          .singleWhere((entry) => entry.agent.agentId == agentId)
          .agent;
      expect(directoryAgent.workspaceId, workspace.id);
      expect(directoryAgent.runState, AgentRunState.idle);

      final timeline = AgentTimelinePage.fromResponseJson(
        await request(
          FetchAgentTimelineRequest(
            agentId: agentId,
            requestId: 'timeline-fetch',
            direction: AgentTimelineDirection.tail,
            limit: 100,
          ).toJson(),
          AgentTimelinePage.responseType,
        ),
      );
      expect(timeline.error, isNull);
      expect(timeline.agent?['status'], 'idle');
      final userMessage = timeline.entries
          .map((entry) => entry.item)
          .whereType<UserMessageItem>()
          .single;
      expect(userMessage.text, prompt);
      expect(userMessage.clientMessageId, clientMessageId);
      final assistantMessage = timeline.entries
          .map((entry) => entry.item)
          .whereType<AssistantMessageItem>()
          .single;
      expect(assistantMessage.text, 'Deterministic provider response.');
      expect(provider.prompts, [prompt]);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

final class _CompletingClient implements AgentClient {
  final prompts = <String>[];

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
  }) async => _CompletingSession(prompts);
}

final class _CompletingSession implements AgentSession {
  _CompletingSession(this.prompts);

  final List<String> prompts;
  final _events = StreamController<ProviderEvent>.broadcast();

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {
    prompts.add(text);
    scheduleMicrotask(() {
      _events
        ..add(
          const AssistantMessageComplete(
            itemId: 'deterministic-assistant-message',
            fullText: 'Deterministic provider response.',
          ),
        )
        ..add(const TurnCompleted());
    });
  }

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> dispose() => _events.close();
}

Future<void> _git(List<String> arguments, String cwd) async {
  final result = await Process.run('git', arguments, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
}

Future<void> _deleteDirectoryEventually(Directory directory) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (!directory.existsSync()) return;
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 39) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
