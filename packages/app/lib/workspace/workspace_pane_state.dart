import 'workspace_file_open.dart';
import 'workspace_pane_layout.dart';
import 'workspace_tab_model.dart';

final class WorkspaceTabDescriptor {
  const WorkspaceTabDescriptor({
    required this.key,
    required this.tabId,
    required this.kind,
    required this.target,
  });

  final String key;
  final String tabId;
  final String kind;
  final WorkspaceTabTarget target;
}

final class WorkspaceDerivedTab {
  const WorkspaceDerivedTab({required this.descriptor});

  final WorkspaceTabDescriptor descriptor;
}

final class WorkspacePaneState {
  const WorkspacePaneState({
    required this.pane,
    required this.tabs,
    required this.focusedTabId,
    required this.activeTabId,
    required this.activeTab,
  });

  final WorkspacePane? pane;
  final List<WorkspaceDerivedTab> tabs;
  final String? focusedTabId;
  final String? activeTabId;
  final WorkspaceDerivedTab? activeTab;
}

WorkspacePaneState deriveWorkspacePaneState({
  WorkspacePaneLayout? layout,
  WorkspacePane? pane,
  String? paneId,
  required List<WorkspaceTab> tabs,
  String? focusedTabId,
  WorkspaceTabTarget? preferredTarget,
}) {
  final resolvedPane =
      pane ??
      switch (layout) {
        null => null,
        final layout => findWorkspacePane(
          layout.root,
          _trimNonEmpty(paneId) ?? layout.focusedPaneId,
        ),
      };
  final tabsById = {for (final tab in tabs) tab.tabId: tab};
  final orderedTabs = resolvedPane == null
      ? tabs
      : [for (final tabId in resolvedPane.tabIds) ?tabsById[tabId]];

  final derivedTabs = <WorkspaceDerivedTab>[];
  final openTabIds = <String>{};
  for (final tab in orderedTabs) {
    final normalized = WorkspaceTab.fromJson(tab.toJson());
    if (normalized == null || !openTabIds.add(normalized.tabId)) continue;
    derivedTabs.add(
      WorkspaceDerivedTab(
        descriptor: WorkspaceTabDescriptor(
          key: normalized.tabId,
          tabId: normalized.tabId,
          kind: normalized.target.kind,
          target: normalized.target,
        ),
      ),
    );
  }

  final resolvedFocusedTabId =
      resolvedPane?.focusedTabId ?? _trimNonEmpty(focusedTabId);
  final normalizedPreferredTarget = normalizeWorkspaceTabTarget(
    preferredTarget,
  );
  final preferredTabId = normalizedPreferredTarget == null
      ? null
      : derivedTabs
                .where(
                  (tab) => workspaceTabTargetsEqual(
                    tab.descriptor.target,
                    normalizedPreferredTarget,
                  ),
                )
                .firstOrNull
                ?.descriptor
                .tabId ??
            buildDeterministicWorkspaceTabId(normalizedPreferredTarget);
  final activeTabId =
      preferredTabId != null && openTabIds.contains(preferredTabId)
      ? preferredTabId
      : resolvedFocusedTabId != null &&
            openTabIds.contains(resolvedFocusedTabId)
      ? resolvedFocusedTabId
      : derivedTabs.firstOrNull?.descriptor.tabId;
  final activeTab = activeTabId == null
      ? null
      : derivedTabs
            .where((tab) => tab.descriptor.tabId == activeTabId)
            .firstOrNull;

  return WorkspacePaneState(
    pane: resolvedPane,
    tabs: derivedTabs,
    focusedTabId: resolvedFocusedTabId,
    activeTabId: activeTabId,
    activeTab: activeTab,
  );
}

List<WorkspaceTabDescriptor> getWorkspacePaneDescriptors({
  WorkspacePaneLayout? layout,
  WorkspacePane? pane,
  String? paneId,
  required List<WorkspaceTab> tabs,
}) => deriveWorkspacePaneState(
  layout: layout,
  pane: pane,
  paneId: paneId,
  tabs: tabs,
).tabs.map((tab) => tab.descriptor).toList();

WorkspaceSideFileOpenPlacement resolveWorkspaceSideTargetPlacement({
  WorkspacePaneLayout? layout,
  String? sourcePaneId,
  required List<WorkspaceTab> tabs,
  required WorkspaceTabTarget target,
}) {
  final normalizedTarget = normalizeWorkspaceTabTarget(target);
  if (normalizedTarget == null) {
    return const WorkspaceSideFileOpenPlacement(
      WorkspaceSideFileOpenPlacementKind.openInSource,
    );
  }
  final targetTabId = buildDeterministicWorkspaceTabId(normalizedTarget);
  final targetAlreadyOpen = tabs.any(
    (tab) =>
        tab.tabId == targetTabId ||
        workspaceTabTargetsEqual(tab.target, normalizedTarget),
  );
  return resolveWorkspaceSideFileOpenPlacement(
    layout: layout,
    sourcePaneId: sourcePaneId,
    targetAlreadyOpen: targetAlreadyOpen,
  );
}

String? _trimNonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
