import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/widgets/sidebar_agent_list_skeleton.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('matches frozen section and row geometry', (tester) async {
    await _pump(tester);

    expect(
      find.byKey(const ValueKey('sidebar-agent-list-skeleton')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sidebar-skeleton-section-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sidebar-skeleton-section-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sidebar-skeleton-section-2')),
      findsOneWidget,
    );
    for (var section = 0; section < 3; section++) {
      for (var row = 0; row < 3; row++) {
        expect(
          find.byKey(ValueKey('sidebar-skeleton-row-$section-$row')),
          findsOneWidget,
        );
      }
    }

    expect(
      tester.getSize(find.byKey(const ValueKey('sidebar-skeleton-chevron-0'))),
      const Size(14, 14),
    );
    expect(
      tester.getSize(
        find.byKey(const ValueKey('sidebar-skeleton-project-icon-0')),
      ),
      const Size(16, 16),
    );
    expect(
      tester.getSize(
        find.byKey(const ValueKey('sidebar-skeleton-section-title-0')),
      ),
      const Size(108, 12),
    );
    expect(
      tester.getSize(
        find.byKey(const ValueKey('sidebar-skeleton-row-dot-0-0')),
      ),
      const Size(8, 8),
    );
    expect(
      tester.getSize(
        find.byKey(const ValueKey('sidebar-skeleton-row-title-0-0')),
      ),
      const Size(172, 12),
    );
    expect(
      tester.getSize(
        find.byKey(const ValueKey('sidebar-skeleton-row-badge-0-0')),
      ),
      const Size(40, 20),
    );

    final sections = [
      for (var section = 0; section < 3; section++)
        tester.widget<Opacity>(
          find.byKey(ValueKey('sidebar-skeleton-section-$section')),
        ),
    ];
    expect(sections.map((section) => section.opacity), [1, 0.7, 0.4]);
  });

  testWidgets('uses surface2 and pulses from 0.4 to 0.8 and back', (
    tester,
  ) async {
    await _pump(tester);

    final pulse = find.descendant(
      of: find.byKey(const ValueKey('sidebar-skeleton-chevron-0')),
      matching: find.byType(FadeTransition),
    );
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: find.byKey(
                      const ValueKey('sidebar-skeleton-chevron-0'),
                    ),
                    matching: find.byType(DecoratedBox),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(decoration.color, paseoPaletteFor(AppThemeName.dark).surface2);
    expect(decoration.borderRadius, BorderRadius.circular(2));
    expect(tester.widget<FadeTransition>(pulse).opacity.value, 0.4);

    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<FadeTransition>(pulse).opacity.value, 0.8);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<FadeTransition>(pulse).opacity.value, 0.4);
  });

  testWidgets('is excluded from the accessibility tree', (tester) async {
    await _pump(tester);
    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('sidebar-agent-list-skeleton')),
    );
    expect(semantics.label, isEmpty);
    expect(semantics.childrenCount, 0);
  });
}

Future<void> _pump(WidgetTester tester) => tester.pumpWidget(
  FluentApp(
    theme: buildAppTheme(AppThemeName.dark),
    home: const Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 280,
        height: 600,
        child: SidebarAgentListSkeleton(),
      ),
    ),
  ),
);
