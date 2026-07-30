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
    'workspace directory subscriptions filter updates and replace their epoch',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'daemon-workspace-directory-subscription-',
      );
      addTearDown(() => _deleteDirectoryEventually(temp));
      final projectA = await Directory(
        '${temp.path}${Platform.pathSeparator}project-a',
      ).create();
      final projectB = await Directory(
        '${temp.path}${Platform.pathSeparator}project-b',
      ).create();

      final handle = await startDaemonServer(
        paths: DaemonPaths(dataDir: temp.path),
        host: '127.0.0.1',
        port: 0,
        dataDir: temp.path,
        log: (_) {},
      );
      addTearDown(handle.stop);

      final subscriber = await _SessionClient.connect(
        handle.server.port,
        'directory-subscriber',
      );
      final mutator = await _SessionClient.connect(
        handle.server.port,
        'directory-mutator',
      );
      addTearDown(subscriber.close);
      addTearDown(mutator.close);

      final addedA = ProjectAddResponse.fromJson(
        await mutator.request(
          ProjectAddRequest(cwd: projectA.path, requestId: 'add-a').toJson(),
          ProjectAddResponse.type,
        ),
      );
      final addedB = ProjectAddResponse.fromJson(
        await mutator.request(
          ProjectAddRequest(cwd: projectB.path, requestId: 'add-b').toJson(),
          ProjectAddResponse.type,
        ),
      );
      expect(addedA.error, isNull);
      expect(addedB.error, isNull);

      final firstSnapshotIndex = subscriber.messages.length;
      final firstSnapshot = FetchWorkspacesResponse.fromJson(
        await subscriber.request(
          FetchWorkspacesRequest(
            requestId: 'subscribe-b',
            projectId: addedB.project!.projectId,
            hasSubscription: true,
          ).toJson(),
          'fetch_workspaces_response',
        ),
      );
      expect(firstSnapshot.subscriptionId, isNotEmpty);
      expect(firstSnapshot.entries, isEmpty);

      final createdA = await _createWorkspace(
        mutator,
        requestId: 'create-a-1',
        path: projectA.path,
        projectId: addedA.project!.projectId,
      );
      final createdB = await _createWorkspace(
        mutator,
        requestId: 'create-b-1',
        path: projectB.path,
        projectId: addedB.project!.projectId,
      );
      await subscriber.waitForWorkspaceUpdate(createdB.id);

      final firstEpochUpdates = subscriber.workspaceUpsertsSince(
        firstSnapshotIndex,
      );
      expect(firstEpochUpdates.map((workspace) => workspace.id), [createdB.id]);
      expect(
        firstEpochUpdates.map((workspace) => workspace.projectId),
        everyElement(addedB.project!.projectId),
      );
      expect(
        firstEpochUpdates.map((workspace) => workspace.id),
        isNot(contains(createdA.id)),
      );

      final secondSnapshotIndex = subscriber.messages.length;
      final secondSnapshot = FetchWorkspacesResponse.fromJson(
        await subscriber.request(
          FetchWorkspacesRequest(
            requestId: 'subscribe-a',
            projectId: addedA.project!.projectId,
            hasSubscription: true,
            subscriptionId: 'workspace-epoch-a',
          ).toJson(),
          'fetch_workspaces_response',
        ),
      );
      expect(secondSnapshot.subscriptionId, 'workspace-epoch-a');
      expect(secondSnapshot.entries.map((workspace) => workspace.id), [
        createdA.id,
      ]);

      final createdB2 = await _createWorkspace(
        mutator,
        requestId: 'create-b-2',
        path: projectB.path,
        projectId: addedB.project!.projectId,
      );
      final createdA2 = await _createWorkspace(
        mutator,
        requestId: 'create-a-2',
        path: projectA.path,
        projectId: addedA.project!.projectId,
      );
      await subscriber.waitForWorkspaceUpdate(createdA2.id);

      final secondEpochUpdates = subscriber.workspaceUpsertsSince(
        secondSnapshotIndex,
      );
      expect(secondEpochUpdates.map((workspace) => workspace.id), [
        createdA2.id,
      ]);
      expect(
        secondEpochUpdates.map((workspace) => workspace.id),
        isNot(contains(createdB2.id)),
      );

      final secondSnapshotFrameIndex = subscriber.messages.indexWhere(
        (message) =>
            message['type'] == 'fetch_workspaces_response' &&
            (message['payload'] as Map?)?['requestId'] == 'subscribe-a',
      );
      final firstSecondEpochUpdateIndex = subscriber.messages.indexWhere(
        (message) =>
            message['type'] == 'workspace_update' &&
            ((message['payload'] as Map?)?['workspace'] as Map?)?['id'] ==
                createdA2.id,
      );
      expect(secondSnapshotFrameIndex, greaterThanOrEqualTo(0));
      expect(
        firstSecondEpochUpdateIndex,
        greaterThan(secondSnapshotFrameIndex),
      );
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Future<WorkspaceDescriptor> _createWorkspace(
  _SessionClient client, {
  required String requestId,
  required String path,
  required String projectId,
}) async {
  final response = WorkspaceCreateResponse.fromJson(
    await client.request(
      WorkspaceCreateRequest(
        requestId: requestId,
        source: DirectoryWorkspaceCreateSource(
          path: path,
          projectId: projectId,
        ),
      ).toJson(),
      'workspace.create.response',
    ),
  );
  expect(response.error, isNull);
  return response.workspace!;
}

final class _SessionClient {
  _SessionClient._(this._channel, this._subscription);

  final WebSocketChannel _channel;
  final StreamSubscription<Object?> _subscription;
  final List<Map<String, Object?>> messages = [];

  static Future<_SessionClient> connect(int port, String clientId) async {
    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:$port/ws'),
    );
    await channel.ready;
    late final _SessionClient client;
    final ready = Completer<void>();
    final subscription = channel.stream.listen((frame) {
      if (frame is! String) return;
      final outer = jsonDecode(frame) as Map<String, Object?>;
      if (outer['status'] == 'server_info') {
        if (!ready.isCompleted) ready.complete();
        return;
      }
      if (outer['type'] != 'session' || outer['message'] is! Map) return;
      client.messages.add((outer['message'] as Map).cast<String, Object?>());
    });
    client = _SessionClient._(channel, subscription);
    channel.sink.add(
      jsonEncode(
        WebSocketHello(
          clientId: clientId,
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await ready.future.timeout(const Duration(seconds: 3));
    return client;
  }

  Future<Map<String, Object?>> request(
    Map<String, Object?> request,
    String responseType,
  ) async {
    final start = messages.length;
    _channel.sink.add(jsonEncode({'type': 'session', 'message': request}));
    return _waitForMessage(
      start,
      (message) =>
          message['type'] == responseType &&
          ((message['payload'] as Map?)?['requestId'] ??
                  message['requestId']) ==
              request['requestId'],
    );
  }

  Future<void> waitForWorkspaceUpdate(String workspaceId) async {
    await _waitForMessage(
      0,
      (message) =>
          message['type'] == 'workspace_update' &&
          ((message['payload'] as Map?)?['workspace'] as Map?)?['id'] ==
              workspaceId,
    );
  }

  List<WorkspaceDescriptor> workspaceUpsertsSince(int index) => [
    for (final message in messages.skip(index))
      if (message['type'] == 'workspace_update' &&
          (message['payload'] as Map?)?['kind'] == 'upsert')
        WorkspaceDescriptor.fromJson(
          (((message['payload'] as Map)['workspace']) as Map)
              .cast<String, Object?>(),
        ),
  ];

  Future<Map<String, Object?>> _waitForMessage(
    int start,
    bool Function(Map<String, Object?> message) predicate,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (true) {
      for (final message in messages.skip(start)) {
        if (predicate(message)) return message;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Timed out waiting for a WebSocket message');
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
