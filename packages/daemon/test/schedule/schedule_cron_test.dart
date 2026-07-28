import 'package:agent_daemon/src/schedule/schedule_cron.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('every cadence advances by the exact rolling interval', () {
    final next = computeNextRunAt(
      const EveryScheduleCadence(everyMs: 90000),
      DateTime.utc(2026, 1, 1, 0, 0),
    );
    expect(next, DateTime.utc(2026, 1, 1, 0, 1, 30));
  });

  test('cron cadence starts at the next minute and uses UTC by default', () {
    final next = computeNextRunAt(
      const CronScheduleCadence(expression: '*/15 * * * *'),
      DateTime.utc(2026, 1, 1, 12, 7, 45),
    );
    expect(next, DateTime.utc(2026, 1, 1, 12, 15));
  });

  test('cron cadence matches the requested weekday minute in UTC', () {
    final next = computeNextRunAt(
      const CronScheduleCadence(expression: '15 9 * * 1-5'),
      DateTime.parse('2026-01-05T09:14:30.000Z'),
    );

    expect(next, DateTime.parse('2026-01-05T09:15:00.000Z'));
  });

  test('timezone cadence follows winter and summer wall-clock offsets', () {
    final winter = computeNextRunAt(
      const CronScheduleCadence(
        expression: '0 9 * * 1-5',
        timezone: 'America/New_York',
      ),
      DateTime.parse('2026-01-05T13:59:30.000Z'),
    );
    final summer = computeNextRunAt(
      const CronScheduleCadence(
        expression: '0 9 * * 1-5',
        timezone: 'America/New_York',
      ),
      DateTime.parse('2026-07-06T12:59:30.000Z'),
    );

    expect(winter, DateTime.parse('2026-01-05T14:00:00.000Z'));
    expect(summer, DateTime.parse('2026-07-06T13:00:00.000Z'));
  });

  test('fall-back wall-clock matches remain distinct UTC instants', () {
    const cadence = CronScheduleCadence(
      expression: '30 1 1 11 *',
      timezone: 'America/New_York',
    );
    final first = computeNextRunAt(
      cadence,
      DateTime.parse('2026-11-01T05:29:30.000Z'),
    );
    final second = computeNextRunAt(cadence, first);

    expect(first, DateTime.parse('2026-11-01T05:30:00.000Z'));
    expect(second, DateTime.parse('2026-11-01T06:30:00.000Z'));
  });

  test('validation preserves frozen parser and timezone errors', () {
    expect(
      () => validateScheduleCadence(
        const CronScheduleCadence(expression: 'not-a-valid-cron'),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'Cron expressions must have 5 fields',
        ),
      ),
    );
    expect(
      () => validateScheduleCadence(
        const CronScheduleCadence(expression: '*/5/2 * * * *'),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'Invalid cron minute step',
        ),
      ),
    );
    expect(
      () => validateScheduleCadence(
        const CronScheduleCadence(
          expression: '0 9 * * *',
          timezone: 'Not/AZone',
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'Invalid cron time zone: Not/AZone',
        ),
      ),
    );
  });

  test('invalid timezone and impossible annual search fail visibly', () {
    expect(
      () => validateScheduleCadence(
        const CronScheduleCadence(
          expression: '* * * * *',
          timezone: 'Mars/Olympus',
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => computeNextRunAt(
        const CronScheduleCadence(expression: '0 0 31 2 *'),
        DateTime.utc(2026),
      ),
      throwsStateError,
    );
  });
}
