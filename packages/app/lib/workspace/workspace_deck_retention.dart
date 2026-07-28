const workspaceDeckMaxMountedWorkspaces = 3;

final class WorkspaceDeckSelection {
  const WorkspaceDeckSelection({
    required this.serverId,
    required this.workspaceId,
    required this.worktreePath,
  });

  final String serverId;
  final String workspaceId;
  final String worktreePath;

  String get key => '$serverId:$workspaceId';

  @override
  bool operator ==(Object other) =>
      other is WorkspaceDeckSelection &&
      other.serverId == serverId &&
      other.workspaceId == workspaceId;

  @override
  int get hashCode => Object.hash(serverId, workspaceId);
}

bool workspaceSelectionListsEqual(
  List<WorkspaceDeckSelection> left,
  List<WorkspaceDeckSelection> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

List<WorkspaceDeckSelection> pruneMountedWorkspaceSelections({
  required List<WorkspaceDeckSelection> currentSelections,
  required WorkspaceDeckSelection? activeSelection,
  int maxMountedWorkspaces = workspaceDeckMaxMountedWorkspaces,
}) {
  if (activeSelection == null) return currentSelections;

  final maxSelections = maxMountedWorkspaces < 1 ? 1 : maxMountedWorkspaces;
  final next = <WorkspaceDeckSelection>[];
  final seenKeys = <String>{};

  void append(WorkspaceDeckSelection selection) {
    if (next.length >= maxSelections || !seenKeys.add(selection.key)) return;
    next.add(selection);
  }

  append(activeSelection);
  for (final selection in currentSelections) {
    if (selection != activeSelection) append(selection);
  }
  return next;
}

List<WorkspaceDeckSelection> orderWorkspaceSelectionsForStableRender(
  List<WorkspaceDeckSelection> selections,
) => [...selections]..sort((left, right) => left.key.compareTo(right.key));

bool shouldKeepWorkspaceDeckEntryMounted({
  required bool isActive,
  required bool hasHydratedWorkspaces,
  required bool workspaceExists,
}) {
  if (isActive) return true;
  if (!hasHydratedWorkspaces) return true;
  return workspaceExists;
}

final class WorkspaceDeckRetentionController {
  List<WorkspaceDeckSelection> _mountedSelections = const [];

  List<WorkspaceDeckSelection> get mountedSelections => _mountedSelections;

  WorkspaceDeckSelection selectionFor({
    required String serverId,
    required String workspaceId,
    required String worktreePath,
  }) {
    for (final selection in _mountedSelections) {
      if (selection.serverId == serverId &&
          selection.worktreePath == worktreePath) {
        return selection;
      }
    }
    return WorkspaceDeckSelection(
      serverId: serverId,
      workspaceId: workspaceId,
      worktreePath: worktreePath,
    );
  }

  List<WorkspaceDeckSelection> reconcile({
    required WorkspaceDeckSelection? activeSelection,
    required bool hasHydratedWorkspaces,
    required Set<String> existingWorktreePaths,
  }) {
    final surviving = [
      for (final selection in _mountedSelections)
        if (shouldKeepWorkspaceDeckEntryMounted(
          isActive: selection == activeSelection,
          hasHydratedWorkspaces: hasHydratedWorkspaces,
          workspaceExists: existingWorktreePaths.contains(
            selection.worktreePath,
          ),
        ))
          selection,
    ];
    _mountedSelections = pruneMountedWorkspaceSelections(
      currentSelections: surviving,
      activeSelection: activeSelection,
    );
    return _mountedSelections;
  }
}
