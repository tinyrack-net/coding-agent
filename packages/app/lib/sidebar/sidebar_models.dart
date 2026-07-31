/// The sidebar's shared data shapes, extracted so that both the projection
/// pipeline in `core/paseo_session_projection.dart` and the view models in
/// `sidebar/paseo_sidebar_view_models.dart` can name them without importing
/// each other.
///
/// These are ports of the record shapes upstream declares inline across
/// `components/sidebar/sidebar-projection.ts`, `hooks/use-sidebar-pins.ts`,
/// and `hooks/sidebar-status-view-model.ts`.
library;

import 'package:agent_protocol/agent_protocol.dart'
    show WorkspaceKind, WorkspaceProjectKind, WorkspaceStateBucket;

import 'sidebar_project_row_model.dart' show SidebarProjectHost;

export 'sidebar_project_row_model.dart' show SidebarProjectHost;

/// Where a workspace row sits in the sidebar tree, independent of anything it
/// renders. This is the unit the shortcut numbering walks.
final class SidebarWorkspacePlacement {
  const SidebarWorkspacePlacement({
    required this.workspaceKey,
    required this.serverId,
    required this.workspaceId,
    required this.projectKey,
    required this.projectName,
    required this.projectKind,
    required this.workspaceKind,
    required this.name,
  });

  /// Sidebar-wide unique key (`serverId:workspaceId` upstream). Distinct from
  /// [workspaceId], which is only unique within one host.
  final String workspaceKey;
  final String serverId;
  final String workspaceId;
  final String projectKey;
  final String projectName;
  final WorkspaceProjectKind projectKind;
  final WorkspaceKind workspaceKind;
  final String name;
}

/// A placement plus the status facts the status-grouped sidebar sorts on.
///
/// Upstream's `SidebarWorkspaceEntry` also carries purely presentational fields
/// (`title`, `currentBranch`, `diffStat`, `prHint`, `scripts`, the archive
/// warning counters). None are read by any rule in this library, so they are
/// left out until the row-rendering port needs them; adding them here would
/// force this library to depend on types it never inspects.
final class SidebarWorkspaceEntry extends SidebarWorkspacePlacement {
  const SidebarWorkspaceEntry({
    required super.workspaceKey,
    required super.serverId,
    required super.workspaceId,
    required super.projectKey,
    required super.projectName,
    required super.projectKind,
    required super.workspaceKind,
    required super.name,
    required this.statusBucket,
    this.statusEnteredAt,
  });

  final WorkspaceStateBucket statusBucket;

  /// When the workspace entered [statusBucket]; null when the daemon never told
  /// us, which sorts *after* everything that has a timestamp.
  final DateTime? statusEnteredAt;
}

/// One project section of the sidebar, holding the placements beneath it.
///
/// Named to avoid colliding with the unrelated `SidebarProjectEntry` in
/// `sidebar/sidebar_project_row_model.dart`, which models the project *row*
/// (chevron, trailing action) rather than the project's workspace list.
final class SidebarWorkspaceProjectEntry {
  const SidebarWorkspaceProjectEntry({
    required this.projectKey,
    required this.projectName,
    required this.projectKind,
    required this.iconWorkingDir,
    required this.hosts,
    required this.workspaces,
  });

  final String projectKey;
  final String projectName;
  final WorkspaceProjectKind projectKind;
  final String iconWorkingDir;
  final List<SidebarProjectHost> hosts;
  final List<SidebarWorkspacePlacement> workspaces;

  /// Upstream's `{ ...project, workspaces }` spread.
  SidebarWorkspaceProjectEntry withWorkspaces(
    List<SidebarWorkspacePlacement> nextWorkspaces,
  ) => SidebarWorkspaceProjectEntry(
    projectKey: projectKey,
    projectName: projectName,
    projectKind: projectKind,
    iconWorkingDir: iconWorkingDir,
    hosts: hosts,
    workspaces: nextWorkspaces,
  );
}

/// The persisted pin state, as keys rather than descriptors so it survives a
/// workspace briefly disappearing from the directory.
final class PinnedSidebarKeys {
  const PinnedSidebarKeys({
    required this.pinnedWorkspaceKeys,
    required this.pinnedAtByKey,
  });

  final List<String> pinnedWorkspaceKeys;

  /// `workspaceKey` -> ISO-8601 pin timestamp, used to order by recency.
  final Map<String, String> pinnedAtByKey;
}

/// The sidebar split into its dedicated Pinned section and everything below it.
final class PinnedSidebarGroups {
  const PinnedSidebarGroups({
    required this.pinnedChats,
    required this.unpinnedProjects,
  });

  /// Individually pinned chats, hoisted out of their project. Most recently
  /// pinned first.
  final List<SidebarWorkspacePlacement> pinnedChats;

  /// Everything else, with the pinned chats removed.
  final List<SidebarWorkspaceProjectEntry> unpinnedProjects;
}

/// The order status groups are rendered in: most demanding of the user first.
///
/// Spelled out explicitly rather than reusing [WorkspaceStateBucket]'s
/// declaration order, which puts `running` before `attention` and would silently
/// reorder the sidebar.
const List<WorkspaceStateBucket> statusBucketOrder = [
  WorkspaceStateBucket.needsInput,
  WorkspaceStateBucket.failed,
  WorkspaceStateBucket.attention,
  WorkspaceStateBucket.running,
  WorkspaceStateBucket.done,
];

/// User-facing group headers. `attention` reads as "Ready to review" and
/// `running` as "Working" because the wire names describe the daemon's view, not
/// the user's.
const Map<WorkspaceStateBucket, String> statusBucketLabels = {
  WorkspaceStateBucket.needsInput: 'Needs input',
  WorkspaceStateBucket.failed: 'Failed',
  WorkspaceStateBucket.attention: 'Ready to review',
  WorkspaceStateBucket.running: 'Working',
  WorkspaceStateBucket.done: 'Done',
};

/// One rendered status section. Empty buckets are never materialized, so a
/// group in this list always has rows.
final class StatusGroup {
  const StatusGroup({
    required this.bucket,
    required this.label,
    required this.rows,
  });

  final WorkspaceStateBucket bucket;
  final String label;
  final List<SidebarWorkspaceEntry> rows;
}
