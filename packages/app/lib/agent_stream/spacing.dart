/// Port of Paseo 0.2.0's `agent-stream/spacing.ts`.
///
/// Decides the vertical gap between two adjacent stream rows and how tightly
/// an assistant row hugs its same-block-group neighbors.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../core/theme.dart';
import '../state/timeline_provider.dart';

/// How much of an assistant row's own vertical padding is collapsed because
/// the row above and/or below belongs to the same assistant block group.
enum AssistantBlockSpacing { normal, compactTop, compactBottom, compactBoth }

/// True when both rows are assistant messages carrying the same non-null
/// [TimelineDisplayItem.blockGroupId].
bool isSameAssistantBlockGroup({
  TimelineDisplayItem? item,
  TimelineDisplayItem? other,
}) =>
    item?.item is AssistantMessageItem &&
    other?.item is AssistantMessageItem &&
    item?.blockGroupId != null &&
    item?.blockGroupId == other?.blockGroupId;

AssistantBlockSpacing getAssistantBlockSpacing({
  required TimelineDisplayItem item,
  TimelineDisplayItem? aboveItem,
  TimelineDisplayItem? belowItem,
}) {
  if (item.item is! AssistantMessageItem) return AssistantBlockSpacing.normal;
  final compactTop = isSameAssistantBlockGroup(item: item, other: aboveItem);
  final compactBottom = isSameAssistantBlockGroup(item: item, other: belowItem);
  if (compactTop && compactBottom) return AssistantBlockSpacing.compactBoth;
  if (compactTop) return AssistantBlockSpacing.compactTop;
  if (compactBottom) return AssistantBlockSpacing.compactBottom;
  return AssistantBlockSpacing.normal;
}

bool _isUserMessageItem(TimelineDisplayItem? item) =>
    item?.item is UserMessageItem;

/// Rows that render as part of a run-together tool sequence. Upstream's
/// `thought` and `todo_list` map onto [ReasoningItem] and [TodoItem].
bool _isToolSequenceItem(TimelineDisplayItem? item) =>
    item?.item is ToolCallItem ||
    item?.item is ReasoningItem ||
    item?.item is TodoItem;

/// The gap rendered below [item], given the row that follows it.
double getGapBetweenStreamItems(
  TimelineDisplayItem? item,
  TimelineDisplayItem? belowItem,
) {
  if (item == null || belowItem == null) return PaseoSpacing.s0;

  if (_isUserMessageItem(item) && _isUserMessageItem(belowItem)) {
    return PaseoSpacing.s1;
  }
  if (_isToolSequenceItem(item) && _isToolSequenceItem(belowItem)) {
    return PaseoSpacing.s0;
  }
  if (item.item is UserMessageItem && _isToolSequenceItem(belowItem)) {
    return PaseoSpacing.s4;
  }
  if (item.item is AssistantMessageItem && _isToolSequenceItem(belowItem)) {
    return PaseoSpacing.s1;
  }
  if (_isToolSequenceItem(item) && belowItem.item is AssistantMessageItem) {
    return PaseoSpacing.s1;
  }
  if (isSameAssistantBlockGroup(item: item, other: belowItem)) {
    return PaseoSpacing.s3;
  }
  return PaseoSpacing.s4;
}
