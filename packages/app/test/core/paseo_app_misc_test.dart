// Ports of the upstream Paseo 0.2.0 suites for the six modules collected in
// `lib/core/paseo_app_misc.dart`:
//
//   file-explorer/preview-target.test.ts
//   projects/host-projects.test.ts (which exercises host-project-model.ts)
//   hooks/use-preferred-editor.test.ts
//   screens/settings/daemon-restart.test.ts
//   utils/review-attachments.test.ts
//   workspace-service-routes/store.test.ts
//
// Every upstream case is ported, plus the edges those suites leave unpinned:
// JS falsy-vs-nullish handling, path normalisation corner cases, storage
// blobs the upstream fixtures never produce, and the ordering guarantees the
// upstream suites only imply.
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/paseo_app_misc.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Stand-in for AsyncStorage / zustand's `StateStorage`, mirroring the
/// `createMemoryStorage` helper in upstream's store suite.
final class _MemoryStorage implements MutableKeyValueStorage {
  _MemoryStorage([Map<String, String>? initial]) : values = {...?initial};

  final Map<String, String> values;
  final List<String> calls = [];

  @override
  Future<String?> getItem(String key) async {
    calls.add('get:$key');
    return values[key];
  }

  @override
  Future<void> setItem(String key, String value) async {
    calls.add('set:$key');
    values[key] = value;
  }

  @override
  Future<void> removeItem(String key) async {
    calls.add('remove:$key');
    values.remove(key);
  }
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

WorkspaceStructureHostPlacement _placement({
  String serverId = 'host-a',
  String iconWorkingDir = '/repo/a',
  bool canCreateWorktree = true,
}) => WorkspaceStructureHostPlacement(
  serverId: serverId,
  iconWorkingDir: iconWorkingDir,
  canCreateWorktree: canCreateWorktree,
);

WorkspaceStructureProject _structureProject({
  String projectKey = 'project-a',
  String projectName = 'Project A',
  WorkspaceProjectKind projectKind = WorkspaceProjectKind.git,
  String iconWorkingDir = '/repo/a',
  List<WorkspaceStructureHostPlacement>? hosts,
  List<String>? workspaceKeys,
}) => WorkspaceStructureProject(
  projectKey: projectKey,
  projectName: projectName,
  projectKind: projectKind,
  iconWorkingDir: iconWorkingDir,
  hosts:
      hosts ??
      [
        _placement(
          iconWorkingDir: iconWorkingDir,
          canCreateWorktree: projectKind != WorkspaceProjectKind.directory,
        ),
      ],
  workspaceKeys: workspaceKeys ?? const ['workspace-a'],
);

HostProjectListItem _hostProject({
  String projectKey = 'project-a',
  String projectName = 'Project A',
  WorkspaceProjectKind projectKind = WorkspaceProjectKind.git,
  String iconWorkingDir = '/repo/a',
  List<WorkspaceStructureHostPlacement>? hosts,
  List<String>? workspaceKeys,
}) => HostProjectListItem(
  projectKey: projectKey,
  projectName: projectName,
  projectKind: projectKind,
  iconWorkingDir: iconWorkingDir,
  hosts: hosts ?? [_placement(iconWorkingDir: iconWorkingDir)],
  workspaceKeys: workspaceKeys ?? const ['workspace-a'],
);

WorkspaceDescriptor _workspace({
  String id = 'workspace-a',
  String projectId = 'project-a',
  String projectDisplayName = 'Project A',
  String projectRootPath = '/repo/a',
  WorkspaceProjectKind projectKind = WorkspaceProjectKind.git,
}) => WorkspaceDescriptor(
  id: id,
  projectId: projectId,
  projectDisplayName: projectDisplayName,
  projectRootPath: projectRootPath,
  workspaceDirectory: projectRootPath,
  projectKind: projectKind,
  workspaceKind: WorkspaceKind.localCheckout,
  name: 'main',
  status: WorkspaceStateBucket.done,
  activityAt: null,
);

final _routeProject = _hostProject(
  projectKey: 'route-project',
  projectName: 'Route Project',
  iconWorkingDir: '/repo/route',
);
final _lastActiveProject = _hostProject(
  projectKey: 'last-project',
  projectName: 'Last Project',
  iconWorkingDir: '/repo/last',
);
final _firstProject = _hostProject(
  projectKey: 'first-project',
  projectName: 'First Project',
  iconWorkingDir: '/repo/first',
);

ForgeSearchItem _searchItem({
  ForgeSearchKind kind = ForgeSearchKind.changeRequest,
  String? forge,
  int number = 123,
  String title = 'Fix race in worktree setup',
  String url = 'https://github.com/getpaseo/paseo/pull/123',
  String state = 'OPEN',
  String? body = 'PR body',
  List<String> labels = const ['bug'],
  String? projectPath,
  String? baseRefName = 'main',
  String? headRefName = 'fix/worktree-race',
}) => ForgeSearchItem(
  kind: kind,
  forge: forge,
  number: number,
  title: title,
  url: url,
  state: state,
  body: body,
  labels: labels,
  projectPath: projectPath,
  baseRefName: baseRefName,
  headRefName: headRefName,
);

// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // file-explorer/preview-target.ts
  // -------------------------------------------------------------------------
  group('resolveFilePreviewReadTarget', () {
    test('uses the workspace cwd for relative paths', () {
      expect(
        resolveFilePreviewReadTarget(
          path: 'packages/app/src/message.tsx',
          workspaceRoot: '/Users/test/project',
        ),
        const FilePreviewReadTarget(
          cwd: '/Users/test/project',
          path: 'packages/app/src/message.tsx',
        ),
      );
    });

    test('uses the workspace cwd for absolute paths inside the workspace', () {
      expect(
        resolveFilePreviewReadTarget(
          path: '/Users/test/project/packages/app/src/message.tsx',
          workspaceRoot: '/Users/test/project',
        ),
        const FilePreviewReadTarget(
          cwd: '/Users/test/project',
          path: '/Users/test/project/packages/app/src/message.tsx',
        ),
      );
    });

    test(
      'uses the filesystem root for absolute paths outside the workspace',
      () {
        expect(
          resolveFilePreviewReadTarget(
            path: '/tmp/paseo-preview.txt',
            workspaceRoot: '/Users/test/project',
          ),
          const FilePreviewReadTarget(cwd: '/', path: '/tmp/paseo-preview.txt'),
        );
      },
    );

    test('uses the home root for tilde paths', () {
      expect(
        resolveFilePreviewReadTarget(
          path: '~/.paseo/plans/file-preview.md',
          workspaceRoot: '/Users/test/project',
        ),
        const FilePreviewReadTarget(
          cwd: '~',
          path: '~/.paseo/plans/file-preview.md',
        ),
      );
    });

    test('uses the drive root for Windows absolute paths outside the '
        'workspace', () {
      expect(
        resolveFilePreviewReadTarget(
          path: 'C:/Users/test/Desktop/file.txt',
          workspaceRoot: 'D:/repo',
        ),
        const FilePreviewReadTarget(
          cwd: 'C:/',
          path: 'C:/Users/test/Desktop/file.txt',
        ),
      );
    });

    test('rejects relative paths without an absolute workspace root', () {
      expect(resolveFilePreviewReadTarget(path: 'src/app.ts'), isNull);
      expect(
        resolveFilePreviewReadTarget(
          path: 'src/app.ts',
          workspaceRoot: 'relative/root',
        ),
        isNull,
      );
    });

    // --- edges the upstream suite leaves unpinned ---

    test('rejects a blank or whitespace-only path', () {
      expect(
        resolveFilePreviewReadTarget(path: '', workspaceRoot: '/repo'),
        isNull,
      );
      expect(
        resolveFilePreviewReadTarget(path: '   \t ', workspaceRoot: '/repo'),
        isNull,
      );
    });

    test('trims the path and the workspace root before using them', () {
      expect(
        resolveFilePreviewReadTarget(
          path: '  src/app.ts  ',
          workspaceRoot: '  /repo  ',
        ),
        const FilePreviewReadTarget(cwd: '/repo', path: 'src/app.ts'),
      );
    });

    test('treats a whitespace-only workspace root as absent', () {
      expect(
        resolveFilePreviewReadTarget(path: 'src/app.ts', workspaceRoot: '   '),
        isNull,
      );
    });

    test('accepts a bare tilde and a backslash-separated home path', () {
      expect(
        resolveFilePreviewReadTarget(path: '~'),
        const FilePreviewReadTarget(cwd: '~', path: '~'),
      );
      expect(
        resolveFilePreviewReadTarget(path: r'~\notes\todo.md'),
        const FilePreviewReadTarget(cwd: '~', path: r'~\notes\todo.md'),
      );
    });

    test('a tilde path ignores the workspace root even when it would '
        'contain it', () {
      expect(
        resolveFilePreviewReadTarget(path: '~/a.txt', workspaceRoot: '~'),
        const FilePreviewReadTarget(cwd: '~', path: '~/a.txt'),
      );
    });

    test('a name that merely starts with a tilde is not home-relative', () {
      // `~backup/x` has no separator after the tilde, so it stays relative.
      expect(
        resolveFilePreviewReadTarget(path: '~backup/x', workspaceRoot: '/repo'),
        const FilePreviewReadTarget(cwd: '/repo', path: '~backup/x'),
      );
    });

    test('uses the share root for UNC paths', () {
      expect(
        resolveFilePreviewReadTarget(path: r'\\server\share\dir\file.txt'),
        const FilePreviewReadTarget(
          cwd: r'\\server\share',
          path: r'\\server\share\dir\file.txt',
        ),
      );
    });

    test('rejects an absolute path with no derivable root', () {
      // Passes `isAbsolutePath` on the `\\` prefix but names no share.
      expect(resolveFilePreviewReadTarget(path: r'\\server'), isNull);
    });

    test('matches a Windows workspace root across separator style, trailing '
        'separator and drive-letter case', () {
      expect(
        resolveFilePreviewReadTarget(
          path: r'c:\repo\src\main.dart',
          workspaceRoot: 'C:/repo/',
        ),
        const FilePreviewReadTarget(
          cwd: 'C:/repo/',
          path: r'c:\repo\src\main.dart',
        ),
      );
    });

    test('the drive root itself is not inside a deeper workspace root', () {
      expect(
        resolveFilePreviewReadTarget(path: 'C:/', workspaceRoot: 'C:/repo'),
        const FilePreviewReadTarget(cwd: 'C:/', path: 'C:/'),
      );
    });

    test('a root of / contains every absolute POSIX path', () {
      expect(
        resolveFilePreviewReadTarget(path: '/etc/hosts', workspaceRoot: '/'),
        const FilePreviewReadTarget(cwd: '/', path: '/etc/hosts'),
      );
    });

    test('a path equal to the workspace root is inside it', () {
      expect(
        resolveFilePreviewReadTarget(
          path: '/Users/test/project',
          workspaceRoot: '/Users/test/project/',
        ),
        const FilePreviewReadTarget(
          cwd: '/Users/test/project/',
          path: '/Users/test/project',
        ),
      );
    });

    test('a sibling that shares the root prefix is not inside it', () {
      expect(
        resolveFilePreviewReadTarget(
          path: '/Users/test/project-two/a.txt',
          workspaceRoot: '/Users/test/project',
        ),
        const FilePreviewReadTarget(
          cwd: '/',
          path: '/Users/test/project-two/a.txt',
        ),
      );
    });

    test('a root that normalises away contains nothing', () {
      // `//` trims to the empty string, which upstream's `!root` guard rejects.
      expect(
        resolveFilePreviewReadTarget(path: '/tmp/a.txt', workspaceRoot: '//'),
        const FilePreviewReadTarget(cwd: '/', path: '/tmp/a.txt'),
      );
    });

    test(
      'a relative path is kept verbatim rather than joined onto the root',
      () {
        expect(
          resolveFilePreviewReadTarget(
            path: '../outside/a.txt',
            workspaceRoot: '/repo',
          ),
          const FilePreviewReadTarget(cwd: '/repo', path: '../outside/a.txt'),
        );
      },
    );
  });

  // -------------------------------------------------------------------------
  // projects/host-project-model.ts + projects/host-projects.ts
  // -------------------------------------------------------------------------
  group('host project list', () {
    test('preserves workspace-structure order and project metadata', () {
      expect(
        buildHostProjectList(
          projects: [
            _structureProject(
              projectKey: 'project-b',
              projectName: 'Project B',
              projectKind: WorkspaceProjectKind.directory,
              iconWorkingDir: '/repo/b',
              workspaceKeys: const ['workspace-b'],
              hosts: [
                _placement(iconWorkingDir: '/repo/b', canCreateWorktree: false),
              ],
            ),
            _structureProject(
              projectKey: 'project-a',
              projectName: 'Project A',
              iconWorkingDir: '/repo/a',
              workspaceKeys: const ['workspace-a'],
              hosts: [_placement(iconWorkingDir: '/repo/a')],
            ),
          ],
        ),
        [
          HostProjectListItem(
            projectKey: 'project-b',
            projectName: 'Project B',
            projectKind: WorkspaceProjectKind.directory,
            iconWorkingDir: '/repo/b',
            hosts: [
              _placement(iconWorkingDir: '/repo/b', canCreateWorktree: false),
            ],
            workspaceKeys: const ['workspace-b'],
          ),
          HostProjectListItem(
            projectKey: 'project-a',
            projectName: 'Project A',
            projectKind: WorkspaceProjectKind.git,
            iconWorkingDir: '/repo/a',
            hosts: [_placement(iconWorkingDir: '/repo/a')],
            workspaceKeys: const ['workspace-a'],
          ),
        ],
      );
    });

    test('keeps worktree capability separate from project listability', () {
      expect(canCreateWorktreeForProjectKind(WorkspaceProjectKind.git), isTrue);
      expect(
        canCreateWorktreeForProjectKind(WorkspaceProjectKind.directory),
        isFalse,
      );
      // Edge: the third kind this repo's wire enum carries is also not a
      // worktree host — only `git` is.
      expect(
        canCreateWorktreeForProjectKind(WorkspaceProjectKind.nonGit),
        isFalse,
      );
    });

    test('uses route project before last active project when it can create '
        'worktrees', () {
      expect(
        resolveInitialWorktreeProject(
          routeProject: _routeProject,
          lastActiveProject: _lastActiveProject,
          projects: [_firstProject],
        ),
        _routeProject,
      );
    });

    test('skips non-worktree route and last-active projects', () {
      final resolved = resolveInitialWorktreeProject(
        routeProject: _routeProject.copyWith(
          projectKind: WorkspaceProjectKind.directory,
          hosts: [
            _placement(iconWorkingDir: '/repo/route', canCreateWorktree: false),
          ],
        ),
        lastActiveProject: _lastActiveProject.copyWith(
          projectKind: WorkspaceProjectKind.directory,
          hosts: [
            _placement(iconWorkingDir: '/repo/last', canCreateWorktree: false),
          ],
        ),
        projects: [
          _firstProject.copyWith(
            projectKind: WorkspaceProjectKind.directory,
            hosts: [
              _placement(
                iconWorkingDir: '/repo/first',
                canCreateWorktree: false,
              ),
            ],
          ),
          _hostProject(projectKey: 'git-project', projectName: 'Git Project'),
        ],
      );

      expect(resolved?.projectKey, 'git-project');
    });

    test('leaves the project empty when no worktree-capable project is '
        'available', () {
      expect(
        resolveInitialWorktreeProject(
          routeProject: null,
          lastActiveProject: null,
          projects: [
            _firstProject.copyWith(
              projectKind: WorkspaceProjectKind.directory,
              hosts: [
                _placement(
                  iconWorkingDir: '/repo/first',
                  canCreateWorktree: false,
                ),
              ],
            ),
          ],
        ),
        isNull,
      );
    });

    test('filters new-workspace projects to the selected host', () {
      final hostAOnly = _hostProject(
        projectKey: 'host-a-project',
        hosts: [_placement(serverId: 'host-a', iconWorkingDir: '/repo/a')],
      );
      final hostBOnly = _hostProject(
        projectKey: 'host-b-project',
        hosts: [_placement(serverId: 'host-b', iconWorkingDir: '/repo/b')],
      );

      expect(
        filterWorkspaceProjectsForHost(
          projects: [hostAOnly, hostBOnly],
          serverId: 'host-b',
          allowAllProjects: false,
        ).map((project) => project.projectKey),
        ['host-b-project'],
      );
    });

    test('allows directory projects only when workspace multiplicity is '
        'supported', () {
      final directoryProject = _hostProject(
        projectKey: 'directory-project',
        projectKind: WorkspaceProjectKind.directory,
        hosts: [
          _placement(
            iconWorkingDir: '/repo/directory',
            canCreateWorktree: false,
          ),
        ],
      );

      expect(
        canCreateWorkspaceForHostProject(
          project: directoryProject,
          serverId: 'host-a',
          allowAllProjects: false,
        ),
        isFalse,
      );
      expect(
        canCreateWorkspaceForHostProject(
          project: directoryProject,
          serverId: 'host-a',
          allowAllProjects: true,
        ),
        isTrue,
      );
    });

    test('falls back when the route project is not available on the selected '
        'host', () {
      final selectedHostProject = _hostProject(
        projectKey: 'selected-host-project',
        hosts: [
          _placement(serverId: 'host-b', iconWorkingDir: '/repo/selected-host'),
        ],
      );

      expect(
        resolveInitialWorkspaceProject(
          routeProject: _routeProject,
          lastActiveProject: null,
          projects: [selectedHostProject],
          serverId: 'host-b',
          allowAllProjects: false,
        ),
        selectedHostProject,
      );
    });

    test('resolves the selected host project source directory', () {
      final project = _hostProject(
        hosts: [
          _placement(serverId: 'host-a', iconWorkingDir: '/repo/a'),
          _placement(serverId: 'host-b', iconWorkingDir: '/repo/b'),
        ],
      );

      expect(getHostProjectSourceDirectory(project, 'host-b'), '/repo/b');
      expect(getHostProjectSourceDirectory(project, 'host-c'), isNull);
    });

    test('keeps a selected route project available before project '
        'hydration', () {
      expect(
        resolveSelectedHostProject(
          selectedProjectKey: _routeProject.projectKey,
          projects: const [],
          routeProject: _routeProject,
          lastActiveProject: null,
        ),
        _routeProject,
      );
    });

    test('converts route project only when it has a key and source '
        'directory', () {
      expect(
        hostProjectFromRoute(
          const HostProjectRouteContext(
            serverId: 'host-a',
            projectId: 'project-a',
            displayName: 'Project A',
            sourceDirectory: '/repo/a',
          ),
        ),
        HostProjectListItem(
          projectKey: 'project-a',
          projectName: 'Project A',
          projectKind: WorkspaceProjectKind.git,
          iconWorkingDir: '/repo/a',
          hosts: [_placement(iconWorkingDir: '/repo/a')],
          workspaceKeys: const [],
        ),
      );
      expect(
        hostProjectFromRoute(
          const HostProjectRouteContext(
            serverId: 'host-a',
            projectId: 'project-a',
          ),
        ),
        isNull,
      );
    });

    test('converts last active workspaces with matching worktree '
        'capability', () {
      expect(
        hostProjectFromWorkspace(serverId: 'host-a', workspace: _workspace()),
        HostProjectListItem(
          projectKey: 'project-a',
          projectName: 'Project A',
          projectKind: WorkspaceProjectKind.git,
          iconWorkingDir: '/repo/a',
          hosts: [_placement(iconWorkingDir: '/repo/a')],
          workspaceKeys: const ['host-a:workspace-a'],
        ),
      );

      final directory = hostProjectFromWorkspace(
        serverId: 'host-a',
        workspace: _workspace(projectKind: WorkspaceProjectKind.directory),
      );
      expect(directory?.projectKind, WorkspaceProjectKind.directory);
      expect(directory?.hosts, [
        _placement(iconWorkingDir: '/repo/a', canCreateWorktree: false),
      ]);
    });

    // --- edges the upstream suite leaves unpinned ---

    test('selectHostProjects short-circuits an empty structure', () {
      expect(selectHostProjects(const []), isEmpty);
      expect(
        selectHostProjects([_structureProject()]).single.projectKey,
        'project-a',
      );
    });

    test('buildHostProjectList shares the placement and key lists rather than '
        'copying them', () {
      // Upstream assigns `project.hosts` straight across; the identity is
      // observable to any caller that mutates or compares by reference.
      final structure = _structureProject();
      final built = buildHostProjectList(projects: [structure]).single;
      expect(identical(built.hosts, structure.hosts), isTrue);
      expect(identical(built.workspaceKeys, structure.workspaceKeys), isTrue);
    });

    test('hostProjectFromRoute trims its inputs and rejects blank ones', () {
      expect(
        hostProjectFromRoute(
          const HostProjectRouteContext(
            serverId: 'host-a',
            projectId: '  project-a  ',
            displayName: '  Project A  ',
            sourceDirectory: '  /repo/a  ',
          ),
        ),
        HostProjectListItem(
          projectKey: 'project-a',
          projectName: 'Project A',
          projectKind: WorkspaceProjectKind.git,
          iconWorkingDir: '/repo/a',
          hosts: [_placement(iconWorkingDir: '/repo/a')],
          workspaceKeys: const [],
        ),
      );

      expect(
        hostProjectFromRoute(
          const HostProjectRouteContext(
            serverId: 'host-a',
            projectId: '   ',
            sourceDirectory: '/repo/a',
          ),
        ),
        isNull,
      );
      expect(
        hostProjectFromRoute(
          const HostProjectRouteContext(
            serverId: 'host-a',
            projectId: 'project-a',
            sourceDirectory: '   ',
          ),
        ),
        isNull,
      );
    });

    test('hostProjectFromRoute falls back to the project key for a blank '
        'display name', () {
      expect(
        hostProjectFromRoute(
          const HostProjectRouteContext(
            serverId: 'host-a',
            projectId: 'project-a',
            displayName: '   ',
            sourceDirectory: '/repo/a',
          ),
        )?.projectName,
        'project-a',
      );
    });

    test('hostProjectFromWorkspace rejects a null workspace and blank '
        'identifiers', () {
      expect(
        hostProjectFromWorkspace(serverId: 'host-a', workspace: null),
        isNull,
      );
      expect(
        hostProjectFromWorkspace(
          serverId: 'host-a',
          workspace: _workspace(projectId: '   '),
        ),
        isNull,
      );
      expect(
        hostProjectFromWorkspace(
          serverId: 'host-a',
          workspace: _workspace(projectRootPath: '   '),
        ),
        isNull,
      );
    });

    test('hostProjectFromWorkspace keeps a whitespace-only display name but '
        'replaces an empty one', () {
      // Upstream's `projectDisplayName || projectKey` is an untrimmed falsy
      // test, so "  " is truthy and survives while "" does not.
      expect(
        hostProjectFromWorkspace(
          serverId: 'host-a',
          workspace: _workspace(projectDisplayName: '  '),
        )?.projectName,
        '  ',
      );
      expect(
        hostProjectFromWorkspace(
          serverId: 'host-a',
          workspace: _workspace(projectDisplayName: ''),
        )?.projectName,
        'project-a',
      );
    });

    test('hostProjectFromWorkspace namespaces the workspace key by host', () {
      expect(
        hostProjectFromWorkspace(
          serverId: 'devbox',
          workspace: _workspace(id: 'ws-7'),
        )?.workspaceKeys,
        ['devbox:ws-7'],
      );
    });

    test('canCreateWorkspaceForHostProject rejects a project that is not on '
        'the host at all, even with multiplicity', () {
      expect(
        canCreateWorkspaceForHostProject(
          project: _hostProject(hosts: [_placement(serverId: 'host-a')]),
          serverId: 'host-z',
          allowAllProjects: true,
        ),
        isFalse,
      );
    });

    test('getHostProjectSourceDirectory returns the first matching '
        'placement', () {
      expect(
        getHostProjectSourceDirectory(
          _hostProject(
            hosts: [
              _placement(serverId: 'host-a', iconWorkingDir: '/first'),
              _placement(serverId: 'host-a', iconWorkingDir: '/second'),
            ],
          ),
          'host-a',
        ),
        '/first',
      );
    });

    test('filterWorkspaceProjectsForHost keeps the incoming order', () {
      final projects = [
        _hostProject(projectKey: 'c'),
        _hostProject(projectKey: 'a'),
        _hostProject(
          projectKey: 'b',
          hosts: [_placement(serverId: 'other')],
        ),
      ];
      expect(
        filterWorkspaceProjectsForHost(
          projects: projects,
          serverId: 'host-a',
          allowAllProjects: false,
        ).map((project) => project.projectKey),
        ['c', 'a'],
      );
    });

    test('resolveInitialWorkspaceProject prefers the hydrated copy of the '
        'route stub', () {
      final hydrated = _hostProject(
        projectKey: 'route-project',
        projectName: 'Hydrated Route Project',
        hosts: [_placement(serverId: 'host-a', iconWorkingDir: '/real/route')],
      );

      expect(
        resolveInitialWorkspaceProject(
          routeProject: _routeProject,
          lastActiveProject: null,
          projects: [hydrated],
          serverId: 'host-a',
          allowAllProjects: false,
        ),
        hydrated,
      );
    });

    test('resolveInitialWorkspaceProject falls through the route to the last '
        'active project', () {
      final lastActive = _hostProject(
        projectKey: 'last-project',
        hosts: [_placement(serverId: 'host-b')],
      );
      final routeElsewhere = _hostProject(
        projectKey: 'route-project',
        hosts: [_placement(serverId: 'host-a')],
      );

      expect(
        resolveInitialWorkspaceProject(
          routeProject: routeElsewhere,
          lastActiveProject: lastActive,
          projects: const [],
          serverId: 'host-b',
          allowAllProjects: false,
        ),
        lastActive,
      );
    });

    test('resolveInitialWorkspaceProject falls back to the first project even '
        'when it is unusable on the host', () {
      final unusable = _hostProject(
        projectKey: 'elsewhere',
        hosts: [_placement(serverId: 'host-z')],
      );

      expect(
        resolveInitialWorkspaceProject(
          routeProject: null,
          lastActiveProject: null,
          projects: [
            unusable,
            _hostProject(projectKey: 'second'),
          ],
          serverId: 'host-a',
          allowAllProjects: false,
        ),
        unusable,
      );
    });

    test(
      'resolveInitialWorkspaceProject returns null with nothing to offer',
      () {
        expect(
          resolveInitialWorkspaceProject(
            routeProject: null,
            lastActiveProject: null,
            projects: const [],
            serverId: 'host-a',
            allowAllProjects: true,
          ),
          isNull,
        );
      },
    );

    test('resolveInitialWorktreeProject uses the last active project when the '
        'route has none', () {
      expect(
        resolveInitialWorktreeProject(
          routeProject: null,
          lastActiveProject: _lastActiveProject,
          projects: [_firstProject],
        ),
        _lastActiveProject,
      );
    });

    test('resolveInitialWorktreeProject trusts the route stub without '
        'consulting the hydrated list', () {
      // The hydrated copy says the project cannot host a worktree; the stub
      // still wins, because this resolver never re-reads its candidates.
      final resolved = resolveInitialWorktreeProject(
        routeProject: _routeProject,
        lastActiveProject: null,
        projects: [
          _routeProject.copyWith(
            projectKind: WorkspaceProjectKind.directory,
            hosts: [_placement(canCreateWorktree: false)],
          ),
        ],
      );
      expect(resolved, _routeProject);
      expect(resolved?.hosts.single.canCreateWorktree, isTrue);
    });

    test('resolveSelectedHostProject prefers hydrated projects over the '
        'stubs', () {
      final hydrated = _hostProject(
        projectKey: 'route-project',
        projectName: 'Hydrated',
      );
      expect(
        resolveSelectedHostProject(
          selectedProjectKey: 'route-project',
          projects: [hydrated],
          routeProject: _routeProject,
          lastActiveProject: null,
        ),
        hydrated,
      );
    });

    test('resolveSelectedHostProject falls back to the last active stub', () {
      expect(
        resolveSelectedHostProject(
          selectedProjectKey: '  last-project  ',
          projects: const [],
          routeProject: _routeProject,
          lastActiveProject: _lastActiveProject,
        ),
        _lastActiveProject,
      );
    });

    test('resolveSelectedHostProject treats a null or blank key as no '
        'selection', () {
      expect(
        resolveSelectedHostProject(
          selectedProjectKey: null,
          projects: [_routeProject],
          routeProject: _routeProject,
          lastActiveProject: _lastActiveProject,
        ),
        isNull,
      );
      expect(
        resolveSelectedHostProject(
          selectedProjectKey: '   ',
          projects: [_routeProject],
          routeProject: _routeProject,
          lastActiveProject: _lastActiveProject,
        ),
        isNull,
      );
    });

    test('resolveSelectedHostProject returns null for an unknown key', () {
      expect(
        resolveSelectedHostProject(
          selectedProjectKey: 'ghost',
          projects: [_firstProject],
          routeProject: _routeProject,
          lastActiveProject: _lastActiveProject,
        ),
        isNull,
      );
    });
  });

  // -------------------------------------------------------------------------
  // hooks/use-preferred-editor.ts
  // -------------------------------------------------------------------------
  group('resolvePreferredEditorId', () {
    String? resolve(List<String> available, String? stored) =>
        resolvePreferredEditorId(available, KnownPreferredEditorId(stored));

    test('keeps the stored editor when it is still available', () {
      expect(resolve(['cursor', 'vscode'], 'vscode'), 'vscode');
    });

    test('falls back to the first available editor when the stored one is '
        'missing', () {
      expect(resolve(['zed', 'finder'], 'cursor'), 'zed');
    });

    test('falls back when a platform-specific file manager target is '
        'unavailable', () {
      expect(resolve(['explorer', 'vscode'], 'finder'), 'explorer');
    });

    test('keeps unknown editor ids when they are still available', () {
      expect(
        resolve(['unknown-editor', 'cursor'], 'unknown-editor'),
        'unknown-editor',
      );
    });

    test('keeps custom script target ids as plain strings', () {
      expect(
        resolve(['script:open-in-nvim', 'cursor'], 'script:open-in-nvim'),
        'script:open-in-nvim',
      );
    });

    test('returns null when no editors are available', () {
      expect(resolve(const [], 'cursor'), isNull);
    });

    // --- edges the upstream suite leaves unpinned ---

    test('returns null while the stored preference is still loading', () {
      expect(
        resolvePreferredEditorId([
          'cursor',
          'vscode',
        ], const PendingPreferredEditorId()),
        isNull,
      );
    });

    test('falls back to the first editor when nothing is stored', () {
      expect(resolve(['cursor', 'vscode'], null), 'cursor');
    });

    test('treats a stored empty string as nothing stored', () {
      expect(resolve(['cursor', ''], ''), 'cursor');
    });

    test('returns null when nothing is stored and nothing is available', () {
      expect(resolve(const [], null), isNull);
    });

    test('availableEditorIdsOf preserves the reply order', () {
      expect(
        availableEditorIdsOf(const [
          AvailableEditor(id: 'vscode', label: 'VS Code'),
          AvailableEditor(id: 'finder', label: 'Finder'),
        ]),
        ['vscode', 'finder'],
      );
    });
  });

  group('loadPreferredEditor', () {
    test(
      'returns null for an absent, empty or whitespace-only value',
      () async {
        expect(await loadPreferredEditor(_MemoryStorage()), isNull);
        expect(
          await loadPreferredEditor(
            _MemoryStorage({preferredEditorStorageKey: ''}),
          ),
          isNull,
        );
        expect(
          await loadPreferredEditor(
            _MemoryStorage({preferredEditorStorageKey: '   '}),
          ),
          isNull,
        );
      },
    );

    test('trims the stored id', () async {
      expect(
        await loadPreferredEditor(
          _MemoryStorage({preferredEditorStorageKey: '  vscode  '}),
        ),
        'vscode',
      );
    });

    test('reads the frozen storage key', () async {
      expect(preferredEditorStorageKey, '@paseo:preferred-editor');
      expect(preferredEditorQueryKey, ['preferred-editor']);

      final storage = _MemoryStorage({'@paseo:preferred-editor': 'zed'});
      expect(await loadPreferredEditor(storage), 'zed');
      expect(storage.calls, ['get:@paseo:preferred-editor']);
    });
  });

  group('PreferredEditorController', () {
    test('reports pending until the first read resolves', () async {
      final controller = PreferredEditorController(
        _MemoryStorage({preferredEditorStorageKey: 'vscode'}),
      );

      expect(controller.isLoading, isTrue);
      expect(controller.preferredEditorId, const PendingPreferredEditorId());

      await controller.ensureLoaded();

      expect(controller.isLoading, isFalse);
      expect(
        controller.preferredEditorId,
        const KnownPreferredEditorId('vscode'),
      );
    });

    test('resolves to a known-null when nothing is stored', () async {
      final controller = PreferredEditorController(_MemoryStorage());
      await controller.ensureLoaded();
      expect(controller.preferredEditorId, const KnownPreferredEditorId(null));
      expect(
        resolvePreferredEditorId(const [
          'cursor',
        ], controller.preferredEditorId),
        'cursor',
      );
    });

    test('reads storage only once no matter how often it is awaited', () async {
      final storage = _MemoryStorage({preferredEditorStorageKey: 'zed'});
      final controller = PreferredEditorController(storage);

      await Future.wait([controller.ensureLoaded(), controller.ensureLoaded()]);
      await controller.ensureLoaded();

      expect(
        storage.calls.where((call) => call.startsWith('get:')),
        hasLength(1),
      );
    });

    test('persists an update and exposes it immediately', () async {
      final storage = _MemoryStorage();
      final controller = PreferredEditorController(storage);
      await controller.ensureLoaded();

      final pending = controller.updatePreferredEditor('cursor');
      expect(
        controller.preferredEditorId,
        const KnownPreferredEditorId('cursor'),
      );
      await pending;

      expect(storage.values[preferredEditorStorageKey], 'cursor');
    });

    test('clears the stored key when the preference is removed', () async {
      final storage = _MemoryStorage({preferredEditorStorageKey: 'cursor'});
      final controller = PreferredEditorController(storage);
      await controller.ensureLoaded();

      await controller.updatePreferredEditor(null);

      expect(storage.values.containsKey(preferredEditorStorageKey), isFalse);
      expect(controller.preferredEditorId, const KnownPreferredEditorId(null));
    });

    test('an empty id is cached but removed from storage', () async {
      final storage = _MemoryStorage({preferredEditorStorageKey: 'cursor'});
      final controller = PreferredEditorController(storage);
      await controller.ensureLoaded();

      await controller.updatePreferredEditor('');

      expect(controller.preferredEditorId, const KnownPreferredEditorId(''));
      expect(storage.values.containsKey(preferredEditorStorageKey), isFalse);
      // …and it resolves like nothing stored, so the picker still defaults.
      expect(
        resolvePreferredEditorId(const [
          'cursor',
        ], controller.preferredEditorId),
        'cursor',
      );
    });

    test('an update before the first read resolves the value and wins over '
        'the in-flight load', () async {
      final storage = _MemoryStorage({preferredEditorStorageKey: 'zed'});
      final controller = PreferredEditorController(storage);

      await controller.updatePreferredEditor('cursor');

      expect(controller.isLoading, isFalse);
      expect(
        controller.preferredEditorId,
        const KnownPreferredEditorId('cursor'),
      );

      await controller.ensureLoaded();
      expect(
        controller.preferredEditorId,
        const KnownPreferredEditorId('cursor'),
      );
    });
  });

  // -------------------------------------------------------------------------
  // screens/settings/daemon-restart.ts
  // -------------------------------------------------------------------------
  group('restartDaemonFromSettings', () {
    const runningDesktopDaemonStatus = DesktopDaemonRestartStatus(
      serverId: 'local-desktop',
      desktopManaged: true,
    );
    const managedSettings = DesktopDaemonSettings(
      manageBuiltInDaemon: true,
      keepRunningAfterQuit: false,
    );

    ({List<String> calls, SettingsDaemonRestartDeps deps}) makeDeps({
      bool isElectron = true,
      DesktopDaemonRestartStatus? desktopDaemonStatus,
      DesktopDaemonSettings? desktopSettings,
      Object? desktopSettingsError,
      Object? desktopDaemonStatusError,
      Future<DaemonStatus> Function(List<String> calls)? restartDesktopDaemon,
      Future<void> Function(List<String> calls, String reason)? restartServer,
    }) {
      final calls = <String>[];
      return (
        calls: calls,
        deps: SettingsDaemonRestartDeps(
          getIsElectron: () => isElectron,
          getDesktopDaemonStatus: () async {
            calls.add('desktop-status');
            if (desktopDaemonStatusError != null) {
              throw desktopDaemonStatusError;
            }
            return desktopDaemonStatus ?? runningDesktopDaemonStatus;
          },
          getDesktopSettings: () async {
            calls.add('desktop-settings');
            if (desktopSettingsError != null) throw desktopSettingsError;
            return desktopSettings ?? managedSettings;
          },
          restartDesktopDaemon: restartDesktopDaemon == null
              ? () async {
                  calls.add('desktop-restart');
                  return const DaemonStatus(health: DaemonHealth.running);
                }
              : () => restartDesktopDaemon(calls),
          restartServer: restartServer == null
              ? (reason) async {
                  calls.add('rpc-restart:$reason');
                }
              : (reason) => restartServer(calls, reason),
        ),
      );
    }

    test('restarts the local desktop-managed daemon through the desktop '
        'bridge', () async {
      final harness = makeDeps();

      await restartDaemonFromSettings(
        hostServerId: ' local-desktop ',
        reason: 'settings_daemon_restart_local',
        deps: harness.deps,
      );

      expect(harness.calls, [
        'desktop-status',
        'desktop-settings',
        'desktop-restart',
      ]);
    });

    test('restarts remote hosts over the daemon RPC without reading desktop '
        'settings', () async {
      final harness = makeDeps(
        desktopSettingsError: StateError('Unreadable desktop settings.'),
      );

      await restartDaemonFromSettings(
        hostServerId: 'remote-host',
        reason: 'settings_daemon_restart_remote',
        deps: harness.deps,
      );

      expect(harness.calls, [
        'desktop-status',
        'rpc-restart:settings_daemon_restart_remote',
      ]);
    });

    test('keeps manually managed local daemons on the RPC path without '
        'reading desktop settings', () async {
      final harness = makeDeps(
        desktopDaemonStatus: const DesktopDaemonRestartStatus(
          serverId: 'local-desktop',
          desktopManaged: false,
        ),
        desktopSettingsError: StateError('Unreadable desktop settings.'),
      );

      await restartDaemonFromSettings(
        hostServerId: 'local-desktop',
        reason: 'settings_daemon_restart_local',
        deps: harness.deps,
      );

      expect(harness.calls, [
        'desktop-status',
        'rpc-restart:settings_daemon_restart_local',
      ]);
    });

    test(
      'keeps the RPC path when built-in daemon management is disabled',
      () async {
        final harness = makeDeps(
          desktopSettings: const DesktopDaemonSettings(
            manageBuiltInDaemon: false,
            keepRunningAfterQuit: false,
          ),
        );

        await restartDaemonFromSettings(
          hostServerId: 'local-desktop',
          reason: 'settings_daemon_restart_local',
          deps: harness.deps,
        );

        expect(harness.calls, [
          'desktop-status',
          'desktop-settings',
          'rpc-restart:settings_daemon_restart_local',
        ]);
      },
    );

    test('uses the RPC path outside Electron without reading desktop daemon '
        'status or settings', () async {
      final harness = makeDeps(isElectron: false);

      await restartDaemonFromSettings(
        hostServerId: 'local-desktop',
        reason: 'settings_daemon_restart_local',
        deps: harness.deps,
      );

      expect(harness.calls, ['rpc-restart:settings_daemon_restart_local']);
    });

    test('surfaces desktop restart failures without falling back to worker '
        'recycle', () async {
      final harness = makeDeps(
        restartDesktopDaemon: (calls) async {
          calls.add('desktop-restart');
          throw StateError('Desktop restart failed.');
        },
      );

      await expectLater(
        restartDaemonFromSettings(
          hostServerId: 'local-desktop',
          reason: 'settings_daemon_restart_local',
          deps: harness.deps,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Desktop restart failed.',
          ),
        ),
      );

      expect(harness.calls, [
        'desktop-status',
        'desktop-settings',
        'desktop-restart',
      ]);
    });

    // --- edges the upstream suite leaves unpinned ---

    test(
      'a blank host id never matches, even a blank desktop server id',
      () async {
        final harness = makeDeps(
          desktopDaemonStatus: const DesktopDaemonRestartStatus(
            serverId: '   ',
            desktopManaged: true,
          ),
        );

        await restartDaemonFromSettings(
          hostServerId: '   ',
          reason: 'blank',
          deps: harness.deps,
        );

        expect(harness.calls, ['desktop-status', 'rpc-restart:blank']);
      },
    );

    test('the desktop server id is trimmed before comparison too', () async {
      final harness = makeDeps(
        desktopDaemonStatus: const DesktopDaemonRestartStatus(
          serverId: '  local-desktop\n',
          desktopManaged: true,
        ),
      );

      await restartDaemonFromSettings(
        hostServerId: 'local-desktop',
        reason: 'trimmed',
        deps: harness.deps,
      );

      expect(harness.calls, [
        'desktop-status',
        'desktop-settings',
        'desktop-restart',
      ]);
    });

    test('a failing desktop status read propagates instead of falling back to '
        'RPC', () async {
      final harness = makeDeps(
        desktopDaemonStatusError: StateError('No desktop bridge.'),
      );

      await expectLater(
        restartDaemonFromSettings(
          hostServerId: 'local-desktop',
          reason: 'status_failure',
          deps: harness.deps,
        ),
        throwsA(isA<StateError>()),
      );

      expect(harness.calls, ['desktop-status']);
    });

    test('a failing RPC restart propagates', () async {
      final harness = makeDeps(
        isElectron: false,
        restartServer: (calls, reason) async {
          calls.add('rpc-restart:$reason');
          throw StateError('RPC restart failed.');
        },
      );

      await expectLater(
        restartDaemonFromSettings(
          hostServerId: 'remote-host',
          reason: 'rpc_failure',
          deps: harness.deps,
        ),
        throwsA(isA<StateError>()),
      );

      expect(harness.calls, ['rpc-restart:rpc_failure']);
    });
  });

  // -------------------------------------------------------------------------
  // utils/review-attachments.ts
  // -------------------------------------------------------------------------
  group('buildGitHubAttachmentFromSearchItem', () {
    test('builds a forge change request attachment for pull requests', () {
      final attachment = buildGitHubAttachmentFromSearchItem(_searchItem());

      expect(attachment?.toJson(), {
        'type': 'forge_change_request',
        'mimeType': 'application/paseo-forge-change-request',
        'forge': 'github',
        'number': 123,
        'title': 'Fix race in worktree setup',
        'url': 'https://github.com/getpaseo/paseo/pull/123',
        'body': 'PR body',
        'baseRefName': 'main',
        'headRefName': 'fix/worktree-race',
      });
    });

    test('builds a forge issue attachment for issues', () {
      final attachment = buildGitHubAttachmentFromSearchItem(
        _searchItem(
          kind: ForgeSearchKind.issue,
          number: 55,
          title: 'Improve startup error details',
          url: 'https://github.com/getpaseo/paseo/issues/55',
          body: 'Issue body',
          baseRefName: null,
          headRefName: null,
        ),
      );

      expect(attachment?.toJson(), {
        'type': 'forge_issue',
        'mimeType': 'application/paseo-forge-issue',
        'forge': 'github',
        'number': 55,
        'title': 'Improve startup error details',
        'url': 'https://github.com/getpaseo/paseo/issues/55',
        'body': 'Issue body',
      });
    });

    test('returns null when no item is selected', () {
      expect(buildGitHubAttachmentFromSearchItem(null), isNull);
    });

    // --- edges the upstream suite leaves unpinned ---

    test('is the same function as buildForgeAttachmentFromSearchItem', () {
      expect(
        identical(
          buildGitHubAttachmentFromSearchItem,
          buildForgeAttachmentFromSearchItem,
        ),
        isTrue,
      );
    });

    test('keeps an explicit forge instead of defaulting to github', () {
      expect(
        buildForgeAttachmentFromSearchItem(
          _searchItem(forge: 'gitlab'),
        )?.toJson()['forge'],
        'gitlab',
      );
    });

    test('keeps an explicitly empty forge, because the default is nullish and '
        'not falsy', () {
      expect(
        buildForgeAttachmentFromSearchItem(
          _searchItem(forge: ''),
        )?.toJson()['forge'],
        '',
      );
    });

    test('omits optional fields that are null or empty', () {
      final changeRequest = buildForgeAttachmentFromSearchItem(
        _searchItem(body: '', baseRefName: '', headRefName: null),
      );
      expect(changeRequest?.toJson(), {
        'type': 'forge_change_request',
        'mimeType': 'application/paseo-forge-change-request',
        'forge': 'github',
        'number': 123,
        'title': 'Fix race in worktree setup',
        'url': 'https://github.com/getpaseo/paseo/pull/123',
      });

      final issue = buildForgeAttachmentFromSearchItem(
        _searchItem(kind: ForgeSearchKind.issue, body: null, projectPath: ''),
      );
      expect(issue?.toJson().containsKey('body'), isFalse);
      expect(issue?.toJson().containsKey('projectPath'), isFalse);
    });

    test('carries projectPath for cross-project items of both kinds', () {
      expect(
        buildForgeAttachmentFromSearchItem(
          _searchItem(projectPath: 'group/repo'),
        )?.toJson()['projectPath'],
        'group/repo',
      );
      expect(
        buildForgeAttachmentFromSearchItem(
          _searchItem(kind: ForgeSearchKind.issue, projectPath: 'group/repo'),
        )?.toJson()['projectPath'],
        'group/repo',
      );
    });

    test('exposes type and mimeType consistently with the emitted object', () {
      final attachment = buildForgeAttachmentFromSearchItem(_searchItem())!;
      expect(attachment, isA<ForgeChangeRequestAttachment>());
      expect(attachment.type, 'forge_change_request');
      expect(attachment.mimeType, 'application/paseo-forge-change-request');
      expect(attachment.toJson()['type'], attachment.type);
      expect(attachment.toJson()['mimeType'], attachment.mimeType);
    });

    test('equal search items produce equal attachments', () {
      expect(
        buildForgeAttachmentFromSearchItem(_searchItem()),
        buildForgeAttachmentFromSearchItem(_searchItem()),
      );
      expect(
        buildForgeAttachmentFromSearchItem(_searchItem())?.hashCode,
        buildForgeAttachmentFromSearchItem(_searchItem())?.hashCode,
      );
      expect(
        buildForgeAttachmentFromSearchItem(_searchItem(number: 1)),
        isNot(buildForgeAttachmentFromSearchItem(_searchItem(number: 2))),
      );
    });
  });

  group('buildLegacyGitHubAttachmentFromSearchItem', () {
    test('builds a legacy GitHub PR attachment for old daemons', () {
      final attachment = buildLegacyGitHubAttachmentFromSearchItem(
        _searchItem(),
      );

      expect(attachment?.toJson(), {
        'type': 'github_pr',
        'mimeType': 'application/github-pr',
        'number': 123,
        'title': 'Fix race in worktree setup',
        'url': 'https://github.com/getpaseo/paseo/pull/123',
        'body': 'PR body',
        'baseRefName': 'main',
        'headRefName': 'fix/worktree-race',
      });
    });

    // --- edges the upstream suite leaves unpinned ---

    test('builds a legacy GitHub issue attachment', () {
      expect(
        buildLegacyGitHubAttachmentFromSearchItem(
          _searchItem(
            kind: ForgeSearchKind.issue,
            number: 55,
            title: 'Improve startup error details',
            url: 'https://github.com/getpaseo/paseo/issues/55',
            body: 'Issue body',
            baseRefName: null,
            headRefName: null,
          ),
        )?.toJson(),
        {
          'type': 'github_issue',
          'mimeType': 'application/github-issue',
          'number': 55,
          'title': 'Improve startup error details',
          'url': 'https://github.com/getpaseo/paseo/issues/55',
          'body': 'Issue body',
        },
      );
    });

    test('returns null when no item is selected', () {
      expect(buildLegacyGitHubAttachmentFromSearchItem(null), isNull);
    });

    test('drops forge and projectPath, which old daemons cannot read', () {
      final attachment = buildLegacyGitHubAttachmentFromSearchItem(
        _searchItem(forge: 'gitlab', projectPath: 'group/repo'),
      );

      expect(attachment?.toJson().containsKey('forge'), isFalse);
      expect(attachment?.toJson().containsKey('projectPath'), isFalse);

      final issue = buildLegacyGitHubAttachmentFromSearchItem(
        _searchItem(kind: ForgeSearchKind.issue, projectPath: 'group/repo'),
      );
      expect(issue?.toJson().containsKey('projectPath'), isFalse);
    });

    test('omits blank optional fields', () {
      expect(
        buildLegacyGitHubAttachmentFromSearchItem(
          _searchItem(body: '', baseRefName: null, headRefName: ''),
        )?.toJson(),
        {
          'type': 'github_pr',
          'mimeType': 'application/github-pr',
          'number': 123,
          'title': 'Fix race in worktree setup',
          'url': 'https://github.com/getpaseo/paseo/pull/123',
        },
      );
    });
  });

  // -------------------------------------------------------------------------
  // workspace-service-routes/store.ts
  // -------------------------------------------------------------------------
  group('workspace service route preferences', () {
    test("persists each host's preferred route", () async {
      final storage = _MemoryStorage();
      final first = WorkspaceServiceRoutePreferencesStore(storage);
      await first.rehydrate();

      await first.setPreferredRoute('desktop', WorkspaceScriptLinkKind.direct);
      await first.setPreferredRoute('devbox', WorkspaceScriptLinkKind.public);

      final restored = WorkspaceServiceRoutePreferencesStore(storage);
      await restored.rehydrate();
      expect(restored.byServerId, {
        'desktop': WorkspaceScriptLinkKind.direct,
        'devbox': WorkspaceScriptLinkKind.public,
      });
    });

    test('drops invalid route kinds from persisted storage', () async {
      final storage = _MemoryStorage({
        workspaceServiceRoutePreferencesStorageName: jsonEncode({
          'state': {
            'byServerId': {'desktop': 'direct', 'broken': 'unknown'},
          },
          'version': 1,
        }),
      });
      final store = WorkspaceServiceRoutePreferencesStore(storage);
      await store.rehydrate();

      expect(store.byServerId, {'desktop': WorkspaceScriptLinkKind.direct});
    });

    // --- edges the upstream suite leaves unpinned ---

    test('starts empty and stays empty when storage has nothing', () async {
      final store = WorkspaceServiceRoutePreferencesStore(_MemoryStorage());
      expect(store.byServerId, isEmpty);
      await store.rehydrate();
      expect(store.byServerId, isEmpty);
    });

    test('writes the frozen persist envelope', () async {
      final storage = _MemoryStorage();
      final store = WorkspaceServiceRoutePreferencesStore(storage);

      await store.setPreferredRoute('desktop', WorkspaceScriptLinkKind.paseo);

      expect(
        jsonDecode(
          storage.values[workspaceServiceRoutePreferencesStorageName]!,
        ),
        {
          'state': {
            'byServerId': {'desktop': 'paseo'},
          },
          'version': 1,
        },
      );
      expect(
        workspaceServiceRoutePreferencesStorageName,
        'workspace-service-route-preferences',
      );
      expect(workspaceServiceRoutePreferencesVersion, 1);
    });

    test(
      'drops a blob stamped with an unmigratable version and reports it',
      () async {
        final messages = <String>[];
        final storage = _MemoryStorage({
          workspaceServiceRoutePreferencesStorageName: jsonEncode({
            'state': {
              'byServerId': {'desktop': 'direct'},
            },
            'version': 2,
          }),
        });
        final store = WorkspaceServiceRoutePreferencesStore(
          storage,
          onRehydrateError: messages.add,
        );

        await store.rehydrate();

        expect(store.byServerId, isEmpty);
        expect(messages, hasLength(1));
      },
    );

    test('accepts a blob with no version field at all', () async {
      // zustand only compares when `typeof version === "number"`.
      final storage = _MemoryStorage({
        workspaceServiceRoutePreferencesStorageName: jsonEncode({
          'state': {
            'byServerId': {'desktop': 'public'},
          },
        }),
      });
      final store = WorkspaceServiceRoutePreferencesStore(storage);
      await store.rehydrate();

      expect(store.byServerId, {'desktop': WorkspaceScriptLinkKind.public});
    });

    test(
      'ignores a non-numeric version rather than dropping the blob',
      () async {
        final storage = _MemoryStorage({
          workspaceServiceRoutePreferencesStorageName: jsonEncode({
            'state': {
              'byServerId': {'desktop': 'public'},
            },
            'version': '1',
          }),
        });
        final store = WorkspaceServiceRoutePreferencesStore(storage);
        await store.rehydrate();

        expect(store.byServerId, {'desktop': WorkspaceScriptLinkKind.public});
      },
    );

    test(
      'yields an empty map for blobs that are not shaped like state',
      () async {
        for (final blob in ['null', '"nope"', '5', '[1,2]', '{}', 'false']) {
          final store = WorkspaceServiceRoutePreferencesStore(
            _MemoryStorage({workspaceServiceRoutePreferencesStorageName: blob}),
          );
          await store.rehydrate();
          expect(store.byServerId, isEmpty, reason: 'blob: $blob');
        }
      },
    );

    test(
      'yields an empty map when byServerId is missing or not an object',
      () async {
        for (final state in <Object?>[null, 'direct', 7, <Object?>[]]) {
          final store = WorkspaceServiceRoutePreferencesStore(
            _MemoryStorage({
              workspaceServiceRoutePreferencesStorageName: jsonEncode({
                'state': {'byServerId': state},
                'version': 1,
              }),
            }),
          );
          await store.rehydrate();
          expect(store.byServerId, isEmpty, reason: 'byServerId: $state');
        }
      },
    );

    test('drops entries whose value is the wrong type entirely', () async {
      final storage = _MemoryStorage({
        workspaceServiceRoutePreferencesStorageName: jsonEncode({
          'state': {
            'byServerId': {
              'a': 'direct',
              'b': 1,
              'c': null,
              'd': {'kind': 'public'},
              'e': 'paseo',
            },
          },
          'version': 1,
        }),
      });
      final store = WorkspaceServiceRoutePreferencesStore(storage);
      await store.rehydrate();

      expect(store.byServerId, {
        'a': WorkspaceScriptLinkKind.direct,
        'e': WorkspaceScriptLinkKind.paseo,
      });
    });

    test('malformed JSON is not swallowed', () async {
      final store = WorkspaceServiceRoutePreferencesStore(
        _MemoryStorage({
          workspaceServiceRoutePreferencesStorageName: '{not json',
        }),
      );

      await expectLater(store.rehydrate(), throwsFormatException);
    });

    test(
      'overwriting a host keeps its position in the persisted order',
      () async {
        final storage = _MemoryStorage();
        final store = WorkspaceServiceRoutePreferencesStore(storage);

        await store.setPreferredRoute('a', WorkspaceScriptLinkKind.direct);
        await store.setPreferredRoute('b', WorkspaceScriptLinkKind.public);
        await store.setPreferredRoute('a', WorkspaceScriptLinkKind.paseo);

        expect(store.byServerId.keys, ['a', 'b']);
        expect(store.byServerId['a'], WorkspaceScriptLinkKind.paseo);
        expect(
          storage.values[workspaceServiceRoutePreferencesStorageName],
          contains('"a":"paseo"'),
        );
      },
    );

    test('rehydrating replaces anything set before it', () async {
      final storage = _MemoryStorage();
      final store = WorkspaceServiceRoutePreferencesStore(storage);
      await store.setPreferredRoute('local', WorkspaceScriptLinkKind.direct);

      storage.values[workspaceServiceRoutePreferencesStorageName] = jsonEncode({
        'state': {
          'byServerId': {'remote': 'public'},
        },
        'version': 1,
      });
      await store.rehydrate();

      expect(store.byServerId, {'remote': WorkspaceScriptLinkKind.public});
    });

    test('the exposed map cannot be mutated by callers', () async {
      final store = WorkspaceServiceRoutePreferencesStore(_MemoryStorage());
      await store.setPreferredRoute('a', WorkspaceScriptLinkKind.direct);

      expect(
        () => store.byServerId['b'] = WorkspaceScriptLinkKind.public,
        throwsUnsupportedError,
      );
    });

    test('every route kind round-trips through storage', () async {
      final storage = _MemoryStorage();
      final store = WorkspaceServiceRoutePreferencesStore(storage);
      for (final kind in WorkspaceScriptLinkKind.values) {
        await store.setPreferredRoute(kind.wireName, kind);
      }

      final restored = WorkspaceServiceRoutePreferencesStore(storage);
      await restored.rehydrate();

      expect(restored.byServerId, {
        'public': WorkspaceScriptLinkKind.public,
        'paseo': WorkspaceScriptLinkKind.paseo,
        'direct': WorkspaceScriptLinkKind.direct,
      });
    });

    test('tryFromWire accepts only the three frozen spellings', () {
      expect(
        WorkspaceScriptLinkKind.tryFromWire('public'),
        WorkspaceScriptLinkKind.public,
      );
      expect(
        WorkspaceScriptLinkKind.tryFromWire('paseo'),
        WorkspaceScriptLinkKind.paseo,
      );
      expect(
        WorkspaceScriptLinkKind.tryFromWire('direct'),
        WorkspaceScriptLinkKind.direct,
      );
      expect(WorkspaceScriptLinkKind.tryFromWire('Direct'), isNull);
      expect(WorkspaceScriptLinkKind.tryFromWire(null), isNull);
      expect(WorkspaceScriptLinkKind.tryFromWire(1), isNull);
    });
  });
}
