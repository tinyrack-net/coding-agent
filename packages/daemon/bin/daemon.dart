import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_manager.dart';
import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/git/git_service.dart';
import 'package:agent_daemon/src/git/workspace_rpc.dart';
import 'package:agent_daemon/src/store/project_store.dart';
import 'package:agent_daemon/src/providers/claude/claude_client.dart';
import 'package:agent_daemon/src/providers/codex/codex_client.dart';
import 'package:agent_daemon/src/providers/exe_resolver.dart';
import 'package:agent_daemon/src/providers/provider_registry.dart';
import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:agent_daemon/src/terminal/terminal_manager.dart';
import 'package:agent_daemon/src/terminal/terminal_rpc.dart';
import 'package:agent_protocol/agent_protocol.dart';
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
  final startedAt = DateTime.now();

  Future<void> flushLog() async {
    try {
      await logSink.flush();
      await logSink.close();
    } catch (_) {}
  }

  final lock = PidLock(paths.lockFile);
  try {
    await lock.acquire(PidLockData(
      pid: pid,
      startedAtMs: startedAt.millisecondsSinceEpoch,
      host: host,
      port: port,
      version: daemonVersion,
      desktopManaged: desktopManaged,
    ));
  } on LockHeldException catch (e) {
    log('already running (pid ${e.existing.pid} port ${e.existing.port})');
    await flushLog();
    exit(11);
  }

  final resolver = ExeResolver();
  final registry = ProviderRegistry(resolver);

  late final WsServer server;
  final manager = AgentManager(
    clients: {
      'claude': ClaudeClient(resolver: resolver),
      'codex': CodexClient(resolver: resolver),
    },
    store: AgentStore(dataDir: dataDir),
    onStream: (payload) => server.broadcast(
      RpcEvent(type: MessageTypes.agentStreamEvent, payload: payload.toJson()),
    ),
    onState: (payload) => server.broadcast(
      RpcEvent(type: MessageTypes.agentStateEvent, payload: payload.toJson()),
    ),
    onPermissionRequested: (agentId, permissionId, toolName, detail) =>
        server.broadcast(RpcEvent(
      type: MessageTypes.permissionRequestedEvent,
      payload: {
        'agentId': agentId,
        'permissionId': permissionId,
        'toolName': toolName,
        'detail': detail.toJson(),
      },
    )),
    onPermissionResolved: (permissionId, decision) =>
        server.broadcast(RpcEvent(
      type: MessageTypes.permissionResolvedEvent,
      payload: {'permissionId': permissionId, 'decision': decision.name},
    )),
  );
  await manager.load();

  final router = RpcRouter()
    ..on(MessageTypes.providerListRequest, (_, __) async {
      final providers = await registry.list();
      return ProviderListResponse(providers: providers).toJson();
    })
    ..on(MessageTypes.agentCreateRequest, (_, payload) async {
      final cwd = payload['cwd'] as String?;
      if (cwd == null || cwd.isEmpty) {
        throw RpcException(RpcErrorCodes.invalidPayload, 'cwd is required');
      }
      final agent = await manager.createAgent(
        cwd: cwd,
        provider: (payload['provider'] as String?) ?? 'claude',
        model: (payload['model'] as String?) ?? '',
        mode: _parseMode(payload['mode']),
        title: payload['title'] as String?,
      );
      return {'agent': agent.toJson()};
    })
    ..on(MessageTypes.agentListRequest, (_, __) {
      return {'agents': manager.list().map((a) => a.toJson()).toList()};
    })
    ..on(MessageTypes.agentPromptRequest, (_, payload) {
      final agentId = _requireString(payload, 'agentId');
      final text = _requireString(payload, 'text');
      // Fire and forget: turn errors surface as timeline ErrorItems.
      unawaited(manager.prompt(agentId, text));
      return const <String, Object?>{};
    })
    ..on(MessageTypes.agentInterruptRequest, (_, payload) async {
      await manager.interrupt(_requireString(payload, 'agentId'));
      return const <String, Object?>{};
    })
    ..on(MessageTypes.agentSetModeRequest, (_, payload) async {
      final agent = await manager.setMode(
        _requireString(payload, 'agentId'),
        _parseMode(payload['mode']),
      );
      return {'agent': agent.toJson()};
    })
    ..on(MessageTypes.agentArchiveRequest, (_, payload) async {
      await manager.archive(_requireString(payload, 'agentId'));
      return const <String, Object?>{};
    })
    ..on(MessageTypes.agentTimelineFetchRequest, (_, payload) {
      return manager
          .fetchTimeline(
            _requireString(payload, 'agentId'),
            epoch: (payload['epoch'] as num?)?.toInt(),
            afterSeq: (payload['afterSeq'] as num?)?.toInt(),
          )
          .toJson();
    })
    ..on(MessageTypes.permissionRespondRequest, (_, payload) async {
      await manager.respondPermission(
        _requireString(payload, 'permissionId'),
        _requireString(payload, 'decision'),
      );
      return const <String, Object?>{};
    });

  final projectStore = ProjectStore(dataDir: dataDir);
  registerWorkspaceHandlers(
    router,
    projects: projectStore,
    git: GitService(dataDir: projectStore.dataDir),
  );

  final terminals = TerminalManager(
    sendBinary: (connectionId, bytes) {
      server.connectionById(connectionId)?.sendBinary(bytes);
    },
    onExited: (terminalId, exitCode) => server.broadcast(RpcEvent(
      type: MessageTypes.terminalExitedEvent,
      payload: {'terminalId': terminalId, 'exitCode': exitCode},
    )),
  );
  registerTerminalHandlers(router, terminals: terminals);

  server = WsServer(router: router, token: token, desktopManaged: desktopManaged);
  server.onBinaryFrame =
      (connection, frame) => terminals.handleFrame(connection.id, frame);
  server.onConnectionClosed =
      (connection) => terminals.onConnectionClosed(connection.id);

  var shuttingDown = false;
  Future<void> shutdown(String reason) async {
    if (shuttingDown) return;
    shuttingDown = true;
    log('shutting down ($reason)');
    await manager.dispose();
    await terminals.dispose();
    await server.stop();
    await lock.release();
    await flushLog();
    exit(0);
  }

  router
    ..on(MessageTypes.daemonStatusRequest, (_, __) {
      return {
        'pid': pid,
        'version': daemonVersion,
        'uptimeMs': DateTime.now().difference(startedAt).inMilliseconds,
        'desktopManaged': desktopManaged,
      };
    })
    ..on(MessageTypes.daemonShutdownRequest, (connection, __) {
      if (!connection.isLoopback) {
        throw RpcException(RpcErrorCodes.unauthorized,
            'shutdown is only allowed from loopback connections');
      }
      // Respond first, then shut down.
      Timer(const Duration(milliseconds: 200), () {
        unawaited(shutdown('shutdown request'));
      });
      return const <String, Object?>{};
    });

  try {
    await server.start(host: host, port: port);
  } catch (e) {
    log('failed to bind ws://$host:$port: $e');
    await lock.release();
    await flushLog();
    exit(1);
  }

  await lock.update(PidLockData(
    pid: pid,
    startedAtMs: startedAt.millisecondsSinceEpoch,
    host: host,
    port: server.port,
    version: daemonVersion,
    desktopManaged: desktopManaged,
  ));
  lock.startHeartbeat();

  log('daemon listening on ws://$host:${server.port}');

  ProcessSignal.sigint.watch().listen((_) => unawaited(shutdown('SIGINT')));
  if (!Platform.isWindows) {
    // SIGTERM cannot be watched on Windows (throws).
    ProcessSignal.sigterm.watch().listen((_) => unawaited(shutdown('SIGTERM')));
  }
}

AgentMode _parseMode(Object? raw) {
  final name = (raw as String?) ?? 'normal';
  try {
    return AgentMode.values.byName(name);
  } catch (_) {
    throw RpcException(RpcErrorCodes.invalidPayload, 'unknown mode "$name"');
  }
}

String _requireString(Map<String, Object?> payload, String key) {
  final value = payload[key] as String?;
  if (value == null || value.isEmpty) {
    throw RpcException(RpcErrorCodes.invalidPayload, '$key is required');
  }
  return value;
}

String? _argValue(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index == -1 || index + 1 >= args.length) return null;
  return args[index + 1];
}
