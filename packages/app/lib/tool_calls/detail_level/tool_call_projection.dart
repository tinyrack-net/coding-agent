import 'package:agent_protocol/agent_protocol.dart';

import 'tool_call_grouping.dart';
import 'tool_call_overview.dart';

enum ToolCallDetailLevel { overview, detailed }

final class PreparedToolCallHistory {
  const PreparedToolCallHistory({required this.grouped});

  final GroupedToolCallHistory<ToolCallOverviewGroup> grouped;
}

typedef ToolCallDetailProjection = GroupedToolCalls<ToolCallOverviewGroup>;

PreparedToolCallHistory? prepareToolCallHistory(
  ToolCallDetailLevel level,
  List<TimelineItem> tail,
) {
  if (level == ToolCallDetailLevel.detailed) return null;
  return PreparedToolCallHistory(
    grouped: prepareGroupedToolCallHistory(
      tail: tail,
      buildGroup: buildToolCallOverviewGroup,
    ),
  );
}

ToolCallDetailProjection projectToolCallDetailLevel({
  required ToolCallDetailLevel level,
  required List<TimelineItem> tail,
  required List<TimelineItem> head,
  required PreparedToolCallHistory? preparedHistory,
  required bool isTurnActive,
}) {
  if (level == ToolCallDetailLevel.detailed) {
    return GroupedToolCalls(
      tail: tail,
      head: head,
      groupsByHostId: const {},
      historyGroupUpdatesByHostId: const {},
    );
  }
  if (preparedHistory == null) {
    throw StateError('Missing prepared overview tool call history');
  }
  return groupLiveToolCalls(
    history: preparedHistory.grouped,
    head: head,
    isTurnActive: isTurnActive,
    buildGroup: buildToolCallOverviewGroup,
  );
}
