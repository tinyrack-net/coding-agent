@Timeout(Duration(seconds: 20))
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/server/daemon_config.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test(
    'diagnostics RPC reports the assembled daemon without secrets',
    () async {
      final home = await Directory.systemTemp.createTemp('diagnostics-e2e-');
      addTearDown(() => home.delete(recursive: true));
      File(
        '${home.path}${Platform.pathSeparator}daemon.log',
      ).writeAsStringSync('token=secret-value\n');
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: home.path,
        relayConfig: const DaemonRelayConfig(
          enabled: false,
          endpoint: 'relay-secret.example:443',
          publicEndpoint: 'relay-secret.example:443',
          useTls: true,
          publicUseTls: true,
        ),
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
            clientId: 'diagnostics-e2e',
            clientType: WebSocketClientType.cli,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      await frames.firstWhere((frame) => frame['status'] == 'server_info');
      handle.server.flushRuntimeMetrics();

      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': const DiagnosticsRequest(
            requestId: 'diagnostic-1',
          ).toJson(),
        }),
      );
      final envelope = await frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == DiagnosticsResponse.type,
      );
      final response = DiagnosticsResponse.fromJson(
        (envelope['message'] as Map).cast<String, Object?>(),
      );

      expect(response.requestId, 'diagnostic-1');
      expect(response.diagnostic, startsWith('Tinyrack diagnostics'));
      expect(response.diagnostic, contains('Daemon version: 0.2.0'));
      expect(response.diagnostic, contains('Sessions: active=1'));
      expect(response.diagnostic, contains('helloNew=1'));
      expect(response.diagnostic, contains('token=[redacted]'));
      expect(response.diagnostic, isNot(contains('secret-value')));
      expect(handle.server.diagnosticSnapshot(), containsPair('final', false));
    },
  );
}
