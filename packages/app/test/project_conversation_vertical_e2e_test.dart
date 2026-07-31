import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/workspace_providers.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Flutter state adds a project and completes initial and follow-up turns',
    () async {
      final temp = Directory.systemTemp.createTempSync(
        'tinyrack-flutter-project-conversation-e2e-',
      );
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final project = Directory('${temp.path}${Platform.pathSeparator}project')
        ..createSync();
      File(
        '${project.path}${Platform.pathSeparator}README.md',
      ).writeAsStringSync('# Flutter vertical journey\n');
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

      final provider = _CompletingAgentClient();
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: temp.path,
        agentClients: {'codex': provider},
        log: (_) {},
      );
      addTearDown(handle.stop);
      final client = DaemonClient(
        uri: Uri.parse('ws://127.0.0.1:${handle.server.port}'),
      );
      addTearDown(client.dispose);
      await client.connect();

      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);

      final registeredProject = await container
          .read(projectsProvider.notifier)
          .add(projectRootPath);
      expect(registeredProject.projectId, isNotNull);
      expect(registeredProject.path, projectRootPath);
      expect(registeredProject.isGitRepo, isTrue);

      final workspaceResponse = WorkspaceCreateResponse.fromJson(
        await client.requestSessionMessage(
          WorkspaceCreateRequest(
            requestId: 'flutter-workspace-create',
            source: DirectoryWorkspaceCreateSource(
              path: projectRootPath,
              projectId: registeredProject.projectId,
            ),
          ).toJson(),
        ),
      );
      expect(workspaceResponse.error, isNull);
      final workspace = workspaceResponse.workspace!;

      const prompt = 'Complete the Flutter client journey.';
      const clientMessageId = 'flutter-first-message';
      final assistantStream = client.agentStreamEvents
          .firstWhere((event) => event.item is AssistantMessageItem)
          .timeout(const Duration(seconds: 5));
      final actions = container.read(agentActionsProvider);
      final created = await actions.create(
        cwd: workspace.workspaceDirectory,
        provider: 'codex',
        model: 'fake',
        mode: AgentMode.normal,
        workspaceId: workspace.id,
        projectPath: projectRootPath,
        branch: 'main',
        initialPrompt: prompt,
        clientMessageId: clientMessageId,
      );
      final streamedAssistant = await assistantStream;
      expect(streamedAssistant.agentId, created.agentId);
      expect(
        (streamedAssistant.item as AssistantMessageItem).text,
        'Deterministic Flutter response 1.',
      );

      var fetched = await _waitForIdle(client, created.agentId);
      expect(fetched?.workspaceId, workspace.id);
      expect(fetched?.runState, AgentRunState.idle);

      const followUp = 'Send a second deterministic response.';
      const followUpMessageId = 'flutter-follow-up-message';
      final followUpAssistantStream = client.agentStreamEvents
          .firstWhere(
            (event) =>
                event.agentId == created.agentId &&
                event.item is AssistantMessageItem &&
                (event.item as AssistantMessageItem).text.endsWith('2.'),
          )
          .timeout(const Duration(seconds: 5));
      await actions.prompt(
        created.agentId,
        followUp,
        clientMessageId: followUpMessageId,
      );
      final followUpAssistant = await followUpAssistantStream;
      expect(
        (followUpAssistant.item as AssistantMessageItem).text,
        'Deterministic Flutter response 2.',
      );
      fetched = await _waitForIdle(client, created.agentId);
      expect(fetched?.runState, AgentRunState.idle);

      final timeline = await client.fetchAgentTimeline(
        agentId: created.agentId,
        limit: 100,
      );
      expect(timeline.error, isNull);
      final users = timeline.entries
          .map((entry) => entry.item)
          .whereType<UserMessageItem>()
          .toList(growable: false);
      expect(users.map((item) => item.text), [prompt, followUp]);
      expect(users.map((item) => item.clientMessageId), [
        clientMessageId,
        followUpMessageId,
      ]);
      expect(
        timeline.entries
            .map((entry) => entry.item)
            .whereType<AssistantMessageItem>()
            .map((item) => item.text),
        [
          'Deterministic Flutter response 1.',
          'Deterministic Flutter response 2.',
        ],
      );
      expect(provider.prompts, [prompt, followUp]);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

final class _CompletingAgentClient implements AgentClient {
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
  }) async => _CompletingAgentSession(prompts);
}

final class _CompletingAgentSession implements AgentSession {
  _CompletingAgentSession(this.prompts);

  final List<String> prompts;
  final _events = StreamController<ProviderEvent>.broadcast();

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {
    prompts.add(text);
    final responseNumber = prompts.length;
    scheduleMicrotask(() {
      _events
        ..add(
          AssistantMessageComplete(
            itemId: 'deterministic-flutter-assistant-message-$responseNumber',
            fullText: 'Deterministic Flutter response $responseNumber.',
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

Future<AgentSummary?> _waitForIdle(DaemonClient client, String agentId) async {
  AgentSummary? fetched;
  for (var attempt = 0; attempt < 100; attempt++) {
    fetched = (await client.fetchAgent(agentId))?.agent;
    if (fetched?.runState == AgentRunState.idle) return fetched;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return fetched;
}

Future<void> _git(List<String> arguments, String cwd) async {
  final result = await Process.run('git', arguments, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
}
