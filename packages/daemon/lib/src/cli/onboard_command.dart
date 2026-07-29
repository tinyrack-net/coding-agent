import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;

import '../server/daemon_config.dart';
import '../server/pairing_offer.dart';
import 'daemon_command.dart';
import 'pair_command.dart';
import 'terminal_command.dart';

const onboardDefaultReadyTimeout = Duration(minutes: 10);
const onboardReadyProbeTimeout = Duration(milliseconds: 1200);
const onboardReadyPollInterval = Duration(milliseconds: 200);

enum OnboardVoiceMode { ask, enable, disable }

final class OnboardDaemonStartResult {
  const OnboardDaemonStartResult({required this.pid, required this.logPath});

  final int? pid;
  final String logPath;
}

typedef OnboardRunningDaemonResolver =
    Future<PidLockData?> Function({
      required String home,
      required Map<String, String> environment,
    });
typedef OnboardDaemonStarter =
    Future<OnboardDaemonStartResult> Function({
      required String home,
      required String? listen,
      required int? port,
      required bool relayEnabled,
      required bool mcpEnabled,
      required String? hostnames,
      required Map<String, String> environment,
    });
typedef OnboardReadyProbe =
    Future<String?> Function({
      required String home,
      required Map<String, String> environment,
      required Duration timeout,
    });
typedef OnboardPairingOfferFactory =
    Future<LocalPairingOffer> Function({
      required DaemonRuntimeConfig config,
      required Map<String, String> environment,
    });
typedef OnboardVoicePrompt = Future<bool?> Function();
typedef OnboardLogTail =
    Future<String?> Function(String home, {required int lines});

final class OnboardRuntime {
  const OnboardRuntime({
    this.environment,
    this.inputIsTerminal = _stdinIsTerminal,
    this.outputIsTerminal = _stdoutIsTerminal,
    this.terminalColumns = _terminalColumns,
    this.promptVoice = _promptVoice,
    this.resolveRunningDaemon = _resolveRunningDaemon,
    this.startDaemon = _startDaemon,
    this.probeReady = _probeReady,
    this.createPairingOffer = _createPairingOffer,
    this.tailLog = _tailDaemonLog,
    this.delay = _delay,
    this.now = DateTime.now,
  });

  final Map<String, String>? environment;
  final bool Function() inputIsTerminal;
  final bool Function() outputIsTerminal;
  final int? Function() terminalColumns;
  final OnboardVoicePrompt promptVoice;
  final OnboardRunningDaemonResolver resolveRunningDaemon;
  final OnboardDaemonStarter startDaemon;
  final OnboardReadyProbe probeReady;
  final OnboardPairingOfferFactory createPairingOffer;
  final OnboardLogTail tailLog;
  final Future<void> Function(Duration duration) delay;
  final DateTime Function() now;
}

Future<int> runOnboardCommand({
  required List<String> arguments,
  OnboardRuntime runtime = const OnboardRuntime(),
  void Function(String value)? writeOutput,
  void Function(String value)? writeError,
}) async {
  final output = writeOutput ?? stdout.write;
  final errorOutput = writeError ?? stderr.write;
  if (arguments.contains('--help') || arguments.contains('-h')) {
    output(onboardHelp);
    return 0;
  }

  late final _OnboardOptions options;
  try {
    options = _OnboardOptions.parse(arguments);
  } on FormatException catch (error) {
    errorOutput('${error.message}\n$onboardUsage\n');
    return 64;
  }

  final environment = runtime.environment ?? Platform.environment;
  final home = p.normalize(
    p.absolute(options.home ?? resolveTinyrackHome(environment)),
  );
  if (runtime.inputIsTerminal() && runtime.outputIsTerminal()) {
    output('Welcome to Tinyrack\n\nTinyrack home\n$home\n\n');
  }

  try {
    // Ensure the versioned defaults exist before preserving and extending them.
    loadDaemonRuntimeConfig(home: home, environment: environment);
    final persisted = await _readPersistedConfig(home);
    final savedVoice = resolvePersistedOnboardVoiceSelection(persisted);
    final voice = await _resolveVoiceSelection(
      options.voice,
      savedVoice: savedVoice,
      runtime: runtime,
      output: output,
    );
    if (voice == null) {
      output('Onboarding cancelled.\n');
      return 0;
    }
    await persistOnboardVoiceSelection(home, persisted, voice);

    output(
      voice
          ? 'Voice features enabled. Local speech models will be downloaded '
                'automatically if missing.\n'
          : 'Voice features disabled. Local speech models will not be '
                'downloaded.\n',
    );

    final config = loadDaemonRuntimeConfig(
      home: home,
      environment: environment,
      cliListen:
          options.listen ??
          (options.port == null ? null : '127.0.0.1:${options.port}'),
      cliRelayEnabled: options.relayEnabled,
      cliHostnames: options.hostnames,
    );

    final running = await runtime.resolveRunningDaemon(
      home: home,
      environment: environment,
    );
    if (running != null) {
      output('Daemon already running (PID ${running.pid}).\n');
    } else {
      output('Starting daemon...\n');
      final started = await runtime.startDaemon(
        home: home,
        listen: options.listen,
        port: options.port,
        relayEnabled: options.relayEnabled != false,
        mcpEnabled: options.mcpEnabled,
        hostnames: options.hostnames,
        environment: environment,
      );
      output('Daemon started (PID ${started.pid ?? 'unknown'})\n');
      output('Logs: ${started.logPath}\n');
    }

    output('Waiting for daemon to become ready...\n');
    final readyListen = await _waitForDaemonReady(
      home: home,
      environment: environment,
      timeout: options.timeout,
      runtime: runtime,
      output: output,
    );
    output('Daemon ready on $readyListen\n');

    if (!config.relay.enabled) {
      output(
        'Relay is disabled; pairing offer is unavailable for this daemon.\n',
      );
      _printNextSteps(output, pairingUrl: null, home: home, config: config);
      output('Tinyrack daemon is running.\n');
      return 0;
    }

    final pairing = await runtime.createPairingOffer(
      config: config,
      environment: environment,
    );
    if (pairing.url == null) {
      output(
        'Relay pairing URL is unavailable for this daemon configuration.\n',
      );
      _printNextSteps(output, pairingUrl: null, home: home, config: config);
      output('Tinyrack daemon is running.\n');
      return 0;
    }

    output(
      formatPairingInstructions(
        url: pairing.url!,
        qr: pairing.qr,
        columns: runtime.terminalColumns(),
      ),
    );
    _printNextSteps(
      output,
      pairingUrl: pairing.url,
      home: home,
      config: config,
    );
    output('Tinyrack is ready!\n');
    return 0;
  } on Object catch (error) {
    errorOutput('${_errorMessage(error)}\n');
    return 1;
  }
}

bool? resolvePersistedOnboardVoiceSelection(Map<String, Object?> persisted) {
  final features = _map(persisted['features']);
  final voiceMode = _map(features['voiceMode']);
  if (voiceMode['enabled'] is bool) return voiceMode['enabled']! as bool;
  final dictation = _map(features['dictation']);
  return dictation['enabled'] is bool ? dictation['enabled']! as bool : null;
}

Future<void> persistOnboardVoiceSelection(
  String home,
  Map<String, Object?> persisted,
  bool enabled,
) async {
  final features = _map(persisted['features']);
  final dictation = _map(features['dictation']);
  final voiceMode = _map(features['voiceMode']);
  final updated = <String, Object?>{
    ...persisted,
    'features': {
      ...features,
      'dictation': {...dictation, 'enabled': enabled},
      'voiceMode': {...voiceMode, 'enabled': enabled},
    },
  };
  final file = File(p.join(home, 'config.json'));
  await file.parent.create(recursive: true);
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(updated)}\n',
    flush: true,
  );
}

OnboardDownloadProgress? parseOnboardDownloadProgress(String logTail) {
  final lines = logTail.split('\n').where((line) => line.isNotEmpty).toList();
  for (var index = lines.length - 1; index >= 0; index--) {
    final line = lines[index];
    if (!line.contains('Downloading model artifact')) continue;
    final percentage = RegExp(
      r'"pct"\s*:\s*(\d{1,3})|\bpct[=:]\s*(\d{1,3})',
    ).firstMatch(line);
    final model = RegExp(
      r'"modelId"\s*:\s*"([^"]+)"|\bmodelId[=:]\s*"?([^\s",}]+)',
    ).firstMatch(line);
    return OnboardDownloadProgress(
      modelId: model?.group(1) ?? model?.group(2),
      percentage: percentage == null
          ? null
          : int.parse(percentage.group(1) ?? percentage.group(2)!),
    );
  }
  return null;
}

final class OnboardDownloadProgress {
  const OnboardDownloadProgress({
    required this.modelId,
    required this.percentage,
  });

  final String? modelId;
  final int? percentage;

  String get message {
    final model = modelId == null ? '' : ' ($modelId)';
    return percentage == null
        ? 'Downloading speech model$model...'
        : 'Downloading speech model$model: $percentage%';
  }
}

Future<bool?> _resolveVoiceSelection(
  OnboardVoiceMode mode, {
  required bool? savedVoice,
  required OnboardRuntime runtime,
  required void Function(String value) output,
}) async {
  if (mode == OnboardVoiceMode.enable) return true;
  if (mode == OnboardVoiceMode.disable) return false;
  if (savedVoice != null) {
    output(
      'Using saved voice setup from config '
      '(${savedVoice ? 'enabled' : 'disabled'}).\n',
    );
    return savedVoice;
  }
  if (!runtime.inputIsTerminal() || !runtime.outputIsTerminal()) {
    output(
      'Non-interactive terminal detected; voice setup defaults to disabled.\n',
    );
    return false;
  }
  return runtime.promptVoice();
}

Future<String> _waitForDaemonReady({
  required String home,
  required Map<String, String> environment,
  required Duration timeout,
  required OnboardRuntime runtime,
  required void Function(String value) output,
}) async {
  final deadline = runtime.now().add(timeout);
  String? lastStatus;
  while (runtime.now().isBefore(deadline)) {
    final remaining = deadline.difference(runtime.now());
    final readyListen = await runtime.probeReady(
      home: home,
      environment: environment,
      timeout: Duration(
        milliseconds: math.max(
          1,
          math.min(
            remaining.inMilliseconds,
            onboardReadyProbeTimeout.inMilliseconds,
          ),
        ),
      ),
    );
    if (readyListen != null) return readyListen;
    final tail = await runtime.tailLog(home, lines: 120) ?? '';
    final progress = parseOnboardDownloadProgress(tail);
    final status = progress?.message ?? 'Waiting for daemon to become ready...';
    if (status != lastStatus) {
      output('$status\n');
      lastStatus = status;
    }
    if (!runtime.now().isBefore(deadline)) break;
    await runtime.delay(onboardReadyPollInterval);
  }
  final recent = await runtime.tailLog(home, lines: 60);
  final timeoutSeconds = (timeout.inMilliseconds / 1000).ceil();
  throw TimeoutException(
    'Timed out after ${timeoutSeconds}s waiting for daemon readiness.'
    '${recent == null || recent.isEmpty ? '' : '\n\nRecent daemon logs:\n$recent'}',
    timeout,
  );
}

void _printNextSteps(
  void Function(String value) output, {
  required String? pairingUrl,
  required String home,
  required DaemonRuntimeConfig config,
}) {
  output('\nNext steps:\n');
  output(
    pairingUrl == null
        ? '1. Open Tinyrack and connect to your daemon.\n'
        : '1. Open Tinyrack and scan the QR code above, or paste the '
              'pairing link.\n',
  );
  output('2. Web app: ${config.appBaseUrl}\n');
  output(
    '3. Desktop app: '
    'https://github.com/tinyrack-net/coding-agent/releases/latest\n',
  );
  output('4. CLI help: coding-agent --help\n');
  output(
    '5. Example: coding-agent run --output-schema schema.json '
    '"extract fields"\n',
  );
  output('\nCLI quick reference:\n');
  output('1. coding-agent --help\n');
  output('2. coding-agent ls\n');
  output('3. coding-agent run "your prompt"\n');
  output('4. coding-agent status\n');
  output('5. Daemon logs: ${p.join(home, 'daemon.log')}\n\n');
}

final class _OnboardOptions {
  _OnboardOptions();

  String? listen;
  int? port;
  String? home;
  bool? relayEnabled;
  bool mcpEnabled = true;
  String? hostnames;
  Duration timeout = onboardDefaultReadyTimeout;
  OnboardVoiceMode voice = OnboardVoiceMode.ask;

  static _OnboardOptions parse(List<String> arguments) {
    final options = _OnboardOptions();
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      String next() {
        if (index + 1 >= arguments.length) {
          throw FormatException('$argument requires a value');
        }
        return arguments[++index];
      }

      switch (argument) {
        case '--listen':
          options.listen = next().trim();
          if (options.listen!.isEmpty) {
            throw const FormatException('--listen requires a value');
          }
        case '--port':
          final raw = next();
          options.port = int.tryParse(raw);
          if (options.port == null ||
              options.port! < 0 ||
              options.port! > 65535) {
            throw FormatException('Invalid port value: $raw');
          }
        case '--home':
          options.home = next().trim();
          if (options.home!.isEmpty) {
            throw const FormatException('--home requires a path');
          }
        case '--no-relay':
          options.relayEnabled = false;
        case '--no-mcp':
          options.mcpEnabled = false;
        case '--hostnames' || '--allowed-hosts':
          options.hostnames = next().trim();
          if (options.hostnames!.isEmpty) {
            throw FormatException('$argument requires a value');
          }
        case '--timeout':
          final raw = next();
          final seconds = double.tryParse(raw);
          if (seconds == null || !seconds.isFinite || seconds <= 0) {
            throw FormatException('Invalid timeout value: $raw');
          }
          options.timeout = Duration(milliseconds: (seconds * 1000).ceil());
        case '--voice':
          final raw = next().trim().toLowerCase();
          options.voice = switch (raw) {
            'ask' => OnboardVoiceMode.ask,
            'enable' => OnboardVoiceMode.enable,
            'disable' => OnboardVoiceMode.disable,
            _ => throw FormatException('Invalid voice setup mode: $raw'),
          };
        default:
          throw FormatException('Unknown option: $argument');
      }
    }
    if (options.listen != null && options.port != null) {
      throw const FormatException('Cannot use --listen and --port together');
    }
    return options;
  }
}

Future<Map<String, Object?>> _readPersistedConfig(String home) async {
  final decoded = jsonDecode(
    await File(p.join(home, 'config.json')).readAsString(),
  );
  if (decoded is! Map) {
    throw const FormatException('config.json must contain a JSON object');
  }
  return Map<String, Object?>.from(decoded);
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

bool _stdinIsTerminal() => stdin.hasTerminal;
bool _stdoutIsTerminal() => stdout.hasTerminal;
int? _terminalColumns() => stdout.hasTerminal ? stdout.terminalColumns : null;

Future<bool?> _promptVoice() async {
  stdout.write(
    'Enable voice features? '
    '(downloads local STT/TTS models in background) [y/N]: ',
  );
  final answer = stdin.readLineSync()?.trim().toLowerCase();
  if (answer == null) return null;
  return answer == 'y' || answer == 'yes';
}

Future<PidLockData?> _resolveRunningDaemon({
  required String home,
  required Map<String, String> environment,
}) async {
  final lock = await PidLock(DaemonPaths(dataDir: home).lockFile).read();
  if (lock == null || !await isPidAlive(lock.pid)) return null;
  return lock;
}

Future<OnboardDaemonStartResult> _startDaemon({
  required String home,
  required String? listen,
  required int? port,
  required bool relayEnabled,
  required bool mcpEnabled,
  required String? hostnames,
  required Map<String, String> environment,
}) async {
  final errors = StringBuffer();
  final arguments = <String>[
    'start',
    '--home',
    home,
    if (listen != null) ...['--listen', listen],
    if (port != null) ...['--port', '$port'],
    if (!relayEnabled) '--no-relay',
    if (!mcpEnabled) '--no-mcp',
    if (hostnames != null) ...['--hostnames', hostnames],
  ];
  final code = await runDaemonCommand(
    arguments: arguments,
    runtime: DaemonCommandRuntime(environment: environment),
    writeOutput: (_) {},
    writeError: errors.write,
  );
  if (code != 0) {
    throw StateError(
      errors.toString().trim().isEmpty
          ? 'Failed to start daemon'
          : errors.toString().trim(),
    );
  }
  final paths = DaemonPaths(dataDir: home);
  final lock = await PidLock(paths.lockFile).read();
  return OnboardDaemonStartResult(pid: lock?.pid, logPath: paths.logFile);
}

Future<String?> _probeReady({
  required String home,
  required Map<String, String> environment,
  required Duration timeout,
}) async {
  final lock = await PidLock(DaemonPaths(dataDir: home).lockFile).read();
  if (lock == null) return null;
  final config = loadDaemonRuntimeConfig(home: home, environment: environment);
  DaemonCliSocketClient? client;
  try {
    final connectHost = switch (lock.host) {
      '0.0.0.0' || '::' => '127.0.0.1',
      final value => value,
    };
    final hostTarget = connectHost.contains(':')
        ? '[$connectHost]:${lock.port}'
        : '$connectHost:${lock.port}';
    client = await DaemonCliSocketClient.connect(
      config,
      hostOverride: hostTarget,
      environment: environment,
      timeout: timeout,
    );
    await client.request(
      FetchAgentsRequest(
        requestId: 'onboard_${DateTime.now().microsecondsSinceEpoch}',
        activeScope: true,
        limit: 1,
      ).toJson(),
      timeout: timeout,
    );
    return '${lock.host}:${lock.port}';
  } on Object {
    return null;
  } finally {
    try {
      await client?.close();
    } on Object {
      // Readiness probing is best effort until the deadline.
    }
  }
}

Future<LocalPairingOffer> _createPairingOffer({
  required DaemonRuntimeConfig config,
  required Map<String, String> environment,
}) => generateLocalPairingOffer(
  tinyrackHome: config.home,
  relayEnabled: config.relay.enabled,
  relayEndpoint: config.relay.endpoint,
  relayPublicEndpoint: config.relay.publicEndpoint,
  relayUseTls: config.relay.useTls,
  relayPublicUseTls: config.relay.publicUseTls,
  appBaseUrl: config.appBaseUrl,
  includeQr: true,
  environment: environment,
);

Future<String?> _tailDaemonLog(String home, {required int lines}) async {
  try {
    final all = await File(DaemonPaths(dataDir: home).logFile).readAsLines();
    return all.skip(math.max(0, all.length - lines)).join('\n');
  } on Object {
    return null;
  }
}

Future<void> _delay(Duration duration) => Future<void>.delayed(duration);

String _errorMessage(Object error) => switch (error) {
  StateError(message: final message) => message,
  FormatException(message: final message) => message,
  TimeoutException(message: final message?) => message,
  FileSystemException(message: final message) => message,
  _ => '$error',
};

const onboardUsage = 'Usage: coding-agent onboard [options]';
const onboardHelp =
    'Usage: coding-agent onboard [options]\n'
    'Run first-time setup, start daemon, and print pairing instructions\n\n'
    'Options:\n'
    '  --listen <listen>       Listen target (host:port)\n'
    '  --port <port>           Port to listen on (default: 6868)\n'
    '  --home <path>           Tinyrack home directory\n'
    '  --no-relay              Disable relay connection\n'
    '  --no-mcp                Disable the Agent MCP HTTP endpoint\n'
    '  --hostnames <hosts>     Daemon hostnames\n'
    '  --timeout <seconds>     Max readiness wait (default: 600)\n'
    '  --voice <mode>          ask, enable, or disable\n';
