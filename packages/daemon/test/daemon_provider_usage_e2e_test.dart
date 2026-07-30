@Timeout(Duration(seconds: 20))
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/providers/usage/provider_usage.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test(
    'real daemon advertises and serves the frozen provider usage RPC',
    () async {
      final home = await Directory.systemTemp.createTemp('provider-usage-e2e-');
      addTearDown(() => home.delete(recursive: true));
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: home.path,
        providerUsageFetchers: const [_UsageFetcher()],
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
            clientId: 'provider-usage-e2e',
            clientType: WebSocketClientType.cli,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      final hello = await frames.firstWhere(
        (frame) => frame['status'] == 'server_info',
      );
      expect((hello['features'] as Map)['providerUsageList'], isTrue);

      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': const ProviderUsageListRequest(
            requestId: 'usage-1',
          ).toJson(),
        }),
      );
      final envelope = await frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] ==
                ProviderUsageListResponse.type,
      );
      final response = ProviderUsageListResponse.fromJson(
        (envelope['message'] as Map).cast<String, Object?>(),
      );

      expect(response.requestId, 'usage-1');
      expect(response.providers.single.windows.single.label, 'Weekly');
      expect(
        response.providers.single.windows.single.tone,
        ProviderUsageTone.danger,
      );
    },
  );
}

final class _UsageFetcher implements ProviderUsageFetcher {
  const _UsageFetcher();

  @override
  String get providerId => 'codex';

  @override
  String get displayName => 'Codex';

  @override
  Future<ProviderUsage> fetchUsage() async => ProviderUsage(
    providerId: providerId,
    displayName: displayName,
    status: ProviderUsageStatus.available,
    planLabel: 'Plus',
    windows: [
      ProviderUsageWindow(
        id: 'weekly',
        label: 'Weekly',
        usedPct: 96,
        tone: providerUsageToneFromUsedPct(96),
      ),
    ],
  );
}
