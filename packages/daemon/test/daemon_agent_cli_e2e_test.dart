import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/agent/timeline_store.dart';
import 'package:agent_daemon/src/cli/agent_command.dart';
import 'package:agent_daemon/src/cli/agent_logs_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
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
    const userMessage = UserMessageItem(id: 'user-item', text: 'Fix it');
    const assistantMessage = AssistantMessageItem(
      id: 'assistant-item',
      text: 'Done',
      complete: true,
    );
    final store = AgentStore(dataDir: home.path);
    await store.save(
      const PersistedAgent(
        summary: active,
        archived: false,
        epoch: 2,
        lastSeq: 3,
        items: [userMessage, assistantMessage, permission],
        rows: [
          TimelineRow(
            seq: 1,
            timestamp: '2026-07-29T12:00:01.000Z',
            item: userMessage,
          ),
          TimelineRow(
            seq: 2,
            timestamp: '2026-07-29T12:00:02.000Z',
            item: assistantMessage,
          ),
          TimelineRow(
            seq: 3,
            timestamp: '2026-07-29T12:00:03.000Z',
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

    final modeClient = _ModeClient();
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: home.path),
      dataDir: home.path,
      host: '127.0.0.1',
      port: 0,
      agentClients: {'codex': modeClient},
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

    final modes = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: [
          'mode',
          '--list',
          'agent-cli-act',
          '--host',
          host,
          '--json',
        ],
        environment: const {},
        writeOutput: modes.write,
      ),
      0,
    );
    expect((jsonDecode(modes.toString()) as List).map((mode) => mode['id']), [
      'auto',
      'auto-review',
      'full-access',
    ]);

    final changedMode = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: [
          'mode',
          'agent-cli-act',
          'full-access',
          '--host',
          host,
          '--json',
        ],
        environment: const {},
        writeOutput: changedMode.write,
      ),
      0,
    );
    expect(jsonDecode(changedMode.toString()), {
      'agentId': 'agent-c',
      'mode': 'full-access',
    });
    expect(modeClient.session.modeId, 'full-access');
    expect(
      handle.manager
          .list()
          .singleWhere((agent) => agent.agentId == active.agentId)
          .currentModeId,
      'full-access',
    );

    final logs = StringBuffer();
    expect(
      await runAgentLogsCommand(
        arguments: [
          active.agentId,
          '--tail',
          '2',
          '--filter',
          'text',
          '--host',
          host,
        ],
        environment: const {},
        writeOutput: logs.write,
      ),
      0,
    );
    expect(logs.toString(), '[User] Fix it\nDone\n');

    final followed = StringBuffer();
    final followErrors = StringBuffer();
    final stop = StreamController<void>();
    final follow = runAgentLogsCommand(
      arguments: [active.agentId, '--follow', '--tail', '1', '--host', host],
      environment: const {},
      stopSignals: stop.stream,
      writeOutput: followed.write,
      writeError: followErrors.write,
    );
    await _waitFor(
      () => followed.toString().contains('Following logs (last 1 entry'),
    );
    expect(
      handle.manager.upsertTimelineItem(
        active.agentId,
        const ErrorItem(id: 'live-error', message: 'live boom'),
      ),
      isTrue,
    );
    await _waitFor(
      () => followed.toString().contains('[Error] live boom'),
      debug: () => 'output=${followed.toString()} errors=$followErrors',
    );
    stop.add(null);
    await stop.close();
    expect(await follow, 0);
    expect(followErrors.toString(), isEmpty);

    await handle.manager.prompt(active.agentId, 'keep working');
    final stopped = StringBuffer();
    expect(
      await runAgentCommand(
        arguments: ['stop', 'agent-cli-act', '--host', host, '--json'],
        environment: const {},
        writeOutput: stopped.write,
      ),
      0,
    );
    expect(jsonDecode(stopped.toString()), {
      'stoppedCount': 1,
      'agentIds': [active.agentId],
    });
    expect(modeClient.session.interrupted, isTrue);
    expect(handle.manager.hasActiveAgentRun(active.agentId), isFalse);
  });
}

final class _ModeClient implements AgentClient {
  final _ModeSession session = _ModeSession();

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
  }) async => session;
}

final class _ModeSession implements ConfigurableAgentSession {
  final _events = StreamController<ProviderEvent>.broadcast();
  String? modeId;
  bool interrupted = false;

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {}

  @override
  Future<void> interrupt() async {
    interrupted = true;
    scheduleMicrotask(
      () => _events.add(const TurnFailed(error: 'interrupted')),
    );
  }

  @override
  Future<void> dispose() => _events.close();

  @override
  Future<AgentProviderNotice?> setMode(String modeId) async {
    this.modeId = modeId;
    return const AgentProviderNotice(
      type: AgentProviderNoticeType.info,
      message: 'mode changed',
    );
  }

  @override
  Future<void> setModel(String? modelId) async {}

  @override
  Future<AgentProviderNotice?> setThinkingOption(
    String? thinkingOptionId,
  ) async => null;

  @override
  Future<void> setFeature(String featureId, Object? value) async {}
}

Future<void> _waitFor(
  bool Function() predicate, {
  String Function()? debug,
}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition was not reached${debug == null ? '' : ': ${debug()}'}');
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
