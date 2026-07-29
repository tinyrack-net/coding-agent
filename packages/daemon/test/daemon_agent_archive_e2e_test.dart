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
  test('archive settles a run and cascades over the real WebSocket', () async {
    final home = Directory.systemTemp.createTempSync('daemon-agent-archive-');
    addTearDown(() => _deleteDirectoryEventually(home));
    const parentId = 'agent-archive-parent';
    const childId = 'agent-archive-child';
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
            workspaceId: 'workspace-archive',
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
        projectId: 'project-archive',
        rootPath: home.path,
        kind: PersistedProjectKind.git,
        displayName: 'archive',
        createdAt: '2026-07-29T00:00:00.000Z',
        updatedAt: '2026-07-29T00:00:00.000Z',
      ),
    );
    await registries.workspaces.upsert(
      createPersistedWorkspaceRecord(
        workspaceId: 'workspace-archive',
        projectId: 'project-archive',
        cwd: home.path,
        kind: PersistedWorkspaceKind.directory,
        displayName: 'archive',
        createdAt: '2026-07-29T00:00:00.000Z',
        updatedAt: '2026-07-29T00:00:00.000Z',
      ),
    );
    final provider = _ArchiveClient();
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
          'archive',
          'parent',
          '--force',
          '--host',
          '127.0.0.1:${handle.server.port}',
          '--json',
        ],
        environment: const {},
        writeOutput: output.write,
      ),
      0,
    );
    final response = jsonDecode(output.toString()) as Map<String, dynamic>;
    expect(response['agentId'], parentId);
    expect(response['status'], 'archived');
    final archivedAt = response['archivedAt'] as String;
    expect(DateTime.tryParse(archivedAt), isNotNull);
    expect(provider.interruptCount, 1);
    expect(handle.manager.hasActiveAgentRun(parentId), isFalse);

    final parent = handle.manager.get(parentId)!;
    final child = handle.manager.get(childId)!;
    expect(parent.archivedAt, archivedAt);
    expect(parent.updatedAt, archivedAt);
    expect(parent.runState, AgentRunState.closed);
    expect(child.archivedAt, isNotNull);
    expect(child.updatedAt, child.archivedAt);
    expect(child.runState, AgentRunState.closed);

    final persisted = await AgentStore(dataDir: home.path).loadAll();
    expect(persisted, hasLength(2));
    expect(persisted.every((record) => record.archived), isTrue);
    expect(
      persisted.every(
        (record) =>
            record.summary.archivedAt != null &&
            record.summary.updatedAt == record.summary.archivedAt,
      ),
      isTrue,
    );
  });
}

final class _ArchiveClient implements AgentClient {
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
  }) async => _ArchiveSession(this);
}

final class _ArchiveSession implements AgentSession {
  _ArchiveSession(this.client);

  final _ArchiveClient client;
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
