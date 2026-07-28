import 'dart:math' as math;

enum WorkspaceSplitDirection { horizontal, vertical }

enum WorkspacePaneDirection { left, right, up, down }

enum WorkspaceSplitDropPosition { center, left, right, top, bottom }

sealed class WorkspacePaneNode {
  const WorkspacePaneNode();

  factory WorkspacePaneNode.fromJson(Map<String, Object?> json) {
    return switch (json['type']) {
      'pane' => WorkspacePane.fromJson(json),
      'group' => WorkspacePaneGroup.fromJson(json),
      _ => throw const FormatException('Unknown workspace pane node type'),
    };
  }

  Map<String, Object?> toJson();
}

class WorkspacePane extends WorkspacePaneNode {
  const WorkspacePane({
    required this.id,
    required this.tabIds,
    this.focusedTabId,
  });

  final String id;
  final List<String> tabIds;
  final String? focusedTabId;

  factory WorkspacePane.fromJson(Map<String, Object?> json) => WorkspacePane(
    id: json['id'] as String,
    tabIds: ((json['tabIds'] as List?) ?? const []).cast<String>(),
    focusedTabId: json['focusedTabId'] as String?,
  );

  @override
  Map<String, Object?> toJson() => {
    'type': 'pane',
    'id': id,
    'tabIds': tabIds,
    if (focusedTabId != null) 'focusedTabId': focusedTabId,
  };
}

class WorkspacePaneGroup extends WorkspacePaneNode {
  const WorkspacePaneGroup({
    required this.id,
    required this.direction,
    required this.children,
    required this.sizes,
  });

  final String id;
  final WorkspaceSplitDirection direction;
  final List<WorkspacePaneNode> children;
  final List<double> sizes;

  factory WorkspacePaneGroup.fromJson(Map<String, Object?> json) =>
      WorkspacePaneGroup(
        id: json['id'] as String,
        direction: WorkspaceSplitDirection.values.byName(
          json['direction'] as String,
        ),
        children: ((json['children'] as List?) ?? const [])
            .cast<Map<String, Object?>>()
            .map(WorkspacePaneNode.fromJson)
            .toList(),
        sizes: ((json['sizes'] as List?) ?? const [])
            .cast<num>()
            .map((value) => value.toDouble())
            .toList(),
      );

  @override
  Map<String, Object?> toJson() => {
    'type': 'group',
    'id': id,
    'direction': direction.name,
    'children': children.map((child) => child.toJson()).toList(),
    'sizes': sizes,
  };
}

class WorkspacePaneLayout {
  const WorkspacePaneLayout({required this.root, required this.focusedPaneId});

  static const maxTreeDepth = 4;
  static const minSplitSize = .1;

  final WorkspacePaneNode root;
  final String? focusedPaneId;

  factory WorkspacePaneLayout.single({
    required String paneId,
    required List<String> tabIds,
    String? focusedTabId,
  }) => WorkspacePaneLayout(
    root: WorkspacePane(
      id: paneId,
      tabIds: tabIds,
      focusedTabId: focusedTabId ?? (tabIds.isEmpty ? null : tabIds.first),
    ),
    focusedPaneId: paneId,
  );

  factory WorkspacePaneLayout.fromJson(Map<String, Object?> json) =>
      WorkspacePaneLayout(
        root: WorkspacePaneNode.fromJson(json['root'] as Map<String, Object?>),
        focusedPaneId: json['focusedPaneId'] as String?,
      );

  Map<String, Object?> toJson() => {
    'root': root.toJson(),
    if (focusedPaneId != null) 'focusedPaneId': focusedPaneId,
  };
}

List<WorkspacePane> collectWorkspacePanes(WorkspacePaneNode root) =>
    switch (root) {
      WorkspacePane() => [root],
      WorkspacePaneGroup() => [
        for (final child in root.children) ...collectWorkspacePanes(child),
      ],
    };

WorkspacePane? findWorkspacePane(WorkspacePaneNode root, String? paneId) {
  if (paneId == null) return null;
  for (final pane in collectWorkspacePanes(root)) {
    if (pane.id == paneId) return pane;
  }
  return null;
}

WorkspacePane? findWorkspacePaneContainingTab(
  WorkspacePaneNode root,
  String tabId,
) {
  for (final pane in collectWorkspacePanes(root)) {
    if (pane.tabIds.contains(tabId)) return pane;
  }
  return null;
}

int _treeDepth(WorkspacePaneNode node) {
  if (node is WorkspacePane) return 1;
  final group = node as WorkspacePaneGroup;
  return 1 + group.children.map(_treeDepth).fold<int>(0, math.max);
}

WorkspacePaneNode _insertSplit(
  WorkspacePaneNode node, {
  required String targetPaneId,
  required WorkspaceSplitDirection direction,
  required WorkspacePane newPane,
  required String newGroupId,
}) {
  if (node is WorkspacePane) {
    if (node.id != targetPaneId) return node;
    return WorkspacePaneGroup(
      id: newGroupId,
      direction: direction,
      children: [node, newPane],
      sizes: const [.5, .5],
    );
  }
  final group = node as WorkspacePaneGroup;
  final targetIndex = group.children.indexWhere(
    (child) => child is WorkspacePane && child.id == targetPaneId,
  );
  if (targetIndex >= 0 && group.direction == direction) {
    final sizes = group.sizes.length == group.children.length
        ? List<double>.of(group.sizes)
        : List.filled(
            group.children.length,
            1 / group.children.length,
            growable: true,
          );
    final targetSize = sizes[targetIndex];
    sizes[targetIndex] = targetSize / 2;
    sizes.insert(targetIndex + 1, targetSize / 2);
    return WorkspacePaneGroup(
      id: group.id,
      direction: group.direction,
      children: [
        ...group.children.take(targetIndex + 1),
        newPane,
        ...group.children.skip(targetIndex + 1),
      ],
      sizes: sizes,
    );
  }
  return WorkspacePaneGroup(
    id: group.id,
    direction: group.direction,
    children: [
      for (final child in group.children)
        _insertSplit(
          child,
          targetPaneId: targetPaneId,
          direction: direction,
          newPane: newPane,
          newGroupId: newGroupId,
        ),
    ],
    sizes: group.sizes,
  );
}

WorkspacePaneLayout? splitWorkspacePane({
  required WorkspacePaneLayout layout,
  required String targetPaneId,
  required WorkspaceSplitDirection direction,
  required String newPaneId,
  required String newGroupId,
  required String newTabId,
}) {
  final target = findWorkspacePane(layout.root, targetPaneId);
  if (target == null) return null;
  final nextPane = WorkspacePane(
    id: newPaneId,
    tabIds: [newTabId],
    focusedTabId: newTabId,
  );
  final root = _insertSplit(
    layout.root,
    targetPaneId: targetPaneId,
    direction: direction,
    newPane: nextPane,
    newGroupId: newGroupId,
  );
  if (_treeDepth(root) > WorkspacePaneLayout.maxTreeDepth) return null;
  return WorkspacePaneLayout(root: root, focusedPaneId: newPaneId);
}

WorkspacePaneNode? _removePane(WorkspacePaneNode node, String paneId) {
  if (node is WorkspacePane) return node.id == paneId ? null : node;
  final group = node as WorkspacePaneGroup;
  final kept = <WorkspacePaneNode>[];
  final keptSizes = <double>[];
  for (var index = 0; index < group.children.length; index++) {
    final child = _removePane(group.children[index], paneId);
    if (child == null) continue;
    kept.add(child);
    keptSizes.add(index < group.sizes.length ? group.sizes[index] : 1);
  }
  if (kept.isEmpty) return null;
  if (kept.length == 1) return kept.single;
  final total = keptSizes.fold<double>(0, (sum, size) => sum + size);
  return WorkspacePaneGroup(
    id: group.id,
    direction: group.direction,
    children: kept,
    sizes: total <= 0
        ? List.filled(kept.length, 1 / kept.length)
        : keptSizes.map((size) => size / total).toList(),
  );
}

WorkspacePaneLayout? removeWorkspacePane(
  WorkspacePaneLayout layout,
  String paneId,
) {
  final panes = collectWorkspacePanes(layout.root);
  if (panes.length <= 1 || !panes.any((pane) => pane.id == paneId)) return null;
  final root = _removePane(layout.root, paneId);
  if (root == null) return null;
  final remaining = collectWorkspacePanes(root);
  return WorkspacePaneLayout(
    root: root,
    focusedPaneId: layout.focusedPaneId == paneId
        ? remaining.first.id
        : layout.focusedPaneId,
  );
}

WorkspacePaneNode _mapPanes(
  WorkspacePaneNode node,
  WorkspacePane Function(WorkspacePane pane) transform,
) => switch (node) {
  WorkspacePane() => transform(node),
  WorkspacePaneGroup() => WorkspacePaneGroup(
    id: node.id,
    direction: node.direction,
    children: [for (final child in node.children) _mapPanes(child, transform)],
    sizes: node.sizes,
  ),
};

WorkspacePaneLayout focusWorkspacePaneTab({
  required WorkspacePaneLayout layout,
  required String paneId,
  required String? tabId,
}) {
  final pane = findWorkspacePane(layout.root, paneId);
  if (pane == null || (tabId != null && !pane.tabIds.contains(tabId))) {
    return layout;
  }
  return WorkspacePaneLayout(
    root: _mapPanes(layout.root, (candidate) {
      if (candidate.id != paneId) return candidate;
      return WorkspacePane(
        id: candidate.id,
        tabIds: candidate.tabIds,
        focusedTabId: tabId,
      );
    }),
    focusedPaneId: layout.focusedPaneId,
  );
}

WorkspacePaneLayout moveWorkspaceTabToPane({
  required WorkspacePaneLayout layout,
  required String tabId,
  required String targetPaneId,
}) {
  final source = findWorkspacePaneContainingTab(layout.root, tabId);
  final target = findWorkspacePane(layout.root, targetPaneId);
  if (source == null || target == null || source.id == target.id) return layout;
  var root = _mapPanes(layout.root, (pane) {
    if (pane.id == source.id) {
      final ids = pane.tabIds.where((id) => id != tabId).toList();
      return WorkspacePane(
        id: pane.id,
        tabIds: ids,
        focusedTabId: ids.contains(pane.focusedTabId)
            ? pane.focusedTabId
            : (ids.isEmpty ? null : ids.first),
      );
    }
    if (pane.id == target.id) {
      return WorkspacePane(
        id: pane.id,
        tabIds: [...pane.tabIds.where((id) => id != tabId), tabId],
        focusedTabId: tabId,
      );
    }
    return pane;
  });
  if (source.tabIds.length == 1) {
    root = _removePane(root, source.id) ?? root;
  }
  return WorkspacePaneLayout(root: root, focusedPaneId: target.id);
}

WorkspacePaneNode _insertPositionedSplit(
  WorkspacePaneNode node, {
  required String targetPaneId,
  required WorkspaceSplitDirection direction,
  required bool insertAfter,
  required WorkspacePane newPane,
  required String newGroupId,
}) {
  if (node is WorkspacePane) {
    if (node.id != targetPaneId) return node;
    return WorkspacePaneGroup(
      id: newGroupId,
      direction: direction,
      children: insertAfter ? [node, newPane] : [newPane, node],
      sizes: const [.5, .5],
    );
  }
  final group = node as WorkspacePaneGroup;
  final targetIndex = group.children.indexWhere(
    (child) => child is WorkspacePane && child.id == targetPaneId,
  );
  if (targetIndex >= 0 && group.direction == direction) {
    final sizes = group.sizes.length == group.children.length
        ? List<double>.of(group.sizes)
        : List.filled(
            group.children.length,
            1 / group.children.length,
            growable: true,
          );
    final targetSize = sizes[targetIndex];
    final insertIndex = insertAfter ? targetIndex + 1 : targetIndex;
    sizes.insert(insertIndex, targetSize / 2);
    sizes[targetIndex + (insertAfter ? 0 : 1)] = targetSize / 2;
    final children = List<WorkspacePaneNode>.of(group.children)
      ..insert(insertIndex, newPane);
    return WorkspacePaneGroup(
      id: group.id,
      direction: group.direction,
      children: children,
      sizes: sizes,
    );
  }
  return WorkspacePaneGroup(
    id: group.id,
    direction: group.direction,
    children: [
      for (final child in group.children)
        _insertPositionedSplit(
          child,
          targetPaneId: targetPaneId,
          direction: direction,
          insertAfter: insertAfter,
          newPane: newPane,
          newGroupId: newGroupId,
        ),
    ],
    sizes: group.sizes,
  );
}

WorkspacePaneLayout? splitWorkspaceTabAtPosition({
  required WorkspacePaneLayout layout,
  required String tabId,
  required String targetPaneId,
  required WorkspaceSplitDropPosition position,
  required String newPaneId,
  required String newGroupId,
}) {
  if (position == WorkspaceSplitDropPosition.center) return null;
  final source = findWorkspacePaneContainingTab(layout.root, tabId);
  final target = findWorkspacePane(layout.root, targetPaneId);
  if (source == null || target == null) return null;

  var root = _mapPanes(layout.root, (pane) {
    if (pane.id != source.id) return pane;
    final tabIds = pane.tabIds.where((id) => id != tabId).toList();
    return WorkspacePane(
      id: pane.id,
      tabIds: tabIds,
      focusedTabId: tabIds.contains(pane.focusedTabId)
          ? pane.focusedTabId
          : tabIds.firstOrNull,
    );
  });
  if (source.id != target.id && source.tabIds.length == 1) {
    root = _removePane(root, source.id) ?? root;
  }
  if (findWorkspacePane(root, targetPaneId) == null) return null;

  final horizontal =
      position == WorkspaceSplitDropPosition.left ||
      position == WorkspaceSplitDropPosition.right;
  final insertAfter =
      position == WorkspaceSplitDropPosition.right ||
      position == WorkspaceSplitDropPosition.bottom;
  root = _insertPositionedSplit(
    root,
    targetPaneId: targetPaneId,
    direction: horizontal
        ? WorkspaceSplitDirection.horizontal
        : WorkspaceSplitDirection.vertical,
    insertAfter: insertAfter,
    newPane: WorkspacePane(id: newPaneId, tabIds: [tabId], focusedTabId: tabId),
    newGroupId: newGroupId,
  );
  if (_treeDepth(root) > WorkspacePaneLayout.maxTreeDepth) return null;
  return WorkspacePaneLayout(root: root, focusedPaneId: newPaneId);
}

WorkspaceSplitDropPosition resolveWorkspaceSplitDropPosition({
  required double width,
  required double height,
  required double x,
  required double y,
}) {
  const edgeRatio = .15;
  const centerRatio = .4;
  final centerInsetX = width * ((1 - centerRatio) / 2);
  final centerInsetY = height * ((1 - centerRatio) / 2);
  final insideCenterX = x >= centerInsetX && x <= width - centerInsetX;
  final insideCenterY = y >= centerInsetY && y <= height - centerInsetY;
  if (insideCenterX && insideCenterY) {
    return WorkspaceSplitDropPosition.center;
  }

  final edgeThresholdX = width * edgeRatio;
  final edgeThresholdY = height * edgeRatio;
  if (x <= edgeThresholdX) return WorkspaceSplitDropPosition.left;
  if (x >= width - edgeThresholdX) {
    return WorkspaceSplitDropPosition.right;
  }
  if (y <= edgeThresholdY) return WorkspaceSplitDropPosition.top;
  if (y >= height - edgeThresholdY) {
    return WorkspaceSplitDropPosition.bottom;
  }

  final distances = <(WorkspaceSplitDropPosition, double)>[
    (WorkspaceSplitDropPosition.left, x),
    (WorkspaceSplitDropPosition.right, width - x),
    (WorkspaceSplitDropPosition.top, y),
    (WorkspaceSplitDropPosition.bottom, height - y),
  ]..sort((left, right) => left.$2.compareTo(right.$2));
  return distances.firstOrNull?.$1 ?? WorkspaceSplitDropPosition.center;
}

WorkspacePaneLayout reconcileWorkspacePaneLayout({
  required WorkspacePaneLayout layout,
  required List<String> tabIds,
  String? preferredTabId,
}) {
  final valid = tabIds.toSet();
  var root = _mapPanes(layout.root, (pane) {
    final ids = pane.tabIds.where(valid.contains).toList();
    return WorkspacePane(
      id: pane.id,
      tabIds: ids,
      focusedTabId: ids.contains(pane.focusedTabId)
          ? pane.focusedTabId
          : (ids.isEmpty ? null : ids.first),
    );
  });
  final assigned = collectWorkspacePanes(
    root,
  ).expand((pane) => pane.tabIds).toSet();
  final focused =
      findWorkspacePane(root, layout.focusedPaneId) ??
      collectWorkspacePanes(root).first;
  final missing = tabIds.where((id) => !assigned.contains(id)).toList();
  if (missing.isNotEmpty) {
    root = _mapPanes(root, (pane) {
      if (pane.id != focused.id) return pane;
      final ids = [...pane.tabIds, ...missing];
      return WorkspacePane(
        id: pane.id,
        tabIds: ids,
        focusedTabId: preferredTabId != null && ids.contains(preferredTabId)
            ? preferredTabId
            : pane.focusedTabId ?? ids.first,
      );
    });
  }
  final preferredPane = preferredTabId == null
      ? null
      : findWorkspacePaneContainingTab(root, preferredTabId);
  return WorkspacePaneLayout(
    root: root,
    focusedPaneId: preferredPane?.id ?? focused.id,
  );
}

class _PaneBounds {
  const _PaneBounds(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;
}

void _collectBounds(
  WorkspacePaneNode node,
  _PaneBounds bounds,
  Map<String, _PaneBounds> output,
) {
  if (node is WorkspacePane) {
    output[node.id] = bounds;
    return;
  }
  final group = node as WorkspacePaneGroup;
  final raw = group.sizes.length == group.children.length
      ? group.sizes
      : List.filled(group.children.length, 1 / group.children.length);
  final total = raw.fold<double>(0, (sum, size) => sum + size);
  var cursor = group.direction == WorkspaceSplitDirection.horizontal
      ? bounds.left
      : bounds.top;
  for (var index = 0; index < group.children.length; index++) {
    final fraction = total <= 0
        ? 1 / group.children.length
        : raw[index] / total;
    final childBounds = group.direction == WorkspaceSplitDirection.horizontal
        ? _PaneBounds(
            cursor,
            bounds.top,
            cursor + (bounds.right - bounds.left) * fraction,
            bounds.bottom,
          )
        : _PaneBounds(
            bounds.left,
            cursor,
            bounds.right,
            cursor + (bounds.bottom - bounds.top) * fraction,
          );
    _collectBounds(group.children[index], childBounds, output);
    cursor = group.direction == WorkspaceSplitDirection.horizontal
        ? childBounds.right
        : childBounds.bottom;
  }
}

String? findAdjacentWorkspacePane(
  WorkspacePaneNode root,
  String paneId,
  WorkspacePaneDirection direction,
) {
  final bounds = <String, _PaneBounds>{};
  _collectBounds(root, const _PaneBounds(0, 0, 1, 1), bounds);
  final source = bounds[paneId];
  if (source == null) return null;
  final sourceX = (source.left + source.right) / 2;
  final sourceY = (source.top + source.bottom) / 2;
  final candidates = <(String, double, double, double, double)>[];
  for (final entry in bounds.entries) {
    if (entry.key == paneId) continue;
    final candidate = entry.value;
    final x = (candidate.left + candidate.right) / 2;
    final y = (candidate.top + candidate.bottom) / 2;
    final primary = switch (direction) {
      WorkspacePaneDirection.left when candidate.right <= source.left =>
        source.left - candidate.right,
      WorkspacePaneDirection.right when candidate.left >= source.right =>
        candidate.left - source.right,
      WorkspacePaneDirection.up when candidate.bottom <= source.top =>
        source.top - candidate.bottom,
      WorkspacePaneDirection.down when candidate.top >= source.bottom =>
        candidate.top - source.bottom,
      _ => null,
    };
    if (primary == null) continue;
    final secondary = switch (direction) {
      WorkspacePaneDirection.left || WorkspacePaneDirection.right => math.max(
        0.0,
        math.max(source.top, candidate.top) -
            math.min(source.bottom, candidate.bottom),
      ),
      WorkspacePaneDirection.up || WorkspacePaneDirection.down => math.max(
        0.0,
        math.max(source.left, candidate.left) -
            math.min(source.right, candidate.right),
      ),
    };
    final overlap = switch (direction) {
      WorkspacePaneDirection.left || WorkspacePaneDirection.right => math.max(
        0.0,
        math.min(source.bottom, candidate.bottom) -
            math.max(source.top, candidate.top),
      ),
      WorkspacePaneDirection.up || WorkspacePaneDirection.down => math.max(
        0.0,
        math.min(source.right, candidate.right) -
            math.max(source.left, candidate.left),
      ),
    };
    final center = switch (direction) {
      WorkspacePaneDirection.left ||
      WorkspacePaneDirection.right => (y - sourceY).abs(),
      WorkspacePaneDirection.up ||
      WorkspacePaneDirection.down => (x - sourceX).abs(),
    };
    candidates.add((entry.key, primary, secondary, overlap, center));
  }
  candidates.sort((left, right) {
    var comparison = left.$2.compareTo(right.$2);
    if (comparison != 0) return comparison;
    comparison = left.$3.compareTo(right.$3);
    if (comparison != 0) return comparison;
    comparison = right.$4.compareTo(left.$4);
    if (comparison != 0) return comparison;
    comparison = left.$5.compareTo(right.$5);
    if (comparison != 0) return comparison;
    return left.$1.compareTo(right.$1);
  });
  return candidates.firstOrNull?.$1;
}

List<double> clampNormalizedWorkspaceSizes(List<double> sizes) {
  if (sizes.isEmpty) return const [];
  final sanitized = sizes
      .map((size) => size.isFinite && size > 0 ? size : 1.0)
      .toList();
  final total = sanitized.fold<double>(0, (sum, size) => sum + size);
  final normalized = sanitized.map((size) => size / total).toList();
  if (sizes.length == 1) return const [1];
  if (sizes.length * WorkspacePaneLayout.minSplitSize > 1) {
    return List.filled(sizes.length, 1 / sizes.length);
  }

  final next = List<double>.filled(sizes.length, 0);
  final unlocked = {for (var index = 0; index < sizes.length; index++) index};
  var remainingTotal = 1.0;
  while (unlocked.isNotEmpty) {
    final unlockedWeight = unlocked.fold<double>(
      0,
      (sum, index) => sum + normalized[index],
    );
    final nextLocked = <int>[];
    for (final index in unlocked) {
      final proposed = normalized[index] / unlockedWeight * remainingTotal;
      if (proposed < WorkspacePaneLayout.minSplitSize) {
        nextLocked.add(index);
      }
    }
    if (nextLocked.isEmpty) {
      for (final index in unlocked) {
        next[index] = normalized[index] / unlockedWeight * remainingTotal;
      }
      break;
    }
    for (final index in nextLocked) {
      next[index] = WorkspacePaneLayout.minSplitSize;
      unlocked.remove(index);
      remainingTotal -= WorkspacePaneLayout.minSplitSize;
    }
  }
  final nextTotal = next.fold<double>(0, (sum, size) => sum + size);
  return next.map((size) => size / nextTotal).toList();
}

List<double> computeWorkspaceResizeHandleSizes({
  required List<double> sizes,
  required int index,
  required double deltaRatio,
  double minSize = WorkspacePaneLayout.minSplitSize,
}) {
  final next = List<double>.of(sizes);
  if (index < 0 || index + 1 >= sizes.length) return next;
  final left = sizes[index];
  final right = sizes[index + 1];
  final pairSize = left + right;
  if (pairSize <= 0) return next;
  final adjacentMin = math.min(minSize, pairSize / 2);
  final nextLeft = math.min(
    pairSize - adjacentMin,
    math.max(adjacentMin, left + deltaRatio),
  );
  next[index] = nextLeft;
  next[index + 1] = pairSize - nextLeft;
  return next;
}

WorkspacePaneLayout resizeWorkspaceSplit({
  required WorkspacePaneLayout layout,
  required String groupId,
  required List<double> sizes,
}) {
  WorkspacePaneNode update(WorkspacePaneNode node) {
    if (node is WorkspacePane) return node;
    final group = node as WorkspacePaneGroup;
    return WorkspacePaneGroup(
      id: group.id,
      direction: group.direction,
      children: group.children.map(update).toList(),
      sizes: group.id == groupId && sizes.length == group.children.length
          ? clampNormalizedWorkspaceSizes(sizes)
          : group.sizes,
    );
  }

  return WorkspacePaneLayout(
    root: update(layout.root),
    focusedPaneId: layout.focusedPaneId,
  );
}

WorkspacePaneLayout? reorderWorkspacePaneTabs({
  required WorkspacePaneLayout layout,
  required String paneId,
  required List<String> tabIds,
}) {
  final pane = findWorkspacePane(layout.root, paneId);
  if (pane == null) return null;
  final valid = pane.tabIds.toSet();
  final seen = <String>{};
  final reordered = [
    for (final tabId in tabIds)
      if (valid.contains(tabId) && seen.add(tabId)) tabId,
    for (final tabId in pane.tabIds)
      if (seen.add(tabId)) tabId,
  ];
  return WorkspacePaneLayout(
    root: _mapPanes(layout.root, (candidate) {
      if (candidate.id != paneId) return candidate;
      return WorkspacePane(
        id: candidate.id,
        tabIds: reordered,
        focusedTabId: reordered.contains(candidate.focusedTabId)
            ? candidate.focusedTabId
            : reordered.firstOrNull,
      );
    }),
    focusedPaneId: layout.focusedPaneId,
  );
}

WorkspacePaneLayout moveWorkspaceTabToPaneIndex({
  required WorkspacePaneLayout layout,
  required String tabId,
  required String targetPaneId,
  required int insertionIndex,
}) {
  final moved = moveWorkspaceTabToPane(
    layout: layout,
    tabId: tabId,
    targetPaneId: targetPaneId,
  );
  final target = findWorkspacePane(moved.root, targetPaneId);
  if (target == null) return moved;
  final ids = target.tabIds.where((id) => id != tabId).toList();
  ids.insert(insertionIndex.clamp(0, ids.length), tabId);
  return reorderWorkspacePaneTabs(
        layout: moved,
        paneId: targetPaneId,
        tabIds: ids,
      ) ??
      moved;
}

class WorkspaceTabDropPreview {
  const WorkspaceTabDropPreview({
    required this.paneId,
    required this.insertionIndex,
    required this.indicatorIndex,
  });

  final String paneId;
  final int insertionIndex;
  final int indicatorIndex;
}

WorkspaceTabDropPreview? computeWorkspaceTabDropPreview({
  required String activePaneId,
  required String activeTabId,
  required String overPaneId,
  required String overTabId,
  required List<String> targetTabIds,
  required double activeCenterX,
  required double overCenterX,
  required double overWidth,
}) {
  final targetIndex = targetTabIds.indexOf(overTabId);
  if (targetIndex < 0 || overWidth <= 0) return null;
  final insertAfter = activeCenterX >= overCenterX;
  final indicatorIndex = targetIndex + (insertAfter ? 1 : 0);
  var insertionIndex = indicatorIndex;
  if (activePaneId == overPaneId) {
    final sourceIndex = targetTabIds.indexOf(activeTabId);
    if (sourceIndex < 0) return null;
    if (sourceIndex < insertionIndex) insertionIndex -= 1;
    insertionIndex = insertionIndex.clamp(0, targetTabIds.length - 1);
  }
  return WorkspaceTabDropPreview(
    paneId: overPaneId,
    insertionIndex: insertionIndex,
    indicatorIndex: indicatorIndex,
  );
}
