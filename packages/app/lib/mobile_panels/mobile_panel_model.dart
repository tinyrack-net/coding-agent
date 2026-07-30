import 'dart:math' as math;

enum MobilePanelView { agent, agentList, fileExplorer }

class MobilePanelSelection {
  const MobilePanelSelection({required this.target, required this.revision});

  const MobilePanelSelection.initial()
    : target = MobilePanelView.agent,
      revision = 0;

  final MobilePanelView target;
  final int revision;

  MobilePanelSelection setTarget(MobilePanelView nextTarget) {
    if (target == nextTarget) return this;
    return MobilePanelSelection(target: nextTarget, revision: revision + 1);
  }

  @override
  bool operator ==(Object other) =>
      other is MobilePanelSelection &&
      other.target == target &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(target, revision);
}

class MobilePanelGesture {
  const MobilePanelGesture({required this.startedRevision});

  final int startedRevision;
}

class MobilePanelMotionState {
  const MobilePanelMotionState({
    required this.target,
    required this.revision,
    required this.gesture,
    required this.motionTarget,
    required this.settledTarget,
  });

  factory MobilePanelMotionState.fromSelection(MobilePanelSelection selection) {
    return MobilePanelMotionState(
      target: selection.target,
      revision: selection.revision,
      gesture: null,
      motionTarget: selection.target,
      settledTarget: selection.target,
    );
  }

  final MobilePanelView target;
  final int revision;
  final MobilePanelGesture? gesture;
  final MobilePanelView motionTarget;
  final MobilePanelView settledTarget;

  MobilePanelMotionState copyWith({
    MobilePanelView? target,
    int? revision,
    MobilePanelGesture? gesture,
    bool clearGesture = false,
    MobilePanelView? motionTarget,
    MobilePanelView? settledTarget,
  }) {
    return MobilePanelMotionState(
      target: target ?? this.target,
      revision: revision ?? this.revision,
      gesture: clearGesture ? null : gesture ?? this.gesture,
      motionTarget: motionTarget ?? this.motionTarget,
      settledTarget: settledTarget ?? this.settledTarget,
    );
  }
}

sealed class MobilePanelEvent {
  const MobilePanelEvent();
}

class MobilePanelCommand extends MobilePanelEvent {
  const MobilePanelCommand(this.selection);

  final MobilePanelSelection selection;
}

class MobilePanelGestureBegin extends MobilePanelEvent {
  const MobilePanelGestureBegin(this.origin);

  final MobilePanelView origin;
}

class MobilePanelGestureFinish extends MobilePanelEvent {
  const MobilePanelGestureFinish({
    required this.startedRevision,
    required this.success,
    required this.target,
  });

  final int startedRevision;
  final bool success;
  final MobilePanelView target;
}

class MobilePanelAnimationFinished extends MobilePanelEvent {
  const MobilePanelAnimationFinished({
    required this.revision,
    required this.target,
  });

  final int revision;
  final MobilePanelView target;
}

class MobilePanelCommit {
  const MobilePanelCommit({
    required this.startedRevision,
    required this.target,
  });

  final int startedRevision;
  final MobilePanelView target;
}

class MobilePanelTransition {
  const MobilePanelTransition({
    required this.state,
    this.animationTarget,
    this.commit,
  });

  final MobilePanelMotionState state;
  final MobilePanelView? animationTarget;
  final MobilePanelCommit? commit;
}

MobilePanelTransition transitionMobilePanel(
  MobilePanelMotionState state,
  MobilePanelEvent event,
) {
  switch (event) {
    case MobilePanelCommand():
      if (event.selection.revision <= state.revision) {
        return MobilePanelTransition(state: state);
      }
      return MobilePanelTransition(
        animationTarget: event.selection.target,
        state: MobilePanelMotionState(
          target: event.selection.target,
          revision: event.selection.revision,
          gesture: null,
          motionTarget: event.selection.target,
          settledTarget: state.settledTarget,
        ),
      );
    case MobilePanelGestureBegin():
      if (state.gesture != null ||
          state.target != event.origin ||
          state.motionTarget != event.origin ||
          state.settledTarget != event.origin) {
        return MobilePanelTransition(state: state);
      }
      return MobilePanelTransition(
        state: state.copyWith(
          gesture: MobilePanelGesture(startedRevision: state.revision),
        ),
      );
    case MobilePanelGestureFinish():
      final gesture = state.gesture;
      final ownsCurrentRevision = gesture?.startedRevision == state.revision;
      final ownsFinish = gesture?.startedRevision == event.startedRevision;
      if (!ownsCurrentRevision || !ownsFinish || gesture == null) {
        return MobilePanelTransition(state: state);
      }
      final target = event.success ? event.target : state.target;
      final commit = event.success && target != state.target
          ? MobilePanelCommit(
              startedRevision: gesture.startedRevision,
              target: target,
            )
          : null;
      return MobilePanelTransition(
        animationTarget: target,
        commit: commit,
        state: state.copyWith(clearGesture: true, motionTarget: target),
      );
    case MobilePanelAnimationFinished():
      final ownsCurrentRevision = event.revision == state.revision;
      final isCanonicalTarget = event.target == state.target;
      final isCurrentMotionTarget = event.target == state.motionTarget;
      if (!ownsCurrentRevision ||
          !isCanonicalTarget ||
          !isCurrentMotionTarget) {
        return MobilePanelTransition(state: state);
      }
      return MobilePanelTransition(
        state: state.copyWith(settledTarget: event.target),
      );
  }
}

double getMobilePanelAnchor(MobilePanelView panel) => switch (panel) {
  MobilePanelView.agentList => -1,
  MobilePanelView.fileExplorer => 1,
  MobilePanelView.agent => 0,
};

bool canBeginMobilePanelGesture(
  MobilePanelMotionState state,
  MobilePanelView origin,
  double position,
) {
  final isCanonical = state.target == origin;
  final isMotionSettled =
      state.motionTarget == origin && state.settledTarget == origin;
  final isAtOrigin = (position - getMobilePanelAnchor(origin)).abs() <= 0.002;
  return state.gesture == null && isCanonical && isMotionSettled && isAtOrigin;
}

bool isMobilePanelGestureCurrent(
  MobilePanelMotionState state,
  int startedRevision,
) {
  return state.revision == startedRevision &&
      state.gesture?.startedRevision == startedRevision;
}

class MobilePanelFrame {
  const MobilePanelFrame({
    required this.leftBackdropOpacity,
    required this.leftTranslateX,
    required this.rightBackdropOpacity,
    required this.rightTranslateX,
  });

  final double leftBackdropOpacity;
  final double leftTranslateX;
  final double rightBackdropOpacity;
  final double rightTranslateX;
}

MobilePanelFrame getMobilePanelFrame(double position, double width) {
  final clampedPosition = position.clamp(-1.0, 1.0);
  return MobilePanelFrame(
    leftBackdropOpacity: math.max(0, -clampedPosition),
    leftTranslateX: -math.min(1, clampedPosition + 1) * width,
    rightBackdropOpacity: math.max(0, clampedPosition),
    rightTranslateX: math.min(1, 1 - clampedPosition) * width,
  );
}
