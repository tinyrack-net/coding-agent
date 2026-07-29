import 'package:coding_agent_app/terminal/terminal_keys.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('terminal key helpers', () {
    test('normalizes supported DOM keys and aliases', () {
      expect(normalizeDomTerminalKey('Esc'), 'Escape');
      expect(normalizeDomTerminalKey('Left'), 'ArrowLeft');
      expect(normalizeDomTerminalKey('Spacebar'), ' ');
      expect(normalizeDomTerminalKey(' '), ' ');
      expect(normalizeDomTerminalKey('ArrowUp'), 'ArrowUp');
      expect(normalizeDomTerminalKey('F12'), 'F12');
    });

    test('filters unsupported and composing DOM keys', () {
      for (final key in [
        '',
        'Dead',
        'Unidentified',
        'Compose',
        'Process',
        'MediaPlayPause',
      ]) {
        expect(normalizeDomTerminalKey(key), isNull);
      }
    });

    test('detects modifiers and lowercases printable transport keys', () {
      expect(isTerminalModifierDomKey('Control'), isTrue);
      expect(isTerminalModifierDomKey('Shift'), isTrue);
      expect(isTerminalModifierDomKey('a'), isFalse);
      expect(normalizeTerminalTransportKey('C'), 'c');
      expect(normalizeTerminalTransportKey('Escape'), 'Escape');
    });

    test('merges pending modifiers with native key modifiers', () {
      final merged = mergeTerminalModifiers(
        pendingModifiers: const PendingTerminalModifiers(ctrl: true, alt: true),
        ctrlKey: false,
        shiftKey: true,
        altKey: false,
        metaKey: false,
      );
      expect(merged.ctrl, isTrue);
      expect(merged.shift, isTrue);
      expect(merged.alt, isTrue);
      expect(merged.meta, isFalse);
    });

    test('pending modifiers always intercept and empty modifiers do not', () {
      expect(
        shouldInterceptDomTerminalKey(
          key: 'Escape',
          ctrlKey: false,
          shiftKey: false,
          altKey: false,
          metaKey: false,
          pendingModifiers: PendingTerminalModifiers.empty,
        ),
        isFalse,
      );
      expect(
        shouldInterceptDomTerminalKey(
          key: 'c',
          ctrlKey: false,
          shiftKey: false,
          altKey: false,
          metaKey: false,
          pendingModifiers: const PendingTerminalModifiers(ctrl: true),
        ),
        isTrue,
      );
    });

    test('modified Enter requires negotiated enhanced input', () {
      for (final modifier in ['ctrl', 'shift', 'alt', 'meta']) {
        bool value(String name) => name == modifier;
        expect(
          shouldInterceptDomTerminalKey(
            key: 'Enter',
            ctrlKey: value('ctrl'),
            shiftKey: value('shift'),
            altKey: value('alt'),
            metaKey: value('meta'),
            pendingModifiers: PendingTerminalModifiers.empty,
          ),
          isFalse,
        );
        expect(
          shouldInterceptDomTerminalKey(
            key: 'Enter',
            ctrlKey: value('ctrl'),
            shiftKey: value('shift'),
            altKey: value('alt'),
            metaKey: value('meta'),
            pendingModifiers: PendingTerminalModifiers.empty,
            enhancedInputActive: true,
          ),
          isTrue,
        );
      }
      expect(
        shouldInterceptDomTerminalKey(
          key: 'Enter',
          ctrlKey: false,
          shiftKey: false,
          altKey: false,
          metaKey: false,
          pendingModifiers: PendingTerminalModifiers.empty,
          enhancedInputActive: true,
        ),
        isFalse,
      );
    });

    test('intercepts only bare Ctrl+C for the iPad xterm quirk', () {
      expect(
        shouldInterceptDomTerminalKey(
          key: 'C',
          ctrlKey: true,
          shiftKey: false,
          altKey: false,
          metaKey: false,
          pendingModifiers: PendingTerminalModifiers.empty,
          isAppleHandheld: true,
        ),
        isTrue,
      );
      for (final input in [
        (key: 'b', shift: false, alt: false, meta: false),
        (key: 'c', shift: true, alt: false, meta: false),
        (key: 'c', shift: false, alt: true, meta: false),
        (key: 'c', shift: false, alt: false, meta: true),
      ]) {
        expect(
          shouldInterceptDomTerminalKey(
            key: input.key,
            ctrlKey: !input.meta,
            shiftKey: input.shift,
            altKey: input.alt,
            metaKey: input.meta,
            pendingModifiers: PendingTerminalModifiers.empty,
            isAppleHandheld: true,
          ),
          isFalse,
        );
      }
      expect(
        shouldInterceptDomTerminalKey(
          key: 'c',
          ctrlKey: true,
          shiftKey: false,
          altKey: false,
          metaKey: false,
          pendingModifiers: PendingTerminalModifiers.empty,
          isAppleHandheld: false,
        ),
        isFalse,
      );
    });

    test('detects Apple handheld platforms including disguised iPadOS', () {
      expect(
        isAppleHandheldPlatform(
          userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_2)',
          platform: 'iPhone',
          maxTouchPoints: 5,
        ),
        isTrue,
      );
      expect(
        isAppleHandheldPlatform(
          userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)',
          platform: 'MacIntel',
          maxTouchPoints: 5,
        ),
        isTrue,
      );
      expect(
        isAppleHandheldPlatform(
          userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)',
          platform: 'MacIntel',
          maxTouchPoints: 1,
        ),
        isFalse,
      );
      expect(isAppleHandheldPlatform(), isFalse);
    });

    test('maps data bytes for pending-modifier fallback', () {
      expect(mapTerminalDataToKey('c'), 'c');
      expect(mapTerminalDataToKey('\r'), 'Enter');
      expect(mapTerminalDataToKey('\t'), 'Tab');
      expect(mapTerminalDataToKey('\x7f'), 'Backspace');
      expect(mapTerminalDataToKey('\x1b'), 'Escape');
      expect(mapTerminalDataToKey('\x03'), isNull);
      expect(mapTerminalDataToKey('hello'), isNull);
      expect(mapTerminalDataToKey(''), isNull);
    });

    test('resolves pending-modifier data and clearing policy', () {
      final key = resolvePendingModifierDataInput(
        data: 'c',
        pendingModifiers: const PendingTerminalModifiers(ctrl: true),
      );
      expect(key, isA<PendingModifierKeyResolution>());
      expect((key as PendingModifierKeyResolution).key, 'c');
      expect(key.clearPendingModifiers, isTrue);

      final unmapped = resolvePendingModifierDataInput(
        data: 'hello',
        pendingModifiers: const PendingTerminalModifiers(ctrl: true),
      );
      expect(unmapped, isA<PendingModifierRawResolution>());
      expect(unmapped.clearPendingModifiers, isTrue);

      final raw = resolvePendingModifierDataInput(
        data: 'c',
        pendingModifiers: PendingTerminalModifiers.empty,
      );
      expect(raw, isA<PendingModifierRawResolution>());
      expect(raw.clearPendingModifiers, isFalse);
    });
  });
}
