import 'package:agent_protocol/agent_protocol.dart';

final class CreateAgentCaller {
  const CreateAgentCaller({
    required this.id,
    required this.cwd,
    required this.workspaceId,
  });

  final String id;
  final String cwd;
  final String? workspaceId;
}

final class CreateAgentPlacement {
  const CreateAgentPlacement({required this.workspaceId, required this.cwd});

  final String workspaceId;
  final String cwd;
}

final class CreateAgentIntent {
  const CreateAgentIntent({
    required this.workspaceId,
    required this.cwd,
    required this.parentAgentId,
    required this.labels,
  });

  final String workspaceId;
  final String cwd;
  final String? parentAgentId;
  final Map<String, String> labels;
}

Future<CreateAgentIntent> resolveCreateAgentIntent({
  String? explicitWorkspaceId,
  required CreateAgentCaller? caller,
  Map<String, String>? labels,
  Map<String, String>? childAgentDefaultLabels,
  required Future<CreateAgentPlacement> Function(String workspaceId)
  resolveWorkspace,
  required Future<CreateAgentPlacement> Function() createWorkspace,
  bool legacyDetached = false,
}) async {
  final parentAgentId = legacyDetached ? null : caller?.id;
  final placement = await _resolvePlacement(
    explicitWorkspaceId: explicitWorkspaceId,
    caller: caller,
    resolveWorkspace: resolveWorkspace,
    createWorkspace: createWorkspace,
  );
  final resolvedLabels = <String, String>{
    ...?childAgentDefaultLabels,
    ...?labels,
    if (parentAgentId != null) paseoParentAgentIdLabel: parentAgentId,
  };

  if (legacyDetached) {
    resolvedLabels.remove(paseoParentAgentIdLabel);
  }

  return CreateAgentIntent(
    workspaceId: placement.workspaceId,
    cwd: placement.cwd,
    parentAgentId: parentAgentId,
    labels: Map.unmodifiable(resolvedLabels),
  );
}

Future<CreateAgentPlacement> _resolvePlacement({
  required String? explicitWorkspaceId,
  required CreateAgentCaller? caller,
  required Future<CreateAgentPlacement> Function(String workspaceId)
  resolveWorkspace,
  required Future<CreateAgentPlacement> Function() createWorkspace,
}) async {
  if (explicitWorkspaceId != null && explicitWorkspaceId.isNotEmpty) {
    return resolveWorkspace(explicitWorkspaceId);
  }
  if (caller != null) {
    final workspaceId = caller.workspaceId;
    if (workspaceId == null || workspaceId.isEmpty) {
      throw StateError('Caller agent ${caller.id} has no workspace');
    }
    return CreateAgentPlacement(workspaceId: workspaceId, cwd: caller.cwd);
  }
  return createWorkspace();
}
