import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('derives Paseo state buckets in exact priority order', () {
    expect(
      deriveAgentStateBucket(
        status: AgentRunState.running,
        pendingPermissionCount: 1,
      ),
      WorkspaceStateBucket.needsInput,
    );
    expect(
      deriveAgentStateBucket(
        status: AgentRunState.running,
        attentionReason: AgentAttentionReason.error,
      ),
      WorkspaceStateBucket.failed,
    );
    expect(
      deriveAgentStateBucket(status: AgentRunState.running),
      WorkspaceStateBucket.running,
    );
    expect(
      deriveAgentStateBucket(
        status: AgentRunState.idle,
        requiresAttention: true,
        attentionReason: AgentAttentionReason.finished,
      ),
      WorkspaceStateBucket.attention,
    );
    expect(
      deriveAgentStateBucket(status: AgentRunState.idle),
      WorkspaceStateBucket.done,
    );
    expect(
      WorkspaceStateBucket.values.map((bucket) => bucket.wireName).toList(),
      ['needs_input', 'failed', 'running', 'attention', 'done'],
    );
  });

  test('permission and error reasons override lifecycle state', () {
    expect(
      deriveAgentStateBucket(
        status: AgentRunState.error,
        attentionReason: AgentAttentionReason.permission,
      ),
      WorkspaceStateBucket.needsInput,
    );
    expect(
      deriveAgentStateBucket(
        status: AgentRunState.idle,
        attentionReason: AgentAttentionReason.error,
      ),
      WorkspaceStateBucket.failed,
    );
    expect(
      deriveAgentStateBucket(status: AgentRunState.awaitingPermission),
      WorkspaceStateBucket.needsInput,
    );
  });

  test('bucket and status priorities match Paseo ordering', () {
    expect(
      WorkspaceStateBucket.values.map(getWorkspaceStateBucketPriority).toList(),
      [0, 1, 2, 3, 4],
    );
    expect(getAgentStatusPriority(status: AgentRunState.awaitingPermission), 0);
    expect(getAgentStatusPriority(status: AgentRunState.error), 1);
    expect(getAgentStatusPriority(status: AgentRunState.running), 2);
    expect(getAgentStatusPriority(status: AgentRunState.initializing), 3);
    expect(getAgentStatusPriority(status: AgentRunState.idle), 4);
  });
}
