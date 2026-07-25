import 'dart:async';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';

import 'agent/agent_manager.dart';
import 'agent/agent_store.dart';
import 'git/git_service.dart';
import 'git/workspace_rpc.dart';
import 'providers/native/credential_store.dart';
import 'providers/native/native_client.dart';
import 'providers/native/openai_compatible_backend.dart';
import 'providers/native/provider_catalog.dart';
import 'providers/provider_registry.dart';
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
  final nativeBackends = {
    for (final entry in ProviderCatalog.all)
      entry.id: OpenAiCompatibleBackend(catalogEntry: entry),
  };
  final registry = ProviderRegistry(credentials, nativeBackends);

  late final WsServer server;
  final manager = AgentManager(
    clients: {
      for (final entry in ProviderCatalog.all)
        entry.id.name: NativeClient(
          providerId: entry.id,
          backend: nativeBackends[entry.id]!,
          credentials: credentials,
        ),
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
    ..on(MessageTypes.providerCredentialSetRequest, (_, payload) async {
      final providerId = _parseProviderId(payload['providerId']);
      final apiKey = _requireString(payload, 'apiKey');
      await credentials.set(providerId.name, apiKey);
      return const <String, Object?>{};
    })
    ..on(MessageTypes.providerCredentialClearRequest, (_, payload) async {
      final providerId = _parseProviderId(payload['providerId']);
      await credentials.clear(providerId.name);
      return const <String, Object?>{};
    })
    ..on(MessageTypes.providerCredentialTestRequest, (_, payload) async {
      final providerId = _parseProviderId(payload['providerId']);
      final apiKey =
          (payload['apiKey'] as String?) ?? await credentials.get(providerId.name);
      if (apiKey == null || apiKey.isEmpty) {
        return const ProviderCredentialTestResult(ok: false, error: 'no API key given')
            .toJson();
      }
      final ok = await nativeBackends[providerId]!.testCredential(apiKey);
      return ProviderCredentialTestResult(
        ok: ok,
        error: ok ? null : 'API key rejected by provider',
      ).toJson();
    })
    ..on(MessageTypes.agentCreateRequest, (_, payload) async {
      final cwd = payload['cwd'] as String?;
      if (cwd == null || cwd.isEmpty) {
        throw RpcException(RpcErrorCodes.invalidPayload, 'cwd is required');
      }
      final agent = await manager.createAgent(
        cwd: cwd,
        provider: (payload['provider'] as String?) ?? ProviderId.openai.name,
        model: (payload['model'] as String?) ?? '',
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
      final agentId = _requireString(payload, 'agentId');
      final text = _requireString(payload, 'text');
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
    ..on(MessageTypes.agentRenameRequest, (_, payload) async {
      final agent = await manager.rename(
        _requireString(payload, 'agentId'),
        _requireString(payload, 'title'),
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

ProviderId _parseProviderId(Object? raw) {
  final name = raw as String?;
  if (name == null || name.isEmpty) {
    throw RpcException(RpcErrorCodes.invalidPayload, 'providerId is required');
  }
  try {
    return ProviderId.fromWire(name);
  } catch (_) {
    throw RpcException(
        RpcErrorCodes.invalidPayload, 'unknown providerId "$name"');
  }
}

String _requireString(Map<String, Object?> payload, String key) {
  final value = payload[key] as String?;
  if (value == null || value.isEmpty) {
    throw RpcException(RpcErrorCodes.invalidPayload, '$key is required');
  }
  return value;
}
