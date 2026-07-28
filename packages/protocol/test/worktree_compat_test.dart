import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('legacy create worktree request round trips every option', () {
    const request = CreatePaseoWorktreeRequest(
      requestId: 'create-1',
      cwd: '/repo',
      projectId: 'project-1',
      worktreeSlug: 'feature-x',
      firstAgentContext: {'prompt': 'Implement x'},
      refName: 'main',
      action: 'branch-off',
      checkoutSource: {'kind': 'change_request', 'number': 42},
      githubPrNumber: 42,
    );
    expect(
      CreatePaseoWorktreeRequest.fromJson(request.toJson()).toJson(),
      request.toJson(),
    );
    expect(
      () => CreatePaseoWorktreeRequest.fromJson({
        ...request.toJson(),
        'action': 'fork',
      }),
      throwsFormatException,
    );
  });

  test('legacy worktree list preserves nullable git metadata and errors', () {
    const response = PaseoWorktreeListResponse(
      requestId: 'list-1',
      worktrees: [
        PaseoWorktreeDescriptor(
          worktreePath: '/managed/feature',
          createdAt: '2026-07-29T00:00:00.000Z',
          branchName: 'feature',
        ),
      ],
      error: null,
    );
    final decoded = PaseoWorktreeListResponse.fromJson(response.toJson());
    expect(decoded.worktrees.single.branchName, 'feature');
    expect(decoded.worktrees.single.head, isNull);
    expect(decoded.error, isNull);
  });

  test('legacy archive validates scope and defaults removed agents', () {
    const request = PaseoWorktreeArchiveRequest(
      requestId: 'archive-1',
      worktreePath: '/managed/feature',
      scope: 'worktree',
    );
    expect(
      PaseoWorktreeArchiveRequest.fromJson(request.toJson()).scope,
      'worktree',
    );
    expect(
      () => PaseoWorktreeArchiveRequest.fromJson({
        ...request.toJson(),
        'scope': 'project',
      }),
      throwsFormatException,
    );
    final response = PaseoWorktreeArchiveResponse.fromJson({
      'type': PaseoWorktreeArchiveResponse.type,
      'payload': {'success': true, 'error': null, 'requestId': 'archive-1'},
    });
    expect(response.removedAgents, isEmpty);
  });

  test('legacy create response preserves workspace and error code', () {
    const response = CreatePaseoWorktreeResponse(
      requestId: 'create-1',
      workspace: {'id': 'workspace-1'},
      error: null,
      setupTerminalId: null,
    );
    expect(CreatePaseoWorktreeResponse.fromJson(response.toJson()).workspace, {
      'id': 'workspace-1',
    });
    const failed = CreatePaseoWorktreeResponse(
      requestId: 'create-2',
      workspace: null,
      error: 'failed',
      errorCode: 'git_error',
      setupTerminalId: null,
    );
    expect(
      CreatePaseoWorktreeResponse.fromJson(failed.toJson()).errorCode,
      'git_error',
    );
  });
}
