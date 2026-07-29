import 'package:agent_protocol/agent_protocol.dart';

const customCronPresetId = 'custom';

final class ScheduleFormReadiness {
  const ScheduleFormReadiness({
    required this.showProject,
    required this.showModel,
    required this.canSubmit,
  });

  final bool showProject;
  final bool showModel;
  final bool canSubmit;
}

ScheduleFormReadiness resolveScheduleFormReadiness({
  required bool agentTarget,
  required bool editing,
  required bool submitting,
  required String? serverId,
  required String prompt,
  required String cwd,
  required bool hasMatchedProject,
  required bool providerSelectionValid,
  required String cronExpression,
}) {
  final hasServer = serverId?.trim().isNotEmpty == true;
  final hasProject = cwd.trim().isNotEmpty;
  final cadenceValid = validateScheduleCron(cronExpression) == null;
  if (agentTarget) {
    return ScheduleFormReadiness(
      showProject: false,
      showModel: false,
      canSubmit: cadenceValid && !submitting,
    );
  }
  return ScheduleFormReadiness(
    showProject: editing || hasServer,
    showModel: hasProject,
    canSubmit:
        !submitting &&
        cadenceValid &&
        prompt.trim().isNotEmpty &&
        hasProject &&
        (editing || hasMatchedProject) &&
        providerSelectionValid,
  );
}

int? parseScheduleMaxRuns(String raw) {
  final match = RegExp(r'^[+-]?\d+').firstMatch(raw.trim());
  if (match == null) return null;
  final parsed = int.tryParse(match.group(0)!);
  return parsed != null && parsed > 0 ? parsed : null;
}

final class ScheduleWorkspaceLifecycle {
  const ScheduleWorkspaceLifecycle({
    required this.showIsolation,
    required this.showArchiveOnFinish,
    required this.effectiveIsolation,
    required this.submitIsolation,
    required this.submitArchiveOnFinish,
  });

  final bool showIsolation;
  final bool showArchiveOnFinish;
  final String effectiveIsolation;
  final String? submitIsolation;
  final bool? submitArchiveOnFinish;
}

ScheduleWorkspaceLifecycle resolveScheduleWorkspaceLifecycle({
  required bool supportsWorkspaceMultiplicity,
  required bool hasProject,
  required bool projectIsGit,
  required String isolation,
  required bool archiveOnFinish,
}) {
  final canUseWorktree =
      supportsWorkspaceMultiplicity && hasProject && projectIsGit;
  final effectiveIsolation = isolation == 'worktree' && canUseWorktree
      ? 'worktree'
      : 'local';
  final canSubmitLifecycle = supportsWorkspaceMultiplicity && hasProject;
  return ScheduleWorkspaceLifecycle(
    showIsolation: canUseWorktree,
    showArchiveOnFinish: canSubmitLifecycle,
    effectiveIsolation: effectiveIsolation,
    submitIsolation: canSubmitLifecycle ? effectiveIsolation : null,
    submitArchiveOnFinish: canSubmitLifecycle ? archiveOnFinish : null,
  );
}

final class ScheduleProviderSelection {
  const ScheduleProviderSelection({
    required this.providers,
    required this.provider,
    required this.model,
    required this.modeId,
    required this.thinkingOptionId,
    required this.modes,
    required this.thinkingOptions,
  });

  final List<ProviderSnapshotEntry> providers;
  final String provider;
  final String model;
  final String modeId;
  final String thinkingOptionId;
  final List<ProviderMode> modes;
  final List<ProviderSelectOption> thinkingOptions;

  bool get isAvailable => providers.isNotEmpty && provider.isNotEmpty;
}

ScheduleProviderSelection resolveScheduleProviderSelection({
  required List<ProviderSnapshotEntry>? entries,
  String? selectedProvider,
  String? selectedModel,
  String? selectedModeId,
  String? selectedThinkingOptionId,
}) {
  final providers = [
    for (final entry in entries ?? const <ProviderSnapshotEntry>[])
      if (entry.enabled && entry.status == ProviderCatalogStatus.ready) entry,
  ];
  if (providers.isEmpty) {
    return const ScheduleProviderSelection(
      providers: [],
      provider: '',
      model: '',
      modeId: '',
      thinkingOptionId: '',
      modes: [],
      thinkingOptions: [],
    );
  }

  final requestedProvider = selectedProvider?.trim() ?? '';
  final provider = providers.firstWhere(
    (entry) => entry.provider == requestedProvider,
    orElse: () => providers.first,
  );
  final models = provider.models ?? const <ProviderModelDefinition>[];
  final requestedModel = selectedModel?.trim() ?? '';
  final model =
      models.where((entry) => entry.id == requestedModel).firstOrNull ??
      models.where((entry) => entry.isDefault == true).firstOrNull ??
      models.firstOrNull;
  final modes = provider.modes ?? const <ProviderMode>[];
  final requestedMode = selectedModeId?.trim() ?? '';
  final modeId = modes.any((entry) => entry.id == requestedMode)
      ? requestedMode
      : modes.any((entry) => entry.id == provider.defaultModeId)
      ? provider.defaultModeId!
      : modes.firstOrNull?.id ?? '';
  final thinkingOptions =
      model?.thinkingOptions ?? const <ProviderSelectOption>[];
  final requestedThinking = selectedThinkingOptionId?.trim() ?? '';
  final thinkingOptionId =
      thinkingOptions.any((entry) => entry.id == requestedThinking)
      ? requestedThinking
      : thinkingOptions.any(
          (entry) => entry.id == model?.defaultThinkingOptionId,
        )
      ? model!.defaultThinkingOptionId!
      : thinkingOptions
                .where((entry) => entry.isDefault == true)
                .firstOrNull
                ?.id ??
            thinkingOptions.firstOrNull?.id ??
            '';

  return ScheduleProviderSelection(
    providers: List.unmodifiable(providers),
    provider: provider.provider,
    model: model?.id ?? '',
    modeId: modeId,
    thinkingOptionId: thinkingOptionId,
    modes: List.unmodifiable(modes),
    thinkingOptions: List.unmodifiable(thinkingOptions),
  );
}

final class ScheduleCadencePreset {
  const ScheduleCadencePreset({
    required this.id,
    required this.label,
    required this.expression,
  });

  final String id;
  final String label;
  final String expression;
}

const scheduleCadencePresets = <ScheduleCadencePreset>[
  ScheduleCadencePreset(
    id: 'every-minute',
    label: 'Every minute',
    expression: '* * * * *',
  ),
  ScheduleCadencePreset(
    id: 'every-hour',
    label: 'Every hour',
    expression: '0 * * * *',
  ),
  ScheduleCadencePreset(
    id: 'daily-9',
    label: 'Daily 9:00',
    expression: '0 9 * * *',
  ),
  ScheduleCadencePreset(
    id: 'weekdays-9',
    label: 'Weekdays 9:00',
    expression: '0 9 * * 1-5',
  ),
  ScheduleCadencePreset(
    id: 'mondays-9',
    label: 'Mondays 9:00',
    expression: '0 9 * * 1',
  ),
];

String resolveCronPresetId(CronScheduleCadence cadence) {
  final expression = cadence.expression.trim();
  for (final preset in scheduleCadencePresets) {
    if (preset.expression == expression) return preset.id;
  }
  return customCronPresetId;
}

String resolveCronPresetLabel(CronScheduleCadence cadence) {
  final id = resolveCronPresetId(cadence);
  for (final preset in scheduleCadencePresets) {
    if (preset.id == id) return preset.label;
  }
  return 'Custom cron';
}

CronScheduleCadence normalizeScheduleFormCadence(
  ScheduleCadence cadence,
  String timezone,
) {
  if (cadence is CronScheduleCadence) {
    return CronScheduleCadence(
      expression: cadence.expression,
      timezone: cadence.timezone ?? timezone,
    );
  }
  final everyMs = (cadence as EveryScheduleCadence).everyMs;
  return CronScheduleCadence(
    expression: _everyMsToCronExpression(everyMs),
    timezone: timezone,
  );
}

String? validateScheduleCron(String expression) {
  final trimmed = expression.trim();
  if (trimmed.isEmpty) return 'Enter a cron expression';
  final error = validateCronExpression(trimmed);
  return error?.replaceFirst(RegExp(r'^Invalid cron '), 'Invalid ');
}

String? describeScheduleCron(CronScheduleCadence cadence) {
  final expression = cadence.expression.trim();
  if (validateScheduleCron(expression) != null) return null;
  final fields = expression.split(RegExp(r'\s+'));
  final minute = fields[0];
  final hour = fields[1];
  final dayOfMonth = fields[2];
  final month = fields[3];
  final dayOfWeek = fields[4];
  if (minute == '*' &&
      hour == '*' &&
      dayOfMonth == '*' &&
      month == '*' &&
      dayOfWeek == '*') {
    return 'Every minute';
  }
  if (!RegExp(r'^\d+$').hasMatch(minute) || dayOfMonth != '*' || month != '*') {
    return null;
  }
  final minuteNumber = int.parse(minute);
  if (hour == '*') {
    if (dayOfWeek != '*') return null;
    return minuteNumber == 0
        ? 'Every hour'
        : 'Every hour at :${_pad2(minuteNumber)}';
  }
  if (!RegExp(r'^\d+$').hasMatch(hour)) return null;
  final dayLabel = switch (dayOfWeek) {
    '*' => 'Daily',
    '1-5' => 'Weekdays',
    '0,6' || '6,0' => 'Weekends',
    '0' => 'Sundays',
    '1' => 'Mondays',
    '2' => 'Tuesdays',
    '3' => 'Wednesdays',
    '4' => 'Thursdays',
    '5' => 'Fridays',
    '6' => 'Saturdays',
    _ => null,
  };
  if (dayLabel == null) return null;
  final timezone = cadence.timezone ?? 'UTC';
  return '$dayLabel at ${_pad2(int.parse(hour))}:${_pad2(minuteNumber)} '
      '$timezone';
}

String _everyMsToCronExpression(int everyMs) {
  const minuteMs = 60000;
  const hourMs = 60 * minuteMs;
  const dayMs = 24 * hourMs;
  if (everyMs <= 0) return '0 * * * *';
  if (everyMs % dayMs == 0) {
    final days = everyMs ~/ dayMs;
    return days == 1 ? '0 9 * * *' : '0 9 */${days.clamp(1, 31)} * *';
  }
  if (everyMs % hourMs == 0) {
    final hours = everyMs ~/ hourMs;
    return hours == 1 ? '0 * * * *' : '0 */${hours.clamp(1, 23)} * * *';
  }
  final minutes = ((everyMs / minuteMs) + 0.5).floor().clamp(1, 59);
  return minutes == 1 ? '* * * * *' : '*/$minutes * * * *';
}

String _pad2(int value) => value < 10 ? '0$value' : '$value';

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
