/// One host on which a logical sidebar project is registered.
final class ProjectRemoveHost {
  const ProjectRemoveHost(this.serverId);

  final String serverId;
}

/// The logical project and every host that participates in it.
final class ProjectRemoveProject {
  const ProjectRemoveProject({required this.projectKey, required this.hosts});

  final String projectKey;
  final List<ProjectRemoveHost> hosts;
}

final class ProjectRemoveTarget {
  const ProjectRemoveTarget(this.serverId);

  final String serverId;

  @override
  bool operator ==(Object other) =>
      other is ProjectRemoveTarget && other.serverId == serverId;

  @override
  int get hashCode => serverId.hashCode;
}

sealed class ProjectRemoveReadiness {
  const ProjectRemoveReadiness();
}

final class ProjectRemoveReady extends ProjectRemoveReadiness {
  const ProjectRemoveReady(this.targets);

  final List<ProjectRemoveTarget> targets;
}

final class ProjectRemoveNeedsHostUpdate extends ProjectRemoveReadiness {
  const ProjectRemoveNeedsHostUpdate(this.serverIds);

  final List<String> serverIds;
}

sealed class ProjectRemoveOutcome {
  const ProjectRemoveOutcome();
}

final class ProjectRemoved extends ProjectRemoveOutcome {
  const ProjectRemoved(this.serverIds);

  final List<String> serverIds;
}

final class ProjectRemoveHostDisconnected extends ProjectRemoveOutcome {
  const ProjectRemoveHostDisconnected(this.serverIds);

  final List<String> serverIds;
}

final class ProjectRemoveFailed extends ProjectRemoveOutcome {
  const ProjectRemoveFailed(this.serverIds);

  final List<String> serverIds;
}

/// A connected host's typed project-remove operation.
typedef ProjectRemover = Future<void> Function(String projectKey);

/// Returns a remover for a connected host, or null when it is disconnected.
typedef ProjectRemoverLookup = ProjectRemover? Function(String serverId);

/// Applies Paseo's all-host capability gate before any destructive request.
ProjectRemoveReadiness getProjectRemoveReadiness({
  required ProjectRemoveProject project,
  required bool Function(String serverId) supportsProjectRemove,
}) {
  final unsupportedServerIds = <String>[];
  final targets = <ProjectRemoveTarget>[];
  for (final host in project.hosts) {
    if (!supportsProjectRemove(host.serverId)) {
      unsupportedServerIds.add(host.serverId);
    } else {
      targets.add(ProjectRemoveTarget(host.serverId));
    }
  }
  if (unsupportedServerIds.isNotEmpty) {
    return ProjectRemoveNeedsHostUpdate(
      List.unmodifiable(unsupportedServerIds),
    );
  }
  return ProjectRemoveReady(List.unmodifiable(targets));
}

/// Removes a logical project from every participating host.
///
/// Connection availability is checked for every target before the first
/// request, then all removals run concurrently and failures are reported by
/// server id, matching frozen Paseo's Promise.allSettled behavior.
Future<ProjectRemoveOutcome> removeProjectFromHosts({
  required String projectKey,
  required List<ProjectRemoveTarget> targets,
  required ProjectRemoverLookup getRemover,
}) async {
  final connected = <({String serverId, ProjectRemover remove})>[];
  final disconnectedServerIds = <String>[];
  for (final target in targets) {
    final remover = getRemover(target.serverId);
    if (remover == null) {
      disconnectedServerIds.add(target.serverId);
    } else {
      connected.add((serverId: target.serverId, remove: remover));
    }
  }
  if (disconnectedServerIds.isNotEmpty) {
    return ProjectRemoveHostDisconnected(
      List.unmodifiable(disconnectedServerIds),
    );
  }

  final results = await Future.wait(
    connected.map(
      (entry) => entry
          .remove(projectKey)
          .then<(String, bool)>(
            (_) => (entry.serverId, true),
            onError: (_) => (entry.serverId, false),
          ),
    ),
  );
  final failedServerIds = [
    for (final (serverId, succeeded) in results)
      if (!succeeded) serverId,
  ];
  if (failedServerIds.isNotEmpty) {
    return ProjectRemoveFailed(List.unmodifiable(failedServerIds));
  }
  return ProjectRemoved(
    List.unmodifiable(connected.map((entry) => entry.serverId)),
  );
}
