import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';
import 'host_registry_provider.dart';

final class AgentHistoryEntry {
  const AgentHistoryEntry({
    required this.serverId,
    required this.serverLabel,
    required this.agent,
    required this.project,
    this.pendingPermissionCount = 0,
  });

  final String serverId;
  final String serverLabel;
  final AgentSummary agent;
  final Map<String, Object?> project;
  final int pendingPermissionCount;

  DateTime get activityAt =>
      DateTime.tryParse(agent.updatedAt ?? '') ??
      DateTime.fromMillisecondsSinceEpoch(agent.createdAtMs);
}

final class AgentHistoryState {
  const AgentHistoryState({
    this.entries = const [],
    this.nextCursorByServerId = const {},
    this.loadingMore = false,
  });

  final List<AgentHistoryEntry> entries;
  final Map<String, String> nextCursorByServerId;
  final bool loadingMore;

  bool get hasMore => nextCursorByServerId.isNotEmpty;

  AgentHistoryState copyWith({
    List<AgentHistoryEntry>? entries,
    Map<String, String>? nextCursorByServerId,
    bool? loadingMore,
  }) => AgentHistoryState(
    entries: entries ?? this.entries,
    nextCursorByServerId: nextCursorByServerId ?? this.nextCursorByServerId,
    loadingMore: loadingMore ?? this.loadingMore,
  );
}

final class AgentHistoryHost {
  const AgentHistoryHost({
    required this.serverId,
    required this.serverLabel,
    required this.client,
  });

  final String serverId;
  final String serverLabel;
  final DaemonClient client;
}

final agentHistoryProvider =
    AsyncNotifierProvider<AgentHistoryNotifier, AgentHistoryState>(
      AgentHistoryNotifier.new,
    );

class AgentHistoryNotifier extends AsyncNotifier<AgentHistoryState> {
  List<AgentHistoryHost> _hosts = const [];

  @override
  Future<AgentHistoryState> build() async {
    final profiles = ref.watch(hostRegistryProvider).hosts;
    final clients = ref.watch(hostRuntimeClientsProvider);
    _hosts = [
      for (final profile in profiles)
        if (clients[profile.serverId] case final client?
            when _watchConnectedHost(ref, profile.serverId, client))
          AgentHistoryHost(
            serverId: profile.serverId,
            serverLabel: profile.label,
            client: client,
          ),
    ];
    if (_hosts.isEmpty) return const AgentHistoryState();
    return fetchAgentHistoryBatch(_hosts);
  }

  Future<void> reload() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => fetchAgentHistoryBatch(_hosts));
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || current.loadingMore || !current.hasMore) return;
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final page = await fetchAgentHistoryBatch(
        _hosts,
        cursorByServerId: current.nextCursorByServerId,
      );
      final merged = <String, AgentHistoryEntry>{
        for (final entry in current.entries)
          '${entry.serverId}:${entry.agent.agentId}': entry,
        for (final entry in page.entries)
          '${entry.serverId}:${entry.agent.agentId}': entry,
      }.values.toList()..sort(_compareHistoryEntries);
      state = AsyncData(
        AgentHistoryState(
          entries: List.unmodifiable(merged),
          nextCursorByServerId: page.nextCursorByServerId,
        ),
      );
    } on Object {
      // A failed incremental page must not replace the history that is
      // already visible. This mirrors Paseo's cached infinite-query behavior:
      // users can retry without losing the pages they successfully loaded.
      state = AsyncData(current.copyWith(loadingMore: false));
    }
  }
}

bool _watchConnectedHost(Ref ref, String serverId, DaemonClient client) {
  // Establish a reactive dependency so a later connect/disconnect rebuilds
  // history, while currentState supplies the synchronous initial snapshot.
  ref.watch(hostConnectionStateProvider(serverId));
  return client.currentState == DaemonConnectionState.connected;
}

Future<AgentHistoryState> fetchAgentHistoryBatch(
  List<AgentHistoryHost> hosts, {
  Map<String, String>? cursorByServerId,
}) async {
  final selectedHosts = cursorByServerId == null
      ? hosts
      : [
          for (final host in hosts)
            if (cursorByServerId.containsKey(host.serverId)) host,
        ];
  final results = await Future.wait([
    for (final host in selectedHosts)
      _fetchHostHistory(
        host,
        cursor: cursorByServerId?[host.serverId],
      ).then<(AgentHistoryHost, FetchAgentHistoryResponse)?>(
        (page) => (host, page),
        onError: (_) => null,
      ),
  ]);
  final pages = results
      .whereType<(AgentHistoryHost, FetchAgentHistoryResponse)>();
  if (selectedHosts.isNotEmpty && pages.isEmpty) {
    throw StateError('No connected hosts could load agent history');
  }
  final entries = <AgentHistoryEntry>[
    for (final (host, page) in pages)
      for (final entry in page.entries)
        AgentHistoryEntry(
          serverId: host.serverId,
          serverLabel: host.serverLabel,
          agent: entry.agent,
          project: entry.project,
          pendingPermissionCount: entry.pendingPermissions.length,
        ),
  ]..sort(_compareHistoryEntries);
  final next = <String, String>{
    for (final (host, page) in pages)
      if (page.pageInfo.hasMore && page.pageInfo.nextCursor != null)
        host.serverId: page.pageInfo.nextCursor!,
  };
  return AgentHistoryState(
    entries: List.unmodifiable(entries),
    nextCursorByServerId: Map.unmodifiable(next),
  );
}

Future<FetchAgentHistoryResponse> _fetchHostHistory(
  AgentHistoryHost host, {
  String? cursor,
}) => host.client.fetchAgentHistory(
  sort: const [
    AgentDirectorySort(
      key: AgentDirectorySortKey.updatedAt,
      direction: AgentDirectorySortDirection.desc,
    ),
  ],
  limit: 200,
  cursor: cursor,
);

int _compareHistoryEntries(AgentHistoryEntry left, AgentHistoryEntry right) {
  final activity = right.activityAt.compareTo(left.activityAt);
  if (activity != 0) return activity;
  final host = left.serverId.compareTo(right.serverId);
  if (host != 0) return host;
  return left.agent.agentId.compareTo(right.agent.agentId);
}
