/// Ports of Paseo 0.2.0's four activity- and measurement-driven hooks, grouped
/// here because each is a frozen controller whose whole job is to turn a stream
/// of raw signals (clock ticks, key events, pointer moves, layout passes) into
/// the far smaller set of events the UI actually reacts to:
///
/// - `hooks/client-activity-tracker.ts` — what the daemon is told about this
///   client: who is focused, when the user last did anything, and whether the
///   app is on screen. Exists so heartbeats stay cheap (throttled) while still
///   being immediate for the transitions that matter.
/// - `hooks/hardware-keyboard-submit-controller.ts` — the subscribe/unsubscribe
///   latch around the platform's "hardware keyboard pressed send" event. It
///   only routes the event; the submit *decision* lives in
///   `composer/composer_submit.dart` and is deliberately not duplicated here.
/// - `hooks/hover-safe-zone-tracker.ts` — whether the pointer is still within a
///   hover card's trigger, its content, or the invisible bridge between them,
///   so crossing the visual gap does not dismiss the card.
/// - `hooks/use-container-width.ts` — container measurement collapsed to the
///   one bit most callers want (narrower than a breakpoint or not), so layout
///   passes do not cause a rebuild per pixel.
///
/// Every time source is injected. Nothing in this file reads the wall clock,
/// starts a timer, or touches a widget tree: callers own the scheduling, which
/// is what lets the suite drive these controllers deterministically.
library;

import 'package:flutter/foundation.dart';

// ---------------------------------------------------------------------------
// client-activity-tracker.ts
// ---------------------------------------------------------------------------

/// How often a connected client re-announces itself even when nothing happened,
/// so the daemon can expire clients that vanished without disconnecting.
const int heartbeatIntervalMs = 15000;

/// Floor on the gap between two *activity-triggered* heartbeats. Typing fires
/// activity constantly; this keeps that from becoming a message per keystroke.
const int activityHeartbeatThrottleMs = 5000;

/// How often desktop polls the OS for a system-wide idle time, which lets the
/// tracker notice activity that happened in another app's window.
const int desktopIdlePollIntervalMs = 5000;

/// Upstream's `deviceType: "web" | "mobile"` string union.
///
/// Modelled as an enum with an explicit [wireValue] so the Dart type system
/// carries the constraint while the serialized payload stays byte-identical to
/// upstream.
enum HeartbeatDeviceType {
  web('web'),
  mobile('mobile');

  const HeartbeatDeviceType(this.wireValue);

  /// The exact string upstream puts on the wire.
  final String wireValue;
}

/// One heartbeat as the daemon receives it.
///
/// Timestamps are pre-rendered ISO-8601 strings rather than [DateTime] because
/// the wire format is the contract: upstream sends `Date.prototype.toISOString`
/// output, and the daemon parses that.
final class HeartbeatPayload {
  const HeartbeatPayload({
    required this.deviceType,
    required this.focusedAgentId,
    required this.focusedTerminalId,
    required this.lastActivityAt,
    required this.appVisible,
    this.appVisibilityChangedAt,
  });

  final HeartbeatDeviceType deviceType;
  final String? focusedAgentId;
  final String? focusedTerminalId;
  final String lastActivityAt;
  final bool appVisible;

  /// Optional in upstream's interface, but [ClientActivityTracker] always
  /// populates it — the field is nullable purely to keep the shape faithful for
  /// any other producer.
  final String? appVisibilityChangedAt;

  @override
  String toString() =>
      'HeartbeatPayload(deviceType: ${deviceType.wireValue}, '
      'focusedAgentId: $focusedAgentId, '
      'focusedTerminalId: $focusedTerminalId, '
      'lastActivityAt: $lastActivityAt, '
      'appVisible: $appVisible, '
      'appVisibilityChangedAt: $appVisibilityChangedAt)';
}

/// The transport the tracker talks through.
///
/// Kept as a port rather than a concrete socket so the tracker never has to
/// know about reconnection: it just asks [isConnected] before every send, and a
/// disconnected client silently drops the heartbeat instead of queueing it.
abstract interface class HeartbeatClient {
  bool get isConnected;

  void sendHeartbeat(HeartbeatPayload payload);
}

/// Tracks what this client is doing and reports it to the daemon.
///
/// Time is injected as [now] — a `DateTime Function()` in place of upstream's
/// `() => number` — and every internal comparison happens in epoch
/// milliseconds. Sub-millisecond precision is intentionally discarded, matching
/// JavaScript's `Date`, which has none.
final class ClientActivityTracker {
  ClientActivityTracker({
    required this.client,
    required this.deviceType,
    required String? initialFocusedAgentId,
    required String? initialFocusedTerminalId,
    required bool initialAppVisible,
    required this.now,
    this.onAppResumed,
  }) : _focusedAgentId = initialFocusedAgentId,
       _focusedTerminalId = initialFocusedTerminalId,
       _appVisible = initialAppVisible {
    final startedAtMs = _nowMs();
    _lastActivityAtMs = startedAtMs;
    _appVisibilityChangedAtMs = startedAtMs;
    // A client that starts hidden is already "away", so a later resume can
    // report how long it was gone rather than reporting nothing.
    _backgroundedAtMs = _appVisible ? null : startedAtMs;
  }

  final HeartbeatClient client;
  final HeartbeatDeviceType deviceType;

  /// The injected clock. Nothing here reads the wall clock directly.
  final DateTime Function() now;

  /// Reports how long the app spent in the background, once per resume.
  final void Function(int awayMs)? onAppResumed;

  late int _lastActivityAtMs;
  late int _appVisibilityChangedAtMs;
  late int? _backgroundedAtMs;
  bool _appVisible;
  String? _focusedAgentId;
  String? _focusedTerminalId;

  /// Upstream seeds this with `0`, i.e. the Unix epoch, not "never". The
  /// difference is observable: with a clock reading less than
  /// [activityHeartbeatThrottleMs], the very first
  /// [maybeSendImmediateHeartbeat] is throttled away. Reproduced rather than
  /// "fixed" so behaviour matches for any injected clock.
  int _lastImmediateHeartbeatAtMs = 0;

  int _nowMs() => now().millisecondsSinceEpoch;

  /// Renders epoch milliseconds the way JavaScript's `toISOString` does.
  ///
  /// Dart emits exactly three fractional digits and a `Z` suffix for a UTC
  /// [DateTime] whose microsecond component is zero, which is guaranteed here
  /// because the value round-trips through milliseconds.
  static String _isoFromMs(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

  /// Sends the current state, or does nothing while disconnected.
  ///
  /// Also the "on connect" heartbeat: callers invoke it directly when the
  /// socket comes up and on the [heartbeatIntervalMs] tick.
  void sendHeartbeat() {
    if (!client.isConnected) return;
    client.sendHeartbeat(
      HeartbeatPayload(
        deviceType: deviceType,
        focusedAgentId: _focusedAgentId,
        focusedTerminalId: _focusedTerminalId,
        lastActivityAt: _isoFromMs(_lastActivityAtMs),
        appVisible: _appVisible,
        appVisibilityChangedAt: _isoFromMs(_appVisibilityChangedAtMs),
      ),
    );
  }

  /// Notes that the user did something. Deliberately does not send: the next
  /// heartbeat, throttled or scheduled, carries the new timestamp.
  void recordUserActivity() {
    _lastActivityAtMs = _nowMs();
  }

  /// Sends now unless one went out within [activityHeartbeatThrottleMs].
  ///
  /// The throttle clock is only advanced when a send actually happens, so time
  /// spent disconnected never burns the budget.
  void maybeSendImmediateHeartbeat() {
    if (!client.isConnected) return;
    final t = _nowMs();
    if (t - _lastImmediateHeartbeatAtMs < activityHeartbeatThrottleMs) return;
    _lastImmediateHeartbeatAtMs = t;
    sendHeartbeat();
  }

  /// Focus changes are worth an unthrottled heartbeat because the daemon routes
  /// notifications by them — a stale focus means a misdirected notification.
  void setFocusedAgentId(String? id) {
    if (_focusedAgentId == id) return;
    _focusedAgentId = id;
    recordUserActivity();
    sendHeartbeat();
  }

  /// See [setFocusedAgentId]; same reasoning for the focused terminal.
  void setFocusedTerminalId(String? id) {
    if (_focusedTerminalId == id) return;
    _focusedTerminalId = id;
    recordUserActivity();
    sendHeartbeat();
  }

  /// Records a foreground/background transition.
  ///
  /// Returns upstream's `{ changed: boolean }` as a Dart record so callers can
  /// skip their own work on a redundant platform event (both web and mobile
  /// fire visibility events that repeat the current state).
  ///
  /// Coming back to the foreground counts as user activity and reports the away
  /// duration through `onAppResumed`; going away does not, and a resume with no
  /// preceding background — the initial-visible case — reports nothing.
  ({bool changed}) notifyAppVisibility(bool nextVisible) {
    if (_appVisible == nextVisible) return (changed: false);
    _appVisible = nextVisible;
    _appVisibilityChangedAtMs = _nowMs();
    if (!nextVisible) {
      _backgroundedAtMs = _nowMs();
      return (changed: true);
    }
    final at = _backgroundedAtMs;
    _backgroundedAtMs = null;
    if (at != null) {
      // Clamped because a clock that jumped backwards must not report a
      // negative absence.
      final awayMs = _nowMs() - at;
      onAppResumed?.call(awayMs < 0 ? 0 : awayMs);
    }
    recordUserActivity();
    return (changed: true);
  }

  /// Folds an OS-level idle reading into the activity timestamp.
  ///
  /// A `null` reading means the poll failed and is ignored — it is not evidence
  /// of idleness. Otherwise the implied activity time only ever moves the
  /// timestamp *forward*: in-app activity the OS has already forgotten must not
  /// be undone by a coarser system reading.
  void notifySystemIdleMs(int? idleMs) {
    if (idleMs == null) return;
    final systemLastActivityAtMs = _nowMs() - idleMs;
    if (systemLastActivityAtMs > _lastActivityAtMs) {
      _lastActivityAtMs = systemLastActivityAtMs;
    }
  }
}

// ---------------------------------------------------------------------------
// hardware-keyboard-submit-controller.ts
// ---------------------------------------------------------------------------

/// Handle returned by [HardwareKeyboardSubmitListenerPort.addListener].
///
/// Upstream returns an object literal `{ remove }`; modelled as an interface so
/// platform implementations can hand back whatever they already own.
abstract interface class HardwareKeyboardSubmitSubscription {
  void remove();
}

/// The platform side of "the hardware keyboard asked to send".
///
/// Split into a port because the native module has to be told to *arm* itself
/// ([setEnabled]) separately from delivering events — mobile keeps the native
/// key interception off while no composer wants it.
abstract interface class HardwareKeyboardSubmitListenerPort {
  HardwareKeyboardSubmitSubscription addListener(void Function() handler);

  void setEnabled(bool enabled);
}

/// Arms and disarms hardware-keyboard submit, dispatching to the latest handler.
///
/// The indirection through [setOnSubmit] exists so a composer can swap its
/// submit closure (new draft, new agent) without re-subscribing, and so
/// [enable] is idempotent: repeated calls never stack listeners, which would
/// otherwise send the same message twice.
final class HardwareKeyboardSubmitController {
  HardwareKeyboardSubmitController(this._port);

  final HardwareKeyboardSubmitListenerPort _port;
  HardwareKeyboardSubmitSubscription? _subscription;

  /// Upstream defaults to a no-op function rather than null, so enabling before
  /// a handler is set is harmless instead of throwing.
  void Function() _onSubmit = _noop;

  static void _noop() {}

  /// Replaces the handler. Safe at any time; takes effect on the next event
  /// even while already enabled.
  void setOnSubmit(void Function() handler) {
    _onSubmit = handler;
  }

  /// Subscribes and arms the native listener. No-op when already enabled.
  void enable() {
    if (_subscription != null) return;
    // Dispatch through a trampoline, not `_onSubmit` directly, so a later
    // setOnSubmit is honoured by the already-registered listener.
    _subscription = _port.addListener(() => _onSubmit());
    _port.setEnabled(true);
  }

  /// Disarms and unsubscribes. No-op when never enabled.
  ///
  /// Disarms before unsubscribing, matching upstream, so no event can be
  /// delivered to a listener that is about to disappear.
  void disable() {
    final subscription = _subscription;
    if (subscription == null) return;
    _port.setEnabled(false);
    subscription.remove();
    _subscription = null;
  }
}

// ---------------------------------------------------------------------------
// hover-safe-zone-tracker.ts
// ---------------------------------------------------------------------------

/// Upstream's `RectLike`.
///
/// Deliberately not `dart:ui`'s [Rect]: `Rect.contains` treats the right and
/// bottom edges as exclusive, while upstream's comparisons are inclusive on all
/// four sides. A pointer resting exactly on the trigger's bottom edge must stay
/// inside the safe zone, so the containment test is written out by hand below.
final class HoverRect {
  const HoverRect({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
  });

  final double left;
  final double right;
  final double top;
  final double bottom;
}

/// Tracks the pointer's position relative to a hover card's "safe zone": the
/// trigger, the content, and the rectangular bridge between them.
///
/// The bridge lets the pointer cross the visual gap without dropping the hover.
/// [pointerMoved] fires `onEnterSafeZone` on *every* move that lands inside so
/// consumers can refresh a dismiss timer, while `onLeaveSafeZone` fires once
/// per inside-to-outside transition so a dismiss is not scheduled repeatedly.
///
/// The rects are read through callbacks on every move because they are live
/// layout values — the card can reposition itself mid-hover.
final class HoverSafeZoneTracker {
  HoverSafeZoneTracker({
    required this.getTriggerRect,
    required this.getContentRect,
    required this.onEnterSafeZone,
    required this.onLeaveSafeZone,
  });

  /// Read fresh on every move: a hover card can reposition mid-hover, and a
  /// null result means the element is not mounted right now.
  final HoverRect? Function() getTriggerRect;
  final HoverRect? Function() getContentRect;
  final void Function() onEnterSafeZone;
  final void Function() onLeaveSafeZone;

  /// The pointer opened the card, so we start inside.
  bool _wasInside = true;

  void pointerMoved(double x, double y) {
    if (_isInsideSafeZone(getTriggerRect(), getContentRect(), x, y)) {
      _wasInside = true;
      onEnterSafeZone();
      return;
    }
    _leave();
  }

  /// The pointer exited the window entirely: there will be no further move
  /// events to detect the exit with, so treat it as a leave immediately.
  void pointerLeftWindow() => _leave();

  /// Focus went elsewhere (another window, a system dialog). The pointer may
  /// still be geometrically inside, but the hover intent is gone.
  void windowBlurred() => _leave();

  void _leave() {
    if (!_wasInside) return;
    _wasInside = false;
    onLeaveSafeZone();
  }
}

/// Inclusive on all four edges — see [HoverRect] for why. A missing rect is
/// never containing, standing in for upstream's `if (!rect) return false`.
bool _isInsideRect(HoverRect? rect, double x, double y) {
  if (rect == null) return false;
  return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
}

bool _isInsideSafeZone(
  HoverRect? trigger,
  HoverRect? content,
  double x,
  double y,
) {
  if (_isInsideRect(trigger, x, y)) return true;
  if (_isInsideRect(content, x, y)) return true;
  if (trigger == null || content == null) return false;

  // Bridge: the horizontal strip connecting trigger and content, stretched
  // vertically to span both. The min/max pairing works for either ordering, so
  // content placed to the left of its trigger bridges just as well. If they
  // overlap horizontally there is no gap to bridge and the strip is empty.
  final bridgeLeft = trigger.right < content.right
      ? trigger.right
      : content.right;
  final bridgeRight = trigger.left > content.left ? trigger.left : content.left;
  if (bridgeLeft >= bridgeRight) return false;
  final bridgeTop = trigger.top < content.top ? trigger.top : content.top;
  final bridgeBottom = trigger.bottom > content.bottom
      ? trigger.bottom
      : content.bottom;
  return x >= bridgeLeft &&
      x <= bridgeRight &&
      y >= bridgeTop &&
      y <= bridgeBottom;
}

// ---------------------------------------------------------------------------
// use-container-width.ts
// ---------------------------------------------------------------------------

/// Tracks the measured width of a container.
///
/// Upstream is a React hook whose `setState` re-renders the subscriber; the
/// Dart equivalent is a [ChangeNotifier], so "upstream re-rendered" reads as
/// "this notified". React bails out of a re-render when the new state is
/// identical to the old, so [onLayout] notifies only on an actual change.
final class ContainerWidthTracker extends ChangeNotifier {
  ContainerWidthTracker();

  double _width = 0;

  double get width => _width;

  /// Feeds one layout measurement in. Returns whether the tracked width
  /// changed, which is the same condition under which listeners are notified —
  /// handy for callers that drive this outside a widget.
  bool onLayout(double width) {
    if (_width == width) return false;
    _width = width;
    notifyListeners();
    return true;
  }
}

/// Tracks only whether a container is narrower than [threshold].
///
/// The point is the coarseness: a responsive layout that only cares about one
/// breakpoint rebuilds twice over a resize instead of once per layout pass.
final class ContainerWidthBelowTracker extends ChangeNotifier {
  /// [initialIsBelow] defaults to `true` — upstream's `?? true` — because the
  /// compact layout is the safer thing to render before the first measurement
  /// arrives.
  ContainerWidthBelowTracker({
    required this.threshold,
    bool initialIsBelow = true,
  }) : _isBelow = initialIsBelow;

  final double threshold;
  bool _isBelow;

  bool get isBelow => _isBelow;

  /// Feeds one layout measurement in. Returns whether [isBelow] flipped.
  ///
  /// Non-positive widths are dropped rather than treated as "extremely narrow":
  /// mounted-but-hidden content measures zero, and letting that flip the layout
  /// would make the container jump when it is revealed.
  bool onLayout(double width) {
    if (width <= 0) return false;
    final nextIsBelow = width < threshold;
    if (_isBelow == nextIsBelow) return false;
    _isBelow = nextIsBelow;
    notifyListeners();
    return true;
  }
}
