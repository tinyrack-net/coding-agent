import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:stream_channel/stream_channel.dart';

import 'service_proxy_route_registry.dart';

const Set<String> serviceProxyHopByHopHeaders = {
  'connection',
  'transfer-encoding',
  'keep-alive',
  'upgrade',
  'proxy-connection',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
};

typedef ServiceProxyLog =
    void Function(String message, Object error, StackTrace stackTrace);

final class ServiceProxyHttpHandler {
  ServiceProxyHttpHandler({
    required this.routes,
    this.log,
    HttpClient Function()? createClient,
  }) : _createClient = createClient ?? HttpClient.new;

  final ServiceProxyRouteRegistry routes;
  final ServiceProxyLog? log;
  final HttpClient Function() _createClient;

  FutureOr<Response?> call(Request request) {
    final classification = routes.classifyHost(request.headers['host']);
    switch (classification.type) {
      case ServiceProxyHostClassificationType.daemon:
        return null;
      case ServiceProxyHostClassificationType.knownServiceMiss:
        return Response.notFound('404 Not Found');
      case ServiceProxyHostClassificationType.registeredService:
        final route = classification.route!;
        if (request.headers['upgrade']?.toLowerCase() == 'websocket') {
          return _proxyWebSocket(request, route);
        }
        return _proxyHttp(request, route);
    }
  }

  Future<Response> _proxyHttp(Request request, ServiceProxyRoute route) async {
    final client = _createClient()..autoUncompress = false;
    try {
      final target = Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: route.port,
        path: request.requestedUri.path,
        query: request.requestedUri.hasQuery
            ? request.requestedUri.query
            : null,
      );
      final upstream = await client.openUrl(request.method, target);
      for (final header in request.headers.entries) {
        if (!serviceProxyHopByHopHeaders.contains(header.key.toLowerCase())) {
          upstream.headers.set(header.key, header.value);
        }
      }
      _setForwardedHeaders(upstream.headers, request, route);
      await upstream.addStream(request.read());
      final response = await upstream.close();
      final headers = <String, Object>{};
      response.headers.forEach((name, values) {
        if (!serviceProxyHopByHopHeaders.contains(name.toLowerCase())) {
          headers[name] = List<String>.unmodifiable(values);
        }
      });
      return Response(
        response.statusCode,
        body: _closeClientAfter(response, client),
        headers: headers,
      );
    } catch (error, stackTrace) {
      client.close(force: true);
      log?.call(
        'Service proxy: upstream unreachable '
        '(${route.hostname}:${route.port})',
        error,
        stackTrace,
      );
      return Response(
        502,
        body: '502 Bad Gateway',
        headers: const {'content-type': 'text/plain'},
      );
    }
  }

  Never _proxyWebSocket(Request request, ServiceProxyRoute route) {
    if (!request.canHijack) {
      throw StateError('Service proxy WebSocket request cannot be hijacked');
    }
    request.hijack((clientChannel) {
      unawaited(_pipeUpgrade(request, route, clientChannel));
    });
  }

  Future<void> _pipeUpgrade(
    Request request,
    ServiceProxyRoute route,
    StreamChannel<List<int>> clientChannel,
  ) async {
    Socket? target;
    try {
      target = await Socket.connect(InternetAddress.loopbackIPv4, route.port);
      final headers = <String, String>{
        for (final header in request.headers.entries)
          if (!serviceProxyHopByHopHeaders.contains(header.key.toLowerCase()))
            header.key: header.value,
      };
      headers['x-forwarded-for'] = _remoteAddress(request);
      headers['x-forwarded-host'] = _hostWithoutPort(
        request.headers['host'] ?? route.hostname,
      );
      headers['x-forwarded-proto'] = 'http';
      headers['connection'] = 'Upgrade';
      headers['upgrade'] = request.headers['upgrade'] ?? 'websocket';

      final path = request.requestedUri.hasQuery
          ? '${request.requestedUri.path}?${request.requestedUri.query}'
          : request.requestedUri.path;
      final buffer = StringBuffer()
        ..writeln('${request.method} ${path.isEmpty ? '/' : path} HTTP/1.1');
      for (final header in headers.entries) {
        buffer.writeln('${header.key}: ${header.value}');
      }
      buffer.writeln();
      target.write(buffer.toString().replaceAll('\n', '\r\n'));

      final finished = Completer<void>();
      target.listen(
        clientChannel.sink.add,
        onError: (Object error, StackTrace stackTrace) {
          if (!finished.isCompleted) {
            finished.completeError(error, stackTrace);
          }
        },
        onDone: () {
          unawaited(clientChannel.sink.close());
          if (!finished.isCompleted) finished.complete();
        },
        cancelOnError: true,
      );
      clientChannel.stream.listen(
        target.add,
        onError: (Object error, StackTrace stackTrace) {
          target?.destroy();
          if (!finished.isCompleted) {
            finished.completeError(error, stackTrace);
          }
        },
        onDone: target.destroy,
        cancelOnError: true,
      );
      await finished.future;
    } catch (error, stackTrace) {
      log?.call(
        'Service proxy: WebSocket upstream unreachable '
        '(${route.hostname}:${route.port})',
        error,
        stackTrace,
      );
      await clientChannel.sink.close();
      target?.destroy();
    }
  }
}

void _setForwardedHeaders(
  HttpHeaders headers,
  Request request,
  ServiceProxyRoute route,
) {
  headers.set('x-forwarded-for', _remoteAddress(request));
  headers.set(
    'x-forwarded-host',
    _hostWithoutPort(request.headers['host'] ?? route.hostname),
  );
  headers.set('x-forwarded-proto', request.requestedUri.scheme);
}

String _remoteAddress(Request request) =>
    (request.context['shelf.io.connection_info'] as HttpConnectionInfo?)
        ?.remoteAddress
        .address ??
    InternetAddress.loopbackIPv4.address;

String _hostWithoutPort(String host) => host.replaceFirst(RegExp(r':\d+$'), '');

Stream<List<int>> _closeClientAfter(
  HttpClientResponse response,
  HttpClient client,
) async* {
  try {
    yield* response;
  } finally {
    client.close();
  }
}
