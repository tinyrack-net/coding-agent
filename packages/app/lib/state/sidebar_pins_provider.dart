import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Locally-pinned worktree keys (see `resolveWorktreeKey` /
/// `SidebarWorktreeRow.key`) for the sidebar's "Pinned" section — a pure
/// client-side convenience (no daemon/backend involvement), persisted in
/// `SharedPreferences`. Pinning is per-worktree, not per-agent: it hoists a
/// whole row (and every agent sharing that cwd) out of its project section.
class SidebarPinsNotifier extends Notifier<Set<String>> {
  static const _key = 'sidebar.pinnedAgentIds';

  @override
  Set<String> build() {
    Future.microtask(_load);
    return const {};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final ids = (jsonDecode(raw) as List).cast<String>().toSet();
      state = ids;
    } catch (_) {
      // Keep the default (empty) set when prefs are unavailable/corrupt.
    }
  }

  Future<void> togglePin(String worktreeKey) async {
    final next = {...state};
    if (!next.remove(worktreeKey)) next.add(worktreeKey);
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(next.toList()));
    } catch (_) {
      // Applies for this session even if persistence fails.
    }
  }

  bool isPinned(String worktreeKey) => state.contains(worktreeKey);
}

final sidebarPinsProvider = NotifierProvider<SidebarPinsNotifier, Set<String>>(
  SidebarPinsNotifier.new,
);
