import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/state/schedule_project_targets_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'builds one target per online project host including empty projects',
    () {
      final targets = buildScheduleProjectTargets([
        ScheduleProjectHostReplica(
          serverId: 'host-a',
          serverName: 'Alpha host',
          isOnline: true,
          workspaces: [
            WorkspaceDescriptor.fromJson(
              _workspace(
                id: 'workspace-a',
                projectId: 'project-a',
                displayName: 'Alpha',
                customName: 'Renamed Alpha',
                root: '/checkout/worktree',
                mainRoot: '/repos/alpha',
              ),
            ),
          ],
          emptyProjects: const [
            WorkspaceProjectDescriptor(
              projectId: 'project-empty',
              projectDisplayName: 'Empty',
              projectRootPath: '/repos/empty',
              projectKind: WorkspaceProjectKind.directory,
            ),
          ],
        ),
        ScheduleProjectHostReplica(
          serverId: 'host-b',
          serverName: 'Offline',
          isOnline: false,
          workspaces: [
            WorkspaceDescriptor.fromJson(
              _workspace(
                id: 'workspace-b',
                projectId: 'project-b',
                displayName: 'Beta',
                root: '/repos/beta',
              ),
            ),
          ],
        ),
      ]);

      expect(targets.map((target) => target.projectName), [
        'Empty',
        'Renamed Alpha',
      ]);
      final alpha = targets.last;
      expect(alpha.cwd, '/repos/alpha');
      expect(alpha.isGit, isTrue);
      expect(alpha.optionId, 'project:host-a:project-a');
      expect(targets.first.isGit, isFalse);
    },
  );

  test(
    'project names resolve stored cwd and unmatched paths are shortened',
    () {
      const target = ScheduleProjectTarget(
        optionId: 'project:host-a:project-a',
        serverId: 'host-a',
        serverName: 'Alpha host',
        projectKey: 'project-a',
        projectName: 'Alpha',
        cwd: '/repos/alpha',
        isGit: true,
      );
      final names = buildScheduleProjectNameByCwd(const [target]);
      expect(
        describeScheduleCwd(
          serverId: 'host-a',
          cwd: '/repos/alpha',
          projectNameByCwd: names,
        ),
        'Alpha',
      );
      expect(
        describeScheduleCwd(
          serverId: 'host-a',
          cwd: '/Users/sam/api',
          projectNameByCwd: names,
        ),
        '~/api',
      );
    },
  );

  test('host catalogs load concurrently and retain partial errors', () async {
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final release = Completer<void>();
    final first = _ProjectClient(
      'first',
      started: firstStarted,
      release: release,
    );
    final second = _ProjectClient(
      'second',
      started: secondStarted,
      release: release,
    );

    final pending = fetchScheduleProjectTargets([
      ScheduleProjectFetchHost(
        serverId: 'host-a',
        serverName: 'Alpha',
        client: first,
      ),
      ScheduleProjectFetchHost(
        serverId: 'host-b',
        serverName: 'Beta',
        client: second,
      ),
    ]);
    await Future.wait([firstStarted.future, secondStarted.future]);
    release.complete();
    final loaded = await pending;
    expect(loaded.targets, hasLength(4));
    expect(loaded.hostErrors, isEmpty);

    second.error = StateError('offline');
    final partial = await fetchScheduleProjectTargets([
      ScheduleProjectFetchHost(
        serverId: 'host-a',
        serverName: 'Alpha',
        client: first,
      ),
      ScheduleProjectFetchHost(
        serverId: 'host-b',
        serverName: 'Beta',
        client: second,
      ),
    ]);
    expect(partial.targets, hasLength(2));
    expect(partial.hostErrors.single.serverId, 'host-b');
    expect(partial.hostErrors.single.message, contains('offline'));
  });

  test('provider reacts to the connected host registry', () async {
    final release = Completer<void>()..complete();
    final first = _ProjectClient(
      'first',
      started: Completer<void>(),
      release: release,
    );
    final second = _ProjectClient(
      'second',
      started: Completer<void>(),
      release: release,
    );
    final container = ProviderContainer(
      overrides: [
        hostRegistryProvider.overrideWith(_ProjectRegistry.new),
        hostRuntimeClientsProvider.overrideWithValue({
          'host-a': first,
          'host-b': second,
        }),
        hostConnectionStateProvider.overrideWith(
          (ref, serverId) => Stream.value(DaemonConnectionState.connected),
        ),
      ],
    );
    addTearDown(container.dispose);

    final state = await container.read(scheduleProjectTargetsProvider.future);
    expect(state.targets, hasLength(4));
    expect(state.connecting, isFalse);
    expect(first.started.isCompleted, isTrue);
    expect(second.started.isCompleted, isTrue);
  });
}

final class _ProjectClient extends DaemonClient {
  _ProjectClient(this.name, {required this.started, required this.release})
    : super(uri: Uri.parse('ws://project-test'));

  final String name;
  final Completer<void> started;
  final Completer<void> release;
  Object? error;

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!started.isCompleted) started.complete();
    if (!release.isCompleted) await release.future;
    if (error case final failure?) throw failure;
    return {
      'type': 'fetch_workspaces_response',
      'payload': {
        'requestId': message['requestId'],
        'entries': [
          _workspace(
            id: '$name-workspace',
            projectId: '$name-project',
            displayName: '$name project',
            root: '/repos/$name',
          ),
        ],
        'emptyProjects': [
          {
            'projectId': '$name-empty',
            'projectDisplayName': '$name empty',
            'projectRootPath': '/repos/$name-empty',
            'projectKind': 'directory',
          },
        ],
        'pageInfo': {'nextCursor': null, 'prevCursor': null, 'hasMore': false},
      },
    };
  }
}

final class _ProjectRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [_host('host-a', 'Alpha'), _host('host-b', 'Beta')],
    activeServerId: 'host-a',
    loaded: true,
  );
}

HostProfile _host(String serverId, String label) => HostProfile(
  serverId: serverId,
  label: label,
  connections: [
    DirectTcpHostConnection(
      id: 'direct:$serverId:6868',
      endpoint: '$serverId:6868',
    ),
  ],
  preferredConnectionId: 'direct:$serverId:6868',
  createdAt: '2026-07-27T00:00:00.000Z',
  updatedAt: '2026-07-27T00:00:00.000Z',
);

Map<String, Object?> _workspace({
  required String id,
  required String projectId,
  required String displayName,
  String? customName,
  required String root,
  String? mainRoot,
}) => {
  'id': id,
  'projectId': projectId,
  'projectDisplayName': displayName,
  'projectCustomName': ?customName,
  'projectRootPath': root,
  'workspaceDirectory': '$root/$id',
  'projectKind': 'git',
  'workspaceKind': 'worktree',
  'name': id,
  'status': 'done',
  'activityAt': null,
  'scripts': <Object?>[],
  'project': ?_projectPayload(mainRoot),
};

Map<String, Object?>? _projectPayload(String? mainRoot) => mainRoot == null
    ? null
    : {
        'checkout': {'mainRepoRoot': mainRoot},
      };
