/// Port of Paseo 0.2.0's four sidebar *view-model* hooks. They are grouped into
/// one library because they are the four halves of a single question the sidebar
/// asks on every render — "which rows, in what order, numbered how, with which
/// remembered form state?" — and each one is a React hook whose *pure* core is
/// the only part worth porting:
///
/// - `hooks/use-sidebar-pins.ts` — which workspaces the user pinned, and how the
///   flat project list splits into a hoisted Pinned section plus everything
///   below it.
/// - `hooks/sidebar-status-view-model.ts` — the status-grouped alternative to the
///   project-grouped list, plus the 1..9 keyboard numbering that runs across it.
/// - `hooks/use-sidebar-workspace-entries.ts` — the one cheap session-store
///   subscription a retained sidebar keeps, and the identity retention that stops
///   an unchanged row from re-rendering.
/// - `hooks/use-form-preferences.ts` — the cached create-agent form preferences a
///   composer reads, and the provider-scoped merge that writes them back.
///
/// ## React hooks in a Dart port
///
/// A hook is two things fused: a pure derivation, and a `useRef`/`useMemo` cell
/// that remembers the previous derivation so an unchanged result keeps its
/// identity and short-circuits the re-render. Dart has the pure half for free;
/// the remembering half is spelled here as a small mutable *retainer* object
/// (`PinnedSidebarKeysRetainer`, `SidebarWorkspaceEntriesRetainer`,
/// `FormPreferencesController`), matching the
/// `WorkspaceAgentActivityIndexController` precedent already in this directory.
/// Callers own the retainer's lifetime exactly as a component owns its refs.
///
/// ## Relationship to `core/paseo_session_projection.dart`
///
/// That library inlines *private* copies of `splitPinnedSidebarGroups` and
/// `buildStatusGroups` because it needed them before this cluster was ported.
/// Its public data types are the ones this library reuses and re-exports, so
/// there is exactly one `SidebarWorkspaceEntry` in the tree; its private
/// functions are superseded by the public ones here and can be collapsed onto
/// them in a follow-up.
///
/// ## Clocks
///
/// Nothing here reads a clock. Every timestamp is data that arrived from the
/// daemon (`statusEnteredAt`, `pinnedAt`), so ordering is a pure function of the
/// inputs and tests need no time control.
library;

import 'package:agent_protocol/agent_protocol.dart'
    show WorkspaceDescriptor, WorkspaceStateBucket;
import 'package:coding_agent_app/composer/create_agent_preferences.dart';
import 'package:coding_agent_app/sidebar/sidebar_models.dart'
    show
        PinnedSidebarGroups,
        PinnedSidebarKeys,
        SidebarWorkspaceEntry,
        SidebarWorkspacePlacement,
        SidebarWorkspaceProjectEntry,
        StatusGroup,
        statusBucketLabels,
        statusBucketOrder;
import 'package:coding_agent_app/sidebar/workspace_agent_activity.dart'
    show WorkspaceAgentActivity;

// The row/group value types are already ported and public. Re-exported so a
// caller of this library never has to reach into `core/` for the types its own
// functions return.
export 'package:coding_agent_app/sidebar/sidebar_models.dart'
    show
        PinnedSidebarGroups,
        PinnedSidebarKeys,
        SidebarWorkspaceEntry,
        SidebarWorkspacePlacement,
        SidebarWorkspaceProjectEntry,
        StatusGroup,
        statusBucketLabels,
        statusBucketOrder;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Sort that keeps equal elements in their original relative order.
///
/// `Array.prototype.sort` has been stable since ES2019 and both comparators
/// below lean on it — pinned chats that share a pin timestamp (or have none)
/// must stay in project order, and status rows that tie on every field must not
/// reshuffle between frames. Dart's `List.sort` makes no stability promise, so
/// the original index is folded in as the final tiebreak.
List<T> _stableSorted<T>(Iterable<T> items, int Function(T a, T b) compare) {
  final indexed = items.toList(growable: false).asMap().entries.toList();
  indexed.sort((a, b) {
    final result = compare(a.value, b.value);
    return result != 0 ? result : a.key.compareTo(b.key);
  });
  return [for (final entry in indexed) entry.value];
}

// ---------------------------------------------------------------------------
// use-sidebar-pins.ts
// ---------------------------------------------------------------------------

/// Reads every placement's pin timestamp out of the session store's workspace
/// index, producing the key list the rest of the pin pipeline runs on.
///
/// Keys rather than descriptors, because a workspace can vanish from the
/// directory for a moment (a paged refetch, a reconnect) and the Pinned section
/// must not flicker; the key survives, the descriptor does not.
///
/// [pinnedAtByServerAndWorkspaceId] is `serverId -> workspaceId -> pinnedAt`.
/// Upstream passes `ReadonlyMap<string, ReadonlyMap<string, {pinnedAt?: string
/// | null}>>` — a structural type standing in for the store's much larger
/// workspace descriptor. `pinnedAt` is the only field it ever reads, so the
/// Dart port takes the projected string directly instead of forcing callers to
/// fabricate a descriptor. A missing server, a missing workspace, and a null
/// `pinnedAt` are all equally "not pinned", exactly as upstream's `?.` chain.
///
/// Deviation, deliberate: upstream's guard is `if (workspace?.pinnedAt)`, a
/// JavaScript *truthiness* test, so an empty-string timestamp counts as
/// unpinned. Dart has no truthiness, so the emptiness check is written out. This
/// matters — a daemon that serialises "never pinned" as `""` rather than `null`
/// must not light up the Pinned section.
///
/// Traversal is project order then workspace order, which is the order the
/// sidebar itself renders, so keys that tie on pin time keep the order the user
/// already sees.
PinnedSidebarKeys buildPinnedSidebarKeys({
  required List<SidebarWorkspaceProjectEntry> projects,
  required Map<String, Map<String, String?>> pinnedAtByServerAndWorkspaceId,
}) {
  final pinnedWorkspaceKeys = <String>[];
  final pinnedAtByKey = <String, String>{};

  for (final project in projects) {
    for (final placement in project.workspaces) {
      final pinnedAt =
          pinnedAtByServerAndWorkspaceId[placement.serverId]?[placement
              .workspaceId];
      if (pinnedAt == null || pinnedAt.isEmpty) continue;
      pinnedWorkspaceKeys.add(placement.workspaceKey);
      pinnedAtByKey[placement.workspaceKey] = pinnedAt;
    }
  }

  return PinnedSidebarKeys(
    pinnedWorkspaceKeys: pinnedWorkspaceKeys,
    pinnedAtByKey: pinnedAtByKey,
  );
}

/// Whether two pin snapshots would render identically.
///
/// This is the equality that lets [PinnedSidebarKeysRetainer] hand back the
/// previous instance: the session store republishes its workspace index on every
/// high-frequency field change (diff stats, script lifecycles, agent activity),
/// and none of that moves a pin. Comparing here is what stops each of those
/// from resorting and re-rendering the whole Pinned section.
///
/// Order-sensitive on purpose — the key list *is* the render order, so two
/// snapshots holding the same set in a different order are genuinely different.
///
/// Deviation, faithful to a quirk: upstream guards the timestamp comparison with
/// `(workspaceKey && ...)`, so a falsy key — in practice the empty string —
/// compares by position only and its `pinnedAt` change goes unnoticed. That is
/// almost certainly an artifact of appeasing `noUncheckedIndexedAccess` rather
/// than an intent, but it is observable, so it is reproduced rather than
/// silently fixed. An empty `workspaceKey` cannot occur for a real placement
/// (`serverId:workspaceId` always contains the separator).
bool arePinnedSidebarKeysEqual(
  PinnedSidebarKeys left,
  PinnedSidebarKeys right,
) {
  if (left.pinnedWorkspaceKeys.length != right.pinnedWorkspaceKeys.length) {
    return false;
  }
  for (var index = 0; index < left.pinnedWorkspaceKeys.length; index += 1) {
    final workspaceKey = left.pinnedWorkspaceKeys[index];
    if (workspaceKey != right.pinnedWorkspaceKeys[index] ||
        (workspaceKey.isNotEmpty &&
            left.pinnedAtByKey[workspaceKey] !=
                right.pinnedAtByKey[workspaceKey])) {
      return false;
    }
  }
  return true;
}

/// The `useRef` half of upstream's `usePinnedSidebarKeys`: remembers the last
/// snapshot and hands the very same instance back when nothing that matters
/// moved.
///
/// Kept as an explicit object rather than folded into [buildPinnedSidebarKeys]
/// so the derivation stays pure and testable, and so a caller that does not care
/// about identity (a one-shot projection, a test) can skip the retention
/// entirely.
final class PinnedSidebarKeysRetainer {
  PinnedSidebarKeys _current = const PinnedSidebarKeys(
    pinnedWorkspaceKeys: [],
    pinnedAtByKey: {},
  );

  /// The snapshot last returned by [update]; the empty snapshot before the first
  /// call, matching upstream's initial ref value.
  PinnedSidebarKeys get current => _current;

  /// Rebuilds the snapshot and returns [current] unchanged when
  /// [arePinnedSidebarKeysEqual] says the rebuild was a no-op.
  PinnedSidebarKeys update({
    required List<SidebarWorkspaceProjectEntry> projects,
    required Map<String, Map<String, String?>> pinnedAtByServerAndWorkspaceId,
  }) {
    final next = buildPinnedSidebarKeys(
      projects: projects,
      pinnedAtByServerAndWorkspaceId: pinnedAtByServerAndWorkspaceId,
    );
    if (arePinnedSidebarKeysEqual(_current, next)) {
      return _current;
    }
    _current = next;
    return next;
  }
}

/// Splits the sidebar into its dedicated Pinned section and the regular list
/// below, ordering pinned chats most-recently-pinned first.
///
/// The public port of the helper that
/// `core/paseo_session_projection.dart` currently inlines privately.
///
/// A project whose chats were *all* hoisted is dropped rather than left behind
/// as an empty duplicate header. A project that was already empty is kept,
/// because its "new workspace" row is the only way to add anything to it — that
/// asymmetry is the whole reason the emptiness test looks at both lists.
///
/// Deviations:
/// - Upstream returns the caller's own `projects` array untouched when nothing
///   is pinned; preserved here so `identical()` still short-circuits downstream
///   rebuilds.
/// - Upstream orders by `localeCompare` on the raw ISO strings. Dart core has no
///   locale-aware string comparison, so [String.compareTo] is used; ISO-8601
///   with a fixed offset is lexicographically ordered, so the two agree. Mixed
///   offsets ("…+09:00" vs "…Z") would not compare chronologically under either
///   implementation, so no behavior is lost.
/// - A pinned key with no recorded timestamp compares as `""` and sinks to the
///   bottom of the Pinned section in project order, which requires a stable
///   sort — see [_stableSorted].
PinnedSidebarGroups splitPinnedSidebarGroups({
  required List<SidebarWorkspaceProjectEntry> projects,
  required PinnedSidebarKeys keys,
}) {
  if (keys.pinnedWorkspaceKeys.isEmpty) {
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
          // Upstream's `{ ...project, workspaces }` spread. Written out because
          // the equivalent private copy-helper lives in another library.
          : SidebarWorkspaceProjectEntry(
              projectKey: project.projectKey,
              projectName: project.projectName,
              projectKind: project.projectKind,
              iconWorkingDir: project.iconWorkingDir,
              hosts: project.hosts,
              workspaces: remainingWorkspaces,
            ),
    );
  }

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

// ---------------------------------------------------------------------------
// sidebar-status-view-model.ts
// ---------------------------------------------------------------------------

/// How many rows the status sidebar can reach by keyboard.
///
/// Nine because the shortcut is a single digit; upstream spells the same bound
/// inline as `shortcutNumber > 9`.
const int statusShortcutLimit = 9;

/// Buckets workspaces by status and orders each bucket for display.
///
/// The public port of the helper that
/// `core/paseo_session_projection.dart` currently inlines privately.
///
/// Groups come out in [statusBucketOrder] — most demanding of the user first —
/// and empty buckets are never materialized, so every group in the result has
/// rows and the caller never has to test for that.
///
/// Within a bucket rows sort newest-transition-first, so whatever just changed
/// sits at the top of its group. Rows the daemon never gave a transition time
/// fall to the bottom; they then order by project name, workspace name, and
/// finally workspace key, which is what keeps the list from reshuffling between
/// frames when several rows tie.
///
/// [projectNamesByKey] is passed in rather than read off the rows because the
/// display name is a *project* fact (it can be user-customised) and several rows
/// share it; a row's own `projectName` is the snapshot from when the row was
/// built and can lag a rename.
///
/// Deviation: upstream sorts each bucket's array in place and hands that same
/// array to the group, so the caller's input array is mutated. This port sorts
/// into a fresh list. No observable difference for any caller — upstream's
/// `bucketRows` arrays are private to the function — and it keeps the input
/// safe to reuse.
List<StatusGroup> buildStatusGroups(
  List<SidebarWorkspaceEntry> workspaces,
  Map<String, String> projectNamesByKey,
) {
  final bucketRows = <WorkspaceStateBucket, List<SidebarWorkspaceEntry>>{};
  for (final workspace in workspaces) {
    bucketRows.putIfAbsent(workspace.statusBucket, () => []).add(workspace);
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

/// Deviations from upstream's comparator, both forced by the language:
/// - `bTime - aTime` becomes `bTime.compareTo(aTime)`. Only the sign is ever
///   read, and reversing the operands gives the same sign without overflowing on
///   far-apart dates.
/// - `localeCompare` becomes [String.compareTo]. Dart core has no locale-aware
///   comparison, so names that differ only by collation (accents, case) can order
///   differently from upstream. ASCII names — overwhelmingly what repository,
///   branch and workspace names are — order identically.
int _compareStatusRows(
  SidebarWorkspaceEntry a,
  SidebarWorkspaceEntry b,
  Map<String, String> projectNamesByKey,
) {
  final aTime = a.statusEnteredAt;
  final bTime = b.statusEnteredAt;

  if (aTime != null && bTime != null) {
    final timeCmp = bTime.compareTo(aTime);
    if (timeCmp != 0) return timeCmp;
  } else if (aTime != null) {
    return -1;
  } else if (bTime != null) {
    return 1;
  }

  final aProject = projectNamesByKey[a.projectKey] ?? '';
  final bProject = projectNamesByKey[b.projectKey] ?? '';
  final projectCmp = aProject.compareTo(bProject);
  if (projectCmp != 0) return projectCmp;

  final nameCmp = a.name.compareTo(b.name);
  if (nameCmp != 0) return nameCmp;

  return a.workspaceKey.compareTo(b.workspaceKey);
}

/// Numbers the first [statusShortcutLimit] rows of the status-grouped sidebar,
/// walking groups then rows so the numbers match top-to-bottom reading order.
///
/// Derived from the already-built [groups] rather than from the raw workspace
/// list, because the number a user presses has to address the row they can see;
/// deriving it from anything but the rendered order is how `2` ends up selecting
/// something other than the row labelled `2`.
///
/// Unlike the project-mode numbering in
/// `core/paseo_session_projection.dart` (upstream `utils/sidebar-shortcuts.ts`),
/// this one has no notion of a collapsed group — status groups were not
/// collapsible when this hook was frozen, so a collapsed group's rows would
/// still consume numbers. Reproduced as-is.
///
/// Two rows sharing a `workspaceKey` cannot happen for real placements; if it
/// did, upstream's later `set` would win the map entry while the earlier row
/// still consumed a number. Reproduced.
Map<String, int> buildStatusShortcutIndex(List<StatusGroup> groups) {
  final index = <String, int>{};
  var shortcutNumber = 1;
  for (final group in groups) {
    for (final row in group.rows) {
      if (shortcutNumber > statusShortcutLimit) return index;
      index[row.workspaceKey] = shortcutNumber;
      shortcutNumber += 1;
    }
  }
  return index;
}

// ---------------------------------------------------------------------------
// use-sidebar-workspace-entries.ts
// ---------------------------------------------------------------------------

/// The two session-store indexes a sidebar row is built from, without the host
/// identity.
///
/// Upstream declares this structurally (`{workspaces, workspaceAgentActivity}`)
/// so any store slice satisfies it; Dart has no structural typing, so it becomes
/// a named type that [SidebarWorkspaceSession] extends.
class SidebarWorkspaceSessionSource {
  const SidebarWorkspaceSessionSource({
    required this.workspaces,
    required this.workspaceAgentActivity,
  });

  /// Workspace descriptors for one host, keyed by workspace id.
  final Map<String, WorkspaceDescriptor> workspaces;

  /// Latest root-agent activity per workspace id, the overlay that turns a
  /// "done" workspace whose agent is still working back into a running row.
  final Map<String, WorkspaceAgentActivity> workspaceAgentActivity;
}

/// One host's session slice, tagged with the host it came from.
final class SidebarWorkspaceSession extends SidebarWorkspaceSessionSource {
  const SidebarWorkspaceSession({
    required this.serverId,
    required super.workspaces,
    required super.workspaceAgentActivity,
  });

  final String serverId;
}

/// The distinct hosts a set of placements spans, first-seen order preserved.
///
/// This is the subscription key: the sidebar watches exactly these hosts and no
/// others. Upstream spells it `Array.from(new Set(...))`; a Dart set literal is
/// insertion-ordered, so the two agree.
List<String> sidebarPlacementServerIds(
  List<SidebarWorkspacePlacement> placements,
) => <String>{for (final placement in placements) placement.serverId}.toList();

/// Narrows the whole session map down to the slices the sidebar actually needs.
///
/// The point of this projection is *not* to save the copy — it is that the
/// result compares cheaply by reference under
/// [areSidebarWorkspaceSessionsEqual], so a store update that touched anything
/// other than these two indexes cannot wake the sidebar. Collection ownership is
/// deliberate: one retained sidebar keeps one subscription to structurally
/// shared indexes, never one subscription per mounted row.
///
/// Output order follows [serverIds], not the map's own order, and hosts missing
/// from [sessions] are skipped rather than yielding a hole — a host can be
/// referenced by a placement before its session has connected. A repeated entry
/// in [serverIds] yields a repeated slice, matching upstream's plain loop.
///
/// [sessions] is typed with a nullable value to mirror TypeScript's
/// `Record<string, T | undefined>`, where a present-but-undefined entry and an
/// absent one behave identically.
List<SidebarWorkspaceSession> selectSidebarWorkspaceSessions(
  Map<String, SidebarWorkspaceSessionSource?> sessions,
  List<String> serverIds,
) {
  final selected = <SidebarWorkspaceSession>[];
  for (final serverId in serverIds) {
    final session = sessions[serverId];
    if (session == null) continue;
    selected.add(
      SidebarWorkspaceSession(
        serverId: serverId,
        workspaces: session.workspaces,
        workspaceAgentActivity: session.workspaceAgentActivity,
      ),
    );
  }
  return selected;
}

/// Whether two selections point at the very same indexes, by reference.
///
/// Reference equality is the entire mechanism: the session store replaces an
/// index object only when its contents actually changed, so `identical` answers
/// "did anything the sidebar cares about move?" in constant time regardless of
/// how many workspaces there are. Deep-comparing here would defeat the purpose.
///
/// The lists themselves are freshly allocated by every
/// [selectSidebarWorkspaceSessions] call and are never identical; only their
/// contents are compared.
///
/// Deviation: upstream additionally guards against `undefined` elements, which
/// only a sparse array could produce; a Dart `List` cannot be sparse, so that
/// branch is dropped as unreachable.
bool areSidebarWorkspaceSessionsEqual(
  List<SidebarWorkspaceSession> left,
  List<SidebarWorkspaceSession> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    final leftSession = left[index];
    final rightSession = right[index];
    if (leftSession.serverId != rightSession.serverId ||
        !identical(leftSession.workspaces, rightSession.workspaces) ||
        !identical(
          leftSession.workspaceAgentActivity,
          rightSession.workspaceAgentActivity,
        )) {
      return false;
    }
  }
  return true;
}

/// Builds the sidebar's workspace entries, given the previous build so unchanged
/// rows can keep their identity.
///
/// Injected rather than imported because the builder itself
/// (`buildSidebarWorkspaceEntries` in upstream's `sidebar-workspaces-view-model.ts`)
/// is a different module and not part of this cluster. Injecting it also lets the
/// caller close over the pending-create-attempt map that upstream threads through
/// as a fourth argument, keeping that store dependency out of this library.
typedef SidebarWorkspaceEntriesBuilder =
    Map<String, SidebarWorkspaceEntry> Function({
      required List<SidebarWorkspacePlacement> placements,
      required List<SidebarWorkspaceSession> sessions,
      required Map<String, SidebarWorkspaceEntry> previousEntries,
    });

/// The `useMemo`/`useRef` body of upstream's `useSidebarWorkspaceEntries`.
///
/// Three behaviors live here, and all three are about *not* doing work:
/// - a disabled sidebar (off-screen, collapsed) returns whatever it last had and
///   never calls the builder, so navigating away costs nothing and navigating
///   back paints the previous rows immediately instead of flashing empty;
/// - no placements or no connected sessions collapses to a shared empty map, so
///   the empty case is reference-stable across frames;
/// - otherwise the previous map is handed to the builder, which reuses any entry
///   that did not change so per-row rebuilds stay proportional to what moved.
///
/// Note the asymmetry between the first two: disabled *retains*, empty *clears*.
/// That is upstream's behavior and it is load-bearing — "I am not looking" must
/// not be confused with "there is nothing to look at".
final class SidebarWorkspaceEntriesRetainer {
  SidebarWorkspaceEntriesRetainer({required this.buildEntries});

  final SidebarWorkspaceEntriesBuilder buildEntries;

  /// Canonicalized so consecutive empty results are `identical`, matching
  /// upstream's module-level `EMPTY_ENTRIES` singleton.
  static const Map<String, SidebarWorkspaceEntry> _emptyEntries = {};

  Map<String, SidebarWorkspaceEntry> _current = _emptyEntries;

  /// The map last returned by [update]; empty before the first call.
  Map<String, SidebarWorkspaceEntry> get current => _current;

  Map<String, SidebarWorkspaceEntry> update({
    required List<SidebarWorkspacePlacement> placements,
    required List<SidebarWorkspaceSession> sessions,
    bool enabled = true,
  }) {
    if (!enabled) {
      return _current;
    }
    if (placements.isEmpty || sessions.isEmpty) {
      _current = _emptyEntries;
      return _current;
    }
    _current = buildEntries(
      placements: placements,
      sessions: sessions,
      previousEntries: _current,
    );
    return _current;
  }
}

// ---------------------------------------------------------------------------
// use-form-preferences.ts
// ---------------------------------------------------------------------------

/// What the composer shows before anything has loaded, and what it falls back to
/// if loading fails: every field unset.
///
/// Upstream's `DEFAULT_FORM_PREFERENCES` is `{}` — the schema makes every field
/// optional precisely so "we have not loaded yet" and "the user has expressed no
/// preference" are the same value and no screen needs a loading branch.
const CreateAgentPreferences defaultFormPreferences = CreateAgentPreferences();

/// A partial update to one provider's remembered form state.
///
/// Upstream types this as `Partial<ProviderPreferences>`, where the distinction
/// that matters is *absent* versus *present*: an absent field leaves the stored
/// value alone, a present one replaces (for scalars) or merges into (for the two
/// maps) it. Dart's `null` carries exactly that "absent" meaning here, which is
/// lossless because upstream has no way to express "clear this field" either —
/// its own guard is `if (updates.model !== undefined)`.
final class ProviderPreferenceUpdates {
  const ProviderPreferenceUpdates({
    this.model,
    this.mode,
    this.thinkingByModel,
    this.featureValues,
  });

  final String? model;
  final String? mode;

  /// Merged key-by-key into the stored map, so recording a thinking level for
  /// one model never forgets the levels chosen for the others.
  final Map<String, String>? thinkingByModel;

  /// Merged key-by-key, same reasoning as [thinkingByModel].
  final Map<String, Object?>? featureValues;
}

/// Applies [updates] to one provider's slice and marks that provider as the
/// current one.
///
/// Selecting a model for a provider is also how a user selects the provider, so
/// the two are written together — splitting them let the form show provider A's
/// model under provider B after a reload.
///
/// Reuses the already-ported `CreateAgentPreferences.mergeProvider` /
/// `ProviderCreateAgentPreferences.copyWith`, whose semantics match upstream's
/// `applyProviderPreferenceUpdates` exactly: scalars replace when present, the
/// two maps merge when present, everything absent is left alone, and unrelated
/// top-level preferences (favorites, isolation) ride through untouched.
CreateAgentPreferences mergeProviderPreferences({
  required CreateAgentPreferences preferences,
  required String provider,
  required ProviderPreferenceUpdates updates,
}) => preferences.mergeProvider(
  provider,
  (current) => current.copyWith(
    model: updates.model,
    mode: updates.mode,
    thinkingByModel: updates.thinkingByModel,
    featureValues: updates.featureValues,
  ),
);

/// What `useFormPreferences` hands its caller on one render.
final class FormPreferencesSnapshot {
  const FormPreferencesSnapshot({
    required this.preferences,
    required this.isLoading,
  });

  /// Never null: [defaultFormPreferences] stands in until the real value lands.
  final CreateAgentPreferences preferences;

  /// True only while the very first read is in flight. Writes never set it, so a
  /// form does not blank out mid-edit while a preference is being persisted.
  final bool isLoading;
}

/// The cache half of upstream's `useFormPreferences`.
///
/// Upstream leans on TanStack Query with `staleTime: Infinity, gcTime: Infinity`
/// — which is a long way of saying "read once per process, then hold it
/// forever". Preferences only ever change through [updatePreferences] in this
/// same process, so there is nothing a refetch could discover; the infinite
/// times exist to stop React Query from refetching on every mount and making the
/// composer flicker. This controller is that intent stated directly.
///
/// Deviations:
/// - React Query's retry policy is not modelled. A failed read settles
///   immediately as "not loading, default preferences", which is where upstream
///   lands once its retries are exhausted; only the interval in between differs,
///   and nothing reads `isError`.
/// - Upstream's `setQueryData` write and a still-in-flight read can race, with
///   the read's older value landing last. Reproduced rather than fixed: the
///   underlying `CreateAgentPreferencesService` serialises its own writes and
///   re-seeds its load cache, so the window is the same one upstream has.
final class FormPreferencesController {
  FormPreferencesController({required this.service, this.onChanged});

  /// Injected rather than reached for globally so a test (or a second composer)
  /// can drive its own storage; upstream's singleton
  /// `createAgentPreferencesService` is one valid argument, not a hard-wired
  /// dependency.
  final CreateAgentPreferencesService service;

  /// Called after every change to [snapshot]. Stands in for React's re-render;
  /// a Flutter caller typically forwards it to `setState` or a notifier.
  final void Function()? onChanged;

  CreateAgentPreferences? _data;
  bool _isPending = true;
  Future<void>? _loadOperation;

  FormPreferencesSnapshot get snapshot => FormPreferencesSnapshot(
    preferences: _data ?? defaultFormPreferences,
    isLoading: _isPending,
  );

  /// The mount-time read. Idempotent — the second and later calls return the
  /// first call's future, which is what `staleTime: Infinity` buys upstream.
  Future<void> ensureLoaded() => _loadOperation ??= _load();

  Future<void> _load() async {
    try {
      _data = await service.load();
    } catch (_) {
      // Swallowed deliberately: the caller has no recovery to offer and the
      // default preferences are a usable form. See the class doc.
    }
    _isPending = false;
    onChanged?.call();
  }

  /// Persists a change and publishes the stored result.
  ///
  /// The service is the source of truth for what actually got written (it
  /// re-parses and can drop fields), so the snapshot takes the service's return
  /// value rather than the locally computed one — upstream's
  /// `setQueryData(key, next)` does the same with the value `update()` resolved
  /// to.
  ///
  /// Resolves the loading state too, mirroring `setQueryData` on a still-pending
  /// query: there is data now, so nothing is waiting on the first read anymore.
  Future<void> updatePreferences(
    CreateAgentPreferences Function(CreateAgentPreferences current) update,
  ) async {
    final next = await service.update(update);
    _data = next;
    _isPending = false;
    onChanged?.call();
  }
}
