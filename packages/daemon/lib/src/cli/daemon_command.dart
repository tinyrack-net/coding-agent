import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;

import '../server/daemon_auth.dart';
import '../server/daemon_config.dart';
import 'cli_output.dart';
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
  final parsed = _parse(command, arguments.sublist(1));
  if (parsed case _ParseFailure(:final message)) {
    err('$message\n${_usage(command: command, topLevel: topLevel)}\n');
    return 64;
  }
  final options = parsed as _DaemonOptions;
  try {
    return await switch (command) {
      'start' => _start(options, runtime, out),
      'status' => _writeDaemonResult(
        await _status(options, runtime),
        options.output,
        out,
      ),
      'stop' => _writeDaemonResult(
        await _stop(options, runtime),
        options.output,
        out,
      ),
      'restart' => _writeDaemonResult(
        await _restart(options, runtime),
        options.output,
        out,
      ),
      'set-password' => _writeDaemonResult(
        await _setPassword(options, runtime),
        options.output,
        out,
      ),
      'pair' => runPairCommand(
        options: PairCommandOptions(
          home: options.home,
          json: options.output.format == 'json',
        ),
        environment: runtime.environment,
        writeOutput: out,
        writeError: err,
        terminalColumns: stdout.hasTerminal ? stdout.terminalColumns : null,
      ),
      _ => _unknown(command, err, topLevel: topLevel),
    };
  } on DaemonCommandException catch (error) {
    if (command == 'start' || command == 'pair') {
      err('${error.message}\n');
    } else {
      err(
        '${renderCliError(code: error.code, message: error.message, details: error.details, options: options.output)}\n',
      );
    }
    return 1;
  } on FormatException catch (error) {
    if (_isDaemonResultCommand(command)) {
      final failure = _daemonUnhandledFailure(command, error);
      err(
        '${renderCliError(code: failure.code, message: failure.message, details: failure.details, options: options.output)}\n',
      );
      return 1;
    }
    err('${error.message}\n');
    return 64;
  } on Object catch (error) {
    if (_isDaemonResultCommand(command)) {
      final failure = _daemonUnhandledFailure(command, error);
      err(
        '${renderCliError(code: failure.code, message: failure.message, details: failure.details, options: options.output)}\n',
      );
      return 1;
    }
    err('${_message(error)}\n');
    return 1;
  }
}

bool _isDaemonResultCommand(String command) => const {
  'status',
  'stop',
  'restart',
  'set-password',
}.contains(command);

DaemonCommandException _daemonUnhandledFailure(String command, Object error) {
  final message = _message(error);
  return switch (command) {
    'stop' => DaemonCommandException(
      'STOP_FAILED',
      'Failed to stop local daemon: $message',
    ),
    'restart' => DaemonCommandException(
      'RESTART_FAILED',
      'Failed to restart local daemon: $message',
    ),
    _ => DaemonCommandException('UNKNOWN_ERROR', message),
  };
}

final class DaemonCommandException implements Exception {
  const DaemonCommandException(this.code, this.message, [this.details]);

  final String code;
  final String message;
  final String? details;
}

int _writeDaemonResult(
  CliOutputResult result,
  CliOutputOptions options,
  void Function(String) out,
) {
  final rendered = renderCliOutput(result, options);
  if (rendered.isNotEmpty) out('$rendered\n');
  return 0;
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
  out('Daemon starting in background (PID ${hello.pid ?? 'unknown'}).\n');
  out('Logs: ${launch.paths.logFile}\n');
  return 0;
}

Future<CliOutputResult> _status(
  _DaemonOptions options,
  DaemonCommandRuntime runtime,
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
  return _daemonStatusResult(result);
}

Future<CliOutputResult> _stop(
  _DaemonOptions options,
  DaemonCommandRuntime runtime,
) async {
  final config = loadDaemonRuntimeConfig(
    home: options.home,
    environment: runtime.environment,
  );
  final paths = DaemonPaths(dataDir: config.home);
  final before = await PidLock(paths.lockFile).read();
  final host = before?.host ?? config.host;
  final port = before?.port ?? config.port;
  final timeout = _parseDaemonTimeout(
    options.timeout,
    fallback: daemonStopTimeout,
    label: 'timeout',
  );
  _parseDaemonTimeout(
    options.killTimeout,
    fallback: const Duration(seconds: 3),
    label: 'kill-timeout',
  );
  try {
    await runtime.stop(
      paths: paths,
      host: host,
      port: port,
      token: _daemonPassword(runtime),
      force: options.force,
      exitWait: timeout,
    );
  } on Object catch (error) {
    throw DaemonCommandException(
      'STOP_FAILED',
      'Failed to stop local daemon: ${_message(error)}',
    );
  }
  final row = <String, Object?>{
    'action': before == null ? 'not_running' : 'stopped',
    'home': config.home,
    'pid': before?.pid.toString() ?? '-',
    'forced': before == null ? false : options.force,
    'usedLifecycleRpc': before != null,
    'reason': before == null ? 'not_running' : 'lifecycle_shutdown_rpc',
    'message': before == null
        ? 'Daemon is not running'
        : 'Local daemon stopped (PID ${before.pid})',
  };
  return CliOutputResult.single(row: row, schema: _daemonStopSchema);
}

Future<CliOutputResult> _restart(
  _DaemonOptions options,
  DaemonCommandRuntime runtime,
) async {
  final config = loadDaemonRuntimeConfig(
    home: options.home,
    environment: runtime.environment,
  );
  final paths = DaemonPaths(dataDir: config.home);
  final before = await PidLock(paths.lockFile).read();
  final host = before?.host ?? config.host;
  final port = before?.port ?? config.port;
  final timeout = _parseDaemonTimeout(
    options.timeout,
    fallback: daemonStopTimeout,
    label: 'timeout',
  );
  try {
    try {
      await runtime.stop(
        paths: paths,
        host: host,
        port: port,
        token: _daemonPassword(runtime),
        force: options.force,
        exitWait: timeout,
      );
    } on Object catch (error) {
      final isTimeout = _message(
        error,
      ).contains('Timed out waiting for daemon PID');
      if (options.force || !isTimeout) rethrow;
      await runtime.stop(
        paths: paths,
        host: host,
        port: port,
        token: _daemonPassword(runtime),
        force: true,
        exitWait: timeout,
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
    final row = <String, Object?>{
      'action': 'restarted',
      'home': launch.config.home,
      'pid': hello.pid?.toString() ?? '-',
      'message':
          'Local daemon restarted (${before == null ? 'not running' : 'PID ${before.pid}'} -> ${hello.pid == null ? 'unknown PID' : 'PID ${hello.pid}'})',
    };
    return CliOutputResult.single(row: row, schema: _daemonRestartSchema);
  } on DaemonCommandException {
    rethrow;
  } on Object catch (error) {
    throw DaemonCommandException(
      'RESTART_FAILED',
      'Failed to restart local daemon: ${_message(error)}',
    );
  }
}

String? _daemonPassword(DaemonCommandRuntime runtime) {
  final value =
      (runtime.environment ?? Platform.environment)['TINYRACK_PASSWORD']
          ?.trim();
  return value == null || value.isEmpty ? null : value;
}

Future<CliOutputResult> _setPassword(
  _DaemonOptions options,
  DaemonCommandRuntime runtime,
) async {
  final first = await runtime.readPassword('New daemon password');
  if (first == null) {
    throw const DaemonCommandException(
      'PASSWORD_CANCELLED',
      'Password update cancelled',
    );
  }
  if (first.isEmpty) {
    throw const DaemonCommandException(
      'PASSWORD_REQUIRED',
      'Password cannot be empty',
    );
  }
  final second = await runtime.readPassword('Confirm daemon password');
  if (second == null) {
    throw const DaemonCommandException(
      'PASSWORD_CANCELLED',
      'Password update cancelled',
    );
  }
  if (first != second) {
    throw const DaemonCommandException(
      'PASSWORD_MISMATCH',
      'Passwords do not match',
    );
  }
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
  final row = <String, Object?>{
    'action': 'password_set',
    'configPath': file.path,
    'restartCommand': 'coding-agent daemon restart',
    'message':
        'Password written to ${file.path}\n'
        'Restart the daemon for the change to take effect.\n'
        'Run: coding-agent daemon restart',
  };
  return CliOutputResult.single(row: row, schema: _daemonPasswordSchema);
}

Future<_Launch> _resolveLaunch(
  _DaemonOptions options,
  DaemonCommandRuntime runtime,
) async {
  if (options.listen != null && options.port != null) {
    throw const DaemonCommandException(
      'INVALID_OPTIONS',
      'Cannot use --listen and --port together',
    );
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

CliOutputResult _daemonStatusResult(Map<String, Object?> status) {
  final providers = [
    for (final value
        in status['providers'] is List
            ? status['providers']! as List
            : const <Object?>[])
      if (value is Map) Map<String, Object?>.from(value),
  ];
  final rows = <Map<String, Object?>>[
    {'key': 'Server ID', 'value': status['serverId'] ?? '-'},
    {'key': 'Local Daemon', 'value': status['localDaemon']},
    {'key': 'Connected Daemon', 'value': status['connectedDaemon']},
    {'key': 'Home', 'value': status['home']},
    {'key': 'Listen', 'value': status['listen']},
    {'key': 'Relay', 'value': status['relay']},
    {'key': 'Hostname', 'value': status['hostname'] ?? '-'},
    {'key': 'PID', 'value': status['pid']?.toString() ?? '-'},
    {'key': 'Started', 'value': status['startedAt'] ?? '-'},
    {'key': 'Owner', 'value': status['owner'] ?? '-'},
    {'key': 'Logs', 'value': status['logPath']},
    {'key': 'Daemon Node', 'value': status['daemonNode']},
    {'key': 'CLI Node', 'value': status['cliNode']},
    {'key': 'CLI', 'value': status['cliVersion']},
    {'key': 'Daemon Version', 'value': status['daemonVersion'] ?? '-'},
    {'key': '', 'value': ''},
    {'key': 'Providers', 'value': ''},
    for (final provider in providers)
      {
        'key': '  ${provider['label']}',
        'value': switch ((provider['path'], provider['version'])) {
          (null, _) => 'not found',
          (final path, null) => '$path (--version failed)',
          (final path, final version) => '$path ($version)',
        },
      },
  ];
  return CliOutputResult.list(
    rows: rows,
    schema: CliOutputSchema(
      idField: (row) => '${row['key']}',
      columns: [
        CliOutputColumn(header: 'KEY', field: (row) => row['key']),
        CliOutputColumn(header: 'VALUE', field: (row) => row['value']),
      ],
      serialize: (_) => status,
    ),
  );
}

final _daemonStopSchema = CliOutputSchema(
  idField: (row) => '${row['action']}',
  columns: [
    CliOutputColumn(header: 'STATUS', field: (row) => row['action']),
    CliOutputColumn(header: 'HOME', field: (row) => row['home']),
    CliOutputColumn(header: 'PID', field: (row) => row['pid']),
    CliOutputColumn(header: 'MESSAGE', field: (row) => row['message']),
  ],
);

final _daemonRestartSchema = CliOutputSchema(
  idField: (row) => '${row['action']}',
  columns: [
    CliOutputColumn(header: 'STATUS', field: (row) => row['action']),
    CliOutputColumn(header: 'HOME', field: (row) => row['home']),
    CliOutputColumn(header: 'PID', field: (row) => row['pid']),
    CliOutputColumn(header: 'MESSAGE', field: (row) => row['message']),
  ],
);

final _daemonPasswordSchema = CliOutputSchema(
  idField: (row) => '${row['action']}',
  columns: [
    CliOutputColumn(header: 'STATUS', field: (row) => row['action']),
    CliOutputColumn(header: 'CONFIG', field: (row) => row['configPath']),
    CliOutputColumn(header: 'RESTART', field: (row) => row['restartCommand']),
  ],
  renderHuman: (rows, _) => '${rows.single['message']}',
);

Duration _parseDaemonTimeout(
  String? raw, {
  required Duration fallback,
  required String label,
}) {
  if (raw == null || raw.trim().isEmpty) return fallback;
  final seconds = double.tryParse(raw);
  if (seconds == null || !seconds.isFinite || seconds <= 0) {
    throw DaemonCommandException(
      'INVALID_TIMEOUT',
      'Invalid $label value: $raw',
      '$label must be a positive number of seconds',
    );
  }
  return Duration(milliseconds: (seconds * 1000).ceil());
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
  String? timeout;
  String? killTimeout;
  CliOutputOptions output = const CliOutputOptions();
  bool force = false;
  bool foreground = false;
  bool? relay;
  bool? relayUseTls;
  bool? mcp;
  bool? injectMcp;
  bool? webUi;
}

_Parsed _parse(String command, List<String> arguments) {
  final value = _DaemonOptions();
  final fullOutput = const {
    'status',
    'stop',
    'restart',
    'set-password',
  }.contains(command);
  var format = 'table';
  var json = false;
  var quiet = false;
  var headers = true;
  var color = true;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    String? next() => index + 1 < arguments.length ? arguments[++index] : null;
    switch (argument) {
      case '--json' when fullOutput || command == 'pair':
        json = true;
      case '-q' || '--quiet' when fullOutput:
        quiet = true;
      case '--no-headers' when fullOutput:
        headers = false;
      case '--no-color' when fullOutput:
        color = false;
      case '-o' || '--format' when fullOutput:
        final raw = next();
        if (raw == null) return _ParseFailure('$argument requires a value');
        try {
          format = normalizeCliOutputFormat(raw);
        } on FormatException catch (error) {
          return _ParseFailure(error.message);
        }
      case '--force' when command == 'stop' || command == 'restart':
        value.force = true;
      case '--foreground' when command == 'start':
        value.foreground = true;
      case '--no-relay' when command == 'start' || command == 'restart':
        value.relay = false;
      case '--relay-use-tls' when command == 'start':
        value.relayUseTls = true;
      case '--no-mcp' when command == 'start' || command == 'restart':
        value.mcp = false;
      case '--no-inject-mcp' when command == 'start' || command == 'restart':
        value.injectMcp = false;
      case '--web-ui' when command == 'start' || command == 'restart':
        value.webUi = true;
      case '--no-web-ui' when command == 'start' || command == 'restart':
        value.webUi = false;
      case '--home':
        value.home = next();
        if (value.home == null) return _ParseFailure('--home requires a path');
      case '--listen' when command == 'start' || command == 'restart':
        value.listen = next();
        if (value.listen == null) {
          return _ParseFailure('--listen requires a target');
        }
      case '--port' when command == 'start' || command == 'restart':
        final raw = next();
        value.port = raw == null ? null : int.tryParse(raw);
        if (value.port == null || value.port! < 0 || value.port! > 65535) {
          return _ParseFailure('Invalid port value: ${raw ?? ''}');
        }
      case '--hostnames' || '--allowed-hosts'
          when command == 'start' || command == 'restart':
        value.hostnames = next();
        if (value.hostnames == null) {
          return _ParseFailure('$argument requires a value');
        }
      case '--timeout' when command == 'stop' || command == 'restart':
      case '--kill-timeout' when command == 'stop':
        final raw = next();
        if (raw == null) return _ParseFailure('$argument requires a value');
        if (argument == '--timeout') {
          value.timeout = raw;
        } else {
          value.killTimeout = raw;
        }
      default:
        if (fullOutput && argument.startsWith('--format=')) {
          try {
            format = normalizeCliOutputFormat(
              argument.substring('--format='.length),
            );
          } on FormatException catch (error) {
            return _ParseFailure(error.message);
          }
        } else if (fullOutput &&
            argument.startsWith('-o') &&
            argument.length > 2) {
          try {
            format = normalizeCliOutputFormat(argument.substring(2));
          } on FormatException catch (error) {
            return _ParseFailure(error.message);
          }
        } else {
          return _ParseFailure('Unknown option: $argument');
        }
    }
  }
  value.output = CliOutputOptions(
    format: json ? 'json' : format,
    quiet: quiet,
    noHeaders: !headers,
    noColor: !color,
  );
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
