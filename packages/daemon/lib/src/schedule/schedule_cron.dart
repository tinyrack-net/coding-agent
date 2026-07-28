import 'package:agent_protocol/agent_protocol.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;

var _timeZonesInitialized = false;

void _ensureTimeZones() {
  if (_timeZonesInitialized) return;
  timezone_data.initializeTimeZones();
  _timeZonesInitialized = true;
}

void validateScheduleCadence(ScheduleCadence cadence) {
  if (cadence case CronScheduleCadence(
    expression: final expression,
    timezone: final timeZone?,
  )) {
    parseCronExpression(expression);
    _location(timeZone);
  } else if (cadence case CronScheduleCadence(expression: final expression)) {
    parseCronExpression(expression);
  }
}

DateTime computeNextRunAt(ScheduleCadence cadence, DateTime after) {
  final utcAfter = after.toUtc();
  if (cadence case EveryScheduleCadence(everyMs: final everyMs)) {
    return utcAfter.add(Duration(milliseconds: everyMs));
  }
  final cron = cadence as CronScheduleCadence;
  final parsed = parseCronExpression(cron.expression);
  final location = cron.timezone == null ? null : _location(cron.timezone!);
  var cursor = DateTime.utc(
    utcAfter.year,
    utcAfter.month,
    utcAfter.day,
    utcAfter.hour,
    utcAfter.minute + 1,
  );
  const limit = 366 * 24 * 60;
  for (var index = 0; index < limit; index++) {
    final local = location == null
        ? cursor
        : timezone.TZDateTime.from(cursor, location);
    if (parsed.minute.matches(local.minute) &&
        parsed.hour.matches(local.hour) &&
        parsed.dayOfMonth.matches(local.day) &&
        parsed.month.matches(local.month) &&
        parsed.dayOfWeek.matches(local.weekday % 7)) {
      return cursor;
    }
    cursor = cursor.add(const Duration(minutes: 1));
  }
  throw StateError(
    'Unable to compute next run time for cron expression: ${cron.expression}',
  );
}

timezone.Location _location(String name) {
  _ensureTimeZones();
  try {
    return timezone.getLocation(name);
  } on Object {
    throw FormatException('Invalid cron time zone: $name');
  }
}
