@Timeout(Duration(seconds: 20))
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/pair_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/server/daemon_config.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('daemon pairing RPC returns its live relay identity and QR', () async {
    final temp = await Directory.systemTemp.createTemp('daemon-pairing-rpc-');
    addTearDown(() => temp.delete(recursive: true));
    final relay = TinyrackRelayServer();
    await relay.start();
    addTearDown(relay.close);
    final endpoint = '127.0.0.1:${relay.boundPort}';
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: temp.path),
      host: '127.0.0.1',
      port: 0,
      dataDir: temp.path,
      relayConfig: DaemonRelayConfig(
        enabled: true,
        endpoint: endpoint,
        publicEndpoint: endpoint,
        useTls: false,
        publicUseTls: false,
      ),
      appBaseUrl: 'https://app.example.test',
      log: (_) {},
    );
    addTearDown(handle.stop);

    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${handle.server.port}/ws'),
    );
    await channel.ready;
    addTearDown(channel.sink.close);
    final frames = channel.stream
        .where((frame) => frame is String)
        .map((frame) => jsonDecode(frame as String) as Map<String, Object?>)
        .asBroadcastStream();
    channel.sink.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'pairing-rpc-e2e',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await frames.firstWhere((frame) => frame['status'] == 'server_info');

    channel.sink.add(
      jsonEncode({
        'type': 'session',
        'message': const DaemonGetPairingOfferRequest(
          requestId: 'pairing-1',
        ).toJson(),
      }),
    );
    final envelope = await frames.firstWhere(
      (frame) =>
          frame['type'] == 'session' &&
          (frame['message'] as Map?)?['type'] ==
              DaemonGetPairingOfferResponse.type,
    );
    final response = DaemonGetPairingOfferResponse.fromJson(
      (envelope['message'] as Map).cast<String, Object?>(),
    );
    final offer = parseConnectionOfferFromUrl(response.url);

    expect(response.requestId, 'pairing-1');
    expect(response.relayEnabled, isTrue);
    expect(response.qr, contains('\u001b[47m\u001b[30m'));
    expect(offer?.serverId, handle.server.serverId);
    expect(offer?.relay.endpoint, endpoint);
    expect(offer?.relay.useTls, isFalse);

    final fetched = await fetchRunningDaemonPairingOffer(
      _runtimeConfig(
        home: temp.path,
        listen: '127.0.0.1:${handle.server.port}',
        relayEndpoint: endpoint,
      ),
    );
    expect(fetched?.relayEnabled, isTrue);
    expect(
      parseConnectionOfferFromUrl(fetched!.url)?.serverId,
      handle.server.serverId,
    );

    expect(
      await fetchRunningDaemonPairingOffer(
        _runtimeConfig(
          home: temp.path,
          listen: '127.0.0.1:1',
          relayEndpoint: endpoint,
        ),
      ),
      isNull,
    );
  });
}

DaemonRuntimeConfig _runtimeConfig({
  required String home,
  required String listen,
  required String relayEndpoint,
}) => DaemonRuntimeConfig(
  home: home,
  listen: listen,
  corsAllowedOrigins: const [],
  trustedProxies: const ['loopback'],
  relay: DaemonRelayConfig(
    enabled: true,
    endpoint: relayEndpoint,
    publicEndpoint: relayEndpoint,
    useTls: false,
    publicUseTls: false,
  ),
  appBaseUrl: 'https://app.example.test',
  webUiEnabled: false,
  logLevel: 'info',
  logFormat: 'pretty',
  enableTerminalAgentHooks: false,
);
