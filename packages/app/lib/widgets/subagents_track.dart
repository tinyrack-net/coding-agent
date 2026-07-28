import 'package:fluent_ui/fluent_ui.dart';

import '../core/provider_display.dart';
import '../core/theme.dart';
import '../state/subagents_provider.dart';

class SubagentsTrack extends StatefulWidget {
  const SubagentsTrack({
    super.key,
    required this.rows,
    required this.onOpenPaseoSubagent,
    required this.onOpenProviderSubagent,
    required this.onArchivePaseoSubagent,
    required this.onDetachPaseoSubagent,
    required this.onHideFinishedProviderSubagents,
  });

  final List<SubagentRow> rows;
  final ValueChanged<PaseoSubagentRow> onOpenPaseoSubagent;
  final ValueChanged<ProviderSubagentRow> onOpenProviderSubagent;
  final ValueChanged<PaseoSubagentRow> onArchivePaseoSubagent;
  final ValueChanged<PaseoSubagentRow> onDetachPaseoSubagent;
  final VoidCallback onHideFinishedProviderSubagents;

  @override
  State<SubagentsTrack> createState() => _SubagentsTrackState();
}

class _SubagentsTrackState extends State<SubagentsTrack> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.rows.isEmpty) return const SizedBox.shrink();
    final finishedCount = countFinishedProviderSubagents(widget.rows);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: FluentTheme.of(context).scaffoldBackgroundColor,
          border: Border.all(color: context.tokens.outlineVariant),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: HoverButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    builder: (context, states) => Container(
                      color: states.isHovered || states.isPressed
                          ? context.tokens.surfaceContainerHighest
                          : null,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _expanded
                                ? FluentIcons.chevron_down
                                : FluentIcons.chevron_right,
                            size: 12,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              formatSubagentsHeader(widget.rows),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (finishedCount > 0)
                  Tooltip(
                    message: 'Archive finished',
                    child: IconButton(
                      icon: const Icon(FluentIcons.archive, size: 14),
                      onPressed: widget.onHideFinishedProviderSubagents,
                    ),
                  ),
              ],
            ),
            if (_expanded) ...[
              Divider(
                style: DividerThemeData(
                  decoration: BoxDecoration(
                    color: context.tokens.outlineVariant,
                  ),
                ),
              ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 8),
                  itemCount: widget.rows.length,
                  itemBuilder: (context, index) => _SubagentTrackRow(
                    row: widget.rows[index],
                    onOpenPaseoSubagent: widget.onOpenPaseoSubagent,
                    onOpenProviderSubagent: widget.onOpenProviderSubagent,
                    onArchivePaseoSubagent: widget.onArchivePaseoSubagent,
                    onDetachPaseoSubagent: widget.onDetachPaseoSubagent,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SubagentTrackRow extends StatelessWidget {
  const _SubagentTrackRow({
    required this.row,
    required this.onOpenPaseoSubagent,
    required this.onOpenProviderSubagent,
    required this.onArchivePaseoSubagent,
    required this.onDetachPaseoSubagent,
  });

  final SubagentRow row;
  final ValueChanged<PaseoSubagentRow> onOpenPaseoSubagent;
  final ValueChanged<ProviderSubagentRow> onOpenProviderSubagent;
  final ValueChanged<PaseoSubagentRow> onArchivePaseoSubagent;
  final ValueChanged<PaseoSubagentRow> onDetachPaseoSubagent;

  @override
  Widget build(BuildContext context) {
    final label = resolveSubagentLabel(row.title) ?? 'Loading';
    return HoverButton(
      onPressed: () => switch (row) {
        final PaseoSubagentRow child => onOpenPaseoSubagent(child),
        final ProviderSubagentRow child => onOpenProviderSubagent(child),
      },
      builder: (context, states) => Container(
        color: states.isHovered || states.isPressed
            ? context.tokens.surfaceContainerHighest
            : null,
        padding: const EdgeInsets.only(left: 12, right: 4, top: 6, bottom: 6),
        child: Row(
          children: [
            Icon(
              FluentIcons.branch_fork,
              size: 14,
              color: row.requiresAttention
                  ? context.tokens.error
                  : context.tokens.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            Text(
              providerDisplayName(row.provider),
              style: context.textStyles.bodySmall?.copyWith(
                color: context.tokens.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            if (row.running)
              const SizedBox(
                width: 12,
                height: 12,
                child: ProgressRing(strokeWidth: 1.5),
              )
            else
              Icon(
                row.requiresAttention
                    ? FluentIcons.error_badge
                    : FluentIcons.completed_solid,
                size: 12,
                color: row.requiresAttention ? context.tokens.error : null,
              ),
            if (row case final PaseoSubagentRow child) ...[
              const SizedBox(width: 4),
              Tooltip(
                message: 'Detach subagent',
                child: IconButton(
                  icon: const Icon(FluentIcons.remove_link, size: 13),
                  onPressed: () => onDetachPaseoSubagent(child),
                ),
              ),
              Tooltip(
                message: 'Archive subagent',
                child: IconButton(
                  icon: const Icon(FluentIcons.archive, size: 13),
                  onPressed: () => onArchivePaseoSubagent(child),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
