import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../keyboard/shortcut_engine.dart';

class KeyboardShortcutOverridesNotifier extends Notifier<Map<String, String>> {
  static const storageKey = 'keyboard.shortcutOverrides';

  @override
  Map<String, String> build() {
    Future.microtask(_load);
    return const {};
  }

  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final stored = preferences.getString(storageKey);
      if (stored == null) return;
      final decoded = jsonDecode(stored);
      if (decoded is! Map) return;
      state = {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value as String,
      };
    } catch (_) {
      // Corrupt or unavailable preferences fall back to default bindings.
    }
  }

  Future<void> setOverride(String bindingId, String comboString) async {
    state = {...state, bindingId: comboString};
    await _persist();
  }

  Future<void> removeOverride(String bindingId) async {
    if (!state.containsKey(bindingId)) return;
    state = {...state}..remove(bindingId);
    await _persist();
  }

  Future<void> resetAll() async {
    state = const {};
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(storageKey);
    } catch (_) {
      // State remains reset for this process if persistence is unavailable.
    }
  }

  Future<void> _persist() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(storageKey, jsonEncode(state));
    } catch (_) {
      // Upstream applies overrides optimistically; keep the in-memory value.
    }
  }
}

final keyboardShortcutOverridesProvider =
    NotifierProvider<KeyboardShortcutOverridesNotifier, Map<String, String>>(
      KeyboardShortcutOverridesNotifier.new,
    );

final effectiveKeyboardShortcutBindingsProvider =
    Provider<List<ShortcutBinding>>((ref) {
      final overrides = ref.watch(keyboardShortcutOverridesProvider);
      return buildEffectiveShortcutBindings(overrides);
    });
