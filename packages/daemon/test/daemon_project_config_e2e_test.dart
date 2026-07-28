import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/server/project_config_service.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('v2 project config write and read cross daemon assembly', () async {
    final home = Directory.systemTemp.createTempSync('daemon-project-config-');
    final project = Directory(p.join(home.path, 'project'))..createSync();
    addTearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
    });
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: p.join(home.path, '.tinyrack')),
      dataDir: p.join(home.path, '.data'),
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
          clientId: 'project-config-e2e',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await frames.firstWhere((frame) => frame['status'] == 'server_info');

    Future<Map<String, Object?>> request(
      Map<String, Object?> message,
      String responseType,
    ) async {
      final future = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == responseType,
      );
      channel.sink.add(jsonEncode({'type': 'session', 'message': message}));
      return ((await future)['message'] as Map).cast<String, Object?>();
    }

    final added = ProjectAddResponse.fromJson(
      await request(
        ProjectAddRequest(cwd: project.path, requestId: 'add').toJson(),
        'project.add.response',
      ),
    );
    expect(added.project, isNotNull);
    final write = await request({
      'type': 'write_project_config_request',
      'requestId': 'write',
      'repoRoot': project.path,
      'config': {
        'worktree': {
          'setup': ['install'],
          'servicePorts': {'range': '4000-4010'},
        },
      },
      'expectedRevision': null,
    }, 'write_project_config_response');
    final writePayload = (write['payload'] as Map);
    expect(writePayload['ok'], isTrue);
    expect(
      File(p.join(project.path, tinyrackProjectConfigFileName)).existsSync(),
      isTrue,
    );

    final read = await request({
      'type': 'read_project_config_request',
      'requestId': 'read',
      'repoRoot': project.path,
    }, 'read_project_config_response');
    final readPayload = read['payload'] as Map;
    expect(readPayload['config'], writePayload['config']);
    expect(readPayload['revision'], writePayload['revision']);
  });
}
