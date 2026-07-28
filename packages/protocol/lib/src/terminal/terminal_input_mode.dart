const _escape = '\x1b';
const _win32InputModeNumber = 9001;

final _inputModeSequence = RegExp(
  '$_escape\\[(?:([<>=?]?)([0-9;]*)u|\\?([0-9;]*)([hl]))',
);
final _incompleteInputModeSequence = RegExp('$_escape\\[[<>=?]?[0-9;]*\$');

class TerminalInputModeFeedResult {
  const TerminalInputModeFeedResult({
    required this.changed,
    required this.responses,
  });

  final bool changed;
  final List<String> responses;
}

class TerminalInputModeState {
  const TerminalInputModeState({
    required this.kittyKeyboardFlags,
    required this.win32InputMode,
  });

  final int kittyKeyboardFlags;
  final bool win32InputMode;
}

const defaultTerminalInputModeState = TerminalInputModeState(
  kittyKeyboardFlags: 0,
  win32InputMode: false,
);

bool terminalInputModeSupportsModifiedEnter(TerminalInputModeState state) =>
    state.kittyKeyboardFlags > 0 || state.win32InputMode;

bool terminalInputModeStatesEqual(
  TerminalInputModeState left,
  TerminalInputModeState right,
) =>
    left.kittyKeyboardFlags == right.kittyKeyboardFlags &&
    left.win32InputMode == right.win32InputMode;

class TerminalInputModeTracker {
  int _kittyKeyboardFlags = 0;
  bool _win32InputMode = false;
  final List<int> _kittyKeyboardStack = [];
  String _pending = '';

  TerminalInputModeFeedResult feed(String data) {
    if (data.isEmpty) {
      return const TerminalInputModeFeedResult(changed: false, responses: []);
    }

    final text = '$_pending$data';
    _pending = '';
    var changed = false;
    final responses = <String>[];
    var consumedUntil = 0;

    for (final match in _inputModeSequence.allMatches(text)) {
      consumedUntil = match.end;
      final privateFinal = match.group(4);
      if (privateFinal != null) {
        changed =
            _applyPrivateModeSequence(match.group(3) ?? '', privateFinal) ||
            changed;
        continue;
      }

      final result = _applyKittyKeyboardSequence(
        match.group(1) ?? '',
        match.group(2) ?? '',
      );
      changed = changed || result.changed;
      responses.addAll(result.responses);
    }

    final tail = text.substring(consumedUntil);
    final pendingStart = tail.lastIndexOf('$_escape[');
    if (pendingStart >= 0) {
      final pending = tail.substring(pendingStart);
      if (_incompleteInputModeSequence.hasMatch(pending)) {
        _pending = pending;
      }
    }

    return TerminalInputModeFeedResult(changed: changed, responses: responses);
  }

  void reset() {
    _kittyKeyboardFlags = 0;
    _win32InputMode = false;
    _kittyKeyboardStack.clear();
    _pending = '';
  }

  TerminalInputModeState getState() => TerminalInputModeState(
    kittyKeyboardFlags: _kittyKeyboardFlags,
    win32InputMode: _win32InputMode,
  );

  int getKittyKeyboardFlags() => _kittyKeyboardFlags;

  bool supportsModifiedEnter() =>
      terminalInputModeSupportsModifiedEnter(getState());

  String getPreamble() {
    final parts = <String>[];
    if (_kittyKeyboardFlags > 0) {
      parts.add('$_escape[=$_kittyKeyboardFlags;1u');
    }
    if (_win32InputMode) {
      parts.add('$_escape[?9001h');
    }
    return parts.join();
  }

  ({bool changed, List<String> responses}) _applyKittyKeyboardSequence(
    String prefix,
    String params,
  ) {
    final previousFlags = _kittyKeyboardFlags;

    switch (prefix) {
      case '>':
        _kittyKeyboardStack.add(_kittyKeyboardFlags);
        _kittyKeyboardFlags = _parseFirstParam(params) ?? 1;
      case '=':
        final mode = _parseSecondParam(params) ?? 1;
        _kittyKeyboardFlags = mode == 0 ? 0 : (_parseFirstParam(params) ?? 0);
      case '<':
        final count = (_parseFirstParam(params) ?? 1).clamp(1, 0x7fffffff);
        for (var index = 0; index < count; index += 1) {
          _kittyKeyboardFlags = _kittyKeyboardStack.isEmpty
              ? 0
              : _kittyKeyboardStack.removeLast();
        }
      case '?':
        return (
          changed: false,
          responses: ['$_escape[?${_kittyKeyboardFlags}u'],
        );
      default:
        return (changed: false, responses: const []);
    }

    return (changed: _kittyKeyboardFlags != previousFlags, responses: const []);
  }

  bool _applyPrivateModeSequence(String params, String finalByte) {
    final modes = _parsePrivateModeParams(params);
    if (!modes.contains(_win32InputModeNumber)) {
      return false;
    }

    final previous = _win32InputMode;
    _win32InputMode = finalByte == 'h';
    return _win32InputMode != previous;
  }
}

int? _parseFirstParam(String params) {
  final first = params.split(';').first;
  return RegExp(r'^\d+$').hasMatch(first) ? int.parse(first) : null;
}

int? _parseSecondParam(String params) {
  final values = params.split(';');
  if (values.length < 2 || !RegExp(r'^\d+$').hasMatch(values[1])) {
    return null;
  }
  return int.parse(values[1]);
}

Set<int> _parsePrivateModeParams(String params) => {
  for (final param in params.split(';'))
    if (RegExp(r'^\d+$').hasMatch(param)) int.parse(param),
};
