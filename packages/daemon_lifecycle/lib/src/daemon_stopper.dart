import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import 'daemon_paths.dart';
import 'hello_probe.dart';
import 'pid_lock.dart';
import 'process_ops.dart';

class StopRefusedException implements Exception {
  StopRefusedException(this.reason);

  final String reason;

  @override
  String toString() => 'StopRefusedException: $reason';
}

/// Stops a running daemon: graceful shutdown RPC first, then process-tree
/// kill, then stale-lock cleanup.
///
/// Policy: a daemon that is NOT desktop-managed (a user's standalone install)
/// is never stopped implicitly — [force] must be set for explicit user action.
Future<void> stopDaemon({
  required DaemonPaths paths,
  String host = '127.0.0.1',
  int port = 6868,
  String? token,
  bool force = false,
  Duration exitWait = const Duration(seconds: 5),
}) async {
  final lock = PidLock(paths.lockFile);
  final lockData = await lock.read();

  final hello = await probeDaemon(host, port, token: token);
  final desktopManaged =
      (hello?.desktopManaged ?? false) || (lockData?.desktopManaged ?? false);
  if (!desktopManaged && !force) {
    throw StopRefusedException(
      'daemon is not desktop-managed; refusing to stop without force',
    );
  }

  if (hello != null) {
    await sendLifecycleRequest(
      host,
      port,
      MessageTypes.daemonShutdownRequest,
      token: token,
    );
    final pid = hello.pid ?? lockData?.pid;
    if (pid != null) {
      final deadline = DateTime.now().add(exitWait);
      while (DateTime.now().isBefore(deadline)) {
        if (!await isPidAlive(pid)) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (await isPidAlive(pid)) await killTree(pid);
    }
  } else if (lockData != null && await isPidAlive(lockData.pid)) {
    await killTree(lockData.pid);
  }

  // Clean up an orphaned lock so the next spawn is unobstructed.
  final remaining = await lock.read();
  if (remaining != null && !await isPidAlive(remaining.pid)) {
    try {
      await File(paths.lockFile).delete();
    } catch (_) {}
  }
}
