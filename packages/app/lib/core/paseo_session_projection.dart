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

// The sidebar row/group shapes live in `sidebar/sidebar_models.dart` so this
// library and the view models can share them without importing each other,
// and the pin-splitting and status-grouping passes are the public ports in
// `sidebar/paseo_sidebar_view_models.dart` rather than private copies here.
import 'package:coding_agent_app/sidebar/paseo_sidebar_view_models.dart'
    show buildStatusGroups, splitPinnedSidebarGroups;
import 'package:coding_agent_app/sidebar/sidebar_models.dart';

export 'package:coding_agent_app/sidebar/sidebar_models.dart';

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
  final pinnedGroups = splitPinnedSidebarGroups(
    projects: projects,
    keys: pinnedKeys,
  );
  final pinnedWorkspaceKeys = pinnedKeys.pinnedWorkspaceKeys.toSet();
  final statusGroups = groupMode == SidebarGroupMode.status
      ? buildStatusGroups([
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
