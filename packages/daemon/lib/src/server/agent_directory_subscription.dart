import 'package:agent_protocol/agent_protocol.dart';

sealed class AgentDirectoryUpdate {
  const AgentDirectoryUpdate();

  String get agentId;
}

final class AgentDirectoryUpsert extends AgentDirectoryUpdate {
  const AgentDirectoryUpsert({required this.agent, required this.project});

  final AgentSummary agent;
  final Map<String, Object?> project;

  @override
  String get agentId => agent.agentId;
}

final class AgentDirectoryRemove extends AgentDirectoryUpdate {
  const AgentDirectoryRemove(this.agentId);

  @override
  final String agentId;
}

typedef AgentDirectoryUpdateEmitter =
    void Function(AgentDirectoryUpdate update);

/// Owns one connection's replaceable `fetch_agents` subscription.
///
/// Paseo starts the subscription before building the initial page. Updates that
/// race that snapshot are retained by agent id, then replayed after the response
/// has been sent. An upsert already represented by an equal-or-newer snapshot is
/// discarded during the replay.
final class AgentDirectorySubscription {
  AgentDirectorySubscription({
    required this.subscriptionId,
    required this.filter,
  });

  final String subscriptionId;
  final AgentDirectoryFilter? filter;

  bool _isBootstrapping = true;
  final Map<String, AgentDirectoryUpdate> _pendingUpdatesByAgentId = {};

  bool get isBootstrapping => _isBootstrapping;
  int get pendingUpdateCount => _pendingUpdatesByAgentId.length;

  void add(
    AgentDirectoryUpdate update, {
    required bool providerVisible,
    required AgentDirectoryUpdateEmitter emit,
  }) {
    if (update is AgentDirectoryUpsert && !providerVisible) return;
    if (_isBootstrapping) {
      _pendingUpdatesByAgentId[update.agentId] = update;
      return;
    }
    emit(update);
  }

  void flush({
    required Map<String, int> snapshotUpdatedAtByAgentId,
    required AgentDirectoryUpdateEmitter emit,
  }) {
    if (!_isBootstrapping) return;
    _isBootstrapping = false;
    final pending = _pendingUpdatesByAgentId.values.toList(growable: false);
    _pendingUpdatesByAgentId.clear();

    for (final update in pending) {
      if (update case AgentDirectoryUpsert(:final agent)) {
        final snapshotUpdatedAt = snapshotUpdatedAtByAgentId[agent.agentId];
        final updateUpdatedAt = DateTime.tryParse(
          agent.updatedAt ?? '',
        )?.millisecondsSinceEpoch;
        if (snapshotUpdatedAt != null &&
            updateUpdatedAt != null &&
            updateUpdatedAt <= snapshotUpdatedAt) {
          continue;
        }
      }
      emit(update);
    }
  }
}
