import 'package:agent_protocol/agent_protocol.dart';

import 'schedule_form_model.dart';

String scheduleProductName(ScheduleSummary schedule) =>
    schedule.target is NewAgentScheduleTarget ? 'Schedule' : 'Heartbeat';

String resolveScheduleTitle(ScheduleSummary schedule) {
  final name = schedule.name?.trim();
  if (name != null && name.isNotEmpty) return name;

  final target = schedule.target;
  if (target is NewAgentScheduleTarget) {
    final configTitle = target.config.title?.trim();
    if (configTitle != null && configTitle.isNotEmpty) return configTitle;
  }

  for (final line in schedule.prompt.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return 'Untitled ${scheduleProductName(schedule).toLowerCase()}';
}

String formatScheduleCadence(ScheduleCadence cadence) => switch (cadence) {
  EveryScheduleCadence(everyMs: final everyMs) => _formatEvery(everyMs),
  CronScheduleCadence() => describeScheduleCron(cadence) ?? cadence.expression,
};

String formatScheduleTimeAgo(String value, {DateTime? now}) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final reference = now ?? DateTime.now();
  final milliseconds = reference.difference(parsed).inMilliseconds;
  final seconds = (milliseconds / Duration.millisecondsPerSecond).floor();
  final minutes = (seconds / Duration.secondsPerMinute).floor();
  final hours = (minutes / Duration.minutesPerHour).floor();
  final days = (hours / Duration.hoursPerDay).floor();

  if (seconds < 10) return 'just now';
  if (minutes < 1) return '${seconds}s ago';
  if (hours < 1) return '${minutes}m ago';
  if (days < 1) return '${hours}h ago';
  if (days < 7) return '${days}d ago';

  final local = parsed.toLocal();
  return '${_months[local.month - 1]} ${local.day}';
}

String formatScheduleNextRun(String? value, {DateTime? now}) {
  if (value == null) return '';
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return '';
  final milliseconds = parsed.difference(now ?? DateTime.now()).inMilliseconds;
  if (milliseconds <= 0 || milliseconds < Duration.millisecondsPerMinute) {
    return 'soon';
  }
  if (milliseconds < Duration.millisecondsPerHour) {
    return 'in ${(milliseconds / Duration.millisecondsPerMinute).round()}m';
  }
  if (milliseconds < Duration.millisecondsPerDay) {
    return 'in ${(milliseconds / Duration.millisecondsPerHour).round()}h';
  }
  return 'in ${(milliseconds / Duration.millisecondsPerDay).round()}d';
}

String buildScheduleRowMeta(
  ScheduleSummary schedule, {
  required bool active,
  required String? serverName,
  required bool singleHost,
  DateTime? now,
}) {
  final reference = now ?? DateTime.now();
  final parts = <String>[
    formatScheduleCadence(schedule.cadence),
    'Created ${formatScheduleTimeAgo(schedule.createdAt, now: reference)}',
    schedule.lastRunAt == null
        ? 'Never run'
        : 'Last run ${formatScheduleTimeAgo(schedule.lastRunAt!, now: reference)}',
  ];
  if (active) {
    final next = formatScheduleNextRun(schedule.nextRunAt, now: reference);
    if (next.isNotEmpty) parts.add('Next run $next');
  }
  if (serverName?.isNotEmpty == true && !singleHost) {
    parts.insert(0, serverName!);
  }
  return parts.join(' · ');
}

String _formatEvery(int everyMs) {
  final (:value, :unit) = _everyMsToParts(everyMs);
  final noun = switch (unit) {
    _IntervalUnit.minutes => 'minute',
    _IntervalUnit.hours => 'hour',
    _IntervalUnit.days => 'day',
  };
  return 'Every $value $noun${value == 1 ? '' : 's'}';
}

({int value, _IntervalUnit unit}) _everyMsToParts(int milliseconds) {
  if (milliseconds <= 0) return (value: 1, unit: _IntervalUnit.hours);
  if (milliseconds % Duration.millisecondsPerDay == 0) {
    return (
      value: milliseconds ~/ Duration.millisecondsPerDay,
      unit: _IntervalUnit.days,
    );
  }
  if (milliseconds % Duration.millisecondsPerHour == 0) {
    return (
      value: milliseconds ~/ Duration.millisecondsPerHour,
      unit: _IntervalUnit.hours,
    );
  }
  return (
    value: switch ((milliseconds / Duration.millisecondsPerMinute).round()) {
      final value when value > 0 => value,
      _ => 1,
    },
    unit: _IntervalUnit.minutes,
  );
}

enum _IntervalUnit { minutes, hours, days }

const _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
