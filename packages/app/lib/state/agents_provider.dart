import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../core/daemon_client.dart';
import '../core/desktop/desktop_shell.dart';
import '../core/desktop/notification_service.dart';
import 'daemon_providers.dart';
import 'worktree_tabs_provider.dart';

/// The worktree/session-group an agent belongs to: a worktree agent's `cwd`
/// *is* the worktree path; a local-isolation agent's `cwd` *is* the project
/// path. Distinct from `resolveAgentProjectPath` (sidebar_grouping_provider.dart),
/// which resolves the *owning* repo/project for sidebar sectioning — a
/// worktree agent's `projectPath` is the main checkout, not the worktree
/// itself.
String resolveWorktreeKey(AgentSummary agent) => agent.cwd;

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
    final previous = state[payload.agent.agentId]?.runState;
    upsert(payload.agent);
    _maybeNotify(previous, payload.agent);
  }

  /// Fires an OS notification on the transitions a user actually cares
  /// about — first sighting an agent isn't a transition, and while the
  /// window is focused the in-chat UI already makes this obvious.
  void _maybeNotify(AgentRunState? previous, AgentSummary agent) {
    if (previous == null) return;
    if (windowFocusedNotifier.value) return;
    final title = agent.title.isEmpty ? agent.agentId : agent.title;
    final notifications = ref.read(notificationServiceProvider);
    void onClick() {
      windowManager.show();
      windowManager.focus();
      final worktreePath = resolveWorktreeKey(agent);
      ref
          .read(worktreeTabsProvider(worktreePath).notifier)
          .focusAgent(agent.agentId);
      ref.read(selectedWorktreeProvider.notifier).select(worktreePath);
    }

    if (previous != AgentRunState.awaitingPermission &&
        agent.runState == AgentRunState.awaitingPermission) {
      notifications.notify(
        title: title,
        body: 'Needs your input',
        onClick: onClick,
      );
    } else if (previous == AgentRunState.running &&
        agent.runState == AgentRunState.idle) {
      notifications.notify(title: title, body: 'Finished', onClick: onClick);
    } else if (previous == AgentRunState.running &&
        agent.runState == AgentRunState.error) {
      notifications.notify(
        title: title,
        body: 'Hit an error',
        onClick: onClick,
      );
    }
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
      'projectPath': ?projectPath,
      'branch': ?branch,
      if (isWorktree) 'isWorktree': isWorktree,
    });
    final agent = AgentSummary.fromJson(
      res['agent'] as Map<String, Object?>? ?? const {},
    );
    _ref.read(agentsProvider.notifier).upsert(agent);
    return agent;
  }

  Future<void> prompt(String agentId, String text) => _client.request(
    MessageTypes.agentPromptRequest,
    {'agentId': agentId, 'text': text},
  );

  Future<void> interrupt(String agentId) =>
      _client.request(MessageTypes.agentInterruptRequest, {'agentId': agentId});

  Future<void> archive(String agentId) async {
    await _client.request(MessageTypes.agentArchiveRequest, {
      'agentId': agentId,
    });
    // Terminal tabs are worktree-scoped, not agent-scoped (several agents
    // can share a worktree), so archiving one agent must never tear down
    // terminal sessions here — that's worktree tab-close's job.
    _ref.read(agentsProvider.notifier).remove(agentId);
  }

  Future<AgentSummary> rename(String agentId, String title) async {
    final res = await _client.request(MessageTypes.agentRenameRequest, {
      'agentId': agentId,
      'title': title,
    });
    final agent = AgentSummary.fromJson(
      res['agent'] as Map<String, Object?>? ?? const {},
    );
    _ref.read(agentsProvider.notifier).upsert(agent);
    return agent;
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
