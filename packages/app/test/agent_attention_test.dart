import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/state/agent_attention.dart';
import 'package:flutter_test/flutter_test.dart';

AgentSummary _agent({
  required String id,
  AgentAttentionReason? reason,
  String? timestamp,
  bool requiresAttention = true,
  String? parentAgentId,
}) => AgentSummary(
  agentId: id,
  title: id,
  cwd: '/work',
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 0,
  parentAgentId: parentAgentId,
  requiresAttention: requiresAttention,
  attentionReason: reason,
  attentionTimestamp: timestamp,
);

void main() {
  test('clear policy matches focus, connectivity, and permission rules', () {
    expect(
      shouldClearAgentAttention(
        agentId: 'agent',
        isConnected: true,
        requiresAttention: true,
        attentionReason: AgentAttentionReason.finished,
        trigger: AgentAttentionClearTrigger.focusEntry,
      ),
      isTrue,
    );
    expect(
      shouldClearAgentAttention(
        agentId: 'agent',
        isConnected: true,
        requiresAttention: true,
        attentionReason: AgentAttentionReason.finished,
        trigger: AgentAttentionClearTrigger.focusEntry,
        hasDeferredFocusEntryClear: true,
      ),
      isFalse,
    );
    expect(
      shouldClearAgentAttention(
        agentId: 'agent',
        isConnected: true,
        requiresAttention: true,
        attentionReason: AgentAttentionReason.permission,
        trigger: AgentAttentionClearTrigger.inputFocus,
      ),
      isFalse,
    );
    for (final input in [
      (agentId: '', connected: true, attention: true),
      (agentId: 'agent', connected: false, attention: true),
      (agentId: 'agent', connected: true, attention: false),
    ]) {
      expect(
        shouldClearAgentAttention(
          agentId: input.agentId,
          isConnected: input.connected,
          requiresAttention: input.attention,
        ),
        isFalse,
      );
    }
  });

  test('picks root attention by reason priority then oldest timestamp', () {
    final agents = [
      _agent(
        id: 'finished-new',
        reason: AgentAttentionReason.finished,
        timestamp: '2026-07-26T02:00:00.000Z',
      ),
      _agent(
        id: 'error-new',
        reason: AgentAttentionReason.error,
        timestamp: '2026-07-26T03:00:00.000Z',
      ),
      _agent(
        id: 'error-old',
        reason: AgentAttentionReason.error,
        timestamp: '2026-07-26T01:00:00.000Z',
      ),
      _agent(
        id: 'permission-child',
        reason: AgentAttentionReason.permission,
        parentAgentId: 'parent',
      ),
      _agent(id: 'unknown'),
      _agent(
        id: 'cleared',
        reason: AgentAttentionReason.permission,
        requiresAttention: false,
      ),
    ];
    expect(pickAttentionAgent(agents), 'error-old');
    expect(pickAttentionAgent([_agent(id: 'unknown')]), isNull);
  });
}
