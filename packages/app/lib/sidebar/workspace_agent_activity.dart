import 'package:agent_protocol/agent_protocol.dart';

import '../state/subagents_provider.dart';

final class WorkspaceAgentActivity {
  const WorkspaceAgentActivity({
    required this.agentId,
    required this.status,
    required this.enteredAt,
  });

  final String agentId;
  final WorkspaceStateBucket status;
  final DateTime enteredAt;
}

Map<String, WorkspaceAgentActivity> buildWorkspaceAgentActivityIndex(
  Map<String, AgentSummary> agents, {
  Map<String, WorkspaceAgentActivity>? previous,
}) {
  final activityByWorkspaceId = <String, WorkspaceAgentActivity>{};
  final latestActivityAtByWorkspaceId = <String, DateTime>{};

  for (final agent in agents.values) {
    final workspaceId = _normalizeWorkspaceId(agent.workspaceId);
    final parent = agent.parentAgentId == null
        ? null
        : agents[agent.parentAgentId];
    if (agent.archivedAt != null ||
        workspaceId == null ||
        !isWorkspaceRootAgent(agent, parent)) {
      continue;
    }

    final enteredAt = _activityTimestamp(agent);
    final latest = latestActivityAtByWorkspaceId[workspaceId];
    if (latest != null && !enteredAt.isAfter(latest)) continue;
    latestActivityAtByWorkspaceId[workspaceId] = enteredAt;

    activityByWorkspaceId[workspaceId] = WorkspaceAgentActivity(
      agentId: agent.agentId,
      status: deriveAgentStateBucket(
        status: agent.runState,
        requiresAttention: agent.requiresAttention,
        attentionReason: agent.attentionReason,
      ),
      enteredAt: enteredAt,
    );
  }

  if (previous != null) {
    for (final entry in activityByWorkspaceId.entries.toList()) {
      final previousActivity = previous[entry.key];
      if (previousActivity?.agentId == entry.value.agentId &&
          previousActivity?.status == entry.value.status) {
        activityByWorkspaceId[entry.key] = previousActivity!;
      }
    }
    if (_indexesAreIdentical(previous, activityByWorkspaceId)) {
      return previous;
    }
  }
  return Map.unmodifiable(activityByWorkspaceId);
}

WorkspaceAgentActivity? latestWorkspaceActivityForAgents(
  Iterable<AgentSummary> agents,
  Map<String, WorkspaceAgentActivity> activityByWorkspaceId,
) {
  WorkspaceAgentActivity? latest;
  final seenWorkspaceIds = <String>{};
  for (final agent in agents) {
    final workspaceId = _normalizeWorkspaceId(agent.workspaceId);
    if (workspaceId == null || !seenWorkspaceIds.add(workspaceId)) continue;
    final activity = activityByWorkspaceId[workspaceId];
    if (activity == null) continue;
    if (latest == null || activity.enteredAt.isAfter(latest.enteredAt)) {
      latest = activity;
    }
  }
  return latest;
}

String? _normalizeWorkspaceId(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

DateTime _activityTimestamp(AgentSummary agent) =>
    DateTime.tryParse(agent.attentionTimestamp ?? '') ??
    DateTime.tryParse(agent.updatedAt ?? '') ??
    DateTime.fromMillisecondsSinceEpoch(agent.createdAtMs, isUtc: true);

bool _indexesAreIdentical(
  Map<String, WorkspaceAgentActivity> previous,
  Map<String, WorkspaceAgentActivity> next,
) {
  if (previous.length != next.length) return false;
  for (final entry in next.entries) {
    if (!identical(previous[entry.key], entry.value)) return false;
  }
  return true;
}

final class WorkspaceAgentActivityIndexController {
  Map<String, WorkspaceAgentActivity> _current = const {};

  Map<String, WorkspaceAgentActivity> update(Map<String, AgentSummary> agents) {
    _current = buildWorkspaceAgentActivityIndex(agents, previous: _current);
    return _current;
  }
}
