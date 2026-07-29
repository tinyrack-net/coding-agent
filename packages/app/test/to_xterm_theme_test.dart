import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/terminal/to_xterm_theme.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('light terminal palette matches frozen Paseo colors', () {
    final palette = paseoTerminalPaletteFor(AppThemeName.light);

    expect(palette.background, const Color(0xFFFFFFFF));
    expect(palette.foreground, const Color(0xFF1A1A1E));
    expect(palette.cursor, const Color(0xFF1A1A1E));
    expect(palette.cursorAccent, const Color(0xFFFFFFFF));
    expect(palette.selectionBackground, const Color(0x26000000));
    expect(palette.selectionForeground, const Color(0xFF1A1A1E));
    expect(
      [
        palette.black,
        palette.red,
        palette.green,
        palette.yellow,
        palette.blue,
        palette.magenta,
        palette.cyan,
        palette.white,
      ],
      const [
        Color(0xFF1A1A1E),
        Color(0xFFDC2626),
        Color(0xFF16A34A),
        Color(0xFFCA8A04),
        Color(0xFF2563EB),
        Color(0xFF9333EA),
        Color(0xFF0891B2),
        Color(0xFFFFFFFF),
      ],
    );
    expect(
      [
        palette.brightBlack,
        palette.brightRed,
        palette.brightGreen,
        palette.brightYellow,
        palette.brightBlue,
        palette.brightMagenta,
        palette.brightCyan,
        palette.brightWhite,
      ],
      const [
        Color(0xFF3F3F46),
        Color(0xFFEF4444),
        Color(0xFF22C55E),
        Color(0xFFF59E0B),
        Color(0xFF3B82F6),
        Color(0xFFA855F7),
        Color(0xFF06B6D4),
        Color(0xFFFAFAFA),
      ],
    );
  });

  test('dark themes share ANSI colors but keep their frozen tint anchors', () {
    final expectedAnchors = {
      AppThemeName.dark: const [
        Color(0xFF181B1A),
        Color(0xFF141716),
        Color(0xFF434645),
      ],
      AppThemeName.zinc: const [
        Color(0xFF18181B),
        Color(0xFF131316),
        Color(0xFF3F3F46),
      ],
      AppThemeName.midnight: const [
        Color(0xFF161820),
        Color(0xFF121420),
        Color(0xFF3C3E4C),
      ],
      AppThemeName.claude: const [
        Color(0xFF1F1F1E),
        Color(0xFF1A1918),
        Color(0xFF4A4745),
      ],
      AppThemeName.ghostty: const [
        Color(0xFF282C34),
        Color(0xFF21252D),
        Color(0xFF4A4F5E),
      ],
    };

    for (final MapEntry(:key, :value) in expectedAnchors.entries) {
      final palette = paseoTerminalPaletteFor(key);
      expect(
        [palette.background, palette.black, palette.brightBlack],
        value,
        reason: key.name,
      );
      expect(palette.cursorAccent, palette.background);
      expect(palette.selectionBackground, const Color(0x33FFFFFF));
      expect(palette.red, const Color(0xFFE07070));
      expect(palette.brightWhite, const Color(0xFFF0F0F2));
    }
  });

  test('auto terminal palette follows platform brightness', () {
    expect(
      paseoTerminalPaletteFor(AppThemeName.auto, Brightness.light).background,
      const Color(0xFFFFFFFF),
    );
    expect(
      paseoTerminalPaletteFor(AppThemeName.auto, Brightness.dark).background,
      const Color(0xFF181B1A),
    );
  });

  test('toXtermTheme preserves every frozen palette field', () {
    final palette = paseoTerminalPaletteFor(AppThemeName.dark);
    final theme = toXtermTheme(palette);

    expect(theme.background, palette.background);
    expect(theme.foreground, palette.foreground);
    expect(theme.cursor, palette.cursor);
    expect(theme.cursorAccent, palette.cursorAccent);
    expect(theme.selectionBackground, palette.selectionBackground);
    expect(theme.selectionForeground, palette.selectionForeground);
    expect(theme.black, palette.black);
    expect(theme.red, palette.red);
    expect(theme.green, palette.green);
    expect(theme.yellow, palette.yellow);
    expect(theme.blue, palette.blue);
    expect(theme.magenta, palette.magenta);
    expect(theme.cyan, palette.cyan);
    expect(theme.white, palette.white);
    expect(theme.brightBlack, palette.brightBlack);
    expect(theme.brightRed, palette.brightRed);
    expect(theme.brightGreen, palette.brightGreen);
    expect(theme.brightYellow, palette.brightYellow);
    expect(theme.brightBlue, palette.brightBlue);
    expect(theme.brightMagenta, palette.brightMagenta);
    expect(theme.brightCyan, palette.brightCyan);
    expect(theme.brightWhite, palette.brightWhite);
  });

  test('Flutter xterm adapter maps every supported rendering color', () {
    final source = toXtermTheme(paseoTerminalPaletteFor(AppThemeName.light));
    final theme = toFlutterTerminalTheme(source);

    expect(theme.background, source.background);
    expect(theme.foreground, source.foreground);
    expect(theme.cursor, source.cursor);
    expect(theme.selection, source.selectionBackground);
    expect(theme.black, source.black);
    expect(theme.red, source.red);
    expect(theme.green, source.green);
    expect(theme.yellow, source.yellow);
    expect(theme.blue, source.blue);
    expect(theme.magenta, source.magenta);
    expect(theme.cyan, source.cyan);
    expect(theme.white, source.white);
    expect(theme.brightBlack, source.brightBlack);
    expect(theme.brightRed, source.brightRed);
    expect(theme.brightGreen, source.brightGreen);
    expect(theme.brightYellow, source.brightYellow);
    expect(theme.brightBlue, source.brightBlue);
    expect(theme.brightMagenta, source.brightMagenta);
    expect(theme.brightCyan, source.brightCyan);
    expect(theme.brightWhite, source.brightWhite);
  });
}
