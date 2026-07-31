/// Port of three frozen Paseo 0.2.0 modules that all answer the same shape of
/// question — "what does the host have to hand a *guest* runtime so the guest
/// behaves like the host?" — for three different guests:
///
/// * `keyboard/browser-shortcuts.ts` — the keyboard policy the desktop shell
///   publishes into an embedded browser view. The guest owns the real key
///   events, so the host cannot match shortcuts itself; it instead ships a list
///   of modifier *prefixes* the guest must forward back across the boundary.
///   Only chord steps that are actually reachable are published, so the guest
///   swallows as little as possible.
/// * `hooks/keyboard-shift-policy.ts` plus the pure core of
///   `hooks/use-keyboard-shift-style.ts` — how far a layout lifts for the
///   on-screen keyboard, given the raw numbers the platform reports.
/// * `desktop/daemon/desktop-daemon-transport.ts` — the `paseo+local://`
///   transport that carries daemon traffic over a Unix socket or a Windows
///   named pipe instead of a WebSocket, driven entirely through an injected RPC
///   port.
///
/// What this library deliberately does *not* re-port, because the repo already
/// has it:
///
/// * Shortcut parsing, binding definitions, chord state and context matching
///   all come from `shortcut_engine.dart`. [buildBrowserKeyboardPolicy] takes
///   that file's [ShortcutBinding]/[ShortcutChordState]/[ShortcutWhen] types
///   directly and reads `parsedChord` off them.
/// * Shortcut *display* strings belong to `formatShortcut` in
///   `core/paseo_ui_utils.dart`. Nothing here formats anything.
///
/// Everything below is pure or takes its side effects through a narrow injected
/// interface ([LocalDaemonTransportRpc], [KeyboardShiftHost]), so the whole
/// library is exercisable with no `dart:io`, no plugins and no widget tree.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'shortcut_engine.dart';

// ---------------------------------------------------------------------------
// keyboard/browser-shortcuts.ts
// ---------------------------------------------------------------------------

/// One modifier prefix the embedded browser view must forward to the host.
///
/// Upstream models the optional fields as *presence* of a single constant —
/// `codeFallback?: true`, `editable?: false`, `repeat?: false` — so "absent"
/// and "the other boolean" are the same state. Dart has no way to express a
/// one-valued optional, so each collapses to a plain `bool`, which is an exact
/// isomorphism: [codeFallback] true means upstream's `codeFallback: true` was
/// present, [excludeWhenEditable] true means upstream's `editable: false` was
/// present, [blockRepeat] true means upstream's `repeat: false` was present.
/// The renames exist because a bare `editable: false` / `repeat: false` reads
/// backwards once it is a real boolean field.
final class BrowserShortcutPrefix {
  const BrowserShortcutPrefix({
    required this.alt,
    required this.code,
    required this.control,
    required this.meta,
    required this.shift,
    this.codeFallback = false,
    this.excludeWhenEditable = false,
    this.key,
    this.blockRepeat = false,
    this.shiftedKey,
  });

  /// Physical key code (`"KeyT"`, `"F12"`, `"ArrowLeft"`).
  ///
  /// Always published, because macOS rewrites the logical key when Option is
  /// held and the guest can only recognise those bindings by code.
  final String code;

  /// Logical key (`"t"`, `"["`), published when the binding has one so
  /// non-QWERTY layouts still match by character rather than by position.
  final String? key;

  /// The character the same physical key produces with Shift held.
  final String? shiftedKey;

  /// The guest may fall back to matching [code] when the logical key does not
  /// match — set for keys whose `key` value is unstable across layouts
  /// (`Space`, `Enter`).
  final bool codeFallback;

  /// The host binding is disabled while a text-editing surface is focused, so
  /// the guest must enforce that itself rather than forwarding blindly.
  final bool excludeWhenEditable;

  /// The host binding ignores auto-repeat, so repeats must not be forwarded.
  final bool blockRepeat;

  final bool control;
  final bool meta;
  final bool alt;
  final bool shift;

  /// Upstream's `prefixKey()`: the string identity used to de-duplicate
  /// prefixes and to decide whether the Ctrl+W window-menu guard is already
  /// covered.
  ///
  /// Reproduced character for character — including JS's `false` -> `"false"`
  /// stringification and the `?? ""` holes for absent optionals — because it is
  /// the exact key upstream's `Map` is built on.
  String get identity => <String>[
    code,
    key ?? '',
    shiftedKey ?? '',
    codeFallback ? 'true' : '',
    excludeWhenEditable ? 'false' : '',
    '$control',
    '$meta',
    '$alt',
    '$shift',
    blockRepeat ? 'false' : '',
  ].join(':');

  /// Field-wise equality, matching the structural comparison upstream's suite
  /// asserts with.
  ///
  /// Note this is a *different* notion from [identity]: upstream de-duplicates
  /// on the joined string but compares prefixes structurally in tests. The two
  /// only diverge if a `code`/`key` value contained a colon, which no entry in
  /// the shortcut key map does. Both notions are kept separate rather than
  /// unified so neither silently changes.
  @override
  bool operator ==(Object other) =>
      other is BrowserShortcutPrefix &&
      other.code == code &&
      other.key == key &&
      other.shiftedKey == shiftedKey &&
      other.codeFallback == codeFallback &&
      other.excludeWhenEditable == excludeWhenEditable &&
      other.blockRepeat == blockRepeat &&
      other.control == control &&
      other.meta == meta &&
      other.alt == alt &&
      other.shift == shift;

  @override
  int get hashCode => Object.hash(
    code,
    key,
    shiftedKey,
    codeFallback,
    excludeWhenEditable,
    blockRepeat,
    control,
    meta,
    alt,
    shift,
  );

  @override
  String toString() =>
      'BrowserShortcutPrefix(code: $code, key: $key, shiftedKey: $shiftedKey, '
      'codeFallback: $codeFallback, excludeWhenEditable: $excludeWhenEditable, '
      'blockRepeat: $blockRepeat, control: $control, meta: $meta, alt: $alt, '
      'shift: $shift)';
}

/// A key event forwarded back out of the embedded browser view.
///
/// Upstream declares `interface BrowserShortcutInput extends
/// KeyboardShortcutInput`. `KeyboardShortcutInput` in `shortcut_engine.dart` is
/// a `final class`, which Dart forbids extending from another library, so the
/// fields are restated here and [shortcutInput] rebuilds the engine's value.
/// That keeps the engine as the single owner of shortcut matching.
final class BrowserShortcutInput {
  const BrowserShortcutInput({
    required this.browserId,
    required this.key,
    required this.code,
    required this.altKey,
    required this.ctrlKey,
    required this.metaKey,
    required this.shiftKey,
    required this.repeat,
  });

  /// Which embedded view sent the event. Never normalised — see
  /// [parseBrowserShortcutInput].
  final String browserId;

  final String key;
  final String code;
  final bool altKey;
  final bool ctrlKey;
  final bool metaKey;
  final bool shiftKey;
  final bool repeat;

  /// The same event in the shape `resolveKeyboardShortcut` expects.
  KeyboardShortcutInput get shortcutInput => KeyboardShortcutInput(
    key: key,
    code: code,
    altKey: altKey,
    ctrlKey: ctrlKey,
    metaKey: metaKey,
    shiftKey: shiftKey,
    repeat: repeat,
  );

  @override
  bool operator ==(Object other) =>
      other is BrowserShortcutInput &&
      other.browserId == browserId &&
      other.key == key &&
      other.code == code &&
      other.altKey == altKey &&
      other.ctrlKey == ctrlKey &&
      other.metaKey == metaKey &&
      other.shiftKey == shiftKey &&
      other.repeat == repeat;

  @override
  int get hashCode => Object.hash(
    browserId,
    key,
    code,
    altKey,
    ctrlKey,
    metaKey,
    shiftKey,
    repeat,
  );

  @override
  String toString() =>
      'BrowserShortcutInput(browserId: $browserId, key: $key, code: $code, '
      'altKey: $altKey, ctrlKey: $ctrlKey, metaKey: $metaKey, '
      'shiftKey: $shiftKey, repeat: $repeat)';
}

/// What the host publishes into an embedded browser view.
///
/// [prefixes] is what the guest must intercept *right now* — it narrows to a
/// single continuation while a chord is pending. [menuPrefixes] is the
/// steady-state set used to build the native window menu, so it always
/// describes the idle policy regardless of chord state; a menu that flickered
/// mid-chord would be worse than one that is momentarily over-broad.
final class BrowserKeyboardPolicy {
  const BrowserKeyboardPolicy({
    required this.menuPrefixes,
    required this.prefixes,
  });

  final List<BrowserShortcutPrefix> menuPrefixes;
  final List<BrowserShortcutPrefix> prefixes;
}

/// Whether a freshly computed policy is worth pushing to the guest.
///
/// Republish on every key that came *from* the browser, and additionally when a
/// host key collapsed a pending chord back to idle — otherwise the guest would
/// stay stuck on the narrow mid-chord policy that the host has already
/// abandoned.
bool shouldPublishBrowserShortcutPolicy({
  required bool isBrowserInput,
  required ShortcutChordState nextChordState,
  required ShortcutChordState previousChordState,
}) =>
    isBrowserInput || (previousChordState.step > 0 && nextChordState.step == 0);

/// Decodes an untrusted key-event payload arriving from an embedded browser
/// view, or null when it is not a well-formed event.
///
/// Deliberately strict: every modifier must be a real boolean and both `code`
/// and `key` must be present, because a half-decoded event would silently
/// mismatch bindings rather than fail loudly. `repeat` is the one optional
/// field and defaults to false.
///
/// Deviations from the JS predicate, all reproducing observable behaviour:
///
/// * `isRecord` upstream is `typeof value === "object" && value !== null &&
///   !Array.isArray(value)`. Dart's `Map` test covers exactly the accepted set;
///   a `List` is not a `Map`, so arrays are rejected as upstream rejects them.
/// * `value.repeat !== undefined` cannot be spelled with a plain lookup in
///   Dart, since an absent key and an explicit null both read as null. The
///   check uses `containsKey`, so `{"repeat": null}` is rejected (JS: `null` is
///   not `undefined` and not a boolean) while an absent key is accepted.
/// * [browserId] is checked for emptiness rather than truthiness; the only
///   falsy string is `""`, so this is the same test.
BrowserShortcutInput? parseBrowserShortcutInput(Object? value) {
  if (value is! Map) return null;
  final record = value;

  final browserId = record['browserId'];
  if (browserId is! String || browserId.isEmpty) return null;

  final code = record['code'];
  final key = record['key'];
  if (code is! String || key is! String) return null;

  final alt = record['alt'];
  final control = record['control'];
  final meta = record['meta'];
  final shift = record['shift'];
  if (alt is! bool || control is! bool || meta is! bool || shift is! bool) {
    return null;
  }
  if (record.containsKey('repeat') && record['repeat'] is! bool) return null;

  return BrowserShortcutInput(
    browserId: browserId,
    key: key,
    code: code,
    altKey: alt,
    ctrlKey: control,
    metaKey: meta,
    shiftKey: shift,
    repeat: record['repeat'] as bool? ?? false,
  );
}

/// Upstream `prefixFromCombo`.
///
/// Returns null for a combo with no modifier at all: a bare key is the guest's
/// own business (typing, its own find bar) and forwarding it would make the
/// embedded view unusable.
///
/// `Mod` resolves here rather than in the guest, because the guest is told what
/// to intercept, not how to interpret the host's platform.
///
/// Deviation: upstream guards `combo.key` and `combo.shiftedKey` with
/// truthiness, so an empty string would be dropped. `shortcut_engine.dart`
/// models both as `String?` and never produces an empty one, but the
/// `isNotEmpty` test is kept so the behaviour is identical if it ever does.
BrowserShortcutPrefix? _prefixFromCombo(
  ShortcutKeyCombo combo,
  bool isMac, {
  required bool excludeWhenEditable,
}) {
  final control = combo.ctrl || (!isMac && combo.mod);
  final meta = combo.meta || (isMac && combo.mod);
  final alt = combo.alt;
  if (!meta && !control && !alt) return null;

  final key = combo.key;
  final shiftedKey = combo.shiftedKey;
  return BrowserShortcutPrefix(
    alt: alt,
    code: combo.code,
    control: control,
    meta: meta,
    shift: combo.shift,
    codeFallback: combo.codeFallback,
    excludeWhenEditable: excludeWhenEditable,
    key: key != null && key.isNotEmpty ? key : null,
    // `ShortcutKeyCombo.allowRepeat` is the inverse of upstream's
    // `repeat?: false`, so an unset `allowRepeat` publishes nothing.
    blockRepeat: !combo.allowRepeat,
    shiftedKey: shiftedKey != null && shiftedKey.isNotEmpty ? shiftedKey : null,
  );
}

/// Cmd+[ and Cmd+] on macOS are the browser's own back/forward.
///
/// Claiming them for workspace navigation would strand the user inside the
/// embedded view with no way back, so those two exact prefixes stay in the
/// guest. The match is deliberately narrow — any extra modifier makes it a
/// different, safe-to-claim shortcut.
bool _isBrowserNativeNavigationPrefix(
  BrowserShortcutPrefix prefix,
  bool isMac,
) =>
    isMac &&
    prefix.meta &&
    !prefix.control &&
    !prefix.alt &&
    !prefix.shift &&
    (prefix.code == 'BracketLeft' || prefix.code == 'BracketRight');

/// Whether *every* step of a chord is safe to claim from the guest.
///
/// All-or-nothing on purpose: publishing a chord start whose continuation the
/// guest will never forward would swallow the first keystroke and then leave
/// the user in a chord that can never complete.
bool _canCrossBrowserBoundary(ShortcutBinding binding, bool isMac) {
  final excludeWhenEditable = _excludesEditable(binding.when);
  return binding.parsedChord.every((combo) {
    final prefix = _prefixFromCombo(
      combo,
      isMac,
      excludeWhenEditable: excludeWhenEditable,
    );
    return prefix != null && !_isBrowserNativeNavigationPrefix(prefix, isMac);
  });
}

/// Upstream reads `binding.when?.editable`, whose only non-undefined value is
/// `false`. `ShortcutWhen.allowEditable` is the inverted boolean, defaulting to
/// true, so "upstream had `editable: false`" is "`allowEditable` is false".
bool _excludesEditable(ShortcutWhen? when) =>
    when != null && !when.allowEditable;

/// `matchesKeyboardShortcutContext` specialised to the browser focus scope.
///
/// Deviation, and the one real gap between this repo and upstream: upstream's
/// `KeyboardFocusScope` union has six members (`terminal`, `message-input`,
/// `command-center`, `editable`, `browser`, `other`) while this repo's enum in
/// `shortcut_engine.dart` has four and is missing `browser`. Rather than widen
/// a shared enum, the browser-scope case is decided here, and it collapses to
/// something simpler than the general matcher:
///
/// * the editable and terminal guards never fire, because `browser` is neither;
/// * the command-center guard never fires, because the policy is always built
///   with the command center closed (an open command center owns the keyboard,
///   so there is no browser policy to publish);
/// * an exact `focusScope` requirement can never be satisfied, because no
///   binding asks for the browser scope. Hence the unconditional reject.
bool _matchesBrowserScopeContext(
  ShortcutWhen? when, {
  required bool isMac,
  required bool isDesktop,
}) {
  if (when == null) return true;
  if (when.mac != null && when.mac != isMac) return false;
  if (when.desktop != null && when.desktop != isDesktop) return false;
  if (when.focusScope != null) return false;
  return true;
}

/// Upstream `buildBrowserShortcutPrefixes`.
///
/// De-duplicates on [BrowserShortcutPrefix.identity] while preserving binding
/// order, exactly as upstream's insertion-ordered `Map` does.
List<BrowserShortcutPrefix> _buildBrowserShortcutPrefixes({
  required List<ShortcutBinding> bindings,
  required bool isMac,
  required bool isDesktop,
  ShortcutChordState? chordState,
}) {
  final prefixes = <String, BrowserShortcutPrefix>{};

  final pending = chordState != null && chordState.step > 0;
  final candidates = pending
      ? chordState.candidateIndices
      : List<int>.generate(bindings.length, (index) => index);
  final step = chordState?.step ?? 0;

  for (final index in candidates) {
    // Upstream reads `input.bindings[index]`, which is `undefined` for an index
    // left over from a stale binding list and is skipped.
    if (index < 0 || index >= bindings.length) continue;
    final binding = bindings[index];
    if (!_matchesBrowserScopeContext(
      binding.when,
      isMac: isMac,
      isDesktop: isDesktop,
    )) {
      continue;
    }
    if (!_canCrossBrowserBoundary(binding, isMac)) continue;
    if (step < 0 || step >= binding.parsedChord.length) continue;
    final prefix = _prefixFromCombo(
      binding.parsedChord[step],
      isMac,
      excludeWhenEditable: _excludesEditable(binding.when),
    );
    if (prefix == null) continue;
    prefixes[prefix.identity] = prefix;
  }

  return prefixes.values.toList();
}

/// The Ctrl+W the non-mac window menu must keep claiming.
///
/// Windows and Linux close the window on Ctrl+W at the shell level. Even when
/// the user has remapped Paseo's close-tab shortcut away from Ctrl+W, the menu
/// entry has to stay bound so the accelerator is consumed by the app rather
/// than closing the whole window out from under an embedded view.
const _closeWindowGuard = BrowserShortcutPrefix(
  alt: false,
  code: 'KeyW',
  control: true,
  key: 'w',
  meta: false,
  shift: false,
);

/// Builds the full keyboard policy for an embedded browser view.
///
/// [chordState] is optional and only narrows [BrowserKeyboardPolicy.prefixes]
/// once a chord is actually pending (`step > 0`); a step-zero state is
/// indistinguishable from idle.
BrowserKeyboardPolicy buildBrowserKeyboardPolicy({
  required List<ShortcutBinding> bindings,
  required bool isMac,
  required bool isDesktop,
  ShortcutChordState? chordState,
}) {
  final idlePrefixes = _buildBrowserShortcutPrefixes(
    bindings: bindings,
    isMac: isMac,
    isDesktop: isDesktop,
  );
  final prefixes = chordState != null && chordState.step > 0
      ? _buildBrowserShortcutPrefixes(
          bindings: bindings,
          isMac: isMac,
          isDesktop: isDesktop,
          chordState: chordState,
        )
      : List<BrowserShortcutPrefix>.of(idlePrefixes);

  final menuPrefixes = List<BrowserShortcutPrefix>.of(idlePrefixes);
  if (!isMac &&
      !menuPrefixes.any(
        (prefix) => prefix.identity == _closeWindowGuard.identity,
      )) {
    menuPrefixes.add(_closeWindowGuard);
  }

  return BrowserKeyboardPolicy(menuPrefixes: menuPrefixes, prefixes: prefixes);
}

// ---------------------------------------------------------------------------
// hooks/keyboard-shift-policy.ts + hooks/use-keyboard-shift-style.ts
// ---------------------------------------------------------------------------

/// Below this many logical pixels an iOS keyboard report is assumed to be the
/// accessory / prediction bar rather than a real keyboard.
const double defaultIosKeyboardInsetMinHeight = 120;

/// The numbers the platform reports about the on-screen keyboard.
///
/// A narrow port so the shift policy can be evaluated with no
/// `react-native-keyboard-controller`, no safe-area provider and no widget
/// tree. Implementations read from whatever the real host offers.
abstract interface class KeyboardShiftHost {
  /// Keyboard height as reported, before any sign or threshold handling.
  ///
  /// Upstream stores this negated in a shared value and applies `Math.abs`
  /// at the read site; [resolveKeyboardShiftFor] does the same, so an
  /// implementation may report either sign.
  double get rawKeyboardHeight;

  /// Open-ness of the keyboard, 0 (closed) through 1 (fully open).
  double get keyboardProgress;

  /// Safe-area inset at the bottom of the window.
  double get bottomInset;

  /// Whether the host is iOS, which is the only platform that reports the
  /// accessory bar as a keyboard.
  bool get isIos;
}

/// How much a layout must move to clear the on-screen keyboard.
///
/// Two independent "the keyboard is closed" signals are honoured because
/// neither is reliable alone: Android keeps reporting a stale height after the
/// keyboard closes (so progress must win), and iOS reports a small height for
/// the accessory bar while the keyboard is genuinely open (so height must win).
///
/// Deviation: upstream writes the guards as `!(x > 0)` rather than `x <= 0`,
/// which additionally catches NaN. That form is preserved verbatim, and it
/// behaves identically on Dart doubles — a NaN height or progress yields 0
/// rather than propagating.
double resolveKeyboardShift({
  required double rawKeyboardHeight,
  required double keyboardProgress,
  required double bottomInset,
  required bool isIos,
  required double iosMinHeight,
}) {
  if (!(keyboardProgress > 0) || !(rawKeyboardHeight > 0)) return 0;

  // iOS can report a small accessory/prediction bar height during touch focus.
  // Treat that as non-keyboard so layouts don't "bounce" while interacting.
  if (isIos && rawKeyboardHeight < iosMinHeight) return 0;

  return math.max(0, rawKeyboardHeight - bottomInset);
}

/// [resolveKeyboardShift] fed from a [KeyboardShiftHost], mirroring upstream's
/// `useDerivedValue` body — including the `Math.abs` on the stored height.
double resolveKeyboardShiftFor(KeyboardShiftHost host) => resolveKeyboardShift(
  rawKeyboardHeight: host.rawKeyboardHeight.abs(),
  keyboardProgress: host.keyboardProgress,
  bottomInset: host.bottomInset,
  isIos: host.isIos,
  iosMinHeight: defaultIosKeyboardInsetMinHeight,
);

/// How a surface reacts to the keyboard.
///
/// `padding` grows the surface from the bottom (used when content must stay
/// scrollable above the keyboard); `translate` slides the whole surface up
/// (used when it must stay pinned to the keyboard).
enum KeyboardShiftMode { translate, padding }

/// The resolved style, as a closed union rather than upstream's structural
/// `ViewStyle` — the two modes never produce overlapping properties, so a union
/// is both smaller and impossible to misread.
sealed class KeyboardShiftStyle {
  const KeyboardShiftStyle();
}

/// Upstream `{ paddingBottom }`.
final class KeyboardShiftPaddingStyle extends KeyboardShiftStyle {
  const KeyboardShiftPaddingStyle(this.paddingBottom);

  final double paddingBottom;

  @override
  bool operator ==(Object other) =>
      other is KeyboardShiftPaddingStyle &&
      other.paddingBottom == paddingBottom;

  @override
  int get hashCode => paddingBottom.hashCode;

  @override
  String toString() => 'KeyboardShiftPaddingStyle($paddingBottom)';
}

/// Upstream `{ transform: [{ translateY }] }`.
final class KeyboardShiftTranslateStyle extends KeyboardShiftStyle {
  const KeyboardShiftTranslateStyle(this.translateY);

  final double translateY;

  @override
  bool operator ==(Object other) =>
      other is KeyboardShiftTranslateStyle && other.translateY == translateY;

  @override
  int get hashCode => translateY.hashCode;

  @override
  String toString() => 'KeyboardShiftTranslateStyle($translateY)';
}

/// Pure core of upstream's `useKeyboardShiftStyle`.
///
/// Note the asymmetry between the modes, which is intentional upstream and is
/// preserved: padding mode adds the safe-area bottom inset on top of the shift
/// so content clears the home indicator even with no keyboard, while translate
/// mode moves by the shift alone — translating by the inset would lift a pinned
/// surface off the bottom of the screen.
///
/// Disabling collapses each mode to its own neutral value (zero padding, zero
/// translation) rather than to a shared "no style", because a padding surface
/// with the style removed would reflow differently from one padded to zero.
KeyboardShiftStyle resolveKeyboardShiftStyle({
  required KeyboardShiftHost host,
  required KeyboardShiftMode mode,
  bool enabled = true,
}) {
  final shift = resolveKeyboardShiftFor(host);
  if (mode == KeyboardShiftMode.padding) {
    if (!enabled) return const KeyboardShiftPaddingStyle(0);
    return KeyboardShiftPaddingStyle(host.bottomInset + shift);
  }
  return KeyboardShiftTranslateStyle(enabled ? -shift : 0);
}

/// The keyboard frame values an iOS `onEnd` event overrides.
final class KeyboardFrameOverride {
  const KeyboardFrameOverride({required this.height, required this.progress});

  /// Stored negated, exactly as upstream writes `keyboardHeight.value =
  /// -event.height`. [resolveKeyboardShiftFor] takes the absolute value again.
  final double height;
  final double progress;

  @override
  bool operator ==(Object other) =>
      other is KeyboardFrameOverride &&
      other.height == height &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(height, progress);

  @override
  String toString() =>
      'KeyboardFrameOverride(height: $height, '
      'progress: $progress)';
}

/// Upstream's `useGenericKeyboardHandler({ onEnd })` body, as a pure decision.
///
/// iOS's animated keyboard values settle late, so the final frame is written
/// straight from the end-of-animation event. Android's values are already
/// correct, and overwriting them would fight the animation — hence null on
/// every non-iOS host.
KeyboardFrameOverride? resolveIosKeyboardFrameOverride({
  required bool isIos,
  required double height,
  required double progress,
}) {
  if (!isIos) return null;
  return KeyboardFrameOverride(height: -height, progress: progress);
}

// ---------------------------------------------------------------------------
// desktop/daemon/desktop-daemon-transport.ts
// ---------------------------------------------------------------------------

const String _localTransportScheme = 'paseo+local';

/// Which local IPC primitive the daemon is listening on.
///
/// Upstream's `"socket" | "pipe"` union; Unix domain socket versus Windows
/// named pipe. Both are addressed by a path, which is why they share a target
/// type instead of being separate transports.
enum LocalTransportType {
  socket('socket'),
  pipe('pipe');

  const LocalTransportType(this.wireName);

  /// The value that appears as the URL host.
  final String wireName;

  /// Null for anything outside the union, matching upstream's explicit
  /// `transportType !== "socket" && transportType !== "pipe"` rejection.
  static LocalTransportType? fromWireName(String value) => switch (value) {
    'socket' => LocalTransportType.socket,
    'pipe' => LocalTransportType.pipe,
    _ => null,
  };
}

/// Where a locally running daemon can be reached.
final class LocalTransportTarget {
  const LocalTransportTarget({
    required this.transportType,
    required this.transportPath,
  });

  final LocalTransportType transportType;
  final String transportPath;

  @override
  bool operator ==(Object other) =>
      other is LocalTransportTarget &&
      other.transportType == transportType &&
      other.transportPath == transportPath;

  @override
  int get hashCode => Object.hash(transportType, transportPath);

  @override
  String toString() =>
      'LocalTransportTarget(${transportType.wireName}, $transportPath)';
}

/// `application/x-www-form-urlencoded` serialisation of a single component.
///
/// Hand-rolled rather than using `Uri.encodeQueryComponent` because upstream
/// builds the query through `URLSearchParams`, whose safe set is exactly
/// `[A-Za-z0-9*\-._]` with space as `+`. Dart's helper additionally leaves
/// `!~'()` unescaped, which would produce a different URL for a socket path
/// containing any of them.
String _encodeFormComponent(String value) {
  final buffer = StringBuffer();
  for (final byte in utf8.encode(value)) {
    final isUnreserved =
        (byte >= 0x41 && byte <= 0x5A) || // A-Z
        (byte >= 0x61 && byte <= 0x7A) || // a-z
        (byte >= 0x30 && byte <= 0x39) || // 0-9
        byte == 0x2A || // *
        byte == 0x2D || // -
        byte == 0x2E || // .
        byte == 0x5F; // _
    if (isUnreserved) {
      buffer.writeCharCode(byte);
    } else if (byte == 0x20) {
      buffer.write('+');
    } else {
      buffer.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return buffer.toString();
}

/// Encodes a local daemon target as the `paseo+local://` URL the transport
/// factory is later handed.
///
/// A URL rather than a struct because the daemon client keys every connection
/// by URL string; a local daemon has to be addressable in the same registry as
/// a remote WebSocket one.
///
/// Deviation: upstream goes through the WHATWG `URL` class. `paseo+local` is a
/// non-special scheme, so its path stays empty and the serialisation is
/// `paseo+local://<host>?path=<encoded>` with no `/` before the query. That
/// exact string is reproduced by concatenation, since Dart's `Uri` would
/// normalise differently.
String buildLocalDaemonTransportUrl(LocalTransportTarget target) =>
    '$_localTransportScheme://${target.transportType.wireName}'
    '?path=${_encodeFormComponent(target.transportPath)}';

/// Inverse of [buildLocalDaemonTransportUrl].
///
/// Throws [FormatException] for a URL that is not a usable local target —
/// wrong scheme, a transport type outside the union, or a blank path. Upstream
/// throws `Error`, and additionally lets `new URL` throw its own `TypeError`
/// on a syntactically invalid URL; `Uri.parse` throws `FormatException` in the
/// same situations, so every failure is one exception type here.
LocalTransportTarget parseLocalDaemonTransportUrl(String url) {
  final parsed = Uri.parse(url);
  if (parsed.scheme != _localTransportScheme) {
    throw FormatException('Unsupported local transport URL: $url');
  }
  final transportType = LocalTransportType.fromWireName(parsed.host);
  final transportPath = parsed.queryParameters['path']?.trim() ?? '';
  if (transportType == null || transportPath.isEmpty) {
    throw FormatException('Invalid local transport target: $url');
  }
  return LocalTransportTarget(
    transportType: transportType,
    transportPath: transportPath,
  );
}

/// What kind of thing happened on a local transport session.
enum LocalDaemonTransportEventKind { open, message, close, error }

/// One event pushed up from the host's local-socket implementation.
///
/// A single flat shape for all four kinds, matching upstream, because it
/// crosses an untyped IPC boundary where a discriminated union would have to be
/// re-validated anyway.
final class LocalDaemonTransportEvent {
  const LocalDaemonTransportEvent({
    required this.sessionId,
    required this.kind,
    this.text,
    this.binaryBase64,
    this.code,
    this.reason,
    this.error,
  });

  final String sessionId;
  final LocalDaemonTransportEventKind kind;

  /// Text frame payload. Checked for emptiness, not just null — see
  /// [createDesktopLocalDaemonTransportFactory].
  final String? text;

  /// Binary frame payload, base64 because the IPC channel is JSON.
  final String? binaryBase64;

  final int? code;
  final String? reason;
  final String? error;
}

/// The host capability this transport is built on: opening, listening to,
/// writing to and closing a local socket or pipe session.
///
/// Every platform call the transport needs lives behind this one interface, so
/// the transport itself has no `dart:io` and no plugin dependency.
abstract interface class LocalDaemonTransportRpc {
  /// Opens a session and resolves its id.
  Future<String> openSession(LocalTransportTarget target);

  /// Subscribes to *all* session events, resolving a cleanup callback.
  ///
  /// Not scoped to a session because the subscription is established before any
  /// session id exists; the transport filters by id itself.
  Future<void Function()> listenToEvents(
    void Function(LocalDaemonTransportEvent event) handler,
  );

  /// Writes one frame. Exactly one of [text] and [binaryBase64] is set.
  Future<void> sendMessage({
    required String sessionId,
    String? text,
    String? binaryBase64,
  });

  Future<void> closeSession(String sessionId);
}

/// A decoded inbound frame handed to message handlers.
///
/// Upstream emits `{ data }` object literals; this is that literal, with [data]
/// being either a [String] (text frame) or a [Uint8List] (binary frame).
final class LocalDaemonTransportMessage {
  const LocalDaemonTransportMessage(this.data);

  final Object data;

  @override
  String toString() => 'LocalDaemonTransportMessage($data)';
}

/// The daemon-client-facing transport surface.
///
/// Mirrors upstream's `DaemonTransport`: each `on*` registers a handler and
/// returns its unsubscribe callback.
abstract interface class LocalDaemonTransport {
  /// Sends a frame. [data] must be a [String] or a [List<int>].
  ///
  /// Deviation: upstream types this as `string | Uint8Array | ArrayBuffer`.
  /// Dart has no structural union, so the parameter is [Object] and a wrong
  /// type raises [ArgumentError] — JS would have coerced it into a garbage
  /// frame instead.
  void send(Object data);

  /// Tears the transport down.
  ///
  /// [code] and [reason] exist for signature parity with the WebSocket
  /// transport and are ignored, exactly as upstream ignores them for the local
  /// transport.
  void close([int? code, String? reason]);

  void Function() onMessage(
    void Function(LocalDaemonTransportMessage message) handler,
  );
  void Function() onOpen(void Function() handler);
  void Function() onClose(void Function(Object? event) handler);
  void Function() onError(void Function(Object? error) handler);
}

/// Builds a [LocalDaemonTransport] for a `paseo+local://` URL.
typedef LocalDaemonTransportFactory =
    LocalDaemonTransport Function({required String url});

/// Base64 for a binary frame, matching `btoa` over the byte string.
String _encodeBinaryToBase64(List<int> data) =>
    base64.encode(data is Uint8List ? data : Uint8List.fromList(data));

/// Inverse of [_encodeBinaryToBase64].
///
/// Deviation: `atob` implements WHATWG "forgiving-base64", which accepts
/// unpadded input; `base64.decode` requires padding. Missing padding is
/// restored first so both accept the same strings.
Uint8List _decodeBase64ToBytes(String value) {
  final remainder = value.length % 4;
  final padded = remainder == 0 ? value : value + '=' * (4 - remainder);
  return base64.decode(padded);
}

/// Creates the factory that turns a `paseo+local://` URL into a live transport.
///
/// The interesting behaviour is the open race. Session setup and event
/// subscription are started concurrently, so the host's `open` event can arrive
/// *before* the session id that would let the transport recognise it. The
/// transport therefore emits `open` from whichever of the two arrives second,
/// guarded so it fires exactly once — a daemon client that never saw `open`
/// would sit waiting forever, and one that saw it twice would re-run its
/// handshake.
///
/// The mirror case is teardown before setup finishes: a `close()` during the
/// in-flight open must still close the session the host is about to hand back,
/// and must run the subscription cleanup that has not been delivered yet.
///
/// Deviation: upstream returns `DaemonTransportFactory | null`, but its body
/// always returns a closure, so the null arm is unreachable and the Dart return
/// type is non-nullable.
LocalDaemonTransportFactory createDesktopLocalDaemonTransportFactory(
  LocalDaemonTransportRpc rpc,
) {
  return ({required String url}) =>
      _LocalDaemonTransport(rpc, parseLocalDaemonTransportUrl(url));
}

final class _LocalDaemonTransport implements LocalDaemonTransport {
  _LocalDaemonTransport(this._rpc, LocalTransportTarget target) {
    unawaited(_startListening());
    unawaited(_startSession(target));
  }

  final LocalDaemonTransportRpc _rpc;

  /// Upstream's `void rpc.listenToEvents(...).then(...).catch(...)`.
  ///
  /// Deviation: written with `async`/`try` rather than a promise chain. The
  /// ordering is the same — the body runs synchronously up to the first `await`
  /// and both the success and failure arms land on a later microtask — but the
  /// error arm no longer has to be typed as a value-producing continuation.
  Future<void> _startListening() async {
    try {
      final cleanup = await _rpc.listenToEvents(_handleEvent);
      if (_disposed) {
        cleanup();
        return;
      }
      _unlisten = cleanup;
    } catch (error) {
      _emitError(error);
    }
  }

  /// Upstream's `void rpc.openSession(...).then(...).catch(...)`.
  ///
  /// The `_disposed` arm is what makes `close()` safe to call while the open is
  /// still in flight: the id the host is about to return would otherwise leak a
  /// live socket with nobody holding it.
  Future<void> _startSession(LocalTransportTarget target) async {
    try {
      final id = await _rpc.openSession(target);
      if (_disposed) {
        _forget(_rpc.closeSession(id));
        return;
      }
      _sessionId = id;
      _emitOpen();
    } catch (error) {
      _emitError(error);
    }
  }

  /// Fire-and-forget with the failure routed to the error handlers, matching
  /// upstream's `void promise.catch((error) => emitError(error))`.
  void _forget(Future<void> future) {
    unawaited(future.catchError(_emitError));
  }

  String? _sessionId;
  void Function()? _unlisten;
  bool _disposed = false;
  bool _didEmitOpen = false;

  final _openHandlers = <void Function()>{};
  final _closeHandlers = <void Function(Object? event)>{};
  final _errorHandlers = <void Function(Object? error)>{};
  final _messageHandlers = <void Function(LocalDaemonTransportMessage)>{};

  // Handler sets are snapshotted before iteration. JS tolerates mutating a Set
  // mid-`for...of`; Dart raises ConcurrentModificationError, so a handler that
  // unsubscribes itself would crash the emit. The one visible difference is
  // that a handler registered *during* an emit is not called by that emit.
  void _emitOpen() {
    if (_didEmitOpen || _disposed) return;
    _didEmitOpen = true;
    for (final handler in _openHandlers.toList()) {
      handler();
    }
  }

  void _emitClose(Object? event) {
    for (final handler in _closeHandlers.toList()) {
      handler(event);
    }
  }

  void _emitError(Object? error) {
    for (final handler in _errorHandlers.toList()) {
      handler(error);
    }
  }

  void _emitMessage(Object data) {
    final message = LocalDaemonTransportMessage(data);
    for (final handler in _messageHandlers.toList()) {
      handler(message);
    }
  }

  void _handleEvent(LocalDaemonTransportEvent payload) {
    final sessionId = _sessionId;
    if (_disposed || sessionId == null || payload.sessionId != sessionId) {
      return;
    }
    switch (payload.kind) {
      case LocalDaemonTransportEventKind.open:
        _emitOpen();
      case LocalDaemonTransportEventKind.message:
        // Upstream guards both payloads with truthiness, so an empty text frame
        // falls through to the binary branch and a frame with neither payload
        // is dropped silently.
        final text = payload.text;
        if (text != null && text.isNotEmpty) {
          _emitMessage(text);
          return;
        }
        final binary = payload.binaryBase64;
        if (binary != null && binary.isNotEmpty) {
          _emitMessage(_decodeBase64ToBytes(binary));
        }
      case LocalDaemonTransportEventKind.close:
        _emitClose(payload);
      case LocalDaemonTransportEventKind.error:
        // `??` and not `||`: an empty-string error is reported as-is.
        _emitError(payload.error ?? 'Local daemon transport error');
    }
  }

  @override
  void send(Object data) {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    if (data is String) {
      _forget(_rpc.sendMessage(sessionId: sessionId, text: data));
      return;
    }
    if (data is List<int>) {
      _forget(
        _rpc.sendMessage(
          sessionId: sessionId,
          binaryBase64: _encodeBinaryToBase64(data),
        ),
      );
      return;
    }
    throw ArgumentError.value(
      data,
      'data',
      'Local daemon transport frames must be a String or a List<int>',
    );
  }

  @override
  void close([int? code, String? reason]) {
    _disposed = true;
    final currentSessionId = _sessionId;
    _sessionId = null;
    if (currentSessionId != null) {
      _forget(_rpc.closeSession(currentSessionId));
    }
    _unlisten?.call();
    _unlisten = null;
  }

  @override
  void Function() onMessage(
    void Function(LocalDaemonTransportMessage message) handler,
  ) {
    _messageHandlers.add(handler);
    return () => _messageHandlers.remove(handler);
  }

  @override
  void Function() onOpen(void Function() handler) {
    _openHandlers.add(handler);
    return () => _openHandlers.remove(handler);
  }

  @override
  void Function() onClose(void Function(Object? event) handler) {
    _closeHandlers.add(handler);
    return () => _closeHandlers.remove(handler);
  }

  @override
  void Function() onError(void Function(Object? error) handler) {
    _errorHandlers.add(handler);
    return () => _errorHandlers.remove(handler);
  }
}
