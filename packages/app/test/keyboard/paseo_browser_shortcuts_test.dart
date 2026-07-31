import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:coding_agent_app/keyboard/paseo_browser_shortcuts.dart';
import 'package:coding_agent_app/keyboard/shortcut_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lets pending microtasks and zero-duration timers drain, standing in for
/// upstream's `await Promise.resolve()`.
Future<void> flush() => Future<void>.delayed(Duration.zero);

final class _ShiftHost implements KeyboardShiftHost {
  const _ShiftHost({
    this.rawKeyboardHeight = 0,
    this.keyboardProgress = 0,
    this.bottomInset = 0,
    this.isIos = false,
  });

  @override
  final double rawKeyboardHeight;
  @override
  final double keyboardProgress;
  @override
  final double bottomInset;
  @override
  final bool isIos;
}

typedef _RecordedSend = ({
  String sessionId,
  String? text,
  String? binaryBase64,
});

/// Dart analogue of upstream's `createFakeLocalDaemonTransportRpc`: every RPC
/// hangs on a [Completer] the test resolves by hand, so the open/listen race
/// can be driven in either order.
final class _FakeLocalDaemonTransportRpc implements LocalDaemonTransportRpc {
  final openCalls = <LocalTransportTarget>[];
  final recordedSends = <_RecordedSend>[];
  final closedSessions = <String>[];

  Object? sendError;

  Completer<String>? _open;
  Completer<void Function()>? _listen;
  void Function(LocalDaemonTransportEvent event)? _handler;

  @override
  Future<String> openSession(LocalTransportTarget target) {
    openCalls.add(target);
    final completer = Completer<String>();
    _open = completer;
    return completer.future;
  }

  @override
  Future<void Function()> listenToEvents(
    void Function(LocalDaemonTransportEvent event) handler,
  ) {
    _handler = handler;
    final completer = Completer<void Function()>();
    _listen = completer;
    return completer.future;
  }

  @override
  Future<void> sendMessage({
    required String sessionId,
    String? text,
    String? binaryBase64,
  }) async {
    recordedSends.add((
      sessionId: sessionId,
      text: text,
      binaryBase64: binaryBase64,
    ));
    final error = sendError;
    if (error != null) throw error;
  }

  @override
  Future<void> closeSession(String sessionId) async {
    closedSessions.add(sessionId);
  }

  void resolveOpen(String sessionId) => _open!.complete(sessionId);
  void rejectOpen(Object error) => _open!.completeError(error);
  void resolveListen(void Function() cleanup) => _listen!.complete(cleanup);
  void rejectListen(Object error) => _listen!.completeError(error);
  void emitEvent(LocalDaemonTransportEvent event) => _handler?.call(event);
}

const _localUrl = 'paseo+local://socket?path=%2Ftmp%2Fpaseo.sock';

void main() {
  group('buildBrowserKeyboardPolicy', () {
    test('publishes only chord starts while no browser chord is pending', () {
      final bindings = buildEffectiveShortcutBindings({
        'workspace-tab-new-ctrl-t-non-mac': 'Ctrl+Y',
        'workspace-terminal-new-ctrl-shift-t-non-mac': 'Ctrl+F12 Ctrl+F11',
      });

      final policy = buildBrowserKeyboardPolicy(
        bindings: bindings,
        isMac: false,
        isDesktop: true,
      );

      expect(
        policy.prefixes,
        contains(
          const BrowserShortcutPrefix(
            alt: false,
            code: 'KeyY',
            control: true,
            key: 'y',
            meta: false,
            shift: false,
          ),
        ),
      );
      expect(
        policy.prefixes,
        contains(
          const BrowserShortcutPrefix(
            alt: false,
            code: 'F12',
            control: true,
            meta: false,
            shift: false,
          ),
        ),
      );
      expect(policy.prefixes.where((prefix) => prefix.code == 'F11'), isEmpty);
    });

    test('publishes a chord continuation only after its browser start crosses '
        'the boundary', () {
      final bindings = buildEffectiveShortcutBindings({
        'workspace-terminal-new-ctrl-shift-t-non-mac': 'Ctrl+F12 Ctrl+F11',
      });
      final chordIndex = bindings.indexWhere(
        (binding) =>
            binding.id == 'workspace-terminal-new-ctrl-shift-t-non-mac',
      );

      final policy = buildBrowserKeyboardPolicy(
        bindings: bindings,
        chordState: ShortcutChordState(candidateIndices: [chordIndex], step: 1),
        isMac: false,
        isDesktop: true,
      );

      expect(policy.prefixes, [
        const BrowserShortcutPrefix(
          alt: false,
          code: 'F11',
          control: true,
          meta: false,
          shift: false,
        ),
      ]);
      expect(
        policy.menuPrefixes,
        contains(
          const BrowserShortcutPrefix(
            alt: false,
            code: 'KeyW',
            control: true,
            key: 'w',
            meta: false,
            shift: false,
          ),
        ),
      );

      // Upstream passes `focusScope: "browser"` here. This repo's
      // `KeyboardFocusScope` has no `browser` member; `other` is used
      // instead, which is equivalent for this binding because it carries no
      // focus-scope requirement.
      final result = resolveKeyboardShortcut(
        event: const KeyboardShortcutInput(
          key: 'F11',
          code: 'F11',
          altKey: false,
          ctrlKey: true,
          metaKey: false,
          shiftKey: false,
          repeat: false,
        ),
        context: const KeyboardShortcutContext(
          isMac: false,
          isDesktop: true,
          focusScope: KeyboardFocusScope.other,
          commandCenterOpen: false,
        ),
        chordState: ShortcutChordState(candidateIndices: [chordIndex], step: 1),
        onChordReset: () {},
        bindings: bindings,
      );

      expect(result.match?.action, 'workspace.terminal.new');
    });

    test('rejects an entire chord when a continuation cannot cross the browser '
        'boundary', () {
      final bindings = buildEffectiveShortcutBindings({
        'settings-toggle-ctrl-comma-non-mac': 'Ctrl+F10 F9',
      });

      final policy = buildBrowserKeyboardPolicy(
        bindings: bindings,
        isMac: false,
        isDesktop: true,
      );

      expect(policy.prefixes.where((p) => p.code == 'F10'), isEmpty);
      expect(policy.prefixes.where((p) => p.code == 'F9'), isEmpty);
    });

    test('publishes Mod bindings for the current shortcut platform', () {
      final bindings = buildEffectiveShortcutBindings({
        'workspace-tab-new-cmd-t-mac': 'Mod+Y',
      });

      expect(
        buildBrowserKeyboardPolicy(
          bindings: bindings,
          isMac: true,
          isDesktop: true,
        ).prefixes,
        contains(
          const BrowserShortcutPrefix(
            alt: false,
            code: 'KeyY',
            control: false,
            key: 'y',
            meta: true,
            shift: false,
          ),
        ),
      );
    });

    test('resolves Mod to control on non-mac', () {
      final bindings = buildEffectiveShortcutBindings({
        'workspace-tab-new-ctrl-t-non-mac': 'Mod+Y',
      });

      expect(
        buildBrowserKeyboardPolicy(
          bindings: bindings,
          isMac: false,
          isDesktop: true,
        ).prefixes,
        contains(
          const BrowserShortcutPrefix(
            alt: false,
            code: 'KeyY',
            control: true,
            key: 'y',
            meta: false,
            shift: false,
          ),
        ),
      );
    });

    test('keeps Ctrl+W out of the window menu after the tab-close shortcut is '
        'remapped', () {
      final bindings = buildEffectiveShortcutBindings({
        'workspace-tab-close-current-ctrl-w-non-mac': 'Ctrl+Y',
      });

      final policy = buildBrowserKeyboardPolicy(
        bindings: bindings,
        isMac: false,
        isDesktop: true,
      );

      const guard = BrowserShortcutPrefix(
        alt: false,
        code: 'KeyW',
        control: true,
        key: 'w',
        meta: false,
        shift: false,
      );
      expect(policy.prefixes, isNot(contains(guard)));
      expect(policy.menuPrefixes, contains(guard));
    });

    test('leaves macOS browser back and forward shortcuts in the guest', () {
      final bindings = buildEffectiveShortcutBindings({});

      final policy = buildBrowserKeyboardPolicy(
        bindings: bindings,
        isMac: true,
        isDesktop: true,
      );

      // Upstream asserts against literal prefix objects that omit
      // `shiftedKey`, which the real Cmd+[ prefix carries; the assertion is
      // restated as the property it was protecting — no bare Cmd+bracket
      // prefix is published at all.
      expect(
        policy.prefixes.where(
          (prefix) =>
              prefix.meta &&
              !prefix.control &&
              !prefix.alt &&
              !prefix.shift &&
              (prefix.code == 'BracketLeft' || prefix.code == 'BracketRight'),
        ),
        isEmpty,
      );
    });

    test(
      'still claims macOS bracket shortcuts that carry another modifier',
      () {
        final bindings = buildEffectiveShortcutBindings({
          'workspace-navigate-relative-cmd-left-mac': 'Cmd+Shift+[',
        });

        expect(
          buildBrowserKeyboardPolicy(
            bindings: bindings,
            isMac: true,
            isDesktop: true,
          ).prefixes,
          contains(
            const BrowserShortcutPrefix(
              alt: false,
              code: 'BracketLeft',
              control: false,
              key: '[',
              shiftedKey: '{',
              meta: true,
              shift: true,
            ),
          ),
        );
      },
    );

    test(
      'claims Ctrl+bracket on non-mac, where it is not browser navigation',
      () {
        final policy = buildBrowserKeyboardPolicy(
          bindings: buildEffectiveShortcutBindings({}),
          isMac: false,
          isDesktop: true,
        );

        expect(
          policy.prefixes,
          contains(
            const BrowserShortcutPrefix(
              alt: false,
              code: 'BracketLeft',
              control: true,
              key: '[',
              shiftedKey: '{',
              meta: false,
              shift: false,
            ),
          ),
        );
      },
    );

    test('marks editable-only exclusions for enforcement inside the guest', () {
      final policy = buildBrowserKeyboardPolicy(
        bindings: buildEffectiveShortcutBindings({}),
        isMac: true,
        isDesktop: true,
      );

      expect(
        policy.prefixes,
        contains(
          const BrowserShortcutPrefix(
            alt: false,
            code: 'ArrowLeft',
            control: false,
            excludeWhenEditable: true,
            meta: true,
            shift: true,
          ),
        ),
      );
    });

    test('does not publish plain browser keys', () {
      final policy = buildBrowserKeyboardPolicy(
        bindings: buildEffectiveShortcutBindings({}),
        isMac: false,
        isDesktop: true,
      );

      expect(
        policy.prefixes.every(
          (prefix) => prefix.meta || prefix.control || prefix.alt,
        ),
        isTrue,
      );
      expect(policy.prefixes.where((p) => p.code == 'Enter'), isEmpty);
      expect(policy.prefixes.where((p) => p.code == 'Escape'), isEmpty);
    });

    test('publishes Cmd+B with its logical key for non-QWERTY layouts', () {
      final policy = buildBrowserKeyboardPolicy(
        bindings: buildEffectiveShortcutBindings({}),
        isMac: true,
        isDesktop: true,
      );

      expect(
        policy.prefixes,
        contains(
          const BrowserShortcutPrefix(
            alt: false,
            code: 'KeyB',
            control: false,
            key: 'b',
            meta: true,
            shift: false,
          ),
        ),
      );
    });

    test('publishes the physical code needed for macOS Option shortcuts', () {
      final policy = buildBrowserKeyboardPolicy(
        bindings: buildEffectiveShortcutBindings({}),
        isMac: true,
        isDesktop: true,
      );

      expect(
        policy.prefixes,
        contains(
          const BrowserShortcutPrefix(
            alt: true,
            code: 'KeyT',
            control: false,
            key: 't',
            meta: true,
            shift: false,
          ),
        ),
      );
    });

    test('publishes the shifted character alongside the logical key', () {
      final policy = buildBrowserKeyboardPolicy(
        bindings: buildEffectiveShortcutBindings({}),
        isMac: false,
        isDesktop: true,
      );

      expect(
        policy.prefixes,
        contains(
          const BrowserShortcutPrefix(
            alt: false,
            code: 'Comma',
            control: true,
            key: ',',
            shiftedKey: '<',
            meta: false,
            shift: false,
          ),
        ),
      );
    });

    test('publishes the code fallback for layout-unstable keys', () {
      final bindings = buildEffectiveShortcutBindings({
        'command-center-toggle-ctrl-k-non-mac': 'Ctrl+Space',
      });

      expect(
        buildBrowserKeyboardPolicy(
          bindings: bindings,
          isMac: false,
          isDesktop: true,
        ).prefixes,
        contains(
          const BrowserShortcutPrefix(
            alt: false,
            code: 'Space',
            control: true,
            key: ' ',
            codeFallback: true,
            meta: false,
            shift: false,
          ),
        ),
      );
    });

    test('publishes the repeat block for non-repeating bindings', () {
      final policy = buildBrowserKeyboardPolicy(
        bindings: buildEffectiveShortcutBindings({}),
        isMac: false,
        isDesktop: true,
      );

      expect(
        policy.prefixes,
        contains(
          const BrowserShortcutPrefix(
            alt: false,
            code: 'KeyD',
            control: true,
            key: 'd',
            meta: false,
            shift: true,
            blockRepeat: true,
          ),
        ),
      );
    });

    test('never publishes a binding that requires an exact focus scope', () {
      final bindings = buildEffectiveShortcutBindings({
        'shortcuts-dialog-toggle-question-mark': 'Ctrl+F8',
      });

      expect(
        buildBrowserKeyboardPolicy(
          bindings: bindings,
          isMac: false,
          isDesktop: true,
        ).prefixes.where((prefix) => prefix.code == 'F8'),
        isEmpty,
      );
    });

    test('drops desktop-only bindings on web', () {
      final policy = buildBrowserKeyboardPolicy(
        bindings: buildEffectiveShortcutBindings({}),
        isMac: false,
        isDesktop: false,
      );

      expect(
        policy.prefixes,
        isNot(
          contains(
            const BrowserShortcutPrefix(
              alt: false,
              code: 'KeyW',
              control: true,
              key: 'w',
              meta: false,
              shift: false,
            ),
          ),
        ),
      );
      expect(
        policy.prefixes,
        contains(
          const BrowserShortcutPrefix(
            alt: true,
            code: 'KeyW',
            control: false,
            key: 'w',
            meta: false,
            shift: true,
          ),
        ),
      );
    });

    test('collapses identical prefixes from different bindings', () {
      final bindings = buildEffectiveShortcutBindings({
        'workspace-tab-new-ctrl-t-non-mac': 'Ctrl+Y',
        'command-center-toggle-ctrl-k-non-mac': 'Ctrl+Y',
      });

      final policy = buildBrowserKeyboardPolicy(
        bindings: bindings,
        isMac: false,
        isDesktop: true,
      );

      expect(
        policy.prefixes.where((prefix) => prefix.code == 'KeyY'),
        hasLength(1),
      );
    });

    test('treats a step-zero chord state as idle', () {
      final bindings = buildEffectiveShortcutBindings({
        'workspace-terminal-new-ctrl-shift-t-non-mac': 'Ctrl+F12 Ctrl+F11',
      });

      final idle = buildBrowserKeyboardPolicy(
        bindings: bindings,
        isMac: false,
        isDesktop: true,
      );
      final withEmptyChord = buildBrowserKeyboardPolicy(
        bindings: bindings,
        chordState: const ShortcutChordState(candidateIndices: [3]),
        isMac: false,
        isDesktop: true,
      );

      expect(withEmptyChord.prefixes, idle.prefixes);
    });

    test('ignores candidate indices left over from a stale binding list', () {
      final bindings = buildEffectiveShortcutBindings({});

      final policy = buildBrowserKeyboardPolicy(
        bindings: bindings,
        chordState: ShortcutChordState(
          candidateIndices: [-1, bindings.length, bindings.length + 10],
          step: 1,
        ),
        isMac: false,
        isDesktop: true,
      );

      expect(policy.prefixes, isEmpty);
      expect(policy.menuPrefixes, isNotEmpty);
    });

    test(
      'leaves the window menu on the idle policy while a chord is pending',
      () {
        final bindings = buildEffectiveShortcutBindings({
          'workspace-terminal-new-ctrl-shift-t-non-mac': 'Ctrl+F12 Ctrl+F11',
        });
        final chordIndex = bindings.indexWhere(
          (binding) =>
              binding.id == 'workspace-terminal-new-ctrl-shift-t-non-mac',
        );

        final idle = buildBrowserKeyboardPolicy(
          bindings: bindings,
          isMac: false,
          isDesktop: true,
        );
        final pending = buildBrowserKeyboardPolicy(
          bindings: bindings,
          chordState: ShortcutChordState(
            candidateIndices: [chordIndex],
            step: 1,
          ),
          isMac: false,
          isDesktop: true,
        );

        expect(pending.menuPrefixes, idle.menuPrefixes);
        expect(pending.prefixes, isNot(idle.prefixes));
      },
    );

    test('adds no Ctrl+W window-menu guard on macOS', () {
      final policy = buildBrowserKeyboardPolicy(
        bindings: buildEffectiveShortcutBindings({}),
        isMac: true,
        isDesktop: true,
      );

      expect(
        policy.menuPrefixes,
        isNot(
          contains(
            const BrowserShortcutPrefix(
              alt: false,
              code: 'KeyW',
              control: true,
              key: 'w',
              meta: false,
              shift: false,
            ),
          ),
        ),
      );
    });

    test(
      'does not duplicate the guard when a binding already claims Ctrl+W',
      () {
        final policy = buildBrowserKeyboardPolicy(
          bindings: buildEffectiveShortcutBindings({}),
          isMac: false,
          isDesktop: true,
        );

        expect(
          policy.menuPrefixes.where(
            (prefix) =>
                prefix.code == 'KeyW' && prefix.control && !prefix.shift,
          ),
          hasLength(1),
        );
      },
    );

    test('publishes only the guard when there are no bindings at all', () {
      final policy = buildBrowserKeyboardPolicy(
        bindings: const [],
        isMac: false,
        isDesktop: true,
      );

      expect(policy.prefixes, isEmpty);
      expect(policy.menuPrefixes, [
        const BrowserShortcutPrefix(
          alt: false,
          code: 'KeyW',
          control: true,
          key: 'w',
          meta: false,
          shift: false,
        ),
      ]);
    });
  });

  group('BrowserShortcutPrefix.identity', () {
    test('separates prefixes that differ only in an optional marker', () {
      const base = BrowserShortcutPrefix(
        alt: false,
        code: 'KeyT',
        control: true,
        key: 't',
        meta: false,
        shift: false,
      );
      const editable = BrowserShortcutPrefix(
        alt: false,
        code: 'KeyT',
        control: true,
        key: 't',
        meta: false,
        shift: false,
        excludeWhenEditable: true,
      );

      expect(base.identity, 'KeyT:t::::true:false:false:false:');
      expect(editable.identity, isNot(base.identity));
      expect(base == editable, isFalse);
    });
  });

  group('shouldPublishBrowserShortcutPolicy', () {
    test('restores the initial browser policy when a host key resets a '
        'pending chord', () {
      expect(
        shouldPublishBrowserShortcutPolicy(
          isBrowserInput: false,
          previousChordState: const ShortcutChordState(
            candidateIndices: [1],
            step: 1,
          ),
          nextChordState: const ShortcutChordState(),
        ),
        isTrue,
      );
    });

    test('always publishes for input that came from the browser', () {
      expect(
        shouldPublishBrowserShortcutPolicy(
          isBrowserInput: true,
          previousChordState: const ShortcutChordState(),
          nextChordState: const ShortcutChordState(),
        ),
        isTrue,
      );
    });

    test('stays quiet for an unrelated host key while idle', () {
      expect(
        shouldPublishBrowserShortcutPolicy(
          isBrowserInput: false,
          previousChordState: const ShortcutChordState(),
          nextChordState: const ShortcutChordState(),
        ),
        isFalse,
      );
    });

    test('stays quiet while a host chord is still advancing', () {
      expect(
        shouldPublishBrowserShortcutPolicy(
          isBrowserInput: false,
          previousChordState: const ShortcutChordState(
            candidateIndices: [1],
            step: 1,
          ),
          nextChordState: const ShortcutChordState(
            candidateIndices: [1],
            step: 2,
          ),
        ),
        isFalse,
      );
    });

    test('publishes when a host key starts a chord from the browser', () {
      expect(
        shouldPublishBrowserShortcutPolicy(
          isBrowserInput: true,
          previousChordState: const ShortcutChordState(),
          nextChordState: const ShortcutChordState(
            candidateIndices: [2],
            step: 1,
          ),
        ),
        isTrue,
      );
    });
  });

  group('parseBrowserShortcutInput', () {
    Map<String, Object?> payload() => {
      'browserId': 'browser-1',
      'key': 't',
      'code': 'KeyT',
      'meta': false,
      'control': true,
      'shift': false,
      'alt': false,
    };

    test('normalizes browser shortcut input without losing its identity', () {
      expect(
        parseBrowserShortcutInput(payload()),
        const BrowserShortcutInput(
          browserId: 'browser-1',
          key: 't',
          code: 'KeyT',
          metaKey: false,
          ctrlKey: true,
          shiftKey: false,
          altKey: false,
          repeat: false,
        ),
      );
    });

    test('keeps browser identities exact', () {
      final parsed = parseBrowserShortcutInput(
        payload()..['browserId'] = ' browser-1 ',
      );

      expect(parsed?.browserId, ' browser-1 ');
    });

    test('rejects a missing browser identity', () {
      expect(parseBrowserShortcutInput(payload()..remove('browserId')), isNull);
    });

    test('rejects a malformed repeat flag', () {
      expect(parseBrowserShortcutInput(payload()..['repeat'] = 'yes'), isNull);
    });

    test('rejects an explicitly null repeat flag', () {
      expect(parseBrowserShortcutInput(payload()..['repeat'] = null), isNull);
    });

    test('accepts an explicit repeat flag', () {
      expect(
        parseBrowserShortcutInput(payload()..['repeat'] = true)?.repeat,
        isTrue,
      );
    });

    test('rejects an empty browser identity', () {
      expect(parseBrowserShortcutInput(payload()..['browserId'] = ''), isNull);
    });

    test('rejects a non-string browser identity', () {
      expect(parseBrowserShortcutInput(payload()..['browserId'] = 7), isNull);
    });

    for (final field in ['key', 'code']) {
      test('rejects a non-string $field', () {
        expect(parseBrowserShortcutInput(payload()..[field] = 1), isNull);
        expect(parseBrowserShortcutInput(payload()..remove(field)), isNull);
      });
    }

    for (final field in ['alt', 'control', 'meta', 'shift']) {
      test('rejects a non-boolean $field', () {
        expect(parseBrowserShortcutInput(payload()..[field] = 'true'), isNull);
        expect(parseBrowserShortcutInput(payload()..remove(field)), isNull);
      });
    }

    test('rejects payloads that are not records', () {
      expect(parseBrowserShortcutInput(null), isNull);
      expect(parseBrowserShortcutInput(<Object?>[]), isNull);
      expect(parseBrowserShortcutInput('browser-1'), isNull);
      expect(parseBrowserShortcutInput(42), isNull);
      expect(parseBrowserShortcutInput(true), isNull);
    });

    test('ignores unknown fields', () {
      expect(
        parseBrowserShortcutInput(payload()..['unexpected'] = 'ignored'),
        isNotNull,
      );
    });

    test('feeds the shortcut engine without re-declaring the event shape', () {
      final parsed = parseBrowserShortcutInput(payload())!;
      final result = resolveKeyboardShortcut(
        event: parsed.shortcutInput,
        context: const KeyboardShortcutContext(
          isMac: false,
          isDesktop: true,
          focusScope: KeyboardFocusScope.other,
          commandCenterOpen: false,
        ),
        chordState: ShortcutChordState.empty,
        onChordReset: () {},
        bindings: buildEffectiveShortcutBindings({}),
      );

      expect(result.match?.action, 'workspace.tab.new');
    });
  });

  group('resolveKeyboardShift', () {
    test('keeps the existing open-keyboard offset behavior', () {
      expect(
        resolveKeyboardShift(
          rawKeyboardHeight: 320,
          keyboardProgress: 1,
          bottomInset: 24,
          isIos: false,
          iosMinHeight: 120,
        ),
        296,
      );
    });

    test('treats progress zero as closed even when Android reports a stale '
        'height', () {
      expect(
        resolveKeyboardShift(
          rawKeyboardHeight: 320,
          keyboardProgress: 0,
          bottomInset: 24,
          isIos: false,
          iosMinHeight: 120,
        ),
        0,
      );
    });

    test('still ignores small iOS accessory bar reports', () {
      expect(
        resolveKeyboardShift(
          rawKeyboardHeight: 80,
          keyboardProgress: 1,
          bottomInset: 0,
          isIos: true,
          iosMinHeight: 120,
        ),
        0,
      );
    });

    test('keeps an iOS report sitting exactly on the minimum', () {
      expect(
        resolveKeyboardShift(
          rawKeyboardHeight: 120,
          keyboardProgress: 1,
          bottomInset: 0,
          isIos: true,
          iosMinHeight: 120,
        ),
        120,
      );
    });

    test('keeps a small Android report, which has no accessory bar', () {
      expect(
        resolveKeyboardShift(
          rawKeyboardHeight: 80,
          keyboardProgress: 1,
          bottomInset: 0,
          isIos: false,
          iosMinHeight: 120,
        ),
        80,
      );
    });

    test('clamps to zero when the safe-area inset swallows the keyboard', () {
      expect(
        resolveKeyboardShift(
          rawKeyboardHeight: 20,
          keyboardProgress: 1,
          bottomInset: 34,
          isIos: false,
          iosMinHeight: 120,
        ),
        0,
      );
    });

    test('treats a zero height as closed', () {
      expect(
        resolveKeyboardShift(
          rawKeyboardHeight: 0,
          keyboardProgress: 1,
          bottomInset: 0,
          isIos: false,
          iosMinHeight: 120,
        ),
        0,
      );
    });

    test('treats a negative progress as closed', () {
      expect(
        resolveKeyboardShift(
          rawKeyboardHeight: 320,
          keyboardProgress: -0.5,
          bottomInset: 0,
          isIos: false,
          iosMinHeight: 120,
        ),
        0,
      );
    });

    test('treats NaN reports as closed', () {
      expect(
        resolveKeyboardShift(
          rawKeyboardHeight: double.nan,
          keyboardProgress: 1,
          bottomInset: 0,
          isIos: false,
          iosMinHeight: 120,
        ),
        0,
      );
      expect(
        resolveKeyboardShift(
          rawKeyboardHeight: 320,
          keyboardProgress: double.nan,
          bottomInset: 0,
          isIos: false,
          iosMinHeight: 120,
        ),
        0,
      );
    });

    test('reads a negated stored height through its absolute value', () {
      expect(
        resolveKeyboardShiftFor(
          const _ShiftHost(
            rawKeyboardHeight: -320,
            keyboardProgress: 1,
            bottomInset: 24,
          ),
        ),
        296,
      );
    });

    test('applies the shipped iOS minimum by default', () {
      expect(defaultIosKeyboardInsetMinHeight, 120);
      expect(
        resolveKeyboardShiftFor(
          const _ShiftHost(
            rawKeyboardHeight: 119,
            keyboardProgress: 1,
            isIos: true,
          ),
        ),
        0,
      );
    });
  });

  group('resolveKeyboardShiftStyle', () {
    const host = _ShiftHost(
      rawKeyboardHeight: 320,
      keyboardProgress: 1,
      bottomInset: 24,
    );

    test('adds the safe-area inset back in padding mode', () {
      expect(
        resolveKeyboardShiftStyle(host: host, mode: KeyboardShiftMode.padding),
        const KeyboardShiftPaddingStyle(320),
      );
    });

    test('keeps the safe-area inset when the keyboard is closed', () {
      expect(
        resolveKeyboardShiftStyle(
          host: const _ShiftHost(bottomInset: 34),
          mode: KeyboardShiftMode.padding,
        ),
        const KeyboardShiftPaddingStyle(34),
      );
    });

    test('collapses padding to zero when disabled', () {
      expect(
        resolveKeyboardShiftStyle(
          host: host,
          mode: KeyboardShiftMode.padding,
          enabled: false,
        ),
        const KeyboardShiftPaddingStyle(0),
      );
    });

    test('translates upward by the shift alone', () {
      expect(
        resolveKeyboardShiftStyle(
          host: host,
          mode: KeyboardShiftMode.translate,
        ),
        const KeyboardShiftTranslateStyle(-296),
      );
    });

    test('collapses translation to zero when disabled', () {
      expect(
        resolveKeyboardShiftStyle(
          host: host,
          mode: KeyboardShiftMode.translate,
          enabled: false,
        ),
        const KeyboardShiftTranslateStyle(0),
      );
    });
  });

  group('resolveIosKeyboardFrameOverride', () {
    test('stores the iOS end-of-animation frame negated', () {
      expect(
        resolveIosKeyboardFrameOverride(isIos: true, height: 320, progress: 1),
        const KeyboardFrameOverride(height: -320, progress: 1),
      );
    });

    test('leaves non-iOS keyboard values alone', () {
      expect(
        resolveIosKeyboardFrameOverride(isIos: false, height: 320, progress: 1),
        isNull,
      );
    });

    test('round trips back into the shift policy', () {
      final override = resolveIosKeyboardFrameOverride(
        isIos: true,
        height: 320,
        progress: 1,
      )!;

      expect(
        resolveKeyboardShiftFor(
          _ShiftHost(
            rawKeyboardHeight: override.height,
            keyboardProgress: override.progress,
            bottomInset: 24,
            isIos: true,
          ),
        ),
        296,
      );
    });
  });

  group('buildLocalDaemonTransportUrl', () {
    test('encodes a unix socket target', () {
      expect(
        buildLocalDaemonTransportUrl(
          const LocalTransportTarget(
            transportType: LocalTransportType.socket,
            transportPath: '/tmp/paseo.sock',
          ),
        ),
        _localUrl,
      );
    });

    test('encodes a windows named pipe target', () {
      expect(
        buildLocalDaemonTransportUrl(
          const LocalTransportTarget(
            transportType: LocalTransportType.pipe,
            transportPath: r'\\.\pipe\paseo',
          ),
        ),
        r'paseo+local://pipe?path=%5C%5C.%5Cpipe%5Cpaseo',
      );
    });

    test('form-encodes spaces and reserved characters', () {
      expect(
        buildLocalDaemonTransportUrl(
          const LocalTransportTarget(
            transportType: LocalTransportType.socket,
            transportPath: "/a b/c(d)!~'*-._",
          ),
        ),
        "paseo+local://socket?path=%2Fa+b%2Fc%28d%29%21%7E%27*-._",
      );
    });

    test('round trips through the parser', () {
      const target = LocalTransportTarget(
        transportType: LocalTransportType.socket,
        transportPath: '/run/user/1000/paseo daemon.sock',
      );

      expect(
        parseLocalDaemonTransportUrl(buildLocalDaemonTransportUrl(target)),
        target,
      );
    });
  });

  group('parseLocalDaemonTransportUrl', () {
    test('decodes the transport type and path', () {
      expect(
        parseLocalDaemonTransportUrl(_localUrl),
        const LocalTransportTarget(
          transportType: LocalTransportType.socket,
          transportPath: '/tmp/paseo.sock',
        ),
      );
    });

    test('trims surrounding whitespace from the path', () {
      expect(
        parseLocalDaemonTransportUrl(
          'paseo+local://pipe?path=%20%20%5C%5C.%5Cpipe%5Cp%20%20',
        ).transportPath,
        r'\\.\pipe\p',
      );
    });

    test('rejects another scheme', () {
      expect(
        () => parseLocalDaemonTransportUrl('ws://socket?path=%2Ftmp%2Fa.sock'),
        throwsFormatException,
      );
    });

    test('rejects an unknown transport type', () {
      expect(
        () => parseLocalDaemonTransportUrl(
          'paseo+local://tcp?path=%2Ftmp%2Fa.sock',
        ),
        throwsFormatException,
      );
    });

    test('rejects a missing path', () {
      expect(
        () => parseLocalDaemonTransportUrl('paseo+local://socket'),
        throwsFormatException,
      );
    });

    test('rejects a whitespace-only path', () {
      expect(
        () => parseLocalDaemonTransportUrl('paseo+local://socket?path=%20%20'),
        throwsFormatException,
      );
    });
  });

  group('createDesktopLocalDaemonTransportFactory', () {
    test('emits open after the session resolves even if the rust open event '
        'raced earlier', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      var openCount = 0;
      transport.onOpen(() => openCount += 1);

      rpc.emitEvent(
        const LocalDaemonTransportEvent(
          sessionId: 'local-session-1',
          kind: LocalDaemonTransportEventKind.open,
        ),
      );
      expect(openCount, 0);

      rpc.resolveOpen('local-session-1');
      await flush();

      expect(openCount, 1);
    });

    test('cleans up late async setup after the transport is closed', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      var cleanupCount = 0;

      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      transport.close();

      rpc.resolveOpen('local-session-2');
      rpc.resolveListen(() => cleanupCount += 1);
      await flush();

      expect(rpc.closedSessions, ['local-session-2']);
      expect(cleanupCount, 1);
    });

    test('opens the session against the parsed target', () {
      final rpc = _FakeLocalDaemonTransportRpc();
      createDesktopLocalDaemonTransportFactory(rpc)(url: _localUrl);

      expect(rpc.openCalls, [
        const LocalTransportTarget(
          transportType: LocalTransportType.socket,
          transportPath: '/tmp/paseo.sock',
        ),
      ]);
    });

    test('rejects a url that is not a local transport target', () {
      final rpc = _FakeLocalDaemonTransportRpc();
      final factory = createDesktopLocalDaemonTransportFactory(rpc);

      expect(
        () => factory(url: 'wss://example.test/ws'),
        throwsFormatException,
      );
      expect(rpc.openCalls, isEmpty);
    });

    test('emits open only once when the event follows the session', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      var openCount = 0;
      transport.onOpen(() => openCount += 1);

      rpc.resolveOpen('s1');
      await flush();
      rpc.emitEvent(
        const LocalDaemonTransportEvent(
          sessionId: 's1',
          kind: LocalDaemonTransportEventKind.open,
        ),
      );

      expect(openCount, 1);
    });

    test('forwards text frames', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      final received = <Object>[];
      transport.onMessage((message) => received.add(message.data));

      rpc.resolveOpen('s1');
      await flush();
      rpc.emitEvent(
        const LocalDaemonTransportEvent(
          sessionId: 's1',
          kind: LocalDaemonTransportEventKind.message,
          text: '{"type":"hello"}',
        ),
      );

      expect(received, ['{"type":"hello"}']);
    });

    test('decodes binary frames when the text payload is absent', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      final received = <Object>[];
      transport.onMessage((message) => received.add(message.data));

      rpc.resolveOpen('s1');
      await flush();
      rpc.emitEvent(
        LocalDaemonTransportEvent(
          sessionId: 's1',
          kind: LocalDaemonTransportEventKind.message,
          binaryBase64: base64.encode(const [1, 2, 3, 250]),
        ),
      );

      expect(received.single, isA<Uint8List>());
      expect(received.single, [1, 2, 3, 250]);
    });

    test('falls through an empty text frame to the binary payload', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      final received = <Object>[];
      transport.onMessage((message) => received.add(message.data));

      rpc.resolveOpen('s1');
      await flush();
      rpc.emitEvent(
        LocalDaemonTransportEvent(
          sessionId: 's1',
          kind: LocalDaemonTransportEventKind.message,
          text: '',
          binaryBase64: base64.encode(const [9]),
        ),
      );

      expect(received.single, [9]);
    });

    test('drops a message frame carrying neither payload', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      final received = <Object>[];
      transport.onMessage((message) => received.add(message.data));

      rpc.resolveOpen('s1');
      await flush();
      rpc.emitEvent(
        const LocalDaemonTransportEvent(
          sessionId: 's1',
          kind: LocalDaemonTransportEventKind.message,
        ),
      );

      expect(received, isEmpty);
    });

    test('ignores events belonging to another session', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      final received = <Object>[];
      transport.onMessage((message) => received.add(message.data));

      rpc.resolveOpen('s1');
      await flush();
      rpc.emitEvent(
        const LocalDaemonTransportEvent(
          sessionId: 's2',
          kind: LocalDaemonTransportEventKind.message,
          text: 'nope',
        ),
      );

      expect(received, isEmpty);
    });

    test('ignores events that arrive before the session id is known', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      final received = <Object>[];
      transport.onMessage((message) => received.add(message.data));

      rpc.emitEvent(
        const LocalDaemonTransportEvent(
          sessionId: 's1',
          kind: LocalDaemonTransportEventKind.message,
          text: 'early',
        ),
      );
      rpc.resolveOpen('s1');
      await flush();

      expect(received, isEmpty);
    });

    test('forwards close events with their payload', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      final closes = <Object?>[];
      transport.onClose(closes.add);

      rpc.resolveOpen('s1');
      await flush();
      const event = LocalDaemonTransportEvent(
        sessionId: 's1',
        kind: LocalDaemonTransportEventKind.close,
        code: 1006,
        reason: 'peer went away',
      );
      rpc.emitEvent(event);

      expect(closes, [same(event)]);
    });

    test('reports the error payload verbatim', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      final errors = <Object?>[];
      transport.onError(errors.add);

      rpc.resolveOpen('s1');
      await flush();
      rpc.emitEvent(
        const LocalDaemonTransportEvent(
          sessionId: 's1',
          kind: LocalDaemonTransportEventKind.error,
          error: 'ECONNREFUSED',
        ),
      );

      expect(errors, ['ECONNREFUSED']);
    });

    test(
      'substitutes a default message for an errorless error event',
      () async {
        final rpc = _FakeLocalDaemonTransportRpc();
        final transport = createDesktopLocalDaemonTransportFactory(rpc)(
          url: _localUrl,
        );

        final errors = <Object?>[];
        transport.onError(errors.add);

        rpc.resolveOpen('s1');
        await flush();
        rpc.emitEvent(
          const LocalDaemonTransportEvent(
            sessionId: 's1',
            kind: LocalDaemonTransportEventKind.error,
          ),
        );

        expect(errors, ['Local daemon transport error']);
      },
    );

    test('drops sends issued before the session opens', () {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      transport.send('early');

      expect(rpc.recordedSends, isEmpty);
    });

    test('sends text frames as text', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      rpc.resolveOpen('s1');
      await flush();
      transport.send('ping');

      expect(rpc.recordedSends, [
        (sessionId: 's1', text: 'ping', binaryBase64: null),
      ]);
    });

    test('sends binary frames as base64', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      rpc.resolveOpen('s1');
      await flush();
      transport.send(Uint8List.fromList(const [0, 255, 16]));
      transport.send(const <int>[1, 2]);

      expect(rpc.recordedSends, [
        (
          sessionId: 's1',
          text: null,
          binaryBase64: base64.encode(const [0, 255, 16]),
        ),
        (
          sessionId: 's1',
          text: null,
          binaryBase64: base64.encode(const [1, 2]),
        ),
      ]);
    });

    test('rejects a frame that is neither text nor bytes', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      rpc.resolveOpen('s1');
      await flush();

      expect(() => transport.send(42), throwsArgumentError);
    });

    test('routes a failed send to the error handlers', () async {
      final rpc = _FakeLocalDaemonTransportRpc()
        ..sendError = StateError('boom');
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      final errors = <Object?>[];
      transport.onError(errors.add);

      rpc.resolveOpen('s1');
      await flush();
      transport.send('ping');
      await flush();

      expect(errors.single, isA<StateError>());
    });

    test('closes the session and runs the subscription cleanup', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      var cleanupCount = 0;
      rpc.resolveListen(() => cleanupCount += 1);
      rpc.resolveOpen('s1');
      await flush();

      transport.close(1000, 'bye');
      await flush();

      expect(rpc.closedSessions, ['s1']);
      expect(cleanupCount, 1);

      // Idempotent: the second close has no session left to close and no
      // cleanup left to run.
      transport.close();
      await flush();
      expect(rpc.closedSessions, ['s1']);
      expect(cleanupCount, 1);
    });

    test('stops delivering events once closed', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      final received = <Object>[];
      transport.onMessage((message) => received.add(message.data));

      rpc.resolveListen(() {});
      rpc.resolveOpen('s1');
      await flush();
      transport.close();

      rpc.emitEvent(
        const LocalDaemonTransportEvent(
          sessionId: 's1',
          kind: LocalDaemonTransportEventKind.message,
          text: 'late',
        ),
      );

      expect(received, isEmpty);
    });

    test('drops sends issued after close', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      rpc.resolveOpen('s1');
      await flush();
      transport.close();
      transport.send('late');

      expect(rpc.recordedSends, isEmpty);
    });

    test('unsubscribing stops delivery to that handler alone', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      final first = <Object>[];
      final second = <Object>[];
      final unsubscribe = transport.onMessage((m) => first.add(m.data));
      transport.onMessage((m) => second.add(m.data));

      rpc.resolveOpen('s1');
      await flush();
      unsubscribe();
      rpc.emitEvent(
        const LocalDaemonTransportEvent(
          sessionId: 's1',
          kind: LocalDaemonTransportEventKind.message,
          text: 'after',
        ),
      );

      expect(first, isEmpty);
      expect(second, ['after']);
    });

    test('unsubscribing an open handler before the session resolves', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      var openCount = 0;
      transport.onOpen(() => openCount += 1)();

      rpc.resolveOpen('s1');
      await flush();

      expect(openCount, 0);
    });

    test('reports a failed openSession', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      final errors = <Object?>[];
      transport.onError(errors.add);

      rpc.rejectOpen(StateError('no socket'));
      await flush();

      expect(errors.single, isA<StateError>());
    });

    test('reports a failed listenToEvents subscription', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      final errors = <Object?>[];
      transport.onError(errors.add);

      rpc.rejectListen(StateError('no bridge'));
      await flush();

      expect(errors.single, isA<StateError>());
    });

    test('suppresses open once the transport is already disposed', () async {
      final rpc = _FakeLocalDaemonTransportRpc();
      final transport = createDesktopLocalDaemonTransportFactory(rpc)(
        url: _localUrl,
      );

      var openCount = 0;
      transport.onOpen(() => openCount += 1);
      transport.close();

      rpc.resolveOpen('s1');
      await flush();

      expect(openCount, 0);
    });
  });
}
