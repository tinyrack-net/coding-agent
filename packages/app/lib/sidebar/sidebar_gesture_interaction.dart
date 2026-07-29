import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'sidebar_gesture_arbitration.dart';

const sidebarDragArmDelay = Duration(milliseconds: 180);
const sidebarContextMenuDelay = Duration(milliseconds: 450);
const sidebarDragArmStationarySlop = 4.0;
const sidebarContextMenuStationarySlop = 6.0;

bool get _usesTouchSidebarGestures {
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    _ => false,
  };
}

/// Paseo-compatible drag listener for a sidebar reorderable list item.
///
/// Desktop starts on primary-button movement. Mobile arms after 180ms only
/// while the pointer remains within Paseo's 4px stationary radius, and yields
/// early to vertical scrolling or horizontal swipe gestures.
class SidebarReorderDragStartListener extends ReorderableDragStartListener {
  const SidebarReorderDragStartListener({
    super.key,
    required super.child,
    required super.index,
    super.enabled,
    this.useTouchGestures,
  });

  final bool? useTouchGestures;

  @override
  MultiDragGestureRecognizer createRecognizer() {
    if (useTouchGestures ?? _usesTouchSidebarGestures) {
      return SidebarDelayedMultiDragGestureRecognizer(debugOwner: this);
    }
    return ImmediateMultiDragGestureRecognizer(debugOwner: this);
  }
}

/// Delayed multi-drag recognizer with Paseo's mobile timing and movement rules.
class SidebarDelayedMultiDragGestureRecognizer
    extends MultiDragGestureRecognizer {
  SidebarDelayedMultiDragGestureRecognizer({
    this.delay = sidebarDragArmDelay,
    super.debugOwner,
    super.supportedDevices,
    super.allowedButtonsFilter,
  });

  final Duration delay;

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    return _SidebarDelayedPointerState(
      event.position,
      delay,
      event.kind,
      gestureSettings,
    );
  }

  @override
  String get debugDescription => 'Paseo sidebar long multidrag';
}

class _SidebarDelayedPointerState extends MultiDragPointerState {
  _SidebarDelayedPointerState(
    super.initialPosition,
    Duration delay,
    super.kind,
    super.gestureSettings,
  ) {
    _timer = Timer(delay, _delayPassed);
  }

  Timer? _timer;
  GestureMultiDragStartCallback? _starter;
  bool _rejected = false;

  void _delayPassed() {
    final delta = pendingDelta;
    _timer = null;
    if (delta == null || delta.distance > sidebarDragArmStationarySlop) {
      _reject();
      return;
    }
    unawaited(HapticFeedback.selectionClick());
    if (_starter case final starter?) {
      _starter = null;
      starter(initialPosition);
    } else {
      resolve(GestureDisposition.accepted);
    }
  }

  void _reject() {
    if (_rejected) return;
    _rejected = true;
    _timer?.cancel();
    _timer = null;
    resolve(GestureDisposition.rejected);
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    if (_timer == null) {
      starter(initialPosition);
    } else {
      _starter = starter;
    }
  }

  @override
  void checkForResolutionAfterMove() {
    final delta = pendingDelta;
    if (delta == null) return;
    if (_timer == null || _rejected) return;
    final decision = decideSidebarLongPressMove(
      dragArmed: false,
      didStartDrag: false,
      startPoint: Offset.zero,
      currentPoint: delta,
    );
    if (decision != SidebarLongPressMoveDecision.none) {
      _reject();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

/// Adds Paseo's stationary touch context-menu timer and desktop secondary tap
/// without joining the gesture arena used by scrolling and reordering.
class SidebarContextMenuRegion extends StatefulWidget {
  const SidebarContextMenuRegion({
    super.key,
    required this.onOpen,
    required this.child,
    this.enableTouchTimer,
  });

  final ValueChanged<Offset> onOpen;
  final Widget child;
  final bool? enableTouchTimer;

  @override
  State<SidebarContextMenuRegion> createState() =>
      _SidebarContextMenuRegionState();
}

class _SidebarContextMenuRegionState extends State<SidebarContextMenuRegion> {
  Timer? _timer;
  int? _pointer;
  Offset? _start;

  bool get _touchTimerEnabled =>
      widget.enableTouchTimer ?? _usesTouchSidebarGestures;

  void _cancelTouchTimer() {
    _timer?.cancel();
    _timer = null;
    _pointer = null;
    _start = null;
  }

  void _handleDown(PointerDownEvent event) {
    if ((event.buttons & kSecondaryMouseButton) != 0) {
      _cancelTouchTimer();
      widget.onOpen(event.position);
      return;
    }
    if (!_touchTimerEnabled ||
        (event.kind != PointerDeviceKind.touch &&
            event.kind != PointerDeviceKind.stylus &&
            event.kind != PointerDeviceKind.invertedStylus)) {
      return;
    }

    _cancelTouchTimer();
    _pointer = event.pointer;
    _start = event.position;
    _timer = Timer(sidebarContextMenuDelay, () {
      final start = _start;
      if (!mounted || start == null) return;
      _timer = null;
      unawaited(HapticFeedback.selectionClick());
      widget.onOpen(start);
    });
  }

  void _handleMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    final start = _start;
    if (start == null) return;
    if ((event.position - start).distance > sidebarContextMenuStationarySlop) {
      _cancelTouchTimer();
    }
  }

  void _handleEnd(PointerEvent event) {
    if (event.pointer == _pointer) {
      _cancelTouchTimer();
    }
  }

  @override
  void dispose() {
    _cancelTouchTimer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handleDown,
      onPointerMove: _handleMove,
      onPointerUp: _handleEnd,
      onPointerCancel: _handleEnd,
      child: widget.child,
    );
  }
}
