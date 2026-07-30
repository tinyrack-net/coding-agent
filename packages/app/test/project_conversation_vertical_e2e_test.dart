import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Flutter client adds a project and completes its first conversation',
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

      final added = await client.addProject(cwd: projectRootPath);
      expect(added.error, isNull);
      expect(added.project?.projectRootPath, projectRootPath);
      expect(added.project?.projectKind, WorkspaceProjectKind.git);

      final workspaceResponse = WorkspaceCreateResponse.fromJson(
        await client.requestSessionMessage(
          WorkspaceCreateRequest(
            requestId: 'flutter-workspace-create',
            source: DirectoryWorkspaceCreateSource(
              path: projectRootPath,
              projectId: added.project!.projectId,
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
      final createdResponse = await client
          .request(MessageTypes.agentCreateRequest, {
            'cwd': workspace.workspaceDirectory,
            'provider': 'codex',
            'model': 'fake',
            'mode': 'normal',
            'workspaceId': workspace.id,
            'projectPath': projectRootPath,
            'branch': 'main',
            'isWorktree': false,
            'initialPrompt': prompt,
            'clientMessageId': clientMessageId,
          });
      final created = AgentSummary.fromJson(
        createdResponse['agent'] as Map<String, Object?>,
      );
      final streamedAssistant = await assistantStream;
      expect(streamedAssistant.agentId, created.agentId);
      expect(
        (streamedAssistant.item as AssistantMessageItem).text,
        'Deterministic Flutter response.',
      );

      AgentSummary? fetched;
      for (var attempt = 0; attempt < 100; attempt++) {
        fetched = (await client.fetchAgent(created.agentId))?.agent;
        if (fetched?.runState == AgentRunState.idle) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(fetched?.workspaceId, workspace.id);
      expect(fetched?.runState, AgentRunState.idle);

      final timeline = await client.fetchAgentTimeline(
        agentId: created.agentId,
        limit: 100,
      );
      expect(timeline.error, isNull);
      final user = timeline.entries
          .map((entry) => entry.item)
          .whereType<UserMessageItem>()
          .single;
      expect(user.text, prompt);
      expect(user.clientMessageId, clientMessageId);
      expect(
        timeline.entries
            .map((entry) => entry.item)
            .whereType<AssistantMessageItem>()
            .single
            .text,
        'Deterministic Flutter response.',
      );
      expect(provider.prompts, [prompt]);
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
    scheduleMicrotask(() {
      _events
        ..add(
          const AssistantMessageComplete(
            itemId: 'deterministic-flutter-assistant-message',
            fullText: 'Deterministic Flutter response.',
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
