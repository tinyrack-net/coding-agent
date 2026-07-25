import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Client-local display-name overrides for sidebar worktree rows, keyed by
/// `SidebarWorktreeRow.key` (== `resolveWorktreeKey`). The daemon has no
/// server-side worktree-title field (only per-agent `title`, which doesn't
/// fit a row that can hold zero or several agents), so "rename" on a
/// worktree row is purely a local override — persisted like
/// `sidebar_pins_provider.dart`, falling back to the branch/agent name when
/// unset.
class WorktreeTitlesNotifier extends Notifier<Map<String, String>> {
  static const _key = 'sidebar.worktreeTitleOverrides';

  @override
  Map<String, String> build() {
    Future.microtask(_load);
    return const {};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      state = (jsonDecode(raw) as Map<String, Object?>).cast<String, String>();
    } catch (_) {
      // Keep the default (empty) map when prefs are unavailable/corrupt.
    }
  }

  Future<void> setTitle(String worktreeKey, String? title) async {
    final next = {...state};
    if (title == null || title.isEmpty) {
      next.remove(worktreeKey);
    } else {
      next[worktreeKey] = title;
    }
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(next));
    } catch (_) {
      // Applies for this session even if persistence fails.
    }
  }
}

final worktreeTitlesProvider =
    NotifierProvider<WorktreeTitlesNotifier, Map<String, String>>(
  WorktreeTitlesNotifier.new,
);
