import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/state/workspace_catalog_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient() : super(uri: Uri.parse('ws://127.0.0.1:6868'));

  final requests = <Map<String, Object?>>[];
  final directoryEventsController =
      StreamController<DirectoryUpdateEvent>.broadcast();

  @override
  Stream<DirectoryUpdateEvent> get directoryUpdateEvents =>
      directoryEventsController.stream;

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add(message);
    final cursor = (message['page'] as Map?)?['cursor'];
    return {
      'type': 'fetch_workspaces_response',
      'payload': {
        'requestId': message['requestId'],
        'entries': [_workspace(cursor == null ? 'workspace-1' : 'workspace-2')],
        'emptyProjects': <Object?>[],
        'pageInfo': {
          'nextCursor': cursor == null ? 'next' : null,
          'prevCursor': null,
          'hasMore': cursor == null,
        },
      },
    };
  }
}

class InvalidCursorDaemonClient extends FakeDaemonClient {
  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async => {
    'type': 'fetch_workspaces_response',
    'payload': {
      'requestId': message['requestId'],
      'entries': <Object?>[],
      'emptyProjects': <Object?>[],
      'pageInfo': {'nextCursor': null, 'prevCursor': null, 'hasMore': true},
    },
  };
}

class WorkspaceCatalogHostRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [
      _host('server-a', 'a.example:7001'),
      _host('server-b', 'b.example:7002'),
    ],
    activeServerId: 'server-a',
    loaded: true,
  );
}

Map<String, Object?> _workspace(String id) => {
  'id': id,
  'projectId': 'project-1',
  'projectDisplayName': 'Project',
  'projectRootPath': r'C:\repo',
  'workspaceDirectory': '$id-dir',
  'projectKind': 'git',
  'workspaceKind': 'worktree',
  'name': id,
  'status': 'done',
  'activityAt': null,
  'scripts': <Object?>[],
};

void main() {
  test('exhausts v2 workspace pages for deep-link resolution', () async {
    final client = FakeDaemonClient();
    addTearDown(client.dispose);
    final result = await fetchAllWorkspaces(client);

    expect(result.map((workspace) => workspace.id), [
      'workspace-1',
      'workspace-2',
    ]);
    expect(client.requests, hasLength(2));
    expect((client.requests.first['page'] as Map)['limit'], 200);
    expect((client.requests.last['page'] as Map)['cursor'], 'next');
  });

  test('rejects a truncated page without its required cursor', () async {
    final client = InvalidCursorDaemonClient();
    addTearDown(client.dispose);
    await expectLater(
      fetchAllWorkspaces(client),
      throwsA(isA<FormatException>()),
    );
  });

  test('provider loads only while the active daemon is connected', () async {
    final client = FakeDaemonClient();
    addTearDown(client.dispose);
    final connected = ProviderContainer(
      overrides: [
        daemonClientProvider.overrideWithValue(client),
        connectionStateProvider.overrideWithValue(
          const AsyncData(DaemonConnectionState.connected),
        ),
      ],
    );
    addTearDown(connected.dispose);
    expect((await connected.read(workspaceCatalogProvider.future)).length, 2);
    expect(client.requests.first['subscribe'], isEmpty);

    final disconnected = ProviderContainer(
      overrides: [
        daemonClientProvider.overrideWithValue(client),
        connectionStateProvider.overrideWithValue(
          const AsyncData(DaemonConnectionState.disconnected),
        ),
      ],
    );
    addTearDown(disconnected.dispose);
    expect(await disconnected.read(workspaceCatalogProvider.future), isEmpty);

    disconnected
        .read(workspaceCatalogCacheProvider.notifier)
        .replace(
          'legacy',
          await connected.read(workspaceCatalogProvider.future),
        );
    disconnected.invalidate(workspaceCatalogProvider);
    expect(
      (await disconnected.read(
        workspaceCatalogProvider.future,
      )).map((workspace) => workspace.id),
      ['workspace-1', 'workspace-2'],
    );
  });

  test('applies native workspace and project directory deltas', () {
    final initial = [WorkspaceDescriptor.fromJson(_workspace('workspace-1'))];
    expect(
      applyWorkspaceDirectoryUpdate(
        initial,
        const WorkspaceDirectoryEvent(WorkspaceRemoveUpdate(id: 'workspace-1')),
      ),
      isEmpty,
    );
    expect(
      applyWorkspaceDirectoryUpdate(
        initial,
        const AgentRemoveDirectoryEvent('agent-1'),
      ),
      same(initial),
    );
    final added = applyWorkspaceDirectoryUpdate(
      initial,
      WorkspaceDirectoryEvent(
        WorkspaceUpsertUpdate(
          WorkspaceDescriptor.fromJson({
            ..._workspace('workspace-2'),
            'projectId': 'project-2',
          }),
        ),
      ),
    );
    expect(added.map((workspace) => workspace.id), [
      'workspace-1',
      'workspace-2',
    ]);

    final removedProject = applyWorkspaceDirectoryUpdate(
      added,
      const ProjectDirectoryEvent(ProjectRemoveUpdate('project-1')),
    );
    expect(removedProject.single.id, 'workspace-2');

    final renamed = applyWorkspaceDirectoryUpdate(
      removedProject,
      const ProjectDirectoryEvent(
        ProjectUpsertUpdate(
          WorkspaceProjectDescriptor(
            projectId: 'project-2',
            projectDisplayName: 'Renamed',
            projectRootPath: r'C:\renamed',
            projectKind: WorkspaceProjectKind.git,
          ),
        ),
      ),
    );
    expect(renamed.single.projectDisplayName, 'Renamed');
    expect(renamed.single.projectRootPath, r'C:\renamed');
  });

  test('streams native workspace updates after snapshot hydration', () async {
    final client = FakeDaemonClient();
    addTearDown(client.dispose);
    final container = ProviderContainer(
      overrides: [
        daemonClientProvider.overrideWithValue(client),
        connectionStateProvider.overrideWithValue(
          const AsyncData(DaemonConnectionState.connected),
        ),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(
      workspaceCatalogProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await container.read(workspaceCatalogProvider.future);

    client.directoryEventsController.add(
      WorkspaceDirectoryEvent(
        WorkspaceUpsertUpdate(
          WorkspaceDescriptor.fromJson(_workspace('workspace-live')),
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      container
          .read(workspaceCatalogProvider)
          .requireValue
          .map((workspace) => workspace.id),
      contains('workspace-live'),
    );
  });

  test(
    'host selection restores and removes scoped workspace catalogs',
    () async {
      final container = ProviderContainer(
        overrides: [
          hostRegistryProvider.overrideWith(WorkspaceCatalogHostRegistry.new),
          connectionStateProvider.overrideWithValue(
            const AsyncData(DaemonConnectionState.disconnected),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(workspaceCatalogReplicaLifecycleProvider);
      container.read(workspaceCatalogCacheProvider.notifier)
        ..replace('server-a', [
          WorkspaceDescriptor.fromJson(_workspace('workspace-a')),
        ])
        ..replace('server-b', [
          WorkspaceDescriptor.fromJson(_workspace('workspace-b')),
        ]);

      expect(
        (await container.read(
          workspaceCatalogProvider.future,
        )).map((workspace) => workspace.id),
        ['workspace-a'],
      );
      await container
          .read(hostRegistryProvider.notifier)
          .selectHost('server-b');
      expect(
        (await container.read(
          workspaceCatalogProvider.future,
        )).map((workspace) => workspace.id),
        ['workspace-b'],
      );

      await container
          .read(hostRegistryProvider.notifier)
          .removeHost('server-a');
      expect(container.read(workspaceCatalogCacheProvider).keys, {'server-b'});
    },
  );
}

HostProfile _host(String serverId, String endpoint) => HostProfile(
  serverId: serverId,
  label: serverId,
  connections: [
    DirectTcpHostConnection(id: 'direct:$endpoint', endpoint: endpoint),
  ],
  preferredConnectionId: 'direct:$endpoint',
  createdAt: '2026-07-28T00:00:00.000Z',
  updatedAt: '2026-07-28T00:00:00.000Z',
);
