import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/projects/projects.dart';
import 'package:coding_agent_app/state/project_summaries_provider.dart';
import 'package:flutter_test/flutter_test.dart';

WorkspaceDescriptor _workspace({
  required String id,
  required String projectId,
  String projectName = 'Project',
}) => WorkspaceDescriptor(
  id: id,
  projectId: projectId,
  projectDisplayName: projectName,
  projectRootPath: '/repo/$projectId',
  workspaceDirectory: '/repo/$projectId/$id',
  projectKind: WorkspaceProjectKind.git,
  workspaceKind: WorkspaceKind.worktree,
  name: id,
  status: WorkspaceStateBucket.done,
  activityAt: null,
);

WorkspaceProjectDescriptor _project(String id, {String? name}) =>
    WorkspaceProjectDescriptor(
      projectId: id,
      projectDisplayName: name ?? id,
      projectRootPath: '/repo/$id',
      projectKind: WorkspaceProjectKind.git,
    );

void main() {
  test('derives projects, runtime flags, and host errors from replicas', () {
    final result = deriveProjectsFromReplica(
      replicas: [
        ProjectHostReplica(
          serverId: 'local',
          serverName: 'Local',
          workspaces: [
            _workspace(id: 'main', projectId: 'app', projectName: 'App'),
          ],
          emptyProjects: const [],
        ),
        ProjectHostReplica(
          serverId: 'laptop',
          serverName: 'Laptop',
          workspaces: [
            _workspace(id: 'feature', projectId: 'app', projectName: 'App'),
          ],
          emptyProjects: const [],
        ),
      ],
      runtimeStates: const [
        ProjectHostRuntimeState(
          serverId: 'local',
          isOnline: true,
          isLoading: false,
          isFetching: true,
          error: null,
        ),
        ProjectHostRuntimeState(
          serverId: 'laptop',
          isOnline: false,
          isLoading: true,
          isFetching: false,
          error: 'host directory failed',
        ),
      ],
    );

    final project = result.projects.single;
    expect(project.hostCount, 2);
    expect(project.onlineHostCount, 1);
    expect(result.isLoading, isTrue);
    expect(result.isFetching, isTrue);
    expect(result.hostErrors, hasLength(1));
    expect(result.hostErrors.single.serverId, 'laptop');
    expect(result.hostErrors.single.message, 'host directory failed');
  });

  test('runtime state defaults a replica to offline without an error', () {
    final result = deriveProjectsFromReplica(
      replicas: [
        ProjectHostReplica(
          serverId: 'missing',
          serverName: 'Missing',
          workspaces: const [],
          emptyProjects: [_project('empty')],
        ),
      ],
      runtimeStates: const [],
    );

    expect(result.projects.single.onlineHostCount, 0);
    expect(result.hostErrors, isEmpty);
    expect(result.isLoading, isFalse);
    expect(result.isFetching, isFalse);
  });

  test('workspace upsert replaces rows and removes empty project marker', () {
    final replica = ProjectHostReplica(
      serverId: 'local',
      serverName: 'Local',
      workspaces: [_workspace(id: 'old', projectId: 'app')],
      emptyProjects: [_project('app'), _project('other')],
    );

    final next = applyProjectReplicaDirectoryUpdate(
      replica,
      WorkspaceDirectoryEvent(
        WorkspaceUpsertUpdate(_workspace(id: 'new', projectId: 'app')),
      ),
    );

    expect(next.workspaces.map((entry) => entry.id), ['old', 'new']);
    expect(next.emptyProjects.map((entry) => entry.projectId), ['other']);
  });

  test('workspace removal can surface an empty or remove a whole project', () {
    final replica = ProjectHostReplica(
      serverId: 'local',
      serverName: 'Local',
      workspaces: [
        _workspace(id: 'app-1', projectId: 'app'),
        _workspace(id: 'app-2', projectId: 'app'),
        _workspace(id: 'other', projectId: 'other'),
      ],
      emptyProjects: const [],
    );
    final empty = applyProjectReplicaDirectoryUpdate(
      replica,
      WorkspaceDirectoryEvent(
        WorkspaceRemoveUpdate(id: 'app-1', emptyProject: _project('app')),
      ),
    );
    expect(empty.workspaces.map((entry) => entry.id), ['app-2', 'other']);
    expect(empty.emptyProjects.single.projectId, 'app');

    final removed = applyProjectReplicaDirectoryUpdate(
      empty,
      const WorkspaceDirectoryEvent(
        WorkspaceRemoveUpdate(id: 'app-2', removedProjectId: 'app'),
      ),
    );
    expect(removed.workspaces.map((entry) => entry.id), ['other']);
    expect(removed.emptyProjects, isEmpty);
  });

  test('project upsert refreshes workspace metadata and empty replica', () {
    final replica = ProjectHostReplica(
      serverId: 'local',
      serverName: 'Local',
      workspaces: [_workspace(id: 'main', projectId: 'app')],
      emptyProjects: const [],
    );
    final project = WorkspaceProjectDescriptor(
      projectId: 'app',
      projectDisplayName: 'Application',
      projectCustomName: 'Custom App',
      projectRootPath: '/new/app',
      projectKind: WorkspaceProjectKind.directory,
    );

    final next = applyProjectReplicaDirectoryUpdate(
      replica,
      ProjectDirectoryEvent(ProjectUpsertUpdate(project)),
    );

    expect(next.emptyProjects, isEmpty);
    expect(next.workspaces.single.projectDisplayName, 'Application');
    expect(next.workspaces.single.projectCustomName, 'Custom App');
    expect(next.workspaces.single.projectRootPath, '/new/app');
    expect(next.workspaces.single.projectKind, WorkspaceProjectKind.directory);

    final empty = applyProjectReplicaDirectoryUpdate(
      const ProjectHostReplica(
        serverId: 'local',
        serverName: 'Local',
        workspaces: [],
        emptyProjects: [],
      ),
      ProjectDirectoryEvent(ProjectUpsertUpdate(project)),
    );
    expect(empty.emptyProjects.single.projectCustomName, 'Custom App');
  });

  test(
    'empty project upsert refreshes its derived name without adding a workspace',
    () {
      final replica = ProjectHostReplica(
        serverId: 'local',
        serverName: 'Local',
        workspaces: const [],
        emptyProjects: [_project('app', name: 'app')],
      );
      final updated = applyProjectReplicaDirectoryUpdate(
        replica,
        const ProjectDirectoryEvent(
          ProjectUpsertUpdate(
            WorkspaceProjectDescriptor(
              projectId: 'app',
              projectDisplayName: 'Renamed empty project',
              projectCustomName: 'Renamed empty project',
              projectRootPath: '/repo/app',
              projectKind: WorkspaceProjectKind.git,
            ),
          ),
        ),
      );

      final result = deriveProjectsFromReplica(
        replicas: [updated],
        runtimeStates: const [
          ProjectHostRuntimeState(
            serverId: 'local',
            isOnline: true,
            isLoading: false,
            isFetching: false,
            error: null,
          ),
        ],
      );

      final project = result.projects.single;
      expect(project.projectName, 'Renamed empty project');
      expect(project.totalWorkspaceCount, 0);
      expect(project.hosts.single.workspaceCount, 0);
      expect(project.hosts.single.repoRoot, '/repo/app');
    },
  );

  test('project removal and agent events preserve exact replica semantics', () {
    final replica = ProjectHostReplica(
      serverId: 'local',
      serverName: 'Local',
      workspaces: [
        _workspace(id: 'app', projectId: 'app'),
        _workspace(id: 'other', projectId: 'other'),
      ],
      emptyProjects: [_project('app')],
    );
    final removed = applyProjectReplicaDirectoryUpdate(
      replica,
      const ProjectDirectoryEvent(ProjectRemoveUpdate('app')),
    );
    expect(removed.workspaces.single.projectId, 'other');
    expect(removed.emptyProjects, isEmpty);

    final ignored = applyProjectReplicaDirectoryUpdate(
      removed,
      const AgentRemoveDirectoryEvent('agent-1'),
    );
    expect(identical(ignored, removed), isTrue);
  });

  test('buffered directory deltas are applied after the fetched snapshot', () {
    final snapshot = ProjectHostReplica(
      serverId: 'local',
      serverName: 'Local',
      workspaces: [_workspace(id: 'stale', projectId: 'app')],
      emptyProjects: const [],
    );
    final reconciled = applyProjectReplicaDirectoryUpdates(snapshot, [
      const WorkspaceDirectoryEvent(WorkspaceRemoveUpdate(id: 'stale')),
      WorkspaceDirectoryEvent(
        WorkspaceUpsertUpdate(_workspace(id: 'fresh', projectId: 'app')),
      ),
    ]);

    expect(reconciled.workspaces.single.id, 'fresh');
  });

  test('copyWith preserves settled project data while fetching changes', () {
    const result = DerivedProjectsResult(
      projects: <ProjectSummary>[],
      hostErrors: <ProjectHostError>[],
      isLoading: false,
      isFetching: true,
    );

    final settled = result.copyWith(isFetching: false);
    expect(identical(settled.projects, result.projects), isTrue);
    expect(settled.isFetching, isFalse);
  });
}
