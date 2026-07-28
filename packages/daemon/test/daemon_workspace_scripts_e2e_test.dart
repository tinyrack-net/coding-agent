import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_daemon/src/workspace/service_proxy_standalone.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('workspace script list, start, status, and stop cross daemon PTY', () async {
    final home = Directory.systemTemp.createTempSync('daemon-scripts-e2e-');
    addTearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
    });
    final workspace = Directory(p.join(home.path, 'workspace'))..createSync();
    final portSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final servicePort = portSocket.port;
    await portSocket.close();
    File(p.join(workspace.path, 'hold.dart')).writeAsStringSync(
      "import 'dart:io';\n"
      'Future<void> main() async {\n'
      "  final port = int.parse(Platform.environment['TINYRACK_PORT']!);\n"
      "  final server = await HttpServer.bind(Platform.environment['HOST']!, port);\n"
      '  await for (final request in server) {\n'
      "    request.response.write('\$port|\${Platform.environment['TINYRACK_URL']}');\n"
      '    await request.response.close();\n'
      '  }\n'
      '}\n',
    );
    File(p.join(workspace.path, 'tinyrack.json')).writeAsStringSync(
      jsonEncode({
        'scripts': {
          'hold': {
            'type': 'service',
            'command': 'dart run hold.dart',
            'port': servicePort,
          },
        },
      }),
    );
    final registries = WorkspaceRegistries(dataDir: home.path);
    await registries.initialize();
    await registries.workspaces.upsert(
      createPersistedWorkspaceRecord(
        workspaceId: 'workspace',
        projectId: 'project',
        cwd: workspace.path,
        kind: PersistedWorkspaceKind.directory,
        displayName: 'Workspace',
        createdAt: '1',
        updatedAt: '1',
      ),
    );
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: home.path),
      dataDir: home.path,
      host: '127.0.0.1',
      port: 0,
      serviceProxyPublicBaseUrl: 'https://services.example.test:9443',
      serviceProxyListen: '127.0.0.1:0',
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
          clientId: 'workspace-script-e2e',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await frames.firstWhere((frame) => frame['status'] == 'server_info');

    Future<Map<String, Object?>> request(
      WorkspaceScriptRequest request,
      String responseType,
    ) async {
      final response = frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map?)?['type'] == responseType,
      );
      channel.sink.add(
        jsonEncode({'type': 'session', 'message': request.toJson()}),
      );
      return ((await response)['message'] as Map).cast<String, Object?>();
    }

    final listed = WorkspaceScriptOperationResponse.fromJson(
      await request(
        const WorkspaceScriptListRequest(
          workspaceId: 'workspace',
          requestId: 'list',
        ),
        'workspace.script.list.response',
      ),
    );
    expect(listed.scripts!.single.lifecycle, WorkspaceScriptLifecycle.stopped);

    final status = frames.firstWhere(
      (frame) =>
          frame['type'] == 'session' &&
          (frame['message'] as Map?)?['type'] == 'script_status_update',
    );
    final started = WorkspaceScriptOperationResponse.fromJson(
      await request(
        const WorkspaceScriptStartRequest(
          workspaceId: 'workspace',
          scriptName: 'hold',
          requestId: 'start',
        ),
        'workspace.script.start.response',
      ),
    );
    expect(started.error, isNull);
    expect(started.script!.terminalId, isNotEmpty);
    expect(started.script!.port, servicePort);
    expect(started.script!.hostname, 'hold--workspace.localhost');
    expect(
      started.script!.localProxyUrl,
      'http://hold--workspace.localhost:${handle.server.port}',
    );
    expect(
      started.script!.publicProxyUrl,
      'https://hold--workspace.services.example.test:9443',
    );
    expect(started.script!.proxyUrl, started.script!.publicProxyUrl);
    expect(
      WorkspaceScriptStatusUpdate.fromJson(
        ((await status)['message'] as Map).cast<String, Object?>(),
      ).scripts.single.lifecycle,
      WorkspaceScriptLifecycle.running,
    );

    final client = HttpClient();
    addTearDown(client.close);
    HttpClientResponse? proxied;
    for (var attempt = 0; attempt < 30; attempt++) {
      final proxyRequest = await client.getUrl(
        Uri.parse('http://127.0.0.1:${handle.server.port}/ready'),
      );
      proxyRequest.headers.host = 'hold--workspace.localhost';
      final candidate = await proxyRequest.close();
      if (candidate.statusCode == 200) {
        proxied = candidate;
        break;
      }
      await candidate.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(proxied, isNotNull);
    expect(
      await utf8.decoder.bind(proxied!).join(),
      '$servicePort|https://hold--workspace.services.example.test:9443',
    );

    final standaloneTarget =
        handle.serviceProxyStandalone!.boundTarget as ServiceProxyTcpTarget;
    final standaloneRequest = await client.getUrl(
      Uri.parse('http://127.0.0.1:${standaloneTarget.port}/standalone'),
    );
    standaloneRequest.headers.host = 'hold--workspace.localhost';
    final standaloneResponse = await standaloneRequest.close();
    expect(standaloneResponse.statusCode, 200);
    await standaloneResponse.drain<void>();

    final stopped = WorkspaceScriptOperationResponse.fromJson(
      await request(
        const WorkspaceScriptStopRequest(
          workspaceId: 'workspace',
          scriptName: 'hold',
          requestId: 'stop',
        ),
        'workspace.script.stop.response',
      ),
    );
    expect(stopped.error, isNull);
    expect(stopped.script!.lifecycle, WorkspaceScriptLifecycle.stopped);

    final removedRequest = await client.getUrl(
      Uri.parse('http://127.0.0.1:${handle.server.port}/ready'),
    );
    removedRequest.headers.host = 'hold--workspace.localhost';
    final removed = await removedRequest.close();
    expect(removed.statusCode, 404);
    expect(await utf8.decoder.bind(removed).join(), '404 Not Found');
  });
}
