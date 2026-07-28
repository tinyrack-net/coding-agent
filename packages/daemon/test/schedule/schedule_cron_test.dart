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

  test('cron cadence honors IANA timezone and daylight-aware local parts', () {
    final next = computeNextRunAt(
      const CronScheduleCadence(
        expression: '0 9 * * *',
        timezone: 'Asia/Seoul',
      ),
      DateTime.utc(2026, 1, 1, 0, 1),
    );
    expect(next, DateTime.utc(2026, 1, 2, 0));
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
