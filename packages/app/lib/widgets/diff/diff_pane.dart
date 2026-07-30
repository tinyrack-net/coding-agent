import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../state/changes_preferences_provider.dart';
import '../../state/review_draft_provider.dart';
import '../../state/working_diff_provider.dart';
import '../../state/workspace_checkout_status_provider.dart';
import '../../state/workspace_attachments_provider.dart';
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
    final changesPreferences =
        ref.watch(changesPreferencesProvider).value ??
        const ChangesPreferences();

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
                _DiffLayoutToggle(
                  layout: changesPreferences.layout,
                  onToggle: () => ref
                      .read(changesPreferencesProvider.notifier)
                      .updatePreferences(
                        layout:
                            changesPreferences.layout == ChangesLayout.unified
                            ? ChangesLayout.split
                            : ChangesLayout.unified,
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
            data: (diff) =>
                DiffView(diff: diff, layout: changesPreferences.layout),
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
    final changesPreferences =
        ref.watch(changesPreferencesProvider).value ??
        const ChangesPreferences();
    final ignoreWhitespace = changesPreferences.hideWhitespace;
    final scopeKey = buildWorkingDiffScopeKey(
      serverId: serverId,
      workspaceId: workspaceId,
      cwd: cwd,
      baseRef: status?.baseRef,
      ignoreWhitespace: ignoreWhitespace,
    );
    final isDirty = status?.isGit == true && status?.isDirty == true;
    final override = ref.watch(
      workingDiffOverrideProvider.select((overrides) => overrides[scopeKey]),
    );
    final mode = resolveWorkingDiffMode(isDirty: isDirty, override: override);
    final compare = CheckoutDiffCompare(
      mode: mode,
      baseRef: mode == CheckoutDiffMode.base ? status?.baseRef : null,
      ignoreWhitespace: ignoreWhitespace,
    );
    final query = CheckoutDiffQuery(
      serverId: serverId,
      cwd: cwd,
      compare: compare,
    );
    final reviewDraftKey = buildReviewDraftKey(
      serverId: serverId,
      workspaceId: workspaceId,
      cwd: cwd,
      mode: mode,
      baseRef: status?.baseRef,
      ignoreWhitespace: ignoreWhitespace,
    );
    final reviewComments = ref.watch(
      reviewDraftProvider.select(
        (state) => state.drafts[reviewDraftKey] ?? const [],
      ),
    );
    final AsyncValue<CheckoutDiffPayload?> diffAsync = switch (status) {
      null => const AsyncLoading(),
      final value when value.isGit => ref.watch(checkoutDiffProvider(query)),
      _ => const AsyncData(null),
    };
    final baseLabel = switch (status?.baseRef?.trim()) {
      final value? when value.isNotEmpty => value,
      _ => 'base',
    };

    void selectMode(CheckoutDiffMode selected) {
      ref
          .read(workingDiffOverrideProvider.notifier)
          .select(
            scopeKey: scopeKey,
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
          if (!compact)
            _DiffLayoutToggle(
              layout: changesPreferences.layout,
              onToggle: () => ref
                  .read(changesPreferencesProvider.notifier)
                  .updatePreferences(
                    layout: changesPreferences.layout == ChangesLayout.unified
                        ? ChangesLayout.split
                        : ChangesLayout.unified,
                  ),
            ),
          Tooltip(
            message: ignoreWhitespace
                ? 'Show whitespace changes'
                : 'Hide whitespace changes',
            child: ToggleButton(
              checked: ignoreWhitespace,
              onChanged: (_) => ref
                  .read(changesPreferencesProvider.notifier)
                  .updatePreferences(hideWhitespace: !ignoreWhitespace),
              child: const Text('−WS'),
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
              final diff =
                  payload?.toLegacyDiff() ?? const DiffResponse(files: []);
              final reviewAttachment = buildReviewAttachment(
                cwd: cwd,
                mode: mode,
                baseRef: status?.baseRef,
                comments: reviewComments,
                diff: diff,
              );
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final attachments = ref.read(
                  workspaceAttachmentsProvider(cwd).notifier,
                );
                if (reviewAttachment == null) {
                  attachments.remove('review', 'working-diff-review');
                } else {
                  attachments.add(
                    WorkspaceContextAttachment(
                      kind: 'review',
                      id: 'working-diff-review',
                      title: 'Code review',
                      subtitle: '${reviewAttachment.comments.length} comments',
                      text: reviewAttachment.comments
                          .map((comment) => comment.body)
                          .join('\n'),
                      url: null,
                      semanticAttachment: reviewAttachment,
                      reviewDraftKey: reviewDraftKey,
                    ),
                  );
                }
              });
              return DiffView(
                diff: diff,
                reviewDraftKey: reviewDraftKey,
                layout: changesPreferences.layout,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _DiffLayoutToggle extends StatelessWidget {
  const _DiffLayoutToggle({required this.layout, required this.onToggle});

  final ChangesLayout layout;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final split = layout == ChangesLayout.split;
    final label = split ? 'Switch to unified diff' : 'Switch to split diff';
    return Tooltip(
      message: label,
      child: IconButton(
        key: const ValueKey('changes-toggle-layout'),
        icon: Icon(
          split ? FluentIcons.align_justify : FluentIcons.column,
          size: 16,
        ),
        onPressed: onToggle,
      ),
    );
  }
}
