import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agents_provider.dart';
import 'sidebar_pins_provider.dart';
import 'workspace_providers.dart';

/// One row per worktree/session-group — Paseo shows exactly one sidebar row
/// per worktree regardless of how many agent sessions are open in it. A git
/// worktree (optionally with zero, one, or several live agents sharing its
/// path) or — for non-git ("local isolation") projects, which have no
/// worktree concept — the bundle of agents sharing that project's cwd. At
/// least one of [worktree]/[agents] is non-empty/non-null.
class SidebarWorktreeRow {
  const SidebarWorktreeRow({this.worktree, this.agents = const []})
    : assert(worktree != null || agents.length > 0);

  final WorktreeInfo? worktree;
  final List<AgentSummary> agents;

  /// This row's pin/selection key — a worktree's path, or (no worktree
  /// concept) the shared cwd of its agents. Matches `resolveWorktreeKey`.
  String get key => worktree?.path ?? agents.first.cwd;
}

/// One project's section in the sidebar: the registered project plus its
/// rows (one per git worktree for git repos — including an agent-less main
/// checkout — or a single row bundling every agent for non-git "local
/// isolation" projects, since their agents always share one cwd).
class SidebarProjectSection {
  const SidebarProjectSection({required this.project, required this.rows});

  final ProjectInfo project;
  final List<SidebarWorktreeRow> rows;
}

/// The sidebar's full grouping: pinned rows (hoisted out of their project),
/// one section per project with ≥1 visible row, and an "Other" bucket for
/// agents claimed by no row (legacy/edge case — every agent created via
/// "New workspace" is always tied to a registered project).
class SidebarGroups {
  const SidebarGroups({
    required this.pinned,
    required this.projectSections,
    required this.other,
  });

  final List<SidebarWorktreeRow> pinned;
  final List<SidebarProjectSection> projectSections;
  final List<SidebarWorktreeRow> other;

  bool get isEmpty =>
      pinned.isEmpty && projectSections.isEmpty && other.isEmpty;
}

/// An agent's owning project path: worktree agents carry it explicitly;
/// local-isolation agents' `cwd` *is* the project path (every agent is
/// created against a registered project — see `NewWorkspaceScreen`).
String resolveAgentProjectPath(AgentSummary agent) =>
    agent.projectPath ?? agent.cwd;

final sidebarGroupsProvider = Provider<SidebarGroups>((ref) {
  final agents = ref.watch(sortedAgentsProvider);
  final projects = ref.watch(projectsProvider).value ?? const <ProjectInfo>[];
  final pinnedKeys = ref.watch(sidebarPinsProvider);

  final agentsByCwd = <String, List<AgentSummary>>{};
  for (final agent in agents) {
    agentsByCwd.putIfAbsent(resolveWorktreeKey(agent), () => []).add(agent);
  }
  final claimedAgentIds = <String>{};
  final pinned = <SidebarWorktreeRow>[];
  final sections = <SidebarProjectSection>[];

  void placeRow(SidebarWorktreeRow row, List<SidebarWorktreeRow> unpinned) {
    for (final agent in row.agents) {
      claimedAgentIds.add(agent.agentId);
    }
    (pinnedKeys.contains(row.key) ? pinned : unpinned).add(row);
  }

  for (final project in projects) {
    if (project.isGitRepo) {
      // Every git worktree of this project (including an idle main
      // checkout) surfaces as a row, independent of whether any agent is
      // currently running in it.
      final worktrees =
          ref.watch(worktreesProvider(project.path)).value ??
          const <WorktreeInfo>[];
      if (worktrees.isEmpty) continue;
      final rows = <SidebarWorktreeRow>[];
      for (final worktree in worktrees) {
        placeRow(
          SidebarWorktreeRow(
            worktree: worktree,
            agents: agentsByCwd[worktree.path] ?? const [],
          ),
          rows,
        );
      }
      if (rows.isNotEmpty) {
        sections.add(SidebarProjectSection(project: project, rows: rows));
      }
    } else {
      // Non-git project: no worktree concept — every agent's cwd is the
      // project path directly, so they all bundle into one row.
      final owned = agents
          .where((agent) => resolveAgentProjectPath(agent) == project.path)
          .toList();
      if (owned.isEmpty) continue;
      final rows = <SidebarWorktreeRow>[];
      placeRow(SidebarWorktreeRow(agents: owned), rows);
      if (rows.isNotEmpty) {
        sections.add(SidebarProjectSection(project: project, rows: rows));
      }
    }
  }

  final otherByCwd = <String, List<AgentSummary>>{};
  for (final agent in agents) {
    if (claimedAgentIds.contains(agent.agentId)) continue;
    otherByCwd.putIfAbsent(agent.cwd, () => []).add(agent);
  }
  final other = <SidebarWorktreeRow>[];
  for (final bucket in otherByCwd.values) {
    placeRow(SidebarWorktreeRow(agents: bucket), other);
  }

  return SidebarGroups(pinned: pinned, projectSections: sections, other: other);
});
