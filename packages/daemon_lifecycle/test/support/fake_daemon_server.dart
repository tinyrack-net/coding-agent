import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

/// A minimal hand-written stand-in for a real daemon's WebSocket endpoint,
/// used to exercise [probeDaemon]/[sendLifecycleRequest]/[stopDaemon] without
/// spawning a real daemon executable.
///
/// Responds to `client.hello.request` with a configurable [ServerHello] and
/// to `daemon.shutdown.request` with a plain success response. Any other
/// request type gets an error response.
class FakeDaemonServer {
  FakeDaemonServer({
    this.daemonVersion = '0.2.0',
    this.protocolVersion = 1,
    this.pid,
    this.desktopManaged = false,
    this.respondToHello = true,
    this.requiredToken,
  });

  final String daemonVersion;
  final int protocolVersion;
  final int? pid;
  final bool desktopManaged;

  /// When false, connections are accepted but hello is never answered
  /// (simulates a daemon that hangs / never responds), so probes time out.
  final bool respondToHello;
  final String? requiredToken;

  HttpServer? _server;
  final _sockets = <WebSocket>[];

  int get port => _server!.port;

  Future<void> start({int port = 0}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server = server;
    unawaited(_serve(server));
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        continue;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      socket.listen((raw) {
        if (raw is! String) return;
        final decoded = RpcFrame.fromJson(
          jsonDecode(raw) as Map<String, Object?>,
        );
        if (decoded is! RpcRequest) return;
        if (decoded.type == MessageTypes.clientHelloRequest) {
          if (!respondToHello) return;
          final hello = ClientHello.fromJson(decoded.payload);
          if (requiredToken != null && hello.token != requiredToken) {
            socket.add(
              jsonEncode(
                decoded
                    .fail(
                      const RpcError(
                        code: RpcErrorCodes.unauthorized,
                        message: 'unauthorized',
                      ),
                    )
                    .toJson(),
              ),
            );
            return;
          }
          socket.add(
            jsonEncode(
              decoded
                  .respond(
                    ServerHello(
                      daemonVersion: daemonVersion,
                      protocolVersion: protocolVersion,
                      pid: pid,
                      desktopManaged: desktopManaged,
                    ).toJson(),
                  )
                  .toJson(),
            ),
          );
        } else if (decoded.type == MessageTypes.daemonShutdownRequest) {
          socket.add(jsonEncode(decoded.respond(const {}).toJson()));
        } else {
          socket.add(
            jsonEncode(
              decoded
                  .fail(
                    const RpcError(
                      code: RpcErrorCodes.unknownType,
                      message: 'unhandled',
                    ),
                  )
                  .toJson(),
            ),
          );
        }
      });
    }
  }

  Future<void> stop() async {
    for (final socket in _sockets) {
      try {
        await socket.close();
      } catch (_) {}
    }
    await _server?.close(force: true);
  }
}
