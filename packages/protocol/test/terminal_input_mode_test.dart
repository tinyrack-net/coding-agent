import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('TerminalInputModeTracker', () {
    test('activates pushed Kitty mode and builds a replay preamble', () {
      final tracker = TerminalInputModeTracker();

      expect(tracker.feed('\x1b[>7u').changed, isTrue);
      expect(tracker.supportsModifiedEnter(), isTrue);
      expect(tracker.getKittyKeyboardFlags(), 7);
      expect(tracker.getPreamble(), '\x1b[=7;1u');
    });

    test('tracks split terminal output chunks', () {
      final tracker = TerminalInputModeTracker()..feed('\x1b[>');

      expect(tracker.feed('1u').changed, isTrue);
      expect(tracker.getKittyKeyboardFlags(), 1);
    });

    test('restores pushed Kitty modes when the program pops them', () {
      final tracker = TerminalInputModeTracker()
        ..feed('\x1b[>1u')
        ..feed('\x1b[>7u');

      expect(tracker.feed('\x1b[<u').changed, isTrue);
      expect(tracker.getKittyKeyboardFlags(), 1);
      expect(tracker.feed('\x1b[<u').changed, isTrue);
      expect(tracker.supportsModifiedEnter(), isFalse);
    });

    test('answers Kitty mode queries with the current flags', () {
      final tracker = TerminalInputModeTracker()..feed('\x1b[=3;1u');

      expect(tracker.feed('\x1b[?u').responses, ['\x1b[?3u']);
    });

    test('tracks ConPTY Win32 mode and replays it after snapshots', () {
      final tracker = TerminalInputModeTracker();

      expect(tracker.feed('\x1b[?9001h').changed, isTrue);
      expect(tracker.getState().kittyKeyboardFlags, 0);
      expect(tracker.getState().win32InputMode, isTrue);
      expect(tracker.supportsModifiedEnter(), isTrue);
      expect(tracker.getPreamble(), '\x1b[?9001h');
      expect(tracker.feed('\x1b[?9001l').changed, isTrue);
      expect(tracker.supportsModifiedEnter(), isFalse);
    });

    test('keeps Kitty and Win32 modes independent', () {
      final tracker = TerminalInputModeTracker()..feed('\x1b[>7u\x1b[?9001h');

      expect(tracker.getState().kittyKeyboardFlags, 7);
      expect(tracker.getState().win32InputMode, isTrue);
      expect(tracker.getPreamble(), '\x1b[=7;1u\x1b[?9001h');
    });

    test('ignores encoded key input sequences', () {
      final tracker = TerminalInputModeTracker()..feed('\x1b[13;2u');

      expect(tracker.supportsModifiedEnter(), isFalse);
    });

    test(
      'set, multi-pop, private lists, empty feeds, and reset match upstream',
      () {
        final tracker = TerminalInputModeTracker();
        expect(tracker.feed('').changed, isFalse);
        tracker
          ..feed('\x1b[>1u')
          ..feed('\x1b[>2u')
          ..feed('\x1b[>3u');
        expect(tracker.feed('\x1b[<2u').changed, isTrue);
        expect(tracker.getKittyKeyboardFlags(), 1);

        expect(tracker.feed('\x1b[=7;0u').changed, isTrue);
        expect(tracker.getKittyKeyboardFlags(), 0);
        expect(tracker.feed('\x1b[?25;9001h').changed, isTrue);
        expect(tracker.feed('\x1b[?25l').changed, isFalse);

        tracker.reset();
        expect(
          terminalInputModeStatesEqual(
            tracker.getState(),
            defaultTerminalInputModeState,
          ),
          isTrue,
        );
        expect(
          terminalInputModeSupportsModifiedEnter(tracker.getState()),
          isFalse,
        );
      },
    );
  });
}
