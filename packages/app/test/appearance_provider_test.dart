import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/state/workspace_focus_mode_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'appearance loads, persists, and cycles in frozen Paseo order',
    () async {
      SharedPreferences.setMockInitialValues({
        'appearance.theme': AppThemeName.claude.name,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appearanceProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(appearanceProvider), AppThemeName.claude);

      final notifier = container.read(appearanceProvider.notifier);
      notifier.cycle();
      expect(container.read(appearanceProvider), AppThemeName.ghostty);
      await notifier.setTheme(AppThemeName.auto);
      notifier.cycle();
      expect(container.read(appearanceProvider), AppThemeName.dark);
      expect(
        (await SharedPreferences.getInstance()).getString('appearance.theme'),
        AppThemeName.dark.name,
      );
    },
  );

  test('focus mode toggles and disables', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(workspaceFocusModeProvider.notifier);
    expect(container.read(workspaceFocusModeProvider), isFalse);
    notifier.toggle();
    expect(container.read(workspaceFocusModeProvider), isTrue);
    notifier.disable();
    expect(container.read(workspaceFocusModeProvider), isFalse);
  });

  test('named themes resolve the frozen Paseo semantic palette', () {
    for (final theme in AppThemeName.values) {
      final data = buildAppTheme(theme, Brightness.light);
      final palette = paseoPaletteFor(theme, Brightness.light);
      expect(data.accentColor.normal, palette.accent);
      expect(data.accentColor.light, palette.accentBright);
      expect(data.scaffoldBackgroundColor, palette.surface0);
      expect(data.menuColor, palette.surface2);
    }
    expect(
      paseoPaletteFor(AppThemeName.dark),
      isA<PaseoPalette>()
          .having(
            (palette) => palette.surface0,
            'surface0',
            const Color(0xFF181B1A),
          )
          .having(
            (palette) => palette.surface1,
            'surface1',
            const Color(0xFF1E2120),
          )
          .having(
            (palette) => palette.surface2,
            'surface2',
            const Color(0xFF272A29),
          )
          .having(
            (palette) => palette.surface3,
            'surface3',
            const Color(0xFF434645),
          )
          .having(
            (palette) => palette.surfaceSidebar,
            'surfaceSidebar',
            const Color(0xFF141716),
          )
          .having(
            (palette) => palette.surfaceSidebarHover,
            'surfaceSidebarHover',
            const Color(0xFF1C1F1E),
          )
          .having(
            (palette) => palette.statusSuccess,
            'statusSuccess',
            const Color(0xFF16A34A),
          )
          .having(
            (palette) => palette.statusDanger,
            'statusDanger',
            const Color(0xFFDC2626),
          )
          .having(
            (palette) => palette.statusWarning,
            'statusWarning',
            const Color(0xFFF59E0B),
          )
          .having(
            (palette) => palette.statusMerged,
            'statusMerged',
            const Color(0xFF9333EA),
          )
          .having(
            (palette) => palette.foreground,
            'foreground',
            const Color(0xFFFAFAFA),
          )
          .having(
            (palette) => palette.foregroundMuted,
            'foregroundMuted',
            const Color(0xFFA1A5A4),
          )
          .having(
            (palette) => palette.border,
            'border',
            const Color(0xFF252B2A),
          )
          .having(
            (palette) => palette.borderAccent,
            'borderAccent',
            const Color(0xFF2F3534),
          )
          .having(
            (palette) => palette.accent,
            'accent',
            const Color(0xFF20744A),
          )
          .having(
            (palette) => palette.accentBright,
            'accentBright',
            const Color(0xFF7CCBA0),
          ),
    );
    expect(
      buildAppTheme(AppThemeName.auto, Brightness.light).brightness,
      Brightness.light,
    );
    expect(
      buildAppTheme(AppThemeName.auto, Brightness.dark).brightness,
      Brightness.dark,
    );
    final light = paseoPaletteFor(AppThemeName.light);
    expect(light.statusSuccess, const Color(0xFF15803D));
    expect(light.statusDanger, const Color(0xFFB91C1C));
    expect(light.statusWarning, const Color(0xFFD97706));
    expect(light.statusMerged, const Color(0xFF7C3AED));
  });
}
