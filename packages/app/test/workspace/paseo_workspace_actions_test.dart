// Port of the frozen Paseo 0.2.0 suites
// `packages/app/src/workspace/workspace-archive.test.ts`,
// `packages/app/src/workspace/open-target-planner.test.ts`,
// `packages/app/src/screens/workspace/workspace-bulk-close.test.ts`,
// `packages/app/src/screens/new-workspace-picker-state.test.ts`,
// `packages/app/src/screens/new-workspace/project-selection.test.ts` and
// `packages/app/src/screens/settings/appearance/apply-appearance.test.ts`.
//
// Every upstream case appears below under the same public symbol. Cases marked
// `// extra:` are not in the upstream suites — they pin behavior the frozen
// modules have but never assert: JS truthiness (an empty `payload.error`, a
// `lineStart` of 0, an empty forge id), the host-disconnected branch of the
// batch archive, every confirmation-copy branch, the missing-client branch of
// the bulk close, the `undefined` vs `null` split on `resolvedActiveFile`,
// manual-selection resolution when the project is gone, and the parts of the
// appearance patch (mono font, non-`diff` line heights, non-`syntax` colors,
// the light theme's own color scheme) the upstream suite leaves alone.

import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart'
    show
        ForgeSearchItem,
        ForgeSearchKind,
        WorkspaceDescriptor,
        WorkspaceKind,
        WorkspaceProjectKind,
        WorkspaceStateBucket;
import 'package:coding_agent_app/core/paseo_app_misc.dart'
    show HostProjectListItem, WorkspaceStructureHostPlacement;
import 'package:coding_agent_app/core/paseo_session_projection.dart'
    show clearWorkspaceArchivePending, isWorkspaceArchivePending;
import 'package:coding_agent_app/hooks/paseo_agent_settings_rules.dart'
    show SyntaxThemeId;
import 'package:coding_agent_app/state/appearance_provider.dart'
    show AppThemeName;
import 'package:coding_agent_app/workspace/paseo_workspace_actions.dart';
import 'package:coding_agent_app/workspace/workspace_file_open.dart'
    show ResolvedWorkspaceFilePaths, WorkspaceFileLocation;
import 'package:coding_agent_app/workspace/workspace_tab_model.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Shared fixtures
// ---------------------------------------------------------------------------

const String serverId = 'workspace-archive-test';
const String secondServerId = 'workspace-archive-test-2';

WorkspaceDescriptor workspace({
  String id = 'workspace-1',
  String? workspaceDirectory,
  String? name,
}) => WorkspaceDescriptor(
  id: id,
  projectId: 'project-1',
  projectDisplayName: 'Project',
  projectRootPath: '/repo/project',
  workspaceDirectory: workspaceDirectory ?? '/repo/project/$id',
  projectKind: WorkspaceProjectKind.git,
  workspaceKind: WorkspaceKind.worktree,
  name: name ?? id,
  status: WorkspaceStateBucket.done,
  activityAt: null,
);

WorkspaceArchiveTarget target({
  String server = serverId,
  String workspaceId = 'workspace-1',
}) => WorkspaceArchiveTarget(serverId: server, workspaceId: workspaceId);

/// The injectable stand-in for upstream's module-global `useSessionStore`.
final class FakeSessionStore implements WorkspaceArchiveSessionStore {
  final Map<String, Map<String, WorkspaceDescriptor>> sessions = {};

  void initializeSession(String serverId) {
    sessions[serverId] = <String, WorkspaceDescriptor>{};
  }

  WorkspaceDescriptor? stored(String serverId, String workspaceId) =>
      sessions[serverId]?[workspaceId];

  @override
  Map<String, WorkspaceDescriptor>? workspacesFor(String serverId) =>
      sessions[serverId];

  @override
  void removeWorkspace(String serverId, String workspaceId) {
    sessions[serverId]?.remove(workspaceId);
  }

  @override
  void mergeWorkspaces(String serverId, List<WorkspaceDescriptor> workspaces) {
    final session = sessions.putIfAbsent(
      serverId,
      () => <String, WorkspaceDescriptor>{},
    );
    for (final workspace in workspaces) {
      session[workspace.id] = workspace;
    }
  }
}

final class FakeArchiveClient implements WorkspaceArchiveClient {
  FakeArchiveClient(this._handler);

  final Future<WorkspaceArchiveResult> Function(String workspaceId) _handler;
  final List<String> calls = [];

  @override
  Future<WorkspaceArchiveResult> archiveWorkspace(String workspaceId) {
    calls.add(workspaceId);
    return _handler(workspaceId);
  }
}

// ---------------------------------------------------------------------------
// workspace/workspace-archive.ts
// ---------------------------------------------------------------------------

void main() {
  group('archiveWorkspaceOptimistically', () {
    late FakeSessionStore store;

    setUp(() {
      store = FakeSessionStore()..initializeSession(serverId);
    });

    tearDown(() {
      for (final server in [serverId, secondServerId]) {
        for (final id in ['workspace-1', 'workspace-2']) {
          clearWorkspaceArchivePending(serverId: server, workspaceId: id);
        }
      }
    });

    test('hides the workspace and marks the archive pending while the daemon '
        'call runs', () async {
      final archived = workspace();
      store.mergeWorkspaces(serverId, [archived]);
      final release = Completer<WorkspaceArchiveResult>();
      final client = FakeArchiveClient((_) => release.future);

      final archive = archiveWorkspaceOptimistically(
        client: client,
        workspace: target(),
        store: store,
      );

      expect(store.stored(serverId, archived.id), isNull);
      expect(
        isWorkspaceArchivePending(serverId: serverId, workspaceId: archived.id),
        isTrue,
      );

      release.complete(const WorkspaceArchiveResult());
      await archive;

      expect(store.stored(serverId, archived.id), isNull);
    });

    test('restores the workspace and clears pending state when the daemon '
        'rejects the archive', () async {
      final archived = workspace();
      store.mergeWorkspaces(serverId, [archived]);
      final client = FakeArchiveClient(
        (_) async => const WorkspaceArchiveResult(error: 'nope'),
      );

      await expectLater(
        archiveWorkspaceOptimistically(
          client: client,
          workspace: target(),
          store: store,
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'message', 'nope')),
      );

      expect(store.stored(serverId, archived.id), same(archived));
      expect(
        isWorkspaceArchivePending(serverId: serverId, workspaceId: archived.id),
        isFalse,
      );
    });

    // extra: upstream's `if (payload.error)` is a truthiness test, so an empty
    // error string is a *success* and the row must stay hidden.
    test('treats an empty error string as success', () async {
      final archived = workspace();
      store.mergeWorkspaces(serverId, [archived]);
      final client = FakeArchiveClient(
        (_) async => const WorkspaceArchiveResult(error: ''),
      );

      await archiveWorkspaceOptimistically(
        client: client,
        workspace: target(),
        store: store,
      );

      expect(store.stored(serverId, archived.id), isNull);
      expect(
        isWorkspaceArchivePending(serverId: serverId, workspaceId: archived.id),
        isTrue,
      );
    });

    // extra: a transport-level throw takes the same restore path as a payload
    // error, and the original error is rethrown untouched.
    test('restores and rethrows when the daemon call itself throws', () async {
      final archived = workspace();
      store.mergeWorkspaces(serverId, [archived]);
      final failure = Exception('socket closed');
      final client = FakeArchiveClient((_) async => throw failure);

      await expectLater(
        archiveWorkspaceOptimistically(
          client: client,
          workspace: target(),
          store: store,
        ),
        throwsA(same(failure)),
      );

      expect(store.stored(serverId, archived.id), same(archived));
      expect(
        isWorkspaceArchivePending(serverId: serverId, workspaceId: archived.id),
        isFalse,
      );
    });

    // extra: nothing to snapshot means nothing to restore, but the pending mark
    // must still clear or every later upsert for that id is swallowed.
    test(
      'clears pending without restoring when the workspace was unknown',
      () async {
        final client = FakeArchiveClient(
          (_) async => const WorkspaceArchiveResult(error: 'nope'),
        );

        await expectLater(
          archiveWorkspaceOptimistically(
            client: client,
            workspace: target(),
            store: store,
          ),
          throwsA(isA<StateError>()),
        );

        expect(store.stored(serverId, 'workspace-1'), isNull);
        expect(
          isWorkspaceArchivePending(
            serverId: serverId,
            workspaceId: 'workspace-1',
          ),
          isFalse,
        );
      },
    );

    // extra: the snapshot is found through `resolveWorkspaceMapKeyByIdentity`,
    // so a store keyed by something other than the workspace id still restores.
    test('restores a workspace stored under a composite key', () async {
      final archived = workspace();
      store.sessions[serverId] = {'$serverId:${archived.id}': archived};
      final client = FakeArchiveClient(
        (_) async => const WorkspaceArchiveResult(error: 'nope'),
      );

      await expectLater(
        archiveWorkspaceOptimistically(
          client: client,
          workspace: target(),
          store: store,
        ),
        throwsA(isA<StateError>()),
      );

      expect(store.stored(serverId, archived.id), same(archived));
    });
  });

  group('archiveWorkspacesOptimistically', () {
    late FakeSessionStore store;

    setUp(() {
      store = FakeSessionStore()..initializeSession(serverId);
    });

    tearDown(() {
      for (final server in [serverId, secondServerId]) {
        for (final id in ['workspace-1', 'workspace-2']) {
          clearWorkspaceArchivePending(serverId: server, workspaceId: id);
        }
      }
    });

    test(
      'returns failures and restores only the workspaces whose archive failed',
      () async {
        final first = workspace(id: 'workspace-1');
        final second = workspace(id: 'workspace-2');
        store.mergeWorkspaces(serverId, [first, second]);
        final client = FakeArchiveClient(
          (workspaceId) async => WorkspaceArchiveResult(
            error: workspaceId == second.id ? 'failed' : null,
          ),
        );

        final failures = await archiveWorkspacesOptimistically(
          getClient: (_) => client,
          workspaces: [
            target(workspaceId: first.id),
            target(workspaceId: second.id),
          ],
          store: store,
        );

        expect(failures, hasLength(1));
        expect(failures.first.workspaceId, second.id);
        expect(store.stored(serverId, first.id), isNull);
        expect(store.stored(serverId, second.id), same(second));
      },
    );

    test('archives each workspace through its own server client', () async {
      final first = workspace(id: 'workspace-1');
      final second = workspace(id: 'workspace-2');
      store
        ..initializeSession(secondServerId)
        ..mergeWorkspaces(serverId, [first])
        ..mergeWorkspaces(secondServerId, [second]);

      final archivedByServer = <String, List<String>>{};
      WorkspaceArchiveClient clientFor(String server) =>
          FakeArchiveClient((workspaceId) async {
            archivedByServer.putIfAbsent(server, () => []).add(workspaceId);
            return const WorkspaceArchiveResult();
          });

      final failures = await archiveWorkspacesOptimistically(
        getClient: clientFor,
        workspaces: [
          target(server: serverId, workspaceId: first.id),
          target(server: secondServerId, workspaceId: second.id),
        ],
        store: store,
      );

      expect(failures, isEmpty);
      expect(archivedByServer, {
        serverId: [first.id],
        secondServerId: [second.id],
      });
      expect(store.stored(serverId, first.id), isNull);
      expect(store.stored(secondServerId, second.id), isNull);
    });

    // extra: a host with no client fails without ever hiding the row, and the
    // synthesized error carries the injected host-disconnected copy.
    test('reports a host with no client without hiding its row', () async {
      final only = workspace();
      store.mergeWorkspaces(serverId, [only]);

      final failures = await archiveWorkspacesOptimistically(
        getClient: (_) => null,
        workspaces: [target()],
        store: store,
      );

      expect(failures, hasLength(1));
      expect(failures.first.serverId, serverId);
      expect(failures.first.workspaceId, only.id);
      expect(
        (failures.first.error as StateError).message,
        defaultWorkspaceArchiveHostDisconnectedMessage,
      );
      expect(store.stored(serverId, only.id), same(only));
      expect(
        isWorkspaceArchivePending(serverId: serverId, workspaceId: only.id),
        isFalse,
      );
    });

    // extra: the message is injectable, matching the repo's translator pattern.
    test('uses the injected host-disconnected message', () async {
      final failures = await archiveWorkspacesOptimistically(
        getClient: (_) => null,
        workspaces: [target()],
        store: store,
        hostDisconnectedMessage: 'Host ist nicht verbunden',
      );

      expect(
        (failures.single.error as StateError).message,
        'Host ist nicht verbunden',
      );
    });

    // extra: every optimistic hide runs before the first daemon call resolves,
    // so a batch archive empties the list in one frame.
    test('hides the whole batch before any daemon call resolves', () async {
      final first = workspace(id: 'workspace-1');
      final second = workspace(id: 'workspace-2');
      store.mergeWorkspaces(serverId, [first, second]);
      final release = Completer<WorkspaceArchiveResult>();
      final client = FakeArchiveClient((_) => release.future);

      final pending = archiveWorkspacesOptimistically(
        getClient: (_) => client,
        workspaces: [
          target(workspaceId: first.id),
          target(workspaceId: second.id),
        ],
        store: store,
      );

      expect(store.stored(serverId, first.id), isNull);
      expect(store.stored(serverId, second.id), isNull);
      expect(client.calls, [first.id, second.id]);

      release.complete(const WorkspaceArchiveResult());
      expect(await pending, isEmpty);
    });

    // extra: failures come back in input order, not completion order.
    test('reports failures in input order', () async {
      final first = workspace(id: 'workspace-1');
      final second = workspace(id: 'workspace-2');
      store.mergeWorkspaces(serverId, [first, second]);
      final client = FakeArchiveClient((workspaceId) async {
        // The first workspace resolves last.
        if (workspaceId == first.id) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        return const WorkspaceArchiveResult(error: 'failed');
      });

      final failures = await archiveWorkspacesOptimistically(
        getClient: (_) => client,
        workspaces: [
          target(workspaceId: first.id),
          target(workspaceId: second.id),
        ],
        store: store,
      );

      expect(failures.map((failure) => failure.workspaceId), [
        first.id,
        second.id,
      ]);
    });

    // extra: an empty selection is a no-op, not a crash.
    test('returns no failures for an empty selection', () async {
      expect(
        await archiveWorkspacesOptimistically(
          getClient: (_) => throw StateError('should not be called'),
          workspaces: const [],
          store: store,
        ),
        isEmpty,
      );
    });
  });

  // -------------------------------------------------------------------------
  // workspace/open-target-planner.ts
  // -------------------------------------------------------------------------

  group('planWorkspaceOpenTargets', () {
    const desktopTargets = [
      DesktopOpenTarget(
        id: 'vscode',
        label: 'VS Code',
        kind: DesktopOpenTargetKind.editor,
        icon: SymbolDesktopOpenTargetIcon(DesktopOpenTargetSymbol.terminal),
      ),
      DesktopOpenTarget(
        id: 'finder',
        label: 'Finder',
        kind: DesktopOpenTargetKind.fileManager,
        icon: SymbolDesktopOpenTargetIcon(DesktopOpenTargetSymbol.folder),
      ),
    ];

    const checkoutStatus = CheckoutStatusForOpenTarget(
      isGit: true,
      remoteUrl: 'git@github.com:getpaseo/paseo.git',
      currentBranch: 'main',
    );

    test('plans editor targets with active-file absolute path and cwd', () {
      final targets = planWorkspaceOpenTargets(
        const PlanWorkspaceOpenTargetsInput(
          workspaceDirectory: '/repo',
          activeFile: WorkspaceFileLocation(
            path: 'src/app.ts',
            lineStart: 3,
            lineEnd: 5,
          ),
          desktopTargets: desktopTargets,
          canUseDesktopBridge: true,
          isLocalExecution: true,
        ),
      );

      final first = targets[0] as PlannedDesktopOpenTarget;
      expect(first.source, 'desktop');
      expect(first.id, 'vscode');
      expect(first.openInput.toJson(), {
        'editorId': 'vscode',
        'workspacePath': '/repo',
        'filePath': '/repo/src/app.ts',
        'line': 3,
      });
    });

    test('plans file-manager targets with active-file absolute path and reveal '
        'mode', () {
      final targets = planWorkspaceOpenTargets(
        const PlanWorkspaceOpenTargetsInput(
          workspaceDirectory: '/repo',
          activeFile: WorkspaceFileLocation(path: 'src/app.ts'),
          desktopTargets: desktopTargets,
          canUseDesktopBridge: true,
          isLocalExecution: true,
        ),
      );

      final second = targets[1] as PlannedDesktopOpenTarget;
      expect(second.source, 'desktop');
      expect(second.id, 'finder');
      expect(second.openInput.toJson(), {
        'editorId': 'finder',
        'workspacePath': '/repo',
        'filePath': '/repo/src/app.ts',
      });
    });

    test('plans no active file as opening the workspace folder', () {
      final targets = planWorkspaceOpenTargets(
        const PlanWorkspaceOpenTargetsInput(
          workspaceDirectory: '/repo',
          desktopTargets: desktopTargets,
          canUseDesktopBridge: true,
          isLocalExecution: true,
        ),
      );

      expect((targets[0] as PlannedDesktopOpenTarget).openInput.toJson(), {
        'editorId': 'vscode',
        'workspacePath': '/repo',
      });
      expect((targets[1] as PlannedDesktopOpenTarget).openInput.toJson(), {
        'editorId': 'finder',
        'workspacePath': '/repo',
      });
    });

    test('passes custom target ids through as strings', () {
      final targets = planWorkspaceOpenTargets(
        const PlanWorkspaceOpenTargetsInput(
          workspaceDirectory: '/repo',
          activeFile: WorkspaceFileLocation(path: 'src/app.ts'),
          desktopTargets: [
            DesktopOpenTarget(
              id: 'script:open-in-nvim',
              label: 'Open in Neovim',
              kind: DesktopOpenTargetKind.editor,
              icon: SymbolDesktopOpenTargetIcon(
                DesktopOpenTargetSymbol.terminal,
              ),
            ),
          ],
          canUseDesktopBridge: true,
          isLocalExecution: true,
        ),
      );

      expect(targets, [
        const PlannedDesktopOpenTarget(
          id: 'script:open-in-nvim',
          label: 'Open in Neovim',
          editorId: 'script:open-in-nvim',
          icon: SymbolDesktopOpenTargetIcon(DesktopOpenTargetSymbol.terminal),
          openInput: OpenDesktopTargetInput(
            editorId: 'script:open-in-nvim',
            workspacePath: '/repo',
            filePath: '/repo/src/app.ts',
          ),
        ),
      ]);
    });

    test('keeps the forge target independent and uses blob and tree URLs', () {
      final blobTargets = planWorkspaceOpenTargets(
        const PlanWorkspaceOpenTargetsInput(
          workspaceDirectory: '/repo',
          activeFile: WorkspaceFileLocation(
            path: 'src/app.ts',
            lineStart: 3,
            lineEnd: 5,
          ),
          canUseDesktopBridge: false,
          isLocalExecution: false,
          checkoutStatus: checkoutStatus,
        ),
      );
      final treeTargets = planWorkspaceOpenTargets(
        const PlanWorkspaceOpenTargetsInput(
          workspaceDirectory: '/repo',
          canUseDesktopBridge: false,
          isLocalExecution: false,
          checkoutStatus: checkoutStatus,
        ),
      );

      expect(blobTargets, [
        const PlannedForgeOpenTarget(
          forge: 'github',
          label: 'GitHub',
          url: 'https://github.com/getpaseo/paseo/blob/main/src/app.ts#L3-L5',
        ),
      ]);
      expect(blobTargets.single.source, 'forge');
      expect(blobTargets.single.id, 'github');
      expect(treeTargets, [
        const PlannedForgeOpenTarget(
          forge: 'github',
          label: 'GitHub',
          url: 'https://github.com/getpaseo/paseo/tree/main',
        ),
      ]);
    });

    test(
      'infers the forge from the remote URL when the forge input is null',
      () {
        final targets = planWorkspaceOpenTargets(
          const PlanWorkspaceOpenTargetsInput(
            workspaceDirectory: '/repo',
            activeFile: WorkspaceFileLocation(
              path: 'src/app.ts',
              lineStart: 3,
              lineEnd: 5,
            ),
            canUseDesktopBridge: false,
            isLocalExecution: false,
            checkoutStatus: CheckoutStatusForOpenTarget(
              isGit: true,
              remoteUrl: 'git@gitlab.com:group/project.git',
              currentBranch: 'main',
            ),
            forge: null,
          ),
        );

        expect(targets, [
          const PlannedForgeOpenTarget(
            forge: 'gitlab',
            label: 'GitLab',
            url: 'https://gitlab.com/group/project/-/blob/main/src/app.ts#L3-5',
          ),
        ]);
      },
    );

    test(
      'suppresses desktop targets when the desktop bridge is unavailable',
      () {
        final targets = planWorkspaceOpenTargets(
          const PlanWorkspaceOpenTargetsInput(
            workspaceDirectory: '/repo',
            desktopTargets: desktopTargets,
            canUseDesktopBridge: false,
            isLocalExecution: true,
            checkoutStatus: checkoutStatus,
          ),
        );

        expect(targets.map((target) => target.id), ['github']);
      },
    );

    test('suppresses desktop targets for remote execution paths', () {
      final targets = planWorkspaceOpenTargets(
        const PlanWorkspaceOpenTargetsInput(
          workspaceDirectory: '/repo',
          desktopTargets: desktopTargets,
          canUseDesktopBridge: true,
          isLocalExecution: false,
          checkoutStatus: checkoutStatus,
        ),
      );

      expect(targets.map((target) => target.id), ['github']);
    });

    // extra: the forge entry is always appended after every desktop target.
    test('appends the forge target after the desktop targets', () {
      final targets = planWorkspaceOpenTargets(
        const PlanWorkspaceOpenTargetsInput(
          workspaceDirectory: '/repo',
          desktopTargets: desktopTargets,
          canUseDesktopBridge: true,
          isLocalExecution: true,
          checkoutStatus: checkoutStatus,
        ),
      );

      expect(targets.map((target) => target.id), [
        'vscode',
        'finder',
        'github',
      ]);
      expect(targets.map((target) => target.source), [
        'desktop',
        'desktop',
        'forge',
      ]);
    });

    // extra: a non-git checkout has no forge page at all.
    test('plans no forge target for a non-git checkout', () {
      expect(
        planWorkspaceOpenTargets(
          const PlanWorkspaceOpenTargetsInput(
            workspaceDirectory: '/repo',
            canUseDesktopBridge: false,
            isLocalExecution: false,
            checkoutStatus: CheckoutStatusForOpenTarget(isGit: false),
          ),
        ),
        isEmpty,
      );
    });

    // extra: no checkout status at all is the same as "not a repo".
    test('plans no forge target without a checkout status', () {
      expect(
        planWorkspaceOpenTargets(
          const PlanWorkspaceOpenTargetsInput(
            workspaceDirectory: '/repo',
            canUseDesktopBridge: false,
            isLocalExecution: false,
          ),
        ),
        isEmpty,
      );
    });

    // extra: `if (!forge)` is a truthiness test — an explicitly empty forge id
    // is rejected rather than normalized to `github`.
    test('plans no forge target for an empty forge id', () {
      expect(
        planWorkspaceOpenTargets(
          const PlanWorkspaceOpenTargetsInput(
            workspaceDirectory: '/repo',
            canUseDesktopBridge: false,
            isLocalExecution: false,
            checkoutStatus: checkoutStatus,
            forge: '',
          ),
        ),
        isEmpty,
      );
    });

    // extra: the explicit forge wins over what the remote URL would infer.
    test('prefers the explicit forge over the remote URL', () {
      final targets = planWorkspaceOpenTargets(
        const PlanWorkspaceOpenTargetsInput(
          workspaceDirectory: '/repo',
          canUseDesktopBridge: false,
          isLocalExecution: false,
          checkoutStatus: CheckoutStatusForOpenTarget(
            isGit: true,
            remoteUrl: 'https://git.example.com/group/project.git',
            currentBranch: 'main',
          ),
          forge: 'gitea',
        ),
      );

      expect(targets, [
        const PlannedForgeOpenTarget(
          forge: 'gitea',
          label: 'Gitea',
          url: 'https://git.example.com/group/project/src/branch/main',
        ),
      ]);
    });

    // extra: a forge with no web-URL grammar produces no link rather than a
    // broken one.
    test('plans no forge target for a forge with no web URL grammar', () {
      expect(
        planWorkspaceOpenTargets(
          const PlanWorkspaceOpenTargetsInput(
            workspaceDirectory: '/repo',
            canUseDesktopBridge: false,
            isLocalExecution: false,
            checkoutStatus: CheckoutStatusForOpenTarget(
              isGit: true,
              remoteUrl: 'https://scm.example.com/group/project.git',
              currentBranch: 'main',
            ),
            forge: 'bitbucket',
          ),
        ),
        isEmpty,
      );
    });

    // extra: a branch that cannot be named yields no URL, so no target.
    test('plans no forge target without a current branch', () {
      expect(
        planWorkspaceOpenTargets(
          const PlanWorkspaceOpenTargetsInput(
            workspaceDirectory: '/repo',
            canUseDesktopBridge: false,
            isLocalExecution: false,
            checkoutStatus: CheckoutStatusForOpenTarget(
              isGit: true,
              remoteUrl: 'git@github.com:getpaseo/paseo.git',
            ),
          ),
        ),
        isEmpty,
      );
    });

    // extra: a file outside the workspace has no relative path, so the forge
    // falls back to the branch tree while the editor still gets the absolute
    // path.
    test('falls back to the tree URL for a file outside the workspace', () {
      final targets = planWorkspaceOpenTargets(
        const PlanWorkspaceOpenTargetsInput(
          workspaceDirectory: '/repo',
          activeFile: WorkspaceFileLocation(path: '/elsewhere/notes.md'),
          desktopTargets: desktopTargets,
          canUseDesktopBridge: true,
          isLocalExecution: true,
          checkoutStatus: checkoutStatus,
        ),
      );

      expect(
        (targets.first as PlannedDesktopOpenTarget).openInput.filePath,
        '/elsewhere/notes.md',
      );
      expect(
        (targets.last as PlannedForgeOpenTarget).url,
        'https://github.com/getpaseo/paseo/tree/main',
      );
    });

    // extra: `...(activeFile?.lineStart ? { line } : {})` is truthy, so a
    // `lineStart` of 0 omits the key exactly like a missing one.
    test('omits the editor line for a zero lineStart', () {
      final targets = planWorkspaceOpenTargets(
        const PlanWorkspaceOpenTargetsInput(
          workspaceDirectory: '/repo',
          activeFile: WorkspaceFileLocation(path: 'src/app.ts', lineStart: 0),
          desktopTargets: desktopTargets,
          canUseDesktopBridge: true,
          isLocalExecution: true,
        ),
      );

      expect((targets.first as PlannedDesktopOpenTarget).openInput.toJson(), {
        'editorId': 'vscode',
        'workspacePath': '/repo',
        'filePath': '/repo/src/app.ts',
      });
    });

    // extra: a supplied override replaces the derivation entirely.
    test('uses a supplied resolved active file verbatim', () {
      final targets = planWorkspaceOpenTargets(
        const PlanWorkspaceOpenTargetsInput(
          workspaceDirectory: '/repo',
          activeFile: WorkspaceFileLocation(path: 'src/app.ts'),
          resolvedActiveFile: ResolvedActiveFileOverride(
            ResolvedWorkspaceFilePaths(
              absolutePath: '/repo/lib/other.dart',
              relativePath: 'lib/other.dart',
            ),
          ),
          desktopTargets: desktopTargets,
          canUseDesktopBridge: true,
          isLocalExecution: true,
          checkoutStatus: checkoutStatus,
        ),
      );

      expect(
        (targets.first as PlannedDesktopOpenTarget).openInput.filePath,
        '/repo/lib/other.dart',
      );
      expect(
        (targets.last as PlannedForgeOpenTarget).url,
        'https://github.com/getpaseo/paseo/blob/main/lib/other.dart',
      );
    });

    // extra: an override *of null* is upstream's explicit `null` — it
    // suppresses the file even though `activeFile` is present. An absent
    // override would have derived one.
    test('suppresses the active file for an override of null', () {
      final targets = planWorkspaceOpenTargets(
        const PlanWorkspaceOpenTargetsInput(
          workspaceDirectory: '/repo',
          activeFile: WorkspaceFileLocation(path: 'src/app.ts'),
          resolvedActiveFile: ResolvedActiveFileOverride(null),
          desktopTargets: desktopTargets,
          canUseDesktopBridge: true,
          isLocalExecution: true,
          checkoutStatus: checkoutStatus,
        ),
      );

      expect(
        (targets.first as PlannedDesktopOpenTarget).openInput.filePath,
        isNull,
      );
      expect(
        (targets.last as PlannedForgeOpenTarget).url,
        'https://github.com/getpaseo/paseo/tree/main',
      );
    });

    // extra: an unresolvable active-file path degrades to the folder open.
    test('degrades to the workspace folder for an unresolvable path', () {
      final targets = planWorkspaceOpenTargets(
        const PlanWorkspaceOpenTargetsInput(
          workspaceDirectory: '/repo',
          activeFile: WorkspaceFileLocation(path: '../escape.txt'),
          desktopTargets: desktopTargets,
          canUseDesktopBridge: true,
          isLocalExecution: true,
        ),
      );

      expect((targets.first as PlannedDesktopOpenTarget).openInput.toJson(), {
        'editorId': 'vscode',
        'workspacePath': '/repo',
      });
    });
  });

  // -------------------------------------------------------------------------
  // screens/workspace/workspace-bulk-close.ts
  // -------------------------------------------------------------------------

  group('workspace bulk close helpers', () {
    WorkspaceTab agentTab(String id) => WorkspaceTab(
      tabId: 'agent_$id',
      target: WorkspaceAgentTabTarget(agentId: id),
      createdAt: 1,
    );

    WorkspaceTab terminalTab(String id) => WorkspaceTab(
      tabId: 'terminal_$id',
      target: WorkspaceTerminalTabTarget(terminalId: id),
      createdAt: 1,
    );

    WorkspaceTab fileTab(String path) => WorkspaceTab(
      tabId: 'file_$path',
      target: WorkspaceFileTabTarget(path: path),
      createdAt: 1,
    );

    test('classifies agent, terminal, and passive tabs for shared bulk close '
        'handling', () {
      final groups = classifyBulkClosableTabs([
        agentTab('a1'),
        terminalTab('t1'),
        fileTab('/repo/README.md'),
      ]);

      expect(
        groups,
        BulkClosableTabGroups(
          agentTabs: const [
            BulkCloseAgentTab(tabId: 'agent_a1', agentId: 'a1'),
          ],
          terminalTabs: const [
            BulkCloseTerminalTab(tabId: 'terminal_t1', terminalId: 't1'),
          ],
          otherTabs: const [
            BulkCloseOtherTab(
              tabId: 'file_/repo/README.md',
              target: WorkspaceFileTabTarget(path: '/repo/README.md'),
            ),
          ],
        ),
      );
    });

    test(
      'describes mixed destructive bulk close operations in the confirmation '
      'copy',
      () {
        expect(
          buildBulkCloseConfirmationMessage(
            classifyBulkClosableTabs([
              agentTab('a1'),
              agentTab('a2'),
              terminalTab('t1'),
              fileTab('/repo/README.md'),
            ]),
          ),
          'This will archive 2 agent(s), close 1 terminal(s), and close 1 '
          'tab(s). Any running process in a closed terminal will be stopped '
          'immediately.',
        );
      },
    );

    test('keeps terminal-only confirmations explicit about stopping running '
        'processes', () {
      expect(
        buildBulkCloseConfirmationMessage(
          classifyBulkClosableTabs([terminalTab('t1')]),
        ),
        'This will close 1 terminal(s). Any running process in a closed '
        'terminal will be stopped immediately.',
      );
    });

    // extra: the remaining five copy branches, and the branch order that makes
    // agents+terminals win over terminals+tabs.
    test('describes agents and terminals without tabs', () {
      expect(
        buildBulkCloseConfirmationMessage(
          classifyBulkClosableTabs([agentTab('a1'), terminalTab('t1')]),
        ),
        'This will archive 1 agent(s) and close 1 terminal(s). Any running '
        'process in a closed terminal will be stopped immediately.',
      );
    });

    test('describes terminals and tabs without agents', () {
      expect(
        buildBulkCloseConfirmationMessage(
          classifyBulkClosableTabs([
            terminalTab('t1'),
            fileTab('/repo/a.md'),
            fileTab('/repo/b.md'),
          ]),
        ),
        'This will close 1 terminal(s) and close 2 tab(s). Any running '
        'process in a closed terminal will be stopped immediately.',
      );
    });

    test('describes agents and tabs without terminals', () {
      expect(
        buildBulkCloseConfirmationMessage(
          classifyBulkClosableTabs([agentTab('a1'), fileTab('/repo/a.md')]),
        ),
        'This will archive 1 agent(s) and close 1 tab(s).',
      );
    });

    test('describes tabs only', () {
      expect(
        buildBulkCloseConfirmationMessage(
          classifyBulkClosableTabs([fileTab('/repo/a.md')]),
        ),
        'This will close 1 tab(s).',
      );
    });

    test('describes agents only', () {
      expect(
        buildBulkCloseConfirmationMessage(
          classifyBulkClosableTabs([agentTab('a1')]),
        ),
        'This will archive 1 agent(s).',
      );
    });

    // extra: the fallback branch is the agents copy, so an empty selection
    // reads "0 agent(s)" rather than throwing.
    test('falls back to the agents copy for an empty selection', () {
      expect(
        buildBulkCloseConfirmationMessage(classifyBulkClosableTabs(const [])),
        'This will archive 0 agent(s).',
      );
    });

    // extra: the copy is fully injectable.
    test('uses injected confirmation labels', () {
      expect(
        buildBulkCloseConfirmationMessage(
          classifyBulkClosableTabs([fileTab('/repo/a.md')]),
          labels: BulkCloseConfirmationLabels(
            all: ({required agents, required terminals, required tabs}) => 'a',
            agentsAndTerminals: ({required agents, required terminals}) => 'b',
            terminalsAndTabs: ({required terminals, required tabs}) => 'c',
            agentsAndTabs: ({required agents, required tabs}) => 'd',
            terminals: ({required terminals}) => 'e',
            tabs: ({required tabs}) => 'tabs:$tabs',
            agents: ({required agents}) => 'g',
          ),
        ),
        'tabs:1',
      );
    });

    // extra: browser, draft, diff and setup tabs all land in `otherTabs`.
    test('routes every non-agent, non-terminal target to otherTabs', () {
      final groups = classifyBulkClosableTabs([
        WorkspaceTab(
          tabId: 'browser_b1',
          target: const WorkspaceBrowserTabTarget(browserId: 'b1'),
          createdAt: 1,
        ),
        WorkspaceTab(
          tabId: 'working_diff',
          target: const WorkspaceWorkingDiffTabTarget(),
          createdAt: 1,
        ),
        WorkspaceTab(
          tabId: 'setup_w1',
          target: const WorkspaceSetupTabTarget(workspaceId: 'w1'),
          createdAt: 1,
        ),
      ]);

      expect(groups.agentTabs, isEmpty);
      expect(groups.terminalTabs, isEmpty);
      expect(groups.otherTabs.map((tab) => tab.tabId), [
        'browser_b1',
        'working_diff',
        'setup_w1',
      ]);
    });

    test(
      'closes all tabs immediately and fires one mixed closeItems RPC in the '
      'background',
      () async {
        final groups = classifyBulkClosableTabs([
          agentTab('a1'),
          terminalTab('t1'),
          terminalTab('t2'),
          fileTab('/repo/README.md'),
        ]);
        final closedTabIds = <String>[];
        final cleanupCalls = <CloseWorkspaceTabWithCleanupInput>[];
        final client = RecordingCloseItemsClient();

        await closeBulkWorkspaceTabs(
          groups: groups,
          client: client,
          closeTab: (tabId, action) async {
            closedTabIds.add(tabId);
            await action();
          },
          closeWorkspaceTabWithCleanup: cleanupCalls.add,
          logLabel: 'all tabs',
        );
        await Future<void>.delayed(Duration.zero);

        expect(client.calls, hasLength(1));
        expect(client.calls.single, ({
          'agentIds': ['a1'],
          'terminalIds': ['t1', 't2'],
        }));
        expect(closedTabIds, [
          'agent_a1',
          'terminal_t1',
          'terminal_t2',
          'file_/repo/README.md',
        ]);
        expect(cleanupCalls, const [
          CloseWorkspaceTabWithCleanupInput(
            tabId: 'agent_a1',
            target: WorkspaceAgentTabTarget(agentId: 'a1'),
          ),
          CloseWorkspaceTabWithCleanupInput(
            tabId: 'terminal_t1',
            target: WorkspaceTerminalTabTarget(terminalId: 't1'),
          ),
          CloseWorkspaceTabWithCleanupInput(
            tabId: 'terminal_t2',
            target: WorkspaceTerminalTabTarget(terminalId: 't2'),
          ),
          CloseWorkspaceTabWithCleanupInput(
            tabId: 'file_/repo/README.md',
            target: WorkspaceFileTabTarget(path: '/repo/README.md'),
          ),
        ]);
      },
    );

    test('still closes all tabs when the mixed closeItems RPC fails', () async {
      final groups = classifyBulkClosableTabs([
        agentTab('a1'),
        terminalTab('t1'),
        fileTab('/repo/README.md'),
      ]);
      final closedTabIds = <String>[];
      final cleanupCalls = <CloseWorkspaceTabWithCleanupInput>[];
      final warnings = <String>[];

      await closeBulkWorkspaceTabs(
        groups: groups,
        client: ThrowingCloseItemsClient(),
        closeTab: (tabId, action) async {
          closedTabIds.add(tabId);
          await action();
        },
        closeWorkspaceTabWithCleanup: cleanupCalls.add,
        warn: (message, _) => warnings.add(message),
        logLabel: 'others',
      );
      await Future<void>.delayed(Duration.zero);

      expect(warnings, hasLength(1));
      expect(
        warnings.single,
        '[WorkspaceScreen] Failed to bulk close tabs others',
      );
      expect(closedTabIds, ['agent_a1', 'terminal_t1', 'file_/repo/README.md']);
      expect(cleanupCalls, const [
        CloseWorkspaceTabWithCleanupInput(
          tabId: 'agent_a1',
          target: WorkspaceAgentTabTarget(agentId: 'a1'),
        ),
        CloseWorkspaceTabWithCleanupInput(
          tabId: 'terminal_t1',
          target: WorkspaceTerminalTabTarget(terminalId: 't1'),
        ),
        CloseWorkspaceTabWithCleanupInput(
          tabId: 'file_/repo/README.md',
          target: WorkspaceFileTabTarget(path: '/repo/README.md'),
        ),
      ]);
    });

    // extra: without a client the destructive tabs still close, and the warning
    // carries the daemon-unavailable copy.
    test('warns and still closes when there is no daemon client', () async {
      final closedTabIds = <String>[];
      final payloads = <Map<String, Object?>>[];

      await closeBulkWorkspaceTabs(
        groups: classifyBulkClosableTabs([agentTab('a1'), fileTab('/a.md')]),
        client: null,
        closeTab: (tabId, action) async {
          closedTabIds.add(tabId);
          await action();
        },
        closeWorkspaceTabWithCleanup: (_) {},
        warn: (_, payload) => payloads.add(payload),
        logLabel: 'all tabs',
      );
      await Future<void>.delayed(Duration.zero);

      expect(payloads, hasLength(1));
      expect(
        (payloads.single['error']! as StateError).message,
        defaultBulkCloseDaemonClientUnavailableMessage,
      );
      expect(closedTabIds, ['agent_a1', 'file_/a.md']);
    });

    // extra: no destructive tabs means no RPC at all, and no warning even
    // without a client.
    test('fires no RPC when nothing destructive is being closed', () async {
      final client = RecordingCloseItemsClient();
      var warned = false;

      await closeBulkWorkspaceTabs(
        groups: classifyBulkClosableTabs([fileTab('/a.md')]),
        client: client,
        closeTab: (_, action) => action(),
        closeWorkspaceTabWithCleanup: (_) {},
        warn: (_, _) => warned = true,
        logLabel: 'others',
      );
      await Future<void>.delayed(Duration.zero);

      expect(client.calls, isEmpty);
      expect(warned, isFalse);
    });

    // extra: `warn` is optional — a failing RPC with no sink must not throw.
    test('tolerates a missing warn sink when the RPC fails', () async {
      await closeBulkWorkspaceTabs(
        groups: classifyBulkClosableTabs([agentTab('a1')]),
        client: ThrowingCloseItemsClient(),
        closeTab: (_, action) => action(),
        closeWorkspaceTabWithCleanup: (_) {},
        logLabel: 'agents',
      );

      await expectLater(Future<void>.delayed(Duration.zero), completes);
    });

    // extra: an empty group set closes nothing and calls nothing.
    test('does nothing for an empty group set', () async {
      final client = RecordingCloseItemsClient();
      var closed = 0;

      await closeBulkWorkspaceTabs(
        groups: classifyBulkClosableTabs(const []),
        client: client,
        closeTab: (_, action) async {
          closed += 1;
          await action();
        },
        closeWorkspaceTabWithCleanup: (_) {},
        logLabel: 'none',
      );

      expect(client.calls, isEmpty);
      expect(closed, 0);
    });
  });

  // -------------------------------------------------------------------------
  // screens/new-workspace-picker-state.ts
  // -------------------------------------------------------------------------

  group('syncPickerPrAttachment', () {
    test('selects a PR when no previous picker PR is set', () {
      final pr = prItem(202, 'Refactor picker');
      expect(
        syncPickerPrAttachment(
          attachments: const [],
          item: ChangeRequestPickerItem(pr),
        ),
        [pickerPrAttachment(pr)],
      );
    });

    test(
      'selects a branch without modifying attachments when no previous picker '
      'PR',
      () {
        final issue = issueAttachment(44);
        expect(
          syncPickerPrAttachment(
            attachments: [issue],
            item: const BranchPickerItem('dev'),
          ),
          [issue],
        );
      },
    );

    test('replaces the previous picker PR when a different PR is selected', () {
      final prA = prItem(202, 'Refactor picker', headRefName: 'feature/picker');
      final prB = prItem(303, 'Polish chip', headRefName: 'feature/chip');
      expect(
        syncPickerPrAttachment(
          attachments: [pickerPrAttachment(prA)],
          item: ChangeRequestPickerItem(prB),
        ),
        [pickerPrAttachment(prB)],
      );
    });

    test(
      'removes the previous picker PR and adds no new attachment when a branch '
      'is selected',
      () {
        final pr = prItem(202, 'Refactor picker');
        final issue = issueAttachment(44);
        expect(
          syncPickerPrAttachment(
            attachments: [issue, pickerPrAttachment(pr)],
            item: const BranchPickerItem('dev'),
          ),
          [issue],
        );
      },
    );

    test('does not duplicate a PR that was already manually attached', () {
      final pr = prItem(202, 'Refactor picker');
      final manual = userPrAttachment(pr);
      expect(
        syncPickerPrAttachment(
          attachments: [manual],
          item: ChangeRequestPickerItem(pr),
        ),
        [manual],
      );
    });

    test('does not duplicate a generalized PR attachment', () {
      final pr = prItem(202, 'Refactor picker');
      final forgePr = forgePrAttachment(pr);
      expect(
        syncPickerPrAttachment(
          attachments: [forgePr],
          item: ChangeRequestPickerItem(pr),
        ),
        [forgePr],
      );
    });

    test('clears a persisted picker selection without removing user-added '
        'attachments', () {
      final pickerPr = pickerPrAttachment(prItem(202, 'Picker PR'));
      final manualPr = userPrAttachment(prItem(303, 'Manual PR'));
      final issue = issueAttachment(44);

      expect(
        syncPickerPrAttachment(
          attachments: [issue, pickerPr, manualPr],
          item: null,
        ),
        [issue, manualPr],
      );
    });

    // extra: matching is by change-request *number*, not by object identity, so
    // a re-fetched copy of the same PR is still recognized as already attached.
    test('deduplicates by change-request number, not identity', () {
      final attached = prItem(202, 'Refactor picker');
      final refetched = prItem(202, 'Refactor picker (edited)');
      final manual = userPrAttachment(attached);

      expect(
        syncPickerPrAttachment(
          attachments: [manual],
          item: ChangeRequestPickerItem(refetched),
        ),
        [manual],
      );
    });

    // extra: a different number is a different PR, so it is appended.
    test('appends when only the numbers differ', () {
      final manual = userPrAttachment(prItem(202, 'Manual PR'));
      final selected = prItem(303, 'Picker PR');

      expect(
        syncPickerPrAttachment(
          attachments: [manual],
          item: ChangeRequestPickerItem(selected),
        ),
        [manual, pickerPrAttachment(selected)],
      );
    });

    // extra: the picker's own attachment is always appended last, after every
    // user attachment, regardless of where the old one sat.
    test('appends the picker attachment last', () {
      final issue = issueAttachment(44);
      final oldPickerPr = pickerPrAttachment(prItem(101, 'Old'));
      final next = prItem(202, 'New');

      expect(
        syncPickerPrAttachment(
          attachments: [oldPickerPr, issue],
          item: ChangeRequestPickerItem(next),
        ),
        [issue, pickerPrAttachment(next)],
      );
    });

    // extra: a `github_pr` attachment with a *different* owner is not the
    // picker's, so it survives.
    test('leaves a github_pr attachment owned by someone else alone', () {
      final pr = prItem(202, 'Someone else');
      final foreign = GithubPrComposerAttachment(
        ForgeSearchItemLike.of(pr.number, pr),
        owner: 'some-other-surface',
      );

      expect(syncPickerPrAttachment(attachments: [foreign], item: null), [
        foreign,
      ]);
    });
  });

  group('clearPickerPrAttachmentForTargetChange', () {
    test('keeps the picker selection when the target is reselected', () {
      final attachments = [pickerPrAttachment(prItem(202, 'Picker PR'))];

      expect(
        clearPickerPrAttachmentForTargetChange(
          attachments: attachments,
          currentTargetId: 'server-a',
          nextTargetId: 'server-a',
        ),
        same(attachments),
      );
    });

    test('clears all PR attachments when the target changes', () {
      final pickerPr = pickerPrAttachment(prItem(202, 'Picker PR'));
      final manualPr = userPrAttachment(prItem(303, 'Manual PR'));
      final forgePr = forgePrAttachment(prItem(404, 'Forge PR'));
      final issue = issueAttachment(44);

      expect(
        clearPickerPrAttachmentForTargetChange(
          attachments: [issue, pickerPr, manualPr, forgePr],
          currentTargetId: 'server-a',
          nextTargetId: 'server-b',
        ),
        [issue],
      );
    });

    // extra: a changed target returns a *new* list even when nothing was
    // removed, so identity alone never reports "unchanged" incorrectly.
    test(
      'returns a fresh list when the target changed but nothing matched',
      () {
        final attachments = [issueAttachment(44)];
        final result = clearPickerPrAttachmentForTargetChange(
          attachments: attachments,
          currentTargetId: 'server-a',
          nextTargetId: 'server-b',
        );

        expect(result, attachments);
        expect(result, isNot(same(attachments)));
      },
    );
  });

  group('reducePickerSelection', () {
    test('selects a PR that was newly detected and added', () {
      final item = ChangeRequestPickerItem(prItem(101, 'A'));
      final detected = reducePickerSelection(
        initialPickerSelectionState,
        const PrDetectedPickerEvent(),
      );

      expect(
        reducePickerSelection(detected, PrAddedPickerEvent(item)),
        PickerSelectionState(selectedItem: item, allowAutoPrSelection: false),
      );
    });

    test('keeps the first PR selected when one edit adds multiple PRs', () {
      final detected = reducePickerSelection(
        initialPickerSelectionState,
        const PrDetectedPickerEvent(),
      );
      final first = reducePickerSelection(
        detected,
        PrAddedPickerEvent(ChangeRequestPickerItem(prItem(101, 'A'))),
      );

      expect(
        reducePickerSelection(
          first,
          PrAddedPickerEvent(ChangeRequestPickerItem(prItem(202, 'B'))),
        ),
        same(first),
      );
    });

    test('keeps a branch selected after a pending PR is added', () {
      final detected = reducePickerSelection(
        initialPickerSelectionState,
        const PrDetectedPickerEvent(),
      );
      final branchSelected = reducePickerSelection(
        detected,
        const PickerSelectedPickerEvent(BranchPickerItem('main')),
      );

      expect(
        reducePickerSelection(
          branchSelected,
          PrAddedPickerEvent(ChangeRequestPickerItem(prItem(101, 'A'))),
        ),
        same(branchSelected),
      );
    });

    test('does not derive checkout selection from an existing attachment', () {
      expect(
        reducePickerSelection(
          initialPickerSelectionState,
          PrAddedPickerEvent(ChangeRequestPickerItem(prItem(101, 'A'))),
        ),
        initialPickerSelectionState,
      );
    });

    test('lets a newly detected PR replace an earlier explicit branch', () {
      final branchSelected = reducePickerSelection(
        initialPickerSelectionState,
        const PickerSelectedPickerEvent(BranchPickerItem('main')),
      );
      final detected = reducePickerSelection(
        branchSelected,
        const PrDetectedPickerEvent(),
      );
      final pr = ChangeRequestPickerItem(prItem(101, 'A'));

      expect(
        reducePickerSelection(detected, PrAddedPickerEvent(pr)).selectedItem,
        same(pr),
      );
    });

    // extra: `pr-detected` spreads the previous state, so it opens the window
    // without disturbing the current selection.
    test('pr-detected preserves the current selection', () {
      const branch = BranchPickerItem('main');
      final selected = reducePickerSelection(
        initialPickerSelectionState,
        const PickerSelectedPickerEvent(branch),
      );

      final detected = reducePickerSelection(
        selected,
        const PrDetectedPickerEvent(),
      );

      expect(detected.selectedItem, same(branch));
      expect(detected.allowAutoPrSelection, isTrue);
    });

    // extra: an explicit click always closes the auto-selection window.
    test('picker-selected closes the auto-selection window', () {
      final detected = reducePickerSelection(
        initialPickerSelectionState,
        const PrDetectedPickerEvent(),
      );

      expect(
        reducePickerSelection(
          detected,
          const PickerSelectedPickerEvent(BranchPickerItem('dev')),
        ).allowAutoPrSelection,
        isFalse,
      );
    });

    // extra: a target change wipes both fields.
    test('target-changed resets to the initial state', () {
      final detected = reducePickerSelection(
        reducePickerSelection(
          initialPickerSelectionState,
          const PickerSelectedPickerEvent(BranchPickerItem('dev')),
        ),
        const PrDetectedPickerEvent(),
      );

      expect(
        reducePickerSelection(detected, const TargetChangedPickerEvent()),
        initialPickerSelectionState,
      );
    });
  });

  // -------------------------------------------------------------------------
  // screens/new-workspace/project-selection.ts
  // -------------------------------------------------------------------------

  group('reconcileProjectSelection', () {
    test(
      'keeps a still-selectable project when the default moves after archive',
      () {
        final remembered = project('remembered');
        final other = project('other');
        final current = createProjectSelection(
          selectionContext(
            initialProject: remembered,
            projects: [remembered, other],
          ),
        );
        final afterArchive = selectionContext(
          initialProject: other,
          projects: [other, remembered],
        );

        final reconciled = reconcileProjectSelection(current, afterArchive);

        expect(
          reconciled,
          ProjectSelection(
            contextKey: 'host:',
            projectKey: remembered.projectKey,
            project: remembered,
            source: ProjectSelectionSource.initial,
          ),
        );
        expect(resolveProjectSelection(reconciled, afterArchive), remembered);
      },
    );

    test('resets stale selection when the route project context changes', () {
      final manual = project('manual');
      final routeProject = project('route-project');
      final current = ProjectSelection(
        contextKey: 'host:previous-route',
        projectKey: manual.projectKey,
        project: manual,
        source: ProjectSelectionSource.manual,
      );
      final nextContext = selectionContext(
        contextKey: 'host:route-project',
        initialProject: routeProject,
        projects: [manual, routeProject],
        routeProject: routeProject,
      );

      expect(
        reconcileProjectSelection(current, nextContext),
        ProjectSelection(
          contextKey: 'host:route-project',
          projectKey: routeProject.projectKey,
          project: routeProject,
          source: ProjectSelectionSource.initial,
        ),
      );
    });

    test('hydrates an empty initial selection when projects arrive', () {
      final initialProject = project('hydrated');
      final current = createProjectSelection(
        selectionContext(initialProject: null, projects: const []),
      );
      final hydratedContext = selectionContext(
        initialProject: initialProject,
        projects: [initialProject],
      );

      expect(
        reconcileProjectSelection(current, hydratedContext),
        ProjectSelection(
          contextKey: 'host:',
          projectKey: initialProject.projectKey,
          project: initialProject,
          source: ProjectSelectionSource.initial,
        ),
      );
    });

    test('stores hydrated project snapshots before archive gaps', () {
      final routeProject = project('route-project');
      final hydratedProject = routeProject.copyWith(
        workspaceKeys: const ['host:workspace'],
      );
      final current = createProjectSelection(
        selectionContext(
          initialProject: routeProject,
          projects: const [],
          routeProject: routeProject,
        ),
      );
      final afterHydration = selectionContext(
        initialProject: hydratedProject,
        projects: [hydratedProject],
        routeProject: routeProject,
      );

      final hydratedSelection = reconcileProjectSelection(
        current,
        afterHydration,
      );

      expect(
        hydratedSelection,
        ProjectSelection(
          contextKey: 'host:',
          projectKey: hydratedProject.projectKey,
          project: hydratedProject,
          source: ProjectSelectionSource.initial,
        ),
      );

      final archiveGap = selectionContext(
        initialProject: routeProject,
        projects: const [],
        routeProject: routeProject,
        shouldPreserveMissingProject: (candidate) =>
            candidate.workspaceKeys.contains('host:workspace'),
      );

      expect(
        resolveProjectSelection(hydratedSelection, archiveGap),
        hydratedProject,
      );
    });

    test(
      'resets an automatic fallback when the remembered project hydrates',
      () {
        final fallback = project('fallback');
        final remembered = project('remembered');
        final current = createProjectSelection(
          selectionContext(
            initialProject: fallback,
            projects: [fallback, remembered],
          ),
        );
        final afterRememberedHydration = selectionContext(
          initialProject: remembered,
          projects: [fallback, remembered],
          lastActiveProject: remembered,
        );

        expect(
          reconcileProjectSelection(current, afterRememberedHydration),
          ProjectSelection(
            contextKey: 'host:',
            projectKey: remembered.projectKey,
            project: remembered,
            source: ProjectSelectionSource.initial,
          ),
        );
      },
    );

    test('keeps manual selections when the remembered project hydrates', () {
      final manual = project('manual');
      final remembered = project('remembered');
      final current = ProjectSelection(
        contextKey: 'host:',
        projectKey: manual.projectKey,
        project: manual,
        source: ProjectSelectionSource.manual,
      );
      final afterRememberedHydration = selectionContext(
        initialProject: remembered,
        projects: [manual, remembered],
        lastActiveProject: remembered,
      );

      expect(
        reconcileProjectSelection(current, afterRememberedHydration),
        current,
      );
    });

    test('resets fallback selection when host project capability changes', () {
      final fallback = project('git-fallback');
      final remembered = project('remembered-directory');
      final current = createProjectSelection(
        selectionContext(
          contextKey: createProjectSelectionContextKey(
            selectedServerId: 'host',
            routeProjectKey: null,
            allowAllProjects: false,
          ),
          initialProject: fallback,
          projects: [fallback, remembered],
        ),
      );
      final afterCapabilityHydration = selectionContext(
        contextKey: createProjectSelectionContextKey(
          selectedServerId: 'host',
          routeProjectKey: null,
          allowAllProjects: true,
        ),
        initialProject: remembered,
        projects: [fallback, remembered],
      );

      expect(
        reconcileProjectSelection(current, afterCapabilityHydration),
        ProjectSelection(
          contextKey: 'host:all-projects:',
          projectKey: remembered.projectKey,
          project: remembered,
          source: ProjectSelectionSource.initial,
        ),
      );
    });

    test(
      'keeps a still-selectable manual selection when host project capability '
      'changes',
      () {
        final fallback = project('git-fallback');
        final manual = project('manual-choice');
        final remembered = project('remembered-directory');
        final current = ProjectSelection(
          contextKey: createManualProjectSelectionContextKey(
            selectedServerId: 'host',
            routeProjectKey: null,
          ),
          projectKey: manual.projectKey,
          project: manual,
          source: ProjectSelectionSource.manual,
        );
        final afterCapabilityHydration = selectionContext(
          contextKey: createProjectSelectionContextKey(
            selectedServerId: 'host',
            routeProjectKey: null,
            allowAllProjects: true,
          ),
          manualContextKey: createManualProjectSelectionContextKey(
            selectedServerId: 'host',
            routeProjectKey: null,
          ),
          initialProject: remembered,
          projects: [fallback, manual, remembered],
        );

        final reconciled = reconcileProjectSelection(
          current,
          afterCapabilityHydration,
        );

        expect(reconciled, current);
        expect(
          resolveProjectSelection(reconciled, afterCapabilityHydration),
          manual,
        );
      },
    );

    test(
      'keeps the selected project snapshot during a pending archive gap',
      () {
        final remembered = project('remembered');
        final fallback = project('fallback');
        final current = createProjectSelection(
          selectionContext(initialProject: remembered, projects: [remembered]),
        );
        final withoutRemembered = selectionContext(
          initialProject: fallback,
          projects: [fallback],
          shouldPreserveMissingProject: (candidate) =>
              candidate.projectKey == remembered.projectKey,
        );

        final reconciled = reconcileProjectSelection(
          current,
          withoutRemembered,
        );

        expect(reconciled, current);
        expect(
          resolveProjectSelection(reconciled, withoutRemembered),
          remembered,
        );
      },
    );

    test('falls back when the selected project disappears without a pending '
        'archive', () {
      final remembered = project('remembered');
      final fallback = project('fallback');
      final current = createProjectSelection(
        selectionContext(initialProject: remembered, projects: [remembered]),
      );
      final withoutRemembered = selectionContext(
        initialProject: fallback,
        projects: [fallback],
      );

      expect(
        reconcileProjectSelection(current, withoutRemembered),
        ProjectSelection(
          contextKey: 'host:',
          projectKey: fallback.projectKey,
          project: fallback,
          source: ProjectSelectionSource.initial,
        ),
      );
    });

    test('resolves manual selections from selectable projects, not route or '
        'remembered projects', () {
      final manual = project('manual');
      final routeProject = project('route-project');
      final remembered = project('remembered');
      final current = ProjectSelection(
        contextKey: 'host:route-project',
        projectKey: manual.projectKey,
        project: manual,
        source: ProjectSelectionSource.manual,
      );
      final context = selectionContext(
        contextKey: 'host:route-project',
        initialProject: routeProject,
        projects: [manual],
        routeProject: routeProject,
        lastActiveProject: remembered,
      );

      expect(resolveProjectSelection(current, context), manual);
    });

    // extra: the flip side of the case above — a manual selection that is no
    // longer selectable resolves to nothing rather than to the route project.
    test('resolves a vanished manual selection to nothing', () {
      final manual = project('manual');
      final routeProject = project('route-project');
      final current = ProjectSelection(
        contextKey: 'host:route-project',
        projectKey: manual.projectKey,
        project: manual,
        source: ProjectSelectionSource.manual,
      );
      final context = selectionContext(
        contextKey: 'host:route-project',
        initialProject: routeProject,
        projects: [routeProject],
        routeProject: routeProject,
        lastActiveProject: manual,
      );

      expect(resolveProjectSelection(current, context), isNull);
    });

    // extra: an automatic selection *does* fall back to the route or remembered
    // project while `projects` is still empty.
    test('resolves an automatic selection from the route project', () {
      final routeProject = project('route-project');
      final current = ProjectSelection(
        contextKey: 'host:',
        projectKey: routeProject.projectKey,
        project: null,
        source: ProjectSelectionSource.initial,
      );

      expect(
        resolveProjectSelection(
          current,
          selectionContext(
            initialProject: routeProject,
            projects: const [],
            routeProject: routeProject,
          ),
        ),
        routeProject,
      );
    });

    test('resolves an automatic selection from the remembered project', () {
      final remembered = project('remembered');
      final current = ProjectSelection(
        contextKey: 'host:',
        projectKey: remembered.projectKey,
        project: null,
        source: ProjectSelectionSource.initial,
      );

      expect(
        resolveProjectSelection(
          current,
          selectionContext(
            initialProject: remembered,
            projects: const [],
            lastActiveProject: remembered,
          ),
        ),
        remembered,
      );
    });

    // extra: `projectKey?.trim() || null` — a blank or whitespace-only key is
    // no key at all.
    test('resolves a blank project key to nothing', () {
      for (final projectKey in <String?>[null, '', '   ']) {
        expect(
          resolveProjectSelection(
            ProjectSelection(
              contextKey: 'host:',
              projectKey: projectKey,
              project: null,
              source: ProjectSelectionSource.initial,
            ),
            selectionContext(
              initialProject: project('anything'),
              projects: [project('anything')],
            ),
          ),
          isNull,
          reason: 'projectKey: ${projectKey ?? '<null>'}',
        );
      }
    });

    // extra: a padded key still matches the trimmed project key.
    test('trims the stored project key before matching', () {
      final only = project('only');

      expect(
        resolveProjectSelection(
          ProjectSelection(
            contextKey: 'host:',
            projectKey: '  only  ',
            project: null,
            source: ProjectSelectionSource.initial,
          ),
          selectionContext(initialProject: only, projects: [only]),
        ),
        only,
      );
    });

    // extra: refreshing onto a structurally-equal but distinct snapshot yields
    // a *new* selection object, matching upstream's `===` identity guard.
    test('produces a new selection for an equal-but-distinct snapshot', () {
      final stored = project('same');
      final refetched = project('same');
      final current = ProjectSelection(
        contextKey: 'host:',
        projectKey: 'same',
        project: stored,
        source: ProjectSelectionSource.initial,
      );

      final reconciled = reconcileProjectSelection(
        current,
        selectionContext(initialProject: refetched, projects: [refetched]),
      );

      expect(reconciled, current);
      expect(reconciled, isNot(same(current)));
      expect(reconciled.project, same(refetched));
    });

    // extra: the same snapshot instance short-circuits and returns the very
    // same selection object.
    test('returns the same selection for an identical snapshot', () {
      final only = project('only');
      final current = ProjectSelection(
        contextKey: 'host:',
        projectKey: 'only',
        project: only,
        source: ProjectSelectionSource.initial,
      );

      expect(
        reconcileProjectSelection(
          current,
          selectionContext(initialProject: only, projects: [only]),
        ),
        same(current),
      );
    });
  });

  group('project selection context keys', () {
    test('scopes the automatic key by project scope and route', () {
      expect(
        createProjectSelectionContextKey(
          selectedServerId: 'host',
          routeProjectKey: null,
          allowAllProjects: false,
        ),
        'host:worktree-projects:',
      );
      expect(
        createProjectSelectionContextKey(
          selectedServerId: 'host',
          routeProjectKey: 'repo',
          allowAllProjects: true,
        ),
        'host:all-projects:repo',
      );
    });

    test('omits the project scope from the manual key', () {
      expect(
        createManualProjectSelectionContextKey(
          selectedServerId: 'host',
          routeProjectKey: null,
        ),
        'host:',
      );
      expect(
        createManualProjectSelectionContextKey(
          selectedServerId: 'host',
          routeProjectKey: 'repo',
        ),
        'host:repo',
      );
    });
  });

  group('createProjectSelection', () {
    // extra: an empty context still produces a usable, null-keyed selection.
    test(
      'produces a null-keyed selection when there is no initial project',
      () {
        expect(
          createProjectSelection(
            selectionContext(initialProject: null, projects: const []),
          ),
          const ProjectSelection(
            contextKey: 'host:',
            projectKey: null,
            project: null,
            source: ProjectSelectionSource.initial,
          ),
        );
      },
    );
  });

  group('resolveInitialProjectSelectionSource', () {
    test('reports null when there is no initial project', () {
      expect(
        resolveInitialProjectSelectionSource(
          initialProject: null,
          routeProject: project('route'),
          lastActiveProject: project('remembered'),
        ),
        isNull,
      );
    });

    test('reports route when the route named the initial project', () {
      final routeProject = project('route');
      expect(
        resolveInitialProjectSelectionSource(
          initialProject: routeProject,
          routeProject: routeProject,
          lastActiveProject: routeProject,
        ),
        InitialProjectSelectionSource.route,
      );
    });

    test('reports lastActive when only the remembered project matches', () {
      final remembered = project('remembered');
      expect(
        resolveInitialProjectSelectionSource(
          initialProject: remembered,
          routeProject: project('route'),
          lastActiveProject: remembered,
        ),
        InitialProjectSelectionSource.lastActive,
      );
    });

    test('reports fallback when nothing matches', () {
      expect(
        resolveInitialProjectSelectionSource(
          initialProject: project('first'),
          routeProject: null,
          lastActiveProject: null,
        ),
        InitialProjectSelectionSource.fallback,
      );
    });
  });

  // -------------------------------------------------------------------------
  // screens/settings/appearance/apply-appearance.ts
  // -------------------------------------------------------------------------

  group('applyAppearance', () {
    late List<AppThemeName> patchedKeys;
    late List<AppearanceThemeUpdater> updaters;
    late List<(SyntaxThemeId, AppearanceColorScheme)> resolverCalls;

    setUp(() {
      patchedKeys = [];
      updaters = [];
      resolverCalls = [];
    });

    void updateTheme(AppThemeName key, AppearanceThemeUpdater updater) {
      patchedKeys.add(key);
      updaters.add(updater);
    }

    Map<String, String> resolveSyntaxColors(
      SyntaxThemeId theme,
      AppearanceColorScheme colorScheme,
    ) {
      resolverCalls.add((theme, colorScheme));
      return {'palette': '${theme.wireValue}/${colorScheme.name}'};
    }

    void apply(AppearanceInput input, {void Function(String)? rootFont}) {
      applyAppearance(
        input,
        updateTheme: updateTheme,
        resolveSyntaxColors: resolveSyntaxColors,
        applyRootUiFont: rootFont,
      );
    }

    AppearanceThemeSnapshot run({
      int call = 0,
      AppearanceThemeSnapshot? theme,
    }) => updaters[call](theme ?? fakeTheme());

    test('patches every registered theme exactly once', () {
      apply(appearanceInput());

      expect(patchedKeys, hasLength(6));
      expect(patchedKeys, appearancePatchableThemeKeys);
    });

    // extra: `auto` is not a registered theme — it resolves to light or dark,
    // both of which are patched.
    test('never patches the auto theme', () {
      apply(appearanceInput());

      expect(patchedKeys, isNot(contains(AppThemeName.auto)));
    });

    test('resolves an empty UI font family to the default stack', () {
      apply(appearanceInput(uiFontFamily: ''));

      expect(run().fontFamily.ui, paseoDefaultUiFontStack);
    });

    test('passes a non-empty UI font family through trimmed', () {
      apply(appearanceInput(uiFontFamily: '  Menlo  '));

      expect(run().fontFamily.ui, 'Menlo');
    });

    // extra: the mono family follows the same trim-or-default rule.
    test('resolves a blank mono font family to the default stack', () {
      apply(appearanceInput(monoFontFamily: '   '));

      expect(run().fontFamily.mono, paseoDefaultMonoFontStack);
    });

    test('passes a non-empty mono font family through trimmed', () {
      apply(appearanceInput(monoFontFamily: '  Cascadia Code  '));

      expect(run().fontFamily.mono, 'Cascadia Code');
    });

    // extra: the platform fallbacks are injectable, because `Platform.select`
    // has no Dart analogue in a pure library.
    test('uses injected font stack fallbacks', () {
      applyAppearance(
        appearanceInput(),
        updateTheme: updateTheme,
        resolveSyntaxColors: resolveSyntaxColors,
        uiFontStackFallback: paseoDefaultUiFontStackWeb,
        monoFontStackFallback: paseoDefaultMonoFontStackWeb,
      );

      expect(run().fontFamily.ui, paseoDefaultUiFontStackWeb);
      expect(run().fontFamily.mono, paseoDefaultMonoFontStackWeb);
    });

    test('scales the whole UI ramp proportionally while preserving ratios', () {
      apply(appearanceInput(uiFontSize: 14));

      final fontSize = run().fontSize;
      // r = 14 / 16 = 0.875
      expect(fontSize.base, 14); // round(16 * 0.875)
      expect(fontSize.lg, 16); // round(18 * 0.875) = round(15.75)
      expect(fontSize.xs, 11); // round(12 * 0.875) = round(10.5)
      expect(fontSize.xl4, 30); // round(34 * 0.875) = round(29.75)
    });

    test(
      'derives the UI ramp from the canonical sizes, not the live theme',
      () {
        apply(appearanceInput(uiFontSize: 14));

        final alreadyScaled = fakeTheme(
          fontSize: const AppearanceFontSizeRamp(
            xs: 4,
            code: 4,
            sm: 4,
            base: 4,
            lg: 4,
            xl: 4,
            xl2: 4,
            xl3: 4,
            xl4: 4,
          ),
        );

        final fontSize = run(theme: alreadyScaled).fontSize;
        expect(fontSize.base, 14); // not 4 * 0.875 — rebuilt from the ramp
        expect(fontSize.lg, 16);
      },
    );

    test(
      'leaves the UI ramp at authored sizes when only the code size changes',
      () {
        apply(appearanceInput(uiFontSize: 16, codeFontSize: 10));

        final fontSize = run().fontSize;
        expect(fontSize.base, 16);
        expect(fontSize.sm, 14);
        expect(fontSize.code, 10);
      },
    );

    test('sets the code size regardless of the UI font size', () {
      apply(appearanceInput(uiFontSize: 14, codeFontSize: 18));

      expect(run().fontSize.code, 18);
    });

    // extra: applying twice must not compound the scale.
    test('is idempotent across repeated applies', () {
      apply(appearanceInput(uiFontSize: 14));
      final once = run();
      apply(appearanceInput(uiFontSize: 14));
      final twice = run(call: 6, theme: once);

      expect(twice.fontSize, once.fontSize);
    });

    test('couples the diff line height to the code font size', () {
      apply(appearanceInput(codeFontSize: 18));

      expect(run().lineHeight['diff'], 27); // round(18 * 1.5)
    });

    // extra: every other line-height key survives the replacement.
    test('preserves line-height keys other than diff', () {
      apply(appearanceInput());

      final patched = run(
        theme: fakeTheme(lineHeight: const {'diff': 22, 'body': 20}),
      );
      expect(patched.lineHeight, {'diff': 18, 'body': 20});
    });

    test(
      'swaps the syntax palette to the resolved one for the named theme',
      () {
        apply(appearanceInput(syntaxTheme: SyntaxThemeId.dracula));

        expect(run().colors['syntax'], {'palette': 'dracula/dark'});
      },
    );

    test('resolves a syntax theme using the theme\'s own color scheme', () {
      apply(appearanceInput(syntaxTheme: SyntaxThemeId.github));

      expect(
        run(
          theme: fakeTheme(colorScheme: AppearanceColorScheme.light),
        ).colors['syntax'],
        {'palette': 'github/light'},
      );
      expect(resolverCalls.last, (
        SyntaxThemeId.github,
        AppearanceColorScheme.light,
      ));
    });

    // extra: colors other than `syntax` are passed through untouched — plain
    // text stays owned by the theme.
    test('preserves colors other than syntax', () {
      apply(appearanceInput());

      final patched = run(
        theme: fakeTheme(colors: {'foreground': '#fff', 'syntax': const {}}),
      );
      expect(patched.colors['foreground'], '#fff');
    });

    // extra: the theme's own polarity survives the replacement.
    test('preserves the theme color scheme', () {
      apply(appearanceInput());

      expect(
        run(
          theme: fakeTheme(colorScheme: AppearanceColorScheme.light),
        ).colorScheme,
        AppearanceColorScheme.light,
      );
    });

    // extra: the root-font hook receives the *resolved* family, not the raw
    // input, and is optional.
    test('applies the resolved UI font to the root', () {
      final rootFonts = <String>[];
      apply(
        appearanceInput(uiFontFamily: '  Menlo  '),
        rootFont: rootFonts.add,
      );

      expect(rootFonts, ['Menlo']);
    });

    test('tolerates a missing root-font hook', () {
      expect(() => apply(appearanceInput()), returnsNormally);
    });

    // extra: the polarity mapping the six keys imply.
    test('maps every dark theme key to the dark color scheme', () {
      expect(
        appearanceColorSchemeForThemeKey(AppThemeName.light),
        AppearanceColorScheme.light,
      );
      for (final key in appearancePatchableThemeKeys.skip(1)) {
        expect(
          appearanceColorSchemeForThemeKey(key),
          AppearanceColorScheme.dark,
          reason: key.name,
        );
      }
      expect(
        appearanceColorSchemeForThemeKey(AppThemeName.auto),
        AppearanceColorScheme.dark,
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Bulk-close fakes
// ---------------------------------------------------------------------------

final class RecordingCloseItemsClient implements BulkCloseItemsClient {
  final List<Map<String, List<String>>> calls = [];

  @override
  Future<void> closeItems({
    required List<String> agentIds,
    required List<String> terminalIds,
  }) async {
    calls.add({'agentIds': agentIds, 'terminalIds': terminalIds});
  }
}

final class ThrowingCloseItemsClient implements BulkCloseItemsClient {
  @override
  Future<void> closeItems({
    required List<String> agentIds,
    required List<String> terminalIds,
  }) async {
    throw StateError('rpc failed');
  }
}

// ---------------------------------------------------------------------------
// Picker fixtures
// ---------------------------------------------------------------------------

ForgeSearchItem prItem(
  int number,
  String title, {
  String headRefName = 'feature/x',
}) => ForgeSearchItem(
  kind: ForgeSearchKind.changeRequest,
  number: number,
  title: title,
  url: 'https://example.com/pull/$number',
  state: 'open',
  body: null,
  labels: const [],
  baseRefName: 'main',
  headRefName: headRefName,
);

GithubPrComposerAttachment pickerPrAttachment(ForgeSearchItem item) =>
    GithubPrComposerAttachment(
      ForgeSearchItemLike.of(item.number, item),
      owner: newWorkspacePickerAttachmentOwner,
    );

GithubPrComposerAttachment userPrAttachment(ForgeSearchItem item) =>
    GithubPrComposerAttachment(ForgeSearchItemLike.of(item.number, item));

ForgeChangeRequestComposerAttachment forgePrAttachment(ForgeSearchItem item) =>
    ForgeChangeRequestComposerAttachment(
      ForgeSearchItemLike.of(item.number, item),
    );

UserComposerAttachment issueAttachment(int number) =>
    OtherUserComposerAttachment('github_issue', payload: number);

// ---------------------------------------------------------------------------
// Project-selection fixtures
// ---------------------------------------------------------------------------

HostProjectListItem project(String projectKey, {String serverId = 'host'}) =>
    HostProjectListItem(
      projectKey: projectKey,
      projectName: projectKey,
      projectKind: WorkspaceProjectKind.git,
      iconWorkingDir: '/work/$projectKey',
      hosts: [
        WorkspaceStructureHostPlacement(
          serverId: serverId,
          iconWorkingDir: '/work/$projectKey',
          canCreateWorktree: true,
        ),
      ],
      workspaceKeys: const [],
    );

/// The Dart analogue of the upstream suite's `context()` helper.
ProjectSelectionContext selectionContext({
  required HostProjectListItem? initialProject,
  required List<HostProjectListItem> projects,
  String contextKey = 'host:',
  String? manualContextKey,
  HostProjectListItem? routeProject,
  HostProjectListItem? lastActiveProject,
  InitialProjectSelectionSource? initialProjectSource,
  bool Function(HostProjectListItem project)? shouldPreserveMissingProject,
}) => ProjectSelectionContext(
  contextKey: contextKey,
  manualContextKey: manualContextKey ?? contextKey,
  initialProject: initialProject,
  initialProjectSource:
      initialProjectSource ??
      resolveInitialProjectSelectionSource(
        initialProject: initialProject,
        routeProject: routeProject,
        lastActiveProject: lastActiveProject,
      ),
  projects: projects,
  routeProject: routeProject,
  lastActiveProject: lastActiveProject,
  shouldPreserveMissingProject: shouldPreserveMissingProject ?? (_) => false,
);

// ---------------------------------------------------------------------------
// Appearance fixtures
// ---------------------------------------------------------------------------

AppearanceInput appearanceInput({
  String uiFontFamily = '',
  String monoFontFamily = '',
  num uiFontSize = 16,
  num codeFontSize = 12,
  SyntaxThemeId syntaxTheme = SyntaxThemeId.one,
}) => AppearanceInput(
  uiFontFamily: uiFontFamily,
  monoFontFamily: monoFontFamily,
  uiFontSize: uiFontSize,
  codeFontSize: codeFontSize,
  syntaxTheme: syntaxTheme,
);

AppearanceThemeSnapshot fakeTheme({
  AppearanceColorScheme colorScheme = AppearanceColorScheme.dark,
  AppearanceFontSizeRamp? fontSize,
  Map<String, num>? lineHeight,
  Map<String, Object?>? colors,
}) => AppearanceThemeSnapshot(
  colorScheme: colorScheme,
  fontFamily: const AppearanceFontFamilies(
    ui: 'seed-ui-stack',
    mono: 'seed-mono-stack',
  ),
  fontSize: fontSize ?? paseoFontSizeRamp,
  lineHeight: lineHeight ?? const {'diff': paseoDiffLineHeight},
  colors: colors ?? const {'foreground': '#fff', 'syntax': <String, String>{}},
);
