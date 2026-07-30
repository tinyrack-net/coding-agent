import '../workspace/workspace_tab_model.dart';

final class CompactExplorerSelection {
  const CompactExplorerSelection({
    required this.serverId,
    required this.workspaceId,
  });

  final String serverId;
  final String workspaceId;
}

final class CompactExplorerWorkspaceSnapshot {
  const CompactExplorerWorkspaceSnapshot({required this.workspaceDirectory});

  final String workspaceDirectory;
}

final class CompactExplorerSidebarHostModel {
  const CompactExplorerSidebarHostModel({
    required this.serverId,
    required this.workspaceId,
    required this.persistenceKey,
    required this.workspaceRoot,
    required this.isGit,
  });

  final String serverId;
  final String workspaceId;
  final String persistenceKey;
  final String workspaceRoot;
  final bool isGit;

  @override
  bool operator ==(Object other) =>
      other is CompactExplorerSidebarHostModel &&
      other.serverId == serverId &&
      other.workspaceId == workspaceId &&
      other.persistenceKey == persistenceKey &&
      other.workspaceRoot == workspaceRoot &&
      other.isGit == isGit;

  @override
  int get hashCode =>
      Object.hash(serverId, workspaceId, persistenceKey, workspaceRoot, isGit);
}

String? _trimNonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

CompactExplorerSidebarHostModel? resolveCompactExplorerSidebarHostModel({
  required CompactExplorerSidebarHostModel? previous,
  required CompactExplorerSelection? selection,
  required CompactExplorerWorkspaceSnapshot? workspace,
  required bool isGit,
}) {
  final serverId = _trimNonEmpty(selection?.serverId);
  final workspaceId = _trimNonEmpty(selection?.workspaceId);
  if (serverId == null || workspaceId == null) return null;

  final persistenceKey = buildWorkspaceTabPersistenceKey(
    serverId: serverId,
    workspaceId: workspaceId,
  );
  if (persistenceKey == null) return null;

  final previousForSelection =
      previous != null &&
          previous.serverId == serverId &&
          previous.workspaceId == workspaceId
      ? previous
      : null;

  return CompactExplorerSidebarHostModel(
    serverId: serverId,
    workspaceId: workspaceId,
    persistenceKey: persistenceKey,
    workspaceRoot:
        _trimNonEmpty(workspace?.workspaceDirectory) ??
        previousForSelection?.workspaceRoot ??
        '',
    isGit: workspace != null ? isGit : previousForSelection?.isGit ?? isGit,
  );
}
