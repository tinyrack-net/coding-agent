import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/agent_daemon.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';

Future<void> main(List<String> args) async {
  final dataDir = _argValue(args, '--data-dir');
  final paths = DaemonPaths(dataDir: dataDir);
  final logFilePath = _argValue(args, '--log-file') ?? paths.logFile;

  // The desktop app spawns the daemon detached (stdio lost), so mirror every
  // message to a log file; keep stdout for foreground runs.
  final logFile = File(logFilePath);
  await logFile.parent.create(recursive: true);
  final logSink = logFile.openWrite(mode: FileMode.append);
  // Serialize flushes so lines hit disk promptly even when running detached.
  var logFlush = Future<void>.value();
  void log(String message) {
    final line = '${DateTime.now().toIso8601String()} $message';
    stdout.writeln(line);
    logSink.writeln(line);
    logFlush = logFlush.then((_) => logSink.flush()).catchError((_) {});
  }

  await runZonedGuarded(
    () => _run(args, paths: paths, log: log, logSink: logSink),
    (error, stack) => log('uncaught error: $error\n$stack'),
  );
}

Future<void> _run(
  List<String> args, {
  required DaemonPaths paths,
  required void Function(String) log,
  required IOSink logSink,
}) async {
  final host = _argValue(args, '--host') ?? '127.0.0.1';
  final port = int.parse(_argValue(args, '--port') ?? '6868');
  final token = _argValue(args, '--token');
  final dataDir = _argValue(args, '--data-dir');
  final desktopManaged = Platform.environment[desktopManagedEnvVar] == '1';

  Future<void> flushLog() async {
    try {
      await logSink.flush();
      await logSink.close();
    } catch (_) {}
  }

  DaemonServerHandle handle;
  try {
    handle = await startDaemonServer(
      paths: paths,
      host: host,
      port: port,
      token: token,
      dataDir: dataDir,
      desktopManaged: desktopManaged,
      log: log,
      onShutdownRequested: () async {
        await flushLog();
        exit(0);
      },
    );
  } on LockHeldException {
    await flushLog();
    exit(11);
  } catch (e) {
    await flushLog();
    exit(1);
  }

  ProcessSignal.sigint.watch().listen((_) async {
    await handle.stop();
    await flushLog();
    exit(0);
  });
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await handle.stop();
      await flushLog();
      exit(0);
    });
  }
}

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}
