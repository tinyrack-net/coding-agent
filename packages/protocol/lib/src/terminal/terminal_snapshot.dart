/// Renders a structured Paseo terminal snapshot into an ANSI replay stream.
library;

import '../messages/terminal_state.dart';

String renderTerminalSnapshotToAnsi(TerminalState state) {
  final rows = [...state.scrollback, ...state.grid];
  final wrapFlags = [...?state.scrollbackWrapped, ...?state.gridWrapped];
  final hasWrapInfo = wrapFlags.length == rows.length;
  final output = StringBuffer();
  if (!hasWrapInfo) output.write('\x1b[?7l');

  for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
    final continues =
        hasWrapInfo && wrapFlags.elementAtOrNull(rowIndex) == true;
    output.write(
      _renderRow(rows[rowIndex], padToCols: continues ? state.cols : null),
    );
    if (rowIndex < rows.length - 1 && !continues) output.write('\r\n');
  }

  output.write('\x1b[0m');
  final cursor = state.cursor;
  if (cursor.style != null) {
    final code = switch (cursor.style!) {
      TerminalCursorStyle.block => cursor.blink == false ? 2 : 1,
      TerminalCursorStyle.underline => cursor.blink == false ? 4 : 3,
      TerminalCursorStyle.bar => cursor.blink == false ? 6 : 5,
    };
    output.write('\x1b[$code q');
  }
  output.write('\x1b[${cursor.row + 1};${cursor.col + 1}H');
  output.write(cursor.hidden == true ? '\x1b[?25l' : '\x1b[?25h');
  if (!hasWrapInfo) output.write('\x1b[?7h');
  return output.toString();
}

String _renderRow(List<TerminalCell> row, {int? padToCols}) {
  final contentLength = _rowLength(row);
  final length = padToCols == null
      ? contentLength
      : contentLength > padToCols
      ? contentLength
      : padToCols;
  final output = StringBuffer();
  var previous = const _Style();
  for (var index = 0; index < length; index++) {
    final cell = index < row.length
        ? row[index]
        : const TerminalCell(char: ' ');
    final next = _Style.fromCell(cell);
    if (next != previous) {
      output.write(_styleToAnsi(next));
      previous = next;
    }
    output.write(cell.char.isEmpty ? ' ' : cell.char);
  }
  if (previous != const _Style()) output.write('\x1b[0m');
  return output.toString();
}

int _rowLength(List<TerminalCell> row) {
  for (var index = row.length - 1; index >= 0; index--) {
    final cell = row[index];
    if (cell.char != ' ' ||
        cell.fg != null ||
        cell.bg != null ||
        cell.fgMode != null ||
        cell.bgMode != null ||
        cell.bold ||
        cell.italic ||
        cell.underline ||
        cell.dim ||
        cell.inverse ||
        cell.strikethrough) {
      return index + 1;
    }
  }
  return 0;
}

final class _Style {
  const _Style({
    this.fg,
    this.bg,
    this.fgMode,
    this.bgMode,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.dim = false,
    this.inverse = false,
    this.strikethrough = false,
  });

  factory _Style.fromCell(TerminalCell cell) => _Style(
    fg: cell.fg,
    bg: cell.bg,
    fgMode: cell.fgMode,
    bgMode: cell.bgMode,
    bold: cell.bold,
    italic: cell.italic,
    underline: cell.underline,
    dim: cell.dim,
    inverse: cell.inverse,
    strikethrough: cell.strikethrough,
  );

  final int? fg;
  final int? bg;
  final int? fgMode;
  final int? bgMode;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool dim;
  final bool inverse;
  final bool strikethrough;

  @override
  bool operator ==(Object other) =>
      other is _Style &&
      fg == other.fg &&
      bg == other.bg &&
      fgMode == other.fgMode &&
      bgMode == other.bgMode &&
      bold == other.bold &&
      italic == other.italic &&
      underline == other.underline &&
      dim == other.dim &&
      inverse == other.inverse &&
      strikethrough == other.strikethrough;

  @override
  int get hashCode => Object.hash(
    fg,
    bg,
    fgMode,
    bgMode,
    bold,
    italic,
    underline,
    dim,
    inverse,
    strikethrough,
  );
}

String _styleToAnsi(_Style style) {
  final codes = <String>['0'];
  if (style.bold) codes.add('1');
  if (style.dim) codes.add('2');
  if (style.italic) codes.add('3');
  if (style.underline) codes.add('4');
  if (style.inverse) codes.add('7');
  if (style.strikethrough) codes.add('9');
  if (style.fg != null && style.fgMode != null) {
    codes.addAll(_colorToSgr(style.fgMode!, style.fg!, false));
  }
  if (style.bg != null && style.bgMode != null) {
    codes.addAll(_colorToSgr(style.bgMode!, style.bg!, true));
  }
  return '\x1b[${codes.join(';')}m';
}

List<String> _colorToSgr(int mode, int value, bool background) =>
    switch (mode) {
      1 when value >= 8 => ['${(background ? 100 : 90) + value - 8}'],
      1 => ['${(background ? 40 : 30) + value}'],
      2 => [background ? '48' : '38', '5', '$value'],
      3 => [
        background ? '48' : '38',
        '2',
        '${(value >> 16) & 0xff}',
        '${(value >> 8) & 0xff}',
        '${value & 0xff}',
      ],
      _ => const [],
    };

extension on List<bool> {
  bool? elementAtOrNull(int index) =>
      index < 0 || index >= length ? null : this[index];
}
