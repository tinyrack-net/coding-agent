import 'package:fluent_ui/fluent_ui.dart';

/// The app's single (dark-only) Fluent theme.
FluentThemeData buildAppTheme() {
  final base = FluentThemeData(brightness: Brightness.dark, accentColor: Colors.teal);
  // fluent_ui defaults menuColor (dialogs, flyouts, menus) to a lighter grey
  // than scaffoldBackgroundColor to convey Fluent Design's popup-elevation
  // layering; this app wants a flat near-black look everywhere instead.
  return base.copyWith(menuColor: base.scaffoldBackgroundColor);
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
  Color get errorContainer => _theme.resources.systemFillColorCriticalBackground;
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
  AppColors get tokens => AppColors._(FluentTheme.of(this));
  StatusColors get statusColors => StatusColors._(FluentTheme.of(this));
  AppTextStyles get textStyles => AppTextStyles._(FluentTheme.of(this).typography);
}
