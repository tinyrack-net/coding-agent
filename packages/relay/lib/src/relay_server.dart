import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cutover_proxy.dart';
import 'relay_service.dart';
import 'relay_types.dart';

typedef RelaySessionFactory = RelaySession Function();

String? resolveRelayVersion(Object? value) {
  if (value == null) return '1';
  final normalized = value.toString().trim();
  if (normalized.isEmpty) return '1';
  return normalized == '1' || normalized == '2' ? normalized : null;
}

final class TinyrackRelayServer {
  TinyrackRelayServer({
    InternetAddress? address,
    this.port = 0,
    RelaySessionFactory? sessionFactory,
    this.upstream,
    void Function(String message)? log,
  }) : address = address ?? InternetAddress.loopbackIPv4,
       _sessionFactory = sessionFactory ?? RelaySession.new,
       _log = log ?? _discardLog;

  final InternetAddress address;
  final int port;
  final Uri? upstream;
  final RelaySessionFactory _sessionFactory;
  final void Function(String message) _log;

  final Map<String, RelaySession> _sessions = {};
  final Set<_IoRelaySocket> _sockets = {};
  HttpServer? _server;
  RelayCutoverProxy? _cutoverProxy;
  StreamSubscription<HttpRequest>? _subscription;

  bool get isRunning => _server != null;
  int get boundPort => _server?.port ?? 0;
  Uri get httpUri =>
      Uri(scheme: 'http', host: address.address, port: boundPort);

  Future<void> start() async {
    if (_server != null) throw StateError('Relay server is already running');
    if (upstream != null) _cutoverProxy = RelayCutoverProxy(upstream!);
    final server = await HttpServer.bind(address, port);
    _server = server;
    _subscription = server.listen(
      (request) => unawaited(_handleRequest(request)),
      onError: (Object error) => _log('relay_http_error:$error'),
    );
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final cutover = _cutoverProxy;
    if (cutover != null) {
      await cutover.forward(request);
      return;
    }

    if (request.uri.path == '/health') {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'status': 'ok'}));
      await request.response.close();
      return;
    }
    if (request.uri.path != '/ws') {
      await _respond(request, HttpStatus.notFound, 'Not found');
      return;
    }

    final role = switch (request.uri.queryParameters['role']) {
      'server' => RelayConnectionRole.server,
      'client' => RelayConnectionRole.client,
      _ => null,
    };
    if (role == null) {
      await _respond(
        request,
        HttpStatus.badRequest,
        'Missing or invalid role parameter',
      );
      return;
    }
    final serverId = request.uri.queryParameters['serverId'];
    if (serverId == null || serverId.isEmpty) {
      await _respond(
        request,
        HttpStatus.badRequest,
        'Missing serverId parameter',
      );
      return;
    }
    final version = resolveRelayVersion(request.uri.queryParameters['v']);
    if (version == null) {
      await _respond(
        request,
        HttpStatus.badRequest,
        'Invalid v parameter (expected 1 or 2)',
      );
      return;
    }
    if (request.headers.value(HttpHeaders.upgradeHeader)?.toLowerCase() !=
        'websocket') {
      await _respond(
        request,
        HttpStatus.upgradeRequired,
        'Expected WebSocket upgrade',
      );
      return;
    }

    final webSocket = await WebSocketTransformer.upgrade(request);
    final socket = _IoRelaySocket(webSocket);
    _sockets.add(socket);
    final key = 'relay-v$version:$serverId';
    final session = _sessions.putIfAbsent(key, _sessionFactory);
    session.attach(
      socket,
      RelayAttachRequest(
        serverId: serverId,
        role: role,
        version: version,
        connectionId: request.uri.queryParameters['connectionId'],
      ),
    );
    webSocket.listen(
      (message) => session.handleMessage(socket, message as Object),
      onError: (Object error) => session.handleError(socket, error),
      onDone: () {
        _sockets.remove(socket);
        session.handleClose(
          socket,
          code: webSocket.closeCode ?? 1000,
          reason: webSocket.closeReason ?? '',
        );
      },
      cancelOnError: false,
    );
  }

  Future<void> close() async {
    final server = _server;
    if (server == null) return;
    _server = null;
    await _subscription?.cancel();
    _subscription = null;
    for (final session in _sessions.values) {
      session.dispose();
    }
    _sessions.clear();
    for (final socket in _sockets.toList(growable: false)) {
      socket.close(1001, 'Relay shutting down');
    }
    _sockets.clear();
    _cutoverProxy?.close();
    _cutoverProxy = null;
    await server.close(force: true);
  }

  Future<void> _respond(HttpRequest request, int status, String body) async {
    request.response.statusCode = status;
    request.response.write(body);
    await request.response.close();
  }
}

final class _IoRelaySocket implements RelaySocket {
  _IoRelaySocket(this.socket);

  final WebSocket socket;

  @override
  void send(Object frame) => socket.add(frame);

  @override
  void close(int code, String reason) {
    unawaited(
      socket.close(code, reason).catchError((_) {
        return socket.close(4000, reason);
      }),
    );
  }
}

void _discardLog(String _) {}
