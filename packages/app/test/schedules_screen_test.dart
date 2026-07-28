import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/screens/schedules_screen.dart';
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
    expect(find.text('New schedule'), findsNWidgets(2));

    await tester.tap(find.text('New schedule').last);
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
    await tester.enterText(fields.at(3), 'Asia/Seoul');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(notifier.updatedId, 'active');
    expect(notifier.updatedChanges!['prompt'], 'Updated prompt');
    expect(notifier.updatedChanges!['cadence'], {
      'type': 'cron',
      'expression': '15 * * * *',
      'timezone': 'Asia/Seoul',
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
    await tester.enterText(fields.at(4), 'codex');
    await tester.enterText(fields.at(5), 'gpt-5.4');
    await tester.enterText(fields.at(6), 'C:/repo');
    await tester.enterText(fields.at(7), '2');
    await tester.tap(find.text('Create schedule'));
    await tester.pumpAndSettle();

    expect(notifier.createdPrompt, 'Run tests');
    expect(notifier.createdMaxRuns, 2);
    expect(find.text('Create schedule'), findsNothing);
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
    expect(find.textContaining('Agent 1111111'), findsOneWidget);
    expect(find.textContaining('Every'), findsOneWidget);
    await tester.tap(find.byIcon(FluentIcons.more_vertical));
    await tester.pumpAndSettle();
    expect(find.text('Run now'), findsNothing);
    expect(find.text('Delete schedule'), findsOneWidget);
  });
}

Future<void> _pump(WidgetTester tester, List<ScheduleSummary> schedules) async {
  await _pumpWithNotifier(tester, _FakeSchedulesNotifier(schedules));
}

Future<void> _pumpWithNotifier(
  WidgetTester tester,
  _FakeSchedulesNotifier notifier,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [schedulesProvider.overrideWith(() => notifier)],
      child: FluentApp(theme: buildAppTheme(), home: const SchedulesScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeSchedulesNotifier extends SchedulesNotifier {
  _FakeSchedulesNotifier(this.initial);
  final List<ScheduleSummary> initial;
  String? createdPrompt;
  int? createdMaxRuns;
  final resumed = <String>[];
  final paused = <String>[];
  final ran = <String>[];
  final deleted = <String>[];
  String? updatedId;
  Map<String, Object?>? updatedChanges;

  @override
  Future<List<ScheduleSummary>> build() async => initial;

  @override
  Future<ScheduleSummary> create({
    required String prompt,
    required String? name,
    required ScheduleCadence cadence,
    required ScheduleTarget target,
    int? maxRuns,
    String? expiresAt,
    bool runOnCreate = false,
  }) async {
    createdPrompt = prompt;
    createdMaxRuns = maxRuns;
    return _schedule(id: 'created');
  }

  @override
  Future<ScheduleSummary> resume(String scheduleId) async {
    resumed.add(scheduleId);
    return _schedule(id: scheduleId);
  }

  @override
  Future<ScheduleSummary> pause(String scheduleId) async {
    paused.add(scheduleId);
    return _schedule(id: scheduleId, status: ScheduleStatus.paused);
  }

  @override
  Future<ScheduleSummary> updateSchedule(
    String scheduleId,
    Map<String, Object?> changes,
  ) async {
    updatedId = scheduleId;
    updatedChanges = changes;
    return _schedule(id: scheduleId);
  }

  @override
  Future<ScheduleSummary> runOnce(String scheduleId) async {
    ran.add(scheduleId);
    return _schedule(id: scheduleId);
  }

  @override
  Future<void> delete(String scheduleId) async {
    deleted.add(scheduleId);
  }
}

final class _ErrorSchedulesNotifier extends _FakeSchedulesNotifier {
  _ErrorSchedulesNotifier() : super(const []);

  int reloadCount = 0;

  @override
  Future<List<ScheduleSummary>> build() async {
    throw StateError('offline');
  }

  @override
  Future<void> reload() async {
    reloadCount++;
    state = const AsyncData([]);
  }
}

ScheduleSummary _schedule({
  required String id,
  ScheduleStatus status = ScheduleStatus.active,
}) => ScheduleSummary(
  id: id,
  name: status == ScheduleStatus.completed
      ? 'Ended schedule'
      : 'Active schedule',
  prompt: 'Review the branch',
  cadence: const CronScheduleCadence(expression: '*/5 * * * *'),
  target: const NewAgentScheduleTarget(
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
  expiresAt: null,
  maxRuns: null,
);
