import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/agent_run_command.dart';
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
    'agent run crosses workspace, create, prompt, and wait over WebSocket',
    () async {
      final home = Directory.systemTemp.createTempSync(
        'daemon-agent-run-home-',
      );
      final repo = Directory.systemTemp.createTempSync(
        'daemon-agent-run-repo-',
      );
      addTearDown(() => _deleteDirectoryEventually(home));
      addTearDown(() => _deleteDirectoryEventually(repo));
      final provider = _RunClient();
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
        agentClients: {'codex': provider},
        log: (_) {},
      );
      addTearDown(handle.stop);

      final output = StringBuffer();
      final errors = StringBuffer();
      final code = await runAgentRunCommand(
        arguments: [
          '--host',
          '127.0.0.1:${handle.server.port}',
          '--provider',
          'codex/gpt-5.4',
          '--title',
          'Real run',
          '--env',
          'RUN_TOKEN=visible',
          '--json',
          'finish through websocket',
        ],
        currentDirectory: repo.path,
        environment: const {},
        writeOutput: output.write,
        writeError: errors.write,
      );

      expect(code, 0, reason: errors.toString());
      final result = jsonDecode(output.toString()) as Map<String, Object?>;
      expect(result['status'], 'completed');
      expect(result['provider'], 'codex');
      expect(result['cwd'], repo.path);
      expect(result['title'], 'Real run');
      expect(provider.prompts, ['finish through websocket']);
      expect(provider.environments.single, {'RUN_TOKEN': 'visible'});
      final agent = handle.manager.get(result['agentId']! as String);
      expect(agent?.workspaceId, isNotNull);
      expect(agent?.runState, AgentRunState.idle);

      final childOutput = StringBuffer();
      final childCode = await runAgentRunCommand(
        arguments: [
          '--host',
          '127.0.0.1:${handle.server.port}',
          '--provider',
          'codex/gpt-5.4',
          '--background',
          '--json',
          'child through caller context',
        ],
        currentDirectory: home.path,
        environment: {'PASEO_AGENT_ID': result['agentId']! as String},
        writeOutput: childOutput.write,
        writeError: errors.write,
      );
      expect(childCode, 0, reason: errors.toString());
      final childResult =
          jsonDecode(childOutput.toString()) as Map<String, Object?>;
      final child = handle.manager.get(childResult['agentId']! as String);
      expect(child?.workspaceId, agent?.workspaceId);
      expect(child?.cwd, agent?.cwd);
      expect(child?.parentAgentId, agent?.agentId);
      expect(child?.labels[paseoParentAgentIdLabel], agent?.agentId);
    },
  );

  test(
    'frozen create request applies legacy git placement and run options',
    () async {
      final home = Directory.systemTemp.createTempSync(
        'daemon-agent-legacy-home-',
      );
      final repo = Directory.systemTemp.createTempSync(
        'daemon-agent-legacy-repo-',
      );
      addTearDown(() => _deleteDirectoryEventually(home));
      addTearDown(() => _deleteDirectoryEventually(repo));
      await _git(['init', '-b', 'main'], repo.path);
      await File(
        '${repo.path}${Platform.pathSeparator}README.md',
      ).writeAsString('fixture');
      await _git(['add', '.'], repo.path);
      await _git([
        '-c',
        'user.name=Test',
        '-c',
        'user.email=test@example.com',
        'commit',
        '-m',
        'initial',
      ], repo.path);

      final provider = _RunClient();
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
            clientId: 'legacy-create-e2e',
            clientType: WebSocketClientType.cli,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      await frames.firstWhere((frame) => frame['status'] == 'server_info');

      Future<AgentCreatedStatus> create(CreateAgentRequest request) async {
        final response = frames.firstWhere(
          (frame) =>
              frame['type'] == 'session' &&
              (frame['message'] as Map?)?['type'] == 'status' &&
              ((frame['message'] as Map?)?['payload'] as Map?)?['requestId'] ==
                  request.requestId,
        );
        channel.sink.add(
          jsonEncode({'type': 'session', 'message': request.toJson()}),
        );
        return CreateAgentStatus.fromJson(
              Map<String, Object?>.from((await response)['message'] as Map),
            )
            as AgentCreatedStatus;
      }

      final worktreeAgent = await create(
        CreateAgentRequest(
          requestId: 'legacy-worktree',
          config: CreateAgentSessionConfig(provider: 'codex', cwd: repo.path),
          worktreeName: 'Legacy Feature',
          initialPrompt: 'structured',
          outputSchema: const {'type': 'object'},
        ),
      );
      final worktree = handle.manager.get(worktreeAgent.agentId)!;
      expect(worktree.isWorktree, isTrue);
      expect(worktree.branch, 'legacy-feature');
      expect(worktree.cwd, isNot(repo.path));
      await _waitFor(() => provider.outputSchemas.isNotEmpty);
      expect(provider.outputSchemas.single, {'type': 'object'});

      final branchAgent = await create(
        CreateAgentRequest(
          requestId: 'legacy-branch',
          config: CreateAgentSessionConfig(provider: 'codex', cwd: repo.path),
          git: const GitSetupOptions(
            baseBranch: 'main',
            createNewBranch: true,
            newBranchName: 'Branch Only',
          ),
        ),
      );
      expect(handle.manager.get(branchAgent.agentId)!.cwd, repo.path);
      expect(
        (await _git(['branch', '--show-current'], repo.path)).trim(),
        'branch-only',
      );

      final combinedAgent = await create(
        CreateAgentRequest(
          requestId: 'current-plus-legacy-worktree',
          config: CreateAgentSessionConfig(provider: 'codex', cwd: repo.path),
          worktree: const BranchOffCreateAgentWorktreeTarget(
            newBranch: 'current-target',
            base: 'main',
          ),
          worktreeName: 'Nested Legacy',
        ),
      );
      final combined = handle.manager.get(combinedAgent.agentId)!;
      expect(combined.isWorktree, isTrue);
      expect(combined.branch, 'nested-legacy');
      expect(combined.cwd, isNot(repo.path));
    },
  );
}

final class _RunClient implements AgentClient, EnvironmentAgentClient {
  final prompts = <String>[];
  final environments = <Map<String, String>>[];
  final outputSchemas = <Map<String, Object?>>[];

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
  }) async => _RunSession(prompts, outputSchemas);

  @override
  Future<AgentSession> createSessionWithEnvironment({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
    Map<String, String> environment = const {},
  }) async {
    environments.add(Map.unmodifiable(environment));
    return _RunSession(prompts, outputSchemas);
  }
}

final class _RunSession implements AgentSession, RunOptionsAgentSession {
  _RunSession(this.prompts, this.outputSchemas);

  final List<String> prompts;
  final List<Map<String, Object?>> outputSchemas;
  final _events = StreamController<ProviderEvent>.broadcast();

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {
    prompts.add(text);
    scheduleMicrotask(() => _events.add(const TurnCompleted()));
  }

  @override
  Future<void> promptWithRunOptions(
    String text, {
    required List<AgentPromptImage> images,
    required List<AgentAttachment> attachments,
    Map<String, Object?>? outputSchema,
  }) async {
    if (outputSchema != null) outputSchemas.add(outputSchema);
    await prompt(text);
  }

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> dispose() => _events.close();
}

Future<String> _git(List<String> arguments, String cwd) async {
  final result = await Process.run('git', arguments, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('condition was not reached');
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
