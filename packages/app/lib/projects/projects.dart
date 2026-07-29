import 'package:agent_protocol/agent_protocol.dart';

final class ProjectWorkspaceSummary {
  const ProjectWorkspaceSummary({
    required this.id,
    required this.name,
    required this.workspaceKind,
    required this.status,
    required this.currentBranch,
    this.title,
    this.archivingAt,
  });

  final String id;
  final String name;
  final String? title;
  final WorkspaceKind workspaceKind;
  final WorkspaceStateBucket status;
  final String? currentBranch;
  final String? archivingAt;
}

final class ProjectHostEntry {
  const ProjectHostEntry({
    required this.serverId,
    required this.serverName,
    required this.isOnline,
    required this.repoRoot,
    required this.workspaceCount,
    required this.workspaces,
    this.gitRuntime,
    this.githubRuntime,
  });

  final String serverId;
  final String serverName;
  final bool isOnline;
  final String repoRoot;
  final int workspaceCount;
  final List<ProjectWorkspaceSummary> workspaces;
  final WorkspaceGitRuntime? gitRuntime;
  final Map<String, Object?>? githubRuntime;
}

final class ProjectSummary {
  const ProjectSummary({
    required this.projectKey,
    required this.projectName,
    required this.projectCustomName,
    required this.hosts,
    required this.totalWorkspaceCount,
    required this.hostCount,
    required this.onlineHostCount,
    required this.githubUrl,
  });

  final String projectKey;
  final String projectName;
  final String? projectCustomName;
  final List<ProjectHostEntry> hosts;
  final int totalWorkspaceCount;
  final int hostCount;
  final int onlineHostCount;
  final String? githubUrl;
}

final class ProjectHost {
  const ProjectHost({
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

final class BuildProjectsResult {
  const BuildProjectsResult({required this.projects});

  final List<ProjectSummary> projects;
}

final class _HostGroup {
  _HostGroup({
    required this.serverId,
    required this.serverName,
    required this.isOnline,
    required this.fallbackRepoRoot,
  });

  final String serverId;
  final String serverName;
  final bool isOnline;
  final String fallbackRepoRoot;
  final List<WorkspaceDescriptor> workspaces = [];
}

final class _ProjectGroup {
  _ProjectGroup({
    required this.projectKey,
    required this.projectName,
    required this.projectCustomName,
  });

  final String projectKey;
  String projectName;
  String? projectCustomName;
  final Map<String, _HostGroup> hostsByServerId = {};
}

BuildProjectsResult buildProjects({required Iterable<ProjectHost> hosts}) {
  final groups = <String, _ProjectGroup>{};

  for (final host in hosts) {
    final emptyRepoRootByProjectKey = <String, String>{};
    for (final project in host.emptyProjects) {
      emptyRepoRootByProjectKey[project.projectId] = project.projectRootPath;
      final group = groups.putIfAbsent(
        project.projectId,
        () => _ProjectGroup(
          projectKey: project.projectId,
          projectName:
              _nonEmpty(project.projectCustomName) ??
              project.projectDisplayName,
          projectCustomName: null,
        ),
      );
      group.hostsByServerId.putIfAbsent(
        host.serverId,
        () => _HostGroup(
          serverId: host.serverId,
          serverName: host.serverName,
          isOnline: host.isOnline,
          fallbackRepoRoot: project.projectRootPath,
        ),
      );
    }

    for (final workspace in host.workspaces) {
      final projectKey =
          _nonEmpty(_projectString(workspace, 'projectKey')) ??
          workspace.projectId;
      final customName = _customNameFor(host.workspaces, projectKey);
      final group = groups.putIfAbsent(
        projectKey,
        () => _ProjectGroup(
          projectKey: projectKey,
          projectName:
              customName?.displayName ??
              _nonEmpty(workspace.projectCustomName) ??
              _nonEmpty(_projectString(workspace, 'projectName')) ??
              workspace.projectDisplayName,
          projectCustomName: customName?.customName,
        ),
      );
      if (customName != null && group.projectCustomName == null) {
        group
          ..projectCustomName = customName.customName
          ..projectName = customName.displayName;
      }
      final hostGroup = group.hostsByServerId.putIfAbsent(
        host.serverId,
        () => _HostGroup(
          serverId: host.serverId,
          serverName: host.serverName,
          isOnline: host.isOnline,
          fallbackRepoRoot: emptyRepoRootByProjectKey[projectKey] ?? '',
        ),
      );
      hostGroup.workspaces.add(workspace);
    }
  }

  final projects = groups.values.map(_toProjectSummary).toList()
    ..sort((left, right) {
      final byName = left.projectName.compareTo(right.projectName);
      return byName != 0 ? byName : left.projectKey.compareTo(right.projectKey);
    });
  return BuildProjectsResult(projects: List.unmodifiable(projects));
}

ProjectSummary _toProjectSummary(_ProjectGroup group) {
  final hosts = group.hostsByServerId.values.map(_toHostEntry).toList()
    ..sort((left, right) {
      final byName = left.serverName.compareTo(right.serverName);
      return byName != 0 ? byName : left.serverId.compareTo(right.serverId);
    });
  return ProjectSummary(
    projectKey: group.projectKey,
    projectName: group.projectName,
    projectCustomName: group.projectCustomName,
    hosts: List.unmodifiable(hosts),
    totalWorkspaceCount: hosts.fold(
      0,
      (total, host) => total + host.workspaceCount,
    ),
    hostCount: hosts.length,
    onlineHostCount: hosts.where((host) => host.isOnline).length,
    githubUrl: _githubUrl(group.projectKey),
  );
}

ProjectHostEntry _toHostEntry(_HostGroup group) {
  final repoRoot = _resolveHostRepoRoot(group);
  final canonical = group.workspaces
      .where((workspace) => workspace.projectRootPath == repoRoot)
      .firstOrNull;
  final runtimeSource = canonical ?? group.workspaces.firstOrNull;
  return ProjectHostEntry(
    serverId: group.serverId,
    serverName: group.serverName,
    isOnline: group.isOnline,
    repoRoot: repoRoot,
    workspaceCount: group.workspaces.length,
    workspaces: List.unmodifiable(group.workspaces.map(_toWorkspaceSummary)),
    gitRuntime: runtimeSource?.gitRuntime,
    githubRuntime: runtimeSource?.githubRuntime,
  );
}

String _resolveHostRepoRoot(_HostGroup group) {
  for (final workspace in group.workspaces) {
    final checkout = workspace.project?['checkout'];
    if (checkout is! Map) continue;
    final root = _nonEmpty(checkout['mainRepoRoot']);
    if (root != null) return root;
  }
  return group.workspaces.firstOrNull?.projectRootPath ??
      group.fallbackRepoRoot;
}

ProjectWorkspaceSummary _toWorkspaceSummary(WorkspaceDescriptor workspace) {
  final branch = _nonEmpty(workspace.gitRuntime?.currentBranch);
  return ProjectWorkspaceSummary(
    id: workspace.id,
    name: workspace.name,
    title: _nonEmpty(workspace.title),
    workspaceKind: workspace.workspaceKind,
    status: workspace.status,
    currentBranch: branch == 'HEAD' ? null : branch,
    archivingAt: _nonEmpty(workspace.archivingAt),
  );
}

({String customName, String displayName})? _customNameFor(
  Iterable<WorkspaceDescriptor> workspaces,
  String projectKey,
) {
  for (final workspace in workspaces) {
    if (workspace.projectId != projectKey) continue;
    final customName = _nonEmpty(workspace.projectCustomName);
    if (customName == null) continue;
    return (customName: customName, displayName: workspace.projectDisplayName);
  }
  return null;
}

String? _projectString(WorkspaceDescriptor workspace, String key) =>
    _nonEmpty(workspace.project?[key]);

String? _githubUrl(String projectKey) {
  final match = RegExp(
    r'^remote:github\.com/([^/]+)/([^/]+)$',
  ).firstMatch(projectKey);
  return match == null
      ? null
      : 'https://github.com/${match.group(1)}/${match.group(2)}';
}

String? _nonEmpty(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
