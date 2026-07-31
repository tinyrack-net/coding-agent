/// Port of the frozen Paseo 0.2.0 `components/headers/*` cluster —
/// `screen-header.tsx`, `screen-title.tsx`, `header-icon-badge.tsx`,
/// `header-toggle-button.tsx`, `back-header.tsx`, and `menu-header.tsx`.
///
/// Upstream these six files are one system: [PaseoScreenHeader] owns the frame
/// (surface, safe area, fixed row height, hairline bottom border, the two
/// horizontal clusters), and everything else is a slot that plugs into it.
/// [PaseoBackHeader] and [PaseoMenuHeader] are the only two assemblies the app
/// ever mounts; the rest exist so the leading icon of *every* screen — a back
/// arrow, a sidebar toggle, or a decorative badge — lands on exactly the same
/// pixel. That alignment is the entire reason [paseoHeaderIconSlotPadding] is
/// shared rather than re-declared per call site.
///
/// ## React Native primitives with no Flutter equivalent
///
/// - `useUnistyles()` responsive style values (`{xs: ..., md: ...}`) resolve
///   against Unistyles' `md` breakpoint of 720px. Flutter reads the same
///   threshold from [MediaQuery] via [paseoHeaderIsCompact]; the constant is
///   [adaptiveModalCompactBreakpoint], already 720 in this repo.
/// - `useSafeAreaInsets().top` maps to `MediaQuery.paddingOf(context).top`.
/// - `<TitlebarDragRegion />` is Electron-web only — it returns `null` on
///   native, which is every target of this Flutter app, so it is omitted.
/// - `<WindowChromeSafeArea placement="inline" horizontalPadding={n} />` adds
///   `n` plus whatever the OS window chrome reserves on each side. The chrome
///   context lives outside this cluster, so the reserve arrives as
///   [PaseoScreenHeader.windowChromeInsets] and defaults to zero.
/// - `Pressable`'s `({hovered, pressed}) => ReactNode` render prop maps to
///   fluent's [HoverButton] builder.
/// - Radix `Tooltip` `side`/`offset`/`delayDuration` map onto fluent's
///   [Tooltip] `displayHorizontally`/`verticalOffset`/`waitDuration`.
/// - `zustand` stores, `expo-router`, and `react-i18next` are not in this
///   cluster: open state, the back action, and every user-visible string are
///   constructor parameters instead.
/// - `userSelect: "none"` on the header row has no analogue — Flutter [Text] is
///   already non-selectable unless wrapped in a `SelectionArea`.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

import '../core/theme.dart';
import '../ui/paseo_control_geometry.dart'
    show ButtonControlSize, buttonIconSize;
import '../workspace/paseo_workspace_actions.dart' show paseoFontSizeRamp;
import 'adaptive_modal_sheet.dart' show adaptiveModalCompactBreakpoint;
import 'shortcut_badge.dart';

/// `constants/layout.ts` `HEADER_INNER_HEIGHT` — the desktop row height, shared
/// with the explorer sidebar header so the two line up across the split.
const double paseoHeaderInnerHeight = 48;

/// `constants/layout.ts` `HEADER_INNER_HEIGHT_MOBILE`. Taller than desktop
/// purely to keep the leading icon a comfortable touch target.
const double paseoHeaderInnerHeightMobile = 56;

/// `constants/layout.ts` `HEADER_TOP_PADDING_MOBILE`. Added *on top of* the
/// safe-area inset, and only on compact widths.
const double paseoHeaderTopPaddingMobile = 8;

/// Unistyles' `md` breakpoint (720). Anything narrower resolves the `xs` branch
/// of every responsive style in this file, and is what upstream's
/// `useIsCompactFormFactor()` reports as compact.
const double paseoHeaderCompactBreakpoint = adaptiveModalCompactBreakpoint;

/// `theme.borderRadius.lg`. No repo-wide radius token is exported yet — the
/// only holder, `ControlGeometryTheme.borderRadiusLg`, is an instance default
/// that cannot be reached without a palette — so the frozen value is restated.
const double _borderRadiusLg = 8;

/// `theme.borderRadius.full` — deliberately absurd so any height reads as a
/// pill. Same sourcing caveat as [_borderRadiusLg].
const double _borderRadiusFull = 9999;

/// `theme.borderWidth[1]`.
const double _borderWidth1 = 1;

/// `menu-header.tsx` `MOBILE_MENU_LINE_WIDTH`.
const double _mobileMenuLineWidth = 16;

/// `menu-header.tsx` `MOBILE_MENU_LINE_SHORT_WIDTH` — the third rule is half
/// width, which is what makes the glyph read as a hamburger rather than an
/// equals sign.
const double _mobileMenuLineShortWidth = 8;

/// `menu-header.tsx` `MOBILE_MENU_LINE_HEIGHT`.
const double _mobileMenuLineHeight = 2;

/// Height of `styles.mobileMenuIcon`; the three rules are distributed into it
/// with `justifyContent: "space-between"`.
const double _mobileMenuIconHeight = 12;

/// `theme.iconSize.md` — the desktop sidebar-toggle glyph.
final double _iconSizeMd = buttonIconSize[ButtonControlSize.md]!;

/// `theme.iconSize.lg` — the back arrow, one step larger than the toggle
/// because it is the primary affordance on the screens that use it.
final double _iconSizeLg = buttonIconSize[ButtonControlSize.lg]!;

/// Whether [context] is at a width where every responsive header style resolves
/// its `xs` branch.
///
/// Upstream this is `useIsCompactFormFactor()`, which reads Unistyles' active
/// breakpoint (`xs` or `sm`, i.e. below `md`). Reading [MediaQuery] reproduces
/// it because Unistyles resolves breakpoints from the same window width.
bool paseoHeaderIsCompact(BuildContext context) =>
    MediaQuery.sizeOf(context).width < paseoHeaderCompactBreakpoint;

/// `header-toggle-button.tsx` `headerIconSlotStyle.slot` padding.
///
/// Every leading header icon — [PaseoHeaderIconBadge], [PaseoHeaderToggleButton],
/// and [PaseoBackHeader]'s arrow — pads by this exact amount so the glyphs sit
/// on a shared baseline no matter which header a screen mounts. Compact gets the
/// larger inset because the slot doubles as the touch target there.
EdgeInsets paseoHeaderIconSlotPadding({required bool isCompact}) =>
    EdgeInsets.all(isCompact ? PaseoSpacing.s3 : PaseoSpacing.s2);

/// Side a [PaseoHeaderToggleButton]'s tooltip prefers, mirroring the Radix
/// `side` prop upstream passes through.
enum PaseoHeaderTooltipSide { left, right, top, bottom }

/// The padded, rounded box every header icon sits in.
///
/// Carries `borderRadius` even though nothing paints a background: upstream
/// declares it on the shared slot so a future hover fill lands with the right
/// corners, and dropping it here would silently break that.
class _PaseoHeaderIconSlot extends StatelessWidget {
  const _PaseoHeaderIconSlot({required this.child, this.padding, super.key});

  final Widget child;

  /// Overrides the resolved [paseoHeaderIconSlotPadding]; used to fold
  /// `menu-header.tsx`'s negative `marginLeft` into the slot (see
  /// [PaseoSidebarMenuToggle]).
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final resolved =
        padding ??
        paseoHeaderIconSlotPadding(isCompact: paseoHeaderIsCompact(context));
    return Container(
      padding: resolved,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_borderRadiusLg),
      ),
      child: child,
    );
  }
}

/// Non-interactive icon slot at the start of a header's left cluster.
///
/// Port of `header-icon-badge.tsx`. It exists only to borrow
/// [paseoHeaderIconSlotPadding] from [PaseoHeaderToggleButton]: decorative
/// headers (settings sections, host detail) must put their glyph on the same
/// pixel as the sidebar toggle does on every other screen, and re-deriving the
/// padding locally is how that alignment historically drifted.
class PaseoHeaderIconBadge extends StatelessWidget {
  const PaseoHeaderIconBadge({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _PaseoHeaderIconSlot(
    key: const ValueKey('paseo-header-icon-badge'),
    child: child,
  );
}

/// Canonical screen title for use inside [PaseoScreenHeader].
///
/// Port of `screen-title.tsx`. One typography, one color, responsive weight —
/// compact renders `400` and desktop `300`, because the lighter weight only
/// stays legible at desktop rendering density. Leading icons are *siblings*
/// ([PaseoHeaderToggleButton], [PaseoHeaderIconBadge]), never nested here, so
/// that ellipsizing the title can never eat the icon.
///
/// Returns a [Flexible] because upstream's `flexShrink: 1` + `minWidth: 0` is
/// what lets a long title truncate instead of pushing the right cluster off
/// screen; that only has meaning as a direct child of a [Row], which is exactly
/// how [PaseoScreenHeader] mounts it.
class PaseoScreenTitle extends StatelessWidget {
  const PaseoScreenTitle(this.text, {super.key, this.maxLines = 1, this.style});

  final String text;

  /// `numberOfLines`; RN truncates with a tail ellipsis past this count.
  final int maxLines;

  /// Per-call-site override merged over the canonical style.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final isCompact = paseoHeaderIsCompact(context);
    final base = TextStyle(
      fontSize: paseoFontSizeRamp.base.toDouble(),
      fontWeight: isCompact ? FontWeight.w400 : FontWeight.w300,
      color: context.paseoPalette.foreground,
    );
    return Flexible(
      child: Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style == null ? base : base.merge(style),
      ),
    );
  }
}

/// One horizontal cluster of a header row.
///
/// Upstream both clusters are `flexDirection: row`, `alignItems: center`,
/// `gap: spacing[2]`. They differ only in how they respond to pressure: the
/// left one takes `flex: 1` + `minWidth: 0` so it absorbs the free space and
/// lets its title shrink, the right one takes `flexShrink: 0` so actions are
/// never squeezed.
class _PaseoHeaderCluster extends StatelessWidget {
  const _PaseoHeaderCluster({required this.children, required this.shrinkWrap});

  final List<Widget> children;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
    crossAxisAlignment: CrossAxisAlignment.center,
    spacing: PaseoSpacing.s2,
    children: children,
  );
}

/// Shared frame for the home/back headers.
///
/// Port of `screen-header.tsx`. It exists so padding, the hairline border, the
/// fixed row height, and safe-area handling are maintained in exactly one
/// place — the previous per-screen copies drifted by a pixel or two and made
/// the sidebar and content headers visibly fail to line up.
///
/// Two details are load-bearing and easy to lose:
///
/// - [borderless] does **not** remove the bottom border, it only makes it
///   transparent. The 1px is still laid out, so toggling the flag never nudges
///   the content below by a pixel.
/// - The extra [paseoHeaderTopPaddingMobile] is added *only* on compact widths.
///   Desktop gets the safe-area inset alone, because desktop has no notch to
///   clear and the taller row would just waste chrome.
class PaseoScreenHeader extends StatelessWidget {
  const PaseoScreenHeader({
    super.key,
    this.left = const <Widget>[],
    this.right = const <Widget>[],
    this.borderless = false,
    this.windowChromeInsets = EdgeInsets.zero,
  });

  /// Leading cluster. A `List` rather than a single child because upstream
  /// passes a fragment and relies on the parent's `gap` to space its members —
  /// Flutter can only apply [Row.spacing] if it owns the children.
  final List<Widget> left;

  /// Trailing cluster, same rationale as [left].
  final List<Widget> right;

  /// Renders the bottom hairline transparent while keeping its 1px of layout.
  final bool borderless;

  /// Horizontal space the OS window chrome reserves, added on top of the base
  /// padding. Upstream this comes from `WindowChromeSafeArea`'s context.
  final EdgeInsets windowChromeInsets;

  @override
  Widget build(BuildContext context) {
    final isCompact = paseoHeaderIsCompact(context);
    final palette = context.paseoPalette;
    final topPadding = isCompact ? paseoHeaderTopPaddingMobile : 0.0;
    // Compact trades horizontal room for the wider icon slots it needs.
    final baseHorizontalPadding = isCompact ? PaseoSpacing.s2 : PaseoSpacing.s3;

    return ColoredBox(
      key: const ValueKey('paseo-screen-header'),
      color: palette.surface0,
      child: Padding(
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + topPadding,
        ),
        child: Container(
          key: const ValueKey('paseo-screen-header-row'),
          height: isCompact
              ? paseoHeaderInnerHeightMobile
              : paseoHeaderInnerHeight,
          padding: EdgeInsets.only(
            left: windowChromeInsets.left + baseHorizontalPadding,
            right: windowChromeInsets.right + baseHorizontalPadding,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: borderless ? Colors.transparent : palette.border,
                width: _borderWidth1,
              ),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _PaseoHeaderCluster(shrinkWrap: false, children: left),
              ),
              _PaseoHeaderCluster(shrinkWrap: true, children: right),
            ],
          ),
        ),
      ),
    );
  }
}

/// A header icon that reacts to press, with a tooltip that names the action and
/// spells out its keyboard shortcut.
///
/// Port of `header-toggle-button.tsx`. The button paints no background of its
/// own — the [builder] is handed `hovered`/`pressed` and is expected to answer
/// with a differently-colored glyph. That is deliberate: a fill would break the
/// flush alignment the shared slot exists to guarantee.
///
/// The tooltip is desktop-only. Upstream passes `enabledOnMobile={false}`,
/// which its `Tooltip` resolves against the same compact breakpoint used here,
/// so on compact widths no [Tooltip] is mounted at all.
class PaseoHeaderToggleButton extends StatelessWidget {
  const PaseoHeaderToggleButton({
    super.key,
    required this.onPressed,
    required this.tooltipLabel,
    required this.tooltipKeys,
    required this.tooltipSide,
    required this.builder,
    this.tooltipDelay = Duration.zero,
    this.slotPadding,
    this.disabled = false,
    this.expanded,
    this.semanticLabel,
    this.isMac,
  });

  final VoidCallback onPressed;

  /// Already-translated label; upstream reads `t("shell.menu.toggleSidebar")`.
  final String tooltipLabel;

  /// Shortcut tokens in this repo's `formatShortcutKeys` vocabulary, e.g.
  /// `['mod', 'B']`.
  final List<String> tooltipKeys;

  final PaseoHeaderTooltipSide tooltipSide;

  /// `delayDuration`, upstream-defaulted to zero so the toggle's tooltip is
  /// instant rather than the usual dwell.
  final Duration tooltipDelay;

  /// Replaces the resolved [paseoHeaderIconSlotPadding]; see
  /// [PaseoSidebarMenuToggle] for the one caller that needs it.
  final EdgeInsets? slotPadding;

  final bool disabled;

  /// `accessibilityState.expanded`, surfaced as `aria-expanded` on web.
  final bool? expanded;

  /// `accessibilityLabel`; distinct from [tooltipLabel] because upstream swaps
  /// it between "open" and "close" while the tooltip stays constant.
  final String? semanticLabel;

  /// Whether to render shortcut keys with macOS glyphs. Defaults to the running
  /// platform, standing in for upstream's `getShortcutOs()`.
  final bool? isMac;

  final Widget Function(BuildContext context, bool hovered, bool pressed)
  builder;

  @override
  Widget build(BuildContext context) {
    final isCompact = paseoHeaderIsCompact(context);
    final button = Semantics(
      button: true,
      label: semanticLabel,
      expanded: expanded,
      child: HoverButton(
        onPressed: disabled ? null : onPressed,
        builder: (context, states) => _PaseoHeaderIconSlot(
          padding: slotPadding,
          child: builder(context, states.isHovered, states.isPressed),
        ),
      ),
    );
    if (isCompact) return button;

    final resolvedIsMac =
        isMac ?? defaultTargetPlatform == TargetPlatform.macOS;
    return Tooltip(
      // `offset={8}` upstream; fluent only exposes the gap on one axis.
      style: TooltipThemeData(
        waitDuration: tooltipDelay,
        preferBelow: tooltipSide == PaseoHeaderTooltipSide.bottom,
        verticalOffset: PaseoSpacing.s2,
      ),
      displayHorizontally:
          tooltipSide == PaseoHeaderTooltipSide.left ||
          tooltipSide == PaseoHeaderTooltipSide.right,
      // The button already carries its own label; the tooltip's plain-text
      // projection of a WidgetSpan would only add a placeholder character.
      excludeFromSemantics: true,
      richMessage: WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          spacing: PaseoSpacing.s2,
          children: [
            Text(
              tooltipLabel,
              style: TextStyle(fontSize: paseoFontSizeRamp.sm.toDouble()),
            ),
            // Upstream's `<Shortcut/>`; this repo already ships the same badge.
            ShortcutBadge(keys: tooltipKeys, isMac: resolvedIsMac),
          ],
        ),
      ),
      child: button,
    );
  }
}

/// Header for any screen pushed on top of another.
///
/// Port of `back-header.tsx`. The arrow, the optional title, and the optional
/// accessory are three *siblings* in the left cluster rather than one composed
/// control, so that a missing title collapses to nothing and the arrow does not
/// move. Every element after the arrow is conditional — that is the whole
/// visual contract here.
class PaseoBackHeader extends StatelessWidget {
  const PaseoBackHeader({
    super.key,
    this.title,
    this.titleAccessory,
    this.rightContent = const <Widget>[],
    this.onBack,
    this.backLabel = 'Back',
    this.borderless = false,
    this.windowChromeInsets = EdgeInsets.zero,
  });

  /// Omitted entirely when null — no placeholder, no reserved width.
  final String? title;

  /// Sits immediately after the title; also omitted when null.
  final Widget? titleAccessory;

  final List<Widget> rightContent;

  /// Upstream falls back to `router.back()`; the Flutter analogue is popping
  /// the enclosing [Navigator], which is what null selects.
  final VoidCallback? onBack;

  /// Already-translated `t("common.actions.back")`.
  final String backLabel;

  final bool borderless;
  final EdgeInsets windowChromeInsets;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    return PaseoScreenHeader(
      borderless: borderless,
      windowChromeInsets: windowChromeInsets,
      left: [
        Semantics(
          button: true,
          label: backLabel,
          child: HoverButton(
            onPressed: onBack ?? () => Navigator.of(context).maybePop(),
            builder: (context, states) => _PaseoHeaderIconSlot(
              key: const ValueKey('paseo-back-header-button'),
              // `ArrowLeft` from lucide; `FluentIcons.back` is this repo's
              // established left-arrow glyph.
              child: Icon(
                FluentIcons.back,
                size: _iconSizeLg,
                color: palette.foregroundMuted,
              ),
            ),
          ),
        ),
        if (title != null) PaseoScreenTitle(title!),
        ?titleAccessory,
      ],
      right: rightContent,
    );
  }
}

/// The compact-width sidebar glyph: three stacked rules, the last half width.
///
/// Port of `menu-header.tsx`'s `MobileMenuIcon`. Drawn from primitives rather
/// than an icon font because the exact rule widths (16/16/8) and the 2px pill
/// height are part of the frozen contract, and no bundled glyph reproduces
/// them.
class PaseoMobileMenuIcon extends StatelessWidget {
  const PaseoMobileMenuIcon({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('paseo-mobile-menu-icon'),
    width: _mobileMenuLineWidth,
    height: _mobileMenuIconHeight,
    // `justifyContent: "space-between"` + `alignItems: "flex-start"`.
    child: Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _line(color, _mobileMenuLineWidth),
        _line(color, _mobileMenuLineWidth),
        _line(color, _mobileMenuLineShortWidth),
      ],
    ),
  );

  static Widget _line(Color color, double width) => Container(
    width: width,
    height: _mobileMenuLineHeight,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(_borderRadiusFull),
    ),
  );
}

/// `styles.leadingToggle`: `marginLeft: {xs: 0, md: -spacing[2]}`.
///
/// Flutter has no negative margin, but the slot paints nothing, so subtracting
/// the same amount from the slot's *left padding* is pixel-identical **and**
/// reproduces the part a `Transform` would miss: the element gets narrower, so
/// the title beside it shifts left too. On desktop this resolves to a left
/// padding of exactly zero (`spacing[2] - spacing[2]`), pulling the toggle flush
/// with the row's own inset.
EdgeInsets _leadingTogglePadding({required bool isCompact}) {
  final base = paseoHeaderIconSlotPadding(isCompact: isCompact);
  if (isCompact) return base;
  return base.copyWith(left: base.left - PaseoSpacing.s2);
}

/// The sidebar toggle itself, minus every decision about whether it should be
/// on screen at all.
class _SidebarMenuToggleButton extends StatelessWidget {
  const _SidebarMenuToggleButton({
    required this.isOpen,
    required this.onToggle,
    required this.isMobile,
    required this.tooltipLabel,
    required this.openLabel,
    required this.closeLabel,
    required this.tooltipSide,
    required this.idleColor,
    this.isMac,
  });

  final bool isOpen;
  final VoidCallback onToggle;
  final bool isMobile;
  final String tooltipLabel;
  final String openLabel;
  final String closeLabel;
  final PaseoHeaderTooltipSide tooltipSide;

  /// Resolved `extraMutedIdleIcon ? colors.foregroundExtraMuted :
  /// colors.foregroundMuted`, passed in because only the caller knows which
  /// branch applies.
  final Color? idleColor;

  final bool? isMac;

  @override
  Widget build(BuildContext context) {
    final palette = context.paseoPalette;
    final resolvedIsMac =
        isMac ?? defaultTargetPlatform == TargetPlatform.macOS;
    return PaseoHeaderToggleButton(
      key: const ValueKey('menu-button'),
      onPressed: onToggle,
      tooltipLabel: tooltipLabel,
      // `getShortcutOs() === "mac" ? ["mod","B"] : ["mod","."]` — Windows and
      // Linux already bind Ctrl+B in the composer, hence the different key.
      tooltipKeys: resolvedIsMac ? const ['mod', 'B'] : const ['mod', '.'],
      tooltipSide: tooltipSide,
      isMac: isMac,
      // The label flips with state while the tooltip label stays put.
      semanticLabel: isOpen ? closeLabel : openLabel,
      expanded: isOpen,
      slotPadding: _leadingTogglePadding(isCompact: isMobile),
      builder: (context, hovered, pressed) {
        // Idle is muted so the toggle recedes; any interaction promotes it to
        // full foreground.
        final color = hovered || pressed
            ? palette.foreground
            : (idleColor ?? palette.foregroundMuted);
        if (isMobile) return PaseoMobileMenuIcon(color: color);
        // lucide `PanelLeft`; `FluentIcons.side_panel` is the closest bundled
        // glyph (a frame with a leading rail).
        return Icon(FluentIcons.side_panel, size: _iconSizeMd, color: color);
      },
    );
  }
}

/// The leading sidebar toggle for [PaseoMenuHeader].
///
/// Port of `menu-header.tsx`'s `SidebarMenuToggle`. Three outcomes, and which
/// one you get is the visual contract:
///
/// 1. Desktop where this surface does **not** own the top-left corner — nothing
///    renders. Two toggles competing for the same corner is the bug this guards.
/// 2. Desktop where the corner is covered by OS window controls — an inert,
///    correctly sized placeholder holds the space so the title does not jump
///    once the controls move.
/// 3. Otherwise the live toggle, hamburger on compact and a panel glyph on
///    desktop.
class PaseoSidebarMenuToggle extends StatelessWidget {
  const PaseoSidebarMenuToggle({
    super.key,
    required this.isOpen,
    required this.onToggle,
    required this.tooltipLabel,
    required this.openLabel,
    required this.closeLabel,
    this.ownsTopLeftCorner = true,
    this.hasTopLeftWindowControls = false,
    this.tooltipSide = PaseoHeaderTooltipSide.right,
    this.isMac,
  });

  /// Drives both the accessibility label and `aria-expanded`.
  final bool isOpen;
  final VoidCallback onToggle;

  /// Already-translated `t("shell.menu.toggleSidebar")`.
  final String tooltipLabel;

  /// Already-translated `t("shell.menu.open")`.
  final String openLabel;

  /// Already-translated `t("shell.menu.close")`.
  final String closeLabel;

  /// `useOwnsWindowChromeCorner("top-left")`.
  final bool ownsTopLeftCorner;

  /// `useHasWindowChromeObstruction("top-left")`.
  final bool hasTopLeftWindowControls;

  final PaseoHeaderTooltipSide tooltipSide;
  final bool? isMac;

  @override
  Widget build(BuildContext context) {
    final isMobile = paseoHeaderIsCompact(context);

    if (!isMobile && !ownsTopLeftCorner) return const SizedBox.shrink();

    if (!isMobile && hasTopLeftWindowControls) {
      return IgnorePointer(
        child: _PaseoHeaderIconSlot(
          key: const ValueKey('paseo-sidebar-menu-toggle-placeholder'),
          padding: _leadingTogglePadding(isCompact: false),
          // `styles.desktopMenuIconSpace` — an icon-sized void.
          child: SizedBox.square(dimension: _iconSizeMd),
        ),
      );
    }

    return _SidebarMenuToggleButton(
      isOpen: isOpen,
      onToggle: onToggle,
      isMobile: isMobile,
      tooltipLabel: tooltipLabel,
      openLabel: openLabel,
      closeLabel: closeLabel,
      tooltipSide: tooltipSide,
      idleColor: null,
      isMac: isMac,
    );
  }
}

/// The sidebar toggle as mounted in the desktop window chrome rather than in a
/// screen header.
///
/// Port of `menu-header.tsx`'s `WindowSidebarMenuToggle`. Always renders — the
/// window frame is by definition the corner's owner — always uses the desktop
/// glyph regardless of width, and idles one step more muted because it sits on
/// the title bar next to the OS controls rather than above content.
class PaseoWindowSidebarMenuToggle extends StatelessWidget {
  const PaseoWindowSidebarMenuToggle({
    super.key,
    required this.isOpen,
    required this.onToggle,
    required this.tooltipLabel,
    required this.openLabel,
    required this.closeLabel,
    this.tooltipSide = PaseoHeaderTooltipSide.right,
    this.extraMutedForeground,
    this.isMac,
  });

  final bool isOpen;
  final VoidCallback onToggle;
  final String tooltipLabel;
  final String openLabel;
  final String closeLabel;
  final PaseoHeaderTooltipSide tooltipSide;

  /// `theme.colors.foregroundExtraMuted`, which upstream defines per theme but
  /// this repo's [PaseoPalette] does not carry. Supply it to get the frozen
  /// look; leaving it null falls back to `foregroundMuted` — the same hue, one
  /// step less recessive.
  final Color? extraMutedForeground;

  final bool? isMac;

  @override
  Widget build(BuildContext context) => _SidebarMenuToggleButton(
    isOpen: isOpen,
    onToggle: onToggle,
    isMobile: false,
    tooltipLabel: tooltipLabel,
    openLabel: openLabel,
    closeLabel: closeLabel,
    tooltipSide: tooltipSide,
    idleColor: extraMutedForeground,
    isMac: isMac,
  );
}

/// Header for a top-level screen: sidebar toggle, optional title, optional
/// actions.
///
/// Port of `menu-header.tsx`'s `MenuHeader`. As with [PaseoBackHeader], the
/// title is fully conditional — no title means no node, not an empty one.
///
/// The toggle is injected rather than constructed here because upstream's
/// `SidebarMenuToggle` reads a `zustand` panel store directly, and this cluster
/// deliberately carries no store dependency; callers pass a configured
/// [PaseoSidebarMenuToggle].
class PaseoMenuHeader extends StatelessWidget {
  const PaseoMenuHeader({
    super.key,
    required this.menuToggle,
    this.title,
    this.rightContent = const <Widget>[],
    this.borderless = false,
    this.windowChromeInsets = EdgeInsets.zero,
  });

  final Widget menuToggle;
  final String? title;
  final List<Widget> rightContent;
  final bool borderless;
  final EdgeInsets windowChromeInsets;

  @override
  Widget build(BuildContext context) => PaseoScreenHeader(
    borderless: borderless,
    windowChromeInsets: windowChromeInsets,
    left: [menuToggle, if (title != null) PaseoScreenTitle(title!)],
    right: rightContent,
  );
}
