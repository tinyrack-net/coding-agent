import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/sidebar/sidebar_agent_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prioritizes pending permissions as needs input', () {
    expect(
      deriveSidebarStateBucket(
        status: AgentRunState.idle,
        pendingPermissionCount: 1,
      ),
      WorkspaceStateBucket.needsInput,
    );
  });

  test('keeps legacy permission attention in needs input', () {
    expect(
      deriveSidebarStateBucket(
        status: AgentRunState.idle,
        requiresAttention: true,
        attentionReason: AgentAttentionReason.permission,
      ),
      WorkspaceStateBucket.needsInput,
    );
  });

  test('treats unread finished agents as attention', () {
    expect(
      deriveSidebarStateBucket(
        status: AgentRunState.idle,
        requiresAttention: true,
        attentionReason: AgentAttentionReason.finished,
      ),
      WorkspaceStateBucket.attention,
    );
  });

  test('does not count initializing agents as active', () {
    expect(isSidebarActiveAgent(status: AgentRunState.initializing), isFalse);
  });
}
