import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

import 'daemon_paths.dart';
import 'hello_probe.dart';

class DaemonSpawnException implements Exception {
  DaemonSpawnException(this.message, {this.logTail});

  final String message;
  final String? logTail;

  @override
  String toString() =>
      'DaemonSpawnException: $message${logTail == null ? '' : '\n--- daemon.log ---\n$logTail'}';
}

/// Spawns the daemon fully detached (survives the app) marked as
/// desktop-managed, then polls the hello probe until healthy.
Future<ServerHello> spawnDaemonDetached({
  required String exePath,
  required DaemonPaths paths,
  String host = '127.0.0.1',
  int port = 6868,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final process = await Process.start(
    exePath,
    ['--host', host, '--port', '$port', '--data-dir', paths.dataDir],
    mode: ProcessStartMode.detached,
    environment: {...Platform.environment, desktopManagedEnvVar: '1'},
  );

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final hello = await probeDaemon(host, port);
    if (hello != null) return hello;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  // Give the failed spawn no chance to linger half-broken.
  try {
    process.kill();
  } catch (_) {}
  throw DaemonSpawnException(
    'daemon did not become healthy within ${timeout.inSeconds}s '
    '(port $port in use by another process, or startup crash?)',
    logTail: await _tailLog(paths.logFile),
  );
}

Future<String?> _tailLog(String path, {int lines = 40}) async {
  try {
    final all = await File(path).readAsLines();
    return all.skip(all.length > lines ? all.length - lines : 0).join('\n');
  } catch (_) {
    return null;
  }
}
