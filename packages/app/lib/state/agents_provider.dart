import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../core/desktop/desktop_shell.dart';
import '../core/desktop/notification_service.dart';
import '../core/host_routes.dart';
import 'agent_history_provider.dart';
import 'daemon_providers.dart';
import 'host_registry_provider.dart';

/// The worktree/session-group an agent belongs to: a worktree agent's `cwd`
/// *is* the worktree path; a local-isolation agent's `cwd` *is* the project
/// path. Distinct from `resolveAgentProjectPath` (sidebar_grouping_provider.dart),
/// which resolves the *owning* repo/project for sidebar sectioning — a
/// worktree agent's `projectPath` is the main checkout, not the worktree
/// itself.
String resolveWorktreeKey(AgentSummary agent) => agent.cwd;

class AgentDirectoryReplicaStoreNotifier
    extends Notifier<Map<String, Map<String, AgentSummary>>> {
  @override
  Map<String, Map<String, AgentSummary>> build() => const {};

  Map<String, AgentSummary> read(String serverId) =>
      state[serverId] ?? const {};

  void write(String serverId, Map<String, AgentSummary> agents) {
    final next = Map<String, Map<String, AgentSummary>>.of(state);
    next[serverId] = Map<String, AgentSummary>.unmodifiable(agents);
    state = Map<String, Map<String, AgentSummary>>.unmodifiable(next);
  }

  void clearServer(String serverId) {
    if (!state.containsKey(serverId)) return;
    final next = Map<String, Map<String, AgentSummary>>.of(state)
      ..remove(serverId);
    state = Map.unmodifiable(next);
  }
}

final agentDirectoryReplicaStoreProvider =
    NotifierProvider<
      AgentDirectoryReplicaStoreNotifier,
      Map<String, Map<String, AgentSummary>>
    >(AgentDirectoryReplicaStoreNotifier.new);

final agentDirectoryReplicaLifecycleProvider = Provider<void>((ref) {
  ref.listen(hostRegistryProvider, (previous, next) {
    if (previous == null) return;
    final currentServerIds = {for (final host in next.hosts) host.serverId};
    final store = ref.read(agentDirectoryReplicaStoreProvider.notifier);
    for (final host in previous.hosts) {
      if (!currentServerIds.contains(host.serverId)) {
        store.clearServer(host.serverId);
      }
    }
  });
});

/// Live map of agentId -> [AgentSummary], fed by `agent.list` on (re)connect
/// and kept fresh by `agent.state` broadcast events.
class AgentsNotifier extends Notifier<Map<String, AgentSummary>> {
  String _serverId = 'legacy';
  int _generation = 0;
  int _refreshId = 0;
  List<DirectoryUpdateEvent>? _refreshDeltas;
  String? _subscriptionId;

  @override
  Map<String, AgentSummary> build() {
    _generation++;
    _subscriptionId = null;
    _serverId = ref.watch(activeHostProvider)?.serverId ?? 'legacy';
    final client = ref.watch(daemonClientProvider);
    final eventSub = client.events.listen(_onEvent);
    final directorySub = client.directoryUpdateEvents.listen(
      _onDirectoryUpdate,
    );
    final connSub = client.connectionState.listen((s) {
      if (s == DaemonConnectionState.connected) refresh();
    });
    ref.onDispose(() {
      eventSub.cancel();
      directorySub.cancel();
      connSub.cancel();
    });
    if (client.currentState == DaemonConnectionState.connected) {
      Future.microtask(refresh);
    }
    return ref
        .read(agentDirectoryReplicaStoreProvider.notifier)
        .read(_serverId);
  }

  void _onDirectoryUpdate(DirectoryUpdateEvent event) {
    if (event is! AgentUpsertDirectoryEvent &&
        event is! AgentRemoveDirectoryEvent &&
        event is! AgentDeletedDirectoryEvent &&
        event is! AgentArchivedDirectoryEvent) {
      return;
    }
    final deltas = _refreshDeltas;
    if (deltas != null) {
      deltas.add(event);
      return;
    }
    _applyDirectoryUpdate(event);
  }

  void _applyDirectoryUpdate(DirectoryUpdateEvent event) {
    switch (event) {
      case AgentUpsertDirectoryEvent(:final agent):
        final previous = state[agent.agentId]?.runState;
        if (agent.archivedAt == null) {
          upsert(agent);
        } else {
          remove(agent.agentId);
        }
        _maybeNotify(previous, agent);
      case AgentRemoveDirectoryEvent(:final agentId) ||
          AgentDeletedDirectoryEvent(:final agentId) ||
          AgentArchivedDirectoryEvent(:final agentId):
        remove(agentId);
      case WorkspaceDirectoryEvent() || ProjectDirectoryEvent():
        break;
    }
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
    if (payload.agent.archivedAt == null) {
      upsert(payload.agent);
    } else {
      remove(payload.agent.agentId);
    }
    _maybeNotify(previous, payload.agent);
  }

  /// Fires an OS notification on the transitions a user actually cares
  /// about — first sighting an agent isn't a transition, and while the
  /// window is focused the in-chat UI already makes this obvious.
  void _maybeNotify(AgentRunState? previous, AgentSummary agent) {
    if (previous == null) return;
    if (windowFocusedNotifier.value) return;
    final workspaceId = agent.workspaceId?.trim();
    if (workspaceId == null || workspaceId.isEmpty) return;
    final title = agent.title.isEmpty ? agent.agentId : agent.title;
    final notifications = ref.read(notificationServiceProvider);
    final openRoute = ref.read(notificationRouteOpenerProvider);
    final route = buildHostWorkspaceOpenRoute(
      _serverId,
      workspaceId,
      'agent:${agent.agentId}',
    );
    void onClick() {
      openRoute(route);
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
    // A directory snapshot may have started before this client-created
    // agent existed. Keep the local mutation in the same ordered delta log
    // as live directory events so that stale snapshot cannot erase the
    // create result when it eventually resolves.
    _refreshDeltas?.add(AgentUpsertDirectoryEvent(agent: agent));
    _publish({...state, agent.agentId: agent});
  }

  void remove(String agentId) {
    if (!state.containsKey(agentId)) return;
    // Preserve local archive/removal actions across an older in-flight
    // directory snapshot for the same reason as [upsert].
    _refreshDeltas?.add(AgentRemoveDirectoryEvent(agentId));
    final next = {...state}..remove(agentId);
    _publish(next);
  }

  Future<void> refresh() async {
    final generation = _generation;
    final refreshId = ++_refreshId;
    final buffered = <DirectoryUpdateEvent>[];
    _refreshDeltas = buffered;
    final client = ref.read(daemonClientProvider);
    try {
      final agents = <AgentSummary>[];
      String? cursor;
      var subscribe = true;
      do {
        final page = await client.fetchAgents(
          sort: const [
            AgentDirectorySort(
              key: AgentDirectorySortKey.updatedAt,
              direction: AgentDirectorySortDirection.desc,
            ),
          ],
          cursor: cursor,
          subscribe: subscribe,
          subscriptionId: subscribe ? _subscriptionId : null,
        );
        if (!ref.mounted ||
            generation != _generation ||
            refreshId != _refreshId) {
          return;
        }
        agents.addAll(page.entries.map((entry) => entry.agent));
        _subscriptionId ??= page.subscriptionId;
        if (page.pageInfo.hasMore && page.pageInfo.nextCursor == null) {
          throw const FormatException(
            'Agent directory page hasMore without nextCursor',
          );
        }
        cursor = page.pageInfo.hasMore ? page.pageInfo.nextCursor : null;
        subscribe = false;
      } while (cursor != null);
      if (!ref.mounted ||
          generation != _generation ||
          refreshId != _refreshId) {
        return;
      }
      if (_serverId != 'legacy' &&
          !ref
              .read(hostRegistryProvider)
              .hosts
              .any((host) => host.serverId == _serverId)) {
        _refreshDeltas = null;
        return;
      }
      final next = {for (final agent in agents) agent.agentId: agent};
      for (final event in buffered) {
        final previous = event is AgentUpsertDirectoryEvent
            ? next[event.agent.agentId]?.runState
            : null;
        _applyDirectoryUpdateTo(next, event);
        if (event is AgentUpsertDirectoryEvent) {
          _maybeNotify(previous, event.agent);
        }
      }
      _refreshDeltas = null;
      _publish(next);
    } catch (_) {
      if (refreshId == _refreshId) {
        _refreshDeltas = null;
        for (final event in buffered) {
          _applyDirectoryUpdate(event);
        }
      }
      // Not connected or request failed; a reconnect will retry.
    }
  }

  void _applyDirectoryUpdateTo(
    Map<String, AgentSummary> agents,
    DirectoryUpdateEvent event,
  ) {
    switch (event) {
      case AgentUpsertDirectoryEvent(:final agent):
        if (agent.archivedAt == null) {
          agents[agent.agentId] = agent;
        } else {
          agents.remove(agent.agentId);
        }
      case AgentRemoveDirectoryEvent(:final agentId) ||
          AgentDeletedDirectoryEvent(:final agentId) ||
          AgentArchivedDirectoryEvent(:final agentId):
        agents.remove(agentId);
      case WorkspaceDirectoryEvent() || ProjectDirectoryEvent():
        break;
    }
  }

  void _publish(Map<String, AgentSummary> agents) {
    final next = Map<String, AgentSummary>.unmodifiable(agents);
    state = next;
    ref
        .read(agentDirectoryReplicaStoreProvider.notifier)
        .write(_serverId, next);
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
final agentSummaryProvider = Provider.family<AgentSummary?, String>((
  ref,
  agentId,
) {
  final active = ref.watch(agentsProvider)[agentId];
  if (active != null) return active;
  final serverId = ref.watch(activeHostProvider)?.serverId;
  final history = ref.watch(agentHistoryProvider);
  return switch (history) {
    AsyncData(:final value) =>
      value.entries
          .where(
            (entry) =>
                entry.serverId == serverId &&
                entry.agent.agentId == agentId &&
                entry.agent.archivedAt != null,
          )
          .map((entry) => entry.agent)
          .firstOrNull,
    _ => null,
  };
});

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
    String? modeId,
    String? thinkingOptionId,
    Map<String, Object?> featureValues = const {},
    String? title,
    String? workspaceId,
    String? projectPath,
    String? branch,
    bool isWorktree = false,
    String? parentAgentId,
    String? initialPrompt,
    String? clientMessageId,
    List<AgentPromptImage> images = const [],
    List<AgentAttachment> attachments = const [],
  }) async {
    final res = await _client.request(MessageTypes.agentCreateRequest, {
      'cwd': cwd,
      'provider': provider,
      'model': model,
      'mode': mode.name,
      if (modeId != null && modeId.isNotEmpty) 'modeId': modeId,
      if (thinkingOptionId != null && thinkingOptionId.isNotEmpty)
        'thinkingOptionId': thinkingOptionId,
      if (featureValues.isNotEmpty) 'features': featureValues,
      if (title != null && title.isNotEmpty) 'title': title,
      'workspaceId': ?workspaceId,
      'projectPath': ?projectPath,
      'branch': ?branch,
      if (isWorktree) 'isWorktree': isWorktree,
      'parentAgentId': ?parentAgentId,
      if (initialPrompt != null && initialPrompt.isNotEmpty)
        'initialPrompt': initialPrompt,
      if (clientMessageId != null && clientMessageId.isNotEmpty)
        'clientMessageId': clientMessageId,
      if (images.isNotEmpty)
        'images': images.map((image) => image.toJson()).toList(growable: false),
      if (attachments.isNotEmpty)
        'attachments': attachments
            .map((attachment) => attachment.toJson())
            .toList(growable: false),
    });
    final agent = AgentSummary.fromJson(
      res['agent'] as Map<String, Object?>? ?? const {},
    );
    _ref.read(agentsProvider.notifier).upsert(agent);
    return agent;
  }

  Future<void> prompt(
    String agentId,
    String text, {
    List<AgentPromptImage> images = const [],
    List<AgentAttachment> attachments = const [],
    String? clientMessageId,
  }) => _client.request(MessageTypes.agentPromptRequest, {
    'agentId': agentId,
    'text': text,
    'clientMessageId': ?clientMessageId,
    if (images.isNotEmpty)
      'images': images.map((image) => image.toJson()).toList(growable: false),
    if (attachments.isNotEmpty)
      'attachments': attachments
          .map((attachment) => attachment.toJson())
          .toList(growable: false),
  });

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

  Future<AgentSummary> detach(String agentId) async {
    final res = await _client.request(MessageTypes.agentDetachRequest, {
      'agentId': agentId,
    });
    final agent = AgentSummary.fromJson(
      res['agent'] as Map<String, Object?>? ?? const {},
    );
    _ref.read(agentsProvider.notifier).upsert(agent);
    return agent;
  }

  Future<AgentSummary> clearAttention(String agentId) async {
    final res = await _client.request(MessageTypes.agentAttentionClearRequest, {
      'agentId': agentId,
    });
    final agent = AgentSummary.fromJson(
      res['agent'] as Map<String, Object?>? ?? const {},
    );
    _ref.read(agentsProvider.notifier).upsert(agent);
    return agent;
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
