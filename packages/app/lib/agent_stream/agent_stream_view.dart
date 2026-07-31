/// Port of the viewport half of Paseo 0.2.0's `agent-stream/view.tsx` and
/// `agent-stream/strategy-web.tsx`.
///
/// Composes the ported pure modules into the actual scrolling surface: the
/// render model segments the timeline, layout resolves each row's neighbors,
/// gap, and footer host, and the bottom-anchor controller decides when to
/// pin the viewport to the newest content.
///
/// Row content stays injected via [rowBuilder] so the chat screen keeps
/// owning tile construction (tool-call overview groups, permission
/// responses, file-open routing) while this widget owns stream geometry.
library;

import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/scheduler.dart';

import '../core/chat_scroll_geometry.dart';
import '../state/timeline_provider.dart';
import 'bottom_anchor_controller.dart';
import 'layout.dart';
import 'render_model.dart';
import 'stream_strategy.dart';

/// Distance from the bottom still considered "at the bottom" for anchoring.
/// Paseo's web strategy uses 64px; the desktop app resolves the web strategy
/// (see [resolveStreamRenderStrategy]).
const streamNearBottomThresholdPx = 64.0;

/// How close to the top of the history the viewport must come before older
/// history is requested.
const streamHistoryStartThresholdPx = 96.0;

/// Flutter's `ListView.builder` virtualizes its own viewport and never swaps
/// containers under the controller, so the measurement container key is
/// constant. Upstream's second key (`web-partial-virtualized`) exists for a
/// DOM container that mounts rows lazily behind a spacer; that container has
/// no Flutter analogue.
const streamViewportContainerKey = 'flutter-scroll-view';

/// Drives [BottomAnchorController] from real frames.
class WidgetsBindingFrameScheduler implements BottomAnchorFrameScheduler {
  final _cancelled = <int>{};
  int _sequence = 0;

  @override
  Object schedule({
    required BottomAnchorFrameKind kind,
    required void Function() callback,
    int delayFrames = 0,
  }) {
    final id = ++_sequence;
    _scheduleFrame(id, callback, delayFrames < 0 ? 0 : delayFrames);
    return id;
  }

  void _scheduleFrame(int id, void Function() callback, int remainingFrames) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_cancelled.remove(id)) return;
      if (remainingFrames > 0) {
        _scheduleFrame(id, callback, remainingFrames - 1);
        return;
      }
      callback();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  @override
  void cancel(Object handle) => _cancelled.add(handle as int);
}

typedef StreamRowBuilder =
    Widget Function(BuildContext context, StreamLayoutItem layoutItem);

class AgentStreamView extends StatefulWidget {
  const AgentStreamView({
    super.key,
    required this.agentId,
    required this.tail,
    required this.head,
    required this.agentStatus,
    required this.rowBuilder,
    required this.isAuthoritativeHistoryReady,
    this.routeAnchorRequest,
    this.onNearHistoryStart,
    this.onAnchorModeChange,
    this.emptyState,
    this.padding = const EdgeInsets.symmetric(vertical: 12),
  });

  final String agentId;

  /// Committed history, already projected for the active tool-call detail
  /// level.
  final List<TimelineDisplayItem> tail;

  /// The live head that has not yet been folded into an authoritative page.
  final List<TimelineDisplayItem> head;

  /// The agent's run state as a Paseo status string; `'running'` suppresses
  /// the auxiliary turn footer and keeps the running turn open.
  final String agentStatus;

  final StreamRowBuilder rowBuilder;

  /// False while the first authoritative page is still loading; blocks
  /// anchoring so the viewport does not pin to a partial history.
  final bool isAuthoritativeHistoryReady;

  final BottomAnchorRouteRequest? routeAnchorRequest;

  /// Invoked when the viewport comes within [streamHistoryStartThresholdPx]
  /// of the top, so the host can page in older history.
  final VoidCallback? onNearHistoryStart;

  final void Function(BottomAnchorMode mode)? onAnchorModeChange;

  /// Rendered when every segment is empty.
  final Widget? emptyState;

  final EdgeInsets padding;

  @override
  State<AgentStreamView> createState() => AgentStreamViewState();
}

class AgentStreamViewState extends State<AgentStreamView> {
  final _scrollController = ScrollController();
  final _scheduler = WidgetsBindingFrameScheduler();
  late final BottomAnchorController _anchorController;
  late final StreamStrategy _strategy;

  double _viewportWidth = 0;
  double _lastViewportHeight = 0;
  double _lastContentHeight = 0;
  bool _hasMeasured = false;
  bool _historyEdgeArmed = false;
  bool _lastNearBottom = true;
  bool _isUserDragging = false;

  @override
  void initState() {
    super.initState();
    // Paseo's desktop app runs its web strategy, so the desktop client
    // resolves the same forward-stream semantics.
    _strategy = resolveStreamRenderStrategy(
      platform: 'web',
      isMobileBreakpoint: false,
    );
    _anchorController = BottomAnchorController(
      getIsAuthoritativeHistoryReady: () => widget.isAuthoritativeHistoryReady,
      getTransportBehavior: () => BottomAnchorTransport(
        verificationDelayFrames:
            _strategy.bottomAnchorTransportBehavior.verificationDelayFrames,
        isRecheck:
            _strategy.bottomAnchorTransportBehavior.verificationRetryMode ==
            BottomAnchorVerificationRetryMode.recheck,
      ),
      getMeasurementState: _measurementState,
      isNearBottom: _isNearBottom,
      scrollToBottom: _scrollToBottom,
      onModeChange: (mode) => widget.onAnchorModeChange?.call(mode),
      scheduler: _scheduler,
    );
    _scrollController.addListener(_onScroll);
    // Arm history paging only after the first frame, so the initial layout
    // at offset zero is not mistaken for the user reaching the top.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) _historyEdgeArmed = true;
    });
    if (widget.routeAnchorRequest != null) {
      _anchorController.applyRouteRequest(widget.routeAnchorRequest);
    }
  }

  @override
  void didUpdateWidget(AgentStreamView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agentId != widget.agentId) {
      _anchorController.resetForAgent();
      _historyEdgeArmed = false;
      _hasMeasured = false;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _historyEdgeArmed = true;
      });
    }
    if (widget.routeAnchorRequest != null) {
      _anchorController.applyRouteRequest(widget.routeAnchorRequest);
    }
    if (oldWidget.isAuthoritativeHistoryReady !=
        widget.isAuthoritativeHistoryReady) {
      _anchorController.notifyAuthoritativeHistoryMaybeChanged();
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _anchorController.dispose();
    super.dispose();
  }

  /// The viewport's scroll controller, exposed so the host can preserve the
  /// visual position while prepending older history.
  ScrollController get scrollController => _scrollController;

  /// Re-anchors after a locally-initiated change, e.g. sending a message.
  void requestLocalAnchor(BottomAnchorLocalReason reason) {
    _anchorController.requestLocalAnchor(
      BottomAnchorLocalRequest(agentId: widget.agentId, reason: reason),
    );
  }

  ControllerMeasurementState _measurementState() {
    if (!_scrollController.hasClients) {
      return ControllerMeasurementState(
        containerKey: streamViewportContainerKey,
        viewportWidth: _viewportWidth,
        viewportHeight: 0,
        contentHeight: 0,
        offsetY: 0,
        viewportMeasuredForKey: null,
        contentMeasuredForKey: null,
      );
    }
    final position = _scrollController.position;
    final viewportHeight = position.viewportDimension;
    final contentHeight = position.maxScrollExtent + viewportHeight;
    return ControllerMeasurementState(
      containerKey: streamViewportContainerKey,
      viewportWidth: _viewportWidth,
      viewportHeight: viewportHeight,
      contentHeight: contentHeight,
      offsetY: position.pixels,
      viewportMeasuredForKey: viewportHeight > 0
          ? streamViewportContainerKey
          : null,
      contentMeasuredForKey: contentHeight > 0
          ? streamViewportContainerKey
          : null,
    );
  }

  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    final state = _measurementState();
    return _strategy.isNearBottom(
      offsetY: state.offsetY,
      threshold: streamNearBottomThresholdPx,
      contentHeight: state.contentHeight,
      viewportHeight: state.viewportHeight,
    );
  }

  void _scrollToBottom(bool animated) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // Not guarded against overscroll: the controller already suppresses
    // anchoring while the user owns the viewport, so any offset past the
    // bottom here is our own overshoot from a shrinking extent estimate
    // (ListView.builder refines it as rows mount) and must be corrected
    // immediately rather than left to settle ballistically.
    if (animated) {
      unawaited(
        _scrollController.animateTo(
          position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        ),
      );
      return;
    }
    _scrollController.jumpTo(position.maxScrollExtent);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // `ListView.builder` refines its extent estimate as rows mount, so an
    // anchor can leave the viewport past the (now smaller) end. A DOM
    // scroller clamps `scrollTop`, so upstream never sees this; Flutter
    // instead settles ballistically, which reads as drift. Snap back —
    // but never while the user owns the viewport.
    if (!_isUserDragging &&
        _anchorController.snapshot.mode == BottomAnchorMode.stickyBottom &&
        isChatViewportOverscrolledPastBottom(
          pixels: position.pixels,
          maxScrollExtent: position.maxScrollExtent,
        )) {
      _scrollController.jumpTo(position.maxScrollExtent);
      return;
    }
    final nearBottom = _isNearBottom();
    final scrollDelta = position.pixels - _lastOffsetY;
    _lastOffsetY = position.pixels;
    if (nearBottom != _lastNearBottom) {
      _lastNearBottom = nearBottom;
    }
    _anchorController.handleScrollNearBottomChange(
      nextIsNearBottom: nearBottom,
      scrollDelta: scrollDelta,
    );
    if (_historyEdgeArmed && position.pixels <= streamHistoryStartThresholdPx) {
      widget.onNearHistoryStart?.call();
    }
  }

  double _lastOffsetY = 0;

  /// Reports post-layout geometry to the controller so a resize or content
  /// growth can re-anchor.
  void _reportGeometry() {
    if (!mounted || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    // `ListView.builder` refines its extent estimate as rows mount, so an
    // anchor can leave the viewport past the (now smaller) end. A DOM
    // scroller clamps `scrollTop`, so upstream never sees this; Flutter
    // instead settles ballistically, which reads as drift. Snap back —
    // but never while the user owns the viewport.
    if (!_isUserDragging &&
        _anchorController.snapshot.mode == BottomAnchorMode.stickyBottom &&
        isChatViewportOverscrolledPastBottom(
          pixels: position.pixels,
          maxScrollExtent: position.maxScrollExtent,
        )) {
      _scrollController.jumpTo(position.maxScrollExtent);
    }
    final state = _measurementState();
    if (state.viewportHeight <= 0 || state.contentHeight <= 0) return;
    final previousViewportHeight = _lastViewportHeight;
    final previousContentHeight = _lastContentHeight;
    _lastViewportHeight = state.viewportHeight;
    _lastContentHeight = state.contentHeight;
    if (!_hasMeasured) {
      _hasMeasured = true;
      _lastOffsetY = state.offsetY;
      _anchorController.reevaluate();
      return;
    }
    if (previousViewportHeight != state.viewportHeight) {
      _anchorController.handleViewportMetricsChange(
        previousViewportWidth: _viewportWidth,
        viewportWidth: _viewportWidth,
        previousViewportHeight: previousViewportHeight,
        viewportHeight: state.viewportHeight,
      );
    }
    if (previousContentHeight != state.contentHeight) {
      _anchorController.handleContentSizeChange(
        previousContentHeight: previousContentHeight,
        contentHeight: state.contentHeight,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = buildAgentStreamRenderModel(
      agentStatus: widget.agentStatus,
      tail: widget.tail,
      head: widget.head,
      platform: StreamRenderPlatform.web,
      isMobileBreakpoint: false,
    );
    final layout = layoutStream(
      strategy: _strategy,
      agentStatus: widget.agentStatus,
      history: model.history,
      liveHead: model.segments.liveHead,
      timingByAssistantId: model.turnTiming.byAssistantId,
    );
    final rows = [...layout.history, ...layout.liveHead];

    SchedulerBinding.instance.addPostFrameCallback((_) => _reportGeometry());

    if (rows.isEmpty) {
      return widget.emptyState ?? const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportWidth = constraints.maxWidth;
        // ScrollMetricsNotification is not a ScrollNotification, so it needs
        // its own listener. It is Flutter's analogue of the ResizeObserver
        // upstream uses: it fires when scroll metrics change *without* the
        // viewport scrolling, which is exactly how a shrinking extent
        // estimate surfaces as rows mount.
        return NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            SchedulerBinding.instance.addPostFrameCallback(
              (_) => _reportGeometry(),
            );
            return false;
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification) {
                if (notification.dragDetails != null) {
                  _isUserDragging = true;
                  _anchorController.beginUserScroll();
                }
              } else if (notification is ScrollEndNotification) {
                _isUserDragging = false;
                _anchorController.endUserScroll(isNearBottom: _isNearBottom());
              }
              return false;
            },
            child: ListView.builder(
              controller: _scrollController,
              padding: widget.padding,
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final layoutItem = rows[index];
                return Padding(
                  key: ValueKey(layoutItem.item.item.id),
                  padding: EdgeInsets.only(bottom: layoutItem.gapBelow),
                  child: widget.rowBuilder(context, layoutItem),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
