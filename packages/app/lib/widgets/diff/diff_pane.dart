import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../state/working_diff_provider.dart';
import '../../state/workspace_checkout_status_provider.dart';
import '../../state/workspace_providers.dart';
import 'diff_view.dart';

/// Diff of a worktree's working directory with a manual refresh action.
/// Reflects git state directly, not any one agent conversation — a
/// worktree's `diff`-kind tab is a singleton.
class DiffPane extends ConsumerWidget {
  const DiffPane({
    super.key,
    required this.cwd,
    this.serverId,
    this.workspaceId,
    this.compact = false,
  });

  final String cwd;
  final String? serverId;
  final String? workspaceId;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = serverId;
    if (host != null && host.isNotEmpty) {
      return _LiveDiffPane(
        serverId: host,
        workspaceId: workspaceId,
        cwd: cwd,
        compact: compact,
      );
    }
    final diffAsync = ref.watch(diffProvider(cwd));

    return Column(
      children: [
        if (!compact) ...[
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
                    onPressed: () =>
                        ref.read(diffProvider(cwd).notifier).refresh(),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
        ] else
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Tooltip(
                message: 'Refresh diff',
                child: IconButton(
                  icon: const Icon(FluentIcons.refresh, size: 14),
                  onPressed: () =>
                      ref.read(diffProvider(cwd).notifier).refresh(),
                ),
              ),
            ),
          ),
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

class _LiveDiffPane extends ConsumerWidget {
  const _LiveDiffPane({
    required this.serverId,
    required this.workspaceId,
    required this.cwd,
    required this.compact,
  });

  final String serverId;
  final String? workspaceId;
  final String cwd;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref
        .watch(workspaceCheckoutStatusProvider((serverId: serverId, cwd: cwd)))
        .value;
    final isDirty = status?.isGit == true && status?.isDirty == true;
    final override = ref.watch(
      workingDiffOverrideProvider.select(
        (overrides) => overrides[(serverId: serverId, cwd: cwd)],
      ),
    );
    final mode = resolveWorkingDiffMode(isDirty: isDirty, override: override);
    final compare = CheckoutDiffCompare(
      mode: mode,
      baseRef: mode == CheckoutDiffMode.base ? status?.baseRef : null,
    );
    final query = CheckoutDiffQuery(
      serverId: serverId,
      cwd: cwd,
      compare: compare,
    );
    final diffAsync = ref.watch(checkoutDiffProvider(query));
    final baseLabel = switch (status?.baseRef?.trim()) {
      final value? when value.isNotEmpty => value,
      _ => 'base',
    };

    void selectMode(CheckoutDiffMode selected) {
      ref
          .read(workingDiffOverrideProvider.notifier)
          .select(
            serverId: serverId,
            cwd: cwd,
            mode: selected,
            isDirty: isDirty,
          );
    }

    final toolbar = Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12, vertical: 4),
      child: Row(
        children: [
          if (!compact)
            Expanded(
              child: Text(
                cwd,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.textStyles.bodySmall,
              ),
            )
          else
            const Spacer(),
          SizedBox(
            width: 150,
            child: ComboBox<CheckoutDiffMode>(
              value: mode,
              isExpanded: true,
              items: [
                const ComboBoxItem(
                  value: CheckoutDiffMode.uncommitted,
                  child: Text('Uncommitted'),
                ),
                ComboBoxItem(
                  value: CheckoutDiffMode.base,
                  child: Text('Against $baseLabel'),
                ),
              ],
              onChanged: (value) {
                if (value != null) selectMode(value);
              },
            ),
          ),
          Tooltip(
            message: 'Refresh diff',
            child: IconButton(
              icon: Icon(FluentIcons.refresh, size: compact ? 14 : 20),
              onPressed: () => ref.invalidate(checkoutDiffProvider(query)),
            ),
          ),
        ],
      ),
    );

    return Column(
      children: [
        toolbar,
        if (!compact) const Divider(),
        Expanded(
          child: diffAsync.when(
            loading: () => const Center(child: ProgressRing()),
            error: (error, _) =>
                Center(child: Text('Failed to load diff: $error')),
            data: (payload) {
              if (payload?.error case final error?) {
                return Center(
                  child: Text('Failed to load diff: ${error.message}'),
                );
              }
              return DiffView(
                diff: payload?.toLegacyDiff() ?? const DiffResponse(files: []),
              );
            },
          ),
        ),
      ],
    );
  }
}
