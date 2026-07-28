import 'package:agent_daemon/src/server/agent_attention_policy.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  final nowMs = DateTime.parse(
    '2026-04-19T12:00:00.000Z',
  ).millisecondsSinceEpoch;
  final staleAtMs = nowMs - presenceThreshold.inMilliseconds - 1;
  final presentAtMs = nowMs - presenceThreshold.inMilliseconds + 1;

  ClientPresenceState state({
    bool appVisible = true,
    int? lastActivityAtMs,
    String? focusedAgentId,
    String? focusedTerminalId,
  }) => ClientPresenceState(
    appVisible: appVisible,
    lastActivityAtMs: lastActivityAtMs,
    focusedAgentId: focusedAgentId,
    focusedTerminalId: focusedTerminalId,
  );

  NotificationPlan plan(
    List<ClientPresenceState> states, {
    AttentionFocusTarget? target = const AttentionFocusTarget.agent('agent-1'),
    bool pushEligible = true,
  }) => computeNotificationPlan(
    allStates: states,
    focusTarget: target,
    pushEligible: pushEligible,
    nowMs: nowMs,
  );

  void expectPlan(
    NotificationPlan actual, {
    required int? recipient,
    required bool push,
  }) {
    expect(actual.inAppRecipientIndex, recipient);
    expect(actual.shouldPush, push);
  }

  test('stale focus does not suppress and present visible focus does', () {
    expectPlan(
      plan([state(lastActivityAtMs: staleAtMs, focusedAgentId: 'agent-1')]),
      recipient: null,
      push: true,
    );
    expectPlan(
      plan([
        state(lastActivityAtMs: staleAtMs, focusedAgentId: 'agent-1'),
        state(lastActivityAtMs: presentAtMs, focusedAgentId: 'agent-1'),
      ]),
      recipient: null,
      push: false,
    );
  });

  test('background focus remains an eligible in-app recipient', () {
    expectPlan(
      plan([
        state(
          appVisible: false,
          lastActivityAtMs: presentAtMs,
          focusedAgentId: 'agent-1',
        ),
      ]),
      recipient: 0,
      push: false,
    );
  });

  test('most recent present client wins and ties keep lower index', () {
    expectPlan(
      plan([
        state(lastActivityAtMs: nowMs - 10000),
        state(lastActivityAtMs: nowMs - 1000),
        state(lastActivityAtMs: staleAtMs),
      ]),
      recipient: 1,
      push: false,
    );
    expectPlan(
      plan([
        state(lastActivityAtMs: nowMs - 1000),
        state(lastActivityAtMs: nowMs - 1000),
      ]),
      recipient: 0,
      push: false,
    );
  });

  test('future activity is clamped and a missing heartbeat is absent', () {
    expectPlan(
      plan([
        state(lastActivityAtMs: nowMs - 1),
        state(lastActivityAtMs: nowMs + 600000),
      ]),
      recipient: 1,
      push: false,
    );
    expectPlan(plan([state()]), recipient: null, push: true);
  });

  test('terminal focus suppresses only with a matching target', () {
    final terminal = state(
      lastActivityAtMs: nowMs - 500,
      focusedAgentId: 'terminal-1',
      focusedTerminalId: 'terminal-1',
    );
    expectPlan(
      plan([
        terminal,
      ], target: const AttentionFocusTarget.terminal('terminal-1')),
      recipient: null,
      push: false,
    );
    expectPlan(plan([terminal], target: null), recipient: 0, push: false);
  });

  test('push eligibility excludes only error attention', () {
    expect(
      isPushEligibleAttentionReason(AgentAttentionReason.finished),
      isTrue,
    );
    expect(
      isPushEligibleAttentionReason(AgentAttentionReason.permission),
      isTrue,
    );
    expect(isPushEligibleAttentionReason(AgentAttentionReason.error), isFalse);
  });
}
