import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import 'polling_workspace_git_backend.dart';
import 'workspace_registry.dart';

typedef CheckoutStatusSnapshotLoader =
    Future<WorkspaceLocalGitSnapshot?> Function(String cwd, {String? baseRef});
typedef CheckoutStatusWorkspaceResolver =
    Future<PersistedWorkspaceRecord?> Function(String cwd);

/// Frozen Paseo checkout-status request projection over the shared Git
/// snapshot backend.
final class CheckoutStatusService {
  CheckoutStatusService({
    required CheckoutStatusSnapshotLoader loadSnapshot,
    required CheckoutStatusWorkspaceResolver resolveWorkspace,
  }) : _loadSnapshot = loadSnapshot,
       _resolveWorkspace = resolveWorkspace;

  final CheckoutStatusSnapshotLoader _loadSnapshot;
  final CheckoutStatusWorkspaceResolver _resolveWorkspace;

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    if (message['type'] != CheckoutStatusRequest.type) return null;
    final request = CheckoutStatusRequest.fromJson(message);
    final resolvedCwd = _expandTilde(request.cwd);
    try {
      final workspace = await _resolveWorkspace(resolvedCwd);
      final snapshot = await _loadSnapshot(
        resolvedCwd,
        baseRef: workspace?.baseBranch,
      );
      final payload = snapshot == null
          ? CheckoutStatusNotGit(
              cwd: request.cwd,
              error: null,
              requestId: request.requestId,
            )
          : projectCheckoutStatusPayload(
              cwd: request.cwd,
              requestId: request.requestId,
              snapshot: snapshot,
              workspace: workspace,
            );
      return CheckoutStatusResponse(payload).toJson();
    } on Object catch (error) {
      return CheckoutStatusResponse(
        CheckoutStatusNotGit(
          cwd: request.cwd,
          error: CheckoutError(
            code: CheckoutErrorCode.unknown,
            message: _errorMessage(error),
          ),
          requestId: request.requestId,
        ),
      ).toJson();
    }
  }
}

CheckoutStatusPayload projectCheckoutStatusPayload({
  required String cwd,
  required String requestId,
  required WorkspaceLocalGitSnapshot snapshot,
  required PersistedWorkspaceRecord? workspace,
}) {
  final owned = workspace?.isPaseoOwnedWorktree == true;
  final aheadBehind = snapshot.aheadBehind == null
      ? null
      : CheckoutAheadBehind(
          ahead: snapshot.aheadBehind!.ahead,
          behind: snapshot.aheadBehind!.behind,
        );
  if (owned) {
    final mainRepoRoot = workspace?.mainRepoRoot ?? snapshot.mainRepoRoot;
    final baseRef = workspace?.baseBranch ?? snapshot.baseRef;
    if (mainRepoRoot == null || baseRef == null) {
      throw StateError(
        'Workspace git snapshot is missing required worktree status fields',
      );
    }
    return CheckoutStatusGitPaseo(
      cwd: cwd,
      repoRoot: snapshot.repoRoot,
      mainRepoRoot: mainRepoRoot,
      currentBranch: snapshot.currentBranch,
      isDirty: snapshot.isDirty,
      baseRef: baseRef,
      aheadBehind: aheadBehind,
      aheadOfOrigin: snapshot.aheadOfOrigin,
      behindOfOrigin: snapshot.behindOfOrigin,
      hasRemote: snapshot.hasRemote,
      remoteUrl: snapshot.remoteUrl,
      error: null,
      requestId: requestId,
    );
  }
  return CheckoutStatusGitNonPaseo(
    cwd: cwd,
    repoRoot: snapshot.repoRoot,
    mainRepoRoot: snapshot.mainRepoRoot,
    currentBranch: snapshot.currentBranch,
    isDirty: snapshot.isDirty,
    baseRef: snapshot.baseRef,
    aheadBehind: aheadBehind,
    aheadOfOrigin: snapshot.aheadOfOrigin,
    behindOfOrigin: snapshot.behindOfOrigin,
    hasRemote: snapshot.hasRemote,
    remoteUrl: snapshot.remoteUrl,
    error: null,
    requestId: requestId,
  );
}

Future<PersistedWorkspaceRecord?> resolveCheckoutStatusWorkspace(
  FileBackedWorkspaceRegistry workspaces,
  String cwd,
) async {
  for (final workspace in await workspaces.list()) {
    if (workspace.archivedAt == null &&
        areEquivalentPaths(workspace.cwd, cwd)) {
      return workspace;
    }
  }
  return null;
}

String _errorMessage(Object error) => error.toString();

String _expandTilde(String value) {
  if (value != '~' && !value.startsWith('~/') && !value.startsWith(r'~\')) {
    return value;
  }
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home == null || home.isEmpty) return value;
  if (value == '~') return home;
  return p.join(home, value.substring(2));
}
