import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'agents_provider.dart';
import 'daemon_providers.dart';
import 'host_registry_provider.dart';
import 'subagents_provider.dart';
import 'workspace_catalog_provider.dart';
import '../workspace/workspace_file_open.dart';
import '../workspace/workspace_pane_layout.dart';
import '../workspace/workspace_pane_state.dart';
import '../workspace/workspace_tab_model.dart';

const _uuid = Uuid();

/// The worktree currently shown in the main content area — replaces
/// `selectedAgentProvider`'s routing role now that a worktree's tab strip
/// (not a single agent) is what gets selected. Focusing a specific agent
/// within that worktree is a separate step (`worktreeTabsProvider(path)
/// .notifier.focusAgent(agentId)`).
class SelectedWorktreeNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? worktreePath) => state = worktreePath;
}

final selectedWorktreeProvider =
    NotifierProvider<SelectedWorktreeNotifier, String?>(
      SelectedWorktreeNotifier.new,
    );

/// A worktree's tab strip holds tabs of these kinds, mirroring Paseo's
/// discriminated tab-target union scoped to what this app supports.
enum WorktreeTabKind {
  /// Not-yet-created agent session: an inline composer (provider/model/mode
  /// + optional first prompt). Converts in place to [agent] on submit.
  draft,

  /// A real agent conversation.
  agent,

  /// A provider-owned child session with its own independently fetched
  /// timeline.
  providerSubagent,

  /// An independent daemon-backed terminal session.
  terminal,

  /// The worktree's "working diff" — singleton, reflects git state, not any
  /// one agent.
  diff,

  /// A workspace file preview. Identity is stable by path; repeated opens
  /// update the requested line range and navigation revision in place.
  file,

  /// Workspace setup progress/details. Singleton per workspace id.
  setup,
}

class WorktreeTab {
  const WorktreeTab({
    required this.tabId,
    required this.kind,
    this.agentId,
    this.parentAgentId,
    this.subagentId,
    this.lastKnownTerminalId,
    this.filePath,
    this.lineStart,
    this.lineEnd,
    this.fileNavigationRevision = 0,
    this.setupWorkspaceId,
    this.diffFocusPath,
    this.diffFocusRequestId,
  });

  final String tabId;
  final WorktreeTabKind kind;

  /// Set when [kind] is [WorktreeTabKind.agent].
  final String? agentId;
  final String? parentAgentId;
  final String? subagentId;

  /// Set when [kind] is [WorktreeTabKind.terminal], once its
  /// `terminal.create.request` resolves — lets a future app restart
  /// re-subscribe instead of re-creating.
  final String? lastKnownTerminalId;
  final String? filePath;
  final int? lineStart;
  final int? lineEnd;
  final int fileNavigationRevision;
  final String? setupWorkspaceId;
  final String? diffFocusPath;
  final int? diffFocusRequestId;

  WorkspaceTabTarget? get workspaceTarget => switch (kind) {
    WorktreeTabKind.draft => WorkspaceDraftTabTarget(draftId: tabId),
    WorktreeTabKind.agent =>
      agentId == null ? null : WorkspaceAgentTabTarget(agentId: agentId!),
    WorktreeTabKind.providerSubagent =>
      parentAgentId == null || subagentId == null
          ? null
          : WorkspaceProviderSubagentTabTarget(
              parentAgentId: parentAgentId!,
              subagentId: subagentId!,
            ),
    WorktreeTabKind.terminal => WorkspaceTerminalTabTarget(
      terminalId: lastKnownTerminalId ?? tabId,
    ),
    WorktreeTabKind.diff => WorkspaceWorkingDiffTabTarget(
      focusPath: diffFocusPath,
      focusRequestId: diffFocusRequestId,
    ),
    WorktreeTabKind.file =>
      filePath == null
          ? null
          : WorkspaceFileTabTarget(
              path: filePath!,
              lineStart: lineStart,
              lineEnd: lineEnd,
            ),
    WorktreeTabKind.setup =>
      setupWorkspaceId == null
          ? null
          : WorkspaceSetupTabTarget(workspaceId: setupWorkspaceId!),
  };

  WorktreeTab copyWith({
    String? lastKnownTerminalId,
    String? filePath,
    int? lineStart,
    int? lineEnd,
    int? fileNavigationRevision,
    String? setupWorkspaceId,
  }) => WorktreeTab(
    tabId: tabId,
    kind: kind,
    agentId: agentId,
    parentAgentId: parentAgentId,
    subagentId: subagentId,
    lastKnownTerminalId: lastKnownTerminalId ?? this.lastKnownTerminalId,
    filePath: filePath ?? this.filePath,
    lineStart: lineStart ?? this.lineStart,
    lineEnd: lineEnd,
    fileNavigationRevision:
        fileNavigationRevision ?? this.fileNavigationRevision,
    setupWorkspaceId: setupWorkspaceId ?? this.setupWorkspaceId,
    diffFocusPath: diffFocusPath,
    diffFocusRequestId: diffFocusRequestId,
  );

  WorktreeTab withDiffFocus({
    required String? focusPath,
    required int? focusRequestId,
  }) => WorktreeTab(
    tabId: tabId,
    kind: kind,
    agentId: agentId,
    parentAgentId: parentAgentId,
    subagentId: subagentId,
    lastKnownTerminalId: lastKnownTerminalId,
    filePath: filePath,
    lineStart: lineStart,
    lineEnd: lineEnd,
    fileNavigationRevision: fileNavigationRevision,
    setupWorkspaceId: setupWorkspaceId,
    diffFocusPath: focusPath,
    diffFocusRequestId: focusRequestId,
  );

  static WorktreeTab fromJson(Map<String, Object?> json) {
    final kind = WorktreeTabKind.values.byName(json['kind'] as String);
    final normalizedDiffTarget = kind == WorktreeTabKind.diff
        ? normalizeWorkspaceTabTarget(
                WorkspaceWorkingDiffTabTarget(
                  focusPath: json['diffFocusPath'] as String?,
                  focusRequestId: (json['diffFocusRequestId'] as num?)?.toInt(),
                ),
              )
              as WorkspaceWorkingDiffTabTarget
        : null;
    return WorktreeTab(
      tabId: json['tabId'] as String,
      kind: kind,
      agentId: json['agentId'] as String?,
      parentAgentId: json['parentAgentId'] as String?,
      subagentId: json['subagentId'] as String?,
      lastKnownTerminalId: json['lastKnownTerminalId'] as String?,
      filePath: json['filePath'] as String?,
      lineStart: (json['lineStart'] as num?)?.toInt(),
      lineEnd: (json['lineEnd'] as num?)?.toInt(),
      fileNavigationRevision:
          (json['fileNavigationRevision'] as num?)?.toInt() ?? 0,
      setupWorkspaceId: json['setupWorkspaceId'] as String?,
      diffFocusPath: normalizedDiffTarget?.focusPath,
      diffFocusRequestId: normalizedDiffTarget?.focusRequestId,
    );
  }

  Map<String, Object?> toJson() => {
    'tabId': tabId,
    'kind': kind.name,
    if (agentId != null) 'agentId': agentId,
    if (parentAgentId != null) 'parentAgentId': parentAgentId,
    if (subagentId != null) 'subagentId': subagentId,
    if (lastKnownTerminalId != null) 'lastKnownTerminalId': lastKnownTerminalId,
    if (filePath != null) 'filePath': filePath,
    if (lineStart != null) 'lineStart': lineStart,
    if (lineEnd != null) 'lineEnd': lineEnd,
    if (fileNavigationRevision != 0)
      'fileNavigationRevision': fileNavigationRevision,
    if (setupWorkspaceId != null) 'setupWorkspaceId': setupWorkspaceId,
    if (diffFocusPath != null) 'diffFocusPath': diffFocusPath,
    if (diffFocusRequestId != null) 'diffFocusRequestId': diffFocusRequestId,
  };

  @override
  bool operator ==(Object other) =>
      other is WorktreeTab &&
      other.tabId == tabId &&
      other.kind == kind &&
      other.agentId == agentId &&
      other.parentAgentId == parentAgentId &&
      other.subagentId == subagentId &&
      other.lastKnownTerminalId == lastKnownTerminalId &&
      other.filePath == filePath &&
      other.lineStart == lineStart &&
      other.lineEnd == lineEnd &&
      other.fileNavigationRevision == fileNavigationRevision &&
      other.setupWorkspaceId == setupWorkspaceId &&
      other.diffFocusPath == diffFocusPath &&
      other.diffFocusRequestId == diffFocusRequestId;

  @override
  int get hashCode => Object.hash(
    tabId,
    kind,
    agentId,
    parentAgentId,
    subagentId,
    lastKnownTerminalId,
    filePath,
    lineStart,
    lineEnd,
    fileNavigationRevision,
    setupWorkspaceId,
    diffFocusPath,
    diffFocusRequestId,
  );
}

class WorktreeTabLayout {
  const WorktreeTabLayout({
    required this.tabs,
    this.activeTabId,
    this.paneLayout,
    this.pinnedAgentIds = const {},
  });

  static const empty = WorktreeTabLayout(tabs: []);

  final List<WorktreeTab> tabs;
  final String? activeTabId;
  final WorkspacePaneLayout? paneLayout;
  final Set<String> pinnedAgentIds;

  static WorktreeTabLayout fromJson(Map<String, Object?> json) =>
      WorktreeTabLayout(
        tabs: ((json['tabs'] as List?) ?? const [])
            .cast<Map<String, Object?>>()
            .map(WorktreeTab.fromJson)
            .toList(),
        activeTabId: json['activeTabId'] as String?,
        paneLayout: json['paneLayout'] is Map<String, Object?>
            ? WorkspacePaneLayout.fromJson(
                json['paneLayout'] as Map<String, Object?>,
              )
            : null,
        pinnedAgentIds: ((json['pinnedAgentIds'] as List?) ?? const [])
            .whereType<String>()
            .toSet(),
      );

  Map<String, Object?> toJson() => {
    'tabs': tabs.map((t) => t.toJson()).toList(),
    if (activeTabId != null) 'activeTabId': activeTabId,
    if (paneLayout != null) 'paneLayout': paneLayout!.toJson(),
    if (pinnedAgentIds.isNotEmpty)
      'pinnedAgentIds': pinnedAgentIds.toList()..sort(),
  };

  bool _tabsEqual(List<WorktreeTab> other) {
    if (other.length != tabs.length) return false;
    for (var i = 0; i < tabs.length; i++) {
      if (other[i] != tabs[i]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is WorktreeTabLayout &&
      other.activeTabId == activeTabId &&
      jsonEncode(other.paneLayout?.toJson()) ==
          jsonEncode(paneLayout?.toJson()) &&
      other.pinnedAgentIds.length == pinnedAgentIds.length &&
      other.pinnedAgentIds.containsAll(pinnedAgentIds) &&
      _tabsEqual(other.tabs);

  @override
  int get hashCode => Object.hash(
    activeTabId,
    Object.hashAll(tabs),
    jsonEncode(paneLayout?.toJson()),
    Object.hashAll(pinnedAgentIds.toList()..sort()),
  );
}

/// Whether a worktree's terminal tabs have been checked against the
/// daemon's live terminal list yet. `false` right after a fresh app launch
/// with persisted terminal tabs, until the async verification pass (below)
/// resolves — consumers shouldn't treat an empty/short tab list as final
/// while this is `false`.
class WorktreeTabLayoutState {
  const WorktreeTabLayoutState({
    required this.layout,
    this.terminalsVerified = true,
  });

  final WorktreeTabLayout layout;
  final bool terminalsVerified;
}

class WorktreeTabLayoutsHydrationNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void markHydrated() => state = true;
}

final worktreeTabLayoutsHydratedProvider =
    NotifierProvider<WorktreeTabLayoutsHydrationNotifier, bool>(
      WorktreeTabLayoutsHydrationNotifier.new,
    );

/// The whole app's worktree tab layouts, persisted as one JSON blob in
/// `SharedPreferences` (mirrors `sidebar_pins_provider.dart`'s house style —
/// one key, one blob, loaded once — rather than per-worktree keys, so
/// rendering many sidebar rows doesn't mean many separate prefs reads).
class WorktreeTabLayoutsNotifier
    extends Notifier<Map<String, WorktreeTabLayout>> {
  static const _key = 'worktree.tabLayouts';

  @override
  Map<String, WorktreeTabLayout> build() {
    Future.microtask(_load);
    return const {};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      state = {
        for (final entry in decoded.entries)
          entry.key: WorktreeTabLayout.fromJson(
            entry.value as Map<String, Object?>,
          ),
      };
    } catch (_) {
      // Keep the default (empty) map when prefs are unavailable/corrupt.
    } finally {
      if (ref.mounted) {
        ref.read(worktreeTabLayoutsHydratedProvider.notifier).markHydrated();
      }
    }
  }

  Future<void> setLayout(
    String persistenceKey,
    WorktreeTabLayout layout, {
    String? removeKey,
  }) async {
    // No-op if unchanged: a new Map is never `==` its predecessor by
    // reference, so an unconditional assignment here would make any watcher
    // that both reads and writes this provider (as WorktreeTabsNotifier
    // does) rebuild-and-rewrite itself forever in a self-sustaining chain of
    // microtasks. Comparing the per-workspace value (which does have real
    // equality) breaks that chain once the layout stabilizes.
    final normalizedRemoveKey = removeKey == persistenceKey ? null : removeKey;
    if (state[persistenceKey] == layout &&
        (normalizedRemoveKey == null ||
            !state.containsKey(normalizedRemoveKey))) {
      return;
    }
    final next = {...state, persistenceKey: layout};
    if (normalizedRemoveKey != null) next.remove(normalizedRemoveKey);
    state = Map.unmodifiable(next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode({for (final e in state.entries) e.key: e.value.toJson()}),
      );
    } catch (_) {
      // Applies for this session even if persistence fails.
    }
  }
}

final worktreeTabLayoutsProvider =
    NotifierProvider<
      WorktreeTabLayoutsNotifier,
      Map<String, WorktreeTabLayout>
    >(WorktreeTabLayoutsNotifier.new);

/// Resolves the frozen Paseo workspace-layout key (`serverId:workspaceId`)
/// while keeping the worktree path as a temporary fallback until the
/// authoritative workspace catalog has hydrated.
///
/// The fallback is also the legacy Tinyrack key. [WorktreeTabsNotifier]
/// migrates it atomically once this provider can resolve a canonical
/// identity.
final worktreeTabPersistenceKeyProvider = Provider.family<String, String>((
  ref,
  worktreePath,
) {
  final serverId = ref.watch(activeHostProvider)?.serverId;
  if (serverId == null || serverId.trim().isEmpty) return worktreePath;

  final cachedWorkspaces =
      ref.watch(workspaceCatalogCacheProvider)[serverId] ?? const [];
  for (final workspace in cachedWorkspaces) {
    if (workspace.workspaceDirectory != worktreePath) continue;
    return buildWorkspaceTabPersistenceKey(
          serverId: serverId,
          workspaceId: workspace.id,
        ) ??
        worktreePath;
  }

  for (final agent in ref.watch(agentsProvider).values) {
    if (resolveWorktreeKey(agent) != worktreePath) continue;
    final workspaceId = agent.workspaceId;
    if (workspaceId == null) continue;
    final key = buildWorkspaceTabPersistenceKey(
      serverId: serverId,
      workspaceId: workspaceId,
    );
    if (key != null) return key;
  }
  return worktreePath;
});

/// One worktree's tab strip state, reconciled against server truth
/// (`agentsProvider` synchronously, `terminal.list.request` asynchronously)
/// on every rebuild. Family argument: the worktree's path (== its `cwd`;
/// see `resolveWorktreeKey`).
class WorktreeTabsNotifier extends Notifier<WorktreeTabLayoutState> {
  WorktreeTabsNotifier(this.worktreePath);

  final String worktreePath;

  /// The most recently computed layout, kept in sync (synchronously) by
  /// every path that finalizes one — see [_persist]. Preferred over the
  /// on-disk blob once available, since the blob write is deferred and a
  /// dependency-change (e.g. `agentsProvider`) can force a rebuild before
  /// that write has flushed.
  WorktreeTabLayout? _cachedLayout;
  String? _persistenceKey;
  String? _legacyKeyToRemove;
  final Set<String> _focusRestorationTokens = {};
  String? _focusRestorePaneId;

  @override
  WorktreeTabLayoutState build() {
    final persistenceKey = ref.watch(
      worktreeTabPersistenceKeyProvider(worktreePath),
    );
    final layouts = ref.read(worktreeTabLayoutsProvider);
    final previousPersistenceKey = _persistenceKey;
    if (previousPersistenceKey != persistenceKey) {
      final canonicalLayout = layouts[persistenceKey];
      final mayMigrateLegacy =
          persistenceKey != worktreePath &&
          (previousPersistenceKey == null ||
              previousPersistenceKey == worktreePath);
      final legacyLayout = mayMigrateLegacy ? layouts[worktreePath] : null;
      final inMemoryLegacyLayout =
          mayMigrateLegacy && previousPersistenceKey == worktreePath
          ? _cachedLayout
          : null;
      _cachedLayout = canonicalLayout ?? inMemoryLegacyLayout ?? legacyLayout;
      _legacyKeyToRemove = legacyLayout == null && inMemoryLegacyLayout == null
          ? null
          : worktreePath;
      _persistenceKey = persistenceKey;
    }
    final persisted =
        _cachedLayout ?? (layouts[persistenceKey] ?? WorktreeTabLayout.empty);

    final liveAgents = ref
        .watch(agentsProvider)
        .values
        .where((a) => resolveWorktreeKey(a) == worktreePath)
        .toList();
    final liveIds = liveAgents.map((a) => a.agentId).toSet();

    // Sync pass: drop agent tabs whose agent no longer exists, add tabs for
    // any live agent missing from the persisted layout.
    var tabs = [
      for (final tab in persisted.tabs)
        if (tab.kind != WorktreeTabKind.agent ||
            liveIds.contains(tab.agentId) ||
            persisted.pinnedAgentIds.contains(tab.agentId))
          tab,
    ];
    final covered = tabs
        .where((t) => t.kind == WorktreeTabKind.agent)
        .map((t) => t.agentId)
        .toSet();
    final agentsById = ref.watch(agentsProvider);
    for (final agent in liveAgents) {
      final parent = agent.parentAgentId == null
          ? null
          : agentsById[agent.parentAgentId];
      if (!isWorkspaceRootAgent(agent, parent)) continue;
      if (!covered.contains(agent.agentId)) {
        tabs.add(
          WorktreeTab(
            tabId: buildDeterministicWorkspaceTabId(
              WorkspaceAgentTabTarget(agentId: agent.agentId),
            ),
            kind: WorktreeTabKind.agent,
            agentId: agent.agentId,
          ),
        );
      }
    }

    // Terminal tabs need an async round-trip to verify against the daemon;
    // don't apply the empty-invariant yet if any are pending verification,
    // or a draft tab would flash in before the real answer arrives. Only
    // tabs with an already-known terminal id (loaded from persisted storage)
    // count as "pending" — one just added via addTab() has no id yet and
    // isn't a verification candidate, just a tab still being created.
    final hasPendingTerminals = persisted.tabs.any(
      (t) =>
          t.kind == WorktreeTabKind.terminal && t.lastKnownTerminalId != null,
    );
    var terminalsVerified = true;
    if (hasPendingTerminals) {
      terminalsVerified = false;
      Future.microtask(_verifyTerminals);
    } else {
      tabs = _applyEmptyInvariant(tabs);
    }

    final activeTabId = _resolveActiveTabId(tabs, persisted.activeTabId);
    final paneLayout = reconcileWorkspacePaneLayout(
      layout:
          persisted.paneLayout ??
          WorkspacePaneLayout.single(
            paneId: 'pane_root',
            tabIds: tabs.map((tab) => tab.tabId).toList(),
            focusedTabId: activeTabId,
          ),
      tabIds: tabs.map((tab) => tab.tabId).toList(),
      preferredTabId: activeTabId,
    );
    final layout = WorktreeTabLayout(
      tabs: tabs,
      activeTabId: activeTabId,
      paneLayout: paneLayout,
      pinnedAgentIds: persisted.pinnedAgentIds,
    );
    _persist(layout);
    return WorktreeTabLayoutState(
      layout: layout,
      terminalsVerified: terminalsVerified,
    );
  }

  List<WorktreeTab> _applyEmptyInvariant(List<WorktreeTab> tabs) {
    if (tabs.isNotEmpty) return tabs;
    return [WorktreeTab(tabId: _uuid.v4(), kind: WorktreeTabKind.draft)];
  }

  String? _resolveActiveTabId(List<WorktreeTab> tabs, String? preferred) {
    if (preferred != null && tabs.any((t) => t.tabId == preferred)) {
      return preferred;
    }
    return tabs.isEmpty ? null : tabs.first.tabId;
  }

  Future<void> _verifyTerminals() async {
    // Only tabs that already had a known terminal id when this pass started
    // may be pruned; anything added since (e.g. tapped "New terminal" while
    // verification was still in flight, with no id yet) is left alone.
    final pendingTabIds = state.layout.tabs
        .where(
          (t) =>
              t.kind == WorktreeTabKind.terminal &&
              t.lastKnownTerminalId != null,
        )
        .map((t) => t.tabId)
        .toSet();

    Set<String> liveTerminalIds;
    try {
      final client = ref.read(daemonClientProvider);
      final res = await client.request(
        MessageTypes.terminalListRequest,
        const {},
      );
      if (!ref.mounted) return;
      liveTerminalIds = ((res['terminals'] as List?) ?? const [])
          .cast<Map<String, Object?>>()
          .map((t) => t['terminalId'] as String)
          .toSet();
    } catch (_) {
      // Daemon unreachable; leave terminal tabs as-is, re-verify next build.
      if (!ref.mounted) return;
      state = WorktreeTabLayoutState(
        layout: state.layout,
        terminalsVerified: true,
      );
      return;
    }

    var tabs = [
      for (final tab in state.layout.tabs)
        if (tab.kind != WorktreeTabKind.terminal ||
            !pendingTabIds.contains(tab.tabId) ||
            liveTerminalIds.contains(tab.lastKnownTerminalId))
          tab,
    ];
    tabs = _applyEmptyInvariant(tabs);

    final layout = WorktreeTabLayout(
      tabs: tabs,
      activeTabId: _resolveActiveTabId(tabs, state.layout.activeTabId),
      paneLayout: reconcileWorkspacePaneLayout(
        layout: state.layout.paneLayout!,
        tabIds: tabs.map((tab) => tab.tabId).toList(),
        preferredTabId: state.layout.activeTabId,
      ),
      pinnedAgentIds: state.layout.pinnedAgentIds,
    );
    if (!ref.mounted) return;
    _persist(layout);
    state = WorktreeTabLayoutState(layout: layout, terminalsVerified: true);
  }

  void _persist(WorktreeTabLayout layout) {
    // Cached synchronously so a rebuild triggered mid-sequence (e.g. an
    // agentsProvider change forcing build() to re-run before the blob write
    // below has flushed) reconciles from the freshest known layout instead
    // of a stale on-disk snapshot that would discard not-yet-persisted local
    // mutations (like a tab just added via addTab()).
    _cachedLayout = layout;
    // The actual blob write stays deferred: writing to
    // worktreeTabLayoutsProvider synchronously from here — even outside
    // build() — can re-enter this same notifier's build() (since it watches
    // that provider) before the current mutating method has returned,
    // corrupting/racing the state it just set.
    Future.microtask(() {
      if (ref.mounted) {
        final persistenceKey = _persistenceKey ?? worktreePath;
        final removeKey = _legacyKeyToRemove;
        _legacyKeyToRemove = null;
        ref
            .read(worktreeTabLayoutsProvider.notifier)
            .setLayout(persistenceKey, layout, removeKey: removeKey);
      }
    });
  }

  void _mutate(
    List<WorktreeTab> Function(List<WorktreeTab> tabs) transform, {
    String? Function(List<WorktreeTab> tabs)? nextActive,
  }) {
    var tabs = transform(List.of(state.layout.tabs));
    tabs = _applyEmptyInvariant(tabs);
    final active = nextActive != null
        ? nextActive(tabs)
        : _resolveActiveTabId(tabs, state.layout.activeTabId);
    final paneLayout = reconcileWorkspacePaneLayout(
      layout:
          state.layout.paneLayout ??
          WorkspacePaneLayout.single(
            paneId: 'pane_root',
            tabIds: state.layout.tabs.map((tab) => tab.tabId).toList(),
            focusedTabId: state.layout.activeTabId,
          ),
      tabIds: tabs.map((tab) => tab.tabId).toList(),
      preferredTabId: active,
    );
    final layout = WorktreeTabLayout(
      tabs: tabs,
      activeTabId: active,
      paneLayout: paneLayout,
      pinnedAgentIds: state.layout.pinnedAgentIds,
    );
    state = WorktreeTabLayoutState(
      layout: layout,
      terminalsVerified: state.terminalsVerified,
    );
    _persist(layout);
  }

  /// Adds a new draft or terminal tab and activates it. Agent tabs are
  /// created only via [retarget] (draft -> agent conversion), never added
  /// directly.
  String addTab(WorktreeTabKind kind) {
    assert(kind == WorktreeTabKind.draft || kind == WorktreeTabKind.terminal);
    final tabId = _uuid.v4();
    _mutate(
      (tabs) => [...tabs, WorktreeTab(tabId: tabId, kind: kind)],
      nextActive: (_) => tabId,
    );
    return tabId;
  }

  /// Activates the existing "diff" tab, or inserts+activates one if none is
  /// open yet.
  void showDiffTab({String? focusPath, int? focusRequestId}) {
    final normalizedTarget =
        normalizeWorkspaceTabTarget(
              WorkspaceWorkingDiffTabTarget(
                focusPath: focusPath,
                focusRequestId: focusRequestId,
              ),
            )
            as WorkspaceWorkingDiffTabTarget;
    final normalizedFocusPath = normalizedTarget.focusPath;
    final normalizedFocusRequestId = normalizedTarget.focusRequestId;
    final existing = state.layout.tabs
        .where((t) => t.kind == WorktreeTabKind.diff)
        .firstOrNull;
    if (existing != null) {
      _mutate(
        (tabs) => [
          for (final tab in tabs)
            if (tab.tabId == existing.tabId)
              tab.withDiffFocus(
                focusPath: normalizedFocusPath,
                focusRequestId: normalizedFocusRequestId,
              )
            else
              tab,
        ],
        nextActive: (_) => existing.tabId,
      );
      return;
    }
    final tabId = buildDeterministicWorkspaceTabId(
      const WorkspaceWorkingDiffTabTarget(),
    );
    _mutate(
      (tabs) => [
        ...tabs,
        WorktreeTab(
          tabId: tabId,
          kind: WorktreeTabKind.diff,
          diffFocusPath: normalizedFocusPath,
          diffFocusRequestId: normalizedFocusRequestId,
        ),
      ],
      nextActive: (_) => tabId,
    );
  }

  void closeTab(String tabId) {
    final agentId = state.layout.tabs
        .where((tab) => tab.tabId == tabId)
        .firstOrNull
        ?.agentId;
    _mutate((tabs) => tabs.where((t) => t.tabId != tabId).toList());
    if (agentId != null) unpinAgent(agentId);
  }

  /// Converts a draft tab in place into an agent tab (same tabId/position),
  /// matching Paseo's draft -> agent conversion.
  void retarget(String tabId, String agentId) {
    _mutate(
      (tabs) {
        // A rebuild between the agent's creation and this call (e.g. Riverpod
        // eagerly propagating the fresh agentsProvider entry to this notifier,
        // or a widget actively watching it) may already have
        // reconciliation-added its own tab for this agent — drop that
        // duplicate rather than the original draft, so the draft's tabId and
        // position always win.
        final withoutDuplicate = [
          for (final tab in tabs)
            if (tab.tabId == tabId ||
                !(tab.kind == WorktreeTabKind.agent && tab.agentId == agentId))
              tab,
        ];
        return [
          for (final tab in withoutDuplicate)
            if (tab.tabId == tabId)
              WorktreeTab(
                tabId: tabId,
                kind: WorktreeTabKind.agent,
                agentId: agentId,
              )
            else
              tab,
        ];
      },
      nextActive: (tabs) {
        final match = tabs.firstWhere(
          (t) => t.kind == WorktreeTabKind.agent && t.agentId == agentId,
          orElse: () => tabs.first,
        );
        return match.tabId;
      },
    );
  }

  void setActiveTab(String tabId) {
    if (!state.layout.tabs.any((t) => t.tabId == tabId)) return;
    final reconciledPaneLayout = reconcileWorkspacePaneLayout(
      layout: state.layout.paneLayout!,
      tabIds: state.layout.tabs.map((tab) => tab.tabId).toList(),
      preferredTabId: tabId,
    );
    final targetPane = findWorkspacePaneContainingTab(
      reconciledPaneLayout.root,
      tabId,
    );
    final layout = WorktreeTabLayout(
      tabs: state.layout.tabs,
      activeTabId: tabId,
      paneLayout: targetPane == null
          ? reconciledPaneLayout
          : focusWorkspacePaneTab(
              layout: reconciledPaneLayout,
              paneId: targetPane.id,
              tabId: tabId,
            ),
      pinnedAgentIds: state.layout.pinnedAgentIds,
    );
    state = WorktreeTabLayoutState(
      layout: layout,
      terminalsVerified: state.terminalsVerified,
    );
    _persist(layout);
  }

  String? splitFocusedPane(WorkspaceSplitDirection direction) {
    final current = state.layout.paneLayout;
    final focusedPaneId = current?.focusedPaneId;
    if (current == null || focusedPaneId == null) return null;
    final tabId = _uuid.v4();
    final paneId = 'pane_${_uuid.v4()}';
    final next = splitWorkspacePane(
      layout: current,
      targetPaneId: focusedPaneId,
      direction: direction,
      newPaneId: paneId,
      newGroupId: 'group_${_uuid.v4()}',
      newTabId: tabId,
    );
    if (next == null) return null;
    final layout = WorktreeTabLayout(
      tabs: [
        ...state.layout.tabs,
        WorktreeTab(tabId: tabId, kind: WorktreeTabKind.draft),
      ],
      activeTabId: tabId,
      paneLayout: next,
      pinnedAgentIds: state.layout.pinnedAgentIds,
    );
    state = WorktreeTabLayoutState(
      layout: layout,
      terminalsVerified: state.terminalsVerified,
    );
    _persist(layout);
    return paneId;
  }

  void focusPane(WorkspacePaneDirection direction) {
    final current = state.layout.paneLayout;
    final focusedPaneId = current?.focusedPaneId;
    if (current == null || focusedPaneId == null) return;
    final adjacent = findAdjacentWorkspacePane(
      current.root,
      focusedPaneId,
      direction,
    );
    if (adjacent == null) return;
    final pane = findWorkspacePane(current.root, adjacent);
    final active = pane?.focusedTabId ?? pane?.tabIds.firstOrNull;
    final layout = WorktreeTabLayout(
      tabs: state.layout.tabs,
      activeTabId: active ?? state.layout.activeTabId,
      paneLayout: WorkspacePaneLayout(
        root: current.root,
        focusedPaneId: adjacent,
      ),
      pinnedAgentIds: state.layout.pinnedAgentIds,
    );
    state = WorktreeTabLayoutState(
      layout: layout,
      terminalsVerified: state.terminalsVerified,
    );
    _persist(layout);
  }

  void focusPaneById(String paneId) {
    final current = state.layout.paneLayout;
    final pane = current == null
        ? null
        : findWorkspacePane(current.root, paneId);
    if (current == null || pane == null) return;
    _clearFocusRestoration();
    final active = pane.focusedTabId ?? pane.tabIds.firstOrNull;
    if (current.focusedPaneId == paneId &&
        state.layout.activeTabId == (active ?? state.layout.activeTabId)) {
      return;
    }
    final layout = WorktreeTabLayout(
      tabs: state.layout.tabs,
      activeTabId: active ?? state.layout.activeTabId,
      paneLayout: WorkspacePaneLayout(
        root: current.root,
        focusedPaneId: paneId,
      ),
      pinnedAgentIds: state.layout.pinnedAgentIds,
    );
    state = WorktreeTabLayoutState(
      layout: layout,
      terminalsVerified: state.terminalsVerified,
    );
    _persist(layout);
  }

  void moveActiveTab(WorkspacePaneDirection direction) {
    final current = state.layout.paneLayout;
    final tabId = state.layout.activeTabId;
    final focusedPaneId = current?.focusedPaneId;
    if (current == null || tabId == null || focusedPaneId == null) return;
    final adjacent = findAdjacentWorkspacePane(
      current.root,
      focusedPaneId,
      direction,
    );
    if (adjacent == null) return;
    final next = moveWorkspaceTabToPane(
      layout: current,
      tabId: tabId,
      targetPaneId: adjacent,
    );
    final layout = WorktreeTabLayout(
      tabs: state.layout.tabs,
      activeTabId: tabId,
      paneLayout: next,
      pinnedAgentIds: state.layout.pinnedAgentIds,
    );
    state = WorktreeTabLayoutState(
      layout: layout,
      terminalsVerified: state.terminalsVerified,
    );
    _persist(layout);
  }

  void resizeSplit(String groupId, List<double> sizes) {
    final current = state.layout.paneLayout;
    if (current == null) return;
    final next = resizeWorkspaceSplit(
      layout: current,
      groupId: groupId,
      sizes: sizes,
    );
    final layout = WorktreeTabLayout(
      tabs: state.layout.tabs,
      activeTabId: state.layout.activeTabId,
      paneLayout: next,
      pinnedAgentIds: state.layout.pinnedAgentIds,
    );
    state = WorktreeTabLayoutState(
      layout: layout,
      terminalsVerified: state.terminalsVerified,
    );
    _persist(layout);
  }

  void reorderTabsInPane(String paneId, List<String> tabIds) {
    final current = state.layout.paneLayout;
    if (current == null) return;
    final next = reorderWorkspacePaneTabs(
      layout: current,
      paneId: paneId,
      tabIds: tabIds,
    );
    if (next == null) return;
    _commitPaneOrder(next);
  }

  void moveTabToPaneIndex({
    required String tabId,
    required String targetPaneId,
    required int insertionIndex,
  }) {
    final current = state.layout.paneLayout;
    if (current == null ||
        !state.layout.tabs.any((tab) => tab.tabId == tabId)) {
      return;
    }
    final next = moveWorkspaceTabToPaneIndex(
      layout: current,
      tabId: tabId,
      targetPaneId: targetPaneId,
      insertionIndex: insertionIndex,
    );
    _commitPaneOrder(next, activeTabId: tabId);
  }

  String? splitTabAtPosition({
    required String tabId,
    required String targetPaneId,
    required WorkspaceSplitDropPosition position,
  }) {
    final current = state.layout.paneLayout;
    if (current == null ||
        position == WorkspaceSplitDropPosition.center ||
        !state.layout.tabs.any((tab) => tab.tabId == tabId)) {
      return null;
    }
    final paneId = 'pane_${_uuid.v4()}';
    final next = splitWorkspaceTabAtPosition(
      layout: current,
      tabId: tabId,
      targetPaneId: targetPaneId,
      position: position,
      newPaneId: paneId,
      newGroupId: 'group_${_uuid.v4()}',
    );
    if (next == null) return null;
    _commitPaneOrder(next, activeTabId: tabId);
    return paneId;
  }

  void _commitPaneOrder(WorkspacePaneLayout paneLayout, {String? activeTabId}) {
    final byId = {for (final tab in state.layout.tabs) tab.tabId: tab};
    final orderedIds = collectWorkspacePanes(
      paneLayout.root,
    ).expand((pane) => pane.tabIds);
    final tabs = [
      for (final id in orderedIds) ?byId.remove(id),
      ...byId.values,
    ];
    final layout = WorktreeTabLayout(
      tabs: tabs,
      activeTabId: activeTabId ?? state.layout.activeTabId,
      paneLayout: paneLayout,
      pinnedAgentIds: state.layout.pinnedAgentIds,
    );
    state = WorktreeTabLayoutState(
      layout: layout,
      terminalsVerified: state.terminalsVerified,
    );
    _persist(layout);
  }

  List<WorktreeTab> focusedPaneTabs() {
    final paneLayout = state.layout.paneLayout;
    if (paneLayout == null) return const [];
    final pane = findWorkspacePane(paneLayout.root, paneLayout.focusedPaneId);
    if (pane == null) return const [];
    final ids = pane.tabIds.toSet();
    return state.layout.tabs.where((tab) => ids.contains(tab.tabId)).toList();
  }

  void removePaneIfEmpty(String? paneId) {
    final current = state.layout.paneLayout;
    final pane = current == null
        ? null
        : findWorkspacePane(current.root, paneId);
    if (current == null ||
        paneId == null ||
        pane == null ||
        pane.tabIds.isNotEmpty) {
      return;
    }
    final next = removeWorkspacePane(current, paneId);
    if (next != null) _commitPaneLayout(next);
  }

  /// Temporarily releases pane focus while a dialog or another focus boundary
  /// owns keyboard input. Nested callers receive independent tokens and the
  /// original pane is restored only after the final token is released.
  String? unfocusPane() {
    final current = state.layout.paneLayout;
    final focusedPaneId = current?.focusedPaneId;
    if (current == null ||
        (focusedPaneId == null && _focusRestorationTokens.isEmpty)) {
      return null;
    }
    if (_focusRestorationTokens.isEmpty) {
      _focusRestorePaneId = focusedPaneId;
    }
    final token = _uuid.v4();
    _focusRestorationTokens.add(token);
    if (focusedPaneId != null) {
      _commitPaneLayout(
        WorkspacePaneLayout(root: current.root, focusedPaneId: null),
      );
    }
    return token;
  }

  void restorePaneFocus(String? token) {
    if (token == null || !_focusRestorationTokens.remove(token)) return;
    final current = state.layout.paneLayout;
    if (current == null) {
      _clearFocusRestoration();
      return;
    }
    if (current.focusedPaneId != null) {
      _clearFocusRestoration();
      return;
    }
    if (_focusRestorationTokens.isNotEmpty) return;
    final restorePaneId = _focusRestorePaneId;
    _clearFocusRestoration();
    if (findWorkspacePane(current.root, restorePaneId) == null) return;
    _commitPaneLayout(
      WorkspacePaneLayout(root: current.root, focusedPaneId: restorePaneId),
    );
  }

  void _clearFocusRestoration() {
    _focusRestorationTokens.clear();
    _focusRestorePaneId = null;
  }

  void _commitPaneLayout(WorkspacePaneLayout paneLayout) {
    final layout = WorktreeTabLayout(
      tabs: state.layout.tabs,
      activeTabId: state.layout.activeTabId,
      paneLayout: paneLayout,
      pinnedAgentIds: state.layout.pinnedAgentIds,
    );
    state = WorktreeTabLayoutState(
      layout: layout,
      terminalsVerified: state.terminalsVerified,
    );
    _persist(layout);
  }

  /// Records the daemon-assigned terminal id for a terminal tab once its
  /// `terminal.create.request` resolves.
  void setTerminalId(String tabId, String terminalId) {
    _mutate(
      (tabs) => [
        for (final tab in tabs)
          if (tab.tabId == tabId)
            tab.copyWith(lastKnownTerminalId: terminalId)
          else
            tab,
      ],
    );
  }

  void clearTerminalId(String tabId) {
    _mutate(
      (tabs) => [
        for (final tab in tabs)
          if (tab.tabId == tabId && tab.kind == WorktreeTabKind.terminal)
            WorktreeTab(tabId: tab.tabId, kind: WorktreeTabKind.terminal)
          else
            tab,
      ],
    );
  }

  /// Finds-or-creates the tab for [agentId] and activates it — used by
  /// notification click-through and "select after create" flows.
  void focusAgent(String agentId, {bool pin = false}) {
    final existing = state.layout.tabs
        .where((t) => t.kind == WorktreeTabKind.agent && t.agentId == agentId)
        .firstOrNull;
    if (existing != null) {
      setActiveTab(existing.tabId);
      if (pin) pinAgent(agentId);
      return;
    }
    final tabId = buildDeterministicWorkspaceTabId(
      WorkspaceAgentTabTarget(agentId: agentId),
    );
    _mutate(
      (tabs) => [
        ...tabs,
        WorktreeTab(
          tabId: tabId,
          kind: WorktreeTabKind.agent,
          agentId: agentId,
        ),
      ],
      nextActive: (_) => tabId,
    );
    if (pin) pinAgent(agentId);
  }

  void pinAgent(String agentId) {
    final normalized = agentId.trim();
    if (normalized.isEmpty ||
        state.layout.pinnedAgentIds.contains(normalized)) {
      return;
    }
    _setPinnedAgentIds({...state.layout.pinnedAgentIds, normalized});
  }

  void unpinAgent(String agentId) {
    final normalized = agentId.trim();
    if (!state.layout.pinnedAgentIds.contains(normalized)) return;
    _setPinnedAgentIds({...state.layout.pinnedAgentIds}..remove(normalized));
  }

  void _setPinnedAgentIds(Set<String> pinnedAgentIds) {
    final layout = WorktreeTabLayout(
      tabs: state.layout.tabs,
      activeTabId: state.layout.activeTabId,
      paneLayout: state.layout.paneLayout,
      pinnedAgentIds: Set.unmodifiable(pinnedAgentIds),
    );
    state = WorktreeTabLayoutState(
      layout: layout,
      terminalsVerified: state.terminalsVerified,
    );
    _persist(layout);
  }

  /// Paseo `prepareWorkspaceTab` parity for route open intents. Target
  /// identity is stable, so repeated terminal/draft/setup links focus the
  /// existing tab. `draft:new` is the one exception: it always receives a
  /// fresh draft id before opening.
  String? focusOpenIntentTarget(WorkspaceTabTarget requestedTarget) {
    var target = normalizeWorkspaceTabTarget(requestedTarget);
    if (target == null) return null;
    if (target case WorkspaceDraftTabTarget(draftId: 'new')) {
      target = WorkspaceDraftTabTarget(draftId: _uuid.v4());
    }

    final existing = state.layout.tabs
        .where(
          (tab) =>
              tab.workspaceTarget != null &&
              workspaceTabTargetsEqual(tab.workspaceTarget!, target!),
        )
        .firstOrNull;
    if (existing != null) {
      setActiveTab(existing.tabId);
      return existing.tabId;
    }

    final WorktreeTab tab;
    switch (target) {
      case WorkspaceDraftTabTarget():
        tab = WorktreeTab(tabId: target.draftId, kind: WorktreeTabKind.draft);
      case WorkspaceTerminalTabTarget():
        tab = WorktreeTab(
          tabId: buildDeterministicWorkspaceTabId(target),
          kind: WorktreeTabKind.terminal,
          lastKnownTerminalId: target.terminalId,
        );
      case WorkspaceSetupTabTarget():
        tab = WorktreeTab(
          tabId: buildDeterministicWorkspaceTabId(target),
          kind: WorktreeTabKind.setup,
          setupWorkspaceId: target.workspaceId,
        );
      case WorkspaceAgentTabTarget():
        focusAgent(target.agentId);
        return buildDeterministicWorkspaceTabId(target);
      case WorkspaceFileTabTarget():
        openFile(
          WorkspaceFileLocation(
            path: target.path,
            lineStart: target.lineStart,
            lineEnd: target.lineEnd,
          ),
        );
        return buildDeterministicWorkspaceTabId(target);
      case WorkspaceWorkingDiffTabTarget():
        showDiffTab(
          focusPath: target.focusPath,
          focusRequestId: target.focusRequestId,
        );
        return buildDeterministicWorkspaceTabId(target);
      case WorkspaceProviderSubagentTabTarget():
        focusProviderSubagent(target.parentAgentId, target.subagentId);
        return buildDeterministicWorkspaceTabId(target);
      case WorkspaceBrowserTabTarget() || WorkspaceCommitDiffTabTarget():
        return null;
    }
    _mutate((tabs) => [...tabs, tab], nextActive: (_) => tab.tabId);
    return tab.tabId;
  }

  void focusProviderSubagent(String parentAgentId, String subagentId) {
    final existing = state.layout.tabs
        .where(
          (tab) =>
              tab.kind == WorktreeTabKind.providerSubagent &&
              tab.parentAgentId == parentAgentId &&
              tab.subagentId == subagentId,
        )
        .firstOrNull;
    if (existing != null) {
      setActiveTab(existing.tabId);
      return;
    }
    final tabId = buildDeterministicWorkspaceTabId(
      WorkspaceProviderSubagentTabTarget(
        parentAgentId: parentAgentId,
        subagentId: subagentId,
      ),
    );
    _mutate(
      (tabs) => [
        ...tabs,
        WorktreeTab(
          tabId: tabId,
          kind: WorktreeTabKind.providerSubagent,
          parentAgentId: parentAgentId,
          subagentId: subagentId,
        ),
      ],
      nextActive: (_) => tabId,
    );
  }

  void openFile(WorkspaceFileLocation requestedLocation) {
    final location = normalizeWorkspaceFileLocation(requestedLocation);
    if (location == null) return;
    final existing = state.layout.tabs
        .where(
          (tab) =>
              tab.kind == WorktreeTabKind.file && tab.filePath == location.path,
        )
        .firstOrNull;
    if (existing != null) {
      _mutate(
        (tabs) => [
          for (final tab in tabs)
            if (tab.tabId == existing.tabId)
              WorktreeTab(
                tabId: tab.tabId,
                kind: WorktreeTabKind.file,
                filePath: location.path,
                lineStart: location.lineStart,
                lineEnd: location.lineEnd,
                fileNavigationRevision: tab.fileNavigationRevision + 1,
              )
            else
              tab,
        ],
        nextActive: (_) => existing.tabId,
      );
      return;
    }
    final tabId = buildDeterministicWorkspaceTabId(
      WorkspaceFileTabTarget(
        path: location.path,
        lineStart: location.lineStart,
        lineEnd: location.lineEnd,
      ),
    );
    _mutate(
      (tabs) => [
        ...tabs,
        WorktreeTab(
          tabId: tabId,
          kind: WorktreeTabKind.file,
          filePath: location.path,
          lineStart: location.lineStart,
          lineEnd: location.lineEnd,
        ),
      ],
      nextActive: (_) => tabId,
    );
  }

  void openFileInSidePane(WorkspaceFileLocation requestedLocation) {
    final location = normalizeWorkspaceFileLocation(requestedLocation);
    if (location == null) return;
    final paneLayout = state.layout.paneLayout;
    final sourcePaneId = paneLayout?.focusedPaneId;
    final sourceFocusedTabId = paneLayout == null
        ? null
        : findWorkspacePane(paneLayout.root, sourcePaneId)?.focusedTabId;
    final target = WorkspaceFileTabTarget(
      path: location.path,
      lineStart: location.lineStart,
      lineEnd: location.lineEnd,
    );
    final placement = resolveWorkspaceSideTargetPlacement(
      layout: paneLayout,
      sourcePaneId: sourcePaneId,
      tabs: [
        for (final tab in state.layout.tabs)
          if (tab.workspaceTarget case final target?)
            WorkspaceTab(tabId: tab.tabId, target: target, createdAt: 0),
      ],
      target: target,
    );

    openFile(location);
    if (placement.kind == WorkspaceSideFileOpenPlacementKind.openInSource) {
      return;
    }
    final fileTab = state.layout.tabs
        .where(
          (tab) =>
              tab.kind == WorktreeTabKind.file && tab.filePath == location.path,
        )
        .firstOrNull;
    if (fileTab == null || placement.paneId == null) return;

    switch (placement.kind) {
      case WorkspaceSideFileOpenPlacementKind.openInSource:
        return;
      case WorkspaceSideFileOpenPlacementKind.focusSidePane:
        final target = findWorkspacePane(
          state.layout.paneLayout!.root,
          placement.paneId,
        );
        moveTabToPaneIndex(
          tabId: fileTab.tabId,
          targetPaneId: placement.paneId!,
          insertionIndex: target?.tabIds.length ?? 0,
        );
      case WorkspaceSideFileOpenPlacementKind.splitSidePane:
        splitTabAtPosition(
          tabId: fileTab.tabId,
          targetPaneId: placement.paneId!,
          position: WorkspaceSplitDropPosition.right,
        );
    }
    final nextPaneLayout = state.layout.paneLayout;
    if (nextPaneLayout != null &&
        sourcePaneId != null &&
        sourceFocusedTabId != null &&
        sourceFocusedTabId != fileTab.tabId) {
      _commitPaneOrder(
        focusWorkspacePaneTab(
          layout: nextPaneLayout,
          paneId: sourcePaneId,
          tabId: sourceFocusedTabId,
        ),
        activeTabId: fileTab.tabId,
      );
    }
  }
}

final worktreeTabsProvider =
    NotifierProvider.family<
      WorktreeTabsNotifier,
      WorktreeTabLayoutState,
      String
    >(WorktreeTabsNotifier.new);
