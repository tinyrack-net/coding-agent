import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/state/workspace_terminal_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TerminalState state(String text) => TerminalState(
    rows: 1,
    cols: 1,
    grid: [
      [TerminalCell(char: text)],
    ],
    scrollback: const [],
    cursor: const TerminalCursor(row: 0, col: 0),
  );

  test('returns the same session for one scope and isolates other scopes', () {
    final first = getWorkspaceTerminalSession('same');
    final second = getWorkspaceTerminalSession('same');
    final other = getWorkspaceTerminalSession('other');

    expect(second, same(first));
    expect(other, isNot(same(first)));

    releaseWorkspaceTerminalSession('same');
    releaseWorkspaceTerminalSession('other');
  });

  test('preserves, clears, and prunes snapshots across lookups', () {
    final first = getWorkspaceTerminalSession('snapshots');
    first.snapshots
      ..set('term-1', state('A'))
      ..set('term-2', state('B'))
      ..set('term-3', state('C'));

    final second = getWorkspaceTerminalSession('snapshots');
    expect(second.snapshots.get('term-1')?.grid.single.single.char, 'A');
    second.snapshots
      ..clear('term-2')
      ..prune(const ['term-1']);
    expect(second.snapshots.get('term-2'), isNull);
    expect(second.snapshots.get('term-3'), isNull);
    expect(second.snapshots.get('term-1'), isNotNull);

    releaseWorkspaceTerminalSession('snapshots');
  });

  test('evicts state only when the retain count returns to zero', () {
    const scopeKey = 'retained';
    final first = getWorkspaceTerminalSession(scopeKey);
    first.snapshots.set('term-1', state('A'));

    retainWorkspaceTerminalSession(scopeKey);
    retainWorkspaceTerminalSession(scopeKey);
    releaseWorkspaceTerminalSession(scopeKey);
    expect(getWorkspaceTerminalSession(scopeKey), same(first));

    releaseWorkspaceTerminalSession(scopeKey);
    final second = getWorkspaceTerminalSession(scopeKey);
    expect(second, isNot(same(first)));
    expect(second.snapshots.get('term-1'), isNull);

    releaseWorkspaceTerminalSession(scopeKey);
  });
}
