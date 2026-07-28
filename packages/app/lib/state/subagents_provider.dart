import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agents_provider.dart';
import 'provider_subagents_provider.dart';

sealed class SubagentRow {
  const SubagentRow();

  String get id;
  String get provider;
  String? get title;
  int get createdAtMs;
  bool get running;
  bool get requiresAttention;
}

final class PaseoSubagentRow extends SubagentRow {
  const PaseoSubagentRow(this.agent);

  final AgentSummary agent;

  @override
  String get id => agent.agentId;
  @override
  String get provider => agent.provider;
  @override
  String get title => agent.title;
  @override
  int get createdAtMs => agent.createdAtMs;
  @override
  bool get running => agent.runState == AgentRunState.running;
  @override
  bool get requiresAttention =>
      agent.requiresAttention ||
      agent.runState == AgentRunState.awaitingPermission ||
      agent.runState == AgentRunState.error;
}

final class ProviderSubagentRow extends SubagentRow {
  const ProviderSubagentRow(this.parentAgentId, this.subagent);

  final String parentAgentId;
  final ProviderSubagentDescriptor subagent;

  @override
  String get id => subagent.id;
  @override
  String get provider => subagent.provider;
  @override
  String? get title => subagent.title ?? subagent.description;
  @override
  int get createdAtMs =>
      DateTime.tryParse(subagent.createdAt)?.millisecondsSinceEpoch ?? 0;
  @override
  bool get running => subagent.status == ProviderSubagentStatus.running;
  @override
  bool get requiresAttention =>
      subagent.status == ProviderSubagentStatus.failed;
}

String? resolveSubagentLabel(String? title) {
  final normalized = title?.trim();
  if (normalized == null ||
      normalized.isEmpty ||
      normalized.toLowerCase() == 'new agent') {
    return null;
  }
  return normalized;
}

final class SubagentConfirmation {
  const SubagentConfirmation({
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.destructive = false,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final bool destructive;
}

enum CloseAgentTabPolicy { archiveOnClose, layoutOnly }

CloseAgentTabPolicy resolveCloseAgentTabPolicy(AgentSummary? agent) =>
    agent?.parentAgentId?.isNotEmpty == true
    ? CloseAgentTabPolicy.layoutOnly
    : CloseAgentTabPolicy.archiveOnClose;

String? _normalizeWorkspaceOpaqueId(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

bool isWorkspaceRootAgent(AgentSummary agent, AgentSummary? parentAgent) {
  if (agent.parentAgentId == null || agent.parentAgentId!.isEmpty) return true;
  final workspaceId = _normalizeWorkspaceOpaqueId(agent.workspaceId);
  final parentWorkspaceId = _normalizeWorkspaceOpaqueId(
    parentAgent?.workspaceId,
  );
  return workspaceId != null &&
      parentWorkspaceId != null &&
      workspaceId != parentWorkspaceId;
}

SubagentConfirmation resolveArchiveSubagentConfirmation(
  PaseoSubagentRow child,
) {
  final label = resolveSubagentLabel(child.title) ?? 'this subagent';
  return child.running
      ? SubagentConfirmation(
          title: 'Archive running subagent?',
          message:
              '$label is still running. Archiving it will stop the '
              'subagent and remove it from the track.',
          confirmLabel: 'Archive',
          destructive: true,
        )
      : SubagentConfirmation(
          title: 'Archive subagent?',
          message:
              'Remove $label from the track. The subagent will be archived.',
          confirmLabel: 'Archive',
          destructive: true,
        );
}

SubagentConfirmation resolveDetachSubagentConfirmation(PaseoSubagentRow child) {
  final label = resolveSubagentLabel(child.title) ?? 'This subagent';
  return SubagentConfirmation(
    title: 'Detach subagent?',
    message: '$label will leave this track and continue as a standalone agent.',
    confirmLabel: 'Detach',
  );
}

String formatSubagentsHeader(List<SubagentRow> rows) {
  final running = rows.where((row) => row.running).length;
  final label = '${rows.length} ${rows.length == 1 ? 'subagent' : 'subagents'}';
  return running == 0 ? label : '$label · $running running';
}

int countFinishedProviderSubagents(List<SubagentRow> rows) =>
    rows.whereType<ProviderSubagentRow>().where((row) => !row.running).length;

List<SubagentRow> selectSubagentsForParent({
  required String parentAgentId,
  required Iterable<AgentSummary> agents,
  required ProviderSubagentsState providerSubagents,
}) =>
    <SubagentRow>[
      for (final agent in agents)
        if (agent.parentAgentId == parentAgentId && agent.archivedAt == null)
          PaseoSubagentRow(agent),
      for (final descriptor in providerSubagents.visibleDescriptors)
        ProviderSubagentRow(parentAgentId, descriptor),
    ]..sort((left, right) {
      final byCreated = left.createdAtMs.compareTo(right.createdAtMs);
      return byCreated != 0 ? byCreated : left.id.compareTo(right.id);
    });

final subagentsForParentProvider = Provider.family<List<SubagentRow>, String>((
  ref,
  parentAgentId,
) {
  return selectSubagentsForParent(
    parentAgentId: parentAgentId,
    agents: ref.watch(agentsProvider).values,
    providerSubagents: ref.watch(providerSubagentsProvider(parentAgentId)),
  );
});
