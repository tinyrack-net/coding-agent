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
    'detach removes durable parentage without moving or archiving over WebSocket',
    () async {
      final home = Directory.systemTemp.createTempSync('daemon-agent-detach-');
      addTearDown(() => _deleteDirectoryEventually(home));
      const parentId = 'agent-detach-parent';
      const childId = 'agent-detach-child';
      const workspaceId = 'workspace-detach';
      final store = AgentStore(dataDir: home.path);
      await store.save(
        PersistedAgent(
          summary: AgentSummary(
            agentId: parentId,
            title: 'Parent',
            cwd: home.path,
            provider: 'codex',
            model: 'gpt-5.4',
            mode: AgentMode.normal,
            runState: AgentRunState.idle,
            createdAtMs: 1,
            workspaceId: workspaceId,
          ),
          archived: false,
          epoch: 1,
          lastSeq: 0,
          items: const [],
        ),
      );
      await store.save(
        PersistedAgent(
          summary: AgentSummary(
            agentId: childId,
            title: 'Stored child',
            cwd: home.path,
            provider: 'codex',
            model: 'gpt-5.4',
            mode: AgentMode.normal,
            runState: AgentRunState.closed,
            createdAtMs: 2,
            workspaceId: workspaceId,
            parentAgentId: parentId,
            labels: const {
              paseoParentAgentIdLabel: parentId,
              'role': 'reviewer',
            },
          ),
          archived: false,
          epoch: 1,
          lastSeq: 0,
          items: const [],
        ),
      );
      final registries = WorkspaceRegistries(dataDir: home.path);
      await registries.initialize();
      await registries.projects.upsert(
        createPersistedProjectRecord(
          projectId: 'project-detach',
          rootPath: home.path,
          kind: PersistedProjectKind.git,
          displayName: 'detach',
          createdAt: '2026-07-29T00:00:00.000Z',
          updatedAt: '2026-07-29T00:00:00.000Z',
        ),
      );
      await registries.workspaces.upsert(
        createPersistedWorkspaceRecord(
          workspaceId: workspaceId,
          projectId: 'project-detach',
          cwd: home.path,
          kind: PersistedWorkspaceKind.directory,
          displayName: 'detach',
          createdAt: '2026-07-29T00:00:00.000Z',
          updatedAt: '2026-07-29T00:00:00.000Z',
        ),
      );
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
        agentClients: {'codex': const _NoopClient()},
        log: (_) {},
      );
      addTearDown(handle.stop);
      final runStateBeforeDetach = handle.manager.get(childId)!.runState;

      final output = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: [
            'detach',
            'stored child',
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
        'agentId': childId,
        'status': 'detached',
      });

      final child = handle.manager.get(childId)!;
      expect(child.parentAgentId, isNull);
      expect(child.labels, {'role': 'reviewer'});
      expect(child.cwd, home.path);
      expect(child.workspaceId, workspaceId);
      expect(child.archivedAt, isNull);
      expect(child.runState, runStateBeforeDetach);
      expect(DateTime.tryParse(child.updatedAt ?? ''), isNotNull);

      final persisted = (await AgentStore(
        dataDir: home.path,
      ).loadAll()).singleWhere((record) => record.summary.agentId == childId);
      expect(persisted.summary.parentAgentId, isNull);
      expect(persisted.summary.labels, {'role': 'reviewer'});

      await handle.manager.archive(parentId);
      expect(handle.manager.get(parentId)?.archivedAt, isNotNull);
      expect(handle.manager.get(childId)?.archivedAt, isNull);
    },
  );
}

final class _NoopClient implements AgentClient {
  const _NoopClient();

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
  }) async => const _NoopSession();
}

final class _NoopSession implements AgentSession {
  const _NoopSession();

  @override
  Stream<ProviderEvent> get events => const Stream.empty();

  @override
  Future<void> prompt(String text) async {}

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> dispose() async {}
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
