/// Widget tests pinning the frozen visual contract of the Paseo 0.2.0
/// `components/headers/*` cluster.
///
/// Upstream ships no test file for any of these six components, so every case
/// here is written against the frozen styles themselves: the exact row heights,
/// paddings, gaps, icon sizes, font weights, colors and radii, plus the
/// conditional-rendering rules that decide what disappears when a prop is
/// absent.
library;

import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/widgets/paseo_headers.dart';
import 'package:coding_agent_app/widgets/shortcut_badge.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';

/// Wide enough to resolve every responsive style's `md` branch.
const double _desktopWidth = 1000;

/// Narrower than the 720 `md` breakpoint, so every style resolves `xs`.
const double _compactWidth = 400;

final _palette = paseoPaletteFor(AppThemeName.dark);

/// Sizes the test view rather than injecting a [MediaQuery], because the header
/// reads both the window width (for the 720 breakpoint) and the view padding
/// (for the safe-area inset), and the surrounding [FluentApp] must agree.
Future<void> pumpHeader(
  WidgetTester tester,
  Widget child, {
  double width = _desktopWidth,
  double safeAreaTop = 0,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  tester.view.padding = FakeViewPadding(top: safeAreaTop);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    FluentApp(
      theme: buildAppTheme(),
      home: Align(alignment: Alignment.topLeft, child: child),
    ),
  );
}

/// Taps and then drains fluent's 100ms post-press timer.
Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
  await tester.tap(finder, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 200));
}

Finder _headerRow() => find.byKey(const ValueKey('paseo-screen-header-row'));

Finder _headerSurface() => find.byKey(const ValueKey('paseo-screen-header'));

/// The [Container] a `_PaseoHeaderIconSlot` renders, addressed through the key
/// on the slot widget itself.
Container _slotContainer(WidgetTester tester, Finder slot) => tester.widget(
  find.descendant(of: slot, matching: find.byType(Container)).first,
);

Container _rowContainer(WidgetTester tester) => tester.widget(_headerRow());

Border _rowBorder(WidgetTester tester) =>
    (_rowContainer(tester).decoration! as BoxDecoration).border! as Border;

Widget _box(String id, double width) =>
    SizedBox(key: ValueKey(id), width: width, height: 10);

void main() {
  group('PaseoScreenHeader frame', () {
    testWidgets('desktop row is 48px tall with 12px horizontal padding', (
      tester,
    ) async {
      await pumpHeader(tester, const PaseoScreenHeader());

      expect(tester.getSize(_headerRow()).height, paseoHeaderInnerHeight);
      expect(paseoHeaderInnerHeight, 48.0);
      expect(
        _rowContainer(tester).padding,
        const EdgeInsets.only(left: PaseoSpacing.s3, right: PaseoSpacing.s3),
      );
    });

    testWidgets('compact row is 56px tall with 8px horizontal padding', (
      tester,
    ) async {
      await pumpHeader(tester, const PaseoScreenHeader(), width: _compactWidth);

      expect(tester.getSize(_headerRow()).height, paseoHeaderInnerHeightMobile);
      expect(paseoHeaderInnerHeightMobile, 56.0);
      expect(
        _rowContainer(tester).padding,
        const EdgeInsets.only(left: PaseoSpacing.s2, right: PaseoSpacing.s2),
      );
    });

    testWidgets('only compact adds the extra 8px above the safe-area inset', (
      tester,
    ) async {
      await pumpHeader(tester, const PaseoScreenHeader(), safeAreaTop: 20);
      // Desktop: safe area only.
      expect(
        tester.getSize(_headerSurface()).height,
        20 + paseoHeaderInnerHeight,
      );

      await pumpHeader(
        tester,
        const PaseoScreenHeader(),
        width: _compactWidth,
        safeAreaTop: 20,
      );
      // Compact: safe area plus the touch-target padding.
      expect(
        tester.getSize(_headerSurface()).height,
        20 + paseoHeaderTopPaddingMobile + paseoHeaderInnerHeightMobile,
      );
      expect(paseoHeaderTopPaddingMobile, 8.0);
    });

    testWidgets('paints surface0 behind a 1px border-colored hairline', (
      tester,
    ) async {
      await pumpHeader(tester, const PaseoScreenHeader());

      expect(
        tester.widget<ColoredBox>(_headerSurface()).color,
        _palette.surface0,
      );
      final bottom = _rowBorder(tester).bottom;
      expect(bottom.width, 1.0);
      expect(bottom.color, _palette.border);
    });

    testWidgets('borderless keeps the 1px hairline and only clears its color', (
      tester,
    ) async {
      await pumpHeader(tester, const PaseoScreenHeader(borderless: true));

      final bottom = _rowBorder(tester).bottom;
      expect(bottom.width, 1.0, reason: 'layout must not shift by a pixel');
      expect(bottom.color, Colors.transparent);
      expect(tester.getSize(_headerRow()).height, paseoHeaderInnerHeight);
    });

    testWidgets('window chrome insets stack on top of the base padding', (
      tester,
    ) async {
      await pumpHeader(
        tester,
        const PaseoScreenHeader(
          windowChromeInsets: EdgeInsets.only(left: 78, right: 140),
        ),
      );

      expect(
        _rowContainer(tester).padding,
        const EdgeInsets.only(
          left: 78 + PaseoSpacing.s3,
          right: 140 + PaseoSpacing.s3,
        ),
      );
    });
  });

  group('PaseoScreenHeader clusters', () {
    testWidgets('left cluster absorbs the free space, right cluster does not', (
      tester,
    ) async {
      await pumpHeader(
        tester,
        PaseoScreenHeader(left: [_box('l', 10)], right: [_box('r', 30)]),
      );

      expect(
        tester.getTopLeft(find.byKey(const ValueKey('l'))).dx,
        PaseoSpacing.s3,
      );
      expect(
        tester.getTopRight(find.byKey(const ValueKey('r'))).dx,
        _desktopWidth - PaseoSpacing.s3,
      );
      expect(tester.getSize(find.byKey(const ValueKey('r'))).width, 30);
    });

    testWidgets('cluster members are separated by spacing[2]', (tester) async {
      await pumpHeader(
        tester,
        PaseoScreenHeader(
          left: [_box('a', 20), _box('b', 20)],
          right: [_box('c', 20), _box('d', 20)],
        ),
      );

      expect(
        tester.getTopLeft(find.byKey(const ValueKey('b'))).dx -
            tester.getTopRight(find.byKey(const ValueKey('a'))).dx,
        PaseoSpacing.s2,
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('d'))).dx -
            tester.getTopRight(find.byKey(const ValueKey('c'))).dx,
        PaseoSpacing.s2,
      );
      expect(PaseoSpacing.s2, 8.0);
    });

    testWidgets('cluster members are vertically centred in the row', (
      tester,
    ) async {
      await pumpHeader(tester, PaseoScreenHeader(left: [_box('l', 10)]));

      // The row's content box is the height minus the 1px bottom border.
      expect(
        tester.getCenter(find.byKey(const ValueKey('l'))).dy,
        (paseoHeaderInnerHeight - 1) / 2,
      );
    });
  });

  group('PaseoScreenTitle', () {
    Text titleText(WidgetTester tester) =>
        tester.widget(find.byType(Text).first);

    testWidgets('desktop title is 16px weight 300 in the foreground color', (
      tester,
    ) async {
      await pumpHeader(
        tester,
        const PaseoScreenHeader(left: [PaseoScreenTitle('Agents')]),
      );

      final style = titleText(tester).style!;
      expect(style.fontSize, 16.0);
      expect(style.fontWeight, FontWeight.w300);
      expect(style.color, _palette.foreground);
    });

    testWidgets('compact title steps the weight up to 400', (tester) async {
      await pumpHeader(
        tester,
        const PaseoScreenHeader(left: [PaseoScreenTitle('Agents')]),
        width: _compactWidth,
      );

      final style = titleText(tester).style!;
      expect(style.fontSize, 16.0, reason: 'size is not responsive');
      expect(style.fontWeight, FontWeight.w400);
    });

    testWidgets('defaults to one ellipsized line', (tester) async {
      await pumpHeader(
        tester,
        const PaseoScreenHeader(left: [PaseoScreenTitle('Agents')]),
      );

      expect(titleText(tester).maxLines, 1);
      expect(titleText(tester).overflow, TextOverflow.ellipsis);
    });

    testWidgets('honors an explicit maxLines and a style override', (
      tester,
    ) async {
      await pumpHeader(
        tester,
        const PaseoScreenHeader(
          left: [
            PaseoScreenTitle(
              'Agents',
              maxLines: 2,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ],
        ),
      );

      expect(titleText(tester).maxLines, 2);
      expect(titleText(tester).style!.fontWeight, FontWeight.w700);
      expect(
        titleText(tester).style!.fontSize,
        16.0,
        reason: 'override merges over the canonical style',
      );
    });

    testWidgets('a long title truncates instead of squeezing the actions', (
      tester,
    ) async {
      await pumpHeader(
        tester,
        PaseoScreenHeader(
          left: [PaseoScreenTitle('A quite unreasonably long screen ' * 12)],
          right: [_box('r', 40)],
        ),
      );

      expect(tester.getSize(find.byKey(const ValueKey('r'))).width, 40);
      expect(
        tester.getTopRight(find.byKey(const ValueKey('r'))).dx,
        _desktopWidth - PaseoSpacing.s3,
      );
      // Left cluster = row width - both insets - the right cluster.
      expect(
        tester.getSize(find.byType(Text).first).width,
        lessThanOrEqualTo(_desktopWidth - PaseoSpacing.s3 * 2 - 40),
      );
    });
  });

  group('PaseoHeaderIconBadge', () {
    Finder badge() => find.byKey(const ValueKey('paseo-header-icon-badge'));

    testWidgets('pads by spacing[2] on desktop with an 8px radius', (
      tester,
    ) async {
      await pumpHeader(
        tester,
        const PaseoScreenHeader(
          left: [PaseoHeaderIconBadge(child: Icon(FluentIcons.settings))],
        ),
      );

      final container = _slotContainer(tester, badge());
      expect(container.padding, const EdgeInsets.all(PaseoSpacing.s2));
      expect(
        (container.decoration! as BoxDecoration).borderRadius,
        BorderRadius.circular(8),
      );
    });

    testWidgets('pads by spacing[3] on compact for the larger touch target', (
      tester,
    ) async {
      await pumpHeader(
        tester,
        const PaseoScreenHeader(
          left: [PaseoHeaderIconBadge(child: Icon(FluentIcons.settings))],
        ),
        width: _compactWidth,
      );

      expect(
        _slotContainer(tester, badge()).padding,
        const EdgeInsets.all(PaseoSpacing.s3),
      );
    });

    testWidgets('is non-interactive', (tester) async {
      await pumpHeader(
        tester,
        const PaseoScreenHeader(
          left: [PaseoHeaderIconBadge(child: Icon(FluentIcons.settings))],
        ),
      );

      expect(
        find.descendant(of: badge(), matching: find.byType(HoverButton)),
        findsNothing,
      );
    });

    testWidgets('shares its padding with the shared icon slot helper', (
      tester,
    ) async {
      expect(
        paseoHeaderIconSlotPadding(isCompact: false),
        const EdgeInsets.all(PaseoSpacing.s2),
      );
      expect(
        paseoHeaderIconSlotPadding(isCompact: true),
        const EdgeInsets.all(PaseoSpacing.s3),
      );
    });
  });

  group('PaseoHeaderToggleButton', () {
    Widget button({
      required VoidCallback onPressed,
      bool disabled = false,
      bool? expanded,
      String? semanticLabel,
      void Function(bool hovered, bool pressed)? onState,
    }) => PaseoHeaderToggleButton(
      key: const ValueKey('toggle'),
      onPressed: onPressed,
      tooltipLabel: 'Toggle sidebar',
      tooltipKeys: const ['mod', 'B'],
      tooltipSide: PaseoHeaderTooltipSide.right,
      disabled: disabled,
      expanded: expanded,
      semanticLabel: semanticLabel,
      isMac: false,
      builder: (context, hovered, pressed) {
        onState?.call(hovered, pressed);
        return Icon(
          FluentIcons.side_panel,
          size: 16,
          color: hovered || pressed
              ? _palette.foreground
              : _palette.foregroundMuted,
        );
      },
    );

    testWidgets('mounts a tooltip on desktop and omits it on compact', (
      tester,
    ) async {
      await pumpHeader(tester, button(onPressed: () {}));
      expect(find.byType(Tooltip), findsOneWidget);

      await pumpHeader(tester, button(onPressed: () {}), width: _compactWidth);
      expect(
        find.byType(Tooltip),
        findsNothing,
        reason: 'upstream passes enabledOnMobile={false}',
      );
    });

    testWidgets('tooltip prefers its side and offsets by spacing[2]', (
      tester,
    ) async {
      await pumpHeader(tester, button(onPressed: () {}));

      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.displayHorizontally, isTrue, reason: 'side: right');
      expect(tooltip.style!.verticalOffset, PaseoSpacing.s2);
      expect(tooltip.style!.waitDuration, Duration.zero);
    });

    testWidgets('wraps its glyph in the shared icon slot padding', (
      tester,
    ) async {
      await pumpHeader(tester, button(onPressed: () {}));

      expect(
        _slotContainer(tester, find.byKey(const ValueKey('toggle'))).padding,
        const EdgeInsets.all(PaseoSpacing.s2),
      );
    });

    testWidgets('starts idle and promotes the glyph on hover', (tester) async {
      // fluent's HoverButton routes hover through FocusableActionDetector,
      // which only reports it while the focus highlight mode is "traditional";
      // the test harness starts in touch mode.
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      await pumpHeader(tester, button(onPressed: () {}), width: _compactWidth);

      expect(
        tester.widget<Icon>(find.byIcon(FluentIcons.side_panel)).color,
        _palette.foregroundMuted,
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byIcon(FluentIcons.side_panel)),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<Icon>(find.byIcon(FluentIcons.side_panel)).color,
        _palette.foreground,
      );
    });

    testWidgets('invokes onPressed, and does not when disabled', (
      tester,
    ) async {
      var taps = 0;
      await pumpHeader(
        tester,
        button(onPressed: () => taps++),
        width: _compactWidth,
      );
      await tapAndSettle(tester, find.byKey(const ValueKey('toggle')));
      expect(taps, 1);

      await pumpHeader(
        tester,
        button(onPressed: () => taps++, disabled: true),
        width: _compactWidth,
      );
      await tapAndSettle(tester, find.byKey(const ValueKey('toggle')));
      expect(taps, 1);
    });

    testWidgets('exposes its accessibility label and expanded state', (
      tester,
    ) async {
      await pumpHeader(
        tester,
        button(onPressed: () {}, expanded: true, semanticLabel: 'Close menu'),
        width: _compactWidth,
      );

      final semantics = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .firstWhere((s) => s.properties.label == 'Close menu');
      expect(semantics.properties.button, isTrue);
      expect(semantics.properties.expanded, isTrue);
    });
  });

  group('PaseoBackHeader', () {
    testWidgets('renders the arrow at iconSize.lg in foregroundMuted', (
      tester,
    ) async {
      await pumpHeader(tester, PaseoBackHeader(onBack: () {}));

      final icon = tester.widget<Icon>(find.byIcon(FluentIcons.back));
      expect(icon.size, 20.0, reason: 'theme.iconSize.lg');
      expect(icon.color, _palette.foregroundMuted);
      expect(
        _slotContainer(
          tester,
          find.byKey(const ValueKey('paseo-back-header-button')),
        ).padding,
        const EdgeInsets.all(PaseoSpacing.s2),
      );
    });

    testWidgets('drops the title and accessory entirely when absent', (
      tester,
    ) async {
      await pumpHeader(tester, PaseoBackHeader(onBack: () {}));

      expect(find.byType(PaseoScreenTitle), findsNothing);
      expect(find.byType(Text), findsNothing);
      // The arrow stays flush against the row inset with nothing reserved.
      expect(
        tester.getTopLeft(find.byIcon(FluentIcons.back)).dx,
        PaseoSpacing.s3 + PaseoSpacing.s2,
      );
    });

    testWidgets('renders title, accessory and right content when supplied', (
      tester,
    ) async {
      await pumpHeader(
        tester,
        PaseoBackHeader(
          title: 'Settings',
          titleAccessory: _box('accessory', 12),
          rightContent: [_box('action', 24)],
          onBack: () {},
        ),
      );

      expect(find.text('Settings'), findsOneWidget);
      expect(find.byKey(const ValueKey('accessory')), findsOneWidget);
      expect(find.byKey(const ValueKey('action')), findsOneWidget);
      // Accessory follows the title, one gap later.
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('accessory'))).dx -
            tester.getTopRight(find.text('Settings')).dx,
        PaseoSpacing.s2,
      );
    });

    testWidgets('tapping the arrow invokes onBack', (tester) async {
      var backs = 0;
      await pumpHeader(tester, PaseoBackHeader(onBack: () => backs++));

      await tapAndSettle(
        tester,
        find.byKey(const ValueKey('paseo-back-header-button')),
      );
      expect(backs, 1);
    });

    testWidgets('forwards borderless to the shared frame', (tester) async {
      await pumpHeader(
        tester,
        PaseoBackHeader(onBack: () {}, borderless: true),
      );

      expect(_rowBorder(tester).bottom.color, Colors.transparent);
    });
  });

  group('PaseoSidebarMenuToggle', () {
    Widget toggle({
      bool isOpen = false,
      bool ownsTopLeftCorner = true,
      bool hasTopLeftWindowControls = false,
      VoidCallback? onToggle,
    }) => PaseoSidebarMenuToggle(
      isOpen: isOpen,
      onToggle: onToggle ?? () {},
      tooltipLabel: 'Toggle sidebar',
      openLabel: 'Open menu',
      closeLabel: 'Close menu',
      ownsTopLeftCorner: ownsTopLeftCorner,
      hasTopLeftWindowControls: hasTopLeftWindowControls,
      isMac: false,
    );

    testWidgets('renders nothing on desktop when it does not own the corner', (
      tester,
    ) async {
      await pumpHeader(tester, toggle(ownsTopLeftCorner: false));

      expect(find.byKey(const ValueKey('menu-button')), findsNothing);
      expect(
        find.byKey(const ValueKey('paseo-sidebar-menu-toggle-placeholder')),
        findsNothing,
      );
    });

    testWidgets('reserves an inert icon-sized slot behind window controls', (
      tester,
    ) async {
      await pumpHeader(tester, toggle(hasTopLeftWindowControls: true));

      final placeholder = find.byKey(
        const ValueKey('paseo-sidebar-menu-toggle-placeholder'),
      );
      expect(placeholder, findsOneWidget);
      expect(find.byKey(const ValueKey('menu-button')), findsNothing);
      expect(
        find.descendant(of: placeholder, matching: find.byType(HoverButton)),
        findsNothing,
      );
      // spacing[2] all round, minus the leading toggle's -spacing[2] margin.
      expect(
        _slotContainer(tester, placeholder).padding,
        const EdgeInsets.fromLTRB(0, PaseoSpacing.s2, PaseoSpacing.s2, 8),
      );
      expect(
        tester.getSize(
          find.descendant(of: placeholder, matching: find.byType(SizedBox)),
        ),
        const Size.square(16),
        reason: 'theme.iconSize.md',
      );
    });

    testWidgets('desktop uses the panel glyph at iconSize.md', (tester) async {
      await pumpHeader(tester, toggle());

      final icon = tester.widget<Icon>(find.byIcon(FluentIcons.side_panel));
      expect(icon.size, 16.0);
      expect(icon.color, _palette.foregroundMuted);
      expect(
        find.byKey(const ValueKey('paseo-mobile-menu-icon')),
        findsNothing,
      );
    });

    testWidgets('desktop folds the -spacing[2] leading margin into the slot', (
      tester,
    ) async {
      await pumpHeader(tester, toggle());

      expect(
        _slotContainer(
          tester,
          find.byKey(const ValueKey('menu-button')),
        ).padding,
        const EdgeInsets.fromLTRB(
          0,
          PaseoSpacing.s2,
          PaseoSpacing.s2,
          PaseoSpacing.s2,
        ),
      );
    });

    testWidgets('compact uses the three-rule hamburger at frozen widths', (
      tester,
    ) async {
      await pumpHeader(tester, toggle(), width: _compactWidth);

      final icon = find.byKey(const ValueKey('paseo-mobile-menu-icon'));
      expect(icon, findsOneWidget);
      expect(tester.getSize(icon), const Size(16, 12));
      expect(find.byIcon(FluentIcons.side_panel), findsNothing);

      final lines = find
          .descendant(of: icon, matching: find.byType(Container))
          .evaluate()
          .toList();
      expect(lines, hasLength(3));
      final sizes = lines
          .map((e) => tester.getSize(find.byWidget(e.widget)))
          .toList();
      expect(sizes, const [Size(16, 2), Size(16, 2), Size(8, 2)]);

      final decoration =
          (lines.first.widget as Container).decoration! as BoxDecoration;
      expect(decoration.color, _palette.foregroundMuted);
      expect(decoration.borderRadius, BorderRadius.circular(9999));
    });

    testWidgets('compact rules are top-aligned and evenly distributed', (
      tester,
    ) async {
      await pumpHeader(tester, toggle(), width: _compactWidth);

      final icon = find.byKey(const ValueKey('paseo-mobile-menu-icon'));
      final lines = find
          .descendant(of: icon, matching: find.byType(Container))
          .evaluate()
          .map((e) => tester.getTopLeft(find.byWidget(e.widget)))
          .toList();
      final origin = tester.getTopLeft(icon);
      // space-between across 12px with three 2px rules → 0 / 5 / 10.
      expect(lines.map((o) => o.dy - origin.dy).toList(), const [
        0.0,
        5.0,
        10.0,
      ]);
      // flex-start cross axis: the short rule stays left-aligned.
      expect(lines.map((o) => o.dx - origin.dx).toSet(), {0.0});
    });

    testWidgets('compact keeps the full slot padding and no negative margin', (
      tester,
    ) async {
      await pumpHeader(tester, toggle(), width: _compactWidth);

      expect(
        _slotContainer(
          tester,
          find.byKey(const ValueKey('menu-button')),
        ).padding,
        const EdgeInsets.all(PaseoSpacing.s3),
      );
    });

    testWidgets('compact ignores both window-chrome guards', (tester) async {
      await pumpHeader(
        tester,
        toggle(ownsTopLeftCorner: false, hasTopLeftWindowControls: true),
        width: _compactWidth,
      );

      expect(find.byKey(const ValueKey('menu-button')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('paseo-mobile-menu-icon')),
        findsOneWidget,
      );
    });

    testWidgets('swaps its accessibility label with the open state', (
      tester,
    ) async {
      await pumpHeader(tester, toggle(isOpen: false), width: _compactWidth);
      expect(
        tester
            .widgetList<Semantics>(find.byType(Semantics))
            .any((s) => s.properties.label == 'Open menu'),
        isTrue,
      );

      await pumpHeader(tester, toggle(isOpen: true), width: _compactWidth);
      final semantics = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .firstWhere((s) => s.properties.label == 'Close menu');
      expect(semantics.properties.expanded, isTrue);
    });

    testWidgets('toggles on tap', (tester) async {
      var toggles = 0;
      await pumpHeader(
        tester,
        toggle(onToggle: () => toggles++),
        width: _compactWidth,
      );

      await tapAndSettle(tester, find.byKey(const ValueKey('menu-button')));
      expect(toggles, 1);
    });

    testWidgets('shortcut hint is mod+B on mac and mod+. elsewhere', (
      tester,
    ) async {
      await pumpHeader(tester, toggle());
      expect(_tooltipShortcutKeys(tester), const ['mod', '.']);

      await pumpHeader(
        tester,
        PaseoSidebarMenuToggle(
          isOpen: false,
          onToggle: _noop,
          tooltipLabel: 'Toggle sidebar',
          openLabel: 'Open menu',
          closeLabel: 'Close menu',
          isMac: true,
        ),
      );
      expect(_tooltipShortcutKeys(tester), const ['mod', 'B']);
    });

    testWidgets('tooltip label stays constant while the state label flips', (
      tester,
    ) async {
      await pumpHeader(tester, toggle(isOpen: true));

      final row =
          (tester.widget<Tooltip>(find.byType(Tooltip)).richMessage!
                      as WidgetSpan)
                  .child
              as Row;
      expect((row.children.first as Text).data, 'Toggle sidebar');
    });
  });

  group('PaseoWindowSidebarMenuToggle', () {
    testWidgets('always renders the desktop glyph, even at compact widths', (
      tester,
    ) async {
      await pumpHeader(
        tester,
        PaseoWindowSidebarMenuToggle(
          isOpen: false,
          onToggle: () {},
          tooltipLabel: 'Toggle sidebar',
          openLabel: 'Open menu',
          closeLabel: 'Close menu',
          isMac: false,
        ),
        width: _compactWidth,
      );

      expect(find.byIcon(FluentIcons.side_panel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('paseo-mobile-menu-icon')),
        findsNothing,
      );
    });

    testWidgets('idles at the supplied extra-muted color', (tester) async {
      const extraMuted = Color(0xFF717574);
      await pumpHeader(
        tester,
        const PaseoWindowSidebarMenuToggle(
          isOpen: false,
          onToggle: _noop,
          tooltipLabel: 'Toggle sidebar',
          openLabel: 'Open menu',
          closeLabel: 'Close menu',
          extraMutedForeground: extraMuted,
          isMac: false,
        ),
      );

      expect(
        tester.widget<Icon>(find.byIcon(FluentIcons.side_panel)).color,
        extraMuted,
      );
    });

    testWidgets('falls back to foregroundMuted without an override', (
      tester,
    ) async {
      await pumpHeader(
        tester,
        const PaseoWindowSidebarMenuToggle(
          isOpen: false,
          onToggle: _noop,
          tooltipLabel: 'Toggle sidebar',
          openLabel: 'Open menu',
          closeLabel: 'Close menu',
          isMac: false,
        ),
      );

      expect(
        tester.widget<Icon>(find.byIcon(FluentIcons.side_panel)).color,
        _palette.foregroundMuted,
      );
    });
  });

  group('PaseoMenuHeader', () {
    testWidgets('omits the title node when no title is given', (tester) async {
      await pumpHeader(tester, PaseoMenuHeader(menuToggle: _box('toggle', 16)));

      expect(find.byType(PaseoScreenTitle), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('toggle'))).dx,
        PaseoSpacing.s3,
      );
    });

    testWidgets('places the title one gap after the toggle', (tester) async {
      await pumpHeader(
        tester,
        PaseoMenuHeader(menuToggle: _box('toggle', 16), title: 'Agents'),
      );

      expect(find.text('Agents'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Agents')).dx -
            tester.getTopRight(find.byKey(const ValueKey('toggle'))).dx,
        PaseoSpacing.s2,
      );
    });

    testWidgets('forwards right content, borderless and chrome insets', (
      tester,
    ) async {
      await pumpHeader(
        tester,
        PaseoMenuHeader(
          menuToggle: _box('toggle', 16),
          rightContent: [_box('action', 24)],
          borderless: true,
          windowChromeInsets: const EdgeInsets.only(right: 140),
        ),
      );

      expect(find.byKey(const ValueKey('action')), findsOneWidget);
      expect(_rowBorder(tester).bottom.color, Colors.transparent);
      expect(
        tester.getTopRight(find.byKey(const ValueKey('action'))).dx,
        _desktopWidth - 140 - PaseoSpacing.s3,
      );
    });
  });
}

/// Reads the [ShortcutBadge] out of a header toggle's rich tooltip message,
/// which is otherwise only built once the tooltip actually opens.
List<String> _tooltipShortcutKeys(WidgetTester tester) {
  final row =
      (tester.widget<Tooltip>(find.byType(Tooltip)).richMessage! as WidgetSpan)
              .child
          as Row;
  return (row.children.last as ShortcutBadge).keys;
}

void _noop() {}
