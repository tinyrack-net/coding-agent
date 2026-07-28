import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_manager.dart';
import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/git/git_service.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_daemon/src/schedule/schedule_agent_runner.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_daemon/src/workspace/workspace_v2_service.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late _AutoClient client;
  late AgentManager manager;
  late WorkspaceRegistries registries;
  late WorkspaceV2Service workspaces;
  late List<({String workspaceId, String? agentId})> records;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('schedule-runner-');
    client = _AutoClient();
    manager = AgentManager(
      clients: {'codex': client},
      store: AgentStore(dataDir: temp.path),
      onStream: (_) {},
      onState: (_) {},
      onPermissionRequested: (_, __, ___, ____) {},
      onPermissionResolved: (_, __) {},
    );
    registries = WorkspaceRegistries(dataDir: temp.path);
    await registries.initialize();
    workspaces = WorkspaceV2Service(
      registries: registries,
      git: _DirectoryGitService(dataDir: temp.path),
      broadcast: (_, __) {},
    );
    records = [];
  });

  tearDown(() async {
    await manager.dispose();
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  ScheduleAgentRunner runner() => ScheduleAgentRunner(
    manager,
    workspaces,
    recordWorkspace:
        ({
          required scheduleId,
          required runId,
          required workspaceId,
          required agentId,
        }) async {
          records.add((workspaceId: workspaceId, agentId: agentId));
        },
  );

  test('existing-agent target receives the exact system envelope', () async {
    final agent = await manager.createAgent(
      cwd: temp.path,
      provider: 'codex',
      model: 'gpt-5.4',
      mode: AgentMode.normal,
    );
    final result = await runner().call(
      _schedule(
        name: 'Nightly review',
        target: AgentScheduleTarget(agentId: agent.agentId),
      ),
      'run-1',
    );

    expect(client.sessions.single.prompts, [
      '<paseo-system>\n'
          'Schedule "Nightly review" fired (id=deadbeef, run=run-1).\n'
          'Review the branch\n'
          '</paseo-system>',
    ]);
    expect(result.agentId, agent.agentId);
    expect(result.output, 'Schedule finished');
  });

  test('new-agent run records and archives its durable workspace', () async {
    final result = await runner().call(
      _schedule(
        target: NewAgentScheduleTarget(
          config: ScheduleNewAgentConfig(
            provider: 'codex',
            cwd: temp.path,
            model: 'gpt-5.4',
            archiveOnFinish: true,
            mcpServers: const {
              'review': {'type': 'http', 'url': 'http://127.0.0.1/mcp'},
            },
          ),
        ),
      ),
      'run-2',
    );

    expect(result.workspaceId, isNotNull);
    expect(manager.get(result.agentId!)!.title, 'Review the branch');
    expect(records, hasLength(2));
    expect(records.first.agentId, isNull);
    expect(records.last.agentId, result.agentId);
    expect(manager.list(), isEmpty);
    expect(client.mcpCalls.single, {
      'review': {'type': 'http', 'url': 'http://127.0.0.1/mcp'},
    });
    expect(
      (await registries.workspaces.get(result.workspaceId!))?.archivedAt,
      isNotNull,
    );
  });

  test('missing existing agent is a permanent target-gone error', () async {
    await expectLater(
      runner().call(
        _schedule(
          target: const AgentScheduleTarget(
            agentId: '11111111-1111-4111-8111-111111111111',
          ),
        ),
        'run-3',
      ),
      throwsA(isA<StateError>()),
    );
  });
}

StoredSchedule _schedule({String? name, required ScheduleTarget target}) =>
    StoredSchedule(
      summary: ScheduleSummary(
        id: 'deadbeef',
        name: name,
        prompt: 'Review the branch',
        cadence: const CronScheduleCadence(expression: '0 9 * * *'),
        target: target,
        status: ScheduleStatus.active,
        createdAt: '2026-07-27T00:00:00.000Z',
        updatedAt: '2026-07-27T00:00:00.000Z',
        nextRunAt: '2026-07-28T00:00:00.000Z',
        lastRunAt: null,
        pausedAt: null,
        expiresAt: null,
        maxRuns: null,
      ),
      runs: const [],
    );

final class _AutoClient implements AgentClient, McpAgentClient {
  final sessions = <_AutoSession>[];
  final mcpCalls = <Map<String, Object?>>[];

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
    final session = _AutoSession();
    sessions.add(session);
    return session;
  }

  @override
  Future<AgentSession> createSessionWithMcp({
    required String cwd,
    required String model,
    required AgentMode mode,
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? systemPrompt,
    String? sessionId,
    List<TimelineItem> initialHistory = const [],
    Map<String, Object?> mcpServers = const {},
  }) {
    mcpCalls.add(mcpServers);
    return createSession(
      cwd: cwd,
      model: model,
      mode: mode,
      modeId: modeId,
      thinkingOptionId: thinkingOptionId,
      featureValues: featureValues,
      sessionId: sessionId,
      initialHistory: initialHistory,
    );
  }
}

final class _AutoSession implements AgentSession {
  final _events = StreamController<ProviderEvent>.broadcast();
  final prompts = <String>[];

  @override
  Stream<ProviderEvent> get events => _events.stream;

  @override
  Future<void> prompt(String text) async {
    prompts.add(text);
    scheduleMicrotask(() {
      _events.add(
        const AssistantMessageComplete(
          itemId: 'answer',
          fullText: 'Schedule finished',
        ),
      );
      _events.add(const TurnCompleted());
    });
  }

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> dispose() async {
    if (!_events.isClosed) await _events.close();
  }
}

final class _DirectoryGitService extends GitService {
  _DirectoryGitService({required super.dataDir});

  @override
  Future<bool> isGitRepo(String path) async => false;
}
