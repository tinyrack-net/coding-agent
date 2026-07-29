import 'package:flutter/services.dart';

import 'terminal_keys.dart';

bool isTerminalModifierLogicalKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.controlLeft ||
    key == LogicalKeyboardKey.controlRight ||
    key == LogicalKeyboardKey.shiftLeft ||
    key == LogicalKeyboardKey.shiftRight ||
    key == LogicalKeyboardKey.altLeft ||
    key == LogicalKeyboardKey.altRight ||
    key == LogicalKeyboardKey.metaLeft ||
    key == LogicalKeyboardKey.metaRight;

String? terminalKeyFromFlutterEvent(KeyEvent event) {
  final key = event.logicalKey;
  final special = switch (key) {
    LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => 'Enter',
    LogicalKeyboardKey.tab => 'Tab',
    LogicalKeyboardKey.backspace => 'Backspace',
    LogicalKeyboardKey.escape => 'Escape',
    LogicalKeyboardKey.arrowUp => 'ArrowUp',
    LogicalKeyboardKey.arrowDown => 'ArrowDown',
    LogicalKeyboardKey.arrowLeft => 'ArrowLeft',
    LogicalKeyboardKey.arrowRight => 'ArrowRight',
    LogicalKeyboardKey.home => 'Home',
    LogicalKeyboardKey.end => 'End',
    LogicalKeyboardKey.insert => 'Insert',
    LogicalKeyboardKey.delete => 'Delete',
    LogicalKeyboardKey.pageUp => 'PageUp',
    LogicalKeyboardKey.pageDown => 'PageDown',
    LogicalKeyboardKey.f1 => 'F1',
    LogicalKeyboardKey.f2 => 'F2',
    LogicalKeyboardKey.f3 => 'F3',
    LogicalKeyboardKey.f4 => 'F4',
    LogicalKeyboardKey.f5 => 'F5',
    LogicalKeyboardKey.f6 => 'F6',
    LogicalKeyboardKey.f7 => 'F7',
    LogicalKeyboardKey.f8 => 'F8',
    LogicalKeyboardKey.f9 => 'F9',
    LogicalKeyboardKey.f10 => 'F10',
    LogicalKeyboardKey.f11 => 'F11',
    LogicalKeyboardKey.f12 => 'F12',
    LogicalKeyboardKey.space => ' ',
    _ => null,
  };
  return normalizeDomTerminalKey(special ?? event.character ?? key.keyLabel);
}
