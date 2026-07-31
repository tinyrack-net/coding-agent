// Port of Paseo's `utils/time.test.ts`.
import 'package:coding_agent_app/core/time_format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Collapses the Unicode spaces ICU emits (narrow/regular no-break) to plain
/// spaces so assertions can be written with ordinary literals.
String _normalizeSpaces(String value) =>
    value.replaceAll(' ', ' ').replaceAll(' ', ' ');

void main() {
  setUpAll(initializeDateFormatting);

  group('formatTimeAgo', () {
    final now = DateTime.parse('2026-07-16T12:00:00.000Z');

    for (final (input, expected) in const [
      ('2026-07-16T11:59:55.000Z', 'just now'),
      ('2026-07-16T11:59:30.000Z', '30s ago'),
      ('2026-07-16T11:55:00.000Z', '5m ago'),
      ('2026-07-16T10:00:00.000Z', '2h ago'),
      ('2026-07-13T12:00:00.000Z', '3d ago'),
    ]) {
      test('formats $input as $expected', () {
        expect(formatTimeAgo(DateTime.parse(input), now), expected);
      });
    }

    test('formats older dates as an abbreviated month and day', () {
      // Compared in local time, so assert on the date's own local fields
      // rather than a fixed string.
      final date = DateTime.parse('2026-01-15T12:00:00.000Z');
      expect(formatTimeAgo(date, now), 'Jan ${date.toLocal().day}');
    });
  });

  group('formatDuration', () {
    test('renders sub-minute durations as whole seconds', () {
      expect(formatDuration(0), '0s');
      expect(formatDuration(5600), '5s');
      expect(formatDuration(9900), '9s');
      expect(formatDuration(10400), '10s');
      expect(formatDuration(12340), '12s');
      expect(formatDuration(47000), '47s');
    });

    test('renders minutes and remainder seconds without decimals', () {
      expect(formatDuration(75230), '1m 15s');
      expect(formatDuration(132000), '2m 12s');
      expect(formatDuration(120000), '2m');
    });

    test('renders hours and remainder minutes without decimals', () {
      expect(formatDuration(3900000), '1h 5m');
      expect(formatDuration(3600000), '1h');
    });

    test('guards against negative and NaN', () {
      expect(formatDuration(-1), '0s');
      expect(formatDuration(double.nan), '0s');
      expect(formatDuration(double.infinity), '0s');
    });
  });

  group('formatMessageTimestamp', () {
    test('shows only time for same-day timestamps', () {
      final now = DateTime(2026, 5, 14, 17, 30);
      final date = DateTime(2026, 5, 14, 12, 23);
      final formatted = formatMessageTimestamp(date, now);

      expect(formatted, contains('12:23'));
      expect(formatted, isNot(contains('Thursday')));
      expect(formatted, isNot(contains('Wednesday')));
    });

    test('includes weekday for timestamps within the last 6 days', () {
      // 2026-05-14 is a Thursday; 2026-05-11 is a Monday.
      final now = DateTime(2026, 5, 14, 17, 30);
      final date = DateTime(2026, 5, 11, 22, 12);
      final formatted = formatMessageTimestamp(date, now);

      expect(formatted, contains('Monday'));
      // ICU separates the time from the day period with a narrow no-break
      // space, so normalize before matching a plain-space expectation.
      expect(
        _normalizeSpaces(formatted),
        anyOf(contains('10:12 PM'), contains('22:12')),
      );
    });

    test('includes full date for older timestamps', () {
      final now = DateTime(2026, 5, 14, 17, 30);
      final date = DateTime(2026, 4, 1, 9, 5);
      final formatted = formatMessageTimestamp(date, now);

      expect(formatted, contains('Apr'));
      expect(formatted, contains('2026'));
    });
  });
}
