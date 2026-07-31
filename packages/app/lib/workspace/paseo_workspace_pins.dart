/// Port of six small frozen Paseo 0.2.0 modules that together answer "what is
/// the user looking at, and what can they launch from the tab strip":
///
/// - `screens/workspace/visible-agent-ids.ts` — which agents are on screen right
///   now, so the replica sync layer can subscribe to exactly those and no more.
/// - `screens/workspace/workspace-tab-model.ts` — the paneless facade a single
///   tab strip renders from.
/// - `workspace-pins/target.ts` — the identity and toggle rules for the pinned
///   "new tab" launchers.
/// - `workspace-pins/run.ts` — dispatching a pinned launcher to the host.
/// - `workspace/project-workspace-archive.ts` — which of a project's workspaces
///   may be archived, prompting once per risky worktree.
/// - `stores/last-workspace-selection.ts` — the remembered workspace route,
///   as a storage-injected store with hydration-race handling.
///
/// They live in one library because each is a handful of pure functions with no
/// natural home of its own, and because the first two both lean on the already
/// ported `workspace_pane_state.dart`.
///
/// ## What this library deliberately does *not* re-implement
///
/// - Tab targets, target normalization, target equality and deterministic tab
///   ids (upstream `workspace-tabs/model.ts` + `workspace-tabs/identity.ts`) are
///   already in `workspace/workspace_tab_model.dart` and are reused as-is. Note
///   that despite the matching file name, that module is *not* upstream's
///   `screens/workspace/workspace-tab-model.ts` — that facade is ported here.
/// - Pane derivation (upstream `screens/workspace/workspace-pane-state.ts`) is
///   already in `workspace/workspace_pane_state.dart`.
/// - The pane tree and `collectAllPanes` (upstream `stores/workspace-layout-
///   store.ts`) are already in `workspace/workspace_pane_layout.dart`, where
///   `collectAllPanes` is spelled `collectWorkspacePanes`.
/// - The worktree archive risk model and its confirmation copy (upstream
///   `git/worktree-archive-warning.ts`) are already in
///   `git/paseo_pr_rules.dart`; [selectProjectWorkspacesToArchive] reuses
///   [WorktreeArchiveRisk], [WorktreeArchiveConfirmationInput] and
///   [toWorktreeArchiveRisk] rather than restating them.
/// - Parsing/encoding the persisted workspace selection is already in
///   `state/last_workspace_route_selection.dart`; [LastWorkspaceSelectionStore]
///   reuses [parseLastWorkspaceRouteSelection] and
///   [encodeLastWorkspaceRouteSelection] so the Riverpod notifier and this pure
///   store can never disagree about the payload shape.
library;

import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart'
    show TerminalProfile, WorkspaceKind;

import '../core/host_routes.dart' show HostWorkspaceRoute;
import '../git/paseo_pr_rules.dart'
    show
        WorktreeArchiveConfirmationInput,
        WorktreeArchiveDiffStat,
        WorktreeArchiveRisk,
        toWorktreeArchiveRisk;
import '../state/last_workspace_route_selection.dart'
    show
        encodeLastWorkspaceRouteSelection,
        lastWorkspaceRouteSelectionStorageKey,
        parseLastWorkspaceRouteSelection;
import 'workspace_pane_layout.dart';
import 'workspace_pane_state.dart';
import 'workspace_tab_model.dart';

export '../git/paseo_pr_rules.dart'
    show
        WorktreeArchiveConfirmationInput,
        WorktreeArchiveDiffStat,
        WorktreeArchiveRisk;
export '../state/last_workspace_route_selection.dart'
    show lastWorkspaceRouteSelectionStorageKey;

// ---------------------------------------------------------------------------
// screens/workspace/visible-agent-ids.ts
// ---------------------------------------------------------------------------

/// The agent ids the user can actually see, sorted and deduplicated.
///
/// This is a *visibility* query, not a membership query: only the active tab of
/// each counted pane contributes, because a background tab in the same pane is
/// not rendering. The result drives which agent replicas stay subscribed, so
/// over-reporting costs bandwidth and under-reporting shows stale transcripts.
///
/// [routeFocused] false (the workspace route is not the foreground route) and a
/// null [layout] both mean "nothing is visible" — the route being blurred is
/// what lets a backgrounded workspace drop all of its subscriptions.
///
/// [focusedPaneOnly] is the compact/zen layout: only the pane named by
/// [WorkspacePaneLayout.focusedPaneId] is on screen. A null `focusedPaneId`
/// therefore matches no pane and yields an empty list — upstream's
/// `pane.id === layout?.focusedPaneId` comparison behaves identically, since a
/// pane id is always a string.
///
/// Deviation, documented: upstream dedupes with a `Set` and then calls
/// `Array.prototype.sort()` with no comparator, which compares UTF-16 code
/// units. Dart's `String.compareTo` is the same code-unit ordering, and the set
/// guarantees no two elements compare equal, so `List.sort`'s instability is
/// unobservable here.
List<String> selectVisibleAgentIds({
  required WorkspacePaneLayout? layout,
  required List<WorkspaceTab> tabs,
  required bool routeFocused,
  required bool focusedPaneOnly,
}) {
  if (!routeFocused || layout == null) {
    return [];
  }

  final allPanes = collectWorkspacePanes(layout.root);
  final panes = focusedPaneOnly
      ? allPanes.where((pane) => pane.id == layout.focusedPaneId)
      : allPanes;

  final agentIds = <String>{};
  for (final pane in panes) {
    final target = deriveWorkspacePaneState(
      pane: pane,
      tabs: tabs,
    ).activeTab?.descriptor.target;
    if (target is WorkspaceAgentTabTarget) {
      agentIds.add(target.agentId);
    }
  }

  return agentIds.toList()..sort();
}

// ---------------------------------------------------------------------------
// screens/workspace/workspace-tab-model.ts
// ---------------------------------------------------------------------------

/// The single-pane view of a workspace's tabs.
///
/// This is the shape a tab strip binds to when there is no split layout to
/// consult — a projection of [WorkspacePaneState] with the pane itself and the
/// raw focused-tab id dropped, so that callers cannot accidentally reason about
/// panes from a paneless model.
final class WorkspaceTabModel {
  const WorkspaceTabModel({
    required this.tabs,
    required this.activeTabId,
    required this.activeTab,
  });

  /// Normalized, deduplicated tabs in the order they should render.
  final List<WorkspaceDerivedTab> tabs;

  /// The tab the strip should highlight, or null when [tabs] is empty.
  final String? activeTabId;

  /// The [WorkspaceDerivedTab] named by [activeTabId], resolved once so callers
  /// do not re-scan [tabs].
  final WorkspaceDerivedTab? activeTab;
}

/// The stable id a tab for [target] would have.
///
/// A pass-through to [buildDeterministicWorkspaceTabId], kept because upstream
/// exports it under this name and screens import it from here; the indirection
/// is what lets tab identity change in one place.
String buildWorkspaceTabId(WorkspaceTabTarget target) =>
    buildDeterministicWorkspaceTabId(target);

/// Derives the paneless tab model.
///
/// [preferredTarget] is the route's opinion and outranks [focusedTabId], which
/// is local UI state that can lag a navigation. Both lose to "the tab does not
/// exist": an active id is only ever one of the surviving normalized tabs.
///
/// Delegates wholly to [deriveWorkspacePaneState] with no pane, exactly as
/// upstream does — normalization, deduplication, target-equality matching and
/// the focused/first fallback all live there.
WorkspaceTabModel deriveWorkspaceTabModel({
  required List<WorkspaceTab> tabs,
  String? focusedTabId,
  WorkspaceTabTarget? preferredTarget,
}) {
  final paneState = deriveWorkspacePaneState(
    tabs: tabs,
    focusedTabId: focusedTabId,
    preferredTarget: preferredTarget,
  );
  return WorkspaceTabModel(
    tabs: paneState.tabs,
    activeTabId: paneState.activeTabId,
    activeTab: paneState.activeTab,
  );
}

// ---------------------------------------------------------------------------
// workspace-pins/target.ts
// ---------------------------------------------------------------------------

/// A launcher the user pinned to the workspace tab strip's "+" menu.
///
/// Upstream's discriminated union becomes a sealed hierarchy so that
/// [runPinnedTabTarget] is exhaustive by construction. Value equality is added
/// (upstream relies on object identity) purely so pin lists compare cleanly in
/// tests and in widget rebuild guards — every rule below still keys off
/// [pinnedTargetKey], never off `==`, so the added equality changes nothing.
sealed class PinnedTabTarget {
  const PinnedTabTarget();

  /// The union discriminant, preserved verbatim because it is also the
  /// persisted key for every non-profile target.
  String get kind;
}

/// Start a new agent draft.
final class PinnedDraftTarget extends PinnedTabTarget {
  const PinnedDraftTarget();

  @override
  String get kind => 'draft';

  @override
  bool operator ==(Object other) => other is PinnedDraftTarget;

  @override
  int get hashCode => kind.hashCode;

  @override
  String toString() => 'PinnedDraftTarget()';
}

/// Open a terminal with the host's default shell.
final class PinnedTerminalTarget extends PinnedTabTarget {
  const PinnedTerminalTarget();

  @override
  String get kind => 'terminal';

  @override
  bool operator ==(Object other) => other is PinnedTerminalTarget;

  @override
  int get hashCode => kind.hashCode;

  @override
  String toString() => 'PinnedTerminalTarget()';
}

/// Open the embedded browser. Only available where the app can host one.
final class PinnedBrowserTarget extends PinnedTabTarget {
  const PinnedBrowserTarget();

  @override
  String get kind => 'browser';

  @override
  bool operator ==(Object other) => other is PinnedBrowserTarget;

  @override
  int get hashCode => kind.hashCode;

  @override
  String toString() => 'PinnedBrowserTarget()';
}

/// Open a terminal running a configured [TerminalProfile].
///
/// [profileId] is the host's profile id, not an index: profiles are reordered
/// and edited freely, and a pin must survive that.
final class PinnedProfileTarget extends PinnedTabTarget {
  const PinnedProfileTarget(this.profileId);

  final String profileId;

  @override
  String get kind => 'profile';

  @override
  bool operator ==(Object other) =>
      other is PinnedProfileTarget && other.profileId == profileId;

  @override
  int get hashCode => Object.hash(kind, profileId);

  @override
  String toString() => 'PinnedProfileTarget($profileId)';
}

/// What the running app can offer, as a value so the pin rules stay pure.
///
/// Upstream passes an inline `{ isElectron: boolean }`; naming it keeps the
/// call sites readable and leaves room for future capability flags.
final class PinnedTargetEnvironment {
  const PinnedTargetEnvironment({required this.isElectron});

  /// Whether the app is running inside the desktop shell, which is the only
  /// host that can embed a browser view.
  final bool isElectron;
}

/// Whether [target] can be offered in [environment].
///
/// Only the browser launcher is gated. Everything else — drafts, terminals and
/// terminal profiles — is served by the daemon and works on every platform, so
/// filtering it would hide working functionality from web users.
bool isPinnedTargetAvailable(
  PinnedTabTarget target,
  PinnedTargetEnvironment environment,
) => target is! PinnedBrowserTarget || environment.isElectron;

/// The persisted identity of [target].
///
/// Non-profile targets are singletons, so their [PinnedTabTarget.kind] is the
/// whole key. Profiles are namespaced by id so that two pinned profiles are two
/// pins, and so that a profile can never collide with the `draft`, `terminal`
/// or `browser` keys.
String pinnedTargetKey(PinnedTabTarget target) => switch (target) {
  PinnedProfileTarget() => 'profile:${target.profileId}',
  _ => target.kind,
};

/// Whether [target] is already in [pinned], compared by [pinnedTargetKey].
///
/// Key comparison rather than value comparison is deliberate: a persisted pin
/// is rehydrated into a fresh instance, and upstream's objects never compare
/// equal by reference either.
bool isTargetPinned(List<PinnedTabTarget> pinned, PinnedTabTarget target) {
  final key = pinnedTargetKey(target);
  return pinned.any((entry) => pinnedTargetKey(entry) == key);
}

/// Adds [target] to [pinned] when absent, removes it when present.
///
/// Returns a new list and never mutates [pinned] — the caller's list is often
/// the current persisted state, and mutating it would defeat change detection.
///
/// Newly pinned targets go to the end, so pin order reads as the order the user
/// pinned things. Unpinning preserves the order of everything else.
List<PinnedTabTarget> togglePinnedTarget(
  List<PinnedTabTarget> pinned,
  PinnedTabTarget target,
) {
  final key = pinnedTargetKey(target);
  final next = pinned.where((entry) => pinnedTargetKey(entry) != key).toList();
  if (next.length == pinned.length) {
    next.add(target);
  }
  return next;
}

// ---------------------------------------------------------------------------
// workspace-pins/run.ts
// ---------------------------------------------------------------------------

/// The subset of a [TerminalProfile] a new terminal actually needs.
///
/// Deliberately not the full profile: `id`, `icon` and the passthrough `extra`
/// bag describe the *configuration*, not the process to spawn, and passing them
/// through would invite callers to depend on them.
final class TerminalProfileInput {
  const TerminalProfileInput({
    required this.name,
    required this.command,
    this.args,
  });

  final String name;
  final String command;

  /// Null and empty are distinct here only because upstream's `string[] |
  /// undefined` is; both mean "no extra arguments" to every caller.
  final List<String>? args;

  @override
  bool operator ==(Object other) =>
      other is TerminalProfileInput &&
      other.name == name &&
      other.command == command &&
      _listsEqual(other.args, args);

  @override
  int get hashCode =>
      Object.hash(name, command, args == null ? null : Object.hashAll(args!));

  @override
  String toString() =>
      'TerminalProfileInput(name: $name, command: $command, args: $args)';
}

/// The host callbacks a pinned launcher can fire.
///
/// Upstream's interface of methods becomes a value holding function fields, so
/// a test can record launches without subclassing anything.
final class TabTargetHandlers {
  const TabTargetHandlers({
    required this.createDraft,
    required this.createTerminal,
    required this.createBrowser,
    required this.createTerminalWithProfile,
  });

  final void Function() createDraft;
  final void Function() createTerminal;
  final void Function() createBrowser;
  final void Function(TerminalProfileInput profile) createTerminalWithProfile;
}

/// Fires the handler [target] stands for.
///
/// A [PinnedProfileTarget] whose id is absent from [profiles] is a no-op rather
/// than an error: profiles live in host settings and can be deleted while a pin
/// survives, and a stale pin must not crash the tab strip or silently open the
/// wrong shell.
void runPinnedTabTarget(
  PinnedTabTarget target,
  List<TerminalProfile> profiles,
  TabTargetHandlers handlers,
) {
  switch (target) {
    case PinnedDraftTarget():
      handlers.createDraft();
    case PinnedTerminalTarget():
      handlers.createTerminal();
    case PinnedBrowserTarget():
      handlers.createBrowser();
    case PinnedProfileTarget():
      // First match wins, mirroring `Array.prototype.find`; duplicate ids are a
      // misconfiguration the host should have rejected, not something to guess
      // about here.
      final profile = profiles
          .where((entry) => entry.id == target.profileId)
          .firstOrNull;
      if (profile == null) {
        return;
      }
      handlers.createTerminalWithProfile(
        TerminalProfileInput(
          name: profile.name,
          command: profile.command,
          args: profile.args,
        ),
      );
  }
}

// ---------------------------------------------------------------------------
// workspace/project-workspace-archive.ts
// ---------------------------------------------------------------------------

/// One workspace the archive-project flow has to decide about.
///
/// Upstream declares this as `Pick<SidebarWorkspaceEntry, ...>`. Dart has no
/// structural pick, and `sidebar/sidebar_models.dart`'s `SidebarWorkspaceEntry`
/// deliberately omits the three archive-warning fields (it documents them as
/// unused by any sidebar rule), so the picked shape is spelled out here instead
/// of widening that type for one caller.
final class ProjectWorkspaceArchiveEntry {
  const ProjectWorkspaceArchiveEntry({
    required this.serverId,
    required this.workspaceId,
    required this.workspaceKind,
    required this.name,
    this.archiveHasUncommittedChanges,
    this.archiveUnpushedCommitCount,
    this.diffStat,
  });

  final String serverId;
  final String workspaceId;

  /// Only [WorkspaceKind.worktree] can lose work on archive; every other kind
  /// leaves the user's checkout on disk untouched.
  final WorkspaceKind workspaceKind;

  /// Shown in the confirmation title, so the user knows *which* worktree.
  final String name;

  /// Tri-state on purpose: null means the daemon did not answer, which lets
  /// [diffStat] stand in. See [WorktreeArchiveRisk].
  final bool? archiveHasUncommittedChanges;
  final int? archiveUnpushedCommitCount;
  final WorktreeArchiveDiffStat? diffStat;
}

/// A workspace approved for archiving.
///
/// Carries the host id alongside the workspace id because workspace ids are
/// only unique within one daemon.
final class WorkspaceArchiveTarget {
  const WorkspaceArchiveTarget({
    required this.serverId,
    required this.workspaceId,
  });

  final String serverId;
  final String workspaceId;

  @override
  bool operator ==(Object other) =>
      other is WorkspaceArchiveTarget &&
      other.serverId == serverId &&
      other.workspaceId == workspaceId;

  @override
  int get hashCode => Object.hash(serverId, workspaceId);

  @override
  String toString() =>
      'WorkspaceArchiveTarget(serverId: $serverId, workspaceId: $workspaceId)';
}

/// Asks the user whether a risky worktree archive may proceed.
///
/// The real implementation is `confirmRiskyWorktreeArchive` in
/// `git/paseo_pr_rules.dart`, which returns true without prompting when there is
/// nothing at risk.
typedef ConfirmWorktreeArchive =
    Future<bool> Function(WorktreeArchiveConfirmationInput input);

/// Filters [workspaces] down to the ones the user agreed to archive.
///
/// Non-worktree workspaces pass straight through: archiving them only hides a
/// row, so interrupting the user would be noise. Worktree workspaces are
/// offered to [confirmWorktreeArchive] one at a time, in list order — awaiting
/// each answer is what keeps a five-worktree project from stacking five modal
/// dialogs on top of each other.
///
/// Deviation, deliberate: upstream defaults this parameter to the real
/// `confirmRiskyWorktreeArchive`, which reaches for a dialog. The Dart port of
/// that function requires an injected prompt, so there is no UI-free default to
/// fall back on and the callback is required instead. This keeps the rule
/// testable without pumping a widget tree.
Future<List<WorkspaceArchiveTarget>> selectProjectWorkspacesToArchive(
  List<ProjectWorkspaceArchiveEntry> workspaces, {
  required ConfirmWorktreeArchive confirmWorktreeArchive,
}) async {
  final confirmed = <WorkspaceArchiveTarget>[];

  for (final workspace in workspaces) {
    if (workspace.workspaceKind == WorkspaceKind.worktree) {
      final shouldArchive = await confirmWorktreeArchive(
        WorktreeArchiveConfirmationInput(
          workspaceName: workspace.name,
          risk: toWorktreeArchiveRisk(
            archiveHasUncommittedChanges:
                workspace.archiveHasUncommittedChanges,
            archiveUnpushedCommitCount: workspace.archiveUnpushedCommitCount,
            diffStat: workspace.diffStat,
          ),
        ),
      );
      if (!shouldArchive) {
        continue;
      }
    }

    confirmed.add(
      WorkspaceArchiveTarget(
        serverId: workspace.serverId,
        workspaceId: workspace.workspaceId,
      ),
    );
  }

  return confirmed;
}

// ---------------------------------------------------------------------------
// stores/last-workspace-selection.ts
// ---------------------------------------------------------------------------

/// Where the remembered selection is kept.
///
/// Injected rather than reaching for `SharedPreferences` so the store stays a
/// pure state machine: the hydration race this module exists to solve is only
/// testable when the read can be held open deliberately.
///
/// The payload is an opaque JSON string, deliberately: the store must not know
/// how a selection is encoded, and a workspace id must never be parsed back
/// into a filesystem path.
abstract interface class LastWorkspaceSelectionStorage {
  /// Returns the stored payload, or null when nothing was ever written.
  Future<String?> read();

  /// Persists [value]. Failures are swallowed by the store — losing the
  /// remembered route is not worth surfacing to the user.
  Future<void> write(String value);
}

/// Remembers the workspace route to return to, surviving a slow disk read.
///
/// The problem this solves: hydration is asynchronous, but the user can
/// navigate before it finishes. A naive store would overwrite the workspace
/// they just opened with the one they had last session. Every [remember] bumps
/// an internal revision, and a hydration whose revision has moved on discards
/// its own result.
///
/// Uses [lastWorkspaceRouteSelectionStorageKey] as its conventional storage key
/// — a deviation from upstream's `"paseo:last-workspace-route-selection"`, kept
/// so this store and `state/last_workspace_route_selection.dart` read the same
/// slot in this app's preferences.
final class LastWorkspaceSelectionStore {
  LastWorkspaceSelectionStore(this._storage);

  final LastWorkspaceSelectionStorage _storage;

  /// Insertion-ordered like upstream's `Set<() => void>`, and deduplicating the
  /// same way (Dart closures compare by identity, as JS functions do).
  final Set<void Function()> _listeners = <void Function()>{};

  HostWorkspaceRoute? _selection;
  bool _hydrated = false;
  Future<void>? _hydration;
  int _revision = 0;

  /// The remembered selection, or null when nothing is remembered *or*
  /// hydration has not run. Pair with [isHydrated] to tell those apart.
  HostWorkspaceRoute? getSelection() => _selection;

  /// Whether hydration has finished, successfully or not.
  ///
  /// Callers use this to avoid redirecting on an "empty" selection that is
  /// merely still loading.
  bool isHydrated() => _hydrated;

  /// Loads the persisted selection exactly once.
  ///
  /// Repeat calls return the same future, so several widgets can await
  /// hydration without racing each other into duplicate reads. A read that
  /// fails leaves the store empty but still hydrated — a broken preferences
  /// file must not wedge the app in a loading state forever.
  Future<void> hydrate() => _hydration ??= _runHydration();

  Future<void> _runHydration() async {
    final hydrationRevision = _revision;
    try {
      final stored = await _storage.read();
      if (_revision == hydrationRevision) {
        _selection = parseLastWorkspaceRouteSelection(stored);
      }
    } on Object {
      if (_revision == hydrationRevision) {
        _selection = null;
      }
    } finally {
      _hydrated = true;
      _notifyListeners();
    }
  }

  /// Records [next] as the selection to return to.
  ///
  /// Ignores selections that normalize away (blank ids) and no-ops when the
  /// selection is unchanged, so a route that rebuilds on every frame does not
  /// churn the listeners or the disk.
  ///
  /// The write is fire-and-forget: the in-memory selection is authoritative for
  /// this session, and blocking navigation on a preferences write would be
  /// worse than losing the memory.
  void remember(HostWorkspaceRoute next) {
    final normalized = parseLastWorkspaceRouteSelection(
      encodeLastWorkspaceRouteSelection(next),
    );
    if (normalized == null) {
      return;
    }
    final current = _selection;
    if (current != null &&
        current.serverId == normalized.serverId &&
        current.workspaceId == normalized.workspaceId) {
      return;
    }
    _selection = normalized;
    _revision += 1;
    _notifyListeners();
    // workspaceId is opaque; this persisted selection is never parsed back into
    // a path.
    unawaited(
      Future<void>.sync(
        () => _storage.write(encodeLastWorkspaceRouteSelection(normalized)),
      ).catchError((Object _) {}),
    );
  }

  /// Registers [listener] and returns its unsubscribe callback.
  ///
  /// Fired on every accepted [remember] and once when hydration settles, which
  /// is exactly the set of moments [getSelection] or [isHydrated] can change.
  void Function() subscribe(void Function() listener) {
    _listeners.add(listener);
    return () {
      _listeners.remove(listener);
    };
  }

  /// Deviation, documented: iterates a snapshot. JS lets a `Set` be mutated
  /// mid-iteration; Dart throws `ConcurrentModificationError`. The observable
  /// difference is confined to listeners that (un)subscribe from inside a
  /// notification — a listener removed during the notification still runs, and
  /// one added during it does not. Neither is behavior any caller relies on,
  /// and both are preferable to a crash.
  void _notifyListeners() {
    for (final listener in _listeners.toList(growable: false)) {
      listener();
    }
  }
}

bool _listsEqual(List<String>? left, List<String>? right) {
  if (left == null || right == null) return left == right;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
