import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/cli/schedule_command.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('schedule lifecycle crosses the v2 daemon WebSocket boundary', () async {
    final home = Directory.systemTemp.createTempSync('daemon-schedule-e2e-');
    addTearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
    });
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
          clientId: 'schedule-e2e',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await frames.firstWhere((frame) => frame['status'] == 'server_info');

    Future<Map<String, Object?>> request(Map<String, Object?> message) async {
      final responseType = '${message['type']}/response';
      final future = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == responseType,
      );
      channel.sink.add(jsonEncode({'type': 'session', 'message': message}));
      return ((await future)['message'] as Map).cast<String, Object?>();
    }

    final created = await request({
      'type': 'schedule/create',
      'requestId': 'create',
      'prompt': 'Review the branch',
      'name': 'Review',
      'cadence': {'type': 'cron', 'expression': '0 9 * * 1-5'},
      'target': {
        'type': 'agent',
        'agentId': '11111111-1111-4111-8111-111111111111',
      },
      'runOnCreate': false,
    });
    final createdPayload = created['payload'] as Map;
    expect(createdPayload['error'], isNull);
    final schedule = createdPayload['schedule'] as Map;
    final id = schedule['id']! as String;
    expect(id, matches(RegExp(r'^[0-9a-f]{8}$')));

    final listed = await request({
      'type': 'schedule/list',
      'requestId': 'list',
    });
    expect((listed['payload'] as Map)['schedules'], hasLength(1));

    var cliOutput = '';
    expect(
      await runScheduleCommand(
        arguments: [
          'ls',
          '--host',
          '127.0.0.1:${handle.server.port}',
          '--json',
        ],
        writeOutput: (value) => cliOutput += value,
      ),
      0,
    );
    expect(jsonDecode(cliOutput), isA<List>());

    final paused = await request({
      'type': 'schedule/pause',
      'requestId': 'pause',
      'scheduleId': id,
    });
    expect(
      (((paused['payload'] as Map)['schedule'] as Map)['status']),
      'paused',
    );

    final resumed = await request({
      'type': 'schedule/resume',
      'requestId': 'resume',
      'scheduleId': id,
    });
    expect(
      (((resumed['payload'] as Map)['schedule'] as Map)['status']),
      'active',
    );

    final deleted = await request({
      'type': 'schedule/delete',
      'requestId': 'delete',
      'scheduleId': id,
    });
    expect((deleted['payload'] as Map)['scheduleId'], id);
    expect((await handle.schedules.list()), isEmpty);
  });
}
