import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../state/workspace_providers.dart';
import 'diff_view.dart';

/// Diff of a worktree's working directory with a manual refresh action.
/// Reflects git state directly, not any one agent conversation — a
/// worktree's `diff`-kind tab is a singleton.
class DiffPane extends ConsumerWidget {
  const DiffPane({super.key, required this.cwd});

  final String cwd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diffAsync = ref.watch(diffProvider(cwd));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  cwd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textStyles.bodySmall,
                ),
              ),
              Tooltip(
                message: 'Refresh diff',
                child: IconButton(
                  icon: const Icon(FluentIcons.refresh, size: 20),
                  onPressed: () => ref.read(diffProvider(cwd).notifier).refresh(),
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        Expanded(
          child: diffAsync.when(
            loading: () => const Center(child: ProgressRing()),
            error: (e, _) => Center(child: Text('Failed to load diff: $e')),
            data: (diff) => DiffView(diff: diff),
          ),
        ),
      ],
    );
  }
}
