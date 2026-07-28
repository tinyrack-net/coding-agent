import 'package:flutter/services.dart';

import 'shortcut_engine.dart';

final _physicalCodes = <PhysicalKeyboardKey, String>{
  PhysicalKeyboardKey.keyA: 'KeyA',
  PhysicalKeyboardKey.keyB: 'KeyB',
  PhysicalKeyboardKey.keyC: 'KeyC',
  PhysicalKeyboardKey.keyD: 'KeyD',
  PhysicalKeyboardKey.keyE: 'KeyE',
  PhysicalKeyboardKey.keyF: 'KeyF',
  PhysicalKeyboardKey.keyG: 'KeyG',
  PhysicalKeyboardKey.keyH: 'KeyH',
  PhysicalKeyboardKey.keyI: 'KeyI',
  PhysicalKeyboardKey.keyJ: 'KeyJ',
  PhysicalKeyboardKey.keyK: 'KeyK',
  PhysicalKeyboardKey.keyL: 'KeyL',
  PhysicalKeyboardKey.keyM: 'KeyM',
  PhysicalKeyboardKey.keyN: 'KeyN',
  PhysicalKeyboardKey.keyO: 'KeyO',
  PhysicalKeyboardKey.keyP: 'KeyP',
  PhysicalKeyboardKey.keyQ: 'KeyQ',
  PhysicalKeyboardKey.keyR: 'KeyR',
  PhysicalKeyboardKey.keyS: 'KeyS',
  PhysicalKeyboardKey.keyT: 'KeyT',
  PhysicalKeyboardKey.keyU: 'KeyU',
  PhysicalKeyboardKey.keyV: 'KeyV',
  PhysicalKeyboardKey.keyW: 'KeyW',
  PhysicalKeyboardKey.keyX: 'KeyX',
  PhysicalKeyboardKey.keyY: 'KeyY',
  PhysicalKeyboardKey.keyZ: 'KeyZ',
  PhysicalKeyboardKey.digit0: 'Digit0',
  PhysicalKeyboardKey.digit1: 'Digit1',
  PhysicalKeyboardKey.digit2: 'Digit2',
  PhysicalKeyboardKey.digit3: 'Digit3',
  PhysicalKeyboardKey.digit4: 'Digit4',
  PhysicalKeyboardKey.digit5: 'Digit5',
  PhysicalKeyboardKey.digit6: 'Digit6',
  PhysicalKeyboardKey.digit7: 'Digit7',
  PhysicalKeyboardKey.digit8: 'Digit8',
  PhysicalKeyboardKey.digit9: 'Digit9',
  PhysicalKeyboardKey.numpad0: 'Numpad0',
  PhysicalKeyboardKey.numpad1: 'Numpad1',
  PhysicalKeyboardKey.numpad2: 'Numpad2',
  PhysicalKeyboardKey.numpad3: 'Numpad3',
  PhysicalKeyboardKey.numpad4: 'Numpad4',
  PhysicalKeyboardKey.numpad5: 'Numpad5',
  PhysicalKeyboardKey.numpad6: 'Numpad6',
  PhysicalKeyboardKey.numpad7: 'Numpad7',
  PhysicalKeyboardKey.numpad8: 'Numpad8',
  PhysicalKeyboardKey.numpad9: 'Numpad9',
  PhysicalKeyboardKey.minus: 'Minus',
  PhysicalKeyboardKey.equal: 'Equal',
  PhysicalKeyboardKey.backslash: 'Backslash',
  PhysicalKeyboardKey.bracketLeft: 'BracketLeft',
  PhysicalKeyboardKey.bracketRight: 'BracketRight',
  PhysicalKeyboardKey.semicolon: 'Semicolon',
  PhysicalKeyboardKey.quote: 'Quote',
  PhysicalKeyboardKey.comma: 'Comma',
  PhysicalKeyboardKey.period: 'Period',
  PhysicalKeyboardKey.backquote: 'Backquote',
  PhysicalKeyboardKey.slash: 'Slash',
  PhysicalKeyboardKey.space: 'Space',
  PhysicalKeyboardKey.enter: 'Enter',
  PhysicalKeyboardKey.numpadEnter: 'Enter',
  PhysicalKeyboardKey.backspace: 'Backspace',
  PhysicalKeyboardKey.escape: 'Escape',
  PhysicalKeyboardKey.arrowLeft: 'ArrowLeft',
  PhysicalKeyboardKey.arrowRight: 'ArrowRight',
  PhysicalKeyboardKey.arrowUp: 'ArrowUp',
  PhysicalKeyboardKey.arrowDown: 'ArrowDown',
  PhysicalKeyboardKey.tab: 'Tab',
  PhysicalKeyboardKey.delete: 'Delete',
  PhysicalKeyboardKey.home: 'Home',
  PhysicalKeyboardKey.end: 'End',
  PhysicalKeyboardKey.pageUp: 'PageUp',
  PhysicalKeyboardKey.pageDown: 'PageDown',
  PhysicalKeyboardKey.insert: 'Insert',
  PhysicalKeyboardKey.f1: 'F1',
  PhysicalKeyboardKey.f2: 'F2',
  PhysicalKeyboardKey.f3: 'F3',
  PhysicalKeyboardKey.f4: 'F4',
  PhysicalKeyboardKey.f5: 'F5',
  PhysicalKeyboardKey.f6: 'F6',
  PhysicalKeyboardKey.f7: 'F7',
  PhysicalKeyboardKey.f8: 'F8',
  PhysicalKeyboardKey.f9: 'F9',
  PhysicalKeyboardKey.f10: 'F10',
  PhysicalKeyboardKey.f11: 'F11',
  PhysicalKeyboardKey.f12: 'F12',
};

const _shiftedKeys = <String, String>{
  'Digit1': '!',
  'Digit2': '@',
  'Digit3': '#',
  'Digit4': r'$',
  'Digit5': '%',
  'Digit6': '^',
  'Digit7': '&',
  'Digit8': '*',
  'Digit9': '(',
  'Digit0': ')',
  'Minus': '_',
  'Equal': '+',
  'Backslash': '|',
  'BracketLeft': '{',
  'BracketRight': '}',
  'Semicolon': ':',
  'Quote': '"',
  'Comma': '<',
  'Period': '>',
  'Backquote': '~',
  'Slash': '?',
};

final _modifierPhysicalKeys = <PhysicalKeyboardKey>{
  PhysicalKeyboardKey.controlLeft,
  PhysicalKeyboardKey.controlRight,
  PhysicalKeyboardKey.altLeft,
  PhysicalKeyboardKey.altRight,
  PhysicalKeyboardKey.shiftLeft,
  PhysicalKeyboardKey.shiftRight,
  PhysicalKeyboardKey.metaLeft,
  PhysicalKeyboardKey.metaRight,
};

String? heldShortcutModifiers({HardwareKeyboard? keyboard}) {
  final state = keyboard ?? HardwareKeyboard.instance;
  final parts = <String>[
    if (state.isControlPressed) 'Ctrl',
    if (state.isAltPressed) 'Alt',
    if (state.isShiftPressed) 'Shift',
    if (state.isMetaPressed) 'Cmd',
  ];
  return parts.isEmpty ? null : parts.join('+');
}

String? shortcutComboStringFromKeyEvent(
  KeyEvent event, {
  HardwareKeyboard? keyboard,
}) {
  if (_modifierPhysicalKeys.contains(event.physicalKey)) return null;
  final code = _physicalCodes[event.physicalKey];
  if (code == null) return null;
  final state = keyboard ?? HardwareKeyboard.instance;
  final humanKey = switch (code) {
    final value when value.startsWith('Key') => value.substring(3),
    final value when value.startsWith('Digit') => value.substring(5),
    'Minus' => '-',
    'Equal' => '=',
    'Backslash' => r'\',
    'BracketLeft' => '[',
    'BracketRight' => ']',
    'Semicolon' => ';',
    'Quote' => "'",
    'Comma' => ',',
    'Period' => '.',
    'Backquote' => '`',
    'Slash' => '/',
    'Space' => 'Space',
    _ => code,
  };
  return [
    if (state.isControlPressed) 'Ctrl',
    if (state.isAltPressed) 'Alt',
    if (state.isShiftPressed) 'Shift',
    if (state.isMetaPressed) 'Cmd',
    humanKey,
  ].join('+');
}

KeyboardShortcutInput? shortcutInputFromKeyEvent(
  KeyEvent event, {
  HardwareKeyboard? keyboard,
}) {
  final code = _physicalCodes[event.physicalKey];
  if (code == null) return null;
  final state = keyboard ?? HardwareKeyboard.instance;
  return KeyboardShortcutInput(
    key:
        (state.isShiftPressed && !state.isAltPressed
            ? _shiftedKeys[code]
            : null) ??
        event.character ??
        event.logicalKey.keyLabel,
    code: code,
    altKey: state.isAltPressed,
    ctrlKey: state.isControlPressed,
    metaKey: state.isMetaPressed,
    shiftKey: state.isShiftPressed,
    repeat: event is KeyRepeatEvent,
  );
}
