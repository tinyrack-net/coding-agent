import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:window_manager/window_manager.dart';

import 'tray_controller.dart';

/// Guard for all desktop-plugin calls (tray, window, autostart). Mobile and
/// web builds must never reach plugin code paths.
bool get isDesktopShell => !kIsWeb && (Platform.isWindows || Platform.isMacOS);

/// Passed by launch-at-login so the app starts tray-resident, window hidden.
const String hiddenLaunchFlag = '--hidden';

const String _appName = 'Coding Agent';

/// Close button hides the window instead of quitting; the app keeps living in
/// the tray. Real quit goes through the tray menu (TrayController.quit).
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
}

/// Sets up tray residency for desktop builds: prevent-close-to-tray, tray
/// icon + menu, and launch-at-login registration. No-op off desktop.
Future<void> initDesktopShell(List<String> args) async {
  if (!isDesktopShell) return;

  await windowManager.ensureInitialized();
  await windowManager.setPreventClose(true);
  windowManager.addListener(_HideOnCloseListener());

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
