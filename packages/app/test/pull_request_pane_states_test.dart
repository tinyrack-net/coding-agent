import 'dart:async';

import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/widgets/pull_request_pane_states.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('matches the frozen pane skeleton structure and geometry', (
    tester,
  ) async {
    await _pump(tester, const PullRequestPaneSkeleton());

    expect(find.byKey(const ValueKey('pr-pane-skeleton')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pr-pane-activity-skeleton')),
      findsOneWidget,
    );
    expect(find.text('Checks'), findsOneWidget);
    for (var row = 0; row < 3; row++) {
      expect(
        find.byKey(ValueKey('pr-pane-skeleton-check-$row')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('pr-activity-skeleton-row-$row')),
        findsOneWidget,
      );
    }

    expect(
      tester.getSize(find.byKey(const ValueKey('pr-pane-skeleton-title'))),
      const Size(261, 16),
    );
    _expectSizeClose(
      tester.getSize(find.byKey(const ValueKey('pr-pane-skeleton-subtitle'))),
      width: 139.2,
      height: 12,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('pr-pane-skeleton-toolbar-0'))),
      const Size(96, 24),
    );
    expect(
      tester.getSize(
        find.byKey(const ValueKey('pr-pane-skeleton-check-dot-0')),
      ),
      const Size(14, 14),
    );
    _expectSizeClose(
      tester.getSize(
        find.byKey(const ValueKey('pr-pane-skeleton-check-name-0')),
      ),
      width: 213.6,
      height: 12,
    );
    expect(
      tester.getSize(
        find.byKey(const ValueKey('pr-activity-skeleton-avatar-0')),
      ),
      const Size(20, 20),
    );
    _expectSizeClose(
      tester.getSize(find.byKey(const ValueKey('pr-activity-skeleton-wide-0'))),
      width: 229.6,
      height: 12,
    );
    _expectSizeClose(
      tester.getSize(
        find.byKey(const ValueKey('pr-activity-skeleton-narrow-0')),
      ),
      width: 147.6,
      height: 10,
    );
  });

  testWidgets('uses frozen sidebar surfaces and a 0.4 to 0.8 pulse', (
    tester,
  ) async {
    await _pump(tester, const PullRequestPaneSkeleton());

    final root = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('pr-pane-skeleton')),
    );
    expect(root.color, paseoPaletteFor(AppThemeName.dark).surfaceSidebar);
    final pulseFinder = find.descendant(
      of: find.byKey(const ValueKey('pr-pane-skeleton-title')),
      matching: find.byType(FadeTransition),
    );
    final pulse = tester.widget<FadeTransition>(pulseFinder);
    expect(pulse.opacity.value, .4);
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: find.byKey(const ValueKey('pr-pane-skeleton-title')),
                    matching: find.byType(DecoratedBox),
                  ),
                )
                .decoration
            as BoxDecoration;
    expect(decoration.color, paseoPaletteFor(AppThemeName.dark).surface2);
    expect(decoration.borderRadius, BorderRadius.circular(2));

    await tester.pump(const Duration(seconds: 1));
    expect(pulse.opacity.value, .8);
    await tester.pump(const Duration(seconds: 1));
    expect(pulse.opacity.value, .4);
  });

  testWidgets('excludes the decorative skeleton from accessibility', (
    tester,
  ) async {
    await _pump(tester, const PullRequestPaneSkeleton());

    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('pr-pane-skeleton')),
    );
    expect(semantics.label, isEmpty);
    expect(semantics.childrenCount, 0);
  });

  testWidgets('renders the frozen error state and invokes retry', (
    tester,
  ) async {
    final retried = Completer<void>();
    await _pump(
      tester,
      PullRequestPaneError(
        message: 'Failed to load pull request',
        onRetry: retried.complete,
      ),
    );

    expect(find.byKey(const ValueKey('pr-pane-error')), findsOneWidget);
    expect(find.text('Failed to load pull request'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byIcon(FluentIcons.refresh), findsOneWidget);
    expect(
      tester
          .widget<ColoredBox>(find.byKey(const ValueKey('pr-pane-error')))
          .color,
      paseoPaletteFor(AppThemeName.dark).surfaceSidebar,
    );

    await tester.tap(find.byKey(const ValueKey('pr-pane-error-retry')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(retried.isCompleted, isTrue);
  });

  testWidgets('uses the frozen localized fallback error copy', (tester) async {
    await _pump(tester, PullRequestPaneError(onRetry: () {}));

    expect(find.text('Failed to refresh git state.'), findsOneWidget);
  });

  testWidgets('matches the frozen Windows loading golden', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(380, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await _pump(tester, const PullRequestPaneSkeleton());
    await expectLater(
      find.byKey(const ValueKey('pr-pane-skeleton')),
      matchesGoldenFile('goldens/pull_request_pane_skeleton_380x700.png'),
    );
  });
}

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  FluentApp(
    theme: buildAppTheme(AppThemeName.dark),
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 380, height: 700, child: child),
    ),
  ),
);

void _expectSizeClose(
  Size actual, {
  required double width,
  required double height,
}) {
  expect(actual.width, closeTo(width, .000001));
  expect(actual.height, closeTo(height, .000001));
}
