import 'package:coding_agent_app/sidebar/sidebar_gesture_arbitration.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decideSidebarLongPressMove', () {
    test('keeps long press pending for small movement before arm', () {
      expect(
        decideSidebarLongPressMove(
          dragArmed: false,
          didStartDrag: false,
          startPoint: Offset.zero,
          currentPoint: const Offset(3, 2),
        ),
        SidebarLongPressMoveDecision.none,
      );
    });

    test('cancels long press when movement exceeds cancel slop', () {
      expect(
        decideSidebarLongPressMove(
          dragArmed: false,
          didStartDrag: false,
          startPoint: Offset.zero,
          currentPoint: const Offset(8, 8),
        ),
        SidebarLongPressMoveDecision.cancelLongPress,
      );
    });

    test('yields to vertical scroll before drag arm', () {
      expect(
        decideSidebarLongPressMove(
          dragArmed: false,
          didStartDrag: false,
          startPoint: Offset.zero,
          currentPoint: const Offset(2, 7),
        ),
        SidebarLongPressMoveDecision.verticalScroll,
      );
    });

    test('keeps diagonal motion neutral before drag arm', () {
      expect(
        decideSidebarLongPressMove(
          dragArmed: false,
          didStartDrag: false,
          startPoint: Offset.zero,
          currentPoint: const Offset(5, 7),
        ),
        SidebarLongPressMoveDecision.none,
      );
    });

    test('yields to horizontal swipe before drag arm', () {
      expect(
        decideSidebarLongPressMove(
          dragArmed: false,
          didStartDrag: false,
          startPoint: Offset.zero,
          currentPoint: const Offset(-10, 2),
        ),
        SidebarLongPressMoveDecision.horizontalSwipe,
      );
    });

    test('starts drag beyond drag slop after arm', () {
      expect(
        decideSidebarLongPressMove(
          dragArmed: true,
          didStartDrag: false,
          startPoint: Offset.zero,
          currentPoint: const Offset(0, 9),
        ),
        SidebarLongPressMoveDecision.startDrag,
      );
    });

    test('does nothing after drag already started', () {
      expect(
        decideSidebarLongPressMove(
          dragArmed: true,
          didStartDrag: true,
          startPoint: Offset.zero,
          currentPoint: const Offset(20, 20),
        ),
        SidebarLongPressMoveDecision.none,
      );
    });
  });

  test('context menu opens only for armed non-drag press', () {
    expect(
      shouldOpenSidebarContextMenuOnPressOut(
        longPressArmed: true,
        didStartDrag: false,
      ),
      isTrue,
    );
    expect(
      shouldOpenSidebarContextMenuOnPressOut(
        longPressArmed: false,
        didStartDrag: false,
      ),
      isFalse,
    );
    expect(
      shouldOpenSidebarContextMenuOnPressOut(
        longPressArmed: true,
        didStartDrag: true,
      ),
      isFalse,
    );
  });
}
