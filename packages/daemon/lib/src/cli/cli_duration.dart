/// Parses the frozen Paseo CLI duration grammar into milliseconds.
///
/// A unitless value is interpreted as seconds. Unit-bearing values may
/// combine seconds, minutes, hours, and days without separators, such as
/// `2h30m`.
int parseCliDurationMilliseconds(String input) {
  final trimmed = input.trim();
  if (RegExp(r'^\d+$').hasMatch(trimmed)) {
    return int.parse(trimmed) * 1000;
  }
  if (!RegExp(r'^(?:\d+[smhd])+$').hasMatch(trimmed)) {
    throw FormatException(
      'Invalid duration format: $input. '
      'Use formats like: 5m, 30s, 1h, 2h30m, 1d',
    );
  }

  var totalMilliseconds = 0;
  for (final match in RegExp(r'(\d+)([smhd])').allMatches(trimmed)) {
    final value = int.parse(match.group(1)!);
    totalMilliseconds += switch (match.group(2)) {
      's' => value * 1000,
      'm' => value * 60 * 1000,
      'h' => value * 60 * 60 * 1000,
      'd' => value * 24 * 60 * 60 * 1000,
      _ => throw StateError('unreachable duration unit'),
    };
  }
  return totalMilliseconds;
}
