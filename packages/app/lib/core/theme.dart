import 'package:fluent_ui/fluent_ui.dart';

import '../state/appearance_provider.dart';

/// Paseo 0.2.0 semantic colors from the frozen upstream theme contract.
class PaseoPalette {
  const PaseoPalette({
    required this.surface0,
    required this.surface1,
    required this.surface2,
    required this.surface3,
    required this.surfaceSidebar,
    required this.surfaceSidebarHover,
    required this.foreground,
    required this.foregroundMuted,
    required this.border,
    required this.borderAccent,
    required this.accent,
    required this.accentBright,
  });

  final Color surface0;
  final Color surface1;
  final Color surface2;
  final Color surface3;
  final Color surfaceSidebar;
  final Color surfaceSidebarHover;
  final Color foreground;
  final Color foregroundMuted;
  final Color border;
  final Color borderAccent;
  final Color accent;
  final Color accentBright;
}

/// Paseo's frozen xterm palette. This retains cursor-accent and selection
/// foreground even though Flutter xterm's public theme API cannot consume
/// those two colors yet.
class PaseoTerminalPalette {
  const PaseoTerminalPalette({
    required this.background,
    required this.foreground,
    required this.cursor,
    required this.cursorAccent,
    required this.selectionBackground,
    required this.selectionForeground,
    required this.black,
    required this.red,
    required this.green,
    required this.yellow,
    required this.blue,
    required this.magenta,
    required this.cyan,
    required this.white,
    required this.brightBlack,
    required this.brightRed,
    required this.brightGreen,
    required this.brightYellow,
    required this.brightBlue,
    required this.brightMagenta,
    required this.brightCyan,
    required this.brightWhite,
  });

  final Color background;
  final Color foreground;
  final Color cursor;
  final Color cursorAccent;
  final Color selectionBackground;
  final Color selectionForeground;
  final Color black;
  final Color red;
  final Color green;
  final Color yellow;
  final Color blue;
  final Color magenta;
  final Color cyan;
  final Color white;
  final Color brightBlack;
  final Color brightRed;
  final Color brightGreen;
  final Color brightYellow;
  final Color brightBlue;
  final Color brightMagenta;
  final Color brightCyan;
  final Color brightWhite;

  static PaseoTerminalPalette lerp(
    PaseoTerminalPalette first,
    PaseoTerminalPalette second,
    double t,
  ) {
    Color mix(Color left, Color right) => Color.lerp(left, right, t) ?? left;
    return PaseoTerminalPalette(
      background: mix(first.background, second.background),
      foreground: mix(first.foreground, second.foreground),
      cursor: mix(first.cursor, second.cursor),
      cursorAccent: mix(first.cursorAccent, second.cursorAccent),
      selectionBackground: mix(
        first.selectionBackground,
        second.selectionBackground,
      ),
      selectionForeground: mix(
        first.selectionForeground,
        second.selectionForeground,
      ),
      black: mix(first.black, second.black),
      red: mix(first.red, second.red),
      green: mix(first.green, second.green),
      yellow: mix(first.yellow, second.yellow),
      blue: mix(first.blue, second.blue),
      magenta: mix(first.magenta, second.magenta),
      cyan: mix(first.cyan, second.cyan),
      white: mix(first.white, second.white),
      brightBlack: mix(first.brightBlack, second.brightBlack),
      brightRed: mix(first.brightRed, second.brightRed),
      brightGreen: mix(first.brightGreen, second.brightGreen),
      brightYellow: mix(first.brightYellow, second.brightYellow),
      brightBlue: mix(first.brightBlue, second.brightBlue),
      brightMagenta: mix(first.brightMagenta, second.brightMagenta),
      brightCyan: mix(first.brightCyan, second.brightCyan),
      brightWhite: mix(first.brightWhite, second.brightWhite),
    );
  }
}

@immutable
class PaseoThemeTokens extends ThemeExtension<PaseoThemeTokens> {
  const PaseoThemeTokens(this.palette, this.terminalPalette);

  final PaseoPalette palette;
  final PaseoTerminalPalette terminalPalette;

  @override
  PaseoThemeTokens copyWith({
    PaseoPalette? palette,
    PaseoTerminalPalette? terminalPalette,
  }) => PaseoThemeTokens(
    palette ?? this.palette,
    terminalPalette ?? this.terminalPalette,
  );

  @override
  PaseoThemeTokens lerp(
    covariant ThemeExtension<PaseoThemeTokens>? other,
    double t,
  ) {
    if (other is! PaseoThemeTokens) return this;
    Color mix(Color first, Color second) =>
        Color.lerp(first, second, t) ?? first;
    return PaseoThemeTokens(
      PaseoPalette(
        surface0: mix(palette.surface0, other.palette.surface0),
        surface1: mix(palette.surface1, other.palette.surface1),
        surface2: mix(palette.surface2, other.palette.surface2),
        surface3: mix(palette.surface3, other.palette.surface3),
        surfaceSidebar: mix(
          palette.surfaceSidebar,
          other.palette.surfaceSidebar,
        ),
        surfaceSidebarHover: mix(
          palette.surfaceSidebarHover,
          other.palette.surfaceSidebarHover,
        ),
        foreground: mix(palette.foreground, other.palette.foreground),
        foregroundMuted: mix(
          palette.foregroundMuted,
          other.palette.foregroundMuted,
        ),
        border: mix(palette.border, other.palette.border),
        borderAccent: mix(palette.borderAccent, other.palette.borderAccent),
        accent: mix(palette.accent, other.palette.accent),
        accentBright: mix(palette.accentBright, other.palette.accentBright),
      ),
      PaseoTerminalPalette.lerp(terminalPalette, other.terminalPalette, t),
    );
  }
}

PaseoTerminalPalette paseoTerminalPaletteFor(
  AppThemeName name, [
  Brightness platformBrightness = Brightness.dark,
]) {
  final resolvedName = name == AppThemeName.auto
      ? (platformBrightness == Brightness.light
            ? AppThemeName.light
            : AppThemeName.dark)
      : name;
  if (resolvedName == AppThemeName.light) {
    return const PaseoTerminalPalette(
      background: Color(0xFFFFFFFF),
      foreground: Color(0xFF1A1A1E),
      cursor: Color(0xFF1A1A1E),
      cursorAccent: Color(0xFFFFFFFF),
      selectionBackground: Color(0x26000000),
      selectionForeground: Color(0xFF1A1A1E),
      black: Color(0xFF1A1A1E),
      red: Color(0xFFDC2626),
      green: Color(0xFF16A34A),
      yellow: Color(0xFFCA8A04),
      blue: Color(0xFF2563EB),
      magenta: Color(0xFF9333EA),
      cyan: Color(0xFF0891B2),
      white: Color(0xFFFFFFFF),
      brightBlack: Color(0xFF3F3F46),
      brightRed: Color(0xFFEF4444),
      brightGreen: Color(0xFF22C55E),
      brightYellow: Color(0xFFF59E0B),
      brightBlue: Color(0xFF3B82F6),
      brightMagenta: Color(0xFFA855F7),
      brightCyan: Color(0xFF06B6D4),
      brightWhite: Color(0xFFFAFAFA),
    );
  }

  final (background, black, brightBlack) = switch (resolvedName) {
    AppThemeName.zinc => (
      const Color(0xFF18181B),
      const Color(0xFF131316),
      const Color(0xFF3F3F46),
    ),
    AppThemeName.midnight => (
      const Color(0xFF161820),
      const Color(0xFF121420),
      const Color(0xFF3C3E4C),
    ),
    AppThemeName.claude => (
      const Color(0xFF1F1F1E),
      const Color(0xFF1A1918),
      const Color(0xFF4A4745),
    ),
    AppThemeName.ghostty => (
      const Color(0xFF282C34),
      const Color(0xFF21252D),
      const Color(0xFF4A4F5E),
    ),
    AppThemeName.dark || AppThemeName.auto || AppThemeName.light => (
      const Color(0xFF181B1A),
      const Color(0xFF141716),
      const Color(0xFF434645),
    ),
  };
  return PaseoTerminalPalette(
    background: background,
    foreground: const Color(0xFFFAFAFA),
    cursor: const Color(0xFFFAFAFA),
    cursorAccent: background,
    selectionBackground: const Color(0x33FFFFFF),
    selectionForeground: const Color(0xFFFAFAFA),
    black: black,
    red: const Color(0xFFE07070),
    green: const Color(0xFF5DBA80),
    yellow: const Color(0xFFD4A44A),
    blue: const Color(0xFF6A9DE0),
    magenta: const Color(0xFFB07AD0),
    cyan: const Color(0xFF4AABB8),
    white: const Color(0xFFD4D4D8),
    brightBlack: brightBlack,
    brightRed: const Color(0xFFE89090),
    brightGreen: const Color(0xFF7ECF9A),
    brightYellow: const Color(0xFFE0BE6E),
    brightBlue: const Color(0xFF8AB4E8),
    brightMagenta: const Color(0xFFC49AE0),
    brightCyan: const Color(0xFF6EC2CC),
    brightWhite: const Color(0xFFF0F0F2),
  );
}

PaseoPalette paseoPaletteFor(
  AppThemeName name, [
  Brightness platformBrightness = Brightness.dark,
]) {
  final resolvedName = name == AppThemeName.auto
      ? (platformBrightness == Brightness.light
            ? AppThemeName.light
            : AppThemeName.dark)
      : name;
  return switch (resolvedName) {
    AppThemeName.light => const PaseoPalette(
      surface0: Color(0xFFFFFFFF),
      surface1: Color(0xFFFAFAFA),
      surface2: Color(0xFFF4F4F5),
      surface3: Color(0xFFE4E4E7),
      surfaceSidebar: Color(0xFFF4F4F5),
      surfaceSidebarHover: Color(0xFFE9E9EC),
      foreground: Color(0xFF1A1A1E),
      foregroundMuted: Color(0xFF71717A),
      border: Color(0xFFE4E4E7),
      borderAccent: Color(0xFFECECF1),
      accent: Color(0xFF20744A),
      accentBright: Color(0xFF239956),
    ),
    AppThemeName.zinc => const PaseoPalette(
      surface0: Color(0xFF18181B),
      surface1: Color(0xFF1F1F22),
      surface2: Color(0xFF27272A),
      surface3: Color(0xFF3F3F46),
      surfaceSidebar: Color(0xFF131316),
      surfaceSidebarHover: Color(0xFF1B1B1E),
      foreground: Color(0xFFFAFAFA),
      foregroundMuted: Color(0xFFA1A1AA),
      border: Color(0xFF27272A),
      borderAccent: Color(0xFF303036),
      accent: Color(0xFFE4E4E7),
      accentBright: Color(0xFFFAFAFA),
    ),
    AppThemeName.midnight => const PaseoPalette(
      surface0: Color(0xFF161820),
      surface1: Color(0xFF1C1E27),
      surface2: Color(0xFF252731),
      surface3: Color(0xFF3C3E4C),
      surfaceSidebar: Color(0xFF121420),
      surfaceSidebarHover: Color(0xFF1A1C28),
      foreground: Color(0xFFFAFAFA),
      foregroundMuted: Color(0xFF9A9DB0),
      border: Color(0xFF242636),
      borderAccent: Color(0xFF2E3040),
      accent: Color(0xFF3B6FCF),
      accentBright: Color(0xFF7EAAEB),
    ),
    AppThemeName.claude => const PaseoPalette(
      surface0: Color(0xFF1F1F1E),
      surface1: Color(0xFF262523),
      surface2: Color(0xFF2F2D2B),
      surface3: Color(0xFF4A4745),
      surfaceSidebar: Color(0xFF1A1918),
      surfaceSidebarHover: Color(0xFF222120),
      foreground: Color(0xFFFAFAFA),
      foregroundMuted: Color(0xFFADA9A5),
      border: Color(0xFF2C2A27),
      borderAccent: Color(0xFF36332F),
      accent: Color(0xFFD97757),
      accentBright: Color(0xFFE89A7F),
    ),
    AppThemeName.ghostty => const PaseoPalette(
      surface0: Color(0xFF282C34),
      surface1: Color(0xFF2F333D),
      surface2: Color(0xFF383C48),
      surface3: Color(0xFF4A4F5E),
      surfaceSidebar: Color(0xFF21252D),
      surfaceSidebarHover: Color(0xFF292D36),
      foreground: Color(0xFFFAFAFA),
      foregroundMuted: Color(0xFFC8CCD8),
      border: Color(0xFF353A47),
      borderAccent: Color(0xFF3F4454),
      accent: Color(0xFF89B4FA),
      accentBright: Color(0xFFB4D0FC),
    ),
    AppThemeName.dark || AppThemeName.auto => const PaseoPalette(
      surface0: Color(0xFF181B1A),
      surface1: Color(0xFF1E2120),
      surface2: Color(0xFF272A29),
      surface3: Color(0xFF434645),
      surfaceSidebar: Color(0xFF141716),
      surfaceSidebarHover: Color(0xFF1C1F1E),
      foreground: Color(0xFFFAFAFA),
      foregroundMuted: Color(0xFFA1A5A4),
      border: Color(0xFF252B2A),
      borderAccent: Color(0xFF2F3534),
      accent: Color(0xFF20744A),
      accentBright: Color(0xFF7CCBA0),
    ),
  };
}

FluentThemeData buildAppTheme([
  AppThemeName name = AppThemeName.dark,
  Brightness platformBrightness = Brightness.dark,
]) {
  final resolvedName = name == AppThemeName.auto
      ? (platformBrightness == Brightness.light
            ? AppThemeName.light
            : AppThemeName.dark)
      : name;
  final brightness = resolvedName == AppThemeName.light
      ? Brightness.light
      : Brightness.dark;
  final palette = paseoPaletteFor(resolvedName, platformBrightness);
  final terminalPalette = paseoTerminalPaletteFor(
    resolvedName,
    platformBrightness,
  );
  final accent = AccentColor.swatch({
    'darkest': palette.accent,
    'darker': palette.accent,
    'dark': palette.accent,
    'normal': palette.accent,
    'light': palette.accentBright,
    'lighter': palette.accentBright,
    'lightest': palette.accentBright,
  });
  final base = FluentThemeData(brightness: brightness, accentColor: accent);
  return base.copyWith(
    extensions: [
      ...base.extensions.values,
      PaseoThemeTokens(palette, terminalPalette),
    ],
    scaffoldBackgroundColor: palette.surface0,
    menuColor: palette.surface2,
  );
}

/// Semantic color tokens used across the app, mapped onto the closest
/// [FluentThemeData.resources] fields. Centralizing these avoids every
/// screen hand-picking raw resource fields (whose names don't map 1:1 onto
/// Material's `ColorScheme`, which this app used before the fluent_ui
/// migration).
class AppColors {
  const AppColors._(this._theme);

  final FluentThemeData _theme;

  Color get error => _theme.resources.systemFillColorCritical;
  Color get errorContainer =>
      _theme.resources.systemFillColorCriticalBackground;
  Color get onErrorContainer => _theme.resources.textFillColorPrimary;
  Color get onError => Colors.white;

  Color get outline => _theme.resources.controlStrokeColorDefault;
  Color get outlineVariant => _theme.resources.dividerStrokeColorDefault;

  Color get surfaceContainerHighest =>
      _theme.resources.cardBackgroundFillColorSecondary;
  Color get onSurfaceVariant => _theme.resources.textFillColorSecondary;

  Color get primary => _theme.accentColor.normal;
  Color get primaryContainer => _theme.accentColor.dark;
  Color get onPrimaryContainer => _theme.resources.textOnAccentFillColorPrimary;

  // Fluent has no "tertiary" concept; reuse accent variants as the closest
  // stand-in for the Material tertiary/tertiaryContainer pairing.
  Color get tertiary => _theme.accentColor.light;
  Color get tertiaryContainer => _theme.accentColor.lighter;
}

/// Status colors for run-state/tool-status/diff/connection indicators,
/// centralizing what used to be ad-hoc `Colors.green/amber/red/...` scattered
/// across the codebase.
class StatusColors {
  const StatusColors._(this._theme);

  final FluentThemeData _theme;

  Color get success => _theme.resources.systemFillColorSuccess;
  Color get running => _theme.resources.systemFillColorCaution;
  Color get warning => _theme.resources.systemFillColorCaution;
  Color get danger => _theme.resources.systemFillColorCritical;
  Color get neutral => _theme.resources.textFillColorSecondary;
  Color get diffAddition => _theme.brightness == Brightness.light
      ? const Color(0xFF15803D)
      : const Color(0xFF4ADE80);
  Color get diffDeletion => _theme.brightness == Brightness.light
      ? const Color(0xFFB91C1C)
      : const Color(0xFFEF4444);
}

/// Text styles used across the app, mapped onto [Typography] (Fluent's
/// type-ramp has different names/sizes than Material's `TextTheme`).
class AppTextStyles {
  const AppTextStyles._(this._typography);

  final Typography _typography;

  TextStyle? get titleLarge => _typography.titleLarge;
  TextStyle? get titleMedium => _typography.title;
  TextStyle? get titleSmall => _typography.subtitle;
  TextStyle? get labelLarge => _typography.bodyStrong;
  TextStyle? get bodyMedium => _typography.body;
  TextStyle? get bodySmall => _typography.caption;
}

extension AppThemeContext on BuildContext {
  FluentThemeData get fluentTheme => FluentTheme.of(this);
  PaseoPalette get paseoPalette =>
      FluentTheme.of(this).extension<PaseoThemeTokens>()?.palette ??
      paseoPaletteFor(
        FluentTheme.of(this).brightness == Brightness.light
            ? AppThemeName.light
            : AppThemeName.dark,
      );
  PaseoTerminalPalette get paseoTerminalPalette =>
      FluentTheme.of(this).extension<PaseoThemeTokens>()?.terminalPalette ??
      paseoTerminalPaletteFor(
        FluentTheme.of(this).brightness == Brightness.light
            ? AppThemeName.light
            : AppThemeName.dark,
      );
  AppColors get tokens => AppColors._(FluentTheme.of(this));
  StatusColors get statusColors => StatusColors._(FluentTheme.of(this));
  AppTextStyles get textStyles =>
      AppTextStyles._(FluentTheme.of(this).typography);
}
