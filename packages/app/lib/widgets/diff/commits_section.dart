import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme.dart';
import '../../state/changes_preferences_provider.dart';
import '../../state/checkout_commits_provider.dart';
import '../../state/workspace_checkout_status_provider.dart';

class CommitsSection extends ConsumerStatefulWidget {
  const CommitsSection({
    super.key,
    required this.serverId,
    required this.cwd,
    required this.onCommitPress,
  });

  final String serverId;
  final String cwd;
  final ValueChanged<String> onCommitPress;

  @override
  ConsumerState<CommitsSection> createState() => _CommitsSectionState();
}

class _CommitsSectionState extends ConsumerState<CommitsSection> {
  Timer? _clock;
  DateTime _now = DateTime.now();
  CheckoutCommitsListResponse? _lastResponse;

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant CommitsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId != widget.serverId || oldWidget.cwd != widget.cwd) {
      _lastResponse = null;
      _now = DateTime.now();
    }
  }

  void _syncClock(bool expanded) {
    if (!expanded) {
      _clock?.cancel();
      _clock = null;
      return;
    }
    _clock ??= Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(
      checkoutStatusDaemonClientProvider(widget.serverId),
    );
    if (!supportsCheckoutCommits(client)) return const SizedBox.shrink();
    final preferences =
        ref.watch(changesPreferencesProvider).value ??
        const ChangesPreferences();
    final collapsed = preferences.commitsCollapsed;
    _syncClock(!collapsed);
    final key = (serverId: widget.serverId, cwd: widget.cwd);
    final query = collapsed ? null : ref.watch(checkoutCommitsProvider(key));
    final response = query?.value ?? _lastResponse;
    if (query?.value case final loaded?) _lastResponse = loaded;
    final count = response?.commits
        .where((commit) => commit.isOnBase == false)
        .length;

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.paseoPalette.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HoverButton(
            key: const ValueKey('commits-section-header'),
            onPressed: () {
              if (collapsed) {
                setState(() => _now = DateTime.now());
              }
              ref
                  .read(changesPreferencesProvider.notifier)
                  .updatePreferences(commitsCollapsed: !collapsed);
            },
            builder: (context, states) => Semantics(
              button: true,
              child: Container(
                color: states.contains(WidgetState.hovered)
                    ? context.paseoPalette.surfaceSidebarHover
                    : Colors.transparent,
                padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: Center(
                        child: AnimatedRotation(
                          turns: collapsed ? 0 : .25,
                          duration: const Duration(milliseconds: 120),
                          child: const Icon(
                            FluentIcons.chevron_right,
                            size: 10,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text('Commits', style: TextStyle(fontSize: 12)),
                    const SizedBox(width: 8),
                    if (count != null)
                      Semantics(
                        label: '$count workspace commits',
                        child: Text(
                          '$count',
                          style: TextStyle(
                            fontSize: 11,
                            color: context.paseoPalette.foregroundMuted,
                          ),
                        ),
                      ),
                    const Spacer(),
                  ],
                ),
              ),
            ),
          ),
          if (!collapsed) _content(context, query),
        ],
      ),
    );
  }

  Widget _content(
    BuildContext context,
    AsyncValue<CheckoutCommitsListResponse?>? query,
  ) {
    if (query == null || query.isLoading) {
      return const _CommitSkeleton();
    }
    if (query.hasError) {
      return _CommitMessage(
        key: const ValueKey('commits-section-error'),
        message: 'Failed to load commits',
        color: context.paseoPalette.statusDanger,
      );
    }
    final response = query.value;
    if (response == null) return const _CommitSkeleton();
    if (response.error != null) {
      return _CommitMessage(
        key: const ValueKey('commits-section-error'),
        message: 'Failed to load commits',
        color: context.paseoPalette.statusDanger,
      );
    }
    final commits = response.commits
        .where((commit) => commit.isOnBase == false)
        .toList(growable: false);
    if (commits.isEmpty) {
      final base = _normalizeBaseRef(response.baseRef) ?? 'base';
      return _CommitMessage(
        key: const ValueKey('commits-section-no-workspace-commits'),
        message: 'No commits ahead of $base yet',
        color: context.paseoPalette.foregroundMuted,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < commits.length; index++)
            _CommitRow(
              commit: commits[index],
              first: index == 0,
              last: index == commits.length - 1,
              now: _now,
              onPressed: widget.onCommitPress,
            ),
        ],
      ),
    );
  }
}

class _CommitSkeleton extends StatelessWidget {
  const _CommitSkeleton();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading commits…',
    child: Padding(
      key: const ValueKey('commits-section-skeleton'),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: [
          _block(context, 8, 8, circular: true),
          const SizedBox(width: 8),
          _block(context, 48, 10),
          const SizedBox(width: 8),
          Expanded(child: _block(context, double.infinity, 12)),
          const SizedBox(width: 8),
          _block(context, 40, 10),
          const SizedBox(width: 8),
          const SizedBox(width: 16, height: 16),
        ],
      ),
    ),
  );

  Widget _block(
    BuildContext context,
    double width,
    double height, {
    bool circular = false,
  }) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: context.paseoPalette.surface2,
      borderRadius: BorderRadius.circular(circular ? 999 : 3),
    ),
  );
}

class _CommitMessage extends StatelessWidget {
  const _CommitMessage({super.key, required this.message, required this.color});

  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
      child: Text(message, style: TextStyle(fontSize: 11, color: color)),
    ),
  );
}

class _CommitRow extends StatelessWidget {
  const _CommitRow({
    required this.commit,
    required this.first,
    required this.last,
    required this.now,
    required this.onPressed,
  });

  final CheckoutCommit commit;
  final bool first;
  final bool last;
  final DateTime now;
  final ValueChanged<String> onPressed;

  @override
  Widget build(BuildContext context) => HoverButton(
    key: ValueKey('commit-row-${commit.shortSha}'),
    onPressed: () => onPressed(commit.sha),
    builder: (context, states) => Semantics(
      button: true,
      label: '${commit.shortSha} ${commit.subject}',
      child: Container(
        color:
            states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.pressed)
            ? context.paseoPalette.surfaceSidebarHover
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            _CommitGraphNode(commit: commit, first: first, last: last),
            const SizedBox(width: 8),
            SizedBox(
              width: 70,
              child: Text(
                commit.shortSha,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontFamily: 'Cascadia Mono',
                  fontSize: 11,
                  color: context.paseoPalette.foregroundMuted,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                commit.subject,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatCommitTimeAgo(
                DateTime.tryParse(commit.authorDate)?.toLocal() ?? now,
                now,
              ),
              style: TextStyle(
                fontSize: 11,
                color: context.paseoPalette.foregroundMuted,
              ),
            ),
            const SizedBox(width: 8),
            const SizedBox(
              width: 16,
              height: 16,
              child: Center(child: Icon(FluentIcons.chevron_right, size: 10)),
            ),
          ],
        ),
      ),
    ),
  );
}

class _CommitGraphNode extends StatelessWidget {
  const _CommitGraphNode({
    required this.commit,
    required this.first,
    required this.last,
  });

  final CheckoutCommit commit;
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final color = commit.isOnBase == true
        ? context.paseoPalette.foregroundMuted
        : context.paseoPalette.accent;
    return SizedBox(
      width: 8,
      height: 20,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (!(first && last))
            Positioned(
              top: first ? 10 : -5,
              bottom: last ? 10 : -5,
              child: Container(width: 2, color: color),
            ),
          Container(
            key: ValueKey(
              commit.isOnRemote ? 'commit-dot-remote' : 'commit-dot-local',
            ),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: commit.isOnRemote ? color : context.paseoPalette.surface0,
              border: Border.all(color: color, width: 2),
            ),
          ),
        ],
      ),
    );
  }
}

String formatCommitTimeAgo(DateTime date, DateTime now) {
  final difference = now.difference(date);
  final seconds = difference.isNegative ? 0 : difference.inSeconds;
  if (seconds < 10) return 'just now';
  if (seconds < 60) return '${seconds}s ago';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '${minutes}m ago';
  final hours = minutes ~/ 60;
  if (hours < 24) return '${hours}h ago';
  final days = hours ~/ 24;
  if (days < 7) return '${days}d ago';
  return DateFormat('MMM d', 'en_US').format(date);
}

String? _normalizeBaseRef(String? input) {
  final value = input
      ?.trim()
      .replaceFirst(RegExp(r'^refs/remotes/origin/'), '')
      .replaceFirst(RegExp(r'^refs/heads/'), '')
      .replaceFirst(RegExp(r'^origin/'), '');
  return value == null || value.isEmpty ? null : value;
}
