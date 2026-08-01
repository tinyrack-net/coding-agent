/// Frozen Paseo 0.2.0 icon components, ported from the upstream
/// `packages/app/src/components/icons/` cluster.
///
/// Twelve of the seventeen upstream components already ship in this app and are
/// deliberately not duplicated here; see [paseoIconsRenderedElsewhere]. This
/// library covers the remaining five: the shared `SvgPathIcon` base, the
/// Discord glyph, the Paseo logo, the source-control panel glyph, and the
/// editor-target dispatcher.
///
/// Upstream draws every glyph with `fill="currentColor"` (or an explicit
/// `theme.colors.foreground` for the logo). React Native resolves that through
/// the ambient text color, so each widget here takes an optional [Color] and
/// falls back to `context.paseoPalette.foreground`, this app's port of that
/// same token.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/workspace/paseo_workspace_actions.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Frozen path data of `discord-icon.tsx`.
const _discordIconPath =
    'M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z';

/// Frozen path data of `paseo-logo.tsx`.
const _paseoLogoPath =
    'M291.495 91.399C333.897 104.892 379.155 135.075 416.229 173.191C453.389 211.394 484.429 259.725 495.708 311.251C497.555 319.693 498.865 328.216 499.586 336.776C509.755 326.554 519.867 317.815 529.89 311.547C540.647 304.821 553.808 299.297 568.641 299.785C584.29 300.299 597.395 307.326 607.747 317.632C632.173 341.947 629.612 372.898 619.872 397.936C610.185 422.833 591.557 447.826 572.732 469.124C553.591 490.78 532.713 510.308 516.779 524.318C508.775 531.355 501.936 537.073 497.07 541.052C494.635 543.043 492.689 544.603 491.334 545.679C490.657 546.217 490.126 546.635 489.756 546.926C489.571 547.071 489.425 547.184 489.321 547.265C489.269 547.305 489.227 547.338 489.196 547.362C489.181 547.374 489.168 547.385 489.157 547.393C489.153 547.397 489.147 547.401 489.144 547.403C489.134 547.4 488.837 547.06 473.001 528.499L489.135 547.411C478.157 555.911 462.033 554.334 453.122 543.89C444.213 533.448 445.887 518.094 456.861 509.592C456.863 509.591 456.865 509.588 456.869 509.586C456.88 509.577 456.902 509.561 456.933 509.536C456.997 509.487 457.101 509.404 457.245 509.292C457.533 509.066 457.979 508.715 458.569 508.247C459.749 507.31 461.506 505.901 463.742 504.073C468.216 500.414 474.589 495.088 482.073 488.508C497.114 475.284 516.315 457.282 533.578 437.75C551.157 417.862 565.26 398.01 571.859 381.048C578.403 364.227 575.681 356.302 570.724 351.367C568.928 349.579 567.744 348.902 567.267 348.676C566.888 348.496 566.811 348.52 566.804 348.52C566.605 348.513 563.971 348.537 557.953 352.3C545.161 360.299 528.815 377.492 506.807 403.867C494.927 418.106 481.871 434.435 467.547 451.957C463.709 457.28 459.503 462.538 454.91 467.717L454.702 467.549C420.808 508.347 380.37 553.856 332.335 593.848C301.853 619.226 262.656 622.597 228.642 614.743C194.834 606.936 162.658 587.448 142.217 561.686C108.054 518.631 100.57 469.801 108.223 427.836C115.56 387.606 137.391 351.005 166.502 331.557C161.248 315.813 156.813 299.49 153.519 283.013C142.593 228.368 143.239 167.031 174.28 119.619C186.922 100.31 205.846 89.1535 227.387 85.2773C248.1 81.5504 270.278 84.648 291.495 91.399ZM378.642 206.356C345.773 172.563 307.463 147.917 275.208 137.654C259.096 132.527 246.171 131.514 236.828 133.195C228.314 134.727 222.227 138.497 217.721 145.38C196.712 177.468 193.858 224.004 203.82 273.827C206.532 287.394 210.127 300.834 214.345 313.817C236.45 310.276 260.156 311.463 281.22 317.11C319.621 327.403 357.501 355.419 357.501 405.654C357.501 435.255 339.111 465.136 307.278 473.815C273.211 483.103 238.854 464.822 213.105 427.541C203.716 413.947 194.443 397.766 185.947 379.89C174.028 392.223 163.08 411.953 158.673 436.118C153.128 466.518 158.514 501.286 183.085 532.253C195.993 548.522 217.742 562.031 240.771 567.349C263.594 572.619 284.147 569.24 298.664 557.154C349.383 514.927 390.709 466.547 426.366 422.952C448.879 390.86 453.195 356.06 445.578 321.265C436.703 280.718 411.425 240.06 378.642 206.356ZM306.296 405.722C306.296 384.769 292.223 370.736 267.284 364.051C256.012 361.03 244.156 360.087 233.095 360.771C240.361 375.935 248.168 389.513 255.897 400.704C275.647 429.298 289.989 427.822 293.247 426.934C298.737 425.437 306.296 418.161 306.296 405.722Z';

/// Frozen path data of lucide 0.546.0 `Folder`, the glyph
/// `editor-target-icon.tsx` renders for the `folder` symbol.
const _lucideFolderPath =
    'M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z';

/// Frozen caret stroke of lucide 0.546.0 `SquareTerminal`, the glyph
/// `editor-target-icon.tsx` falls back to.
const _lucideSquareTerminalCaretPath = 'm7 11 2-2-2-2';

/// Frozen prompt stroke of lucide 0.546.0 `SquareTerminal`.
const _lucideSquareTerminalBarPath = 'M11 13h4';

/// Every frozen SVG path string this library draws, keyed by its source.
///
/// Exposed so tests can pin the path data without reaching into the widgets.
const paseoIconPaths = <String, String>{
  'discord-icon.tsx': _discordIconPath,
  'paseo-logo.tsx': _paseoLogoPath,
  'lucide/folder': _lucideFolderPath,
  'lucide/square-terminal:caret': _lucideSquareTerminalCaretPath,
  'lucide/square-terminal:bar': _lucideSquareTerminalBarPath,
};

/// Frozen `viewBox` per upstream component.
///
/// `svg-path-icon.tsx` takes its view box as a prop and so has no entry.
/// `editor-target-icon.tsx` inherits lucide's 24x24 box for its symbol branch.
const paseoIconViewBoxes = <String, String>{
  'discord-icon.tsx': '0 0 24 24',
  'paseo-logo.tsx': '0 0 700 700',
  'source-control-panel-icon.tsx': '0 0 24 24',
  'editor-target-icon.tsx': '0 0 24 24',
};

/// Frozen default `size` prop per upstream component.
const paseoIconDefaultSizes = <String, double>{
  'svg-path-icon.tsx': 16,
  'discord-icon.tsx': 16,
  'paseo-logo.tsx': 64,
  'source-control-panel-icon.tsx': 16,
  'editor-target-icon.tsx': 16,
};

/// Frozen default `strokeWidth` prop of `source-control-panel-icon.tsx`.
const paseoSourceControlPanelDefaultStrokeWidth = 2.0;

/// The upstream icon components whose frozen path data already ships in this
/// app, mapped to the widget that renders it.
///
/// Listed instead of re-ported so the cluster stays enumerable without a second
/// copy of any path string.
const paseoIconsRenderedElsewhere = <String, String>{
  'claude-icon.tsx': 'ProviderIcon(provider: claude)',
  'codex-icon.tsx': 'ProviderIcon(provider: codex)',
  'copilot-icon.tsx': 'ProviderIcon(provider: copilot)',
  'minimax-icon.tsx': 'ProviderIcon(provider: minimax)',
  'omp-icon.tsx': 'ProviderIcon(provider: omp)',
  'opencode-icon.tsx': 'ProviderIcon(provider: opencode)',
  'pi-icon.tsx': 'ProviderIcon(provider: pi)',
  'github-icon.tsx': 'ForgeBrandIcon(iconKind: github)',
  'gitlab-icon.tsx': 'ForgeBrandIcon(iconKind: gitlab)',
  'gitea-icon.tsx': 'ForgeBrandIcon(iconKind: gitea)',
  'forgejo-icon.tsx': 'ForgeBrandIcon(iconKind: forgejo)',
  'codeberg-icon.tsx': 'ForgeBrandIcon(iconKind: codeberg)',
};

const _lucideStrokeAttributes =
    'fill="none" stroke="currentColor" stroke-width="2" '
    'stroke-linecap="round" stroke-linejoin="round"';

const _lucideFolderSvg =
    '<svg viewBox="0 0 24 24" $_lucideStrokeAttributes>'
    '<path d="$_lucideFolderPath"/>'
    '</svg>';

const _lucideSquareTerminalSvg =
    '<svg viewBox="0 0 24 24" $_lucideStrokeAttributes>'
    '<path d="$_lucideSquareTerminalCaretPath"/>'
    '<path d="$_lucideSquareTerminalBarPath"/>'
    '<rect width="18" height="18" x="3" y="3" rx="2" ry="2"/>'
    '</svg>';

/// Frozen lucide 0.546.0 markup for the two built-in symbols
/// `editor-target-icon.tsx` can fall back to.
const paseoEditorTargetGlyphSvgs = <String, String>{
  'folder': _lucideFolderSvg,
  'square-terminal': _lucideSquareTerminalSvg,
};

/// Frozen markup of `source-control-panel-icon.tsx` at [strokeWidth].
///
/// Upstream draws a rounded `Rect` plus three `Line`s (a plus and a minus)
/// rather than path data, so the whole shape is pinned here as markup.
String paseoSourceControlPanelIconSvg(double strokeWidth) =>
    '<svg viewBox="0 0 24 24" fill="none">'
    '<rect x="3" y="3" width="18" height="18" rx="2" stroke="currentColor" '
    'stroke-width="$strokeWidth" stroke-linecap="round" '
    'stroke-linejoin="round"/>'
    '<line x1="9" y1="9.5" x2="15" y2="9.5" stroke="currentColor" '
    'stroke-width="$strokeWidth" stroke-linecap="round"/>'
    '<line x1="12" y1="6.5" x2="12" y2="12.5" stroke="currentColor" '
    'stroke-width="$strokeWidth" stroke-linecap="round"/>'
    '<line x1="9" y1="16" x2="15" y2="16" stroke="currentColor" '
    'stroke-width="$strokeWidth" stroke-linecap="round"/>'
    '</svg>';

/// Port of `packages/app/src/components/icons/svg-path-icon.tsx`.
///
/// Upstream renders a single `<Path d={path} />` inside an `<Svg>` sized
/// `size` x `size` and filled with `color`, defaulting to `currentColor`.
class PaseoSvgPathIcon extends StatelessWidget {
  const PaseoSvgPathIcon({
    super.key,
    required this.path,
    required this.viewBox,
    this.size = 16,
    this.color,
  });

  final String path;
  final String viewBox;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SvgPicture.string(
    '<svg viewBox="$viewBox"><path d="$path"/></svg>',
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(
      color ?? context.paseoPalette.foreground,
      BlendMode.srcIn,
    ),
  );
}

/// Port of `packages/app/src/components/icons/discord-icon.tsx`.
class PaseoDiscordIcon extends StatelessWidget {
  const PaseoDiscordIcon({super.key, this.size = 16, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => PaseoSvgPathIcon(
    path: _discordIconPath,
    viewBox: '0 0 24 24',
    size: size,
    color: color,
  );
}

/// Port of `packages/app/src/components/icons/paseo-logo.tsx`.
///
/// Upstream defaults its fill to `theme.colors.foreground` rather than
/// `currentColor`, and its default `size` is 64 rather than 16.
class PaseoLogo extends StatelessWidget {
  const PaseoLogo({super.key, this.size = 64, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => PaseoSvgPathIcon(
    path: _paseoLogoPath,
    viewBox: '0 0 700 700',
    size: size,
    color: color,
  );
}

/// Port of `packages/app/src/components/icons/source-control-panel-icon.tsx`.
class PaseoSourceControlPanelIcon extends StatelessWidget {
  const PaseoSourceControlPanelIcon({
    super.key,
    this.size = 16,
    this.color,
    this.strokeWidth = paseoSourceControlPanelDefaultStrokeWidth,
  });

  final double size;
  final Color? color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) => SvgPicture.string(
    paseoSourceControlPanelIconSvg(strokeWidth),
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(
      color ?? context.paseoPalette.foreground,
      BlendMode.srcIn,
    ),
  );
}

/// Port of `packages/app/src/components/icons/editor-target-icon.tsx`.
///
/// Upstream renders the host-supplied app icon when the target carries one and
/// otherwise falls back to lucide's `Folder` or `SquareTerminal`.
class PaseoEditorTargetIcon extends StatelessWidget {
  const PaseoEditorTargetIcon({
    super.key,
    required this.icon,
    this.size = 16,
    this.color,
  });

  final DesktopOpenTargetIcon icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => switch (icon) {
    ImageDesktopOpenTargetIcon(:final dataUrl) => _image(dataUrl),
    SymbolDesktopOpenTargetIcon(name: DesktopOpenTargetSymbol.folder) => _glyph(
      context,
      _lucideFolderSvg,
    ),
    SymbolDesktopOpenTargetIcon() => _glyph(context, _lucideSquareTerminalSvg),
  };

  Widget _image(String dataUrl) {
    final bytes = _decodeBase64DataUrl(dataUrl);
    if (bytes == null) return SizedBox.square(dimension: size);
    return Image.memory(
      bytes,
      width: size,
      height: size,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) =>
          SizedBox.square(dimension: size),
    );
  }

  Widget _glyph(BuildContext context, String svg) => SvgPicture.string(
    svg,
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(
      color ?? context.paseoPalette.foreground,
      BlendMode.srcIn,
    ),
  );
}

/// Decodes a `data:<mime>;base64,<payload>` URL, or returns null when the value
/// is not one this app can turn into image bytes.
Uint8List? _decodeBase64DataUrl(String value) {
  final comma = value.indexOf(',');
  if (comma < 0) return null;
  final header = value.substring(0, comma);
  if (!header.startsWith('data:') || !header.endsWith(';base64')) return null;
  try {
    return base64Decode(value.substring(comma + 1));
  } on FormatException {
    return null;
  }
}
