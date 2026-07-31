// Port of the frozen Paseo 0.2.0 suites `utils/path.test.ts`,
// `server/workspace-registry-bootstrap.test.ts`, `tasks/task-store.test.ts` and
// `server/agent/providers/provider-image-output.test.ts`.
//
// Everything that upstream exercises against a real filesystem is exercised
// against a real temp directory here too, following the pattern already
// established in `test/workspace/` — the daemon genuinely touches the disk in
// these paths and a fake would not prove the migration works.
//
// Where upstream leans on `setTimeout` to force distinct `created` timestamps,
// this suite injects a ticking clock instead: same ordering guarantee, no
// wall-clock dependency.
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/server/paseo_registry_bootstrap.dart';
import 'package:agent_daemon/src/services/paseo_quota_and_tasks.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Shared fixtures
// ---------------------------------------------------------------------------

/// Advances one second per read, so ordering assertions never depend on how
/// fast the host filesystem is.
final class TickingClock {
  TickingClock([DateTime? start])
    : _next = start ?? DateTime.utc(2026, 3, 1, 12);

  DateTime _next;

  DateTime call() {
    final current = _next;
    _next = _next.add(const Duration(seconds: 1));
    return current;
  }
}

String _iso(String value) => value;

PersistedAgent _agentRecord({
  required String id,
  required String cwd,
  required String createdAt,
  String? updatedAt,
  String? archivedAt,
  String? workspaceId,
}) => PersistedAgent(
  summary: AgentSummary(
    agentId: id,
    title: id,
    cwd: cwd,
    provider: 'codex',
    model: 'gpt-5-codex',
    mode: AgentMode.normal,
    runState: AgentRunState.idle,
    createdAtMs: DateTime.parse(createdAt).millisecondsSinceEpoch,
    updatedAt: updatedAt,
    archivedAt: archivedAt,
    workspaceId: workspaceId,
  ),
  archived: archivedAt != null,
  epoch: 1,
  lastSeq: 0,
  items: const [],
);

Future<ProjectCheckoutLite> _noopCheckout(String cwd) async =>
    ProjectCheckoutLite(cwd: cwd, isGit: false);

void main() {
  // -------------------------------------------------------------------------
  // utils/path.ts
  // -------------------------------------------------------------------------
  group('path equivalence', () {
    const windowsEquivalents = <List<String>>[
      [
        r'C:/Users/Administrator/GhostFactory',
        r'C:\Users\Administrator\GhostFactory',
      ],
      [r'd:\Projects\paseo', r'D:\Projects\paseo'],
      [
        r'C:\Users\Administrator\GhostFactory\',
        r'C:\Users\Administrator\GhostFactory',
      ],
      [
        r'\\?\C:\Users\Administrator\GhostFactory',
        r'C:\Users\Administrator\GhostFactory',
      ],
      [r'\\?\UNC\server\share\GhostFactory', r'\\server\share\GhostFactory'],
    ];

    for (final pair in windowsEquivalents) {
      test('matches Windows-equivalent cwd forms: ${pair[0]}', () {
        expect(areEquivalentPathStrings(pair[0], pair[1]), isTrue);
        expect(createPathEquivalenceMatcher(pair[0])(pair[1]), isTrue);
        // The matcher must also work when the *target* is the POSIX-looking
        // side, which is the branch that re-normalizes the target.
        expect(createPathEquivalenceMatcher(pair[1])(pair[0]), isTrue);
      });
    }

    test('keeps POSIX path casing significant', () {
      expect(
        areEquivalentPathStrings(
          '/Users/Administrator/GhostFactory',
          '/users/administrator/ghostfactory',
        ),
        isFalse,
      );
    });

    test('ignores trailing separators and dot segments on POSIX', () {
      expect(areEquivalentPathStrings('/opt/paseo/', '/opt/paseo'), isTrue);
      expect(areEquivalentPathStrings('/opt/./paseo', '/opt/paseo'), isTrue);
      expect(areEquivalentPathStrings('/opt/x/../paseo', '/opt/paseo'), isTrue);
    });

    test('never collapses the filesystem root away', () {
      expect(areEquivalentPathStrings('/', '/'), isTrue);
      expect(areEquivalentPathStrings('/', '/opt'), isFalse);
    });

    test('checks POSIX root containment without prefix false positives', () {
      expect(
        isPathInsideRoot(
          '/opt/paseo',
          '/opt/paseo/node_modules/@getpaseo/server',
        ),
        isTrue,
      );
      expect(isPathInsideRoot('/opt/paseo', '/opt/paseo-other'), isFalse);
    });

    test('treats the root itself as inside the root', () {
      expect(isPathInsideRoot('/opt/paseo', '/opt/paseo'), isTrue);
      expect(getRealpathAwareRelativePath('/opt/paseo', '/opt/paseo'), '');
    });

    test('checks Windows root containment case-insensitively', () {
      expect(
        isPathInsideRoot(
          r'C:\Paseo\node_modules',
          'c:/paseo/node_modules/@getpaseo/server',
        ),
        isTrue,
      );
      expect(
        isPathInsideRoot(
          r'C:\Paseo\node_modules',
          r'C:\Paseo\node_modules-other',
        ),
        isFalse,
      );
    });

    test('rejects a candidate on another Windows drive', () {
      expect(isPathInsideRoot(r'C:\Paseo', r'D:\Paseo\nested'), isFalse);
    });

    test('returns the contained suffix for a plain nested path', () {
      expect(
        getRealpathAwareRelativePath('/opt/paseo', '/opt/paseo/packages/app'),
        p.posix.join('packages', 'app'),
      );
      expect(getRealpathAwareRelativePath('/opt/paseo', '/opt/other'), isNull);
    });

    test(
      'derives the contained suffix from a realpath-equivalent root',
      () {
        final tempDir = Directory.systemTemp.createTempSync('paseo-path-');
        try {
          final realRoot = p.join(tempDir.path, 'real-root');
          final nestedPath = p.join(realRoot, 'packages', 'app');
          final aliasRoot = p.join(tempDir.path, 'root-alias');
          Directory(nestedPath).createSync(recursive: true);
          Link(aliasRoot).createSync(realRoot);

          expect(
            getRealpathAwareRelativePath(aliasRoot, nestedPath),
            p.join('packages', 'app'),
          );
          expect(getRealpathAwareRelativePath(aliasRoot, tempDir.path), isNull);
          expect(createRealpathAwarePathMatcher(aliasRoot)(realRoot), isTrue);
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
      // Upstream skips this on win32: creating a directory symlink there needs
      // developer mode or elevation.
      skip: Platform.isWindows ? 'symlinks require elevation on Windows' : null,
    );

    test('realpath-aware matcher falls back to string comparison', () {
      // Neither path exists, so there are no symlink variants to compare.
      expect(
        createRealpathAwarePathMatcher(r'C:/nowhere/x')(r'C:\NOWHERE\x'),
        isTrue,
      );
      expect(
        createRealpathAwarePathMatcher('/nowhere/x')('/nowhere/y'),
        isFalse,
      );
    });
  });

  group('expandTilde', () {
    test('expands a bare tilde to the home directory', () {
      expect(expandTilde('~', homeDirectory: '/home/ada'), '/home/ada');
    });

    test('expands a tilde-slash prefix', () {
      expect(
        expandTilde('~/projects/paseo', homeDirectory: '/home/ada'),
        '/home/ada/projects/paseo',
      );
    });

    test('leaves other paths untouched', () {
      expect(expandTilde('~ada/x', homeDirectory: '/home/ada'), '~ada/x');
      expect(expandTilde('/opt/~/x', homeDirectory: '/home/ada'), '/opt/~/x');
      expect(
        expandTilde('relative/path', homeDirectory: '/home/ada'),
        'relative/path',
      );
    });
  });

  // -------------------------------------------------------------------------
  // utils/git-rev-parse-path.ts
  // -------------------------------------------------------------------------
  group('parseGitRevParsePath', () {
    test('returns the single trimmed line git printed', () {
      expect(parseGitRevParsePath('  /repo/root\n'), '/repo/root');
      expect(parseGitRevParsePath('/repo/root\r\n'), '/repo/root');
    });

    test('rejects the shapes git uses to mean "no answer"', () {
      expect(parseGitRevParsePath(''), isNull);
      expect(parseGitRevParsePath('   \n  '), isNull);
      expect(parseGitRevParsePath('/a\n/b\n'), isNull);
      expect(parseGitRevParsePath('--git-dir\n'), isNull);
    });

    test('resolves a relative answer against the command cwd', () {
      final cwd = p.join(Directory.systemTemp.path, 'repo');
      expect(
        resolveGitRevParsePath(cwd, '.git\n'),
        p.normalize(p.join(cwd, '.git')),
      );
      expect(resolveGitRevParsePath(cwd, '\n'), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // workspace-registry-bootstrap-legacy.ts
  // -------------------------------------------------------------------------
  group('classifyDirectoryForProjectMembership', () {
    test('classifies a plain directory as a non-git project', () {
      final membership = classifyDirectoryForProjectMembership(
        cwd: p.join(p.rootPrefix(Directory.current.path), 'work', 'notes'),
        checkout: ProjectCheckoutLite(
          cwd: p.join(p.rootPrefix(Directory.current.path), 'work', 'notes'),
          isGit: false,
        ),
      );

      expect(membership.projectKind, PersistedProjectKind.nonGit);
      expect(membership.workspaceKind, PersistedWorkspaceKind.directory);
      expect(membership.workspaceDisplayName, 'notes');
      expect(membership.projectName, 'notes');
      expect(membership.projectKey, membership.cwd);
      expect(membership.projectRootPath, membership.cwd);
      expect(membership.workspaceDirectoryKey, membership.cwd);
    });

    test('groups a checkout and its worktree under one remote project', () {
      final main = p.join(p.rootPrefix(Directory.current.path), 'src', 'repo');
      final worktree = p.join(
        p.rootPrefix(Directory.current.path),
        'src',
        'repo-feature',
      );

      final mainMembership = classifyDirectoryForProjectMembership(
        cwd: main,
        checkout: ProjectCheckoutLite(
          cwd: main,
          isGit: true,
          currentBranch: 'main',
          remoteUrl: 'git@github.com:acme/legacy-project.git',
          worktreeRoot: main,
        ),
      );
      final worktreeMembership = classifyDirectoryForProjectMembership(
        cwd: worktree,
        checkout: ProjectCheckoutLite(
          cwd: worktree,
          isGit: true,
          currentBranch: 'feature/plain',
          remoteUrl: 'git@github.com:acme/legacy-project.git',
          worktreeRoot: worktree,
          mainRepoRoot: main,
        ),
      );

      expect(
        mainMembership.projectKey,
        'remote:github.com/acme/legacy-project',
      );
      expect(worktreeMembership.projectKey, mainMembership.projectKey);
      expect(mainMembership.projectName, 'acme/legacy-project');
      expect(
        mainMembership.workspaceKind,
        PersistedWorkspaceKind.localCheckout,
      );
      expect(worktreeMembership.workspaceKind, PersistedWorkspaceKind.worktree);
      expect(worktreeMembership.projectRootPath, main);
      expect(worktreeMembership.workspaceDisplayName, 'feature/plain');
    });

    test('parses https and ssh remotes into the same project key', () {
      String keyFor(String remote) => classifyDirectoryForProjectMembership(
        cwd: p.join(p.rootPrefix(Directory.current.path), 'src', 'repo'),
        checkout: ProjectCheckoutLite(
          cwd: p.join(p.rootPrefix(Directory.current.path), 'src', 'repo'),
          isGit: true,
          remoteUrl: remote,
        ),
      ).projectKey;

      expect(
        keyFor('https://GitHub.com/acme/legacy-project.git'),
        'remote:github.com/acme/legacy-project',
      );
      expect(
        keyFor('ssh://git@github.com/acme/legacy-project'),
        'remote:github.com/acme/legacy-project',
      );
    });

    test('falls back to a path key for unusable remotes', () {
      final cwd = p.join(p.rootPrefix(Directory.current.path), 'src', 'repo');
      String keyFor(String? remote, {String? mainRepoRoot}) =>
          classifyDirectoryForProjectMembership(
            cwd: cwd,
            checkout: ProjectCheckoutLite(
              cwd: cwd,
              isGit: true,
              remoteUrl: remote,
              mainRepoRoot: mainRepoRoot,
            ),
          ).projectKey;

      // A single-segment remote path cannot identify a repository.
      expect(keyFor('https://example.com/repo.git'), cwd);
      // Neither scp-like nor a URL.
      expect(keyFor('not-a-remote'), cwd);
      expect(keyFor(''), cwd);
      // With no remote, the main repo root groups worktrees together.
      final mainRoot = p.join(
        p.rootPrefix(Directory.current.path),
        'src',
        'main',
      );
      expect(keyFor(null, mainRepoRoot: mainRoot), mainRoot);
    });

    test('detached HEAD falls back to the directory name', () {
      final cwd = p.join(p.rootPrefix(Directory.current.path), 'src', 'repo');
      final membership = classifyDirectoryForProjectMembership(
        cwd: cwd,
        checkout: ProjectCheckoutLite(
          cwd: cwd,
          isGit: true,
          currentBranch: 'HEAD',
        ),
      );
      expect(membership.workspaceDisplayName, 'repo');
    });

    test('an empty mainRepoRoot reads as no main repo', () {
      // Upstream relies on JS truthiness here; the port must not treat "" as a
      // worktree parent.
      expect(
        deriveWorkspaceKind(
          const ProjectCheckoutLite(cwd: '/x', isGit: true, mainRepoRoot: ''),
        ),
        PersistedWorkspaceKind.localCheckout,
      );
      expect(
        deriveProjectKind(const ProjectCheckoutLite(cwd: '/x', isGit: false)),
        PersistedProjectKind.nonGit,
      );
    });

    test('collapses subdirectories of one worktree onto one directory key', () {
      final root = p.join(p.rootPrefix(Directory.current.path), 'src', 'repo');
      final nested = p.join(root, 'packages', 'app');

      final rootKey = classifyDirectoryForProjectMembership(
        cwd: root,
        checkout: ProjectCheckoutLite(
          cwd: root,
          isGit: true,
          worktreeRoot: root,
        ),
      ).workspaceDirectoryKey;
      final nestedKey = classifyDirectoryForProjectMembership(
        cwd: nested,
        checkout: ProjectCheckoutLite(
          cwd: nested,
          isGit: true,
          worktreeRoot: root,
        ),
      ).workspaceDirectoryKey;

      expect(nestedKey, rootKey);
    });
  });

  // -------------------------------------------------------------------------
  // workspace-registry-bootstrap.ts
  // -------------------------------------------------------------------------
  group('bootstrapWorkspaceRegistries', () {
    late Directory tempDir;
    late String paseoHome;
    late String nonGitProject;
    late String archivedProject;
    late String gitProject;
    late String gitWorktree;
    late AgentStore agentStore;
    late FileBackedProjectRegistry projectRegistry;
    late FileBackedWorkspaceRegistry workspaceRegistry;
    late List<({String message, Map<String, Object?> fields})> logLines;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('workspace-bootstrap-');
      nonGitProject = p.join(tempDir.path, 'non-git-project');
      archivedProject = p.join(tempDir.path, 'archived-project');
      gitProject = p.join(tempDir.path, 'legacy-git-project');
      gitWorktree = p.join(tempDir.path, 'legacy-git-project-feature');
      paseoHome = p.join(tempDir.path, '.paseo');
      agentStore = AgentStore(dataDir: p.join(paseoHome, 'agents'));
      projectRegistry = FileBackedProjectRegistry(
        filePath: p.join(paseoHome, 'projects', 'projects.json'),
      );
      workspaceRegistry = FileBackedWorkspaceRegistry(
        filePath: p.join(paseoHome, 'projects', 'workspaces.json'),
      );
      logLines = [];
      for (final directory in [
        nonGitProject,
        archivedProject,
        gitProject,
        gitWorktree,
      ]) {
        Directory(directory).createSync(recursive: true);
      }
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Future<RegistryBootstrapSummary> runBootstrap({
      WorkspaceCheckoutProbe? getCheckout,
      String Function()? workspaceIdFactory,
    }) => bootstrapWorkspaceRegistries(
      paseoHome: paseoHome,
      agentStore: agentStore,
      projectRegistry: projectRegistry,
      workspaceRegistry: workspaceRegistry,
      getCheckout: getCheckout ?? _noopCheckout,
      workspaceIdFactory: workspaceIdFactory,
      homeDirectory: p.join(tempDir.path, 'home'),
      log: (message, fields) =>
          logLines.add((message: message, fields: fields)),
    );

    Future<PersistedAgent?> loadAgent(String id) async {
      final records = await agentStore.loadAll();
      for (final record in records) {
        if (record.summary.agentId == id) return record;
      }
      return null;
    }

    test('skips a legacy agent whose directory no longer exists', () async {
      await agentStore.save(
        _agentRecord(
          id: 'agent-missing-directory',
          cwd: p.join(tempDir.path, 'missing-project'),
          createdAt: '2026-03-01T00:00:00.000Z',
          updatedAt: '2026-03-01T00:00:00.000Z',
        ),
      );

      final summary = await runBootstrap(
        getCheckout: (_) async =>
            throw StateError('Git must not inspect a missing directory'),
      );

      expect(await projectRegistry.list(), isEmpty);
      expect(await workspaceRegistry.list(), isEmpty);
      expect(summary.materializedWorkspaces, 0);
    });

    test('skips a legacy agent whose cwd is a file', () async {
      final cwd = p.join(tempDir.path, 'not-a-directory');
      File(cwd).writeAsStringSync('not a directory');
      await agentStore.save(
        _agentRecord(
          id: 'agent-file-cwd',
          cwd: cwd,
          createdAt: '2026-03-01T00:00:00.000Z',
          updatedAt: '2026-03-01T00:00:00.000Z',
        ),
      );

      await runBootstrap(
        getCheckout: (_) async =>
            throw StateError('Git must not inspect a file'),
      );

      expect(await projectRegistry.list(), isEmpty);
      expect(await workspaceRegistry.list(), isEmpty);
    });

    test('propagates a Git failure for an existing legacy directory', () async {
      final gitFailure = StateError('Git is unavailable');
      await agentStore.save(
        _agentRecord(
          id: 'agent-existing-directory',
          cwd: nonGitProject,
          createdAt: '2026-03-01T00:00:00.000Z',
          updatedAt: '2026-03-01T00:00:00.000Z',
        ),
      );

      await expectLater(
        runBootstrap(getCheckout: (_) async => throw gitFailure),
        throwsA(same(gitFailure)),
      );
    });

    test('materializes registries from non-archived agent records', () async {
      await agentStore.save(
        _agentRecord(
          id: 'agent-1',
          cwd: nonGitProject,
          createdAt: '2026-03-01T00:00:00.000Z',
          updatedAt: _iso('2026-03-02T00:00:00.000Z'),
        ),
      );
      await agentStore.save(
        _agentRecord(
          id: 'agent-2',
          cwd: nonGitProject,
          createdAt: '2026-03-01T01:00:00.000Z',
          updatedAt: _iso('2026-03-03T00:00:00.000Z'),
        ),
      );
      await agentStore.save(
        _agentRecord(
          id: 'agent-archived',
          cwd: archivedProject,
          createdAt: '2026-03-01T00:00:00.000Z',
          updatedAt: '2026-03-01T00:00:00.000Z',
          archivedAt: '2026-03-02T00:00:00.000Z',
        ),
      );

      final summary = await runBootstrap();

      final workspaces = await workspaceRegistry.list();
      expect(workspaces, hasLength(1));
      expect(
        workspaces.single.workspaceId,
        matches(RegExp(r'^wks_[0-9a-f]{16}$')),
      );
      expect(workspaces.single.cwd, nonGitProject);
      // Oldest creation across the group, newest update across the group.
      expect(workspaces.single.createdAt, '2026-03-01T00:00:00.000Z');
      expect(workspaces.single.updatedAt, '2026-03-03T00:00:00.000Z');

      final projects = await projectRegistry.list();
      expect(projects, hasLength(1));
      expect(projects.single.projectId, nonGitProject);
      expect(projects.single.createdAt, '2026-03-01T00:00:00.000Z');
      expect(projects.single.updatedAt, '2026-03-03T00:00:00.000Z');

      expect(summary.materializedProjects, 1);
      expect(summary.materializedWorkspaces, 1);
      expect(summary.skippedBecauseRegistriesExisted, isFalse);
      expect(
        logLines.map((line) => line.message),
        contains(
          'Workspace registries bootstrapped from existing agent storage',
        ),
      );
      final bootstrapLog = logLines
          .firstWhere(
            (line) =>
                line.message.startsWith('Workspace registries bootstrapped'),
          )
          .fields;
      expect(
        bootstrapLog['projectsFile'],
        p.join(paseoHome, 'projects', 'projects.json'),
      );
      expect(bootstrapLog['materializedWorkspaces'], 1);
    });

    test('does not rematerialize when registry files already exist', () async {
      await projectRegistry.initialize();
      await workspaceRegistry.initialize();
      await projectRegistry.upsert(
        createPersistedProjectRecord(
          projectId: 'proj-existing',
          rootPath: p.join(tempDir.path, 'existing'),
          kind: PersistedProjectKind.nonGit,
          displayName: 'existing',
          createdAt: '2026-03-01T00:00:00.000Z',
          updatedAt: '2026-03-01T00:00:00.000Z',
        ),
      );
      await workspaceRegistry.upsert(
        createPersistedWorkspaceRecord(
          workspaceId: 'ws-existing',
          projectId: 'proj-existing',
          cwd: p.join(tempDir.path, 'existing'),
          kind: PersistedWorkspaceKind.directory,
          displayName: 'existing',
          createdAt: '2026-03-01T00:00:00.000Z',
          updatedAt: '2026-03-01T00:00:00.000Z',
        ),
      );

      await agentStore.save(
        _agentRecord(
          id: 'agent-1',
          cwd: p.join(tempDir.path, 'another-project'),
          createdAt: '2026-03-02T00:00:00.000Z',
          updatedAt: '2026-03-02T00:00:00.000Z',
        ),
      );

      final summary = await runBootstrap();

      expect(summary.skippedBecauseRegistriesExisted, isTrue);
      expect(await projectRegistry.list(), hasLength(1));
      final workspaces = await workspaceRegistry.list();
      expect(workspaces, hasLength(1));
      expect(workspaces.single.workspaceId, 'ws-existing');
    });

    test(
      'materializes legacy remote worktrees into one readable project',
      () async {
        Future<ProjectCheckoutLite> getCheckout(String cwd) async =>
            ProjectCheckoutLite(
              cwd: cwd,
              isGit: true,
              currentBranch: cwd == gitProject ? 'main' : 'feature/plain',
              remoteUrl: 'git@github.com:acme/legacy-project.git',
              worktreeRoot: cwd,
              mainRepoRoot: cwd == gitProject ? null : gitProject,
            );

        for (final entry in [
          ('main-agent', gitProject),
          ('worktree-agent', gitWorktree),
        ]) {
          await agentStore.save(
            _agentRecord(
              id: entry.$1,
              cwd: entry.$2,
              createdAt: '2026-03-01T00:00:00.000Z',
              updatedAt: '2026-03-02T00:00:00.000Z',
            ),
          );
        }

        await runBootstrap(getCheckout: getCheckout);

        final projects = await projectRegistry.list();
        expect(projects, hasLength(1));
        expect(
          projects.single.projectId,
          'remote:github.com/acme/legacy-project',
        );
        expect(projects.single.rootPath, gitProject);
        expect(projects.single.kind, PersistedProjectKind.git);
        expect(projects.single.displayName, 'acme/legacy-project');

        final workspaces = (await workspaceRegistry.list()).toList()
          ..sort((left, right) => left.cwd.compareTo(right.cwd));
        expect(
          workspaces
              .map(
                (workspace) => [
                  workspace.projectId,
                  workspace.cwd,
                  workspace.kind,
                  workspace.displayName,
                ],
              )
              .toList(),
          [
            [
              'remote:github.com/acme/legacy-project',
              gitProject,
              PersistedWorkspaceKind.localCheckout,
              'main',
            ],
            [
              'remote:github.com/acme/legacy-project',
              gitWorktree,
              PersistedWorkspaceKind.worktree,
              'feature/plain',
            ],
          ],
        );
      },
    );

    test(
      'migrates cwd-only agents to the oldest existing same-cwd workspace',
      () async {
        await projectRegistry.initialize();
        await workspaceRegistry.initialize();
        await projectRegistry.upsert(
          createPersistedProjectRecord(
            projectId: nonGitProject,
            rootPath: nonGitProject,
            kind: PersistedProjectKind.nonGit,
            displayName: 'non-git-project',
            createdAt: '2026-03-01T00:00:00.000Z',
            updatedAt: '2026-03-01T00:00:00.000Z',
          ),
        );
        await workspaceRegistry.upsert(
          createPersistedWorkspaceRecord(
            workspaceId: 'ws-newer',
            projectId: nonGitProject,
            cwd: nonGitProject,
            kind: PersistedWorkspaceKind.directory,
            displayName: 'newer',
            createdAt: '2026-03-02T00:00:00.000Z',
            updatedAt: '2026-03-02T00:00:00.000Z',
          ),
        );
        await workspaceRegistry.upsert(
          createPersistedWorkspaceRecord(
            workspaceId: 'ws-older',
            projectId: nonGitProject,
            cwd: nonGitProject,
            kind: PersistedWorkspaceKind.directory,
            displayName: 'older',
            createdAt: '2026-03-01T00:00:00.000Z',
            updatedAt: '2026-03-01T00:00:00.000Z',
          ),
        );

        await agentStore.save(
          _agentRecord(
            id: 'legacy-agent',
            cwd: nonGitProject,
            createdAt: '2026-03-01T12:00:00.000Z',
            updatedAt: '2026-03-01T12:00:00.000Z',
          ),
        );

        final summary = await runBootstrap();

        expect(
          (await loadAgent('legacy-agent'))?.summary.workspaceId,
          'ws-older',
        );
        expect(await workspaceRegistry.list(), hasLength(2));
        expect(summary.backfilledAgents, 1);
      },
    );

    test(
      'migrated legacy agents keep their owner when a same-cwd workspace is added later',
      () async {
        await projectRegistry.initialize();
        await workspaceRegistry.initialize();
        await projectRegistry.upsert(
          createPersistedProjectRecord(
            projectId: nonGitProject,
            rootPath: nonGitProject,
            kind: PersistedProjectKind.nonGit,
            displayName: 'non-git-project',
            createdAt: '2026-03-01T00:00:00.000Z',
            updatedAt: '2026-03-01T00:00:00.000Z',
          ),
        );
        await workspaceRegistry.upsert(
          createPersistedWorkspaceRecord(
            workspaceId: 'ws-original-owner',
            projectId: nonGitProject,
            cwd: nonGitProject,
            kind: PersistedWorkspaceKind.directory,
            displayName: 'original',
            createdAt: '2026-03-01T00:00:00.000Z',
            updatedAt: '2026-03-01T00:00:00.000Z',
          ),
        );

        await agentStore.save(
          _agentRecord(
            id: 'legacy-agent',
            cwd: nonGitProject,
            createdAt: '2026-03-01T12:00:00.000Z',
            updatedAt: '2026-03-01T12:00:00.000Z',
          ),
        );

        await runBootstrap();
        await workspaceRegistry.upsert(
          createPersistedWorkspaceRecord(
            workspaceId: 'ws-created-later',
            projectId: nonGitProject,
            cwd: nonGitProject,
            kind: PersistedWorkspaceKind.directory,
            displayName: 'created later',
            createdAt: '2026-03-04T00:00:00.000Z',
            updatedAt: '2026-03-04T00:00:00.000Z',
          ),
        );
        final second = await runBootstrap();

        expect(
          (await loadAgent('legacy-agent'))?.summary.workspaceId,
          'ws-original-owner',
        );
        expect(second.backfilledAgents, 0);
        expect(
          (await workspaceRegistry.get('ws-created-later'))?.cwd,
          nonGitProject,
        );
      },
    );

    test(
      'preserves existing workspace IDs when only the projects file is missing',
      () async {
        await workspaceRegistry.initialize();
        await workspaceRegistry.upsert(
          createPersistedWorkspaceRecord(
            workspaceId: 'ws-existing',
            projectId: nonGitProject,
            cwd: nonGitProject,
            kind: PersistedWorkspaceKind.directory,
            displayName: 'non-git-project',
            createdAt: '2026-03-01T00:00:00.000Z',
            updatedAt: '2026-03-01T00:00:00.000Z',
          ),
        );

        await agentStore.save(
          _agentRecord(
            id: 'agent-1',
            cwd: nonGitProject,
            createdAt: '2026-03-02T00:00:00.000Z',
            updatedAt: '2026-03-02T00:00:00.000Z',
          ),
        );

        await runBootstrap(
          workspaceIdFactory: () =>
              fail('a fresh workspace id must not be minted'),
        );

        final workspaces = await workspaceRegistry.list();
        expect(workspaces, hasLength(1));
        expect(workspaces.single.workspaceId, 'ws-existing');
        expect(workspaces.single.cwd, nonGitProject);

        final projects = await projectRegistry.list();
        expect(projects, hasLength(1));
        expect(projects.single.projectId, nonGitProject);
      },
    );

    test(
      'collapses two agents in one worktree into a single workspace',
      () async {
        final nested = p.join(gitProject, 'packages', 'app');
        Directory(nested).createSync(recursive: true);

        Future<ProjectCheckoutLite> getCheckout(String cwd) async =>
            ProjectCheckoutLite(
              cwd: cwd,
              isGit: true,
              currentBranch: 'main',
              worktreeRoot: gitProject,
            );

        await agentStore.save(
          _agentRecord(
            id: 'root-agent',
            cwd: gitProject,
            createdAt: '2026-03-01T00:00:00.000Z',
            updatedAt: '2026-03-01T00:00:00.000Z',
          ),
        );
        await agentStore.save(
          _agentRecord(
            id: 'nested-agent',
            cwd: nested,
            createdAt: '2026-03-02T00:00:00.000Z',
            updatedAt: '2026-03-02T00:00:00.000Z',
          ),
        );

        final summary = await runBootstrap(getCheckout: getCheckout);

        expect(summary.materializedWorkspaces, 1);
        final workspaces = await workspaceRegistry.list();
        expect(workspaces, hasLength(1));
        // The first record to claim the directory key fixes the workspace cwd.
        expect(workspaces.single.cwd, gitProject);
        expect(workspaces.single.createdAt, '2026-03-01T00:00:00.000Z');
        expect(workspaces.single.updatedAt, '2026-03-02T00:00:00.000Z');
      },
    );
  });

  // -------------------------------------------------------------------------
  // tasks/task-document.ts + tasks/task-store.ts
  // -------------------------------------------------------------------------
  group('FileTaskStore', () {
    late Directory tempDir;
    late FileTaskStore store;
    late TickingClock clock;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('task-store-test-');
      clock = TickingClock();
      store = FileTaskStore(tempDir.path, clock: clock);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    group('create', () {
      test('creates a task with default status open', () async {
        final task = await store.create('My first task');

        expect(task.id, matches(RegExp(r'^[a-f0-9]{8}$')));
        expect(task.title, 'My first task');
        expect(task.status, TaskStatus.open);
        expect(task.deps, isEmpty);
        expect(task.parentId, isNull);
        expect(task.body, '');
        expect(task.notes, isEmpty);
        expect(task.created, matches(RegExp(r'^\d{4}-\d{2}-\d{2}T')));
        expect(task.assignee, isNull);
        expect(task.priority, isNull);
      });

      test(
        'creates a task with priority, status, deps, body and assignee',
        () async {
          final dep1 = await store.create('Dependency 1');
          final dep2 = await store.create('Dependency 2');
          final task = await store.create(
            'Main task',
            CreateTaskOptions(
              deps: [dep1.id, dep2.id],
              status: TaskStatus.draft,
              body: 'This is a **long** body\n\nWith multiple lines.',
              assignee: 'claude',
              priority: 1,
            ),
          );

          expect(task.deps, [dep1.id, dep2.id]);
          expect(task.status, TaskStatus.draft);
          expect(task.body, 'This is a **long** body\n\nWith multiple lines.');
          expect(task.assignee, 'claude');
          expect(task.priority, 1);
        },
      );

      test('creates a task with parentId', () async {
        final parent = await store.create('Parent task');
        final child = await store.create(
          'Child task',
          CreateTaskOptions(parentId: parent.id),
        );

        expect(child.parentId, parent.id);
      });

      test('throws when creating a task with a non-existent parent', () async {
        expect(
          () => store.create(
            'Child',
            const CreateTaskOptions(parentId: 'nonexistent'),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('Parent task not found'),
            ),
          ),
        );
      });

      test('generates unique IDs for each task', () async {
        final ids = {
          (await store.create('Task 1')).id,
          (await store.create('Task 2')).id,
          (await store.create('Task 3')).id,
        };

        expect(ids, hasLength(3));
      });

      test(
        'sets a created timestamp between the surrounding clock reads',
        () async {
          final realClockStore = FileTaskStore(tempDir.path);
          final before = DateTime.now().toUtc();
          final task = await realClockStore.create('Task');
          final after = DateTime.now().toUtc();

          final created = DateTime.parse(task.created);
          expect(
            created.isBefore(before.subtract(const Duration(seconds: 1))),
            isFalse,
          );
          expect(
            created.isAfter(after.add(const Duration(seconds: 1))),
            isFalse,
          );
          // JS `toISOString()` shape: exactly three fractional digits, UTC.
          expect(
            task.created,
            matches(RegExp(r'^\d{4}-\d{2}-\d{2}T[\d:]{8}\.\d{3}Z$')),
          );
        },
      );

      test('returns the task with its raw document filled in', () async {
        final task = await store.create(
          'Test task',
          const CreateTaskOptions(
            body: 'Task body here',
            acceptanceCriteria: ['criterion 1', 'criterion 2'],
          ),
        );

        expect(task.raw, contains('---'));
        expect(task.raw, contains('title: Test task'));
        expect(task.raw, contains('Task body here'));
        expect(task.raw, contains('## Acceptance Criteria'));
        expect(task.raw, contains('criterion 1'));
        expect(task.raw, contains('criterion 2'));
      });
    });

    group('get and list', () {
      test('returns a task by id and null for an unknown id', () async {
        final created = await store.create('Test task');
        final retrieved = await store.get(created.id);

        expect(retrieved?.id, created.id);
        expect(retrieved?.title, created.title);
        expect(retrieved?.raw, created.raw);
        expect(await store.get('nonexistent'), isNull);
      });

      test('returns raw content matching the file', () async {
        final created = await store.create(
          'Task with body',
          const CreateTaskOptions(
            body: 'Some body content',
            acceptanceCriteria: ['test passes', 'lint passes'],
          ),
        );
        await store.addNote(created.id, 'A note was added');

        final retrieved = await store.get(created.id);

        expect(retrieved?.raw, contains('title: Task with body'));
        expect(retrieved?.raw, contains('Some body content'));
        expect(retrieved?.raw, contains('## Acceptance Criteria'));
        expect(retrieved?.raw, contains('test passes'));
        expect(retrieved?.raw, contains('## Notes'));
        expect(retrieved?.raw, contains('A note was added'));
      });

      test('returns an empty list when there are no tasks', () async {
        expect(await store.list(), isEmpty);
      });

      test('returns all tasks oldest first', () async {
        final first = await store.create('Task 1');
        final second = await store.create('Task 2');
        final third = await store.create('Task 3');

        expect((await store.list()).map((task) => task.id).toList(), [
          first.id,
          second.id,
          third.id,
        ]);
      });
    });

    group('update', () {
      test('updates fields and persists them', () async {
        final task = await store.create('Original title');
        final updated = await store.update(
          task.id,
          const TaskChanges(
            title: 'New title',
            body: 'New body',
            assignee: 'claude',
          ),
        );

        expect(updated.title, 'New title');
        expect(updated.id, task.id);
        expect(updated.body, 'New body');
        expect(updated.assignee, 'claude');
        expect((await store.get(task.id))?.title, 'New title');
      });

      test('preserves the created timestamp on update', () async {
        final task = await store.create('Task');
        await store.update(task.id, const TaskChanges(title: 'Updated'));

        expect((await store.get(task.id))?.created, task.created);
      });

      test('throws for a non-existent task', () {
        expect(
          () => store.update('nonexistent', const TaskChanges(title: 'New')),
          throwsA(isA<StateError>()),
        );
      });

      test('replaces and clears acceptance criteria', () async {
        final task = await store.create(
          'Task',
          const CreateTaskOptions(
            acceptanceCriteria: ['old criterion 1', 'old criterion 2'],
          ),
        );

        expect(
          (await store.update(
            task.id,
            const TaskChanges(acceptanceCriteria: ['new criterion']),
          )).acceptanceCriteria,
          ['new criterion'],
        );
        expect(
          (await store.update(
            task.id,
            const TaskChanges(acceptanceCriteria: []),
          )).acceptanceCriteria,
          isEmpty,
        );
      });

      test(
        'leaves omitted nullable fields alone but honours an explicit null',
        () async {
          final parent = await store.create('Parent');
          final task = await store.create(
            'Task',
            CreateTaskOptions(
              parentId: parent.id,
              assignee: 'claude',
              priority: 3,
            ),
          );

          final untouched = await store.update(
            task.id,
            const TaskChanges(title: 'T'),
          );
          expect(untouched.parentId, parent.id);
          expect(untouched.assignee, 'claude');
          expect(untouched.priority, 3);

          final cleared = await store.update(
            task.id,
            const TaskChanges(parentId: null, assignee: null, priority: null),
          );
          expect(cleared.parentId, isNull);
          expect(cleared.assignee, isNull);
          expect(cleared.priority, isNull);
        },
      );

      test('returns the pre-update raw document, matching upstream', () async {
        final task = await store.create('Original');
        final updated = await store.update(
          task.id,
          const TaskChanges(title: 'Renamed'),
        );

        // Upstream spreads the in-memory task rather than re-reading the file.
        expect(updated.raw, task.raw);
        expect((await store.get(task.id))?.raw, contains('title: Renamed'));
      });
    });

    group('delete', () {
      test('deletes a task and removes it from the list', () async {
        final first = await store.create('Task 1');
        final second = await store.create('Task 2');
        await store.delete(first.id);

        expect(await store.get(first.id), isNull);
        expect((await store.list()).map((task) => task.id).toList(), [
          second.id,
        ]);
      });

      test('throws for a non-existent task', () {
        expect(() => store.delete('nonexistent'), throwsA(isA<StateError>()));
      });
    });

    group('status transitions', () {
      test('open accepts any prior status', () async {
        for (final prepare in <Future<Task> Function()>[
          () async {
            final task = await store.create(
              'Draft',
              const CreateTaskOptions(status: TaskStatus.draft),
            );
            return task;
          },
          () async {
            final task = await store.create('Done');
            await store.close(task.id);
            return task;
          },
          () async {
            final task = await store.create('Failed');
            await store.fail(task.id);
            return task;
          },
          () async {
            final task = await store.create('Started');
            await store.start(task.id);
            return task;
          },
          () async => store.create('Already open'),
        ]) {
          final task = await prepare();
          await store.open(task.id);
          expect((await store.get(task.id))?.status, TaskStatus.open);
        }
      });

      test('start moves an open task to in_progress', () async {
        final task = await store.create('Task');
        await store.start(task.id);

        expect((await store.get(task.id))?.status, TaskStatus.inProgress);
      });

      test('start refuses a draft or done task', () async {
        final draft = await store.create(
          'Draft',
          const CreateTaskOptions(status: TaskStatus.draft),
        );
        expect(() => store.start(draft.id), throwsA(isA<StateError>()));

        final done = await store.create('Task');
        await store.close(done.id);
        expect(() => store.start(done.id), throwsA(isA<StateError>()));
      });

      test('close and fail accept any prior status', () async {
        final draft = await store.create(
          'Draft',
          const CreateTaskOptions(status: TaskStatus.draft),
        );
        await store.close(draft.id);
        expect((await store.get(draft.id))?.status, TaskStatus.done);

        final started = await store.create('Task');
        await store.start(started.id);
        await store.fail(started.id);
        expect((await store.get(started.id))?.status, TaskStatus.failed);
      });
    });

    group('dependencies', () {
      test('adds a dependency without duplicating it', () async {
        final dep = await store.create('Dependency');
        final task = await store.create('Task');

        await store.addDep(task.id, dep.id);
        await store.addDep(task.id, dep.id);

        expect((await store.get(task.id))?.deps, [dep.id]);
      });

      test('throws for an unknown task or dependency', () async {
        final dep = await store.create('Dependency');
        final task = await store.create('Task');

        expect(
          () => store.addDep('nonexistent', dep.id),
          throwsA(isA<StateError>()),
        );
        expect(
          () => store.addDep(task.id, 'nonexistent'),
          throwsA(isA<StateError>()),
        );
      });

      test('removes a dependency and is idempotent for unknown ones', () async {
        final dep = await store.create('Dependency');
        final task = await store.create(
          'Task',
          CreateTaskOptions(deps: [dep.id]),
        );

        await store.removeDep(task.id, dep.id);
        await store.removeDep(task.id, 'nonexistent');

        expect((await store.get(task.id))?.deps, isEmpty);
      });
    });

    group('notes and acceptance criteria', () {
      test('appends notes in order with timestamps', () async {
        final task = await store.create('Task');

        await store.addNote(task.id, 'First note');
        await store.addNote(task.id, 'Second note');
        await store.addNote(task.id, 'Third note');

        final notes = (await store.get(task.id))!.notes;
        expect(notes.map((note) => note.content).toList(), [
          'First note',
          'Second note',
          'Third note',
        ]);
        expect(notes.first.timestamp, matches(RegExp(r'^\d{4}-\d{2}-\d{2}T')));
      });

      test('preserves multi-line note bodies', () async {
        final task = await store.create('Task');
        await store.addNote(task.id, 'line one\n\nline two');

        expect(
          (await store.get(task.id))!.notes.single.content,
          'line one\n\nline two',
        );
      });

      test('appends acceptance criteria', () async {
        final task = await store.create('Task');
        await store.addAcceptanceCriteria(task.id, 'tests pass');
        await store.addAcceptanceCriteria(task.id, 'lint passes');

        expect((await store.get(task.id))?.acceptanceCriteria, [
          'tests pass',
          'lint passes',
        ]);
      });
    });

    group('getReady', () {
      test('returns open leaf tasks and excludes every other status', () async {
        final ready = await store.create('Ready task');
        await store.create(
          'Draft',
          const CreateTaskOptions(status: TaskStatus.draft),
        );
        final started = await store.create('Started');
        await store.start(started.id);
        final done = await store.create('Done');
        await store.close(done.id);

        expect((await store.getReady()).map((task) => task.id).toList(), [
          ready.id,
        ]);
      });

      test(
        'excludes tasks with unresolved deps and includes them once done',
        () async {
          final dep = await store.create('Dependency');
          final task = await store.create(
            'Blocked task',
            CreateTaskOptions(deps: [dep.id]),
          );

          expect((await store.getReady()).map((task) => task.id).toList(), [
            dep.id,
          ]);

          await store.close(dep.id);
          expect((await store.getReady()).map((task) => task.id).toList(), [
            task.id,
          ]);
        },
      );

      test('requires every dep to be done', () async {
        final dep1 = await store.create('Dep 1');
        final dep2 = await store.create('Dep 2');
        final task = await store.create(
          'Task',
          CreateTaskOptions(deps: [dep1.id, dep2.id]),
        );

        await store.close(dep1.id);
        expect(
          (await store.getReady()).map((task) => task.id),
          isNot(contains(task.id)),
        );

        await store.close(dep2.id);
        expect(
          (await store.getReady()).map((task) => task.id),
          contains(task.id),
        );
      });

      test('sorts by created date when no priority is set', () async {
        final first = await store.create('Task 1');
        final second = await store.create('Task 2');
        final third = await store.create('Task 3');

        expect((await store.getReady()).map((task) => task.id).toList(), [
          first.id,
          second.id,
          third.id,
        ]);
      });

      test('sorts by priority, lowest number first', () async {
        final low = await store.create(
          'Low',
          const CreateTaskOptions(priority: 10),
        );
        final high = await store.create(
          'High',
          const CreateTaskOptions(priority: 1),
        );
        final medium = await store.create(
          'Medium',
          const CreateTaskOptions(priority: 5),
        );

        expect((await store.getReady()).map((task) => task.id).toList(), [
          high.id,
          medium.id,
          low.id,
        ]);
      });

      test('prioritised tasks come before unprioritised ones', () async {
        final noPriority = await store.create('No priority');
        final withPriority = await store.create(
          'With priority',
          const CreateTaskOptions(priority: 5),
        );

        expect((await store.getReady()).map((task) => task.id).toList(), [
          withPriority.id,
          noPriority.id,
        ]);
      });

      test('sorts by created date within one priority', () async {
        final first = await store.create(
          'First',
          const CreateTaskOptions(priority: 1),
        );
        final second = await store.create(
          'Second',
          const CreateTaskOptions(priority: 1),
        );
        final third = await store.create(
          'Third',
          const CreateTaskOptions(priority: 1),
        );

        expect((await store.getReady()).map((task) => task.id).toList(), [
          first.id,
          second.id,
          third.id,
        ]);
      });

      test('a parent waits for all of its children', () async {
        final parent = await store.create('Parent task');
        final child1 = await store.create(
          'Child 1',
          CreateTaskOptions(parentId: parent.id),
        );
        final child2 = await store.create(
          'Child 2',
          CreateTaskOptions(parentId: parent.id),
        );

        expect((await store.getReady()).map((task) => task.id).toList(), [
          child1.id,
          child2.id,
        ]);

        await store.close(child1.id);
        expect((await store.getReady()).map((task) => task.id).toList(), [
          child2.id,
        ]);

        await store.close(child2.id);
        expect((await store.getReady()).map((task) => task.id).toList(), [
          parent.id,
        ]);
      });

      test(
        'a parent waits for every descendant, one level at a time',
        () async {
          final parent = await store.create('Parent');
          final child = await store.create(
            'Child',
            CreateTaskOptions(parentId: parent.id),
          );
          final grandchild = await store.create(
            'Grandchild',
            CreateTaskOptions(parentId: child.id),
          );

          expect((await store.getReady()).map((task) => task.id).toList(), [
            grandchild.id,
          ]);
          await store.close(grandchild.id);
          expect((await store.getReady()).map((task) => task.id).toList(), [
            child.id,
          ]);
          await store.close(child.id);
          expect((await store.getReady()).map((task) => task.id).toList(), [
            parent.id,
          ]);
        },
      );

      test('combines dep and child blocking', () async {
        final dep = await store.create('Dependency');
        final parent = await store.create(
          'Parent',
          CreateTaskOptions(deps: [dep.id]),
        );
        final child = await store.create(
          'Child',
          CreateTaskOptions(parentId: parent.id),
        );

        var ready = (await store.getReady()).map((task) => task.id).toList();
        expect(ready, containsAll([dep.id, child.id]));
        expect(ready, isNot(contains(parent.id)));

        await store.close(child.id);
        expect(
          (await store.getReady()).map((task) => task.id),
          isNot(contains(parent.id)),
        );

        await store.close(dep.id);
        expect((await store.getReady()).map((task) => task.id).toList(), [
          parent.id,
        ]);
      });

      test('scopes to an epic subtree', () async {
        await store.create('Unrelated task');
        final epic = await store.create('Epic');
        final child = await store.create(
          'Epic child',
          CreateTaskOptions(parentId: epic.id),
        );

        expect(
          (await store.getReady(epic.id)).map((task) => task.id).toList(),
          [child.id],
        );

        await store.close(child.id);
        expect(
          (await store.getReady(epic.id)).map((task) => task.id).toList(),
          [epic.id],
        );
      });

      test('returns nothing when the whole scope is draft', () async {
        final epic = await store.create(
          'Epic',
          const CreateTaskOptions(status: TaskStatus.draft),
        );
        await store.create(
          'Child',
          CreateTaskOptions(parentId: epic.id, status: TaskStatus.draft),
        );

        expect(await store.getReady(epic.id), isEmpty);
      });
    });

    group('getBlocked', () {
      test('returns tasks with unresolved deps only', () async {
        final dep = await store.create('Dependency');
        final blocked = await store.create(
          'Blocked',
          CreateTaskOptions(deps: [dep.id]),
        );
        await store.create('No deps');

        expect((await store.getBlocked()).map((task) => task.id).toList(), [
          blocked.id,
        ]);

        await store.close(dep.id);
        expect(await store.getBlocked(), isEmpty);
      });

      test('excludes draft tasks but includes in_progress ones', () async {
        final dep = await store.create('Dep');
        await store.create(
          'Draft blocked',
          CreateTaskOptions(status: TaskStatus.draft, deps: [dep.id]),
        );
        expect(await store.getBlocked(), isEmpty);

        final task = await store.create(
          'Task',
          CreateTaskOptions(deps: [dep.id]),
        );
        await store.update(
          task.id,
          const TaskChanges(status: TaskStatus.inProgress),
        );

        expect((await store.getBlocked()).map((task) => task.id).toList(), [
          task.id,
        ]);
      });

      test('scopes to an epic subtree', () async {
        final unrelatedDep = await store.create('Unrelated dep');
        await store.create(
          'Unrelated blocked',
          CreateTaskOptions(deps: [unrelatedDep.id]),
        );

        final epic = await store.create('Epic');
        final externalDep = await store.create('External dep');
        final blockedChild = await store.create(
          'Blocked child',
          CreateTaskOptions(parentId: epic.id, deps: [externalDep.id]),
        );

        expect(
          (await store.getBlocked(epic.id)).map((task) => task.id).toList(),
          [blockedChild.id],
        );
      });
    });

    group('getClosed', () {
      test('returns done tasks newest first', () async {
        final first = await store.create('Task 1');
        final second = await store.create('Task 2');
        final third = await store.create('Task 3');
        await store.create('Still open');

        await store.close(first.id);
        await store.close(second.id);
        await store.close(third.id);

        expect((await store.getClosed()).map((task) => task.id).toList(), [
          third.id,
          second.id,
          first.id,
        ]);
      });

      test('scopes to an epic subtree', () async {
        final unrelated = await store.create('Unrelated');
        await store.close(unrelated.id);

        final epic = await store.create('Epic');
        final child = await store.create(
          'Epic child',
          CreateTaskOptions(parentId: epic.id),
        );
        await store.close(child.id);

        expect(
          (await store.getClosed(epic.id)).map((task) => task.id).toList(),
          [child.id],
        );
      });
    });

    group('getDepTree', () {
      test('returns nothing for a leaf', () async {
        final task = await store.create('Leaf task');
        expect(await store.getDepTree(task.id), isEmpty);
      });

      test('returns direct and nested deps without duplicates', () async {
        final shared = await store.create('Shared');
        final left = await store.create(
          'Left',
          CreateTaskOptions(deps: [shared.id]),
        );
        final right = await store.create(
          'Right',
          CreateTaskOptions(deps: [shared.id]),
        );
        final root = await store.create(
          'Root',
          CreateTaskOptions(deps: [left.id, right.id]),
        );

        final tree = await store.getDepTree(root.id);
        expect(tree.map((task) => task.id).toSet(), {
          shared.id,
          left.id,
          right.id,
        });
        expect(tree, hasLength(3));
      });

      test('handles circular deps without looping forever', () async {
        final task1 = await store.create('Task 1');
        final task2 = await store.create(
          'Task 2',
          CreateTaskOptions(deps: [task1.id]),
        );
        await store.addDep(task1.id, task2.id);

        expect(
          (await store.getDepTree(task1.id)).map((task) => task.id),
          contains(task2.id),
        );
      });

      test('throws for a non-existent task', () {
        expect(
          () => store.getDepTree('nonexistent'),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('parent-child hierarchy', () {
      test('returns the ancestor chain from nearest to root', () async {
        final grandparent = await store.create('Grandparent');
        final parent = await store.create(
          'Parent',
          CreateTaskOptions(parentId: grandparent.id),
        );
        final child = await store.create(
          'Child',
          CreateTaskOptions(parentId: parent.id),
        );

        expect(await store.getAncestors(grandparent.id), isEmpty);
        expect(
          (await store.getAncestors(child.id)).map((task) => task.id).toList(),
          [parent.id, grandparent.id],
        );
        expect(
          () => store.getAncestors('nonexistent'),
          throwsA(isA<StateError>()),
        );
      });

      test('returns direct children only, in execution order', () async {
        final grandparent = await store.create('Grandparent');
        final parent = await store.create(
          'Parent',
          CreateTaskOptions(parentId: grandparent.id),
        );
        await store.create(
          'Grandchild',
          CreateTaskOptions(parentId: parent.id),
        );

        expect(await store.getChildren(parent.id), hasLength(1));
        expect((await store.getChildren(grandparent.id)).single.id, parent.id);
        expect(await store.getChildren('nonexistent'), isEmpty);
      });

      test('sorts children by priority then creation', () async {
        final parent = await store.create('Parent');
        final low = await store.create(
          'Low',
          CreateTaskOptions(parentId: parent.id, priority: 10),
        );
        final high = await store.create(
          'High',
          CreateTaskOptions(parentId: parent.id, priority: 1),
        );
        final none = await store.create(
          'None',
          CreateTaskOptions(parentId: parent.id),
        );

        expect(
          (await store.getChildren(parent.id)).map((task) => task.id).toList(),
          [high.id, low.id, none.id],
        );
      });

      test('returns every descendant depth-first', () async {
        final root = await store.create('Root');
        final child = await store.create(
          'Child',
          CreateTaskOptions(parentId: root.id),
        );
        final grandchild = await store.create(
          'Grandchild',
          CreateTaskOptions(parentId: child.id),
        );

        expect(
          (await store.getDescendants(root.id)).map((task) => task.id).toList(),
          [child.id, grandchild.id],
        );
      });

      test('sets and clears a parent', () async {
        final parent = await store.create('Parent');
        final task = await store.create('Task');

        await store.setParent(task.id, parent.id);
        expect((await store.get(task.id))?.parentId, parent.id);

        await store.setParent(task.id, null);
        expect((await store.get(task.id))?.parentId, isNull);
      });

      test('rejects unknown ids, self-parenting and cycles', () async {
        final parent = await store.create('Parent');
        final child = await store.create(
          'Child',
          CreateTaskOptions(parentId: parent.id),
        );

        expect(
          () => store.setParent('nonexistent', parent.id),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('Task not found'),
            ),
          ),
        );
        expect(
          () => store.setParent(parent.id, 'nonexistent'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('Parent task not found'),
            ),
          ),
        );
        expect(
          () => store.setParent(parent.id, parent.id),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('cannot be its own parent'),
            ),
          ),
        );
        expect(
          () => store.setParent(parent.id, child.id),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('circular reference'),
            ),
          ),
        );
      });
    });

    group('file persistence', () {
      test('round-trips every field through a second store instance', () async {
        final parent = await store.create('Parent');
        final task = await store.create(
          'Task with everything',
          CreateTaskOptions(
            body: 'Detailed body',
            acceptanceCriteria: ['tests pass', 'build succeeds'],
            assignee: 'claude',
            priority: 1,
            parentId: parent.id,
            deps: [parent.id],
          ),
        );
        await store.addNote(task.id, 'Implementation note');

        final reopened = FileTaskStore(tempDir.path, clock: clock);
        final retrieved = await reopened.get(task.id);

        expect(retrieved, isNotNull);
        expect(retrieved!.title, 'Task with everything');
        expect(retrieved.body, 'Detailed body');
        expect(retrieved.assignee, 'claude');
        expect(retrieved.priority, 1);
        expect(retrieved.parentId, parent.id);
        expect(retrieved.deps, [parent.id]);
        expect(retrieved.created, task.created);
        expect(retrieved.acceptanceCriteria, ['tests pass', 'build succeeds']);
        expect(retrieved.notes.single.content, 'Implementation note');
        expect(retrieved.raw, contains('assignee: claude'));
        expect(retrieved.raw, contains('priority: 1'));
      });
    });
  });

  group('task documents', () {
    test('serializes and parses a full document', () {
      const task = Task(
        id: 'a1b2c3d4',
        title: 'Do the thing',
        status: TaskStatus.inProgress,
        created: '2026-03-01T00:00:00.000Z',
        deps: ['aaaaaaaa', 'bbbbbbbb'],
        parentId: 'cccccccc',
        body: 'Body line one\nBody line two',
        acceptanceCriteria: ['first', 'second'],
        notes: [
          TaskNote(timestamp: '2026-03-02T00:00:00.000Z', content: 'note one'),
          TaskNote(timestamp: '2026-03-03T00:00:00.000Z', content: 'note two'),
        ],
        assignee: 'claude',
        priority: 2,
      );

      final document = serializeTaskDocument(task);
      final parsed = parseTaskDocument(document);

      expect(parsed.id, task.id);
      expect(parsed.title, task.title);
      expect(parsed.status, TaskStatus.inProgress);
      expect(parsed.deps, task.deps);
      expect(parsed.parentId, task.parentId);
      expect(parsed.body, task.body);
      expect(parsed.acceptanceCriteria, task.acceptanceCriteria);
      expect(
        parsed.notes.map((note) => [note.timestamp, note.content]).toList(),
        [
          ['2026-03-02T00:00:00.000Z', 'note one'],
          ['2026-03-03T00:00:00.000Z', 'note two'],
        ],
      );
      expect(parsed.assignee, 'claude');
      expect(parsed.priority, 2);
      expect(parsed.raw, document);
    });

    test('omits blank optional frontmatter but keeps a zero priority', () {
      const task = Task(
        id: 'a1b2c3d4',
        title: 'Minimal',
        status: TaskStatus.open,
        created: '2026-03-01T00:00:00.000Z',
        priority: 0,
      );

      final document = serializeTaskDocument(task);
      expect(document, isNot(contains('parentId:')));
      expect(document, isNot(contains('assignee:')));
      expect(document, contains('priority: 0'));
      expect(parseTaskDocument(document).priority, 0);
    });

    test('rejects a document with no frontmatter', () {
      expect(
        () => parseTaskDocument('just some markdown\n'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects an unrecognized status instead of laundering it', () {
      // Deviation from upstream, which casts the raw string into its union and
      // produces a Task that then silently fails every scheduling predicate.
      const document =
          '---\nid: a1b2c3d4\ntitle: T\nstatus: bogus\ndeps: []\n'
          'created: 2026-03-01T00:00:00.000Z\n---\n\n';
      expect(
        () => parseTaskDocument(document),
        throwsA(isA<FormatException>()),
      );
    });

    test('falls back to the clock when created is missing', () {
      const document =
          '---\nid: a1b2c3d4\ntitle: T\nstatus: open\ndeps: []\n---\n\n';
      final parsed = parseTaskDocument(
        document,
        clock: () => DateTime.utc(2026, 5, 4, 3, 2, 1),
      );
      expect(parsed.created, '2026-05-04T03:02:01.000Z');
    });

    test('reads a priority with trailing text, like parseInt', () {
      // Deviation: int.tryParse would reject the whole value.
      const document =
          '---\nid: a1b2c3d4\ntitle: T\nstatus: open\ndeps: []\n'
          'priority: 3 (high)\ncreated: 2026-03-01T00:00:00.000Z\n---\n\n';
      expect(parseTaskDocument(document).priority, 3);
    });

    test('tolerates a hand-edited deps list with stray whitespace', () {
      const document =
          '---\nid: a1b2c3d4\ntitle: T\nstatus: open\ndeps: [ aaa ,, bbb ]\n'
          'created: 2026-03-01T00:00:00.000Z\n---\n\n';
      expect(parseTaskDocument(document).deps, ['aaa', 'bbb']);
    });
  });

  // -------------------------------------------------------------------------
  // provider-image-output.ts
  // -------------------------------------------------------------------------
  group('provider image output', () {
    final hash = 'a' * 64;

    String renderImageMarkdown(String imagePath) {
      final item = renderProviderImageOutputAsAssistantMarkdown(
        ProviderImageOutput(path: imagePath),
      );
      if (item == null) fail('expected provider image output to render');
      return item.text;
    }

    test('matches the markdown emitted for a materialized attachment', () {
      expect(
        isProviderImageMarkdown('![Image](/tmp/paseo-attachments/$hash.png)'),
        isTrue,
      );
      expect(
        isProviderImageMarkdown(
          '![Image](/tmp/paseo-attachments-a1B2c3/$hash.png)',
        ),
        isTrue,
      );
      expect(
        isProviderImageMarkdown(
          '![Image](/tmp/paseo-attachments/user-1000/$hash.png)',
        ),
        isTrue,
      );
      expect(
        isProviderImageMarkdown(
          '![shot](/var/folders/x/paseo-attachments/$hash.webp)',
        ),
        isTrue,
      );
      // Windows: backslash separators are doubled by the source escaper.
      expect(
        isProviderImageMarkdown(
          r'![Image](C:\\Users\\me\\AppData\\Local\\Temp\\paseo-attachments\\'
          '$hash.png)',
        ),
        isTrue,
      );
    });

    test(
      'rejects user-authored markdown that is not a materialized attachment',
      () {
        expect(
          isProviderImageMarkdown('![diagram](./paseo-attachments/notes.png)'),
          isFalse,
        );
        expect(
          isProviderImageMarkdown('![logo](https://example.com/logo.png)'),
          isFalse,
        );
        expect(
          isProviderImageMarkdown('see the chart: ![chart](x.png)'),
          isFalse,
        );
      },
    );

    test('emits Windows file paths as file URIs', () {
      final markdown = renderImageMarkdown(
        r'C:\Users\me\AppData\Local\Temp\paseo-attachments\'
        '$hash.png',
      );

      expect(
        markdown,
        '![Image](file:///C:/Users/me/AppData/Local/Temp/paseo-attachments/$hash.png)',
      );
      expect(isProviderImageMarkdown(markdown), isTrue);
    });

    test('emits POSIX file paths with spaces as valid file URI markdown', () {
      expect(
        renderImageMarkdown(
          '/home/user/Projects/Project With Spaces/screenshot.png',
        ),
        '![Image](file:///home/user/Projects/Project%20With%20Spaces/screenshot.png)',
      );
    });

    test('encodes URI-significant characters in POSIX file paths', () {
      expect(
        renderImageMarkdown('/tmp/screenshot#1?draft.png'),
        '![Image](file:///tmp/screenshot%231%3Fdraft.png)',
      );
    });

    test('preserves double-leading slashes in POSIX file paths', () {
      expect(
        renderImageMarkdown('//tmp/screenshot#1.png'),
        '![Image](file:////tmp/screenshot%231.png)',
      );
    });

    test('encodes UNC and extended-UNC image paths as file URIs', () {
      expect(
        renderImageMarkdown(r'\\server\share\shot#1.png'),
        '![Image](file://server/share/shot%231.png)',
      );
      expect(
        renderImageMarkdown(r'\\?\UNC\server\share\shot?draft.png'),
        '![Image](file://server/share/shot%3Fdraft.png)',
      );
    });

    test('escapes alt text and leaves relative sources alone', () {
      final item = renderProviderImageOutputAsAssistantMarkdown(
        const ProviderImageOutput(
          path: 'relative/shot.png',
          altText: r'a ] and a \ ',
        ),
      );
      expect(item!.text, r'![a \] and a \\](relative/shot.png)');
    });

    test('prefers path over url and falls back to url', () {
      expect(
        renderProviderImageOutputAsAssistantMarkdown(
          const ProviderImageOutput(
            path: 'from-path.png',
            url: 'https://example.com/from-url.png',
          ),
        )!.text,
        '![Image](from-path.png)',
      );
      expect(
        renderProviderImageOutputAsAssistantMarkdown(
          const ProviderImageOutput(
            path: '   ',
            url: 'https://example.com/from-url.png',
          ),
        )!.text,
        '![Image](https://example.com/from-url.png)',
      );
    });

    test('returns null when there is nothing at all to render', () {
      expect(
        renderProviderImageOutputAsAssistantMarkdown(
          const ProviderImageOutput(path: '  ', url: null, data: '  '),
        ),
        isNull,
      );
    });

    test('materializes inline base64 and links the resulting file', () {
      final materialized = <String>[];
      final item = renderProviderImageOutputAsAssistantMarkdown(
        const ProviderImageOutput(data: 'YWJjMTIz', mimeType: 'image/png'),
        materialize: ({required data, mimeType}) {
          materialized.add(data);
          return const MaterializedProviderImage(path: '/tmp/x/$_fakeHashPng');
        },
      );

      expect(materialized, ['YWJjMTIz']);
      expect(item!.text, '![Image](file:///tmp/x/$_fakeHashPng)');
    });

    test('reads a data: URI that arrived in the path slot', () {
      String? seenData;
      String? seenMime;
      renderProviderImageOutputAsAssistantMarkdown(
        const ProviderImageOutput(
          path: 'data:image/png;base64,YWJjMTIz',
          mimeType: 'image/png',
        ),
        materialize: ({required data, mimeType}) {
          seenData = data;
          seenMime = mimeType;
          return const MaterializedProviderImage(path: '/tmp/x.png');
        },
      );

      expect(seenData, 'data:image/png;base64,YWJjMTIz');
      expect(seenMime, 'image/png');
    });

    test('degrades to an apology when materialization is impossible', () {
      const omitted =
          'Image output was omitted because it was not available as a file '
          'path or URL.';

      // No materializer at all.
      expect(
        renderProviderImageOutputAsAssistantMarkdown(
          const ProviderImageOutput(data: 'YWJjMTIz'),
        )!.text,
        omitted,
      );
      // A materializer that throws.
      expect(
        renderProviderImageOutputAsAssistantMarkdown(
          const ProviderImageOutput(data: 'YWJjMTIz'),
          materialize: ({required data, mimeType}) =>
              throw const FileSystemException('disk full'),
        )!.text,
        omitted,
      );
      // A materializer that hands back a data: URI or an empty path.
      expect(
        renderProviderImageOutputAsAssistantMarkdown(
          const ProviderImageOutput(data: 'YWJjMTIz'),
          materialize: ({required data, mimeType}) =>
              const MaterializedProviderImage(path: 'data:image/png;base64,x'),
        )!.text,
        omitted,
      );
      expect(
        renderProviderImageOutputAsAssistantMarkdown(
          const ProviderImageOutput(data: 'YWJjMTIz'),
          materialize: ({required data, mimeType}) =>
              const MaterializedProviderImage(path: ''),
        )!.text,
        omitted,
      );
    });

    test('renders into a timeline item at the boundary', () {
      final item = renderProviderImageOutputAsAssistantMarkdown(
        const ProviderImageOutput(path: 'shot.png'),
      )!.toTimelineItem(id: 'item-1');

      expect(item.id, 'item-1');
      expect(item.text, '![Image](shot.png)');
      expect(item.complete, isTrue);
    });
  });

  group('materializeProviderImage', () {
    tearDown(resetMaterializedImageAttachmentDirForTest);

    test('writes content-addressed files and reuses them', () {
      final first = materializeProviderImage(
        data: 'YWJjMTIz',
        mimeType: 'image/png',
      );
      final again = materializeProviderImage(
        data: 'YWJjMTIz',
        mimeType: 'image/png',
      );
      final directory = Directory(p.dirname(first.path));

      try {
        expect(File(first.path).existsSync(), isTrue);
        expect(again.path, first.path);
        expect(File(first.path).readAsBytesSync(), utf8.encode('abc123'));
        expect(p.basename(first.path), matches(RegExp(r'^[0-9a-f]{64}\.png$')));
        // The rendered markdown for it must be recognized as a provider image.
        expect(
          isProviderImageMarkdown(
            renderProviderImageOutputAsAssistantMarkdown(
              ProviderImageOutput(path: first.path),
            )!.text,
          ),
          isTrue,
        );
      } finally {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      }
    });

    test('picks the extension from the mime type, including a data: URI', () {
      final directories = <String>[];
      try {
        for (final probe in <(String, String?, String)>[
          ('YWJjMTIz', 'image/jpeg', 'jpg'),
          ('YWJjMTIz', 'image/webp', 'webp'),
          ('YWJjMTIz', 'image/heic', 'bin'),
          ('YWJjMTIz', null, 'png'),
          ('data:image/gif;base64,YWJjMTIz', 'image/png', 'gif'),
        ]) {
          final result = materializeProviderImage(
            data: probe.$1,
            mimeType: probe.$2,
          );
          directories.add(p.dirname(result.path));
          expect(p.extension(result.path), '.${probe.$3}');
        }
      } finally {
        for (final directory in directories.toSet()) {
          final entity = Directory(directory);
          if (entity.existsSync()) entity.deleteSync(recursive: true);
        }
      }
    });

    test(
      'recreates the private temp directory if the cached one is removed',
      () {
        final first = materializeProviderImage(
          data: 'YWJjMTIz',
          mimeType: 'image/png',
        );
        final firstDir = Directory(p.dirname(first.path));
        expect(File(first.path).existsSync(), isTrue);

        firstDir.deleteSync(recursive: true);

        final second = materializeProviderImage(
          data: 'ZGVmNDU2',
          mimeType: 'image/png',
        );
        final secondDir = Directory(p.dirname(second.path));
        try {
          expect(File(second.path).existsSync(), isTrue);
          expect(secondDir.path, isNot(firstDir.path));
        } finally {
          if (secondDir.existsSync()) secondDir.deleteSync(recursive: true);
        }
      },
    );
  });
}

const String _fakeHashPng =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.png';
