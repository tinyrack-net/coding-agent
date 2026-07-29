import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../composer/create_agent_preferences.dart';
import '../composer/provider_model_selection.dart';
import '../core/daemon_client.dart';
import '../core/theme.dart';
import '../providers/providers_snapshot.dart';
import '../state/agents_provider.dart';
import '../state/daemon_providers.dart';
import '../state/host_registry_provider.dart';
import '../state/providers_snapshot_provider.dart';
import '../state/schedule_form_model.dart';
import '../state/schedule_project_targets_provider.dart';
import '../state/schedules_provider.dart';
import '../widgets/adaptive_modal_sheet.dart';
import '../widgets/combined_model_selector.dart';
import '../widgets/fluent/select_field.dart';
import '../widgets/fluent/toast.dart';
import '../widgets/provider_icon.dart';

enum _ScheduleFilter { active, ended }

enum _ScheduleDerivedState { active, paused, expired, finished, targetGone }

const _allScheduleHosts = '__all__';

// Lucide 0.546.0, ISC. Matches the frozen Paseo schedule option glyphs.
const _lucideFolderSvg = '''
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"
  stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>
</svg>
''';

const _lucideGitBranchSvg = '''
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"
  stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <line x1="6" x2="6" y1="3" y2="15"/>
  <circle cx="18" cy="6" r="3"/>
  <circle cx="6" cy="18" r="3"/>
  <path d="M18 9a9 9 0 0 1-9 9"/>
</svg>
''';

const _lucideBrainSvg = '''
<svg viewBox="0 0 24 24" fill="none" stroke="currentColor"
  stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
  <path d="M12 18V5"/>
  <path d="M15 13a4.17 4.17 0 0 1-3-4 4.17 4.17 0 0 1-3 4"/>
  <path d="M17.598 6.5A3 3 0 1 0 12 5a3 3 0 1 0-5.598 1.5"/>
  <path d="M17.997 5.125a4 4 0 0 1 2.526 5.77"/>
  <path d="M18 18a4 4 0 0 0 2-7.464"/>
  <path d="M19.967 17.483A4 4 0 1 1 12 18a4 4 0 1 1-7.967-.517"/>
  <path d="M6 18a4 4 0 0 1-2-7.464"/>
  <path d="M6.003 5.125a4 4 0 0 0-2.526 5.77"/>
</svg>
''';

class SchedulesScreen extends ConsumerStatefulWidget {
  const SchedulesScreen({super.key, this.preferencesService});

  final CreateAgentPreferencesService? preferencesService;

  @override
  ConsumerState<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends ConsumerState<SchedulesScreen> {
  var _filter = _ScheduleFilter.active;
  var _selectedHost = _allScheduleHosts;

  @override
  Widget build(BuildContext context) {
    final schedules = ref.watch(aggregatedSchedulesProvider);
    final hosts = ref.watch(hostRegistryProvider).hosts;
    final agentDirectories = ref.watch(agentDirectoryReplicaStoreProvider);
    final projectTargets =
        ref.watch(scheduleProjectTargetsProvider).value?.targets ??
        const <ScheduleProjectTarget>[];
    final projectNameByCwd = buildScheduleProjectNameByCwd(projectTargets);
    final selectedHost =
        _selectedHost == _allScheduleHosts ||
            hosts.any((host) => host.serverId == _selectedHost)
        ? _selectedHost
        : _allScheduleHosts;
    return ScaffoldPage(
      header: const PageHeader(title: Text('Schedules')),
      content: schedules.when(
        loading: () => const Center(child: ProgressRing()),
        error: (error, _) => _ScheduleLoadError(
          onRetry: () =>
              ref.read(aggregatedSchedulesProvider.notifier).reload(),
        ),
        data: (state) {
          if (state.connecting && state.schedules.isEmpty) {
            return const Center(child: ProgressRing());
          }
          if (state.schedules.isEmpty) {
            return Column(
              children: [
                if (state.hostErrors.isNotEmpty)
                  _ScheduleHostErrors(errors: state.hostErrors),
                Expanded(
                  child: _ScheduleEmptyState(
                    ended: false,
                    onCreate: () => _showForm(),
                  ),
                ),
              ],
            );
          }
          final now = DateTime.now();
          final rows = [
            for (final entry in state.schedules)
              _resolveSchedule(
                entry,
                agentDirectories: agentDirectories,
                projectNameByCwd: projectNameByCwd,
                now: now,
              ),
          ];
          final visible = rows
              .where((row) {
                if (selectedHost != _allScheduleHosts &&
                    row.entry.serverId != selectedHost) {
                  return false;
                }
                final ended =
                    row.state != _ScheduleDerivedState.active &&
                    row.state != _ScheduleDerivedState.paused;
                return _filter == _ScheduleFilter.ended ? ended : !ended;
              })
              .toList(growable: false);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                child: Row(
                  children: [
                    if (hosts.length > 1) ...[
                      ComboBox<String>(
                        value: selectedHost,
                        items: [
                          const ComboBoxItem(
                            value: _allScheduleHosts,
                            child: Text('All hosts'),
                          ),
                          for (final host in hosts)
                            ComboBoxItem(
                              value: host.serverId,
                              child: Text(host.label),
                            ),
                        ],
                        onChanged: (value) => setState(
                          () => _selectedHost = value ?? _allScheduleHosts,
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    ToggleButton(
                      checked: _filter == _ScheduleFilter.active,
                      onChanged: (_) =>
                          setState(() => _filter = _ScheduleFilter.active),
                      child: const Text('Active'),
                    ),
                    const SizedBox(width: 4),
                    ToggleButton(
                      checked: _filter == _ScheduleFilter.ended,
                      onChanged: (_) =>
                          setState(() => _filter = _ScheduleFilter.ended),
                      child: const Text('Ended'),
                    ),
                    const Spacer(),
                    Button(
                      onPressed: () => _showForm(),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(FluentIcons.add, size: 14),
                          SizedBox(width: 8),
                          Text('New schedule'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (state.hostErrors.isNotEmpty)
                _ScheduleHostErrors(errors: state.hostErrors),
              Expanded(
                child: visible.isEmpty
                    ? _ScheduleEmptyState(
                        ended: _filter == _ScheduleFilter.ended,
                        onCreate: () => _showForm(),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: context.tokens.surfaceContainerHighest,
                              border: Border.all(
                                color: context.tokens.outlineVariant,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Column(
                              children: [
                                for (
                                  var index = 0;
                                  index < visible.length;
                                  index++
                                )
                                  _ScheduleRow(
                                    row: visible[index],
                                    singleHost: hosts.length <= 1,
                                    showDivider: index > 0,
                                    onEdit: () =>
                                        _showForm(visible[index].entry),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showForm([AggregatedSchedule? entry]) async {
    await showAdaptiveModalSheet<void>(
      context: context,
      builder: (context) => _ScheduleFormDialog(
        schedule: entry?.schedule,
        serverId: entry?.serverId,
        preferencesService: widget.preferencesService,
      ),
    );
  }
}

class _ScheduleLoadError extends StatelessWidget {
  const _ScheduleLoadError({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Unable to load schedules'),
        const SizedBox(height: 12),
        Button(onPressed: onRetry, child: const Text('Try again')),
      ],
    ),
  );
}

class _ScheduleHostErrors extends StatelessWidget {
  const _ScheduleHostErrors({required this.errors});

  final List<ScheduleHostError> errors;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(24, 0, 24, 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      border: Border.all(color: context.tokens.outlineVariant),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final error in errors)
          Text(
            '${error.serverName}: Could not load schedules',
            style: context.textStyles.bodySmall?.copyWith(
              color: context.statusColors.danger,
            ),
          ),
      ],
    ),
  );
}

class _ScheduleEmptyState extends StatelessWidget {
  const _ScheduleEmptyState({required this.ended, required this.onCreate});
  final bool ended;
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            FluentIcons.calendar_week,
            size: 32,
            color: context.tokens.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            ended ? 'No ended schedules' : 'No active schedules',
            style: context.textStyles.titleSmall,
          ),
          if (!ended) ...[
            const SizedBox(height: 8),
            Text(
              'Schedules run agents on a cadence.',
              style: TextStyle(color: context.tokens.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Button(
              onPressed: onCreate,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.add, size: 14),
                  SizedBox(width: 8),
                  Text('New schedule'),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class _ScheduleRow extends ConsumerWidget {
  const _ScheduleRow({
    required this.row,
    required this.singleHost,
    required this.showDivider,
    required this.onEdit,
  });

  final _ResolvedScheduleRow row;
  final bool singleHost;
  final bool showDivider;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final schedule = row.entry.schedule;
    final status = switch (row.state) {
      _ScheduleDerivedState.active => ('Active', context.statusColors.success),
      _ScheduleDerivedState.paused => ('Paused', context.statusColors.neutral),
      _ScheduleDerivedState.expired => (
        'Expired',
        context.statusColors.neutral,
      ),
      _ScheduleDerivedState.finished => (
        'Finished',
        context.statusColors.neutral,
      ),
      _ScheduleDerivedState.targetGone => (
        'Target gone',
        context.statusColors.danger,
      ),
    };
    return Column(
      children: [
        if (showDivider)
          Divider(
            style: DividerThemeData(
              decoration: BoxDecoration(color: context.tokens.outlineVariant),
            ),
          ),
        HoverButton(
          onPressed: onEdit,
          builder: (context, states) {
            final hovered = states.contains(WidgetState.hovered);
            final pressed = states.contains(WidgetState.pressed);
            return Container(
              color: pressed
                  ? context.tokens.outlineVariant
                  : hovered
                  ? context.fluentTheme.cardColor
                  : Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    child: Icon(
                      _providerIcon(row.provider),
                      size: 16,
                      color: context.tokens.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _title(schedule),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.textStyles.labelLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          row.targetLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.tokens.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _meta(
                            schedule,
                            state: row.state,
                            serverName: row.entry.serverName,
                            singleHost: singleHost,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.textStyles.bodySmall?.copyWith(
                            color: context.tokens.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: status.$2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      status.$1,
                      style: context.textStyles.bodySmall?.copyWith(
                        color: status.$2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _ScheduleMenu(row: row, onEdit: onEdit),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ScheduleMenu extends ConsumerStatefulWidget {
  const _ScheduleMenu({required this.row, required this.onEdit});
  final _ResolvedScheduleRow row;
  final VoidCallback onEdit;

  @override
  ConsumerState<_ScheduleMenu> createState() => _ScheduleMenuState();
}

class _ScheduleMenuState extends ConsumerState<_ScheduleMenu> {
  var _pending = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _pending = true);
    try {
      await action();
    } catch (error) {
      if (mounted) AppToast.show(context, 'Schedule action failed: $error');
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_pending) {
      return const SizedBox(width: 28, height: 28, child: ProgressRing());
    }
    final notifier = ref.read(aggregatedSchedulesProvider.notifier);
    final schedule = widget.row.entry.schedule;
    final serverId = widget.row.entry.serverId;
    final canExecute =
        schedule.target is NewAgentScheduleTarget &&
        (widget.row.state == _ScheduleDerivedState.active ||
            widget.row.state == _ScheduleDerivedState.paused);
    return DropDownButton(
      title: const Icon(FluentIcons.more_vertical, size: 14),
      items: [
        MenuFlyoutItem(
          leading: const Icon(FluentIcons.edit, size: 14),
          text: const Text('Edit schedule'),
          onPressed: widget.onEdit,
        ),
        if (schedule.target is NewAgentScheduleTarget) ...[
          if (schedule.status == ScheduleStatus.paused)
            MenuFlyoutItem(
              leading: const Icon(FluentIcons.play, size: 14),
              text: const Text('Resume schedule'),
              onPressed: canExecute
                  ? () => _run(() async {
                      await notifier.resume(serverId, schedule.id);
                    })
                  : null,
            )
          else
            MenuFlyoutItem(
              leading: const Icon(FluentIcons.pause, size: 14),
              text: const Text('Pause schedule'),
              onPressed: canExecute
                  ? () => _run(() async {
                      await notifier.pause(serverId, schedule.id);
                    })
                  : null,
            ),
          MenuFlyoutItem(
            leading: const Icon(FluentIcons.refresh, size: 14),
            text: const Text('Run now'),
            onPressed: canExecute
                ? () => _run(() async {
                    await notifier.runOnce(serverId, schedule.id);
                  })
                : null,
          ),
        ],
        const MenuFlyoutSeparator(),
        MenuFlyoutItem(
          leading: Icon(
            FluentIcons.delete,
            size: 14,
            color: context.statusColors.danger,
          ),
          text: Text(
            'Delete schedule',
            style: TextStyle(color: context.statusColors.danger),
          ),
          onPressed: () => _confirmDelete(notifier),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(AggregatedSchedulesNotifier notifier) async {
    final entry = widget.row.entry;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Delete schedule'),
        content: Text(
          'Delete "${_title(entry.schedule)}"? This cannot be undone.',
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(() => notifier.delete(entry.serverId, entry.schedule.id));
    }
  }
}

class _ScheduleFormDialog extends ConsumerStatefulWidget {
  const _ScheduleFormDialog({
    this.schedule,
    this.serverId,
    this.preferencesService,
  });
  final ScheduleSummary? schedule;
  final String? serverId;
  final CreateAgentPreferencesService? preferencesService;

  @override
  ConsumerState<_ScheduleFormDialog> createState() =>
      _ScheduleFormDialogState();
}

class _ScheduleFormDialogState extends ConsumerState<_ScheduleFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late final TextEditingController _cron;
  late final TextEditingController _cwd;
  late final TextEditingController _maxRuns;
  String? _serverId;
  String? _provider;
  String? _model;
  String? _modeId;
  String? _thinkingOptionId;
  CreateAgentPreferences _preferences = const CreateAgentPreferences();
  late final CreateAgentPreferencesService _preferencesService;
  var _selectionTouched = false;
  var _isolationTouched = false;
  late final String _timezone;
  var _isolation = 'local';
  var _archiveOnFinish = true;
  var _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final schedule = widget.schedule;
    final target = schedule?.target;
    final config = target is NewAgentScheduleTarget ? target.config : null;
    final cadence = normalizeScheduleFormCadence(
      schedule?.cadence ?? const EveryScheduleCadence(everyMs: 3600000),
      'UTC',
    );
    _name = TextEditingController(text: schedule?.name ?? '');
    _prompt = TextEditingController(text: schedule?.prompt ?? '');
    _cron = TextEditingController(text: cadence.expression);
    _timezone = cadence.timezone ?? 'UTC';
    _provider = config?.provider;
    _model = config?.model;
    _modeId = config?.modeId;
    _thinkingOptionId = config?.thinkingOptionId;
    _cwd = TextEditingController(text: config?.cwd ?? '');
    _maxRuns = TextEditingController(text: schedule?.maxRuns?.toString() ?? '');
    final hosts = ref.read(hostRegistryProvider).hosts;
    _serverId =
        widget.serverId ?? (hosts.length == 1 ? hosts.first.serverId : null);
    _isolation = config?.isolation ?? 'local';
    _archiveOnFinish = config?.archiveOnFinish ?? true;
    _preferencesService =
        widget.preferencesService ?? createAgentPreferencesService;
    unawaited(_hydratePreferences());
  }

  @override
  void dispose() {
    for (final controller in [_name, _prompt, _cron, _cwd, _maxRuns]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _hydratePreferences() async {
    try {
      final preferences = await _preferencesService.load();
      if (!mounted) return;
      setState(() {
        _preferences = preferences;
        if (widget.schedule == null && !_selectionTouched) {
          _provider = preferences.provider;
          _model = null;
          _modeId = null;
          _thinkingOptionId = null;
        }
        if (widget.schedule == null && !_isolationTouched) {
          _isolation = preferences.isolation == 'worktree'
              ? 'worktree'
              : 'local';
        }
      });
    } catch (_) {
      // Local preferences must not prevent schedule creation.
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.schedule != null;
    final agentTarget = widget.schedule?.target is AgentScheduleTarget;
    final newAgent = !agentTarget;
    final hosts = ref.watch(hostRegistryProvider).hosts;
    final agentDirectories = ref.watch(agentDirectoryReplicaStoreProvider);
    final projectTargets =
        ref.watch(scheduleProjectTargetsProvider).value?.targets ??
        const <ScheduleProjectTarget>[];
    final controlSize =
        MediaQuery.sizeOf(context).width < adaptiveModalCompactBreakpoint
        ? PaseoFieldControlSize.md
        : PaseoFieldControlSize.sm;
    final hostClients = ref.watch(hostRuntimeClientsProvider);
    final client = _serverId == null ? null : hostClients[_serverId];
    ScheduleProjectTarget? selectedProject;
    for (final target in projectTargets) {
      if (target.serverId == _serverId && target.cwd == _cwd.text.trim()) {
        selectedProject = target;
        break;
      }
    }
    final supportsWorkspaceMultiplicity =
        client?.serverInfo?.features['workspaceMultiplicity'] == true;
    final workspaceLifecycle = resolveScheduleWorkspaceLifecycle(
      supportsWorkspaceMultiplicity: supportsWorkspaceMultiplicity,
      hasProject: _cwd.text.trim().isNotEmpty,
      projectIsGit: selectedProject?.isGit == true,
      isolation: _isolation,
      archiveOnFinish: _archiveOnFinish,
    );
    final snapshotScope =
        newAgent && client != null && _cwd.text.trim().isNotEmpty
        ? ProvidersSnapshotScope(
            client: client,
            serverId: _serverId,
            cwd: _cwd.text,
          )
        : null;
    final snapshot = snapshotScope == null
        ? null
        : ref.watch(providersSnapshotProvider(snapshotScope));
    final preferenceProvider = widget.schedule == null && !_selectionTouched
        ? (_provider ?? _preferences.provider)
        : _provider;
    final providerPreferences = preferenceProvider == null
        ? null
        : _preferences.providerPreferences[preferenceProvider];
    final preferenceModel = widget.schedule == null && !_selectionTouched
        ? (_model ?? providerPreferences?.model)
        : _model;
    final providerSelection = resolveScheduleProviderSelection(
      entries: snapshot?.entries,
      selectedProvider: preferenceProvider,
      selectedModel: preferenceModel,
      selectedModeId: widget.schedule == null && !_selectionTouched
          ? (_modeId ?? providerPreferences?.mode)
          : _modeId,
      selectedThinkingOptionId: widget.schedule == null && !_selectionTouched
          ? (_thinkingOptionId ??
                providerPreferences?.thinkingByModel[preferenceModel])
          : _thinkingOptionId,
    );
    if (providerSelection.hasProvider) {
      _provider = providerSelection.provider;
      _model = providerSelection.model.isEmpty ? null : providerSelection.model;
      _modeId = providerSelection.modeId.isEmpty
          ? null
          : providerSelection.modeId;
      _thinkingOptionId = providerSelection.thinkingOptionId.isEmpty
          ? null
          : providerSelection.thinkingOptionId;
    }
    final readiness = resolveScheduleFormReadiness(
      agentTarget: agentTarget,
      editing: editing,
      submitting: _submitting,
      serverId: _serverId,
      prompt: _prompt.text,
      cwd: _cwd.text,
      hasMatchedProject: selectedProject != null,
      providerSelectionValid: providerSelection.isAvailable,
      cronExpression: _cron.text,
    );
    return AdaptiveModalSheet(
      key: const ValueKey('schedule-form-sheet'),
      title: agentTarget
          ? 'Edit heartbeat'
          : editing
          ? 'Edit schedule'
          : 'New schedule',
      onClose: () => Navigator.pop(context),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _withFieldSpacing([
          if (agentTarget) ...[
            _agentTargetField(agentDirectories),
            _cadenceEditor(controlSize),
          ] else ...[
            if (editing || hosts.length > 1)
              _labeledControl(
                'Host',
                PaseoSelectField<String>(
                  field: false,
                  triggerKey: const ValueKey('schedule-host-trigger'),
                  label: 'Host',
                  value: _serverId,
                  selectedDisplay: _serverId == null
                      ? null
                      : SelectFieldDisplay(
                          label:
                              hosts
                                  .where((host) => host.serverId == _serverId)
                                  .firstOrNull
                                  ?.label ??
                              _serverId!,
                        ),
                  options: [
                    for (final host in hosts)
                      SelectFieldOption(
                        id: host.serverId,
                        value: host.serverId,
                        label: host.label,
                        leading: _hostStatusDot(
                          host.serverId,
                          hostClients[host.serverId]?.currentState ==
                              DaemonConnectionState.connected,
                        ),
                      ),
                  ],
                  onChanged: (value, _) {
                    if (!editing) {
                      setState(() {
                        _serverId = value;
                        _cwd.clear();
                        _clearProviderSelection();
                      });
                    }
                  },
                  placeholder: 'Select host',
                  emptyText: 'No hosts found',
                  title: 'Host',
                  size: controlSize,
                  disabled: editing,
                ),
              ),
            _field('Name', _name, placeholder: 'Optional'),
            _field(
              'Prompt',
              _prompt,
              placeholder: 'What should the agent do each run?',
              maxLines: 4,
              onChanged: (_) => setState(() {}),
            ),
            if (readiness.showProject) _projectSelector(projectTargets),
            if (readiness.showModel)
              _providerEditor(
                snapshot: snapshot,
                scope: snapshotScope,
                selection: providerSelection,
                hasClient: client != null,
                controlSize: controlSize,
              ),
            if (workspaceLifecycle.showIsolation)
              _isolationSelector(
                workspaceLifecycle.effectiveIsolation,
                controlSize,
              ),
            if (workspaceLifecycle.showArchiveOnFinish)
              _labeledControl(
                'Archive on finish',
                Align(
                  alignment: Alignment.centerLeft,
                  child: ToggleSwitch(
                    checked: _archiveOnFinish,
                    onChanged: (value) =>
                        setState(() => _archiveOnFinish = value),
                  ),
                ),
              ),
            _cadenceEditor(controlSize),
            _field('Max runs', _maxRuns, placeholder: 'Unlimited'),
          ],
          if (_error != null)
            Text(_error!, style: TextStyle(color: context.statusColors.danger)),
        ]),
      ),
      actions: [
        Button(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('schedule-form-submit'),
          onPressed: readiness.canSubmit ? _submit : null,
          child: Text(editing ? 'Save changes' : 'Create schedule'),
        ),
      ],
    );
  }

  Widget _agentTargetField(
    Map<String, Map<String, AgentSummary>> agentDirectories,
  ) {
    final target = widget.schedule?.target;
    final agentId = target is AgentScheduleTarget ? target.agentId : null;
    final agent = agentId == null
        ? null
        : agentDirectories[_serverId]?[agentId];
    final label = agent == null
        ? 'Agent unavailable'
        : agent.title.trim().isEmpty
        ? 'Untitled agent'
        : agent.title;
    return _labeledControl(
      'Target',
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: context.tokens.outlineVariant),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  List<Widget> _withFieldSpacing(List<Widget> fields) => [
    for (var index = 0; index < fields.length; index++) ...[
      if (index > 0) const SizedBox(height: 16),
      fields[index],
    ],
  ];

  Widget _labeledControl(
    String label,
    Widget control, {
    String? helper,
    bool error = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        label,
        style: TextStyle(color: context.tokens.onSurfaceVariant, fontSize: 14),
      ),
      const SizedBox(height: 8),
      control,
      if (helper != null) ...[
        const SizedBox(height: 4),
        Text(
          helper,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.textStyles.bodySmall?.copyWith(
            color: error
                ? context.statusColors.danger
                : context.tokens.onSurfaceVariant,
          ),
        ),
      ],
    ],
  );

  Widget _field(
    String label,
    TextEditingController controller, {
    String? placeholder,
    String? helper,
    int maxLines = 1,
    ValueChanged<String>? onChanged,
  }) => _labeledControl(
    label,
    ConstrainedBox(
      constraints: BoxConstraints(minHeight: maxLines > 1 ? 96 : 0),
      child: TextBox(
        controller: controller,
        placeholder: placeholder,
        maxLines: maxLines,
        onChanged: onChanged,
      ),
    ),
    helper: helper,
  );

  Widget _cadenceEditor(PaseoFieldControlSize controlSize) {
    final cadence = CronScheduleCadence(
      expression: _cron.text.trim(),
      timezone: _timezone,
    );
    final error = _cron.text.trim().isEmpty
        ? null
        : validateScheduleCron(_cron.text);
    final preview = error == null && _cron.text.trim().isNotEmpty
        ? describeScheduleCron(cadence) ?? _cron.text.trim()
        : null;
    final selectedPresetId = resolveCronPresetId(cadence);
    return _labeledControl(
      'Cadence',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PaseoSelectField<String>(
            field: false,
            triggerKey: const ValueKey('schedule-cadence-preset-trigger'),
            label: 'Cadence',
            value: selectedPresetId == customCronPresetId
                ? null
                : selectedPresetId,
            selectedDisplay: SelectFieldDisplay(
              label: resolveCronPresetLabel(cadence),
            ),
            options: [
              for (final preset in scheduleCadencePresets)
                SelectFieldOption(
                  id: preset.id,
                  value: preset.id,
                  label: preset.label,
                  optionKey: ValueKey('schedule-cadence-preset-${preset.id}'),
                ),
            ],
            onChanged: (value, _) {
              final preset = scheduleCadencePresets.firstWhere(
                (preset) => preset.id == value,
              );
              setState(() => _cron.text = preset.expression);
            },
            placeholder: 'Select cadence',
            emptyText: 'No cadences found',
            searchable: false,
            title: 'Cadence',
            size: controlSize,
          ),
          const SizedBox(height: 12),
          TextBox(
            key: const ValueKey('cadence-cron-expression'),
            controller: _cron,
            placeholder: '0 9 * * *',
            style: const TextStyle(fontFamily: 'monospace'),
            onChanged: (_) => setState(() {}),
          ),
          if (error != null || preview != null) ...[
            const SizedBox(height: 4),
            Text(
              error ?? preview!,
              style: context.textStyles.bodySmall?.copyWith(
                color: error == null
                    ? context.tokens.onSurfaceVariant
                    : context.statusColors.danger,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _projectSelector(List<ScheduleProjectTarget> targets) {
    final options = [
      for (final target in targets)
        if (target.serverId == _serverId) target,
    ];
    ScheduleProjectTarget? selected;
    for (final target in options) {
      if (target.cwd == _cwd.text.trim()) {
        selected = target;
        break;
      }
    }
    final storedDisplay =
        selected == null &&
            _cwd.text.trim().isNotEmpty &&
            widget.schedule != null
        ? SelectFieldDisplay(
            label: describeScheduleCwd(
              serverId: _serverId ?? '',
              cwd: _cwd.text,
              projectNameByCwd: const {},
            ),
          )
        : null;
    return _labeledControl(
      'Project',
      PaseoSelectField<String>(
        field: false,
        triggerKey: const ValueKey('schedule-project-trigger'),
        label: 'Project',
        value: selected?.optionId,
        selectedDisplay: selected == null
            ? storedDisplay
            : SelectFieldDisplay(label: selected.projectName),
        options: [
          for (final target in options)
            SelectFieldOption(
              id: target.optionId,
              value: target.optionId,
              label: target.projectName,
              leading: _lucideScheduleIcon(
                _lucideFolderSvg,
                key: ValueKey('schedule-project-icon-${target.optionId}'),
              ),
            ),
        ],
        onChanged: (value, _) {
          final target = options.firstWhere(
            (target) => target.optionId == value,
          );
          setState(() {
            _serverId = target.serverId;
            _cwd.text = target.cwd;
            _clearProviderSelection();
          });
        },
        placeholder: 'Select project',
        emptyText: 'No projects found',
        searchable: true,
        searchPlaceholder: 'Search projects...',
        title: 'Select project',
        size: MediaQuery.sizeOf(context).width < adaptiveModalCompactBreakpoint
            ? PaseoFieldControlSize.md
            : PaseoFieldControlSize.sm,
      ),
    );
  }

  Widget _hostStatusDot(String serverId, bool connected) => Center(
    child: Container(
      key: ValueKey('schedule-host-status-$serverId'),
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: connected
            ? context.statusColors.success
            : context.statusColors.neutral,
        shape: BoxShape.circle,
      ),
    ),
  );

  Widget _providerEditor({
    required ProvidersSnapshotState? snapshot,
    required ProvidersSnapshotScope? scope,
    required ScheduleProviderSelection selection,
    required bool hasClient,
    required PaseoFieldControlSize controlSize,
  }) {
    if (_cwd.text.trim().isEmpty) {
      return const Text('Select a project to choose a model.');
    }
    if (!hasClient) {
      return const Text('Host is not connected.');
    }
    if (snapshot?.supportsSnapshot == false) {
      return const Text('Update the host to use provider discovery.');
    }
    if (snapshot == null || (snapshot.isLoading && snapshot.entries == null)) {
      return const Center(child: ProgressRing());
    }
    if (snapshot.error != null && snapshot.entries == null) {
      return Text('Failed to load providers: ${snapshot.error}');
    }
    if (selection.providers.isEmpty) {
      return const Text(
        'No agent providers are available. '
        'Install or enable a provider on this host and try again.',
      );
    }

    final selectorProviders = buildSelectableProviderSelectorProviders(
      snapshot.entries,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _withFieldSpacing([
        _labeledControl(
          'Model',
          CombinedModelSelector(
            providers: selectorProviders,
            selectedProvider: selection.provider,
            selectedModel: selection.model,
            isLoading: snapshot.isLoading || snapshot.isFetching,
            disabled: _submitting,
            triggerFill: true,
            renderTrigger: (input) => PaseoSelectFieldTrigger(
              key: const ValueKey('schedule-model-trigger'),
              label: input.selectedModelLabel,
              isPlaceholder: selection.model.isEmpty,
              placeholder: input.selectedModelLabel,
              leading: selection.provider.isEmpty
                  ? null
                  : ProviderIcon(
                      provider: selection.provider,
                      size: 16,
                      color: context.paseoPalette.foregroundMuted,
                    ),
              active: input.hovered || input.pressed || input.isOpen,
              disabled: input.disabled,
              size: controlSize,
            ),
            onSelect: (provider, model) => setState(() {
              _selectionTouched = true;
              _provider = provider;
              _model = model.isEmpty ? null : model;
              _modeId = null;
              _thinkingOptionId = null;
            }),
            onOpen: scope == null
                ? null
                : () => ref
                      .read(providersSnapshotProvider(scope).notifier)
                      .refetchIfStale(selection.provider),
            onRetryProvider: scope == null
                ? null
                : (provider) => unawaited(
                    ref.read(providersSnapshotProvider(scope).notifier).refresh(
                      [provider],
                    ),
                  ),
            isRetryingProvider: snapshot.isRefreshing,
          ),
        ),
        if (selection.thinkingOptions.isNotEmpty)
          _labeledControl(
            'Thinking',
            PaseoSelectField<String>(
              field: false,
              triggerKey: const ValueKey('schedule-thinking-trigger'),
              label: 'Thinking',
              value: selection.thinkingOptionId,
              selectedDisplay: SelectFieldDisplay(
                label:
                    selection.thinkingOptions
                        .where(
                          (option) => option.id == selection.thinkingOptionId,
                        )
                        .firstOrNull
                        ?.label ??
                    selection.thinkingOptionId,
              ),
              options: [
                for (final option in selection.thinkingOptions)
                  SelectFieldOption(
                    id: option.id,
                    value: option.id,
                    label: option.label,
                    optionKey: ValueKey(
                      'schedule-thinking-option-${option.id}',
                    ),
                    leading: _lucideScheduleIcon(
                      _lucideBrainSvg,
                      key: ValueKey('schedule-thinking-icon-${option.id}'),
                    ),
                  ),
              ],
              onChanged: (value, _) => setState(() {
                _selectionTouched = true;
                _thinkingOptionId = value;
              }),
              placeholder: 'Select thinking',
              emptyText: 'No thinking options found',
              searchable: selection.thinkingOptions.length > 6,
              title: 'Select thinking',
              size: controlSize,
              disabled: _submitting,
            ),
          ),
        if (selection.modes.isNotEmpty)
          _labeledControl(
            'Mode',
            PaseoSelectField<String>(
              field: false,
              triggerKey: const ValueKey('schedule-mode-trigger'),
              label: 'Mode',
              value: selection.modeId,
              selectedDisplay: SelectFieldDisplay(
                label:
                    selection.modes
                        .where((mode) => mode.id == selection.modeId)
                        .firstOrNull
                        ?.label ??
                    selection.modeId,
              ),
              options: [
                for (final mode in selection.modes)
                  SelectFieldOption(
                    id: mode.id,
                    value: mode.id,
                    label: mode.label,
                  ),
              ],
              onChanged: (value, _) => setState(() {
                _selectionTouched = true;
                _modeId = value;
              }),
              placeholder: 'Default mode',
              emptyText: 'No modes found',
              searchable: selection.modes.length > 6,
              title: 'Select mode',
              size: controlSize,
              disabled: _submitting,
            ),
          ),
      ]),
    );
  }

  Widget _isolationSelector(
    String effectiveIsolation,
    PaseoFieldControlSize controlSize,
  ) => _labeledControl(
    'Isolation',
    PaseoSelectField<String>(
      key: const ValueKey('schedule-isolation'),
      field: false,
      triggerKey: const ValueKey('schedule-isolation-trigger'),
      label: 'Isolation',
      value: effectiveIsolation,
      selectedDisplay: SelectFieldDisplay(
        label: effectiveIsolation == 'worktree' ? 'Worktree' : 'Local',
      ),
      options: [
        SelectFieldOption(
          id: 'local',
          value: 'local',
          label: 'Local',
          optionKey: const ValueKey('schedule-isolation-local'),
          leading: _lucideScheduleIcon(_lucideFolderSvg),
        ),
        SelectFieldOption(
          id: 'worktree',
          value: 'worktree',
          label: 'Worktree',
          optionKey: const ValueKey('schedule-isolation-worktree'),
          leading: _lucideScheduleIcon(_lucideGitBranchSvg),
        ),
      ],
      onChanged: (value, _) => setState(() {
        _isolationTouched = true;
        _isolation = value;
      }),
      placeholder: 'Select isolation',
      emptyText: 'No isolation options found',
      searchable: false,
      title: 'Isolation',
      size: controlSize,
      triggerLeading: _lucideScheduleIcon(
        effectiveIsolation == 'worktree'
            ? _lucideGitBranchSvg
            : _lucideFolderSvg,
      ),
    ),
  );

  Widget _lucideScheduleIcon(String svg, {Key? key}) => SvgPicture.string(
    svg,
    key: key,
    width: 16,
    height: 16,
    colorFilter: ColorFilter.mode(
      context.paseoPalette.foregroundMuted,
      BlendMode.srcIn,
    ),
  );

  void _clearProviderSelection() {
    _provider = null;
    _model = null;
    _modeId = null;
    _thinkingOptionId = null;
  }

  Future<void> _persistPreferences(String provider) async {
    final updated = await _preferencesService.update((current) {
      final selection = mergeCreateAgentSelectionPreferences(
        preferences: current,
        provider: provider,
        modelId: _model,
        modeId: _modeId,
        thinkingOptionId: _thinkingOptionId,
      );
      return selection.copyWith(isolation: _isolation);
    });
    if (mounted) setState(() => _preferences = updated);
  }

  Future<void> _submit() async {
    final prompt = _prompt.text.trim();
    final cron = _cron.text.trim();
    final provider = _provider?.trim() ?? '';
    final cwd = _cwd.text.trim();
    final maxRuns = parseScheduleMaxRuns(_maxRuns.text);
    final cronError = validateScheduleCron(cron);
    final agentTarget = widget.schedule?.target is AgentScheduleTarget;
    if (!agentTarget && prompt.isEmpty) {
      setState(() => _error = 'Prompt is required.');
      return;
    }
    if (cronError != null) {
      setState(() => _error = cronError);
      return;
    }
    if (!agentTarget && (provider.isEmpty || cwd.isEmpty)) {
      setState(() => _error = 'Provider and project are required.');
      return;
    }
    final serverId = _serverId;
    if (serverId == null) {
      setState(() => _error = 'A connected host is required.');
      return;
    }
    final client = ref.read(hostRuntimeClientsProvider)[serverId];
    final supportsWorkspaceMultiplicity =
        client?.serverInfo?.features['workspaceMultiplicity'] == true;
    final selectedProject = ref
        .read(scheduleProjectTargetsProvider)
        .value
        ?.targets
        .where((target) => target.serverId == serverId && target.cwd == cwd)
        .firstOrNull;
    final workspaceLifecycle = resolveScheduleWorkspaceLifecycle(
      supportsWorkspaceMultiplicity: supportsWorkspaceMultiplicity,
      hasProject: cwd.isNotEmpty,
      projectIsGit: selectedProject?.isGit == true,
      isolation: _isolation,
      archiveOnFinish: _archiveOnFinish,
    );
    setState(() {
      _submitting = true;
      _error = null;
    });
    final cadence = CronScheduleCadence(expression: cron, timezone: _timezone);
    try {
      final notifier = ref.read(aggregatedSchedulesProvider.notifier);
      if (!agentTarget) await _persistPreferences(provider);
      if (widget.schedule == null) {
        await notifier.create(
          serverId,
          prompt: prompt,
          name: _name.text.trim().isEmpty ? null : _name.text.trim(),
          cadence: cadence,
          target: NewAgentScheduleTarget(
            config: ScheduleNewAgentConfig(
              provider: provider,
              cwd: cwd,
              model: _model,
              modeId: _modeId,
              thinkingOptionId: _thinkingOptionId,
              isolation: workspaceLifecycle.submitIsolation,
              archiveOnFinish: workspaceLifecycle.submitArchiveOnFinish,
              title: _name.text.trim().isEmpty ? null : _name.text.trim(),
            ),
          ),
          maxRuns: maxRuns,
        );
      } else {
        final changes = <String, Object?>{'cadence': cadence.toJson()};
        if (widget.schedule!.target is NewAgentScheduleTarget) {
          changes.addAll({
            'name': _name.text.trim().isEmpty ? null : _name.text.trim(),
            'prompt': prompt,
            'maxRuns': maxRuns,
          });
          changes['newAgentConfig'] = {
            'provider': provider,
            'cwd': cwd,
            'model': _model,
            'modeId': _modeId,
            'thinkingOptionId': _thinkingOptionId,
            if (workspaceLifecycle.submitIsolation != null)
              'isolation': workspaceLifecycle.submitIsolation,
            if (workspaceLifecycle.submitArchiveOnFinish != null)
              'archiveOnFinish': workspaceLifecycle.submitArchiveOnFinish,
          };
        }
        await notifier.updateSchedule(serverId, widget.schedule!.id, changes);
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = '$error';
        });
      }
    }
  }
}

String _title(ScheduleSummary schedule) =>
    schedule.name?.trim().isNotEmpty == true ? schedule.name! : 'Schedule';

IconData _providerIcon(String? provider) {
  final normalized = provider?.toLowerCase();
  if (normalized?.contains('codex') == true) return FluentIcons.code;
  if (normalized != null) return FluentIcons.robot;
  return FluentIcons.contact;
}

String _meta(
  ScheduleSummary schedule, {
  required _ScheduleDerivedState state,
  required String serverName,
  required bool singleHost,
}) {
  final parts = <String>[
    _cadenceLabel(schedule.cadence),
    'Created ${_timeAgo(schedule.createdAt)}',
    schedule.lastRunAt == null
        ? 'Never run'
        : 'Last run ${_timeAgo(schedule.lastRunAt!)}',
  ];
  if (state == _ScheduleDerivedState.active && schedule.nextRunAt != null) {
    parts.add('Next run ${_timeAgo(schedule.nextRunAt!, future: true)}');
  }
  if (!singleHost) parts.insert(0, serverName);
  return parts.join(' · ');
}

final class _ResolvedScheduleRow {
  const _ResolvedScheduleRow({
    required this.entry,
    required this.state,
    required this.targetLabel,
    required this.provider,
  });

  final AggregatedSchedule entry;
  final _ScheduleDerivedState state;
  final String targetLabel;
  final String? provider;
}

_ResolvedScheduleRow _resolveSchedule(
  AggregatedSchedule entry, {
  required Map<String, Map<String, AgentSummary>> agentDirectories,
  required Map<String, String> projectNameByCwd,
  required DateTime now,
}) {
  final schedule = entry.schedule;
  final target = schedule.target;
  String targetLabel;
  String? provider;
  var targetGone = false;
  switch (target) {
    case NewAgentScheduleTarget(config: final config):
      targetLabel = describeScheduleCwd(
        serverId: entry.serverId,
        cwd: config.cwd,
        projectNameByCwd: projectNameByCwd,
      );
      provider = config.provider;
    case AgentScheduleTarget(agentId: final agentId) ||
        SelfScheduleTarget(agentId: final agentId):
      final directory = agentDirectories[entry.serverId];
      final agent = directory?[agentId];
      targetGone = directory != null && agent == null;
      targetLabel = agent == null
          ? 'Agent unavailable'
          : agent.title.trim().isEmpty
          ? 'Untitled agent'
          : agent.title;
      provider = agent?.provider;
  }
  final expiresAt = schedule.expiresAt == null
      ? null
      : DateTime.tryParse(schedule.expiresAt!);
  final state = expiresAt != null && !expiresAt.isAfter(now)
      ? _ScheduleDerivedState.expired
      : targetGone
      ? _ScheduleDerivedState.targetGone
      : switch (schedule.status) {
          ScheduleStatus.active => _ScheduleDerivedState.active,
          ScheduleStatus.paused => _ScheduleDerivedState.paused,
          ScheduleStatus.completed => _ScheduleDerivedState.finished,
        };
  return _ResolvedScheduleRow(
    entry: entry,
    state: state,
    targetLabel: targetLabel,
    provider: provider,
  );
}

String _cadenceLabel(ScheduleCadence cadence) => switch (cadence) {
  EveryScheduleCadence(everyMs: final everyMs) =>
    'Every ${Duration(milliseconds: everyMs)}',
  CronScheduleCadence(expression: final expression, timezone: final timezone) =>
    timezone == null ? expression : '$expression ($timezone)',
};

String _timeAgo(String value, {bool future = false}) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final delta = future
      ? parsed.difference(DateTime.now())
      : DateTime.now().difference(parsed);
  if (delta.isNegative) return future ? 'now' : 'just now';
  if (delta.inDays > 0) {
    return '${delta.inDays}d ${future ? 'from now' : 'ago'}';
  }
  if (delta.inHours > 0) {
    return '${delta.inHours}h ${future ? 'from now' : 'ago'}';
  }
  if (delta.inMinutes > 0) {
    return '${delta.inMinutes}m ${future ? 'from now' : 'ago'}';
  }
  return future ? 'soon' : 'just now';
}
