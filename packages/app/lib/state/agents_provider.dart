import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';
import 'terminal_providers.dart';

/// Live map of agentId -> [AgentSummary], fed by `agent.list` on (re)connect
/// and kept fresh by `agent.state` broadcast events.
class AgentsNotifier extends Notifier<Map<String, AgentSummary>> {
  @override
  Map<String, AgentSummary> build() {
    final client = ref.watch(daemonClientProvider);
    final eventSub = client.events.listen(_onEvent);
    final connSub = client.connectionState.listen((s) {
      if (s == DaemonConnectionState.connected) refresh();
    });
    ref.onDispose(() {
      eventSub.cancel();
      connSub.cancel();
    });
    if (client.currentState == DaemonConnectionState.connected) {
      Future.microtask(refresh);
    }
    return const {};
  }

  void _onEvent(RpcEvent event) {
    if (event.type != MessageTypes.agentStateEvent) return;
    final AgentStatePayload payload;
    try {
      payload = AgentStatePayload.fromJson(event.payload);
    } catch (_) {
      return;
    }
    upsert(payload.agent);
  }

  void upsert(AgentSummary agent) {
    state = {...state, agent.agentId: agent};
  }

  void remove(String agentId) {
    if (!state.containsKey(agentId)) return;
    final next = {...state}..remove(agentId);
    state = next;
  }

  Future<void> refresh() async {
    final client = ref.read(daemonClientProvider);
    try {
      final res = await client.request(MessageTypes.agentListRequest, const {});
      final agents = ((res['agents'] as List?) ?? const [])
          .cast<Map<String, Object?>>()
          .map(AgentSummary.fromJson);
      state = {for (final agent in agents) agent.agentId: agent};
    } catch (_) {
      // Not connected or request failed; a reconnect will retry.
    }
  }
}

final agentsProvider =
    NotifierProvider<AgentsNotifier, Map<String, AgentSummary>>(
  AgentsNotifier.new,
);

/// Agents sorted most-recent first for the sidebar.
final sortedAgentsProvider = Provider<List<AgentSummary>>((ref) {
  final agents = ref.watch(agentsProvider).values.toList()
    ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
  return agents;
});

/// Summary (incl. runState) for a single agent.
final agentSummaryProvider = Provider.family<AgentSummary?, String>(
  (ref, agentId) => ref.watch(agentsProvider)[agentId],
);

/// Currently selected agent in the shell.
class SelectedAgentNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? agentId) => state = agentId;
}

final selectedAgentProvider = NotifierProvider<SelectedAgentNotifier, String?>(
  SelectedAgentNotifier.new,
);

/// Imperative daemon actions used by the UI.
class AgentActions {
  AgentActions(this._ref);

  final Ref _ref;

  DaemonClient get _client => _ref.read(daemonClientProvider);

  Future<AgentSummary> create({
    required String cwd,
    required String provider,
    required String model,
    required AgentMode mode,
    String? title,
    String? projectPath,
    String? branch,
    bool isWorktree = false,
  }) async {
    final res = await _client.request(MessageTypes.agentCreateRequest, {
      'cwd': cwd,
      'provider': provider,
      'model': model,
      'mode': mode.name,
      if (title != null && title.isNotEmpty) 'title': title,
      if (projectPath != null) 'projectPath': projectPath,
      if (branch != null) 'branch': branch,
      if (isWorktree) 'isWorktree': isWorktree,
    });
    final agent =
        AgentSummary.fromJson(res['agent'] as Map<String, Object?>? ?? const {});
    _ref.read(agentsProvider.notifier).upsert(agent);
    return agent;
  }

  Future<void> prompt(String agentId, String text) =>
      _client.request(MessageTypes.agentPromptRequest, {
        'agentId': agentId,
        'text': text,
      });

  Future<void> interrupt(String agentId) =>
      _client.request(MessageTypes.agentInterruptRequest, {'agentId': agentId});

  Future<void> archive(String agentId) async {
    await _client
        .request(MessageTypes.agentArchiveRequest, {'agentId': agentId});
    // Tear down the agent's embedded terminal (if one was ever opened).
    if (_ref.exists(terminalSessionProvider(agentId))) {
      await _ref.read(terminalSessionProvider(agentId).notifier).shutdown();
      _ref.invalidate(terminalSessionProvider(agentId));
    }
    _ref.read(agentsProvider.notifier).remove(agentId);
  }

  Future<void> respondPermission(String permissionId, String decision) =>
      _client.request(MessageTypes.permissionRespondRequest, {
        'permissionId': permissionId,
        'decision': decision,
      });

  /// Wipe every agent's conversation state on the daemon (timeline,
  /// provider session id, in-memory session). Used by the "Reset all data"
  /// settings action. Returns the number of agents the daemon reported
  /// as affected.
  Future<int> clearConversations() async {
    final res = await _client.request(
      MessageTypes.agentConversationClearRequest,
      const {},
    );
    final cleared = AgentConversationClearResponse.fromJson(res).cleared;
    // The daemon's session-id-bump + timeline-clear may take a moment to
    // round-trip through the broadcast state event; the most reliable local
    // signal is to re-list, so the sidebar shows the wiped summaries.
    await _ref.read(agentsProvider.notifier).refresh();
    return cleared;
  }
}

final agentActionsProvider = Provider<AgentActions>(AgentActions.new);
