/// Port of Paseo 0.2.0's `agent-stream/bottom-anchor-controller.ts`.
///
/// Owns whether the stream viewport is pinned to the bottom. The hard part
/// is that "scroll to the bottom" is not a single action: the content is
/// still growing, rows are still measuring, and history may still be
/// loading, so a scroll can silently land short. The controller therefore
/// treats every anchor attempt as *scroll, then verify next frame*, retrying
/// a bounded number of times, and only gives up sticking when the user
/// deliberately scrolls away.
///
/// Two request sources drive it: route requests (entering or resuming a
/// conversation, deduplicated by request key) and local requests (the
/// jump-to-latest affordance, sending a message). Requests are separate from
/// [BottomAnchorMode] because a request can be blocked for a while — waiting
/// on authoritative history, on a measurable viewport or content, or on
/// post-layout verification — and the blocked reason is observable so the
/// view can keep the affordance honest.
///
/// Upstream ships this as a driver plus a React hook. Only the driver holds
/// behavior; the hook just wires refs and effects to it, so this port
/// provides the driver as a plain class the Flutter viewport widget drives
/// directly. Frame scheduling is injected so tests can advance frames
/// deterministically instead of waiting on real vsync.
library;

/// Whether the viewport is currently pinned to the bottom.
enum BottomAnchorMode { stickyBottom, detached }

/// Why a route-level anchor was requested.
enum BottomAnchorRouteReason { initialEntry, resume }

/// Why a local (in-conversation) anchor was requested.
enum BottomAnchorLocalReason { jumpToBottom, messageSent }

/// The union of both request reasons, as carried on an accepted request.
enum BottomAnchorRequestReason {
  initialEntry,
  resume,
  jumpToBottom,
  messageSent,
}

/// Why an accepted request has not been satisfied yet.
enum BottomAnchorBlockedReason {
  waitingForHistoryReadiness,
  waitingForMeasurableViewport,
  waitingForMeasurableContent,
  waitingForPostLayoutVerification,
}

enum BottomAnchorFrameKind { attempt, verification }

/// What to do when verification finds the viewport did not actually land at
/// the bottom.
enum BottomAnchorRetryDisposition { retryScroll, retryVerify, fail }

final class BottomAnchorRouteRequest {
  const BottomAnchorRouteRequest({
    required this.reason,
    required this.agentId,
    required this.requestKey,
  });

  final BottomAnchorRouteReason reason;
  final String agentId;

  /// Deduplication key: re-applying the same key is a no-op, so a rebuild
  /// that re-delivers the same route request does not re-anchor.
  final String requestKey;
}

final class BottomAnchorLocalRequest {
  const BottomAnchorLocalRequest({required this.reason, required this.agentId});

  final BottomAnchorLocalReason reason;
  final String agentId;
}

final class BottomAnchorRequest {
  const BottomAnchorRequest({
    required this.id,
    required this.agentId,
    required this.reason,
    required this.requestKey,
  });

  final int id;
  final String agentId;
  final BottomAnchorRequestReason reason;
  final String requestKey;
}

/// Everything the controller needs to know about current geometry.
///
/// [viewportMeasuredForKey] and [contentMeasuredForKey] guard against acting
/// on measurements taken for a *different* container: when the viewport is
/// swapped (e.g. history virtualization changes the container), stale
/// measurements must not be treated as current, so they only count when they
/// match [containerKey].
final class ControllerMeasurementState {
  const ControllerMeasurementState({
    required this.containerKey,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.contentHeight,
    required this.offsetY,
    required this.viewportMeasuredForKey,
    required this.contentMeasuredForKey,
  });

  final String containerKey;
  final double viewportWidth;
  final double viewportHeight;
  final double contentHeight;
  final double offsetY;
  final String? viewportMeasuredForKey;
  final String? contentMeasuredForKey;
}

/// One in-flight scroll attempt and its verification bookkeeping.
final class AttemptContext {
  const AttemptContext({
    required this.requestId,
    required this.retries,
    this.confirmationPasses = 0,
    this.startedContentHeight,
    this.startedOffsetY,
    this.startedViewportHeight,
  });

  /// The request this attempt is satisfying, or null for a sticky-mode
  /// re-anchor that no explicit request asked for.
  final int? requestId;
  final int retries;
  final int confirmationPasses;
  final double? startedContentHeight;
  final double? startedOffsetY;
  final double? startedViewportHeight;
}

final class BottomAnchorSnapshot {
  const BottomAnchorSnapshot({
    required this.mode,
    required this.pendingRequest,
    required this.pendingVerification,
    required this.blockedReason,
  });

  final BottomAnchorMode mode;
  final BottomAnchorRequest? pendingRequest;
  final AttemptContext? pendingVerification;
  final BottomAnchorBlockedReason? blockedReason;
}

/// Injected frame scheduling. [schedule] must invoke `callback` after
/// `delayFrames` further frames have elapsed, and return a handle [cancel]
/// accepts.
abstract interface class BottomAnchorFrameScheduler {
  Object schedule({
    required BottomAnchorFrameKind kind,
    required void Function() callback,
    int delayFrames,
  });

  void cancel(Object handle);
}

const maxVerificationRetries = 3;
const _webPartialVirtualizedConfirmationDelayFrames = 1;

/// How far the user must scroll in one gesture for it to count as
/// deliberately leaving the bottom rather than incidental drift.
const userScrollAwayDeltaPx = 24.0;

/// The container key for desktop web's partially-virtualized history. That
/// container mounts rows lazily, so a first successful verification can be
/// invalidated by the very next layout — hence the extra confirmation pass.
const webPartialVirtualizedContainerKey = 'web-partial-virtualized';

/// Blocked reason for a verification pass (which can never itself be
/// "waiting for verification").
BottomAnchorBlockedReason? deriveVerificationBlockedReason({
  required bool isAuthoritativeHistoryReady,
  required ControllerMeasurementState measurementState,
}) {
  if (!isAuthoritativeHistoryReady) {
    return BottomAnchorBlockedReason.waitingForHistoryReadiness;
  }
  if (measurementState.viewportHeight <= 0 ||
      measurementState.viewportMeasuredForKey !=
          measurementState.containerKey) {
    return BottomAnchorBlockedReason.waitingForMeasurableViewport;
  }
  if (measurementState.contentHeight <= 0 ||
      measurementState.contentMeasuredForKey != measurementState.containerKey) {
    return BottomAnchorBlockedReason.waitingForMeasurableContent;
  }
  return null;
}

/// Why [pendingRequest] cannot be satisfied right now, or null when nothing
/// is blocking it (including when there is no request at all).
BottomAnchorBlockedReason? deriveBottomAnchorBlockedReason({
  required BottomAnchorRequest? pendingRequest,
  required bool isAuthoritativeHistoryReady,
  required ControllerMeasurementState measurementState,
  required int? pendingVerificationRequestId,
}) {
  if (pendingRequest == null) return null;
  final verificationBlocked = deriveVerificationBlockedReason(
    isAuthoritativeHistoryReady: isAuthoritativeHistoryReady,
    measurementState: measurementState,
  );
  if (verificationBlocked != null) return verificationBlocked;
  if (pendingVerificationRequestId == pendingRequest.id) {
    return BottomAnchorBlockedReason.waitingForPostLayoutVerification;
  }
  return null;
}

BottomAnchorRetryDisposition deriveRetryDisposition({
  required BottomAnchorMode mode,
  required int retries,
  required BottomAnchorVerificationRetryModeLike verificationRetryMode,
}) {
  if (mode != BottomAnchorMode.stickyBottom ||
      retries >= maxVerificationRetries) {
    return BottomAnchorRetryDisposition.fail;
  }
  return verificationRetryMode.isRecheck
      ? BottomAnchorRetryDisposition.retryVerify
      : BottomAnchorRetryDisposition.retryScroll;
}

/// A local anchor request always sticks, whatever its reason.
BottomAnchorMode deriveModeForLocalRequest(BottomAnchorLocalReason reason) =>
    BottomAnchorMode.stickyBottom;

/// A resize while sticking should re-anchor: the old bottom offset no longer
/// means the bottom. Zero dimensions are ignored as "not measured yet"
/// rather than treated as a real change.
bool shouldRestickOnViewportChange({
  required BottomAnchorMode mode,
  required double previousViewportWidth,
  required double viewportWidth,
  required double previousViewportHeight,
  required double viewportHeight,
}) =>
    mode == BottomAnchorMode.stickyBottom &&
    ((previousViewportHeight > 0 &&
            viewportHeight > 0 &&
            previousViewportHeight != viewportHeight) ||
        (previousViewportWidth > 0 &&
            viewportWidth > 0 &&
            previousViewportWidth != viewportWidth));

/// Content growing while sticking should re-anchor; content shrinking should
/// not, since that cannot push the bottom away from the viewport.
bool shouldRestickOnContentChange({
  required BottomAnchorMode mode,
  required double previousContentHeight,
  required double contentHeight,
}) =>
    mode == BottomAnchorMode.stickyBottom &&
    contentHeight > previousContentHeight;

/// Detach only when the viewport left the bottom for a reason the controller
/// did not cause. An in-flight request or verification means the controller
/// is mid-anchor, and an unverified measurement change means content moved
/// under the viewport — neither should be mistaken for the user scrolling
/// away, unless the scroll was large enough to be unambiguously deliberate.
bool shouldDetachFromScrollAway({
  required BottomAnchorMode mode,
  required bool nextIsNearBottom,
  required double scrollDelta,
  required bool hasPendingRequest,
  required bool hasPendingVerification,
  required bool hasUnverifiedStickyMeasurementChange,
}) {
  final scrolledAwayIntentionally = scrollDelta.abs() >= userScrollAwayDeltaPx;
  return mode == BottomAnchorMode.stickyBottom &&
      !nextIsNearBottom &&
      !hasPendingRequest &&
      !hasPendingVerification &&
      (!hasUnverifiedStickyMeasurementChange || scrolledAwayIntentionally);
}

/// Minimal view of the strategy's retry mode, so this module does not depend
/// on the strategy config just to read one flag.
abstract interface class BottomAnchorVerificationRetryModeLike {
  /// True for `recheck` (verify again without re-scrolling), false for
  /// `rescroll` (scroll again, then verify).
  bool get isRecheck;
}

/// Frame delay and retry mode for one platform's scroll transport.
final class BottomAnchorTransport
    implements BottomAnchorVerificationRetryModeLike {
  const BottomAnchorTransport({
    required this.verificationDelayFrames,
    required this.isRecheck,
  });

  final int verificationDelayFrames;

  @override
  final bool isRecheck;
}

/// Drives bottom anchoring for one conversation viewport.
class BottomAnchorController {
  BottomAnchorController({
    required this.getIsAuthoritativeHistoryReady,
    required this.getTransportBehavior,
    required this.getMeasurementState,
    required this.isNearBottom,
    required this.scrollToBottom,
    required this.onModeChange,
    required this.scheduler,
  });

  final bool Function() getIsAuthoritativeHistoryReady;
  final BottomAnchorTransport Function() getTransportBehavior;
  final ControllerMeasurementState Function() getMeasurementState;
  final bool Function() isNearBottom;
  final void Function(bool animated) scrollToBottom;
  final void Function(BottomAnchorMode mode) onModeChange;
  final BottomAnchorFrameScheduler scheduler;

  int _requestSequence = 0;
  BottomAnchorMode _mode = BottomAnchorMode.stickyBottom;
  BottomAnchorRequest? _pendingRequest;
  AttemptContext? _pendingVerification;
  BottomAnchorBlockedReason? _blockedReason;
  Object? _attemptHandle;
  Object? _verificationHandle;
  String? _lastRouteRequestKey;

  /// Bumped whenever geometry changes under a sticky viewport, and marked
  /// verified once the viewport is confirmed at the bottom again. A
  /// divergence means "content moved and we have not re-confirmed the
  /// bottom yet".
  int _stickyMeasurementRevision = 0;
  int _lastVerifiedStickyMeasurementRevision = 0;
  bool _isUserScrollActive = false;

  BottomAnchorSnapshot get snapshot => BottomAnchorSnapshot(
    mode: _mode,
    pendingRequest: _pendingRequest,
    pendingVerification: _pendingVerification,
    blockedReason: _blockedReason,
  );

  void dispose() => _cancelPendingAttempt();

  void _setMode(BottomAnchorMode nextMode) {
    if (_mode == nextMode) return;
    _mode = nextMode;
    onModeChange(nextMode);
    if (nextMode == BottomAnchorMode.detached) {
      _lastVerifiedStickyMeasurementRevision = _stickyMeasurementRevision;
    }
  }

  void _markStickyMeasurementChanged() => _stickyMeasurementRevision += 1;

  void _markStickyMeasurementVerified() =>
      _lastVerifiedStickyMeasurementRevision = _stickyMeasurementRevision;

  void _cancelPendingAttempt() {
    final attempt = _attemptHandle;
    if (attempt != null) {
      scheduler.cancel(attempt);
      _attemptHandle = null;
    }
    final verification = _verificationHandle;
    if (verification != null) {
      scheduler.cancel(verification);
      _verificationHandle = null;
    }
    _pendingVerification = null;
  }

  void _cancelPendingRequest() {
    _pendingRequest = null;
    _cancelPendingAttempt();
    _blockedReason = null;
  }

  BottomAnchorBlockedReason? _deriveBlockedReason(
    ControllerMeasurementState measurementState,
  ) => deriveBottomAnchorBlockedReason(
    pendingRequest: _pendingRequest,
    isAuthoritativeHistoryReady: getIsAuthoritativeHistoryReady(),
    measurementState: measurementState,
    pendingVerificationRequestId: _verificationHandle != null
        ? _pendingVerification?.requestId
        : null,
  );

  void _scheduleVerification(
    AttemptContext attemptContext, {
    int? delayFramesOverride,
  }) {
    final existing = _verificationHandle;
    if (existing != null) scheduler.cancel(existing);
    _verificationHandle = scheduler.schedule(
      kind: BottomAnchorFrameKind.verification,
      delayFrames:
          delayFramesOverride ?? getTransportBehavior().verificationDelayFrames,
      callback: () => _runVerification(attemptContext),
    );
  }

  void _runVerification(AttemptContext attemptContext) {
    _verificationHandle = null;
    final currentRequest = _pendingRequest;
    final isRequestAttempt =
        currentRequest != null && attemptContext.requestId == currentRequest.id;
    final measurementState = getMeasurementState();
    final verificationBlockedReason = deriveVerificationBlockedReason(
      isAuthoritativeHistoryReady: getIsAuthoritativeHistoryReady(),
      measurementState: measurementState,
    );

    if (verificationBlockedReason != null) {
      _pendingVerification = attemptContext;
      _blockedReason = verificationBlockedReason;
      return;
    }

    if (isNearBottom()) {
      // Desktop web's partially-virtualized container can mount more rows
      // right after a successful landing, so require one confirming pass
      // before considering a route request satisfied.
      if (isRequestAttempt &&
          _shouldRequireRouteRequestConfirmation(
            request: currentRequest,
            measurementState: measurementState,
            confirmationPasses: attemptContext.confirmationPasses,
          )) {
        final next = AttemptContext(
          requestId: attemptContext.requestId,
          retries: attemptContext.retries,
          confirmationPasses: attemptContext.confirmationPasses + 1,
          startedContentHeight: attemptContext.startedContentHeight,
          startedOffsetY: attemptContext.startedOffsetY,
          startedViewportHeight: attemptContext.startedViewportHeight,
        );
        _pendingVerification = next;
        _blockedReason =
            BottomAnchorBlockedReason.waitingForPostLayoutVerification;
        _scheduleVerification(
          next,
          delayFramesOverride: _webPartialVirtualizedConfirmationDelayFrames,
        );
        return;
      }
      _pendingVerification = null;
      _markStickyMeasurementVerified();
      if (isRequestAttempt) _pendingRequest = null;
      _blockedReason = null;
      return;
    }

    final retryDisposition = deriveRetryDisposition(
      mode: _mode,
      retries: attemptContext.retries,
      verificationRetryMode: getTransportBehavior(),
    );

    switch (retryDisposition) {
      case BottomAnchorRetryDisposition.retryVerify:
        final next = AttemptContext(
          requestId: attemptContext.requestId,
          retries: attemptContext.retries + 1,
        );
        _pendingVerification = next;
        _blockedReason =
            BottomAnchorBlockedReason.waitingForPostLayoutVerification;
        _scheduleVerification(next);
      case BottomAnchorRetryDisposition.retryScroll:
        _pendingVerification = AttemptContext(
          requestId: attemptContext.requestId,
          retries: attemptContext.retries + 1,
        );
        _evaluate(animated: false);
      case BottomAnchorRetryDisposition.fail:
        _pendingVerification = null;
        _blockedReason = isRequestAttempt
            ? BottomAnchorBlockedReason.waitingForPostLayoutVerification
            : null;
    }
  }

  bool _shouldRequireRouteRequestConfirmation({
    required BottomAnchorRequest? request,
    required ControllerMeasurementState measurementState,
    required int confirmationPasses,
  }) {
    if (request == null) return false;
    if (request.reason != BottomAnchorRequestReason.initialEntry &&
        request.reason != BottomAnchorRequestReason.resume) {
      return false;
    }
    if (measurementState.containerKey != webPartialVirtualizedContainerKey) {
      return false;
    }
    return confirmationPasses < 1;
  }

  void _runAttempt(bool animated) {
    final measurementState = getMeasurementState();
    final attemptContext = AttemptContext(
      requestId: _pendingRequest?.id,
      retries: _pendingVerification?.retries ?? 0,
      startedContentHeight: measurementState.contentHeight,
      startedOffsetY: measurementState.offsetY,
      startedViewportHeight: measurementState.viewportHeight,
    );
    _pendingVerification = attemptContext;
    scrollToBottom(animated);
    _scheduleVerification(attemptContext);
    _blockedReason = _deriveBlockedReason(getMeasurementState());
  }

  /// Defers the decision to attempt by one frame, so a burst of geometry
  /// changes collapses into a single scroll.
  void _evaluate({required bool animated}) {
    if (_isUserScrollActive) return;
    if (_attemptHandle != null) return;
    _attemptHandle = scheduler.schedule(
      kind: BottomAnchorFrameKind.attempt,
      callback: () {
        _attemptHandle = null;
        final measurementState = getMeasurementState();
        final nextBlockedReason = _deriveBlockedReason(measurementState);
        _blockedReason = nextBlockedReason;

        final shouldAttemptForPendingRequest =
            _pendingRequest != null && nextBlockedReason == null;
        final shouldAttemptForStickyVerification =
            _mode == BottomAnchorMode.stickyBottom &&
            _pendingVerification != null &&
            nextBlockedReason == null;

        if (!shouldAttemptForPendingRequest &&
            !shouldAttemptForStickyVerification) {
          return;
        }
        _runAttempt(animated);
      },
    );
  }

  void _createRequest({
    required String agentId,
    required BottomAnchorRequestReason reason,
    required String? requestKey,
    required BottomAnchorMode mode,
    required bool animated,
  }) {
    _cancelPendingAttempt();
    final id = _requestSequence + 1;
    _requestSequence = id;
    _pendingRequest = BottomAnchorRequest(
      id: id,
      agentId: agentId,
      reason: reason,
      requestKey: requestKey ?? '$agentId:${reason.name}:$id',
    );
    _pendingVerification = null;
    _setMode(mode);
    _evaluate(animated: animated);
  }

  /// Resets all state for a newly-selected conversation.
  void resetForAgent() {
    _lastRouteRequestKey = null;
    _pendingRequest = null;
    _blockedReason = null;
    _cancelPendingAttempt();
    _stickyMeasurementRevision = 0;
    _lastVerifiedStickyMeasurementRevision = 0;
    _isUserScrollActive = false;
    _mode = BottomAnchorMode.stickyBottom;
    onModeChange(BottomAnchorMode.stickyBottom);
  }

  /// Applies a route request, ignoring a repeat of the last request key.
  void applyRouteRequest(BottomAnchorRouteRequest? request) {
    if (request == null) return;
    if (_lastRouteRequestKey == request.requestKey) return;
    _lastRouteRequestKey = request.requestKey;
    _createRequest(
      agentId: request.agentId,
      reason: switch (request.reason) {
        BottomAnchorRouteReason.initialEntry =>
          BottomAnchorRequestReason.initialEntry,
        BottomAnchorRouteReason.resume => BottomAnchorRequestReason.resume,
      },
      requestKey: request.requestKey,
      // A route request always sticks, regardless of the previous mode.
      mode: BottomAnchorMode.stickyBottom,
      animated: false,
    );
  }

  void requestLocalAnchor(BottomAnchorLocalRequest request) {
    _createRequest(
      agentId: request.agentId,
      reason: switch (request.reason) {
        BottomAnchorLocalReason.jumpToBottom =>
          BottomAnchorRequestReason.jumpToBottom,
        BottomAnchorLocalReason.messageSent =>
          BottomAnchorRequestReason.messageSent,
      },
      requestKey: null,
      mode: deriveModeForLocalRequest(request.reason),
      animated: request.reason == BottomAnchorLocalReason.jumpToBottom,
    );
  }

  void beginUserScroll() {
    _isUserScrollActive = true;
    _cancelPendingAttempt();
  }

  void endUserScroll({required bool isNearBottom}) {
    _isUserScrollActive = false;
    if (!isNearBottom) {
      if (_mode == BottomAnchorMode.stickyBottom) detachByUser();
      return;
    }
    if (_mode == BottomAnchorMode.detached) {
      _setMode(BottomAnchorMode.stickyBottom);
      _pendingVerification = const AttemptContext(requestId: null, retries: 0);
      _evaluate(animated: false);
      return;
    }
    if (_pendingRequest != null) {
      _evaluate(animated: false);
      return;
    }
    // The gesture ended near the bottom, but "near" is not "at": re-anchor
    // unless the viewport is genuinely at the bottom with no unverified
    // geometry change.
    if (!this.isNearBottom() ||
        _stickyMeasurementRevision != _lastVerifiedStickyMeasurementRevision) {
      _pendingVerification = const AttemptContext(requestId: null, retries: 0);
      _evaluate(animated: false);
      return;
    }
    _markStickyMeasurementVerified();
  }

  void detachByUser() {
    if (_mode == BottomAnchorMode.detached) return;
    _cancelPendingRequest();
    _setMode(BottomAnchorMode.detached);
  }

  void handleViewportMetricsChange({
    required double previousViewportWidth,
    required double viewportWidth,
    required double previousViewportHeight,
    required double viewportHeight,
  }) {
    if (previousViewportWidth != viewportWidth ||
        previousViewportHeight != viewportHeight) {
      _markStickyMeasurementChanged();
    }
    if (_isUserScrollActive) return;
    final shouldRestick = shouldRestickOnViewportChange(
      mode: _mode,
      previousViewportWidth: previousViewportWidth,
      viewportWidth: viewportWidth,
      previousViewportHeight: previousViewportHeight,
      viewportHeight: viewportHeight,
    );
    if (shouldRestick && _pendingRequest == null) {
      _pendingVerification = const AttemptContext(requestId: null, retries: 0);
    }
    if (shouldRestick || _pendingRequest != null) {
      _evaluate(animated: false);
    }
  }

  void handleContentSizeChange({
    required double previousContentHeight,
    required double contentHeight,
  }) {
    if (previousContentHeight != contentHeight) {
      _markStickyMeasurementChanged();
    }
    if (_isUserScrollActive) return;
    final shouldRestick = shouldRestickOnContentChange(
      mode: _mode,
      previousContentHeight: previousContentHeight,
      contentHeight: contentHeight,
    );
    if (shouldRestick && _pendingRequest == null) {
      // Content just grew under a sticky viewport: re-anchor this frame
      // rather than deferring, so streaming text never visibly drifts away.
      _pendingVerification = const AttemptContext(requestId: null, retries: 0);
      final attempt = _attemptHandle;
      if (attempt != null) {
        scheduler.cancel(attempt);
        _attemptHandle = null;
      }
      _runAttempt(false);
      return;
    }
    if (shouldRestick || _pendingRequest != null) {
      _evaluate(animated: false);
    }
  }

  /// Called just before a known-imminent viewport change while sticking, so
  /// the resulting geometry counts as unverified.
  void prepareForStickyViewportChange() {
    if (_mode != BottomAnchorMode.stickyBottom) return;
    _markStickyMeasurementChanged();
  }

  /// Called just before a known-imminent content change while sticking.
  void prepareForStickyContentChange() {
    if (_mode != BottomAnchorMode.stickyBottom) return;
    _markStickyMeasurementChanged();
    if (_isUserScrollActive) return;
    if (_pendingRequest == null) {
      _pendingVerification = const AttemptContext(requestId: null, retries: 0);
      final attempt = _attemptHandle;
      if (attempt != null) {
        scheduler.cancel(attempt);
        _attemptHandle = null;
      }
      _runAttempt(false);
      return;
    }
    _evaluate(animated: false);
  }

  void handleScrollNearBottomChange({
    required bool nextIsNearBottom,
    required double scrollDelta,
  }) {
    if (_isUserScrollActive) return;
    if (nextIsNearBottom &&
        _mode == BottomAnchorMode.stickyBottom &&
        _stickyMeasurementRevision != _lastVerifiedStickyMeasurementRevision) {
      _markStickyMeasurementVerified();
    }
    final hasUnverifiedStickyMeasurementChange =
        _stickyMeasurementRevision != _lastVerifiedStickyMeasurementRevision;
    if (shouldDetachFromScrollAway(
      mode: _mode,
      nextIsNearBottom: nextIsNearBottom,
      scrollDelta: scrollDelta,
      hasPendingRequest: _pendingRequest != null,
      hasPendingVerification: _pendingVerification != null,
      hasUnverifiedStickyMeasurementChange:
          hasUnverifiedStickyMeasurementChange,
    )) {
      detachByUser();
      return;
    }
    if (_mode == BottomAnchorMode.stickyBottom &&
        !nextIsNearBottom &&
        hasUnverifiedStickyMeasurementChange) {
      if (_pendingRequest == null && _pendingVerification == null) {
        _pendingVerification = const AttemptContext(
          requestId: null,
          retries: 0,
        );
      }
      _evaluate(animated: false);
      return;
    }
    if (nextIsNearBottom && _pendingRequest != null) {
      _evaluate(animated: false);
    }
  }

  /// Retries a blocked anchor once authoritative history may have arrived.
  void notifyAuthoritativeHistoryMaybeChanged() {
    if (_pendingVerification == null && _pendingRequest == null) return;
    _evaluate(animated: false);
  }

  void reevaluate({bool animated = false}) => _evaluate(animated: animated);
}
