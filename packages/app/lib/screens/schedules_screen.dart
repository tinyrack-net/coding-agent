import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../composer/provider_model_selection.dart';
import '../core/theme.dart';
import '../providers/providers_snapshot.dart';
import '../state/agents_provider.dart';
import '../state/daemon_providers.dart';
import '../state/host_registry_provider.dart';
import '../state/providers_snapshot_provider.dart';
import '../state/schedule_form_model.dart';
import '../state/schedule_project_targets_provider.dart';
import '../state/schedules_provider.dart';
import '../widgets/combined_model_selector.dart';
import '../widgets/fluent/toast.dart';

enum _ScheduleFilter { active, ended }

enum _ScheduleDerivedState { active, paused, expired, finished, targetGone }

const _allScheduleHosts = '__all__';

class SchedulesScreen extends ConsumerStatefulWidget {
  const SchedulesScreen({super.key});

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
    await showDialog<void>(
      context: context,
      builder: (context) => _ScheduleFormDialog(
        schedule: entry?.schedule,
        serverId: entry?.serverId,
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
  const _ScheduleFormDialog({this.schedule, this.serverId});
  final ScheduleSummary? schedule;
  final String? serverId;

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
    _serverId =
        widget.serverId ??
        ref.read(activeHostProvider)?.serverId ??
        ref.read(hostRegistryProvider).hosts.firstOrNull?.serverId;
    _isolation = config?.isolation ?? 'local';
    _archiveOnFinish = config?.archiveOnFinish ?? true;
  }

  @override
  void dispose() {
    for (final controller in [_name, _prompt, _cron, _cwd, _maxRuns]) {
      controller.dispose();
    }
    super.dispose();
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
    final client = _serverId == null
        ? null
        : ref.watch(hostRuntimeClientsProvider)[_serverId];
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
    final providerSelection = resolveScheduleProviderSelection(
      entries: snapshot?.entries,
      selectedProvider: _provider,
      selectedModel: _model,
      selectedModeId: _modeId,
      selectedThinkingOptionId: _thinkingOptionId,
    );
    if (providerSelection.isAvailable) {
      _provider = providerSelection.provider;
      _model = providerSelection.model.isEmpty ? null : providerSelection.model;
      _modeId = providerSelection.modeId.isEmpty
          ? null
          : providerSelection.modeId;
      _thinkingOptionId = providerSelection.thinkingOptionId.isEmpty
          ? null
          : providerSelection.thinkingOptionId;
    }
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 560),
      title: Text(
        agentTarget
            ? 'Edit heartbeat'
            : editing
            ? 'Edit schedule'
            : 'New schedule',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (agentTarget) ...[
                _agentTargetField(agentDirectories),
                _cadenceEditor(),
              ] else ...[
                if (!editing && hosts.length > 1) ...[
                  const Text('Host'),
                  const SizedBox(height: 6),
                  ComboBox<String>(
                    value: _serverId,
                    items: [
                      for (final host in hosts)
                        ComboBoxItem(
                          value: host.serverId,
                          child: Text(host.label),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      _serverId = value;
                      _cwd.clear();
                      _clearProviderSelection();
                    }),
                  ),
                  const SizedBox(height: 12),
                ],
                _field('Name', _name, placeholder: 'Optional'),
                _field(
                  'Prompt',
                  _prompt,
                  placeholder: 'What should the agent do each run?',
                  maxLines: 4,
                ),
                _projectSelector(projectTargets),
                _providerEditor(
                  snapshot: snapshot,
                  scope: snapshotScope,
                  selection: providerSelection,
                  hasClient: client != null,
                ),
                _cadenceEditor(),
                const SizedBox(height: 12),
                const Text('Isolation'),
                const SizedBox(height: 6),
                ComboBox<String>(
                  value: _isolation,
                  items: const [
                    ComboBoxItem(value: 'local', child: Text('Local')),
                    ComboBoxItem(value: 'worktree', child: Text('Worktree')),
                  ],
                  onChanged: (value) =>
                      setState(() => _isolation = value ?? 'local'),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Archive on finish'),
                    ToggleSwitch(
                      checked: _archiveOnFinish,
                      onChanged: (value) =>
                          setState(() => _archiveOnFinish = value),
                    ),
                  ],
                ),
                _field('Max runs', _maxRuns, placeholder: 'Unlimited'),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: context.statusColors.danger),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        Button(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Target'),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(color: context.tokens.outlineVariant),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? placeholder,
    String? helper,
    int maxLines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label),
        const SizedBox(height: 6),
        TextBox(
          controller: controller,
          placeholder: placeholder,
          maxLines: maxLines,
        ),
        if (helper != null) ...[
          const SizedBox(height: 4),
          Text(helper, style: context.textStyles.bodySmall),
        ],
      ],
    ),
  );

  Widget _cadenceEditor() {
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Cadence'),
          const SizedBox(height: 6),
          ComboBox<String>(
            value: resolveCronPresetId(cadence),
            items: [
              for (final preset in scheduleCadencePresets)
                ComboBoxItem(value: preset.id, child: Text(preset.label)),
              const ComboBoxItem(
                value: customCronPresetId,
                child: Text('Custom cron'),
              ),
            ],
            onChanged: (value) {
              if (value == null || value == customCronPresetId) return;
              final preset = scheduleCadencePresets.firstWhere(
                (preset) => preset.id == value,
              );
              setState(() => _cron.text = preset.expression);
            },
          ),
          const SizedBox(height: 12),
          TextBox(
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
    final storedValue =
        selected == null &&
            _cwd.text.trim().isNotEmpty &&
            widget.schedule != null
        ? '__stored_project__'
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Project'),
          const SizedBox(height: 6),
          ComboBox<String>(
            value: selected?.optionId ?? storedValue,
            placeholder: const Text('Select project'),
            items: [
              if (storedValue != null)
                ComboBoxItem(
                  value: storedValue,
                  child: Text(
                    describeScheduleCwd(
                      serverId: _serverId ?? '',
                      cwd: _cwd.text,
                      projectNameByCwd: const {},
                    ),
                  ),
                ),
              for (final target in options)
                ComboBoxItem(
                  value: target.optionId,
                  child: Text(target.projectName),
                ),
            ],
            onChanged: (value) {
              if (value == null || value == storedValue) return;
              final target = options.firstWhere(
                (target) => target.optionId == value,
              );
              setState(() {
                _serverId = target.serverId;
                _cwd.text = target.cwd;
                _clearProviderSelection();
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _providerEditor({
    required ProvidersSnapshotState? snapshot,
    required ProvidersSnapshotScope? scope,
    required ScheduleProviderSelection selection,
    required bool hasClient,
  }) {
    if (_cwd.text.trim().isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text('Select a project to choose a model.'),
      );
    }
    if (!hasClient) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text('Host is not connected.'),
      );
    }
    if (snapshot?.supportsSnapshot == false) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text('Update the host to use provider discovery.'),
      );
    }
    if (snapshot == null || (snapshot.isLoading && snapshot.entries == null)) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Center(child: ProgressRing()),
      );
    }
    if (snapshot.error != null && snapshot.entries == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text('Failed to load providers: ${snapshot.error}'),
      );
    }
    if (!selection.isAvailable) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text(
          'No agent providers are available. '
          'Install or enable a provider on this host and try again.',
        ),
      );
    }

    final selectorProviders = buildSelectableProviderSelectorProviders(
      snapshot.entries,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Model'),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: ComboBox<String>(
                  key: const ValueKey('schedule-provider-selector'),
                  value: selection.provider,
                  items: [
                    for (final provider in selection.providers)
                      ComboBoxItem(
                        value: provider.provider,
                        child: Text(provider.label ?? provider.provider),
                      ),
                  ],
                  onChanged: _submitting
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() {
                            _provider = value;
                            _model = null;
                            _modeId = null;
                            _thinkingOptionId = null;
                          });
                        },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: CombinedModelSelector(
                  providers: selectorProviders,
                  selectedProvider: selection.provider,
                  selectedModel: selection.model,
                  isLoading: snapshot.isLoading || snapshot.isFetching,
                  disabled: _submitting,
                  onSelect: (provider, model) => setState(() {
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
                          ref
                              .read(providersSnapshotProvider(scope).notifier)
                              .refresh([provider]),
                        ),
                  isRetryingProvider: snapshot.isRefreshing,
                ),
              ),
            ],
          ),
          if (selection.modes.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Mode'),
            const SizedBox(height: 6),
            ComboBox<String>(
              key: const ValueKey('schedule-mode-selector'),
              value: selection.modeId,
              items: [
                for (final mode in selection.modes)
                  ComboBoxItem(value: mode.id, child: Text(mode.label)),
              ],
              onChanged: _submitting
                  ? null
                  : (value) => setState(() => _modeId = value),
            ),
          ],
          if (selection.thinkingOptions.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Thinking'),
            const SizedBox(height: 6),
            ComboBox<String>(
              key: const ValueKey('schedule-thinking-selector'),
              value: selection.thinkingOptionId,
              items: [
                for (final option in selection.thinkingOptions)
                  ComboBoxItem(value: option.id, child: Text(option.label)),
              ],
              onChanged: _submitting
                  ? null
                  : (value) => setState(() => _thinkingOptionId = value),
            ),
          ],
        ],
      ),
    );
  }

  void _clearProviderSelection() {
    _provider = null;
    _model = null;
    _modeId = null;
    _thinkingOptionId = null;
  }

  Future<void> _submit() async {
    final prompt = _prompt.text.trim();
    final cron = _cron.text.trim();
    final provider = _provider?.trim() ?? '';
    final cwd = _cwd.text.trim();
    final maxRuns = _maxRuns.text.trim().isEmpty
        ? null
        : int.tryParse(_maxRuns.text.trim());
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
    if (!agentTarget &&
        _maxRuns.text.trim().isNotEmpty &&
        (maxRuns == null || maxRuns <= 0)) {
      setState(() => _error = 'Max runs must be a positive integer.');
      return;
    }
    final serverId = _serverId;
    if (serverId == null) {
      setState(() => _error = 'A connected host is required.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final cadence = CronScheduleCadence(expression: cron, timezone: _timezone);
    try {
      final notifier = ref.read(aggregatedSchedulesProvider.notifier);
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
              isolation: _isolation,
              archiveOnFinish: _archiveOnFinish,
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
            'isolation': _isolation,
            'archiveOnFinish': _archiveOnFinish,
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
