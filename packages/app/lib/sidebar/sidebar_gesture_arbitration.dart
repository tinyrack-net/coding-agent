import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Paseo's decision after a pointer moves during a sidebar long press.
enum SidebarLongPressMoveDecision {
  none,
  cancelLongPress,
  verticalScroll,
  horizontalSwipe,
  startDrag,
}

/// Classifies pointer movement using the frozen Paseo 0.2.0 thresholds.
SidebarLongPressMoveDecision decideSidebarLongPressMove({
  required bool dragArmed,
  required bool didStartDrag,
  required Offset? startPoint,
  required Offset currentPoint,
  double cancelSlop = 10,
  double scrollSlop = 6,
  double swipeSlop = 8,
  double directionalDominanceRatio = 1.5,
  double dragSlop = 8,
}) {
  if (startPoint == null || didStartDrag) {
    return SidebarLongPressMoveDecision.none;
  }

  final delta = currentPoint - startPoint;
  final absDx = delta.dx.abs();
  final absDy = delta.dy.abs();
  final distance = math.sqrt(delta.dx * delta.dx + delta.dy * delta.dy);
  final clearlyVertical = absDy >= absDx * directionalDominanceRatio;
  final clearlyHorizontal = absDx >= absDy * directionalDominanceRatio;

  if (!dragArmed) {
    if (clearlyVertical && absDy > scrollSlop) {
      return SidebarLongPressMoveDecision.verticalScroll;
    }
    if (clearlyHorizontal && absDx > swipeSlop) {
      return SidebarLongPressMoveDecision.horizontalSwipe;
    }
    return distance > cancelSlop
        ? SidebarLongPressMoveDecision.cancelLongPress
        : SidebarLongPressMoveDecision.none;
  }
  return distance > dragSlop
      ? SidebarLongPressMoveDecision.startDrag
      : SidebarLongPressMoveDecision.none;
}

/// Whether releasing a stationary long press should open its context menu.
bool shouldOpenSidebarContextMenuOnPressOut({
  required bool longPressArmed,
  required bool didStartDrag,
}) => longPressArmed && !didStartDrag;
