import 'package:agent_protocol/agent_protocol.dart';

typedef SidebarStateBucket = WorkspaceStateBucket;

SidebarStateBucket deriveSidebarStateBucket({
  required AgentRunState status,
  int pendingPermissionCount = 0,
  bool requiresAttention = false,
  AgentAttentionReason? attentionReason,
}) => deriveAgentStateBucket(
  status: status,
  pendingPermissionCount: pendingPermissionCount,
  requiresAttention: requiresAttention,
  attentionReason: attentionReason,
);

bool isSidebarActiveAgent({
  required AgentRunState status,
  int pendingPermissionCount = 0,
  bool requiresAttention = false,
  AgentAttentionReason? attentionReason,
}) =>
    deriveSidebarStateBucket(
      status: status,
      pendingPermissionCount: pendingPermissionCount,
      requiresAttention: requiresAttention,
      attentionReason: attentionReason,
    ) !=
    WorkspaceStateBucket.done;
