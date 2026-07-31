/// Port of Paseo 0.2.0's `agent-stream/layout.ts`.
///
/// Turns the render model's ordered history and live-head segments into
/// per-row layout: each row's strategy-aware neighbors, the gap below it,
/// assistant block compaction, its position within a tool sequence or user
/// group, and which row (if any) hosts a completed-turn footer.
///
/// Footer placement is the subtle part. Exactly one footer exists per
/// completed assistant turn, and it renders after that turn's *last visible*
/// row rather than on the assistant row itself — so a turn ending in tool
/// rows hangs its footer off the trailing tool row. The newest turn's footer
/// instead lives in the auxiliary slot below the whole stream, and is
/// suppressed entirely while the agent is running. Because a turn can span
/// the history/live-head boundary, the search for a turn's latest assistant
/// row is allowed to cross that boundary exactly once.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../state/timeline_provider.dart';
import 'spacing.dart';
import 'stream_strategy.dart';
import 'turn_time.dart';

/// A row's position within a run of consecutive tool-sequence rows.
enum StreamToolSequence { none, single, first, middle, last }

/// The assistant turn a footer renders for, plus where to read its content
/// from ([items] and [startIndex] locate the assistant row inside whichever
/// segment it lives in).
final class TurnFooterHost {
  const TurnFooterHost({
    required this.itemId,
    required this.items,
    required this.startIndex,
    this.timing,
  });

  /// The id of the assistant row whose turn this footer summarizes.
  final String itemId;
  final List<TimelineDisplayItem> items;
  final int startIndex;
  final TurnTiming? timing;
}

final class StreamLayoutItem {
  const StreamLayoutItem({
    required this.item,
    required this.index,
    required this.items,
    required this.aboveItem,
    required this.belowItem,
    required this.gapBelow,
    required this.assistantSpacing,
    required this.completedFooter,
    required this.toolSequence,
    required this.isFirstInUserGroup,
    required this.isLastInUserGroup,
    required this.isLastInToolSequence,
    required this.frameOrder,
  });

  final TimelineDisplayItem item;
  final int index;
  final List<TimelineDisplayItem> items;

  /// The visually-preceding row, resolved through the strategy's traversal
  /// direction and across the history/live-head boundary.
  final TimelineDisplayItem? aboveItem;
  final TimelineDisplayItem? belowItem;
  final double gapBelow;
  final AssistantBlockSpacing assistantSpacing;
  final TurnFooterHost? completedFooter;
  final StreamToolSequence toolSequence;
  final bool isFirstInUserGroup;
  final bool isLastInUserGroup;
  final bool isLastInToolSequence;
  final StreamFrameChildOrder frameOrder;
}

final class StreamLayout {
  const StreamLayout({
    required this.history,
    required this.liveHead,
    required this.auxiliaryTurnFooter,
  });

  final List<StreamLayoutItem> history;
  final List<StreamLayoutItem> liveHead;

  /// The newest completed turn's footer, rendered below the whole stream
  /// rather than inline. Null while the agent is running.
  final TurnFooterHost? auxiliaryTurnFooter;
}

final class _AssistantFooterSource {
  const _AssistantFooterSource({
    required this.item,
    required this.items,
    required this.index,
  });

  final TimelineDisplayItem item;
  final List<TimelineDisplayItem> items;
  final int index;
}

TurnFooterHost _createTurnFooterHost({
  required TimelineDisplayItem item,
  required List<TimelineDisplayItem> items,
  required int index,
  required Map<String, TurnTiming> timingByAssistantId,
}) => TurnFooterHost(
  itemId: item.item.id,
  items: items,
  startIndex: index,
  timing: timingByAssistantId[item.item.id],
);

/// Walks "above" from [startIndex] looking for the turn's latest assistant
/// row, stopping at the user message that started the turn. When the walk
/// runs off the end of its segment it may continue into
/// [boundaryAboveItems] exactly once, so a turn spanning the
/// history/live-head boundary still resolves a single footer.
_AssistantFooterSource? _findLatestAssistantInTurn({
  required StreamStrategy strategy,
  required List<TimelineDisplayItem> items,
  required int startIndex,
  List<TimelineDisplayItem>? boundaryAboveItems,
  int? boundaryAboveIndex,
}) {
  var currentItems = items;
  var index = startIndex;
  var canCrossBoundary = true;

  while (true) {
    for (
      ;
      index >= 0 && index < currentItems.length;
      index = strategy.getNeighborIndex(index, NeighborRelation.above)
    ) {
      final display = currentItems[index];
      if (display.item is UserMessageItem) return null;
      if (display.item is AssistantMessageItem) {
        return _AssistantFooterSource(
          item: display,
          items: currentItems,
          index: index,
        );
      }
    }

    if (!canCrossBoundary ||
        boundaryAboveItems == null ||
        boundaryAboveIndex == null) {
      return null;
    }

    currentItems = boundaryAboveItems;
    index = boundaryAboveIndex;
    canCrossBoundary = false;
  }
}

TurnFooterHost? _resolveAuxiliaryTurnFooter({
  required StreamStrategy strategy,
  required String agentStatus,
  required List<TimelineDisplayItem> history,
  required List<TimelineDisplayItem> liveHead,
  required Map<String, TurnTiming> timingByAssistantId,
}) {
  if (agentStatus == 'running') return null;

  final footerItems = liveHead.isNotEmpty ? liveHead : history;
  final latestIndex = strategy.getLatestItemIndex(footerItems);
  if (latestIndex == null) return null;

  final assistant = _findLatestAssistantInTurn(
    strategy: strategy,
    items: footerItems,
    startIndex: latestIndex,
  );
  if (assistant == null) return null;

  return _createTurnFooterHost(
    item: assistant.item,
    items: assistant.items,
    index: assistant.index,
    timingByAssistantId: timingByAssistantId,
  );
}

/// A row hosts an inline completed footer only when it ends a turn — i.e. it
/// is not itself a user message but the row below it is. The turn already
/// owning the auxiliary footer never also gets an inline one.
TurnFooterHost? _resolveCompletedFooter({
  required StreamStrategy strategy,
  required List<TimelineDisplayItem> items,
  required int index,
  required TimelineDisplayItem item,
  required TimelineDisplayItem? belowItem,
  required Map<String, TurnTiming> timingByAssistantId,
  required TurnFooterHost? auxiliaryTurnFooter,
  required List<TimelineDisplayItem>? boundaryAboveItems,
  required int? boundaryAboveIndex,
}) {
  if (item.item is UserMessageItem || belowItem?.item is! UserMessageItem) {
    return null;
  }

  final assistant = _findLatestAssistantInTurn(
    strategy: strategy,
    items: items,
    startIndex: index,
    boundaryAboveItems: boundaryAboveItems,
    boundaryAboveIndex: boundaryAboveIndex,
  );
  if (assistant == null ||
      auxiliaryTurnFooter?.itemId == assistant.item.item.id) {
    return null;
  }
  return _createTurnFooterHost(
    item: assistant.item,
    items: assistant.items,
    index: assistant.index,
    timingByAssistantId: timingByAssistantId,
  );
}

bool _isToolSequenceItem(TimelineDisplayItem? display) =>
    display?.item is ToolCallItem ||
    display?.item is ReasoningItem ||
    display?.item is TodoItem;

StreamToolSequence _getToolSequence({
  required TimelineDisplayItem item,
  required TimelineDisplayItem? aboveItem,
  required TimelineDisplayItem? belowItem,
}) {
  if (!_isToolSequenceItem(item)) return StreamToolSequence.none;

  final hasAbove = _isToolSequenceItem(aboveItem);
  final hasBelow = _isToolSequenceItem(belowItem);
  if (hasAbove && hasBelow) return StreamToolSequence.middle;
  if (hasAbove) return StreamToolSequence.last;
  if (hasBelow) return StreamToolSequence.first;
  return StreamToolSequence.single;
}

/// Resolves a row's neighbor inside its own segment, falling back to the
/// item on the other side of the history/live-head boundary when the row
/// sits on that boundary.
TimelineDisplayItem? _getSegmentNeighbor({
  required StreamStrategy strategy,
  required List<TimelineDisplayItem> items,
  required int index,
  required NeighborRelation relation,
  required int? boundaryIndex,
  required TimelineDisplayItem? boundaryItem,
}) {
  final neighbor = strategy.getNeighborItem(items, index, relation);
  if (neighbor != null) return neighbor;
  if (index == boundaryIndex) return boundaryItem;
  return null;
}

List<StreamLayoutItem> _layoutSegment({
  required StreamStrategy strategy,
  required List<TimelineDisplayItem> items,
  required Map<String, TurnTiming> timingByAssistantId,
  required TurnFooterHost? auxiliaryTurnFooter,
  required StreamFrameChildOrder frameOrder,
  required int? boundaryIndex,
  required TimelineDisplayItem? boundaryAboveItem,
  required TimelineDisplayItem? boundaryBelowItem,
  required List<TimelineDisplayItem>? boundaryAboveItems,
  required int? boundaryAboveIndex,
}) => [
  for (var index = 0; index < items.length; index += 1)
    _layoutRow(
      strategy: strategy,
      items: items,
      index: index,
      timingByAssistantId: timingByAssistantId,
      auxiliaryTurnFooter: auxiliaryTurnFooter,
      frameOrder: frameOrder,
      boundaryIndex: boundaryIndex,
      boundaryAboveItem: boundaryAboveItem,
      boundaryBelowItem: boundaryBelowItem,
      boundaryAboveItems: boundaryAboveItems,
      boundaryAboveIndex: boundaryAboveIndex,
    ),
];

StreamLayoutItem _layoutRow({
  required StreamStrategy strategy,
  required List<TimelineDisplayItem> items,
  required int index,
  required Map<String, TurnTiming> timingByAssistantId,
  required TurnFooterHost? auxiliaryTurnFooter,
  required StreamFrameChildOrder frameOrder,
  required int? boundaryIndex,
  required TimelineDisplayItem? boundaryAboveItem,
  required TimelineDisplayItem? boundaryBelowItem,
  required List<TimelineDisplayItem>? boundaryAboveItems,
  required int? boundaryAboveIndex,
}) {
  final item = items[index];
  final aboveItem = _getSegmentNeighbor(
    strategy: strategy,
    items: items,
    index: index,
    relation: NeighborRelation.above,
    boundaryIndex: boundaryIndex,
    boundaryItem: boundaryAboveItem,
  );
  final belowItem = _getSegmentNeighbor(
    strategy: strategy,
    items: items,
    index: index,
    relation: NeighborRelation.below,
    boundaryIndex: boundaryIndex,
    boundaryItem: boundaryBelowItem,
  );
  final completedFooter = _resolveCompletedFooter(
    strategy: strategy,
    items: items,
    index: index,
    item: item,
    belowItem: belowItem,
    timingByAssistantId: timingByAssistantId,
    auxiliaryTurnFooter: auxiliaryTurnFooter,
    boundaryAboveItems: boundaryAboveItems,
    boundaryAboveIndex: boundaryAboveIndex,
  );

  return StreamLayoutItem(
    item: item,
    index: index,
    items: items,
    aboveItem: aboveItem,
    belowItem: belowItem,
    // A row hosting a footer owns the spacing below it instead.
    gapBelow: completedFooter != null
        ? 0
        : getGapBetweenStreamItems(item, belowItem),
    assistantSpacing: getAssistantBlockSpacing(
      item: item,
      aboveItem: aboveItem,
      belowItem: belowItem,
    ),
    completedFooter: completedFooter,
    toolSequence: _getToolSequence(
      item: item,
      aboveItem: aboveItem,
      belowItem: belowItem,
    ),
    isFirstInUserGroup:
        item.item is UserMessageItem && aboveItem?.item is! UserMessageItem,
    isLastInUserGroup:
        item.item is UserMessageItem && belowItem?.item is! UserMessageItem,
    isLastInToolSequence:
        _isToolSequenceItem(item) && !_isToolSequenceItem(belowItem),
    frameOrder: frameOrder,
  );
}

/// Keyed by history list identity; the inner key encodes every input that
/// can change history layout. History layout is stable across text-chunk
/// flushes because the live-head boundary row's id and kind don't change
/// when only its text grows.
final _historyLayoutCache = Expando<Map<String, List<StreamLayoutItem>>>(
  'historyLayout',
);

StreamLayout layoutStream({
  required StreamStrategy strategy,
  required String agentStatus,
  required List<TimelineDisplayItem> history,
  required List<TimelineDisplayItem> liveHead,
  required Map<String, TurnTiming> timingByAssistantId,
}) {
  final auxiliaryTurnFooter = _resolveAuxiliaryTurnFooter(
    strategy: strategy,
    agentStatus: agentStatus,
    history: history,
    liveHead: liveHead,
    timingByAssistantId: timingByAssistantId,
  );
  final historyBoundaryIndex = strategy.getHistoryLiveBoundaryIndex(history);
  final liveHeadBoundaryIndex = strategy.getLiveHeadHistoryBoundaryIndex(
    liveHead,
  );
  final historyBoundaryItem = historyBoundaryIndex == null
      ? null
      : history[historyBoundaryIndex];
  final liveHeadBoundaryItem = liveHeadBoundaryIndex == null
      ? null
      : liveHead[liveHeadBoundaryIndex];
  final frameOrder = strategy.frameChildOrder;

  List<StreamLayoutItem> historyLayout;
  if (history.isNotEmpty) {
    final historyCacheKey = [
      frameOrder.name,
      historyBoundaryIndex?.toString() ?? 'null',
      liveHeadBoundaryItem?.item.id ?? 'null',
      liveHeadBoundaryItem?.item.kind ?? 'null',
      auxiliaryTurnFooter?.itemId ?? 'null',
    ].join(':');
    final byKey = _historyLayoutCache[history] ??=
        <String, List<StreamLayoutItem>>{};
    historyLayout = byKey[historyCacheKey] ??= _layoutSegment(
      strategy: strategy,
      items: history,
      timingByAssistantId: timingByAssistantId,
      auxiliaryTurnFooter: auxiliaryTurnFooter,
      frameOrder: frameOrder,
      boundaryIndex: historyBoundaryIndex,
      boundaryAboveItem: null,
      boundaryBelowItem: liveHeadBoundaryItem,
      boundaryAboveItems: null,
      boundaryAboveIndex: null,
    );
  } else {
    historyLayout = const [];
  }

  final liveHeadLayout = _layoutSegment(
    strategy: strategy,
    items: liveHead,
    timingByAssistantId: timingByAssistantId,
    auxiliaryTurnFooter: auxiliaryTurnFooter,
    frameOrder: frameOrder,
    boundaryIndex: liveHeadBoundaryIndex,
    boundaryAboveItem: historyBoundaryItem,
    boundaryBelowItem: null,
    boundaryAboveItems: history,
    boundaryAboveIndex: historyBoundaryIndex,
  );

  return StreamLayout(
    history: historyLayout,
    liveHead: liveHeadLayout,
    auxiliaryTurnFooter: auxiliaryTurnFooter,
  );
}
