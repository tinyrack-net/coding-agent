/// Port of Paseo 0.2.0's `agent-stream/model.ts`.
///
/// Turns the timeline replica's tail/live-head lists into the ordered,
/// segmented render model the stream viewport draws: a committed history
/// (optionally split into a collapsed virtualized section plus a mounted
/// recent window), the live head, per-turn timing, and the boundary flags
/// layout and the bottom-anchor controller branch on.
///
/// Upstream memoizes each stage on *list identity* (`WeakMap` keyed by the
/// source array) so a live-head update never re-orders or re-splits
/// unchanged committed history. Dart's [Expando] provides the same
/// identity-keyed, weakly-held association, and the ported tests assert the
/// same object-identity reuse upstream's tests do.
library;

import '../state/timeline_provider.dart';
import 'stream_strategy.dart';
import 'turn_time.dart';
import 'web_virtualization.dart';

enum StreamRenderPlatform { web, native }

final class StreamRenderSegments {
  const StreamRenderSegments({
    required this.historyVirtualized,
    required this.historyMounted,
    required this.liveHead,
  });

  /// Older history collapsed behind an estimated-height spacer upstream;
  /// always empty unless desktop web crosses the virtualization threshold.
  final List<TimelineDisplayItem> historyVirtualized;
  final List<TimelineDisplayItem> historyMounted;
  final List<TimelineDisplayItem> liveHead;
}

final class StreamHistoryBoundary {
  const StreamHistoryBoundary({
    required this.hasVirtualizedHistory,
    required this.hasMountedHistory,
    required this.hasLiveHead,
  });

  final bool hasVirtualizedHistory;
  final bool hasMountedHistory;
  final bool hasLiveHead;
}

/// The live auxiliary slots rendered below the stream.
///
/// Upstream's model always returns both as `null` — the view supplies the
/// actual nodes through its segment renderers — so these stay typed as
/// framework-agnostic [Object?] rather than pulling widgets into the pure
/// model.
final class StreamRenderAuxiliary {
  const StreamRenderAuxiliary({this.pendingPermissions, this.turnFooter});

  final Object? pendingPermissions;
  final Object? turnFooter;
}

final class AgentStreamRenderModel {
  const AgentStreamRenderModel({
    required this.history,
    required this.segments,
    required this.turnTiming,
    required this.boundary,
    required this.auxiliary,
  });

  /// The full ordered committed history, before the virtualized/mounted
  /// split. Never contains live-head items.
  final List<TimelineDisplayItem> history;
  final StreamRenderSegments segments;
  final StreamTurnTiming turnTiming;
  final StreamHistoryBoundary boundary;
  final StreamRenderAuxiliary auxiliary;
}

const _emptyStreamItems = <TimelineDisplayItem>[];
const _emptyAuxiliary = StreamRenderAuxiliary();

final _orderedTailCache = Expando<Map<String, List<TimelineDisplayItem>>>(
  'orderedTail',
);
final _orderedHeadCache = Expando<Map<String, List<TimelineDisplayItem>>>(
  'orderedHead',
);
final _splitHistoryCache = Expando<Map<String, _SplitHistory>>('splitHistory');
final _turnTimingCache = Expando<Expando<Map<String, StreamTurnTiming>>>(
  'turnTiming',
);

final class _SplitHistory {
  const _SplitHistory({required this.history, required this.segments});

  final List<TimelineDisplayItem> history;
  final StreamRenderSegments segments;
}

List<TimelineDisplayItem> _getOrderedItems({
  required Expando<Map<String, List<TimelineDisplayItem>>> cache,
  required List<TimelineDisplayItem> source,
  required String cacheKey,
  required List<TimelineDisplayItem> Function(List<TimelineDisplayItem>) order,
}) {
  final cachedByKey = cache[source] ??= <String, List<TimelineDisplayItem>>{};
  final cached = cachedByKey[cacheKey];
  if (cached != null) return cached;
  final ordered = order(source);
  cachedByKey[cacheKey] = ordered;
  return ordered;
}

_SplitHistory _splitOrderedTail({
  required List<TimelineDisplayItem> orderedTail,
  required StreamRenderPlatform platform,
  required bool isMobileBreakpoint,
}) {
  // Only desktop web virtualizes: native uses its own virtualized list, and
  // mobile web keeps the whole committed tail mounted.
  final shouldSplitHistory =
      platform == StreamRenderPlatform.web &&
      !isMobileBreakpoint &&
      orderedTail.length > getWebPartialVirtualizationThreshold();
  final cacheKey =
      '${platform.name}:$isMobileBreakpoint:'
      '${getWebMountedRecentStreamItems()}:$shouldSplitHistory';
  final cachedByKey = _splitHistoryCache[orderedTail] ??=
      <String, _SplitHistory>{};
  final cached = cachedByKey[cacheKey];
  if (cached != null) return cached;

  if (!shouldSplitHistory) {
    final unsplit = _SplitHistory(
      history: orderedTail,
      segments: StreamRenderSegments(
        historyVirtualized: _emptyStreamItems,
        historyMounted: orderedTail,
        liveHead: _emptyStreamItems,
      ),
    );
    cachedByKey[cacheKey] = unsplit;
    return unsplit;
  }

  final mountedWindowStart = findMountedWindowStart(
    items: orderedTail,
    minMountedCount: getWebMountedRecentStreamItems(),
  );
  final split = _SplitHistory(
    history: orderedTail,
    segments: StreamRenderSegments(
      historyVirtualized: orderedTail.sublist(0, mountedWindowStart),
      historyMounted: orderedTail.sublist(mountedWindowStart),
      liveHead: _emptyStreamItems,
    ),
  );
  cachedByKey[cacheKey] = split;
  return split;
}

StreamTurnTiming _getTurnTiming({
  required String agentStatus,
  required List<TimelineDisplayItem> tail,
  required List<TimelineDisplayItem> head,
}) {
  final cachedByHead = _turnTimingCache[tail] ??=
      Expando<Map<String, StreamTurnTiming>>();
  final cachedByStatus = cachedByHead[head] ??= <String, StreamTurnTiming>{};
  final cached = cachedByStatus[agentStatus];
  if (cached != null) return cached;
  final timing = deriveStreamTurnTiming(
    agentStatus: agentStatus,
    tail: tail,
    head: head,
  );
  cachedByStatus[agentStatus] = timing;
  return timing;
}

AgentStreamRenderModel buildAgentStreamRenderModel({
  required String agentStatus,
  required List<TimelineDisplayItem> tail,
  required List<TimelineDisplayItem> head,
  required StreamRenderPlatform platform,
  required bool isMobileBreakpoint,
}) {
  final strategy = resolveStreamRenderStrategy(
    platform: platform == StreamRenderPlatform.web ? 'web' : 'native',
    isMobileBreakpoint: isMobileBreakpoint,
  );
  final orderingCacheKey = '${platform.name}:$isMobileBreakpoint';
  final orderedTail = _getOrderedItems(
    cache: _orderedTailCache,
    source: tail,
    cacheKey: orderingCacheKey,
    order: strategy.orderTail,
  );
  final orderedHead = _getOrderedItems(
    cache: _orderedHeadCache,
    source: head,
    cacheKey: orderingCacheKey,
    order: strategy.orderHead,
  );
  final splitHistory = _splitOrderedTail(
    orderedTail: orderedTail,
    platform: platform,
    isMobileBreakpoint: isMobileBreakpoint,
  );
  final turnTiming = _getTurnTiming(
    agentStatus: agentStatus,
    tail: tail,
    head: head,
  );

  return AgentStreamRenderModel(
    history: splitHistory.history,
    segments: StreamRenderSegments(
      historyVirtualized: splitHistory.segments.historyVirtualized,
      historyMounted: splitHistory.segments.historyMounted,
      liveHead: orderedHead,
    ),
    turnTiming: turnTiming,
    boundary: StreamHistoryBoundary(
      hasVirtualizedHistory:
          splitHistory.segments.historyVirtualized.isNotEmpty,
      hasMountedHistory: splitHistory.segments.historyMounted.isNotEmpty,
      hasLiveHead: orderedHead.isNotEmpty,
    ),
    auxiliary: _emptyAuxiliary,
  );
}
