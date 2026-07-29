import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/provider_display.dart';
import '../core/theme.dart';
import '../state/provider_subagents_provider.dart';
import '../widgets/timeline_item_tile.dart';
import '../workspace/workspace_file_open.dart';

class ProviderSubagentScreen extends ConsumerStatefulWidget {
  const ProviderSubagentScreen({
    super.key,
    required this.parentAgentId,
    required this.subagentId,
    this.onOpenWorkspaceFile,
  });

  final String parentAgentId;
  final String subagentId;
  final void Function(WorkspaceFileOpenRequest request)? onOpenWorkspaceFile;

  @override
  ConsumerState<ProviderSubagentScreen> createState() =>
      _ProviderSubagentScreenState();
}

class _ProviderSubagentScreenState
    extends ConsumerState<ProviderSubagentScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref
          .read(providerSubagentsProvider(widget.parentAgentId).notifier)
          .loadTimeline(widget.subagentId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(providerSubagentsProvider(widget.parentAgentId));
    final descriptor = state.descriptors[widget.subagentId];
    final timeline = state.timelines[widget.subagentId];
    final rows = timeline?.projectedRows ?? const [];
    return Column(
      children: [
        Container(
          color: context.tokens.surfaceContainerHighest,
          child: ListTile(
            leading: const Icon(FluentIcons.branch_fork),
            title: Text(descriptor?.title ?? 'Sub-agent'),
            subtitle: Text(
              descriptor?.description ?? widget.subagentId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: descriptor == null
                ? null
                : _SubagentStatus(status: descriptor.status.name),
          ),
        ),
        const Divider(),
        Expanded(
          child: timeline?.loading == true && rows.isEmpty
              ? const Center(child: ProgressRing())
              : rows.isEmpty
              ? const Center(child: Text('No sub-agent activity yet.'))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  itemCount: rows.length + (timeline?.hasOlder == true ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (timeline?.hasOlder == true && index == 0) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: timeline!.loading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: ProgressRing(strokeWidth: 2),
                                )
                              : HyperlinkButton(
                                  onPressed: () => ref
                                      .read(
                                        providerSubagentsProvider(
                                          widget.parentAgentId,
                                        ).notifier,
                                      )
                                      .loadOlder(widget.subagentId),
                                  child: const Text('Load older activity'),
                                ),
                        ),
                      );
                    }
                    final rowIndex =
                        index - (timeline?.hasOlder == true ? 1 : 0);
                    final row = rows[rowIndex];
                    return TimelineItemTile(
                      key: ValueKey('${row.seq}:${row.item.id}'),
                      item: row.item,
                      providerLabel: providerDisplayName(descriptor?.provider),
                      cwd: descriptor?.cwd,
                      onOpenFilePath: widget.onOpenWorkspaceFile == null
                          ? null
                          : (path) => widget.onOpenWorkspaceFile!(
                              WorkspaceFileOpenRequest(
                                location: WorkspaceFileLocation(path: path),
                                disposition: OpenFileDisposition.main,
                              ),
                            ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

final class _SubagentStatus extends StatelessWidget {
  const _SubagentStatus({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) => Text(
    status,
    style: context.textStyles.bodySmall?.copyWith(
      color: context.tokens.onSurfaceVariant,
    ),
  );
}
