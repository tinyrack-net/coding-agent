import 'messages/agent.dart';
import 'messages/workspace_v2.dart';

WorkspaceStateBucket deriveAgentStateBucket({
  required AgentRunState status,
  int pendingPermissionCount = 0,
  bool requiresAttention = false,
  AgentAttentionReason? attentionReason,
}) {
  if (pendingPermissionCount > 0 ||
      status == AgentRunState.awaitingPermission ||
      attentionReason == AgentAttentionReason.permission) {
    return WorkspaceStateBucket.needsInput;
  }
  if (status == AgentRunState.error ||
      attentionReason == AgentAttentionReason.error) {
    return WorkspaceStateBucket.failed;
  }
  if (status == AgentRunState.running) {
    return WorkspaceStateBucket.running;
  }
  if (requiresAttention) return WorkspaceStateBucket.attention;
  return WorkspaceStateBucket.done;
}

int getWorkspaceStateBucketPriority(WorkspaceStateBucket bucket) =>
    switch (bucket) {
      WorkspaceStateBucket.needsInput => 0,
      WorkspaceStateBucket.failed => 1,
      WorkspaceStateBucket.running => 2,
      WorkspaceStateBucket.attention => 3,
      WorkspaceStateBucket.done => 4,
    };

int getAgentStatusPriority({
  required AgentRunState status,
  int pendingPermissionCount = 0,
  AgentAttentionReason? attentionReason,
}) {
  if (pendingPermissionCount > 0 ||
      status == AgentRunState.awaitingPermission ||
      attentionReason == AgentAttentionReason.permission) {
    return 0;
  }
  if (status == AgentRunState.error ||
      attentionReason == AgentAttentionReason.error) {
    return 1;
  }
  if (status == AgentRunState.running) return 2;
  if (status == AgentRunState.initializing) return 3;
  return 4;
}
