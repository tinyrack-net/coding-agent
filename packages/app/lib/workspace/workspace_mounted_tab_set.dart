/// Paseo's desktop pane retention contract.
///
/// The active tab is mounted synchronously, explicitly retained tabs are
/// never evicted, and the remaining capacity is filled from the previously
/// committed most-recently-used order.
List<String> deriveMountedTabLru({
  required String? activeTabId,
  required Set<String> availableTabIds,
  required int cap,
  required List<String> previousLru,
  Set<String> retainedTabIds = const {},
}) {
  final maxSize = cap < 1 ? 1 : cap;
  final next = <String>[];

  if (activeTabId != null && availableTabIds.contains(activeTabId)) {
    next.add(activeTabId);
  }

  for (final tabId in retainedTabIds) {
    if (tabId != activeTabId && availableTabIds.contains(tabId)) {
      next.add(tabId);
    }
  }

  for (final tabId in previousLru) {
    if (next.length >= maxSize) break;
    if (tabId != activeTabId &&
        availableTabIds.contains(tabId) &&
        !next.contains(tabId)) {
      next.add(tabId);
    }
  }
  return next;
}
