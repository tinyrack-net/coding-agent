import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

const _kitty = TerminalKeyInputEncodingOptions(
  inputMode: TerminalInputModeState(
    kittyKeyboardFlags: 7,
    win32InputMode: false,
  ),
);
const _win32 = TerminalKeyInputEncodingOptions(
  inputMode: TerminalInputModeState(
    kittyKeyboardFlags: 0,
    win32InputMode: true,
  ),
);
const _both = TerminalKeyInputEncodingOptions(
  inputMode: TerminalInputModeState(
    kittyKeyboardFlags: 7,
    win32InputMode: true,
  ),
);

void main() {
  group('encodeTerminalKeyInput', () {
    test('encodes ctrl+b for tmux prefix', () {
      expect(
        encodeTerminalKeyInput(const TerminalKeyInput(key: 'b', ctrl: true)),
        '\x02',
      );
    });

    test('encodes shifted arrows and alt printable keys', () {
      expect(
        encodeTerminalKeyInput(
          const TerminalKeyInput(key: 'ArrowLeft', shift: true),
        ),
        '\x1b[1;2D',
      );
      expect(
        encodeTerminalKeyInput(const TerminalKeyInput(key: 'x', alt: true)),
        '\x1bx',
      );
    });

    test('encodes enter, backspace, tab, and escape', () {
      expect(
        encodeTerminalKeyInput(const TerminalKeyInput(key: 'Enter')),
        '\r',
      );
      expect(
        encodeTerminalKeyInput(const TerminalKeyInput(key: 'Backspace')),
        '\x7f',
      );
      expect(
        encodeTerminalKeyInput(const TerminalKeyInput(key: 'Tab', shift: true)),
        '\x1b[Z',
      );
      expect(
        encodeTerminalKeyInput(const TerminalKeyInput(key: 'Escape')),
        '\x1b',
      );
    });

    test('keeps modified Enter plain before enhanced mode is active', () {
      expect(
        encodeTerminalKeyInput(
          const TerminalKeyInput(key: 'Enter', shift: true),
        ),
        '\r',
      );
    });

    test('encodes modified Enter with CSI u in Kitty mode', () {
      expect(
        encodeTerminalKeyInput(
          const TerminalKeyInput(key: 'Enter', shift: true),
          _kitty,
        ),
        '\x1b[13;2u',
      );
      expect(
        encodeTerminalKeyInput(
          const TerminalKeyInput(key: 'Enter', ctrl: true),
          _kitty,
        ),
        '\x1b[13;5u',
      );
      expect(
        encodeTerminalKeyInput(
          const TerminalKeyInput(key: 'Enter', alt: true),
          _kitty,
        ),
        '\x1b[13;3u',
      );
      expect(
        encodeTerminalKeyInput(
          const TerminalKeyInput(key: 'Enter', meta: true),
          _kitty,
        ),
        '\x1b[13;9u',
      );
      expect(
        encodeTerminalKeyInput(
          const TerminalKeyInput(key: 'Enter', shift: true, ctrl: true),
          _kitty,
        ),
        '\x1b[13;6u',
      );
    });

    test('uses and prefers Win32 mode for modified Enter', () {
      for (final options in [_win32, _both]) {
        expect(
          encodeTerminalKeyInput(
            const TerminalKeyInput(key: 'Enter', shift: true),
            options,
          ),
          '\x1b[13;28;13;1;16;1_',
        );
      }
    });

    test('covers navigation and function key encodings', () {
      expect(
        encodeTerminalKeyInput(const TerminalKeyInput(key: 'Home')),
        '\x1b[H',
      );
      expect(
        encodeTerminalKeyInput(const TerminalKeyInput(key: 'Delete')),
        '\x1b[3~',
      );
      expect(
        encodeTerminalKeyInput(const TerminalKeyInput(key: 'F1')),
        '\x1bOP',
      );
      expect(
        encodeTerminalKeyInput(const TerminalKeyInput(key: 'F12', ctrl: true)),
        '\x1b[24;5~',
      );
    });

    test('returns empty string for empty and unsupported keys', () {
      expect(encodeTerminalKeyInput(const TerminalKeyInput(key: '')), '');
      expect(
        encodeTerminalKeyInput(const TerminalKeyInput(key: 'UnidentifiedKey')),
        '',
      );
    });
  });
}
