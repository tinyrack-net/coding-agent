import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/host_routes.dart';
import '../core/theme.dart';
import '../projects/projects.dart';
import '../state/project_summaries_provider.dart';

class ProjectsSettingsScreen extends ConsumerWidget {
  const ProjectsSettingsScreen({super.key, this.selectedProjectKey});

  final String? selectedProjectKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectSummariesProvider);
    final data = projects.value;
    return ScaffoldPage.scrollable(
      key: const Key('projects-list'),
      header: const PageHeader(title: Text('Projects')),
      children: [
        if (projects.isLoading && data == null)
          const Center(
            child: Padding(padding: EdgeInsets.all(32), child: ProgressRing()),
          )
        else if (data == null)
          _LoadFailure(
            message: projects.error?.toString() ?? 'Failed to load projects.',
            onRetry: () => ref.read(projectSummariesProvider.notifier).reload(),
          )
        else ...[
          for (final error in data.hostErrors)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InfoBar(
                key: ValueKey('projects-host-error-${error.serverId}'),
                title: Text('${error.serverName} could not load projects'),
                content: Text(error.message),
                severity: InfoBarSeverity.warning,
              ),
            ),
          if (data.projects.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Text(
                  'No projects yet',
                  style: TextStyle(color: context.tokens.outline),
                ),
              ),
            )
          else
            Card(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var index = 0; index < data.projects.length; index++)
                    _ProjectRow(
                      project: data.projects[index],
                      selected:
                          selectedProjectKey == data.projects[index].projectKey,
                      showDivider: index > 0,
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.project,
    required this.selected,
    required this.showDivider,
  });

  final ProjectSummary project;
  final bool selected;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final initial = project.projectName.trim().isEmpty
        ? '?'
        : project.projectName.trim()[0].toUpperCase();
    return Column(
      children: [
        if (showDivider) const Divider(),
        HoverButton(
          key: ValueKey('project-row-${project.projectKey}'),
          onPressed: () =>
              context.go(buildProjectSettingsRoute(project.projectKey)),
          builder: (context, states) {
            final active = selected || states.contains(WidgetState.hovered);
            return Container(
              color: active
                  ? context.tokens.surfaceContainerHighest
                  : Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: context.tokens.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(initial, style: const TextStyle(fontSize: 11)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      project.projectName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(FluentIcons.chevron_right, size: 12),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _LoadFailure extends StatelessWidget {
  const _LoadFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => InfoBar(
    title: const Text('Failed to load projects'),
    content: Text(message),
    severity: InfoBarSeverity.error,
    action: Button(onPressed: onRetry, child: const Text('Reload')),
  );
}
