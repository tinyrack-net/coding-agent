import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'explorer_checkout_context.dart';

const explorerTabMemoryStorageKey = 'tinyrack.panel.explorer-tabs';

enum WorkspaceExplorerTab { changes, files, pullRequest }

String? buildExplorerCheckoutKey(String serverId, String cwd) {
  final trimmedServerId = serverId.trim();
  final trimmedCwd = cwd.trim();
  if (trimmedServerId.isEmpty || trimmedCwd.isEmpty) return null;
  return '$trimmedServerId::$trimmedCwd';
}

WorkspaceExplorerTab coerceExplorerTabForCheckout(
  WorkspaceExplorerTab tab, {
  required bool isGit,
}) {
  if (!isGit && tab == WorkspaceExplorerTab.changes) {
    return WorkspaceExplorerTab.files;
  }
  return tab;
}

WorkspaceExplorerTab resolveExplorerTabForCheckout({
  required String serverId,
  required String cwd,
  required bool isGit,
  required Map<String, WorkspaceExplorerTab> explorerTabByCheckout,
}) {
  final key = buildExplorerCheckoutKey(serverId, cwd);
  final stored = key == null ? null : explorerTabByCheckout[key];
  final next =
      stored ??
      (isGit ? WorkspaceExplorerTab.changes : WorkspaceExplorerTab.files);
  return coerceExplorerTabForCheckout(next, isGit: isGit);
}

String _wireName(WorkspaceExplorerTab tab) => switch (tab) {
  WorkspaceExplorerTab.changes => 'changes',
  WorkspaceExplorerTab.files => 'files',
  WorkspaceExplorerTab.pullRequest => 'pr',
};

WorkspaceExplorerTab? _tabFromWire(Object? value) => switch (value) {
  'changes' => WorkspaceExplorerTab.changes,
  'files' => WorkspaceExplorerTab.files,
  'pr' => WorkspaceExplorerTab.pullRequest,
  _ => null,
};

final class ExplorerTabMemoryState {
  const ExplorerTabMemoryState({
    this.activeTab = WorkspaceExplorerTab.changes,
    this.byCheckout = const {},
  });

  final WorkspaceExplorerTab activeTab;
  final Map<String, WorkspaceExplorerTab> byCheckout;

  ExplorerTabMemoryState copyWith({
    WorkspaceExplorerTab? activeTab,
    Map<String, WorkspaceExplorerTab>? byCheckout,
  }) => ExplorerTabMemoryState(
    activeTab: activeTab ?? this.activeTab,
    byCheckout: byCheckout ?? this.byCheckout,
  );
}

abstract interface class ExplorerTabMemoryStorage {
  Future<ExplorerTabMemoryState?> load();

  Future<void> save(ExplorerTabMemoryState state);
}

final class SharedPreferencesExplorerTabMemoryStorage
    implements ExplorerTabMemoryStorage {
  const SharedPreferencesExplorerTabMemoryStorage();

  @override
  Future<ExplorerTabMemoryState?> load() async {
    final encoded = (await SharedPreferences.getInstance()).getString(
      explorerTabMemoryStorageKey,
    );
    if (encoded == null) return null;
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) return null;
    final activeTab = _tabFromWire(decoded['activeTab']);
    final rawByCheckout = decoded['byCheckout'];
    final byCheckout = <String, WorkspaceExplorerTab>{};
    if (rawByCheckout is Map) {
      for (final entry in rawByCheckout.entries) {
        if (entry.key is! String) continue;
        final tab = _tabFromWire(entry.value);
        if (tab != null) byCheckout[entry.key as String] = tab;
      }
    }
    return ExplorerTabMemoryState(
      activeTab: activeTab ?? WorkspaceExplorerTab.changes,
      byCheckout: Map.unmodifiable(byCheckout),
    );
  }

  @override
  Future<void> save(ExplorerTabMemoryState state) async {
    await (await SharedPreferences.getInstance()).setString(
      explorerTabMemoryStorageKey,
      jsonEncode({
        'activeTab': _wireName(state.activeTab),
        'byCheckout': {
          for (final entry in state.byCheckout.entries)
            entry.key: _wireName(entry.value),
        },
      }),
    );
  }
}

final explorerTabMemoryStorageProvider = Provider<ExplorerTabMemoryStorage>(
  (_) => const SharedPreferencesExplorerTabMemoryStorage(),
);

final class ExplorerTabMemoryNotifier extends Notifier<ExplorerTabMemoryState> {
  var _changedSinceBuild = false;

  @override
  ExplorerTabMemoryState build() {
    _changedSinceBuild = false;
    scheduleMicrotask(_hydrate);
    return const ExplorerTabMemoryState();
  }

  Future<void> _hydrate() async {
    ExplorerTabMemoryState? stored;
    try {
      stored = await ref.read(explorerTabMemoryStorageProvider).load();
    } catch (_) {
      return;
    }
    if (!ref.mounted || _changedSinceBuild || stored == null) return;
    state = stored;
  }

  void setForCheckout({
    required ExplorerCheckoutContext checkout,
    required WorkspaceExplorerTab tab,
  }) {
    _changedSinceBuild = true;
    final resolved = coerceExplorerTabForCheckout(tab, isGit: checkout.isGit);
    final key = buildExplorerCheckoutKey(checkout.serverId, checkout.cwd);
    final current = key == null ? null : state.byCheckout[key];
    final next = state.copyWith(
      activeTab: resolved,
      byCheckout: key == null || current == resolved
          ? state.byCheckout
          : Map.unmodifiable({...state.byCheckout, key: resolved}),
    );
    state = next;
    unawaited(
      ref.read(explorerTabMemoryStorageProvider).save(next).catchError((_) {}),
    );
  }
}

final explorerTabMemoryProvider =
    NotifierProvider<ExplorerTabMemoryNotifier, ExplorerTabMemoryState>(
      ExplorerTabMemoryNotifier.new,
    );
