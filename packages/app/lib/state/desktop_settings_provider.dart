import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/desktop/desktop_shell.dart';

/// Desktop-only preferences (tray residency behaviour).
class DesktopSettings {
  const DesktopSettings({
    this.autoStartAtLogin = false,
    this.keepRunningAfterQuit = true,
  });

  /// Reflects the OS registration state (launch_at_startup.isEnabled).
  final bool autoStartAtLogin;

  /// When false, quitting from the tray also stops the managed daemon.
  final bool keepRunningAfterQuit;

  DesktopSettings copyWith({bool? autoStartAtLogin, bool? keepRunningAfterQuit}) {
    return DesktopSettings(
      autoStartAtLogin: autoStartAtLogin ?? this.autoStartAtLogin,
      keepRunningAfterQuit: keepRunningAfterQuit ?? this.keepRunningAfterQuit,
    );
  }
}

class DesktopSettingsNotifier extends Notifier<DesktopSettings> {
  static const _keepRunningKey = 'desktop.keepRunningAfterQuit';

  @override
  DesktopSettings build() {
    if (isDesktopShell) Future.microtask(_load);
    return const DesktopSettings();
  }

  Future<void> _load() async {
    var autoStart = state.autoStartAtLogin;
    try {
      autoStart = await launchAtStartup.isEnabled();
    } catch (_) {
      // Keep the default when the platform query fails.
    }
    var keepRunning = state.keepRunningAfterQuit;
    try {
      final prefs = await SharedPreferences.getInstance();
      keepRunning = prefs.getBool(_keepRunningKey) ?? keepRunning;
    } catch (_) {}
    state = DesktopSettings(
      autoStartAtLogin: autoStart,
      keepRunningAfterQuit: keepRunning,
    );
  }

  Future<void> setAutoStartAtLogin(bool value) async {
    if (!isDesktopShell) return;
    try {
      if (value) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
    } catch (_) {
      // Fall through: reflect whatever the OS actually reports.
    }
    var actual = value;
    try {
      actual = await launchAtStartup.isEnabled();
    } catch (_) {}
    state = state.copyWith(autoStartAtLogin: actual);
  }

  Future<void> setKeepRunningAfterQuit(bool value) async {
    state = state.copyWith(keepRunningAfterQuit: value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keepRunningKey, value);
    } catch (_) {
      // Applies for this session even if persistence fails.
    }
  }

  /// Restores defaults: turns off OS-level auto-start (if applicable) and
  /// forgets the persisted `keepRunningAfterQuit` choice. Use from a
  /// destructive flow that has already confirmed with the user.
  Future<void> reset() async {
    if (isDesktopShell) {
      try {
        if (await launchAtStartup.isEnabled()) {
          await launchAtStartup.disable();
        }
      } catch (_) {
        // Fall through: we'll still reset the in-memory state and prefs.
      }
    }
    // Reflect whatever the OS actually reports for auto-start (could differ
    // from the requested value if the platform call failed silently).
    var autoStart = state.autoStartAtLogin;
    if (isDesktopShell) {
      try {
        autoStart = await launchAtStartup.isEnabled();
      } catch (_) {}
    }
    state = DesktopSettings(
      autoStartAtLogin: autoStart,
      keepRunningAfterQuit: true,
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keepRunningKey);
    } catch (_) {
      // State is already reset for this session even if persistence fails.
    }
  }
}

final desktopSettingsProvider =
    NotifierProvider<DesktopSettingsNotifier, DesktopSettings>(
  DesktopSettingsNotifier.new,
);
