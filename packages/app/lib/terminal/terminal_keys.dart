enum TerminalModifier { ctrl, shift, alt }

final class PendingTerminalModifiers {
  const PendingTerminalModifiers({
    this.ctrl = false,
    this.shift = false,
    this.alt = false,
  });

  static const empty = PendingTerminalModifiers();

  final bool ctrl;
  final bool shift;
  final bool alt;

  bool get hasAny => ctrl || shift || alt;

  PendingTerminalModifiers copyWith({bool? ctrl, bool? shift, bool? alt}) =>
      PendingTerminalModifiers(
        ctrl: ctrl ?? this.ctrl,
        shift: shift ?? this.shift,
        alt: alt ?? this.alt,
      );
}

final class TerminalModifiers {
  const TerminalModifiers({
    required this.ctrl,
    required this.shift,
    required this.alt,
    required this.meta,
  });

  final bool ctrl;
  final bool shift;
  final bool alt;
  final bool meta;
}

const _modifierDomKeys = {'Control', 'Shift', 'Alt', 'Meta', 'AltGraph', 'OS'};

const _domKeyAliases = {
  'Esc': 'Escape',
  'Left': 'ArrowLeft',
  'Right': 'ArrowRight',
  'Up': 'ArrowUp',
  'Down': 'ArrowDown',
  'Del': 'Delete',
  'Spacebar': ' ',
  'Space': ' ',
};

const _supportedSpecialKeys = {
  'Enter',
  'Tab',
  'Backspace',
  'Escape',
  'ArrowUp',
  'ArrowDown',
  'ArrowLeft',
  'ArrowRight',
  'Home',
  'End',
  'Insert',
  'Delete',
  'PageUp',
  'PageDown',
  'F1',
  'F2',
  'F3',
  'F4',
  'F5',
  'F6',
  'F7',
  'F8',
  'F9',
  'F10',
  'F11',
  'F12',
};

bool isTerminalModifierDomKey(String rawKey) =>
    _modifierDomKeys.contains(rawKey);

String? normalizeDomTerminalKey(String rawKey) {
  if (rawKey.isEmpty) return null;
  final key = _domKeyAliases[rawKey] ?? rawKey;
  if (key == 'Unidentified' ||
      key == 'Dead' ||
      key == 'Compose' ||
      key == 'Process') {
    return null;
  }
  if (key.length == 1) return key;
  return _supportedSpecialKeys.contains(key) ? key : null;
}

String normalizeTerminalTransportKey(String key) =>
    key.length == 1 ? key.toLowerCase() : key;

bool hasPendingTerminalModifiers(PendingTerminalModifiers modifiers) =>
    modifiers.hasAny;

bool isAppleHandheldPlatform({
  String? userAgent,
  String? platform,
  int? maxTouchPoints,
}) {
  final resolvedUserAgent = userAgent ?? '';
  final resolvedPlatform = platform ?? '';
  final touchPoints = maxTouchPoints ?? 0;
  if (RegExp(r'iPad|iPhone|iPod').hasMatch(resolvedUserAgent)) return true;
  return RegExp('Mac', caseSensitive: false).hasMatch(resolvedPlatform) &&
      touchPoints > 1;
}

bool shouldInterceptDomTerminalKey({
  required String key,
  required bool ctrlKey,
  required bool shiftKey,
  required bool altKey,
  required bool metaKey,
  required PendingTerminalModifiers pendingModifiers,
  bool enhancedInputActive = false,
  bool isAppleHandheld = false,
}) {
  if (hasPendingTerminalModifiers(pendingModifiers)) return true;
  if (key == 'Enter' && (shiftKey || ctrlKey || altKey || metaKey)) {
    return enhancedInputActive;
  }
  // COMPAT(xterm-ipad-ctrl-c): mirror the frozen xterm.js workaround until
  // its upstream hardware-keyboard keyCode bug is no longer relevant.
  return isAppleHandheld &&
      ctrlKey &&
      !metaKey &&
      !altKey &&
      !shiftKey &&
      (key == 'c' || key == 'C');
}

TerminalModifiers mergeTerminalModifiers({
  required PendingTerminalModifiers pendingModifiers,
  required bool ctrlKey,
  required bool shiftKey,
  required bool altKey,
  required bool metaKey,
}) => TerminalModifiers(
  ctrl: ctrlKey || pendingModifiers.ctrl,
  shift: shiftKey || pendingModifiers.shift,
  alt: altKey || pendingModifiers.alt,
  meta: metaKey,
);

String? mapTerminalDataToKey(String data) {
  if (data.isEmpty || data.length != 1) return null;
  return switch (data) {
    '\r' || '\n' => 'Enter',
    '\t' => 'Tab',
    '\x7f' || '\b' => 'Backspace',
    '\x1b' => 'Escape',
    _ => data.codeUnitAt(0) >= 0x20 && data.codeUnitAt(0) <= 0x7e ? data : null,
  };
}

sealed class PendingModifierDataResolution {
  const PendingModifierDataResolution({required this.clearPendingModifiers});

  final bool clearPendingModifiers;
}

final class PendingModifierKeyResolution extends PendingModifierDataResolution {
  const PendingModifierKeyResolution({required this.key})
    : super(clearPendingModifiers: true);

  final String key;
}

final class PendingModifierRawResolution extends PendingModifierDataResolution {
  const PendingModifierRawResolution({required super.clearPendingModifiers});
}

PendingModifierDataResolution resolvePendingModifierDataInput({
  required String data,
  required PendingTerminalModifiers pendingModifiers,
}) {
  if (!hasPendingTerminalModifiers(pendingModifiers)) {
    return const PendingModifierRawResolution(clearPendingModifiers: false);
  }
  final mappedKey = mapTerminalDataToKey(data);
  if (mappedKey == null) {
    return const PendingModifierRawResolution(clearPendingModifiers: true);
  }
  return PendingModifierKeyResolution(key: mappedKey);
}
