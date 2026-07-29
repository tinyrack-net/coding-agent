import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const sidebarOrderStorageKey = 'sidebar-project-workspace-order';

final class SidebarOrderState {
  const SidebarOrderState({
    this.projectOrder = const [],
    this.workspaceOrderByProject = const {},
    this.hydrated = false,
  });

  final List<String> projectOrder;
  final Map<String, List<String>> workspaceOrderByProject;
  final bool hydrated;

  List<String> workspaceOrder(String projectKey) =>
      workspaceOrderByProject[projectKey.trim()] ?? const [];

  Map<String, Object?> toJson() => {
    'version': 1,
    'projectOrder': projectOrder,
    'workspaceOrderByProject': workspaceOrderByProject,
  };
}

List<String> _normalizeKeys(Object? raw) {
  if (raw is! List) return const [];
  final seen = <String>{};
  return [
    for (final value in raw)
      if (value is String)
        if (value.trim() case final key when key.isNotEmpty && seen.add(key))
          key,
  ];
}

Map<String, List<String>> _normalizeWorkspaceOrders(Object? raw) {
  if (raw is! Map) return const {};
  return {
    for (final entry in raw.entries)
      if (entry.key is String)
        if ((entry.key as String).trim() case final key when key.isNotEmpty)
          key: List<String>.unmodifiable(_normalizeKeys(entry.value)),
  };
}

({String serverId, String projectKey})? _legacyScope(String raw) {
  final separator = raw.indexOf('::');
  if (separator < 0) return null;
  final serverId = raw.substring(0, separator).trim();
  final projectKey = raw.substring(separator + 2).trim();
  if (serverId.isEmpty || projectKey.isEmpty) return null;
  return (serverId: serverId, projectKey: projectKey);
}

SidebarOrderState migrateSidebarOrderState(Object? persisted) {
  if (persisted is! Map) return const SidebarOrderState(hydrated: true);
  final raw = persisted.cast<Object?, Object?>();
  final nested = raw['state'];
  final state = nested is Map ? nested.cast<Object?, Object?>() : raw;

  final projectOrder = [..._normalizeKeys(state['projectOrder'])];
  final seenProjects = projectOrder.toSet();
  final legacyProjectOrders = state['projectOrderByServerId'];
  if (legacyProjectOrders is Map) {
    for (final rawOrder in legacyProjectOrders.values) {
      for (final key in _normalizeKeys(rawOrder)) {
        if (seenProjects.add(key)) projectOrder.add(key);
      }
    }
  }

  final workspaceOrders = <String, List<String>>{
    ..._normalizeWorkspaceOrders(state['workspaceOrderByProject']),
  };
  final legacyWorkspaceOrders = state['workspaceOrderByServerAndProject'];
  if (legacyWorkspaceOrders is Map) {
    for (final entry in legacyWorkspaceOrders.entries) {
      if (entry.key is! String) continue;
      final scope = _legacyScope(entry.key as String);
      if (scope == null) continue;
      final merged = [...?workspaceOrders[scope.projectKey]];
      final seen = merged.toSet();
      for (final rawKey in _normalizeKeys(entry.value)) {
        final key = rawKey.startsWith('${scope.serverId}:')
            ? rawKey
            : '${scope.serverId}:$rawKey';
        if (seen.add(key)) merged.add(key);
      }
      workspaceOrders[scope.projectKey] = merged;
    }
  }

  return SidebarOrderState(
    projectOrder: List.unmodifiable(projectOrder),
    workspaceOrderByProject: Map<String, List<String>>.unmodifiable({
      for (final entry in workspaceOrders.entries)
        entry.key: List<String>.unmodifiable(entry.value),
    }),
    hydrated: true,
  );
}

class SidebarOrderNotifier extends Notifier<SidebarOrderState> {
  var _mutationVersion = 0;

  @override
  SidebarOrderState build() {
    Future.microtask(_load);
    return const SidebarOrderState();
  }

  Future<void> _load() async {
    final startedAtVersion = _mutationVersion;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(
        sidebarOrderStorageKey,
      );
      final decoded = raw == null ? null : jsonDecode(raw);
      if (ref.mounted && _mutationVersion == startedAtVersion) {
        state = migrateSidebarOrderState(decoded);
      }
    } on Object {
      if (ref.mounted && _mutationVersion == startedAtVersion) {
        state = const SidebarOrderState(hydrated: true);
      }
    }
  }

  Future<void> setProjectOrder(List<String> keys) async {
    _mutationVersion += 1;
    state = SidebarOrderState(
      projectOrder: List.unmodifiable(_normalizeKeys(keys)),
      workspaceOrderByProject: state.workspaceOrderByProject,
      hydrated: true,
    );
    await _persist();
  }

  Future<void> setWorkspaceOrder(String projectKey, List<String> keys) async {
    final scope = projectKey.trim();
    if (scope.isEmpty) return;
    _mutationVersion += 1;
    final next = Map<String, List<String>>.of(state.workspaceOrderByProject);
    next[scope] = List<String>.unmodifiable(_normalizeKeys(keys));
    state = SidebarOrderState(
      projectOrder: state.projectOrder,
      workspaceOrderByProject: Map.unmodifiable(next),
      hydrated: true,
    );
    await _persist();
  }

  Future<void> reconcileVisibleOrder({
    required List<String> projectOrder,
    required Map<String, List<String>> workspaceOrders,
  }) async {
    final normalizedProjects = _normalizeKeys(projectOrder);
    final nextWorkspaceOrders = Map<String, List<String>>.of(
      state.workspaceOrderByProject,
    );
    var changed = !_sameKeys(state.projectOrder, normalizedProjects);
    for (final entry in workspaceOrders.entries) {
      final scope = entry.key.trim();
      if (scope.isEmpty) continue;
      final normalized = _normalizeKeys(entry.value);
      if (_sameKeys(nextWorkspaceOrders[scope] ?? const [], normalized)) {
        continue;
      }
      changed = true;
      nextWorkspaceOrders[scope] = List.unmodifiable(normalized);
    }
    if (!changed) return;

    _mutationVersion += 1;
    state = SidebarOrderState(
      projectOrder: List.unmodifiable(normalizedProjects),
      workspaceOrderByProject: Map.unmodifiable(nextWorkspaceOrders),
      hydrated: true,
    );
    await _persist();
  }

  Future<void> _persist() async {
    await (await SharedPreferences.getInstance()).setString(
      sidebarOrderStorageKey,
      jsonEncode(state.toJson()),
    );
  }
}

bool _sameKeys(List<String> left, List<String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final sidebarOrderProvider =
    NotifierProvider<SidebarOrderNotifier, SidebarOrderState>(
      SidebarOrderNotifier.new,
    );
