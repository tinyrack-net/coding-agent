import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';
import 'host_registry_provider.dart';

final class WorkspaceCatalogCacheNotifier
    extends Notifier<Map<String, List<WorkspaceDescriptor>>> {
  final Map<String, DaemonClient> _hydratedClients = {};

  @override
  Map<String, List<WorkspaceDescriptor>> build() => const {};

  List<WorkspaceDescriptor> read(String serverId) =>
      state[serverId] ?? const [];

  void replace(String serverId, List<WorkspaceDescriptor> workspaces) {
    final next = Map<String, List<WorkspaceDescriptor>>.of(state);
    next[serverId] = List<WorkspaceDescriptor>.unmodifiable(workspaces);
    state = Map<String, List<WorkspaceDescriptor>>.unmodifiable(next);
  }

  void clearServer(String serverId) {
    if (!state.containsKey(serverId)) return;
    final next = Map<String, List<WorkspaceDescriptor>>.of(state)
      ..remove(serverId);
    _hydratedClients.remove(serverId);
    state = Map.unmodifiable(next);
  }

  bool isHydratedFor(String serverId, DaemonClient client) =>
      identical(_hydratedClients[serverId], client);

  void markHydrated(String serverId, DaemonClient client) {
    _hydratedClients[serverId] = client;
  }

  void clearHydrated(String serverId) {
    _hydratedClients.remove(serverId);
  }
}

/// Retains the last authoritative catalog while the active host reconnects.
/// Paseo keeps cached workspace descriptors renderable instead of turning a
/// transient transport loss into a false "workspace missing" route.
final workspaceCatalogCacheProvider =
    NotifierProvider<
      WorkspaceCatalogCacheNotifier,
      Map<String, List<WorkspaceDescriptor>>
    >(WorkspaceCatalogCacheNotifier.new);

final workspaceCatalogReplicaLifecycleProvider = Provider<void>((ref) {
  ref.listen(hostRegistryProvider, (previous, next) {
    if (previous == null) return;
    final currentServerIds = {for (final host in next.hosts) host.serverId};
    final store = ref.read(workspaceCatalogCacheProvider.notifier);
    for (final host in previous.hosts) {
      if (!currentServerIds.contains(host.serverId)) {
        store.clearServer(host.serverId);
      }
    }
  });
});

final class WorkspaceCatalogRevisionNotifier
    extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => const {};

  void bump(String serverId) {
    state = {...state, serverId: (state[serverId] ?? 0) + 1};
  }
}

final workspaceCatalogRevisionProvider =
    NotifierProvider<WorkspaceCatalogRevisionNotifier, Map<String, int>>(
      WorkspaceCatalogRevisionNotifier.new,
    );

final class WorkspaceCatalogSnapshot {
  const WorkspaceCatalogSnapshot({
    required this.workspaces,
    required this.emptyProjects,
  });

  final List<WorkspaceDescriptor> workspaces;
  final List<WorkspaceProjectDescriptor> emptyProjects;
}

Future<WorkspaceCatalogSnapshot> fetchWorkspaceCatalogSnapshot(
  DaemonClient client, {
  bool subscribe = false,
}) async {
  const uuid = Uuid();
  final entries = <WorkspaceDescriptor>[];
  final emptyProjects = <WorkspaceProjectDescriptor>[];
  String? cursor;
  do {
    final request = FetchWorkspacesRequest(
      requestId: uuid.v4(),
      limit: 200,
      cursor: cursor,
      hasSubscription: subscribe && cursor == null,
    );
    final message = await client.requestSessionMessage(request.toJson());
    final response = FetchWorkspacesResponse.fromJson(message);
    entries.addAll(response.entries);
    emptyProjects.addAll(response.emptyProjects);
    cursor = response.pageInfo.hasMore ? response.pageInfo.nextCursor : null;
    if (response.pageInfo.hasMore && cursor == null) {
      throw const FormatException(
        'Workspace catalog page hasMore without nextCursor',
      );
    }
  } while (cursor != null);
  return WorkspaceCatalogSnapshot(
    workspaces: List.unmodifiable(entries),
    emptyProjects: List.unmodifiable(emptyProjects),
  );
}

Future<List<WorkspaceDescriptor>> fetchAllWorkspaces(
  DaemonClient client, {
  bool subscribe = false,
}) async => (await fetchWorkspaceCatalogSnapshot(
  client,
  subscribe: subscribe,
)).workspaces;

List<WorkspaceDescriptor> applyWorkspaceDirectoryUpdate(
  List<WorkspaceDescriptor> current,
  DirectoryUpdateEvent event,
) {
  final next = {for (final workspace in current) workspace.id: workspace};
  switch (event) {
    case WorkspaceDirectoryEvent(:final update):
      switch (update) {
        case WorkspaceUpsertUpdate(:final workspace):
          next[workspace.id] = workspace;
        case WorkspaceRemoveUpdate(:final id):
          next.remove(id);
      }
    case ProjectDirectoryEvent(:final update):
      switch (update) {
        case ProjectRemoveUpdate(:final projectId):
          next.removeWhere((_, workspace) => workspace.projectId == projectId);
        case ProjectUpsertUpdate(:final project):
          for (final entry in next.entries.toList(growable: false)) {
            if (entry.value.projectId != project.projectId) continue;
            next[entry.key] = WorkspaceDescriptor.fromJson({
              ...entry.value.toJson(),
              'projectDisplayName': project.projectDisplayName,
              'projectCustomName': project.projectCustomName,
              'projectRootPath': project.projectRootPath,
              'projectKind': project.projectKind.wireName,
            });
          }
      }
    case AgentUpsertDirectoryEvent() ||
        AgentRemoveDirectoryEvent() ||
        AgentDeletedDirectoryEvent() ||
        AgentArchivedDirectoryEvent():
      return current;
  }
  final ordered = next.values.toList(growable: false)
    ..sort(_compareWorkspaceCatalogEntries);
  return List<WorkspaceDescriptor>.unmodifiable(ordered);
}

/// Keeps subscription deltas in the daemon's default directory order:
/// newest activity first, then the stable workspace id tie-breaker.
int _compareWorkspaceCatalogEntries(
  WorkspaceDescriptor left,
  WorkspaceDescriptor right,
) {
  final leftActivity = DateTime.tryParse(left.activityAt ?? '');
  final rightActivity = DateTime.tryParse(right.activityAt ?? '');
  final byActivity = switch ((leftActivity, rightActivity)) {
    (null, null) => 0,
    (null, _) => 1,
    (_, null) => -1,
    (final left?, final right?) => right.compareTo(left),
  };
  return byActivity != 0 ? byActivity : left.id.compareTo(right.id);
}

/// Paseo v2 workspace catalog for the active host. Pages are exhausted so a
/// canonical deep link can resolve an opaque workspace id without guessing
/// from a local path or requiring the workspace to already have an agent.
final workspaceCatalogProvider = FutureProvider<List<WorkspaceDescriptor>>((
  ref,
) async {
  final serverId = ref.watch(activeHostProvider)?.serverId ?? 'legacy';
  ref.watch(
    workspaceCatalogRevisionProvider.select(
      (revisions) => revisions[serverId] ?? 0,
    ),
  );
  final cache = ref.read(workspaceCatalogCacheProvider.notifier);
  final connection = ref.watch(connectionStateProvider).value;
  if (connection != DaemonConnectionState.connected) {
    cache.clearHydrated(serverId);
    return cache.read(serverId);
  }
  final client = ref.watch(daemonClientProvider);
  final alreadyHydrated = cache.isHydratedFor(serverId, client);
  final buffered = <DirectoryUpdateEvent>[];
  var hydrating = !alreadyHydrated;
  final subscription = client.directoryUpdateEvents.listen((event) {
    if (event is! WorkspaceDirectoryEvent && event is! ProjectDirectoryEvent) {
      return;
    }
    if (hydrating) {
      buffered.add(event);
      return;
    }
    cache.replace(
      serverId,
      applyWorkspaceDirectoryUpdate(cache.read(serverId), event),
    );
    ref.read(workspaceCatalogRevisionProvider.notifier).bump(serverId);
  });
  ref.onDispose(() => unawaited(subscription.cancel()));
  if (alreadyHydrated) return cache.read(serverId);

  var workspaces = await fetchAllWorkspaces(client, subscribe: true);
  hydrating = false;
  for (final event in buffered) {
    workspaces = applyWorkspaceDirectoryUpdate(workspaces, event);
  }
  if (ref.mounted) {
    cache
      ..replace(serverId, workspaces)
      ..markHydrated(serverId, client);
  }
  return workspaces;
});
