import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';
import 'host_registry_provider.dart';
import 'workspace_catalog_provider.dart';

const scheduleProjectOptionPrefix = 'project:';

final class ScheduleProjectTarget {
  const ScheduleProjectTarget({
    required this.optionId,
    required this.serverId,
    required this.serverName,
    required this.projectKey,
    required this.projectName,
    required this.cwd,
    required this.isGit,
  });

  final String optionId;
  final String serverId;
  final String serverName;
  final String projectKey;
  final String projectName;
  final String cwd;
  final bool isGit;
}

final class ScheduleProjectHostReplica {
  const ScheduleProjectHostReplica({
    required this.serverId,
    required this.serverName,
    required this.isOnline,
    required this.workspaces,
    this.emptyProjects = const [],
  });

  final String serverId;
  final String serverName;
  final bool isOnline;
  final List<WorkspaceDescriptor> workspaces;
  final List<WorkspaceProjectDescriptor> emptyProjects;
}

final class ScheduleProjectHostError {
  const ScheduleProjectHostError({
    required this.serverId,
    required this.serverName,
    required this.message,
  });

  final String serverId;
  final String serverName;
  final String message;
}

final class ScheduleProjectTargetsState {
  const ScheduleProjectTargetsState({
    this.targets = const [],
    this.hostErrors = const [],
    this.connecting = false,
  });

  final List<ScheduleProjectTarget> targets;
  final List<ScheduleProjectHostError> hostErrors;
  final bool connecting;
}

String buildScheduleProjectOptionId(String serverId, String projectKey) =>
    '$scheduleProjectOptionPrefix$serverId:$projectKey';

List<ScheduleProjectTarget> buildScheduleProjectTargets(
  Iterable<ScheduleProjectHostReplica> replicas,
) {
  final targets = <String, ScheduleProjectTarget>{};
  for (final replica in replicas) {
    if (!replica.isOnline) continue;
    final projects = <String, WorkspaceProjectDescriptor>{
      for (final project in replica.emptyProjects) project.projectId: project,
    };
    final repoRootByProject = <String, String>{};
    for (final workspace in replica.workspaces) {
      final existing = projects[workspace.projectId];
      projects[workspace.projectId] = WorkspaceProjectDescriptor(
        projectId: workspace.projectId,
        projectDisplayName: workspace.projectDisplayName,
        projectCustomName:
            workspace.projectCustomName ?? existing?.projectCustomName,
        projectRootPath: workspace.projectRootPath,
        projectKind: workspace.projectKind,
      );
      repoRootByProject.putIfAbsent(
        workspace.projectId,
        () => _workspaceRepoRoot(workspace),
      );
    }
    for (final project in projects.values) {
      final cwd =
          (repoRootByProject[project.projectId] ?? project.projectRootPath)
              .trim();
      if (cwd.isEmpty) continue;
      final key = '${replica.serverId}:${project.projectId}';
      targets[key] = ScheduleProjectTarget(
        optionId: buildScheduleProjectOptionId(
          replica.serverId,
          project.projectId,
        ),
        serverId: replica.serverId,
        serverName: replica.serverName,
        projectKey: project.projectId,
        projectName: project.projectCustomName?.trim().isNotEmpty == true
            ? project.projectCustomName!
            : project.projectDisplayName,
        cwd: cwd,
        isGit: project.projectKind == WorkspaceProjectKind.git,
      );
    }
  }
  final result = targets.values.toList()
    ..sort((left, right) {
      final name = left.projectName.compareTo(right.projectName);
      if (name != 0) return name;
      final host = left.serverName.compareTo(right.serverName);
      if (host != 0) return host;
      return left.optionId.compareTo(right.optionId);
    });
  return List.unmodifiable(result);
}

Map<String, String> buildScheduleProjectNameByCwd(
  Iterable<ScheduleProjectTarget> targets,
) => Map.unmodifiable({
  for (final target in targets)
    _projectNameKey(target.serverId, target.cwd): target.projectName,
});

String describeScheduleCwd({
  required String serverId,
  required String cwd,
  required Map<String, String> projectNameByCwd,
}) =>
    projectNameByCwd[_projectNameKey(serverId, cwd)] ??
    cwd.replaceFirst(RegExp(r'^/(?:Users|home)/[^/]+'), '~');

String _projectNameKey(String serverId, String cwd) =>
    '$serverId:${cwd.trim()}';

String _workspaceRepoRoot(WorkspaceDescriptor workspace) {
  final checkout = workspace.project?['checkout'];
  if (checkout is Map) {
    final root = checkout['mainRepoRoot'];
    if (root is String && root.trim().isNotEmpty) return root;
  }
  return workspace.projectRootPath;
}

final scheduleProjectTargetsProvider =
    AsyncNotifierProvider<
      ScheduleProjectTargetsNotifier,
      ScheduleProjectTargetsState
    >(ScheduleProjectTargetsNotifier.new);

class ScheduleProjectTargetsNotifier
    extends AsyncNotifier<ScheduleProjectTargetsState> {
  List<ScheduleProjectFetchHost> _hosts = const [];
  bool _connecting = false;
  final List<StreamSubscription<DirectoryUpdateEvent>> _subscriptions = [];
  bool _disposeRegistered = false;
  Future<void>? _refreshOperation;

  @override
  Future<ScheduleProjectTargetsState> build() async {
    if (!_disposeRegistered) {
      _disposeRegistered = true;
      ref.onDispose(() {
        for (final subscription in _subscriptions) {
          unawaited(subscription.cancel());
        }
      });
    }
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();

    final profiles = ref.watch(hostRegistryProvider).hosts;
    final clients = ref.watch(hostRuntimeClientsProvider);
    final hosts = <ScheduleProjectFetchHost>[];
    var connecting = false;
    for (final profile in profiles) {
      final client = clients[profile.serverId];
      if (client == null) continue;
      ref.watch(hostConnectionStateProvider(profile.serverId));
      switch (client.currentState) {
        case DaemonConnectionState.connected:
          hosts.add(
            ScheduleProjectFetchHost(
              serverId: profile.serverId,
              serverName: profile.label,
              client: client,
            ),
          );
          _subscriptions.add(
            client.directoryUpdateEvents.listen((event) {
              if (event is WorkspaceDirectoryEvent ||
                  event is ProjectDirectoryEvent) {
                unawaited(_refreshPreservingData());
              }
            }),
          );
        case DaemonConnectionState.connecting:
          connecting = true;
        case DaemonConnectionState.disconnected:
        case DaemonConnectionState.versionMismatch:
          break;
      }
    }
    _hosts = List.unmodifiable(hosts);
    _connecting = connecting;
    return _fetch();
  }

  Future<void> reload() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }

  Future<ScheduleProjectTargetsState> _fetch() =>
      fetchScheduleProjectTargets(_hosts, connecting: _connecting);

  Future<void> _refreshPreservingData() {
    final existing = _refreshOperation;
    if (existing != null) return existing;
    final operation = _runRefreshPreservingData();
    _refreshOperation = operation;
    return operation.whenComplete(() {
      if (identical(_refreshOperation, operation)) _refreshOperation = null;
    });
  }

  Future<void> _runRefreshPreservingData() async {
    final current = state.value;
    try {
      final next = await _fetch();
      if (ref.mounted) state = AsyncData(next);
    } on Object {
      if (ref.mounted && current != null) state = AsyncData(current);
    }
  }
}

final class ScheduleProjectFetchHost {
  const ScheduleProjectFetchHost({
    required this.serverId,
    required this.serverName,
    required this.client,
  });

  final String serverId;
  final String serverName;
  final DaemonClient client;
}

final class _ScheduleProjectFetchResult {
  const _ScheduleProjectFetchResult.success(this.host, this.snapshot)
    : error = null;
  const _ScheduleProjectFetchResult.failure(this.host, this.error)
    : snapshot = null;

  final ScheduleProjectFetchHost host;
  final WorkspaceCatalogSnapshot? snapshot;
  final Object? error;
}

Future<ScheduleProjectTargetsState> fetchScheduleProjectTargets(
  List<ScheduleProjectFetchHost> hosts, {
  bool connecting = false,
}) async {
  final results = await Future.wait([
    for (final host in hosts)
      fetchWorkspaceCatalogSnapshot(
        host.client,
        // Host runtime owns the directory subscription. This is a snapshot
        // refresh only; requesting another subscription here would leak one
        // every time a directory event triggers a revalidation.
        subscribe: false,
      ).then<_ScheduleProjectFetchResult>(
        (snapshot) => _ScheduleProjectFetchResult.success(host, snapshot),
        onError: (Object error) =>
            _ScheduleProjectFetchResult.failure(host, error),
      ),
  ]);
  return ScheduleProjectTargetsState(
    targets: buildScheduleProjectTargets([
      for (final result in results)
        if (result.snapshot case final snapshot?)
          ScheduleProjectHostReplica(
            serverId: result.host.serverId,
            serverName: result.host.serverName,
            isOnline: true,
            workspaces: snapshot.workspaces,
            emptyProjects: snapshot.emptyProjects,
          ),
    ]),
    hostErrors: List.unmodifiable([
      for (final result in results)
        if (result.error case final error?)
          ScheduleProjectHostError(
            serverId: result.host.serverId,
            serverName: result.host.serverName,
            message: error.toString(),
          ),
    ]),
    connecting: connecting,
  );
}
