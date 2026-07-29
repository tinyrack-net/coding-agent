import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/composer/create_agent_preferences.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/external_url_launcher.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/screens/schedules_screen.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/state/schedule_project_targets_provider.dart';
import 'package:coding_agent_app/state/schedules_provider.dart';
import 'package:coding_agent_app/widgets/adaptive_modal_sheet.dart';
import 'package:coding_agent_app/widgets/fluent/select_field.dart';
import 'package:coding_agent_app/widgets/host_status_dot.dart';
import 'package:coding_agent_app/widgets/provider_icon.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('empty state preserves Paseo schedule copy and create action', (
    tester,
  ) async {
    await _pump(tester, const []);

    expect(find.text('Schedules'), findsOneWidget);
    expect(find.text('No active schedules'), findsOneWidget);
    expect(find.text('Schedules run agents on a cadence.'), findsOneWidget);
    expect(find.text('See docs'), findsOneWidget);
    expect(find.text('New schedule'), findsOneWidget);

    await tester.tap(find.text('New schedule'));
    await tester.pumpAndSettle();
    final card = tester.getRect(
      find.byKey(const ValueKey('adaptive-modal-sheet-card')),
    );
    expect(card.width, adaptiveModalDesktopMaxWidth);
    expect(
      card.height,
      lessThanOrEqualTo(
        tester.view.physicalSize.height /
            tester.view.devicePixelRatio *
            adaptiveModalDesktopMaxHeightFactor,
      ),
    );
    expect(find.text('Prompt'), findsOneWidget);
    expect(find.text('Cadence'), findsOneWidget);
    expect(find.text('Project'), findsOneWidget);
    expect(find.text('Model'), findsNothing);
    expect(find.text('Isolation'), findsNothing);
    expect(find.text('Archive on finish'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('schedule-form-submit')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('empty state opens the Tinyrack schedules help route', (
    tester,
  ) async {
    final launcher = _FakeExternalUrlLauncher();
    await _pump(tester, const [], launcher: launcher);

    await tester.tap(find.byKey(const ValueKey('schedules-docs')));
    await tester.pumpAndSettle();

    expect(launcher.opened, ['https://tinyrack.net/docs/schedules']);
  });

  testWidgets('create form uses the frozen compact bottom-sheet geometry', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await _pump(tester, const []);

    await tester.tap(find.text('New schedule'));
    await tester.pumpAndSettle();

    final card = tester.getRect(
      find.byKey(const ValueKey('adaptive-modal-sheet-card')),
    );
    expect(card.width, 390);
    expect(card.height, 844 * adaptiveModalCompactInitialHeightFactor);
    expect(card.bottom, 844);
    expect(
      tester.getSize(find.byKey(const ValueKey('schedule-name-input'))).height,
      46,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('schedule-prompt-input')))
          .height,
      112,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('cadence-cron-expression')))
          .height,
      46,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('schedule-form-submit'))).top,
      greaterThanOrEqualTo(card.bottom),
    );
    expect(
      tester.getRect(
        find.byKey(const ValueKey('adaptive-modal-sheet-card-content')),
      ),
      within(distance: 1, from: const Rect.fromLTWH(0, 295.4, 390, 759.6)),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('schedule-name-input'))),
      within(distance: 1, from: const Rect.fromLTWH(0, 411.4, 390, 46)),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('schedule-prompt-input'))),
      within(distance: 1, from: const Rect.fromLTWH(0, 484.4, 390, 112)),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('schedule-project-trigger'))),
      within(distance: 1, from: const Rect.fromLTWH(0, 623.4, 390, 46)),
    );
    expect(
      tester.getRect(
        find.byKey(const ValueKey('schedule-cadence-preset-trigger')),
      ),
      within(distance: 1, from: const Rect.fromLTWH(0, 696.4, 390, 46)),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('cadence-cron-expression'))),
      within(distance: 1, from: const Rect.fromLTWH(0, 754.4, 390, 46)),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('schedule-form-submit'))),
      within(distance: 1, from: const Rect.fromLTWH(201, 999, 165, 44)),
    );
  });

  testWidgets('desktop create form matches its frozen Windows golden', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 900);
    addTearDown(tester.view.reset);
    await _pump(tester, const [], themeName: AppThemeName.light);

    await tester.tap(find.text('New schedule'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const ValueKey('adaptive-modal-sheet-card')),
      matchesGoldenFile('goldens/schedule_form_desktop_900x900.png'),
    );
  });

  testWidgets('compact create form matches its frozen Windows golden', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await _pump(tester, const [], themeName: AppThemeName.light);

    await tester.tap(find.text('New schedule'));
    await tester.pumpAndSettle();

    await expectLater(
      find.byKey(const ValueKey('adaptive-modal-sheet-card')),
      matchesGoldenFile('goldens/schedule_form_compact_390x844.png'),
    );
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

  testWidgets('compact screen keeps the frozen toolbar and list insets', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 700);
    addTearDown(tester.view.reset);
    await _pumpWithNotifier(
      tester,
      _FakeSchedulesNotifier([_schedule(id: 'compact-screen')]),
      hosts: _twoHosts,
    );

    final toolbar = tester.getRect(
      find.byKey(const ValueKey('schedules-filter-row')),
    );
    final filter = tester.getRect(
      find.byKey(const ValueKey('schedules-status-filter')),
    );
    final create = tester.getRect(find.byKey(const ValueKey('schedules-new')));
    final hostFilter = tester.getRect(
      find.byKey(const ValueKey('schedules-host-filter-trigger')),
    );
    final activeSegment = tester.getRect(
      find.byKey(const ValueKey('schedules-filter-active')),
    );
    final endedSegment = tester.getRect(
      find.byKey(const ValueKey('schedules-filter-ended')),
    );
    final card = tester.getRect(
      find.byKey(const ValueKey('schedules-table-card')),
    );
    expect(toolbar.left, 0);
    expect(toolbar.right, 390);
    expect(filter.height, 32);
    expect(hostFilter.height, 32);
    expect(activeSegment.size, const Size(64, 28));
    expect(endedSegment.size, const Size(66, 28));
    expect(create.size, const Size(146, 32));
    expect(
      find.byKey(const ValueKey('schedules-host-filter-trigger')),
      findsOneWidget,
    );
    expect(create.right, lessThanOrEqualTo(378));
    expect(card.left, 12);
    expect(card.right, 378);
    final activeDecoration =
        tester
                .widget<Container>(
                  find
                      .descendant(
                        of: find.byKey(
                          const ValueKey('schedules-filter-active'),
                        ),
                        matching: find.byType(Container),
                      )
                      .last,
                )
                .decoration
            as BoxDecoration;
    expect(
      activeDecoration.color,
      paseoPaletteFor(AppThemeName.dark).foreground,
    );
    expect(activeDecoration.borderRadius, BorderRadius.circular(9999));
    expect(tester.takeException(), isNull);
  });

  testWidgets('screen sorts visible schedules newest first', (tester) async {
    await _pump(tester, [
      _schedule(
        id: 'older',
        name: 'Older schedule',
        createdAt: '2026-07-27T00:00:00.000Z',
      ),
      _schedule(
        id: 'newer',
        name: 'Newer schedule',
        createdAt: '2026-07-28T00:00:00.000Z',
      ),
    ]);

    expect(
      tester.getTopLeft(find.text('Newer schedule')).dy,
      lessThan(tester.getTopLeft(find.text('Older schedule')).dy),
    );
  });

  testWidgets('host error banner uses frozen compact geometry and palette', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 700);
    addTearDown(tester.view.reset);
    final notifier = _FakeSchedulesNotifier.aggregated(
      AggregatedSchedulesState(
        schedules: [
          AggregatedSchedule(
            serverId: 'server-a',
            serverName: 'Local',
            schedule: _schedule(id: 'active'),
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
    await _pumpWithNotifier(tester, notifier);

    final bannerFinder = find.byKey(const ValueKey('schedules-host-errors'));
    final rect = tester.getRect(bannerFinder);
    expect(rect.left, 12);
    expect(rect.right, 378);
    final decoration =
        tester.widget<Container>(bannerFinder).decoration! as BoxDecoration;
    expect(
      (decoration.border! as Border).top.color,
      paseoPaletteFor(AppThemeName.dark).border,
    );
    expect(decoration.borderRadius, BorderRadius.circular(8));
  });

  testWidgets('table uses frozen desktop card geometry and tokens', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(tester.view.reset);
    await _pump(tester, [_schedule(id: 'first'), _schedule(id: 'second')]);

    final tableRect = tester.getRect(
      find.byKey(const ValueKey('schedules-table')),
    );
    final cardRect = tester.getRect(
      find.byKey(const ValueKey('schedules-table-card')),
    );
    expect(tableRect.left, 0);
    expect(tableRect.right, 900);
    expect(cardRect.left, 24);
    expect(cardRect.right, 876);
    expect(cardRect.top, tableRect.top);
    expect(cardRect.bottom, tableRect.bottom);
    final card = tester.widget<Container>(
      find.byKey(const ValueKey('schedules-table-card')),
    );
    final decoration = card.decoration! as BoxDecoration;
    final palette = paseoPaletteFor(AppThemeName.dark);
    expect(card.clipBehavior, Clip.hardEdge);
    expect(decoration.color, palette.surface1);
    expect((decoration.border! as Border).top.color, palette.border);
    expect(decoration.borderRadius, BorderRadius.circular(8));
    expect(
      find.byKey(const ValueKey('schedule-divider-second')),
      findsOneWidget,
    );
  });

  testWidgets('table switches to frozen compact horizontal inset', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 700);
    addTearDown(tester.view.reset);
    await _pump(tester, [_schedule(id: 'compact')]);

    final cardRect = tester.getRect(
      find.byKey(const ValueKey('schedules-table-card')),
    );
    expect(cardRect.left, 12);
    expect(cardRect.right, 588);
  });

  testWidgets('row opens the edit sheet with frozen values', (tester) async {
    await _pump(tester, [_schedule(id: 'active')]);

    await tester.tap(find.text('Active schedule'));
    await tester.pumpAndSettle();

    expect(find.text('Edit schedule'), findsOneWidget);
    expect(find.text('Save changes'), findsOneWidget);
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('schedule-host-trigger')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('schedule-host-trigger-option-server-a')),
      findsNothing,
    );
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
    final preferences = CreateAgentPreferencesService(
      _MemoryPreferenceStorage(),
    );
    await _pumpWithNotifier(tester, notifier, preferencesService: preferences);
    await tester.tap(find.text('New schedule').last);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('schedule-form-submit')),
          )
          .onPressed,
      isNull,
    );

    final fields = find.byType(TextBox);
    expect(
      tester.getSize(find.byKey(const ValueKey('schedule-name-input'))).height,
      34,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('schedule-prompt-input')))
          .height,
      98,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('cadence-cron-expression')))
          .height,
      34,
    );
    await tester.enterText(fields.at(1), 'Run tests');
    await tester.enterText(fields.at(2), '*/5 * * * *');
    await _selectScheduleProject(tester, 'Local project');
    expect(find.text('Select model'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('schedule-form-submit')),
          )
          .onPressed,
      isNull,
    );
    await _selectCodexModel(tester);
    expect(find.text('GPT 5.4'), findsOneWidget);
    expect(find.text('Mode'), findsOneWidget);
    expect(find.text('Thinking'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Thinking')).dy,
      lessThan(tester.getTopLeft(find.text('Mode')).dy),
    );
    expect(
      tester.getTopLeft(find.byType(ToggleSwitch)).dy,
      greaterThan(tester.getTopLeft(find.text('Archive on finish')).dy),
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('schedule-model-trigger')))
          .height,
      34,
    );
    final modeSelector = find.byKey(const ValueKey('schedule-mode-trigger'));
    await tester.ensureVisible(modeSelector);
    await tester.tap(modeSelector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plan').last);
    await tester.pumpAndSettle();
    final thinkingSelector = find.byKey(
      const ValueKey('schedule-thinking-trigger'),
    );
    await tester.ensureVisible(thinkingSelector);
    await tester.tap(thinkingSelector);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('schedule-thinking-option-medium')),
    );
    await tester.pumpAndSettle();
    final isolationTrigger = find.byKey(
      const ValueKey('schedule-isolation-trigger'),
    );
    await tester.ensureVisible(isolationTrigger);
    await tester.tap(isolationTrigger);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-isolation-worktree')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextBox).at(3), '2 runs');
    await tester.tap(find.text('Create schedule'));
    await tester.pumpAndSettle();

    expect(notifier.createdPrompt, 'Run tests');
    expect(notifier.createdMaxRuns, 2);
    final config = (notifier.createdTarget! as NewAgentScheduleTarget).config;
    expect(config.provider, 'codex');
    expect(config.model, 'gpt-5.4');
    expect(config.modeId, 'plan');
    expect(config.thinkingOptionId, 'medium');
    expect(config.isolation, 'worktree');
    final stored = await preferences.load();
    expect(stored.provider, 'codex');
    expect(stored.providerPreferences['codex']?.model, 'gpt-5.4');
    expect(stored.providerPreferences['codex']?.mode, 'plan');
    expect(stored.providerPreferences['codex']?.thinkingByModel, {
      'gpt-5.4': 'medium',
    });
    expect(stored.isolation, 'worktree');
    expect(find.text('Create schedule'), findsNothing);
  });

  testWidgets('create form applies stored provider selections', (tester) async {
    final preferences = CreateAgentPreferencesService(
      _MemoryPreferenceStorage({
        'provider': 'codex',
        'isolation': 'worktree',
        'providerPreferences': {
          'codex': {
            'model': 'gpt-5.4',
            'mode': 'plan',
            'thinkingByModel': {'gpt-5.4': 'medium'},
          },
        },
      }),
    );
    await _pumpWithNotifier(
      tester,
      _FakeSchedulesNotifier(const []),
      preferencesService: preferences,
    );
    await tester.tap(find.text('New schedule').last);
    await tester.pumpAndSettle();
    await _selectScheduleProject(tester, 'Local project');

    expect(find.text('GPT 5.4'), findsOneWidget);
    expect(
      _selectFieldForTrigger(
        tester,
        const ValueKey('schedule-mode-trigger'),
      ).value,
      'plan',
    );
    expect(
      _selectFieldForTrigger(
        tester,
        const ValueKey('schedule-thinking-trigger'),
      ).value,
      'medium',
    );
    expect(
      _selectFieldForTrigger(
        tester,
        const ValueKey('schedule-isolation-trigger'),
      ).value,
      'worktree',
    );
  });

  testWidgets('edit form ignores stored provider defaults', (tester) async {
    final preferences = CreateAgentPreferencesService(
      _MemoryPreferenceStorage({
        'provider': 'codex',
        'isolation': 'worktree',
        'providerPreferences': {
          'codex': {
            'model': 'gpt-5.4',
            'mode': 'plan',
            'thinkingByModel': {'gpt-5.4': 'medium'},
          },
        },
      }),
    );
    final schedule = _schedule(
      id: 'edit-preferences',
      target: const NewAgentScheduleTarget(
        config: ScheduleNewAgentConfig(
          provider: 'codex',
          cwd: 'C:/repo',
          model: 'gpt-5.4',
          modeId: 'agent',
          thinkingOptionId: 'high',
          isolation: 'local',
        ),
      ),
    );
    await _pumpWithNotifier(
      tester,
      _FakeSchedulesNotifier([schedule]),
      preferencesService: preferences,
    );
    await tester.tap(find.text('Active schedule'));
    await tester.pumpAndSettle();

    expect(
      _selectFieldForTrigger(
        tester,
        const ValueKey('schedule-mode-trigger'),
      ).value,
      'agent',
    );
    expect(
      _selectFieldForTrigger(
        tester,
        const ValueKey('schedule-thinking-trigger'),
      ).value,
      'high',
    );
    expect(
      _selectFieldForTrigger(
        tester,
        const ValueKey('schedule-isolation-trigger'),
      ).value,
      'local',
    );
  });

  testWidgets('legacy host omits workspace lifecycle controls and payload', (
    tester,
  ) async {
    final notifier = _FakeSchedulesNotifier(const []);
    await _pumpWithNotifier(
      tester,
      notifier,
      supportsWorkspaceMultiplicity: false,
    );
    await tester.tap(find.text('New schedule').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextBox).at(1), 'Run tests');

    await _selectScheduleProject(tester, 'Local project');
    await _selectCodexModel(tester);

    expect(find.text('Isolation'), findsNothing);
    expect(find.text('Archive on finish'), findsNothing);
    await tester.tap(find.text('Create schedule'));
    await tester.pumpAndSettle();

    final config = (notifier.createdTarget! as NewAgentScheduleTarget).config;
    expect(config.isolation, isNull);
    expect(config.archiveOnFinish, isNull);
  });

  testWidgets('non-git project forces local isolation but keeps archive', (
    tester,
  ) async {
    final notifier = _FakeSchedulesNotifier(const []);
    await _pumpWithNotifier(tester, notifier, projectsAreGit: false);
    await tester.tap(find.text('New schedule').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextBox).at(1), 'Run tests');

    await _selectScheduleProject(tester, 'Local project');
    await _selectCodexModel(tester);

    expect(find.text('Isolation'), findsNothing);
    expect(find.text('Archive on finish'), findsOneWidget);
    await tester.tap(find.text('Create schedule'));
    await tester.pumpAndSettle();

    final config = (notifier.createdTarget! as NewAgentScheduleTarget).config;
    expect(config.isolation, 'local');
    expect(config.archiveOnFinish, isTrue);
  });

  testWidgets('cadence editor applies presets and previews custom cron', (
    tester,
  ) async {
    await _pump(tester, const []);
    await tester.tap(find.text('New schedule'));
    await tester.pumpAndSettle();

    expect(find.text('Every hour'), findsWidgets);
    final cadenceTrigger = find.byKey(
      const ValueKey('schedule-cadence-preset-trigger'),
    );
    await tester.ensureVisible(cadenceTrigger);
    await tester.tap(cadenceTrigger);
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
    final pausedBadge =
        tester
                .widget<Container>(
                  find.byKey(const ValueKey('schedule-status-paused')),
                )
                .decoration
            as BoxDecoration;
    expect(pausedBadge.color, paseoPaletteFor(AppThemeName.dark).surface3);
    expect(
      (pausedBadge.border! as Border).top.color,
      paseoPaletteFor(AppThemeName.dark).border,
    );
    expect(find.byKey(const ValueKey('schedule-row-paused')), findsOneWidget);
    expect(
      find.bySemanticsLabel('Edit schedule Active schedule'),
      findsOneWidget,
    );
    expect(find.byType(ProviderIcon), findsOneWidget);

    await tester.tap(find.byIcon(FluentIcons.more_vertical));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('schedule-menu-resume-paused')),
      findsOneWidget,
    );
    await tester.tap(find.text('Resume schedule'));
    await tester.pumpAndSettle();
    expect(notifier.resumed, ['paused']);

    await tester.tap(find.byIcon(FluentIcons.more_vertical));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('schedule-menu-run-paused')),
      findsOneWidget,
    );
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

  testWidgets('row keeps its kebab and item-specific pending state', (
    tester,
  ) async {
    final notifier = _FakeSchedulesNotifier([
      _schedule(id: 'pending', status: ScheduleStatus.paused),
    ])..resumeCompleter = Completer<ScheduleSummary>();
    await _pumpWithNotifier(tester, notifier);

    await tester.tap(find.byKey(const ValueKey('schedule-kebab-pending')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resume schedule'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(notifier.resumed, ['pending']);
    expect(
      find.byKey(const ValueKey('schedule-kebab-pending')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('schedule-kebab-state-pending-resume')),
      findsOneWidget,
    );

    notifier.resumeCompleter!.complete(
      _schedule(id: 'pending', status: ScheduleStatus.active),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(const ValueKey('schedule-kebab-state-pending-idle')),
      findsOneWidget,
    );
  });

  testWidgets('table keeps concurrent pending state owned by each row', (
    tester,
  ) async {
    final first = Completer<ScheduleSummary>();
    final second = Completer<ScheduleSummary>();
    final notifier = _FakeSchedulesNotifier([
      _schedule(id: 'first', status: ScheduleStatus.paused),
      _schedule(id: 'second', status: ScheduleStatus.paused),
    ])..resumeCompleters.addAll({'first': first, 'second': second});
    await _pumpWithNotifier(tester, notifier);

    await tester.tap(find.byKey(const ValueKey('schedule-kebab-first')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-menu-resume-first')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('schedule-kebab-second')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-menu-resume-second')));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(
        const ValueKey('schedule-kebab-state-first-resume'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('schedule-kebab-state-second-resume'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );

    first.complete(_schedule(id: 'first'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey('schedule-kebab-state-first-idle'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('schedule-kebab-state-second-resume'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );

    second.complete(_schedule(id: 'second'));
    await tester.pumpAndSettle();
  });

  testWidgets('table silently settles a failed row mutation', (tester) async {
    final notifier = _FakeSchedulesNotifier([
      _schedule(id: 'failed', status: ScheduleStatus.paused),
    ])..resumeError = StateError('offline');
    await _pumpWithNotifier(tester, notifier);

    await tester.tap(find.byKey(const ValueKey('schedule-kebab-failed')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-menu-resume-failed')));
    await tester.pumpAndSettle();

    expect(notifier.resumed, ['failed']);
    expect(find.textContaining('Schedule action failed'), findsNothing);
    expect(
      find.byKey(const ValueKey('schedule-kebab-state-failed-idle')),
      findsOneWidget,
    );
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

    expect(find.text('Heartbeat'), findsOneWidget);
    expect(find.text('Agent unavailable'), findsOneWidget);
    expect(find.textContaining('Every 1 hour'), findsOneWidget);
    expect(find.bySemanticsLabel('Edit heartbeat Heartbeat'), findsOneWidget);
    expect(find.bySemanticsLabel('Heartbeat actions'), findsOneWidget);
    await tester.tap(find.byIcon(FluentIcons.more_vertical));
    await tester.pumpAndSettle();
    expect(find.text('Edit heartbeat'), findsOneWidget);
    expect(find.text('Run now'), findsNothing);
    expect(find.text('Delete heartbeat'), findsOneWidget);
  });

  testWidgets('agent-target edit exposes only target and cadence', (
    tester,
  ) async {
    final schedule = ScheduleSummary(
      id: 'heartbeat',
      name: null,
      prompt: 'Heartbeat',
      cadence: const CronScheduleCadence(expression: '0 * * * *'),
      target: const AgentScheduleTarget(
        agentId: '11111111-1111-4111-8111-111111111111',
      ),
      status: ScheduleStatus.active,
      createdAt: '2026-07-27T00:00:00.000Z',
      updatedAt: '2026-07-27T00:00:00.000Z',
      nextRunAt: null,
      lastRunAt: null,
      pausedAt: null,
      expiresAt: null,
      maxRuns: 4,
    );
    final notifier = _FakeSchedulesNotifier([schedule]);
    await _pumpWithNotifier(
      tester,
      notifier,
      agentDirectories: const {
        'server-a': {'11111111-1111-4111-8111-111111111111': _heartbeatAgent},
      },
    );

    await tester.tap(find.byKey(const ValueKey('schedule-row-heartbeat')));
    await tester.pumpAndSettle();

    expect(find.text('Edit heartbeat'), findsOneWidget);
    expect(find.text('Target'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('schedule-form-sheet')),
        matching: find.text('Heartbeat agent'),
      ),
      findsOneWidget,
    );
    expect(find.text('Name'), findsNothing);
    expect(find.text('Prompt'), findsNothing);
    expect(find.text('Max runs'), findsNothing);
    expect(find.text('Project'), findsNothing);
    expect(find.text('Model'), findsNothing);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('schedule-agent-target')))
          .height,
      34,
    );

    await tester.enterText(find.byType(TextBox), '30 * * * *');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(notifier.updatedChanges, {
      'cadence': {
        'type': 'cron',
        'expression': '30 * * * *',
        'timezone': 'UTC',
      },
    });
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

  testWidgets('removed host resets the filter before a matching host returns', (
    tester,
  ) async {
    final registry = _ScheduleHostRegistry(_twoHosts);
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
      ),
    );
    await _pumpWithNotifier(
      tester,
      notifier,
      hosts: _twoHosts,
      hostRegistry: registry,
    );

    await tester.tap(find.text('All hosts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remote').last);
    await tester.pumpAndSettle();
    expect(find.text('Active schedule'), findsNothing);

    registry.replace(_oneHost);
    await tester.pumpAndSettle();
    registry.replace(_twoHosts);
    await tester.pumpAndSettle();

    expect(find.text('All hosts'), findsOneWidget);
    expect(find.text('Active schedule'), findsOneWidget);
    expect(find.text('Remote schedule'), findsOneWidget);
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
    await _pumpWithNotifier(
      tester,
      notifier,
      hosts: _twoHosts,
      hostStates: const {
        'server-a': DaemonConnectionState.connected,
        'server-b': DaemonConnectionState.connecting,
      },
    );

    await tester.tap(find.text('New schedule'));
    await tester.pumpAndSettle();
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Project'), findsNothing);
    expect(find.text('Model'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('schedule-host-trigger')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('schedule-host-status-server-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('schedule-host-status-server-b')),
      findsOneWidget,
    );
    BoxDecoration hostDotDecoration(String serverId) =>
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: find.byKey(
                          ValueKey('schedule-host-status-$serverId'),
                        ),
                        matching: find.byType(DecoratedBox),
                      )
                      .last,
                )
                .decoration
            as BoxDecoration;
    expect(hostDotDecoration('server-a').color, hostStatusOnlineColor);
    expect(hostDotDecoration('server-b').color, hostStatusConnectingColor);
    await tester.tap(find.text('Remote').last);
    await tester.pumpAndSettle();
    await _selectScheduleProject(tester, 'Remote project');
    await _selectCodexModel(tester);

    final fields = find.byType(TextBox);
    await tester.enterText(fields.at(1), 'Run tests');
    await tester.enterText(fields.at(2), '*/5 * * * *');
    await tester.tap(find.text('Create schedule'));
    await tester.pumpAndSettle();

    expect(notifier.createdServerId, 'server-b');
  });
}

PaseoSelectField<String> _selectFieldForTrigger(
  WidgetTester tester,
  Key triggerKey,
) => tester.widget<PaseoSelectField<String>>(
  find
      .ancestor(
        of: find.byKey(triggerKey),
        matching: find.byType(PaseoSelectField<String>),
      )
      .first,
);

Future<void> _selectCodexModel(WidgetTester tester) async {
  final selector = find.byKey(const ValueKey('combined-model-selector'));
  await tester.ensureVisible(selector);
  await tester.tap(selector);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('model-row-codex-gpt-5.4')));
  await tester.pumpAndSettle();
}

Future<void> _selectScheduleProject(WidgetTester tester, String label) async {
  final trigger = find.byKey(const ValueKey('schedule-project-trigger'));
  await tester.ensureVisible(trigger);
  await tester.tap(trigger);
  await tester.pumpAndSettle();
  final search = find.byKey(const ValueKey('schedule-project-trigger-search'));
  expect(search, findsOneWidget);
  expect(find.byType(SvgPicture), findsWidgets);
  await tester.enterText(search, label);
  await tester.pump();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _pump(
  WidgetTester tester,
  List<ScheduleSummary> schedules, {
  AppThemeName themeName = AppThemeName.dark,
  ExternalUrlLauncher? launcher,
}) async {
  await _pumpWithNotifier(
    tester,
    _FakeSchedulesNotifier(schedules),
    themeName: themeName,
    launcher: launcher,
  );
}

Future<void> _pumpWithNotifier(
  WidgetTester tester,
  _FakeSchedulesNotifier notifier, {
  List<HostProfile> hosts = _oneHost,
  _ScheduleHostRegistry? hostRegistry,
  Map<String, Map<String, AgentSummary>> agentDirectories = const {},
  bool settle = true,
  bool supportsWorkspaceMultiplicity = true,
  bool projectsAreGit = true,
  Map<String, DaemonConnectionState> hostStates = const {},
  CreateAgentPreferencesService? preferencesService,
  AppThemeName themeName = AppThemeName.dark,
  ExternalUrlLauncher? launcher,
}) async {
  final effectiveHosts = hostRegistry?.hosts ?? hosts;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        aggregatedSchedulesProvider.overrideWith(() => notifier),
        hostRegistryProvider.overrideWith(
          () => hostRegistry ?? _ScheduleHostRegistry(effectiveHosts),
        ),
        agentDirectoryReplicaStoreProvider.overrideWith(
          () => _ScheduleAgentStore(agentDirectories),
        ),
        scheduleProjectTargetsProvider.overrideWith(
          () => _ScheduleProjectTargets(
            _targetsFor(effectiveHosts, isGit: projectsAreGit),
          ),
        ),
        hostRuntimeClientsProvider.overrideWithValue({
          for (final host in effectiveHosts)
            host.serverId: _ScheduleSnapshotClient(
              host.serverId,
              supportsWorkspaceMultiplicity: supportsWorkspaceMultiplicity,
            ),
        }),
        hostConnectionStateProvider.overrideWith(
          (ref, serverId) => Stream.value(
            hostStates[serverId] ?? DaemonConnectionState.connected,
          ),
        ),
        if (launcher != null)
          externalUrlLauncherProvider.overrideWithValue(launcher),
      ],
      child: FluentApp(
        theme: buildAppTheme(themeName),
        home: SchedulesScreen(
          preferencesService:
              preferencesService ??
              CreateAgentPreferencesService(_MemoryPreferenceStorage()),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

final class _FakeExternalUrlLauncher implements ExternalUrlLauncher {
  final opened = <String>[];

  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return true;
  }
}

final class _MemoryPreferenceStorage implements CreateAgentPreferenceStorage {
  _MemoryPreferenceStorage([this.value]);

  Object? value;

  @override
  Future<Object?> read() async => value;

  @override
  Future<void> write(CreateAgentPreferences preferences) async {
    value = preferences.toJson();
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
  ScheduleTarget? createdTarget;
  final resumed = <String>[];
  final paused = <String>[];
  final ran = <String>[];
  final deleted = <String>[];
  String? updatedId;
  String? updatedServerId;
  Map<String, Object?>? updatedChanges;
  Completer<ScheduleSummary>? resumeCompleter;
  final resumeCompleters = <String, Completer<ScheduleSummary>>{};
  Object? resumeError;

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
    createdTarget = target;
    return _schedule(id: 'created');
  }

  @override
  Future<ScheduleSummary> resume(String serverId, String scheduleId) async {
    resumed.add(scheduleId);
    if (resumeError case final error?) throw error;
    if (resumeCompleters[scheduleId] case final completer?) {
      return await completer.future;
    }
    if (resumeCompleter != null) return await resumeCompleter!.future;
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

final class _ScheduleSnapshotClient extends DaemonClient {
  _ScheduleSnapshotClient(
    String serverId, {
    required bool supportsWorkspaceMultiplicity,
  }) : super(uri: Uri.parse('ws://fake-$serverId')) {
    serverInfo = ServerInfoStatus(
      serverId: serverId,
      hostname: serverId,
      version: '0.2.0',
      desktopManaged: false,
      features: {
        'providersSnapshot': true,
        'workspaceMultiplicity': supportsWorkspaceMultiplicity,
      },
    );
  }

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      const Stream<DaemonConnectionState>.empty();

  @override
  Stream<ProvidersSnapshotUpdate> get providersSnapshotUpdates =>
      const Stream<ProvidersSnapshotUpdate>.empty();

  @override
  Future<GetProvidersSnapshotResponse> fetchProvidersSnapshot({
    String? cwd,
    Duration timeout = const Duration(seconds: 30),
  }) async => const GetProvidersSnapshotResponse(
    requestId: 'snapshot',
    generatedAt: '2026-07-29T00:00:00.000Z',
    entries: [
      ProviderSnapshotEntry(
        provider: 'codex',
        label: 'Codex',
        status: ProviderCatalogStatus.ready,
        defaultModeId: 'agent',
        modes: [
          ProviderMode(id: 'agent', label: 'Agent'),
          ProviderMode(id: 'plan', label: 'Plan'),
        ],
        models: [
          ProviderModelDefinition(
            provider: 'codex',
            id: 'gpt-5.4',
            label: 'GPT 5.4',
            isDefault: true,
            defaultThinkingOptionId: 'high',
            thinkingOptions: [
              ProviderSelectOption(id: 'medium', label: 'Medium'),
              ProviderSelectOption(id: 'high', label: 'High'),
            ],
          ),
        ],
      ),
    ],
  );
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
  _ScheduleHostRegistry(List<HostProfile> hosts) : _hosts = hosts;

  List<HostProfile> _hosts;

  List<HostProfile> get hosts => _hosts;

  @override
  HostRegistryState build() => HostRegistryState(
    hosts: _hosts,
    activeServerId: 'server-a',
    loaded: true,
  );

  void replace(List<HostProfile> hosts) {
    _hosts = hosts;
    state = HostRegistryState(
      hosts: hosts,
      activeServerId: 'server-a',
      loaded: true,
    );
  }
}

final class _ScheduleAgentStore extends AgentDirectoryReplicaStoreNotifier {
  _ScheduleAgentStore(this.directories);

  final Map<String, Map<String, AgentSummary>> directories;

  @override
  Map<String, Map<String, AgentSummary>> build() => directories;
}

final class _ScheduleProjectTargets extends ScheduleProjectTargetsNotifier {
  _ScheduleProjectTargets(this.targets);

  final List<ScheduleProjectTarget> targets;

  @override
  Future<ScheduleProjectTargetsState> build() async =>
      ScheduleProjectTargetsState(targets: targets);
}

List<ScheduleProjectTarget> _targetsFor(
  List<HostProfile> hosts, {
  required bool isGit,
}) => [
  for (final host in hosts)
    ScheduleProjectTarget(
      optionId: buildScheduleProjectOptionId(
        host.serverId,
        'project-${host.serverId}',
      ),
      serverId: host.serverId,
      serverName: host.label,
      projectKey: 'project-${host.serverId}',
      projectName: '${host.label} project',
      cwd: 'C:/repo',
      isGit: isGit,
    ),
];

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

const _heartbeatAgent = AgentSummary(
  agentId: '11111111-1111-4111-8111-111111111111',
  title: 'Heartbeat agent',
  cwd: 'C:/repo',
  provider: 'codex',
  model: 'gpt-5.4',
  mode: AgentMode.fullAccess,
  runState: AgentRunState.idle,
  createdAtMs: 0,
);

ScheduleSummary _schedule({
  required String id,
  ScheduleStatus status = ScheduleStatus.active,
  String? name,
  ScheduleTarget? target,
  String? expiresAt,
  String createdAt = '2026-07-27T00:00:00.000Z',
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
  createdAt: createdAt,
  updatedAt: createdAt,
  nextRunAt: status == ScheduleStatus.active
      ? '2026-07-27T00:05:00.000Z'
      : null,
  lastRunAt: null,
  pausedAt: null,
  expiresAt: expiresAt,
  maxRuns: null,
);
