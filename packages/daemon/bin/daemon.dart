import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/agent_daemon.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';

Future<void> main(List<String> args) async {
  final dataDir = _argValue(args, '--data-dir');
  final cliHost = _argValue(args, '--host');
  final cliPort = _argValue(args, '--port');
  final cliHostnames =
      _argValue(args, '--hostnames') ?? _argValue(args, '--allowed-hosts');
  final cliListen =
      _argValue(args, '--listen') ??
      (cliHost != null || cliPort != null
          ? '${cliHost ?? '127.0.0.1'}:${cliPort ?? '6868'}'
          : null);
  final config = loadDaemonRuntimeConfig(
    home: dataDir,
    cliListen: cliListen,
    cliHostnames: cliHostnames,
    cliWebUiDistDir: _argValue(args, '--web-ui-dist-dir'),
  );
  final paths = DaemonPaths(dataDir: config.home);
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
    logFlush = logFlush
        .then((_) {
          logSink.writeln(line);
          return logSink.flush();
        })
        .catchError((_) {});
  }

  await runZonedGuarded(
    () => _run(
      args,
      paths: paths,
      config: config,
      log: log,
      logSink: logSink,
      waitForLogFlush: () => logFlush,
    ),
    (error, stack) => log('uncaught error: $error\n$stack'),
  );
}

Future<void> _run(
  List<String> args, {
  required DaemonPaths paths,
  required DaemonRuntimeConfig config,
  required void Function(String) log,
  required IOSink logSink,
  required Future<void> Function() waitForLogFlush,
}) async {
  final host = config.host;
  final port = config.port;
  final token = _argValue(args, '--token');
  final desktopManaged = Platform.environment[desktopManagedEnvVar] == '1';

  Future<void> flushLog() async {
    try {
      await waitForLogFlush();
      await logSink.flush();
      await logSink.close();
    } catch (_) {}
  }

  DaemonServerHandle handle;
  try {
    final speechLogger = CallbackSpeechLogger(log);
    final speechService = createOpenAiSpeechRuntime(
      runtimeConfig: config.speech,
      openAiConfig: config.openAiSpeech,
      logger: speechLogger,
    );
    handle = await startDaemonServer(
      paths: paths,
      host: host,
      port: port,
      token: token,
      passwordHash: config.auth?.passwordHash,
      allowedOrigins: config.corsAllowedOrigins,
      hostnames: config.hostnames,
      trustedProxies: config.trustedProxies,
      webUiEnabled: config.webUiEnabled,
      webUiDistDir: config.webUiDistDir,
      serviceProxyPublicBaseUrl: config.serviceProxy.publicBaseUrl,
      serviceProxyListen: config.serviceProxy.standaloneListen,
      dataDir: config.home,
      desktopManaged: desktopManaged,
      enableTerminalAgentHooks: config.enableTerminalAgentHooks,
      relayConfig: config.relay,
      appBaseUrl: config.appBaseUrl,
      speechService: speechService,
      log: log,
      onShutdownRequested: () async {
        await flushLog();
        exit(0);
      },
    );
  } on LockHeldException {
    await flushLog();
    exit(11);
  } catch (error, stack) {
    log('failed to start daemon: $error\n$stack');
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
