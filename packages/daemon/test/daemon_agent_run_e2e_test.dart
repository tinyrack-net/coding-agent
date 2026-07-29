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
}

final class _RunClient implements AgentClient, EnvironmentAgentClient {
  final prompts = <String>[];
  final environments = <Map<String, String>>[];

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
  }) async => _RunSession(prompts);

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
    return _RunSession(prompts);
  }
}

final class _RunSession implements AgentSession {
  _RunSession(this.prompts);

  final List<String> prompts;
  final _events = StreamController<ProviderEvent>.broadcast();

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {
    prompts.add(text);
    scheduleMicrotask(() => _events.add(const TurnCompleted()));
  }

  @override
  Future<void> interrupt() async {}

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
