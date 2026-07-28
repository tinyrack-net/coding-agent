import 'dart:async';
import 'dart:io';

Uri rewriteRelayCutoverUri(Uri requestUri, Uri origin) => origin.replace(
  path: requestUri.path,
  query: requestUri.hasQuery ? requestUri.query : null,
  fragment: null,
);

/// Transparent HTTP/WebSocket cutover proxy used while moving a public relay
/// hostname between Tinyrack deployments.
final class RelayCutoverProxy {
  RelayCutoverProxy(Uri origin, {HttpClient? httpClient})
    : origin = _validateOrigin(origin),
      _httpClient = httpClient ?? HttpClient();

  final Uri origin;
  final HttpClient _httpClient;

  Future<void> forward(HttpRequest request) async {
    if (_isWebSocketUpgrade(request)) {
      await _forwardWebSocket(request);
      return;
    }
    await _forwardHttp(request);
  }

  Future<void> _forwardHttp(HttpRequest request) async {
    final upstreamUri = rewriteRelayCutoverUri(request.uri, origin);
    try {
      final upstream = await _httpClient.openUrl(request.method, upstreamUri);
      _copyRequestHeaders(request.headers, upstream.headers);
      await upstream.addStream(request);
      final response = await upstream.close();
      request.response.statusCode = response.statusCode;
      response.headers.forEach((name, values) {
        if (!_isHopByHopHeader(name)) {
          request.response.headers.set(name, values);
        }
      });
      await request.response.addStream(response);
      await request.response.close();
    } on Object catch (error) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
        request.response.write('Relay upstream unavailable: $error');
        await request.response.close();
      } on Object {
        // The downstream may already be committed or disconnected.
      }
    }
  }

  Future<void> _forwardWebSocket(HttpRequest request) async {
    final httpUri = rewriteRelayCutoverUri(request.uri, origin);
    final upstreamUri = httpUri.replace(
      scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
    );
    final headers = <String, dynamic>{};
    request.headers.forEach((name, values) {
      if (!_isHopByHopHeader(name) &&
          !name.toLowerCase().startsWith('sec-websocket-')) {
        headers[name] = values.length == 1 ? values.single : values;
      }
    });

    WebSocket upstream;
    try {
      upstream = await WebSocket.connect(
        upstreamUri.toString(),
        headers: headers,
      );
    } on Object catch (error) {
      request.response.statusCode = HttpStatus.badGateway;
      request.response.write('Relay upstream unavailable: $error');
      await request.response.close();
      return;
    }

    final downstream = await WebSocketTransformer.upgrade(request);
    late final StreamSubscription<dynamic> downstreamSubscription;
    late final StreamSubscription<dynamic> upstreamSubscription;
    var closing = false;

    Future<void> closeBoth([
      int code = 1000,
      String reason = 'Proxy closed',
    ]) async {
      if (closing) return;
      closing = true;
      await Future.wait<void>([
        _closeSocket(downstream, code, reason),
        _closeSocket(upstream, code, reason),
      ]);
    }

    downstreamSubscription = downstream.listen(
      upstream.add,
      onError: (_) => unawaited(closeBoth(1011, 'Downstream error')),
      onDone: () => unawaited(
        closeBoth(
          downstream.closeCode ?? 1000,
          downstream.closeReason ?? 'Downstream closed',
        ),
      ),
      cancelOnError: false,
    );
    upstreamSubscription = upstream.listen(
      downstream.add,
      onError: (_) => unawaited(closeBoth(1011, 'Upstream error')),
      onDone: () => unawaited(
        closeBoth(
          upstream.closeCode ?? 1000,
          upstream.closeReason ?? 'Upstream closed',
        ),
      ),
      cancelOnError: false,
    );
    try {
      await Future.wait<void>([
        downstreamSubscription.asFuture<void>(),
        upstreamSubscription.asFuture<void>(),
      ]);
    } on Object {
      // closeBoth owns transport cleanup.
    }
  }

  void close() => _httpClient.close(force: true);
}

Uri _validateOrigin(Uri origin) {
  if ((origin.scheme != 'http' && origin.scheme != 'https') ||
      origin.host.isEmpty) {
    throw const FormatException(
      'Relay cutover origin must be an absolute http(s) URL',
    );
  }
  return origin;
}

bool _isWebSocketUpgrade(HttpRequest request) =>
    request.headers.value(HttpHeaders.upgradeHeader)?.toLowerCase() ==
    'websocket';

void _copyRequestHeaders(HttpHeaders source, HttpHeaders target) {
  source.forEach((name, values) {
    if (!_isHopByHopHeader(name)) target.set(name, values);
  });
}

bool _isHopByHopHeader(String name) => switch (name.toLowerCase()) {
  'connection' ||
  'upgrade' ||
  'host' ||
  'keep-alive' ||
  'proxy-authenticate' ||
  'proxy-authorization' ||
  'te' ||
  'trailers' ||
  'transfer-encoding' => true,
  _ => false,
};

Future<void> _closeSocket(WebSocket socket, int code, String reason) async {
  try {
    await socket.close(code, reason);
  } on Object {
    await socket.close(4000, reason);
  }
}
