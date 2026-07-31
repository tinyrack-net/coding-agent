// Ports of the upstream test suites for Paseo's activity- and
// measurement-driven hooks: client-activity-tracker,
// hardware-keyboard-submit-controller, hover-safe-zone-tracker, and
// use-container-width — plus the edge cases those suites leave unpinned
// (throttle bookkeeping while disconnected, the epoch-seeded throttle, rect
// edge inclusivity, reversed bridges, threshold equality, re-enable cycles).
//
// Time is never real here: the tracker takes a `DateTime Function()` and every
// test advances a fake clock explicitly.
import 'package:coding_agent_app/hooks/paseo_activity_rules.dart';
import 'package:flutter_test/flutter_test.dart';

final DateTime _startAt = DateTime.utc(2026, 4, 19, 10);

/// Hand-cranked clock standing in for upstream's `createTestClock`.
final class _TestClock {
  _TestClock([DateTime? initial]) : _at = initial ?? _startAt;

  DateTime _at;

  DateTime now() => _at;

  void set(DateTime at) => _at = at;

  void advance(int ms) => _at = _at.add(Duration(milliseconds: ms));
}

final class _FakeHeartbeatClient implements HeartbeatClient {
  @override
  bool isConnected = true;

  final List<HeartbeatPayload> recordedHeartbeats = [];

  @override
  void sendHeartbeat(HeartbeatPayload payload) {
    recordedHeartbeats.add(payload);
  }

  HeartbeatPayload latest() {
    expect(recordedHeartbeats, isNotEmpty, reason: 'Expected a heartbeat');
    return recordedHeartbeats.last;
  }

  void reset() => recordedHeartbeats.clear();
}

final class _TrackerHandle {
  _TrackerHandle({
    required this.tracker,
    required this.client,
    required this.clock,
  });

  final ClientActivityTracker tracker;
  final _FakeHeartbeatClient client;
  final _TestClock clock;
}

_TrackerHandle _buildTracker({
  _FakeHeartbeatClient? client,
  _TestClock? clock,
  HeartbeatDeviceType deviceType = HeartbeatDeviceType.web,
  String? initialFocusedAgentId = 'agent-1',
  String? initialFocusedTerminalId,
  bool initialAppVisible = true,
  void Function(int awayMs)? onAppResumed,
}) {
  final resolvedClient = client ?? _FakeHeartbeatClient();
  final resolvedClock = clock ?? _TestClock();
  return _TrackerHandle(
    tracker: ClientActivityTracker(
      client: resolvedClient,
      deviceType: deviceType,
      initialFocusedAgentId: initialFocusedAgentId,
      initialFocusedTerminalId: initialFocusedTerminalId,
      initialAppVisible: initialAppVisible,
      now: resolvedClock.now,
      onAppResumed: onAppResumed,
    ),
    client: resolvedClient,
    clock: resolvedClock,
  );
}

String _isoAfterStart(int ms) =>
    _startAt.add(Duration(milliseconds: ms)).toIso8601String();

void main() {
  group('ClientActivityTracker', () {
    test('includes the latest user-activity time in the next heartbeat', () {
      final handle = _buildTracker();

      handle.clock.advance(5250);
      handle.tracker.recordUserActivity();
      handle.tracker.maybeSendImmediateHeartbeat();

      final payload = handle.client.latest();
      expect(payload.deviceType, HeartbeatDeviceType.web);
      expect(payload.deviceType.wireValue, 'web');
      expect(payload.focusedAgentId, 'agent-1');
      expect(payload.appVisible, isTrue);
      expect(payload.lastActivityAt, _isoAfterStart(5250));
    });

    test('renders timestamps exactly as JavaScript toISOString does', () {
      final handle = _buildTracker();
      handle.tracker.sendHeartbeat();

      expect(handle.client.latest().lastActivityAt, '2026-04-19T10:00:00.000Z');
    });

    test('throttles repeated immediate heartbeats within the window', () {
      final handle = _buildTracker();

      handle.tracker.recordUserActivity();
      handle.tracker.maybeSendImmediateHeartbeat();
      expect(handle.client.recordedHeartbeats, hasLength(1));

      handle.clock.advance(activityHeartbeatThrottleMs - 1);
      handle.tracker.recordUserActivity();
      handle.tracker.maybeSendImmediateHeartbeat();
      expect(handle.client.recordedHeartbeats, hasLength(1));

      handle.clock.advance(1);
      handle.tracker.recordUserActivity();
      handle.tracker.maybeSendImmediateHeartbeat();
      expect(handle.client.recordedHeartbeats, hasLength(2));
    });

    test('sends one immediate heartbeat when the focused agent changes', () {
      final handle = _buildTracker();
      handle.tracker.sendHeartbeat(); // simulate the on-connect heartbeat
      expect(handle.client.recordedHeartbeats, hasLength(1));
      handle.client.reset();

      handle.clock.advance(5000);
      handle.tracker.setFocusedAgentId('agent-2');

      expect(handle.client.recordedHeartbeats, hasLength(1));
      expect(handle.client.latest().focusedAgentId, 'agent-2');
      expect(handle.client.latest().lastActivityAt, _isoAfterStart(5000));
    });

    test('ignores focused-agent updates that do not change the value', () {
      final handle = _buildTracker(initialFocusedAgentId: 'agent-1');

      handle.tracker.setFocusedAgentId('agent-1');

      expect(handle.client.recordedHeartbeats, isEmpty);
    });

    test('sends one immediate heartbeat when the focused terminal changes', () {
      final handle = _buildTracker(initialFocusedTerminalId: null);

      handle.clock.advance(5000);
      handle.tracker.setFocusedTerminalId('terminal-1');

      expect(handle.client.recordedHeartbeats, hasLength(1));
      final payload = handle.client.latest();
      expect(payload.focusedAgentId, 'agent-1');
      expect(payload.focusedTerminalId, 'terminal-1');
      expect(payload.lastActivityAt, _isoAfterStart(5000));
    });

    test('drives lastActivityAt forward from system idle polling', () {
      final handle = _buildTracker();

      handle.clock.advance(5000);
      handle.tracker.notifySystemIdleMs(0);
      handle.clock.advance(5000);
      handle.tracker.notifySystemIdleMs(0);
      handle.clock.advance(5000);
      handle.tracker.notifySystemIdleMs(0);
      handle.tracker.sendHeartbeat();

      expect(handle.client.latest().lastActivityAt, _isoAfterStart(15000));
    });

    test('sets lastActivityAt to now minus the system idle time', () {
      final handle = _buildTracker();

      handle.clock.advance(15000);
      handle.tracker.notifySystemIdleMs(2000);
      handle.tracker.sendHeartbeat();

      expect(handle.client.latest().lastActivityAt, _isoAfterStart(13000));
    });

    test('ignores failed system idle polls', () {
      final handle = _buildTracker();
      handle.tracker.sendHeartbeat();
      final before = handle.client.latest().lastActivityAt;

      handle.clock.advance(15000);
      handle.tracker.notifySystemIdleMs(null);
      handle.tracker.sendHeartbeat();

      expect(handle.client.latest().lastActivityAt, before);
    });

    test('never moves lastActivityAt backward from a system idle poll', () {
      final handle = _buildTracker();

      handle.clock.advance(5000);
      handle.tracker.recordUserActivity();
      final userActivityAt = _isoAfterStart(5000);

      handle.clock.advance(10000);
      // Would imply activity 5_000 ms before start.
      handle.tracker.notifySystemIdleMs(20000);
      handle.tracker.sendHeartbeat();

      expect(handle.client.latest().lastActivityAt, userActivityAt);
    });

    test('emits appVisibilityChangedAt and resumes after backgrounding', () {
      int? resumed;
      final handle = _buildTracker(
        initialAppVisible: true,
        onAppResumed: (awayMs) => resumed = awayMs,
      );

      handle.clock.advance(2000);
      expect(handle.tracker.notifyAppVisibility(false).changed, isTrue);

      handle.clock.advance(8000);
      expect(handle.tracker.notifyAppVisibility(true).changed, isTrue);
      expect(resumed, 8000);

      handle.tracker.sendHeartbeat();
      final payload = handle.client.latest();
      expect(payload.appVisible, isTrue);
      expect(payload.appVisibilityChangedAt, _isoAfterStart(10000));
      expect(payload.lastActivityAt, _isoAfterStart(10000));
    });

    test('treats no-op visibility transitions as no change', () {
      final handle = _buildTracker(initialAppVisible: true);

      expect(handle.tracker.notifyAppVisibility(true).changed, isFalse);
    });

    test('does not resume when going from initial-visible to hidden', () {
      int? resumed;
      final handle = _buildTracker(
        initialAppVisible: true,
        onAppResumed: (awayMs) => resumed = awayMs,
      );

      handle.tracker.notifyAppVisibility(false);

      expect(resumed, isNull);
    });

    test('skips heartbeats while the client is disconnected', () {
      final client = _FakeHeartbeatClient()..isConnected = false;
      final handle = _buildTracker(client: client);

      handle.tracker.sendHeartbeat();
      handle.tracker.recordUserActivity();
      handle.tracker.maybeSendImmediateHeartbeat();
      handle.clock.advance(10000);
      handle.tracker.setFocusedAgentId('agent-2');

      expect(client.recordedHeartbeats, isEmpty);
    });

    // --- edge cases the upstream suite leaves unpinned -----------------------

    test('a disconnected immediate heartbeat does not burn the throttle', () {
      final client = _FakeHeartbeatClient()..isConnected = false;
      final handle = _buildTracker(client: client);

      handle.tracker.maybeSendImmediateHeartbeat();
      client.isConnected = true;
      // No time passed; the earlier attempt must not count as a send.
      handle.tracker.maybeSendImmediateHeartbeat();

      expect(client.recordedHeartbeats, hasLength(1));
    });

    test('throttle is seeded from the epoch, not from construction', () {
      // Upstream seeds lastImmediateHeartbeatAt with 0. Faithfully reproduced:
      // a clock reading below the throttle window swallows the first send.
      final handle = _buildTracker(
        clock: _TestClock(
          DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
        ),
      );

      handle.tracker.maybeSendImmediateHeartbeat();
      expect(handle.client.recordedHeartbeats, isEmpty);

      handle.clock.advance(activityHeartbeatThrottleMs);
      handle.tracker.maybeSendImmediateHeartbeat();
      expect(handle.client.recordedHeartbeats, hasLength(1));
    });

    test('clearing the focused agent to null sends a heartbeat', () {
      final handle = _buildTracker(initialFocusedAgentId: 'agent-1');

      handle.tracker.setFocusedAgentId(null);

      expect(handle.client.recordedHeartbeats, hasLength(1));
      expect(handle.client.latest().focusedAgentId, isNull);
    });

    test('null-to-null focus updates are no-ops for both fields', () {
      final handle = _buildTracker(
        initialFocusedAgentId: null,
        initialFocusedTerminalId: null,
      );

      handle.tracker.setFocusedAgentId(null);
      handle.tracker.setFocusedTerminalId(null);

      expect(handle.client.recordedHeartbeats, isEmpty);
    });

    test('an idle poll equal to the current activity time changes nothing', () {
      final handle = _buildTracker();

      handle.clock.advance(5000);
      handle.tracker.recordUserActivity();
      handle.clock.advance(3000);
      // now - 3000 == the recorded activity time; the comparison is strict.
      handle.tracker.notifySystemIdleMs(3000);
      handle.tracker.sendHeartbeat();

      expect(handle.client.latest().lastActivityAt, _isoAfterStart(5000));
    });

    test('a negative idle reading still moves activity forward', () {
      final handle = _buildTracker();

      handle.clock.advance(1000);
      handle.tracker.notifySystemIdleMs(-2000);
      handle.tracker.sendHeartbeat();

      expect(handle.client.latest().lastActivityAt, _isoAfterStart(3000));
    });

    test('a client that starts hidden reports its away time on resume', () {
      int? resumed;
      final handle = _buildTracker(
        initialAppVisible: false,
        onAppResumed: (awayMs) => resumed = awayMs,
      );

      handle.clock.advance(4000);
      expect(handle.tracker.notifyAppVisibility(true).changed, isTrue);

      expect(resumed, 4000);
    });

    test('hidden-to-hidden is not a transition', () {
      int? resumed;
      final handle = _buildTracker(
        initialAppVisible: false,
        onAppResumed: (awayMs) => resumed = awayMs,
      );

      expect(handle.tracker.notifyAppVisibility(false).changed, isFalse);
      expect(resumed, isNull);
    });

    test('a backwards clock reports a clamped away duration', () {
      final resumedValues = <int>[];
      final handle = _buildTracker(
        initialAppVisible: true,
        onAppResumed: resumedValues.add,
      );

      handle.clock.advance(5000);
      handle.tracker.notifyAppVisibility(false);
      handle.clock.set(_startAt); // clock jumped backwards
      handle.tracker.notifyAppVisibility(true);

      expect(resumedValues, [0]);
    });

    test('a second background/foreground round trip resumes again', () {
      final resumedValues = <int>[];
      final handle = _buildTracker(onAppResumed: resumedValues.add);

      handle.tracker.notifyAppVisibility(false);
      handle.clock.advance(1000);
      handle.tracker.notifyAppVisibility(true);
      handle.tracker.notifyAppVisibility(false);
      handle.clock.advance(2000);
      handle.tracker.notifyAppVisibility(true);

      expect(resumedValues, [1000, 2000]);
    });

    test('heartbeats sent while hidden report the hidden state', () {
      final handle = _buildTracker(initialAppVisible: true);

      handle.clock.advance(1000);
      handle.tracker.notifyAppVisibility(false);
      handle.tracker.sendHeartbeat();

      final payload = handle.client.latest();
      expect(payload.appVisible, isFalse);
      expect(payload.appVisibilityChangedAt, _isoAfterStart(1000));
    });

    test('recordUserActivity alone never sends', () {
      final handle = _buildTracker();

      handle.tracker.recordUserActivity();

      expect(handle.client.recordedHeartbeats, isEmpty);
    });

    test('the mobile device type reaches the payload verbatim', () {
      final handle = _buildTracker(deviceType: HeartbeatDeviceType.mobile);

      handle.tracker.sendHeartbeat();

      expect(handle.client.latest().deviceType.wireValue, 'mobile');
    });
  });

  group('HardwareKeyboardSubmitController', () {
    test('dispatches to onSubmit when the keyboard emits while enabled', () {
      final keyboard = _FakeKeyboard();
      final controller = HardwareKeyboardSubmitController(keyboard);
      var calls = 0;
      controller.setOnSubmit(() => calls += 1);

      controller.enable();
      keyboard.emit();

      expect(calls, 1);
      expect(keyboard.isEnabled, isTrue);
    });

    test('does not subscribe or enable when never enabled', () {
      final keyboard = _FakeKeyboard();
      final controller = HardwareKeyboardSubmitController(keyboard);
      var calls = 0;
      controller.setOnSubmit(() => calls += 1);

      keyboard.emit();

      expect(calls, 0);
      expect(keyboard.listenerCount, 0);
      expect(keyboard.isEnabled, isFalse);
    });

    test('disables native hardware submit and unsubscribes on disable', () {
      final keyboard = _FakeKeyboard();
      final controller = HardwareKeyboardSubmitController(keyboard);
      controller.setOnSubmit(() {});

      controller.enable();
      expect(keyboard.isEnabled, isTrue);
      expect(keyboard.listenerCount, 1);

      controller.disable();
      expect(keyboard.isEnabled, isFalse);
      expect(keyboard.listenerCount, 0);
    });

    test('dispatches the latest onSubmit handler', () {
      final keyboard = _FakeKeyboard();
      final controller = HardwareKeyboardSubmitController(keyboard);
      final received = <String>[];
      controller.setOnSubmit(() => received.add('first'));

      controller.enable();
      controller.setOnSubmit(() => received.add('second'));
      keyboard.emit();

      expect(received, ['second']);
    });

    test('does not dispatch after disable', () {
      final keyboard = _FakeKeyboard();
      final controller = HardwareKeyboardSubmitController(keyboard);
      var calls = 0;
      controller.setOnSubmit(() => calls += 1);

      controller.enable();
      controller.disable();
      keyboard.emit();

      expect(calls, 0);
    });

    test('ignores repeated enable calls', () {
      final keyboard = _FakeKeyboard();
      final controller = HardwareKeyboardSubmitController(keyboard);
      var calls = 0;
      controller.setOnSubmit(() => calls += 1);

      controller.enable();
      controller.enable();
      keyboard.emit();

      expect(calls, 1);
      expect(keyboard.listenerCount, 1);
    });

    test('ignores disable without a prior enable', () {
      final keyboard = _FakeKeyboard();
      final controller = HardwareKeyboardSubmitController(keyboard);

      controller.disable();

      expect(keyboard.isEnabled, isFalse);
      expect(keyboard.setEnabledCalls, isEmpty);
    });

    // --- edge cases the upstream suite leaves unpinned -----------------------

    test('enabling without a handler is harmless', () {
      final keyboard = _FakeKeyboard();
      HardwareKeyboardSubmitController(keyboard).enable();

      expect(keyboard.emit, returnsNormally);
    });

    test('re-enabling after disable resubscribes exactly once', () {
      final keyboard = _FakeKeyboard();
      final controller = HardwareKeyboardSubmitController(keyboard);
      var calls = 0;
      controller.setOnSubmit(() => calls += 1);

      controller.enable();
      controller.disable();
      controller.enable();
      keyboard.emit();

      expect(calls, 1);
      expect(keyboard.listenerCount, 1);
      expect(keyboard.isEnabled, isTrue);
      expect(keyboard.setEnabledCalls, [true, false, true]);
    });

    test('repeated disable calls do not re-disable the native listener', () {
      final keyboard = _FakeKeyboard();
      final controller = HardwareKeyboardSubmitController(keyboard);

      controller.enable();
      controller.disable();
      controller.disable();

      expect(keyboard.setEnabledCalls, [true, false]);
    });

    test('a handler set after enable is used on the first emit', () {
      final keyboard = _FakeKeyboard();
      final controller = HardwareKeyboardSubmitController(keyboard);
      var calls = 0;

      controller.enable();
      controller.setOnSubmit(() => calls += 1);
      keyboard.emit();

      expect(calls, 1);
    });

    test('every emit while enabled dispatches', () {
      final keyboard = _FakeKeyboard();
      final controller = HardwareKeyboardSubmitController(keyboard);
      var calls = 0;
      controller.setOnSubmit(() => calls += 1);

      controller.enable();
      keyboard.emit();
      keyboard.emit();
      keyboard.emit();

      expect(calls, 3);
    });
  });

  group('HoverSafeZoneTracker', () {
    test('tracks transitions across trigger, bridge, content, outside', () {
      final handle = _HoverHandle();

      // Bridge between trigger and content.
      handle.tracker.pointerMoved(110, 40);
      expect(handle.enters, 1);
      expect(handle.leaves, 0);

      // Outside everything — fires leave once.
      handle.tracker.pointerMoved(300, 40);
      expect(handle.leaves, 1);

      // Back into the bridge — fires enter again.
      handle.tracker.pointerMoved(130, 40);
      expect(handle.enters, 2);
    });

    test('refreshes the safe-zone enter callback while moving inside', () {
      final handle = _HoverHandle();

      handle.tracker.pointerMoved(110, 40);
      handle.tracker.pointerMoved(130, 40);

      expect(handle.enters, 2);
      expect(handle.leaves, 0);
    });

    test('treats leaving the browser window as leaving the safe zone', () {
      final handle = _HoverHandle();

      handle.tracker.pointerLeftWindow();
      expect(handle.leaves, 1);

      // Already outside — blur does not fire a second leave.
      handle.tracker.windowBlurred();
      expect(handle.leaves, 1);
    });

    test('falls back to rect membership when a rect is missing', () {
      final handle = _HoverHandle(content: null);

      // Inside the trigger.
      handle.tracker.pointerMoved(50, 40);
      expect(handle.enters, 1);

      // Inside the (now-missing) bridge — counts as outside.
      handle.tracker.pointerMoved(110, 40);
      expect(handle.leaves, 1);
    });

    test('treats overlapping trigger and content as having no bridge', () {
      final handle = _HoverHandle(
        trigger: const HoverRect(left: 0, right: 200, top: 0, bottom: 50),
        content: const HoverRect(left: 100, right: 300, top: 60, bottom: 100),
      );

      // Outside both rects, in what would be a bridge — should be outside.
      handle.tracker.pointerMoved(150, 55);
      expect(handle.enters, 0);
      expect(handle.leaves, 1);
    });

    // --- edge cases the upstream suite leaves unpinned -----------------------

    test('rect edges are inclusive on all four sides', () {
      final handle = _HoverHandle();

      handle.tracker.pointerMoved(0, 20); // top-left corner of the trigger
      handle.tracker.pointerMoved(100, 60); // bottom-right corner
      handle.tracker.pointerMoved(240, 120); // bottom-right of the content

      expect(handle.enters, 3);
      expect(handle.leaves, 0);
    });

    test('bridge edges are inclusive and its vertical span covers both', () {
      final handle = _HoverHandle();

      handle.tracker.pointerMoved(100, 120); // bridge left edge, content bottom
      expect(handle.enters, 1);
      handle.tracker.pointerMoved(120, 20); // bridge right edge, shared top
      expect(handle.enters, 2);
      handle.tracker.pointerMoved(110, 121); // one pixel below the bridge
      expect(handle.leaves, 1);
    });

    test('bridges content positioned to the left of its trigger', () {
      final handle = _HoverHandle(
        trigger: const HoverRect(left: 120, right: 240, top: 20, bottom: 60),
        content: const HoverRect(left: 0, right: 100, top: 20, bottom: 120),
      );

      handle.tracker.pointerMoved(110, 40);

      expect(handle.enters, 1);
      expect(handle.leaves, 0);
    });

    test('both rects missing means everything is outside', () {
      final handle = _HoverHandle(trigger: null, content: null);

      handle.tracker.pointerMoved(50, 40);

      expect(handle.enters, 0);
      expect(handle.leaves, 1);
    });

    test('repeated moves outside fire exactly one leave', () {
      final handle = _HoverHandle();

      handle.tracker.pointerMoved(300, 300);
      handle.tracker.pointerMoved(400, 400);
      handle.tracker.pointerMoved(500, 500);

      expect(handle.leaves, 1);
    });

    test('a move back inside after a window blur re-enters', () {
      final handle = _HoverHandle();

      handle.tracker.windowBlurred();
      expect(handle.leaves, 1);

      handle.tracker.pointerMoved(50, 40);
      expect(handle.enters, 1);

      handle.tracker.windowBlurred();
      expect(handle.leaves, 2);
    });

    test('rects are re-read on every move, so a moved card still counts', () {
      var content = const HoverRect(
        left: 120,
        right: 240,
        top: 20,
        bottom: 120,
      );
      var enters = 0;
      final tracker = HoverSafeZoneTracker(
        getTriggerRect: () =>
            const HoverRect(left: 0, right: 100, top: 20, bottom: 60),
        getContentRect: () => content,
        onEnterSafeZone: () => enters += 1,
        onLeaveSafeZone: () {},
      );

      content = const HoverRect(left: 400, right: 520, top: 20, bottom: 120);
      tracker.pointerMoved(450, 40);

      expect(enters, 1);
    });
  });

  group('ContainerWidthTracker', () {
    test('starts at zero and adopts the measured width', () {
      final tracker = ContainerWidthTracker();
      var notifications = 0;
      tracker.addListener(() => notifications += 1);

      expect(tracker.width, 0);
      expect(tracker.onLayout(640), isTrue);
      expect(tracker.width, 640);
      expect(notifications, 1);
    });

    test('re-measuring the same width does not notify', () {
      final tracker = ContainerWidthTracker();
      var notifications = 0;
      tracker.addListener(() => notifications += 1);

      tracker.onLayout(640);
      expect(tracker.onLayout(640), isFalse);

      expect(notifications, 1);
    });

    test('keeps zero-width measurements, unlike the threshold tracker', () {
      final tracker = ContainerWidthTracker();

      tracker.onLayout(640);
      expect(tracker.onLayout(0), isTrue);
      expect(tracker.width, 0);
    });
  });

  group('ContainerWidthBelowTracker', () {
    test('does not notify for width changes within the same bucket', () {
      final tracker = ContainerWidthBelowTracker(threshold: 700);
      var notifications = 0;
      tracker.addListener(() => notifications += 1);

      expect(tracker.isBelow, isTrue);
      expect(notifications, 0);

      tracker.onLayout(650);
      tracker.onLayout(620);
      tracker.onLayout(699);

      expect(tracker.isBelow, isTrue);
      expect(notifications, 0);
    });

    test('notifies when the width crosses the threshold', () {
      final tracker = ContainerWidthBelowTracker(threshold: 700);
      var notifications = 0;
      tracker.addListener(() => notifications += 1);

      expect(tracker.onLayout(760), isTrue);

      expect(tracker.isBelow, isFalse);
      expect(notifications, 1);
    });

    test('ignores zero-width measurements from hidden mounted content', () {
      final tracker = ContainerWidthBelowTracker(
        threshold: 700,
        initialIsBelow: false,
      );
      var notifications = 0;
      tracker.addListener(() => notifications += 1);

      expect(tracker.isBelow, isFalse);

      expect(tracker.onLayout(0), isFalse);
      expect(tracker.isBelow, isFalse);
      expect(notifications, 0);

      expect(tracker.onLayout(650), isTrue);
      expect(tracker.isBelow, isTrue);
      expect(notifications, 1);
    });

    // --- edge cases the upstream suite leaves unpinned -----------------------

    test('a width exactly at the threshold is not below it', () {
      final tracker = ContainerWidthBelowTracker(
        threshold: 700,
        initialIsBelow: true,
      );

      expect(tracker.onLayout(700), isTrue);
      expect(tracker.isBelow, isFalse);
    });

    test('negative widths are dropped like zero widths', () {
      final tracker = ContainerWidthBelowTracker(
        threshold: 700,
        initialIsBelow: false,
      );

      expect(tracker.onLayout(-1), isFalse);
      expect(tracker.isBelow, isFalse);
    });

    test('notifies once per crossing while resizing back and forth', () {
      final tracker = ContainerWidthBelowTracker(threshold: 700);
      var notifications = 0;
      tracker.addListener(() => notifications += 1);

      tracker.onLayout(800);
      tracker.onLayout(900);
      tracker.onLayout(600);
      tracker.onLayout(500);
      tracker.onLayout(1000);

      expect(notifications, 3);
      expect(tracker.isBelow, isFalse);
    });

    test('defaults to below before any measurement arrives', () {
      expect(ContainerWidthBelowTracker(threshold: 700).isBelow, isTrue);
    });
  });
}

final class _FakeKeyboard implements HardwareKeyboardSubmitListenerPort {
  final List<void Function()> _handlers = [];
  final List<bool> setEnabledCalls = [];
  bool isEnabled = false;

  int get listenerCount => _handlers.length;

  @override
  HardwareKeyboardSubmitSubscription addListener(void Function() handler) {
    _handlers.add(handler);
    return _FakeSubscription(() => _handlers.remove(handler));
  }

  @override
  void setEnabled(bool enabled) {
    setEnabledCalls.add(enabled);
    isEnabled = enabled;
  }

  void emit() {
    for (final handler in List.of(_handlers)) {
      handler();
    }
  }
}

final class _FakeSubscription implements HardwareKeyboardSubmitSubscription {
  _FakeSubscription(this._remove);

  final void Function() _remove;

  @override
  void remove() => _remove();
}

const _defaultTrigger = HoverRect(left: 0, right: 100, top: 20, bottom: 60);
const _defaultContent = HoverRect(left: 120, right: 240, top: 20, bottom: 120);

/// Counts enter/leave callbacks around a tracker with fixed rects.
final class _HoverHandle {
  _HoverHandle({
    HoverRect? trigger = _defaultTrigger,
    HoverRect? content = _defaultContent,
  }) {
    tracker = HoverSafeZoneTracker(
      getTriggerRect: () => trigger,
      getContentRect: () => content,
      onEnterSafeZone: () => enters += 1,
      onLeaveSafeZone: () => leaves += 1,
    );
  }

  late final HoverSafeZoneTracker tracker;
  int enters = 0;
  int leaves = 0;
}
