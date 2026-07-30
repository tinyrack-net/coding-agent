import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart' show daemonVersion;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connection.dart';
import 'daemon_auth.dart';
import 'hostnames.dart';
import 'rpc_router.dart';
import 'websocket_runtime_metrics.dart';

export 'package:daemon_lifecycle/daemon_lifecycle.dart' show daemonVersion;

typedef V2SessionHandler =
    FutureOr<Object?> Function(
      Connection connection,
      Map<String, Object?> message,
    );
typedef AdditionalHttpHandler = FutureOr<Response> Function(Request request);
typedef OptionalHttpHandler = FutureOr<Response?> Function(Request request);

final class V2HandledNoResponse {
  const V2HandledNoResponse();
}

const v2HandledNoResponse = V2HandledNoResponse();

final class V2SessionResponse {
  const V2SessionResponse({required this.message, this.afterSend});

  final Map<String, Object?> message;
  final FutureOr<void> Function()? afterSend;
}

/// WebSocket server: accepts connections, enforces the hello handshake,
/// dispatches RPC frames, and fans broadcast events out to all clients.
class WsServer {
  WsServer({
    required this.router,
    this.token,
    this.passwordHash,
    this.allowedOrigins = const [],
    this.hostnames,
    this.desktopManaged = false,
    this.helloTimeout = const Duration(seconds: 15),
    this.terminalActivityHandler,
    this.publicStaticHandler,
    this.webUiHandler,
    this.fileDownloadHandler,
    this.serviceProxyHandler,
    this.agentMcpHandler,
    this.runtimeMetricsFlushInterval = const Duration(seconds: 60),
    RuntimeMetricsClock? runtimeMetricsClock,
    String? serverId,
  }) : serverId = serverId ?? const Uuid().v4(),
       _runtimeMetrics = WebSocketRuntimeMetricsWindow(
         clock: runtimeMetricsClock,
       );

  final RpcRouter router;

  /// Required for non-loopback clients when set.
  final String? token;
  final String? passwordHash;
  final List<String> allowedOrigins;
  final HostnamesConfig hostnames;
  final String serverId;

  /// True when this daemon was spawned and is owned by the desktop app;
  /// echoed to clients in the server hello.
  final bool desktopManaged;
  final Duration helloTimeout;
  final Duration runtimeMetricsFlushInterval;
  final AdditionalHttpHandler? terminalActivityHandler;
  final OptionalHttpHandler? publicStaticHandler;
  final OptionalHttpHandler? webUiHandler;
  final OptionalHttpHandler? fileDownloadHandler;
  final OptionalHttpHandler? serviceProxyHandler;
  final AdditionalHttpHandler? agentMcpHandler;

  /// Invoked for every decoded binary terminal frame from an authenticated
  /// connection (M5). Malformed frames are dropped.
  void Function(Connection connection, TerminalFrame frame)? onBinaryFrame;
  FutureOr<void> Function(Connection connection, FileTransferFrame frame)?
  onFileTransferFrame;

  /// Invoked once a connection's stream ends (close or error).
  void Function(Connection connection)? onConnectionClosed;

  /// Handles native Paseo session messages. Returning null falls through to
  /// the temporary v1 RPC adapter.
  V2SessionHandler? onV2SessionMessage;

  final Map<String, Connection> _connections = {};
  final Map<String, Timer> _helloTimers = {};
  final _uuid = const Uuid();
  final WebSocketRuntimeMetricsWindow _runtimeMetrics;
  final EventLoopDelayWindow _eventLoopDelay = EventLoopDelayWindow();
  HttpServer? _httpServer;
  Timer? _runtimeMetricsTimer;
  Timer? _eventLoopDelayTimer;
  Map<String, Object?>? _lastRuntimeMetricsSnapshot;
  Map<String, Object?> _serverCapabilities = const {};
  final Stopwatch _uptime = Stopwatch()..start();

  Future<void> start({required String host, required int port}) async {
    Future<Response> handler(Request request) async {
      final serviceProxyResponse = await serviceProxyHandler?.call(request);
      if (serviceProxyResponse != null) return serviceProxyResponse;
      final corsHeaders = _corsHeaders(request, host, port);
      if (!isHostnameAllowed(request.headers['host'], hostnames)) {
        _runtimeMetrics.incrementCounter('hostRejected');
        return Response.forbidden(
          jsonEncode({'error': 'Invalid Host header'}),
          headers: {...corsHeaders, 'content-type': 'application/json'},
        );
      }
      if (request.method == 'OPTIONS') {
        return Response(204, headers: corsHeaders);
      }
      if (request.url.path == 'api/health') {
        return Response.ok(
          jsonEncode({
            'status': 'ok',
            'timestamp': DateTime.now().toUtc().toIso8601String(),
          }),
          headers: {...corsHeaders, 'content-type': 'application/json'},
        );
      }
      if (request.url.path == 'api/status') {
        final bearer = extractHttpBearerToken(request.headers['authorization']);
        if (!isBearerTokenValid(passwordHash: passwordHash, token: bearer)) {
          return Response.unauthorized(
            jsonEncode({'error': 'Unauthorized'}),
            headers: {...corsHeaders, 'content-type': 'application/json'},
          );
        }
        return Response.ok(
          jsonEncode({
            'status': 'server_info',
            'serverId': serverId,
            'hostname': Platform.localHostname,
            'version': daemonVersion,
            'listen': '$host:${_httpServer?.port ?? port}',
          }),
          headers: {...corsHeaders, 'content-type': 'application/json'},
        );
      }
      if (request.url.path == 'api/terminal-activity') {
        final route = terminalActivityHandler;
        if (route == null) {
          return Response.notFound('Not found', headers: corsHeaders);
        }
        return route(request);
      }
      if (request.url.path == 'api/files/download') {
        final response = await fileDownloadHandler?.call(request);
        return response ?? Response.notFound('Not found', headers: corsHeaders);
      }
      if (request.url.path == 'mcp/agents') {
        final route = agentMcpHandler;
        if (route == null) {
          return Response.notFound('Not found', headers: corsHeaders);
        }
        return route(request);
      }

      final isV2Path = request.url.path == 'ws';
      final isLegacyPath =
          request.url.path.isEmpty &&
          request.headers['upgrade']?.toLowerCase() == 'websocket';
      if (!isV2Path && !isLegacyPath) {
        final publicResponse = await publicStaticHandler?.call(request);
        if (publicResponse != null) return publicResponse;
        final webUiResponse = await webUiHandler?.call(request);
        if (webUiResponse != null) return webUiResponse;
        return Response.notFound('Not found', headers: corsHeaders);
      }
      if (!_isOriginAllowed(request, host, port)) {
        _runtimeMetrics.incrementCounter('originRejected');
        return Response.forbidden('Origin not allowed', headers: corsHeaders);
      }
      final info =
          request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
      final isLoopback = info?.remoteAddress.isLoopback ?? false;
      final bearerProtocol = extractWsBearerProtocol(
        request.headers['sec-websocket-protocol'],
      );
      final wsHandler = webSocketHandler(
        (WebSocketChannel channel, String? protocol) => _onConnect(
          channel,
          isLoopback: isLoopback,
          isV2: isV2Path,
          bearerProtocol: protocol,
        ),
        protocols: bearerProtocol == null ? null : [bearerProtocol],
      );
      return wsHandler(request);
    }

    _httpServer = await shelf_io.serve(
      const Pipeline().addHandler(handler),
      host,
      port,
    );
    _runtimeMetricsTimer = Timer.periodic(
      runtimeMetricsFlushInterval,
      (_) => flushRuntimeMetrics(),
    );
    var expectedEventLoopTick = DateTime.now().add(
      const Duration(milliseconds: 10),
    );
    _eventLoopDelayTimer = Timer.periodic(const Duration(milliseconds: 10), (
      _,
    ) {
      final now = DateTime.now();
      _eventLoopDelay.record(
        now.difference(expectedEventLoopTick).inMicroseconds / 1000,
      );
      expectedEventLoopTick = now.add(const Duration(milliseconds: 10));
    });
  }

  int get port => _httpServer!.port;
  int get connectionCount => _connections.length;
  Map<String, Object?> diagnosticSnapshot() =>
      _lastRuntimeMetricsSnapshot ?? const {};

  /// Flushes the bounded Paseo runtime window. Public for deterministic
  /// diagnostics tests; production calls it every 60 seconds and at shutdown.
  Map<String, Object?> flushRuntimeMetrics({bool finalSnapshot = false}) {
    final runtime = _runtimeMetrics.snapshotAndReset();
    final authenticated = _connections.values
        .where((connection) => connection.authenticated)
        .toList(growable: false);
    final snapshot = <String, Object?>{
      'collectedAt': DateTime.now().toUtc().toIso8601String(),
      ...runtime,
      'final': finalSnapshot,
      'sessions': {
        'activeConnections': authenticated.length,
        'externalSessionKeys': authenticated
            .where((connection) => connection.externalSessionKey != null)
            .length,
        'reconnectGraceSessions': 0,
      },
      'sockets': {
        'activeSockets': _connections.length,
        'pendingConnections': _connections.values
            .where((connection) => !connection.authenticated)
            .length,
      },
      'eventLoopDelay': _eventLoopDelay.snapshotAndReset(),
      'uptimeSeconds': _uptime.elapsedMilliseconds / 1000,
      'memory': {
        'rss': ProcessInfo.currentRss,
        'heapUsed': -1,
        'heapTotal': -1,
        'external': -1,
        'arrayBuffers': -1,
      },
      'runtime': const {
        'terminalDirectorySubscriptionCount': 0,
        'terminalSubscriptionCount': 0,
        'inflightRequests': 0,
        'peakInflightRequests': 0,
        'checkoutDiffTargetCount': 0,
        'checkoutDiffSubscriptionCount': 0,
        'checkoutDiffWatcherCount': 0,
        'checkoutDiffFallbackRefreshTargetCount': 0,
      },
      'agents': const {
        'total': 0,
        'byLifecycle': <String, int>{},
        'withActiveForegroundTurn': 0,
        'timelineStats': {'totalItems': 0, 'maxItemsPerAgent': 0},
      },
      'git': const <String, Object?>{},
    };
    _lastRuntimeMetricsSnapshot = Map.unmodifiable(snapshot);
    return _lastRuntimeMetricsSnapshot!;
  }

  List<Connection> get authenticatedV2Connections => List.unmodifiable(
    _connections.values.where(
      (connection) => connection.authenticated && connection.v2,
    ),
  );

  void broadcast(
    RpcEvent event, {
    Map<String, Object?>? v2Message,
    String? legacyV2Capability,
    Set<String>? v2ConnectionIds,
  }) {
    for (final connection in _connections.values) {
      if (!connection.authenticated) continue;
      if (connection.v2) {
        if (v2ConnectionIds != null &&
            !v2ConnectionIds.contains(connection.id)) {
          continue;
        }
        final requestsLegacy =
            legacyV2Capability != null &&
            connection.clientCapabilities[legacyV2Capability] == true;
        connection.sendJson({
          'type': 'session',
          'message': v2Message != null && !requestsLegacy
              ? v2Message
              : event.toJson(),
        });
      } else {
        connection.sendFrame(event);
      }
    }
  }

  void broadcastV2(Map<String, Object?> message, {Set<String>? connectionIds}) {
    for (final connection in _connections.values) {
      if (!connection.authenticated || !connection.v2) continue;
      if (connectionIds != null && !connectionIds.contains(connection.id)) {
        continue;
      }
      connection.sendJson({'type': 'session', 'message': message});
    }
  }

  void _onConnect(
    WebSocketChannel channel, {
    bool isLoopback = false,
    bool isV2 = false,
    String? bearerProtocol,
  }) {
    if (passwordHash != null) {
      final bearer = extractWsBearerToken(bearerProtocol);
      if (!isBearerTokenValid(passwordHash: passwordHash, token: bearer)) {
        unawaited(
          channel.sink.close(
            4401,
            bearer == null ? 'Password required' : 'Incorrect password',
          ),
        );
        return;
      }
    }
    final connection = Connection(
      channel,
      id: _uuid.v4(),
      isLoopback: isLoopback,
    )..v2 = isV2;
    _registerConnection(connection);
  }

  /// Attaches a pre-authenticated transport such as an E2EE relay data socket.
  ///
  /// The transport authentication is complete, but the normal v2 hello is
  /// still required before session messages are accepted.
  Connection attachExternal({
    required Stream<dynamic> frames,
    required void Function(Object data) send,
    required FutureOr<void> Function(int? code, String? reason) close,
    required String transport,
    required String externalSessionKey,
    required String relayConnectionId,
  }) {
    final connection = Connection.external(
      frames: frames,
      send: send,
      close: close,
      id: _uuid.v4(),
      transport: transport,
      externalSessionKey: externalSessionKey,
      relayConnectionId: relayConnectionId,
    )..v2 = true;
    _runtimeMetrics.incrementCounter('relayExternalSocketAttached');
    _registerConnection(connection);
    return connection;
  }

  /// Attaches the authenticated daemon-facing Hub channel without a client
  /// hello. Its authority remains limited to the enrollment scopes.
  Connection attachHubSocket({
    required Stream<dynamic> frames,
    required void Function(Object data) send,
    required FutureOr<void> Function(int? code, String? reason) close,
    required String daemonId,
    required List<String> scopes,
  }) {
    final connection =
        Connection.external(
            frames: frames,
            send: send,
            close: close,
            id: _uuid.v4(),
            transport: 'hub',
            externalSessionKey: daemonId,
            relayConnectionId: null,
            scopes: List<String>.unmodifiable(scopes),
          )
          ..v2 = true
          ..authenticated = true
          ..clientName = 'hub:$daemonId';
    _registerConnection(connection);
    return connection;
  }

  void _registerConnection(Connection connection) {
    _connections[connection.id] = connection;
    connection
      ..onJsonSent = _runtimeMetrics.recordOutboundMessage
      ..onBinarySent = _runtimeMetrics.recordOutboundBinaryFrame;
    if (connection.v2 && !connection.authenticated) {
      _runtimeMetrics.incrementCounter('connectedAwaitingHello');
      _helloTimers[connection.id] = Timer(helloTimeout, () {
        if (!connection.authenticated) {
          unawaited(connection.close(4001, 'Hello timeout'));
        }
      });
    }
    // Stream.listen does not await an async callback, and this WebSocket
    // stream is broadcast, so asyncMap cannot pause its producer either.
    // Chain dispatch explicitly: a JSON file.upload.request must finish before
    // the immediately following binary begin/chunk frames are observed.
    var frameQueue = Future<void>.value();
    connection.frames.listen(
      (frame) {
        frameQueue = frameQueue.then((_) => _onFrame(connection, frame));
      },
      onDone: () =>
          unawaited(frameQueue.whenComplete(() => _onDisconnect(connection))),
      onError: (_) =>
          unawaited(frameQueue.whenComplete(() => _onDisconnect(connection))),
    );
  }

  void _onDisconnect(Connection connection) {
    _helloTimers.remove(connection.id)?.cancel();
    if (_connections.remove(connection.id) == null) return;
    if (connection.authenticated) {
      _runtimeMetrics.incrementCounter('sessionCleanup');
    } else {
      _runtimeMetrics.incrementCounter('pendingDisconnected');
    }
    onConnectionClosed?.call(connection);
  }

  /// Retrieves a live authenticated connection by id (binary fanout).
  Connection? connectionById(String id) {
    final connection = _connections[id];
    return (connection?.authenticated ?? false) ? connection : null;
  }

  void updateServerCapabilities(Map<String, Object?>? capabilities) {
    final next = Map<String, Object?>.unmodifiable(capabilities ?? const {});
    if (jsonEncode(_serverCapabilities) == jsonEncode(next)) return;
    _serverCapabilities = next;
    final status = _serverInfoStatus();
    for (final connection in _connections.values) {
      if (connection.authenticated) connection.sendJson(status);
    }
  }

  Map<String, Object?> _serverInfoStatus() => ServerInfoStatus(
    serverId: serverId,
    hostname: Platform.localHostname,
    version: daemonVersion,
    desktopManaged: desktopManaged,
    capabilities: _serverCapabilities,
    features: const {
      'providersSnapshot': true,
      'importSessionWorkspaceTarget': true,
      'daemonStatusRpc': true,
      'daemonDiagnostics': true,
      'hubRelationshipManagement': true,
      'terminal-restore-modes': true,
      'workspaceFileEditing': true,
      'workspaceRecovery': true,
      'workspaceScriptManagement': true,
      'forgeProviders': true,
      'forgeCheckDetails': true,
      'checkoutRefresh': true,
      'projectAdd': true,
      'stableProjectIdentity': true,
      'projectGithubClone': true,
      'workspaceGithubRepositorySearch': true,
      'projectCreateDirectory': true,
      'projectRemove': true,
      'commitsList': true,
      'commitBaseClassification': true,
    },
  ).toJson();

  Future<void> _onFrame(Connection connection, dynamic frame) async {
    if (frame is! String) {
      await _onBinary(connection, frame);
      return;
    }
    Map<String, Object?> json;
    try {
      json = jsonDecode(frame) as Map<String, Object?>;
    } catch (e) {
      _runtimeMetrics.incrementCounter('validationFailed');
      connection.sendFrame(
        const RpcEvent(
          type: 'protocol.error',
          payload: {'message': 'malformed frame'},
        ),
      );
      return;
    }
    final inboundType = json['type'];
    if (inboundType is String) {
      _runtimeMetrics.recordInboundMessage(inboundType);
    }
    if (connection.v2) {
      await _onV2Frame(connection, json);
      return;
    }

    RpcFrame decoded;
    try {
      decoded = RpcFrame.fromJson(json);
    } catch (_) {
      _runtimeMetrics.incrementCounter('validationFailed');
      connection.sendFrame(
        const RpcEvent(
          type: 'protocol.error',
          payload: {'message': 'malformed frame'},
        ),
      );
      return;
    }
    if (decoded is! RpcRequest) return;
    _runtimeMetrics.recordInboundSessionRequest(decoded.type);

    if (decoded.type == MessageTypes.clientHelloRequest) {
      _handleHello(connection, decoded);
      return;
    }
    if (!connection.authenticated) {
      _runtimeMetrics.incrementCounter('pendingMessageRejectedBeforeHello');
      connection.sendFrame(
        decoded.fail(
          RpcError(
            code: RpcErrorCodes.unauthorized,
            message: 'hello required before ${decoded.type}',
          ),
        ),
      );
      return;
    }
    final startedAt = Stopwatch()..start();
    connection.sendFrame(await router.dispatch(connection, decoded));
    _runtimeMetrics.recordRequestLatency(
      decoded.type,
      startedAt.elapsedMicroseconds / 1000,
    );
  }

  Future<void> _onV2Frame(
    Connection connection,
    Map<String, Object?> json,
  ) async {
    if (json['type'] == 'ping') {
      connection.sendJson(const {'type': 'pong'});
      return;
    }
    if (json['type'] == 'hello') {
      if (connection.authenticated) {
        _runtimeMetrics.incrementCounter('unexpectedHelloOnActiveConnection');
        await connection.close(4002, 'Unexpected hello');
        return;
      }
      try {
        final hello = WebSocketHello.fromJson(json);
        if (hello.protocolVersion != paseoWebSocketProtocolVersion) {
          _runtimeMetrics.incrementCounter('validationFailed');
          await connection.close(4003, 'Incompatible protocol version');
          return;
        }
        connection
          ..authenticated = true
          ..clientName = hello.clientId
          ..appVersion = hello.appVersion
          ..clientCapabilities = hello.capabilities;
        _runtimeMetrics.incrementCounter('helloNew');
        _helloTimers.remove(connection.id)?.cancel();
        connection.sendJson(_serverInfoStatus());
      } on FormatException {
        _runtimeMetrics.incrementCounter('validationFailed');
        await connection.close(4002, 'Invalid hello');
      }
      return;
    }
    if (!connection.authenticated) {
      _runtimeMetrics.incrementCounter('pendingMessageRejectedBeforeHello');
      await connection.close(4002, 'Session message before hello');
      return;
    }
    if (json['type'] != 'session' || json['message'] is! Map<String, Object?>) {
      _runtimeMetrics.incrementCounter('validationFailed');
      await connection.close(4002, 'Invalid session message');
      return;
    }
    try {
      final message = json['message'] as Map<String, Object?>;
      final requestType = message['type'];
      if (requestType is String) {
        _runtimeMetrics.recordInboundSessionRequest(requestType);
      }
      final startedAt = Stopwatch()..start();
      if (connection.transport == 'hub' &&
          !_scopeAllows(connection.scopes, message['type'])) {
        connection.sendJson({
          'type': 'session',
          'message': {
            'type': 'rpc_error',
            'payload': {
              'requestId': message['requestId'] as String? ?? '',
              'requestType': message['type'] as String? ?? '',
              'error': 'Hub scope does not allow this request',
              'code': 'unauthorized',
            },
          },
        });
        if (requestType is String) {
          _runtimeMetrics.recordRequestLatency(
            requestType,
            startedAt.elapsedMicroseconds / 1000,
          );
        }
        return;
      }
      final nativeResponse = await onV2SessionMessage?.call(
        connection,
        message,
      );
      if (nativeResponse is V2HandledNoResponse) {
        if (requestType is String) {
          _runtimeMetrics.recordRequestLatency(
            requestType,
            startedAt.elapsedMicroseconds / 1000,
          );
        }
        return;
      }
      if (nativeResponse is V2SessionResponse) {
        connection.sendJson({
          'type': 'session',
          'message': nativeResponse.message,
        });
        await nativeResponse.afterSend?.call();
        if (requestType is String) {
          _runtimeMetrics.recordRequestLatency(
            requestType,
            startedAt.elapsedMicroseconds / 1000,
          );
        }
        return;
      }
      if (nativeResponse != null) {
        connection.sendJson({
          'type': 'session',
          'message': nativeResponse as Map<String, Object?>,
        });
        if (requestType is String) {
          _runtimeMetrics.recordRequestLatency(
            requestType,
            startedAt.elapsedMicroseconds / 1000,
          );
        }
        return;
      }
      final request = RpcFrame.fromJson(message);
      if (request is! RpcRequest) return;
      final response = await router.dispatch(connection, request);
      connection.sendJson({'type': 'session', 'message': response.toJson()});
      if (requestType is String) {
        _runtimeMetrics.recordRequestLatency(
          requestType,
          startedAt.elapsedMicroseconds / 1000,
        );
      }
    } catch (_) {
      _runtimeMetrics.incrementCounter('validationFailed');
      await connection.close(4002, 'Invalid session message');
    }
  }

  bool _scopeAllows(List<String> scopes, Object? requestType) {
    if (requestType is! String) return false;
    for (final scope in scopes) {
      if (scope == '*' || scope == requestType) return true;
      if (scope.endsWith('.*') &&
          requestType.startsWith(scope.substring(0, scope.length - 1))) {
        return true;
      }
    }
    return false;
  }

  Future<void> _onBinary(Connection connection, dynamic frame) async {
    if (!connection.authenticated) {
      _runtimeMetrics.incrementCounter('binaryBeforeHelloRejected');
      return;
    }
    final bytes = switch (frame) {
      Uint8List b => b,
      List<int> b => Uint8List.fromList(b),
      _ => null,
    };
    if (bytes == null) return;
    final fileTransfer = FileTransferFrame.decode(bytes);
    if (fileTransfer != null) {
      final fileHandler = onFileTransferFrame;
      if (fileHandler != null) {
        await Future.sync(() => fileHandler(connection, fileTransfer));
      }
      return;
    }
    final handler = onBinaryFrame;
    if (handler == null) return;
    final decoded = TerminalFrame.decode(bytes);
    if (decoded == null) return; // malformed/unknown opcode: drop
    handler(connection, decoded);
  }

  void _handleHello(Connection connection, RpcRequest request) {
    final hello = ClientHello.fromJson(request.payload);
    if (token != null && hello.token != token) {
      connection.sendFrame(
        request.fail(
          RpcError(code: RpcErrorCodes.unauthorized, message: 'invalid token'),
        ),
      );
      connection.close(4001, 'unauthorized');
      return;
    }
    connection
      ..authenticated = true
      ..clientName = hello.clientName
      ..sendFrame(
        request.respond(
          ServerHello(
            daemonVersion: daemonVersion,
            protocolVersion: protocolVersion,
            capabilities: const ['agents', 'providers', 'terminals'],
            pid: pid,
            desktopManaged: desktopManaged,
          ).toJson(),
        ),
      );
    _helloTimers.remove(connection.id)?.cancel();
  }

  Map<String, String> _corsHeaders(Request request, String host, int port) {
    final origin = request.headers['origin'];
    if (origin == null || !_isOriginAllowed(request, host, port)) {
      return const {};
    }
    return {
      'access-control-allow-origin': origin,
      'access-control-allow-methods': 'GET, POST, DELETE, OPTIONS',
      'access-control-allow-headers': 'Content-Type, Authorization',
      'access-control-allow-credentials': 'true',
    };
  }

  bool _isOriginAllowed(Request request, String host, int port) {
    final origin = request.headers['origin'];
    if (origin == null) return true;
    final requestHost = request.headers['host']?.trim().toLowerCase();
    final originUri = Uri.tryParse(origin);
    if (requestHost != null &&
        requestHost.isNotEmpty &&
        originUri != null &&
        originUri.hasAuthority &&
        originUri.authority.toLowerCase() == requestHost) {
      return true;
    }
    final effectivePort = _httpServer?.port ?? port;
    final defaults = {
      'paseo://app',
      'coding-agent://app',
      'http://$host:$effectivePort',
      'http://localhost:$effectivePort',
      'http://127.0.0.1:$effectivePort',
    };
    return allowedOrigins.contains('*') ||
        allowedOrigins.contains(origin) ||
        defaults.contains(origin);
  }

  Future<void> stop() async {
    _runtimeMetricsTimer?.cancel();
    _runtimeMetricsTimer = null;
    _eventLoopDelayTimer?.cancel();
    _eventLoopDelayTimer = null;
    flushRuntimeMetrics(finalSnapshot: true);
    for (final timer in _helloTimers.values) {
      timer.cancel();
    }
    _helloTimers.clear();
    for (final connection in _connections.values.toList()) {
      await connection.close(1000, 'daemon shutting down');
    }
    await _httpServer?.close();
  }
}
