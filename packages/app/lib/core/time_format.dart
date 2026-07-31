/// Port of Paseo 0.2.0's `utils/time.ts`.
///
/// Human-facing time formatting shared by the sidebar, message metadata, and
/// the stream's turn footer.
library;

import 'package:intl/intl.dart';

/// Formats [date] as a relative time string: "just now", "30s ago",
/// "5m ago", "2h ago", "3d ago", and an abbreviated "Jan 15" beyond a week.
String formatTimeAgo(DateTime date, [DateTime? now]) {
  final reference = now ?? DateTime.now();
  final diffMs = reference.difference(date).inMilliseconds;
  final diffSec = (diffMs / 1000).floor();
  final diffMin = (diffSec / 60).floor();
  final diffHour = (diffMin / 60).floor();
  final diffDay = (diffHour / 24).floor();

  if (diffSec < 10) return 'just now';
  if (diffMin < 1) return '${diffSec}s ago';
  if (diffHour < 1) return '${diffMin}m ago';
  if (diffDay < 1) return '${diffHour}h ago';
  if (diffDay < 7) return '${diffDay}d ago';

  // Older dates fall back to an abbreviated month and day. Upstream pins
  // this branch to en-US while the branches below follow the user's locale.
  return '${DateFormat.MMM('en_US').format(date)} ${date.day}';
}

bool _isSameLocalDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Formats a chat-message timestamp for hover-revealed UI:
/// - same day: `10:11 PM` (or `22:11`, per locale)
/// - within ~6 days: `Wednesday 10:11 PM`
/// - older: `14 May 2026, 10:11 PM`
String formatMessageTimestamp(DateTime date, [DateTime? now]) {
  final reference = now ?? DateTime.now();
  final time = DateFormat.jm().format(date);

  if (_isSameLocalDay(date, reference)) return time;

  final diffDays =
      (reference.difference(date).inMilliseconds / Duration.millisecondsPerDay)
          .floor();
  if (diffDays >= 0 && diffDays < 7) {
    return '${DateFormat.EEEE().format(date)} $time';
  }
  return '${DateFormat.yMMMd().format(date)}, $time';
}

/// Formats a duration compactly: whole seconds below a minute, then
/// integer-only minutes and hours ("2m 12s", "1h 5m").
String formatDuration(num durationMs) {
  if (durationMs is double && (durationMs.isNaN || durationMs.isInfinite)) {
    return '0s';
  }
  if (durationMs < 0) return '0s';
  final totalSeconds = durationMs / 1000;

  if (totalSeconds < 60) return '${totalSeconds.floor()}s';
  final totalMinutes = (totalSeconds / 60).floor();
  if (totalMinutes < 60) {
    final seconds = totalSeconds.floor() % 60;
    return seconds == 0 ? '${totalMinutes}m' : '${totalMinutes}m ${seconds}s';
  }
  final hours = (totalMinutes / 60).floor();
  final remMinutes = totalMinutes % 60;
  return remMinutes == 0 ? '${hours}h' : '${hours}h ${remMinutes}m';
}
