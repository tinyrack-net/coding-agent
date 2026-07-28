import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workspace/workspace_pane_layout.dart';

enum WorkspaceKeyboardDragDirection { left, right, up, down }

final class WorkspaceKeyboardTabDrag {
  const WorkspaceKeyboardTabDrag({
    required this.activePaneId,
    required this.activeTabId,
    required this.overPaneId,
    required this.overTabId,
    required this.overIndex,
  });

  final String activePaneId;
  final String activeTabId;
  final String overPaneId;
  final String overTabId;
  final int overIndex;

  WorkspaceKeyboardTabDrag copyWith({
    required String overPaneId,
    required String overTabId,
    required int overIndex,
  }) => WorkspaceKeyboardTabDrag(
    activePaneId: activePaneId,
    activeTabId: activeTabId,
    overPaneId: overPaneId,
    overTabId: overTabId,
    overIndex: overIndex,
  );
}

WorkspaceKeyboardTabDrag moveWorkspaceKeyboardTabDrag({
  required WorkspaceKeyboardTabDrag drag,
  required WorkspacePaneLayout layout,
  required WorkspaceKeyboardDragDirection direction,
}) {
  final pane = findWorkspacePane(layout.root, drag.overPaneId);
  if (pane == null || !pane.tabIds.contains(drag.overTabId)) return drag;
  final currentIndex = pane.tabIds.indexOf(drag.overTabId);
  final inlineOffset = switch (direction) {
    WorkspaceKeyboardDragDirection.left => -1,
    WorkspaceKeyboardDragDirection.right => 1,
    WorkspaceKeyboardDragDirection.up ||
    WorkspaceKeyboardDragDirection.down => 0,
  };
  final inlineIndex = currentIndex + inlineOffset;
  if (inlineOffset != 0 &&
      inlineIndex >= 0 &&
      inlineIndex < pane.tabIds.length) {
    return drag.copyWith(
      overPaneId: pane.id,
      overTabId: pane.tabIds[inlineIndex],
      overIndex: inlineIndex,
    );
  }

  final paneDirection = switch (direction) {
    WorkspaceKeyboardDragDirection.left => WorkspacePaneDirection.left,
    WorkspaceKeyboardDragDirection.right => WorkspacePaneDirection.right,
    WorkspaceKeyboardDragDirection.up => WorkspacePaneDirection.up,
    WorkspaceKeyboardDragDirection.down => WorkspacePaneDirection.down,
  };
  final adjacentPaneId = findAdjacentWorkspacePane(
    layout.root,
    pane.id,
    paneDirection,
  );
  final adjacentPane = findWorkspacePane(layout.root, adjacentPaneId);
  if (adjacentPane == null || adjacentPane.tabIds.isEmpty) return drag;
  final preferredTabId =
      adjacentPane.focusedTabId ??
      switch (direction) {
        WorkspaceKeyboardDragDirection.left => adjacentPane.tabIds.last,
        WorkspaceKeyboardDragDirection.right => adjacentPane.tabIds.first,
        WorkspaceKeyboardDragDirection.up ||
        WorkspaceKeyboardDragDirection.down => adjacentPane.tabIds.first,
      };
  final targetIndex = adjacentPane.tabIds.indexOf(preferredTabId);
  final resolvedIndex = targetIndex < 0 ? 0 : targetIndex;
  return drag.copyWith(
    overPaneId: adjacentPane.id,
    overTabId: adjacentPane.tabIds[resolvedIndex],
    overIndex: resolvedIndex,
  );
}

class WorkspaceTabKeyboardDragNotifier
    extends Notifier<WorkspaceKeyboardTabDrag?> {
  WorkspaceTabKeyboardDragNotifier(this.worktreePath);

  final String worktreePath;

  @override
  WorkspaceKeyboardTabDrag? build() => null;

  void start({
    required String paneId,
    required String tabId,
    required int tabIndex,
  }) {
    state = WorkspaceKeyboardTabDrag(
      activePaneId: paneId,
      activeTabId: tabId,
      overPaneId: paneId,
      overTabId: tabId,
      overIndex: tabIndex,
    );
  }

  void move(
    WorkspacePaneLayout layout,
    WorkspaceKeyboardDragDirection direction,
  ) {
    final current = state;
    if (current == null) return;
    state = moveWorkspaceKeyboardTabDrag(
      drag: current,
      layout: layout,
      direction: direction,
    );
  }

  WorkspaceKeyboardTabDrag? finish() {
    final result = state;
    state = null;
    return result;
  }

  void cancel() => state = null;
}

final workspaceTabKeyboardDragProvider =
    NotifierProvider.family<
      WorkspaceTabKeyboardDragNotifier,
      WorkspaceKeyboardTabDrag?,
      String
    >(WorkspaceTabKeyboardDragNotifier.new);
