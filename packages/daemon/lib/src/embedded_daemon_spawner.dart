import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';

import 'daemon_server.dart';
import 'server/daemon_config.dart';
import 'voice/configured_speech_runtime.dart';
import 'voice/speech_provider.dart';

void _embeddedDaemonIsolateEntryPoint(Map<String, Object?> config) async {
  final dataDir = config['dataDir'] as String?;
  final host = config['host'] as String? ?? '127.0.0.1';
  final port = config['port'] as int? ?? 6868;
  final paths = DaemonPaths(dataDir: dataDir);
  final runtimeConfig = loadDaemonRuntimeConfig(home: dataDir);

  IOSink? logSink;
  try {
    final logFile = File(paths.logFile);
    await logFile.parent.create(recursive: true);
    logSink = logFile.openWrite(mode: FileMode.append);
  } catch (_) {}

  void log(String message) {
    final line = '${DateTime.now().toIso8601String()} $message';
    print(line);
    try {
      logSink?.writeln(line);
    } catch (_) {}
  }

  try {
    final speechService = createConfiguredSpeechRuntime(
      runtimeConfig: runtimeConfig.speech,
      openAiConfig: runtimeConfig.openAiSpeech,
      localConfig: runtimeConfig.localSpeech,
      logger: CallbackSpeechLogger(log),
    );
    await startDaemonServer(
      paths: paths,
      host: host,
      port: port,
      dataDir: dataDir,
      desktopManaged: true,
      passwordHash: runtimeConfig.auth?.passwordHash,
      allowedOrigins: runtimeConfig.corsAllowedOrigins,
      hostnames: runtimeConfig.hostnames,
      trustedProxies: runtimeConfig.trustedProxies,
      webUiEnabled: runtimeConfig.webUiEnabled,
      webUiDistDir: runtimeConfig.webUiDistDir,
      serviceProxyPublicBaseUrl: runtimeConfig.serviceProxy.publicBaseUrl,
      serviceProxyListen: runtimeConfig.serviceProxy.standaloneListen,
      enableTerminalAgentHooks: runtimeConfig.enableTerminalAgentHooks,
      relayConfig: runtimeConfig.relay,
      appBaseUrl: runtimeConfig.appBaseUrl,
      speechService: speechService,
      log: log,
    );
  } catch (e) {
    log('embedded daemon failed to start: $e');
    await logSink?.close();
  }
}

/// Spawns an embedded daemon inside a Dart [Isolate] and polls until healthy.
Future<ServerHello> spawnEmbeddedDaemon({
  required DaemonPaths paths,
  String host = '127.0.0.1',
  int port = 6868,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final isolate = await Isolate.spawn(
    _embeddedDaemonIsolateEntryPoint,
    <String, Object?>{'dataDir': paths.dataDir, 'host': host, 'port': port},
  );

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final hello = await probeDaemon(host, port);
    if (hello != null) return hello;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  isolate.kill(priority: Isolate.immediate);
  throw DaemonSpawnException(
    'embedded daemon did not become healthy within ${timeout.inSeconds}s',
  );
}
