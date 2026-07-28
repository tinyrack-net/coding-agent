import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';

void main() {
  test(
    'relay E2EE performs hello, RPC, and binary terminal transport',
    () async {
      final daemonKeyPair = RelayKeyPair.fromSecretKey(
        Uint8List.fromList(List<int>.generate(32, (index) => index + 32)),
      );
      final server = await _RelayTestServer.start(daemonKeyPair);
      addTearDown(server.close);
      final uri = Uri.parse(
        buildRelayWebSocketUrl(
          endpoint: '127.0.0.1:${server.port}',
          useTls: false,
          serverId: 'server-test',
          role: RelayRole.client,
        ),
      );
      final client = DaemonClient(
        uri: uri,
        relayE2ee: RelayE2eeOptions(
          daemonPublicKeyB64: exportRelayPublicKey(daemonKeyPair.publicKey),
        ),
      );
      addTearDown(client.dispose);

      await client.connect();
      expect(client.currentState, DaemonConnectionState.connected);
      expect(client.serverInfo?.serverId, 'server-test');
      expect(server.clientHello?['type'], 'hello');

      final response = await client.request(
        MessageTypes.providerListRequest,
        const {},
      );
      expect(response, {'providers': <Object?>[]});
      expect(server.lastRequest?['type'], MessageTypes.providerListRequest);

      final terminalFuture = client.terminalFrames.first;
      server.send(
        TerminalFrame(
          opcode: TerminalOpcode.output,
          slotId: 7,
          payload: Uint8List.fromList(utf8.encode('encrypted terminal')),
        ).encode(),
      );
      final terminal = await terminalFuture;
      expect(terminal.slotId, 7);
      expect(utf8.decode(terminal.payload), 'encrypted terminal');
    },
  );

  test('relay URLs require a daemon public key before app hello', () async {
    final daemonKeyPair = RelayKeyPair.generate();
    final server = await _RelayTestServer.start(daemonKeyPair);
    addTearDown(server.close);
    final client = DaemonClient(
      uri: Uri.parse(
        buildRelayWebSocketUrl(
          endpoint: '127.0.0.1:${server.port}',
          useTls: false,
          serverId: 'server-test',
          role: RelayRole.client,
        ),
      ),
    );
    addTearDown(client.dispose);

    await client.connect();
    expect(client.currentState, DaemonConnectionState.disconnected);
    expect(server.clientHello, isNull);
  });

  test(
    'relay E2EE reconnects with a fresh handshake after transport loss',
    () async {
      final daemonKeyPair = RelayKeyPair.generate();
      final server = await _RelayTestServer.start(daemonKeyPair);
      addTearDown(server.close);
      final client = DaemonClient(
        uri: Uri.parse(
          buildRelayWebSocketUrl(
            endpoint: '127.0.0.1:${server.port}',
            useTls: false,
            serverId: 'server-test',
            role: RelayRole.client,
          ),
        ),
        relayE2ee: RelayE2eeOptions(
          daemonPublicKeyB64: exportRelayPublicKey(daemonKeyPair.publicKey),
        ),
      );
      addTearDown(client.dispose);

      await client.connect();
      expect(server.connectionCount, 1);
      final reconnected = client.connectionState.firstWhere(
        (state) =>
            state == DaemonConnectionState.connected &&
            server.connectionCount >= 2,
      );

      await server.dropCurrentConnection();
      await reconnected.timeout(const Duration(seconds: 5));

      expect(client.currentState, DaemonConnectionState.connected);
      expect(server.connectionCount, 2);
      final response = await client.request(
        MessageTypes.providerListRequest,
        const {},
      );
      expect(response, {'providers': <Object?>[]});
    },
  );
}

final class _RelayTestServer {
  _RelayTestServer._(this._server, this._daemonKeyPair);

  final HttpServer _server;
  final RelayKeyPair _daemonKeyPair;
  final List<WebSocket> _sockets = [];
  WebSocket? _socket;
  Uint8List? _sharedKey;
  Map<String, Object?>? clientHello;
  Map<String, Object?>? lastRequest;
  int connectionCount = 0;

  int get port => _server.port;

  static Future<_RelayTestServer> start(RelayKeyPair daemonKeyPair) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = _RelayTestServer._(server, daemonKeyPair);
    unawaited(result._serve());
    return result;
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      final socket = await WebSocketTransformer.upgrade(request);
      connectionCount++;
      _sockets.add(socket);
      _socket = socket;
      unawaited(_handle(socket));
    }
  }

  Future<void> _handle(WebSocket socket) async {
    var handshaking = true;
    await for (final raw in socket) {
      if (handshaking) {
        final hello = jsonDecode(raw as String) as Map<String, Object?>;
        if (hello['type'] != 'e2ee_hello') continue;
        _sharedKey = deriveRelaySharedKey(
          secretKey: _daemonKeyPair.secretKey,
          peerPublicKey: importRelayPublicKey(hello['key']! as String),
        );
        socket.add('{"type":"e2ee_ready"}');
        handshaking = false;
        continue;
      }
      final plaintext = decryptRelayPayload(
        _sharedKey!,
        base64.decode(raw as String),
      );
      if (plaintext is! String) continue;
      final frame = jsonDecode(plaintext) as Map<String, Object?>;
      if (frame['type'] == 'hello') {
        clientHello = frame;
        send({
          'status': 'server_info',
          'serverId': 'server-test',
          'hostname': 'relay-host',
          'version': '0.1.0',
          'desktopManaged': false,
          'capabilities': <String, Object?>{},
          'features': <String, bool>{},
        });
        continue;
      }
      final message = frame['message'];
      if (frame['type'] == 'session' && message is Map) {
        final request = message.cast<String, Object?>();
        lastRequest = request;
        send({
          'type': 'session',
          'message': RpcResponse(
            type: '${request['type']}.response',
            requestId: request['requestId']! as String,
            payload: {'providers': <Object?>[]},
          ).toJson(),
        });
      }
    }
  }

  void send(Object data) {
    final socket = _socket;
    final sharedKey = _sharedKey;
    if (socket == null || sharedKey == null) {
      throw StateError('Relay client is not ready');
    }
    final payload = data is String || data is Uint8List || data is List<int>
        ? data
        : jsonEncode(data);
    socket.add(base64.encode(encryptRelayPayload(sharedKey, payload)));
  }

  Future<void> dropCurrentConnection() async {
    final socket = _socket;
    if (socket == null) throw StateError('Relay client is not connected');
    await socket.close(4002, 'test transport loss');
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}
