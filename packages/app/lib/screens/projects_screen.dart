import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/worktree_actions.dart';
import '../state/agents_provider.dart';
import '../state/workspace_providers.dart';
import '../state/worktree_tabs_provider.dart';
import '../widgets/fluent/page_back_button.dart';

/// Lists registered projects and, per project, their git worktrees —
/// showing which agent (if any) is using each one and letting the user
/// archive idle worktrees. This is the Paseo-style "workspace list" view.
class ProjectsScreen extends ConsumerWidget {
  const ProjectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projectsAsync = ref.watch(projectsProvider);

    return ScaffoldPage(
      header: const PageHeader(
        leading: PageBackButton(),
        title: Text('Projects & worktrees'),
      ),
      content: projectsAsync.when(
        loading: () => const Center(child: ProgressRing()),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Expander(
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(project.name.isEmpty ? project.path : project.name),
            Text(
              project.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        content: _WorktreeList(projectPath: project.path),
      ),
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
        child: Center(child: ProgressRing()),
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
      leading: Icon(
        worktree.isMain ? FluentIcons.home : FluentIcons.branch_fork2,
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
                  Tooltip(
                    message: 'Open agent',
                    child: IconButton(
                      icon: const Icon(FluentIcons.open_in_new_window, size: 18),
                      onPressed: () {
                        final worktreePath = resolveWorktreeKey(owner!);
                        ref
                            .read(worktreeTabsProvider(worktreePath).notifier)
                            .focusAgent(owner!.agentId);
                        ref
                            .read(selectedWorktreeProvider.notifier)
                            .select(worktreePath);
                        Navigator.of(context).pop();
                      },
                    ),
                  ),
                Tooltip(
                  message: 'Archive worktree',
                  child: IconButton(
                    icon: const Icon(FluentIcons.delete, size: 18),
                    onPressed: () => archiveWorktreeWithConfirm(
                      context,
                      ref,
                      worktree.projectPath,
                      worktree.path,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
