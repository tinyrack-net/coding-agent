import 'package:agent_protocol/agent_protocol.dart';

enum AgentAttentionClearTrigger {
  focusEntry,
  inputFocus,
  promptSend,
  agentBlur,
}

bool shouldClearAgentAttention({
  required String? agentId,
  required bool isConnected,
  required bool requiresAttention,
  AgentAttentionReason? attentionReason,
  AgentAttentionClearTrigger? trigger,
  bool hasDeferredFocusEntryClear = false,
}) {
  if (agentId == null || agentId.trim().isEmpty) return false;
  if (!isConnected || !requiresAttention) return false;
  if (attentionReason == AgentAttentionReason.permission) return false;
  if (trigger == AgentAttentionClearTrigger.focusEntry &&
      hasDeferredFocusEntryClear) {
    return false;
  }
  return true;
}

String? pickAttentionAgent(Iterable<AgentSummary> agents) {
  AgentSummary? selected;
  int? selectedPriority;
  DateTime? selectedTimestamp;
  for (final agent in agents) {
    if (!agent.requiresAttention || agent.parentAgentId != null) continue;
    final priority = switch (agent.attentionReason) {
      AgentAttentionReason.permission => 0,
      AgentAttentionReason.error => 1,
      AgentAttentionReason.finished => 2,
      null => null,
    };
    if (priority == null) continue;
    final timestamp = DateTime.tryParse(agent.attentionTimestamp ?? '');
    if (selected == null ||
        priority < selectedPriority! ||
        (priority == selectedPriority &&
            _isEarlier(timestamp, selectedTimestamp))) {
      selected = agent;
      selectedPriority = priority;
      selectedTimestamp = timestamp;
    }
  }
  return selected?.agentId;
}

bool _isEarlier(DateTime? candidate, DateTime? current) {
  if (candidate == null) return false;
  if (current == null) return true;
  return candidate.isBefore(current);
}
