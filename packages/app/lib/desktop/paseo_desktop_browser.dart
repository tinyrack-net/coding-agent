/// Ports of four frozen Paseo 0.2.0 desktop-host modules that sit on the
/// boundary between an untrusted web page and the host machine, plus the
/// bundled-skill installer that shares their "the host owns the filesystem"
/// shape:
///
/// - `desktop/features/browser-automation/trusted-input.ts` — the exact CDP and
///   Electron key events the automation service synthesises so a page sees
///   *trusted* input (`isTrusted === true`) instead of a scripted `dispatchEvent`
///   a site can detect or a `beforeinput` guard can swallow.
/// - `desktop/features/browser-keyboard/policy.ts` — which keystrokes the
///   embedded browser hands back to the Paseo shell instead of letting the guest
///   page consume, and the validation the host applies to the policy the
///   renderer ships it.
/// - `desktop/features/attachments.ts` — the host side of attachment storage:
///   the only component that turns a renderer-supplied id/extension into a real
///   path, and the containment check that keeps a compromised renderer from
///   reading or deleting anything outside the managed directory.
/// - `desktop/integrations/skills/operations.ts` — install / update /
///   auto-update / uninstall of the bundled Paseo skills across the `.agents`,
///   `.claude` and `.codex` skill directories, and the drift diff that drives
///   them.
///
/// ## Already ported elsewhere — `browser-webviews/window-open.ts`
///
/// The fifth module of this cluster was already ported, before this file
/// existed, to `core/desktop/desktop_browser_window_open.dart`. It is faithful
/// (`decideBrowserWindowOpenRequest`, `isAllowedBrowserWebviewUrl` and
/// `PendingBrowserWindowOpenRequests` are all present with upstream's semantics)
/// so nothing is re-implemented here; it is re-exported below so a caller
/// wiring up the embedded browser gets the whole cluster from one import, and
/// the companion test suite re-runs upstream's `window-open.test.ts` cases
/// against it rather than taking the existing port on trust.
///
/// That module's URL allowlist is deliberately *stricter* than upstream's
/// WHATWG `new URL(...)`: see [isAllowedDesktopBrowserUrl]. WHATWG accepts
/// `http:example.com` and normalises it to `http://example.com/`, whereas
/// `Uri.tryParse` yields a scheme-with-opaque-path and the existing port
/// rejects it for lacking an authority. A looser allowlist on a
/// `window.open()` gate is a real security risk and a tighter one only costs a
/// popup, so the asymmetry is the safe direction and is left as-is.
///
/// ## Injected host capabilities
///
/// Nothing here imports `dart:io` or a plugin. Every OS capability arrives as a
/// narrow interface: [DesktopCdpCommandSender] and [DesktopKeyboardInputSender]
/// for the browser guest, [DesktopAttachmentFileSystem] and
/// [PaseoSkillsFileSystem] for disk, [PaseoSkillsSyncGateway] for the
/// file-copying half of `skills/sync.ts`, and [PaseoSkillContentHasher] for
/// SHA-256 (this package has no crypto dependency, and the operations rules
/// only ever compare digests for equality).
///
/// ## Deviation: reuse that was deliberately *not* taken
///
/// - `DesktopPathOps` in `desktop/paseo_desktop_daemon_launch.dart` covers
///   `join`/`dirname`/`basename` with the same POSIX/Win32 split as
///   [DesktopBrowserPathOps] here. It is not reused because that library
///   transitively imports `shared_preferences` (a plugin) and `dart:io` through
///   `daemon_lifecycle`, which these security-sensitive rules must stay free of,
///   and because it has no `resolve` — the `..`-collapsing normaliser that the
///   attachment containment check depends on for its entire security value.
/// - `DesktopAttachmentFileResult` in `attachments/paseo_attachment_stores.dart`
///   is the same `{path, byteSize}` payload as upstream's `AttachmentFileResult`,
///   but that library reaches `dart:io` and the `desktop_drop` plugin through
///   `attachment_store.dart`. [DesktopManagedAttachmentFileResult] here is the
///   host-side twin of it; the two are the two ends of one IPC call.
library;

import 'dart:convert' show base64Encode;
import 'dart:typed_data';

export '../core/desktop/desktop_browser_window_open.dart';

// ---------------------------------------------------------------------------
// node:path subset
// ---------------------------------------------------------------------------

/// The slice of `node:path` these rules need, as an injectable value so a test
/// can pin POSIX semantics on a Windows machine and Win32 semantics on a POSIX
/// one — upstream's suites assume the host's own flavour, and the attachment
/// containment check behaves differently under each.
///
/// Deviation: only [join], [basename], [fileStem], [isAbsolute], [resolve] and
/// [toPosix] exist, and [resolve] treats a leading separator on Windows as an
/// absolute root rather than "the drive of the current directory" the way
/// `path.win32.resolve` does. No upstream call site passes a drive-relative
/// path, and the difference can only make the containment check *reject* more.
final class DesktopBrowserPathOps {
  const DesktopBrowserPathOps._(this.separator, this._separators);

  /// `node:path.posix`.
  static const DesktopBrowserPathOps posix = DesktopBrowserPathOps._('/', '/');

  /// `node:path.win32`, which accepts either slash flavour as a separator but
  /// always emits a backslash.
  static const DesktopBrowserPathOps windows = DesktopBrowserPathOps._(
    r'\',
    r'/\',
  );

  /// The separator emitted when joining, and `path.sep`.
  final String separator;

  final String _separators;

  bool get _isWindows => separator == r'\';

  bool _isSeparator(String character) => _separators.contains(character);

  /// `path.join(...)` for plain segments. Empty segments are dropped, and an
  /// all-empty call yields `"."`, both as in Node.
  String join(List<String> parts) {
    final present = parts.where((part) => part.isNotEmpty).toList();
    if (present.isEmpty) return '.';

    final leading = _leadingSeparators(present.first);
    final segments = <String>[];
    for (final part in present) {
      for (final piece in _splitSegments(part)) {
        if (piece.isNotEmpty) segments.add(piece);
      }
    }
    if (segments.isEmpty) return leading.isEmpty ? '.' : leading;
    return '$leading${segments.join(separator)}';
  }

  /// `path.basename(...)`.
  String basename(String path) {
    var end = path.length;
    while (end > 0 && _isSeparator(path[end - 1])) {
      end--;
    }
    if (end == 0) return '';

    var start = 0;
    for (var index = end - 1; index >= 0; index--) {
      if (_isSeparator(path[index])) {
        start = index + 1;
        break;
      }
    }
    return path.substring(start, end);
  }

  /// `path.parse(path).name` — the basename with its extension removed.
  ///
  /// Reproduces Node's two carve-outs, both confirmed by running `node:path`
  /// against the frozen inputs: a dot in position 0 is part of the name rather
  /// than an extension (`.bashrc` stays `.bashrc`), and the exact basename `..`
  /// is never split (Node yields `..`, not `.`). Everything else splits at the
  /// last dot, so `a.tar.gz` becomes `a.tar` and `...` becomes `..`.
  ///
  /// This is what decides whether a file in managed attachment storage is
  /// claimed by a referenced attachment id, so a mismatch here would delete
  /// live attachments.
  String fileStem(String path) {
    final base = basename(path);
    if (base == '..') return base;
    final lastDot = base.lastIndexOf('.');
    if (lastDot <= 0) return base;
    return base.substring(0, lastDot);
  }

  /// Whether [path] names a filesystem root rather than something relative to
  /// the current directory.
  bool isAbsolute(String path) {
    if (path.isEmpty) return false;
    if (_isSeparator(path[0])) return true;
    if (!_isWindows) return false;
    return path.length >= 3 &&
        _isDriveLetter(path[0]) &&
        path[1] == ':' &&
        _isSeparator(path[2]);
  }

  /// `path.resolve(cwd, path)` — anchor [path] to [workingDirectory] when it is
  /// relative, then collapse `.` and `..`.
  ///
  /// The collapsing is the whole security value of
  /// [DesktopManagedAttachments]: without it,
  /// `<home>/desktop-attachments/../../.ssh/id_rsa` would pass a naive prefix
  /// check.
  String resolve(String workingDirectory, String path) {
    final combined = isAbsolute(path)
        ? path
        : join(<String>[workingDirectory, path]);
    return _normalize(combined);
  }

  /// Rewrites [path] with forward slashes, matching upstream's `toPosix`.
  ///
  /// Used so a skill's file map is keyed identically on every host and a
  /// bundle hashed on Windows still matches one installed from a POSIX build.
  String toPosix(String path) =>
      separator == '/' ? path : path.split(separator).join('/');

  String _normalize(String path) {
    final root = _rootOf(path);
    final segments = <String>[];
    for (final piece in _splitSegments(path.substring(root.length))) {
      if (piece.isEmpty || piece == '.') continue;
      if (piece == '..') {
        if (segments.isNotEmpty && segments.last != '..') {
          segments.removeLast();
        } else if (root.isEmpty) {
          segments.add('..');
        }
        // An `..` that would climb above a real root is dropped, exactly as
        // `path.resolve` drops it. This is the branch a traversal attempt hits.
        continue;
      }
      segments.add(piece);
    }
    if (root.isEmpty) {
      return segments.isEmpty ? '.' : segments.join(separator);
    }
    return '$root${segments.join(separator)}';
  }

  /// The un-collapsible prefix of [path]: `''`, `'/'`, `'\\'` (UNC) or `'C:\'`.
  String _rootOf(String path) {
    if (path.isEmpty) return '';
    if (_isWindows) {
      if (path.length >= 2 && _isSeparator(path[0]) && _isSeparator(path[1])) {
        return r'\\';
      }
      if (path.length >= 3 &&
          _isDriveLetter(path[0]) &&
          path[1] == ':' &&
          _isSeparator(path[2])) {
        return '${path[0]}:$separator';
      }
    }
    if (_isSeparator(path[0])) return separator;
    return '';
  }

  static bool _isDriveLetter(String character) {
    final code = character.codeUnitAt(0);
    return (code >= 0x41 && code <= 0x5a) || (code >= 0x61 && code <= 0x7a);
  }

  String _leadingSeparators(String part) {
    var index = 0;
    while (index < part.length && _isSeparator(part[index])) {
      index++;
    }
    return part.substring(0, index);
  }

  Iterable<String> _splitSegments(String part) sync* {
    final buffer = StringBuffer();
    for (var index = 0; index < part.length; index++) {
      if (_isSeparator(part[index])) {
        yield buffer.toString();
        buffer.clear();
      } else {
        buffer.write(part[index]);
      }
    }
    yield buffer.toString();
  }
}

/// One entry of a directory listing, as `readdir(dir, { withFileTypes: true })`
/// reports it.
final class DesktopDirectoryEntry {
  const DesktopDirectoryEntry({
    required this.name,
    required this.isFile,
    this.isDirectory = false,
  });

  /// The bare entry name, never a path.
  final String name;

  final bool isFile;
  final bool isDirectory;

  @override
  String toString() =>
      'DesktopDirectoryEntry($name, isFile: $isFile, isDirectory: $isDirectory)';
}

// ---------------------------------------------------------------------------
// browser-automation/trusted-input.ts
// ---------------------------------------------------------------------------

/// A viewport point an automation action was resolved to, in CSS pixels.
///
/// Upstream's `ActionablePoint` lives in the sibling `actionability.ts`; only
/// its two fields are needed here, and they are doubles because they come from
/// `getBoundingClientRect()` and are routinely fractional.
final class DesktopBrowserInputPoint {
  const DesktopBrowserInputPoint({required this.x, required this.y});

  final double x;
  final double y;

  @override
  bool operator ==(Object other) =>
      other is DesktopBrowserInputPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'DesktopBrowserInputPoint($x, $y)';
}

/// The mouse button an automated click uses.
enum DesktopBrowserMouseButton {
  left('left', 1),
  right('right', 2),
  middle('middle', 4);

  const DesktopBrowserMouseButton(this.wireName, this.pressedMask);

  /// The value CDP's `Input.dispatchMouseEvent.button` expects.
  final String wireName;

  /// The bit this button contributes to `Input.dispatchMouseEvent.buttons`
  /// while it is held down.
  final int pressedMask;
}

/// A modifier key held for the duration of a synthesised input event.
enum DesktopBrowserInputModifier {
  alt(1),
  control(2),
  meta(4),
  shift(8);

  const DesktopBrowserInputModifier(this.mask);

  /// The bit CDP's `modifiers` bitfield uses for this key.
  final int mask;
}

/// Options for [dispatchTrustedClick].
final class DesktopBrowserClickOptions {
  const DesktopBrowserClickOptions({
    this.button = DesktopBrowserMouseButton.left,
    this.doubleClick = false,
    this.modifiers = const <DesktopBrowserInputModifier>[],
  });

  final DesktopBrowserMouseButton button;

  /// When true the click is sent twice, with `clickCount` 1 then 2 — the exact
  /// sequence a real double click produces, and the only one that fires
  /// `dblclick` in the page.
  final bool doubleClick;

  final List<DesktopBrowserInputModifier> modifiers;
}

/// Sends one Chrome DevTools Protocol command to the guest page.
///
/// Upstream's `CdpCommandSender` from `cdp-session-queue.ts`; the queue itself
/// is a separate source unit and is not ported here. `params` stays optional so
/// the signature matches, even though every call site below passes it.
typedef DesktopCdpCommandSender =
    Future<Object?> Function(String command, [Map<String, Object?>? params]);

/// The kind of a synthesised Electron keyboard event.
enum IsolatedKeyboardInputEventType {
  char('char'),
  keyDown('keyDown'),
  keyUp('keyUp');

  const IsolatedKeyboardInputEventType(this.wireName);

  final String wireName;
}

/// One `webContents.sendInputEvent` keyboard event.
///
/// `skipIfUnhandled` is always true and has no setter: it is the entire point
/// of the type. Electron accepts the flag even though its public typings omit
/// it, and it stops a key the guest page did not handle from being redispatched
/// into the embedder's focused DOM element or application menu — without it a
/// keystroke automated into a webview can leak into the Paseo shell.
final class IsolatedKeyboardInputEvent {
  const IsolatedKeyboardInputEvent({required this.type, required this.keyCode});

  final IsolatedKeyboardInputEventType type;

  /// Electron's `keyCode`, which for a `char` event carries the character to
  /// insert rather than a key name.
  final String keyCode;

  /// Always `true`; mirrors upstream's `skipIfUnhandled: true` literal type.
  bool get skipIfUnhandled => true;

  @override
  bool operator ==(Object other) =>
      other is IsolatedKeyboardInputEvent &&
      other.type == type &&
      other.keyCode == keyCode;

  @override
  int get hashCode => Object.hash(type, keyCode);

  @override
  String toString() =>
      'IsolatedKeyboardInputEvent(${type.wireName}, keyCode: $keyCode, '
      'skipIfUnhandled: true)';
}

/// Hands a synthesised keyboard event to the host webview.
typedef DesktopKeyboardInputSender =
    void Function(IsolatedKeyboardInputEvent event);

/// Electron spells the four arrow keys without the `Arrow` prefix that the DOM
/// `KeyboardEvent.key` values use.
const Map<String, String> _electronKeyCodeAliases = <String, String>{
  'ArrowDown': 'Down',
  'ArrowLeft': 'Left',
  'ArrowRight': 'Right',
  'ArrowUp': 'Up',
};

/// Moves the pointer to [point], then presses and releases [options]'s button
/// there.
///
/// The leading `mouseMoved` is not decoration: a page that only reveals its
/// click target on hover, or that reads `event.movementX`, behaves differently
/// without it, and CDP does not imply a move from a press.
Future<void> dispatchTrustedClick(
  DesktopCdpCommandSender send,
  DesktopBrowserInputPoint point, [
  DesktopBrowserClickOptions options = const DesktopBrowserClickOptions(),
]) async {
  final button = options.button;
  final modifiers = _modifierMask(options.modifiers);
  await send('Input.dispatchMouseEvent', <String, Object?>{
    'type': 'mouseMoved',
    'x': point.x,
    'y': point.y,
    'button': 'none',
    'modifiers': modifiers,
  });
  if (options.doubleClick) {
    await _dispatchTrustedMouseClick(send, point, button, modifiers, 1);
    await _dispatchTrustedMouseClick(send, point, button, modifiers, 2);
    return;
  }
  await _dispatchTrustedMouseClick(send, point, button, modifiers, 1);
}

Future<void> _dispatchTrustedMouseClick(
  DesktopCdpCommandSender send,
  DesktopBrowserInputPoint point,
  DesktopBrowserMouseButton button,
  int modifiers,
  int clickCount,
) async {
  await send('Input.dispatchMouseEvent', <String, Object?>{
    'type': 'mousePressed',
    'x': point.x,
    'y': point.y,
    'button': button.wireName,
    'buttons': button.pressedMask,
    'clickCount': clickCount,
    'modifiers': modifiers,
  });
  await send('Input.dispatchMouseEvent', <String, Object?>{
    'type': 'mouseReleased',
    'x': point.x,
    'y': point.y,
    'button': button.wireName,
    'buttons': 0,
    'clickCount': clickCount,
    'modifiers': modifiers,
  });
}

/// Moves the pointer to [point] without pressing anything.
///
/// Deliberately omits `modifiers` entirely rather than sending `0`, matching
/// upstream's object literal.
Future<void> dispatchTrustedHover(
  DesktopCdpCommandSender send,
  DesktopBrowserInputPoint point,
) async {
  await send('Input.dispatchMouseEvent', <String, Object?>{
    'type': 'mouseMoved',
    'x': point.x,
    'y': point.y,
    'button': 'none',
  });
}

/// Presses at [source], moves through the midpoint to [target], and releases.
///
/// The intermediate move is what makes HTML5 drag-and-drop and most JS drag
/// libraries commit: a press followed by a single move to the destination is
/// frequently read as a click.
Future<void> dispatchTrustedDrag(
  DesktopCdpCommandSender send,
  DesktopBrowserInputPoint source,
  DesktopBrowserInputPoint target,
) async {
  await send('Input.dispatchMouseEvent', <String, Object?>{
    'type': 'mouseMoved',
    'x': source.x,
    'y': source.y,
    'button': 'none',
  });
  await send('Input.dispatchMouseEvent', <String, Object?>{
    'type': 'mousePressed',
    'x': source.x,
    'y': source.y,
    'button': 'left',
    'buttons': 1,
    'clickCount': 1,
  });
  await send('Input.dispatchMouseEvent', <String, Object?>{
    'type': 'mouseMoved',
    'x': (source.x + target.x) / 2,
    'y': (source.y + target.y) / 2,
    'button': 'left',
    'buttons': 1,
  });
  await send('Input.dispatchMouseEvent', <String, Object?>{
    'type': 'mouseMoved',
    'x': target.x,
    'y': target.y,
    'button': 'left',
    'buttons': 1,
  });
  await send('Input.dispatchMouseEvent', <String, Object?>{
    'type': 'mouseReleased',
    'x': target.x,
    'y': target.y,
    'button': 'left',
    'buttons': 0,
    'clickCount': 1,
  });
}

/// Sends a wheel event at [point].
Future<void> dispatchTrustedScroll(
  DesktopCdpCommandSender send,
  DesktopBrowserInputPoint point,
  double deltaX,
  double deltaY,
) async {
  await send('Input.dispatchMouseEvent', <String, Object?>{
    'type': 'mouseWheel',
    'x': point.x,
    'y': point.y,
    'deltaX': deltaX,
    'deltaY': deltaY,
  });
}

/// Inserts [text] at the focused element, as one atomic input.
///
/// Empty text is a no-op rather than an empty `Input.insertText`, which some
/// pages observe as a spurious `input` event.
Future<void> dispatchTrustedText(
  DesktopCdpCommandSender send,
  String text,
) async {
  if (text.isEmpty) return;
  await send('Input.insertText', <String, Object?>{'text': text});
}

/// Sends a named key as a keyDown / optional char / keyUp triple.
///
/// The `char` event is what actually types a character; without it a `keyDown`
/// for `a` moves focus and fires listeners but inserts nothing. It is emitted
/// for the literal name `Space` (as a space character) and for any single-code-
/// unit key, and suppressed for named keys like `Enter` or `ArrowDown` that
/// insert nothing.
///
/// Deviation note: upstream's `key.length === 1` counts UTF-16 code units, so a
/// non-BMP key such as an emoji is length 2 and gets no `char` event. Dart's
/// `String.length` is also UTF-16 code units, so the same input produces the
/// same (arguably wrong) result on both sides, deliberately.
void dispatchTrustedKey(DesktopKeyboardInputSender send, String key) {
  final keyCode = _electronKeyCodeAliases[key] ?? key;
  String? character;
  if (key == 'Space') {
    character = ' ';
  } else if (key.length == 1) {
    character = key;
  }
  send(
    IsolatedKeyboardInputEvent(
      type: IsolatedKeyboardInputEventType.keyDown,
      keyCode: keyCode,
    ),
  );
  if (character != null) {
    send(
      IsolatedKeyboardInputEvent(
        type: IsolatedKeyboardInputEventType.char,
        keyCode: character,
      ),
    );
  }
  send(
    IsolatedKeyboardInputEvent(
      type: IsolatedKeyboardInputEventType.keyUp,
      keyCode: keyCode,
    ),
  );
}

int _modifierMask(List<DesktopBrowserInputModifier> modifiers) {
  var mask = 0;
  for (final modifier in modifiers) {
    mask |= modifier.mask;
  }
  return mask;
}

// ---------------------------------------------------------------------------
// browser-keyboard/policy.ts
// ---------------------------------------------------------------------------

/// One keystroke shape the Paseo shell claims from the embedded browser.
///
/// Upstream models the three flag fields with literal types — `codeFallback?:
/// true`, `editable?: false`, `repeat?: false` — because each is only ever
/// present to *assert* one thing. Dart has no literal types, so each becomes a
/// plain `bool` named for what it asserts, and the parser below rejects the
/// opposite literal rather than silently normalising it: a policy that shipped
/// `editable: true` is malformed, not permissive.
final class BrowserShortcutPrefix {
  const BrowserShortcutPrefix({
    required this.alt,
    required this.code,
    required this.control,
    required this.meta,
    required this.shift,
    this.codeFallback = false,
    this.excludesEditable = false,
    this.excludesRepeat = false,
    this.key,
    this.shiftedKey,
  });

  final bool alt;

  /// A `KeyboardEvent.code`, or the sentinel `Digit` which stands for any of
  /// `Digit1`–`Digit9` / `Numpad1`–`Numpad9`.
  final String code;

  final bool control;
  final bool meta;
  final bool shift;

  /// Upstream `codeFallback: true` — also match on [code] when the layout's
  /// `key` does not match, so a shortcut still fires on a non-US layout.
  final bool codeFallback;

  /// Upstream `editable: false` — never claim this keystroke while the guest's
  /// focus is in an editable field.
  final bool excludesEditable;

  /// Upstream `repeat: false` — never claim an auto-repeated keystroke.
  final bool excludesRepeat;

  /// A lowercased `KeyboardEvent.key`. When absent, matching is by [code] only.
  final String? key;

  /// A lowercased `KeyboardEvent.key` for the shifted form of [key], so
  /// `Shift+1` still matches a prefix written against `1` on a layout that
  /// reports `!`.
  final String? shiftedKey;

  @override
  bool operator ==(Object other) =>
      other is BrowserShortcutPrefix &&
      other.alt == alt &&
      other.code == code &&
      other.control == control &&
      other.meta == meta &&
      other.shift == shift &&
      other.codeFallback == codeFallback &&
      other.excludesEditable == excludesEditable &&
      other.excludesRepeat == excludesRepeat &&
      other.key == key &&
      other.shiftedKey == shiftedKey;

  @override
  int get hashCode => Object.hash(
    alt,
    code,
    control,
    meta,
    shift,
    codeFallback,
    excludesEditable,
    excludesRepeat,
    key,
    shiftedKey,
  );

  @override
  String toString() =>
      'BrowserShortcutPrefix(code: $code, key: $key, shiftedKey: $shiftedKey, '
      'alt: $alt, control: $control, meta: $meta, shift: $shift, '
      'codeFallback: $codeFallback, excludesEditable: $excludesEditable, '
      'excludesRepeat: $excludesRepeat)';
}

/// The full set of keystrokes the shell claims, as shipped by the renderer.
///
/// [menuPrefixes] is the subset that also appears in the application menu; the
/// host keeps it separate because a menu accelerator is dispatched by Electron
/// itself and must not be double-handled.
final class BrowserKeyboardPolicy {
  const BrowserKeyboardPolicy({
    required this.menuPrefixes,
    required this.prefixes,
  });

  final List<BrowserShortcutPrefix> menuPrefixes;
  final List<BrowserShortcutPrefix> prefixes;

  @override
  bool operator ==(Object other) =>
      other is BrowserKeyboardPolicy &&
      _listEquals(other.menuPrefixes, menuPrefixes) &&
      _listEquals(other.prefixes, prefixes);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(menuPrefixes), Object.hashAll(prefixes));

  @override
  String toString() =>
      'BrowserKeyboardPolicy(menuPrefixes: $menuPrefixes, prefixes: $prefixes)';
}

/// A keystroke observed inside a specific guest webview.
final class BrowserShortcutInput {
  const BrowserShortcutInput({
    required this.alt,
    required this.browserId,
    required this.code,
    required this.control,
    required this.key,
    required this.meta,
    required this.repeat,
    required this.shift,
  });

  final bool alt;

  /// The guest's identity, forwarded verbatim. Never trimmed or normalised:
  /// the host looks this up in a registry keyed by the exact string the
  /// renderer registered, so `" browser-1 "` and `"browser-1"` are different
  /// browsers, and quietly conflating them would route a keystroke to the wrong
  /// guest.
  final String browserId;

  final String code;
  final bool control;
  final String key;
  final bool meta;
  final bool repeat;
  final bool shift;

  @override
  bool operator ==(Object other) =>
      other is BrowserShortcutInput &&
      other.alt == alt &&
      other.browserId == browserId &&
      other.code == code &&
      other.control == control &&
      other.key == key &&
      other.meta == meta &&
      other.repeat == repeat &&
      other.shift == shift;

  @override
  int get hashCode =>
      Object.hash(alt, browserId, code, control, key, meta, repeat, shift);

  @override
  String toString() =>
      'BrowserShortcutInput(browserId: $browserId, key: $key, code: $code, '
      'alt: $alt, control: $control, meta: $meta, shift: $shift, '
      'repeat: $repeat)';
}

/// A keystroke being tested against a policy.
final class BrowserShortcutMatchInput {
  const BrowserShortcutMatchInput({
    required this.alt,
    required this.code,
    required this.control,
    required this.key,
    required this.meta,
    required this.repeat,
    required this.shift,
    this.editable,
  });

  final bool alt;
  final String code;
  final bool control;
  final String key;
  final bool meta;
  final bool repeat;
  final bool shift;

  /// Whether the guest's focus is in an editable field. `null` means "the
  /// caller does not know", which upstream treats as *not* editable — only an
  /// explicit `true` suppresses a prefix carrying `editable: false`.
  final bool? editable;
}

/// A shortcut the embedded browser handles itself instead of forwarding.
enum BrowserReservedShortcut { focusUrl, reload, forceReload }

/// The raw Electron `before-input-event` fields
/// [classifyBrowserReservedShortcut] reads.
final class BrowserReservedShortcutInput {
  const BrowserReservedShortcutInput({
    required this.alt,
    required this.control,
    required this.key,
    required this.meta,
    required this.shift,
    required this.type,
  });

  final bool alt;
  final bool control;
  final String key;
  final bool meta;
  final bool shift;

  /// Electron's input-event type, e.g. `keyDown`. Kept as a raw string because
  /// the host receives whatever Electron sends and only ever compares it to
  /// `keyDown`.
  final String type;
}

/// Parses a keyboard policy the renderer shipped over IPC.
///
/// Returns `null` — meaning "keep the previous policy, claim nothing new" —
/// for any structural defect. The host must never half-apply a policy it does
/// not fully understand, because a partially-parsed policy would silently stop
/// claiming keystrokes the shell depends on.
///
/// Deviation note: upstream distinguishes an *absent* optional field from an
/// explicit `null` (`value.key === undefined` is false for `null`, and `null`
/// is not a string, so `{key: null}` is rejected while `{}` is accepted). Dart
/// map lookup cannot tell the two apart, so this parser uses `containsKey` to
/// reproduce the distinction exactly.
BrowserKeyboardPolicy? parseBrowserKeyboardPolicy(Object? value) {
  final record = _asRecord(value);
  if (record == null) return null;
  final menuPrefixes = _parsePrefixes(record['menuPrefixes']);
  final prefixes = _parsePrefixes(record['prefixes']);
  if (menuPrefixes == null || prefixes == null) return null;
  return BrowserKeyboardPolicy(menuPrefixes: menuPrefixes, prefixes: prefixes);
}

/// Parses a keystroke report the renderer shipped over IPC, or `null` when it
/// is malformed.
BrowserShortcutInput? parseBrowserShortcutInput(Object? value) {
  final record = _asRecord(value);
  if (record == null) return null;
  final browserId = record['browserId'];
  final key = record['key'];
  final code = record['code'];
  final alt = record['alt'];
  final control = record['control'];
  final meta = record['meta'];
  final shift = record['shift'];
  if (browserId is! String ||
      browserId.isEmpty ||
      key is! String ||
      code is! String ||
      alt is! bool ||
      control is! bool ||
      meta is! bool ||
      shift is! bool) {
    return null;
  }
  return BrowserShortcutInput(
    alt: alt,
    browserId: browserId,
    code: code,
    control: control,
    key: key,
    meta: meta,
    // Upstream `value.repeat === true`: anything other than the boolean `true`
    // — including a missing field or a truthy non-boolean — means "not a
    // repeat", so a malformed field can never suppress a shortcut.
    repeat: record['repeat'] == true,
    shift: shift,
  );
}

/// Whether any of [prefixes] claims [input].
bool matchesBrowserShortcutPrefixes(
  List<BrowserShortcutPrefix> prefixes,
  BrowserShortcutMatchInput input,
) => prefixes.any((prefix) => _matchesPrefix(prefix, input));

/// Whether [policy]'s non-menu prefixes claim [input].
bool matchesBrowserShortcutPolicy(
  BrowserKeyboardPolicy policy,
  BrowserShortcutMatchInput input,
) => matchesBrowserShortcutPrefixes(policy.prefixes, input);

/// Which browser-owned shortcut, if any, [input] is.
///
/// These three are handled by the embedded browser itself rather than by the
/// guest page, so the platform command modifier must be unambiguous: on macOS
/// exactly Meta (not Control), elsewhere exactly Control (not Meta). Holding
/// both, or holding Alt, disqualifies the keystroke — a page-defined
/// `Ctrl+Meta+R` should reach the page.
BrowserReservedShortcut? classifyBrowserReservedShortcut(
  BrowserReservedShortcutInput input, {
  required bool isMac,
}) {
  final hasPlatformModifier = isMac
      ? input.meta && !input.control
      : input.control && !input.meta;
  if (input.type != 'keyDown' || input.alt || !hasPlatformModifier) {
    return null;
  }
  final key = input.key.toLowerCase();
  if (!input.shift && key == 'l') return BrowserReservedShortcut.focusUrl;
  if (key != 'r') return null;
  return input.shift
      ? BrowserReservedShortcut.forceReload
      : BrowserReservedShortcut.reload;
}

Map<String, Object?>? _asRecord(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    // A JSON decoder yields `Map<String, dynamic>`, but a hand-built literal
    // may be `Map<Object?, Object?>`. Upstream's `isRecord` accepts any plain
    // object, so accept any map with string keys.
    final out = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) return null;
      out[key] = entry.value;
    }
    return out;
  }
  return null;
}

List<BrowserShortcutPrefix>? _parsePrefixes(Object? value) {
  if (value is! List) return null;
  final prefixes = <BrowserShortcutPrefix>[];
  for (final entry in value) {
    final prefix = _parsePrefix(entry);
    if (prefix == null) return null;
    prefixes.add(prefix);
  }
  return prefixes;
}

BrowserShortcutPrefix? _parsePrefix(Object? value) {
  final record = _asRecord(value);
  if (record == null) return null;

  final code = record['code'];
  final alt = record['alt'];
  final control = record['control'];
  final meta = record['meta'];
  final shift = record['shift'];
  if (code is! String ||
      code.isEmpty ||
      alt is! bool ||
      control is! bool ||
      meta is! bool ||
      shift is! bool ||
      !_hasValidOptionalPrefixFields(record)) {
    return null;
  }

  final key = record['key'];
  final shiftedKey = record['shiftedKey'];
  return BrowserShortcutPrefix(
    alt: alt,
    code: code,
    control: control,
    meta: meta,
    shift: shift,
    codeFallback: record['codeFallback'] == true,
    excludesEditable: record['editable'] == false,
    excludesRepeat: record['repeat'] == false,
    key: key is String ? key.toLowerCase() : null,
    shiftedKey: shiftedKey is String ? shiftedKey.toLowerCase() : null,
  );
}

/// Upstream `hasValidOptionalPrefixFields`: each optional field may be absent,
/// or present with exactly the one value its literal type allows.
bool _hasValidOptionalPrefixFields(Map<String, Object?> record) {
  if (record.containsKey('key') && record['key'] is! String) return false;
  if (record.containsKey('shiftedKey') && record['shiftedKey'] is! String) {
    return false;
  }
  if (record.containsKey('codeFallback') && record['codeFallback'] != true) {
    return false;
  }
  if (record.containsKey('editable') && record['editable'] != false) {
    return false;
  }
  if (record.containsKey('repeat') && record['repeat'] != false) return false;
  return true;
}

final RegExp _digitCodePattern = RegExp(r'^(?:Digit|Numpad)[1-9]$');

/// Upstream `matchesCode`: the sentinel code `Digit` stands for the nine
/// "switch to tab N" keys on either the top row or the numeric keypad. `0` is
/// deliberately excluded — it is the shell's "last tab", bound separately.
bool _matchesCode(String prefixCode, String inputCode) {
  if (prefixCode != 'Digit') return prefixCode == inputCode;
  return _digitCodePattern.hasMatch(inputCode);
}

bool _matchesPrefix(
  BrowserShortcutPrefix prefix,
  BrowserShortcutMatchInput input,
) {
  if (prefix.alt != input.alt ||
      prefix.control != input.control ||
      prefix.meta != input.meta ||
      prefix.shift != input.shift ||
      (prefix.excludesEditable && input.editable == true) ||
      (prefix.excludesRepeat && input.repeat)) {
    return false;
  }
  if (prefix.key == null) {
    return _matchesCode(prefix.code, input.code);
  }
  final key = input.key.toLowerCase();
  if (key == prefix.key) return true;
  if (prefix.shift && prefix.shiftedKey != null && key == prefix.shiftedKey) {
    return true;
  }
  // Alt famously rewrites `key` on macOS (Alt+L reports `¬`), so an Alt prefix
  // always falls back to the physical code; other prefixes only do so when
  // they opted in.
  return (prefix.alt || prefix.codeFallback) &&
      _matchesCode(prefix.code, input.code);
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// features/attachments.ts
// ---------------------------------------------------------------------------

/// A rejected attachment request.
///
/// Deviation note: upstream throws bare `Error`s whose messages are part of the
/// IPC contract (the renderer surfaces them). Dart's `ArgumentError` would
/// mangle those messages with its own prefix, so this type carries them
/// verbatim.
final class DesktopManagedAttachmentError implements Exception {
  const DesktopManagedAttachmentError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Where the host put an attachment file, and how big it turned out.
///
/// The renderer-side twin of this is `DesktopAttachmentFileResult` in
/// `attachments/paseo_attachment_stores.dart`; see this library's header for
/// why the two are not the same class.
final class DesktopManagedAttachmentFileResult {
  const DesktopManagedAttachmentFileResult({
    required this.path,
    required this.byteSize,
  });

  final String path;
  final int byteSize;

  @override
  bool operator ==(Object other) =>
      other is DesktopManagedAttachmentFileResult &&
      other.path == path &&
      other.byteSize == byteSize;

  @override
  int get hashCode => Object.hash(path, byteSize);

  @override
  String toString() =>
      'DesktopManagedAttachmentFileResult(path: $path, byteSize: $byteSize)';
}

/// The `node:fs/promises` calls the attachment rules make.
abstract interface class DesktopAttachmentFileSystem {
  /// `mkdir(path, { recursive: true })` — succeeds when the directory exists.
  Future<void> createDirectory(String path);

  /// `writeFile(path, bytes)`, truncating any existing file.
  Future<void> writeFile(String path, Uint8List bytes);

  /// `readFile(path)`.
  Future<Uint8List> readFile(String path);

  /// `copyFile(source, destination)`.
  Future<void> copyFile(String source, String destination);

  /// `stat(path).size`. Throws when the file is missing, as `stat` does.
  Future<int> fileByteSize(String path);

  /// `rm(path, { force: true })` — succeeds when the file is already gone.
  Future<void> removeFile(String path);

  /// `readdir(path, { withFileTypes: true })`.
  Future<List<DesktopDirectoryEntry>> readDirectory(String path);
}

/// The host side of attachment storage.
///
/// This is the only component that turns a renderer-supplied id and extension
/// into a real path, and the only one that decides whether a path the renderer
/// hands back is allowed to be read or deleted. Every method takes its inputs
/// as `Object?` because upstream types them `unknown`: they arrive straight off
/// an IPC channel and are validated here, not by a type system.
final class DesktopManagedAttachments {
  const DesktopManagedAttachments({
    required this.fileSystem,
    required this.paseoHome,
    required this.workingDirectory,
    this.pathOps = DesktopBrowserPathOps.posix,
  });

  /// Upstream `ATTACHMENTS_DIRNAME`.
  static const String directoryName = 'desktop-attachments';

  /// Upstream `ATTACHMENT_ID_PATTERN`. No dots and no separators, so an id can
  /// never contribute a path segment or a fake extension.
  static final RegExp idPattern = RegExp(r'^[A-Za-z0-9_-]+$');

  /// Upstream `EXTENSION_PATTERN`. Exactly one leading dot and 1–16
  /// alphanumerics, so `.tar.gz`, `.` and `..` are all rejected.
  static final RegExp extensionPattern = RegExp(r'^\.[A-Za-z0-9]{1,16}$');

  /// Upstream's fallback when no extension is supplied.
  static const String defaultExtension = '.bin';

  final DesktopAttachmentFileSystem fileSystem;

  /// The already-resolved `resolvePaseoHome(process.env)`.
  final String paseoHome;

  /// `process.cwd()`, the anchor `path.resolve` uses for a relative input.
  final String workingDirectory;

  final DesktopBrowserPathOps pathOps;

  DesktopAttachmentFileSystem get _fileSystem => fileSystem;

  DesktopBrowserPathOps get _ops => pathOps;

  /// Upstream `attachmentsDirPath()`.
  ///
  /// Derived from an injected home rather than read from the environment:
  /// upstream calls `resolvePaseoHome(process.env)`, and this port takes the
  /// already-resolved value so no `dart:io` is needed.
  String get directoryPath => _ops.join(<String>[paseoHome, directoryName]);

  /// Decodes [base64] and writes it as the file for [attachmentId].
  Future<DesktopManagedAttachmentFileResult> writeAttachmentBase64({
    Object? attachmentId,
    Object? base64,
    Object? extension,
  }) async {
    // Validated before the directory is created, matching upstream's ordering:
    // a rejected payload leaves the filesystem untouched.
    final payload = base64 is String ? base64.trim() : '';
    if (payload.isEmpty) {
      throw const DesktopManagedAttachmentError(
        'Attachment base64 payload is required.',
      );
    }
    final targetPath = await _buildManagedAttachmentPath(
      attachmentId: attachmentId,
      extension: extension,
    );
    await _fileSystem.writeFile(targetPath, decodeNodeBase64(payload));
    return DesktopManagedAttachmentFileResult(
      path: targetPath,
      byteSize: await _fileSystem.fileByteSize(targetPath),
    );
  }

  /// Writes raw [bytes] as the file for [attachmentId].
  Future<DesktopManagedAttachmentFileResult> writeAttachmentBytes({
    Object? attachmentId,
    Object? bytes,
    Object? extension,
  }) async {
    final payload = normalizeAttachmentBytes(bytes);
    final targetPath = await _buildManagedAttachmentPath(
      attachmentId: attachmentId,
      extension: extension,
    );
    await _fileSystem.writeFile(targetPath, payload);
    return DesktopManagedAttachmentFileResult(
      path: targetPath,
      byteSize: await _fileSystem.fileByteSize(targetPath),
    );
  }

  /// Copies an existing file into managed storage without loading its bytes.
  ///
  /// [sourcePath] is *not* required to be inside managed storage — this is the
  /// intake path for a file the user picked or dropped. Only the destination is
  /// constrained, and it is computed here rather than supplied.
  Future<DesktopManagedAttachmentFileResult>
  copyAttachmentFileToManagedStorage({
    Object? attachmentId,
    Object? sourcePath,
    Object? extension,
  }) async {
    if (sourcePath is! String || sourcePath.trim().isEmpty) {
      throw const DesktopManagedAttachmentError(
        'Attachment source path is required.',
      );
    }

    final resolvedSource = _ops.resolve(workingDirectory, sourcePath.trim());
    final targetPath = await _buildManagedAttachmentPath(
      attachmentId: attachmentId,
      extension: extension,
    );

    // Re-importing a file that already *is* the managed copy must not be a
    // self-copy: `copyFile(p, p)` truncates on some platforms.
    if (resolvedSource != targetPath) {
      await _fileSystem.copyFile(resolvedSource, targetPath);
    }

    return DesktopManagedAttachmentFileResult(
      path: targetPath,
      byteSize: await _fileSystem.fileByteSize(targetPath),
    );
  }

  /// Reads a managed file and returns it base64-encoded.
  Future<String> readManagedFileBase64({Object? path}) async {
    final filePath = resolveManagedAttachmentPath(path);
    return base64Encode(await _fileSystem.readFile(filePath));
  }

  /// Deletes a managed file, reporting success even when it was already gone.
  Future<bool> deleteManagedAttachmentFile({Object? path}) async {
    final filePath = resolveManagedAttachmentPath(path);
    await _fileSystem.removeFile(filePath);
    return true;
  }

  /// Deletes every managed file whose id is not in [referencedIds], returning
  /// how many were removed.
  ///
  /// A non-list argument collects *everything*, which is upstream's behaviour
  /// and is safe only because the caller is the renderer's own draft store: an
  /// empty reference set genuinely means "no attachment is live".
  Future<int> garbageCollectManagedAttachmentFiles({
    Object? referencedIds,
  }) async {
    final dirPath = await _ensureAttachmentsDir();
    final referenced = <String>{};
    if (referencedIds is List) {
      for (final value in referencedIds) {
        if (value is! String) continue;
        final trimmed = value.trim();
        if (idPattern.hasMatch(trimmed)) referenced.add(trimmed);
      }
    }

    final entries = await _fileSystem.readDirectory(dirPath);
    final toDelete = entries
        .where(
          (entry) =>
              entry.isFile && !referenced.contains(_ops.fileStem(entry.name)),
        )
        .toList();

    // Deviation: upstream fires the removals through `Promise.all`. Dart runs
    // them in the same order sequentially; the only observable difference is
    // interleaving, and the recorded order is identical.
    for (final entry in toDelete) {
      await _fileSystem.removeFile(_ops.join(<String>[dirPath, entry.name]));
    }

    return toDelete.length;
  }

  /// Upstream `resolveManagedAttachmentPath` — the containment check.
  ///
  /// Rejects anything that does not resolve to a strict descendant of
  /// [directoryPath]. The trailing separator on the prefix is load-bearing: a
  /// sibling directory named `desktop-attachments-stolen` shares the prefix
  /// without it, and the managed directory itself is not a file.
  ///
  /// Comparison is case-sensitive on every platform, matching Node's
  /// `String.prototype.startsWith`. On Windows that means a differently-cased
  /// path is rejected rather than accepted — the strict direction.
  String resolveManagedAttachmentPath(Object? inputPath) {
    if (inputPath is! String || inputPath.trim().isEmpty) {
      throw const DesktopManagedAttachmentError('Attachment path is required.');
    }
    final resolvedDir =
        '${_ops.resolve(workingDirectory, directoryPath)}${_ops.separator}';
    final resolvedPath = _ops.resolve(workingDirectory, inputPath.trim());
    if (!resolvedPath.startsWith(resolvedDir)) {
      throw const DesktopManagedAttachmentError(
        'Attachment path must stay within desktop-managed storage.',
      );
    }
    return resolvedPath;
  }

  /// Upstream `normalizeAttachmentId`.
  static String normalizeAttachmentId(Object? value) {
    if (value is! String) {
      throw const DesktopManagedAttachmentError('Attachment id is required.');
    }
    final normalized = value.trim();
    if (!idPattern.hasMatch(normalized)) {
      throw DesktopManagedAttachmentError('Invalid attachment id: $value');
    }
    return normalized;
  }

  /// Upstream `normalizeExtension`.
  ///
  /// Accepts both the dot-prefixed form a file picker reports (`.md`) and the
  /// bare legacy form older drafts stored (`md`), lowercases either, and falls
  /// back to `.bin` for a missing or empty value.
  ///
  /// Deviation note: upstream's `value == null` is a loose comparison that
  /// catches both `null` and `undefined`; Dart's `null` covers both. A
  /// whitespace-only string is *not* treated as absent — it trims to `""`,
  /// becomes `"."`, and fails [extensionPattern], which is upstream's
  /// behaviour too.
  static String normalizeExtension(Object? value) {
    if (value == null || value == '') return defaultExtension;
    if (value is! String) {
      throw const DesktopManagedAttachmentError(
        'Attachment extension must be a string.',
      );
    }
    final normalized = value.trim().toLowerCase();
    final extension = normalized.startsWith('.') ? normalized : '.$normalized';
    if (!extensionPattern.hasMatch(extension)) {
      throw DesktopManagedAttachmentError(
        'Invalid attachment extension: $value',
      );
    }
    return extension;
  }

  /// Upstream `normalizeBytes`.
  ///
  /// Deviation note: upstream's `Array.isArray` branch runs `Uint8Array.from`,
  /// which applies JS's `ToUint8` coercion — `"a"` and `null` become `0`, `300`
  /// wraps to `44`, `-1` wraps to `255`, `1.7` truncates to `1`. Dart's
  /// `Uint8List.fromList` would throw on the non-numeric cases, so the
  /// coercion is reproduced explicitly (ground truth captured by running the
  /// same values through Node).
  static Uint8List normalizeAttachmentBytes(Object? value) {
    if (value is Uint8List) return value;
    if (value is ByteBuffer) return value.asUint8List();
    if (value is TypedData) {
      return value.buffer.asUint8List(value.offsetInBytes, value.lengthInBytes);
    }
    if (value is List) {
      return Uint8List.fromList(value.map(_toUint8).toList());
    }
    throw const DesktopManagedAttachmentError(
      'Attachment byte payload is required.',
    );
  }

  Future<String> _ensureAttachmentsDir() async {
    final dirPath = directoryPath;
    await _fileSystem.createDirectory(dirPath);
    return dirPath;
  }

  /// Upstream `buildManagedAttachmentPath`.
  ///
  /// The directory is created *before* the id and extension are validated,
  /// exactly as upstream does; a rejected request therefore still leaves an
  /// empty managed directory behind.
  Future<String> _buildManagedAttachmentPath({
    required Object? attachmentId,
    required Object? extension,
  }) async {
    final dirPath = await _ensureAttachmentsDir();
    final id = normalizeAttachmentId(attachmentId);
    final normalizedExtension = normalizeExtension(extension);
    return _ops.join(<String>[dirPath, '$id$normalizedExtension']);
  }
}

int _toUint8(Object? value) {
  num? number;
  if (value is num) {
    number = value;
  } else if (value is bool) {
    number = value ? 1 : 0;
  } else if (value == null) {
    number = 0;
  } else if (value is String) {
    final trimmed = value.trim();
    number = trimmed.isEmpty ? 0 : num.tryParse(trimmed);
  }
  if (number == null || number.isNaN || number.isInfinite) return 0;
  return ((number.truncate() % 256) + 256) % 256;
}

const String _base64Alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/// Decodes [value] the way Node's `Buffer.from(value, "base64")` does.
///
/// Dart's `base64.decode` is strict — it throws on whitespace, on the
/// base64url alphabet, and on missing padding — whereas Node silently skips
/// every character outside the alphabet, accepts `-`/`_` as `+`/`/`, stops at
/// the first `=`, and drops a trailing group too short to form a byte. A
/// renderer that has been round-tripping sloppy base64 through the Electron
/// build must keep working, so the lenient behaviour is reproduced here rather
/// than tightened. Ground truth for every rule was captured by running the
/// inputs through Node.
///
/// Note this is decode-only leniency: it can never produce a *path*, only
/// bytes, so accepting more here has no security consequence.
Uint8List decodeNodeBase64(String value) {
  final bytes = <int>[];
  var accumulator = 0;
  var bitCount = 0;
  for (var index = 0; index < value.length; index++) {
    final character = value[index];
    if (character == '=') break;
    var sextet = _base64Alphabet.indexOf(character);
    if (sextet < 0) {
      if (character == '-') {
        sextet = 62;
      } else if (character == '_') {
        sextet = 63;
      } else {
        continue;
      }
    }
    accumulator = (accumulator << 6) | sextet;
    bitCount += 6;
    if (bitCount >= 8) {
      bitCount -= 8;
      bytes.add((accumulator >> bitCount) & 0xff);
    }
  }
  return Uint8List.fromList(bytes);
}

// ---------------------------------------------------------------------------
// integrations/skills/operations.ts
// ---------------------------------------------------------------------------

/// How the bundled Paseo skills compare to what is installed on disk.
enum PaseoSkillsState {
  /// No Paseo skill is installed in any target. The user has never opted in,
  /// so auto-update must not install anything.
  notInstalled('not-installed'),

  upToDate('up-to-date'),

  /// At least one Paseo skill is installed and at least one target diverges.
  drift('drift');

  const PaseoSkillsState(this.wireName);

  final String wireName;
}

/// One change [PaseoSkillsOperations] would make to reach [PaseoSkillsState.upToDate].
sealed class PaseoSkillOp {
  const PaseoSkillOp(this.name);

  final String name;
}

/// The skill is bundled but missing from at least one target directory.
final class AddPaseoSkillOp extends PaseoSkillOp {
  const AddPaseoSkillOp(super.name);

  @override
  bool operator ==(Object other) =>
      other is AddPaseoSkillOp && other.name == name;

  @override
  int get hashCode => Object.hash(AddPaseoSkillOp, name);

  @override
  String toString() => 'AddPaseoSkillOp($name)';
}

/// The skill is present in every target but at least one copy diverges from
/// the bundle.
final class UpdatePaseoSkillOp extends PaseoSkillOp {
  const UpdatePaseoSkillOp(super.name);

  @override
  bool operator ==(Object other) =>
      other is UpdatePaseoSkillOp && other.name == name;

  @override
  int get hashCode => Object.hash(UpdatePaseoSkillOp, name);

  @override
  String toString() => 'UpdatePaseoSkillOp($name)';
}

/// The skill is installed but no longer bundled — a name Paseo has retired.
final class DeletePaseoSkillOp extends PaseoSkillOp {
  const DeletePaseoSkillOp(super.name);

  @override
  bool operator ==(Object other) =>
      other is DeletePaseoSkillOp && other.name == name;

  @override
  int get hashCode => Object.hash(DeletePaseoSkillOp, name);

  @override
  String toString() => 'DeletePaseoSkillOp($name)';
}

/// The result of comparing the bundle to disk.
final class PaseoSkillsStatus {
  const PaseoSkillsStatus({required this.state, required this.ops});

  final PaseoSkillsState state;

  /// Sorted by skill name, so a status is stable enough to show in the UI and
  /// to compare between runs.
  final List<PaseoSkillOp> ops;

  @override
  bool operator ==(Object other) =>
      other is PaseoSkillsStatus &&
      other.state == state &&
      _listEquals(other.ops, ops);

  @override
  int get hashCode => Object.hash(state, Object.hashAll(ops));

  @override
  String toString() => 'PaseoSkillsStatus(${state.wireName}, ops: $ops)';
}

/// The bundle directory and the three agent skill directories it is mirrored
/// into.
///
/// Deviation note: upstream defaults these from Electron's `app.isPackaged`
/// and `os.homedir()`. Those are host capabilities, so this port always takes
/// them explicitly.
final class PaseoSkillTargets {
  const PaseoSkillTargets({
    required this.sourceDir,
    required this.agentsDir,
    required this.claudeDir,
    required this.codexDir,
  });

  /// The read-only bundle shipped inside the app.
  final String sourceDir;

  final String agentsDir;
  final String claudeDir;
  final String codexDir;

  /// The three install targets, in the order upstream diffs them.
  List<String> get installDirs => <String>[agentsDir, claudeDir, codexDir];
}

/// Skill names Paseo installs, plus retired names kept so auto-update deletes
/// stale copies rather than leaving a dead skill enabled forever.
const List<String> paseoSkillNames = <String>[
  'paseo',
  'paseo-advisor',
  'paseo-chat',
  'paseo-committee',
  'paseo-handoff',
  'paseo-loop',
  // Retired bundle names. Present here only so `diff` emits a delete op.
  'paseo-epic',
  'paseo-orchestrate',
  'paseo-orchestrator',
];

/// The filename `skills/sync.ts` writes to record which files it manages, and
/// which is therefore excluded from every hash so a target never looks drifted
/// because of its own bookkeeping.
const String paseoManagedFilesManifestName = '.paseo-managed-files.json';

/// Digests file content for change detection.
///
/// Injected because this package has no crypto dependency. Only equality of
/// the returned strings matters, so any collision-resistant digest works;
/// upstream uses SHA-256 hex.
typedef PaseoSkillContentHasher = String Function(Uint8List bytes);

/// The read-only `node:fs/promises` calls the drift diff makes.
abstract interface class PaseoSkillsFileSystem {
  /// `stat(path).isDirectory()`, false when the path is missing.
  Future<bool> isDirectory(String path);

  /// `readdir(path, { withFileTypes: true })`.
  Future<List<DesktopDirectoryEntry>> readDirectory(String path);

  /// `readFile(path)`.
  Future<Uint8List> readFile(String path);
}

/// The writing half of `skills/sync.ts`, which is a separate source unit.
///
/// Kept behind an interface so the operations rules — which decide *what* to
/// write and *when* — are testable without a filesystem, and so a host can
/// supply whatever copy strategy it likes as long as it preserves user-added
/// files inside a managed skill directory.
abstract interface class PaseoSkillsSyncGateway {
  /// Mirrors each of [skillNames] from the bundle into all three targets,
  /// leaving files the user added inside those directories alone.
  Future<void> syncSkills({
    required String sourceDir,
    required String agentsDir,
    required String claudeDir,
    required String codexDir,
    required List<String> skillNames,
  });

  /// Removes [skillName] from all three targets, recursively.
  Future<void> removeSkill(
    String skillName, {
    required String agentsDir,
    required String claudeDir,
    required String codexDir,
  });
}

/// Install / update / uninstall of the bundled Paseo skills.
final class PaseoSkillsOperations {
  const PaseoSkillsOperations({
    required this.fileSystem,
    required this.syncGateway,
    required this.hashContent,
    this.pathOps = DesktopBrowserPathOps.posix,
  });

  final PaseoSkillsFileSystem fileSystem;
  final PaseoSkillsSyncGateway syncGateway;
  final PaseoSkillContentHasher hashContent;
  final DesktopBrowserPathOps pathOps;

  PaseoSkillsFileSystem get _fileSystem => fileSystem;

  PaseoSkillsSyncGateway get _syncGateway => syncGateway;

  PaseoSkillContentHasher get _hashContent => hashContent;

  DesktopBrowserPathOps get _ops => pathOps;

  /// Compares the bundle to all three targets.
  ///
  /// The state is deliberately not derived from `ops.isEmpty` alone: a machine
  /// where the user never installed Paseo skills has a full list of add ops but
  /// is [PaseoSkillsState.notInstalled], which is what stops
  /// [autoUpdateInstalled] from installing skills nobody asked for. Only Paseo's
  /// own skill names are inspected, so a directory full of the user's personal
  /// skills still reads as not-installed.
  Future<PaseoSkillsStatus> getStatus(PaseoSkillTargets targets) async {
    final bundle = await _hashSkills(targets.sourceDir);
    final disks = <Map<String, Map<String, String>>>[
      for (final dir in targets.installDirs) await _hashSkills(dir),
    ];
    final ops = _diff(bundle, disks);

    if (!disks.any((disk) => disk.isNotEmpty)) {
      return PaseoSkillsStatus(state: PaseoSkillsState.notInstalled, ops: ops);
    }
    if (ops.isEmpty) {
      return PaseoSkillsStatus(state: PaseoSkillsState.upToDate, ops: ops);
    }
    return PaseoSkillsStatus(state: PaseoSkillsState.drift, ops: ops);
  }

  /// Writes every bundled skill into all three targets.
  Future<PaseoSkillsStatus> install(PaseoSkillTargets targets) =>
      _apply(targets);

  /// Identical to [install]; upstream keeps both names because the UI presents
  /// them as different affordances.
  Future<PaseoSkillsStatus> update(PaseoSkillTargets targets) =>
      _apply(targets);

  /// Repairs drift, but never installs onto a machine that has no Paseo skill.
  Future<PaseoSkillsStatus> autoUpdateInstalled(
    PaseoSkillTargets targets,
  ) async {
    final status = await getStatus(targets);
    if (status.state != PaseoSkillsState.drift) return status;
    return _apply(targets, status);
  }

  /// Removes every Paseo skill name — current and retired — from all three
  /// targets, leaving the user's own skill directories untouched.
  Future<PaseoSkillsStatus> uninstall(PaseoSkillTargets targets) async {
    for (final name in paseoSkillNames) {
      await _syncGateway.removeSkill(
        name,
        agentsDir: targets.agentsDir,
        claudeDir: targets.claudeDir,
        codexDir: targets.codexDir,
      );
    }
    return getStatus(targets);
  }

  Future<PaseoSkillsStatus> _apply(
    PaseoSkillTargets targets, [
    PaseoSkillsStatus? initialStatus,
  ]) async {
    final status = initialStatus ?? await getStatus(targets);

    final writes = <String>[
      for (final op in status.ops)
        if (op is AddPaseoSkillOp || op is UpdatePaseoSkillOp) op.name,
    ];
    if (writes.isNotEmpty) {
      await _syncGateway.syncSkills(
        sourceDir: targets.sourceDir,
        agentsDir: targets.agentsDir,
        claudeDir: targets.claudeDir,
        codexDir: targets.codexDir,
        skillNames: writes,
      );
    }

    for (final op in status.ops) {
      if (op is! DeletePaseoSkillOp) continue;
      await _syncGateway.removeSkill(
        op.name,
        agentsDir: targets.agentsDir,
        claudeDir: targets.claudeDir,
        codexDir: targets.codexDir,
      );
    }

    // Re-read rather than assume: the sync gateway is a host capability and
    // may have failed to converge, and the caller is shown the real state.
    return getStatus(targets);
  }

  List<PaseoSkillOp> _diff(
    Map<String, Map<String, String>> bundle,
    List<Map<String, Map<String, String>>> disks,
  ) {
    final ops = <PaseoSkillOp>[];
    for (final name in paseoSkillNames) {
      final bundled = bundle[name];
      final installed = <Map<String, String>>[
        for (final disk in disks)
          if (disk[name] != null) disk[name]!,
      ];
      if (bundled != null) {
        final missingTargets = installed.length < disks.length;
        final changedTargets = installed.any(
          (files) => !_bundleFilesMatch(bundled, files),
        );
        if (missingTargets) {
          ops.add(AddPaseoSkillOp(name));
        } else if (changedTargets) {
          ops.add(UpdatePaseoSkillOp(name));
        }
      } else if (installed.isNotEmpty) {
        ops.add(DeletePaseoSkillOp(name));
      }
    }
    ops.sort((a, b) => a.name.compareTo(b.name));
    return ops;
  }

  /// Only bundled files are compared, so a file the user added inside a managed
  /// skill directory never reads as drift and is never overwritten.
  bool _bundleFilesMatch(Map<String, String> bundle, Map<String, String> disk) {
    for (final entry in bundle.entries) {
      if (disk[entry.key] != entry.value) return false;
    }
    return true;
  }

  Future<Map<String, Map<String, String>>> _hashSkills(String rootDir) async {
    final out = <String, Map<String, String>>{};
    for (final name in paseoSkillNames) {
      final files = await _hashSkillDir(_ops.join(<String>[rootDir, name]));
      if (files != null) out[name] = files;
    }
    return out;
  }

  Future<Map<String, String>?> _hashSkillDir(String skillDir) async {
    if (!await _fileSystem.isDirectory(skillDir)) return null;
    final files = <String, String>{};
    for (final relative in await _listFilesRecursive(skillDir)) {
      final bytes = await _fileSystem.readFile(
        _ops.join(<String>[skillDir, relative]),
      );
      files[_ops.toPosix(relative)] = _hashContent(bytes);
    }
    return files;
  }

  /// Upstream `listFilesRecursive` from `skills/sync.ts`, borrowed because
  /// `operations.ts` imports it and `sync.ts` is a separate source unit.
  ///
  /// Only the manifest at the skill root is skipped — a nested file that
  /// happens to share the name is a user file and is listed.
  Future<List<String>> _listFilesRecursive(String rootDir) async {
    final out = <String>[];
    Future<void> walk(String dir, String prefix) async {
      for (final entry in await _fileSystem.readDirectory(dir)) {
        final relative = prefix.isEmpty
            ? entry.name
            : '$prefix${_ops.separator}${entry.name}';
        if (relative == paseoManagedFilesManifestName) continue;
        if (entry.isDirectory) {
          await walk(_ops.join(<String>[dir, entry.name]), relative);
        } else if (entry.isFile) {
          out.add(relative);
        }
      }
    }

    await walk(rootDir, '');
    return out;
  }
}
