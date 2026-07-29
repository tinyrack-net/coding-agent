import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/src/cli/cli_client_id.dart';
import 'package:agent_daemon/src/cli/cli_version.dart';
import 'package:agent_daemon/src/cli/terminal_command.dart';
import 'package:agent_daemon/src/server/daemon_config.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';

void main() {
  test(
    'pairing offer connects CLI through relay E2EE and performs RPC',
    () async {
      final daemonKeyPair = RelayKeyPair.fromSecretKey(
        Uint8List.fromList(List<int>.generate(32, (index) => index + 32)),
      );
      final server = await _RelayCliTestServer.start(daemonKeyPair);
      addTearDown(server.close);
      final home = await Directory.systemTemp.createTemp('cli-relay-e2ee-');
      addTearDown(() => home.delete(recursive: true));
      final environment = {'TINYRACK_HOME': home.path};
      final offer = ConnectionOffer(
        serverId: 'relay-server-test',
        daemonPublicKeyB64: exportRelayPublicKey(daemonKeyPair.publicKey),
        relay: ConnectionOfferRelay(
          endpoint: '127.0.0.1:${server.port}',
          useTls: false,
        ),
      );
      final offerUrl = encodeConnectionOfferToFragmentUrl(
        offer,
        'https://app.tinyrack.dev',
      );

      final client = await DaemonCliSocketClient.connect(
        loadDaemonRuntimeConfig(home: home.path, environment: environment),
        hostOverride: offerUrl,
        environment: environment,
        timeout: const Duration(seconds: 5),
      );
      addTearDown(client.close);

      expect(client.serverInfo.serverId, 'relay-server-test');
      expect(server.requestedPath, '/ws');
      expect(server.queryParameters, {
        'serverId': 'relay-server-test',
        'role': 'client',
        'v': currentRelayProtocolVersion,
      });
      expect(server.clientHello, {
        'type': 'hello',
        'clientId': matches(RegExp(r'^cid_[0-9a-f]{32}$')),
        'clientType': 'cli',
        'protocolVersion': paseoWebSocketProtocolVersion,
        'appVersion': resolveCliVersion(),
      });
      expect(
        await File(p.join(home.path, cliClientIdFileName)).readAsString(),
        server.clientHello!['clientId'],
      );

      final response = await client.request({
        'type': MessageTypes.providerListRequest,
        'requestId': 'relay-provider-list',
        'payload': <String, Object?>{},
      });
      expect(response, {
        'requestId': 'relay-provider-list',
        'providers': <Object?>[],
      });
      expect(server.lastRequest?['type'], MessageTypes.providerListRequest);
      expect(server.lastRequest?['requestId'], 'relay-provider-list');
    },
  );

  test(
    'malformed pairing offer fails before a direct connection attempt',
    () async {
      final home = Directory.systemTemp.createTempSync('cli-relay-invalid-');
      addTearDown(() => home.deleteSync(recursive: true));
      final environment = {'TINYRACK_HOME': home.path};

      await expectLater(
        DaemonCliSocketClient.connect(
          loadDaemonRuntimeConfig(home: home.path, environment: environment),
          hostOverride: 'https://app.tinyrack.dev/#offer=not-base64!',
          environment: environment,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Invalid pairing offer URL:'),
          ),
        ),
      );
    },
  );
}

final class _RelayCliTestServer {
  _RelayCliTestServer._(this._server, this._daemonKeyPair);

  final HttpServer _server;
  final RelayKeyPair _daemonKeyPair;
  final List<WebSocket> _sockets = [];
  String? requestedPath;
  Map<String, String>? queryParameters;
  Map<String, Object?>? clientHello;
  Map<String, Object?>? lastRequest;

  int get port => _server.port;

  static Future<_RelayCliTestServer> start(RelayKeyPair daemonKeyPair) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = _RelayCliTestServer._(server, daemonKeyPair);
    unawaited(result._serve());
    return result;
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      requestedPath = request.uri.path;
      queryParameters = request.uri.queryParameters;
      final socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      unawaited(_handle(socket));
    }
  }

  Future<void> _handle(WebSocket socket) async {
    Uint8List? sharedKey;
    await for (final raw in socket) {
      if (sharedKey == null) {
        final hello = jsonDecode(raw as String) as Map<String, Object?>;
        if (hello['type'] != 'e2ee_hello') continue;
        sharedKey = deriveRelaySharedKey(
          secretKey: _daemonKeyPair.secretKey,
          peerPublicKey: importRelayPublicKey(hello['key']! as String),
        );
        socket.add('{"type":"e2ee_ready"}');
        continue;
      }
      final plaintext = decryptRelayPayload(
        sharedKey,
        base64.decode(raw as String),
      );
      if (plaintext is! String) continue;
      final frame = jsonDecode(plaintext) as Map<String, Object?>;
      if (frame['type'] == 'hello') {
        clientHello = frame;
        _sendEncrypted(socket, sharedKey, {
          'status': 'server_info',
          'serverId': 'relay-server-test',
          'hostname': 'relay-host',
          'version': '0.2.0',
          'desktopManaged': false,
          'capabilities': <String, Object?>{},
          'features': <String, bool>{},
        });
        continue;
      }
      final message = frame['message'];
      if (frame['type'] != 'session' || message is! Map) continue;
      final request = message.cast<String, Object?>();
      lastRequest = request;
      _sendEncrypted(socket, sharedKey, {
        'type': 'session',
        'message': {
          'type': 'provider.list.response',
          'payload': {
            'requestId': request['requestId'],
            'providers': <Object?>[],
          },
        },
      });
    }
  }

  void _sendEncrypted(WebSocket socket, Uint8List sharedKey, Object message) {
    socket.add(
      base64.encode(encryptRelayPayload(sharedKey, jsonEncode(message))),
    );
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}
