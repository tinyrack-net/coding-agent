import '../state/worktree_tabs_provider.dart';
import '../workspace/workspace_pane_layout.dart';
import 'composer_draft_store.dart';

final class FocusedChatTarget {
  const FocusedChatTarget({required this.tabId, required this.draftKey});

  final String tabId;
  final String draftKey;
}

FocusedChatTarget? resolveFocusedChatTarget({
  required String serverId,
  required WorktreeTabLayout layout,
}) {
  final paneLayout = layout.paneLayout;
  if (paneLayout == null) return null;
  final pane = findWorkspacePane(paneLayout.root, paneLayout.focusedPaneId);
  final focusedTabId = pane?.focusedTabId;
  if (focusedTabId == null) return null;
  final tab = layout.tabs
      .where((candidate) => candidate.tabId == focusedTabId)
      .firstOrNull;
  if (tab == null) return null;
  return switch (tab.kind) {
    WorktreeTabKind.agent when tab.agentId != null => FocusedChatTarget(
      tabId: tab.tabId,
      draftKey: buildComposerDraftKey(
        serverId: serverId,
        agentId: tab.agentId!,
      ),
    ),
    WorktreeTabKind.draft => FocusedChatTarget(
      tabId: tab.tabId,
      draftKey: buildComposerDraftKey(
        serverId: serverId,
        agentId: tab.tabId,
        draftId: tab.tabId,
      ),
    ),
    _ => null,
  };
}
