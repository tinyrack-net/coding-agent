import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../projects/projects.dart';
import 'daemon_providers.dart';
import 'host_registry_provider.dart';
import 'workspace_catalog_provider.dart';

final class ProjectHostError {
  const ProjectHostError({
    required this.serverId,
    required this.serverName,
    required this.message,
  });

  final String serverId;
  final String serverName;
  final String message;
}

final class ProjectHostReplica {
  const ProjectHostReplica({
    required this.serverId,
    required this.serverName,
    required this.workspaces,
    required this.emptyProjects,
  });

  final String serverId;
  final String serverName;
  final List<WorkspaceDescriptor> workspaces;
  final List<WorkspaceProjectDescriptor> emptyProjects;

  ProjectHostReplica copyWith({
    String? serverName,
    List<WorkspaceDescriptor>? workspaces,
    List<WorkspaceProjectDescriptor>? emptyProjects,
  }) => ProjectHostReplica(
    serverId: serverId,
    serverName: serverName ?? this.serverName,
    workspaces: workspaces ?? this.workspaces,
    emptyProjects: emptyProjects ?? this.emptyProjects,
  );
}

final class ProjectHostRuntimeState {
  const ProjectHostRuntimeState({
    required this.serverId,
    required this.isOnline,
    required this.isLoading,
    required this.isFetching,
    required this.error,
  });

  final String serverId;
  final bool isOnline;
  final bool isLoading;
  final bool isFetching;
  final String? error;
}

final class DerivedProjectsResult {
  const DerivedProjectsResult({
    required this.projects,
    required this.hostErrors,
    required this.isLoading,
    required this.isFetching,
  });

  final List<ProjectSummary> projects;
  final List<ProjectHostError> hostErrors;
  final bool isLoading;
  final bool isFetching;

  DerivedProjectsResult copyWith({
    List<ProjectSummary>? projects,
    List<ProjectHostError>? hostErrors,
    bool? isLoading,
    bool? isFetching,
  }) => DerivedProjectsResult(
    projects: projects ?? this.projects,
    hostErrors: hostErrors ?? this.hostErrors,
    isLoading: isLoading ?? this.isLoading,
    isFetching: isFetching ?? this.isFetching,
  );
}

DerivedProjectsResult deriveProjectsFromReplica({
  required Iterable<ProjectHostReplica> replicas,
  required Iterable<ProjectHostRuntimeState> runtimeStates,
}) {
  final states = {for (final state in runtimeStates) state.serverId: state};
  final replicaList = replicas.toList(growable: false);
  final projects = buildProjects(
    hosts: [
      for (final replica in replicaList)
        ProjectHost(
          serverId: replica.serverId,
          serverName: replica.serverName,
          isOnline: states[replica.serverId]?.isOnline ?? false,
          workspaces: replica.workspaces,
          emptyProjects: replica.emptyProjects,
        ),
    ],
  ).projects;
  return DerivedProjectsResult(
    projects: projects,
    hostErrors: List.unmodifiable([
      for (final replica in replicaList)
        if (states[replica.serverId]?.error case final message?)
          ProjectHostError(
            serverId: replica.serverId,
            serverName: replica.serverName,
            message: message,
          ),
    ]),
    isLoading: states.values.any((state) => state.isLoading),
    isFetching: states.values.any((state) => state.isFetching),
  );
}

ProjectHostReplica applyProjectReplicaDirectoryUpdate(
  ProjectHostReplica replica,
  DirectoryUpdateEvent event,
) {
  final workspaces = {
    for (final workspace in replica.workspaces) workspace.id: workspace,
  };
  final emptyProjects = {
    for (final project in replica.emptyProjects) project.projectId: project,
  };
  switch (event) {
    case WorkspaceDirectoryEvent(:final update):
      switch (update) {
        case WorkspaceUpsertUpdate(:final workspace):
          workspaces[workspace.id] = workspace;
          emptyProjects.remove(workspace.projectId);
        case WorkspaceRemoveUpdate(
          :final id,
          :final emptyProject,
          :final removedProjectId,
        ):
          workspaces.remove(id);
          if (emptyProject != null) {
            emptyProjects[emptyProject.projectId] = emptyProject;
          }
          if (removedProjectId != null) {
            emptyProjects.remove(removedProjectId);
          }
      }
    case ProjectDirectoryEvent(:final update):
      switch (update) {
        case ProjectUpsertUpdate(:final project):
          var hasAttachedWorkspace = false;
          for (final entry in workspaces.entries.toList(growable: false)) {
            if (entry.value.projectId != project.projectId) continue;
            hasAttachedWorkspace = true;
            workspaces[entry.key] = WorkspaceDescriptor.fromJson({
              ...entry.value.toJson(),
              'projectDisplayName': project.projectDisplayName,
              'projectCustomName': project.projectCustomName,
              'projectRootPath': project.projectRootPath,
              'projectKind': project.projectKind.wireName,
            });
          }
          if (hasAttachedWorkspace) {
            emptyProjects.remove(project.projectId);
          } else {
            emptyProjects[project.projectId] = project;
          }
        case ProjectRemoveUpdate(:final projectId):
          emptyProjects.remove(projectId);
          workspaces.removeWhere(
            (_, workspace) => workspace.projectId == projectId,
          );
      }
    case AgentUpsertDirectoryEvent() ||
        AgentRemoveDirectoryEvent() ||
        AgentDeletedDirectoryEvent() ||
        AgentArchivedDirectoryEvent():
      return replica;
  }
  return replica.copyWith(
    workspaces: List.unmodifiable(workspaces.values),
    emptyProjects: List.unmodifiable(emptyProjects.values),
  );
}

ProjectHostReplica applyProjectReplicaDirectoryUpdates(
  ProjectHostReplica replica,
  Iterable<DirectoryUpdateEvent> events,
) {
  var next = replica;
  for (final event in events) {
    next = applyProjectReplicaDirectoryUpdate(next, event);
  }
  return next;
}

final projectSummariesProvider =
    AsyncNotifierProvider<ProjectSummariesNotifier, DerivedProjectsResult>(
      ProjectSummariesNotifier.new,
    );

final class ProjectSummariesNotifier
    extends AsyncNotifier<DerivedProjectsResult> {
  final Map<String, ProjectHostReplica> _replicas = {};
  final Map<String, String> _errors = {};
  final Map<String, DaemonClient> _hydratedClients = {};
  final Map<String, StreamSubscription<DirectoryUpdateEvent>> _subscriptions =
      {};
  final Set<String> _hydrating = {};
  final Map<String, List<DirectoryUpdateEvent>> _bufferedEvents = {};
  List<HostProfile> _hosts = const [];
  Map<String, DaemonClient> _clients = const {};
  bool _disposeRegistered = false;

  @override
  Future<DerivedProjectsResult> build() async {
    if (!_disposeRegistered) {
      _disposeRegistered = true;
      ref.onDispose(() {
        for (final subscription in _subscriptions.values) {
          unawaited(subscription.cancel());
        }
      });
    }
    _hosts = ref.watch(hostRegistryProvider).hosts;
    _clients = ref.watch(hostRuntimeClientsProvider);
    for (final host in _hosts) {
      ref.watch(hostConnectionStateProvider(host.serverId));
    }
    _reconcileHosts();
    return _fetch();
  }

  Future<void> reload() async {
    final current = state.value;
    state = current == null
        ? const AsyncLoading()
        : AsyncData(current.copyWith(isFetching: true));
    state = await AsyncValue.guard(_fetch);
  }

  void _reconcileHosts() {
    final serverIds = {for (final host in _hosts) host.serverId};
    for (final serverId in _replicas.keys.toList(growable: false)) {
      if (serverIds.contains(serverId)) continue;
      _replicas.remove(serverId);
      _errors.remove(serverId);
      _hydratedClients.remove(serverId);
      _hydrating.remove(serverId);
      _bufferedEvents.remove(serverId);
      unawaited(_subscriptions.remove(serverId)?.cancel());
    }
    for (final host in _hosts) {
      final replica = _replicas.putIfAbsent(
        host.serverId,
        () => ProjectHostReplica(
          serverId: host.serverId,
          serverName: host.label,
          workspaces: const [],
          emptyProjects: const [],
        ),
      );
      if (replica.serverName != host.label) {
        _replicas[host.serverId] = replica.copyWith(serverName: host.label);
      }
      final client = _clients[host.serverId];
      final previous = _hydratedClients[host.serverId];
      if (client == null || identical(previous, client)) continue;
      unawaited(_subscriptions.remove(host.serverId)?.cancel());
      _subscriptions[host.serverId] = client.directoryUpdateEvents.listen(
        (event) => _onDirectoryUpdate(host.serverId, event),
      );
    }
  }

  Future<DerivedProjectsResult> _fetch() async {
    final operations = <Future<_ProjectHostFetchResult>>[];
    for (final host in _hosts) {
      final client = _clients[host.serverId];
      if (client == null ||
          client.currentState != DaemonConnectionState.connected) {
        continue;
      }
      _hydrating.add(host.serverId);
      _bufferedEvents.putIfAbsent(host.serverId, () => []);
      operations.add(
        _fetchHost(
          host,
          client,
          subscribe: !identical(_hydratedClients[host.serverId], client),
        ),
      );
    }
    final results = await Future.wait(operations);
    for (final result in results) {
      final buffered = _bufferedEvents.remove(result.host.serverId) ?? const [];
      _hydrating.remove(result.host.serverId);
      final snapshot = result.snapshot;
      if (snapshot == null) {
        _errors[result.host.serverId] = result.error.toString();
        final existing = _replicas[result.host.serverId];
        if (existing != null) {
          _replicas[result.host.serverId] = applyProjectReplicaDirectoryUpdates(
            existing,
            buffered,
          );
        }
        continue;
      }
      _errors.remove(result.host.serverId);
      _hydratedClients[result.host.serverId] = result.client;
      _replicas[result.host.serverId] = applyProjectReplicaDirectoryUpdates(
        ProjectHostReplica(
          serverId: result.host.serverId,
          serverName: result.host.label,
          workspaces: snapshot.workspaces,
          emptyProjects: snapshot.emptyProjects,
        ),
        buffered,
      );
    }
    return _derive(fetching: false);
  }

  DerivedProjectsResult _derive({required bool fetching}) {
    return deriveProjectsFromReplica(
      replicas: [
        for (final host in _hosts)
          _replicas[host.serverId] ??
              ProjectHostReplica(
                serverId: host.serverId,
                serverName: host.label,
                workspaces: const [],
                emptyProjects: const [],
              ),
      ],
      runtimeStates: [
        for (final host in _hosts)
          ProjectHostRuntimeState(
            serverId: host.serverId,
            isOnline:
                _clients[host.serverId]?.currentState ==
                DaemonConnectionState.connected,
            isLoading:
                !_replicas.containsKey(host.serverId) &&
                _clients[host.serverId]?.currentState ==
                    DaemonConnectionState.connecting,
            isFetching:
                fetching &&
                _clients[host.serverId]?.currentState ==
                    DaemonConnectionState.connected,
            error: _errors[host.serverId],
          ),
      ],
    );
  }

  void _onDirectoryUpdate(String serverId, DirectoryUpdateEvent event) {
    if (_hydrating.contains(serverId)) {
      _bufferedEvents.putIfAbsent(serverId, () => []).add(event);
      return;
    }
    final replica = _replicas[serverId];
    if (replica == null) return;
    _replicas[serverId] = applyProjectReplicaDirectoryUpdate(replica, event);
    if (state.value != null) state = AsyncData(_derive(fetching: false));
  }
}

final class _ProjectHostFetchResult {
  const _ProjectHostFetchResult({
    required this.host,
    required this.client,
    required this.snapshot,
    required this.error,
  });

  final HostProfile host;
  final DaemonClient client;
  final WorkspaceCatalogSnapshot? snapshot;
  final Object? error;
}

Future<_ProjectHostFetchResult> _fetchHost(
  HostProfile host,
  DaemonClient client, {
  required bool subscribe,
}) async {
  try {
    return _ProjectHostFetchResult(
      host: host,
      client: client,
      snapshot: await fetchWorkspaceCatalogSnapshot(
        client,
        subscribe: subscribe,
      ),
      error: null,
    );
  } on Object catch (error) {
    return _ProjectHostFetchResult(
      host: host,
      client: client,
      snapshot: null,
      error: error,
    );
  }
}
