import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/cli/agent_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

void main() {
  test(
    'delete interrupts and hard-deletes only its target over WebSocket',
    () async {
      final home = Directory.systemTemp.createTempSync('daemon-agent-delete-');
      addTearDown(() => _deleteDirectoryEventually(home));
      const parentId = 'agent-delete-parent';
      const childId = 'agent-delete-child';
      final store = AgentStore(dataDir: home.path);
      for (final entry in const [
        (id: parentId, parentId: null, createdAtMs: 1),
        (id: childId, parentId: parentId, createdAtMs: 2),
      ]) {
        await store.save(
          PersistedAgent(
            summary: AgentSummary(
              agentId: entry.id,
              title: entry.id,
              cwd: home.path,
              provider: 'codex',
              model: 'gpt-5.4',
              mode: AgentMode.normal,
              runState: AgentRunState.idle,
              createdAtMs: entry.createdAtMs,
              parentAgentId: entry.parentId,
              workspaceId: 'workspace-delete',
            ),
            archived: false,
            epoch: 1,
            lastSeq: 0,
            items: const [],
          ),
        );
      }
      final registries = WorkspaceRegistries(dataDir: home.path);
      await registries.initialize();
      await registries.projects.upsert(
        createPersistedProjectRecord(
          projectId: 'project-delete',
          rootPath: home.path,
          kind: PersistedProjectKind.git,
          displayName: 'delete',
          createdAt: '2026-07-29T00:00:00.000Z',
          updatedAt: '2026-07-29T00:00:00.000Z',
        ),
      );
      await registries.workspaces.upsert(
        createPersistedWorkspaceRecord(
          workspaceId: 'workspace-delete',
          projectId: 'project-delete',
          cwd: home.path,
          kind: PersistedWorkspaceKind.directory,
          displayName: 'delete',
          createdAt: '2026-07-29T00:00:00.000Z',
          updatedAt: '2026-07-29T00:00:00.000Z',
        ),
      );
      final provider = _DeleteClient();
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
        agentClients: {'codex': provider},
        log: (_) {},
      );
      addTearDown(handle.stop);
      await handle.manager.prompt(parentId, 'keep running');
      expect(handle.manager.hasActiveAgentRun(parentId), isTrue);

      final output = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: [
            'delete',
            'agent-delete-par',
            '--host',
            '127.0.0.1:${handle.server.port}',
            '--json',
          ],
          environment: const {},
          writeOutput: output.write,
        ),
        0,
      );
      expect(jsonDecode(output.toString()), {
        'deletedCount': 1,
        'agentIds': [parentId],
      });
      expect(provider.interruptCount, 1);
      expect(handle.manager.get(parentId), isNull);
      expect(handle.manager.get(childId), isNotNull);

      var persisted = await AgentStore(dataDir: home.path).loadAll();
      expect(persisted.map((record) => record.summary.agentId), [childId]);
      await Future<void>.delayed(const Duration(milliseconds: 650));
      persisted = await AgentStore(dataDir: home.path).loadAll();
      expect(persisted.map((record) => record.summary.agentId), [childId]);
    },
  );
}

final class _DeleteClient implements AgentClient {
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
  }) async => _DeleteSession(this);
}

final class _DeleteSession implements AgentSession {
  _DeleteSession(this.client);

  final _DeleteClient client;
  final _events = StreamController<ProviderEvent>.broadcast();

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {}

  @override
  Future<void> interrupt() async {
    client.interruptCount++;
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
