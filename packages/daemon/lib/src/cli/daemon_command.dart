import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;

import '../server/daemon_auth.dart';
import '../server/daemon_config.dart';
import 'pair_command.dart';

const daemonStopTimeout = Duration(seconds: 15);

typedef DaemonExeResolver = Future<String?> Function();
typedef DaemonRuntimeExecutableResolver = Future<String?> Function(int pid);
typedef DaemonStarter =
    Future<ServerHello> Function({
      required String exePath,
      required DaemonPaths paths,
      required String host,
      required int port,
      required List<String> additionalArguments,
      required Map<String, String> additionalEnvironment,
      required Duration timeout,
    });
typedef DaemonStopper =
    Future<void> Function({
      required DaemonPaths paths,
      required String host,
      required int port,
      required String? token,
      required bool force,
      required Duration exitWait,
    });
typedef PasswordReader = Future<String?> Function(String prompt);

final class DaemonCommandRuntime {
  const DaemonCommandRuntime({
    this.resolveExe = resolveDaemonExe,
    this.resolveRuntimeExecutable = resolveDaemonRuntimeExecutable,
    this.start = _startDaemon,
    this.stop = stopDaemon,
    this.readPassword = _readPassword,
    this.environment,
  });

  final DaemonExeResolver resolveExe;
  final DaemonRuntimeExecutableResolver resolveRuntimeExecutable;
  final DaemonStarter start;
  final DaemonStopper stop;
  final PasswordReader readPassword;
  final Map<String, String>? environment;
}

// coverage:ignore-start
// OS/process boundary. The injected wrapper is covered by command tests and
// the real native executable path is covered by daemon lifecycle E2E.
Future<ServerHello> _startDaemon({
  required String exePath,
  required DaemonPaths paths,
  required String host,
  required int port,
  required List<String> additionalArguments,
  required Map<String, String> additionalEnvironment,
  required Duration timeout,
}) => spawnDaemonDetached(
  exePath: exePath,
  paths: paths,
  host: host,
  port: port,
  additionalArguments: additionalArguments,
  additionalEnvironment: additionalEnvironment,
  timeout: timeout,
);

Future<String?> _readPassword(String prompt) async {
  stdout.write('$prompt: ');
  stdin.echoMode = false;
  try {
    return stdin.readLineSync();
  } finally {
    stdin.echoMode = true;
    stdout.writeln();
  }
}
// coverage:ignore-end

Future<String?> resolveDaemonRuntimeExecutable(int processId) async {
  if (processId <= 0) return null;
  if (Platform.isWindows) {
    for (final command in [
      [
        'powershell.exe',
        '-NoProfile',
        '-Command',
        '(Get-CimInstance Win32_Process -Filter "ProcessId = $processId").ExecutablePath',
      ],
      [
        'powershell.exe',
        '-NoProfile',
        '-Command',
        '(Get-Process -Id $processId).Path',
      ],
    ]) {
      try {
        final result = await Process.run(
          command.first,
          command.sublist(1),
        ).timeout(const Duration(seconds: 5));
        final resolved = (result.stdout as String).trim();
        if (result.exitCode == 0 && resolved.isNotEmpty) return resolved;
      } on Object {
        // Probe the next Windows process API.
      }
    }
    return null;
  }
  // coverage:ignore-start
  final result = await Process.run('ps', [
    '-o',
    'comm=',
    '-p',
    '$processId',
  ]).timeout(const Duration(seconds: 5));
  final resolved = (result.stdout as String).trim();
  return result.exitCode == 0 && resolved.isNotEmpty ? resolved : null;
  // coverage:ignore-end
}

Future<int> runDaemonCommand({
  required List<String> arguments,
  DaemonCommandRuntime runtime = const DaemonCommandRuntime(),
  bool topLevel = false,
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final out = writeOutput ?? stdout.write;
  final err = writeError ?? stderr.write;
  if (arguments.length == 1 &&
      (arguments.first == '--help' || arguments.first == '-h')) {
    out('${_usage(topLevel: topLevel)}\n');
    return 0;
  }
  if (arguments.isEmpty) {
    err('${_usage(topLevel: topLevel)}\n');
    return 64;
  }
  final command = arguments.first;
  if (arguments
      .sublist(1)
      .any((argument) => argument == '--help' || argument == '-h')) {
    out('${_usage(command: command, topLevel: topLevel)}\n');
    return 0;
  }
  final parsed = _parse(arguments.sublist(1));
  if (parsed case _ParseFailure(:final message)) {
    err('$message\n${_usage(command: command, topLevel: topLevel)}\n');
    return 64;
  }
  final options = parsed as _DaemonOptions;
  try {
    return await switch (command) {
      'start' => _start(options, runtime, out),
      'status' => _status(options, runtime, out),
      'stop' => _stop(options, runtime, out),
      'restart' => _restart(options, runtime, out),
      'set-password' => _setPassword(options, runtime, out),
      'pair' => runPairCommand(
        options: PairCommandOptions(home: options.home, json: options.json),
        environment: runtime.environment,
        writeOutput: out,
        writeError: err,
        terminalColumns: stdout.hasTerminal ? stdout.terminalColumns : null,
      ),
      _ => _unknown(command, err, topLevel: topLevel),
    };
  } on FormatException catch (error) {
    err('${error.message}\n');
    return 64;
  } on Object catch (error) {
    err('${_message(error)}\n');
    return 1;
  }
}

int _unknown(
  String command,
  void Function(String) err, {
  required bool topLevel,
}) {
  err(
    'Unknown daemon command: $command\n'
    '${_usage(topLevel: topLevel)}\n',
  );
  return 64;
}

Future<int> _start(
  _DaemonOptions options,
  DaemonCommandRuntime runtime,
  void Function(String) out,
) async {
  final launch = await _resolveLaunch(options, runtime);
  if (options.foreground) {
    // coverage:ignore-start
    // inheritStdio is a process-boundary behavior covered by the packaged CLI
    // smoke test; unit tests exercise the equivalent detached launch contract.
    final process = await Process.start(
      launch.exe,
      launch.arguments,
      mode: ProcessStartMode.inheritStdio,
      environment: {...Platform.environment, ...launch.environment},
    );
    return process.exitCode;
    // coverage:ignore-end
  }
  final hello = await runtime.start(
    exePath: launch.exe,
    paths: launch.paths,
    host: launch.config.host,
    port: launch.config.port,
    additionalArguments: launch.additionalArguments,
    additionalEnvironment: launch.environment,
    timeout: const Duration(seconds: 30),
  );
  if (options.json) {
    out(
      '${jsonEncode({'action': 'started', 'home': launch.config.home, 'pid': hello.pid, 'listen': launch.config.listen, 'logPath': launch.paths.logFile})}\n',
    );
  } else {
    out('Daemon starting in background (PID ${hello.pid ?? 'unknown'}).\n');
    out('Logs: ${launch.paths.logFile}\n');
  }
  return 0;
}

Future<int> _status(
  _DaemonOptions options,
  DaemonCommandRuntime runtime,
  void Function(String) out,
) async {
  final config = loadDaemonRuntimeConfig(
    home: options.home,
    environment: runtime.environment,
  );
  final paths = DaemonPaths(dataDir: config.home);
  final lock = await PidLock(paths.lockFile).read();
  final host = lock?.host ?? config.host;
  final port = lock?.port ?? config.port;
  final alive = lock != null && await isPidAlive(lock.pid);
  final hello = await probeDaemon(host, port, token: _daemonPassword(runtime));
  final daemonExecutable = lock == null
      ? null
      : await runtime.resolveRuntimeExecutable(lock.pid);
  final local = alive
      ? (hello == null ? 'unresponsive' : 'running')
      : lock == null
      ? 'stopped'
      : 'stale_pid';
  final configuredPassword =
      (runtime.environment ?? Platform.environment)['TINYRACK_PASSWORD']
          ?.trim();
  final connected = hello != null
      ? 'reachable'
      : alive && config.auth != null
      ? (configuredPassword == null || configuredPassword.isEmpty
            ? 'auth_required'
            : 'auth_failed')
      : 'unreachable';
  final providers = await Future.wait(
    const [
      ('Claude', 'claude'),
      ('Codex', 'codex'),
      ('OpenCode', 'opencode'),
    ].map(_providerStatus),
  );
  final result = <String, Object?>{
    'serverId': await _readServerId(config.home),
    'localDaemon': local,
    'connectedDaemon': connected,
    'home': config.home,
    'listen': '$host:$port',
    'relay': config.relay.enabled
        ? '${config.relay.publicUseTls ? 'wss' : 'ws'}://${config.relay.publicEndpoint}'
        : 'disabled',
    'hostname': lock == null ? null : Platform.localHostname,
    'pid': lock?.pid,
    'startedAt': lock == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            lock.startedAtMs,
          ).toIso8601String(),
    'owner': lock == null
        ? null
        : '${Platform.environment['USERNAME'] ?? '?'}@${Platform.localHostname}',
    'logPath': paths.logFile,
    'daemonNode': daemonExecutable ?? (hello == null ? '-' : 'unknown'),
    'cliNode': Platform.resolvedExecutable,
    'cliVersion': '0.1.0',
    'daemonVersion': hello?.daemonVersion,
    'desktopManaged': lock?.desktopManaged ?? false,
    'providers': providers,
  };
  if (options.json) {
    out('${const JsonEncoder.withIndent('  ').convert(result)}\n');
  } else {
    final rows = <(String, Object?)>[
      ('Server ID', result['serverId']),
      ('Local Daemon', local),
      ('Connected Daemon', connected),
      ('Home', config.home),
      ('Listen', result['listen']),
      ('Relay', result['relay']),
      ('Hostname', result['hostname']),
      ('PID', lock?.pid),
      ('Started', result['startedAt']),
      ('Owner', result['owner']),
      ('Logs', paths.logFile),
      ('Daemon Node', result['daemonNode']),
      ('CLI Node', result['cliNode']),
      ('CLI', result['cliVersion']),
      ('Daemon Version', result['daemonVersion']),
    ];
    out('KEY                 VALUE\n');
    for (final (key, value) in rows) {
      out('${key.padRight(20)}${value ?? '-'}\n');
    }
    out('\nProviders\n');
    for (final provider in providers) {
      out(
        '  ${(provider['label'] as String).padRight(17)}'
        '${provider['path'] ?? 'not found'}\n',
      );
    }
  }
  return 0;
}

Future<int> _stop(
  _DaemonOptions options,
  DaemonCommandRuntime runtime,
  void Function(String) out,
) async {
  final config = loadDaemonRuntimeConfig(
    home: options.home,
    environment: runtime.environment,
  );
  final paths = DaemonPaths(dataDir: config.home);
  final before = await PidLock(paths.lockFile).read();
  final host = before?.host ?? config.host;
  final port = before?.port ?? config.port;
  final timeout = options.timeout ?? daemonStopTimeout;
  await runtime.stop(
    paths: paths,
    host: host,
    port: port,
    token: _daemonPassword(runtime),
    force: options.force,
    exitWait: timeout,
  );
  final result = {
    'action': 'stopped',
    'home': config.home,
    'pid': before?.pid,
    'forced': options.force,
    'usedLifecycleRpc': before != null,
    'reason': before == null ? 'not_running' : 'stopped',
    'message': before == null
        ? 'Local daemon was not running'
        : 'Local daemon stopped (PID ${before.pid})',
  };
  _writeResult(result, options.json, out);
  return 0;
}

Future<int> _restart(
  _DaemonOptions options,
  DaemonCommandRuntime runtime,
  void Function(String) out,
) async {
  final config = loadDaemonRuntimeConfig(
    home: options.home,
    environment: runtime.environment,
  );
  final paths = DaemonPaths(dataDir: config.home);
  final before = await PidLock(paths.lockFile).read();
  final host = before?.host ?? config.host;
  final port = before?.port ?? config.port;
  try {
    await runtime.stop(
      paths: paths,
      host: host,
      port: port,
      token: _daemonPassword(runtime),
      force: options.force,
      exitWait: options.timeout ?? daemonStopTimeout,
    );
  } on Object {
    if (options.force) rethrow;
    await runtime.stop(
      paths: paths,
      host: host,
      port: port,
      token: _daemonPassword(runtime),
      force: true,
      exitWait: options.timeout ?? daemonStopTimeout,
    );
  }
  final launch = await _resolveLaunch(options, runtime);
  final hello = await runtime.start(
    exePath: launch.exe,
    paths: launch.paths,
    host: launch.config.host,
    port: launch.config.port,
    additionalArguments: launch.additionalArguments,
    additionalEnvironment: launch.environment,
    timeout: const Duration(seconds: 30),
  );
  final result = {
    'action': 'restarted',
    'home': launch.config.home,
    'pid': hello.pid,
    'message':
        'Local daemon restarted (${before == null ? 'not running' : 'PID ${before.pid}'} -> ${hello.pid == null ? 'unknown PID' : 'PID ${hello.pid}'})',
  };
  _writeResult(result, options.json, out);
  return 0;
}

String? _daemonPassword(DaemonCommandRuntime runtime) {
  final value =
      (runtime.environment ?? Platform.environment)['TINYRACK_PASSWORD']
          ?.trim();
  return value == null || value.isEmpty ? null : value;
}

Future<int> _setPassword(
  _DaemonOptions options,
  DaemonCommandRuntime runtime,
  void Function(String) out,
) async {
  final first = await runtime.readPassword('New daemon password');
  if (first == null) throw const FormatException('Password update cancelled');
  if (first.isEmpty) throw const FormatException('Password cannot be empty');
  final second = await runtime.readPassword('Confirm daemon password');
  if (second == null) throw const FormatException('Password update cancelled');
  if (first != second) throw const FormatException('Passwords do not match');
  final home = p.normalize(
    p.absolute(
      options.home ??
          resolveTinyrackHome(runtime.environment ?? Platform.environment),
    ),
  );
  final file = File(p.join(home, 'config.json'));
  final root = file.existsSync()
      ? Map<String, Object?>.from(jsonDecode(await file.readAsString()) as Map)
      : <String, Object?>{'version': 1};
  final daemon = _object(root['daemon']);
  final auth = _object(daemon['auth']);
  root['daemon'] = {
    ...daemon,
    'auth': {...auth, 'password': hashDaemonPassword(first)},
  };
  await file.parent.create(recursive: true);
  final temporary = File('${file.path}.tmp-$pid');
  await temporary.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(root)}\n',
    flush: true,
  );
  if (await file.exists()) await file.delete();
  await temporary.rename(file.path);
  final result = {
    'action': 'password_set',
    'configPath': file.path,
    'restartCommand': 'coding-agent daemon restart',
    'message':
        'Password written to ${file.path}\n'
        'Restart the daemon for the change to take effect.\n'
        'Run: coding-agent daemon restart',
  };
  if (options.json) {
    out('${jsonEncode(result)}\n');
  } else {
    out('${result['message']}\n');
  }
  return 0;
}

Future<_Launch> _resolveLaunch(
  _DaemonOptions options,
  DaemonCommandRuntime runtime,
) async {
  if (options.listen != null && options.port != null) {
    throw const FormatException('Cannot use --listen and --port together');
  }
  final listen =
      options.listen ??
      (options.port == null ? null : '127.0.0.1:${options.port}');
  final config = loadDaemonRuntimeConfig(
    home: options.home,
    environment: runtime.environment,
    cliListen: listen,
    cliRelayEnabled: options.relay,
    cliRelayUseTls: options.relayUseTls,
    cliWebUiEnabled: options.webUi,
    cliHostnames: options.hostnames,
  );
  final exe = await runtime.resolveExe();
  if (exe == null) {
    throw StateError(
      'Could not find the daemon executable. Run tool/build_daemon.ps1 first.',
    );
  }
  final extras = <String>[
    if (options.relay == false) '--no-relay',
    if (options.relayUseTls == true) '--relay-use-tls',
    if (options.mcp == false) '--no-mcp',
    if (options.injectMcp == false) '--no-inject-mcp',
    if (options.webUi == true) '--web-ui',
    if (options.webUi == false) '--no-web-ui',
    if (options.hostnames case final hostnames?) ...['--hostnames', hostnames],
  ];
  return _Launch(
    exe: exe,
    paths: DaemonPaths(dataDir: config.home),
    config: config,
    additionalArguments: extras,
    environment: {
      'TINYRACK_HOME': config.home,
      'TINYRACK_LISTEN': config.listen,
      if (options.relayUseTls != null)
        'TINYRACK_RELAY_USE_TLS': '${options.relayUseTls}',
      if (options.webUi != null) 'TINYRACK_WEB_UI_ENABLED': '${options.webUi}',
    },
  );
}

Future<Map<String, Object?>> _providerStatus((String, String) binary) async {
  final (label, name) = binary;
  final result = await Process.run(Platform.isWindows ? 'where.exe' : 'which', [
    name,
  ]);
  final path = result.exitCode == 0
      ? (result.stdout as String).split(RegExp(r'\r?\n')).first.trim()
      : null;
  String? version;
  if (path != null && path.isNotEmpty) {
    try {
      final versionResult = await Process.run(path, const [
        '--version',
      ]).timeout(const Duration(seconds: 5));
      if (versionResult.exitCode == 0) {
        final resolved = (versionResult.stdout as String).trim();
        if (resolved.isNotEmpty) version = resolved;
      }
    } on Object {
      version = null;
    }
  }
  return {'label': label, 'path': path, 'version': version, 'source': 'local'};
}

Future<String?> _readServerId(String home) async {
  final file = File(p.join(home, 'server-id'));
  if (!await file.exists()) return null;
  final value = (await file.readAsString()).trim();
  return value.isEmpty ? null : value;
}

void _writeResult(
  Map<String, Object?> result,
  bool json,
  void Function(String) out,
) {
  if (json) {
    out('${jsonEncode(result)}\n');
  } else {
    out('${result['action']}  ${result['home']}\n${result['message']}\n');
  }
}

String _message(Object error) => switch (error) {
  DaemonSpawnException(:final message) => message,
  StopRefusedException(:final reason) => reason,
  _ => error.toString().replaceFirst(RegExp(r'^[^:]+: '), ''),
};

Map<String, Object?> _object(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

sealed class _Parsed {}

final class _ParseFailure extends _Parsed {
  _ParseFailure(this.message);
  final String message;
}

final class _DaemonOptions extends _Parsed {
  _DaemonOptions();
  String? home;
  String? listen;
  int? port;
  String? hostnames;
  Duration? timeout;
  bool json = false;
  bool force = false;
  bool foreground = false;
  bool? relay;
  bool? relayUseTls;
  bool? mcp;
  bool? injectMcp;
  bool? webUi;
}

_Parsed _parse(List<String> arguments) {
  final value = _DaemonOptions();
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    String? next() => index + 1 < arguments.length ? arguments[++index] : null;
    switch (argument) {
      case '--json':
        value.json = true;
      case '--force':
        value.force = true;
      case '--foreground':
        value.foreground = true;
      case '--no-relay':
        value.relay = false;
      case '--relay-use-tls':
        value.relayUseTls = true;
      case '--no-mcp':
        value.mcp = false;
      case '--no-inject-mcp':
        value.injectMcp = false;
      case '--web-ui':
        value.webUi = true;
      case '--no-web-ui':
        value.webUi = false;
      case '--home':
        value.home = next();
        if (value.home == null) return _ParseFailure('--home requires a path');
      case '--listen':
        value.listen = next();
        if (value.listen == null) {
          return _ParseFailure('--listen requires a target');
        }
      case '--port':
        final raw = next();
        value.port = raw == null ? null : int.tryParse(raw);
        if (value.port == null || value.port! < 0 || value.port! > 65535) {
          return _ParseFailure('Invalid port value: ${raw ?? ''}');
        }
      case '--hostnames':
      case '--allowed-hosts':
        value.hostnames = next();
        if (value.hostnames == null) {
          return _ParseFailure('$argument requires a value');
        }
      case '--timeout':
      case '--kill-timeout':
        final raw = next();
        final seconds = raw == null ? null : double.tryParse(raw);
        if (seconds == null || !seconds.isFinite || seconds <= 0) {
          return _ParseFailure('Invalid timeout value: ${raw ?? ''}');
        }
        if (argument == '--timeout') {
          value.timeout = Duration(milliseconds: (seconds * 1000).ceil());
        }
      default:
        return _ParseFailure('Unknown option: $argument');
    }
  }
  return value;
}

final class _Launch {
  const _Launch({
    required this.exe,
    required this.paths,
    required this.config,
    required this.additionalArguments,
    required this.environment,
  });
  final String exe;
  final DaemonPaths paths;
  final DaemonRuntimeConfig config;
  final List<String> additionalArguments;
  final Map<String, String> environment;

  List<String> get arguments => [
    '--host',
    config.host,
    '--port',
    '${config.port}',
    '--data-dir',
    paths.dataDir,
    ...additionalArguments,
  ];
}

String _usage({String? command, bool topLevel = false}) {
  final root = topLevel ? 'coding-agent' : 'coding-agent daemon';
  return switch (command) {
    'start' =>
      'Usage: $root start [--home <path>] [--listen <target> | --port <port>] [--foreground]',
    'status' => 'Usage: $root status [--home <path>] [--json]',
    'stop' =>
      'Usage: $root stop [--home <path>] [--timeout <seconds>] [--kill-timeout <seconds>] [--force] [--json]',
    'restart' =>
      'Usage: $root restart [start options] [--timeout <seconds>] [--force] [--json]',
    'set-password' => 'Usage: $root set-password [--home <path>] [--json]',
    'pair' => 'Usage: $root pair [--home <path>] [--json]',
    _ => 'Usage: $root <start|status|stop|restart|set-password|pair> ...',
  };
}
