import 'dart:async';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';

import 'agent/agent_manager.dart';
import 'agent/agent_store.dart';
import 'git/git_service.dart';
import 'git/workspace_rpc.dart';
import 'providers/native/credential_store.dart';
import 'providers/native/provider_config_store.dart';
import 'providers/provider_registry.dart';
import 'providers/provider_rpc.dart';
import 'server/rpc_router.dart';
import 'server/ws_server.dart';
import 'store/project_store.dart';
import 'terminal/terminal_manager.dart';
import 'terminal/terminal_rpc.dart';

class DaemonServerHandle {
  DaemonServerHandle({
    required this.server,
    required this.lock,
    required this.manager,
    required this.terminals,
    required this.stop,
  });

  final WsServer server;
  final PidLock lock;
  final AgentManager manager;
  final TerminalManager terminals;
  final Future<void> Function() stop;
}

Future<DaemonServerHandle> startDaemonServer({
  required DaemonPaths paths,
  String host = '127.0.0.1',
  int port = 6868,
  String? token,
  String? dataDir,
  bool desktopManaged = true,
  void Function(String)? log,
  void Function()? onShutdownRequested,
}) async {
  log ??= (msg) => stdout.writeln('${DateTime.now().toIso8601String()} $msg');
  final startedAt = DateTime.now();

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
    rethrow;
  }

  final credentials = CredentialStore(dataDir: dataDir);
  final registry = ProviderRegistry(
    credentials: credentials,
    configs: ProviderConfigStore(dataDir: dataDir),
  );

  late final WsServer server;
  final manager = AgentManager(
    resolveClient: (provider) async {
      try {
        return await registry.clientFor(provider);
      } on UnknownProviderException catch (e) {
        throw RpcException(RpcErrorCodes.invalidPayload, '$e');
      }
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

  final router = RpcRouter();
  registerProviderHandlers(router, registry: registry);
  router
    ..on(MessageTypes.agentCreateRequest, (_, payload) async {
      final cwd = payload['cwd'] as String?;
      if (cwd == null || cwd.isEmpty) {
        throw RpcException(RpcErrorCodes.invalidPayload, 'cwd is required');
      }
      final agent = await manager.createAgent(
        cwd: cwd,
        // No implicit default: with user-configured providers there is no
        // sensible fallback, and an empty model only failed later as an opaque
        // HTTP error mid-stream.
        provider: requireString(payload, 'provider'),
        model: requireString(payload, 'model'),
        mode: _parseMode(payload['mode']),
        title: payload['title'] as String?,
        projectPath: payload['projectPath'] as String?,
        branch: payload['branch'] as String?,
        isWorktree: payload['isWorktree'] == true,
      );
      return {'agent': agent.toJson()};
    })
    ..on(MessageTypes.agentListRequest, (_, __) {
      return {'agents': manager.list().map((a) => a.toJson()).toList()};
    })
    ..on(MessageTypes.agentPromptRequest, (_, payload) {
      final agentId = requireString(payload, 'agentId');
      final text = requireString(payload, 'text');
      unawaited(manager.prompt(agentId, text));
      return const <String, Object?>{};
    })
    ..on(MessageTypes.agentInterruptRequest, (_, payload) async {
      await manager.interrupt(requireString(payload, 'agentId'));
      return const <String, Object?>{};
    })
    ..on(MessageTypes.agentSetModeRequest, (_, payload) async {
      final agent = await manager.setMode(
        requireString(payload, 'agentId'),
        _parseMode(payload['mode']),
      );
      return {'agent': agent.toJson()};
    })
    ..on(MessageTypes.agentRenameRequest, (_, payload) async {
      final agent = await manager.rename(
        requireString(payload, 'agentId'),
        requireString(payload, 'title'),
      );
      return {'agent': agent.toJson()};
    })
    ..on(MessageTypes.agentArchiveRequest, (_, payload) async {
      await manager.archive(requireString(payload, 'agentId'));
      return const <String, Object?>{};
    })
    ..on(MessageTypes.agentTimelineFetchRequest, (_, payload) {
      return manager
          .fetchTimeline(
            requireString(payload, 'agentId'),
            epoch: (payload['epoch'] as num?)?.toInt(),
            afterSeq: (payload['afterSeq'] as num?)?.toInt(),
          )
          .toJson();
    })
    ..on(MessageTypes.agentConversationClearRequest, (_, payload) async {
      // Optional agentId scopes the wipe to one agent; missing/empty means
      // "clear every agent the daemon has loaded".
      final agentId = payload['agentId'] as String?;
      final cleared = await manager.clearConversations(
        agentId: (agentId == null || agentId.isEmpty) ? null : agentId,
      );
      return AgentConversationClearResponse(cleared: cleared).toJson();
    })
    ..on(MessageTypes.permissionRespondRequest, (_, payload) async {
      await manager.respondPermission(
        requireString(payload, 'permissionId'),
        requireString(payload, 'decision'),
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
    log!('shutting down ($reason)');
    await manager.dispose();
    await terminals.dispose();
    await server.stop();
    await lock.release();
    if (onShutdownRequested != null) {
      onShutdownRequested();
    }
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
    rethrow;
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

  return DaemonServerHandle(
    server: server,
    lock: lock,
    manager: manager,
    terminals: terminals,
    stop: () => shutdown('manual stop'),
  );
}

AgentMode _parseMode(Object? raw) {
  final name = (raw as String?) ?? 'normal';
  try {
    return AgentMode.values.byName(name);
  } catch (_) {
    throw RpcException(RpcErrorCodes.invalidPayload, 'unknown mode "$name"');
  }
}
