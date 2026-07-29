import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/widgets/adaptive_modal_sheet.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compact safe-area padding follows the frozen footer contract', () {
    final desktop = resolveCompactSheetSafeAreaPadding(
      isCompact: false,
      hasFooter: true,
      safeAreaBottom: 24,
    );
    expect(desktop.contentPaddingBottom, isNull);
    expect(desktop.footerPaddingBottom, isNull);

    final withFooter = resolveCompactSheetSafeAreaPadding(
      isCompact: true,
      hasFooter: true,
      safeAreaBottom: 24,
    );
    expect(withFooter.contentPaddingBottom, isNull);
    expect(withFooter.footerPaddingBottom, 36);

    final withoutFooter = resolveCompactSheetSafeAreaPadding(
      isCompact: true,
      hasFooter: false,
      safeAreaBottom: 24,
    );
    expect(withoutFooter.contentPaddingBottom, 48);
    expect(withoutFooter.footerPaddingBottom, isNull);
  });

  testWidgets('desktop card uses frozen width and maximum height', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1000, 800));
    await _pumpSheet(tester);

    final card = tester.getRect(
      find.byKey(const ValueKey('adaptive-modal-sheet-card')),
    );
    final decoration =
        tester
                .widget<Container>(
                  find.byKey(const ValueKey('adaptive-modal-sheet-card')),
                )
                .decoration
            as BoxDecoration;
    expect(card.width, adaptiveModalDesktopMaxWidth);
    expect(card.height, 800 * adaptiveModalDesktopMaxHeightFactor);
    expect(card.center, const Offset(500, 400));
    expect(decoration.color, paseoPaletteFor(AppThemeName.dark).surface1);
    expect(decoration.borderRadius, BorderRadius.circular(12));
  });

  testWidgets('compact card starts as a bottom-aligned 65 percent sheet', (
    tester,
  ) async {
    await _setViewport(tester, const Size(500, 800));
    await _pumpSheet(tester);

    final card = tester.getRect(
      find.byKey(const ValueKey('adaptive-modal-sheet-card')),
    );
    final decoration =
        tester
                .widget<Container>(
                  find.byKey(const ValueKey('adaptive-modal-sheet-card')),
                )
                .decoration
            as BoxDecoration;
    expect(card.width, 500);
    expect(card.height, 800 * adaptiveModalCompactInitialHeightFactor);
    expect(card.bottom, 800);
    expect(decoration.color, paseoPaletteFor(AppThemeName.dark).surface0);
    expect(
      decoration.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(16)),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('cancel'))).top,
      greaterThanOrEqualTo(card.bottom),
    );
  });

  testWidgets(
    'compact visible-content mode keeps its footer in the live snap',
    (tester) async {
      await _setViewport(tester, const Size(500, 800));
      await _pumpSheet(tester, sizeContentToCurrentSnapPoint: true);

      final card = tester.getRect(
        find.byKey(const ValueKey('adaptive-modal-sheet-card')),
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('cancel'))).bottom,
        lessThanOrEqualTo(card.bottom),
      );
    },
  );

  testWidgets('header close action and equal-width footer are interactive', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1000, 800));
    var closed = false;
    await _pumpSheet(tester, onClose: () => closed = true);

    final cancel = tester.getRect(find.byKey(const ValueKey('cancel')));
    final submit = tester.getRect(find.byKey(const ValueKey('submit')));
    expect(cancel.width, submit.width);
    expect(cancel.height, 44);
    expect(submit.height, 44);

    await tester.tap(find.byKey(const ValueKey('adaptive-modal-sheet-close')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(closed, isTrue);
  });

  testWidgets('custom header and footer occupy the adaptive card chrome', (
    tester,
  ) async {
    await _setViewport(tester, const Size(1000, 800));
    await tester.pumpWidget(
      FluentApp(
        theme: buildAppTheme(),
        home: AdaptiveModalSheet(
          title: 'Provider',
          onClose: () {},
          headerActions: const [
            IconButton(
              key: ValueKey('header-action'),
              onPressed: null,
              icon: Icon(FluentIcons.refresh),
            ),
          ],
          headerContent: const Text('Search header', key: ValueKey('header')),
          content: const Text('Models'),
          footer: const Text('Provider footer', key: ValueKey('footer')),
          contentScrollable: false,
        ),
      ),
    );

    expect(find.byKey(const ValueKey('header-action')), findsOneWidget);
    expect(find.byKey(const ValueKey('header')), findsOneWidget);
    expect(find.byKey(const ValueKey('footer')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('adaptive-modal-sheet-content')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('adaptive-modal-sheet-scroll')),
      findsNothing,
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('header'))).dy,
      lessThan(tester.getTopLeft(find.text('Models')).dy),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('footer'))).dy,
      greaterThan(tester.getTopLeft(find.text('Models')).dy),
    );
  });

  testWidgets('compact sheet supports pan-down dismissal', (tester) async {
    await _setViewport(tester, const Size(500, 800));
    var closed = false;
    await _pumpSheet(tester, onClose: () => closed = true);

    await tester.dragFrom(const Offset(250, 400), const Offset(0, 500));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
  });
}

Future<void> _setViewport(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  VoidCallback? onClose,
  bool sizeContentToCurrentSnapPoint = false,
}) => tester.pumpWidget(
  FluentApp(
    theme: buildAppTheme(),
    home: AdaptiveModalSheet(
      title: 'New schedule',
      onClose: onClose ?? () {},
      sizeContentToCurrentSnapPoint: sizeContentToCurrentSnapPoint,
      content: const SizedBox(height: 2000),
      actions: const [
        Button(key: ValueKey('cancel'), onPressed: null, child: Text('Cancel')),
        FilledButton(
          key: ValueKey('submit'),
          onPressed: null,
          child: Text('Submit'),
        ),
      ],
    ),
  ),
);
