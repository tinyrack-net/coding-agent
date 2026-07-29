import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../core/external_url_launcher.dart';
import '../core/forge.dart';
import '../core/forge_logic.dart';
import '../core/pull_request_activity_state.dart';
import '../core/pull_request_context.dart';
import '../core/theme.dart';
import '../state/daemon_providers.dart';
import '../state/gitlab_pipeline_query.dart';
import '../state/pull_request_provider.dart';
import '../state/workspace_attachments_provider.dart';
import 'fluent/toast.dart';
import 'pull_request_pane_states.dart';
import 'pull_request_section_kit.dart';

class PullRequestPane extends ConsumerStatefulWidget {
  const PullRequestPane({
    super.key,
    required this.cwd,
    @visibleForTesting this.webOverride,
  });

  final String cwd;
  final bool? webOverride;

  @override
  ConsumerState<PullRequestPane> createState() => _PullRequestPaneState();
}

class _PullRequestPaneState extends ConsumerState<PullRequestPane> {
  bool _checksOpen = true;
  bool _activityOpen = true;
  bool _refreshing = false;

  Future<void> _refreshCheckout() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await ref
          .read(pullRequestPaneProvider(widget.cwd).notifier)
          .refreshCheckout();
    } on Object catch (error) {
      if (mounted) {
        AppToast.show(
          context,
          _refreshErrorMessage(error),
          severity: InfoBarSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(pullRequestPaneProvider(widget.cwd));
    final daemonFeatures =
        ref.watch(daemonClientProvider).serverInfo?.features ??
        const <String, bool>{};
    final forgeProvidersEnabled = daemonFeatures['forgeProviders'] == true;
    final canFetchForgeCheckDetails =
        daemonFeatures['forgeCheckDetails'] == true;
    final refreshSupported = daemonFeatures['checkoutRefresh'] == true;
    return ColoredBox(
      color: FluentTheme.of(context).scaffoldBackgroundColor,
      child: async.when(
        loading: () => const PullRequestPaneSkeleton(),
        error: (_, _) => PullRequestPaneError(
          onRetry: () =>
              ref.read(pullRequestPaneProvider(widget.cwd).notifier).refresh(),
        ),
        data: (data) {
          final status = data.status;
          if (status == null) {
            return _PaneMessage(
              icon: FluentIcons.branch_fork2,
              message: data.statusError ?? 'No pull request for this branch',
            );
          }
          final checks = resolvePullRequestChecks(status);
          final gitlabFacts = GitlabMergeFacts.parse(status.forgeSpecific);
          final gitlabPipeline = gitlabFacts == null
              ? null
              : deriveGitlabPipelineSummary(gitlabFacts);
          return ListView(
            children: [
              _Toolbar(
                forge: status.forge,
                onOpen: () => _openExternalUrl(context, ref, status.url),
                refreshSupported: refreshSupported,
                refreshing: _refreshing,
                onRefresh: _refreshCheckout,
              ),
              _PullRequestHeader(
                status: status,
                onOpen: () => _openExternalUrl(context, ref, status.url),
              ),
              if (gitlabPipeline != null && forgeProvidersEnabled)
                _GitLabPipelineSection(
                  key: const ValueKey('gitlab-pipeline'),
                  cwd: widget.cwd,
                  status: status,
                  summary: gitlabPipeline,
                  cacheRevision: data.pipelineCacheRevision,
                  canFetchCheckDetails: canFetchForgeCheckDetails,
                  open: _checksOpen,
                  onToggle: () => setState(() => _checksOpen = !_checksOpen),
                )
              else
                PullRequestSection(
                  title: 'Checks',
                  open: _checksOpen,
                  summary: _CheckSummary(checks: checks),
                  onToggle: () => setState(() => _checksOpen = !_checksOpen),
                  child: _ChecksSection(
                    cwd: widget.cwd,
                    status: status,
                    checks: checks,
                  ),
                ),
              const Divider(),
              PullRequestSection(
                title: 'Activity',
                open: _activityOpen,
                summary: _ActivitySummary(items: data.timeline),
                onToggle: () => setState(() => _activityOpen = !_activityOpen),
                child: _PrActionsPlatformScope(
                  isWeb: widget.webOverride ?? kIsWeb,
                  child: _ActivitySection(
                    cwd: widget.cwd,
                    status: status,
                    items: data.timeline,
                    error: data.timelineError,
                    truncated: data.timelineTruncated,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PrActionsPlatformScope extends InheritedWidget {
  const _PrActionsPlatformScope({required this.isWeb, required super.child});

  final bool isWeb;

  static bool isWebOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_PrActionsPlatformScope>()
          ?.isWeb ??
      kIsWeb;

  @override
  bool updateShouldNotify(_PrActionsPlatformScope oldWidget) =>
      isWeb != oldWidget.isWeb;
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.forge,
    required this.onOpen,
    required this.refreshSupported,
    required this.refreshing,
    required this.onRefresh,
  });

  final String forge;
  final VoidCallback onOpen;
  final bool refreshSupported;
  final bool refreshing;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('pr-pane-toolbar'),
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: context.tokens.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          _ToolbarViewButton(onPressed: onOpen),
          const Spacer(),
          if (refreshSupported)
            _ToolbarRefreshButton(
              forge: forge,
              refreshing: refreshing,
              onPressed: refreshing ? null : onRefresh,
            ),
        ],
      ),
    );
  }
}

class _ToolbarViewButton extends StatelessWidget {
  const _ToolbarViewButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return HoverButton(
      key: const ValueKey('pr-pane-view-pr'),
      semanticLabel: 'View',
      onPressed: onPressed,
      builder: (context, states) {
        final hovered = states.contains(WidgetState.hovered);
        final pressed = states.contains(WidgetState.pressed);
        final color = hovered
            ? context.paseoPalette.foreground
            : context.paseoPalette.foregroundMuted;
        return Opacity(
          opacity: pressed ? .85 : 1,
          child: Container(
            key: const ValueKey('pr-pane-view-pr-content'),
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: Colors.transparent,
              border: Border.all(color: Colors.transparent),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  FluentIcons.open_in_new_window,
                  key: const ValueKey('pr-pane-view-pr-icon'),
                  size: 12,
                  color: color,
                ),
                const SizedBox(width: 4),
                Text('View', style: TextStyle(fontSize: 12, color: color)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ToolbarRefreshButton extends StatelessWidget {
  const _ToolbarRefreshButton({
    required this.forge,
    required this.refreshing,
    required this.onPressed,
  });

  final String forge;
  final bool refreshing;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final brand = getForgeDefinitionOrNeutral(forge.toLowerCase()).displayName;
    final label = refreshing ? 'Refreshing' : 'Refresh git and $brand state';
    return Tooltip(
      message: label,
      child: HoverButton(
        key: const ValueKey('pr-pane-refresh'),
        semanticLabel: label,
        onPressed: onPressed,
        builder: (context, states) {
          final active =
              states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.pressed);
          return Container(
            key: const ValueKey('pr-pane-refresh-content'),
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active
                  ? context.paseoPalette.surface2
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: SizedBox.square(
              key: const ValueKey('pr-pane-refresh-icon-slot'),
              dimension: 16,
              child: Center(
                child: refreshing
                    ? const SizedBox.square(
                        dimension: 14,
                        child: ProgressRing(strokeWidth: 2),
                      )
                    : Icon(
                        FluentIcons.refresh,
                        size: 14,
                        color: context.paseoPalette.foregroundMuted,
                      ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PullRequestHeader extends StatelessWidget {
  const _PullRequestHeader({required this.status, required this.onOpen});

  final CheckoutPrStatus status;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final state = _statePresentation(context, status);
    final gitlabFacts = GitlabMergeFacts.parse(status.forgeSpecific);
    final approvals = gitlabFacts == null
        ? null
        : deriveGitlabApprovals(gitlabFacts);
    final number = status.number?.toInt();
    final repository =
        status.projectPath ??
        [status.repoOwner, status.repoName].whereType<String>().join('/');
    final numberPrefix = getForgeDefinitionOrNeutral(
      status.forge.toLowerCase(),
    ).changeRequestNumberPrefix;
    return Semantics(
      button: true,
      label: 'Open ${status.title}',
      child: HoverButton(
        key: const ValueKey('pr-pane-header'),
        onPressed: onOpen,
        builder: (context, states) {
          final hovered = states.contains(WidgetState.hovered);
          return Padding(
            key: const ValueKey('pr-pane-header-content'),
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
                          text: ' $numberPrefix$number',
                          style: TextStyle(
                            color: context.tokens.onSurfaceVariant,
                          ),
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
                    if (approvals != null) ...[
                      const SizedBox(width: 8),
                      Icon(
                        FluentIcons.completed,
                        key: const ValueKey('pr-pane-approvals-icon'),
                        size: 11,
                        color: approvals.given >= approvals.required
                            ? context.statusColors.success
                            : context.tokens.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${approvals.given} of ${approvals.required} approvals',
                        key: const ValueKey('pr-pane-approvals'),
                        style: TextStyle(
                          fontSize: 10,
                          color: context.tokens.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (repository.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          repository,
                          key: const ValueKey('pr-pane-repository'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: context.tokens.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ] else
                      const Spacer(),
                    const SizedBox(width: 4),
                    Opacity(
                      key: const ValueKey('pr-pane-header-link-icon'),
                      opacity: hovered ? 1 : 0,
                      child: Icon(
                        FluentIcons.open_in_new_window,
                        size: 12,
                        color: context.tokens.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
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
        .where(
          (check) =>
              mapForgeCheckStatus(check.status) == ForgeCheckStatus.success,
        )
        .length;
    final failed = checks
        .where(
          (check) =>
              mapForgeCheckStatus(check.status) == ForgeCheckStatus.failure,
        )
        .length;
    final pending = checks
        .where(
          (check) =>
              mapForgeCheckStatus(check.status) == ForgeCheckStatus.pending,
        )
        .length;
    return PullRequestSectionSummary(
      children: [
        PullRequestSummaryPill(
          key: const ValueKey('pr-pane-check-passed'),
          count: passed,
          variant: PullRequestSummaryVariant.success,
          icon: PullRequestSummaryIcon.check,
        ),
        PullRequestSummaryPill(
          key: const ValueKey('pr-pane-check-failed'),
          count: failed,
          variant: PullRequestSummaryVariant.danger,
          icon: PullRequestSummaryIcon.x,
        ),
        PullRequestSummaryPill(
          key: const ValueKey('pr-pane-check-pending'),
          count: pending,
          variant: PullRequestSummaryVariant.warning,
          icon: PullRequestSummaryIcon.dot,
        ),
      ],
    );
  }
}

class _GitLabPipelineSection extends ConsumerStatefulWidget {
  const _GitLabPipelineSection({
    super.key,
    required this.cwd,
    required this.status,
    required this.summary,
    required this.cacheRevision,
    required this.canFetchCheckDetails,
    required this.open,
    required this.onToggle,
  });

  final String cwd;
  final CheckoutPrStatus status;
  final GitlabPipelineSummary summary;
  final int cacheRevision;
  final bool canFetchCheckDetails;
  final bool open;
  final VoidCallback onToggle;

  @override
  ConsumerState<_GitLabPipelineSection> createState() =>
      _GitLabPipelineSectionState();
}

class _GitLabPipelineSectionState
    extends ConsumerState<_GitLabPipelineSection> {
  CheckoutPipeline? _pipeline;
  Object? _error;
  var _loading = false;
  var _hasResolvedData = false;
  var _isPlaceholderData = false;
  var _generation = 0;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _seedFromCache(preservePrevious: false);
    if (_canFetch) {
      unawaited(_fetch(force: true));
    }
  }

  @override
  void didUpdateWidget(covariant _GitLabPipelineSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identityChanged =
        oldWidget.cwd != widget.cwd ||
        oldWidget.status.number != widget.status.number ||
        oldWidget.summary.id != widget.summary.id;
    if (identityChanged) {
      _pollTimer?.cancel();
      _generation += 1;
      _seedFromCache(preservePrevious: true);
      _error = null;
      _loading = false;
      if (_canFetch) {
        unawaited(_fetch(force: true));
      }
      return;
    }
    if (oldWidget.cacheRevision != widget.cacheRevision) {
      _generation += 1;
      _error = null;
      _loading = false;
      if (_canFetch) unawaited(_fetch());
      return;
    }
    if (!oldWidget.canFetchCheckDetails && widget.canFetchCheckDetails) {
      if (_canFetch) unawaited(_fetch());
    } else if (oldWidget.canFetchCheckDetails && !widget.canFetchCheckDetails) {
      _pollTimer?.cancel();
    }
    if (oldWidget.open != widget.open) {
      if (_canFetch) {
        unawaited(_fetch());
      } else {
        _pollTimer?.cancel();
      }
    }
    if (oldWidget.summary.rawStatus != widget.summary.rawStatus) {
      _schedulePoll();
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetch({bool force = false}) async {
    if (_loading || !_canFetch) return;
    final generation = _generation;
    final status = widget.status;
    final summary = widget.summary;
    final live = isGitlabPipelineActiveStatus(summary.rawStatus);
    setState(() => _loading = !_hasResolvedData);
    try {
      final pipeline = await ref
          .read(pullRequestPaneProvider(widget.cwd).notifier)
          .loadGitlabPipeline(status, summary.id, live: live, force: force);
      if (!mounted || generation != _generation) return;
      setState(() {
        _pipeline = pipeline;
        _hasResolvedData = true;
        _isPlaceholderData = false;
        _error = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        if (_isPlaceholderData) {
          _pipeline = null;
          _hasResolvedData = false;
          _isPlaceholderData = false;
        }
        _error = error;
        _loading = false;
      });
    } finally {
      if (mounted) _schedulePoll();
    }
  }

  void _schedulePoll() {
    _pollTimer?.cancel();
    if (!_canFetch || !isGitlabPipelineActiveStatus(widget.summary.rawStatus)) {
      return;
    }
    _pollTimer = Timer(
      gitlabLivePipelineRefetchInterval,
      () => unawaited(_fetch()),
    );
  }

  void _seedFromCache({required bool preservePrevious}) {
    final snapshot = ref
        .read(pullRequestPaneProvider(widget.cwd).notifier)
        .gitlabPipelineSnapshot(widget.status, widget.summary.id);
    if (snapshot != null) {
      _pipeline = snapshot.pipeline;
      _hasResolvedData = true;
      _isPlaceholderData = false;
      return;
    }
    if (preservePrevious && _hasResolvedData) {
      _isPlaceholderData = true;
      return;
    }
    _pipeline = null;
    _hasResolvedData = false;
    _isPlaceholderData = false;
  }

  bool get _canFetch =>
      widget.open && widget.canFetchCheckDetails && widget.cwd.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final pipeline = _pipeline;
    final counts = countGitlabPipelineJobs(
      pipeline?.stages ?? const <CheckoutPipelineStage>[],
    );
    final showBreakdown =
        !_isPlaceholderData && pipeline != null && counts.total > 0;
    return PullRequestSection(
      title: 'Pipeline',
      open: widget.open,
      summary: PullRequestSectionSummary(
        children: [
          if (showBreakdown) ...[
            PullRequestSummaryPill(
              key: const ValueKey('pr-pane-pipeline-passed'),
              count: counts.passed,
              variant: PullRequestSummaryVariant.success,
              icon: PullRequestSummaryIcon.check,
            ),
            PullRequestSummaryPill(
              key: const ValueKey('pr-pane-pipeline-failed'),
              count: counts.failed,
              variant: PullRequestSummaryVariant.danger,
              icon: PullRequestSummaryIcon.x,
            ),
            PullRequestSummaryPill(
              key: const ValueKey('pr-pane-pipeline-pending'),
              count: counts.pending,
              variant: PullRequestSummaryVariant.warning,
              icon: PullRequestSummaryIcon.dot,
            ),
          ] else
            PullRequestCheckStatusIcon(status: widget.summary.status),
        ],
      ),
      onToggle: widget.onToggle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PipelineLinkRow(
            summary: widget.summary,
            onOpen: widget.summary.url == null
                ? null
                : () => _openExternalUrl(context, ref, widget.summary.url!),
          ),
          if (_loading && !_hasResolvedData)
            const PullRequestEmptyText('Loading pipeline…')
          else if (pipeline != null && pipeline.stages.isEmpty)
            const PullRequestEmptyText('No jobs')
          else if (pipeline != null)
            for (final stage in pipeline.stages)
              _PipelineStageGroup(stage: stage)
          else if (_error != null)
            const PullRequestEmptyText('Could not load pipeline jobs'),
        ],
      ),
    );
  }
}

class _PipelineLinkRow extends StatelessWidget {
  const _PipelineLinkRow({required this.summary, required this.onOpen});

  final GitlabPipelineSummary summary;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return PullRequestCheckRowLayout(
      key: const ValueKey('pr-pane-pipeline-link'),
      status: summary.status,
      name: 'Pipeline #${summary.id}',
      workflow: summary.rawStatus,
      onPressed: onOpen,
      enabled: onOpen != null,
      trailing: summary.url == null
          ? null
          : Icon(
              FluentIcons.open_in_new_window,
              size: 12,
              color: context.paseoPalette.foregroundMuted,
            ),
    );
  }
}

class _PipelineStageGroup extends StatelessWidget {
  const _PipelineStageGroup({required this.stage});

  final CheckoutPipelineStage stage;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              PullRequestCheckStatusIcon(
                status: mapGitlabPipelineStatus(stage.status),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  stage.name.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    letterSpacing: .5,
                    color: context.tokens.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        for (final job in stage.jobs)
          _PipelineJobRow(key: ValueKey('pipeline-job-${job.id}'), job: job),
      ],
    );
  }
}

class _PipelineJobRow extends ConsumerWidget {
  const _PipelineJobRow({super.key, required this.job});

  final CheckoutPipelineJob job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final duration = formatGitlabPipelineDuration(job.durationSeconds);
    return PullRequestCheckRowLayout(
      status: mapGitlabPipelineStatus(job.status),
      name: job.name,
      workflow: job.allowFailure ? 'allowed to fail' : null,
      onPressed: job.url == null
          ? null
          : () => _openExternalUrl(context, ref, job.url!),
      enabled: job.url != null,
      padding: const EdgeInsets.fromLTRB(24, 8, 12, 8),
      trailing: duration.isEmpty ? null : PullRequestCheckDuration(duration),
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
      return const PullRequestEmptyText('No checks');
    }
    return Column(
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
    final trailing = <Widget>[
      if (canAddPullRequestCheckLogsToChat(check))
        _GhostChatButton(
          key: ValueKey(
            'add-check-${check.checkRunId ?? check.workflowRunId ?? check.name}',
          ),
          onPressed: _adding ? null : _addToChat,
          loading: _adding,
          label: _adding ? 'Adding...' : 'Add to chat',
        ),
      if (check.duration case final duration?)
        PullRequestCheckDuration(duration),
    ];
    return PullRequestCheckRowLayout(
      status: mapForgeCheckStatus(check.status),
      name: check.name,
      workflow: check.workflow,
      onPressed: check.url == null
          ? null
          : () => _openExternalUrl(context, ref, check.url!),
      trailing: trailing.isEmpty
          ? null
          : PullRequestCheckTrailing(children: trailing),
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

class _CollapsedReviewAddButton extends StatelessWidget {
  const _CollapsedReviewAddButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: true,
      label: 'Add to chat',
      child: HoverButton(
        onPressed: onPressed,
        builder: (context, states) {
          final hovered = states.contains(WidgetState.hovered);
          final pressed = states.contains(WidgetState.pressed);
          final color = hovered
              ? context.fluentTheme.resources.textFillColorPrimary
              : context.tokens.onSurfaceVariant;
          return Opacity(
            opacity: pressed ? .85 : 1,
            child: Container(
              constraints: const BoxConstraints(minHeight: 20),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: Colors.transparent,
                border: Border.all(color: Colors.transparent),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(FluentIcons.comment_add, size: 12, color: color),
                  const SizedBox(width: 4),
                  Text(
                    'Add to chat',
                    style: TextStyle(fontSize: 10, color: color),
                  ),
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
    return PullRequestSectionSummary(
      children: [
        PullRequestSummaryPill(
          count: approved,
          variant: PullRequestSummaryVariant.success,
          icon: PullRequestSummaryIcon.check,
        ),
        PullRequestSummaryPill(
          count: changes,
          variant: PullRequestSummaryVariant.danger,
          icon: PullRequestSummaryIcon.x,
        ),
        PullRequestSummaryPill(
          count: comments,
          variant: PullRequestSummaryVariant.muted,
          icon: PullRequestSummaryIcon.message,
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
  var _activityState = const PullRequestActivityState();

  int get _prNumber => widget.status.number?.toInt() ?? 0;

  bool _isCollapsed(PullRequestTimelineEntry entry) =>
      _activityState.isCollapsed(prNumber: _prNumber, entry: entry);

  void _toggle(PullRequestTimelineEntry entry) {
    setState(() {
      _activityState = _activityState.toggle(prNumber: _prNumber, entry: entry);
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          widget.error!,
          style: TextStyle(fontSize: 12, color: context.tokens.error),
        ),
      );
    }
    if (widget.items.isEmpty) {
      return const PullRequestEmptyText('No activity yet');
    }
    final entries = buildPullRequestTimeline(widget.items);
    final brandLabel = getForgePresentation(
      widget.status.forge.toLowerCase(),
    ).brandLabel;
    return Column(
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
            brandLabel: brandLabel,
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
    required this.brandLabel,
  });

  final PullRequestTimelineEntry entry;
  final bool collapsed;
  final bool Function(PullRequestTimelineEntry) isNestedCollapsed;
  final ValueChanged<PullRequestTimelineEntry> onToggle;
  final ValueChanged<PullRequestTimelineItem> onAddActivity;
  final ValueChanged<PullRequestThreadEntry> onAddThread;
  final ValueChanged<String> onOpen;
  final String brandLabel;

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
      onOpenUrl: onOpen,
      brandLabel: brandLabel,
    ),
    PullRequestThreadEntry() => _ThreadCard(
      thread: entry as PullRequestThreadEntry,
      collapsed: collapsed,
      onToggle: () => onToggle(entry),
      onAddActivity: onAddActivity,
      onAddThread: () => onAddThread(entry as PullRequestThreadEntry),
      onOpen: onOpen,
      brandLabel: brandLabel,
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
        brandLabel: brandLabel,
      ),
  };
}

class _ActivityAvatar extends StatelessWidget {
  const _ActivityAvatar({required this.item, required this.size});

  final PullRequestTimelineItem item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorHex = derivePullRequestAvatarColor(item.author);
    final fallback = Container(
      key: ValueKey('activity-avatar-fallback-${item.id}'),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Color(0xff000000 | int.parse(colorHex.substring(1), radix: 16)),
        shape: BoxShape.circle,
      ),
      child: Text(
        item.author.isEmpty ? '' : item.author.characters.first.toUpperCase(),
        style: const TextStyle(fontSize: 10, color: Colors.white),
      ),
    );
    final avatarUrl = item.avatarUrl?.trim();
    if (avatarUrl == null || avatarUrl.isEmpty) return fallback;
    return ClipOval(
      child: Image.network(
        avatarUrl,
        key: ValueKey('activity-avatar-image-${item.id}'),
        width: size,
        height: size,
        fit: BoxFit.cover,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }
}

typedef _PrActionsRevealBuilder =
    Widget Function(
      BuildContext context,
      bool actionsVisible,
      ValueChanged<bool> onMenuOpenChanged,
    );

class _PrActionsRevealRegion extends StatefulWidget {
  const _PrActionsRevealRegion({super.key, required this.builder});

  final _PrActionsRevealBuilder builder;

  @override
  State<_PrActionsRevealRegion> createState() => _PrActionsRevealRegionState();
}

class _PrActionsRevealRegionState extends State<_PrActionsRevealRegion> {
  bool _hovered = false;
  bool _menuOpen = false;

  void _setHovered(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
  }

  void _setMenuOpen(bool value) {
    if (_menuOpen == value) return;
    setState(() => _menuOpen = value);
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    final actionsVisible =
        !_PrActionsPlatformScope.isWebOf(context) ||
        compact ||
        _hovered ||
        _menuOpen;
    return MouseRegion(
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: widget.builder(context, actionsVisible, _setMenuOpen),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.item,
    required this.collapsed,
    required this.onToggle,
    required this.onAddToChat,
    required this.onOpen,
    required this.onOpenUrl,
    required this.brandLabel,
    this.embedded = false,
    this.collapsedThreadCount,
    this.actionsVisible,
    this.onMenuOpenChanged,
  });

  final PullRequestTimelineItem item;
  final bool collapsed;
  final VoidCallback onToggle;
  final VoidCallback? onAddToChat;
  final VoidCallback onOpen;
  final ValueChanged<String> onOpenUrl;
  final String brandLabel;
  final bool embedded;
  final int? collapsedThreadCount;
  final bool? actionsVisible;
  final ValueChanged<bool>? onMenuOpenChanged;

  @override
  Widget build(BuildContext context) {
    if (actionsVisible case final visible?) {
      return _buildCard(context, visible, onMenuOpenChanged!);
    }
    return _PrActionsRevealRegion(
      key: ValueKey('activity-reveal-${item.id}'),
      builder: _buildCard,
    );
  }

  Widget _buildCard(
    BuildContext context,
    bool actionsVisible,
    ValueChanged<bool> onMenuOpenChanged,
  ) {
    final eventRow = !embedded && item.body.trim().isEmpty;
    return Container(
      key: eventRow ? ValueKey('activity-event-row-${item.id}') : null,
      margin: embedded
          ? EdgeInsets.zero
          : EdgeInsets.fromLTRB(12, 0, 12, eventRow ? 8 : 12),
      decoration: BoxDecoration(
        border: embedded || eventRow
            ? null
            : Border.all(color: context.tokens.outlineVariant),
        borderRadius: embedded || eventRow ? null : BorderRadius.circular(8),
      ),
      clipBehavior: eventRow ? Clip.none : Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HoverButton(
            key: ValueKey('activity-header-${item.id}'),
            onPressed: item.body.trim().isEmpty ? onOpen : onToggle,
            builder: (context, states) => Container(
              key: ValueKey('activity-header-content-${item.id}'),
              constraints: const BoxConstraints(minHeight: 36),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: states.contains(WidgetState.hovered)
                  ? context.tokens.surfaceContainerHighest
                  : Colors.transparent,
              child: Row(
                children: [
                  _ActivityAvatar(item: item, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            item.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(flex: 2, child: _ActivityVerb(item: item)),
                      ],
                    ),
                  ),
                  Text(
                    formatPullRequestAge(item.createdAt),
                    style: TextStyle(
                      fontSize: 10,
                      color: context.tokens.onSurfaceVariant,
                    ),
                  ),
                  if (collapsed &&
                      collapsedThreadCount != null &&
                      onAddToChat != null) ...[
                    const SizedBox(width: 8),
                    _CollapsedReviewAddButton(
                      key: ValueKey('collapsed-review-add-${item.id}'),
                      onPressed: onAddToChat!,
                    ),
                  ],
                  if (collapsed && collapsedThreadCount != null) ...[
                    const SizedBox(width: 8),
                    Row(
                      key: ValueKey('collapsed-review-thread-count-${item.id}'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          FluentIcons.message,
                          size: 11,
                          color: context.tokens.onSurfaceVariant,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '$collapsedThreadCount',
                          style: TextStyle(
                            fontSize: 10,
                            color: context.tokens.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(width: 2),
                  _ActivityActionsMenu(
                    item: item,
                    brandLabel: brandLabel,
                    onAddToChat: onAddToChat,
                    onOpen: onOpen,
                    visible: actionsVisible,
                    onOpenChanged: onMenuOpenChanged,
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed && item.body.trim().isNotEmpty)
            Padding(
              key: ValueKey('activity-card-body-${item.id}'),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: MarkdownBody(
                data: item.body,
                selectable: true,
                onTapLink: (_, href, _) {
                  if (href != null) onOpenUrl(href);
                },
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(fontSize: 12, height: 1.4),
                  code: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          if (!collapsed && onAddToChat != null)
            Padding(
              key: ValueKey('activity-card-footer-${item.id}'),
              padding: const EdgeInsets.fromLTRB(0, 0, 8, 8),
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

class _ActivityVerb extends StatelessWidget {
  const _ActivityVerb({required this.item});

  final PullRequestTimelineItem item;

  @override
  Widget build(BuildContext context) {
    final presentation = _activityPresentation(context, item);
    final icon = switch (item) {
      PullRequestTimelineReview(
        reviewState: PullRequestTimelineReviewState.approved,
      ) =>
        FluentIcons.status_circle_checkmark,
      PullRequestTimelineReview(
        reviewState: PullRequestTimelineReviewState.changesRequested,
      ) =>
        FluentIcons.status_circle_error_x,
      _ => null,
    };
    final label = Text(
      presentation.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 10, color: presentation.color),
    );
    if (icon == null) return label;
    final glyph = Icon(
      icon,
      key: ValueKey('activity-verb-icon-${item.id}'),
      size: 12,
      color: presentation.color,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 16) {
          return Align(alignment: Alignment.centerLeft, child: glyph);
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            glyph,
            const SizedBox(width: 4),
            Flexible(child: label),
          ],
        );
      },
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
    required this.brandLabel,
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
  final String brandLabel;

  @override
  Widget build(BuildContext context) {
    return _PrActionsRevealRegion(
      key: ValueKey('activity-reveal-${review.id}'),
      builder: _buildCard,
    );
  }

  Widget _buildCard(
    BuildContext context,
    bool actionsVisible,
    ValueChanged<bool> onMenuOpenChanged,
  ) {
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
            onOpenUrl: onOpen,
            brandLabel: brandLabel,
            embedded: true,
            collapsedThreadCount: threads.length,
            actionsVisible: actionsVisible,
            onMenuOpenChanged: onMenuOpenChanged,
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
                  brandLabel: brandLabel,
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
    required this.brandLabel,
    this.nested = false,
  });

  final PullRequestThreadEntry thread;
  final bool collapsed;
  final VoidCallback onToggle;
  final ValueChanged<PullRequestTimelineItem> onAddActivity;
  final VoidCallback onAddThread;
  final ValueChanged<String> onOpen;
  final String brandLabel;
  final bool nested;

  @override
  Widget build(BuildContext context) {
    return _PrActionsRevealRegion(
      key: ValueKey('thread-reveal-${thread.id}'),
      builder: _buildCard,
    );
  }

  Widget _buildCard(
    BuildContext context,
    bool actionsVisible,
    ValueChanged<bool> onMenuOpenChanged,
  ) {
    final root = thread.comments.first;
    final replies = thread.comments.skip(1);
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
              key: ValueKey('thread-header-content-${thread.id}'),
              constraints: const BoxConstraints(minHeight: 36),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                  _ThreadActionsMenu(
                    threadId: thread.id,
                    brandLabel: brandLabel,
                    onOpen: () => onOpen(root.url),
                    visible: actionsVisible,
                    onOpenChanged: onMenuOpenChanged,
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed) ...[
            _ThreadComment(
              comment: root,
              onAddToChat: root.body.trim().isEmpty
                  ? null
                  : () => onAddActivity(root),
              onOpen: () => onOpen(root.url),
              onOpenUrl: onOpen,
              brandLabel: brandLabel,
            ),
            if (replies.isNotEmpty)
              Container(
                key: ValueKey('thread-reply-rail-${thread.id}'),
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Column(
                  children: [
                    for (final reply in replies)
                      Container(
                        key: ValueKey('thread-reply-card-${reply.id}'),
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: FluentTheme.of(context).cardColor,
                          border: Border.all(
                            color: context.tokens.outlineVariant,
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _ThreadComment(
                          comment: reply,
                          showTopBorder: false,
                          onAddToChat: reply.body.trim().isEmpty
                              ? null
                              : () => onAddActivity(reply),
                          onOpen: () => onOpen(reply.url),
                          onOpenUrl: onOpen,
                          brandLabel: brandLabel,
                        ),
                      ),
                  ],
                ),
              ),
            Padding(
              key: ValueKey('thread-footer-${thread.id}'),
              padding: const EdgeInsets.fromLTRB(0, 0, 8, 8),
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
    required this.onOpenUrl,
    required this.brandLabel,
    this.showTopBorder = true,
  });

  final PullRequestTimelineComment comment;
  final VoidCallback? onAddToChat;
  final VoidCallback onOpen;
  final ValueChanged<String> onOpenUrl;
  final String brandLabel;
  final bool showTopBorder;

  @override
  Widget build(BuildContext context) {
    return _PrActionsRevealRegion(
      key: ValueKey('thread-comment-reveal-${comment.id}'),
      builder: _buildComment,
    );
  }

  Widget _buildComment(
    BuildContext context,
    bool actionsVisible,
    ValueChanged<bool> onMenuOpenChanged,
  ) {
    return Container(
      key: ValueKey('thread-comment-${comment.id}'),
      decoration: BoxDecoration(
        border: showTopBorder
            ? Border(top: BorderSide(color: context.tokens.outlineVariant))
            : null,
      ),
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            key: ValueKey('thread-comment-header-${comment.id}'),
            constraints: const BoxConstraints(minHeight: 32),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                _ActivityAvatar(item: comment, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          comment.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(child: _ActivityVerb(item: comment)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatPullRequestAge(comment.createdAt),
                  style: TextStyle(
                    fontSize: 10,
                    color: context.tokens.onSurfaceVariant,
                  ),
                ),
                _ActivityActionsMenu(
                  item: comment,
                  brandLabel: brandLabel,
                  onAddToChat: onAddToChat,
                  onOpen: onOpen,
                  visible: actionsVisible,
                  onOpenChanged: onMenuOpenChanged,
                ),
              ],
            ),
          ),
          if (comment.body.trim().isNotEmpty)
            Padding(
              key: ValueKey('thread-comment-body-${comment.id}'),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: MarkdownBody(
                data: comment.body,
                selectable: true,
                onTapLink: (_, href, _) {
                  if (href != null) onOpenUrl(href);
                },
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(fontSize: 12, height: 1.4),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ActivityActionsMenu extends StatelessWidget {
  const _ActivityActionsMenu({
    required this.item,
    required this.brandLabel,
    required this.onAddToChat,
    required this.onOpen,
    required this.visible,
    required this.onOpenChanged,
  });

  final PullRequestTimelineItem item;
  final String brandLabel;
  final VoidCallback? onAddToChat;
  final VoidCallback onOpen;
  final bool visible;
  final ValueChanged<bool> onOpenChanged;

  @override
  Widget build(BuildContext context) {
    return _PrActionsMenuButton(
      triggerKey: ValueKey('activity-actions-${item.id}'),
      visibilityKey: ValueKey('activity-actions-visibility-${item.id}'),
      semanticLabel: 'Comment actions',
      visible: visible,
      onOpenChanged: onOpenChanged,
      items: [
        if (onAddToChat != null)
          MenuFlyoutItem(
            key: ValueKey('activity-action-add-${item.id}'),
            leading: const Icon(FluentIcons.comment_add, size: 14),
            text: const Text('Add to chat'),
            onPressed: onAddToChat,
          ),
        if (item.body.trim().isNotEmpty)
          MenuFlyoutItem(
            key: ValueKey('activity-action-copy-${item.id}'),
            leading: const Icon(FluentIcons.copy, size: 14),
            text: const Text('Copy'),
            onPressed: () {
              unawaited(Clipboard.setData(ClipboardData(text: item.body)));
            },
          ),
        MenuFlyoutItem(
          key: ValueKey('activity-action-open-${item.id}'),
          leading: const Icon(FluentIcons.open_in_new_window, size: 14),
          text: Text('Open on $brandLabel'),
          onPressed: onOpen,
        ),
      ],
    );
  }
}

class _ThreadActionsMenu extends StatelessWidget {
  const _ThreadActionsMenu({
    required this.threadId,
    required this.brandLabel,
    required this.onOpen,
    required this.visible,
    required this.onOpenChanged,
  });

  final String threadId;
  final String brandLabel;
  final VoidCallback onOpen;
  final bool visible;
  final ValueChanged<bool> onOpenChanged;

  @override
  Widget build(BuildContext context) {
    return _PrActionsMenuButton(
      triggerKey: ValueKey('thread-actions-$threadId'),
      visibilityKey: ValueKey('thread-actions-visibility-$threadId'),
      semanticLabel: 'Thread actions',
      visible: visible,
      onOpenChanged: onOpenChanged,
      items: [
        MenuFlyoutItem(
          key: ValueKey('thread-action-open-$threadId'),
          leading: const Icon(FluentIcons.open_in_new_window, size: 14),
          text: Text('Open on $brandLabel'),
          onPressed: onOpen,
        ),
      ],
    );
  }
}

class _PrActionsMenuButton extends StatefulWidget {
  const _PrActionsMenuButton({
    required this.triggerKey,
    required this.visibilityKey,
    required this.semanticLabel,
    required this.visible,
    required this.onOpenChanged,
    required this.items,
  });

  final Key triggerKey;
  final Key visibilityKey;
  final String semanticLabel;
  final bool visible;
  final ValueChanged<bool> onOpenChanged;
  final List<MenuFlyoutItemBase> items;

  @override
  State<_PrActionsMenuButton> createState() => _PrActionsMenuButtonState();
}

class _PrActionsMenuButtonState extends State<_PrActionsMenuButton> {
  final _controller = FlyoutController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _showMenu() async {
    widget.onOpenChanged(true);
    try {
      await _controller.showFlyout<void>(
        placementMode: FlyoutPlacementMode.bottomRight,
        additionalOffset: 2,
        builder: (context) => MenuFlyout(
          constraints: const BoxConstraints.tightFor(width: 200),
          items: widget.items,
        ),
      );
    } finally {
      if (mounted) widget.onOpenChanged(false);
    }
  }

  void _openMenu() {
    unawaited(_showMenu());
  }

  @override
  Widget build(BuildContext context) {
    return Visibility(
      key: widget.visibilityKey,
      visible: widget.visible,
      maintainState: true,
      maintainAnimation: true,
      maintainSize: true,
      child: Semantics(
        container: true,
        button: true,
        label: widget.semanticLabel,
        child: FlyoutTarget(
          controller: _controller,
          child: HoverButton(
            key: widget.triggerKey,
            onPressed: _openMenu,
            builder: (context, states) => Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: states.contains(WidgetState.hovered)
                    ? context.tokens.surfaceContainerHighest
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(FluentIcons.more_vertical, size: 12),
            ),
          ),
        ),
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

String _refreshErrorMessage(Object error) => switch (error) {
  StateError() => error.message,
  _ => '$error',
};
