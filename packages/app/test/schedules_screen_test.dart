import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/screens/schedules_screen.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/state/schedules_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('empty state preserves Paseo schedule copy and create action', (
    tester,
  ) async {
    await _pump(tester, const []);

    expect(find.text('Schedules'), findsOneWidget);
    expect(find.text('No active schedules'), findsOneWidget);
    expect(find.text('Schedules run agents on a cadence.'), findsOneWidget);
    expect(find.text('New schedule'), findsOneWidget);

    await tester.tap(find.text('New schedule'));
    await tester.pumpAndSettle();
    expect(find.text('Prompt'), findsOneWidget);
    expect(find.text('Cadence'), findsOneWidget);
    expect(find.text('Isolation'), findsOneWidget);
    expect(find.text('Archive on finish'), findsOneWidget);
  });

  testWidgets('active and ended filters partition schedule rows', (
    tester,
  ) async {
    await _pump(tester, [
      _schedule(id: 'active', status: ScheduleStatus.active),
      _schedule(id: 'ended', status: ScheduleStatus.completed),
    ]);

    expect(find.text('Active schedule'), findsOneWidget);
    expect(find.text('Ended schedule'), findsNothing);
    expect(find.text('Active'), findsNWidgets(2));

    await tester.tap(find.text('Ended').first);
    await tester.pumpAndSettle();
    expect(find.text('Active schedule'), findsNothing);
    expect(find.text('Ended schedule'), findsOneWidget);
    expect(find.text('Finished'), findsOneWidget);
  });

  testWidgets('row opens the edit sheet with frozen values', (tester) async {
    await _pump(tester, [_schedule(id: 'active')]);

    await tester.tap(find.text('Active schedule'));
    await tester.pumpAndSettle();

    expect(find.text('Edit schedule'), findsOneWidget);
    expect(find.text('Save changes'), findsOneWidget);
    expect(find.widgetWithText(TextBox, 'Review the branch'), findsOneWidget);
  });

  testWidgets('edit sheet submits cadence and new-agent configuration', (
    tester,
  ) async {
    final notifier = _FakeSchedulesNotifier([_schedule(id: 'active')]);
    await _pumpWithNotifier(tester, notifier);
    await tester.tap(find.text('Active schedule'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextBox);
    await tester.enterText(fields.at(1), 'Updated prompt');
    await tester.enterText(fields.at(2), '15 * * * *');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(notifier.updatedId, 'active');
    expect(notifier.updatedChanges!['prompt'], 'Updated prompt');
    expect(notifier.updatedChanges!['cadence'], {
      'type': 'cron',
      'expression': '15 * * * *',
      'timezone': 'UTC',
    });
    expect(notifier.updatedChanges!['newAgentConfig'], isA<Map>());
  });

  testWidgets('load error retries through the schedule notifier', (
    tester,
  ) async {
    final notifier = _ErrorSchedulesNotifier();
    await _pumpWithNotifier(tester, notifier);

    expect(find.text('Unable to load schedules'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(notifier.reloadCount, 1);
    expect(find.text('No active schedules'), findsOneWidget);
  });

  testWidgets('settling hosts keep the schedules body in loading state', (
    tester,
  ) async {
    await _pumpWithNotifier(
      tester,
      _FakeSchedulesNotifier.aggregated(
        const AggregatedSchedulesState(connecting: true),
      ),
      settle: false,
    );

    expect(find.byType(ProgressRing), findsOneWidget);
    expect(find.text('No active schedules'), findsNothing);
  });

  testWidgets('create form validates and submits a new-agent schedule', (
    tester,
  ) async {
    final notifier = _FakeSchedulesNotifier(const []);
    await _pumpWithNotifier(tester, notifier);
    await tester.tap(find.text('New schedule').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create schedule'));
    await tester.pumpAndSettle();
    expect(find.text('Prompt is required.'), findsOneWidget);

    final fields = find.byType(TextBox);
    await tester.enterText(fields.at(1), 'Run tests');
    await tester.enterText(fields.at(2), '*/5 * * * *');
    await tester.enterText(fields.at(3), 'codex');
    await tester.enterText(fields.at(4), 'gpt-5.4');
    await tester.enterText(fields.at(5), 'C:/repo');
    await tester.enterText(fields.at(6), '2');
    await tester.tap(find.text('Create schedule'));
    await tester.pumpAndSettle();

    expect(notifier.createdPrompt, 'Run tests');
    expect(notifier.createdMaxRuns, 2);
    expect(find.text('Create schedule'), findsNothing);
  });

  testWidgets('cadence editor applies presets and previews custom cron', (
    tester,
  ) async {
    await _pump(tester, const []);
    await tester.tap(find.text('New schedule'));
    await tester.pumpAndSettle();

    expect(find.text('Every hour'), findsWidgets);
    await tester.tap(find.text('Every hour').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weekdays 9:00').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextBox, '0 9 * * 1-5'), findsOneWidget);
    expect(find.text('Weekdays at 09:00 UTC'), findsOneWidget);

    final cron = find.byType(TextBox).at(2);
    await tester.enterText(cron, '61 * * * *');
    await tester.pump();
    expect(find.text('Invalid minute value'), findsOneWidget);

    await tester.enterText(cron, '30 8 * * 1-5');
    await tester.pump();
    expect(find.text('Custom cron'), findsWidgets);
    expect(find.text('Weekdays at 08:30 UTC'), findsOneWidget);
  });

  testWidgets('paused row menu resumes, runs, and confirms deletion', (
    tester,
  ) async {
    final notifier = _FakeSchedulesNotifier([
      _schedule(id: 'paused', status: ScheduleStatus.paused),
    ]);
    await _pumpWithNotifier(tester, notifier);
    expect(find.text('Paused'), findsOneWidget);

    await tester.tap(find.byIcon(FluentIcons.more_vertical));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume schedule'));
    await tester.pumpAndSettle();
    expect(notifier.resumed, ['paused']);

    await tester.tap(find.byIcon(FluentIcons.more_vertical));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run now'));
    await tester.pumpAndSettle();
    expect(notifier.ran, ['paused']);

    await tester.tap(find.byIcon(FluentIcons.more_vertical));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete schedule'));
    await tester.pumpAndSettle();
    expect(find.textContaining('This cannot be undone'), findsOneWidget);
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(notifier.deleted, ['paused']);
  });

  testWidgets('agent target and every cadence render without execution menu', (
    tester,
  ) async {
    final schedule = ScheduleSummary(
      id: 'agent',
      name: null,
      prompt: 'Heartbeat',
      cadence: const EveryScheduleCadence(everyMs: 3600000),
      target: const AgentScheduleTarget(
        agentId: '11111111-1111-4111-8111-111111111111',
      ),
      status: ScheduleStatus.active,
      createdAt: DateTime.now()
          .subtract(const Duration(minutes: 2))
          .toUtc()
          .toIso8601String(),
      updatedAt: 'updated',
      nextRunAt: DateTime.now()
          .add(const Duration(hours: 1))
          .toUtc()
          .toIso8601String(),
      lastRunAt: DateTime.now()
          .subtract(const Duration(hours: 1))
          .toUtc()
          .toIso8601String(),
      pausedAt: null,
      expiresAt: null,
      maxRuns: null,
    );
    await _pump(tester, [schedule]);

    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('Agent unavailable'), findsOneWidget);
    expect(find.textContaining('Every'), findsOneWidget);
    await tester.tap(find.byIcon(FluentIcons.more_vertical));
    await tester.pumpAndSettle();
    expect(find.text('Run now'), findsNothing);
    expect(find.text('Delete schedule'), findsOneWidget);
  });

  testWidgets('multi-host rows expose host filter and partial host errors', (
    tester,
  ) async {
    final notifier = _FakeSchedulesNotifier.aggregated(
      AggregatedSchedulesState(
        schedules: [
          AggregatedSchedule(
            serverId: 'server-a',
            serverName: 'Local',
            schedule: _schedule(id: 'local'),
          ),
          AggregatedSchedule(
            serverId: 'server-b',
            serverName: 'Remote',
            schedule: _schedule(id: 'remote', name: 'Remote schedule'),
          ),
        ],
        hostErrors: const [
          ScheduleHostError(
            serverId: 'server-b',
            serverName: 'Remote',
            message: 'offline',
          ),
        ],
      ),
    );
    await _pumpWithNotifier(tester, notifier, hosts: _twoHosts);

    expect(find.text('All hosts'), findsOneWidget);
    expect(find.text('Remote: Could not load schedules'), findsOneWidget);
    expect(find.textContaining('Local ·'), findsOneWidget);
    expect(find.textContaining('Remote ·'), findsOneWidget);

    await tester.tap(find.text('All hosts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remote').last);
    await tester.pumpAndSettle();
    expect(find.text('Remote schedule'), findsOneWidget);
    expect(find.text('Active schedule'), findsNothing);
  });

  testWidgets('derived ended states override raw schedule status', (
    tester,
  ) async {
    final notifier = _FakeSchedulesNotifier.aggregated(
      AggregatedSchedulesState(
        schedules: [
          AggregatedSchedule(
            serverId: 'server-a',
            serverName: 'Local',
            schedule: _schedule(
              id: 'expired',
              name: 'Expired schedule',
              expiresAt: '2020-01-01T00:00:00.000Z',
            ),
          ),
          AggregatedSchedule(
            serverId: 'server-a',
            serverName: 'Local',
            schedule: _schedule(
              id: 'gone',
              name: 'Gone schedule',
              target: const AgentScheduleTarget(
                agentId: '11111111-1111-4111-8111-111111111111',
              ),
            ),
          ),
        ],
      ),
    );
    await _pumpWithNotifier(
      tester,
      notifier,
      agentDirectories: const {'server-a': {}},
    );

    expect(find.text('Expired schedule'), findsNothing);
    await tester.tap(find.text('Ended'));
    await tester.pumpAndSettle();
    expect(find.text('Expired'), findsOneWidget);
    expect(find.text('Target gone'), findsOneWidget);
    expect(find.text('Agent unavailable'), findsOneWidget);
  });

  testWidgets('editing a multi-host row mutates its owning host', (
    tester,
  ) async {
    final notifier = _FakeSchedulesNotifier.aggregated(
      AggregatedSchedulesState(
        schedules: [
          AggregatedSchedule(
            serverId: 'server-b',
            serverName: 'Remote',
            schedule: _schedule(id: 'remote', name: 'Remote schedule'),
          ),
        ],
      ),
    );
    await _pumpWithNotifier(tester, notifier, hosts: _twoHosts);

    await tester.tap(find.text('Remote schedule'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(notifier.updatedServerId, 'server-b');
    expect(notifier.updatedId, 'remote');
  });

  testWidgets('create form targets the selected host', (tester) async {
    final notifier = _FakeSchedulesNotifier(const []);
    await _pumpWithNotifier(tester, notifier, hosts: _twoHosts);

    await tester.tap(find.text('New schedule'));
    await tester.pumpAndSettle();
    expect(find.text('Host'), findsOneWidget);
    await tester.tap(find.text('Local').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remote').last);
    await tester.pumpAndSettle();

    final fields = find.byType(TextBox);
    await tester.enterText(fields.at(1), 'Run tests');
    await tester.enterText(fields.at(2), '*/5 * * * *');
    await tester.enterText(fields.at(3), 'codex');
    await tester.enterText(fields.at(5), 'C:/repo');
    await tester.tap(find.text('Create schedule'));
    await tester.pumpAndSettle();

    expect(notifier.createdServerId, 'server-b');
  });
}

Future<void> _pump(WidgetTester tester, List<ScheduleSummary> schedules) async {
  await _pumpWithNotifier(tester, _FakeSchedulesNotifier(schedules));
}

Future<void> _pumpWithNotifier(
  WidgetTester tester,
  _FakeSchedulesNotifier notifier, {
  List<HostProfile> hosts = _oneHost,
  Map<String, Map<String, AgentSummary>> agentDirectories = const {},
  bool settle = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        aggregatedSchedulesProvider.overrideWith(() => notifier),
        hostRegistryProvider.overrideWith(() => _ScheduleHostRegistry(hosts)),
        agentDirectoryReplicaStoreProvider.overrideWith(
          () => _ScheduleAgentStore(agentDirectories),
        ),
      ],
      child: FluentApp(theme: buildAppTheme(), home: const SchedulesScreen()),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

class _FakeSchedulesNotifier extends AggregatedSchedulesNotifier {
  _FakeSchedulesNotifier(this.initial) : initialState = null;
  _FakeSchedulesNotifier.aggregated(this.initialState) : initial = const [];

  final List<ScheduleSummary> initial;
  final AggregatedSchedulesState? initialState;
  String? createdPrompt;
  String? createdServerId;
  int? createdMaxRuns;
  final resumed = <String>[];
  final paused = <String>[];
  final ran = <String>[];
  final deleted = <String>[];
  String? updatedId;
  String? updatedServerId;
  Map<String, Object?>? updatedChanges;

  @override
  Future<AggregatedSchedulesState> build() async =>
      initialState ??
      AggregatedSchedulesState(
        schedules: [
          for (final schedule in initial)
            AggregatedSchedule(
              serverId: 'server-a',
              serverName: 'Local',
              schedule: schedule,
            ),
        ],
      );

  @override
  Future<ScheduleSummary> create(
    String serverId, {
    required String prompt,
    required String? name,
    required ScheduleCadence cadence,
    required ScheduleTarget target,
    int? maxRuns,
    String? expiresAt,
    bool runOnCreate = false,
  }) async {
    createdServerId = serverId;
    createdPrompt = prompt;
    createdMaxRuns = maxRuns;
    return _schedule(id: 'created');
  }

  @override
  Future<ScheduleSummary> resume(String serverId, String scheduleId) async {
    resumed.add(scheduleId);
    return _schedule(id: scheduleId);
  }

  @override
  Future<ScheduleSummary> pause(String serverId, String scheduleId) async {
    paused.add(scheduleId);
    return _schedule(id: scheduleId, status: ScheduleStatus.paused);
  }

  @override
  Future<ScheduleSummary> updateSchedule(
    String serverId,
    String scheduleId,
    Map<String, Object?> changes,
  ) async {
    updatedServerId = serverId;
    updatedId = scheduleId;
    updatedChanges = changes;
    return _schedule(id: scheduleId);
  }

  @override
  Future<ScheduleSummary> runOnce(String serverId, String scheduleId) async {
    ran.add(scheduleId);
    return _schedule(id: scheduleId);
  }

  @override
  Future<void> delete(String serverId, String scheduleId) async {
    deleted.add(scheduleId);
  }
}

final class _ErrorSchedulesNotifier extends _FakeSchedulesNotifier {
  _ErrorSchedulesNotifier() : super(const []);

  int reloadCount = 0;

  @override
  Future<AggregatedSchedulesState> build() async {
    throw StateError('offline');
  }

  @override
  Future<void> reload() async {
    reloadCount++;
    state = const AsyncData(AggregatedSchedulesState());
  }
}

final class _ScheduleHostRegistry extends HostRegistryNotifier {
  _ScheduleHostRegistry(this.hosts);

  final List<HostProfile> hosts;

  @override
  HostRegistryState build() =>
      HostRegistryState(hosts: hosts, activeServerId: 'server-a', loaded: true);
}

final class _ScheduleAgentStore extends AgentDirectoryReplicaStoreNotifier {
  _ScheduleAgentStore(this.directories);

  final Map<String, Map<String, AgentSummary>> directories;

  @override
  Map<String, Map<String, AgentSummary>> build() => directories;
}

const _oneHost = [
  HostProfile(
    serverId: 'server-a',
    label: 'Local',
    connections: [
      DirectTcpHostConnection(
        id: 'direct:localhost:6868',
        endpoint: 'localhost:6868',
      ),
    ],
    preferredConnectionId: 'direct:localhost:6868',
    createdAt: '2026-07-27T00:00:00.000Z',
    updatedAt: '2026-07-27T00:00:00.000Z',
  ),
];

const _twoHosts = [
  ..._oneHost,
  HostProfile(
    serverId: 'server-b',
    label: 'Remote',
    connections: [
      DirectTcpHostConnection(
        id: 'direct:remote:6868',
        endpoint: 'remote:6868',
      ),
    ],
    preferredConnectionId: 'direct:remote:6868',
    createdAt: '2026-07-27T00:00:00.000Z',
    updatedAt: '2026-07-27T00:00:00.000Z',
  ),
];

ScheduleSummary _schedule({
  required String id,
  ScheduleStatus status = ScheduleStatus.active,
  String? name,
  ScheduleTarget? target,
  String? expiresAt,
}) => ScheduleSummary(
  id: id,
  name:
      name ??
      (status == ScheduleStatus.completed
          ? 'Ended schedule'
          : 'Active schedule'),
  prompt: 'Review the branch',
  cadence: const CronScheduleCadence(expression: '*/5 * * * *'),
  target:
      target ??
      const NewAgentScheduleTarget(
        config: ScheduleNewAgentConfig(
          provider: 'codex',
          cwd: 'C:/repo',
          model: 'gpt-5.4',
          isolation: 'worktree',
        ),
      ),
  status: status,
  createdAt: '2026-07-27T00:00:00.000Z',
  updatedAt: '2026-07-27T00:00:00.000Z',
  nextRunAt: status == ScheduleStatus.active
      ? '2026-07-27T00:05:00.000Z'
      : null,
  lastRunAt: null,
  pausedAt: null,
  expiresAt: expiresAt,
  maxRuns: null,
);
