import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/widgets/sidebar_resize_handle.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('uses the frozen 10px boundary hit area and resize cursor', (
    tester,
  ) async {
    await _pump(tester);

    final handle = find.byKey(const ValueKey('resize'));
    expect(tester.getRect(handle), const Rect.fromLTWH(195, 0, 10, 100));
    expect(
      tester.widget<MouseRegion>(handle).cursor,
      SystemMouseCursors.resizeColumn,
    );
  });

  testWidgets('shows the 1px highlight only after 100ms hover', (tester) async {
    await _pump(tester);
    final handle = find.byKey(const ValueKey('resize'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(100, 50));
    await mouse.moveTo(tester.getCenter(handle));

    await tester.pump(const Duration(milliseconds: 99));
    expect(find.byKey(const ValueKey('resize-highlight')), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    final highlight = find.byKey(const ValueKey('resize-highlight'));
    expect(highlight, findsOneWidget);
    expect(tester.getRect(highlight), const Rect.fromLTWH(200, 0, 1, 100));
    expect(
      tester
          .widget<ColoredBox>(
            find.descendant(of: highlight, matching: find.byType(ColoredBox)),
          )
          .color,
      paseoPaletteFor(AppThemeName.dark).foreground.withValues(alpha: 0.25),
    );

    await mouse.moveTo(const Offset(100, 50));
    await tester.pump();
    expect(highlight, findsNothing);
  });

  testWidgets('forwards horizontal drag lifecycle', (tester) async {
    var starts = 0;
    var updates = 0;
    var ends = 0;
    await _pump(
      tester,
      onStart: (_) => starts++,
      onUpdate: (_) => updates++,
      onEnd: (_) => ends++,
    );

    await tester.drag(
      find.byKey(const ValueKey('resize')),
      const Offset(80, 0),
    );
    await tester.pump();
    expect(starts, 1);
    expect(updates, greaterThan(0));
    expect(ends, 1);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  GestureDragStartCallback? onStart,
  GestureDragUpdateCallback? onUpdate,
  GestureDragEndCallback? onEnd,
}) => tester.pumpWidget(
  FluentApp(
    theme: buildAppTheme(AppThemeName.dark),
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 205,
        height: 100,
        child: Stack(
          children: [
            SidebarResizeHandle(
              edge: SidebarResizeEdge.right,
              testId: 'resize',
              onDragStart: onStart ?? (_) {},
              onDragUpdate: onUpdate ?? (_) {},
              onDragEnd: onEnd ?? (_) {},
              onDragCancel: () {},
            ),
          ],
        ),
      ),
    ),
  ),
);
