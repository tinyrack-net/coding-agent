/// Port of Paseo 0.2.0's `agent-stream`-adjacent `timeline/turn-time.ts`.
///
/// Derives per-assistant-turn start/completion timing, and whether a turn is
/// currently running, purely from ordered stream items and the agent's live
/// status. Pure and side-effect free so it can be unit tested and reused by
/// both the turn footer (running elapsed / completed duration) and the
/// render model.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../state/timeline_provider.dart';

/// Timing for one completed assistant turn.
final class TurnTiming {
  const TurnTiming({
    required this.startedAt,
    required this.completedAt,
    required this.durationMs,
  });

  /// The timestamp of the user message that started this turn.
  final DateTime startedAt;

  /// The timestamp of the last item observed in this turn (the final
  /// assistant chunk, a trailing tool call, etc).
  final DateTime completedAt;

  /// `max(0, completedAt - startedAt)` in milliseconds.
  final int durationMs;

  @override
  bool operator ==(Object other) =>
      other is TurnTiming &&
      other.startedAt == startedAt &&
      other.completedAt == completedAt &&
      other.durationMs == durationMs;

  @override
  int get hashCode => Object.hash(startedAt, completedAt, durationMs);

  @override
  String toString() =>
      'TurnTiming(startedAt: $startedAt, completedAt: $completedAt, '
      'durationMs: $durationMs)';
}

/// Result of [deriveStreamTurnTiming].
final class StreamTurnTiming {
  const StreamTurnTiming({
    required this.byAssistantId,
    required this.runningStartedAt,
    required this.isActive,
  });

  /// Every assistant message id observed in a completed turn maps to that
  /// turn's [TurnTiming]. Multiple assistant chunks in the same turn (e.g.
  /// separated by tool calls) share one entry.
  final Map<String, TurnTiming> byAssistantId;

  /// When the currently-running turn's authoritative (non-optimistic) user
  /// message was sent, or `null` if no turn is running.
  final DateTime? runningStartedAt;

  /// `true` while a turn is running, or while an optimistic prompt is
  /// waiting on the host to start one. Mirrors Paseo's turn-footer "reserve
  /// space for an about-to-start running indicator" behavior.
  final bool isActive;
}

/// Walks [tail] then [head] (Paseo's tail/live-head split) and assigns
/// completed-turn timing to every assistant message id, plus the running
/// turn's start time when [agentStatus] is `"running"`.
///
/// Items with a `null` [TimelineDisplayItem.timestamp] are skipped: the
/// upstream TS type system guarantees every `StreamItem` carries a
/// timestamp, but Dart's [TimelineDisplayItem.timestamp] stays nullable for
/// items synthesized outside the timeline replica, so this defensively
/// treats "no timestamp" as "no timing signal" rather than throwing.
StreamTurnTiming deriveStreamTurnTiming({
  required String agentStatus,
  required List<TimelineDisplayItem> tail,
  required List<TimelineDisplayItem> head,
}) {
  final byAssistantId = <String, TurnTiming>{};
  DateTime? currentUserAt;
  DateTime? currentAuthoritativeUserAt;
  var currentUserIsOptimistic = false;
  DateTime? currentLastItemAt;
  var currentAssistantIds = <String>[];

  void flushCompletedTurn() {
    final userAt = currentUserAt;
    final lastItemAt = currentLastItemAt;
    if (userAt == null || lastItemAt == null || currentAssistantIds.isEmpty) {
      return;
    }
    final durationMs = lastItemAt.difference(userAt).inMilliseconds;
    final timing = TurnTiming(
      startedAt: userAt,
      completedAt: lastItemAt,
      durationMs: durationMs < 0 ? 0 : durationMs,
    );
    for (final id in currentAssistantIds) {
      byAssistantId[id] = timing;
    }
  }

  void visit(TimelineDisplayItem display) {
    final timestamp = display.timestamp;
    if (timestamp == null) return;
    if (display.item is UserMessageItem) {
      flushCompletedTurn();
      currentUserAt = timestamp;
      currentAuthoritativeUserAt = display.optimistic ? null : timestamp;
      currentUserIsOptimistic = display.optimistic;
      currentLastItemAt = null;
      currentAssistantIds = <String>[];
      return;
    }
    if (currentUserAt == null) return;
    currentLastItemAt = timestamp;
    if (display.item is AssistantMessageItem) {
      currentAssistantIds.add(display.item.id);
    }
  }

  for (final display in tail) {
    visit(display);
  }
  for (final display in head) {
    visit(display);
  }

  final isRunning = agentStatus == 'running';
  final runningStartedAt = isRunning ? currentAuthoritativeUserAt : null;
  if (!isRunning) flushCompletedTurn();

  return StreamTurnTiming(
    byAssistantId: byAssistantId,
    runningStartedAt: runningStartedAt,
    isActive: isRunning || currentUserIsOptimistic,
  );
}
