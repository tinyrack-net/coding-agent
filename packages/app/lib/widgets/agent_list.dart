import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;
import 'package:intl/intl.dart';

import '../core/theme.dart';
import '../state/agent_history_provider.dart';
import 'provider_icon.dart';

enum AgentDateSection { today, yesterday, thisWeek, thisMonth, older }

AgentDateSection deriveAgentDateSection(DateTime activity, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final activityDay = DateTime(activity.year, activity.month, activity.day);
  if (!activityDay.isBefore(today)) return AgentDateSection.today;
  final yesterday = today.subtract(const Duration(days: 1));
  if (!activityDay.isBefore(yesterday)) return AgentDateSection.yesterday;
  final days = today.difference(activityDay).inDays;
  if (days <= 7) return AgentDateSection.thisWeek;
  if (days <= 30) return AgentDateSection.thisMonth;
  return AgentDateSection.older;
}

String agentDateSectionLabel(AgentDateSection section) => switch (section) {
  AgentDateSection.today => 'Today',
  AgentDateSection.yesterday => 'Yesterday',
  AgentDateSection.thisWeek => 'This week',
  AgentDateSection.thisMonth => 'This month',
  AgentDateSection.older => 'Older',
};

String formatAgentTimeAgo(DateTime activity, DateTime now) {
  final seconds = now.difference(activity).inSeconds;
  if (seconds < 10) return 'just now';
  if (seconds < 60) return '${seconds}s ago';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '${minutes}m ago';
  final hours = minutes ~/ 60;
  if (hours < 24) return '${hours}h ago';
  final days = hours ~/ 24;
  if (days < 7) return '${days}d ago';
  return DateFormat('MMM d', 'en_US').format(activity);
}

typedef AgentEntryCallback = void Function(AgentHistoryEntry entry);

/// Flutter port of Paseo 0.2.0's aggregated AgentList.
class AgentList extends StatelessWidget {
  const AgentList({
    super.key,
    required this.agents,
    required this.onAgentPressed,
    required this.onAgentLongPressed,
    this.onRefresh,
    this.refreshing = false,
    this.selectedAgentId,
    this.showAttentionIndicator = true,
    this.showHostColumn = false,
    this.footer,
    this.now,
  });

  final List<AgentHistoryEntry> agents;
  final AgentEntryCallback onAgentPressed;
  final AgentEntryCallback onAgentLongPressed;
  final Future<void> Function()? onRefresh;
  final bool refreshing;
  final String? selectedAgentId;
  final bool showAttentionIndicator;
  final bool showHostColumn;
  final Widget? footer;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final referenceNow = now ?? DateTime.now();
    final buckets = <AgentDateSection, List<AgentHistoryEntry>>{};
    for (final entry in agents) {
      buckets
          .putIfAbsent(
            deriveAgentDateSection(entry.activityAt.toLocal(), referenceNow),
            () => [],
          )
          .add(entry);
    }
    final items = <Widget>[
      for (final section in AgentDateSection.values)
        if (buckets[section] case final entries?) ...[
          _SectionHeading(section: section),
          for (final entry in entries)
            _AgentRow(
              key: ValueKey(
                'agent-row-${entry.serverId}-${entry.agent.agentId}',
              ),
              entry: entry,
              selected:
                  selectedAgentId == '${entry.serverId}:${entry.agent.agentId}',
              showAttentionIndicator: showAttentionIndicator,
              showHostColumn: showHostColumn,
              now: referenceNow,
              onPressed: () => onAgentPressed(entry),
              onLongPressed: () => onAgentLongPressed(entry),
            ),
        ],
      ?footer,
    ];
    final list = LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          constraints.maxWidth < 720 ? 12 : 24,
          16,
          constraints.maxWidth < 720 ? 12 : 24,
          24,
        ),
        children: items,
      ),
    );
    if (onRefresh == null) return list;
    return material.RefreshIndicator.adaptive(
      onRefresh: onRefresh!,
      child: Stack(
        children: [
          Positioned.fill(child: list),
          if (refreshing)
            const Positioned(
              top: 8,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox.square(
                  dimension: 16,
                  child: ProgressRing(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.section});

  final AgentDateSection section;

  @override
  Widget build(BuildContext context) => Padding(
    key: ValueKey('agent-section-${section.name}'),
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    child: Text(
      agentDateSectionLabel(section),
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: context.paseoPalette.foregroundMuted,
      ),
    ),
  );
}

class _AgentRow extends StatefulWidget {
  const _AgentRow({
    super.key,
    required this.entry,
    required this.selected,
    required this.showAttentionIndicator,
    required this.showHostColumn,
    required this.now,
    required this.onPressed,
    required this.onLongPressed,
  });

  final AgentHistoryEntry entry;
  final bool selected;
  final bool showAttentionIndicator;
  final bool showHostColumn;
  final DateTime now;
  final VoidCallback onPressed;
  final VoidCallback onLongPressed;

  @override
  State<_AgentRow> createState() => _AgentRowState();
}

class _AgentRowState extends State<_AgentRow> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    final entry = widget.entry;
    final agent = entry.agent;
    final projectName = entry.project['projectName'] as String? ?? '';
    final workspaceName = entry.project['workspaceName'] as String? ?? '';
    final checkout = entry.project['checkout'];
    final branch = checkout is Map
        ? checkout['currentBranch'] as String? ?? ''
        : agent.branch ?? '';
    final title = agent.title.trim().isEmpty ? 'New session' : agent.title;
    final time = formatAgentTimeAgo(entry.activityAt.toLocal(), widget.now);
    final background = widget.selected || _pressed
        ? palette.surface2
        : _hovered
        ? palette.surface1
        : Colors.transparent;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        return Semantics(
          button: true,
          selected: widget.selected,
          label: '$workspaceName $title'.trim(),
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onPressed,
              onLongPress: widget.onLongPressed,
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 80),
                margin: EdgeInsets.only(bottom: compact ? 4 : 0),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: compact ? BorderRadius.circular(8) : null,
                ),
                child: compact
                    ? _CompactAgentRow(
                        entry: entry,
                        title: title,
                        projectName: projectName,
                        workspaceName: workspaceName,
                        branch: branch,
                        time: time,
                        showAttentionIndicator: widget.showAttentionIndicator,
                        showHostColumn: widget.showHostColumn,
                      )
                    : _DesktopAgentRow(
                        entry: entry,
                        title: title,
                        projectName: projectName,
                        workspaceName: workspaceName,
                        branch: branch,
                        time: time,
                        showAttentionIndicator: widget.showAttentionIndicator,
                        showHostColumn: widget.showHostColumn,
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DesktopAgentRow extends StatelessWidget {
  const _DesktopAgentRow({
    required this.entry,
    required this.title,
    required this.projectName,
    required this.workspaceName,
    required this.branch,
    required this.time,
    required this.showAttentionIndicator,
    required this.showHostColumn,
  });

  final AgentHistoryEntry entry;
  final String title;
  final String projectName;
  final String workspaceName;
  final String branch;
  final String time;
  final bool showAttentionIndicator;
  final bool showHostColumn;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: _AgentTitle(
          entry: entry,
          title: title,
          workspaceName: workspaceName,
          showAttention:
              showAttentionIndicator && entry.agent.requiresAttention,
        ),
      ),
      _MetaColumn(
        key: ValueKey(
          'agent-row-project-${entry.serverId}-${entry.agent.agentId}',
        ),
        text: projectName,
      ),
      if (showHostColumn)
        _MetaColumn(text: entry.serverLabel, width: 120, right: true),
      _MetaColumn(
        key: ValueKey(
          'agent-row-branch-${entry.serverId}-${entry.agent.agentId}',
        ),
        text: branch,
      ),
      _MetaColumn(text: time, width: 72, right: true),
    ],
  );
}

class _CompactAgentRow extends StatelessWidget {
  const _CompactAgentRow({
    required this.entry,
    required this.title,
    required this.projectName,
    required this.workspaceName,
    required this.branch,
    required this.time,
    required this.showAttentionIndicator,
    required this.showHostColumn,
  });

  final AgentHistoryEntry entry;
  final String title;
  final String projectName;
  final String workspaceName;
  final String branch;
  final String time;
  final bool showAttentionIndicator;
  final bool showHostColumn;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AgentTitle(entry: entry, title: title),
            const SizedBox(height: 2),
            Wrap(
              spacing: 4,
              runSpacing: 2,
              children: [
                _MetaText(
                  projectName,
                  key: ValueKey(
                    'agent-row-project-'
                    '${entry.serverId}-${entry.agent.agentId}',
                  ),
                ),
                const _MetaText('·'),
                _MetaText(
                  branch,
                  key: ValueKey(
                    'agent-row-branch-'
                    '${entry.serverId}-${entry.agent.agentId}',
                  ),
                ),
                const _MetaText('·'),
                _MetaText(
                  workspaceName,
                  key: ValueKey(
                    'agent-row-workspace-'
                    '${entry.serverId}-${entry.agent.agentId}',
                  ),
                ),
                const _MetaText('·'),
                _MetaText(time),
                if (showHostColumn) ...[
                  const _MetaText('·'),
                  _MetaText(entry.serverLabel),
                ],
              ],
            ),
          ],
        ),
      ),
      if (showAttentionIndicator && entry.agent.requiresAttention) ...[
        const SizedBox(width: 8),
        const _SessionBadge(label: 'Attention', tone: _BadgeTone.danger),
      ],
    ],
  );
}

class _AgentTitle extends StatelessWidget {
  const _AgentTitle({
    required this.entry,
    required this.title,
    this.workspaceName = '',
    this.showAttention = false,
  });

  final AgentHistoryEntry entry;
  final String title;
  final String workspaceName;
  final bool showAttention;

  @override
  Widget build(BuildContext context) {
    final badges = <Widget>[
      if (entry.agent.archivedAt != null)
        const _SessionBadge(label: 'Archived', icon: FluentIcons.archive),
      if (entry.pendingPermissionCount > 0)
        _SessionBadge(
          label: '${entry.pendingPermissionCount} pending',
          tone: _BadgeTone.warning,
        ),
      if (showAttention)
        const _SessionBadge(label: 'Attention', tone: _BadgeTone.danger),
    ];
    return Row(
      children: [
        if (workspaceName.isNotEmpty) ...[
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                workspaceName,
                key: ValueKey(
                  'agent-row-workspace-'
                  '${entry.serverId}-${entry.agent.agentId}',
                ),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: context.paseoPalette.foregroundMuted,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            FluentIcons.chevron_right,
            size: 12,
            color: context.paseoPalette.foregroundMuted,
          ),
          const SizedBox(width: 8),
        ],
        SizedBox(
          width: 16,
          child: Center(
            child: ProviderIcon(
              provider: entry.agent.provider,
              size: 14,
              color: context.paseoPalette.foregroundMuted,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              color: context.paseoPalette.foreground.withValues(alpha: .86),
            ),
          ),
        ),
        if (badges.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: badges,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _MetaColumn extends StatelessWidget {
  const _MetaColumn({
    super.key,
    required this.text,
    this.width = 132,
    this.right = false,
  });

  final String text;
  final double width;
  final bool right;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: right ? TextAlign.right : TextAlign.left,
        style: TextStyle(
          fontSize: 14,
          color: context.paseoPalette.foregroundMuted,
        ),
      ),
    ),
  );
}

class _MetaText extends StatelessWidget {
  const _MetaText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(fontSize: 14, color: context.paseoPalette.foregroundMuted),
  );
}

enum _BadgeTone { neutral, warning, danger }

class _SessionBadge extends StatelessWidget {
  const _SessionBadge({
    required this.label,
    this.icon,
    this.tone = _BadgeTone.neutral,
  });

  final String label;
  final IconData? icon;
  final _BadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    final (background, foreground) = switch (tone) {
      _BadgeTone.neutral => (palette.surface2, palette.foregroundMuted),
      _BadgeTone.warning => (const Color(0x1FF59E0B), const Color(0xFFF59E0B)),
      _BadgeTone.danger => (const Color(0x24EF4444), const Color(0xFFFCA5A5)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: foreground,
            ),
          ),
        ],
      ),
    );
  }
}
