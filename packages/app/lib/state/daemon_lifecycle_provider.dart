import 'package:agent_daemon/agent_daemon.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart' show isLoopbackHost;
import '../core/desktop/desktop_shell.dart';
import '../core/desktop/tray_controller.dart';
import '../desktop/paseo_desktop_daemon_launch.dart'
    show isDesktopManagedDaemonRunning, shouldStopDesktopManagedDaemonOnQuit;
import 'connection_settings_provider.dart';
import 'desktop_settings_provider.dart';

/// Overridable in tests to simulate a desktop (or mobile) shell.
final desktopShellProvider = Provider<bool>((_) => isDesktopShell);

/// Overridable in tests to inject a fake supervisor.
final daemonSupervisorFactoryProvider =
    Provider<DaemonSupervisor Function(ConnectionSettings settings)>(
      (_) =>
          (settings) => DaemonSupervisor(
            host: settings.host,
            port: settings.port,
            fallbackSpawner: spawnEmbeddedDaemon,
          ),
    );

/// Manages the local daemon's lifetime on desktop. State is:
/// - `null` → remote/unmanaged (non-desktop shell or non-loopback host)
/// - [DaemonStatus] → local daemon supervised by this app
/// - error → spawn failure (message + log tail from [DaemonSpawnException])
class DaemonLifecycleNotifier extends AsyncNotifier<DaemonStatus?> {
  DaemonSupervisor? _supervisor;

  @override
  Future<DaemonStatus?> build() async {
    final settings = ref.watch(effectiveConnectionSettingsProvider);
    final desktop = ref.watch(desktopShellProvider);

    if (!desktop || settings.isRelay || !isLoopbackHost(settings.host)) {
      _supervisor = null;
      _wireTray();
      _pushToTray(null);
      return null;
    }

    final supervisor = ref.watch(daemonSupervisorFactoryProvider)(settings);
    _supervisor = supervisor;
    _wireTray();
    try {
      final status = await supervisor.ensureRunning();
      _pushToTray(status);
      return status;
    } on DaemonSpawnException {
      // Surface as AsyncError; DaemonSpawnException.toString() carries the
      // message plus the daemon.log tail for the UI.
      _pushToTray(const DaemonStatus(health: DaemonHealth.stopped));
      rethrow;
    }
  }

  /// Tray menu action: restart the local daemon (spawns bundled if needed).
  Future<void> restart() async {
    final supervisor = _supervisor;
    if (supervisor == null) return;
    state = const AsyncLoading<DaemonStatus?>();
    state = await AsyncValue.guard(() async {
      final status = await supervisor.restart();
      _pushToTray(status);
      return status;
    });
    if (state case AsyncError()) {
      _pushToTray(const DaemonStatus(health: DaemonHealth.stopped));
    }
  }

  /// Tray menu action: stop the daemon (explicit user intent, so allowed
  /// even for standalone daemons).
  Future<void> stopDaemon() async {
    final supervisor = _supervisor;
    if (supervisor == null) return;
    state = await AsyncValue.guard(() async {
      await supervisor.stop();
      final status = await supervisor.status();
      _pushToTray(status);
      return status;
    });
  }

  void _wireTray() {
    final tray = TrayController.instance;
    tray.onRestartDaemon = restart;
    tray.onStopDaemon = stopDaemon;
    tray.onQuit = _onQuit;
  }

  /// Quit flow: leave the daemon alive unless the user disabled
  /// keepRunningAfterQuit — and, even then, only stop one this app started.
  ///
  /// A daemon the user launched themselves is not ours to kill just because
  /// they closed the window. Upstream guards on exactly this
  /// (`isDesktopManagedDaemonRunning`), and both halves of the rule live in
  /// `desktop/paseo_desktop_daemon_launch.dart`.
  Future<void> _onQuit() async {
    final supervisor = _supervisor;
    if (supervisor == null) return;
    if (!shouldStopDesktopManagedDaemonOnQuit(
      ref.read(desktopSettingsProvider),
    )) {
      return;
    }
    if (!isDesktopManagedDaemonRunning(state.value)) return;
    await supervisor.stop();
  }

  void _pushToTray(DaemonStatus? status) {
    TrayController.instance.updateStatus(status);
  }
}

final daemonLifecycleProvider =
    AsyncNotifierProvider<DaemonLifecycleNotifier, DaemonStatus?>(
      DaemonLifecycleNotifier.new,
      // No Riverpod auto-retry: a spawn failure is surfaced once and the daemon
      // client's own reconnect loop does the retrying (see daemonClientProvider).
      retry: (retryCount, error) => null,
    );
