/// Frozen Paseo 0.2.0 project-row projection.
///
/// A sidebar project is always rendered as an expandable section. Its
/// project-level "new workspace" affordance is bound to the first usable host
/// that can either create a git worktree or supports multiple workspaces for
/// one directory.
final class SidebarProjectHost {
  const SidebarProjectHost({
    required this.serverId,
    required this.iconWorkingDir,
    required this.canCreateWorktree,
  });

  final String serverId;
  final String iconWorkingDir;
  final bool canCreateWorktree;
}

final class SidebarProjectEntry {
  const SidebarProjectEntry({
    required this.projectKey,
    required this.projectName,
    required this.hosts,
  });

  final String projectKey;
  final String projectName;
  final List<SidebarProjectHost> hosts;
}

final class SidebarProjectHostTarget {
  const SidebarProjectHostTarget({
    required this.serverId,
    required this.iconWorkingDir,
  });

  final String serverId;
  final String iconWorkingDir;

  @override
  bool operator ==(Object other) =>
      other is SidebarProjectHostTarget &&
      serverId == other.serverId &&
      iconWorkingDir == other.iconWorkingDir;

  @override
  int get hashCode => Object.hash(serverId, iconWorkingDir);
}

enum SidebarProjectChevron { expand, collapse }

sealed class SidebarProjectTrailingAction {
  const SidebarProjectTrailingAction();
}

final class SidebarProjectNewWorkspaceAction
    extends SidebarProjectTrailingAction {
  const SidebarProjectNewWorkspaceAction(this.target);

  final SidebarProjectHostTarget target;
}

final class SidebarProjectNoTrailingAction
    extends SidebarProjectTrailingAction {
  const SidebarProjectNoTrailingAction();
}

final class SidebarProjectRowModel {
  const SidebarProjectRowModel({
    required this.chevron,
    required this.trailingAction,
  });

  final SidebarProjectChevron chevron;
  final SidebarProjectTrailingAction trailingAction;
}

SidebarProjectHostTarget? _hostTarget(SidebarProjectHost host) {
  final serverId = host.serverId.trim();
  final iconWorkingDir = host.iconWorkingDir.trim();
  if (serverId.isEmpty || iconWorkingDir.isEmpty) return null;
  return SidebarProjectHostTarget(
    serverId: serverId,
    iconWorkingDir: iconWorkingDir,
  );
}

SidebarProjectHostTarget? resolveSidebarProjectIconTarget(
  SidebarProjectEntry project,
) {
  for (final host in project.hosts) {
    final target = _hostTarget(host);
    if (target != null) return target;
  }
  return null;
}

SidebarProjectHostTarget? _resolveNewWorkspaceTarget(
  SidebarProjectEntry project,
  Map<String, bool> supportsMultiplicityByServerId,
) {
  for (final host in project.hosts) {
    if (!host.canCreateWorktree &&
        supportsMultiplicityByServerId[host.serverId] != true) {
      continue;
    }
    final target = _hostTarget(host);
    if (target != null) return target;
  }
  return null;
}

SidebarProjectRowModel buildSidebarProjectRowModel({
  required SidebarProjectEntry project,
  required bool collapsed,
  Map<String, bool> supportsMultiplicityByServerId = const {},
}) {
  final target = _resolveNewWorkspaceTarget(
    project,
    supportsMultiplicityByServerId,
  );
  return SidebarProjectRowModel(
    chevron: collapsed
        ? SidebarProjectChevron.expand
        : SidebarProjectChevron.collapse,
    trailingAction: target == null
        ? const SidebarProjectNoTrailingAction()
        : SidebarProjectNewWorkspaceAction(target),
  );
}
