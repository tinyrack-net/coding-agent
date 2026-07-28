import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('terminal state round-trips cells, cursor, title, and wrap flags', () {
    final state = TerminalState(
      rows: 1,
      cols: 2,
      grid: const [
        [
          TerminalCell(char: 'A', fg: 1, fgMode: 1, bold: true),
          TerminalCell(char: ' '),
        ],
      ],
      scrollback: const [
        [
          TerminalCell(char: 'B', bg: 0x112233, bgMode: 3),
          TerminalCell(char: ' '),
        ],
      ],
      cursor: const TerminalCursor(
        row: 0,
        col: 1,
        hidden: true,
        style: TerminalCursorStyle.bar,
        blink: false,
      ),
      title: 'Build',
      gridWrapped: const [false],
      scrollbackWrapped: const [true],
    );

    final decoded = TerminalState.fromJson(state.toJson());
    expect(decoded.toJson(), state.toJson());
  });

  test('restore requests accept only frozen kebab-case modes', () {
    for (final mode in const ['live', 'visible-snapshot', 'full-snapshot']) {
      final request = SubscribeTerminalRequest.fromJson({
        'type': 'subscribe_terminal_request',
        'terminalId': 'term',
        'requestId': 'req',
        'restore': {
          'mode': mode,
          'scrollbackLines': 25,
          'size': {'rows': 40, 'cols': 120},
        },
      });
      expect(request.restore!.mode.wire, mode);
      expect(request.restore!.size, (rows: 40, cols: 120));
    }
    expect(
      () => SubscribeTerminalRequest.fromJson({
        'type': 'subscribe_terminal_request',
        'terminalId': 'term',
        'requestId': 'req',
        'restore': {'mode': 'visibleSnapshot'},
      }),
      throwsFormatException,
    );
  });

  test('directory subscriptions preserve independent workspace identity', () {
    final subscribe = SubscribeTerminalsRequest.fromJson({
      'type': 'subscribe_terminals_request',
      'cwd': '/repo',
      'workspaceId': 'ws-a',
    });
    final unsubscribe = UnsubscribeTerminalsRequest.fromJson({
      'type': 'unsubscribe_terminals_request',
      'cwd': '/repo',
      'workspaceId': 'ws-b',
    });
    expect(subscribe.toJson()['workspaceId'], 'ws-a');
    expect(unsubscribe.toJson()['workspaceId'], 'ws-b');
  });

  test('terminal unsubscribe and stream exit preserve frozen wire shapes', () {
    final unsubscribe = UnsubscribeTerminalRequest.fromJson({
      'type': UnsubscribeTerminalRequest.type,
      'terminalId': 'term-1',
    });
    final exit = TerminalStreamExit.fromJson({
      'type': TerminalStreamExit.type,
      'payload': {'terminalId': 'term-1'},
    });

    expect(unsubscribe.toJson(), {
      'type': 'unsubscribe_terminal_request',
      'terminalId': 'term-1',
    });
    expect(exit.toJson(), {
      'type': 'terminal_stream_exit',
      'payload': {'terminalId': 'term-1'},
    });
    expect(
      () => TerminalStreamExit.fromJson({
        'type': TerminalStreamExit.type,
        'payload': 'bad',
      }),
      throwsFormatException,
    );
  });

  test('terminal state rejects malformed schema boundaries', () {
    expect(
      () => TerminalState.fromJson({
        'rows': 1,
        'cols': 1,
        'grid': [
          ['not-a-cell'],
        ],
        'scrollback': const [],
        'cursor': {'row': 0, 'col': 0},
      }),
      throwsFormatException,
    );
    expect(
      () => TerminalRestoreOptions.fromJson({
        'mode': 'live',
        'scrollbackLines': -1,
      }),
      throwsFormatException,
    );
  });
}
