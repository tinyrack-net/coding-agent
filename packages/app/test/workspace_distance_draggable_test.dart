import 'package:coding_agent_app/workspace/workspace_distance_draggable.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets('activates $kind only after Euclidean distance exceeds 8', (
      tester,
    ) async {
      var starts = 0;
      var cancels = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Overlay(
            initialEntries: [
              OverlayEntry(
                builder: (context) => Align(
                  alignment: Alignment.topLeft,
                  child: WorkspaceDistanceDraggable<String>(
                    activationDistance: 8,
                    data: 'tab',
                    onDragStarted: () => starts += 1,
                    onPointerCancel: () => cancels += 1,
                    feedback: const SizedBox(
                      key: ValueKey('feedback'),
                      width: 40,
                      height: 40,
                    ),
                    child: const ColoredBox(
                      key: ValueKey('source'),
                      color: Color(0xff000000),
                      child: SizedBox(width: 100, height: 40),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('source'))),
        kind: kind,
      );
      await gesture.moveBy(const Offset(8, 0));
      await tester.pump();
      expect(starts, 0);
      expect(find.byKey(const ValueKey('feedback')), findsNothing);

      await gesture.moveBy(const Offset(1, 0));
      await tester.pump();
      expect(starts, 1);
      expect(find.byKey(const ValueKey('feedback')), findsOneWidget);

      await gesture.cancel();
      await tester.pump();
      expect(cancels, 1);
      expect(find.byKey(const ValueKey('feedback')), findsNothing);
    });
  }

  testWidgets('uses Euclidean rather than per-axis distance', (tester) async {
    var starts = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Overlay(
          initialEntries: [
            OverlayEntry(
              builder: (context) => WorkspaceDistanceDraggable<String>(
                activationDistance: 8,
                data: 'tab',
                onDragStarted: () => starts += 1,
                feedback: const SizedBox(width: 40, height: 40),
                child: const ColoredBox(
                  key: ValueKey('source'),
                  color: Color(0xff000000),
                  child: SizedBox(width: 100, height: 40),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('source'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(6, 6));
    await tester.pump();
    expect(starts, 1);
    await gesture.cancel();
  });
}
