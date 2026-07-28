import 'dart:io';

import 'package:dart_ipc/dart_ipc.dart' as ipc;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'service_proxy_http.dart';

sealed class ServiceProxyListenTarget {
  const ServiceProxyListenTarget();
}

ServiceProxyListenTarget parseServiceProxyListenTarget(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw const FormatException('Service proxy listen target is empty');
  }
  if (trimmed.startsWith(r'\\.\pipe\')) {
    return ServiceProxyPipeTarget(trimmed);
  }
  if (trimmed.startsWith('unix://')) {
    final path = Uri.parse(trimmed).path;
    if (path.isEmpty) {
      throw FormatException('Invalid service proxy listen target: $value');
    }
    return ServiceProxySocketTarget(path);
  }
  if (trimmed.startsWith('/') || trimmed.startsWith(r'\')) {
    return ServiceProxySocketTarget(trimmed);
  }
  final match = RegExp(
    r'^(?:\[([^\]]+)\]|([^:]+)):(\d{1,5})$',
  ).firstMatch(trimmed);
  final host = match?.group(1) ?? match?.group(2);
  final port = match == null ? null : int.tryParse(match.group(3)!);
  if (host == null ||
      host.isEmpty ||
      port == null ||
      port < 0 ||
      port > 65535) {
    throw FormatException('Invalid service proxy listen target: $value');
  }
  return ServiceProxyTcpTarget(host: host, port: port);
}

final class ServiceProxyTcpTarget extends ServiceProxyListenTarget {
  const ServiceProxyTcpTarget({required this.host, required this.port});

  final String host;
  final int port;
}

final class ServiceProxySocketTarget extends ServiceProxyListenTarget {
  const ServiceProxySocketTarget(this.path);

  final String path;
}

final class ServiceProxyPipeTarget extends ServiceProxyListenTarget {
  const ServiceProxyPipeTarget(this.path);

  final String path;
}

final class ServiceProxyStandaloneServer {
  ServiceProxyStandaloneServer({required this.proxy});

  final ServiceProxyHttpHandler proxy;
  HttpServer? _server;
  ServerSocket? _listener;
  ServiceProxyListenTarget? _boundTarget;

  ServiceProxyListenTarget? get boundTarget => _boundTarget;
  bool get isRunning => _server != null;

  Future<ServiceProxyListenTarget> start(
    ServiceProxyListenTarget target,
  ) async {
    final existing = _boundTarget;
    if (_server != null && existing != null) return existing;
    HttpServer? server;
    ServerSocket? listener;
    try {
      switch (target) {
        case ServiceProxyTcpTarget(:final host, :final port):
          server = await shelf_io.serve(
            _handler,
            host,
            port,
            poweredByHeader: null,
          );
          _boundTarget = ServiceProxyTcpTarget(host: host, port: server.port);
        case ServiceProxySocketTarget(:final path):
          if (Platform.isWindows) {
            throw UnsupportedError(
              'Unix service proxy sockets are unavailable on Windows',
            );
          }
          final file = File(path);
          if (await file.exists()) await file.delete();
          final socket = await ServerSocket.bind(
            InternetAddress(path, type: InternetAddressType.unix),
            0,
          );
          listener = socket;
          server = HttpServer.listenOn(socket);
          shelf_io.serveRequests(server, _handler, poweredByHeader: null);
          _boundTarget = target;
        case ServiceProxyPipeTarget(:final path):
          if (!Platform.isWindows) {
            throw UnsupportedError(
              'Named-pipe service proxy transport is available only on Windows',
            );
          }
          final pipeListener = await ipc.bind(path);
          listener = pipeListener;
          server = HttpServer.listenOn(pipeListener);
          shelf_io.serveRequests(server, _handler, poweredByHeader: null);
          _boundTarget = target;
      }
      _server = server;
      _listener = listener;
      return _boundTarget!;
    } catch (_) {
      await server?.close(force: true);
      await listener?.close();
      _server = null;
      _listener = null;
      _boundTarget = null;
      rethrow;
    }
  }

  Future<void> stop() async {
    final server = _server;
    final listener = _listener;
    final target = _boundTarget;
    _server = null;
    _listener = null;
    _boundTarget = null;
    if (server == null) return;
    await server.close(force: true);
    await listener?.close();
    if (target is ServiceProxySocketTarget) {
      final file = File(target.path);
      if (await file.exists()) await file.delete();
    }
  }

  Future<Response> _handler(Request request) async =>
      await proxy.call(request) ?? Response.notFound('404 Not Found');
}
