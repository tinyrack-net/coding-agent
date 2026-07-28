@Timeout(Duration(seconds: 20))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/server/relay_transport.dart';
import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';

void main() {
  test(
    'local relay carries an encrypted daemon v2 session end to end',
    () async {
      final relay = TinyrackRelayServer();
      await relay.start();
      addTearDown(relay.close);

      final daemonKeyPair = RelayKeyPair.generate();
      final server = WsServer(router: RpcRouter(), serverId: 'srv_e2e');
      final controller = RelayTransportController(
        server: server,
        relayEndpoint: '127.0.0.1:${relay.boundPort}',
        relayUseTls: false,
        serverId: 'srv_e2e',
        daemonKeyPair: daemonKeyPair,
        controlPingInterval: const Duration(milliseconds: 100),
      );
      addTearDown(() async {
        await controller.stop();
        await server.stop();
      });
      await _waitUntil(() => controller.controlReady);

      final rawClient = await WebSocket.connect(
        buildRelayWebSocketUrl(
          endpoint: '127.0.0.1:${relay.boundPort}',
          useTls: false,
          serverId: 'srv_e2e',
          role: RelayRole.client,
          connectionId: 'conn_e2e',
        ),
        compression: CompressionOptions.compressionOff,
      );
      addTearDown(rawClient.close);
      final plaintext = StreamController<Object>();
      late final RelayE2eeClientChannel client;
      client = RelayE2eeClientChannel(
        daemonPublicKeyB64: exportRelayPublicKey(daemonKeyPair.publicKey),
        transportSend: rawClient.add,
        transportClose: rawClient.close,
        onMessage: plaintext.add,
        handshakeRetry: const Duration(milliseconds: 30),
      );
      final rawSubscription = rawClient.listen(
        (frame) => client.handleFrame(frame as Object),
        onDone: () {
          client.transportClosed(
            rawClient.closeCode ?? 1006,
            rawClient.closeReason ?? '',
          );
          if (!plaintext.isClosed) unawaited(plaintext.close());
        },
      );
      addTearDown(rawSubscription.cancel);
      addTearDown(() async {
        client.close();
        if (!plaintext.isClosed) await plaintext.close();
      });
      final frames = StreamIterator<Object>(plaintext.stream);
      addTearDown(frames.cancel);

      client.start();
      await client.ready;
      client.send(
        jsonEncode(
          const WebSocketHello(
            clientId: 'relay-e2e',
            clientType: WebSocketClientType.browser,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      final serverInfo = jsonDecode(await _nextText(frames));
      expect(serverInfo, containsPair('status', 'server_info'));
      expect(serverInfo, containsPair('serverId', 'srv_e2e'));

      client.send(jsonEncode(const {'type': 'ping'}));
      expect(jsonDecode(await _nextText(frames)), const {'type': 'pong'});
      expect(server.authenticatedV2Connections.single.transport, 'relay');
    },
  );
}

Future<String> _nextText(StreamIterator<Object> frames) async {
  if (!await frames.moveNext()) throw StateError('relay stream closed');
  return frames.current as String;
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
