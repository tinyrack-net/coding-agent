import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/worktree_actions.dart';
import '../state/agents_provider.dart';
import '../state/workspace_providers.dart';

/// Lists registered projects and, per project, their git worktrees —
/// showing which agent (if any) is using each one and letting the user
/// archive idle worktrees. This is the Paseo-style "workspace list" view.
class ProjectsScreen extends ConsumerWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectsAsync = ref.watch(projectsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Projects & worktrees')),
      body: projectsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load projects: $e')),
        data: (projects) {
          final gitProjects = projects.where((p) => p.isGitRepo).toList();
          if (gitProjects.isEmpty) {
            return const Center(
              child: Text('No git projects registered yet.'),
            );
          }
          return ListView.builder(
            itemCount: gitProjects.length,
            itemBuilder: (context, index) =>
                _ProjectSection(project: gitProjects[index]),
          );
        },
      ),
    );
  }
}

class _ProjectSection extends ConsumerWidget {
  const _ProjectSection({required this.project});

  final ProjectInfo project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ExpansionTile(
      title: Text(project.name.isEmpty ? project.path : project.name),
      subtitle: Text(
        project.path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      children: [_WorktreeList(projectPath: project.path)],
    );
  }
}

class _WorktreeList extends ConsumerWidget {
  const _WorktreeList({required this.projectPath});

  final String projectPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final worktreesAsync = ref.watch(worktreesProvider(projectPath));
    final agents = ref.watch(agentsProvider);

    return worktreesAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Failed to load worktrees: $e'),
      ),
      data: (worktrees) {
        if (worktrees.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No worktrees.'),
          );
        }
        return Column(
          children: [
            for (final worktree in worktrees)
              _WorktreeTile(
                worktree: worktree,
                owner: agents.values
                    .where((a) => a.cwd == worktree.path)
                    .firstOrNull,
              ),
          ],
        );
      },
    );
  }
}

class _WorktreeTile extends ConsumerWidget {
  const _WorktreeTile({required this.worktree, required this.owner});

  final WorktreeInfo worktree;
  final AgentSummary? owner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      dense: true,
      leading: Icon(
        worktree.isMain ? Icons.home_outlined : Icons.call_split,
        size: 18,
      ),
      title: Text(worktree.branch.isEmpty ? '(detached)' : worktree.branch),
      subtitle: Text(
        owner == null
            ? worktree.path
            : 'in use by "${owner!.title.isEmpty ? owner!.agentId : owner!.title}" · ${worktree.path}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: worktree.isMain
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (owner != null)
                  IconButton(
                    tooltip: 'Open agent',
                    icon: const Icon(Icons.open_in_new, size: 18),
                    onPressed: () {
                      ref
                          .read(selectedAgentProvider.notifier)
                          .select(owner!.agentId);
                      Navigator.of(context).pop();
                    },
                  ),
                IconButton(
                  tooltip: 'Archive worktree',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => archiveWorktreeWithConfirm(
                    context,
                    ref,
                    worktree.projectPath,
                    worktree.path,
                  ),
                ),
              ],
            ),
    );
  }
}
