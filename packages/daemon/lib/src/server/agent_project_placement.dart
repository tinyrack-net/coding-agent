import 'package:agent_protocol/agent_protocol.dart';

import '../workspace/workspace_registry.dart';

Future<Map<String, Object?>?> buildAgentProjectPlacement(
  AgentSummary agent,
  WorkspaceRegistries registries, {
  bool activeOnly = false,
}) async {
  final workspaceId = agent.workspaceId;
  if (workspaceId == null) return null;
  final workspace = await registries.workspaces.get(workspaceId);
  if (workspace == null) return null;
  final project = await registries.projects.get(workspace.projectId);
  if (project == null) return null;
  if (activeOnly &&
      (agent.archivedAt != null ||
          workspace.archivedAt != null ||
          project.archivedAt != null)) {
    return null;
  }

  return {
    'projectKey': project.projectId,
    'projectName': resolveProjectDisplayName(project),
    'workspaceName': resolveWorkspaceDisplayName(workspace),
    'checkout': _checkoutFromWorkspace(workspace),
  };
}

Map<String, Object?> _checkoutFromWorkspace(
  PersistedWorkspaceRecord workspace,
) {
  if (workspace.kind == PersistedWorkspaceKind.directory) {
    return {
      'cwd': workspace.cwd,
      'isGit': false,
      'currentBranch': null,
      'remoteUrl': null,
      'worktreeRoot': null,
      'isPaseoOwnedWorktree': false,
      'mainRepoRoot': null,
    };
  }
  return {
    'cwd': workspace.cwd,
    'isGit': true,
    'currentBranch': workspace.branch,
    'remoteUrl': null,
    'worktreeRoot': workspace.worktreeRoot ?? workspace.cwd,
    'isPaseoOwnedWorktree': workspace.isPaseoOwnedWorktree,
    'mainRepoRoot': workspace.mainRepoRoot,
  };
}
