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
    'reload unarchives and rehydrates provider history over WebSocket',
    () async {
      final home = Directory.systemTemp.createTempSync('daemon-agent-reload-');
      addTearDown(() => _deleteDirectoryEventually(home));
      const agentId = 'agent-reload-target';
      const workspaceId = 'workspace-reload';
      await AgentStore(dataDir: home.path).save(
        PersistedAgent(
          summary: AgentSummary(
            agentId: agentId,
            title: 'Reload target',
            cwd: home.path,
            provider: 'codex',
            model: 'gpt-5.4',
            mode: AgentMode.normal,
            runState: AgentRunState.closed,
            createdAtMs: 1,
            workspaceId: workspaceId,
            archivedAt: '2026-07-28T00:00:00.000Z',
          ),
          archived: true,
          epoch: 1,
          lastSeq: 1,
          items: const [
            AssistantMessageItem(
              id: 'stale',
              text: 'stale local history',
              complete: true,
            ),
          ],
        ),
      );
      final registries = WorkspaceRegistries(dataDir: home.path);
      await registries.initialize();
      await registries.projects.upsert(
        createPersistedProjectRecord(
          projectId: 'project-reload',
          rootPath: home.path,
          kind: PersistedProjectKind.git,
          displayName: 'reload',
          createdAt: '2026-07-29T00:00:00.000Z',
          updatedAt: '2026-07-29T00:00:00.000Z',
        ),
      );
      await registries.workspaces.upsert(
        createPersistedWorkspaceRecord(
          workspaceId: workspaceId,
          projectId: 'project-reload',
          cwd: home.path,
          kind: PersistedWorkspaceKind.directory,
          displayName: 'reload',
          createdAt: '2026-07-29T00:00:00.000Z',
          updatedAt: '2026-07-29T00:00:00.000Z',
        ),
      );
      final provider = _ReloadClient();
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
        agentClients: {'codex': provider},
        log: (_) {},
      );
      addTearDown(handle.stop);
      expect(handle.manager.get(agentId)?.archivedAt, isNotNull);

      final output = StringBuffer();
      expect(
        await runAgentCommand(
          arguments: [
            'reload',
            'reload target',
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
        'status': 'reloaded',
        'timelineSize': 2,
      });
      expect(provider.createCount, 1);

      final refreshed = handle.manager.get(agentId)!;
      expect(refreshed.archivedAt, isNull);
      expect(refreshed.runState, AgentRunState.idle);
      final timeline = handle.manager.fetchTimeline(agentId);
      expect(timeline.epoch, greaterThan(1));
      expect(timeline.items.map((item) => item.id), [
        'provider-user',
        'provider-answer',
      ]);

      final persisted = (await AgentStore(dataDir: home.path).loadAll()).single;
      expect(persisted.archived, isFalse);
      expect(persisted.summary.archivedAt, isNull);
      expect(persisted.items.map((item) => item.id), [
        'provider-user',
        'provider-answer',
      ]);
    },
  );
}

final class _ReloadClient implements AgentClient {
  int createCount = 0;

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
  }) async {
    createCount++;
    return _ReloadSession();
  }
}

final class _ReloadSession
    implements AgentSession, HistoryRestoringAgentSession {
  final _events = StreamController<ProviderEvent>.broadcast();

  @override
  List<TimelineItem> get restoredHistory => const [
    UserMessageItem(id: 'provider-user', text: 'provider prompt'),
    AssistantMessageItem(
      id: 'provider-answer',
      text: 'provider answer',
      complete: true,
    ),
  ];

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {}

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
