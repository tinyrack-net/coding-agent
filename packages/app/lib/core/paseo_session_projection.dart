/// Port of Paseo 0.2.0's session/sidebar *projection* rules — the pure
/// reducers that turn whatever the daemon last told us into the shape the UI
/// renders. Grouped into one library because they form a single pipeline: a
/// workspace delta lands, local archive intent suppresses it, the surviving
/// directory feeds the sidebar, and the agent statuses ride alongside.
///
/// - `contexts/session-status-tracking.ts` — which agent statuses we still
///   remember from *before* the current snapshot, so the UI can tell "was
///   running, now idle" from "has always been idle".
/// - `contexts/session-workspace-upserts.ts` — a client-local record of
///   archives this client started but the daemon has not confirmed yet, so a
///   still-in-flight upsert cannot resurrect a row the user just archived.
/// - `contexts/workspace-directory-reconciliation.ts` — replaying workspace
///   deltas that arrived while a paged directory fetch was still running, so
///   nothing received mid-fetch is lost or resurrected.
/// - `components/sidebar/sidebar-projection.ts` — one pin-aware pass that
///   produces the pinned section, the status groups, and the 1-9 keyboard
///   shortcut numbering from the *same* traversal, so the numbers a user sees
///   always match the rows in view.
///
/// Not re-ported here: the sidebar workspace *title* rule, daemon reconnect
/// detection, and resume revalidation already live in `paseo_session_rules.dart`.
library;

import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart';

// `SidebarProjectHost` is the exact Dart analogue of upstream's
// `WorkspaceStructureHostPlacement` (serverId / iconWorkingDir /
// canCreateWorktree) and is already ported, so it is reused rather than
// redeclared.
import 'package:coding_agent_app/sidebar/sidebar_project_row_model.dart'
    show SidebarProjectHost;

export 'package:coding_agent_app/sidebar/sidebar_project_row_model.dart'
    show SidebarProjectHost;

// ---------------------------------------------------------------------------
// Shared identity normalization (utils/workspace-identity.ts)
// ---------------------------------------------------------------------------

/// Upstream `trimNonEmpty`: a value that is only whitespace is indistinguishable
/// from a missing one, because both mean "no usable identity".
String? _trimNonEmpty(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Upstream `normalizeWorkspaceOpaqueId`.
String? _normalizeWorkspaceOpaqueId(String? value) => _trimNonEmpty(value);

/// Upstream `normalizeWorkspacePath`: canonicalize separators and drop trailing
/// slashes so two spellings of the same directory compare equal. The bare root
/// is special-cased because stripping its only slash would leave nothing.
String? _normalizeWorkspacePath(String? value) {
  final trimmed = _trimNonEmpty(value);
  if (trimmed == null) return null;
  final withUnixSeparators = trimmed.replaceAll(r'\', '/');
  if (withUnixSeparators == '/') return withUnixSeparators;
  final withoutTrailingSlash = withUnixSeparators.replaceAll(
    RegExp(r'/+$'),
    '',
  );
  return withoutTrailingSlash.isEmpty ? '/' : withoutTrailingSlash;
}

/// Re-applies upstream `normalizeWorkspaceDescriptor`'s *identity* canonicalization
/// to an already-decoded descriptor.
///
/// Upstream normalizes at the store boundary, converting a wire payload into a
/// store descriptor: it trims the id, canonicalizes `workspaceDirectory`, parses
/// `statusEnteredAt` into a `Date`, and clones the script list. In this repo the
/// decoding half already happened in `WorkspaceDescriptor.fromJson`, and the
/// clone is pointless because the protocol types are immutable — so only the two
/// identity fields are reproduced, and only those two are observable to the
/// reconciler below (they decide the map key and the archive-match).
///
/// The id falls back to the raw value when normalization yields nothing, because
/// a blank id is still the only handle we have on that row.
WorkspaceDescriptor _normalizeWorkspaceDescriptorIdentity(
  WorkspaceDescriptor workspace,
) {
  final id = _normalizeWorkspaceOpaqueId(workspace.id) ?? workspace.id;
  final workspaceDirectory =
      _normalizeWorkspacePath(workspace.workspaceDirectory) ?? '';
  if (id == workspace.id &&
      workspaceDirectory == workspace.workspaceDirectory) {
    // Upstream always allocates a fresh object here; returning the original when
    // nothing changed is a deliberate deviation that keeps `identical()` stable
    // for Flutter's rebuild short-circuits. No field differs, so no observable
    // value changes.
    return workspace;
  }
  return WorkspaceDescriptor(
    id: id,
    projectId: workspace.projectId,
    projectDisplayName: workspace.projectDisplayName,
    projectCustomName: workspace.projectCustomName,
    projectRootPath: workspace.projectRootPath,
    workspaceDirectory: workspaceDirectory,
    projectKind: workspace.projectKind,
    workspaceKind: workspace.workspaceKind,
    name: workspace.name,
    title: workspace.title,
    pinnedAt: workspace.pinnedAt,
    archivingAt: workspace.archivingAt,
    status: workspace.status,
    statusEnteredAt: workspace.statusEnteredAt,
    activityAt: workspace.activityAt,
    diffStat: workspace.diffStat,
    scripts: workspace.scripts,
    gitRuntime: workspace.gitRuntime,
    githubRuntime: workspace.githubRuntime,
    forge: workspace.forge,
    project: workspace.project,
  );
}

// ---------------------------------------------------------------------------
// session-status-tracking.ts
// ---------------------------------------------------------------------------

/// The two fields `reconcilePreviousAgentStatuses` reads off upstream's much
/// larger `Agent` store record.
///
/// Passing the whole agent would force this library to depend on an app-level
/// store type it otherwise has no interest in, and would obscure that the
/// reconciler is deliberately blind to everything except identity and status.
final class AgentStatusSnapshot {
  const AgentStatusSnapshot({required this.id, required this.status});

  final String id;

  /// Upstream types this as `AgentLifecycleStatus`
  /// (`initializing | idle | running | error | closed`), which has no exact
  /// Dart analogue. [AgentRunState] is the protocol enum and a strict superset
  /// (it adds `awaitingPermission`); the extra member is inert here because the
  /// reconciler only ever copies statuses, never inspects them.
  final AgentRunState status;
}

/// Carries forward the status each agent had the *last* time we looked, so a
/// caller can diff "then" against the live snapshot.
///
/// Three rules, in upstream order:
/// - an agent we already track keeps its remembered status, even though the
///   snapshot may show a newer one — that gap is exactly the signal callers want;
/// - an agent we have never seen is seeded from the snapshot, so its first
///   observation is not reported as a transition;
/// - an agent missing from the snapshot is forgotten, so a later reappearance
///   seeds fresh instead of comparing against a stale status.
///
/// A null [sessionAgents] means the session itself is gone (not merely empty),
/// which drops everything — there is no session left to be relative to.
///
/// Identity comes from `agent.id`, not the map key: upstream iterates
/// `.values()`, so a snapshot keyed by anything else still tracks by id.
///
/// Returns a fresh map; [previousStatuses] is never mutated. Iteration order is
/// previous-order-first then newly seen agents, matching JS `Map` semantics,
/// because Dart's default `Map` is equally insertion-ordered.
Map<String, AgentRunState> reconcilePreviousAgentStatuses({
  required Map<String, AgentRunState> previousStatuses,
  required Map<String, AgentStatusSnapshot>? sessionAgents,
}) {
  if (sessionAgents == null) {
    return <String, AgentRunState>{};
  }

  final nextStatuses = Map<String, AgentRunState>.of(previousStatuses);
  final seenAgentIds = <String>{};

  for (final agent in sessionAgents.values) {
    seenAgentIds.add(agent.id);
    nextStatuses.putIfAbsent(agent.id, () => agent.status);
  }

  // Upstream deletes while iterating `nextStatuses.keys()`, which JS `Map`
  // tolerates; Dart throws on concurrent modification, so the stale keys are
  // collected first. Same result, same order for the survivors.
  final staleAgentIds = [
    for (final agentId in nextStatuses.keys)
      if (!seenAgentIds.contains(agentId)) agentId,
  ];
  for (final agentId in staleAgentIds) {
    nextStatuses.remove(agentId);
  }

  return nextStatuses;
}

// ---------------------------------------------------------------------------
// session-workspace-upserts.ts
// ---------------------------------------------------------------------------

/// Process-wide record of archives this client started, keyed by server id and
/// then by a `serverId::workspaceId` composite.
///
/// Deliberately module-global, exactly as upstream: the suppression has to
/// outlive the widget that triggered the archive, because the resurrecting
/// upsert typically arrives after that widget is gone. Upstream stores a
/// `{ workspaceId }` record whose field is never read back, so the inner map
/// simply holds the normalized workspace id as its value.
final Map<String, Map<String, String>> _pendingWorkspaceArchivesByServer = {};

String _pendingArchiveKey({
  required String serverId,
  required String workspaceId,
}) => '${serverId.trim()}::${workspaceId.trim()}';

/// Records that this client asked to archive [workspaceId] on [serverId].
///
/// A blank server or workspace id is dropped rather than stored: it could never
/// match a real descriptor later, so keeping it would only leak an entry that
/// pins the server bucket alive forever.
void markWorkspaceArchivePending({
  required String serverId,
  required String workspaceId,
}) {
  final normalizedServerId = serverId.trim();
  final normalizedWorkspaceId = _normalizeWorkspaceOpaqueId(workspaceId);
  if (normalizedServerId.isEmpty || normalizedWorkspaceId == null) {
    return;
  }

  final archives = _pendingWorkspaceArchivesByServer.putIfAbsent(
    normalizedServerId,
    () => <String, String>{},
  );
  archives[_pendingArchiveKey(
        serverId: normalizedServerId,
        workspaceId: normalizedWorkspaceId,
      )] =
      normalizedWorkspaceId;
}

/// Forgets a pending archive once the daemon has confirmed it (or the attempt
/// failed and the row should come back).
///
/// The server bucket is dropped when its last archive clears so the registry
/// does not accumulate an empty map per server the user ever touched.
void clearWorkspaceArchivePending({
  required String serverId,
  required String workspaceId,
}) {
  final normalizedServerId = serverId.trim();
  final normalizedWorkspaceId = _normalizeWorkspaceOpaqueId(workspaceId);
  if (normalizedServerId.isEmpty || normalizedWorkspaceId == null) {
    return;
  }

  final archives = _pendingWorkspaceArchivesByServer[normalizedServerId];
  if (archives == null) {
    return;
  }
  archives.remove(
    _pendingArchiveKey(
      serverId: normalizedServerId,
      workspaceId: normalizedWorkspaceId,
    ),
  );
  if (archives.isEmpty) {
    _pendingWorkspaceArchivesByServer.remove(normalizedServerId);
  }
}

/// Whether this client is still waiting on the daemon to confirm an archive of
/// [workspaceId].
///
/// [workspaceId] is nullable because callers hand over a descriptor field that
/// older daemons may omit; a missing id can never match, so it answers false.
bool isWorkspaceArchivePending({
  required String serverId,
  String? workspaceId,
}) {
  final normalizedServerId = serverId.trim();
  if (normalizedServerId.isEmpty) {
    return false;
  }

  final archives = _pendingWorkspaceArchivesByServer[normalizedServerId];
  if (archives == null) {
    return false;
  }

  final normalizedWorkspaceId = _normalizeWorkspaceOpaqueId(workspaceId);
  return normalizedWorkspaceId != null &&
      archives.containsKey(
        _pendingArchiveKey(
          serverId: normalizedServerId,
          workspaceId: normalizedWorkspaceId,
        ),
      );
}

/// Whether an incoming descriptor should be swallowed because this client is
/// mid-archive on that exact workspace.
///
/// Matching is by workspace id only, never by directory: two workspaces can
/// share a checkout directory, and archiving one must not hide its sibling.
bool shouldSuppressWorkspaceForLocalArchive({
  required String serverId,
  required WorkspaceDescriptor workspace,
}) => isWorkspaceArchivePending(serverId: serverId, workspaceId: workspace.id);

// ---------------------------------------------------------------------------
// workspace-directory-reconciliation.ts
// ---------------------------------------------------------------------------

/// Folds workspace deltas that arrived mid-fetch onto the page snapshot that
/// finally landed.
///
/// A paged directory fetch is not atomic: updates keep streaming while later
/// pages are still in flight, and the snapshot they are folded into is already
/// stale by the time it arrives. Replaying the buffered deltas *after* the
/// snapshot is what makes the two consistent again.
///
/// Deltas are applied strictly in arrival order, so a remove that followed an
/// upsert wins and vice versa. An upsert for a workspace this client is
/// archiving does not merely get ignored — it *removes* the row, because the
/// snapshot it is being folded into predates the archive and would otherwise
/// leave the row on screen.
///
/// [snapshot] is copied, never mutated, and the returned map keys off the
/// normalized descriptor id.
Map<String, WorkspaceDescriptor> reconcileWorkspaceDirectory({
  required String serverId,
  required Map<String, WorkspaceDescriptor> snapshot,
  required List<WorkspaceUpdate> deltas,
}) {
  final workspaces = Map<String, WorkspaceDescriptor>.of(snapshot);
  for (final delta in deltas) {
    switch (delta) {
      case WorkspaceRemoveUpdate():
        workspaces.remove(delta.id);
      case WorkspaceUpsertUpdate():
        final workspace = _normalizeWorkspaceDescriptorIdentity(
          delta.workspace,
        );
        if (shouldSuppressWorkspaceForLocalArchive(
          serverId: serverId,
          workspace: workspace,
        )) {
          workspaces.remove(workspace.id);
        } else {
          workspaces[workspace.id] = workspace;
        }
    }
  }
  return workspaces;
}

// ---------------------------------------------------------------------------
// sidebar-projection.ts (and the three helpers it composes)
// ---------------------------------------------------------------------------

/// Sort that keeps equal elements in their original relative order.
///
/// JavaScript's `Array.prototype.sort` has been stable since ES2019 and every
/// comparator below leans on that (pinned chats with no `pinnedAt` must keep
/// project order). Dart's `List.sort` makes no stability promise, so the index
/// is folded in as a final tiebreak.
List<T> _stableSorted<T>(Iterable<T> items, int Function(T a, T b) compare) {
  final indexed = items.toList(growable: false).asMap().entries.toList();
  indexed.sort((a, b) {
    final result = compare(a.value, b.value);
    return result != 0 ? result : a.key.compareTo(b.key);
  });
  return [for (final entry in indexed) entry.value];
}

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
  SidebarWorkspaceProjectEntry _withWorkspaces(
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

/// Splits pinned chats out of the project list.
///
/// Private because `hooks/use-sidebar-pins.ts` is not in this port's cluster —
/// only [buildSidebarProjection] needs it, and publishing it here would stake a
/// claim on a module that deserves its own port.
///
/// A project whose chats were *all* hoisted is dropped rather than left as an
/// empty duplicate header; a project that was already empty is kept, because its
/// "new workspace" row is the only way to add to it.
PinnedSidebarGroups _splitPinnedSidebarGroups({
  required List<SidebarWorkspaceProjectEntry> projects,
  required PinnedSidebarKeys keys,
}) {
  if (keys.pinnedWorkspaceKeys.isEmpty) {
    // Upstream hands the caller the very same array; preserved here so
    // `identical()` still short-circuits downstream rebuilds.
    return PinnedSidebarGroups(
      pinnedChats: const [],
      unpinnedProjects: projects,
    );
  }
  final pinnedWorkspaceKeySet = keys.pinnedWorkspaceKeys.toSet();
  final pinnedChats = <SidebarWorkspacePlacement>[];
  final unpinnedProjects = <SidebarWorkspaceProjectEntry>[];

  for (final project in projects) {
    final remainingWorkspaces = <SidebarWorkspacePlacement>[];
    for (final workspace in project.workspaces) {
      if (pinnedWorkspaceKeySet.contains(workspace.workspaceKey)) {
        pinnedChats.add(workspace);
      } else {
        remainingWorkspaces.add(workspace);
      }
    }
    if (remainingWorkspaces.isEmpty && project.workspaces.isNotEmpty) {
      continue;
    }
    unpinnedProjects.add(
      remainingWorkspaces.length == project.workspaces.length
          ? project
          : project._withWorkspaces(remainingWorkspaces),
    );
  }

  // Descending by pin time. Upstream compares the raw ISO strings with
  // `localeCompare`; `compareTo` is used instead (Dart has no locale-aware
  // string compare in core) and agrees for ISO-8601, which is lexicographically
  // ordered. Keys with no recorded timestamp compare as "" and sink to the
  // bottom in their original order.
  return PinnedSidebarGroups(
    pinnedChats: _stableSorted(
      pinnedChats,
      (a, b) => (keys.pinnedAtByKey[b.workspaceKey] ?? '').compareTo(
        keys.pinnedAtByKey[a.workspaceKey] ?? '',
      ),
    ),
    unpinnedProjects: unpinnedProjects,
  );
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

/// Buckets workspaces by status and orders each bucket.
///
/// Private for the same reason as [_splitPinnedSidebarGroups]:
/// `hooks/sidebar-status-view-model.ts` is a separate module awaiting its own port.
///
/// Rows sort newest-transition-first so the thing that just changed is at the
/// top of its group; rows with no transition timestamp fall to the bottom and
/// are then ordered by project name, workspace name, and finally key, so the
/// list never reshuffles between rebuilds.
List<StatusGroup> _buildStatusGroups(
  List<SidebarWorkspaceEntry> workspaces,
  Map<String, String> projectNamesByKey,
) {
  final bucketRows = <WorkspaceStateBucket, List<SidebarWorkspaceEntry>>{};
  for (final ws in workspaces) {
    bucketRows.putIfAbsent(ws.statusBucket, () => []).add(ws);
  }

  final groups = <StatusGroup>[];
  for (final bucket in statusBucketOrder) {
    final rows = bucketRows[bucket];
    if (rows == null || rows.isEmpty) continue;
    groups.add(
      StatusGroup(
        bucket: bucket,
        label: statusBucketLabels[bucket]!,
        rows: _stableSorted(
          rows,
          (a, b) => _compareStatusRows(a, b, projectNamesByKey),
        ),
      ),
    );
  }
  return groups;
}

int _compareStatusRows(
  SidebarWorkspaceEntry a,
  SidebarWorkspaceEntry b,
  Map<String, String> projectNamesByKey,
) {
  final aTime = a.statusEnteredAt;
  final bTime = b.statusEnteredAt;

  if (aTime != null && bTime != null) {
    // Upstream returns `bTime - aTime`; only the sign matters, and `compareTo`
    // on the reversed operands has the same sign.
    final timeCmp = bTime.compareTo(aTime);
    if (timeCmp != 0) return timeCmp;
  } else if (aTime != null) {
    return -1;
  } else if (bTime != null) {
    return 1;
  }

  // `localeCompare` -> `compareTo`: Dart core has no locale-aware comparison, so
  // names differing only by locale collation (accents, case) may order
  // differently from upstream. ASCII names, the overwhelming case for repo and
  // branch names, order identically.
  final aProject = projectNamesByKey[a.projectKey] ?? '';
  final bProject = projectNamesByKey[b.projectKey] ?? '';
  final projectCmp = aProject.compareTo(bProject);
  if (projectCmp != 0) return projectCmp;

  final nameCmp = a.name.compareTo(b.name);
  if (nameCmp != 0) return nameCmp;

  return a.workspaceKey.compareTo(b.workspaceKey);
}

/// A workspace reachable by a numeric keyboard shortcut.
final class SidebarShortcutWorkspaceTarget {
  const SidebarShortcutWorkspaceTarget({
    required this.serverId,
    required this.workspaceId,
  });

  final String serverId;
  final String workspaceId;

  /// Value equality: upstream compares these as plain object literals via
  /// structural assertions and `===` field checks, never by reference.
  @override
  bool operator ==(Object other) =>
      other is SidebarShortcutWorkspaceTarget &&
      serverId == other.serverId &&
      workspaceId == other.workspaceId;

  @override
  int get hashCode => Object.hash(serverId, workspaceId);

  @override
  String toString() =>
      'SidebarShortcutWorkspaceTarget($serverId, $workspaceId)';
}

/// The shortcut assignment for one render: the ordered targets and the reverse
/// lookup a row uses to draw its own number.
final class SidebarShortcutModel {
  const SidebarShortcutModel({
    required this.shortcutTargets,
    required this.shortcutIndexByWorkspaceKey,
  });

  final List<SidebarShortcutWorkspaceTarget> shortcutTargets;

  /// `workspaceKey` -> 1-based shortcut number.
  final Map<String, int> shortcutIndexByWorkspaceKey;
}

/// One numbering-eligible run of rows. [collapsed] sections are skipped whole,
/// so numbers only ever land on rows the user can actually see.
final class SidebarShortcutSection {
  const SidebarShortcutSection({required this.workspaces, this.collapsed});

  final List<SidebarWorkspacePlacement> workspaces;

  /// Nullable rather than defaulted to `false` to mirror upstream's optional
  /// field; null and false are treated identically.
  final bool? collapsed;
}

/// Numbers visible rows 1..N in render order.
///
/// Private because `utils/sidebar-shortcuts.ts` is a separate module awaiting
/// its own port; only [buildSidebarProjection] consumes it today.
///
/// The default limit of 9 exists because the shortcut is a single digit. A
/// fractional or negative [shortcutLimit] is floored and clamped at zero, matching
/// upstream's `Math.max(0, Math.floor(...))`, so a bad limit disables shortcuts
/// rather than throwing.
SidebarShortcutModel _buildSidebarShortcutSections({
  required List<SidebarShortcutSection> sections,
  num? shortcutLimit,
}) {
  final maxShortcuts = math.max(0, (shortcutLimit ?? 9).floor());
  final shortcutTargets = <SidebarShortcutWorkspaceTarget>[];
  final shortcutIndexByWorkspaceKey = <String, int>{};

  for (final section in sections) {
    if (section.collapsed ?? false) {
      continue;
    }
    for (final workspace in section.workspaces) {
      if (shortcutTargets.length >= maxShortcuts) {
        break;
      }
      final shortcutNumber = shortcutTargets.length + 1;
      shortcutTargets.add(
        SidebarShortcutWorkspaceTarget(
          serverId: workspace.serverId,
          workspaceId: workspace.workspaceId,
        ),
      );
      shortcutIndexByWorkspaceKey[workspace.workspaceKey] = shortcutNumber;
    }
  }

  return SidebarShortcutModel(
    shortcutTargets: shortcutTargets,
    shortcutIndexByWorkspaceKey: shortcutIndexByWorkspaceKey,
  );
}

/// How the sidebar groups its rows. Upstream's `SidebarGroupMode` union
/// (`"project" | "status"`) from `stores/sidebar-view-store.ts`.
enum SidebarGroupMode { project, status }

/// Everything one sidebar render needs, derived in a single pass.
final class SidebarProjection {
  const SidebarProjection({
    required this.pinnedGroups,
    required this.statusGroups,
    required this.shortcutModel,
  });

  final PinnedSidebarGroups pinnedGroups;

  /// Empty in [SidebarGroupMode.project]; the sidebar renders
  /// [PinnedSidebarGroups.unpinnedProjects] instead.
  final List<StatusGroup> statusGroups;

  final SidebarShortcutModel shortcutModel;
}

/// Projects the sidebar's rows, groups, and keyboard shortcut numbering
/// together.
///
/// The reason this is one function rather than three hooks: the shortcut
/// numbers must be derived from the *same* pin-aware traversal that produced the
/// rows. Computing them separately let the two drift, so a user pressing `2` hit
/// a different row than the one labelled `2`.
///
/// Pinned chats always number first, and are skipped entirely when the pinned
/// section is collapsed. In status mode the pinned rows are also removed from
/// their status group, so a pinned workspace appears exactly once.
SidebarProjection buildSidebarProjection({
  required List<SidebarWorkspaceProjectEntry> projects,
  required PinnedSidebarKeys pinnedKeys,
  required Map<String, SidebarWorkspaceEntry> workspaceEntriesByKey,
  required Map<String, String> projectNamesByKey,
  required SidebarGroupMode groupMode,
  required bool pinnedCollapsed,
  required Set<String> collapsedProjectKeys,
  required Set<String> collapsedStatusGroupKeys,
}) {
  final pinnedGroups = _splitPinnedSidebarGroups(
    projects: projects,
    keys: pinnedKeys,
  );
  final pinnedWorkspaceKeys = pinnedKeys.pinnedWorkspaceKeys.toSet();
  final statusGroups = groupMode == SidebarGroupMode.status
      ? _buildStatusGroups([
          // Insertion-ordered, matching JS `Map.values()`.
          for (final workspace in workspaceEntriesByKey.values)
            if (!pinnedWorkspaceKeys.contains(workspace.workspaceKey))
              workspace,
        ], projectNamesByKey)
      : <StatusGroup>[];

  final sections = <SidebarShortcutSection>[];
  if (!pinnedCollapsed) {
    sections.add(SidebarShortcutSection(workspaces: pinnedGroups.pinnedChats));
  }
  if (groupMode == SidebarGroupMode.status) {
    sections.addAll(
      statusGroups.map(
        (group) => SidebarShortcutSection(
          workspaces: group.rows,
          collapsed: collapsedStatusGroupKeys.contains(group.bucket.wireName),
        ),
      ),
    );
  } else {
    sections.addAll(
      pinnedGroups.unpinnedProjects.map(
        (project) => SidebarShortcutSection(
          workspaces: project.workspaces,
          collapsed: collapsedProjectKeys.contains(project.projectKey),
        ),
      ),
    );
  }

  return SidebarProjection(
    pinnedGroups: pinnedGroups,
    statusGroups: statusGroups,
    shortcutModel: _buildSidebarShortcutSections(sections: sections),
  );
}
