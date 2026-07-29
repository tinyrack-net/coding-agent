import 'package:fluent_ui/fluent_ui.dart';
import 'package:xterm/xterm.dart';

import '../core/theme.dart';

/// The full xterm.js theme shape used by frozen Paseo.
final class PaseoXtermTheme {
  const PaseoXtermTheme({
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
}

PaseoXtermTheme toXtermTheme(PaseoTerminalPalette terminal) => PaseoXtermTheme(
  background: terminal.background,
  foreground: terminal.foreground,
  cursor: terminal.cursor,
  cursorAccent: terminal.cursorAccent,
  selectionBackground: terminal.selectionBackground,
  selectionForeground: terminal.selectionForeground,
  black: terminal.black,
  red: terminal.red,
  green: terminal.green,
  yellow: terminal.yellow,
  blue: terminal.blue,
  magenta: terminal.magenta,
  cyan: terminal.cyan,
  white: terminal.white,
  brightBlack: terminal.brightBlack,
  brightRed: terminal.brightRed,
  brightGreen: terminal.brightGreen,
  brightYellow: terminal.brightYellow,
  brightBlue: terminal.brightBlue,
  brightMagenta: terminal.brightMagenta,
  brightCyan: terminal.brightCyan,
  brightWhite: terminal.brightWhite,
);

/// Adapts the frozen xterm.js theme to Flutter xterm 4's public color surface.
///
/// Flutter xterm does not expose cursor-accent or selection-foreground. They
/// remain present in [PaseoXtermTheme] so a future renderer adapter can apply
/// them without losing the frozen contract.
TerminalTheme toFlutterTerminalTheme(PaseoXtermTheme theme) => TerminalTheme(
  cursor: theme.cursor,
  selection: theme.selectionBackground,
  foreground: theme.foreground,
  background: theme.background,
  black: theme.black,
  red: theme.red,
  green: theme.green,
  yellow: theme.yellow,
  blue: theme.blue,
  magenta: theme.magenta,
  cyan: theme.cyan,
  white: theme.white,
  brightBlack: theme.brightBlack,
  brightRed: theme.brightRed,
  brightGreen: theme.brightGreen,
  brightYellow: theme.brightYellow,
  brightBlue: theme.brightBlue,
  brightMagenta: theme.brightMagenta,
  brightCyan: theme.brightCyan,
  brightWhite: theme.brightWhite,
  searchHitBackground: theme.brightYellow,
  searchHitBackgroundCurrent: theme.brightGreen,
  searchHitForeground: theme.black,
);
