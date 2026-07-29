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
  test('update patches an archived agent over the real WebSocket', () async {
    final home = Directory.systemTemp.createTempSync('daemon-agent-update-');
    addTearDown(() => _deleteDirectoryEventually(home));
    const agentId = 'agent-update-full-id';
    const workspaceId = 'workspace-update';
    final store = AgentStore(dataDir: home.path);
    await store.save(
      PersistedAgent(
        summary: AgentSummary(
          agentId: agentId,
          title: 'Before update',
          cwd: home.path,
          provider: 'codex',
          model: 'gpt-5.4',
          mode: AgentMode.normal,
          runState: AgentRunState.closed,
          createdAtMs: 1,
          workspaceId: workspaceId,
          labels: const {'owner': 'before'},
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
        projectId: 'project-update',
        rootPath: home.path,
        kind: PersistedProjectKind.git,
        displayName: 'update',
        createdAt: '2026-07-29T00:00:00.000Z',
        updatedAt: '2026-07-29T00:00:00.000Z',
      ),
    );
    await registries.workspaces.upsert(
      createPersistedWorkspaceRecord(
        workspaceId: workspaceId,
        projectId: 'project-update',
        cwd: home.path,
        kind: PersistedWorkspaceKind.directory,
        displayName: 'update',
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
    await handle.manager.archive(agentId);

    final output = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: [
          'update',
          'agent-update-full',
          '--name',
          '  After update  ',
          '--label',
          'owner=after,empty=',
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
      'agentId': agentId,
      'name': 'After update',
      'labels': 'owner=after,empty=',
    });

    final updated = handle.manager.get(agentId)!;
    expect(updated.title, 'After update');
    expect(updated.labels, {'owner': 'after', 'empty': ''});
    expect(updated.cwd, home.path);
    expect(updated.workspaceId, workspaceId);
    expect(updated.archivedAt, isNotNull);

    final persisted = (await AgentStore(
      dataDir: home.path,
    ).loadAll()).singleWhere((record) => record.summary.agentId == agentId);
    expect(persisted.archived, isTrue);
    expect(persisted.summary.title, 'After update');
    expect(persisted.summary.labels, {'owner': 'after', 'empty': ''});
  });
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
