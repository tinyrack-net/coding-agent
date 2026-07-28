import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// A [Draggable] whose pointer sensor activates only after the pointer has
/// travelled strictly farther than [activationDistance].
///
/// Paseo 0.2.0 configures dnd-kit's PointerSensor with `distance: 8`.
/// dnd-kit 6.3.1 compares Euclidean distance with `>`, not `>=`; keeping that
/// detail here makes mouse, pen, and touch activation share the same contract.
class WorkspaceDistanceDraggable<T extends Object> extends Draggable<T> {
  const WorkspaceDistanceDraggable({
    super.key,
    required super.child,
    required super.feedback,
    required this.activationDistance,
    super.data,
    super.childWhenDragging,
    super.feedbackOffset,
    super.dragAnchorStrategy,
    super.maxSimultaneousDrags,
    super.onDragStarted,
    super.onDragUpdate,
    super.onDraggableCanceled,
    super.onDragEnd,
    super.onDragCompleted,
    this.onPointerCancel,
    super.ignoringFeedbackSemantics,
    super.ignoringFeedbackPointer,
    super.rootOverlay,
    super.hitTestBehavior,
    super.allowedButtonsFilter,
  }) : assert(activationDistance >= 0);

  final double activationDistance;
  final VoidCallback? onPointerCancel;

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) => _WorkspaceDistanceMultiDragGestureRecognizer(
    activationDistance: activationDistance,
    debugOwner: this,
    allowedButtonsFilter: allowedButtonsFilter,
    onPointerCancel: onPointerCancel,
  )..onStart = onStart;
}

final class _WorkspaceDistanceMultiDragGestureRecognizer
    extends MultiDragGestureRecognizer {
  _WorkspaceDistanceMultiDragGestureRecognizer({
    required this.activationDistance,
    this.onPointerCancel,
    super.debugOwner,
    super.allowedButtonsFilter,
  });

  final double activationDistance;
  final VoidCallback? onPointerCancel;
  final Set<int> _trackedPointers = {};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _trackedPointers.add(event.pointer);
    GestureBinding.instance.pointerRouter.addRoute(
      event.pointer,
      _handlePointerLifecycle,
    );
    super.addAllowedPointer(event);
  }

  void _handlePointerLifecycle(PointerEvent event) {
    if (event is PointerCancelEvent) onPointerCancel?.call();
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _removePointerLifecycleRoute(event.pointer);
    }
  }

  void _removePointerLifecycleRoute(int pointer) {
    if (!_trackedPointers.remove(pointer)) return;
    GestureBinding.instance.pointerRouter.removeRoute(
      pointer,
      _handlePointerLifecycle,
    );
  }

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _WorkspaceDistancePointerState(
        event.position,
        event.kind,
        gestureSettings,
        activationDistance,
      );

  @override
  String get debugDescription => 'workspace distance multidrag';

  @override
  void dispose() {
    for (final pointer in _trackedPointers.toList()) {
      _removePointerLifecycleRoute(pointer);
    }
    super.dispose();
  }
}

final class _WorkspaceDistancePointerState extends MultiDragPointerState {
  _WorkspaceDistancePointerState(
    super.initialPosition,
    super.kind,
    super.gestureSettings,
    this.activationDistance,
  );

  final double activationDistance;
  GestureMultiDragStartCallback? _starter;
  bool _started = false;

  @override
  void checkForResolutionAfterMove() {
    final delta = pendingDelta;
    if (delta != null && delta.distance > activationDistance) {
      if (_starter == null) {
        resolve(GestureDisposition.accepted);
      } else {
        _startIfExceeded();
      }
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    _starter = starter;
    _startIfExceeded();
  }

  void _startIfExceeded() {
    final delta = pendingDelta;
    final starter = _starter;
    if (_started ||
        starter == null ||
        delta == null ||
        delta.distance <= activationDistance) {
      return;
    }
    _started = true;
    _starter = null;
    starter(initialPosition);
  }
}
