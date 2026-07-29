import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> placement({
  required String projectKey,
  required String projectName,
  required String cwd,
  required String? remoteUrl,
  String? mainRepoRoot,
}) => {
  'projectKey': projectKey,
  'projectName': projectName,
  'checkout': {
    'cwd': cwd,
    'isGit': true,
    'currentBranch': 'main',
    'remoteUrl': remoteUrl,
    'worktreeRoot': cwd,
    'isPaseoOwnedWorktree': false,
    'mainRepoRoot': mainRepoRoot,
  },
};

WorkspaceDescriptor workspace({
  required String id,
  required String repoRoot,
  Map<String, Object?>? project,
  String? projectId,
  String? projectName,
  String? projectCustomName,
  String? remoteUrl,
  String currentBranch = 'main',
  String? archivingAt,
}) => WorkspaceDescriptor(
  id: id,
  projectId: projectId ?? project?['projectKey'] as String? ?? repoRoot,
  projectDisplayName:
      projectName ?? project?['projectName'] as String? ?? 'Project',
  projectCustomName: projectCustomName,
  projectRootPath: repoRoot,
  workspaceDirectory: repoRoot,
  projectKind: WorkspaceProjectKind.git,
  workspaceKind: WorkspaceKind.localCheckout,
  name: id,
  status: WorkspaceStateBucket.done,
  activityAt: null,
  archivingAt: archivingAt,
  gitRuntime: WorkspaceGitRuntime(
    currentBranch: currentBranch,
    remoteUrl:
        remoteUrl ?? ((project?['checkout'] as Map?)?['remoteUrl'] as String?),
    isPaseoOwnedWorktree: false,
    isDirty: false,
  ),
  project: project,
);

ProjectHost host({
  required String id,
  required String name,
  bool online = true,
  List<WorkspaceDescriptor> workspaces = const [],
  List<WorkspaceProjectDescriptor> emptyProjects = const [],
}) => ProjectHost(
  serverId: id,
  serverName: name,
  isOnline: online,
  workspaces: workspaces,
  emptyProjects: emptyProjects,
);

void main() {
  test('normalizes detached and blank branches and carries archive state', () {
    final result = buildProjects(
      hosts: [
        host(
          id: 'local',
          name: 'Local',
          workspaces: [
            workspace(
              id: 'detached',
              repoRoot: '/repo/app',
              currentBranch: 'HEAD',
              archivingAt: '2026-07-15T18:00:00.000Z',
            ),
            workspace(id: 'blank', repoRoot: '/repo/app', currentBranch: '  '),
          ],
        ),
      ],
    );

    final workspaces = result.projects.single.hosts.single.workspaces;
    expect(workspaces[0].currentBranch, isNull);
    expect(workspaces[0].archivingAt, '2026-07-15T18:00:00.000Z');
    expect(workspaces[1].currentBranch, isNull);
    expect(workspaces[1].archivingAt, isNull);
  });

  test('groups one remote project across hosts and totals workspaces', () {
    Map<String, Object?> project(String cwd) => placement(
      projectKey: 'remote:github.com/acme/app',
      projectName: 'acme/app',
      cwd: cwd,
      remoteUrl: 'https://github.com/acme/app.git',
    );
    final result = buildProjects(
      hosts: [
        host(
          id: 'local',
          name: 'Local',
          workspaces: [
            workspace(
              id: 'main',
              repoRoot: '/repo/app',
              project: project('/repo/app'),
            ),
            workspace(
              id: 'feature-a',
              repoRoot: '/repo/app',
              project: project('/repo/app/a'),
            ),
            workspace(
              id: 'feature-b',
              repoRoot: '/repo/app',
              project: project('/repo/app/b'),
            ),
          ],
        ),
        host(
          id: 'laptop',
          name: 'Laptop',
          workspaces: [
            workspace(
              id: 'main',
              repoRoot: '/work/app',
              project: project('/work/app'),
            ),
            workspace(
              id: 'feature',
              repoRoot: '/work/app',
              project: project('/work/app/f'),
            ),
          ],
        ),
      ],
    );

    final summary = result.projects.single;
    expect(summary.projectKey, 'remote:github.com/acme/app');
    expect(summary.projectName, 'acme/app');
    expect(summary.hostCount, 2);
    expect(summary.onlineHostCount, 2);
    expect(summary.totalWorkspaceCount, 5);
    expect(summary.githubUrl, 'https://github.com/acme/app');
    expect(
      summary.hosts
          .firstWhere((entry) => entry.serverId == 'local')
          .workspaceCount,
      3,
    );
    expect(
      summary.hosts
          .firstWhere((entry) => entry.serverId == 'laptop')
          .workspaceCount,
      2,
    );
  });

  test('collapses five workspaces on one host', () {
    final project = placement(
      projectKey: 'remote:github.com/acme/app',
      projectName: 'acme/app',
      cwd: '/repo/app',
      remoteUrl: 'https://github.com/acme/app.git',
    );
    final result = buildProjects(
      hosts: [
        host(
          id: 'local',
          name: 'Local',
          workspaces: [
            for (var index = 0; index < 5; index++)
              workspace(
                id: 'ws-$index',
                repoRoot: '/repo/app',
                project: project,
              ),
          ],
        ),
      ],
    );

    expect(result.projects.single.hosts.single.workspaceCount, 5);
    expect(result.projects.single.totalWorkspaceCount, 5);
  });

  test('prefers placement mainRepoRoot and retains legacy fallback', () {
    final result = buildProjects(
      hosts: [
        host(
          id: 'local',
          name: 'Local',
          workspaces: [
            workspace(
              id: 'main',
              repoRoot: '/worktrees/app/main',
              project: placement(
                projectKey: 'remote:github.com/acme/app',
                projectName: 'acme/app',
                cwd: '/worktrees/app/main',
                remoteUrl: 'https://github.com/acme/app.git',
                mainRepoRoot: '/repo/app',
              ),
            ),
          ],
        ),
        host(
          id: 'legacy',
          name: 'Legacy',
          workspaces: [
            workspace(
              id: 'legacy',
              repoRoot: '/repo/legacy',
              projectId: 'legacy-project',
              projectName: 'Legacy',
            ),
          ],
        ),
      ],
    );

    expect(
      result.projects
          .firstWhere(
            (entry) => entry.projectKey == 'remote:github.com/acme/app',
          )
          .hosts
          .single
          .repoRoot,
      '/repo/app',
    );
    expect(
      result.projects
          .firstWhere((entry) => entry.projectKey == 'legacy-project')
          .hosts
          .single
          .repoRoot,
      '/repo/legacy',
    );
  });

  test('derives GitHub URL only for exact GitHub remote keys', () {
    final result = buildProjects(
      hosts: [
        host(
          id: 'local',
          name: 'Local',
          workspaces: [
            workspace(
              id: 'github',
              repoRoot: '/repo/app',
              project: placement(
                projectKey: 'remote:github.com/acme/app',
                projectName: 'acme/app',
                cwd: '/repo/app',
                remoteUrl: 'https://github.com/acme/app.git',
              ),
            ),
            workspace(
              id: 'local',
              repoRoot: '/repo/local',
              project: placement(
                projectKey: '/repo/local',
                projectName: 'local',
                cwd: '/repo/local',
                remoteUrl: null,
              ),
            ),
          ],
        ),
      ],
    );

    expect(result.projects[0].githubUrl, 'https://github.com/acme/app');
    expect(result.projects[1].githubUrl, isNull);
  });

  test('counts online hosts without dropping offline replicas', () {
    final project = placement(
      projectKey: 'remote:github.com/acme/app',
      projectName: 'acme/app',
      cwd: '/repo/app',
      remoteUrl: 'https://github.com/acme/app.git',
    );
    final result = buildProjects(
      hosts: [
        host(
          id: 'online',
          name: 'Online',
          workspaces: [
            workspace(id: 'ws', repoRoot: '/repo/app', project: project),
          ],
        ),
        host(
          id: 'offline',
          name: 'Offline',
          online: false,
          workspaces: [
            workspace(id: 'ws', repoRoot: '/repo/app', project: project),
          ],
        ),
      ],
    );

    expect(result.projects.single.hostCount, 2);
    expect(result.projects.single.onlineHostCount, 1);
    expect(
      result.projects.single.hosts
          .firstWhere((entry) => entry.serverId == 'offline')
          .isOnline,
      isFalse,
    );
  });

  test('keeps local roots separate and sorts mixed forge projects by name', () {
    final cases = [
      ('remote:github.com/acme/web', 'acme/web', '/repo/github'),
      ('remote:gitlab.com/acme/api', 'acme/api', '/repo/gitlab'),
      ('remote:bitbucket.org/acme/cli', 'acme/cli', '/repo/bitbucket'),
      ('/repo/local', 'local', '/repo/local'),
      ('/repo/two', 'two', '/repo/two'),
    ];
    final result = buildProjects(
      hosts: [
        host(
          id: 'local',
          name: 'Local',
          workspaces: [
            for (final entry in cases)
              workspace(
                id: entry.$2,
                repoRoot: entry.$3,
                project: placement(
                  projectKey: entry.$1,
                  projectName: entry.$2,
                  cwd: entry.$3,
                  remoteUrl: entry.$1.startsWith('remote:')
                      ? 'https://${entry.$1.substring(7)}.git'
                      : null,
                ),
              ),
          ],
        ),
      ],
    );

    expect(result.projects.map((entry) => entry.projectKey), [
      'remote:gitlab.com/acme/api',
      'remote:bitbucket.org/acme/cli',
      'remote:github.com/acme/web',
      '/repo/local',
      '/repo/two',
    ]);
  });

  test('groups non-GitHub remotes and supports legacy descriptors', () {
    final gitlab = placement(
      projectKey: 'remote:gitlab.com/acme/app',
      projectName: 'acme/app',
      cwd: '/repo/gitlab',
      remoteUrl: 'https://gitlab.com/acme/app.git',
    );
    final result = buildProjects(
      hosts: [
        host(
          id: 'local',
          name: 'Local',
          workspaces: [
            workspace(id: 'main', repoRoot: '/repo/gitlab', project: gitlab),
            workspace(id: 'feature', repoRoot: '/repo/gitlab', project: gitlab),
          ],
        ),
        host(
          id: 'old',
          name: 'Old',
          workspaces: [
            workspace(
              id: 'legacy',
              repoRoot: '/repo/legacy',
              projectId: 'legacy-project',
              projectName: 'Legacy',
              remoteUrl: 'https://gitlab.com/acme/legacy.git',
            ),
          ],
        ),
      ],
    );

    final remote = result.projects.firstWhere(
      (entry) => entry.projectKey == 'remote:gitlab.com/acme/app',
    );
    expect(remote.hosts.single.workspaceCount, 2);
    expect(remote.githubUrl, isNull);
    final legacy = result.projects.firstWhere(
      (entry) => entry.projectKey == 'legacy-project',
    );
    expect(legacy.projectName, 'Legacy');
    expect(legacy.hosts.single.repoRoot, '/repo/legacy');
  });

  test('surfaces empty projects with an editable repoRoot', () {
    final result = buildProjects(
      hosts: [
        host(
          id: 'local',
          name: 'Local',
          emptyProjects: const [
            WorkspaceProjectDescriptor(
              projectId: '/repo/fresh',
              projectDisplayName: 'fresh',
              projectCustomName: null,
              projectRootPath: '/repo/fresh',
              projectKind: WorkspaceProjectKind.git,
            ),
          ],
        ),
      ],
    );

    final summary = result.projects.single;
    expect(summary.projectKey, '/repo/fresh');
    expect(summary.totalWorkspaceCount, 0);
    expect(summary.hosts.single.repoRoot, '/repo/fresh');
    expect(summary.hosts.single.workspaceCount, 0);
  });

  test('prefers a project custom name and retains canonical runtimes', () {
    final result = buildProjects(
      hosts: [
        host(
          id: 'local',
          name: 'Local',
          workspaces: [
            workspace(
              id: 'main',
              repoRoot: '/repo/app',
              projectId: 'project-1',
              projectName: 'acme/app',
              projectCustomName: 'App',
            ),
          ],
        ),
      ],
    );

    final summary = result.projects.single;
    expect(summary.projectName, 'acme/app');
    expect(summary.projectCustomName, 'App');
    expect(summary.hosts.single.gitRuntime, isNotNull);
  });
}
