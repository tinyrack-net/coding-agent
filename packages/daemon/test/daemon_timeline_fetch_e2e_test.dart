import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/agent/timeline_store.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test(
    'timeline fetch resets an after cursor behind retained history',
    () async {
      final temp = Directory.systemTemp.createTempSync('timeline-fetch-e2e-');
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      const agent = AgentSummary(
        agentId: 'agent-retained',
        title: 'Retained timeline',
        cwd: '/repo',
        provider: 'codex',
        model: 'gpt-5',
        mode: AgentMode.normal,
        runState: AgentRunState.idle,
        createdAtMs: 1000,
        lastUserMessageAt: '2026-07-28T00:00:04.000Z',
        lastError: 'persisted provider error',
        labels: {'origin': 'schedule'},
      );
      const rows = [
        TimelineRow(
          seq: 5,
          timestamp: '2026-07-28T00:00:05.000Z',
          item: AssistantMessageItem(id: 'm5', text: 'five', complete: true),
        ),
        TimelineRow(
          seq: 6,
          timestamp: '2026-07-28T00:00:06.000Z',
          item: AssistantMessageItem(id: 'm6', text: 'six', complete: true),
        ),
        TimelineRow(
          seq: 7,
          timestamp: '2026-07-28T00:00:07.000Z',
          item: AssistantMessageItem(id: 'm7', text: 'seven', complete: true),
        ),
      ];
      await AgentStore(dataDir: temp.path).save(
        const PersistedAgent(
          summary: agent,
          archived: false,
          epoch: 3,
          lastSeq: 7,
          items: [
            AssistantMessageItem(id: 'm5', text: 'five', complete: true),
            AssistantMessageItem(id: 'm6', text: 'six', complete: true),
            AssistantMessageItem(id: 'm7', text: 'seven', complete: true),
          ],
          rows: rows,
        ),
      );

      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: temp.path,
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
            clientId: 'timeline-fetch-e2e',
            clientType: WebSocketClientType.cli,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      await frames.firstWhere((frame) => frame['status'] == 'server_info');

      final response = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] ==
                'fetch_agent_timeline_response',
      );
      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': {
            'type': 'fetch_agent_timeline_request',
            'requestId': 'fetch-gap',
            'agentId': agent.agentId,
            'cursor': {'epoch': '3', 'seq': 1},
            'limit': 1,
            'projection': 'canonical',
          },
        }),
      );
      final payload = Map<String, Object?>.from(
        Map<String, Object?>.from((await response)['message'] as Map)['payload']
            as Map,
      );
      expect(payload['direction'], 'after');
      expect(payload['reset'], isTrue);
      expect(payload['staleCursor'], isFalse);
      expect(payload['gap'], isTrue);
      expect(payload['window'], {'minSeq': 5, 'maxSeq': 7, 'nextSeq': 8});
      expect(payload['hasOlder'], isTrue);
      expect(payload['hasNewer'], isFalse);
      expect(payload['startCursor'], {'epoch': '3', 'seq': 7});
      expect(payload['endCursor'], {'epoch': '3', 'seq': 7});
      final entries = (payload['entries'] as List).cast<Map>();
      expect(entries, hasLength(1));
      expect(
        Map<String, Object?>.from(entries.single['item'] as Map)['text'],
        'seven',
      );
      expect(
        Map<String, Object?>.from(payload['agent'] as Map)['id'],
        agent.agentId,
      );
      final snapshot = Map<String, Object?>.from(payload['agent'] as Map);
      expect(snapshot['currentModeId'], 'auto-review');
      expect(snapshot['lastUserMessageAt'], '2026-07-28T00:00:04.000Z');
      expect(snapshot['lastError'], 'persisted provider error');
      expect(snapshot['labels'], {'origin': 'schedule'});
      expect(
        (snapshot['availableModes'] as List).cast<Map>().map(
          (mode) => mode['id'],
        ),
        ['auto', 'auto-review', 'full-access'],
      );
      expect(
        Map<String, Object?>.from(snapshot['capabilities'] as Map),
        containsPair('supportsRewindConversation', true),
      );
      expect(
        Map<String, Object?>.from(snapshot['capabilities'] as Map),
        containsPair('supportsDynamicModes', false),
      );
      expect(
        (snapshot['features'] as List).cast<Map>().map(
          (feature) => [feature['id'], feature['value']],
        ),
        [
          ['fast_mode', false],
          ['plan_mode', false],
        ],
      );
    },
  );
}
