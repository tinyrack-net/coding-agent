import 'package:coding_agent_app/widgets/diff/diff_scroll.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('reports viewport width and exposes horizontal overflow', (
    tester,
  ) async {
    final widths = <double>[];
    final offsets = <double>[];
    await tester.pumpWidget(
      FluentApp(
        home: Center(
          child: SizedBox(
            width: 200,
            height: 80,
            child: DiffScroll(
              onScrollViewWidthChange: widths.add,
              onScrollOffsetChange: offsets.add,
              child: const SizedBox(width: 500, height: 40),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(widths, [200]);
    final scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('diff-horizontal-scroll')),
    );
    expect(scroll.scrollDirection, Axis.horizontal);
    expect(scroll.physics, isA<ClampingScrollPhysics>());
    expect(
      tester.widget<Scrollbar>(find.byType(Scrollbar)).thumbVisibility,
      isTrue,
    );

    await tester.drag(
      find.byKey(const ValueKey('diff-horizontal-scroll')),
      const Offset(-120, 0),
    );
    await tester.pumpAndSettle();

    expect(offsets, isNotEmpty);
    expect(offsets.last, greaterThan(0));
  });

  testWidgets('does not report unchanged width again after rebuild', (
    tester,
  ) async {
    final widths = <double>[];
    Widget build() => FluentApp(
      home: Center(
        child: SizedBox(
          width: 240,
          child: DiffScroll(
            onScrollViewWidthChange: widths.add,
            child: const SizedBox(width: 480),
          ),
        ),
      ),
    );

    await tester.pumpWidget(build());
    await tester.pump();
    await tester.pumpWidget(build());
    await tester.pump();

    expect(widths, [240]);
  });
}
