import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'agents_provider.dart';
import 'daemon_providers.dart';

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
/// discriminated tab-target union scoped to what this app supports (no
/// browser/file/subagent/commit-diff — those need capabilities this app
/// doesn't have).
enum WorktreeTabKind {
  /// Not-yet-created agent session: an inline composer (provider/model/mode
  /// + optional first prompt). Converts in place to [agent] on submit.
  draft,

  /// A real agent conversation.
  agent,

  /// An independent daemon-backed terminal session.
  terminal,

  /// The worktree's "working diff" — singleton, reflects git state, not any
  /// one agent.
  diff,
}

class WorktreeTab {
  const WorktreeTab({
    required this.tabId,
    required this.kind,
    this.agentId,
    this.lastKnownTerminalId,
  });

  final String tabId;
  final WorktreeTabKind kind;

  /// Set when [kind] is [WorktreeTabKind.agent].
  final String? agentId;

  /// Set when [kind] is [WorktreeTabKind.terminal], once its
  /// `terminal.create.request` resolves — lets a future app restart
  /// re-subscribe instead of re-creating.
  final String? lastKnownTerminalId;

  WorktreeTab copyWith({String? lastKnownTerminalId}) => WorktreeTab(
        tabId: tabId,
        kind: kind,
        agentId: agentId,
        lastKnownTerminalId: lastKnownTerminalId ?? this.lastKnownTerminalId,
      );

  static WorktreeTab fromJson(Map<String, Object?> json) => WorktreeTab(
        tabId: json['tabId'] as String,
        kind: WorktreeTabKind.values.byName(json['kind'] as String),
        agentId: json['agentId'] as String?,
        lastKnownTerminalId: json['lastKnownTerminalId'] as String?,
      );

  Map<String, Object?> toJson() => {
        'tabId': tabId,
        'kind': kind.name,
        if (agentId != null) 'agentId': agentId,
        if (lastKnownTerminalId != null)
          'lastKnownTerminalId': lastKnownTerminalId,
      };

  @override
  bool operator ==(Object other) =>
      other is WorktreeTab &&
      other.tabId == tabId &&
      other.kind == kind &&
      other.agentId == agentId &&
      other.lastKnownTerminalId == lastKnownTerminalId;

  @override
  int get hashCode => Object.hash(tabId, kind, agentId, lastKnownTerminalId);
}

class WorktreeTabLayout {
  const WorktreeTabLayout({required this.tabs, this.activeTabId});

  static const empty = WorktreeTabLayout(tabs: []);

  final List<WorktreeTab> tabs;
  final String? activeTabId;

  static WorktreeTabLayout fromJson(Map<String, Object?> json) =>
      WorktreeTabLayout(
        tabs: ((json['tabs'] as List?) ?? const [])
            .cast<Map<String, Object?>>()
            .map(WorktreeTab.fromJson)
            .toList(),
        activeTabId: json['activeTabId'] as String?,
      );

  Map<String, Object?> toJson() => {
        'tabs': tabs.map((t) => t.toJson()).toList(),
        if (activeTabId != null) 'activeTabId': activeTabId,
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
      _tabsEqual(other.tabs);

  @override
  int get hashCode =>
      Object.hash(activeTabId, Object.hashAll(tabs));
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

/// The whole app's worktree tab layouts, persisted as one JSON blob in
/// `SharedPreferences` (mirrors `sidebar_pins_provider.dart`'s house style —
/// one key, one blob, loaded once — rather than per-worktree keys, so
/// rendering many sidebar rows doesn't mean many separate prefs reads).
class WorktreeTabLayoutsNotifier extends Notifier<Map<String, WorktreeTabLayout>> {
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
          entry.key:
              WorktreeTabLayout.fromJson(entry.value as Map<String, Object?>),
      };
    } catch (_) {
      // Keep the default (empty) map when prefs are unavailable/corrupt.
    }
  }

  Future<void> setLayout(String worktreePath, WorktreeTabLayout layout) async {
    // No-op if unchanged: a new Map is never `==` its predecessor by
    // reference, so an unconditional assignment here would make any watcher
    // that both reads and writes this provider (as WorktreeTabsNotifier
    // does) rebuild-and-rewrite itself forever in a self-sustaining chain of
    // microtasks. Comparing the per-worktree value (which does have real
    // equality) breaks that chain once the layout stabilizes.
    if (state[worktreePath] == layout) return;
    state = {...state, worktreePath: layout};
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

final worktreeTabLayoutsProvider = NotifierProvider<WorktreeTabLayoutsNotifier,
    Map<String, WorktreeTabLayout>>(WorktreeTabLayoutsNotifier.new);

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

  @override
  WorktreeTabLayoutState build() {
    final persisted = _cachedLayout ??
        (ref.read(worktreeTabLayoutsProvider)[worktreePath] ??
            WorktreeTabLayout.empty);

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
        if (tab.kind != WorktreeTabKind.agent || liveIds.contains(tab.agentId))
          tab,
    ];
    final covered = tabs
        .where((t) => t.kind == WorktreeTabKind.agent)
        .map((t) => t.agentId)
        .toSet();
    for (final agent in liveAgents) {
      if (!covered.contains(agent.agentId)) {
        tabs.add(WorktreeTab(
          tabId: _uuid.v4(),
          kind: WorktreeTabKind.agent,
          agentId: agent.agentId,
        ));
      }
    }

    // Terminal tabs need an async round-trip to verify against the daemon;
    // don't apply the empty-invariant yet if any are pending verification,
    // or a draft tab would flash in before the real answer arrives. Only
    // tabs with an already-known terminal id (loaded from persisted storage)
    // count as "pending" — one just added via addTab() has no id yet and
    // isn't a verification candidate, just a tab still being created.
    final hasPendingTerminals = persisted.tabs.any(
      (t) => t.kind == WorktreeTabKind.terminal && t.lastKnownTerminalId != null,
    );
    var terminalsVerified = true;
    if (hasPendingTerminals) {
      terminalsVerified = false;
      Future.microtask(_verifyTerminals);
    } else {
      tabs = _applyEmptyInvariant(tabs);
    }

    final layout = WorktreeTabLayout(
      tabs: tabs,
      activeTabId: _resolveActiveTabId(tabs, persisted.activeTabId),
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
        .where((t) =>
            t.kind == WorktreeTabKind.terminal && t.lastKnownTerminalId != null)
        .map((t) => t.tabId)
        .toSet();

    Set<String> liveTerminalIds;
    try {
      final client = ref.read(daemonClientProvider);
      final res =
          await client.request(MessageTypes.terminalListRequest, const {});
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
        ref.read(worktreeTabLayoutsProvider.notifier).setLayout(worktreePath, layout);
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
    final layout = WorktreeTabLayout(tabs: tabs, activeTabId: active);
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
  void showDiffTab() {
    final existing = state.layout.tabs
        .where((t) => t.kind == WorktreeTabKind.diff)
        .firstOrNull;
    if (existing != null) {
      setActiveTab(existing.tabId);
      return;
    }
    final tabId = _uuid.v4();
    _mutate(
      (tabs) => [...tabs, WorktreeTab(tabId: tabId, kind: WorktreeTabKind.diff)],
      nextActive: (_) => tabId,
    );
  }

  void closeTab(String tabId) {
    _mutate((tabs) => tabs.where((t) => t.tabId != tabId).toList());
  }

  /// Converts a draft tab in place into an agent tab (same tabId/position),
  /// matching Paseo's draft -> agent conversion.
  void retarget(String tabId, String agentId) {
    _mutate((tabs) {
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
    }, nextActive: (tabs) {
      final match = tabs.firstWhere(
        (t) => t.kind == WorktreeTabKind.agent && t.agentId == agentId,
        orElse: () => tabs.first,
      );
      return match.tabId;
    });
  }

  void setActiveTab(String tabId) {
    if (!state.layout.tabs.any((t) => t.tabId == tabId)) return;
    final layout = WorktreeTabLayout(tabs: state.layout.tabs, activeTabId: tabId);
    state = WorktreeTabLayoutState(
      layout: layout,
      terminalsVerified: state.terminalsVerified,
    );
    _persist(layout);
  }

  /// Records the daemon-assigned terminal id for a terminal tab once its
  /// `terminal.create.request` resolves.
  void setTerminalId(String tabId, String terminalId) {
    _mutate((tabs) => [
          for (final tab in tabs)
            if (tab.tabId == tabId)
              tab.copyWith(lastKnownTerminalId: terminalId)
            else
              tab,
        ]);
  }

  /// Finds-or-creates the tab for [agentId] and activates it — used by
  /// notification click-through and "select after create" flows.
  void focusAgent(String agentId) {
    final existing = state.layout.tabs
        .where((t) => t.kind == WorktreeTabKind.agent && t.agentId == agentId)
        .firstOrNull;
    if (existing != null) {
      setActiveTab(existing.tabId);
      return;
    }
    final tabId = _uuid.v4();
    _mutate(
      (tabs) => [
        ...tabs,
        WorktreeTab(tabId: tabId, kind: WorktreeTabKind.agent, agentId: agentId),
      ],
      nextActive: (_) => tabId,
    );
  }
}

final worktreeTabsProvider =
    NotifierProvider.family<WorktreeTabsNotifier, WorktreeTabLayoutState, String>(
  WorktreeTabsNotifier.new,
);
