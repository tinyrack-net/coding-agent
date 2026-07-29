import 'package:agent_protocol/agent_protocol.dart';

const customCronPresetId = 'custom';

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
