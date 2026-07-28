import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'launch_at_startup.dart';
import 'tray_controller.dart';

/// Guard for all desktop-plugin calls (tray, window, autostart). Mobile and
/// web builds must never reach plugin code paths.
bool get isDesktopShell => !kIsWeb && (Platform.isWindows || Platform.isMacOS);

/// True when the custom WinUI-style title bar (see `title_bar.dart`) should
/// be shown. Windows-only: macOS/mobile keep native window chrome, since
/// WinUI caption-button conventions don't apply there.
bool get isWindowsDesktop => !kIsWeb && Platform.isWindows;

/// Passed by launch-at-login so the app starts tray-resident, window hidden.
const String hiddenLaunchFlag = '--hidden';

const String _appName = 'Coding Agent';

/// Whether the app window currently has OS focus. Updated by
/// [_HideOnCloseListener]'s `onWindowFocus`/`onWindowBlur` overrides; read
/// directly (no Riverpod indirection needed) wherever a point-in-time check
/// is enough, e.g. deciding whether to fire an OS notification.
final windowFocusedNotifier = ValueNotifier<bool>(true);

/// Close button hides the window instead of quitting; the app keeps living in
/// the tray. Real quit goes through the tray menu (TrayController.quit).
/// Also tracks OS focus into [windowFocusedNotifier].
class _HideOnCloseListener with WindowListener {
  @override
  void onWindowClose() async {
    await windowManager.hide();
    if (Platform.isMacOS) {
      // macOS: also drop the Dock icon while hidden so the app feels
      // tray-resident. Untested on macOS.
      await windowManager.setSkipTaskbar(true);
    }
  }

  @override
  void onWindowFocus() => windowFocusedNotifier.value = true;

  @override
  void onWindowBlur() => windowFocusedNotifier.value = false;
}

/// Sets up tray residency for desktop builds: prevent-close-to-tray, tray
/// icon + menu, and launch-at-login registration. No-op off desktop.
Future<void> initDesktopShell(List<String> args) async {
  if (!isDesktopShell) return;

  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  windowManager.addListener(_HideOnCloseListener());

  if (isWindowsDesktop) {
    // Draw our own WinUI-style caption bar (see AppTitleBar) instead of the
    // OS-native one, while keeping native resize borders/snap behavior.
    await windowManager.setTitleBarStyle(
      TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
  }

  final startHidden = args.contains(hiddenLaunchFlag);
  await windowManager.waitUntilReadyToShow(null, () async {
    if (startHidden) {
      await windowManager.hide();
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
  });

  await TrayController.instance.init();

  launchAtStartup.setup(
    appName: _appName,
    appPath: Platform.resolvedExecutable,
    args: [hiddenLaunchFlag],
  );
}
