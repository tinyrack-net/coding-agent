import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeName { auto, light, dark, zinc, midnight, claude, ghostty }

const paseoThemeCycleOrder = [
  AppThemeName.dark,
  AppThemeName.zinc,
  AppThemeName.midnight,
  AppThemeName.claude,
  AppThemeName.ghostty,
  AppThemeName.light,
];

class AppearanceNotifier extends Notifier<AppThemeName> {
  static const _key = 'appearance.theme';

  @override
  AppThemeName build() {
    Future.microtask(_load);
    return AppThemeName.dark;
  }

  Future<void> _load() async {
    try {
      final stored = (await SharedPreferences.getInstance()).getString(_key);
      final value = AppThemeName.values
          .where((candidate) => candidate.name == stored)
          .firstOrNull;
      if (value != null) state = value;
    } catch (_) {
      // Keep the session default when preferences are unavailable.
    }
  }

  Future<void> setTheme(AppThemeName theme) async {
    state = theme;
    try {
      await (await SharedPreferences.getInstance()).setString(_key, theme.name);
    } catch (_) {
      // The in-memory selection still applies for this session.
    }
  }

  void cycle() {
    final currentIndex = paseoThemeCycleOrder.indexOf(state);
    final nextIndex = (currentIndex + 1) % paseoThemeCycleOrder.length;
    unawaited(setTheme(paseoThemeCycleOrder[nextIndex]));
  }
}

final appearanceProvider = NotifierProvider<AppearanceNotifier, AppThemeName>(
  AppearanceNotifier.new,
);
