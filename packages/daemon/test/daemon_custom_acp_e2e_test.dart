import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/server/daemon_config_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

String fixturePath() {
  final local = p.join(
    Directory.current.path,
    'test',
    'fixtures',
    'acp_agent_child.dart',
  );
  if (File(local).existsSync()) return local;
  return p.join(
    Directory.current.path,
    'packages',
    'daemon',
    'test',
    'fixtures',
    'acp_agent_child.dart',
  );
}

void main() {
  test(
    'installed ACP provider is executable through the live daemon manager',
    () async {
      final home = Directory.systemTemp.createTempSync('daemon-custom-acp-');
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      DaemonConfigStore(home: home.path).patch(
        MutableDaemonConfigPatch(
          providers: {
            'fixture-acp': MutableDaemonProviderConfig(
              extra: {
                'extends': 'acp',
                'label': 'Fixture ACP',
                'command': [Platform.resolvedExecutable, fixturePath()],
                'env': const {'ACP_FIXTURE_ENV': 'configured'},
                'params': const {'supportsMcpServers': false},
              },
            ),
          },
        ),
      );

      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: home.path),
        dataDir: home.path,
        host: '127.0.0.1',
        port: 0,
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
            clientId: 'custom-acp-e2e',
            clientType: WebSocketClientType.cli,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      await frames.firstWhere((frame) => frame['status'] == 'server_info');
      final snapshotFrame = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] ==
                'get_providers_snapshot_response',
      );
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': const GetProvidersSnapshotRequest(
            requestId: 'custom-acp-snapshot',
            cwd: '.',
          ).toJson(),
        }),
      );
      final snapshot = GetProvidersSnapshotResponse.fromJson(
        ((await snapshotFrame)['message'] as Map).cast<String, Object?>(),
      );
      final provider = snapshot.entries.firstWhere(
        (entry) => entry.provider == 'fixture-acp',
      );
      expect(provider.status, ProviderCatalogStatus.ready);
      expect(provider.models?.map((model) => model.id), [
        'fixture-model',
        'fixture-fast',
      ]);
      expect(provider.modes?.map((mode) => mode.id), ['agent', 'plan']);
      expect(provider.models?.first.defaultThinkingOptionId, 'medium');

      expect(handle.manager.isProviderAvailable('fixture-acp'), isTrue);
      final created = await handle.manager.createAgent(
        cwd: Directory.current.path,
        provider: 'fixture-acp',
        model: '',
        mode: AgentMode.normal,
        title: 'Custom ACP',
      );
      await pumpEventQueue();

      expect(created.provider, 'fixture-acp');
      expect(handle.manager.get(created.agentId)?.sessionId, 'session-1');
      expect(
        (await handle.manager.listCommands(agentId: created.agentId)).single,
        isA<AgentSlashCommand>().having(
          (command) => command.name,
          'command',
          'review',
        ),
      );

      final recentFrame = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] ==
                FetchRecentProviderSessionsResponse.type,
      );
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': FetchRecentProviderSessionsRequest(
            requestId: 'custom-acp-recent',
            cwd: Directory.current.path,
            providers: const ['fixture-acp'],
            limit: 10,
          ).toJson(),
        }),
      );
      final recent = FetchRecentProviderSessionsResponse.fromJson(
        ((await recentFrame)['message'] as Map).cast<String, Object?>(),
      );
      expect(recent.entries, hasLength(2));
      expect(
        recent.entries.first,
        isA<RecentProviderSessionDescriptor>()
            .having((entry) => entry.providerId, 'provider', 'fixture-acp')
            .having(
              (entry) => entry.providerHandleId,
              'provider handle',
              'restored-session',
            )
            .having((entry) => entry.title, 'title', 'Imported ACP session'),
      );

      final imported = await handle.manager.importProviderSession(
        provider: 'fixture-acp',
        providerHandleId: 'restored-session',
        cwd: Directory.current.path,
        workspaceId: 'workspace-import',
      );
      expect(imported.timelineSize, 5);
      expect(imported.summary.sessionId, 'restored-session');
      final importedTimeline = handle.manager.fetchTimeline(
        imported.summary.agentId,
      );
      expect(
        importedTimeline.items.whereType<AssistantMessageItem>().single.text,
        'Loaded response',
      );
      expect(
        importedTimeline.items.whereType<ToolCallItem>().single.status,
        ToolCallStatus.success,
      );
    },
  );
}
