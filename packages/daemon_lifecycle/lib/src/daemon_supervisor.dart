import 'package:agent_protocol/agent_protocol.dart';

import 'daemon_exe_resolver.dart';
import 'daemon_paths.dart';
import 'daemon_spawner.dart';
import 'daemon_stopper.dart';
import 'hello_probe.dart';
import 'versions.dart' as versions;

enum DaemonHealth { running, stopped }

final class DaemonStatus {
  const DaemonStatus({required this.health, this.hello, this.notice});

  final DaemonHealth health;
  final ServerHello? hello;

  /// Human-readable remark, e.g. "standalone daemon v0.1.0 (app bundles 0.2.0)".
  final String? notice;

  bool get isRunning => health == DaemonHealth.running;
}

/// App-side façade over probe/spawn/stop with the version-replacement policy.
class DaemonSupervisor {
  DaemonSupervisor({
    DaemonPaths? paths,
    this.host = '127.0.0.1',
    this.port = 6868,
    this.bundledVersion = versions.daemonVersion,
  }) : paths = paths ?? DaemonPaths();

  final DaemonPaths paths;
  final String host;
  final int port;
  final String bundledVersion;

  Future<DaemonStatus> status() async {
    final hello = await probeDaemon(host, port);
    if (hello == null) return const DaemonStatus(health: DaemonHealth.stopped);
    String? notice;
    if (!hello.desktopManaged && hello.daemonVersion != bundledVersion) {
      notice = 'standalone daemon v${hello.daemonVersion} '
          '(app bundles v$bundledVersion)';
    }
    return DaemonStatus(
        health: DaemonHealth.running, hello: hello, notice: notice);
  }

  /// Ensures a healthy daemon is available, applying the replacement policy:
  /// - healthy + same version → reuse
  /// - healthy + desktop-managed + different version → stop, spawn bundled
  /// - healthy + standalone (any version) → reuse untouched
  /// - not running → spawn bundled
  Future<DaemonStatus> ensureRunning() async {
    final hello = await probeDaemon(host, port);
    if (hello != null) {
      final outdated =
          hello.desktopManaged && hello.daemonVersion != bundledVersion;
      if (!outdated) return status();
      await stopDaemon(paths: paths, host: host, port: port);
    }
    final exe = await resolveDaemonExe();
    if (exe == null) {
      throw DaemonSpawnException(
          'daemon executable not found (bundled, dev build, or PATH)');
    }
    final spawned = await spawnDaemonDetached(
        exePath: exe, paths: paths, host: host, port: port);
    return DaemonStatus(health: DaemonHealth.running, hello: spawned);
  }

  /// Explicit user action from the tray: allowed even for standalone daemons.
  Future<void> stop() =>
      stopDaemon(paths: paths, host: host, port: port, force: true);

  Future<DaemonStatus> restart() async {
    await stop();
    return ensureRunning();
  }
}
