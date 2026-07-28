import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/external_url_launcher.dart';
import '../core/pull_request_context.dart';
import '../core/theme.dart';
import '../state/pull_request_provider.dart';
import '../state/workspace_attachments_provider.dart';
import 'fluent/toast.dart';

class PullRequestPane extends ConsumerStatefulWidget {
  const PullRequestPane({super.key, required this.cwd});

  final String cwd;

  @override
  ConsumerState<PullRequestPane> createState() => _PullRequestPaneState();
}

class _PullRequestPaneState extends ConsumerState<PullRequestPane> {
  bool _checksOpen = true;
  bool _activityOpen = true;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(pullRequestPaneProvider(widget.cwd));
    return ColoredBox(
      color: FluentTheme.of(context).scaffoldBackgroundColor,
      child: async.when(
        loading: () => const Center(child: ProgressRing()),
        error: (error, _) => _PaneMessage(
          icon: FluentIcons.error_badge,
          message: 'Failed to load pull request\n$error',
        ),
        data: (data) {
          final status = data.status;
          if (status == null) {
            return _PaneMessage(
              icon: FluentIcons.branch_fork2,
              message: data.statusError ?? 'No pull request for this branch',
            );
          }
          return Column(
            children: [
              _Toolbar(
                url: status.url,
                onOpen: () => _openExternalUrl(context, ref, status.url),
                onRefresh: () => ref
                    .read(pullRequestPaneProvider(widget.cwd).notifier)
                    .refresh(),
              ),
              Expanded(
                child: ListView(
                  children: [
                    _PullRequestHeader(status: status),
                    _SectionHeader(
                      title: 'Checks',
                      open: _checksOpen,
                      summary: _CheckSummary(checks: status.checks),
                      onPressed: () =>
                          setState(() => _checksOpen = !_checksOpen),
                    ),
                    if (_checksOpen)
                      _ChecksSection(
                        cwd: widget.cwd,
                        status: status,
                        checks: status.checks,
                      ),
                    const Divider(),
                    _SectionHeader(
                      title: 'Activity',
                      open: _activityOpen,
                      summary: _ActivitySummary(items: data.timeline),
                      onPressed: () =>
                          setState(() => _activityOpen = !_activityOpen),
                    ),
                    if (_activityOpen)
                      _ActivitySection(
                        cwd: widget.cwd,
                        status: status,
                        items: data.timeline,
                        error: data.timelineError,
                        truncated: data.timelineTruncated,
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.url,
    required this.onOpen,
    required this.onRefresh,
  });

  final String url;
  final VoidCallback onOpen;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: context.tokens.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Tooltip(
            message: url,
            child: Button(
              onPressed: onOpen,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('View'),
                  SizedBox(width: 4),
                  Icon(FluentIcons.open_in_new_window, size: 12),
                ],
              ),
            ),
          ),
          const Spacer(),
          Tooltip(
            message: 'Refresh pull request',
            child: IconButton(
              icon: const Icon(FluentIcons.refresh, size: 14),
              onPressed: onRefresh,
            ),
          ),
        ],
      ),
    );
  }
}

class _PullRequestHeader extends StatelessWidget {
  const _PullRequestHeader({required this.status});

  final CheckoutPrStatus status;

  @override
  Widget build(BuildContext context) {
    final state = _statePresentation(context, status);
    final number = status.number?.toInt();
    final repository =
        status.projectPath ??
        [status.repoOwner, status.repoName].whereType<String>().join('/');
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              text: status.title,
              children: [
                if (number != null)
                  TextSpan(
                    text: ' #$number',
                    style: TextStyle(color: context.tokens.onSurfaceVariant),
                  ),
              ],
            ),
            style: const TextStyle(fontSize: 14, height: 1.55),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(state.icon, size: 14, color: state.color),
              const SizedBox(width: 4),
              Text(
                state.label,
                style: TextStyle(fontSize: 11, color: state.color),
              ),
              if (repository.isNotEmpty) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$repository · ${status.headRefName} → ${status.baseRefName}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: context.tokens.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.open,
    required this.summary,
    required this.onPressed,
  });

  final String title;
  final bool open;
  final Widget summary;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return HoverButton(
      onPressed: onPressed,
      builder: (context, states) => Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        color: states.contains(WidgetState.hovered)
            ? context.tokens.surfaceContainerHighest
            : Colors.transparent,
        child: Row(
          children: [
            Icon(
              open ? FluentIcons.chevron_down : FluentIcons.chevron_right,
              size: 10,
              color: context.tokens.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: context.tokens.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            summary,
          ],
        ),
      ),
    );
  }
}

class _CheckSummary extends StatelessWidget {
  const _CheckSummary({required this.checks});

  final List<CheckoutPrCheck> checks;

  @override
  Widget build(BuildContext context) {
    final passed = checks
        .where((check) => _checkKind(check.status) == 0)
        .length;
    final failed = checks
        .where((check) => _checkKind(check.status) == 2)
        .length;
    final pending = checks.length - passed - failed;
    return Wrap(
      spacing: 4,
      children: [
        if (passed > 0)
          _SummaryPill(
            icon: FluentIcons.completed_solid,
            count: passed,
            color: context.statusColors.success,
          ),
        if (failed > 0)
          _SummaryPill(
            icon: FluentIcons.error_badge,
            count: failed,
            color: context.statusColors.danger,
          ),
        if (pending > 0)
          _SummaryPill(
            icon: FluentIcons.clock,
            count: pending,
            color: context.statusColors.warning,
          ),
      ],
    );
  }
}

class _SummaryPill extends StatelessWidget {
  const _SummaryPill({
    required this.icon,
    required this.count,
    required this.color,
  });

  final IconData icon;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text('$count', style: TextStyle(fontSize: 10, color: color)),
        ],
      ),
    );
  }
}

class _ChecksSection extends StatelessWidget {
  const _ChecksSection({
    required this.cwd,
    required this.status,
    required this.checks,
  });

  final String cwd;
  final CheckoutPrStatus status;
  final List<CheckoutPrCheck> checks;

  @override
  Widget build(BuildContext context) {
    if (checks.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Text('No checks reported', style: TextStyle(fontSize: 12)),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          for (final check in checks)
            _CheckRow(
              key: ValueKey(
                'check-${check.checkRunId ?? check.workflowRunId ?? check.name}',
              ),
              cwd: cwd,
              status: status,
              check: check,
            ),
        ],
      ),
    );
  }
}

class _CheckRow extends ConsumerStatefulWidget {
  const _CheckRow({
    super.key,
    required this.cwd,
    required this.status,
    required this.check,
  });

  final String cwd;
  final CheckoutPrStatus status;
  final CheckoutPrCheck check;

  @override
  ConsumerState<_CheckRow> createState() => _CheckRowState();
}

class _CheckRowState extends ConsumerState<_CheckRow> {
  var _adding = false;

  Future<void> _addToChat() async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      final details = await ref
          .read(pullRequestPaneProvider(widget.cwd).notifier)
          .loadCheckDetails(widget.status, widget.check);
      if (!mounted) return;
      final attachment = buildPullRequestCheckAttachment(
        status: widget.status,
        check: widget.check,
        details: details,
      );
      ref
          .read(workspaceAttachmentsProvider(widget.cwd).notifier)
          .add(attachment);
    } on Object {
      // The check row must recover if formatting or insertion fails.
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final check = widget.check;
    final kind = _checkKind(check.status);
    final (icon, color) = switch (kind) {
      0 => (FluentIcons.completed_solid, context.statusColors.success),
      2 => (FluentIcons.error_badge, context.statusColors.danger),
      _ => (FluentIcons.clock, context.statusColors.warning),
    };
    return HoverButton(
      onPressed: check.url == null
          ? null
          : () => _openExternalUrl(context, ref, check.url!),
      builder: (context, states) => Container(
        constraints: const BoxConstraints(minHeight: 32),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: states.contains(WidgetState.hovered)
            ? context.tokens.surfaceContainerHighest
            : Colors.transparent,
        child: Row(
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    check.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (check.workflow case final workflow?)
                    Text(
                      workflow,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: context.tokens.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (canAddPullRequestCheckLogsToChat(check))
              _GhostChatButton(
                key: ValueKey(
                  'add-check-${check.checkRunId ?? check.workflowRunId ?? check.name}',
                ),
                onPressed: _adding ? null : _addToChat,
                loading: _adding,
                label: _adding ? 'Adding...' : 'Add to chat',
              ),
            if (canAddPullRequestCheckLogsToChat(check))
              const SizedBox(width: 6),
            if (check.duration case final duration?)
              Text(
                duration,
                style: TextStyle(
                  fontSize: 10,
                  color: context.tokens.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GhostChatButton extends StatelessWidget {
  const _GhostChatButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.loading = false,
  });

  final VoidCallback? onPressed;
  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      child: HoverButton(
        onPressed: onPressed,
        builder: (context, states) {
          final hovered = enabled && states.contains(WidgetState.hovered);
          final pressed = enabled && states.contains(WidgetState.pressed);
          final color = hovered
              ? context.fluentTheme.resources.textFillColorPrimary
              : context.tokens.onSurfaceVariant;
          return Opacity(
            opacity: enabled ? (pressed ? .85 : 1) : .5,
            child: Container(
              constraints: const BoxConstraints(minHeight: 28),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.transparent,
                border: Border.all(color: Colors.transparent),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (loading)
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: ProgressRing(strokeWidth: 2, activeColor: color),
                    )
                  else
                    Icon(FluentIcons.message, size: 12, color: color),
                  const SizedBox(width: 8),
                  Text(label, style: TextStyle(fontSize: 11, color: color)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ActivitySummary extends StatelessWidget {
  const _ActivitySummary({required this.items});

  final List<PullRequestTimelineItem> items;

  @override
  Widget build(BuildContext context) {
    final approved = items
        .whereType<PullRequestTimelineReview>()
        .where(
          (item) => item.reviewState == PullRequestTimelineReviewState.approved,
        )
        .length;
    final changes = items
        .whereType<PullRequestTimelineReview>()
        .where(
          (item) =>
              item.reviewState ==
              PullRequestTimelineReviewState.changesRequested,
        )
        .length;
    final comments = items.length - approved - changes;
    return Wrap(
      spacing: 4,
      children: [
        if (approved > 0)
          _SummaryPill(
            icon: FluentIcons.completed_solid,
            count: approved,
            color: context.statusColors.success,
          ),
        if (changes > 0)
          _SummaryPill(
            icon: FluentIcons.error_badge,
            count: changes,
            color: context.statusColors.danger,
          ),
        if (comments > 0)
          _SummaryPill(
            icon: FluentIcons.chat,
            count: comments,
            color: context.tokens.onSurfaceVariant,
          ),
      ],
    );
  }
}

class _ActivitySection extends ConsumerStatefulWidget {
  const _ActivitySection({
    required this.cwd,
    required this.status,
    required this.items,
    required this.error,
    required this.truncated,
  });

  final String cwd;
  final CheckoutPrStatus status;
  final List<PullRequestTimelineItem> items;
  final String? error;
  final bool truncated;

  @override
  ConsumerState<_ActivitySection> createState() => _ActivitySectionState();
}

class _ActivitySectionState extends ConsumerState<_ActivitySection> {
  final _collapsed = <String>{};
  final _expanded = <String>{};

  bool _isCollapsed(PullRequestTimelineEntry entry) {
    if (_collapsed.contains(entry.id)) return true;
    if (_expanded.contains(entry.id)) return false;
    return switch (entry) {
      PullRequestThreadEntry() => entry.collapsedByDefault,
      PullRequestSingleEntry(
        activity: PullRequestTimelineComment(location: final location?),
      ) =>
        location.isResolved == true || location.isOutdated == true,
      _ => false,
    };
  }

  void _toggle(PullRequestTimelineEntry entry) {
    setState(() {
      if (_isCollapsed(entry)) {
        _collapsed.remove(entry.id);
        _expanded.add(entry.id);
      } else {
        _expanded.remove(entry.id);
        _collapsed.add(entry.id);
      }
    });
  }

  void _addActivity(PullRequestTimelineItem activity) {
    final attachment = buildPullRequestActivityAttachment(
      status: widget.status,
      activity: activity,
    );
    if (attachment != null) {
      ref
          .read(workspaceAttachmentsProvider(widget.cwd).notifier)
          .add(attachment);
    }
  }

  void _addThread(PullRequestThreadEntry thread) {
    final attachment = buildPullRequestThreadAttachment(
      status: widget.status,
      thread: thread,
    );
    if (attachment != null) {
      ref
          .read(workspaceAttachmentsProvider(widget.cwd).notifier)
          .add(attachment);
    }
  }

  void _addAll(List<PullRequestTimelineEntry> entries) {
    for (final entry in entries) {
      switch (entry) {
        case PullRequestSingleEntry(activity: final activity):
          _addActivity(activity);
        case PullRequestReviewEntry(
          review: final review,
          threads: final threads,
        ):
          _addActivity(review);
          for (final thread in threads) {
            if (thread.isResolved != true) _addThread(thread);
          }
        case PullRequestThreadEntry():
          if (entry.isResolved != true) _addThread(entry);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.error != null && widget.items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        child: Text(
          widget.error!,
          style: TextStyle(fontSize: 11, color: context.tokens.error),
        ),
      );
    }
    if (widget.items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, 16),
        child: Text('No activity yet', style: TextStyle(fontSize: 12)),
      );
    }
    final entries = buildPullRequestTimeline(widget.items);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(right: 12, bottom: 8),
              child: _GhostChatButton(
                onPressed: () => _addAll(entries),
                label: 'Add all to chat',
              ),
            ),
          ),
          for (final entry in entries)
            _TimelineEntryCard(
              key: ValueKey(entry.id),
              entry: entry,
              collapsed: _isCollapsed(entry),
              isNestedCollapsed: _isCollapsed,
              onToggle: _toggle,
              onAddActivity: _addActivity,
              onAddThread: _addThread,
              onOpen: (url) => _openExternalUrl(context, ref, url),
            ),
          if (widget.truncated)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'Older activity is not shown',
                style: TextStyle(
                  fontSize: 10,
                  color: context.tokens.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TimelineEntryCard extends StatelessWidget {
  const _TimelineEntryCard({
    super.key,
    required this.entry,
    required this.collapsed,
    required this.isNestedCollapsed,
    required this.onToggle,
    required this.onAddActivity,
    required this.onAddThread,
    required this.onOpen,
  });

  final PullRequestTimelineEntry entry;
  final bool collapsed;
  final bool Function(PullRequestTimelineEntry) isNestedCollapsed;
  final ValueChanged<PullRequestTimelineEntry> onToggle;
  final ValueChanged<PullRequestTimelineItem> onAddActivity;
  final ValueChanged<PullRequestThreadEntry> onAddThread;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) => switch (entry) {
    PullRequestSingleEntry(activity: final activity) => _ActivityCard(
      item: activity,
      collapsed: collapsed,
      onToggle: () => onToggle(entry),
      onAddToChat: canAddPullRequestActivityToChat(activity)
          ? () => onAddActivity(activity)
          : null,
      onOpen: () => onOpen(activity.url),
    ),
    PullRequestThreadEntry() => _ThreadCard(
      thread: entry as PullRequestThreadEntry,
      collapsed: collapsed,
      onToggle: () => onToggle(entry),
      onAddActivity: onAddActivity,
      onAddThread: () => onAddThread(entry as PullRequestThreadEntry),
      onOpen: onOpen,
    ),
    PullRequestReviewEntry(review: final review, threads: final threads) =>
      _ReviewCard(
        review: review,
        threads: threads,
        collapsed: collapsed,
        isNestedCollapsed: isNestedCollapsed,
        onToggle: () => onToggle(entry),
        onToggleEntry: onToggle,
        onAddActivity: onAddActivity,
        onAddThread: onAddThread,
        onOpen: onOpen,
      ),
  };
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.item,
    required this.collapsed,
    required this.onToggle,
    required this.onAddToChat,
    required this.onOpen,
    this.embedded = false,
  });

  final PullRequestTimelineItem item;
  final bool collapsed;
  final VoidCallback onToggle;
  final VoidCallback? onAddToChat;
  final VoidCallback onOpen;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final presentation = _activityPresentation(context, item);
    final location = item is PullRequestTimelineComment
        ? (item as PullRequestTimelineComment).location
        : null;
    final initial = item.author.trim().isEmpty
        ? '?'
        : item.author.trim().characters.first.toUpperCase();
    return Container(
      margin: embedded
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        border: embedded
            ? null
            : Border.all(color: context.tokens.outlineVariant),
        borderRadius: embedded ? null : BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HoverButton(
            onPressed: item.body.trim().isEmpty ? onOpen : onToggle,
            builder: (context, states) => Container(
              constraints: const BoxConstraints(minHeight: 36),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              color: states.contains(WidgetState.hovered)
                  ? context.tokens.surfaceContainerHighest
                  : Colors.transparent,
              child: Row(
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: context.tokens.primary,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      initial,
                      style: const TextStyle(fontSize: 10, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      item.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    presentation.label,
                    style: TextStyle(fontSize: 10, color: presentation.color),
                  ),
                  const Spacer(),
                  Text(
                    formatPullRequestAge(item.createdAt),
                    style: TextStyle(
                      fontSize: 10,
                      color: context.tokens.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    key: ValueKey('open-activity-${item.id}'),
                    icon: const Icon(FluentIcons.open_in_new_window, size: 10),
                    onPressed: onOpen,
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed && location != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              color: context.tokens.surfaceContainerHighest,
              child: Text(
                formatPullRequestActivityLocation(location),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
              ),
            ),
          if (!collapsed && item.body.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: MarkdownBody(
                data: item.body,
                selectable: true,
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(fontSize: 12, height: 1.4),
                  code: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          if (!collapsed && onAddToChat != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 8, 8),
              child: _GhostChatButton(
                onPressed: onAddToChat,
                label: 'Add to chat',
              ),
            ),
        ],
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({
    required this.review,
    required this.threads,
    required this.collapsed,
    required this.isNestedCollapsed,
    required this.onToggle,
    required this.onToggleEntry,
    required this.onAddActivity,
    required this.onAddThread,
    required this.onOpen,
  });

  final PullRequestTimelineReview review;
  final List<PullRequestThreadEntry> threads;
  final bool collapsed;
  final bool Function(PullRequestTimelineEntry) isNestedCollapsed;
  final VoidCallback onToggle;
  final ValueChanged<PullRequestTimelineEntry> onToggleEntry;
  final ValueChanged<PullRequestTimelineItem> onAddActivity;
  final ValueChanged<PullRequestThreadEntry> onAddThread;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        border: Border.all(color: context.tokens.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _ActivityCard(
            item: review,
            collapsed: collapsed,
            onToggle: onToggle,
            onAddToChat: canAddPullRequestActivityToChat(review)
                ? () => onAddActivity(review)
                : null,
            onOpen: () => onOpen(review.url),
            embedded: true,
          ),
          if (!collapsed)
            for (final thread in threads)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                child: _ThreadCard(
                  thread: thread,
                  collapsed: isNestedCollapsed(thread),
                  onToggle: () => onToggleEntry(thread),
                  onAddActivity: onAddActivity,
                  onAddThread: () => onAddThread(thread),
                  onOpen: onOpen,
                  nested: true,
                ),
              ),
        ],
      ),
    );
  }
}

class _ThreadCard extends StatelessWidget {
  const _ThreadCard({
    required this.thread,
    required this.collapsed,
    required this.onToggle,
    required this.onAddActivity,
    required this.onAddThread,
    required this.onOpen,
    this.nested = false,
  });

  final PullRequestThreadEntry thread;
  final bool collapsed;
  final VoidCallback onToggle;
  final ValueChanged<PullRequestTimelineItem> onAddActivity;
  final VoidCallback onAddThread;
  final ValueChanged<String> onOpen;
  final bool nested;

  @override
  Widget build(BuildContext context) {
    final root = thread.comments.first;
    return Container(
      margin: nested
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(12, 0, 12, 12),
      decoration: BoxDecoration(
        border: Border.all(color: context.tokens.outlineVariant),
        borderRadius: BorderRadius.circular(nested ? 6 : 8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HoverButton(
            onPressed: onToggle,
            builder: (context, states) => Container(
              constraints: const BoxConstraints(minHeight: 36),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              color: states.contains(WidgetState.hovered)
                  ? context.tokens.surfaceContainerHighest
                  : FluentTheme.of(context).cardColor,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      thread.location == null
                          ? 'Discussion thread'
                          : formatPullRequestThreadPath(thread.location!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                      ),
                    ),
                  ),
                  if (thread.isResolved == true)
                    const _ThreadBadge(label: 'Resolved', success: true),
                  if (thread.location?.isOutdated == true)
                    const _ThreadBadge(label: 'Outdated'),
                  if (collapsed) ...[
                    const SizedBox(width: 6),
                    const Icon(FluentIcons.message, size: 10),
                    const SizedBox(width: 3),
                    Text(
                      '${thread.comments.length}',
                      style: TextStyle(
                        fontSize: 10,
                        color: context.tokens.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'Open on forge',
                    child: IconButton(
                      icon: const Icon(
                        FluentIcons.open_in_new_window,
                        size: 11,
                      ),
                      onPressed: () => onOpen(root.url),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed) ...[
            for (final comment in thread.comments)
              _ThreadComment(
                comment: comment,
                onAddToChat: comment.body.trim().isEmpty
                    ? null
                    : () => onAddActivity(comment),
                onOpen: () => onOpen(comment.url),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 8, 8),
              child: _GhostChatButton(
                onPressed: onAddThread,
                label: 'Add to chat',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ThreadComment extends StatelessWidget {
  const _ThreadComment({
    required this.comment,
    required this.onAddToChat,
    required this.onOpen,
  });

  final PullRequestTimelineComment comment;
  final VoidCallback? onAddToChat;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.tokens.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  comment.author,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              Text(
                formatPullRequestAge(comment.createdAt),
                style: TextStyle(
                  fontSize: 10,
                  color: context.tokens.onSurfaceVariant,
                ),
              ),
              IconButton(
                icon: const Icon(FluentIcons.open_in_new_window, size: 10),
                onPressed: onOpen,
              ),
            ],
          ),
          if (comment.body.trim().isNotEmpty)
            MarkdownBody(
              data: comment.body,
              selectable: true,
              styleSheet: MarkdownStyleSheet(
                p: const TextStyle(fontSize: 12, height: 1.4),
              ),
            ),
          if (onAddToChat != null)
            _GhostChatButton(onPressed: onAddToChat, label: 'Add to chat'),
        ],
      ),
    );
  }
}

class _ThreadBadge extends StatelessWidget {
  const _ThreadBadge({required this.label, this.success = false});

  final String label;
  final bool success;

  @override
  Widget build(BuildContext context) {
    final color = success
        ? context.statusColors.success
        : context.tokens.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.only(left: 5),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: TextStyle(fontSize: 9, color: color)),
    );
  }
}

class _PaneMessage extends StatelessWidget {
  const _PaneMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: context.tokens.onSurfaceVariant),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: context.tokens.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

({IconData icon, Color color, String label}) _statePresentation(
  BuildContext context,
  CheckoutPrStatus status,
) {
  if (status.isMerged) {
    return (
      icon: FluentIcons.branch_merge,
      color: const Color(0xffa371f7),
      label: 'Merged',
    );
  }
  if (status.isDraft) {
    return (
      icon: FluentIcons.branch_fork2,
      color: context.tokens.onSurfaceVariant,
      label: 'Draft',
    );
  }
  if (status.state.toUpperCase() == 'OPEN') {
    return (
      icon: FluentIcons.branch_fork2,
      color: context.statusColors.success,
      label: 'Open',
    );
  }
  return (
    icon: FluentIcons.branch_fork2,
    color: context.statusColors.danger,
    label: 'Closed',
  );
}

({Color color, String label}) _activityPresentation(
  BuildContext context,
  PullRequestTimelineItem item,
) {
  if (item case PullRequestTimelineReview(
    reviewState: PullRequestTimelineReviewState.approved,
  )) {
    return (color: context.statusColors.success, label: 'approved');
  }
  if (item case PullRequestTimelineReview(
    reviewState: PullRequestTimelineReviewState.changesRequested,
  )) {
    return (color: context.statusColors.danger, label: 'requested changes');
  }
  if (item is PullRequestTimelineReview) {
    return (color: context.tokens.onSurfaceVariant, label: 'reviewed');
  }
  return (color: context.tokens.onSurfaceVariant, label: 'commented');
}

Future<void> _openExternalUrl(
  BuildContext context,
  WidgetRef ref,
  String url,
) async {
  try {
    final opened = await ref.read(externalUrlLauncherProvider).open(url);
    if (!opened && context.mounted) {
      AppToast.show(
        context,
        'Unable to open link',
        severity: InfoBarSeverity.error,
      );
    }
  } catch (error) {
    if (!context.mounted) return;
    AppToast.show(
      context,
      'Unable to open link: $error',
      severity: InfoBarSeverity.error,
    );
  }
}

int _checkKind(String status) => switch (status.toLowerCase()) {
  'success' || 'passed' || 'completed' => 0,
  'failure' || 'failed' || 'error' || 'cancelled' || 'timed_out' => 2,
  _ => 1,
};
