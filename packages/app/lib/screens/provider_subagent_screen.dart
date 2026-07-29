import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/provider_display.dart';
import '../core/theme.dart';
import '../state/provider_subagents_provider.dart';
import '../state/tool_call_detail_level_provider.dart';
import '../tool_calls/detail_level/tool_call_overview.dart';
import '../tool_calls/detail_level/tool_call_overview_view.dart';
import '../tool_calls/detail_level/tool_call_projection.dart';
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
    final detailLevel = ref.watch(toolCallDetailLevelProvider);
    final rows = _projectProviderRows(
      timeline?.projectedRows ?? const [],
      detailLevel,
      isTurnActive: descriptor?.status == ProviderSubagentStatus.running,
    );
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
                    Widget buildTile(TimelineItem item) => TimelineItemTile(
                      key: ValueKey('${row.seq}:${item.id}'),
                      item: item,
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
                    final group = row.group;
                    if (group != null) {
                      return ToolCallOverviewGroupView(
                        key: ValueKey('provider-overview-${group.run.id}'),
                        group: group,
                        isLastInSequence: row.isLastInSequence,
                        children: [
                          for (final call in group.run.calls) buildTile(call),
                        ],
                      );
                    }
                    return buildTile(row.item);
                  },
                ),
        ),
      ],
    );
  }
}

final class _ProviderProjectedRow {
  const _ProviderProjectedRow({
    required this.seq,
    required this.item,
    required this.group,
    required this.isLastInSequence,
  });

  final int seq;
  final TimelineItem item;
  final ToolCallOverviewGroup? group;
  final bool isLastInSequence;
}

List<_ProviderProjectedRow> _projectProviderRows(
  List<ProviderSubagentTimelineRow> rows,
  ToolCallDetailLevel level, {
  required bool isTurnActive,
}) {
  final items = [for (final row in rows) row.item];
  final prepared = prepareToolCallHistory(level, items);
  final projection = projectToolCallDetailLevel(
    level: level,
    tail: items,
    head: const [],
    preparedHistory: prepared,
    isTurnActive: isTurnActive,
  );
  final seqById = {for (final row in rows) row.item.id: row.seq};
  return [
    for (var index = 0; index < projection.tail.length; index++)
      _ProviderProjectedRow(
        seq: seqById[projection.tail[index].id] ?? 0,
        item: projection.tail[index],
        group: projection.groupsByHostId[projection.tail[index].id],
        isLastInSequence:
            projection.groupsByHostId.containsKey(projection.tail[index].id) &&
            (index == projection.tail.length - 1 ||
                !projection.groupsByHostId.containsKey(
                  projection.tail[index + 1].id,
                )),
      ),
  ];
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
