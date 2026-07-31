/// Port of Paseo 0.2.0's `agent-stream/web-virtualization.ts`.
///
/// Upstream's web strategy renders a very long chat as two sections: an older
/// "virtualized" section collapsed behind a single estimated-height spacer,
/// and a recent "mounted" window of real rows. The split point is always
/// rewound to a `user_message` so a turn is never cut in half.
///
/// Flutter's `ListView.builder` already virtualizes its viewport, so the
/// Flutter stream view mounts rows through the builder rather than a spacer
/// div. The split itself still drives the render model's segments (and the
/// history/live boundary flags that layout and the bottom-anchor controller
/// branch on), so the pure logic and its thresholds are ported here and
/// verified against the same cases as upstream's `web-virtualization.test.ts`.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../state/timeline_provider.dart';

const defaultWebPartialVirtualizationThreshold = 100;
const defaultWebMountedRecentStreamItems = 50;
const _collapsedToolSequenceRowHeightEstimate = 40.0;

int? _partialVirtualizationThresholdOverride;
int? _mountedRecentStreamItemsOverride;

/// Mirrors upstream's `readPositiveIntegerOverride`: non-finite values and
/// non-positive integers are rejected, everything else is truncated toward
/// zero.
int? _normalizePositiveIntegerOverride(num? value) {
  if (value == null) return null;
  if (value is double && (value.isNaN || value.isInfinite)) return null;
  final normalized = value.truncate();
  return normalized > 0 ? normalized : null;
}

/// Test-only override hook. Upstream reads
/// `globalThis.__PASEO_E2E_WEB_PARTIAL_VIRTUALIZATION_THRESHOLD` /
/// `__PASEO_E2E_WEB_MOUNTED_RECENT_STREAM_ITEMS`, which its E2E harness sets
/// to shrink the window without building a 100-message conversation. Passing
/// `null` (the default) for either argument clears that override.
void setWebVirtualizationOverrides({
  num? partialVirtualizationThreshold,
  num? mountedRecentStreamItems,
}) {
  _partialVirtualizationThresholdOverride = _normalizePositiveIntegerOverride(
    partialVirtualizationThreshold,
  );
  _mountedRecentStreamItemsOverride = _normalizePositiveIntegerOverride(
    mountedRecentStreamItems,
  );
}

/// Item count above which the history section starts virtualizing.
int getWebPartialVirtualizationThreshold() =>
    _partialVirtualizationThresholdOverride ??
    defaultWebPartialVirtualizationThreshold;

/// Minimum number of recent items kept mounted once virtualization kicks in.
int getWebMountedRecentStreamItems() =>
    _mountedRecentStreamItemsOverride ?? defaultWebMountedRecentStreamItems;

/// A history item paired with its index in the full, unsplit history list.
/// Upstream keeps the original index so a virtualized row can still resolve
/// its neighbors for spacing/tool-sequence classification after the split.
final class IndexedStreamItem {
  const IndexedStreamItem({required this.item, required this.index});

  final TimelineDisplayItem item;
  final int index;
}

final class WebVirtualizedHistoryWindow {
  const WebVirtualizedHistoryWindow({
    required this.virtualizedEntries,
    required this.mountedEntries,
  });

  final List<IndexedStreamItem> virtualizedEntries;
  final List<IndexedStreamItem> mountedEntries;
}

/// Resolves a cached measured height for an assistant message's markdown, or
/// `null` when nothing has been measured yet.
///
/// Upstream's implementation lives in `utils/assistant-message-height-estimate.ts`
/// (backed by `split-markdown-blocks.ts` and `assistant-image-metadata.ts`),
/// all of which are tracked as their own parity items. Injecting it keeps
/// this module's split logic independent of that measurement chain.
typedef AssistantMessageHeightEstimator = double? Function(String markdown);

/// Estimated row height used to size the collapsed virtualized section.
double estimateStreamItemHeight(
  TimelineDisplayItem display, {
  AssistantMessageHeightEstimator? assistantHeightEstimator,
}) {
  final item = display.item;
  return switch (item) {
    UserMessageItem() =>
      (display.userMessage?.images.isNotEmpty ?? false) ? 220 : 96,
    AssistantMessageItem(:final text) =>
      assistantHeightEstimator?.call(text) ?? 220,
    // Tool calls and reasoning ("thought" upstream) render as compact
    // collapsed tool-sequence rows.
    ToolCallItem() ||
    ReasoningItem() => _collapsedToolSequenceRowHeightEstimate,
    TodoItem() => 144,
    // Upstream's `activity_log`; Tinyrack projects curated activity into
    // error items.
    ErrorItem() => 88,
    CompactionItem() => 72,
    _ => 120,
  };
}

/// Returns the index the mounted window starts at, rewound to the nearest
/// preceding `user_message` so a turn is never split across the boundary.
int findMountedWindowStart({
  required List<TimelineDisplayItem> items,
  required int minMountedCount,
}) {
  if (items.length <= minMountedCount) return 0;

  var startIndex = items.length - minMountedCount;
  if (startIndex < 0) startIndex = 0;
  while (startIndex > 0 && items[startIndex].item is! UserMessageItem) {
    startIndex -= 1;
  }
  return startIndex;
}

/// Splits indexed history entries into the collapsed virtualized section and
/// the mounted recent window.
WebVirtualizedHistoryWindow splitWebVirtualizedHistory({
  required List<IndexedStreamItem> entries,
  required int minMountedCount,
}) {
  final startIndex = findMountedWindowStart(
    items: [for (final entry in entries) entry.item],
    minMountedCount: minMountedCount,
  );
  return WebVirtualizedHistoryWindow(
    virtualizedEntries: entries.sublist(0, startIndex),
    mountedEntries: entries.sublist(startIndex),
  );
}
