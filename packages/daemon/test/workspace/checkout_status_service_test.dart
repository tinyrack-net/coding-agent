import 'package:agent_daemon/src/workspace/checkout_status_service.dart';
import 'package:agent_daemon/src/workspace/polling_workspace_git_backend.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'returns the frozen non-git status and ignores other messages',
    () async {
      final service = CheckoutStatusService(
        loadSnapshot: (_, {baseRef}) async => null,
        resolveWorkspace: (_) async => null,
      );

      final response = CheckoutStatusResponse.fromJson(
        (await service.handle(_request()))!,
      );

      expect(response.payload, isA<CheckoutStatusNotGit>());
      expect(response.payload.cwd, '/repo');
      expect(response.payload.error, isNull);
      expect(await service.handle({'type': 'other'}), isNull);
    },
  );

  test('projects a non-owned Git checkout snapshot', () async {
    String? observedBase;
    final service = CheckoutStatusService(
      loadSnapshot: (_, {baseRef}) async {
        observedBase = baseRef;
        return _snapshot();
      },
      resolveWorkspace: (_) async => _workspace(owned: false),
    );

    final payload =
        CheckoutStatusResponse.fromJson(
              (await service.handle(_request()))!,
            ).payload
            as CheckoutStatusGitNonPaseo;

    expect(observedBase, 'main');
    expect(payload.repoRoot, '/repo');
    expect(payload.mainRepoRoot, '/main');
    expect(payload.currentBranch, 'feature');
    expect(payload.isDirty, isTrue);
    expect(payload.aheadBehind?.ahead, 2);
    expect(payload.aheadBehind?.behind, 1);
    expect(payload.aheadOfOrigin, 3);
    expect(payload.behindOfOrigin, 4);
    expect(payload.hasRemote, isTrue);
  });

  test('projects strict owned-worktree roots and base ref', () async {
    final service = CheckoutStatusService(
      loadSnapshot: (_, {baseRef}) async =>
          _snapshot(mainRepoRoot: null, baseRef: null),
      resolveWorkspace: (_) async => _workspace(owned: true),
    );

    final payload =
        CheckoutStatusResponse.fromJson(
              (await service.handle(_request()))!,
            ).payload
            as CheckoutStatusGitPaseo;

    expect(payload.mainRepoRoot, '/registered-main');
    expect(payload.baseRef, 'main');
    expect(payload.isPaseoOwnedWorktree, isTrue);
  });

  test('normalizes snapshot failures into a frozen checkout error', () async {
    final service = CheckoutStatusService(
      loadSnapshot: (_, {baseRef}) async =>
          throw StateError('snapshot unavailable'),
      resolveWorkspace: (_) async => null,
    );

    final payload = CheckoutStatusResponse.fromJson(
      (await service.handle(_request()))!,
    ).payload;

    expect(payload, isA<CheckoutStatusNotGit>());
    expect(payload.error?.code, CheckoutErrorCode.unknown);
    expect(payload.error?.message, 'Bad state: snapshot unavailable');
  });
}

Map<String, Object?> _request() =>
    const CheckoutStatusRequest(cwd: '/repo', requestId: 'status-1').toJson();

WorkspaceLocalGitSnapshot _snapshot({
  String? mainRepoRoot = '/main',
  String? baseRef = 'main',
}) => WorkspaceLocalGitSnapshot(
  cwd: '/repo',
  repoRoot: '/repo',
  mainRepoRoot: mainRepoRoot,
  currentBranch: 'feature',
  headSha: 'abc123',
  remoteUrl: 'git@example.test:org/repo.git',
  isDirty: true,
  baseRef: baseRef,
  aheadBehind: const WorkspaceAheadBehind(ahead: 2, behind: 1),
  aheadOfOrigin: 3,
  behindOfOrigin: 4,
  diffStat: const WorkspaceDiffStat(additions: 5, deletions: 6),
);

PersistedWorkspaceRecord _workspace({required bool owned}) =>
    createPersistedWorkspaceRecord(
      workspaceId: 'workspace-1',
      projectId: 'project-1',
      cwd: '/repo',
      kind: owned
          ? PersistedWorkspaceKind.worktree
          : PersistedWorkspaceKind.localCheckout,
      displayName: 'repo',
      baseBranch: 'main',
      isPaseoOwnedWorktree: owned,
      mainRepoRoot: owned ? '/registered-main' : null,
      createdAt: '2026-01-01T00:00:00Z',
      updatedAt: '2026-01-01T00:00:00Z',
    );
