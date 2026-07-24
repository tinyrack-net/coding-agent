import 'dart:io';

import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_shell.dart';

/// Owns the tray icon and its context menu. Deliberately thin: all daemon
/// actions are injected callbacks (wired by the lifecycle provider) so this
/// plugin-heavy class stays out of tests.
class TrayController with TrayListener {
  TrayController._();

  static final TrayController instance = TrayController._();

  /// Wired by daemonLifecycleProvider.
  Future<void> Function()? onRestartDaemon;
  Future<void> Function()? onStopDaemon;

  /// Called during quit; stops the daemon when keepRunningAfterQuit is off.
  Future<void> Function()? onQuit;

  DaemonStatus? _status;
  bool _initialized = false;

  Future<void> init() async {
    if (!isDesktopShell || _initialized) return;
    _initialized = true;
    trayManager.addListener(this);
    await trayManager.setIcon(
      Platform.isWindows
          ? 'assets/tray/tray_icon.ico'
          : 'assets/tray/tray_icon.png',
      // macOS: monochrome template image adapts to the menu bar. Untested.
      isTemplate: Platform.isMacOS,
    );
    await trayManager.setToolTip('Coding Agent');
    await _rebuildMenu();
  }

  /// Rebuilds the menu so the status line reflects the daemon state.
  /// `null` means remote/unmanaged (app connects elsewhere).
  Future<void> updateStatus(DaemonStatus? status) async {
    _status = status;
    if (!_initialized) return;
    await _rebuildMenu();
  }

  String get _statusLabel {
    final status = _status;
    if (status == null) return 'Daemon: remote (unmanaged)';
    if (!status.isRunning) return 'Daemon: stopped';
    final notice = status.notice;
    if (notice != null) return 'Daemon: $notice';
    final hello = status.hello;
    final version = hello?.daemonVersion;
    final pid = hello?.pid;
    return 'Daemon: running'
        '${version == null ? '' : ' v$version'}'
        '${pid == null ? '' : ' (pid $pid)'}';
  }

  Future<void> _rebuildMenu() async {
    final managed = _status != null;
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: _MenuKeys.open, label: 'Open Coding Agent'),
          MenuItem.separator(),
          MenuItem(key: _MenuKeys.status, label: _statusLabel, disabled: true),
          MenuItem(
            key: _MenuKeys.restart,
            label: 'Restart daemon',
            disabled: !managed,
          ),
          MenuItem(
            key: _MenuKeys.stop,
            label: 'Stop daemon',
            disabled: !managed,
          ),
          MenuItem.separator(),
          MenuItem(key: _MenuKeys.quit, label: 'Quit'),
        ],
      ),
    );
  }

  @override
  void onTrayIconMouseDown() {
    if (Platform.isWindows) {
      // Windows convention: left-click opens the app window.
      _showWindow();
    } else {
      // macOS convention: clicking the status item shows the menu. Untested.
      trayManager.popUpContextMenu();
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _MenuKeys.open:
        _showWindow();
      case _MenuKeys.restart:
        onRestartDaemon?.call();
      case _MenuKeys.stop:
        onStopDaemon?.call();
      case _MenuKeys.quit:
        quit();
    }
  }

  Future<void> _showWindow() async {
    if (Platform.isMacOS) {
      // Restore Dock presence removed by the hide-on-close listener. Untested.
      await windowManager.setSkipTaskbar(false);
    }
    await windowManager.show();
    await windowManager.focus();
  }

  /// Real application exit: tear down the tray, optionally stop the managed
  /// daemon, then destroy the window (setPreventClose off so it terminates).
  Future<void> quit() async {
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    try {
      await onQuit?.call();
    } catch (_) {
      // Quitting must not hang on a daemon-stop failure.
    }
    await windowManager.destroy();
  }
}

abstract final class _MenuKeys {
  static const open = 'open';
  static const status = 'status';
  static const restart = 'restart';
  static const stop = 'stop';
  static const quit = 'quit';
}
