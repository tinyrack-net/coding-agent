import 'package:uuid/uuid.dart';

import 'workspace_tab_model.dart';

final class PrepareWorkspaceTabInput {
  const PrepareWorkspaceTabInput({
    required this.serverId,
    required this.workspaceId,
    required this.target,
    this.pin = false,
  });

  final String serverId;
  final String workspaceId;
  final WorkspaceTabTarget target;
  final bool pin;
}

final class PrepareWorkspaceTabDependencies {
  const PrepareWorkspaceTabDependencies({
    required this.openTabFocused,
    required this.pinAgent,
  });

  final String? Function(String workspaceKey, WorkspaceTabTarget target)
  openTabFocused;
  final void Function(String workspaceKey, String agentId) pinAgent;
}

void prepareWorkspaceTab(
  PrepareWorkspaceTabInput input,
  PrepareWorkspaceTabDependencies dependencies, {
  Uuid uuid = const Uuid(),
}) {
  final target =
      input.target is WorkspaceDraftTabTarget &&
          (input.target as WorkspaceDraftTabTarget).draftId.trim() == 'new'
      ? WorkspaceDraftTabTarget(draftId: uuid.v4())
      : input.target;
  final workspaceKey =
      buildWorkspaceTabPersistenceKey(
        serverId: input.serverId,
        workspaceId: input.workspaceId,
      ) ??
      '';

  dependencies.openTabFocused(workspaceKey, target);
  if (input.pin && target is WorkspaceAgentTabTarget) {
    dependencies.pinAgent(workspaceKey, target.agentId);
  }
}
