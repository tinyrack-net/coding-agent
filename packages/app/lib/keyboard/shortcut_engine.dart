import 'dart:async';

enum KeyboardFocusScope { messageInput, editable, terminal, other }

final class ShortcutKeyCombo {
  ShortcutKeyCombo({
    required this.code,
    this.key,
    this.shiftedKey,
    this.codeFallback = false,
    this.meta = false,
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
    this.mod = false,
    this.allowRepeat = true,
  });

  final String code;
  final String? key;
  final String? shiftedKey;
  final bool codeFallback;
  final bool meta;
  final bool ctrl;
  final bool alt;
  final bool shift;
  final bool mod;
  bool allowRepeat;
}

final class _KeyMapping {
  const _KeyMapping(
    this.code, {
    this.key,
    this.shiftedKey,
    this.codeFallback = false,
  });

  final String code;
  final String? key;
  final String? shiftedKey;
  final bool codeFallback;
}

Map<String, _KeyMapping> _buildKeyMap() {
  final result = <String, _KeyMapping>{};
  for (var index = 0; index < 26; index++) {
    final letter = String.fromCharCode(65 + index);
    result[letter] = _KeyMapping('Key$letter', key: letter.toLowerCase());
  }
  const shiftedDigits = {
    '1': '!',
    '2': '@',
    '3': '#',
    '4': r'$',
    '5': '%',
    '6': '^',
    '7': '&',
    '8': '*',
    '9': '(',
    '0': ')',
  };
  for (var index = 0; index <= 9; index++) {
    final digit = '$index';
    result[digit] = _KeyMapping(
      'Digit$digit',
      key: digit,
      shiftedKey: shiftedDigits[digit],
    );
  }
  result.addAll({
    'Digit': const _KeyMapping('Digit'),
    '-': const _KeyMapping('Minus', key: '-', shiftedKey: '_'),
    '=': const _KeyMapping('Equal', key: '=', shiftedKey: '+'),
    r'\': const _KeyMapping('Backslash', key: r'\', shiftedKey: '|'),
    '[': const _KeyMapping('BracketLeft', key: '[', shiftedKey: '{'),
    ']': const _KeyMapping('BracketRight', key: ']', shiftedKey: '}'),
    ';': const _KeyMapping('Semicolon', key: ';', shiftedKey: ':'),
    "'": const _KeyMapping('Quote', key: "'", shiftedKey: '"'),
    ',': const _KeyMapping('Comma', key: ',', shiftedKey: '<'),
    '.': const _KeyMapping('Period', key: '.', shiftedKey: '>'),
    '`': const _KeyMapping('Backquote', key: '`', shiftedKey: '~'),
    '/': const _KeyMapping('Slash', key: '/', shiftedKey: '?'),
    '?': const _KeyMapping('Slash', key: '?'),
    'Space': const _KeyMapping('Space', key: ' ', codeFallback: true),
    'Enter': const _KeyMapping('Enter', key: 'Enter', codeFallback: true),
    'Backspace': const _KeyMapping('Backspace'),
    'Escape': const _KeyMapping('Escape'),
    'ArrowLeft': const _KeyMapping('ArrowLeft'),
    'ArrowRight': const _KeyMapping('ArrowRight'),
    'ArrowUp': const _KeyMapping('ArrowUp'),
    'ArrowDown': const _KeyMapping('ArrowDown'),
    'Tab': const _KeyMapping('Tab'),
    'Delete': const _KeyMapping('Delete'),
    'Home': const _KeyMapping('Home'),
    'End': const _KeyMapping('End'),
    'PageUp': const _KeyMapping('PageUp'),
    'PageDown': const _KeyMapping('PageDown'),
    'Insert': const _KeyMapping('Insert'),
  });
  for (var index = 1; index <= 12; index++) {
    result['F$index'] = _KeyMapping('F$index');
  }
  return result;
}

final _keyMap = _buildKeyMap();
final _codeToKey = <String, String>{
  for (final entry in _keyMap.entries) entry.value.code: entry.key,
};

ShortcutKeyCombo parseShortcutString(String value) {
  final parts = value.split('+');
  if (parts.isEmpty || parts.any((part) => part.isEmpty)) {
    throw FormatException('Invalid shortcut string: "$value"');
  }
  var meta = false;
  var ctrl = false;
  var alt = false;
  var shift = false;
  var mod = false;
  String? keyPart;
  for (final part in parts) {
    switch (part) {
      case 'Cmd':
        meta = true;
      case 'Ctrl':
        ctrl = true;
      case 'Alt':
        alt = true;
      case 'Shift':
        shift = true;
      case 'Mod':
        mod = true;
      default:
        if (keyPart != null) {
          throw FormatException(
            'Invalid shortcut string: "$value" - multiple key parts',
          );
        }
        keyPart = part;
    }
  }
  if (keyPart == null) {
    throw FormatException('Invalid shortcut string: "$value" - no key part');
  }
  final mapping = _keyMap[keyPart];
  if (mapping == null) throw FormatException('Unknown key: "$keyPart"');
  return ShortcutKeyCombo(
    code: mapping.code,
    key: mapping.key,
    shiftedKey: mapping.shiftedKey,
    codeFallback: mapping.codeFallback,
    meta: meta,
    ctrl: ctrl,
    alt: alt,
    shift: shift,
    mod: mod,
  );
}

List<ShortcutKeyCombo> parseChordString(String value) =>
    value.split(' ').map(parseShortcutString).toList();

String shortcutKeyComboToString(ShortcutKeyCombo combo) {
  final parts = <String>[
    if (combo.mod) 'Mod',
    if (combo.ctrl) 'Ctrl',
    if (combo.alt) 'Alt',
    if (combo.shift) 'Shift',
    if (combo.meta) 'Cmd',
    ?_codeToKey[combo.code],
  ];
  return parts.join('+');
}

String shortcutChordToString(List<ShortcutKeyCombo> chord) =>
    chord.map(shortcutKeyComboToString).join(' ');

final class KeyboardShortcutContext {
  const KeyboardShortcutContext({
    required this.isMac,
    required this.isDesktop,
    required this.focusScope,
    required this.commandCenterOpen,
  });

  final bool isMac;
  final bool isDesktop;
  final KeyboardFocusScope focusScope;
  final bool commandCenterOpen;
}

final class KeyboardShortcutInput {
  const KeyboardShortcutInput({
    required this.key,
    required this.code,
    required this.altKey,
    required this.ctrlKey,
    required this.metaKey,
    required this.shiftKey,
    required this.repeat,
  });

  final String key;
  final String code;
  final bool altKey;
  final bool ctrlKey;
  final bool metaKey;
  final bool shiftKey;
  final bool repeat;
}

final class ShortcutWhen {
  const ShortcutWhen({
    this.mac,
    this.desktop,
    this.allowEditable = true,
    this.allowTerminal = true,
    this.allowCommandCenter = true,
    this.focusScope,
  });

  final bool? mac;
  final bool? desktop;
  final bool allowEditable;
  final bool allowTerminal;
  final bool allowCommandCenter;
  final KeyboardFocusScope? focusScope;
}

sealed class KeyboardShortcutPayload {
  const KeyboardShortcutPayload();
}

final class ShortcutIndexPayload extends KeyboardShortcutPayload {
  const ShortcutIndexPayload(this.index);
  final int index;
}

final class ShortcutDeltaPayload extends KeyboardShortcutPayload {
  const ShortcutDeltaPayload(this.delta);
  final int delta;
}

final class ShortcutMessageInputPayload extends KeyboardShortcutPayload {
  const ShortcutMessageInputPayload(this.kind);
  final String kind;
}

enum ShortcutPayloadKind { none, digitIndex, previous, next, messageInput }

final class ShortcutBinding {
  ShortcutBinding({
    required this.id,
    required this.action,
    required this.combo,
    this.when,
    this.payloadKind = ShortcutPayloadKind.none,
    this.messageInputKind,
    this.preventDefault = true,
    this.stopPropagation = true,
    this.allowRepeat = true,
    this.helpId,
  }) : parsedChord = parseChordString(combo) {
    if (!allowRepeat && parsedChord.isNotEmpty) {
      parsedChord.last.allowRepeat = false;
    }
  }

  final String id;
  final String action;
  final String combo;
  final ShortcutWhen? when;
  final ShortcutPayloadKind payloadKind;
  final String? messageInputKind;
  final bool preventDefault;
  final bool stopPropagation;
  final bool allowRepeat;
  final String? helpId;
  final List<ShortcutKeyCombo> parsedChord;

  ShortcutBinding withCombo(String value) => ShortcutBinding(
    id: id,
    action: action,
    combo: value,
    when: when,
    payloadKind: payloadKind,
    messageInputKind: messageInputKind,
    preventDefault: preventDefault,
    stopPropagation: stopPropagation,
    allowRepeat: allowRepeat,
    helpId: helpId,
  );
}

final class KeyboardShortcutMatch {
  const KeyboardShortcutMatch({
    required this.action,
    required this.payload,
    required this.preventDefault,
    required this.stopPropagation,
  });

  final String action;
  final KeyboardShortcutPayload? payload;
  final bool preventDefault;
  final bool stopPropagation;
}

final class ShortcutChordState {
  const ShortcutChordState({
    this.candidateIndices = const [],
    this.step = 0,
    this.timeout,
  });

  final List<int> candidateIndices;
  final int step;
  final Timer? timeout;

  static const empty = ShortcutChordState();
}

final class KeyboardShortcutResolution {
  const KeyboardShortcutResolution({
    required this.match,
    required this.nextChordState,
    required this.preventDefault,
  });

  final KeyboardShortcutMatch? match;
  final ShortcutChordState nextChordState;
  final bool preventDefault;
}

bool matchesKeyboardShortcutContext(
  ShortcutWhen? when,
  KeyboardShortcutContext context,
) {
  if (when == null) return true;
  if (when.mac != null && when.mac != context.isMac) return false;
  if (when.desktop != null && when.desktop != context.isDesktop) return false;
  if (!when.allowEditable &&
      (context.focusScope == KeyboardFocusScope.messageInput ||
          context.focusScope == KeyboardFocusScope.editable)) {
    return false;
  }
  if (!when.allowTerminal &&
      context.focusScope == KeyboardFocusScope.terminal) {
    return false;
  }
  if (!when.allowCommandCenter && context.commandCenterOpen) return false;
  if (when.focusScope != null && when.focusScope != context.focusScope) {
    return false;
  }
  return true;
}

int? _parseDigit(KeyboardShortcutInput event) {
  final code = event.code;
  if (code.startsWith('Digit')) {
    final value = int.tryParse(code.substring('Digit'.length));
    return value != null && value >= 1 && value <= 9 ? value : null;
  }
  if (code.startsWith('Numpad')) {
    final value = int.tryParse(code.substring('Numpad'.length));
    return value != null && value >= 1 && value <= 9 ? value : null;
  }
  return event.key.compareTo('1') >= 0 && event.key.compareTo('9') <= 0
      ? int.parse(event.key)
      : null;
}

bool _matchesKeyOrCode(ShortcutKeyCombo combo, KeyboardShortcutInput event) {
  if (combo.key == null) return event.code == combo.code;
  final eventKey = event.key.toLowerCase();
  if (eventKey == combo.key) return true;
  if (combo.shift && combo.shiftedKey != null && eventKey == combo.shiftedKey) {
    return true;
  }
  if (combo.alt && event.code == combo.code) return true;
  return combo.codeFallback && event.code == combo.code;
}

bool _matchesCombo(
  ShortcutKeyCombo combo,
  KeyboardShortcutInput event,
  bool isMac,
) {
  if (combo.mod) {
    if (isMac) {
      if (!event.metaKey || combo.ctrl != event.ctrlKey) return false;
    } else {
      if (!event.ctrlKey || combo.meta != event.metaKey) return false;
    }
  } else {
    if (combo.meta != event.metaKey || combo.ctrl != event.ctrlKey) {
      return false;
    }
  }
  if (combo.alt != event.altKey || combo.shift != event.shiftKey) {
    return false;
  }
  if (!combo.allowRepeat && event.repeat) return false;
  if (combo.code == 'Digit') return _parseDigit(event) != null;
  return _matchesKeyOrCode(combo, event);
}

KeyboardShortcutPayload? _resolvePayload(
  ShortcutBinding binding,
  KeyboardShortcutInput event,
) => switch (binding.payloadKind) {
  ShortcutPayloadKind.none => null,
  ShortcutPayloadKind.digitIndex =>
    _parseDigit(event) == null
        ? null
        : ShortcutIndexPayload(_parseDigit(event)!),
  ShortcutPayloadKind.previous => const ShortcutDeltaPayload(-1),
  ShortcutPayloadKind.next => const ShortcutDeltaPayload(1),
  ShortcutPayloadKind.messageInput => ShortcutMessageInputPayload(
    binding.messageInputKind!,
  ),
};

KeyboardShortcutMatch _buildMatch(
  ShortcutBinding binding,
  KeyboardShortcutInput event,
) => KeyboardShortcutMatch(
  action: binding.action,
  payload: _resolvePayload(binding, event),
  preventDefault: binding.preventDefault,
  stopPropagation: binding.stopPropagation,
);

ShortcutChordState _resetChordState(ShortcutChordState state) {
  state.timeout?.cancel();
  return ShortcutChordState.empty;
}

const shortcutChordTimeout = Duration(milliseconds: 1500);

KeyboardShortcutResolution resolveKeyboardShortcut({
  required KeyboardShortcutInput event,
  required KeyboardShortcutContext context,
  required ShortcutChordState chordState,
  required void Function() onChordReset,
  List<ShortcutBinding>? bindings,
}) {
  final effectiveBindings = bindings ?? defaultShortcutBindings;
  if (chordState.step == 0) {
    final advancing = <int>[];
    KeyboardShortcutMatch? single;
    for (var index = 0; index < effectiveBindings.length; index++) {
      final binding = effectiveBindings[index];
      if (binding.parsedChord.isEmpty ||
          !_matchesCombo(binding.parsedChord.first, event, context.isMac) ||
          !matchesKeyboardShortcutContext(binding.when, context)) {
        continue;
      }
      if (binding.parsedChord.length > 1) {
        advancing.add(index);
      } else {
        single ??= _buildMatch(binding, event);
      }
    }
    if (advancing.isNotEmpty) {
      return KeyboardShortcutResolution(
        match: null,
        nextChordState: ShortcutChordState(
          candidateIndices: advancing,
          step: 1,
          timeout: Timer(shortcutChordTimeout, onChordReset),
        ),
        preventDefault: true,
      );
    }
    return KeyboardShortcutResolution(
      match: single,
      nextChordState: _resetChordState(chordState),
      preventDefault: false,
    );
  }

  final advancing = <int>[];
  KeyboardShortcutMatch? completed;
  for (final index in chordState.candidateIndices) {
    if (index < 0 || index >= effectiveBindings.length) continue;
    final binding = effectiveBindings[index];
    if (chordState.step >= binding.parsedChord.length) continue;
    final combo = binding.parsedChord[chordState.step];
    if (!_matchesCombo(combo, event, context.isMac) ||
        !matchesKeyboardShortcutContext(binding.when, context)) {
      continue;
    }
    if (chordState.step + 1 == binding.parsedChord.length) {
      completed = _buildMatch(binding, event);
      break;
    }
    advancing.add(index);
  }
  if (completed != null) {
    return KeyboardShortcutResolution(
      match: completed,
      nextChordState: _resetChordState(chordState),
      preventDefault: false,
    );
  }
  if (advancing.isNotEmpty) {
    chordState.timeout?.cancel();
    return KeyboardShortcutResolution(
      match: null,
      nextChordState: ShortcutChordState(
        candidateIndices: advancing,
        step: chordState.step + 1,
        timeout: Timer(shortcutChordTimeout, onChordReset),
      ),
      preventDefault: true,
    );
  }
  return KeyboardShortcutResolution(
    match: null,
    nextChordState: _resetChordState(chordState),
    preventDefault: false,
  );
}

List<ShortcutBinding> buildEffectiveShortcutBindings(
  Map<String, String> overrides, {
  List<ShortcutBinding>? bindings,
}) {
  final defaults = bindings ?? defaultShortcutBindings;
  return defaults.map((binding) {
    final override = overrides[binding.id];
    if (override == null) return binding;
    try {
      return binding.withCombo(override);
    } on FormatException {
      return binding;
    }
  }).toList();
}

ShortcutBinding _b(
  String id,
  String action,
  String combo, {
  ShortcutWhen? when,
  ShortcutPayloadKind payload = ShortcutPayloadKind.none,
  String? messageInputKind,
  bool preventDefault = true,
  bool stopPropagation = true,
  bool allowRepeat = true,
  String? helpId,
}) => ShortcutBinding(
  id: id,
  action: action,
  combo: combo,
  when: when,
  payloadKind: payload,
  messageInputKind: messageInputKind,
  preventDefault: preventDefault,
  stopPropagation: stopPropagation,
  allowRepeat: allowRepeat,
  helpId: helpId,
);

const _mac = ShortcutWhen(mac: true);
const _nonMacNoTerminal = ShortcutWhen(mac: false, allowTerminal: false);
const _macNoCenter = ShortcutWhen(mac: true, allowCommandCenter: false);
const _nonMacNoCenterTerminal = ShortcutWhen(
  mac: false,
  allowCommandCenter: false,
  allowTerminal: false,
);

final defaultShortcutBindings = <ShortcutBinding>[
  _b(
    'agent-new-cmd-shift-o-mac',
    'agent.new',
    'Cmd+O',
    when: _mac,
    helpId: 'new-agent',
  ),
  _b(
    'agent-new-ctrl-shift-o-non-mac',
    'agent.new',
    'Ctrl+O',
    when: _nonMacNoTerminal,
    helpId: 'new-agent',
  ),
  _b(
    'workspace-new-cmd-n-mac',
    'workspace.new',
    'Cmd+N',
    when: _macNoCenter,
    helpId: 'new-workspace',
  ),
  _b(
    'workspace-new-ctrl-n-non-mac',
    'workspace.new',
    'Ctrl+N',
    when: _nonMacNoCenterTerminal,
    helpId: 'new-workspace',
  ),
  _b(
    'worktree-archive-cmd-shift-backspace-mac',
    'workspace.archive',
    'Cmd+Shift+Backspace',
    when: _macNoCenter,
    helpId: 'archive-workspace',
  ),
  _b(
    'worktree-archive-ctrl-shift-backspace-non-mac',
    'workspace.archive',
    'Ctrl+Shift+Backspace',
    when: _nonMacNoCenterTerminal,
    helpId: 'archive-workspace',
  ),
  _b(
    'workspace-pin-cmd-shift-p-mac',
    'workspace.pin',
    'Cmd+Shift+P',
    when: _macNoCenter,
    helpId: 'pin-workspace',
  ),
  _b(
    'workspace-pin-ctrl-shift-p-non-mac',
    'workspace.pin',
    'Ctrl+Shift+P',
    when: _nonMacNoCenterTerminal,
    helpId: 'pin-workspace',
  ),
  _b(
    'workspace-tab-new-cmd-t-mac',
    'workspace.tab.new',
    'Cmd+T',
    when: _macNoCenter,
    helpId: 'workspace-tab-new',
  ),
  _b(
    'workspace-tab-new-ctrl-t-non-mac',
    'workspace.tab.new',
    'Ctrl+T',
    when: _nonMacNoCenterTerminal,
    helpId: 'workspace-tab-new',
  ),
  _b(
    'workspace-tab-close-current-cmd-w-mac',
    'workspace.tab.close.current',
    'Cmd+W',
    when: const ShortcutWhen(
      mac: true,
      desktop: true,
      allowCommandCenter: false,
    ),
    helpId: 'workspace-tab-close-current',
  ),
  _b(
    'workspace-tab-close-current-ctrl-w-non-mac',
    'workspace.tab.close.current',
    'Ctrl+W',
    when: const ShortcutWhen(
      mac: false,
      desktop: true,
      allowCommandCenter: false,
      allowTerminal: false,
    ),
    helpId: 'workspace-tab-close-current',
  ),
  _b(
    'workspace-tab-close-current-alt-shift-w-web',
    'workspace.tab.close.current',
    'Alt+Shift+W',
    when: const ShortcutWhen(desktop: false, allowCommandCenter: false),
    helpId: 'workspace-tab-close-current',
  ),
  _b(
    'workspace-navigate-index-cmd-digit-mac',
    'workspace.navigate.index',
    'Cmd+Digit',
    when: const ShortcutWhen(
      mac: true,
      desktop: true,
      allowCommandCenter: false,
    ),
    payload: ShortcutPayloadKind.digitIndex,
    helpId: 'workspace-jump-index',
  ),
  _b(
    'workspace-navigate-index-ctrl-digit-non-mac',
    'workspace.navigate.index',
    'Ctrl+Digit',
    when: const ShortcutWhen(
      mac: false,
      desktop: true,
      allowCommandCenter: false,
      allowTerminal: false,
    ),
    payload: ShortcutPayloadKind.digitIndex,
    helpId: 'workspace-jump-index',
  ),
  _b(
    'workspace-navigate-index-alt-digit-web',
    'workspace.navigate.index',
    'Alt+Digit',
    when: const ShortcutWhen(desktop: false, allowCommandCenter: false),
    payload: ShortcutPayloadKind.digitIndex,
    helpId: 'workspace-jump-index',
  ),
  _b(
    'workspace-tab-navigate-index-cmd-alt-digit-mac-desktop',
    'workspace.tab.navigate.index',
    'Cmd+Alt+Digit',
    when: const ShortcutWhen(
      mac: true,
      desktop: true,
      allowCommandCenter: false,
    ),
    payload: ShortcutPayloadKind.digitIndex,
    helpId: 'workspace-tab-jump-index',
  ),
  _b(
    'workspace-tab-navigate-index-alt-digit-desktop',
    'workspace.tab.navigate.index',
    'Alt+Digit',
    when: const ShortcutWhen(
      mac: false,
      desktop: true,
      allowCommandCenter: false,
    ),
    payload: ShortcutPayloadKind.digitIndex,
    helpId: 'workspace-tab-jump-index',
  ),
  _b(
    'workspace-tab-navigate-index-alt-shift-digit-web',
    'workspace.tab.navigate.index',
    'Alt+Shift+Digit',
    when: const ShortcutWhen(desktop: false, allowCommandCenter: false),
    payload: ShortcutPayloadKind.digitIndex,
    helpId: 'workspace-tab-jump-index',
  ),
  _b(
    'workspace-navigate-relative-cmd-left-mac',
    'workspace.navigate.relative',
    'Cmd+[',
    when: const ShortcutWhen(
      mac: true,
      desktop: true,
      allowCommandCenter: false,
    ),
    payload: ShortcutPayloadKind.previous,
    helpId: 'workspace-prev',
  ),
  _b(
    'workspace-navigate-relative-ctrl-left-non-mac',
    'workspace.navigate.relative',
    'Ctrl+[',
    when: const ShortcutWhen(
      mac: false,
      desktop: true,
      allowCommandCenter: false,
      allowTerminal: false,
    ),
    payload: ShortcutPayloadKind.previous,
    helpId: 'workspace-prev',
  ),
  _b(
    'workspace-navigate-relative-cmd-right-mac',
    'workspace.navigate.relative',
    'Cmd+]',
    when: const ShortcutWhen(
      mac: true,
      desktop: true,
      allowCommandCenter: false,
    ),
    payload: ShortcutPayloadKind.next,
    helpId: 'workspace-next',
  ),
  _b(
    'workspace-navigate-relative-ctrl-right-non-mac',
    'workspace.navigate.relative',
    'Ctrl+]',
    when: const ShortcutWhen(
      mac: false,
      desktop: true,
      allowCommandCenter: false,
      allowTerminal: false,
    ),
    payload: ShortcutPayloadKind.next,
    helpId: 'workspace-next',
  ),
  _b(
    'workspace-navigate-relative-alt-left-web',
    'workspace.navigate.relative',
    'Alt+[',
    when: const ShortcutWhen(desktop: false, allowCommandCenter: false),
    payload: ShortcutPayloadKind.previous,
    helpId: 'workspace-prev',
  ),
  _b(
    'workspace-navigate-relative-alt-right-web',
    'workspace.navigate.relative',
    'Alt+]',
    when: const ShortcutWhen(desktop: false, allowCommandCenter: false),
    payload: ShortcutPayloadKind.next,
    helpId: 'workspace-next',
  ),
  _b(
    'workspace-tab-navigate-relative-alt-shift-left',
    'workspace.tab.navigate.relative',
    'Alt+Shift+[',
    when: const ShortcutWhen(allowCommandCenter: false),
    payload: ShortcutPayloadKind.previous,
    helpId: 'workspace-tab-prev',
  ),
  _b(
    'workspace-tab-navigate-relative-alt-shift-right',
    'workspace.tab.navigate.relative',
    'Alt+Shift+]',
    when: const ShortcutWhen(allowCommandCenter: false),
    payload: ShortcutPayloadKind.next,
    helpId: 'workspace-tab-next',
  ),
  _b(
    'workspace-pane-split-right-cmd-backslash',
    'workspace.pane.split.right',
    r'Cmd+\',
    when: _macNoCenter,
    helpId: 'workspace-pane-split-right',
  ),
  _b(
    'workspace-pane-split-down-cmd-shift-backslash',
    'workspace.pane.split.down',
    r'Cmd+Shift+\',
    when: _macNoCenter,
    helpId: 'workspace-pane-split-down',
  ),
  _b(
    'workspace-pane-focus-left-cmd-shift-left',
    'workspace.pane.focus.left',
    'Cmd+Shift+ArrowLeft',
    when: const ShortcutWhen(
      mac: true,
      allowCommandCenter: false,
      allowEditable: false,
    ),
    helpId: 'workspace-pane-focus-left',
  ),
  _b(
    'workspace-pane-focus-right-cmd-shift-right',
    'workspace.pane.focus.right',
    'Cmd+Shift+ArrowRight',
    when: const ShortcutWhen(
      mac: true,
      allowCommandCenter: false,
      allowEditable: false,
    ),
    helpId: 'workspace-pane-focus-right',
  ),
  _b(
    'workspace-pane-focus-up-cmd-shift-up',
    'workspace.pane.focus.up',
    'Cmd+Shift+ArrowUp',
    when: const ShortcutWhen(
      mac: true,
      allowCommandCenter: false,
      allowEditable: false,
    ),
    helpId: 'workspace-pane-focus-up',
  ),
  _b(
    'workspace-pane-focus-down-cmd-shift-down',
    'workspace.pane.focus.down',
    'Cmd+Shift+ArrowDown',
    when: const ShortcutWhen(
      mac: true,
      allowCommandCenter: false,
      allowEditable: false,
    ),
    helpId: 'workspace-pane-focus-down',
  ),
  _b(
    'workspace-pane-move-tab-left-cmd-shift-alt-left',
    'workspace.pane.move-tab.left',
    'Cmd+Alt+Shift+ArrowLeft',
    when: _macNoCenter,
    helpId: 'workspace-pane-move-tab-left',
  ),
  _b(
    'workspace-pane-move-tab-right-cmd-shift-alt-right',
    'workspace.pane.move-tab.right',
    'Cmd+Alt+Shift+ArrowRight',
    when: _macNoCenter,
    helpId: 'workspace-pane-move-tab-right',
  ),
  _b(
    'workspace-pane-move-tab-up-cmd-shift-alt-up',
    'workspace.pane.move-tab.up',
    'Cmd+Alt+Shift+ArrowUp',
    when: _macNoCenter,
    helpId: 'workspace-pane-move-tab-up',
  ),
  _b(
    'workspace-pane-move-tab-down-cmd-shift-alt-down',
    'workspace.pane.move-tab.down',
    'Cmd+Alt+Shift+ArrowDown',
    when: _macNoCenter,
    helpId: 'workspace-pane-move-tab-down',
  ),
  _b(
    'workspace-pane-close-cmd-shift-w',
    'workspace.pane.close',
    'Cmd+Shift+W',
    when: _macNoCenter,
    helpId: 'workspace-pane-close',
  ),
  _b(
    'workspace-terminal-new-cmd-shift-t-mac',
    'workspace.terminal.new',
    'Cmd+Shift+T',
    when: _macNoCenter,
    helpId: 'workspace-terminal-new',
  ),
  _b(
    'workspace-terminal-new-ctrl-shift-t-non-mac',
    'workspace.terminal.new',
    'Ctrl+Shift+T',
    when: _nonMacNoCenterTerminal,
    helpId: 'workspace-terminal-new',
  ),
  _b(
    'command-center-toggle-cmd-k-mac',
    'command-center.toggle',
    'Cmd+K',
    when: _mac,
    helpId: 'toggle-command-center',
  ),
  _b(
    'command-center-toggle-ctrl-k-non-mac',
    'command-center.toggle',
    'Ctrl+K',
    when: _nonMacNoTerminal,
    helpId: 'toggle-command-center',
  ),
  _b(
    'shortcuts-dialog-toggle-question-mark',
    'shortcuts.dialog.toggle',
    'Shift+?',
    when: const ShortcutWhen(focusScope: KeyboardFocusScope.other),
    allowRepeat: false,
    helpId: 'show-shortcuts',
  ),
  _b(
    'sidebar-toggle-left-mac-cmd-b',
    'sidebar.toggle.left',
    'Cmd+B',
    when: _mac,
    helpId: 'toggle-left-sidebar',
  ),
  _b(
    'sidebar-toggle-left-ctrl-period-non-mac',
    'sidebar.toggle.left',
    'Ctrl+B',
    when: _nonMacNoCenterTerminal,
    helpId: 'toggle-left-sidebar',
  ),
  _b(
    'sidebar-toggle-right-cmd-e-mac',
    'sidebar.toggle.right',
    'Cmd+E',
    when: _macNoCenter,
    helpId: 'toggle-right-sidebar',
  ),
  _b(
    'sidebar-toggle-right-ctrl-e-non-mac',
    'sidebar.toggle.right',
    'Ctrl+E',
    when: _nonMacNoCenterTerminal,
    helpId: 'toggle-right-sidebar',
  ),
  _b(
    'sidebar-toggle-right-ctrl-backquote',
    'sidebar.toggle.right',
    'Ctrl+`',
    when: const ShortcutWhen(allowCommandCenter: false),
  ),
  _b(
    'sidebar-toggle-both-cmd-period-mac',
    'sidebar.toggle.both',
    'Cmd+.',
    when: _macNoCenter,
    helpId: 'toggle-both-sidebars',
  ),
  _b(
    'sidebar-toggle-both-ctrl-period-non-mac',
    'sidebar.toggle.both',
    'Ctrl+.',
    when: _nonMacNoCenterTerminal,
    helpId: 'toggle-both-sidebars',
  ),
  _b(
    'settings-toggle-cmd-comma-mac',
    'settings.toggle',
    'Cmd+,',
    when: _macNoCenter,
    helpId: 'toggle-settings',
  ),
  _b(
    'settings-toggle-ctrl-comma-non-mac',
    'settings.toggle',
    'Ctrl+,',
    when: _nonMacNoCenterTerminal,
    helpId: 'toggle-settings',
  ),
  _b(
    'view-toggle-focus-cmd-shift-f-mac',
    'view.toggle.focus',
    'Cmd+Shift+F',
    when: _macNoCenter,
    helpId: 'toggle-focus',
  ),
  _b(
    'view-toggle-focus-ctrl-shift-f-non-mac',
    'view.toggle.focus',
    'Ctrl+Shift+F',
    when: _nonMacNoCenterTerminal,
    helpId: 'toggle-focus',
  ),
  _b(
    'theme-cycle-cmd-shift-t-mac',
    'theme.cycle',
    'Cmd+Alt+T',
    when: _macNoCenter,
    helpId: 'cycle-theme',
  ),
  _b(
    'theme-cycle-ctrl-alt-t-non-mac',
    'theme.cycle',
    'Ctrl+Alt+T',
    when: _nonMacNoCenterTerminal,
    helpId: 'cycle-theme',
  ),
  _b(
    'message-input-focus-cmd-l-mac',
    'message-input.action',
    'Cmd+L',
    when: _macNoCenter,
    payload: ShortcutPayloadKind.messageInput,
    messageInputKind: 'focus',
    helpId: 'focus-message-input',
  ),
  _b(
    'message-input-focus-ctrl-l-non-mac',
    'message-input.action',
    'Ctrl+L',
    when: _nonMacNoCenterTerminal,
    payload: ShortcutPayloadKind.messageInput,
    messageInputKind: 'focus',
    helpId: 'focus-message-input',
  ),
  _b(
    'message-input-mode-cycle-shift-tab',
    'message-input.action',
    'Shift+Tab',
    when: const ShortcutWhen(
      allowCommandCenter: false,
      focusScope: KeyboardFocusScope.messageInput,
    ),
    payload: ShortcutPayloadKind.messageInput,
    messageInputKind: 'mode-cycle',
    allowRepeat: false,
    helpId: 'cycle-agent-mode',
  ),
  _b(
    'message-input-voice-toggle-cmd-shift-d-mac',
    'message-input.action',
    'Cmd+Shift+D',
    when: const ShortcutWhen(
      mac: true,
      allowCommandCenter: false,
      allowTerminal: false,
    ),
    payload: ShortcutPayloadKind.messageInput,
    messageInputKind: 'voice-toggle',
    allowRepeat: false,
    helpId: 'voice-toggle',
  ),
  _b(
    'message-input-voice-toggle-ctrl-shift-d-non-mac',
    'message-input.action',
    'Ctrl+Shift+D',
    when: const ShortcutWhen(
      mac: false,
      allowCommandCenter: false,
      allowTerminal: false,
    ),
    payload: ShortcutPayloadKind.messageInput,
    messageInputKind: 'voice-toggle',
    allowRepeat: false,
    helpId: 'voice-toggle',
  ),
  _b(
    'message-input-dictation-toggle-cmd-d-mac',
    'message-input.action',
    'Cmd+D',
    when: const ShortcutWhen(
      mac: true,
      allowCommandCenter: false,
      allowTerminal: false,
    ),
    payload: ShortcutPayloadKind.messageInput,
    messageInputKind: 'dictation-toggle',
    helpId: 'dictation-toggle',
  ),
  _b(
    'message-input-dictation-toggle-ctrl-d-non-mac',
    'message-input.action',
    'Ctrl+D',
    when: const ShortcutWhen(
      mac: false,
      allowCommandCenter: false,
      allowTerminal: false,
    ),
    payload: ShortcutPayloadKind.messageInput,
    messageInputKind: 'dictation-toggle',
    helpId: 'dictation-toggle',
  ),
  _b(
    'agent-interrupt',
    'agent.interrupt',
    'Escape',
    when: const ShortcutWhen(allowCommandCenter: false, allowTerminal: false),
    preventDefault: false,
    stopPropagation: false,
    helpId: 'agent-interrupt',
  ),
  _b(
    'message-input-dictation-confirm-enter',
    'message-input.action',
    'Enter',
    when: const ShortcutWhen(allowCommandCenter: false, allowTerminal: false),
    payload: ShortcutPayloadKind.messageInput,
    messageInputKind: 'dictation-confirm',
  ),
  _b(
    'message-input-voice-mute-toggle',
    'message-input.action',
    'Space',
    when: const ShortcutWhen(
      allowCommandCenter: false,
      focusScope: KeyboardFocusScope.other,
    ),
    payload: ShortcutPayloadKind.messageInput,
    messageInputKind: 'voice-mute-toggle',
    allowRepeat: false,
    helpId: 'voice-mute-toggle',
  ),
];
