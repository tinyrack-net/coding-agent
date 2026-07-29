import 'package:coding_agent_app/sidebar/sidebar_gesture_interaction.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestDrag extends Drag {}

void main() {
  testWidgets('stationary touch opens context menu at exactly 450ms', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    Offset? openedAt;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SidebarContextMenuRegion(
          enableTouchTimer: true,
          onOpen: (position) => openedAt = position,
          child: const SizedBox(width: 100, height: 100),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      const Offset(25, 35),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 449));
    expect(openedAt, isNull);
    await tester.pump(const Duration(milliseconds: 1));
    expect(openedAt, const Offset(25, 35));
    expect(
      calls
          .where((call) => call.method == 'HapticFeedback.vibrate')
          .map((call) => call.arguments),
      ['HapticFeedbackType.selectionClick'],
    );
    await gesture.up();
  });

  testWidgets('touch movement beyond 6px cancels context menu', (tester) async {
    var openCount = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SidebarContextMenuRegion(
          enableTouchTimer: true,
          onOpen: (_) => openCount++,
          child: const SizedBox(width: 100, height: 100),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      const Offset(25, 35),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveTo(const Offset(25, 42));
    await tester.pump(sidebarContextMenuDelay);
    expect(openCount, 0);
    await gesture.up();
  });

  testWidgets('secondary pointer opens context menu immediately', (
    tester,
  ) async {
    Offset? openedAt;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SidebarContextMenuRegion(
          onOpen: (position) => openedAt = position,
          child: const SizedBox(width: 100, height: 100),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      const Offset(40, 45),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    expect(openedAt, const Offset(40, 45));
    await gesture.up();
  });

  testWidgets('reorder listener selects Paseo delayed recognizer on touch', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SidebarReorderDragStartListener(
          index: 0,
          useTouchGestures: true,
          child: SizedBox(),
        ),
      ),
    );

    final listener = tester.widget<SidebarReorderDragStartListener>(
      find.byType(SidebarReorderDragStartListener),
    );
    final recognizer = listener.createRecognizer();
    addTearDown(recognizer.dispose);
    expect(recognizer, isA<SidebarDelayedMultiDragGestureRecognizer>());
    expect(
      (recognizer as SidebarDelayedMultiDragGestureRecognizer).delay,
      sidebarDragArmDelay,
    );
  });

  testWidgets('reorder listener remains immediate on desktop', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SidebarReorderDragStartListener(
          index: 0,
          useTouchGestures: false,
          child: SizedBox(),
        ),
      ),
    );

    final listener = tester.widget<SidebarReorderDragStartListener>(
      find.byType(SidebarReorderDragStartListener),
    );
    final recognizer = listener.createRecognizer();
    addTearDown(recognizer.dispose);
    expect(recognizer, isA<ImmediateMultiDragGestureRecognizer>());
  });

  testWidgets('armed touch drag emits medium impact once beyond 8px', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SidebarReorderDragStartListener(
          index: 0,
          useTouchGestures: true,
          child: SizedBox(
            key: ValueKey('feedback-target'),
            width: 100,
            height: 60,
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('feedback-target'))),
      kind: PointerDeviceKind.touch,
      buttons: kPrimaryButton,
    );
    await tester.pump(const Duration(milliseconds: 181));
    await gesture.moveBy(const Offset(0, 9));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 9));
    await tester.pump();

    expect(
      calls
          .where((call) => call.method == 'HapticFeedback.vibrate')
          .map((call) => call.arguments),
      ['HapticFeedbackType.mediumImpact'],
    );
    await gesture.up();
  });

  testWidgets('pre-arm scroll movement suppresses drag impact', (tester) async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SidebarReorderDragStartListener(
          index: 0,
          useTouchGestures: true,
          child: SizedBox(
            key: ValueKey('feedback-target'),
            width: 100,
            height: 60,
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('feedback-target'))),
      kind: PointerDeviceKind.touch,
      buttons: kPrimaryButton,
    );
    await gesture.moveBy(const Offset(2, 7));
    await tester.pump(sidebarDragArmDelay);
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();

    expect(
      calls.where(
        (call) =>
            call.method == 'HapticFeedback.vibrate' &&
            call.arguments == 'HapticFeedbackType.mediumImpact',
      ),
      isEmpty,
    );
    await gesture.up();
  });

  testWidgets('touch reorder starts at the 180ms arm threshold', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    var startCount = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            SidebarDelayedMultiDragGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  SidebarDelayedMultiDragGestureRecognizer
                >(SidebarDelayedMultiDragGestureRecognizer.new, (recognizer) {
                  recognizer.onStart = (_) {
                    startCount++;
                    return _TestDrag();
                  };
                }),
          },
          child: const SizedBox(
            key: ValueKey('drag-target'),
            width: 200,
            height: 60,
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('drag-target'))),
      kind: PointerDeviceKind.touch,
      buttons: kPrimaryButton,
    );
    await tester.pump(const Duration(milliseconds: 179));
    expect(startCount, 0);
    await tester.pump(const Duration(milliseconds: 2));
    expect(startCount, 1);
    expect(
      calls
          .where((call) => call.method == 'HapticFeedback.vibrate')
          .map((call) => call.arguments),
      ['HapticFeedbackType.selectionClick'],
    );
    await gesture.up();
  });

  testWidgets('touch reorder yields to vertical scroll before arm', (
    tester,
  ) async {
    var startCount = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            SidebarDelayedMultiDragGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  SidebarDelayedMultiDragGestureRecognizer
                >(SidebarDelayedMultiDragGestureRecognizer.new, (recognizer) {
                  recognizer.onStart = (_) {
                    startCount++;
                    return _TestDrag();
                  };
                }),
          },
          child: const SizedBox(
            key: ValueKey('drag-target'),
            width: 200,
            height: 60,
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('drag-target'))),
      kind: PointerDeviceKind.touch,
      buttons: kPrimaryButton,
    );
    await gesture.moveBy(const Offset(2, 7));
    await tester.pump(sidebarDragArmDelay);
    expect(startCount, 0);
    await gesture.up();
  });
}
