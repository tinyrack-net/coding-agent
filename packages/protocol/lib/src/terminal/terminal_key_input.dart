import 'terminal_input_mode.dart';

const _escape = '\x1b';
const _win32LeftAltPressed = 0x0002;
const _win32LeftCtrlPressed = 0x0008;
const _win32ShiftPressed = 0x0010;

class TerminalKeyInput {
  const TerminalKeyInput({
    required this.key,
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
  });

  final String key;
  final bool ctrl;
  final bool alt;
  final bool shift;
  final bool meta;
}

class TerminalKeyInputEncodingOptions {
  const TerminalKeyInputEncodingOptions({this.inputMode});

  final TerminalInputModeState? inputMode;
}

String encodeTerminalKeyInput(
  TerminalKeyInput input, [
  TerminalKeyInputEncodingOptions options =
      const TerminalKeyInputEncodingOptions(),
]) {
  final key = input.key;
  if (key.isEmpty) return '';
  if (key.runes.length == 1) return _encodePrintableKey(input);

  switch (key) {
    case 'Enter':
      final modifier = _modifierParam(input);
      if (modifier > 1 && _shouldUseWin32InputMode(input, options)) {
        return _encodeWin32EnterKeyInput(input);
      }
      if (modifier > 1 && _shouldUseKittyKeyboardMode(input, options)) {
        return '$_escape[13;${modifier}u';
      }
      return '\r';
    case 'Tab':
      if (input.shift && !input.ctrl && !input.alt && !input.meta) {
        return '$_escape[Z';
      }
      return _applyAltLikePrefix('\t', input);
    case 'Backspace':
      return _applyAltLikePrefix('\x7f', input);
    case 'Escape':
      return _escape;
  }

  return _encodeNavigationKey(key, input) ??
      _encodeFunctionKey(key, input) ??
      '';
}

int _modifierParam(TerminalKeyInput input) {
  var value = 1;
  if (input.shift) value += 1;
  if (input.alt) value += 2;
  if (input.ctrl) value += 4;
  if (input.meta) value += 8;
  return value;
}

int _win32ControlKeyState(TerminalKeyInput input) {
  var value = 0;
  if (input.shift) value += _win32ShiftPressed;
  if (input.ctrl) value += _win32LeftCtrlPressed;
  if (input.alt) value += _win32LeftAltPressed;
  return value;
}

bool _shouldUseWin32InputMode(
  TerminalKeyInput input,
  TerminalKeyInputEncodingOptions options,
) =>
    (options.inputMode?.win32InputMode ?? false) &&
    (input.shift || input.ctrl || input.alt);

bool _shouldUseKittyKeyboardMode(
  TerminalKeyInput input,
  TerminalKeyInputEncodingOptions options,
) =>
    (options.inputMode?.kittyKeyboardFlags ?? 0) > 0 &&
    (input.shift || input.ctrl || input.alt || input.meta);

String _encodeWin32EnterKeyInput(TerminalKeyInput input) =>
    '$_escape[13;28;13;1;${_win32ControlKeyState(input)};1_';

String _applyAltLikePrefix(String sequence, TerminalKeyInput input) =>
    input.alt ? '$_escape$sequence' : sequence;

String? _ctrlSymbolCode(String character) => switch (character) {
  ' ' || '@' || '2' => '\x00',
  '[' || '3' => _escape,
  r'\' || '4' => '\x1c',
  ']' || '5' => '\x1d',
  '^' || '6' => '\x1e',
  '_' || '/' || '7' => '\x1f',
  '8' || '?' => '\x7f',
  _ => null,
};

String _encodeCtrlChar(String character, TerminalKeyInput input) {
  final upper = character.toUpperCase();
  if (upper.runes.length == 1 &&
      upper.codeUnitAt(0) >= 65 &&
      upper.codeUnitAt(0) <= 90) {
    return _applyAltLikePrefix(
      String.fromCharCode(upper.codeUnitAt(0) - 64),
      input,
    );
  }
  final symbol = _ctrlSymbolCode(character);
  if (symbol != null) return _applyAltLikePrefix(symbol, input);
  if (character.runes.length == 1) {
    return _applyAltLikePrefix(
      String.fromCharCode(character.codeUnitAt(0) & 0x1f),
      input,
    );
  }
  return _applyAltLikePrefix(character, input);
}

String _encodePrintableKey(TerminalKeyInput input) {
  final character = input.shift ? input.key.toUpperCase() : input.key;
  if (input.ctrl) return _encodeCtrlChar(character, input);
  return _applyAltLikePrefix(character, input);
}

String _csiWithModifier(String finalByte, TerminalKeyInput input) {
  final modifier = _modifierParam(input);
  return modifier == 1
      ? '$_escape[$finalByte'
      : '$_escape[1;$modifier$finalByte';
}

String _csiTilde(int base, TerminalKeyInput input) {
  final modifier = _modifierParam(input);
  return modifier == 1 ? '$_escape[$base~' : '$_escape[$base;$modifier~';
}

String? _encodeFunctionKey(String key, TerminalKeyInput input) => switch (key) {
  'F1' =>
    _modifierParam(input) == 1 ? '${_escape}OP' : _csiWithModifier('P', input),
  'F2' =>
    _modifierParam(input) == 1 ? '${_escape}OQ' : _csiWithModifier('Q', input),
  'F3' =>
    _modifierParam(input) == 1 ? '${_escape}OR' : _csiWithModifier('R', input),
  'F4' =>
    _modifierParam(input) == 1 ? '${_escape}OS' : _csiWithModifier('S', input),
  'F5' => _csiTilde(15, input),
  'F6' => _csiTilde(17, input),
  'F7' => _csiTilde(18, input),
  'F8' => _csiTilde(19, input),
  'F9' => _csiTilde(20, input),
  'F10' => _csiTilde(21, input),
  'F11' => _csiTilde(23, input),
  'F12' => _csiTilde(24, input),
  _ => null,
};

String? _encodeNavigationKey(String key, TerminalKeyInput input) =>
    switch (key) {
      'ArrowUp' => _csiWithModifier('A', input),
      'ArrowDown' => _csiWithModifier('B', input),
      'ArrowRight' => _csiWithModifier('C', input),
      'ArrowLeft' => _csiWithModifier('D', input),
      'Home' => _csiWithModifier('H', input),
      'End' => _csiWithModifier('F', input),
      'Insert' => _csiTilde(2, input),
      'Delete' => _csiTilde(3, input),
      'PageUp' => _csiTilde(5, input),
      'PageDown' => _csiTilde(6, input),
      _ => null,
    };
