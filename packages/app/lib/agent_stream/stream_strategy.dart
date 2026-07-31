/// Port of Paseo 0.2.0's `agent-stream/strategy.ts`,
/// `agent-stream/strategy-native.tsx`, `agent-stream/strategy-web.tsx`, and
/// `agent-stream/strategy-resolver.ts`.
///
/// Upstream bundles a per-platform *render strategy*: a config object whose
/// pure fields (ordering, traversal direction, near-bottom math, edge slot,
/// bottom-anchor transport behavior, ...) drive `model.ts`/`layout.ts`/
/// `bottom-anchor-controller.ts`, plus a `render` closure that returns a
/// React-Native `FlatList` wired with those fields (`ListHeaderComponent`/
/// `ListFooterComponent`, `maintainVisibleContentPosition`, list inversion,
/// ...). Flutter has no equivalent to that render-prop plumbing, so this
/// module ports only the platform-config *values* — everything the render
/// pipeline actually branches on — as plain immutable data, verified against
/// the same cases as upstream's `render-strategy.test.ts`. The Flutter
/// viewport widget (a later parity slice) consumes [StreamStrategy] the way
/// upstream's `WebStreamViewport`/native `FlatList` wiring consumes
/// `StreamStrategy` today.
library;

import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart';

import '../state/timeline_provider.dart';

enum NeighborRelation { above, below }

enum StreamEdgeSlot { header, footer }

enum StreamBoundaryEdge { first, last }

enum StreamFrameChildOrder { contentThenFooter, footerThenContent }

enum BottomAnchorVerificationRetryMode { rescroll, recheck }

final class BottomAnchorTransportBehavior {
  const BottomAnchorTransportBehavior({
    required this.verificationDelayFrames,
    required this.verificationRetryMode,
  });

  final int verificationDelayFrames;
  final BottomAnchorVerificationRetryMode verificationRetryMode;

  @override
  bool operator ==(Object other) =>
      other is BottomAnchorTransportBehavior &&
      other.verificationDelayFrames == verificationDelayFrames &&
      other.verificationRetryMode == verificationRetryMode;

  @override
  int get hashCode =>
      Object.hash(verificationDelayFrames, verificationRetryMode);

  @override
  String toString() =>
      'BottomAnchorTransportBehavior(verificationDelayFrames: '
      '$verificationDelayFrames, verificationRetryMode: '
      '$verificationRetryMode)';
}

/// Mirrors RN FlatList's `maintainVisibleContentPosition` prop shape. Kept
/// as inert config data — Flutter's `ListView` has no equivalent — solely so
/// the frozen per-platform config surface stays fully represented.
final class MaintainVisibleContentPositionConfig {
  const MaintainVisibleContentPositionConfig({
    required this.minIndexForVisible,
    required this.autoscrollToTopThreshold,
  });

  final int minIndexForVisible;
  final int autoscrollToTopThreshold;
}

const _nativeSettlingVerificationDelayFrames = 4;

/// Immutable per-platform render strategy config. See the library doc for
/// why this ports upstream's `StreamStrategyConfig` fields but not its
/// React-Native render wiring.
final class StreamStrategy {
  const StreamStrategy._({
    required this.orderTailReverse,
    required this.orderHeadReverse,
    required this.assistantTurnTraversalStep,
    required this.edgeSlot,
    required this.historyLiveBoundaryEdge,
    required this.liveHeadHistoryBoundaryEdge,
    required this.frameChildOrder,
    required this.flatListInverted,
    required this.overlayScrollbarInverted,
    required this.maintainVisibleContentPosition,
    required this.bottomAnchorTransportBehavior,
    required this.disableParentScrollOnInlineDetailsExpansion,
    required this.anchorBottomOnContentSizeChange,
    required this.animateManualScrollToBottom,
    required this.useVirtualizedList,
    required this.isWeb,
  });

  final bool orderTailReverse;
  final bool orderHeadReverse;

  /// `-1` walks toward the start of the (already-ordered) list; `1` walks
  /// toward the end. Paired with [collectAssistantTurnContent]'s traversal.
  final int assistantTurnTraversalStep;
  final StreamEdgeSlot edgeSlot;
  final StreamBoundaryEdge historyLiveBoundaryEdge;
  final StreamBoundaryEdge liveHeadHistoryBoundaryEdge;
  final StreamFrameChildOrder frameChildOrder;
  final bool flatListInverted;
  final bool overlayScrollbarInverted;
  final MaintainVisibleContentPositionConfig? maintainVisibleContentPosition;
  final BottomAnchorTransportBehavior bottomAnchorTransportBehavior;
  final bool disableParentScrollOnInlineDetailsExpansion;
  final bool anchorBottomOnContentSizeChange;
  final bool animateManualScrollToBottom;
  final bool useVirtualizedList;

  /// True for the web strategy, false for native; branches
  /// [isNearBottom]/[getBottomOffset]'s per-platform math.
  final bool isWeb;

  static final web = StreamStrategy._(
    orderTailReverse: false,
    orderHeadReverse: false,
    assistantTurnTraversalStep: -1,
    edgeSlot: StreamEdgeSlot.footer,
    historyLiveBoundaryEdge: StreamBoundaryEdge.last,
    liveHeadHistoryBoundaryEdge: StreamBoundaryEdge.first,
    frameChildOrder: StreamFrameChildOrder.contentThenFooter,
    flatListInverted: false,
    overlayScrollbarInverted: false,
    maintainVisibleContentPosition: null,
    bottomAnchorTransportBehavior: const BottomAnchorTransportBehavior(
      verificationDelayFrames: 0,
      verificationRetryMode: BottomAnchorVerificationRetryMode.rescroll,
    ),
    disableParentScrollOnInlineDetailsExpansion: false,
    anchorBottomOnContentSizeChange: true,
    animateManualScrollToBottom: false,
    useVirtualizedList: false,
    isWeb: true,
  );

  static final native = StreamStrategy._(
    orderTailReverse: true,
    orderHeadReverse: true,
    assistantTurnTraversalStep: 1,
    edgeSlot: StreamEdgeSlot.header,
    historyLiveBoundaryEdge: StreamBoundaryEdge.first,
    liveHeadHistoryBoundaryEdge: StreamBoundaryEdge.last,
    frameChildOrder: StreamFrameChildOrder.footerThenContent,
    flatListInverted: true,
    overlayScrollbarInverted: true,
    maintainVisibleContentPosition: const MaintainVisibleContentPositionConfig(
      minIndexForVisible: 0,
      autoscrollToTopThreshold: 0,
    ),
    bottomAnchorTransportBehavior: const BottomAnchorTransportBehavior(
      verificationDelayFrames: 2,
      verificationRetryMode: BottomAnchorVerificationRetryMode.recheck,
    ),
    disableParentScrollOnInlineDetailsExpansion: false,
    anchorBottomOnContentSizeChange: false,
    animateManualScrollToBottom: true,
    useVirtualizedList: true,
    isWeb: false,
  );

  List<TimelineDisplayItem> orderTail(List<TimelineDisplayItem> items) =>
      orderTailReverse ? items.reversed.toList(growable: false) : items;

  List<TimelineDisplayItem> orderHead(List<TimelineDisplayItem> items) =>
      orderHeadReverse ? items.reversed.toList(growable: false) : items;

  int getNeighborIndex(int index, NeighborRelation relation) =>
      relation == NeighborRelation.above
      ? index + assistantTurnTraversalStep
      : index - assistantTurnTraversalStep;

  TimelineDisplayItem? getNeighborItem(
    List<TimelineDisplayItem> items,
    int index,
    NeighborRelation relation,
  ) {
    final neighborIndex = relation == NeighborRelation.above
        ? index + assistantTurnTraversalStep
        : index - assistantTurnTraversalStep;
    if (neighborIndex < 0 || neighborIndex >= items.length) return null;
    return items[neighborIndex];
  }

  /// Walks from [startIndex] in [assistantTurnTraversalStep] steps,
  /// collecting consecutive assistant message text until a user message (the
  /// start of a different turn) or a list boundary is reached, then joins
  /// the collected text back into chronological order.
  String collectAssistantTurnContent(
    List<TimelineDisplayItem> items,
    int startIndex,
  ) {
    final messages = <String>[];
    for (
      var index = startIndex;
      index >= 0 && index < items.length;
      index += assistantTurnTraversalStep
    ) {
      final current = items[index].item;
      if (current is UserMessageItem) break;
      if (current is AssistantMessageItem) messages.add(current.text);
    }
    return messages.reversed.join('\n\n');
  }

  bool isNearBottom({
    required double offsetY,
    required double threshold,
    required double contentHeight,
    required double viewportHeight,
  }) {
    if (isWeb) {
      final distanceFromBottom = math.max(
        0.0,
        contentHeight - (offsetY + viewportHeight),
      );
      return distanceFromBottom <= threshold;
    }
    return offsetY <= threshold;
  }

  double getBottomOffset({
    required double contentHeight,
    required double viewportHeight,
  }) {
    if (isWeb) {
      return math.max(0.0, contentHeight - viewportHeight);
    }
    return 0;
  }

  int? getHistoryLiveBoundaryIndex(List<TimelineDisplayItem> history) {
    if (history.isEmpty) return null;
    return historyLiveBoundaryEdge == StreamBoundaryEdge.first
        ? 0
        : history.length - 1;
  }

  int? getLiveHeadHistoryBoundaryIndex(List<TimelineDisplayItem> liveHead) {
    if (liveHead.isEmpty) return null;
    return liveHeadHistoryBoundaryEdge == StreamBoundaryEdge.first
        ? 0
        : liveHead.length - 1;
  }

  int? getLatestItemIndex(List<TimelineDisplayItem> items) {
    if (items.isEmpty) return null;
    return historyLiveBoundaryEdge == StreamBoundaryEdge.first
        ? 0
        : items.length - 1;
  }
}

/// Delays and switches native's bottom-anchor verification to `recheck`
/// while the viewport is settling (e.g. a keyboard/rotation transition);
/// leaves web's `rescroll` behavior untouched since it never inverts its
/// list.
BottomAnchorTransportBehavior resolveBottomAnchorTransportBehavior({
  required StreamStrategy strategy,
  required bool isViewportSettling,
}) {
  final base = strategy.bottomAnchorTransportBehavior;
  if (!isViewportSettling || !strategy.flatListInverted) return base;
  return BottomAnchorTransportBehavior(
    verificationDelayFrames:
        base.verificationDelayFrames > _nativeSettlingVerificationDelayFrames
        ? base.verificationDelayFrames
        : _nativeSettlingVerificationDelayFrames,
    verificationRetryMode: BottomAnchorVerificationRetryMode.recheck,
  );
}

/// Port of `resolveStreamRenderStrategy`: `"web"` selects [StreamStrategy.web];
/// every other platform string (`"ios"`, `"android"`, and by extension
/// Flutter's desktop/mobile targets) selects [StreamStrategy.native].
/// [isMobileBreakpoint] is accepted for signature fidelity with upstream
/// (which threads it into the web strategy's `render` closure only) but does
/// not affect any config value here.
StreamStrategy resolveStreamRenderStrategy({
  required String platform,
  required bool isMobileBreakpoint,
}) => platform == 'web' ? StreamStrategy.web : StreamStrategy.native;
