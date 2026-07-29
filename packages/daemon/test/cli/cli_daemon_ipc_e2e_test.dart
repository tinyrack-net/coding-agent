import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/cli_version.dart';
import 'package:agent_daemon/src/cli/terminal_command.dart';
import 'package:agent_daemon/src/server/daemon_config.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:dart_ipc/dart_ipc.dart' as ipc;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('CLI performs hello and RPC over the platform IPC transport', () async {
    final server = await _IpcCliTestServer.start();
    addTearDown(server.close);
    final home = await Directory.systemTemp.createTemp('cli-ipc-e2e-');
    addTearDown(() => home.delete(recursive: true));
    final environment = {'TINYRACK_HOME': home.path};

    final client = await DaemonCliSocketClient.connect(
      loadDaemonRuntimeConfig(home: home.path, environment: environment),
      hostOverride: server.cliHost,
      environment: environment,
      timeout: const Duration(seconds: 5),
    );
    addTearDown(client.close);

    expect(client.serverInfo.serverId, 'ipc-server-test');
    expect(server.requestedPath, '/ws');
    expect(server.clientHello, {
      'type': 'hello',
      'clientId': matches(RegExp(r'^cid_[0-9a-f]{32}$')),
      'clientType': 'cli',
      'protocolVersion': paseoWebSocketProtocolVersion,
      'appVersion': resolveCliVersion(),
    });

    final response = await client.request({
      'type': MessageTypes.providerListRequest,
      'requestId': 'ipc-provider-list',
      'payload': <String, Object?>{},
    });
    expect(response, {
      'requestId': 'ipc-provider-list',
      'providers': <Object?>[],
    });
    expect(server.lastRequest?['type'], MessageTypes.providerListRequest);
    expect(server.lastRequest?['requestId'], 'ipc-provider-list');
  });
}

final class _IpcCliTestServer {
  _IpcCliTestServer._({
    required this.cliHost,
    required this.socketPath,
    required this.directory,
    required ServerSocket listener,
    required HttpServer server,
  }) : _listener = listener,
       _server = server;

  final String cliHost;
  final String socketPath;
  final Directory? directory;
  final ServerSocket _listener;
  final HttpServer _server;
  final List<WebSocket> _sockets = [];
  String? requestedPath;
  Map<String, Object?>? clientHello;
  Map<String, Object?>? lastRequest;

  static Future<_IpcCliTestServer> start() async {
    final Directory? directory;
    final String socketPath;
    final String cliHost;
    if (Platform.isWindows) {
      directory = null;
      socketPath =
          r'\\.\pipe\tinyrack-cli-ipc-' +
          '$pid-${DateTime.now().microsecondsSinceEpoch}';
      cliHost = socketPath;
    } else {
      directory = await Directory.systemTemp.createTemp('cli-ipc-server-');
      socketPath = p.join(directory.path, 'daemon.sock');
      cliHost = 'unix://$socketPath';
    }
    final listener = await ipc.bind(socketPath);
    final server = HttpServer.listenOn(listener);
    final result = _IpcCliTestServer._(
      cliHost: cliHost,
      socketPath: socketPath,
      directory: directory,
      listener: listener,
      server: server,
    );
    unawaited(result._serve());
    return result;
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      requestedPath = request.uri.path;
      final socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      unawaited(_handle(socket));
    }
  }

  Future<void> _handle(WebSocket socket) async {
    await for (final raw in socket) {
      if (raw is! String) continue;
      final frame = jsonDecode(raw) as Map<String, Object?>;
      if (frame['type'] == 'hello') {
        clientHello = frame;
        socket.add(
          jsonEncode({
            'status': 'server_info',
            'serverId': 'ipc-server-test',
            'hostname': 'ipc-host',
            'version': '0.2.0',
            'desktopManaged': false,
            'capabilities': <String, Object?>{},
            'features': <String, bool>{},
          }),
        );
        continue;
      }
      final message = frame['message'];
      if (frame['type'] != 'session' || message is! Map) continue;
      final request = message.cast<String, Object?>();
      lastRequest = request;
      socket.add(
        jsonEncode({
          'type': 'session',
          'message': {
            'type': 'provider.list.response',
            'payload': {
              'requestId': request['requestId'],
              'providers': <Object?>[],
            },
          },
        }),
      );
    }
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _server.close(force: true);
    await _listener.close();
    final socketFile = File(socketPath);
    if (!Platform.isWindows && await socketFile.exists()) {
      await socketFile.delete();
    }
    final tempDirectory = directory;
    if (tempDirectory != null && await tempDirectory.exists()) {
      await tempDirectory.delete(recursive: true);
    }
  }
}
