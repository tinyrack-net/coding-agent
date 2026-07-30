import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../core/chat_scroll_geometry.dart';
import '../core/desktop/desktop_shell.dart';
import '../core/provider_display.dart';
import '../core/theme.dart';
import '../core/worktree_actions.dart';
import '../state/agent_attention.dart';
import '../state/agents_provider.dart';
import '../state/daemon_providers.dart';
import '../state/provider_subagents_provider.dart';
import '../state/subagents_provider.dart';
import '../state/timeline_provider.dart';
import '../state/tool_call_detail_level_provider.dart';
import '../state/worktree_tabs_provider.dart';
import '../tool_calls/detail_level/tool_call_overview.dart';
import '../tool_calls/detail_level/tool_call_overview_view.dart';
import '../tool_calls/detail_level/tool_call_projection.dart';
import '../workspace/workspace_tab_model.dart';
import '../workspace/workspace_file_open.dart';
import '../widgets/composer.dart';
import '../widgets/fluent/toast.dart';
import '../widgets/subagents_track.dart';
import '../widgets/timeline_item_tile.dart';
import 'agent_screen_sync_state.dart';

const _viewedTimelineUnsubscribeGrace = Duration(seconds: 30);

/// Chat view for one agent: timeline list (auto-stick to bottom) + composer.
/// Chat-only — diff and terminal are sibling top-level tabs at the worktree
/// level (see `WorktreeTabbedPane`), not nested inside an agent's tab.
class AgentChatScreen extends ConsumerStatefulWidget {
  const AgentChatScreen({
    super.key,
    required this.agentId,
    this.serverId = 'local',
    this.isScreenFocused = true,
    this.onOpenWorkspaceFile,
  });

  final String agentId;
  final String serverId;
  final bool isScreenFocused;
  final void Function(WorkspaceFileOpenRequest request)? onOpenWorkspaceFile;

  @override
  ConsumerState<AgentChatScreen> createState() => _AgentChatScreenState();
}

class _AgentChatScreenState extends ConsumerState<AgentChatScreen>
    with WidgetsBindingObserver {
  final _scrollController = ScrollController();
  final _syncMemory = AgentScreenRouteMemory();
  bool _stickToBottom = true;
  bool _hasSeenAttentionState = false;
  bool _lastRequiresAttention = false;
  bool _deferredFocusEntryClear = false;
  bool _attentionClearInFlight = false;
  bool _historyEdgeReady = false;
  bool _loadingOlder = false;
  bool _reconnectToastArmed = false;
  bool _timelineWasVisible = false;
  bool _hasTimelineBeenVisible = false;
  bool _visibilityCatchUpRequired = false;
  bool _visibilityCatchUpScheduled = false;
  bool _visibilityCatchUpPending = false;
  bool _visibilityCatchUpError = false;
  bool _unarchiving = false;
  String? _unarchiveError;
  int _visibilityCatchUpGeneration = 0;
  late bool _isAppVisible;
  AgentSummary? _observedAgent;
  DaemonClient? _observedClient;
  AgentSummary? _lastReadyAgent;
  AppToastHandle? _reconnectToastHandle;
  Timer? _visibilityGraceTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    windowFocusedNotifier.addListener(_onWindowFocusChanged);
    _isAppVisible = _computeAppVisibility();
    _timelineWasVisible = _isAppVisible && widget.isScreenFocused;
    _hasTimelineBeenVisible = _timelineWasVisible;
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _historyEdgeReady = true;
    });
  }

  @override
  void dispose() {
    _visibilityCatchUpGeneration++;
    _visibilityGraceTimer?.cancel();
    _reconnectToastHandle?.dismiss();
    WidgetsBinding.instance.removeObserver(this);
    windowFocusedNotifier.removeListener(_onWindowFocusChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _observeReconnectToast({
    required AgentScreenSyncStatus syncStatus,
    required bool hasRenderedReady,
  }) {
    if (!hasRenderedReady || syncStatus != AgentScreenSyncStatus.reconnecting) {
      if (!_reconnectToastArmed) return;
      _reconnectToastArmed = false;
      final handle = _reconnectToastHandle;
      _reconnectToastHandle = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => handle?.dismiss());
      return;
    }
    if (_reconnectToastArmed) return;
    _reconnectToastArmed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_reconnectToastArmed) return;
      _reconnectToastHandle = AppToast.show(
        context,
        'Reconnecting…',
        key: const ValueKey('agent-reconnecting-toast'),
        duration: null,
      );
    });
  }

  @override
  void deactivate() {
    unawaited(_clearAttentionOnBlur());
    super.deactivate();
  }

  @override
  void didUpdateWidget(covariant AgentChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agentId != widget.agentId ||
        oldWidget.serverId != widget.serverId) {
      _resetVisibilityCatchUpForRoute();
    }
    if (oldWidget.isScreenFocused && !widget.isScreenFocused) {
      unawaited(_clearAttentionOnBlur());
    } else if (!oldWidget.isScreenFocused &&
        widget.isScreenFocused &&
        _isAppVisible) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _clearAttention(AgentAttentionClearTrigger.focusEntry),
      );
    }
    _updateTimelineVisibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _updateAppVisibility();
  }

  bool _computeAppVisibility() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final lifecycleVisible =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    final windowVisible = !isDesktopShell || windowFocusedNotifier.value;
    return lifecycleVisible && windowVisible;
  }

  void _onWindowFocusChanged() => _updateAppVisibility();

  void _updateAppVisibility() {
    final next = _computeAppVisibility();
    if (next == _isAppVisible) return;
    final resumed = !_isAppVisible && next;
    _isAppVisible = next;
    _updateTimelineVisibility();
    if (resumed && mounted && widget.isScreenFocused) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _clearAttention(AgentAttentionClearTrigger.focusEntry),
      );
    }
  }

  void _resetVisibilityCatchUpForRoute() {
    _visibilityCatchUpGeneration++;
    _visibilityGraceTimer?.cancel();
    _visibilityGraceTimer = null;
    _visibilityCatchUpRequired = false;
    _visibilityCatchUpScheduled = false;
    _visibilityCatchUpPending = false;
    _visibilityCatchUpError = false;
    _timelineWasVisible = false;
    _hasTimelineBeenVisible = false;
  }

  void _updateTimelineVisibility() {
    final visible = _isAppVisible && widget.isScreenFocused;
    if (visible == _timelineWasVisible) return;
    _timelineWasVisible = visible;
    if (!visible) {
      _visibilityGraceTimer?.cancel();
      _visibilityGraceTimer = Timer(_viewedTimelineUnsubscribeGrace, () {
        _visibilityGraceTimer = null;
        _visibilityCatchUpRequired = true;
      });
      return;
    }

    final firstVisibleEntry = !_hasTimelineBeenVisible;
    _hasTimelineBeenVisible = true;
    final returnedWithinGrace = _visibilityGraceTimer != null;
    _visibilityGraceTimer?.cancel();
    _visibilityGraceTimer = null;
    if (returnedWithinGrace && !firstVisibleEntry) return;
    if (firstVisibleEntry || _visibilityCatchUpRequired) {
      _visibilityCatchUpRequired = true;
      _scheduleVisibilityCatchUp();
    }
  }

  void _scheduleVisibilityCatchUp() {
    if (_visibilityCatchUpScheduled || !_timelineWasVisible) return;
    _visibilityCatchUpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCatchUpScheduled = false;
      if (!mounted || !_timelineWasVisible || !_visibilityCatchUpRequired) {
        return;
      }
      final client = ref.read(daemonClientProvider);
      final timeline = ref.read(timelineProvider(widget.agentId));
      if (client.currentState != DaemonConnectionState.connected ||
          timeline.loading) {
        return;
      }
      _visibilityCatchUpRequired = false;
      _startVisibilityCatchUp();
    });
  }

  void _startVisibilityCatchUp() {
    if (_visibilityCatchUpPending) return;
    final generation = ++_visibilityCatchUpGeneration;
    setState(() {
      _visibilityCatchUpPending = true;
      _visibilityCatchUpError = false;
    });
    unawaited(() async {
      await ref.read(timelineProvider(widget.agentId).notifier).retry();
      if (!mounted || generation != _visibilityCatchUpGeneration) return;
      final timeline = ref.read(timelineProvider(widget.agentId));
      setState(() {
        _visibilityCatchUpPending = false;
        _visibilityCatchUpError =
            timeline.error != null || timeline.syncError != null;
      });
    }());
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final nearBottom = position.pixels >= position.maxScrollExtent - 80;
    if (nearBottom != _stickToBottom) {
      setState(() => _stickToBottom = nearBottom);
    }
    if (_historyEdgeReady &&
        position.pixels <= 96 &&
        !_loadingOlder &&
        ref.read(timelineProvider(widget.agentId)).hasOlder) {
      unawaited(_loadOlder());
    }
  }

  Future<void> _loadOlder() async {
    if (_loadingOlder || !_scrollController.hasClients) return;
    _loadingOlder = true;
    final beforeExtent = _scrollController.position.maxScrollExtent;
    final beforePixels = _scrollController.position.pixels;
    try {
      final loaded = await ref
          .read(timelineProvider(widget.agentId).notifier)
          .loadOlder();
      if (!loaded || !mounted) {
        if (mounted) {
          final error = ref.read(timelineProvider(widget.agentId)).error;
          if (error != null) {
            AppToast.show(
              context,
              'Failed to load older messages: $error',
              severity: InfoBarSeverity.error,
            );
          }
        }
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final addedExtent =
            _scrollController.position.maxScrollExtent - beforeExtent;
        _scrollController.jumpTo(
          (beforePixels + addedExtent).clamp(
            _scrollController.position.minScrollExtent,
            _scrollController.position.maxScrollExtent,
          ),
        );
      });
    } finally {
      _loadingOlder = false;
    }
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (isChatViewportOverscrolledPastBottom(
      pixels: position.pixels,
      maxScrollExtent: position.maxScrollExtent,
    )) {
      return;
    }
    _scrollController.jumpTo(position.maxScrollExtent);
  }

  void _observeAttention(AgentSummary? agent) {
    if (agent == null) return;
    _observedAgent = agent;
    if (!_hasSeenAttentionState) {
      _hasSeenAttentionState = true;
      _lastRequiresAttention = agent.requiresAttention;
      if (agent.requiresAttention && _isAppVisible && widget.isScreenFocused) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _clearAttention(AgentAttentionClearTrigger.focusEntry),
        );
      }
      return;
    }
    if (!_lastRequiresAttention &&
        agent.requiresAttention &&
        _isAppVisible &&
        widget.isScreenFocused) {
      _deferredFocusEntryClear = true;
    } else if (!agent.requiresAttention) {
      _deferredFocusEntryClear = false;
    }
    _lastRequiresAttention = agent.requiresAttention;
  }

  Future<void> _clearAttention(AgentAttentionClearTrigger trigger) async {
    if (_attentionClearInFlight || !mounted) return;
    final agent = ref.read(agentSummaryProvider(widget.agentId));
    final connected =
        ref.read(daemonClientProvider).currentState ==
        DaemonConnectionState.connected;
    if (!shouldClearAgentAttention(
      agentId: agent?.agentId,
      isConnected: connected,
      requiresAttention: agent?.requiresAttention ?? false,
      attentionReason: agent?.attentionReason,
      trigger: trigger,
      hasDeferredFocusEntryClear: _deferredFocusEntryClear,
    )) {
      return;
    }
    _attentionClearInFlight = true;
    _deferredFocusEntryClear = false;
    try {
      await ref.read(agentActionsProvider).clearAttention(widget.agentId);
    } on Object {
      // Attention clear is acknowledgement bookkeeping and must not block
      // viewing or composing when a connection races away.
    } finally {
      _attentionClearInFlight = false;
    }
  }

  Future<void> _clearAttentionOnBlur() async {
    if (_attentionClearInFlight) return;
    final agent = _observedAgent;
    final client = _observedClient;
    if (agent == null ||
        client == null ||
        !shouldClearAgentAttention(
          agentId: agent.agentId,
          isConnected: client.currentState == DaemonConnectionState.connected,
          requiresAttention: agent.requiresAttention,
          attentionReason: agent.attentionReason,
          trigger: AgentAttentionClearTrigger.agentBlur,
          hasDeferredFocusEntryClear: _deferredFocusEntryClear,
        )) {
      return;
    }
    _attentionClearInFlight = true;
    _deferredFocusEntryClear = false;
    try {
      final response = await client.request(
        MessageTypes.agentAttentionClearRequest,
        {'agentId': agent.agentId},
      );
      if (mounted && response['agent'] is Map<String, Object?>) {
        final cleared = AgentSummary.fromJson(
          response['agent']! as Map<String, Object?>,
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref.read(agentsProvider.notifier).upsert(cleared);
          }
        });
      }
    } on Object {
      // Blur acknowledgement is best effort when navigation races disconnect.
    } finally {
      _attentionClearInFlight = false;
    }
  }

  Future<bool> _confirmSubagent(SubagentConfirmation confirmation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: Text(confirmation.title),
        content: Text(confirmation.message),
        actions: [
          Button(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmation.confirmLabel),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _archiveSubagent(PaseoSubagentRow child) async {
    if (!await _confirmSubagent(resolveArchiveSubagentConfirmation(child))) {
      return;
    }
    try {
      await ref.read(agentActionsProvider).archive(child.id);
    } on Object catch (error) {
      if (mounted) {
        AppToast.show(
          context,
          'Failed to archive subagent: $error',
          severity: InfoBarSeverity.error,
        );
      }
    }
  }

  Future<void> _detachSubagent(PaseoSubagentRow child) async {
    if (!await _confirmSubagent(resolveDetachSubagentConfirmation(child))) {
      return;
    }
    try {
      await ref.read(agentActionsProvider).detach(child.id);
      if (!mounted) return;
      final worktree = resolveWorktreeKey(child.agent);
      ref.read(worktreeTabsProvider(worktree).notifier).focusAgent(child.id);
      ref.read(selectedWorktreeProvider.notifier).select(worktree);
    } on Object catch (error) {
      if (mounted) {
        AppToast.show(
          context,
          'Failed to detach subagent: $error',
          severity: InfoBarSeverity.error,
        );
      }
    }
  }

  Future<void> _handleClientSlashCommand(
    ComposerClientSlashCommand command,
  ) async {
    final agent = ref.read(agentSummaryProvider(widget.agentId));
    if (agent == null) return;
    if (command == ComposerClientSlashCommand.exit) {
      await archiveAgentWithWorktreeConfirm(context, ref, agent);
      return;
    }

    final worktree = resolveWorktreeKey(agent);
    ref
        .read(worktreeTabsProvider(worktree).notifier)
        .focusOpenIntentTarget(
          WorkspaceDraftTabTarget(
            draftId: 'new',
            setup: WorkspaceDraftTabSetup(
              provider: agent.provider,
              cwd: agent.cwd,
              modeId: agent.currentModeId,
              model: agent.model,
              thinkingOptionId: agent.thinkingOptionId,
              featureValues: agent.featureValues,
            ),
          ),
        );
    ref.read(selectedWorktreeProvider.notifier).select(worktree);
    try {
      await ref.read(agentActionsProvider).archive(agent.agentId);
    } on Object catch (error) {
      if (!mounted) return;
      AppToast.show(
        context,
        'Failed to start a fresh draft: $error',
        severity: InfoBarSeverity.error,
      );
    }
  }

  Future<void> _unarchiveAgent() async {
    if (_unarchiving) return;
    setState(() {
      _unarchiving = true;
      _unarchiveError = null;
    });
    try {
      await ref.read(daemonClientProvider).refreshAgent(widget.agentId);
      await ref.read(agentsProvider.notifier).refresh();
      ref.invalidate(timelineProvider(widget.agentId));
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _unarchiveError = error.toString());
    } finally {
      if (mounted) setState(() => _unarchiving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _observedClient = ref.watch(daemonClientProvider);
    final agent = ref.watch(agentSummaryProvider(widget.agentId));
    final archived = agent?.archivedAt != null;
    final timeline = archived
        ? const TimelineState(loading: false)
        : ref.watch(timelineProvider(widget.agentId));
    final connection =
        ref.watch(connectionStateProvider).value ??
        _observedClient!.currentState;
    final routeChanged = _syncMemory.enterRoute(
      '${widget.serverId}:${widget.agentId}',
    );
    if (routeChanged) {
      _lastReadyAgent = null;
    }
    if (timeline.error != null && timeline.epoch == null) {
      _syncMemory.markInitialSyncFailure();
    }
    if (timeline.epoch != null) {
      _syncMemory.markReady();
    }
    if (agent != null && _syncMemory.hasRenderedReady) {
      _lastReadyAgent = agent;
    }
    final mayUseStaleAgent =
        _syncMemory.hasRenderedReady &&
        (connection != DaemonConnectionState.connected ||
            timeline.catchUpPhase != TimelineCatchUpPhase.idle);
    final displayAgent = agent ?? (mayUseStaleAgent ? _lastReadyAgent : null);
    final syncState = resolveAgentScreenSyncState(
      archived: archived,
      connected: connection == DaemonConnectionState.connected,
      catchUpPending:
          timeline.catchUpPhase == TimelineCatchUpPhase.syncing ||
          _visibilityCatchUpPending,
      hasSyncError: timeline.syncError != null || _visibilityCatchUpError,
      optimisticCreate:
          timeline.epoch == null && timeline.pendingUserMessages.isNotEmpty,
      hasHydratedTimeline: timeline.epoch != null,
      visibilityCatchUpPending: _visibilityCatchUpPending,
      hadInitialSyncFailure: _syncMemory.hadInitialSyncFailure,
    );
    final toolCallDetailLevel = ref.watch(toolCallDetailLevelProvider);
    final projectedRows = _projectTimelineRows(
      timeline,
      toolCallDetailLevel,
      isTurnActive:
          displayAgent?.runState == AgentRunState.initializing ||
          displayAgent?.runState == AgentRunState.running ||
          displayAgent?.runState == AgentRunState.awaitingPermission,
    );
    final subagents = ref.watch(subagentsForParentProvider(widget.agentId));
    _observeAttention(agent);
    _observeReconnectToast(
      syncStatus: syncState.status,
      hasRenderedReady: _syncMemory.hasRenderedReady,
    );
    if (_visibilityCatchUpRequired &&
        connection == DaemonConnectionState.connected) {
      _scheduleVisibilityCatchUp();
    }

    // While stuck to bottom, follow new/updated content.
    if (!archived) {
      ref.listen(timelineProvider(widget.agentId), (previous, next) {
        if (_stickToBottom) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _scrollToBottom(),
          );
        }
      });
    }

    return Column(
      children: [
        Container(
          color: context.tokens.surfaceContainerHighest,
          child: ListTile(
            title: Text(
              displayAgent == null || displayAgent.title.isEmpty
                  ? widget.agentId
                  : displayAgent.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: displayAgent == null
                ? null
                : Text(
                    displayAgent.isWorktree
                        ? '${displayAgent.provider} · ${displayAgent.model} · ${displayAgent.mode.name} · ${displayAgent.branch} · ${displayAgent.cwd}'
                        : '${displayAgent.provider} · ${displayAgent.model} · ${displayAgent.mode.name} · ${displayAgent.cwd}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            trailing: Tooltip(
              message: 'Archive agent',
              child: IconButton(
                icon: const Icon(FluentIcons.archive),
                onPressed: agent == null || archived
                    ? null
                    : () =>
                          archiveAgentWithWorktreeConfirm(context, ref, agent),
              ),
            ),
          ),
        ),
        if (subagents.isNotEmpty)
          SubagentsTrack(
            rows: subagents,
            onOpenPaseoSubagent: (child) {
              final worktree = resolveWorktreeKey(child.agent);
              ref
                  .read(worktreeTabsProvider(worktree).notifier)
                  .focusAgent(child.id);
              ref.read(selectedWorktreeProvider.notifier).select(worktree);
            },
            onOpenProviderSubagent: (child) {
              if (agent == null) return;
              ref
                  .read(
                    worktreeTabsProvider(resolveWorktreeKey(agent)).notifier,
                  )
                  .focusProviderSubagent(child.parentAgentId, child.id);
            },
            onArchivePaseoSubagent: (child) {
              unawaited(_archiveSubagent(child));
            },
            onDetachPaseoSubagent: (child) {
              unawaited(_detachSubagent(child));
            },
            onHideFinishedProviderSubagents: () => ref
                .read(providerSubagentsProvider(widget.agentId).notifier)
                .hideFinished(),
          ),
        const Divider(),
        if (archived)
          Expanded(
            child: _ArchivedAgentCallout(
              loading: _unarchiving,
              error: _unarchiveError,
              onUnarchive: _unarchiveAgent,
            ),
          )
        else
          ..._chatChildren(
            context,
            projectedRows,
            timeline,
            syncState,
            timeline.loading,
            timeline.loadingOlder,
          ),
      ],
    );
  }

  List<Widget> _chatChildren(
    BuildContext context,
    List<_ProjectedTimelineRow> rows,
    TimelineState timeline,
    AgentScreenSyncState syncState,
    bool loading,
    bool loadingOlder,
  ) {
    final count = rows.length;
    final isColdOpenFailure =
        timeline.error != null &&
        timeline.epoch == null &&
        count == 0 &&
        !_visibilityCatchUpError;
    final hasRetainedHistory = timeline.epoch != null || count > 0;
    if (isColdOpenFailure) {
      return [
        Expanded(
          child: _TimelineColdOpenFailure(
            message: timeline.error!,
            onRetry: () => unawaited(
              ref.read(timelineProvider(widget.agentId).notifier).retry(),
            ),
          ),
        ),
      ];
    }
    if (loading && count == 0 && !syncState.showsCatchUpOverlay) {
      return const [Expanded(child: Center(child: ProgressRing()))];
    }
    return [
      Expanded(
        child: Stack(
          children: [
            Positioned.fill(
              child: count == 0
                  ? Center(
                      child: Text(
                        'No messages yet. Say something below.',
                        style: TextStyle(color: context.tokens.outline),
                      ),
                    )
                  : Stack(
                      children: [
                        ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          itemCount: count,
                          itemBuilder: (context, index) => _TimelineRow(
                            agentId: widget.agentId,
                            row: rows[index],
                            onOpenWorkspaceFile: widget.onOpenWorkspaceFile,
                          ),
                        ),
                        if (loadingOlder)
                          const Align(
                            alignment: Alignment.topCenter,
                            child: Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: ProgressRing(strokeWidth: 2),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
            if (syncState.showsCatchUpOverlay)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0x33000000),
                  child: Center(
                    child: ProgressRing(key: ValueKey('agent-history-overlay')),
                  ),
                ),
              ),
          ],
        ),
      ),
      if (!_stickToBottom)
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 16, bottom: 4),
            child: Tooltip(
              message: 'Jump to latest',
              child: SizedBox(
                width: 36,
                height: 36,
                child: IconButton(
                  icon: const Icon(FluentIcons.down),
                  onPressed: () {
                    setState(() => _stickToBottom = true);
                    _scrollToBottom();
                  },
                ),
              ),
            ),
          ),
        ),
      if (hasRetainedHistory &&
          syncState.status == AgentScreenSyncStatus.syncError)
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: InfoBar(
            title: Text('Timeline sync failed'),
            severity: InfoBarSeverity.error,
          ),
        ),
      const Divider(),
      Composer(
        agentId: widget.agentId,
        serverId: widget.serverId,
        keyboardActionsEnabled: widget.isScreenFocused,
        onClientSlashCommand: (command) =>
            unawaited(_handleClientSlashCommand(command)),
        onInputFocus: () =>
            unawaited(_clearAttention(AgentAttentionClearTrigger.inputFocus)),
        onPromptSend: () =>
            unawaited(_clearAttention(AgentAttentionClearTrigger.promptSend)),
      ),
    ];
  }
}

class _ArchivedAgentCallout extends StatelessWidget {
  const _ArchivedAgentCallout({
    required this.loading,
    required this.error,
    required this.onUnarchive,
  });

  final bool loading;
  final String? error;
  final VoidCallback onUnarchive;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'This agent is archived',
            key: ValueKey('archived-agent-callout'),
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(
              error!,
              key: const ValueKey('agent-unarchive-error'),
              style: TextStyle(
                color: FluentTheme.of(
                  context,
                ).resources.systemFillColorCritical,
              ),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('agent-unarchive-action'),
            onPressed: loading ? null : onUnarchive,
            child: Text(loading ? 'Unarchiving...' : 'Unarchive'),
          ),
        ],
      ),
    ),
  );
}

class _TimelineColdOpenFailure extends StatelessWidget {
  const _TimelineColdOpenFailure({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: InfoBar(
          title: const Text('Failed to load conversation'),
          content: Text(message),
          severity: InfoBarSeverity.error,
          action: Button(onPressed: onRetry, child: const Text('Retry')),
        ),
      ),
    ),
  );
}

final class _ProjectedTimelineRow {
  const _ProjectedTimelineRow({
    required this.display,
    required this.group,
    required this.isLastInSequence,
  });

  final TimelineDisplayItem display;
  final ToolCallOverviewGroup? group;
  final bool isLastInSequence;
}

List<_ProjectedTimelineRow> _projectTimelineRows(
  TimelineState timeline,
  ToolCallDetailLevel level, {
  required bool isTurnActive,
}) {
  final tailDisplays = timeline.tailDisplayItems;
  final headDisplays = timeline.headDisplayItems;
  final tail = [for (final display in tailDisplays) display.item];
  final head = [for (final display in headDisplays) display.item];
  final projection = projectToolCallDetailLevel(
    level: level,
    tail: tail,
    head: head,
    preparedHistory: prepareToolCallHistory(level, tail),
    isTurnActive: isTurnActive,
  );
  final sourceById = <String, TimelineDisplayItem>{
    for (final display in [...tailDisplays, ...headDisplays])
      display.item.id: display,
  };
  final items = [...projection.tail, ...projection.head];
  return [
    for (var index = 0; index < items.length; index++)
      _ProjectedTimelineRow(
        display: TimelineDisplayItem(
          item: items[index],
          userMessage: sourceById[items[index].id]?.userMessage,
        ),
        group: projection.groupsByHostId[items[index].id],
        isLastInSequence:
            projection.groupsByHostId.containsKey(items[index].id) &&
            (index == items.length - 1 ||
                !projection.groupsByHostId.containsKey(items[index + 1].id)),
      ),
  ];
}

class _TimelineRow extends ConsumerWidget {
  const _TimelineRow({
    required this.agentId,
    required this.row,
    this.onOpenWorkspaceFile,
  });

  final String agentId;
  final _ProjectedTimelineRow row;
  final void Function(WorkspaceFileOpenRequest request)? onOpenWorkspaceFile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agent = ref.watch(agentSummaryProvider(agentId));
    Widget buildTile(TimelineDisplayItem item) => TimelineItemTile(
      key: ValueKey(item.item.id),
      item: item.item,
      userMessage: item.userMessage,
      providerLabel: providerDisplayName(agent?.provider),
      cwd: agent?.cwd,
      onOpenFilePath: onOpenWorkspaceFile == null
          ? null
          : (path) => onOpenWorkspaceFile!(
              WorkspaceFileOpenRequest(
                location: WorkspaceFileLocation(path: path),
                disposition: OpenFileDisposition.main,
              ),
            ),
      onPermissionDecision: (permissionId, decision) async {
        try {
          await ref
              .read(agentActionsProvider)
              .respondPermission(permissionId, decision);
        } catch (e) {
          if (!context.mounted) return;
          AppToast.show(
            context,
            'Failed to respond: $e',
            severity: InfoBarSeverity.error,
          );
        }
      },
    );

    final group = row.group;
    if (group != null) {
      return ToolCallOverviewGroupView(
        key: ValueKey('overview-${group.run.id}'),
        group: group,
        isLastInSequence: row.isLastInSequence,
        children: [
          for (final call in group.run.calls)
            buildTile(TimelineDisplayItem(item: call)),
        ],
      );
    }
    return buildTile(row.display);
  }
}
