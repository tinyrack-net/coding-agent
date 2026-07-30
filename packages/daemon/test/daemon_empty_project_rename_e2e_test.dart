import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test(
    'empty project rename responds before its directory update and persists',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'daemon-empty-project-rename-',
      );
      addTearDown(() => _deleteDirectoryEventually(temp));
      final projectDirectory = await Directory(
        '${temp.path}${Platform.pathSeparator}fresh-project',
      ).create();
      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        dataDir: temp.path,
        host: '127.0.0.1',
        port: 0,
        log: (_) {},
      );
      addTearDown(handle.stop);

      final client = await _SessionClient.connect(handle.server.port);
      addTearDown(client.close);
      final added = ProjectAddResponse.fromJson(
        await client.request(
          ProjectAddRequest(
            cwd: projectDirectory.path,
            requestId: 'add-empty-project',
          ).toJson(),
          ProjectAddResponse.type,
        ),
      );
      expect(added.error, isNull);
      final project = added.project!;

      final subscribed = FetchWorkspacesResponse.fromJson(
        await client.request(
          const FetchWorkspacesRequest(
            requestId: 'subscribe-empty-projects',
            hasSubscription: true,
            subscriptionId: 'empty-projects',
          ).toJson(),
          'fetch_workspaces_response',
        ),
      );
      expect(subscribed.entries, isEmpty);
      expect(subscribed.emptyProjects.single.projectId, project.projectId);

      final renameStart = client.messages.length;
      final renamed = ProjectRenameResponse.fromJson(
        await client.request(
          ProjectRenameRequest(
            projectId: project.projectId,
            customName: '  Renamed before workspace  ',
            requestId: 'rename-empty',
          ).toJson(),
          'project.rename.response',
        ),
      );
      expect(renamed.accepted, isTrue);
      expect(renamed.customName, 'Renamed before workspace');
      await client.waitForProjectUpdate(
        project.projectId,
        customName: 'Renamed before workspace',
      );
      await client.barrier('rename-barrier');
      _expectRenameOrdering(
        client.messages.sublist(renameStart),
        requestId: 'rename-empty',
        projectId: project.projectId,
      );

      final persisted = await client.fetchEmptyProject(
        project.projectId,
        'fetch-renamed',
      );
      expect(persisted.projectDisplayName, 'Renamed before workspace');
      expect(persisted.projectCustomName, 'Renamed before workspace');

      final resetStart = client.messages.length;
      final reset = ProjectRenameResponse.fromJson(
        await client.request(
          ProjectRenameRequest(
            projectId: project.projectId,
            customName: '   ',
            requestId: 'reset-empty',
          ).toJson(),
          'project.rename.response',
        ),
      );
      expect(reset.accepted, isTrue);
      expect(reset.customName, isNull);
      await client.waitForProjectUpdate(project.projectId, customName: null);
      await client.barrier('reset-barrier');
      _expectRenameOrdering(
        client.messages.sublist(resetStart),
        requestId: 'reset-empty',
        projectId: project.projectId,
      );

      final resetPersisted = await client.fetchEmptyProject(
        project.projectId,
        'fetch-reset',
      );
      expect(resetPersisted.projectDisplayName, project.projectDisplayName);
      expect(resetPersisted.projectCustomName, isNull);

      final missingStart = client.messages.length;
      final missing = ProjectRenameResponse.fromJson(
        await client.request(
          const ProjectRenameRequest(
            projectId: 'prj_missing',
            customName: 'Missing',
            requestId: 'rename-missing',
          ).toJson(),
          'project.rename.response',
        ),
      );
      expect(missing.accepted, isFalse);
      expect(missing.customName, isNull);
      expect(missing.error, isNotEmpty);
      await client.barrier('missing-barrier');
      final missingMessages = client.messages.sublist(missingStart);
      expect(
        missingMessages.where(
          (message) =>
              message['type'] == 'project.update' ||
              message['type'] == 'workspace_update',
        ),
        isEmpty,
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

void _expectRenameOrdering(
  List<Map<String, Object?>> messages, {
  required String requestId,
  required String projectId,
}) {
  final responseIndex = messages.indexWhere(
    (message) =>
        message['type'] == 'project.rename.response' &&
        (message['payload'] as Map?)?['requestId'] == requestId,
  );
  final updateIndex = messages.indexWhere(
    (message) =>
        message['type'] == 'project.update' &&
        (message['payload'] as Map?)?['kind'] == 'upsert' &&
        (((message['payload'] as Map?)?['project'] as Map?)?['projectId']) ==
            projectId,
  );
  expect(responseIndex, greaterThanOrEqualTo(0));
  expect(updateIndex, greaterThan(responseIndex));
  expect(
    messages.where((message) => message['type'] == 'workspace_update'),
    isEmpty,
  );
}

final class _SessionClient {
  _SessionClient._(this._channel, this._subscription);

  final WebSocketChannel _channel;
  final StreamSubscription<Object?> _subscription;
  final List<Map<String, Object?>> messages = [];

  static Future<_SessionClient> connect(int port) async {
    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port/ws'),
    );
    await channel.ready;
    late final _SessionClient client;
    final hello = Completer<void>();
    final subscription = channel.stream.listen((frame) {
      if (frame is! String) return;
      final outer = jsonDecode(frame) as Map<String, Object?>;
      if (outer['status'] == 'server_info') {
        if (!hello.isCompleted) hello.complete();
        return;
      }
      if (outer['type'] != 'session' || outer['message'] is! Map) return;
      client.messages.add((outer['message'] as Map).cast<String, Object?>());
    });
    client = _SessionClient._(channel, subscription);
    channel.sink.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'empty-project-rename-e2e',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await hello.future.timeout(const Duration(seconds: 3));
    return client;
  }

  Future<Map<String, Object?>> request(
    Map<String, Object?> request,
    String responseType,
  ) async {
    final start = messages.length;
    _channel.sink.add(jsonEncode({'type': 'session', 'message': request}));
    return _waitFor(
      start,
      (message) =>
          message['type'] == responseType &&
          ((message['payload'] as Map?)?['requestId'] ??
                  message['requestId']) ==
              request['requestId'],
    );
  }

  Future<void> waitForProjectUpdate(
    String projectId, {
    required String? customName,
  }) async {
    await _waitFor(
      0,
      (message) =>
          message['type'] == 'project.update' &&
          (message['payload'] as Map?)?['kind'] == 'upsert' &&
          (((message['payload'] as Map?)?['project'] as Map?)?['projectId']) ==
              projectId &&
          (((message['payload'] as Map?)?['project']
                  as Map?)?['projectCustomName']) ==
              customName,
    );
  }

  Future<WorkspaceProjectDescriptor> fetchEmptyProject(
    String projectId,
    String requestId,
  ) async {
    final response = FetchWorkspacesResponse.fromJson(
      await request(
        FetchWorkspacesRequest(
          requestId: requestId,
          projectId: projectId,
        ).toJson(),
        'fetch_workspaces_response',
      ),
    );
    expect(response.entries, isEmpty);
    return response.emptyProjects.single;
  }

  Future<void> barrier(String requestId) async {
    await request(
      FetchWorkspacesRequest(requestId: requestId).toJson(),
      'fetch_workspaces_response',
    );
  }

  Future<Map<String, Object?>> _waitFor(
    int start,
    bool Function(Map<String, Object?> message) predicate,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (true) {
      for (final message in messages.skip(start)) {
        if (predicate(message)) return message;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Timed out waiting for a session message');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> close() async {
    await _channel.sink.close();
    await _subscription.cancel();
  }
}

Future<void> _deleteDirectoryEventually(Directory directory) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (!directory.existsSync()) return;
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 39) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
