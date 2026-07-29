import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/state/schedule_form_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cadence presets match frozen Paseo options', () {
    expect(
      scheduleCadencePresets.map(
        (preset) => (preset.id, preset.label, preset.expression),
      ),
      const [
        ('every-minute', 'Every minute', '* * * * *'),
        ('every-hour', 'Every hour', '0 * * * *'),
        ('daily-9', 'Daily 9:00', '0 9 * * *'),
        ('weekdays-9', 'Weekdays 9:00', '0 9 * * 1-5'),
        ('mondays-9', 'Mondays 9:00', '0 9 * * 1'),
      ],
    );
    expect(
      resolveCronPresetId(
        const CronScheduleCadence(expression: ' 0 9 * * 1-5 '),
      ),
      'weekdays-9',
    );
    expect(
      resolveCronPresetLabel(
        const CronScheduleCadence(expression: '30 8 * * 1-5'),
      ),
      'Custom cron',
    );
  });

  test('rolling intervals normalize to frozen cron cadence semantics', () {
    CronScheduleCadence normalize(int everyMs) => normalizeScheduleFormCadence(
      EveryScheduleCadence(everyMs: everyMs),
      'Asia/Seoul',
    );

    expect(normalize(60000).expression, '* * * * *');
    expect(normalize(5 * 60000).expression, '*/5 * * * *');
    expect(normalize(3600000).expression, '0 * * * *');
    expect(normalize(3 * 3600000).expression, '0 */3 * * *');
    expect(normalize(24 * 3600000).expression, '0 9 * * *');
    expect(normalize(2 * 24 * 3600000).expression, '0 9 */2 * *');
    expect(normalize(61000).expression, '* * * * *');
    expect(normalize(60000).timezone, 'Asia/Seoul');
    expect(
      normalizeScheduleFormCadence(
        const CronScheduleCadence(expression: '0 9 * * *'),
        'Asia/Seoul',
      ).timezone,
      'Asia/Seoul',
    );
  });

  test('cron validation and preview use frozen reader-facing copy', () {
    expect(validateScheduleCron(''), 'Enter a cron expression');
    expect(validateScheduleCron('61 * * * *'), 'Invalid minute value');
    expect(validateScheduleCron('0 9 * * 1-5'), isNull);

    expect(
      describeScheduleCron(
        const CronScheduleCadence(
          expression: '* * * * *',
          timezone: 'Asia/Seoul',
        ),
      ),
      'Every minute',
    );
    expect(
      describeScheduleCron(
        const CronScheduleCadence(
          expression: '30 8 * * 1-5',
          timezone: 'Asia/Seoul',
        ),
      ),
      'Weekdays at 08:30 Asia/Seoul',
    );
    expect(
      describeScheduleCron(
        const CronScheduleCadence(expression: '*/5 * * * *'),
      ),
      isNull,
    );
  });
}
