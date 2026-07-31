// Port of Paseo's `agent-stream/bottom-anchor-controller.test.ts`.
import 'package:coding_agent_app/agent_stream/bottom_anchor_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mutable stand-in for the measurement snapshot the viewport supplies.
class MeasurementContext {
  MeasurementContext({
    this.containerKey = 'scroll-view',
    this.viewportWidth = 0,
    this.viewportHeight = 0,
    this.contentHeight = 0,
    this.offsetY = 0,
    this.viewportMeasuredForKey,
    this.contentMeasuredForKey,
  });

  String containerKey;
  double viewportWidth;
  double viewportHeight;
  double contentHeight;
  double offsetY;
  String? viewportMeasuredForKey;
  String? contentMeasuredForKey;

  ControllerMeasurementState get state => ControllerMeasurementState(
    containerKey: containerKey,
    viewportWidth: viewportWidth,
    viewportHeight: viewportHeight,
    contentHeight: contentHeight,
    offsetY: offsetY,
    viewportMeasuredForKey: viewportMeasuredForKey,
    contentMeasuredForKey: contentMeasuredForKey,
  );
}

MeasurementContext measuredContext() => MeasurementContext(
  viewportWidth: 800,
  viewportHeight: 480,
  contentHeight: 1200,
  viewportMeasuredForKey: 'scroll-view',
  contentMeasuredForKey: 'scroll-view',
);

class _ScheduledTask {
  _ScheduledTask({required this.remainingFrames, required this.callback});

  bool cancelled = false;
  int remainingFrames;
  final void Function() callback;
}

/// Deterministic frame scheduler: tests advance frames explicitly instead of
/// waiting on real vsync.
class FakeFrameScheduler implements BottomAnchorFrameScheduler {
  int _sequence = 0;
  final _tasks = <int, _ScheduledTask>{};

  @override
  Object schedule({
    required BottomAnchorFrameKind kind,
    required void Function() callback,
    int delayFrames = 0,
  }) {
    final id = ++_sequence;
    _tasks[id] = _ScheduledTask(
      remainingFrames: delayFrames < 0 ? 0 : delayFrames,
      callback: callback,
    );
    return id;
  }

  @override
  void cancel(Object handle) {
    _tasks[handle as int]?.cancelled = true;
  }

  void flushFrame() {
    final due = <void Function()>[];
    for (final entry in _tasks.entries.toList()) {
      final task = entry.value;
      if (task.cancelled) {
        _tasks.remove(entry.key);
        continue;
      }
      if (task.remainingFrames > 0) {
        task.remainingFrames -= 1;
        continue;
      }
      _tasks.remove(entry.key);
      due.add(task.callback);
    }
    for (final callback in due) {
      callback();
    }
  }

  void flushAll({int limit = 20}) {
    for (var index = 0; index < limit && _tasks.isNotEmpty; index += 1) {
      flushFrame();
    }
  }
}

class Harness {
  Harness({
    BottomAnchorTransport? transportBehavior,
    bool isNearBottom = true,
    MeasurementContext? measurement,
    this.authoritativeReady = true,
  }) : measurement = measurement ?? measuredContext(),
       nearBottom = isNearBottom,
       transport =
           transportBehavior ??
           const BottomAnchorTransport(
             verificationDelayFrames: 0,
             isRecheck: false,
           ) {
    scrollToBottomBehavior = () {
      nearBottom = true;
      this.measurement.offsetY = 720;
    };
    controller = BottomAnchorController(
      getIsAuthoritativeHistoryReady: () => authoritativeReady,
      getTransportBehavior: () => transport,
      getMeasurementState: () => this.measurement.state,
      isNearBottom: () => nearBottom,
      scrollToBottom: (animated) {
        scrollAttempts.add(animated);
        scrollToBottomBehavior();
      },
      onModeChange: modeChanges.add,
      scheduler: scheduler,
    );
  }

  final MeasurementContext measurement;
  bool nearBottom;
  bool authoritativeReady;
  BottomAnchorTransport transport;
  final scheduler = FakeFrameScheduler();
  final scrollAttempts = <bool>[];
  final modeChanges = <BottomAnchorMode>[];
  late void Function() scrollToBottomBehavior;
  late final BottomAnchorController controller;
}

const _nativeTransport = BottomAnchorTransport(
  verificationDelayFrames: 2,
  isRecheck: true,
);

void main() {
  group('deriveBottomAnchorBlockedReason', () {
    const pendingRequest = BottomAnchorRequest(
      id: 1,
      agentId: 'agent-1',
      reason: BottomAnchorRequestReason.initialEntry,
      requestKey: 'route:agent-1',
    );

    test('keeps initial-entry pending until history is ready and geometry is '
        'measurable', () {
      expect(
        deriveBottomAnchorBlockedReason(
          pendingRequest: pendingRequest,
          isAuthoritativeHistoryReady: false,
          measurementState: MeasurementContext().state,
          pendingVerificationRequestId: null,
        ),
        BottomAnchorBlockedReason.waitingForHistoryReadiness,
      );

      expect(
        deriveBottomAnchorBlockedReason(
          pendingRequest: pendingRequest,
          isAuthoritativeHistoryReady: true,
          measurementState: MeasurementContext(
            viewportHeight: 480,
            viewportMeasuredForKey: 'scroll-view',
          ).state,
          pendingVerificationRequestId: null,
        ),
        BottomAnchorBlockedReason.waitingForMeasurableContent,
      );

      expect(
        deriveBottomAnchorBlockedReason(
          pendingRequest: pendingRequest,
          isAuthoritativeHistoryReady: true,
          measurementState: MeasurementContext(
            viewportHeight: 480,
            contentHeight: 1200,
            viewportMeasuredForKey: 'scroll-view',
            contentMeasuredForKey: 'scroll-view',
          ).state,
          pendingVerificationRequestId: pendingRequest.id,
        ),
        BottomAnchorBlockedReason.waitingForPostLayoutVerification,
      );
    });

    test('reports no blocked reason without a pending request', () {
      expect(
        deriveBottomAnchorBlockedReason(
          pendingRequest: null,
          isAuthoritativeHistoryReady: false,
          measurementState: MeasurementContext().state,
          pendingVerificationRequestId: null,
        ),
        isNull,
      );
    });
  });

  group('bottom anchor controller driver', () {
    test('keeps initial-entry pending until authoritative history and current '
        'geometry exist', () {
      final harness = Harness(
        authoritativeReady: false,
        measurement: MeasurementContext(),
      );

      harness.controller.applyRouteRequest(
        const BottomAnchorRouteRequest(
          agentId: 'agent-1',
          reason: BottomAnchorRouteReason.initialEntry,
          requestKey: 'route:agent-1:initial-entry',
        ),
      );
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, isEmpty);
      var snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.stickyBottom);
      expect(
        snapshot.blockedReason,
        BottomAnchorBlockedReason.waitingForHistoryReadiness,
      );
      expect(
        snapshot.pendingRequest?.reason,
        BottomAnchorRequestReason.initialEntry,
      );

      harness
        ..authoritativeReady = true
        ..nearBottom = true;
      harness.measurement
        ..viewportHeight = 480
        ..contentHeight = 1200
        ..viewportMeasuredForKey = 'scroll-view'
        ..contentMeasuredForKey = 'scroll-view';
      harness.controller
        ..notifyAuthoritativeHistoryMaybeChanged()
        ..reevaluate();
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, hasLength(1));
      snapshot = harness.controller.snapshot;
      expect(snapshot.pendingRequest, isNull);
      expect(snapshot.blockedReason, isNull);
    });

    test('preserves a blocked route anchor while a user scroll ends at the '
        'bottom', () {
      final harness = Harness(authoritativeReady: false);

      harness.controller.applyRouteRequest(
        const BottomAnchorRouteRequest(
          agentId: 'agent-1',
          reason: BottomAnchorRouteReason.initialEntry,
          requestKey: 'route:agent-1:initial-entry',
        ),
      );
      harness.scheduler.flushAll();

      harness.controller.beginUserScroll();
      harness.authoritativeReady = true;
      harness.controller
        ..notifyAuthoritativeHistoryMaybeChanged()
        ..reevaluate();
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, isEmpty);

      harness.controller.endUserScroll(isNearBottom: true);
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, hasLength(1));
      final snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.stickyBottom);
      expect(snapshot.blockedReason, isNull);
      expect(snapshot.pendingRequest, isNull);
      expect(snapshot.pendingVerification, isNull);
    });

    test('preserves a blocked route anchor when layout moves after drag '
        'release', () {
      final harness = Harness(authoritativeReady: false);

      harness.controller.applyRouteRequest(
        const BottomAnchorRouteRequest(
          agentId: 'agent-1',
          reason: BottomAnchorRouteReason.resume,
          requestKey: 'route:agent-1:resume',
        ),
      );
      harness.scheduler.flushAll();

      harness.controller.beginUserScroll();
      harness.nearBottom = false;
      harness.controller.handleScrollNearBottomChange(
        nextIsNearBottom: false,
        scrollDelta: 0,
      );
      harness.authoritativeReady = true;
      harness.controller
        ..notifyAuthoritativeHistoryMaybeChanged()
        ..endUserScroll(isNearBottom: true);
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, hasLength(1));
      final snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.stickyBottom);
      expect(snapshot.blockedReason, isNull);
      expect(snapshot.pendingRequest, isNull);
      expect(snapshot.pendingVerification, isNull);
    });

    test('lets a user scroll away supersede a blocked route anchor', () {
      final harness = Harness(authoritativeReady: false);

      harness.controller.applyRouteRequest(
        const BottomAnchorRouteRequest(
          agentId: 'agent-1',
          reason: BottomAnchorRouteReason.resume,
          requestKey: 'route:agent-1:resume',
        ),
      );
      harness.scheduler.flushAll();

      harness.controller.beginUserScroll();
      harness.nearBottom = false;
      harness.controller
        ..handleScrollNearBottomChange(nextIsNearBottom: false, scrollDelta: 48)
        ..endUserScroll(isNearBottom: false);
      harness.authoritativeReady = true;
      harness.controller
        ..notifyAuthoritativeHistoryMaybeChanged()
        ..reevaluate();
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, isEmpty);
      final snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.detached);
      expect(snapshot.blockedReason, isNull);
      expect(snapshot.pendingRequest, isNull);
      expect(snapshot.pendingVerification, isNull);
    });

    test('suppresses sticky maintenance while detached', () {
      final harness = Harness();

      harness.controller
        ..detachByUser()
        ..handleContentSizeChange(
          previousContentHeight: 1200,
          contentHeight: 1500,
        )
        ..handleViewportMetricsChange(
          previousViewportWidth: 800,
          viewportWidth: 640,
          previousViewportHeight: 480,
          viewportHeight: 420,
        );
      harness.scheduler.flushAll();

      expect(harness.controller.snapshot.mode, BottomAnchorMode.detached);
      expect(harness.scrollAttempts, isEmpty);
    });

    test('pauses sticky maintenance while a user scroll owns the viewport', () {
      final harness = Harness(transportBehavior: _nativeTransport);

      harness.controller
        ..prepareForStickyContentChange()
        ..beginUserScroll()
        ..handleContentSizeChange(
          previousContentHeight: 1200,
          contentHeight: 1400,
        );
      harness.nearBottom = false;
      harness.controller.handleScrollNearBottomChange(
        nextIsNearBottom: false,
        scrollDelta: 1,
      );
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, hasLength(1));
      var snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.stickyBottom);
      expect(snapshot.pendingRequest, isNull);
      expect(snapshot.pendingVerification, isNull);

      harness.controller.endUserScroll(isNearBottom: false);

      snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.detached);
    });

    test('restores sticky maintenance when a user scroll returns to the '
        'bottom', () {
      final harness = Harness(transportBehavior: _nativeTransport);

      harness.controller.beginUserScroll();
      harness.nearBottom = false;
      harness.controller
        ..handleScrollNearBottomChange(nextIsNearBottom: false, scrollDelta: 48)
        ..handleContentSizeChange(
          previousContentHeight: 1200,
          contentHeight: 1400,
        );
      harness.nearBottom = true;
      harness.controller
        ..handleScrollNearBottomChange(nextIsNearBottom: true, scrollDelta: -48)
        ..endUserScroll(isNearBottom: true);
      harness.scheduler.flushAll();

      final snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.stickyBottom);
      expect(snapshot.pendingRequest, isNull);
      expect(snapshot.pendingVerification, isNull);
      expect(harness.scrollAttempts, hasLength(1));
    });

    test('switches back to sticky-bottom for explicit jump-to-bottom', () {
      final harness = Harness(isNearBottom: false);

      harness.controller
        ..detachByUser()
        ..requestLocalAnchor(
          const BottomAnchorLocalRequest(
            agentId: 'agent-1',
            reason: BottomAnchorLocalReason.jumpToBottom,
          ),
        );
      harness.scheduler.flushAll();

      expect(harness.modeChanges, contains(BottomAnchorMode.detached));
      expect(harness.modeChanges, contains(BottomAnchorMode.stickyBottom));
      expect(harness.scrollAttempts, hasLength(1));
      // jump-to-bottom is the one animated anchor.
      expect(harness.scrollAttempts.single, isTrue);
      expect(harness.controller.snapshot.mode, BottomAnchorMode.stickyBottom);
    });

    test('schedules sticky maintenance on viewport and content growth', () {
      final harness = Harness();

      harness.controller.handleViewportMetricsChange(
        previousViewportWidth: 800,
        viewportWidth: 640,
        previousViewportHeight: 480,
        viewportHeight: 420,
      );
      harness.scheduler.flushAll();

      harness.controller.handleContentSizeChange(
        previousContentHeight: 1200,
        contentHeight: 1600,
      );
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, hasLength(2));
    });

    test('keeps a pending request blocked when stale container measurements '
        'arrive', () {
      final harness = Harness(
        measurement: MeasurementContext(
          containerKey: webPartialVirtualizedContainerKey,
          viewportHeight: 420,
          contentHeight: 1200,
          viewportMeasuredForKey: 'scroll-view',
          contentMeasuredForKey: 'scroll-view',
        ),
      );

      harness.controller.applyRouteRequest(
        const BottomAnchorRouteRequest(
          agentId: 'agent-1',
          reason: BottomAnchorRouteReason.resume,
          requestKey: 'route:agent-1:resume',
        ),
      );
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, isEmpty);
      var snapshot = harness.controller.snapshot;
      expect(
        snapshot.blockedReason,
        BottomAnchorBlockedReason.waitingForMeasurableViewport,
      );
      expect(snapshot.pendingRequest?.reason, BottomAnchorRequestReason.resume);

      harness.measurement
        ..viewportMeasuredForKey = webPartialVirtualizedContainerKey
        ..contentMeasuredForKey = webPartialVirtualizedContainerKey;
      harness.controller.reevaluate();
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, hasLength(1));
      snapshot = harness.controller.snapshot;
      expect(snapshot.pendingRequest, isNull);
    });

    test('uses delayed rechecks instead of repeated rescroll loops for native '
        'transport', () {
      final harness = Harness(
        transportBehavior: _nativeTransport,
        isNearBottom: false,
      );
      harness.scrollToBottomBehavior = () {
        harness.measurement.offsetY = 0;
      };

      harness.controller.requestLocalAnchor(
        const BottomAnchorLocalRequest(
          agentId: 'agent-1',
          reason: BottomAnchorLocalReason.jumpToBottom,
        ),
      );

      harness.scheduler.flushFrame();
      expect(harness.scrollAttempts, hasLength(1));

      harness.scheduler
        ..flushFrame()
        ..flushFrame();
      expect(harness.scrollAttempts, hasLength(1));

      harness.nearBottom = true;
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, hasLength(1));
      expect(harness.controller.snapshot.pendingRequest, isNull);
    });

    test('does not stay blocked on post-layout verification after a '
        'retry-scroll request', () {
      final harness = Harness(
        measurement: MeasurementContext(
          containerKey: webPartialVirtualizedContainerKey,
          viewportWidth: 828,
          viewportHeight: 846,
          contentHeight: 14322,
          viewportMeasuredForKey: webPartialVirtualizedContainerKey,
          contentMeasuredForKey: webPartialVirtualizedContainerKey,
        ),
        isNearBottom: false,
      );
      harness.scrollToBottomBehavior = () {
        harness.measurement.offsetY = 13476;
      };

      harness.controller.applyRouteRequest(
        const BottomAnchorRouteRequest(
          agentId: 'agent-1',
          reason: BottomAnchorRouteReason.resume,
          requestKey: 'route:agent-1:resume',
        ),
      );

      harness.scheduler.flushFrame();
      expect(harness.scrollAttempts, hasLength(1));

      harness.measurement.contentHeight = 14804;
      harness.nearBottom = false;
      harness.controller.handleContentSizeChange(
        previousContentHeight: 14322,
        contentHeight: 14804,
      );

      harness.scheduler.flushFrame();

      var snapshot = harness.controller.snapshot;
      expect(snapshot.pendingRequest?.reason, BottomAnchorRequestReason.resume);
      expect(snapshot.pendingVerification?.requestId, 1);
      expect(snapshot.pendingVerification?.retries, 1);

      harness.scheduler.flushFrame();

      expect(harness.scrollAttempts, hasLength(2));
      snapshot = harness.controller.snapshot;
      expect(
        snapshot.blockedReason,
        BottomAnchorBlockedReason.waitingForPostLayoutVerification,
      );
      expect(snapshot.pendingRequest?.reason, BottomAnchorRequestReason.resume);
      expect(snapshot.pendingVerification?.requestId, 1);
    });

    test('does not fulfill a web partial-virtualized resume request before a '
        'confirmation pass', () {
      final harness = Harness(
        measurement: MeasurementContext(
          containerKey: webPartialVirtualizedContainerKey,
          viewportWidth: 828,
          viewportHeight: 846,
          contentHeight: 14322,
          viewportMeasuredForKey: webPartialVirtualizedContainerKey,
          contentMeasuredForKey: webPartialVirtualizedContainerKey,
        ),
        isNearBottom: false,
      );
      harness.scrollToBottomBehavior = () {
        final offset =
            harness.measurement.contentHeight -
            harness.measurement.viewportHeight;
        harness.measurement.offsetY = offset < 0 ? 0 : offset;
        harness.nearBottom = true;
      };

      harness.controller.applyRouteRequest(
        const BottomAnchorRouteRequest(
          agentId: 'agent-1',
          reason: BottomAnchorRouteReason.resume,
          requestKey: 'route:agent-1:resume-confirmation',
        ),
      );

      harness.scheduler
        ..flushFrame()
        ..flushFrame();

      var snapshot = harness.controller.snapshot;
      expect(snapshot.pendingRequest?.reason, BottomAnchorRequestReason.resume);
      expect(
        snapshot.blockedReason,
        BottomAnchorBlockedReason.waitingForPostLayoutVerification,
      );

      harness.measurement.contentHeight = 16230;
      harness.nearBottom = false;
      harness.controller.handleContentSizeChange(
        previousContentHeight: 14322,
        contentHeight: 16230,
      );

      harness.scheduler
        ..flushFrame()
        ..flushFrame()
        ..flushFrame();

      expect(harness.scrollAttempts, hasLength(2));
      snapshot = harness.controller.snapshot;
      expect(snapshot.pendingRequest?.reason, BottomAnchorRequestReason.resume);
    });

    test('keeps sticky-bottom during viewport growth until bottom is '
        're-verified', () {
      final harness = Harness()..nearBottom = false;
      harness.scrollToBottomBehavior = () {
        harness.measurement.offsetY = 720;
      };

      harness.controller.handleViewportMetricsChange(
        previousViewportWidth: 800,
        viewportWidth: 800,
        previousViewportHeight: 480,
        viewportHeight: 420,
      );
      harness.scheduler.flushAll();

      // One initial attempt plus the bounded retry-scroll ladder.
      expect(harness.scrollAttempts, hasLength(4));
      var snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.stickyBottom);
      expect(snapshot.pendingRequest, isNull);
      expect(snapshot.pendingVerification, isNull);

      harness.controller.handleScrollNearBottomChange(
        nextIsNearBottom: false,
        scrollDelta: 0,
      );

      expect(harness.controller.snapshot.mode, BottomAnchorMode.stickyBottom);

      harness.nearBottom = true;
      harness.controller.handleScrollNearBottomChange(
        nextIsNearBottom: true,
        scrollDelta: 0,
      );
      harness.scheduler.flushAll();
      harness.controller.handleScrollNearBottomChange(
        nextIsNearBottom: false,
        scrollDelta: 64,
      );

      snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.detached);
    });

    test('keeps sticky-bottom during streaming growth until bottom is '
        're-verified', () {
      final harness = Harness()..nearBottom = false;
      harness.scrollToBottomBehavior = () {
        harness.measurement.offsetY = 900;
      };

      harness.controller.handleContentSizeChange(
        previousContentHeight: 1200,
        contentHeight: 1400,
      );
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, hasLength(4));
      var snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.stickyBottom);
      expect(snapshot.pendingRequest, isNull);
      expect(snapshot.pendingVerification, isNull);

      harness.controller.handleScrollNearBottomChange(
        nextIsNearBottom: false,
        scrollDelta: 0,
      );

      expect(harness.controller.snapshot.mode, BottomAnchorMode.stickyBottom);

      harness.nearBottom = true;
      harness.controller.handleScrollNearBottomChange(
        nextIsNearBottom: true,
        scrollDelta: 0,
      );
      harness.scheduler.flushAll();
      harness.controller.handleScrollNearBottomChange(
        nextIsNearBottom: false,
        scrollDelta: 64,
      );

      snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.detached);
    });

    test('keeps initial native content growth anchored before layout scroll '
        'events arrive', () {
      final harness = Harness(
        transportBehavior: _nativeTransport,
        measurement: MeasurementContext(containerKey: 'native-virtualized'),
      );
      harness.scrollToBottomBehavior = () {
        harness.measurement.offsetY = 0;
      };

      harness.measurement
        ..contentHeight = 1348
        ..contentMeasuredForKey = 'native-virtualized';
      harness.controller.handleContentSizeChange(
        previousContentHeight: 0,
        contentHeight: 1348,
      );

      expect(harness.scrollAttempts, hasLength(1));
      var snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.stickyBottom);
      expect(snapshot.pendingVerification, isNotNull);
      expect(snapshot.pendingVerification?.requestId, isNull);

      harness.measurement
        ..viewportWidth = 390
        ..viewportHeight = 546
        ..viewportMeasuredForKey = 'native-virtualized'
        ..offsetY = 50;
      harness.nearBottom = false;
      harness.controller.handleScrollNearBottomChange(
        nextIsNearBottom: false,
        scrollDelta: 50,
      );

      snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.stickyBottom);
    });

    test('keeps native sticky content changes anchored when measured height is '
        'unchanged', () {
      final harness = Harness(
        transportBehavior: _nativeTransport,
        measurement: MeasurementContext(
          containerKey: 'native-virtualized',
          viewportWidth: 390,
          viewportHeight: 546,
          contentHeight: 546,
          viewportMeasuredForKey: 'native-virtualized',
          contentMeasuredForKey: 'native-virtualized',
        ),
      );
      harness.scrollToBottomBehavior = () {
        harness.measurement.offsetY = 0;
        harness.nearBottom = true;
      };

      harness.controller.prepareForStickyContentChange();

      expect(harness.scrollAttempts, hasLength(1));
      var snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.stickyBottom);
      expect(snapshot.pendingVerification, isNotNull);
      expect(snapshot.pendingVerification?.requestId, isNull);

      harness.measurement.offsetY = 50;
      harness.nearBottom = false;
      harness.controller.handleScrollNearBottomChange(
        nextIsNearBottom: false,
        scrollDelta: 50,
      );

      snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.stickyBottom);
    });

    test('resetForAgent clears requests and returns to sticky-bottom', () {
      final harness = Harness(isNearBottom: false);

      harness.controller.detachByUser();
      expect(harness.controller.snapshot.mode, BottomAnchorMode.detached);

      harness.controller.resetForAgent();

      final snapshot = harness.controller.snapshot;
      expect(snapshot.mode, BottomAnchorMode.stickyBottom);
      expect(snapshot.pendingRequest, isNull);
      expect(snapshot.blockedReason, isNull);
      expect(harness.modeChanges.last, BottomAnchorMode.stickyBottom);
    });

    test('ignores a repeated route request key but accepts a new one', () {
      final harness = Harness();

      harness.controller.applyRouteRequest(
        const BottomAnchorRouteRequest(
          agentId: 'agent-1',
          reason: BottomAnchorRouteReason.initialEntry,
          requestKey: 'route:agent-1',
        ),
      );
      harness.scheduler.flushAll();
      expect(harness.scrollAttempts, hasLength(1));

      harness.controller.applyRouteRequest(
        const BottomAnchorRouteRequest(
          agentId: 'agent-1',
          reason: BottomAnchorRouteReason.initialEntry,
          requestKey: 'route:agent-1',
        ),
      );
      harness.scheduler.flushAll();
      expect(harness.scrollAttempts, hasLength(1));

      harness.controller.applyRouteRequest(
        const BottomAnchorRouteRequest(
          agentId: 'agent-1',
          reason: BottomAnchorRouteReason.resume,
          requestKey: 'route:agent-1:resume',
        ),
      );
      harness.scheduler.flushAll();
      expect(harness.scrollAttempts, hasLength(2));
    });

    test('ignores a null route request', () {
      final harness = Harness();

      harness.controller.applyRouteRequest(null);
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, isEmpty);
      expect(harness.controller.snapshot.pendingRequest, isNull);
    });

    test('a message-sent local anchor scrolls without animation', () {
      final harness = Harness(isNearBottom: false);

      harness.controller.requestLocalAnchor(
        const BottomAnchorLocalRequest(
          agentId: 'agent-1',
          reason: BottomAnchorLocalReason.messageSent,
        ),
      );
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, isNotEmpty);
      expect(harness.scrollAttempts.first, isFalse);
      expect(harness.controller.snapshot.mode, BottomAnchorMode.stickyBottom);
    });

    test('notifyAuthoritativeHistoryMaybeChanged is inert while idle', () {
      final harness = Harness();

      harness.controller.notifyAuthoritativeHistoryMaybeChanged();
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, isEmpty);
    });

    test('dispose cancels in-flight frames', () {
      final harness = Harness(authoritativeReady: false);

      harness.controller.applyRouteRequest(
        const BottomAnchorRouteRequest(
          agentId: 'agent-1',
          reason: BottomAnchorRouteReason.initialEntry,
          requestKey: 'route:agent-1',
        ),
      );
      harness.controller.dispose();
      harness.scheduler.flushAll();

      expect(harness.scrollAttempts, isEmpty);
    });
  });

  group('controller helper predicates', () {
    test('rejects stale container measurements during post-scroll '
        'verification', () {
      expect(
        deriveVerificationBlockedReason(
          isAuthoritativeHistoryReady: true,
          measurementState: MeasurementContext(
            containerKey: webPartialVirtualizedContainerKey,
            viewportHeight: 420,
            contentHeight: 1200,
            viewportMeasuredForKey: 'scroll-view',
            contentMeasuredForKey: 'scroll-view',
          ).state,
        ),
        BottomAnchorBlockedReason.waitingForMeasurableViewport,
      );
    });

    test('allows verification only after authoritative readiness and current '
        'geometry exist', () {
      expect(
        deriveVerificationBlockedReason(
          isAuthoritativeHistoryReady: false,
          measurementState: MeasurementContext(
            viewportHeight: 420,
            contentHeight: 1200,
            viewportMeasuredForKey: 'scroll-view',
            contentMeasuredForKey: 'scroll-view',
          ).state,
        ),
        BottomAnchorBlockedReason.waitingForHistoryReadiness,
      );

      expect(
        deriveVerificationBlockedReason(
          isAuthoritativeHistoryReady: true,
          measurementState: MeasurementContext(
            viewportHeight: 420,
            contentHeight: 1200,
            viewportMeasuredForKey: 'scroll-view',
            contentMeasuredForKey: 'scroll-view',
          ).state,
        ),
        isNull,
      );
    });

    test('suppresses auto-anchor helpers while detached', () {
      expect(
        shouldRestickOnContentChange(
          mode: BottomAnchorMode.detached,
          previousContentHeight: 1000,
          contentHeight: 1100,
        ),
        isFalse,
      );
      expect(
        shouldRestickOnViewportChange(
          mode: BottomAnchorMode.detached,
          previousViewportWidth: 800,
          viewportWidth: 640,
          previousViewportHeight: 400,
          viewportHeight: 360,
        ),
        isFalse,
      );
    });

    test('ignores unmeasured dimensions and shrinking content', () {
      expect(
        shouldRestickOnViewportChange(
          mode: BottomAnchorMode.stickyBottom,
          previousViewportWidth: 0,
          viewportWidth: 640,
          previousViewportHeight: 0,
          viewportHeight: 360,
        ),
        isFalse,
      );
      expect(
        shouldRestickOnContentChange(
          mode: BottomAnchorMode.stickyBottom,
          previousContentHeight: 1200,
          contentHeight: 1000,
        ),
        isFalse,
      );
      expect(
        shouldRestickOnContentChange(
          mode: BottomAnchorMode.stickyBottom,
          previousContentHeight: 1000,
          contentHeight: 1200,
        ),
        isTrue,
      );
    });

    test('does not detach from sticky while a restick request is still '
        'pending', () {
      expect(
        shouldDetachFromScrollAway(
          mode: BottomAnchorMode.stickyBottom,
          nextIsNearBottom: false,
          scrollDelta: 0,
          hasPendingRequest: true,
          hasPendingVerification: false,
          hasUnverifiedStickyMeasurementChange: false,
        ),
        isFalse,
      );
      expect(
        shouldDetachFromScrollAway(
          mode: BottomAnchorMode.stickyBottom,
          nextIsNearBottom: false,
          scrollDelta: 0,
          hasPendingRequest: false,
          hasPendingVerification: true,
          hasUnverifiedStickyMeasurementChange: false,
        ),
        isFalse,
      );
      expect(
        shouldDetachFromScrollAway(
          mode: BottomAnchorMode.stickyBottom,
          nextIsNearBottom: false,
          scrollDelta: 0,
          hasPendingRequest: false,
          hasPendingVerification: false,
          hasUnverifiedStickyMeasurementChange: true,
        ),
        isFalse,
      );
      expect(
        shouldDetachFromScrollAway(
          mode: BottomAnchorMode.stickyBottom,
          nextIsNearBottom: false,
          scrollDelta: 0,
          hasPendingRequest: false,
          hasPendingVerification: false,
          hasUnverifiedStickyMeasurementChange: false,
        ),
        isTrue,
      );
    });

    test('treats a large scroll delta as user detach even during an unverified '
        'sticky change', () {
      expect(
        shouldDetachFromScrollAway(
          mode: BottomAnchorMode.stickyBottom,
          nextIsNearBottom: false,
          scrollDelta: 48,
          hasPendingRequest: false,
          hasPendingVerification: false,
          hasUnverifiedStickyMeasurementChange: true,
        ),
        isTrue,
      );
    });

    test(
      'deriveRetryDisposition follows mode, retry budget, and transport',
      () {
        const rescroll = BottomAnchorTransport(
          verificationDelayFrames: 0,
          isRecheck: false,
        );

        expect(
          deriveRetryDisposition(
            mode: BottomAnchorMode.detached,
            retries: 0,
            verificationRetryMode: rescroll,
          ),
          BottomAnchorRetryDisposition.fail,
        );
        expect(
          deriveRetryDisposition(
            mode: BottomAnchorMode.stickyBottom,
            retries: maxVerificationRetries,
            verificationRetryMode: rescroll,
          ),
          BottomAnchorRetryDisposition.fail,
        );
        expect(
          deriveRetryDisposition(
            mode: BottomAnchorMode.stickyBottom,
            retries: 0,
            verificationRetryMode: rescroll,
          ),
          BottomAnchorRetryDisposition.retryScroll,
        );
        expect(
          deriveRetryDisposition(
            mode: BottomAnchorMode.stickyBottom,
            retries: 0,
            verificationRetryMode: _nativeTransport,
          ),
          BottomAnchorRetryDisposition.retryVerify,
        );
      },
    );

    test('a local request always resolves to sticky-bottom', () {
      expect(
        deriveModeForLocalRequest(BottomAnchorLocalReason.jumpToBottom),
        BottomAnchorMode.stickyBottom,
      );
      expect(
        deriveModeForLocalRequest(BottomAnchorLocalReason.messageSent),
        BottomAnchorMode.stickyBottom,
      );
    });
  });
}
