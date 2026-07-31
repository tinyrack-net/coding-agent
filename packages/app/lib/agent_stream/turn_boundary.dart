/// Port of Paseo 0.2.0's `agent-stream/turn-boundary.ts`.
///
/// Resolves where a "fork this assistant turn" action should branch from.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../state/timeline_provider.dart';

/// Where a fork branches from. Upstream models this as a union that always
/// carries at least one of the two identifiers, so the constructors here
/// enforce the same invariant: [AssistantTurnForkBoundary.fromCursor]
/// always has a cursor (optionally plus a message id), and
/// [AssistantTurnForkBoundary.fromMessageId] always has a message id.
final class AssistantTurnForkBoundary {
  const AssistantTurnForkBoundary.fromCursor(
    StreamTimelinePosition this.boundaryCursor, {
    this.boundaryMessageId,
  });

  const AssistantTurnForkBoundary.fromMessageId(String this.boundaryMessageId)
    : boundaryCursor = null;

  final StreamTimelinePosition? boundaryCursor;
  final String? boundaryMessageId;

  @override
  bool operator ==(Object other) =>
      other is AssistantTurnForkBoundary &&
      other.boundaryCursor == boundaryCursor &&
      other.boundaryMessageId == boundaryMessageId;

  @override
  int get hashCode => Object.hash(boundaryCursor, boundaryMessageId);

  @override
  String toString() =>
      'AssistantTurnForkBoundary(boundaryCursor: $boundaryCursor, '
      'boundaryMessageId: $boundaryMessageId)';
}

/// Returns the fork boundary for the assistant row at [startIndex], or
/// `null` when that row cannot anchor a fork.
///
/// A host that supports timeline cursors forks from the row's own cursor
/// (carrying the provider message id along when there is one); otherwise the
/// provider message id is the only usable boundary. Notably the message id
/// is never borrowed from a neighboring assistant row in the same turn — a
/// row without its own identifier simply cannot be forked from.
AssistantTurnForkBoundary? resolveAssistantTurnForkBoundary({
  required List<TimelineDisplayItem> items,
  required int startIndex,
  required bool supportsTimelineCursor,
}) {
  if (startIndex < 0 || startIndex >= items.length) return null;
  final display = items[startIndex];
  if (display.item is! AssistantMessageItem) return null;

  final cursor = display.timelineCursor;
  if (supportsTimelineCursor && cursor != null) {
    return AssistantTurnForkBoundary.fromCursor(
      cursor,
      boundaryMessageId: display.messageId,
    );
  }
  final messageId = display.messageId;
  return messageId == null
      ? null
      : AssistantTurnForkBoundary.fromMessageId(messageId);
}
