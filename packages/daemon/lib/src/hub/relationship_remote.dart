import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

final class HubEnrollment {
  const HubEnrollment({
    required this.daemonId,
    required this.idempotencyKey,
    required this.hubOrigin,
    required this.token,
    required this.serverId,
    required this.daemonPublicKey,
    required this.credentialVerifier,
    required this.scopes,
  });

  final String daemonId;
  final String idempotencyKey;
  final String hubOrigin;
  final String token;
  final String serverId;
  final String daemonPublicKey;
  final String credentialVerifier;
  final List<String> scopes;
}

final class HubEnrollmentResult {
  const HubEnrollmentResult({
    required this.daemonId,
    required this.scopes,
    required this.webSocketUrl,
  });

  final String daemonId;
  final List<String> scopes;
  final String webSocketUrl;
}

final class HubRevocation {
  const HubRevocation({
    required this.daemonId,
    required this.hubOrigin,
    required this.credential,
  });

  final String daemonId;
  final String hubOrigin;
  final String credential;
}

final class HubSocketCredentials {
  const HubSocketCredentials({
    required this.daemonId,
    required this.webSocketUrl,
    required this.credential,
  });

  final String daemonId;
  final String webSocketUrl;
  final String credential;
}

abstract interface class HubSocket {
  Stream<Object> get frames;
  void send(Object data);
  Future<void> close([int? code, String? reason]);
}

abstract interface class HubSocketConnection {
  Future<void> close();
}

final class HubSocketEvents {
  const HubSocketEvents({
    required this.connected,
    required this.rejected,
    required this.closed,
    required this.failed,
  });

  final void Function(HubSocket socket) connected;
  final void Function(int statusCode) rejected;
  final void Function(int code) closed;
  final void Function(Object error) failed;
}

abstract interface class HubRelationshipRemote {
  Future<HubEnrollmentResult> enroll(HubEnrollment input);
  Future<void> revoke(HubRevocation input);
  HubSocketConnection openSocket(
    HubSocketCredentials input,
    HubSocketEvents events,
  );
}

final class HubEnrollmentRejectedError implements Exception {
  const HubEnrollmentRejectedError(this.statusCode);
  final int statusCode;

  @override
  String toString() => 'Hub enrollment failed ($statusCode)';
}

typedef HubWebSocketConnector =
    Future<WebSocket> Function(
      String url, {
      required Map<String, dynamic> headers,
      required Duration timeout,
    });

final class DirectHubRelationshipRemote implements HubRelationshipRemote {
  DirectHubRelationshipRemote({
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 15),
    HubWebSocketConnector? connectWebSocket,
  }) : _client = client ?? http.Client(),
       _connectWebSocket = connectWebSocket ?? _connectIoWebSocket;

  final http.Client _client;
  final Duration requestTimeout;
  final HubWebSocketConnector _connectWebSocket;

  @override
  Future<HubEnrollmentResult> enroll(HubEnrollment input) async {
    final response = await _withTimeout(
      _client.post(
        Uri.parse('${input.hubOrigin}/api/daemons/enroll'),
        headers: {
          HttpHeaders.contentTypeHeader: 'application/json',
          HttpHeaders.authorizationHeader: 'Bearer ${input.token}',
        },
        body: jsonEncode({
          'daemonId': input.daemonId,
          'idempotencyKey': input.idempotencyKey,
          'serverId': input.serverId,
          'daemonPublicKey': input.daemonPublicKey,
          'credentialVerifier': input.credentialVerifier,
          'scopes': input.scopes,
        }),
      ),
    );
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw HubEnrollmentRejectedError(response.statusCode);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Hub enrollment failed (${response.statusCode})');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map ||
        decoded['daemonId'] is! String ||
        decoded['scopes'] is! List ||
        (decoded['scopes'] as List).any((scope) => scope is! String) ||
        decoded['webSocketUrl'] is! String) {
      throw const FormatException('Invalid Hub enrollment response');
    }
    final webSocketUrl = decoded['webSocketUrl'] as String;
    _ensureWebSocketMatchesHubOrigin(input.hubOrigin, webSocketUrl);
    return HubEnrollmentResult(
      daemonId: decoded['daemonId'] as String,
      scopes: List<String>.unmodifiable(
        (decoded['scopes'] as List).cast<String>(),
      ),
      webSocketUrl: webSocketUrl,
    );
  }

  @override
  Future<void> revoke(HubRevocation input) async {
    final response = await _withTimeout(
      _client.delete(
        Uri.parse(
          '${input.hubOrigin}/api/daemons/'
          '${Uri.encodeComponent(input.daemonId)}',
        ),
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer ${input.credential}',
        },
      ),
    );
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (const {401, 403, 404}.contains(response.statusCode)) return;
    throw StateError('Hub revocation failed (${response.statusCode})');
  }

  @override
  HubSocketConnection openSocket(
    HubSocketCredentials input,
    HubSocketEvents events,
  ) {
    final connection = _DirectHubSocketConnection();
    unawaited(
      _openSocket(input, events, connection).catchError((Object error) {
        if (!connection.settled) {
          connection.settled = true;
          events.failed(error);
        }
      }),
    );
    return connection;
  }

  Future<void> _openSocket(
    HubSocketCredentials input,
    HubSocketEvents events,
    _DirectHubSocketConnection connection,
  ) async {
    try {
      final socket = await _connectWebSocket(
        input.webSocketUrl,
        headers: {
          HttpHeaders.authorizationHeader: 'Bearer ${input.credential}',
          'x-paseo-daemon-id': input.daemonId,
          'x-tinyrack-daemon-id': input.daemonId,
        },
        timeout: requestTimeout,
      );
      if (connection.closed) {
        await socket.close();
        return;
      }
      final hubSocket = _IoHubSocket(socket);
      connection.socket = hubSocket;
      events.connected(hubSocket);
      hubSocket.frames.listen(
        (_) {},
        onError: (Object error) {
          if (connection.settled) return;
          connection.settled = true;
          events.failed(error);
        },
        onDone: () {
          if (connection.settled) return;
          connection.settled = true;
          events.closed(socket.closeCode ?? 1006);
        },
      );
    } on WebSocketException catch (error) {
      final status = _statusFromWebSocketError(error);
      if (status == 401 || status == 403) {
        connection.settled = true;
        events.rejected(status!);
        return;
      }
      rethrow;
    }
  }

  Future<http.Response> _withTimeout(Future<http.Response> request) async {
    try {
      return await request.timeout(requestTimeout);
    } on TimeoutException catch (error) {
      throw StateError('Hub request timed out: $error');
    }
  }
}

final class _DirectHubSocketConnection implements HubSocketConnection {
  _IoHubSocket? socket;
  bool closed = false;
  bool settled = false;

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    settled = true;
    await socket?.close();
  }
}

final class _IoHubSocket implements HubSocket {
  _IoHubSocket(this.socket) : _frames = socket.asBroadcastStream();
  final WebSocket socket;
  final Stream<dynamic> _frames;

  @override
  Stream<Object> get frames => _frames.cast<Object>();

  @override
  void send(Object data) => socket.add(data);

  @override
  Future<void> close([int? code, String? reason]) => socket.close(code, reason);
}

Future<WebSocket> _connectIoWebSocket(
  String url, {
  required Map<String, dynamic> headers,
  required Duration timeout,
}) => WebSocket.connect(
  url,
  headers: headers,
  compression: CompressionOptions.compressionOff,
).timeout(timeout);

void _ensureWebSocketMatchesHubOrigin(String hubOrigin, String webSocketUrl) {
  final hub = Uri.parse(hubOrigin);
  final socket = Uri.parse(webSocketUrl);
  if ((socket.scheme != 'ws' && socket.scheme != 'wss') ||
      socket.fragment.isNotEmpty) {
    throw const FormatException(
      'Hub WebSocket URL must use ws or wss without a fragment',
    );
  }
  final expectedScheme = hub.scheme == 'https' ? 'wss' : 'ws';
  if (socket.scheme != expectedScheme ||
      socket.host != hub.host ||
      _effectivePort(socket) != _effectivePort(hub)) {
    throw const FormatException('Hub WebSocket URL must match the Hub origin');
  }
}

int _effectivePort(Uri uri) {
  if (uri.hasPort) return uri.port;
  return switch (uri.scheme) {
    'https' || 'wss' => 443,
    'http' || 'ws' => 80,
    _ => uri.port,
  };
}

int? _statusFromWebSocketError(WebSocketException error) {
  final match = RegExp(r'\b(401|403)\b').firstMatch(error.message);
  return match == null ? null : int.parse(match.group(1)!);
}
