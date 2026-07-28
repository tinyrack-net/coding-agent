import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/agent/timeline_store.dart';
import 'package:agent_daemon/src/cli/agent_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

void main() {
  test('agent ls and inspect cross the real daemon WebSocket', () async {
    final home = Directory.systemTemp.createTempSync('daemon-agent-cli-e2e-');
    addTearDown(() => _deleteDirectoryEventually(home));
    const active = AgentSummary(
      agentId: 'agent-cli-active',
      title: 'Active agent',
      cwd: r'C:\workspace\active',
      provider: 'codex',
      model: 'gpt-5.4',
      mode: AgentMode.normal,
      runState: AgentRunState.idle,
      createdAtMs: 1785326400000,
      updatedAt: '2026-07-29T12:00:00.000Z',
      lastUsage: AgentUsage(
        inputTokens: 100,
        cachedInputTokens: 25,
        outputTokens: 50,
        totalCostUsd: 0.125,
      ),
      thinkingOptionId: 'high',
      currentModeId: 'auto-review',
      workspaceId: 'workspace-active',
      parentAgentId: 'parent-agent',
      labels: {'surface': 'workspace', 'paseo.parent-agent-id': 'parent-agent'},
    );
    const permission = PermissionItem(
      id: 'permission-item',
      permissionId: 'permission-1',
      toolName: 'Bash',
      status: PermissionStatus.pending,
      detail: PlainTextDetail(label: 'Command', text: 'git status'),
    );
    final store = AgentStore(dataDir: home.path);
    await store.save(
      const PersistedAgent(
        summary: active,
        archived: false,
        epoch: 2,
        lastSeq: 1,
        items: [permission],
        rows: [
          TimelineRow(
            seq: 1,
            timestamp: '2026-07-29T12:00:01.000Z',
            item: permission,
          ),
        ],
      ),
    );
    await store.save(
      const PersistedAgent(
        summary: AgentSummary(
          agentId: 'agent-cli-archived',
          title: 'Archived agent',
          cwd: r'C:\workspace\archived',
          provider: 'codex',
          model: 'gpt-5.4',
          mode: AgentMode.normal,
          runState: AgentRunState.closed,
          createdAtMs: 1785322800000,
          workspaceId: 'workspace-archived',
          archivedAt: '2026-07-29T12:30:00.000Z',
        ),
        archived: true,
        epoch: 1,
        lastSeq: 0,
        items: [],
      ),
    );
    final registries = WorkspaceRegistries(dataDir: home.path);
    await registries.initialize();
    await registries.projects.upsert(
      createPersistedProjectRecord(
        projectId: 'project',
        rootPath: r'C:\workspace',
        kind: PersistedProjectKind.git,
        displayName: 'workspace',
        createdAt: '2026-07-29T11:00:00.000Z',
        updatedAt: '2026-07-29T12:00:00.000Z',
      ),
    );
    await registries.workspaces.upsert(
      createPersistedWorkspaceRecord(
        workspaceId: 'workspace-active',
        projectId: 'project',
        cwd: active.cwd,
        kind: PersistedWorkspaceKind.directory,
        displayName: 'active',
        createdAt: '2026-07-29T11:00:00.000Z',
        updatedAt: '2026-07-29T12:00:00.000Z',
      ),
    );
    await registries.workspaces.upsert(
      createPersistedWorkspaceRecord(
        workspaceId: 'workspace-archived',
        projectId: 'project',
        cwd: r'C:\workspace\archived',
        kind: PersistedWorkspaceKind.directory,
        displayName: 'archived',
        createdAt: '2026-07-29T10:00:00.000Z',
        updatedAt: '2026-07-29T12:30:00.000Z',
        archivedAt: '2026-07-29T12:30:00.000Z',
      ),
    );

    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: home.path),
      dataDir: home.path,
      host: '127.0.0.1',
      port: 0,
      log: (_) {},
    );
    addTearDown(handle.stop);
    final host = '127.0.0.1:${handle.server.port}';

    final listed = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: ['ls', '--global', '--host', host, '--json'],
        environment: const {},
        now: () => DateTime.parse('2026-07-29T13:00:00Z'),
        writeOutput: listed.write,
      ),
      0,
    );
    final activeRows = (jsonDecode(listed.toString()) as List).cast<Map>();
    expect(activeRows, hasLength(1));
    expect(activeRows.single['id'], active.agentId);
    expect(activeRows.single['provider'], 'codex/gpt-5.4');
    expect(activeRows.single['thinking'], 'high');

    final all = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: ['ls', '--all', '--global', '--host', host, '--json'],
        environment: const {},
        now: () => DateTime.parse('2026-07-29T13:00:00Z'),
        writeOutput: all.write,
      ),
      0,
    );
    expect((jsonDecode(all.toString()) as List), hasLength(2));

    final inspected = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: ['inspect', 'agent-cli-act', '--host', host, '--json'],
        environment: const {},
        writeOutput: inspected.write,
      ),
      0,
    );
    final detail = jsonDecode(inspected.toString()) as Map<String, dynamic>;
    expect(detail['Id'], active.agentId);
    expect(detail['Model'], 'gpt-5.4');
    expect(detail['Mode'], 'auto-review');
    expect(detail['LastUsage'], {
      'InputTokens': 100,
      'OutputTokens': 50,
      'CachedTokens': 25,
      'CostUsd': 0.125,
    });
    expect(detail['Capabilities']['Persistence'], isTrue);
    expect((detail['AvailableModes'] as List).map((mode) => mode['id']), [
      'auto',
      'auto-review',
      'full-access',
    ]);
    expect(detail['PendingPermissions'], [
      {'id': 'permission-1', 'tool': 'Bash'},
    ]);
    expect(detail['ParentAgentId'], 'parent-agent');
  });
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
