import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('renders styled snapshot, cursor presentation, and visibility', () {
    final ansi = renderTerminalSnapshotToAnsi(
      const TerminalState(
        rows: 1,
        cols: 2,
        grid: [
          [
            TerminalCell(char: 'A', fg: 1, fgMode: 1, bold: true),
            TerminalCell(char: ' '),
          ],
        ],
        scrollback: [],
        cursor: TerminalCursor(
          row: 0,
          col: 1,
          hidden: true,
          style: TerminalCursorStyle.underline,
          blink: false,
        ),
      ),
    );
    expect(ansi, contains('\x1b[0;1;31mA'));
    expect(ansi, contains('\x1b[4 q'));
    expect(ansi, endsWith('\x1b[?7h'));
    expect(ansi, contains('\x1b[1;2H\x1b[?25l'));
  });

  test('wrap metadata replays logical rows without hard newline', () {
    final ansi = renderTerminalSnapshotToAnsi(
      const TerminalState(
        rows: 1,
        cols: 2,
        grid: [
          [TerminalCell(char: 'C'), TerminalCell(char: 'D')],
        ],
        scrollback: [
          [TerminalCell(char: 'A'), TerminalCell(char: 'B')],
        ],
        cursor: TerminalCursor(row: 0, col: 0),
        scrollbackWrapped: [true],
        gridWrapped: [false],
      ),
    );
    expect(ansi, startsWith('ABCD'));
    expect(ansi, isNot(contains('\x1b[?7l')));
  });
}
