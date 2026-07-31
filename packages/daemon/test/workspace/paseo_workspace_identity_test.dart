import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/agent/agent_store.dart';
import 'package:agent_daemon/src/workspace/paseo_workspace_identity.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<void> _git(String cwd, List<String> args) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: cwd,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw StateError('git $args failed: ${result.stderr}');
  }
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('paseo-workspace-identity-');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// Creates a real directory under the temp root, mirroring upstream's
  /// `mkdtempSync` fixtures. Names may contain spaces and punctuation on
  /// purpose: slug derivation is defined over the basename.
  String directory(String name) {
    final path = p.join(temp.path, name);
    Directory(path).createSync(recursive: true);
    return path;
  }

  /// The daemon really runs git, so remote fixtures are real repositories with
  /// a real `remote.origin.url` config, matching the rest of this suite.
  Future<String> gitDirectory(String name, {String? remoteUrl}) async {
    final path = directory(name);
    await _git(path, ['init']);
    if (remoteUrl != null) {
      await _git(path, ['config', 'remote.origin.url', remoteUrl]);
    }
    return path;
  }

  // -------------------------------------------------------------------------
  // workspace-git-metadata.ts
  // -------------------------------------------------------------------------

  group('parseGitHubRepoFromRemote', () {
    test('returns the owner-qualified repo for a GitHub remote', () {
      expect(
        parseGitHubRepoFromRemote(
          'https://github.com/anthropics/claude-code.git',
        ),
        'anthropics/claude-code',
      );
    });

    test('returns null for a non-GitHub remote', () {
      expect(
        parseGitHubRepoFromRemote('git@gitlab.com:anthropics/claude-code.git'),
        isNull,
      );
    });
  });

  group('parseGitHubRepoNameFromRemote', () {
    const cases = <String, String>{
      'https://github.com/anthropics/claude-code.git': 'claude-code',
      'http://github.com/anthropics/claude-code.git': 'claude-code',
      'git@github.com:anthropics/claude-code.git': 'claude-code',
      'ssh://git@github.com/anthropics/claude-code.git': 'claude-code',
      'https://github.com/anthropics/claude-code': 'claude-code',
      'https://github.com/acme/repo.with.dots.git': 'repo.with.dots',
      'https://github.com/acme/Claude Code.git': 'Claude Code',
      'https://github.com/acme/Repo_Name! 2026.git': 'Repo_Name! 2026',
    };

    cases.forEach((remoteUrl, repoName) {
      test('extracts $remoteUrl as $repoName', () {
        expect(parseGitHubRepoNameFromRemote(remoteUrl), repoName);
      });
    });

    test('returns null for non-GitHub remotes', () {
      expect(
        parseGitHubRepoNameFromRemote(
          'git@gitlab.com:anthropics/claude-code.git',
        ),
        isNull,
      );
    });

    for (final remoteUrl in const [
      'https://gitlab.example/mirror/github.com/acme/claude-code.git',
      'ssh://git@gitlab.example/mirror/github.com/acme/claude-code.git',
    ]) {
      test('returns null for an embedded GitHub path: $remoteUrl', () {
        expect(parseGitHubRepoNameFromRemote(remoteUrl), isNull);
      });
    }

    test('normalizes host case and trailing dots', () {
      expect(
        parseGitHubRepoNameFromRemote(
          'https://GitHub.COM/anthropics/claude-code.git',
        ),
        'claude-code',
      );
      expect(
        parseGitHubRepoNameFromRemote(
          'git@github.com.:anthropics/claude-code.git',
        ),
        'claude-code',
      );
    });

    test('returns null when the path is not exactly owner/name', () {
      expect(parseGitHubRepoNameFromRemote('https://github.com/acme'), isNull);
      expect(
        parseGitHubRepoNameFromRemote('https://github.com/acme/repo/extra'),
        isNull,
      );
      expect(parseGitHubRepoNameFromRemote('https://github.com/'), isNull);
    });

    test('returns null for blank and unparseable remotes', () {
      expect(parseGitHubRepoNameFromRemote(''), isNull);
      expect(parseGitHubRepoNameFromRemote('   '), isNull);
      expect(parseGitHubRepoNameFromRemote('not a remote at all'), isNull);
      expect(
        parseGitHubRepoNameFromRemote('git://github.com/acme/repo.git'),
        isNull,
      );
    });

    test('accepts ssh.github.com, the port-443 SSH alias', () {
      // Upstream derives its GitHub host set from the forge manifest, which
      // lists both `github.com` and `ssh.github.com`. `agent_protocol`'s
      // `isGitHubHost` originally knew only `github.com`; porting this
      // module surfaced the gap and it was fixed in the protocol package
      // rather than worked around here.
      expect(
        parseGitHubRepoNameFromRemote(
          'git@ssh.github.com:anthropics/claude-code.git',
        ),
        'claude-code',
      );
    });
  });

  group('deriveProjectSlug', () {
    const remoteSlugs = <String, String>{
      'https://github.com/acme/repo.with.dots.git': 'repo-with-dots',
      'http://github.com/acme/http-repo.git': 'http-repo',
      'git@github.com:acme/scp-repo.git': 'scp-repo',
      'ssh://git@github.com/acme/ssh-repo.git': 'ssh-repo',
      'https://github.com/acme/Claude Code.git': 'claude-code',
      'https://github.com/acme/Repo_Name! 2026.git': 'repo-name-2026',
    };

    var fixtureIndex = 0;
    remoteSlugs.forEach((remoteUrl, expectedSlug) {
      test('slugifies the GitHub repo name from $remoteUrl', () async {
        final cwd = await gitDirectory(
          'fallback-name-${fixtureIndex++}',
          remoteUrl: remoteUrl,
        );

        expect(deriveProjectSlug(cwd, remoteUrl), expectedSlug);
      });
    });

    test(
      'uses only the repo name, so identical names collide across owners',
      () async {
        final acmeCwd = await gitDirectory(
          'acme-fallback',
          remoteUrl: 'https://github.com/acme/claude-code',
        );
        final otherCwd = await gitDirectory(
          'other-fallback',
          remoteUrl: 'https://github.com/other/claude-code',
        );

        expect(
          deriveProjectSlug(acmeCwd, 'https://github.com/acme/claude-code'),
          'claude-code',
        );
        expect(
          deriveProjectSlug(otherCwd, 'https://github.com/other/claude-code'),
          'claude-code',
        );
      },
    );

    test('falls through to the cwd basename for non-GitHub remotes', () async {
      const remoteUrl = 'git@gitlab.com:acme/claude-code.git';
      final cwd = await gitDirectory('My Local Repo', remoteUrl: remoteUrl);

      expect(deriveProjectSlug(cwd, remoteUrl), 'my-local-repo');
    });

    test(
      'falls through to the cwd basename for embedded GitHub paths',
      () async {
        const remoteUrl =
            'https://gitlab.example/mirror/github.com/acme/claude-code.git';
        final cwd = await gitDirectory(
          'Embedded GitHub Path',
          remoteUrl: remoteUrl,
        );

        expect(deriveProjectSlug(cwd, remoteUrl), 'embedded-github-path');
      },
    );

    test('falls through to the cwd basename for an empty remote', () async {
      final cwd = await gitDirectory('Empty Remote Repo', remoteUrl: '');

      expect(deriveProjectSlug(cwd), 'empty-remote-repo');
    });

    test('treats an explicit empty-string remote like no remote', () async {
      // Upstream relies on JS truthiness (`remoteUrl ? ... : null`); the Dart
      // port spells the emptiness check out, so this must stay basename-derived
      // instead of attempting to parse "".
      final cwd = await gitDirectory('Explicit Empty Remote', remoteUrl: '');

      expect(deriveProjectSlug(cwd, ''), 'explicit-empty-remote');
    });

    test(
      'falls through to the cwd basename when the remote is missing',
      () async {
        final cwd = await gitDirectory('Missing Remote Repo');

        expect(deriveProjectSlug(cwd), 'missing-remote-repo');
      },
    );

    test('uses the cwd basename for a non-git directory', () {
      expect(
        deriveProjectSlug(directory('Plain Directory')),
        'plain-directory',
      );
    });

    test('uses the cwd basename when no remote is provided', () {
      expect(
        deriveProjectSlug(directory('Basename Project!')),
        'basename-project',
      );
    });

    test('ignores parent directories and trailing separators', () {
      final cwd = directory(p.join('Outer Dir', 'Inner Dir'));

      expect(deriveProjectSlug(cwd), 'inner-dir');
      expect(deriveProjectSlug('$cwd${p.separator}'), 'inner-dir');
    });

    test('uses untitled when the source collapses to an empty slug', () {
      expect(deriveProjectSlug(directory('日本語')), 'untitled');
      expect(deriveProjectSlug(directory('!!!')), 'untitled');
    });

    test('inherits the shared slugify truncation for very long names', () {
      // slugify caps at 50 characters, cutting back to the last hyphen past the
      // halfway mark; deriveProjectSlug must not add its own limit.
      const repoName =
          'this-is-a-very-long-repository-name-that-keeps-on-going-forever';
      expect(
        deriveProjectSlug('/tmp/ignored', 'https://github.com/acme/$repoName'),
        slugify(repoName),
      );
      expect(
        deriveProjectSlug(
          '/tmp/ignored',
          'https://github.com/acme/$repoName',
        ).length,
        lessThanOrEqualTo(50),
      );
    });
  });

  group('deriveProjectServiceSlug', () {
    test('keeps same-basename projects distinct and stable', () {
      const first = (
        projectId: 'prj_aaaaaaaaaaaaaaaa',
        rootPath: '/repo-a/app',
      );
      const second = (
        projectId: 'prj_bbbbbbbbbbbbbbbb',
        rootPath: '/repo-b/app',
      );

      final firstSlug = deriveProjectServiceSlug(
        projectId: first.projectId,
        rootPath: first.rootPath,
      );
      expect(
        firstSlug,
        deriveProjectServiceSlug(
          projectId: first.projectId,
          rootPath: first.rootPath,
        ),
      );
      expect(
        firstSlug,
        isNot(
          deriveProjectServiceSlug(
            projectId: second.projectId,
            rootPath: second.rootPath,
          ),
        ),
      );
    });

    test('appends the first 8 hex characters of sha256(projectId)', () {
      expect(
        deriveProjectServiceSlug(
          projectId: 'prj_aaaaaaaaaaaaaaaa',
          rootPath: '/repo-a/app',
        ),
        'app-2a96cfd4',
      );
      expect(
        deriveProjectServiceSlug(
          projectId: 'prj_bbbbbbbbbbbbbbbb',
          rootPath: '/repo-b/app',
        ),
        'app-08546f56',
      );
    });

    test('derives the slug from the root path basename only', () {
      // The identity digest is over the project id, so moving the project to a
      // different parent keeps the same suffix but tracks the new basename.
      expect(
        deriveProjectServiceSlug(
          projectId: 'prj_service_slug',
          rootPath: p.join('elsewhere', 'My Project'),
        ),
        'my-project-d66c9fcc',
      );
    });

    test('falls back to untitled when the basename slugifies empty', () {
      expect(
        deriveProjectServiceSlug(
          projectId: 'prj_service_slug',
          rootPath: '/repos/日本語',
        ),
        'untitled-d66c9fcc',
      );
    });
  });

  // -------------------------------------------------------------------------
  // resolve-workspace-id-for-path.ts
  // -------------------------------------------------------------------------

  group('resolveWorkspaceIdForPath', () {
    test('returns the first id when workspaces share the exact cwd', () {
      // Upstream only asserts membership; the implementation actually returns
      // the first match in iteration order, so pin that.
      expect(
        resolveWorkspaceIdForPath('/workspace/project', [
          _workspace('/workspace/project', 'ws-1'),
          _workspace('/workspace/project', 'ws-2'),
          _workspace('/workspace/other', 'ws-3'),
        ], homeDirectory: _fakeHome),
        'ws-1',
      );
    });

    test('resolves an exact archived workspace match for archive-by-path', () {
      expect(
        resolveWorkspaceIdForPath('/workspace/project', [
          _workspace(
            '/workspace/project',
            'ws-archived',
            archivedAt: '2026-03-05T00:00:00.000Z',
          ),
        ], homeDirectory: _fakeHome),
        'ws-archived',
      );
    });

    test('resolves the deepest enclosing workspace for a subdirectory', () {
      expect(
        resolveWorkspaceIdForPath(
          p.join('/workspace/project', 'packages', 'app'),
          [
            _workspace('/workspace/project', 'ws-1'),
            _workspace('/workspace', 'ws-root'),
          ],
          homeDirectory: _fakeHome,
        ),
        'ws-1',
      );
      // Order-independent: the deepest wins regardless of iteration order.
      expect(
        resolveWorkspaceIdForPath(
          p.join('/workspace/project', 'packages', 'app'),
          [
            _workspace('/workspace', 'ws-root'),
            _workspace('/workspace/project', 'ws-1'),
          ],
          homeDirectory: _fakeHome,
        ),
        'ws-1',
      );
    });

    test('keeps the first workspace when enclosing depths tie', () {
      expect(
        resolveWorkspaceIdForPath(
          p.join('/workspace/project', 'src'),
          [
            _workspace('/workspace/project', 'ws-first'),
            _workspace('/workspace/project', 'ws-second'),
          ],
          // Force the prefix path by asking about a descendant, not the cwd.
          homeDirectory: _fakeHome,
        ),
        'ws-first',
      );
    });

    test('never lets a sibling directory prefix win', () {
      expect(
        resolveWorkspaceIdForPath('/workspace/project-two', [
          _workspace('/workspace/project', 'ws-1'),
        ], homeDirectory: _fakeHome),
        isNull,
      );
    });

    test('ignores archived workspaces when matching a prefix', () {
      expect(
        resolveWorkspaceIdForPath(p.join('/workspace/project', 'src'), [
          _workspace(
            '/workspace/project',
            'ws-archived',
            archivedAt: '2026-03-05T00:00:00.000Z',
          ),
        ], homeDirectory: _fakeHome),
        isNull,
      );
      expect(
        resolveWorkspaceIdForPath(p.join('/workspace/project', 'src'), [
          _workspace(
            '/workspace/project',
            'ws-archived',
            archivedAt: '2026-03-05T00:00:00.000Z',
          ),
          _workspace('/workspace', 'ws-root'),
        ], homeDirectory: _fakeHome),
        'ws-root',
      );
    });

    test('does not match the home directory as a prefix', () {
      expect(
        resolveWorkspaceIdForPath(p.join(_fakeHome, 'child'), [
          _workspace(_fakeHome, 'ws-home'),
        ], homeDirectory: _fakeHome),
        isNull,
      );
      expect(
        resolveWorkspaceIdForPath(_fakeHome, [
          _workspace(_fakeHome, 'ws-home'),
        ], homeDirectory: _fakeHome),
        'ws-home',
      );
    });

    test('defaults to the ambient home directory when none is injected', () {
      final home = defaultUserHomeDirectory();
      expect(home, isNotEmpty);

      expect(
        resolveWorkspaceIdForPath(p.join(home, 'child'), [
          _workspace(home, 'ws-home'),
        ]),
        isNull,
      );
      expect(
        resolveWorkspaceIdForPath(home, [_workspace(home, 'ws-home')]),
        'ws-home',
      );
    });

    test('returns null for an empty registry and for unrelated paths', () {
      expect(
        resolveWorkspaceIdForPath(
          '/workspace/project',
          const <PersistedWorkspaceRecord>[],
          homeDirectory: _fakeHome,
        ),
        isNull,
      );
      expect(
        resolveWorkspaceIdForPath('/elsewhere/entirely', [
          _workspace('/workspace/project', 'ws-1'),
        ], homeDirectory: _fakeHome),
        isNull,
      );
    });

    test('normalizes both sides before comparing', () {
      expect(
        resolveWorkspaceIdForPath('/workspace/nested/../project', [
          _workspace('/workspace/project${p.separator}', 'ws-1'),
        ], homeDirectory: _fakeHome),
        'ws-1',
      );
    });

    test('resolves a relative cwd against the process working directory', () {
      final relative = p.join('packages', 'daemon');
      final absolute = p.absolute(relative);

      expect(
        resolveWorkspaceIdForPath(relative, [
          _workspace(absolute, 'ws-relative'),
        ], homeDirectory: _fakeHome),
        'ws-relative',
      );
    });

    test('never lets the filesystem root enclose a descendant path', () {
      // A root workspace normalizes to a value already ending in a separator,
      // so the prefix is not doubled and the root legitimately encloses.
      final root = p.rootPrefix(p.absolute('/workspace/project'));
      expect(
        resolveWorkspaceIdForPath('/workspace/project', [
          _workspace(root, 'ws-root'),
        ], homeDirectory: _fakeHome),
        'ws-root',
      );
    });
  });

  // -------------------------------------------------------------------------
  // workspace-bootstrap-dedupe.ts
  // -------------------------------------------------------------------------

  group('shouldEmitPendingBootstrapUpdate', () {
    final snapshotDone1030 = BootstrapUpdateSnapshot(
      status: 'done',
      statusEnteredAt: '2026-05-12T10:30:00.000Z',
      activityAtMs: DateTime.parse(
        '2026-05-12T10:00:00.000Z',
      ).millisecondsSinceEpoch,
    );

    test('emits when there is no snapshot (first-time subscription)', () {
      expect(
        shouldEmitPendingBootstrapUpdate(
          snapshot: null,
          update: const BootstrapUpdateSnapshot(
            status: 'done',
            statusEnteredAt: null,
            activityAtMs: null,
          ),
        ),
        isTrue,
      );
    });

    test('emits when status changed (unmask: needs_input -> done)', () {
      expect(
        shouldEmitPendingBootstrapUpdate(
          snapshot: snapshotDone1030.copyWith(status: 'needs_input'),
          update: BootstrapUpdateSnapshot(
            status: 'done',
            statusEnteredAt: snapshotDone1030.statusEnteredAt,
            activityAtMs: null,
          ),
        ),
        isTrue,
      );
    });

    test('emits when statusEnteredAt changed (fresh unmask time)', () {
      expect(
        shouldEmitPendingBootstrapUpdate(
          snapshot: snapshotDone1030,
          update: BootstrapUpdateSnapshot(
            status: 'done',
            statusEnteredAt: '2026-05-12T11:00:00.000Z',
            activityAtMs: snapshotDone1030.activityAtMs,
          ),
        ),
        isTrue,
      );
    });

    test('emits when statusEnteredAt goes from null to a value (unmask)', () {
      expect(
        shouldEmitPendingBootstrapUpdate(
          snapshot: snapshotDone1030.copyWith(statusEnteredAt: null),
          update: snapshotDone1030,
        ),
        isTrue,
      );
    });

    test('emits when statusEnteredAt goes from a value to null', () {
      expect(
        shouldEmitPendingBootstrapUpdate(
          snapshot: snapshotDone1030,
          update: snapshotDone1030.copyWith(statusEnteredAt: null),
        ),
        isTrue,
      );
    });

    test('emits when update activity is strictly newer', () {
      expect(
        shouldEmitPendingBootstrapUpdate(
          snapshot: snapshotDone1030,
          update: snapshotDone1030.copyWith(
            activityAtMs: DateTime.parse(
              '2026-05-12T10:30:00.000Z',
            ).millisecondsSinceEpoch,
          ),
        ),
        isTrue,
      );
      // One millisecond is enough; the comparison is strict, not tolerant.
      expect(
        shouldEmitPendingBootstrapUpdate(
          snapshot: snapshotDone1030,
          update: snapshotDone1030.copyWith(
            activityAtMs: snapshotDone1030.activityAtMs! + 1,
          ),
        ),
        isTrue,
      );
    });

    test('emits when snapshot has no activity and the update does', () {
      expect(
        shouldEmitPendingBootstrapUpdate(
          snapshot: snapshotDone1030.copyWith(activityAtMs: null),
          update: snapshotDone1030,
        ),
        isTrue,
      );
    });

    test('drops when the status pair matches and activity is older', () {
      expect(
        shouldEmitPendingBootstrapUpdate(
          snapshot: snapshotDone1030,
          update: snapshotDone1030.copyWith(
            activityAtMs: DateTime.parse(
              '2026-05-12T09:30:00.000Z',
            ).millisecondsSinceEpoch,
          ),
        ),
        isFalse,
      );
    });

    test('drops when the status pair matches and activity is equal', () {
      expect(
        shouldEmitPendingBootstrapUpdate(
          snapshot: snapshotDone1030,
          update: snapshotDone1030,
        ),
        isFalse,
      );
    });

    test('drops when both activities are null', () {
      expect(
        shouldEmitPendingBootstrapUpdate(
          snapshot: snapshotDone1030.copyWith(activityAtMs: null),
          update: snapshotDone1030.copyWith(activityAtMs: null),
        ),
        isFalse,
      );
    });

    test('drops when the update lost activity the snapshot had', () {
      expect(
        shouldEmitPendingBootstrapUpdate(
          snapshot: snapshotDone1030,
          update: snapshotDone1030.copyWith(activityAtMs: null),
        ),
        isFalse,
      );
    });

    test('treats the status label as opaque, not as a known enum', () {
      expect(
        shouldEmitPendingBootstrapUpdate(
          snapshot: snapshotDone1030.copyWith(status: 'brand_new_status'),
          update: snapshotDone1030,
        ),
        isTrue,
      );
      expect(
        shouldEmitPendingBootstrapUpdate(
          snapshot: snapshotDone1030.copyWith(status: 'brand_new_status'),
          update: snapshotDone1030.copyWith(status: 'brand_new_status'),
        ),
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  // migrations/backfill-workspace-id.migration.ts
  // -------------------------------------------------------------------------

  group('resolveLegacyWorkspaceOwner', () {
    test('prefers the oldest exact-cwd workspace', () {
      expect(
        resolveLegacyWorkspaceOwner('/tmp/repo', [
          _workspace(
            '/tmp/repo',
            'ws-newer',
            createdAt: '2026-03-02T00:00:00.000Z',
          ),
          _workspace(
            '/tmp/repo',
            'ws-older',
            createdAt: '2026-03-01T00:00:00.000Z',
          ),
        ], homeDirectory: _fakeHome),
        'ws-older',
      );
    });

    test('keeps the first record when createdAt ties', () {
      expect(
        resolveLegacyWorkspaceOwner('/tmp/repo', [
          _workspace('/tmp/repo', 'ws-a'),
          _workspace('/tmp/repo', 'ws-b'),
        ], homeDirectory: _fakeHome),
        'ws-a',
      );
    });

    test('falls back to the deepest enclosing workspace', () {
      expect(
        resolveLegacyWorkspaceOwner(
          p.join('/tmp/repo', 'packages', 'app', 'src'),
          [
            _workspace('/tmp/repo', 'ws-root'),
            _workspace(p.join('/tmp/repo', 'packages', 'app'), 'ws-app'),
          ],
          homeDirectory: _fakeHome,
        ),
        'ws-app',
      );
    });

    test('breaks equally deep prefix matches by age', () {
      expect(
        resolveLegacyWorkspaceOwner(p.join('/tmp/repo', 'src'), [
          _workspace(
            '/tmp/repo',
            'ws-newer',
            createdAt: '2026-03-09T00:00:00.000Z',
          ),
          _workspace(
            '/tmp/repo',
            'ws-older',
            createdAt: '2026-03-03T00:00:00.000Z',
          ),
        ], homeDirectory: _fakeHome),
        'ws-older',
      );
    });

    test('never lets a sibling directory prefix win', () {
      expect(
        resolveLegacyWorkspaceOwner('/tmp/repo-two', [
          _workspace('/tmp/repo', 'ws-1'),
        ], homeDirectory: _fakeHome),
        isNull,
      );
    });

    test('excludes archived workspaces unless includeArchived is set', () {
      final workspaces = [
        _workspace(
          '/tmp/repo',
          'ws-archived',
          archivedAt: '2026-03-02T00:00:00.000Z',
        ),
      ];

      expect(
        resolveLegacyWorkspaceOwner(
          '/tmp/repo',
          workspaces,
          homeDirectory: _fakeHome,
        ),
        isNull,
      );
      expect(
        resolveLegacyWorkspaceOwner(
          '/tmp/repo',
          workspaces,
          includeArchived: true,
          homeDirectory: _fakeHome,
        ),
        'ws-archived',
      );
    });

    test('does not let the home directory own descendants', () {
      expect(
        resolveLegacyWorkspaceOwner(p.join(_fakeHome, 'repo'), [
          _workspace(_fakeHome, 'ws-home'),
        ], homeDirectory: _fakeHome),
        isNull,
      );
      // The home directory can still own itself, via the exact-match branch.
      expect(
        resolveLegacyWorkspaceOwner(_fakeHome, [
          _workspace(_fakeHome, 'ws-home'),
        ], homeDirectory: _fakeHome),
        'ws-home',
      );
    });

    test('defaults to the ambient home directory when none is injected', () {
      final home = defaultUserHomeDirectory();
      expect(
        resolveLegacyWorkspaceOwner(p.join(home, 'repo'), [
          _workspace(home, 'ws-home'),
        ]),
        isNull,
      );
    });

    test('returns null when nothing matches', () {
      expect(
        resolveLegacyWorkspaceOwner(
          '/tmp/repo',
          const <PersistedWorkspaceRecord>[],
          homeDirectory: _fakeHome,
        ),
        isNull,
      );
      expect(
        resolveLegacyWorkspaceOwner('/elsewhere/entirely', [
          _workspace('/tmp/repo', 'ws-1'),
        ], homeDirectory: _fakeHome),
        isNull,
      );
    });
  });

  group('backfillWorkspaceIdForLegacyAgents', () {
    late AgentStore agentStore;
    late FileBackedWorkspaceRegistry workspaceRegistry;
    late List<String> logs;

    setUp(() async {
      agentStore = AgentStore(dataDir: p.join(temp.path, 'data'));
      workspaceRegistry = FileBackedWorkspaceRegistry(
        filePath: p.join(temp.path, 'data', 'workspaces.json'),
      );
      await workspaceRegistry.initialize();
      logs = <String>[];
    });

    Future<void> seedLegacyAgent(
      String cwd,
      String agentId, {
      bool archived = false,
      String? archivedAt,
      String? workspaceId,
    }) => agentStore.save(
      _agent(
        agentId: agentId,
        cwd: cwd,
        archived: archived,
        archivedAt: archivedAt,
        workspaceId: workspaceId,
      ),
    );

    Future<int> run() => backfillWorkspaceIdForLegacyAgents(
      agentStore: agentStore,
      workspaceRegistry: workspaceRegistry,
      log: logs.add,
      homeDirectory: _fakeHome,
    );

    Future<String?> storedWorkspaceId(String agentId) async {
      final records = await agentStore.loadAll();
      return records
          .firstWhere((record) => record.summary.agentId == agentId)
          .summary
          .workspaceId;
    }

    test('stamps the oldest exact-cwd workspace onto a legacy agent', () async {
      await workspaceRegistry.upsert(
        _workspace(
          '/tmp/repo',
          'ws-newer',
          createdAt: '2026-03-02T00:00:00.000Z',
        ),
      );
      await workspaceRegistry.upsert(
        _workspace(
          '/tmp/repo',
          'ws-older',
          createdAt: '2026-03-01T00:00:00.000Z',
        ),
      );
      await seedLegacyAgent('/tmp/repo', 'legacy-agent');

      expect(await run(), 1);
      expect(await storedWorkspaceId('legacy-agent'), 'ws-older');
      expect(logs, ['Backfilled workspaceId for 1 legacy agent records']);
    });

    test('attributes to the deepest enclosing workspace', () async {
      await workspaceRegistry.upsert(_workspace('/tmp/repo', 'ws-root'));
      await workspaceRegistry.upsert(
        _workspace(p.join('/tmp/repo', 'packages', 'app'), 'ws-app'),
      );
      await seedLegacyAgent(
        p.join('/tmp/repo', 'packages', 'app', 'src'),
        'legacy-agent',
      );

      expect(await run(), 1);
      expect(await storedWorkspaceId('legacy-agent'), 'ws-app');
    });

    test('leaves already-stamped records untouched', () async {
      await workspaceRegistry.upsert(_workspace('/tmp/repo', 'ws-cwd'));
      await seedLegacyAgent(
        '/tmp/repo',
        'stamped-agent',
        workspaceId: 'ws-explicit',
      );

      expect(await run(), 0);
      expect(await storedWorkspaceId('stamped-agent'), 'ws-explicit');
      expect(logs, isEmpty);
    });

    test('backfills a blank workspaceId, matching JS truthiness', () async {
      // Upstream's `if (record.workspaceId) continue;` also treats "" as
      // unstamped, so a blank id must be replaced rather than preserved.
      await workspaceRegistry.upsert(_workspace('/tmp/repo', 'ws-cwd'));
      await seedLegacyAgent('/tmp/repo', 'blank-agent', workspaceId: '');

      expect(await run(), 1);
      expect(await storedWorkspaceId('blank-agent'), 'ws-cwd');
    });

    test('stamps archived agents from archived workspace owners', () async {
      await workspaceRegistry.upsert(
        _workspace(
          '/tmp/repo',
          'ws-archived',
          archivedAt: '2026-03-02T00:00:00.000Z',
        ),
      );
      await seedLegacyAgent(
        '/tmp/repo',
        'legacy-agent',
        archived: true,
        archivedAt: '2026-03-02T12:00:00.000Z',
      );

      expect(await run(), 1);
      expect(await storedWorkspaceId('legacy-agent'), 'ws-archived');
    });

    test('treats the archivedAt timestamp alone as archived', () async {
      // This repo carries both `PersistedAgent.archived` and
      // `summary.archivedAt`; upstream only has the timestamp, so either
      // signal must opt the record into archived workspace owners.
      await workspaceRegistry.upsert(
        _workspace(
          '/tmp/repo',
          'ws-archived',
          archivedAt: '2026-03-02T00:00:00.000Z',
        ),
      );
      await seedLegacyAgent(
        '/tmp/repo',
        'timestamp-only-agent',
        archivedAt: '2026-03-02T12:00:00.000Z',
      );

      expect(await run(), 1);
      expect(await storedWorkspaceId('timestamp-only-agent'), 'ws-archived');
    });

    test('does not stamp live agents from archived workspace owners', () async {
      await workspaceRegistry.upsert(
        _workspace(
          '/tmp/repo',
          'ws-archived',
          archivedAt: '2026-03-02T00:00:00.000Z',
        ),
      );
      await seedLegacyAgent('/tmp/repo', 'legacy-agent');

      expect(await run(), 0);
      expect(await storedWorkspaceId('legacy-agent'), isNull);
    });

    test('does not let the home directory own descendants', () async {
      await workspaceRegistry.upsert(_workspace(_fakeHome, 'ws-home'));
      await seedLegacyAgent(p.join(_fakeHome, 'repo'), 'legacy-agent');

      expect(await run(), 0);
      expect(await storedWorkspaceId('legacy-agent'), isNull);
      expect(logs, isEmpty);
    });

    test('migrates several records and reports the count once', () async {
      await workspaceRegistry.upsert(_workspace('/tmp/repo', 'ws-root'));
      await workspaceRegistry.upsert(
        _workspace(p.join('/tmp/repo', 'app'), 'ws-app'),
      );
      await seedLegacyAgent('/tmp/repo', 'agent-a');
      await seedLegacyAgent(p.join('/tmp/repo', 'app', 'lib'), 'agent-b');
      await seedLegacyAgent('/elsewhere/entirely', 'agent-unowned');

      expect(await run(), 2);
      expect(await storedWorkspaceId('agent-a'), 'ws-root');
      expect(await storedWorkspaceId('agent-b'), 'ws-app');
      expect(await storedWorkspaceId('agent-unowned'), isNull);
      expect(logs, ['Backfilled workspaceId for 2 legacy agent records']);
    });

    test('preserves every other persisted field while stamping', () async {
      await workspaceRegistry.upsert(_workspace('/tmp/repo', 'ws-cwd'));
      await agentStore.save(
        _agent(
          agentId: 'rich-agent',
          cwd: '/tmp/repo',
          title: 'Rich Agent',
          epoch: 7,
          lastSeq: 42,
          internal: false,
          environment: const {'FOO': 'bar'},
        ),
      );

      expect(await run(), 1);

      final stored = (await agentStore.loadAll()).single;
      expect(stored.summary.workspaceId, 'ws-cwd');
      expect(stored.summary.title, 'Rich Agent');
      expect(stored.epoch, 7);
      expect(stored.lastSeq, 42);
      expect(stored.environment, {'FOO': 'bar'});
    });

    test('is idempotent across repeated runs', () async {
      await workspaceRegistry.upsert(_workspace('/tmp/repo', 'ws-cwd'));
      await seedLegacyAgent('/tmp/repo', 'legacy-agent');

      expect(await run(), 1);
      expect(await run(), 0);
      expect(await storedWorkspaceId('legacy-agent'), 'ws-cwd');
    });

    test('reports zero and stays silent with no records at all', () async {
      expect(await run(), 0);
      expect(logs, isEmpty);
    });

    test('tolerates a missing log callback', () async {
      await workspaceRegistry.upsert(_workspace('/tmp/repo', 'ws-cwd'));
      await seedLegacyAgent('/tmp/repo', 'legacy-agent');

      expect(
        await backfillWorkspaceIdForLegacyAgents(
          agentStore: agentStore,
          workspaceRegistry: workspaceRegistry,
          homeDirectory: _fakeHome,
        ),
        1,
      );
    });
  });
}

/// A home directory that is guaranteed not to enclose the synthetic
/// `/workspace` and `/tmp` fixtures, so the home rule can be tested without
/// depending on where the suite actually runs.
final String _fakeHome = p.join('/paseo-identity-fake-home', 'tester');

PersistedWorkspaceRecord _workspace(
  String cwd,
  String workspaceId, {
  String? createdAt,
  String? archivedAt,
}) => createPersistedWorkspaceRecord(
  workspaceId: workspaceId,
  projectId: workspaceId,
  cwd: cwd,
  kind: PersistedWorkspaceKind.directory,
  displayName: p.basename(cwd).isEmpty ? cwd : p.basename(cwd),
  createdAt: createdAt ?? '2026-03-01T00:00:00.000Z',
  updatedAt: createdAt ?? '2026-03-01T00:00:00.000Z',
  archivedAt: archivedAt,
);

PersistedAgent _agent({
  required String agentId,
  required String cwd,
  String title = 'Legacy Agent',
  bool archived = false,
  String? archivedAt,
  String? workspaceId,
  int epoch = 1,
  int lastSeq = 0,
  bool internal = false,
  Map<String, String> environment = const {},
}) => PersistedAgent(
  summary: AgentSummary(
    agentId: agentId,
    title: title,
    cwd: cwd,
    provider: 'codex',
    model: 'gpt-5',
    mode: AgentMode.normal,
    runState: AgentRunState.closed,
    createdAtMs: 1772366400000,
    workspaceId: workspaceId,
    archivedAt: archivedAt,
  ),
  archived: archived,
  epoch: epoch,
  lastSeq: lastSeq,
  items: const [],
  internal: internal,
  environment: environment,
);
