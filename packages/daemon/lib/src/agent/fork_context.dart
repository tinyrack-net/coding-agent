/// Port of the fork-context half of Paseo 0.2.0's
/// `server/agent/activity-curator.ts`.
///
/// Forking a conversation seeds the new agent with everything up to the
/// chosen boundary, rendered as one curated text attachment rather than a
/// replayed timeline. The boundary is either an exact timeline cursor or,
/// when the host cannot supply one, the provider's assistant message id.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../server/agent_mcp_tools.dart';
import 'timeline_projection.dart';
import 'timeline_store.dart';

/// A fork boundary expressed as a timeline cursor, validated against the
/// epoch the caller observed so a rebuilt timeline cannot be forked blindly.
final class ForkCursorBoundary {
  const ForkCursorBoundary({
    required this.epoch,
    required this.seq,
    required this.timelineEpoch,
  });

  /// The epoch the cursor was taken in.
  final String epoch;
  final int seq;

  /// The timeline's current epoch.
  final String timelineEpoch;
}

final class AgentForkContext {
  const AgentForkContext({
    required this.attachment,
    required this.itemCount,
    required this.boundaryCursor,
    required this.boundaryMessageId,
  });

  final TextAgentAttachment attachment;
  final int itemCount;
  final ({String epoch, int seq})? boundaryCursor;
  final String? boundaryMessageId;
}

/// Raised when the requested boundary no longer exists in the timeline.
final class ForkBoundaryUnavailable implements Exception {
  const ForkBoundaryUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

String? _trimMetadata(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

/// Selects the rows a fork should carry, up to and including the boundary.
/// With no boundary the whole timeline is carried.
List<TimelineItem> _selectForkContextRows({
  required List<TimelineRow> rows,
  ForkCursorBoundary? cursorBoundary,
  String? boundaryMessageId,
}) {
  final messageId = _trimMetadata(boundaryMessageId);
  if (cursorBoundary == null && messageId == null) {
    return [
      for (final entry in projectTimelineRows(rows, projected: true))
        entry.item,
    ];
  }

  if (cursorBoundary != null &&
      cursorBoundary.epoch != cursorBoundary.timelineEpoch) {
    throw const ForkBoundaryUnavailable(
      'Selected timeline position is no longer available.',
    );
  }

  final boundaryIndex = cursorBoundary != null
      ? rows.indexWhere((row) => row.seq == cursorBoundary.seq)
      : rows.lastIndexWhere(
          (row) => row.item is AssistantMessageItem && row.item.id == messageId,
        );
  if (boundaryIndex < 0) {
    throw ForkBoundaryUnavailable(
      cursorBoundary != null
          ? 'Selected timeline position is no longer available.'
          : 'Selected assistant message is no longer available.',
    );
  }

  return [
    for (final entry in projectTimelineRows(
      rows.sublist(0, boundaryIndex + 1),
      projected: true,
    ))
      entry.item,
  ];
}

/// Builds the `<chat-history-summary>` attachment a forked agent is seeded
/// with.
AgentForkContext buildAgentForkContextAttachment({
  required List<TimelineRow> rows,
  ForkCursorBoundary? cursorBoundary,
  String? boundaryMessageId,
  String? agentTitle,
  String? cwd,
}) {
  final items = _selectForkContextRows(
    rows: rows,
    cursorBoundary: cursorBoundary,
    boundaryMessageId: boundaryMessageId,
  );
  final body = curateAgentActivity(
    items,
    cwd: cwd,
    labelAssistantMessages: true,
    includeKinds: const {'user_message', 'assistant_message', 'tool_call'},
    includeExternalToolInput: false,
  );
  final resolvedBody = items.isEmpty || body == 'No activity to display.'
      ? 'No chat history to display.'
      : body;

  final header = <String>[];
  final title = _trimMetadata(agentTitle);
  final directory = _trimMetadata(cwd);
  if (title != null) header.add('Source agent: $title');
  if (directory != null) header.add('Source directory: $directory');

  return AgentForkContext(
    attachment: TextAgentAttachment(
      title: 'Chat history',
      text:
          '<chat-history-summary>\n${header.join('\n')}\n\n'
          '$resolvedBody\n</chat-history-summary>',
    ),
    itemCount: items.length,
    boundaryCursor: cursorBoundary == null
        ? null
        : (epoch: cursorBoundary.epoch, seq: cursorBoundary.seq),
    boundaryMessageId: _trimMetadata(boundaryMessageId),
  );
}
