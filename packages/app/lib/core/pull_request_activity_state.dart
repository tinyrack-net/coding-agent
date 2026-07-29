import 'package:agent_protocol/agent_protocol.dart';

import 'pull_request_context.dart';

final class VisiblePullRequestEntry {
  const VisiblePullRequestEntry({required this.entry, required this.collapsed});

  final PullRequestTimelineEntry entry;
  final bool collapsed;
}

final class PullRequestActivityState {
  const PullRequestActivityState({
    this.collapsedKeys = const {},
    this.expandedKeys = const {},
  });

  final Set<String> collapsedKeys;
  final Set<String> expandedKeys;

  static String key({required int prNumber, required String activityId}) =>
      '$prNumber:$activityId';

  PullRequestActivityState collapse({
    required int prNumber,
    required String activityId,
  }) {
    final activityKey = key(prNumber: prNumber, activityId: activityId);
    return PullRequestActivityState(
      collapsedKeys: Set.unmodifiable({...collapsedKeys, activityKey}),
      expandedKeys: Set.unmodifiable({...expandedKeys}..remove(activityKey)),
    );
  }

  PullRequestActivityState expand({
    required int prNumber,
    required String activityId,
  }) {
    final activityKey = key(prNumber: prNumber, activityId: activityId);
    return PullRequestActivityState(
      collapsedKeys: Set.unmodifiable({...collapsedKeys}..remove(activityKey)),
      expandedKeys: Set.unmodifiable({...expandedKeys, activityKey}),
    );
  }

  PullRequestActivityState toggle({
    required int prNumber,
    required PullRequestTimelineEntry entry,
  }) => isCollapsed(prNumber: prNumber, entry: entry)
      ? expand(prNumber: prNumber, activityId: entry.id)
      : collapse(prNumber: prNumber, activityId: entry.id);

  bool isCollapsed({
    required int prNumber,
    required PullRequestTimelineEntry entry,
  }) {
    final activityKey = key(prNumber: prNumber, activityId: entry.id);
    if (collapsedKeys.contains(activityKey)) return true;
    if (expandedKeys.contains(activityKey)) return false;
    return _shouldCollapseByDefault(entry);
  }

  List<VisiblePullRequestEntry> visibleEntries({
    required int prNumber,
    required List<PullRequestTimelineEntry> entries,
  }) => [
    for (final entry in entries)
      VisiblePullRequestEntry(
        entry: entry,
        collapsed: isCollapsed(prNumber: prNumber, entry: entry),
      ),
  ];

  Set<String> collapsedEntryIds({
    required int prNumber,
    required List<PullRequestTimelineEntry> entries,
  }) {
    final prefix = '$prNumber:';
    final result = <String>{
      for (final activityKey in collapsedKeys)
        if (activityKey.startsWith(prefix))
          activityKey.substring(prefix.length),
    };
    _addDefaultCollapsedEntryIds(result, prNumber, entries);
    return Set.unmodifiable(result);
  }

  void _addDefaultCollapsedEntryIds(
    Set<String> result,
    int prNumber,
    List<PullRequestTimelineEntry> entries,
  ) {
    for (final entry in entries) {
      final activityKey = key(prNumber: prNumber, activityId: entry.id);
      if (_shouldCollapseByDefault(entry) &&
          !expandedKeys.contains(activityKey)) {
        result.add(entry.id);
      }
      if (expandedKeys.contains(activityKey)) result.remove(entry.id);
      if (entry is PullRequestReviewEntry) {
        _addDefaultCollapsedEntryIds(result, prNumber, entry.threads);
      }
    }
  }
}

bool _shouldCollapseByDefault(PullRequestTimelineEntry entry) =>
    switch (entry) {
      PullRequestThreadEntry() => entry.collapsedByDefault,
      PullRequestSingleEntry(
        activity: PullRequestTimelineComment(location: final location?),
      ) =>
        location.isResolved == true || location.isOutdated == true,
      _ => false,
    };
