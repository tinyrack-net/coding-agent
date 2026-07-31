// Port of the frozen Paseo 0.2.0 suites
// `packages/app/src/utils/workspace-directory.test.ts`,
// `explorer-paths.test.ts`, `workspace-identity.test.ts`,
// `project-placement.test.ts`, `workspace-archive-navigation.test.ts` and
// `workspace-script-links.test.ts`.
//
// Every upstream case appears below under the same public symbol. Cases marked
// `// extra:` are not in the upstream suites — they pin behavior the frozen
// modules have but never assert (JS truthiness vs. nullish coalescing, the
// separator-flavour inference, `new URL` parse failures, bracketed IPv6
// hostnames, target de-duplication, and the degenerate `/` workspace root).
//
// `redirectIfArchivingActiveWorkspace`, which shares the upstream
// archive-navigation suite, belongs to `utils/workspace-archive-redirect.ts` —
// a different module, outside this cluster — so it is not ported here.

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/workspace/paseo_workspace_paths.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Builders — the Dart analogues of the upstream suites' `createWorkspace()`,
// `workspace()` and `runningService` fixtures.
// ---------------------------------------------------------------------------

WorkspaceDescriptor descriptor(
  String id, {
  String projectId = 'project-1',
  String projectDisplayName = 'Project',
  String projectRootPath = '/repo',
  String? workspaceDirectory,
  WorkspaceProjectKind projectKind = WorkspaceProjectKind.git,
  WorkspaceKind workspaceKind = WorkspaceKind.worktree,
  String? name,
  WorkspaceStateBucket status = WorkspaceStateBucket.done,
}) => WorkspaceDescriptor(
  id: id,
  projectId: projectId,
  projectDisplayName: projectDisplayName,
  projectRootPath: projectRootPath,
  workspaceDirectory: workspaceDirectory ?? projectRootPath,
  projectKind: projectKind,
  workspaceKind: workspaceKind,
  name: name ?? id,
  status: status,
  activityAt: null,
);

const String paseoProxyUrl = 'http://web--feature--paseo.localhost:6767';
const String publicProxyUrl =
    'https://web--feature--paseo.services.example.com';

WorkspaceScript service({
  WorkspaceScriptType type = WorkspaceScriptType.service,
  WorkspaceScriptLifecycle lifecycle = WorkspaceScriptLifecycle.running,
  int? port = 3000,
  String? localProxyUrl = paseoProxyUrl,
  String? publicUrl,
  String? proxyUrl = paseoProxyUrl,
}) => WorkspaceScript(
  scriptName: 'web',
  type: type,
  hostname: 'web--feature--paseo.localhost',
  port: port,
  localProxyUrl: localProxyUrl,
  publicProxyUrl: publicUrl,
  proxyUrl: proxyUrl,
  lifecycle: lifecycle,
  health: WorkspaceScriptHealth.healthy,
);

ResolvedWorkspaceScriptLink resolveLink(
  ActiveConnection? activeConnection, [
  WorkspaceScript? script,
]) => resolveWorkspaceScriptLink(
  script: script ?? service(),
  activeConnection: activeConnection,
);

WorkspaceScriptLinkTarget target(
  WorkspaceScriptLinkKind kind,
  String label,
  String url,
) => WorkspaceScriptLinkTarget(kind: kind, label: label, url: url);

final WorkspaceScriptLinkTarget paseoTarget = target(
  WorkspaceScriptLinkKind.paseo,
  'web--feature--paseo.localhost:6767',
  paseoProxyUrl,
);

final WorkspaceScriptLinkTarget publicTarget = target(
  WorkspaceScriptLinkKind.public,
  'web--feature--paseo.services.example.com',
  publicProxyUrl,
);

final WorkspaceScriptLinkTarget localhostDirectTarget = target(
  WorkspaceScriptLinkKind.direct,
  'localhost:3000',
  'http://localhost:3000',
);

void main() {
  // =========================================================================
  // utils/workspace-identity.ts
  // =========================================================================

  group('resolveWorkspaceRouteId', () {
    test('trims route workspace ids without path normalization', () {
      expect(
        resolveWorkspaceRouteId(routeWorkspaceId: '  C:\\tmp\\repo\\  '),
        'C:\\tmp\\repo\\',
      );
    });

    test('returns null for empty values', () {
      expect(resolveWorkspaceRouteId(routeWorkspaceId: '   '), isNull);
    });

    // extra: the Dart signature admits null where the TS one admits
    // `null | undefined`; both mean "no route parameter".
    test('returns null for a missing route parameter', () {
      expect(resolveWorkspaceRouteId(routeWorkspaceId: null), isNull);
      expect(resolveWorkspaceRouteId(routeWorkspaceId: ''), isNull);
    });

    // extra: `String.trim` and JS `trim` agree on tabs and newlines, so an id
    // pasted with stray whitespace still resolves.
    test('trims tabs and newlines as well as spaces', () {
      expect(
        resolveWorkspaceRouteId(routeWorkspaceId: '\t\nwks_1\r\n '),
        'wks_1',
      );
      expect(resolveWorkspaceRouteId(routeWorkspaceId: '\t\n '), isNull);
    });
  });

  group('normalizeWorkspaceOpaqueId', () {
    // extra: the opaque rule must stay trim-only — this is the guard that keeps
    // it from drifting into `normalizeWorkspacePath`.
    test('leaves separators and trailing slashes alone', () {
      expect(
        normalizeWorkspaceOpaqueId(' C:\\repo\\app\\ '),
        'C:\\repo\\app\\',
      );
      expect(normalizeWorkspaceOpaqueId('/repo/app/'), '/repo/app/');
      expect(normalizeWorkspaceOpaqueId('workspace-1'), 'workspace-1');
    });

    test('returns null for blank and missing values', () {
      expect(normalizeWorkspaceOpaqueId(null), isNull);
      expect(normalizeWorkspaceOpaqueId('  '), isNull);
    });
  });

  group('normalizeWorkspacePath', () {
    // extra: the path rule is only asserted upstream through
    // `resolveWorkspaceDirectory`; these pin it directly.
    test('canonicalizes separators and drops trailing slashes', () {
      expect(normalizeWorkspacePath('C:\\repo\\app\\'), 'C:/repo/app');
      expect(normalizeWorkspacePath('/repo/app//'), '/repo/app');
      expect(normalizeWorkspacePath('  C:/repo\\app/  '), 'C:/repo/app');
    });

    test('keeps the bare root rather than collapsing it to nothing', () {
      expect(normalizeWorkspacePath('/'), '/');
      expect(normalizeWorkspacePath('///'), '/');
      // `\\` becomes `//`, which is all-trailing-slash, so it collapses to the
      // root too rather than to the empty string.
      expect(normalizeWorkspacePath('\\\\'), '/');
    });

    test('returns null for blank and missing values', () {
      expect(normalizeWorkspacePath(null), isNull);
      expect(normalizeWorkspacePath('   '), isNull);
    });
  });

  group('resolveWorkspaceMapKeyByIdentity', () {
    test(
      'returns the existing map key when the identity already matches a key',
      () {
        final workspaces = <String, WorkspaceDescriptor>{
          'workspace-1': descriptor(
            'workspace-1',
            workspaceDirectory: '/repo/.paseo/worktrees/feature',
          ),
        };

        expect(
          resolveWorkspaceMapKeyByIdentity(
            workspaces: workspaces,
            workspaceId: 'workspace-1',
          ),
          'workspace-1',
        );
      },
    );

    test('does not resolve workspace directories when an id is required', () {
      final workspaces = <String, WorkspaceDescriptor>{
        'workspace-1': descriptor(
          'workspace-1',
          workspaceDirectory: 'C:\\repo\\feature\\',
        ),
      };

      expect(
        resolveWorkspaceMapKeyByIdentity(
          workspaces: workspaces,
          workspaceId: 'C:/repo/feature',
        ),
        isNull,
      );
    });

    // extra: the fallback scan is upstream's second lookup but is never
    // exercised by the frozen suite.
    test('falls back to scanning descriptor ids when the key differs', () {
      final workspaces = <String, WorkspaceDescriptor>{
        'server-1:workspace-1': descriptor('workspace-1'),
        'server-1:workspace-2': descriptor('workspace-2'),
      };

      expect(
        resolveWorkspaceMapKeyByIdentity(
          workspaces: workspaces,
          workspaceId: 'workspace-2',
        ),
        'server-1:workspace-2',
      );
    });

    // extra: both sides of the scan are trimmed, so padding on either the
    // lookup id or the stored descriptor still matches.
    test('trims both the lookup id and the scanned descriptor id', () {
      final workspaces = <String, WorkspaceDescriptor>{
        'key-1': descriptor('  workspace-1  '),
      };

      expect(
        resolveWorkspaceMapKeyByIdentity(
          workspaces: workspaces,
          workspaceId: ' workspace-1 ',
        ),
        'key-1',
      );
    });

    // extra: the direct key hit wins over the scan even when a later entry also
    // claims the id, and the scan itself takes the first insertion-order match.
    test('prefers the direct key hit, then the first inserted match', () {
      final direct = <String, WorkspaceDescriptor>{
        'workspace-1': descriptor('other'),
        'key-2': descriptor('workspace-1'),
      };
      expect(
        resolveWorkspaceMapKeyByIdentity(
          workspaces: direct,
          workspaceId: 'workspace-1',
        ),
        'workspace-1',
      );

      final scanned = <String, WorkspaceDescriptor>{
        'key-1': descriptor('shared'),
        'key-2': descriptor('shared'),
      };
      expect(
        resolveWorkspaceMapKeyByIdentity(
          workspaces: scanned,
          workspaceId: 'shared',
        ),
        'key-1',
      );
    });

    // extra: both "no map" and "no id" short-circuit to null.
    test('returns null without a map or without an id', () {
      expect(
        resolveWorkspaceMapKeyByIdentity(
          workspaces: null,
          workspaceId: 'workspace-1',
        ),
        isNull,
      );
      expect(
        resolveWorkspaceMapKeyByIdentity(
          workspaces: <String, WorkspaceDescriptor>{
            'workspace-1': descriptor('workspace-1'),
          },
          workspaceId: '   ',
        ),
        isNull,
      );
      expect(
        resolveWorkspaceMapKeyByIdentity(
          workspaces: <String, WorkspaceDescriptor>{},
          workspaceId: 'workspace-1',
        ),
        isNull,
      );
    });
  });

  // =========================================================================
  // utils/workspace-directory.ts
  // =========================================================================

  group('resolveWorkspaceDirectory', () {
    test('canonicalizes a workspace directory and returns null when blank', () {
      expect(
        resolveWorkspaceDirectory(workspaceDirectory: 'C:\\repo\\app\\'),
        'C:/repo/app',
      );
      expect(resolveWorkspaceDirectory(workspaceDirectory: '   '), isNull);
    });

    // extra: a missing directory is the same as a blank one.
    test('returns null for a missing directory', () {
      expect(resolveWorkspaceDirectory(workspaceDirectory: null), isNull);
    });
  });

  group('requireWorkspaceDirectory', () {
    test('returns the canonical directory when present', () {
      expect(
        requireWorkspaceDirectory(workspaceDirectory: '/repo/app/'),
        '/repo/app',
      );
    });

    test('throws naming the workspace when the directory is missing', () {
      expect(
        () => requireWorkspaceDirectory(
          workspaceId: 'wks_1',
          workspaceDirectory: '  ',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Workspace directory is missing for workspace wks_1',
          ),
        ),
      );
    });

    // extra: upstream picks the message with a JS truthiness test, so an empty
    // id must produce the generic message rather than a dangling "for
    // workspace ".
    test('throws the generic message without a usable workspace id', () {
      for (final workspaceId in <String?>[null, '']) {
        expect(
          () => requireWorkspaceDirectory(
            workspaceId: workspaceId,
            workspaceDirectory: null,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'Workspace directory is missing.',
            ),
          ),
        );
      }
    });

    // extra: a whitespace-only id is *truthy* in JS, so it does reach the
    // named message.
    test('treats a whitespace-only workspace id as present', () {
      expect(
        () =>
            requireWorkspaceDirectory(workspaceId: ' ', workspaceDirectory: ''),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Workspace directory is missing for workspace  ',
          ),
        ),
      );
    });

    // extra: the root survives the "must exist" check instead of being read as
    // absent.
    test('accepts the bare root as a present directory', () {
      expect(requireWorkspaceDirectory(workspaceDirectory: '///'), '/');
    });
  });

  // =========================================================================
  // utils/explorer-paths.ts
  // =========================================================================

  group('buildAbsoluteExplorerPath', () {
    test('builds a POSIX absolute path from a relative explorer path', () {
      expect(
        buildAbsoluteExplorerPath(
          workspaceRoot: '/workspaces/paseo',
          entryPath: 'packages/app/src/components/file-explorer-pane.tsx',
        ),
        '/workspaces/paseo/packages/app/src/components/file-explorer-pane.tsx',
      );
    });

    test('returns workspace root when entry path points to explorer root', () {
      expect(
        buildAbsoluteExplorerPath(
          workspaceRoot: '/workspaces/paseo',
          entryPath: '.',
        ),
        '/workspaces/paseo',
      );
    });

    test('trims trailing separators from workspace root before joining', () {
      expect(
        buildAbsoluteExplorerPath(
          workspaceRoot: '/workspaces/paseo/',
          entryPath: 'README.md',
        ),
        '/workspaces/paseo/README.md',
      );
    });

    test('builds a Windows absolute path with backslash separators', () {
      expect(
        buildAbsoluteExplorerPath(
          workspaceRoot: 'C:\\repo\\paseo',
          entryPath: 'packages/app/src/components/file-explorer-pane.tsx',
        ),
        'C:\\repo\\paseo\\packages\\app\\src\\components\\'
        'file-explorer-pane.tsx',
      );
    });

    test('passes through an already-absolute entry path', () {
      expect(
        buildAbsoluteExplorerPath(
          workspaceRoot: '/workspaces/paseo',
          entryPath: '/tmp/another/location.txt',
        ),
        '/tmp/another/location.txt',
      );
    });

    // extra: with no root there is nothing to join onto, so the entry path is
    // returned as-is even though it is not absolute.
    test('returns the entry path when the workspace root is blank', () {
      expect(
        buildAbsoluteExplorerPath(workspaceRoot: '   ', entryPath: ' a/b.txt '),
        'a/b.txt',
      );
    });

    // extra: the Unix root is *entirely* trailing separator, so it normalizes
    // to blank and takes the branch above. Surprising, and worth pinning.
    test('treats a bare "/" workspace root as blank', () {
      expect(
        buildAbsoluteExplorerPath(workspaceRoot: '/', entryPath: 'README.md'),
        'README.md',
      );
    });

    // extra: an empty entry path is the explorer root, same as ".".
    test('returns the workspace root for a blank entry path', () {
      expect(
        buildAbsoluteExplorerPath(workspaceRoot: '/repo/', entryPath: '   '),
        '/repo',
      );
    });

    // extra: a separators-only entry path survives the split with no segments.
    // It has to be a *lone* backslash to get that far: `/…` and `\\…` are both
    // absolute-path spellings and short-circuit above.
    test(
      'returns the workspace root when the entry path is all separators',
      () {
        expect(
          buildAbsoluteExplorerPath(workspaceRoot: 'C:\\repo', entryPath: r'\'),
          'C:\\repo',
        );
        expect(
          buildAbsoluteExplorerPath(
            workspaceRoot: 'C:\\repo',
            entryPath: r'\\',
          ),
          r'\\',
        );
        expect(
          buildAbsoluteExplorerPath(workspaceRoot: 'C:\\repo', entryPath: '//'),
          '//',
        );
      },
    );

    // extra: repeated and mixed separators collapse into the root's flavour.
    test('collapses repeated and mixed separators', () {
      expect(
        buildAbsoluteExplorerPath(
          workspaceRoot: '/repo',
          entryPath: 'a//b\\\\c',
        ),
        '/repo/a/b/c',
      );
      expect(
        buildAbsoluteExplorerPath(
          workspaceRoot: 'C:\\repo',
          entryPath: 'a/b//c',
        ),
        'C:\\repo\\a\\b\\c',
      );
    });

    // extra: the separator is chosen by the root's own spelling, not by the
    // host platform — a POSIX-looking root joins with "/" even on Windows.
    test('infers the separator from the workspace root, not the platform', () {
      expect(
        buildAbsoluteExplorerPath(workspaceRoot: 'C:/repo', entryPath: 'a/b'),
        'C:/repo/a/b',
      );
    });

    // extra: all three absolute-path spellings `isAbsolutePath` recognizes pass
    // straight through.
    test('passes through UNC and drive-letter absolute entry paths', () {
      expect(
        buildAbsoluteExplorerPath(
          workspaceRoot: 'C:\\repo',
          entryPath: '\\\\server\\share\\file.txt',
        ),
        '\\\\server\\share\\file.txt',
      );
      expect(
        buildAbsoluteExplorerPath(
          workspaceRoot: '/repo',
          entryPath: 'D:/other/file.txt',
        ),
        'D:/other/file.txt',
      );
    });

    // extra: both inputs are trimmed before anything else happens.
    test('trims both inputs', () {
      expect(
        buildAbsoluteExplorerPath(
          workspaceRoot: '  /repo//  ',
          entryPath: '  README.md  ',
        ),
        '/repo/README.md',
      );
    });
  });

  // =========================================================================
  // utils/project-placement.ts
  // =========================================================================

  group('deriveProjectPlacementFromCwd', () {
    test('derives fallback placement from cwd', () {
      final placement = deriveProjectPlacementFromCwd('/Users/test/repo');

      expect(placement.projectKey, '/Users/test/repo');
      expect(placement.projectName, 'repo');
      expect(placement.checkout.cwd, '/Users/test/repo');
      expect(placement.checkout.isGit, isFalse);
    });

    test('normalizes paseo worktree paths into the parent repo key', () {
      final placement = deriveProjectPlacementFromCwd(
        '/Users/test/repo/.paseo/worktrees/feature-x',
      );

      expect(placement.projectKey, '/Users/test/repo');
      expect(placement.projectName, 'repo');
      expect(
        placement.checkout.cwd,
        '/Users/test/repo/.paseo/worktrees/feature-x',
      );
    });

    // extra: the fallback checkout is the non-git member of the union, so every
    // git-only field is pinned null — including `worktreeRoot`, which the two
    // git members would have defaulted to `cwd`.
    test('produces a fully non-git checkout with no workspace name', () {
      final placement = deriveProjectPlacementFromCwd('/Users/test/repo');

      expect(placement.workspaceName, isNull);
      expect(placement.checkout, isA<NotGitProjectCheckout>());
      expect(placement.checkout.isPaseoOwnedWorktree, isFalse);
      expect(placement.checkout.currentBranch, isNull);
      expect(placement.checkout.remoteUrl, isNull);
      expect(placement.checkout.worktreeRoot, isNull);
      expect(placement.checkout.mainRepoRoot, isNull);
    });

    // extra: a blank cwd becomes ".", so the key is never empty and the name
    // never falls back to the whole key.
    test('substitutes "." for a blank cwd', () {
      for (final cwd in <String>['', '   ']) {
        final placement = deriveProjectPlacementFromCwd(cwd);
        expect(placement.projectKey, '.');
        expect(placement.projectName, '.');
        expect(placement.checkout.cwd, '.');
      }
    });

    // extra: the cwd is trimmed before the worktree marker is looked for.
    test('trims the cwd before deriving the key', () {
      final placement = deriveProjectPlacementFromCwd(
        '  /Users/test/repo/.paseo/worktrees/feature-x  ',
      );
      expect(placement.projectKey, '/Users/test/repo');
      expect(
        placement.checkout.cwd,
        '/Users/test/repo/.paseo/worktrees/feature-x',
      );
    });

    // extra: `deriveProjectKey` strips exactly one trailing slash, matching
    // upstream's non-global `/\/$/`, so a doubled separator keeps one.
    test('strips only one separator before the worktree marker', () {
      expect(
        deriveProjectPlacementFromCwd(
          '/Users/test/repo//.paseo/worktrees/feature-x',
        ).projectKey,
        '/Users/test/repo/',
      );
    });

    // extra: a Windows cwd has no `.paseo/worktrees/` match (the marker is
    // forward-slashed), so the whole path becomes the key.
    test('leaves a backslash-spelled worktree path ungrouped', () {
      final placement = deriveProjectPlacementFromCwd(
        r'C:\repo\.paseo\worktrees\feature-x',
      );
      expect(placement.projectKey, r'C:\repo\.paseo\worktrees\feature-x');
      expect(placement.projectName, r'C:\repo\.paseo\worktrees\feature-x');
    });
  });

  group('resolveProjectPlacement', () {
    test('prefers an existing placement when present', () {
      final existing = ProjectPlacement(
        projectKey: 'remote:github.com/acme/repo',
        projectName: 'acme/repo',
        workspaceName: null,
        checkout: GitProjectCheckout(
          cwd: '/Users/test/repo',
          currentBranch: 'main',
          remoteUrl: 'https://github.com/acme/repo.git',
          worktreeRoot: '/Users/test/repo',
        ),
      );

      final resolved = resolveProjectPlacement(
        projectPlacement: existing,
        cwd: '/Users/test/repo',
      );

      expect(identical(resolved, existing), isTrue);
    });

    // extra: the fallback path is the same object `deriveProjectPlacementFromCwd`
    // would build.
    test('derives from the cwd when no placement was sent', () {
      final resolved = resolveProjectPlacement(
        projectPlacement: null,
        cwd: '/Users/test/repo/.paseo/worktrees/feature-x',
      );

      expect(resolved.projectKey, '/Users/test/repo');
      expect(resolved.checkout, isA<NotGitProjectCheckout>());
    });
  });

  group('ProjectCheckoutLite', () {
    // extra: upstream's zod transform defaults `worktreeRoot` to `cwd` for both
    // git members; the sealed port applies it in the constructor.
    test('defaults the worktree root of a git checkout to its cwd', () {
      final nonPaseo = GitProjectCheckout(
        cwd: '/repo',
        currentBranch: null,
        remoteUrl: null,
      );
      expect(nonPaseo.worktreeRoot, '/repo');
      expect(nonPaseo.isGit, isTrue);
      expect(nonPaseo.isPaseoOwnedWorktree, isFalse);
      expect(nonPaseo.mainRepoRoot, isNull);

      final paseo = PaseoWorktreeProjectCheckout(
        cwd: '/repo/.paseo/worktrees/feature',
        currentBranch: 'feature',
        remoteUrl: null,
        mainRepoRoot: '/repo',
      );
      expect(paseo.worktreeRoot, '/repo/.paseo/worktrees/feature');
      expect(paseo.isGit, isTrue);
      expect(paseo.isPaseoOwnedWorktree, isTrue);
      expect(paseo.mainRepoRoot, '/repo');
    });

    test('keeps an explicit worktree root', () {
      expect(
        GitProjectCheckout(
          cwd: '/repo/sub',
          currentBranch: null,
          remoteUrl: null,
          worktreeRoot: '/repo',
        ).worktreeRoot,
        '/repo',
      );
    });
  });

  // =========================================================================
  // utils/workspace-archive-navigation.ts
  // =========================================================================

  group('buildWorkspaceArchiveRedirectRoute', () {
    test('redirects an archived worktree to the new workspace screen for the '
        'same project', () {
      final workspaces = <WorkspaceDescriptor>[
        descriptor(
          '/repo',
          workspaceKind: WorkspaceKind.checkout,
          name: 'main',
        ),
        descriptor('/repo/.paseo/worktrees/feature', name: 'feature'),
      ];

      expect(
        buildWorkspaceArchiveRedirectRoute(
          serverId: 'server-1',
          archivedWorkspaceId: '/repo/.paseo/worktrees/feature',
          workspaces: workspaces,
        ),
        '/new?serverId=server-1&dir=%2Frepo&name=Project&projectId=project-1',
      );
    });

    test('redirects to the new workspace route when no sibling workspace '
        'target exists', () {
      final workspaces = <WorkspaceDescriptor>[
        descriptor(
          '/repo/.paseo/worktrees/feature',
          name: 'feature',
          projectRootPath: '/repo',
        ),
      ];

      expect(
        buildWorkspaceArchiveRedirectRoute(
          serverId: 'server-1',
          archivedWorkspaceId: '/repo/.paseo/worktrees/feature',
          workspaces: workspaces,
        ),
        '/new?serverId=server-1&dir=%2Frepo&name=Project&projectId=project-1',
      );
    });

    test(
      'redirects to the new workspace route instead of another workspace',
      () {
        final workspaces = <WorkspaceDescriptor>[
          descriptor(
            '/notes',
            projectId: 'notes',
            projectRootPath: '/notes',
            projectKind: WorkspaceProjectKind.directory,
            workspaceKind: WorkspaceKind.checkout,
          ),
        ];

        expect(
          buildWorkspaceArchiveRedirectRoute(
            serverId: 'server-1',
            archivedWorkspaceId: '/notes',
            workspaces: workspaces,
          ),
          '/new?serverId=server-1&dir=%2Fnotes&name=Project&projectId=notes',
        );
      },
    );

    // extra: the two host-root fallbacks are never taken upstream.
    test('falls back to the host root for a blank or unknown archived id', () {
      final workspaces = <WorkspaceDescriptor>[descriptor('/repo')];

      expect(
        buildWorkspaceArchiveRedirectRoute(
          serverId: 'server-1',
          archivedWorkspaceId: '   ',
          workspaces: workspaces,
        ),
        '/h/server-1',
      );
      expect(
        buildWorkspaceArchiveRedirectRoute(
          serverId: 'server-1',
          archivedWorkspaceId: '/missing',
          workspaces: workspaces,
        ),
        '/h/server-1',
      );
      expect(
        buildWorkspaceArchiveRedirectRoute(
          serverId: 'server-1',
          archivedWorkspaceId: '/repo',
          workspaces: const <WorkspaceDescriptor>[],
        ),
        '/h/server-1',
      );
    });

    // extra: JS `||` makes an empty project root fall through to the workspace
    // directory, and only a *pair* of empties reaches the host root.
    test('falls back to the workspace directory when the project root is '
        'empty', () {
      expect(
        buildWorkspaceArchiveRedirectRoute(
          serverId: 'server-1',
          archivedWorkspaceId: '/repo/feature',
          workspaces: <WorkspaceDescriptor>[
            descriptor(
              '/repo/feature',
              projectRootPath: '',
              workspaceDirectory: '/repo/feature',
            ),
          ],
        ),
        '/new?serverId=server-1&dir=%2Frepo%2Ffeature&name=Project'
        '&projectId=project-1',
      );

      expect(
        buildWorkspaceArchiveRedirectRoute(
          serverId: 'server-1',
          archivedWorkspaceId: '/repo/feature',
          workspaces: <WorkspaceDescriptor>[
            descriptor(
              '/repo/feature',
              projectRootPath: '',
              workspaceDirectory: '',
            ),
          ],
        ),
        '/h/server-1',
      );
    });

    // extra: the archived id is trimmed, but descriptor ids are compared
    // verbatim — a trailing slash on the stored id is a different workspace.
    test('trims the archived id but matches descriptor ids verbatim', () {
      expect(
        buildWorkspaceArchiveRedirectRoute(
          serverId: 'server-1',
          archivedWorkspaceId: '  /repo  ',
          workspaces: <WorkspaceDescriptor>[descriptor('/repo')],
        ),
        '/new?serverId=server-1&dir=%2Frepo&name=Project&projectId=project-1',
      );

      expect(
        buildWorkspaceArchiveRedirectRoute(
          serverId: 'server-1',
          archivedWorkspaceId: '/repo',
          workspaces: <WorkspaceDescriptor>[descriptor('/repo/')],
        ),
        '/h/server-1',
      );
    });

    // extra: an empty display name or project id is dropped from the query by
    // `buildNewWorkspaceRoute`, and a blank server id collapses the host-root
    // fallback to "/".
    test('omits empty query values and degrades a blank server id', () {
      expect(
        buildWorkspaceArchiveRedirectRoute(
          serverId: '  ',
          archivedWorkspaceId: '/repo',
          workspaces: <WorkspaceDescriptor>[
            descriptor('/repo', projectDisplayName: '', projectId: ''),
          ],
        ),
        '/new?dir=%2Frepo',
      );
      expect(
        buildWorkspaceArchiveRedirectRoute(
          serverId: '  ',
          archivedWorkspaceId: '  ',
          workspaces: const <WorkspaceDescriptor>[],
        ),
        '/',
      );
    });
  });

  // =========================================================================
  // utils/workspace-script-links.ts
  // =========================================================================

  group('resolveWorkspaceScriptLink', () {
    test('defaults to the memorable Paseo URL locally and keeps direct as a '
        'fallback', () {
      expect(
        resolveLink(
          const DirectTcpActiveConnection(
            endpoint: 'localhost:6767',
            display: 'localhost:6767',
          ),
        ),
        ResolvedWorkspaceScriptLink(
          primary: paseoTarget,
          targets: [paseoTarget, localhostDirectTarget],
        ),
      );
    });

    test('defaults to an explicitly configured reverse proxy', () {
      expect(
        resolveLink(
          const DirectSocketActiveConnection(endpoint: '/tmp/paseo.sock'),
          service(publicUrl: publicProxyUrl, proxyUrl: publicProxyUrl),
        ),
        ResolvedWorkspaceScriptLink(
          primary: publicTarget,
          targets: [publicTarget, paseoTarget, localhostDirectTarget],
        ),
      );
    });

    test('uses the daemon host and service port over a direct network '
        'connection', () {
      final remoteDirectTarget = target(
        WorkspaceScriptLinkKind.direct,
        'mac-mini.tail123.ts.net:3000',
        'http://mac-mini.tail123.ts.net:3000',
      );

      expect(
        resolveLink(
          const DirectTcpActiveConnection(
            endpoint: 'mac-mini.tail123.ts.net:6767',
            display: 'mac-mini.tail123.ts.net:6767',
          ),
        ),
        ResolvedWorkspaceScriptLink(
          primary: paseoTarget,
          targets: [paseoTarget, remoteDirectTarget],
        ),
      );
    });

    test('offers the reverse proxy and direct route over a direct network '
        'connection', () {
      expect(
        resolveLink(
          const DirectTcpActiveConnection(
            endpoint: 'mac-mini.tail123.ts.net:6767',
            display: 'remote',
          ),
          service(publicUrl: publicProxyUrl, proxyUrl: publicProxyUrl),
        ).targets,
        [
          publicTarget,
          paseoTarget,
          target(
            WorkspaceScriptLinkKind.direct,
            'mac-mini.tail123.ts.net:3000',
            'http://mac-mini.tail123.ts.net:3000',
          ),
        ],
      );
    });

    test(
      'keeps service routes available independently of a relay connection',
      () {
        const relay = RelayActiveConnection(endpoint: 'relay.paseo.sh:443');

        expect(
          resolveLink(relay),
          ResolvedWorkspaceScriptLink(
            primary: paseoTarget,
            targets: [paseoTarget, localhostDirectTarget],
          ),
        );

        expect(
          resolveLink(
            relay,
            service(publicUrl: publicProxyUrl, proxyUrl: publicProxyUrl),
          ),
          ResolvedWorkspaceScriptLink(
            primary: publicTarget,
            targets: [publicTarget, paseoTarget, localhostDirectTarget],
          ),
        );
      },
    );

    test('classifies proxyUrl from older daemons', () {
      final legacyLocal = service(localProxyUrl: null);

      expect(resolveLink(null, legacyLocal).targets.map((t) => t.kind), [
        WorkspaceScriptLinkKind.paseo,
        WorkspaceScriptLinkKind.direct,
      ]);

      expect(
        resolveLink(
          const RelayActiveConnection(endpoint: 'relay.paseo.sh:443'),
          service(localProxyUrl: null, proxyUrl: publicProxyUrl),
        ).primary,
        publicTarget,
      );
    });

    test('has no routes for stopped services or plain scripts', () {
      expect(
        resolveLink(null, service(lifecycle: WorkspaceScriptLifecycle.stopped)),
        const ResolvedWorkspaceScriptLink(primary: null, targets: []),
      );
      expect(
        resolveLink(null, service(type: WorkspaceScriptType.script)),
        const ResolvedWorkspaceScriptLink(primary: null, targets: []),
      );
    });

    // extra: a service with no port and no proxies has nowhere to go.
    test('produces no targets when there is no port and no proxy', () {
      expect(
        resolveLink(
          null,
          service(port: null, localProxyUrl: null, proxyUrl: null),
        ),
        const ResolvedWorkspaceScriptLink(primary: null, targets: []),
      );
    });

    // extra: `port: null` suppresses only the direct target.
    test('omits the direct target when the service has no port', () {
      expect(resolveLink(null, service(port: null)).targets, [paseoTarget]);
    });

    // extra: de-duplication is by URL, so a daemon reporting the same address
    // as both proxies contributes one chip — and it keeps the first (public)
    // classification.
    test('de-duplicates targets that share a URL', () {
      final resolved = resolveLink(
        null,
        service(
          localProxyUrl: paseoProxyUrl,
          publicUrl: paseoProxyUrl,
          proxyUrl: paseoProxyUrl,
        ),
      );

      expect(resolved.targets, [
        target(
          WorkspaceScriptLinkKind.public,
          'web--feature--paseo.localhost:6767',
          paseoProxyUrl,
        ),
        localhostDirectTarget,
      ]);
      expect(resolved.primary, resolved.targets.first);
    });

    // extra: an explicit `publicProxyUrl` wins even when the legacy `proxyUrl`
    // would have been classified local — `??` only fills in a *missing* value.
    test('never re-classifies an explicitly supplied split URL', () {
      final resolved = resolveLink(
        null,
        service(
          localProxyUrl: null,
          publicUrl: paseoProxyUrl,
          proxyUrl: paseoProxyUrl,
        ),
      );

      // `localProxyUrl` is absent, so the legacy `proxyUrl` fills it; the
      // explicit `publicProxyUrl` is added first and the duplicate is dropped.
      expect(resolved.targets.map((t) => t.kind), [
        WorkspaceScriptLinkKind.public,
        WorkspaceScriptLinkKind.direct,
      ]);
    });

    // extra: every non-TCP transport, plus "no connection at all", assumes
    // localhost for the direct target.
    test('assumes localhost for every non-TCP transport', () {
      for (final connection in <ActiveConnection?>[
        null,
        const DirectSocketActiveConnection(endpoint: '/tmp/paseo.sock'),
        const DirectPipeActiveConnection(endpoint: r'\\.\pipe\paseo'),
        const RelayActiveConnection(endpoint: 'relay.paseo.sh:443'),
      ]) {
        expect(resolveLink(connection).targets.last, localhostDirectTarget);
      }
    });

    // extra: a loopback TCP daemon is rendered as `localhost`, an IPv6 daemon
    // is re-bracketed, and an unparseable endpoint degrades to localhost.
    test('normalizes the direct host of a TCP daemon endpoint', () {
      String directUrl(String endpoint) => resolveLink(
        DirectTcpActiveConnection(endpoint: endpoint, display: endpoint),
      ).targets.last.url;

      expect(directUrl('127.0.0.1:6767'), 'http://localhost:3000');
      expect(directUrl('[::1]:6767'), 'http://localhost:3000');
      expect(directUrl('[2001:db8::1]:6767'), 'http://[2001:db8::1]:3000');
      expect(directUrl('LOCALHOST:6767'), 'http://localhost:3000');
      expect(directUrl('not-a-host-port'), 'http://localhost:3000');
      expect(directUrl('   '), 'http://localhost:3000');
    });

    // extra: the label drops only a leading http/https scheme.
    test('labels a target by stripping just the leading scheme', () {
      expect(
        resolveLink(
          null,
          service(localProxyUrl: 'ws://web.localhost:6767', proxyUrl: null),
        ).targets.first.label,
        'ws://web.localhost:6767',
      );
      expect(publicTarget.label, 'web--feature--paseo.services.example.com');
    });

    // extra: the legacy classifier's `new URL` failure branch. An unparseable
    // or scheme-less `proxyUrl` is treated as local-only, so it lands in the
    // `paseo` slot rather than being advertised as public.
    test('treats an unparseable legacy proxy URL as local-only', () {
      for (final url in <String>[
        'not a url',
        '//web.localhost:6767',
        'http://',
      ]) {
        expect(
          resolveLink(
            null,
            service(localProxyUrl: null, proxyUrl: url),
          ).targets.first.kind,
          WorkspaceScriptLinkKind.paseo,
          reason: url,
        );
      }
    });

    // extra: hostname classification. `*.localhost` and the three loopback
    // spellings are local; a *bracketed* IPv6 literal is not, because
    // `URL.hostname` keeps the brackets and never equals the bare `::1`
    // upstream compares against.
    test(
      'classifies legacy proxy hostnames the way URL.hostname reports them',
      () {
        WorkspaceScriptLinkKind kindFor(String url) => resolveLink(
          null,
          service(localProxyUrl: null, proxyUrl: url),
        ).targets.first.kind;

        expect(kindFor('http://localhost:6767'), WorkspaceScriptLinkKind.paseo);
        expect(kindFor('http://127.0.0.1:6767'), WorkspaceScriptLinkKind.paseo);
        expect(
          kindFor('HTTP://Web--X.LocalHost:6767'),
          WorkspaceScriptLinkKind.paseo,
        );
        expect(
          kindFor('https://services.example.com'),
          WorkspaceScriptLinkKind.public,
        );
        expect(kindFor('http://[::1]:6767'), WorkspaceScriptLinkKind.public);
        // `localhost` must be a *suffix* preceded by a dot, not a substring.
        expect(
          kindFor('https://localhost.example.com'),
          WorkspaceScriptLinkKind.public,
        );
      },
    );

    // extra: value equality is what the tests above rely on, so pin it.
    test('compares resolved links by value', () {
      expect(
        const ResolvedWorkspaceScriptLink(primary: null, targets: []),
        const ResolvedWorkspaceScriptLink(primary: null, targets: []),
      );
      expect(
        ResolvedWorkspaceScriptLink(
          primary: paseoTarget,
          targets: [paseoTarget],
        ).hashCode,
        ResolvedWorkspaceScriptLink(
          primary: paseoTarget,
          targets: [paseoTarget],
        ).hashCode,
      );
      expect(
        ResolvedWorkspaceScriptLink(
          primary: paseoTarget,
          targets: [paseoTarget],
        ),
        isNot(
          ResolvedWorkspaceScriptLink(
            primary: paseoTarget,
            targets: [paseoTarget, localhostDirectTarget],
          ),
        ),
      );
      expect(paseoTarget, isNot(publicTarget));
    });
  });
}
