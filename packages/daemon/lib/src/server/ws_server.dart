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
import 'rpc_router.dart';

export 'package:daemon_lifecycle/daemon_lifecycle.dart' show daemonVersion;

/// WebSocket server: accepts connections, enforces the hello handshake,
/// dispatches RPC frames, and fans broadcast events out to all clients.
class WsServer {
  WsServer({required this.router, this.token, this.desktopManaged = false});

  final RpcRouter router;

  /// Required for non-loopback clients when set.
  final String? token;

  /// True when this daemon was spawned and is owned by the desktop app;
  /// echoed to clients in the server hello.
  final bool desktopManaged;

  /// Invoked for every decoded binary terminal frame from an authenticated
  /// connection (M5). Malformed frames are dropped.
  void Function(Connection connection, TerminalFrame frame)? onBinaryFrame;

  /// Invoked once a connection's stream ends (close or error).
  void Function(Connection connection)? onConnectionClosed;

  final Map<String, Connection> _connections = {};
  final _uuid = const Uuid();
  HttpServer? _httpServer;

  Future<void> start({required String host, required int port}) async {
    // shelf_web_socket's callback does not expose the request, so wrap it to
    // capture the connection info (loopback detection) per request.
    FutureOr<Response> handler(Request request) {
      final info =
          request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
      final isLoopback = info?.remoteAddress.isLoopback ?? false;
      final wsHandler = webSocketHandler(
        (WebSocketChannel channel, String? protocol) =>
            _onConnect(channel, isLoopback: isLoopback),
      );
      return wsHandler(request);
    }

    _httpServer = await shelf_io.serve(
      const Pipeline().addHandler(handler),
      host,
      port,
    );
  }

  int get port => _httpServer!.port;
  int get connectionCount => _connections.length;

  void broadcast(RpcEvent event) {
    for (final connection in _connections.values) {
      if (connection.authenticated) connection.sendFrame(event);
    }
  }

  void _onConnect(WebSocketChannel channel, {bool isLoopback = false}) {
    final connection = Connection(channel, id: _uuid.v4(), isLoopback: isLoopback);
    _connections[connection.id] = connection;
    connection.frames.listen(
      (frame) => _onFrame(connection, frame),
      onDone: () => _onDisconnect(connection),
      onError: (_) => _onDisconnect(connection),
    );
  }

  void _onDisconnect(Connection connection) {
    _connections.remove(connection.id);
    onConnectionClosed?.call(connection);
  }

  /// Retrieves a live authenticated connection by id (binary fanout).
  Connection? connectionById(String id) {
    final connection = _connections[id];
    return (connection?.authenticated ?? false) ? connection : null;
  }

  Future<void> _onFrame(Connection connection, dynamic frame) async {
    if (frame is! String) {
      _onBinary(connection, frame);
      return;
    }
    RpcFrame decoded;
    try {
      decoded = RpcFrame.fromJson(jsonDecode(frame) as Map<String, Object?>);
    } catch (e) {
      connection.sendFrame(const RpcEvent(
        type: 'protocol.error',
        payload: {'message': 'malformed frame'},
      ));
      return;
    }
    if (decoded is! RpcRequest) return;

    if (decoded.type == MessageTypes.clientHelloRequest) {
      _handleHello(connection, decoded);
      return;
    }
    if (!connection.authenticated) {
      connection.sendFrame(decoded.fail(RpcError(
        code: RpcErrorCodes.unauthorized,
        message: 'hello required before ${decoded.type}',
      )));
      return;
    }
    connection.sendFrame(await router.dispatch(connection, decoded));
  }

  void _onBinary(Connection connection, dynamic frame) {
    if (!connection.authenticated) return;
    final handler = onBinaryFrame;
    if (handler == null) return;
    final bytes = switch (frame) {
      Uint8List b => b,
      List<int> b => Uint8List.fromList(b),
      _ => null,
    };
    if (bytes == null) return;
    final decoded = TerminalFrame.decode(bytes);
    if (decoded == null) return; // malformed/unknown opcode: drop
    handler(connection, decoded);
  }

  void _handleHello(Connection connection, RpcRequest request) {
    final hello = ClientHello.fromJson(request.payload);
    if (token != null && hello.token != token) {
      connection.sendFrame(request.fail(RpcError(
        code: RpcErrorCodes.unauthorized,
        message: 'invalid token',
      )));
      connection.close(4001, 'unauthorized');
      return;
    }
    connection
      ..authenticated = true
      ..clientName = hello.clientName
      ..sendFrame(request.respond(ServerHello(
        daemonVersion: daemonVersion,
        protocolVersion: protocolVersion,
        capabilities: const ['agents', 'providers', 'terminals'],
        pid: pid,
        desktopManaged: desktopManaged,
      ).toJson()));
  }

  Future<void> stop() async {
    for (final connection in _connections.values.toList()) {
      await connection.close(1000, 'daemon shutting down');
    }
    await _httpServer?.close();
  }
}
