import 'package:agent_protocol/agent_protocol.dart';

const presenceThreshold = Duration(minutes: 3);

final class ClientPresenceState {
  const ClientPresenceState({
    required this.appVisible,
    required this.lastActivityAtMs,
    required this.focusedAgentId,
    required this.focusedTerminalId,
  });

  final bool appVisible;
  final int? lastActivityAtMs;
  final String? focusedAgentId;
  final String? focusedTerminalId;
}

enum AttentionFocusKind { agent, terminal }

final class AttentionFocusTarget {
  const AttentionFocusTarget.agent(String id)
    : kind = AttentionFocusKind.agent,
      id = id;

  const AttentionFocusTarget.terminal(String id)
    : kind = AttentionFocusKind.terminal,
      id = id;

  final AttentionFocusKind kind;
  final String id;
}

final class NotificationPlan {
  const NotificationPlan({
    required this.inAppRecipientIndex,
    required this.shouldPush,
  });

  final int? inAppRecipientIndex;
  final bool shouldPush;
}

NotificationPlan computeNotificationPlan({
  required List<ClientPresenceState> allStates,
  required AttentionFocusTarget? focusTarget,
  required bool pushEligible,
  required int nowMs,
}) {
  int? mostRecentPresentIndex;
  var mostRecentPresentAtMs = -double.infinity;

  for (var clientIndex = 0; clientIndex < allStates.length; clientIndex++) {
    final state = allStates[clientIndex];
    final activityAt = state.lastActivityAtMs;
    final clampedActivityAtMs = activityAt == null
        ? null
        : activityAt.clamp(0, nowMs);
    final isPresent =
        clampedActivityAtMs != null &&
        nowMs - clampedActivityAtMs <= presenceThreshold.inMilliseconds;
    if (!isPresent) continue;

    if (state.appVisible && _isFocusedOnTarget(state, focusTarget)) {
      return const NotificationPlan(
        inAppRecipientIndex: null,
        shouldPush: false,
      );
    }

    if (clampedActivityAtMs > mostRecentPresentAtMs) {
      mostRecentPresentIndex = clientIndex;
      mostRecentPresentAtMs = clampedActivityAtMs.toDouble();
    }
  }

  if (mostRecentPresentIndex != null) {
    return NotificationPlan(
      inAppRecipientIndex: mostRecentPresentIndex,
      shouldPush: false,
    );
  }
  return NotificationPlan(inAppRecipientIndex: null, shouldPush: pushEligible);
}

bool isPushEligibleAttentionReason(AgentAttentionReason reason) =>
    reason != AgentAttentionReason.error;

bool _isFocusedOnTarget(
  ClientPresenceState state,
  AttentionFocusTarget? target,
) {
  if (target == null) return false;
  return switch (target.kind) {
    AttentionFocusKind.agent => state.focusedAgentId == target.id,
    AttentionFocusKind.terminal => state.focusedTerminalId == target.id,
  };
}
