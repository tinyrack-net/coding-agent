import 'package:coding_agent_app/keyboard/shortcut_engine.dart';
import 'package:flutter_test/flutter_test.dart';

KeyboardShortcutInput key(
  String key,
  String code, {
  bool alt = false,
  bool ctrl = false,
  bool meta = false,
  bool shift = false,
  bool repeat = false,
}) => KeyboardShortcutInput(
  key: key,
  code: code,
  altKey: alt,
  ctrlKey: ctrl,
  metaKey: meta,
  shiftKey: shift,
  repeat: repeat,
);

const windowsOther = KeyboardShortcutContext(
  isMac: false,
  isDesktop: true,
  focusScope: KeyboardFocusScope.other,
  commandCenterOpen: false,
);

KeyboardShortcutResolution resolve(
  KeyboardShortcutInput event, {
  KeyboardShortcutContext context = windowsOther,
  ShortcutChordState state = ShortcutChordState.empty,
  List<ShortcutBinding>? bindings,
  void Function()? reset,
}) => resolveKeyboardShortcut(
  event: event,
  context: context,
  chordState: state,
  onChordReset: reset ?? () {},
  bindings: bindings,
);

void main() {
  group('shortcut strings', () {
    test('parses, serializes, and round-trips supported keys', () {
      final combo = parseShortcutString('Mod+Ctrl+Alt+Shift+Cmd+K');
      expect(combo.code, 'KeyK');
      expect(combo.key, 'k');
      expect(combo.mod, isTrue);
      expect(combo.ctrl, isTrue);
      expect(combo.alt, isTrue);
      expect(combo.shift, isTrue);
      expect(combo.meta, isTrue);
      expect(shortcutKeyComboToString(combo), 'Mod+Ctrl+Alt+Shift+Cmd+K');
      expect(
        shortcutChordToString(parseChordString('Ctrl+K Ctrl+C')),
        'Ctrl+K Ctrl+C',
      );
      expect(parseShortcutString('Shift+?').shiftedKey, isNull);
      expect(parseShortcutString(r'Cmd+\').code, 'Backslash');
      expect(parseShortcutString('F12').code, 'F12');
    });

    test('rejects malformed, unknown, missing, and multiple keys', () {
      expect(() => parseShortcutString(''), throwsFormatException);
      expect(() => parseShortcutString('Ctrl+'), throwsFormatException);
      expect(() => parseShortcutString('Ctrl+K+L'), throwsFormatException);
      expect(() => parseShortcutString('Ctrl+Shift'), throwsFormatException);
      expect(() => parseShortcutString('Hyper+K'), throwsFormatException);
    });
  });

  group('context matching', () {
    test('matches platform, desktop, focus, terminal, and command center', () {
      expect(matchesKeyboardShortcutContext(null, windowsOther), isTrue);
      expect(
        matchesKeyboardShortcutContext(
          const ShortcutWhen(mac: true),
          windowsOther,
        ),
        isFalse,
      );
      expect(
        matchesKeyboardShortcutContext(
          const ShortcutWhen(desktop: false),
          windowsOther,
        ),
        isFalse,
      );
      expect(
        matchesKeyboardShortcutContext(
          const ShortcutWhen(allowEditable: false),
          const KeyboardShortcutContext(
            isMac: false,
            isDesktop: true,
            focusScope: KeyboardFocusScope.editable,
            commandCenterOpen: false,
          ),
        ),
        isFalse,
      );
      expect(
        matchesKeyboardShortcutContext(
          const ShortcutWhen(allowEditable: false),
          const KeyboardShortcutContext(
            isMac: false,
            isDesktop: true,
            focusScope: KeyboardFocusScope.messageInput,
            commandCenterOpen: false,
          ),
        ),
        isFalse,
      );
      expect(
        matchesKeyboardShortcutContext(
          const ShortcutWhen(allowTerminal: false),
          const KeyboardShortcutContext(
            isMac: false,
            isDesktop: true,
            focusScope: KeyboardFocusScope.terminal,
            commandCenterOpen: false,
          ),
        ),
        isFalse,
      );
      expect(
        matchesKeyboardShortcutContext(
          const ShortcutWhen(allowCommandCenter: false),
          const KeyboardShortcutContext(
            isMac: false,
            isDesktop: true,
            focusScope: KeyboardFocusScope.other,
            commandCenterOpen: true,
          ),
        ),
        isFalse,
      );
      expect(
        matchesKeyboardShortcutContext(
          const ShortcutWhen(focusScope: KeyboardFocusScope.other),
          const KeyboardShortcutContext(
            isMac: false,
            isDesktop: true,
            focusScope: KeyboardFocusScope.editable,
            commandCenterOpen: false,
          ),
        ),
        isFalse,
      );
    });
  });

  group('matching', () {
    test('resolves mod per platform and preserves logical character', () {
      final windows = resolve(key('k', 'KeyK', ctrl: true));
      expect(windows.match?.action, 'command-center.toggle');
      expect(windows.match?.preventDefault, isTrue);

      final mac = resolve(
        key('k', 'KeyK', meta: true),
        context: const KeyboardShortcutContext(
          isMac: true,
          isDesktop: true,
          focusScope: KeyboardFocusScope.other,
          commandCenterOpen: false,
        ),
      );
      expect(mac.match?.action, 'command-center.toggle');

      // Dvorak-style physical mismatch stays key-first without Alt.
      expect(resolve(key('v', 'Period', ctrl: true)).match, isNull);
    });

    test('matches shifted symbols, option-altered keys and code fallback', () {
      expect(
        resolve(key('?', 'Slash', shift: true)).match?.action,
        'shortcuts.dialog.toggle',
      );
      final optionBinding = ShortcutBinding(
        id: 'option',
        action: 'option',
        combo: 'Alt+T',
      );
      expect(
        resolve(
          key('†', 'KeyT', alt: true),
          bindings: [optionBinding],
        ).match?.action,
        'option',
      );
      final enterBinding = ShortcutBinding(
        id: 'enter',
        action: 'enter',
        combo: 'Enter',
      );
      expect(
        resolve(
          key('Unidentified', 'Enter'),
          bindings: [enterBinding],
        ).match?.action,
        'enter',
      );
    });

    test('resolves digit and numpad payloads and rejects zero', () {
      final digit = resolve(key('3', 'Digit3', ctrl: true));
      expect(digit.match?.action, 'workspace.navigate.index');
      expect((digit.match?.payload as ShortcutIndexPayload).index, 3);

      final numpad = resolve(key('3', 'Numpad3', ctrl: true));
      expect((numpad.match?.payload as ShortcutIndexPayload).index, 3);
      expect(resolve(key('0', 'Digit0', ctrl: true)).match, isNull);
    });

    test('resolves delta and message-input payloads', () {
      final previous = resolve(key('[', 'BracketLeft', ctrl: true));
      expect((previous.match?.payload as ShortcutDeltaPayload).delta, -1);
      final message = resolve(key('l', 'KeyL', ctrl: true));
      expect(
        (message.match?.payload as ShortcutMessageInputPayload).kind,
        'focus',
      );
    });

    test('honors repeat and prevent/propagation flags', () {
      expect(
        resolve(key('?', 'Slash', shift: true, repeat: true)).match,
        isNull,
      );
      final escape = resolve(key('Escape', 'Escape'));
      expect(escape.match?.action, 'agent.interrupt');
      expect(escape.match?.preventDefault, isFalse);
      expect(escape.match?.stopPropagation, isFalse);
    });
  });

  group('chords and overrides', () {
    test('advances, completes, and resets a chord', () {
      final bindings = [
        ShortcutBinding(
          id: 'comment',
          action: 'comment',
          combo: 'Ctrl+K Ctrl+C',
        ),
        ShortcutBinding(
          id: 'uncomment',
          action: 'uncomment',
          combo: 'Ctrl+K Ctrl+U',
        ),
      ];
      final first = resolve(key('k', 'KeyK', ctrl: true), bindings: bindings);
      expect(first.match, isNull);
      expect(first.preventDefault, isTrue);
      expect(first.nextChordState.step, 1);
      expect(first.nextChordState.candidateIndices, [0, 1]);
      expect(first.nextChordState.timeout, isNotNull);

      final completed = resolve(
        key('c', 'KeyC', ctrl: true),
        state: first.nextChordState,
        bindings: bindings,
      );
      expect(completed.match?.action, 'comment');
      expect(completed.nextChordState.step, 0);
      expect(first.nextChordState.timeout!.isActive, isFalse);
    });

    test('supports three-step chords and clears on mismatch', () {
      final bindings = [
        ShortcutBinding(
          id: 'three',
          action: 'three',
          combo: 'Ctrl+K Ctrl+C Ctrl+D',
        ),
      ];
      final first = resolve(key('k', 'KeyK', ctrl: true), bindings: bindings);
      final second = resolve(
        key('c', 'KeyC', ctrl: true),
        state: first.nextChordState,
        bindings: bindings,
      );
      expect(second.nextChordState.step, 2);
      final mismatch = resolve(
        key('x', 'KeyX', ctrl: true),
        state: second.nextChordState,
        bindings: bindings,
      );
      expect(mismatch.match, isNull);
      expect(mismatch.nextChordState.step, 0);
    });

    test('chord precedence suppresses an overlapping single combo', () {
      final bindings = [
        ShortcutBinding(id: 'single', action: 'single', combo: 'Ctrl+K'),
        ShortcutBinding(id: 'chord', action: 'chord', combo: 'Ctrl+K Ctrl+C'),
      ];
      final result = resolve(key('k', 'KeyK', ctrl: true), bindings: bindings);
      expect(result.match, isNull);
      expect(result.nextChordState.candidateIndices, [1]);
      result.nextChordState.timeout?.cancel();
    });

    test('applies valid overrides and falls back from invalid ones', () {
      final defaults = [
        ShortcutBinding(id: 'one', action: 'one', combo: 'Ctrl+K'),
        ShortcutBinding(
          id: 'two',
          action: 'two',
          combo: 'Ctrl+L',
          allowRepeat: false,
        ),
      ];
      final effective = buildEffectiveShortcutBindings({
        'one': 'Ctrl+J',
        'two': 'not-valid',
      }, bindings: defaults);
      expect(effective[0].combo, 'Ctrl+J');
      expect(effective[1], same(defaults[1]));
      expect(
        resolve(
          key('j', 'KeyJ', ctrl: true),
          bindings: effective,
        ).match?.action,
        'one',
      );
    });
  });

  test('default catalog contains the frozen Paseo binding identities', () {
    expect(defaultShortcutBindings, hasLength(66));
    expect(
      defaultShortcutBindings.map((binding) => binding.id).toSet(),
      hasLength(defaultShortcutBindings.length),
    );
    expect(
      defaultShortcutBindings.where(
        (binding) => binding.helpId == 'toggle-command-center',
      ),
      hasLength(2),
    );
  });
}
