import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../state/schedules_provider.dart';
import '../widgets/fluent/toast.dart';

enum _ScheduleFilter { active, ended }

class SchedulesScreen extends ConsumerStatefulWidget {
  const SchedulesScreen({super.key});

  @override
  ConsumerState<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends ConsumerState<SchedulesScreen> {
  var _filter = _ScheduleFilter.active;

  @override
  Widget build(BuildContext context) {
    final schedules = ref.watch(schedulesProvider);
    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Schedules'),
        commandBar: FilledButton(
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
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Row(
              children: [
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
              ],
            ),
          ),
          Expanded(
            child: schedules.when(
              loading: () => const Center(child: ProgressRing()),
              error: (error, _) => _ScheduleLoadError(
                onRetry: () => ref.read(schedulesProvider.notifier).reload(),
              ),
              data: (values) {
                final visible = values
                    .where((schedule) {
                      final ended = schedule.status == ScheduleStatus.completed;
                      return _filter == _ScheduleFilter.ended ? ended : !ended;
                    })
                    .toList(growable: false);
                if (visible.isEmpty) {
                  return _ScheduleEmptyState(
                    ended: _filter == _ScheduleFilter.ended,
                    onCreate: _showForm,
                  );
                }
                return ListView(
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
                          for (var index = 0; index < visible.length; index++)
                            _ScheduleRow(
                              schedule: visible[index],
                              showDivider: index > 0,
                              onEdit: () => _showForm(visible[index]),
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showForm([ScheduleSummary? schedule]) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _ScheduleFormDialog(schedule: schedule),
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
    required this.schedule,
    required this.showDivider,
    required this.onEdit,
  });

  final ScheduleSummary schedule;
  final bool showDivider;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = switch (schedule.status) {
      ScheduleStatus.active => ('Active', context.statusColors.success),
      ScheduleStatus.paused => ('Paused', context.statusColors.neutral),
      ScheduleStatus.completed => ('Finished', context.statusColors.neutral),
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
                      _providerIcon(schedule),
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
                          _target(schedule),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.tokens.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _meta(schedule),
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
                  _ScheduleMenu(schedule: schedule, onEdit: onEdit),
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
  const _ScheduleMenu({required this.schedule, required this.onEdit});
  final ScheduleSummary schedule;
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
    final notifier = ref.read(schedulesProvider.notifier);
    final canExecute =
        widget.schedule.target is NewAgentScheduleTarget &&
        widget.schedule.status != ScheduleStatus.completed;
    return DropDownButton(
      title: const Icon(FluentIcons.more_vertical, size: 14),
      items: [
        MenuFlyoutItem(
          leading: const Icon(FluentIcons.edit, size: 14),
          text: const Text('Edit schedule'),
          onPressed: widget.onEdit,
        ),
        if (widget.schedule.target is NewAgentScheduleTarget) ...[
          if (widget.schedule.status == ScheduleStatus.paused)
            MenuFlyoutItem(
              leading: const Icon(FluentIcons.play, size: 14),
              text: const Text('Resume schedule'),
              onPressed: canExecute
                  ? () => _run(() async {
                      await notifier.resume(widget.schedule.id);
                    })
                  : null,
            )
          else
            MenuFlyoutItem(
              leading: const Icon(FluentIcons.pause, size: 14),
              text: const Text('Pause schedule'),
              onPressed: canExecute
                  ? () => _run(() async {
                      await notifier.pause(widget.schedule.id);
                    })
                  : null,
            ),
          MenuFlyoutItem(
            leading: const Icon(FluentIcons.refresh, size: 14),
            text: const Text('Run now'),
            onPressed: canExecute
                ? () => _run(() async {
                    await notifier.runOnce(widget.schedule.id);
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

  Future<void> _confirmDelete(SchedulesNotifier notifier) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Delete schedule'),
        content: Text(
          'Delete "${_title(widget.schedule)}"? This cannot be undone.',
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
      await _run(() => notifier.delete(widget.schedule.id));
    }
  }
}

class _ScheduleFormDialog extends ConsumerStatefulWidget {
  const _ScheduleFormDialog({this.schedule});
  final ScheduleSummary? schedule;

  @override
  ConsumerState<_ScheduleFormDialog> createState() =>
      _ScheduleFormDialogState();
}

class _ScheduleFormDialogState extends ConsumerState<_ScheduleFormDialog> {
  late final TextEditingController _name;
  late final TextEditingController _prompt;
  late final TextEditingController _cron;
  late final TextEditingController _timezone;
  late final TextEditingController _provider;
  late final TextEditingController _model;
  late final TextEditingController _cwd;
  late final TextEditingController _maxRuns;
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
    final cadence = schedule?.cadence;
    _name = TextEditingController(text: schedule?.name ?? '');
    _prompt = TextEditingController(text: schedule?.prompt ?? '');
    _cron = TextEditingController(
      text: cadence is CronScheduleCadence ? cadence.expression : '0 9 * * *',
    );
    _timezone = TextEditingController(
      text: cadence is CronScheduleCadence ? cadence.timezone ?? '' : '',
    );
    _provider = TextEditingController(text: config?.provider ?? 'codex');
    _model = TextEditingController(text: config?.model ?? '');
    _cwd = TextEditingController(text: config?.cwd ?? '');
    _maxRuns = TextEditingController(text: schedule?.maxRuns?.toString() ?? '');
    _isolation = config?.isolation ?? 'local';
    _archiveOnFinish = config?.archiveOnFinish ?? true;
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _prompt,
      _cron,
      _timezone,
      _provider,
      _model,
      _cwd,
      _maxRuns,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.schedule != null;
    final newAgent = widget.schedule?.target is! AgentScheduleTarget;
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 560),
      title: Text(editing ? 'Edit schedule' : 'New schedule'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _field('Name', _name, placeholder: 'Optional'),
              _field('Prompt', _prompt, maxLines: 4),
              _field(
                'Cadence',
                _cron,
                placeholder: '0 9 * * *',
                helper: 'Five-field cron expression',
              ),
              _field('Timezone', _timezone, placeholder: 'UTC'),
              if (newAgent) ...[
                _field('Provider', _provider),
                _field('Model', _model, placeholder: 'Provider default'),
                _field('Project', _cwd, placeholder: 'Working directory'),
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
              ],
              _field('Max runs', _maxRuns, placeholder: 'Unlimited'),
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

  Future<void> _submit() async {
    final prompt = _prompt.text.trim();
    final cron = _cron.text.trim();
    final provider = _provider.text.trim();
    final cwd = _cwd.text.trim();
    final maxRuns = _maxRuns.text.trim().isEmpty
        ? null
        : int.tryParse(_maxRuns.text.trim());
    final cronError = validateCronExpression(cron);
    if (prompt.isEmpty) {
      setState(() => _error = 'Prompt is required.');
      return;
    }
    if (cronError != null) {
      setState(() => _error = cronError);
      return;
    }
    if (widget.schedule?.target is! AgentScheduleTarget &&
        (provider.isEmpty || cwd.isEmpty)) {
      setState(() => _error = 'Provider and project are required.');
      return;
    }
    if (_maxRuns.text.trim().isNotEmpty && (maxRuns == null || maxRuns <= 0)) {
      setState(() => _error = 'Max runs must be a positive integer.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final cadence = CronScheduleCadence(
      expression: cron,
      timezone: _timezone.text.trim().isEmpty ? null : _timezone.text.trim(),
    );
    try {
      final notifier = ref.read(schedulesProvider.notifier);
      if (widget.schedule == null) {
        await notifier.create(
          prompt: prompt,
          name: _name.text.trim().isEmpty ? null : _name.text.trim(),
          cadence: cadence,
          target: NewAgentScheduleTarget(
            config: ScheduleNewAgentConfig(
              provider: provider,
              cwd: cwd,
              model: _model.text.trim().isEmpty ? null : _model.text.trim(),
              isolation: _isolation,
              archiveOnFinish: _archiveOnFinish,
            ),
          ),
          maxRuns: maxRuns,
        );
      } else {
        final changes = <String, Object?>{
          'name': _name.text.trim().isEmpty ? null : _name.text.trim(),
          'prompt': prompt,
          'cadence': cadence.toJson(),
          'maxRuns': maxRuns,
        };
        if (widget.schedule!.target is NewAgentScheduleTarget) {
          changes['newAgentConfig'] = {
            'provider': provider,
            'cwd': cwd,
            'model': _model.text.trim().isEmpty ? null : _model.text.trim(),
            'isolation': _isolation,
            'archiveOnFinish': _archiveOnFinish,
          };
        }
        await notifier.updateSchedule(widget.schedule!.id, changes);
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

IconData _providerIcon(ScheduleSummary schedule) => switch (schedule.target) {
  NewAgentScheduleTarget(config: final config)
      when config.provider.toLowerCase().contains('codex') =>
    FluentIcons.code,
  NewAgentScheduleTarget() => FluentIcons.robot,
  _ => FluentIcons.contact,
};

String _target(ScheduleSummary schedule) => switch (schedule.target) {
  NewAgentScheduleTarget(config: final config) =>
    config.model == null
        ? config.cwd
        : '${config.provider}/${config.model} · ${config.cwd}',
  AgentScheduleTarget(agentId: final id) =>
    'Agent ${id.substring(0, id.length.clamp(0, 7))}',
  SelfScheduleTarget(agentId: final id) =>
    'Agent ${id.substring(0, id.length.clamp(0, 7))}',
};

String _meta(ScheduleSummary schedule) {
  final parts = <String>[
    _cadenceLabel(schedule.cadence),
    'Created ${_timeAgo(schedule.createdAt)}',
    schedule.lastRunAt == null
        ? 'Never run'
        : 'Last run ${_timeAgo(schedule.lastRunAt!)}',
  ];
  if (schedule.status == ScheduleStatus.active && schedule.nextRunAt != null) {
    parts.add('Next run ${_timeAgo(schedule.nextRunAt!, future: true)}');
  }
  return parts.join(' · ');
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
