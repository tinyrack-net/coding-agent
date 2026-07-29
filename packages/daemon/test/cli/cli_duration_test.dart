import 'package:agent_daemon/src/cli/cli_duration.dart';
import 'package:test/test.dart';

void main() {
  test('parses the frozen unitless and compound duration grammar', () {
    expect(parseCliDurationMilliseconds('0'), 0);
    expect(parseCliDurationMilliseconds(' 90 '), 90000);
    expect(parseCliDurationMilliseconds('30s'), 30000);
    expect(parseCliDurationMilliseconds('5m'), 300000);
    expect(parseCliDurationMilliseconds('1h'), 3600000);
    expect(parseCliDurationMilliseconds('1d'), 86400000);
    expect(parseCliDurationMilliseconds('2h30m5s'), 9005000);
    expect(parseCliDurationMilliseconds('1d2h3m4s'), 93784000);
  });

  test('rejects every spelling outside the frozen grammar', () {
    for (final value in [
      '',
      ' ',
      '-1',
      '+1',
      '1.5',
      '1ms',
      '1M',
      '1m 2s',
      '1m,2s',
      'soon',
    ]) {
      expect(
        () => parseCliDurationMilliseconds(value),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'Invalid duration format: $value. '
                'Use formats like: 5m, 30s, 1h, 2h30m, 1d',
          ),
        ),
        reason: value,
      );
    }
  });
}
