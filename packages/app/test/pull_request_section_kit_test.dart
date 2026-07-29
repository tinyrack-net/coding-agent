import 'dart:ui' show PointerDeviceKind;

import 'package:coding_agent_app/core/forge_logic.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/widgets/pull_request_section_kit.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('section uses frozen header geometry and open body padding', (
    tester,
  ) async {
    var toggles = 0;
    await _pump(
      tester,
      PullRequestSection(
        title: 'Checks',
        open: true,
        onToggle: () => toggles += 1,
        summary: const SizedBox.shrink(),
        child: const SizedBox(key: ValueKey('section-content'), height: 20),
      ),
    );

    final header = find.byKey(const ValueKey('pr-section-Checks'));
    final chevron = find.byKey(const ValueKey('pr-section-chevron-Checks'));
    expect(tester.getSize(chevron), const Size(14, 14));
    expect(tester.getTopLeft(chevron).dx, 12);
    expect(tester.getTopLeft(find.text('Checks')).dx, 34);
    final title = tester.widget<Text>(find.text('Checks'));
    expect(title.style?.fontSize, 12);
    expect(title.style?.fontWeight, FontWeight.w500);
    expect(
      title.style?.color,
      paseoPaletteFor(AppThemeName.dark).foregroundMuted,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('pr-section-body-Checks')))
          .height,
      32,
    );

    await tester.tap(header);
    await tester.pump(const Duration(milliseconds: 100));
    expect(toggles, 1);
  });

  testWidgets('closed section changes chevron and omits its body', (
    tester,
  ) async {
    await _pump(
      tester,
      PullRequestSection(
        title: 'Activity',
        open: false,
        onToggle: () {},
        summary: const SizedBox.shrink(),
        child: const Text('hidden body'),
      ),
    );

    expect(find.text('hidden body'), findsNothing);
    expect(
      tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byKey(const ValueKey('pr-section-chevron-Activity')),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter,
      isA<PullRequestGlyphPainter>().having(
        (painter) => painter.kind,
        'kind',
        PullRequestGlyphKind.chevronRight,
      ),
    );
  });

  testWidgets('summary pills are transparent, exact-sized, and omit zeroes', (
    tester,
  ) async {
    await _pump(
      tester,
      const PullRequestSectionSummary(
        children: [
          PullRequestSummaryPill(
            key: ValueKey('success-pill'),
            count: 2,
            variant: PullRequestSummaryVariant.success,
            icon: PullRequestSummaryIcon.check,
          ),
          PullRequestSummaryPill(
            key: ValueKey('zero-pill'),
            count: 0,
            variant: PullRequestSummaryVariant.warning,
            icon: PullRequestSummaryIcon.dot,
          ),
          PullRequestSummaryPill(
            key: ValueKey('danger-pill'),
            count: 1,
            variant: PullRequestSummaryVariant.danger,
            icon: PullRequestSummaryIcon.x,
          ),
        ],
      ),
    );

    expect(find.byKey(const ValueKey('zero-pill')), findsNothing);
    final success = find.byKey(const ValueKey('success-pill'));
    expect(
      find.descendant(of: success, matching: find.byType(DecoratedBox)),
      findsNothing,
    );
    final successGlyph = find.descendant(
      of: success,
      matching: find.byType(PullRequestGlyph),
    );
    expect(tester.getSize(successGlyph), const Size(12, 12));
    final successText = tester.widget<Text>(
      find.descendant(of: success, matching: find.text('2')),
    );
    expect(successText.style?.fontSize, 12);
    expect(successText.style?.fontWeight, FontWeight.w400);
    expect(
      successText.style?.color,
      paseoPaletteFor(AppThemeName.dark).statusSuccess,
    );

    final danger = find.byKey(const ValueKey('danger-pill'));
    expect(tester.getTopLeft(danger).dx - tester.getTopRight(success).dx, 8);
  });

  testWidgets('status icons map all frozen variants to exact semantic colors', (
    tester,
  ) async {
    await _pump(
      tester,
      const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PullRequestCheckStatusIcon(
            key: ValueKey('success-status'),
            status: ForgeCheckStatus.success,
          ),
          PullRequestCheckStatusIcon(
            key: ValueKey('failure-status'),
            status: ForgeCheckStatus.failure,
          ),
          PullRequestCheckStatusIcon(
            key: ValueKey('pending-status'),
            status: ForgeCheckStatus.pending,
          ),
          PullRequestCheckStatusIcon(
            key: ValueKey('skipped-status'),
            status: ForgeCheckStatus.skipped,
          ),
        ],
      ),
    );

    final expected = {
      'success-status': (
        PullRequestGlyphKind.circleCheck,
        paseoPaletteFor(AppThemeName.dark).statusSuccess,
      ),
      'failure-status': (
        PullRequestGlyphKind.circleX,
        paseoPaletteFor(AppThemeName.dark).statusDanger,
      ),
      'pending-status': (
        PullRequestGlyphKind.circleDot,
        paseoPaletteFor(AppThemeName.dark).statusWarning,
      ),
      'skipped-status': (
        PullRequestGlyphKind.circleSlash,
        paseoPaletteFor(AppThemeName.dark).foregroundMuted,
      ),
    };
    for (final MapEntry(key: key, value: (kind, color)) in expected.entries) {
      final status = find.byKey(ValueKey(key));
      expect(tester.getSize(status), const Size(14, 14));
      final paint = tester.widget<CustomPaint>(
        find.descendant(of: status, matching: find.byType(CustomPaint)),
      );
      expect(
        paint.painter,
        isA<PullRequestGlyphPainter>()
            .having((painter) => painter.kind, 'kind', kind)
            .having((painter) => painter.color, 'color', color),
      );
    }
  });

  testWidgets('check row uses frozen type, spacing, trailing, and hover', (
    tester,
  ) async {
    await _pump(
      tester,
      const PullRequestCheckRowLayout(
        key: ValueKey('check-row'),
        status: ForgeCheckStatus.failure,
        name: 'Flutter tests',
        workflow: 'CI',
        trailing: PullRequestCheckDuration('1m 12s'),
      ),
    );

    final row = find.byKey(const ValueKey('check-row'));
    final glyph = find.descendant(
      of: row,
      matching: find.byType(PullRequestCheckStatusIcon),
    );
    expect(tester.getTopLeft(glyph).dx, 12);
    expect(tester.getTopLeft(find.text('Flutter tests')).dx, 34);
    expect(tester.widget<Text>(find.text('Flutter tests')).style?.fontSize, 14);
    expect(tester.widget<Text>(find.text('CI')).style?.fontSize, 12);
    expect(tester.widget<Text>(find.text('1m 12s')).style?.fontSize, 12);

    final containerFinder = find.descendant(
      of: row,
      matching: find.byType(Container),
    );
    expect(tester.widget<Container>(containerFinder).color, Colors.transparent);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: const Offset(700, 500));
    await gesture.moveTo(tester.getCenter(row));
    await tester.pump();
    expect(
      tester.widget<Container>(containerFinder).color,
      paseoPaletteFor(AppThemeName.dark).surface1,
    );
  });

  testWidgets('empty text uses frozen padding and muted 12px type', (
    tester,
  ) async {
    await _pump(tester, const PullRequestEmptyText('No checks'));

    final text = tester.widget<Text>(find.text('No checks'));
    expect(text.style?.fontSize, 12);
    expect(
      text.style?.color,
      paseoPaletteFor(AppThemeName.dark).foregroundMuted,
    );
    expect(tester.getTopLeft(find.text('No checks')), const Offset(12, 8));
  });

  testWidgets('matches the frozen Windows section-kit golden', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(380, 220);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await _pump(tester, const _SectionKitGolden());
    await expectLater(
      find.byKey(const ValueKey('section-kit-golden')),
      matchesGoldenFile('goldens/pull_request_section_kit_380x220.png'),
    );
  });
}

class _SectionKitGolden extends StatelessWidget {
  const _SectionKitGolden();

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const ValueKey('section-kit-golden'),
    color: context.paseoPalette.surfaceSidebar,
    child: PullRequestSection(
      title: 'Checks',
      open: true,
      onToggle: _noop,
      summary: const PullRequestSectionSummary(
        children: [
          PullRequestSummaryPill(
            count: 2,
            variant: PullRequestSummaryVariant.success,
            icon: PullRequestSummaryIcon.check,
          ),
          PullRequestSummaryPill(
            count: 1,
            variant: PullRequestSummaryVariant.danger,
            icon: PullRequestSummaryIcon.x,
          ),
          PullRequestSummaryPill(
            count: 3,
            variant: PullRequestSummaryVariant.warning,
            icon: PullRequestSummaryIcon.dot,
          ),
        ],
      ),
      child: const Column(
        children: [
          PullRequestCheckRowLayout(
            status: ForgeCheckStatus.success,
            name: 'Flutter tests',
            workflow: 'CI',
            trailing: PullRequestCheckDuration('1m 12s'),
          ),
          PullRequestCheckRowLayout(
            status: ForgeCheckStatus.failure,
            name: 'Package',
            workflow: 'Release',
          ),
          PullRequestCheckRowLayout(
            status: ForgeCheckStatus.skipped,
            name: 'Web',
          ),
        ],
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  FluentApp(
    theme: buildAppTheme(AppThemeName.dark),
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 380, height: 220, child: child),
    ),
  ),
);

void _noop() {}
