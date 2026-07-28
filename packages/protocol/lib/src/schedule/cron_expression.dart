/// Paseo-compatible five-field cron expression parsing.
library;

final class CronFieldMatcher {
  const CronFieldMatcher(this._allowed);

  final Set<int> _allowed;

  bool matches(int value) => _allowed.contains(value);
}

final class ParsedCronExpression {
  const ParsedCronExpression({
    required this.minute,
    required this.hour,
    required this.dayOfMonth,
    required this.month,
    required this.dayOfWeek,
  });

  final CronFieldMatcher minute;
  final CronFieldMatcher hour;
  final CronFieldMatcher dayOfMonth;
  final CronFieldMatcher month;
  final CronFieldMatcher dayOfWeek;
}

const _cronBounds = <({int min, int max, String name})>[
  (min: 0, max: 59, name: 'minute'),
  (min: 0, max: 23, name: 'hour'),
  (min: 1, max: 31, name: 'day-of-month'),
  (min: 1, max: 12, name: 'month'),
  (min: 0, max: 6, name: 'day-of-week'),
];

ParsedCronExpression parseCronExpression(String expression) {
  final parts = expression.trim().split(RegExp(r'\s+'));
  if (parts.length != 5) {
    throw const FormatException('Cron expressions must have 5 fields');
  }
  return ParsedCronExpression(
    minute: _parseField(parts[0], _cronBounds[0]),
    hour: _parseField(parts[1], _cronBounds[1]),
    dayOfMonth: _parseField(parts[2], _cronBounds[2]),
    month: _parseField(parts[3], _cronBounds[3]),
    dayOfWeek: _parseField(parts[4], _cronBounds[4]),
  );
}

String? validateCronExpression(String expression) {
  try {
    parseCronExpression(expression);
    return null;
  } on FormatException catch (error) {
    return error.message;
  } on Object {
    return 'Invalid cron expression';
  }
}

CronFieldMatcher _parseField(
  String source,
  ({int min, int max, String name}) bounds,
) {
  final trimmed = source.trim();
  if (trimmed.isEmpty) {
    throw FormatException('Invalid cron ${bounds.name} field');
  }
  final allowed = <int>{};
  for (final rawPart in trimmed.split(',')) {
    final part = rawPart.trim();
    if (part.isEmpty) {
      throw FormatException('Invalid cron ${bounds.name} field');
    }
    final stepParts = part.split('/');
    if (stepParts.length > 2) {
      throw FormatException('Invalid cron ${bounds.name} step');
    }
    final base = stepParts[0];
    final stepSource = stepParts.length == 2 ? stepParts[1].trim() : null;
    final step = stepSource == null ? 1 : int.tryParse(stepSource);
    if (step == null ||
        step <= 0 ||
        (stepSource != null && '$step' != stepSource)) {
      throw FormatException('Invalid cron ${bounds.name} step');
    }
    if (base == '*') {
      _addRange(allowed, bounds.min, bounds.max, step);
      continue;
    }
    final range = RegExp(r'^(\d+)-(\d+)$').firstMatch(base);
    if (range != null) {
      final start = int.parse(range.group(1)!);
      final end = int.parse(range.group(2)!);
      if (start > end || start < bounds.min || end > bounds.max) {
        throw FormatException('Invalid cron ${bounds.name} range');
      }
      _addRange(allowed, start, end, step);
      continue;
    }
    if (!RegExp(r'^\d+$').hasMatch(base)) {
      throw FormatException('Invalid cron ${bounds.name} value');
    }
    final value = int.parse(base);
    if (value < bounds.min || value > bounds.max) {
      throw FormatException('Invalid cron ${bounds.name} value');
    }
    allowed.add(value);
  }
  return CronFieldMatcher(Set.unmodifiable(allowed));
}

void _addRange(Set<int> target, int start, int end, int step) {
  for (var value = start; value <= end; value += step) {
    target.add(value);
  }
}
