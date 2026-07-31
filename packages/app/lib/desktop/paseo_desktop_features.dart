/// Port of four frozen Paseo 0.2.0 desktop-host modules. Each one is a *rule*
/// that the Electron main process asked before touching an OS capability; here
/// every capability is a narrow injected interface so the rules run with no
/// Electron, no `dart:io` and no wall clock.
///
/// - `desktop/features/app-update-rollout.ts` — whether a client is inside the
///   staged-rollout window for an app update yet, and which rollout bucket this
///   install lands in.
/// - `desktop/features/browser-profile.ts` — which Electron sessions make up
///   the built-in browser's cookie jar (the shared one plus any pre-v0.1.108
///   per-tab leftovers), and the exact order in which "clear browsing data"
///   wipes them and reloads the live guests.
/// - `desktop/features/editor-targets/registry.ts` — which external editors and
///   file managers are installed, and how each one is invoked to open a
///   workspace at an optional file/line/column.
/// - `desktop/settings/desktop-settings-commands.ts` — the three desktop
///   command-bus handlers that expose the persisted desktop settings store.
///
/// ## Reuse
///
/// [DesktopAppReleaseChannel] and [DesktopAppUpdateCheckIntent] are *not*
/// redeclared here: they already exist in
/// `core/desktop/desktop_app_update_service.dart` and were re-exported by the
/// two sibling ports (`paseo_desktop_daemon_rules.dart`,
/// `paseo_desktop_services.dart`). Upstream spells them `AppReleaseChannel` and
/// `AppUpdateCheckIntent` in `app-update-rollout.ts`, and the ones already in
/// this repo are the same two-member unions with the same members, so the
/// rollout gate below takes the existing enums directly.
///
/// ## Deviation: JS truthiness
///
/// Upstream leans on JS falsiness in several hot spots (`!input.line`,
/// `!input.filePath`, `!args.releaseDate`, `if (runtime.env.HOME)`). In JS the
/// empty string and `0` are falsy, so `line: 0` and `filePath: ""` behave
/// exactly like "absent". Dart's `null` check alone would *not* reproduce that,
/// so every such site goes through [_hasText] / [_hasPosition] and is called
/// out at the use site.
library;

import 'dart:math' as math;

import '../core/desktop/desktop_app_update_service.dart'
    show DesktopAppReleaseChannel, DesktopAppUpdateCheckIntent;

// Re-exported because they appear throughout this library's public signatures;
// a caller wiring up the rollout gate should not have to know which module in
// this repo first introduced them.
export '../core/desktop/desktop_app_update_service.dart'
    show DesktopAppReleaseChannel, DesktopAppUpdateCheckIntent;

// ---------------------------------------------------------------------------
// Shared JS-truthiness helpers
// ---------------------------------------------------------------------------

/// True when [value] is a JS-truthy string: non-null *and* non-empty.
///
/// Upstream writes `if (input.filePath)` / `if (runtime.env.HOME)`; an empty
/// string is falsy in JS, and callers really do pass `""` for "the host has the
/// variable but it is blank". A bare `!= null` would change behaviour there.
bool _hasText(String? value) => value != null && value.isNotEmpty;

/// True when [value] is a JS-truthy line/column: non-null *and* non-zero.
///
/// Upstream writes `if (input.line)`. Editors number lines from 1, so `0` is
/// never a real position — upstream silently treats it as "no position given",
/// and so does this port.
bool _hasPosition(int? value) => value != null && value != 0;

// ---------------------------------------------------------------------------
// app-update-rollout.ts
// ---------------------------------------------------------------------------

/// The two rollout fields Paseo reads out of an electron-updater manifest.
///
/// Upstream is a Zod schema whose fields are both `.optional().catch(undefined)`
/// — every malformed value collapses to "absent" rather than failing the whole
/// parse, because a broken rollout field must never block an update. This class
/// is the parsed result; [parseRolloutManifest] is the schema.
final class RolloutManifest {
  const RolloutManifest({this.rolloutHours, this.releaseDate});

  /// How long the staged rollout takes to reach 100% of stable clients.
  ///
  /// Null means "no staged rollout configured", which admits everyone. Always
  /// finite and non-negative when non-null — the schema drops anything else.
  final double? rolloutHours;

  /// When the release was published, as the manifest's raw string.
  ///
  /// Kept as a string (not a [DateTime]) because upstream keeps it as a string
  /// and defers parsing to [shouldAdmitAppUpdate], where an unparseable value
  /// is a distinct "admit everyone" branch rather than a parse failure.
  final String? releaseDate;

  @override
  bool operator ==(Object other) =>
      other is RolloutManifest &&
      other.rolloutHours == rolloutHours &&
      other.releaseDate == releaseDate;

  @override
  int get hashCode => Object.hash(rolloutHours, releaseDate);

  @override
  String toString() =>
      'RolloutManifest(rolloutHours: $rolloutHours, '
      'releaseDate: $releaseDate)';
}

/// Reads the rollout fields out of an update manifest, tolerating garbage.
///
/// Port of upstream `rolloutManifestSchema.parse(info)`. Reproduces Zod's
/// behaviour exactly:
///
/// - a non-object input throws (Zod raises `ZodError`; here [FormatException]),
///   because the caller only ever hands it a decoded manifest object;
/// - `rolloutHours` accepts a number, or a string coerced through JS `Number()`
///   (so `"24"` → 24, `"0x10"` → 16, `""` → 0, `"  36  "` → 36), then requires
///   the result to be finite and non-negative. Anything else — `null`, a bool,
///   a list, `NaN`, `Infinity`, `-1`, `"not a number"` — becomes null;
/// - `releaseDate` accepts only a string; anything else becomes null.
///
/// Deviation: Zod distinguishes "key absent" from "key present but invalid"
/// internally, but `.catch(undefined)` erases the difference in the output, so
/// this port collapses both to null and is observably identical.
RolloutManifest parseRolloutManifest(Object? input) {
  if (input is! Map) {
    throw const FormatException('Rollout manifest must be an object');
  }
  return RolloutManifest(
    rolloutHours: _coerceRolloutHours(input['rolloutHours']),
    releaseDate: input['releaseDate'] is String
        ? input['releaseDate'] as String
        : null,
  );
}

double? _coerceRolloutHours(Object? raw) {
  final double? value;
  if (raw is num) {
    // `bool` is not a `num` in Dart, matching Zod's rejection of booleans.
    value = raw.toDouble();
  } else if (raw is String) {
    value = _jsNumber(raw);
  } else {
    return null;
  }
  if (value == null || !value.isFinite || value < 0) return null;
  return value;
}

/// Reproduces JS `Number(string)` for the forms that reach a manifest.
///
/// Deviation: Dart has no single equivalent. `double.tryParse` already accepts
/// `"1e2"`, `".5"`, `"5."`, `"+1"`, `"Infinity"` and `"NaN"` the same way JS
/// does, so only three JS-specific behaviours need adding: whitespace-only and
/// empty strings become `0`, and the `0x`/`0b`/`0o` radix prefixes are honoured.
/// Returns null where JS would return `NaN`.
double? _jsNumber(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return 0;
  if (text.length > 2 && text[0] == '0') {
    final radix = switch (text[1]) {
      'x' || 'X' => 16,
      'o' || 'O' => 8,
      'b' || 'B' => 2,
      _ => null,
    };
    if (radix != null) {
      // JS forbids a sign on radix-prefixed literals, and `int.tryParse`
      // would accept one, so reject explicitly.
      final digits = text.substring(2);
      if (digits.startsWith('+') || digits.startsWith('-')) return null;
      final parsed = int.tryParse(digits, radix: radix);
      return parsed?.toDouble();
    }
  }
  return double.tryParse(text);
}

/// Whether this client may take an app update *right now*.
///
/// Port of upstream `shouldAdmitAppUpdate`. Five short-circuits admit
/// unconditionally, in this exact order, because each one means "staged
/// rollout does not apply here":
///
/// 1. a manual check — the user asked, so never make them wait;
/// 2. any non-stable channel (beta) — pre-release testers get everything;
/// 3. no `rolloutHours` in the manifest — no staged rollout configured;
/// 4. `rolloutHours == 0` — an explicitly instant rollout (and it also guards
///    the division below);
/// 5. a missing, empty or unparseable `releaseDate` — nothing to measure age
///    against, so failing open is the safe direction.
///
/// Otherwise the release's age is converted to a percentage of the rollout
/// window and compared against this install's [bucket]: a client is admitted
/// once the ramp has passed its slot. Note the comparison is strict (`<`), so
/// the bucket-zero client is *not* admitted at the exact release instant — it
/// is admitted one millisecond later.
///
/// A release dated in the future is rejected outright (a negative age is not
/// treated as "0% rolled out" — it never reaches the percentage compare).
///
/// Deviation: upstream takes `now` as an epoch-millisecond number and
/// `releaseDate` as a string it feeds to `new Date(...)`. [now] is a [DateTime]
/// here per this repo's injected-clock convention, and the release string is
/// parsed by [_parseReleaseDate].
bool shouldAdmitAppUpdate({
  required DesktopAppReleaseChannel channel,
  required DesktopAppUpdateCheckIntent intent,
  required double? rolloutHours,
  required String? releaseDate,
  required DateTime now,
  required double bucket,
}) {
  if (intent == DesktopAppUpdateCheckIntent.manual) return true;
  if (channel != DesktopAppReleaseChannel.stable) return true;
  if (rolloutHours == null) return true;
  if (rolloutHours == 0) return true;
  // JS truthiness: upstream `!args.releaseDate` also rejects `""`.
  if (!_hasText(releaseDate)) return true;

  final releaseTime = _parseReleaseDate(releaseDate!);
  if (releaseTime == null) return true;

  final ageHours =
      now.difference(releaseTime).inMicroseconds / Duration.microsecondsPerHour;
  if (ageHours < 0) return false;

  final pct = math.min(100.0, (ageHours / rolloutHours) * 100);
  return bucket * 100 < pct;
}

/// Parses a manifest `releaseDate`, returning null where JS yields `NaN`.
///
/// Deviation: JS `new Date(str)` accepts more than ISO-8601 — notably a
/// date-only `"2026-04-28"` (interpreted as *UTC* midnight) and legacy RFC-2822
/// forms like `"Apr 28 2026"`. `DateTime.tryParse` accepts date-only but treats
/// it as *local* midnight, and rejects RFC-2822 entirely. Two adjustments keep
/// the observable behaviour aligned for everything electron-updater actually
/// emits (always a full `toISOString()` timestamp):
///
/// - a bare `YYYY-MM-DD` is pinned to UTC, matching JS;
/// - a legacy RFC-2822 string stays unparseable, so the gate takes the
///   "unparseable release date → admit" branch instead of computing an age.
///   Upstream would have computed one; no Paseo manifest carries that form.
DateTime? _parseReleaseDate(String value) {
  final normalized = _dateOnlyPattern.hasMatch(value)
      ? '${value}T00:00:00.000Z'
      : value;
  return DateTime.tryParse(normalized);
}

final RegExp _dateOnlyPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// This install's stable position in `[0, 1)` on the rollout ramp.
///
/// Port of upstream `bucketFromStagingUserId`, which is
/// `UUID.parse(id).readUInt32BE(12) / 0x100000000` from `builder-util-runtime`.
/// The staging user id is a UUID electron-updater persists once per install, so
/// the bucket is stable across checks: a client admitted at 30% stays admitted.
///
/// Deviation: `builder-util-runtime`'s `UUID.parse` is an *unvalidated* reader,
/// not a UUID validator. Verified by executing the frozen module under Node:
///
/// - it walks fixed character offsets, skipping the four dash positions, so
///   bytes 12..15 always come from characters 28..35 regardless of the input;
/// - its hex table is lowercase-only, so an uppercase digit yields `undefined`,
///   which a `Buffer` write coerces to `0` — `"AAAAAAAA-BBBB-CCCC-DDDD-
///   EEEEFFFF0102"` buckets as `0x00000102 / 2^32`, not `0xFFFF0102 / 2^32`;
/// - a short or non-UUID string never throws, it just reads zeroes, so
///   `"not-a-uuid"` and `""` both bucket as `0`.
///
/// This port reproduces all three rather than validating, because validating
/// would move an install from bucket 0 to an exception.
///
/// Ground truth captured from Node: all-`f` → `0.9999999997671694`, all-`0` →
/// `0`, `123e4567-e89b-42d3-a456-426614174000` → `0.07847976684570312`.
double bucketFromStagingUserId(String stagingUserId) {
  // Byte 12 of the parsed buffer starts at character 28; each byte is two
  // characters and no dash falls inside the final group.
  var slot = 0;
  for (var byteIndex = 0; byteIndex < 4; byteIndex++) {
    final offset = 28 + byteIndex * 2;
    slot = (slot << 8) | _hexByte(stagingUserId, offset);
  }
  return slot / 0x100000000;
}

int _hexByte(String source, int offset) {
  if (offset + 1 >= source.length) return 0;
  final high = _hexDigit(source.codeUnitAt(offset));
  final low = _hexDigit(source.codeUnitAt(offset + 1));
  if (high == null || low == null) return 0;
  return (high << 4) | low;
}

/// Lowercase-only on purpose — see [bucketFromStagingUserId].
int? _hexDigit(int codeUnit) {
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x30;
  if (codeUnit >= 0x61 && codeUnit <= 0x66) return codeUnit - 0x61 + 10;
  return null;
}

// ---------------------------------------------------------------------------
// browser-profile.ts
// ---------------------------------------------------------------------------

/// The Electron partition backing Paseo's built-in browser.
///
/// A single `persist:` partition means every browser tab shares one cookie jar,
/// so a login in one tab is visible in the next.
const String paseoBrowserProfilePartition = 'persist:paseo-browser';

/// The storage buckets "clear browsing data" wipes.
///
/// Deviation: upstream is a `readonly string[]` tuple whose members double as
/// the TypeScript union constraining `clearStorageData`. Repo style turns a
/// string union into an enum; [wireName] keeps the exact Electron spelling
/// (note `indexdb`, not `indexeddb` — that is Electron's own spelling).
enum BrowserProfileStorageType {
  cookies('cookies'),
  filesystem('filesystem'),
  indexdb('indexdb'),
  localstorage('localstorage'),
  serviceworkers('serviceworkers'),
  cachestorage('cachestorage'),
  websql('websql');

  const BrowserProfileStorageType(this.wireName);

  /// The literal string Electron's `clearStorageData` expects.
  final String wireName;
}

/// Every storage bucket, in upstream's declaration order.
///
/// The order is preserved because it is passed straight through to the host and
/// the upstream suite asserts on the exact array.
const List<BrowserProfileStorageType> paseoBrowserProfileStorageTypes =
    <BrowserProfileStorageType>[
      BrowserProfileStorageType.cookies,
      BrowserProfileStorageType.filesystem,
      BrowserProfileStorageType.indexdb,
      BrowserProfileStorageType.localstorage,
      BrowserProfileStorageType.serviceworkers,
      BrowserProfileStorageType.cachestorage,
      BrowserProfileStorageType.websql,
    ];

/// The argument bag handed to [BrowserProfileSession.clearStorageData].
///
/// Kept as an object rather than a bare list so the call keeps upstream's
/// `{ storages: [...] }` shape — the host API is Electron's and takes a named
/// options object that may grow more keys.
final class BrowserProfileStorageClearRequest {
  const BrowserProfileStorageClearRequest({required this.storages});

  final List<BrowserProfileStorageType> storages;

  @override
  bool operator ==(Object other) =>
      other is BrowserProfileStorageClearRequest &&
      _listEquals(other.storages, storages);

  @override
  int get hashCode => Object.hashAll(storages);

  @override
  String toString() => 'BrowserProfileStorageClearRequest(storages: $storages)';
}

/// One Electron `Session` the browser profile is spread across.
///
/// Injected rather than imported so the wipe order is testable with no Electron
/// present.
abstract interface class BrowserProfileSession {
  /// Wipes the named site-data buckets (cookies, localStorage, …).
  Future<void> clearStorageData(BrowserProfileStorageClearRequest request);

  /// Wipes the HTTP cache. Separate from site data in Electron's API.
  Future<void> clearCache();

  /// Wipes cached HTTP auth credentials, which survive a cookie wipe.
  Future<void> clearAuthCache();
}

/// A live page that must be reloaded after its profile is wiped.
///
/// Narrower than [BrowserProfileWebContents] on purpose: the wipe only needs an
/// id for logging plus liveness and reload, and takes them as a lambda so the
/// caller decides how guests are discovered.
abstract interface class BrowserProfileGuest {
  /// Electron's `webContents.id`, used only to label a reload failure.
  int get id;

  bool isDestroyed();

  void reload();
}

/// An Electron `WebContents`, as seen while filtering for profile members.
abstract interface class BrowserProfileWebContents
    implements BrowserProfileGuest {
  /// The `Session` object this contents belongs to.
  ///
  /// Compared by *identity* against the profile session, exactly as upstream's
  /// `contents.session === input.profileSession` does.
  Object get session;

  /// Electron's contents type: `"webview"`, `"window"`, `"browserView"`, …
  String getType();
}

/// The slice of Electron's `session` module the profile rules touch.
abstract interface class BrowserProfileSessions {
  BrowserProfileSession fromPartition(String partition);
}

/// The one shared browser profile session.
BrowserProfileSession getPaseoBrowserProfileSession(
  BrowserProfileSessions sessions,
) => sessions.fromPartition(paseoBrowserProfilePartition);

/// Matches the two shapes a pre-v0.1.108 per-tab browser id could take.
///
/// Either a v4 UUID or the `<epoch-millis>-<hex>` fallback the renderer used
/// when `crypto.randomUUID` was unavailable. Case-insensitive, anchored at both
/// ends, so an attacker-supplied value cannot smuggle a path segment into the
/// partition name it is interpolated into.
final RegExp _legacyBrowserIdPattern = RegExp(
  r'^(?:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
  r'|\d{13,}-[0-9a-f]+)$',
  caseSensitive: false,
);

/// Upstream `MAX_LEGACY_BROWSER_PROFILES`: a hard cap so a corrupted stored
/// array cannot make the wipe open thousands of Electron sessions.
const int _maxLegacyBrowserProfiles = 1000;

/// Filters a stored, untrusted array down to well-formed unique browser ids.
///
/// Port of upstream `readLegacyPaseoBrowserIds`. [input] is deliberately typed
/// `Object?` — it comes from disk, so a non-list, a list of numbers, or a list
/// with duplicates are all expected and all yield an empty/deduplicated result
/// rather than an error.
///
/// The cap is checked *after* each insert, so a run of duplicates that does not
/// grow the set still re-tests it — matching upstream's `browserIds.size >=
/// MAX` placement inside the loop body.
List<String> readLegacyPaseoBrowserIds(Object? input) {
  if (input is! List) return const <String>[];
  final browserIds = <String>{};
  for (final value in input) {
    if (value is String && _legacyBrowserIdPattern.hasMatch(value)) {
      browserIds.add(value);
      if (browserIds.length >= _maxLegacyBrowserProfiles) break;
    }
  }
  return List<String>.unmodifiable(browserIds);
}

/// Every session "clear browsing data" has to wipe.
///
/// The shared profile always comes first, followed by one session per surviving
/// legacy per-tab partition. The upstream return type is a non-empty tuple
/// (`[Session, ...Session[]]`); Dart has no non-empty list type, but the shared
/// profile is unconditional so the result is never empty.
///
/// COMPAT(browserProfile): the legacy partitions were added in v0.1.108 and
/// upstream marks them for removal after 2027-01-15.
List<BrowserProfileSession> getPaseoBrowserProfileSessions(
  BrowserProfileSessions sessions,
  List<String> legacyBrowserIds,
) => <BrowserProfileSession>[
  getPaseoBrowserProfileSession(sessions),
  for (final browserId in legacyBrowserIds)
    sessions.fromPartition('$paseoBrowserProfilePartition-$browserId'),
];

/// Resolves the legacy session for a single browser id, or null if the id is
/// malformed.
///
/// Used when one tab closes: only that tab's old partition is cleaned up. The
/// id is re-validated through [readLegacyPaseoBrowserIds] rather than trusted,
/// so [BrowserProfileSessions.fromPartition] is never called for a rejected id.
BrowserProfileSession? getLegacyPaseoBrowserProfileSession(
  BrowserProfileSessions sessions,
  String browserId,
) {
  final validated = readLegacyPaseoBrowserIds(<String>[browserId]);
  if (validated.isEmpty) return null;
  return sessions.fromPartition(
    '$paseoBrowserProfilePartition-${validated.first}',
  );
}

/// The live pages belonging to a given browser profile session.
///
/// Both `webview` (an embedded tab) and `window` (a popup the page opened) are
/// included; anything destroyed, or belonging to another session, is dropped.
/// Session comparison is by identity, matching upstream's `===`.
List<BrowserProfileGuest> listPaseoBrowserProfileGuests({
  required Object profileSession,
  required List<BrowserProfileWebContents> webContents,
}) => <BrowserProfileGuest>[
  for (final contents in webContents)
    if (!contents.isDestroyed() &&
        (contents.getType() == 'webview' || contents.getType() == 'window') &&
        identical(contents.session, profileSession))
      contents,
];

/// Wipes every browser profile session, then reloads the live guests.
///
/// Port of upstream `clearPaseoBrowserProfile`. Two ordering guarantees matter
/// and are both load-bearing:
///
/// - all three wipes for all sessions are started *together* and fully awaited
///   before any reload, so no guest can re-populate the jar mid-wipe;
/// - if any wipe fails the error propagates and **no** guest is reloaded, so
///   the user is never shown pages that look cleared but are not.
///
/// Individual reload failures are different: a guest can disappear between the
/// listing and the reload, so each is caught and reported through
/// [logReloadError] instead of aborting the remaining reloads.
///
/// Deviation: `Promise.all` rejects on the first rejection without waiting for
/// its siblings, which is `eagerError: true` — not [Future.wait]'s default. As
/// with `Promise.all`, a *later* failure among the siblings then surfaces as an
/// unhandled async error; that hazard is upstream's too.
Future<void> clearPaseoBrowserProfile({
  required List<BrowserProfileSession> profileSessions,
  required List<BrowserProfileGuest> Function() listGuests,
  required void Function(int guestId, Object error) logReloadError,
}) async {
  await Future.wait<void>(<Future<void>>[
    for (final profileSession in profileSessions) ...<Future<void>>[
      profileSession.clearStorageData(
        const BrowserProfileStorageClearRequest(
          storages: paseoBrowserProfileStorageTypes,
        ),
      ),
      profileSession.clearCache(),
      profileSession.clearAuthCache(),
    ],
  ], eagerError: true);

  for (final guest in listGuests()) {
    if (guest.isDestroyed()) continue;
    try {
      guest.reload();
    } catch (error) {
      logReloadError(guest.id, error);
    }
  }
}

// ---------------------------------------------------------------------------
// editor-targets/target.ts
// ---------------------------------------------------------------------------

/// The host OS, as the editor detection rules see it.
///
/// Deviation: upstream is Node's `NodeJS.Platform` string union, which has a
/// dozen members the rules never name. Only `darwin` and `win32` are branched
/// on; [other] stands in for every remaining Node platform so the three
/// file-manager targets (`finder` / `explorer` / `file-manager`) still partition
/// the space exactly as upstream does.
enum EditorTargetPlatform {
  darwin,
  linux,
  win32,
  other;

  /// Maps a Node `process.platform` string onto this enum.
  static EditorTargetPlatform fromNodePlatform(String value) => switch (value) {
    'darwin' => darwin,
    'linux' => linux,
    'win32' => win32,
    _ => other,
  };
}

/// Whether a target opens code or opens a folder.
///
/// The UI groups editors separately from file managers, and stored preferences
/// persist [wireName], so the hyphenated spelling is preserved.
enum EditorTargetKind {
  editor('editor'),
  fileManager('file-manager');

  const EditorTargetKind(this.wireName);

  final String wireName;
}

/// The two built-in glyphs a target can fall back to when it ships no icon.
enum EditorTargetSymbol { folder, terminal }

/// How a target renders in the picker: either a real icon or a built-in glyph.
///
/// Deviation: upstream is a discriminated union on a `kind` field; repo style
/// makes it a sealed hierarchy.
sealed class EditorTargetIcon {
  const EditorTargetIcon();
}

/// A bitmap the host loaded off disk, already encoded as a `data:` URL.
final class EditorTargetImageIcon extends EditorTargetIcon {
  const EditorTargetImageIcon(this.dataUrl);

  final String dataUrl;

  @override
  bool operator ==(Object other) =>
      other is EditorTargetImageIcon && other.dataUrl == dataUrl;

  @override
  int get hashCode => Object.hash(EditorTargetImageIcon, dataUrl);

  @override
  String toString() => 'EditorTargetImageIcon($dataUrl)';
}

/// A built-in glyph, used by targets that ship no bundled icon.
final class EditorTargetSymbolIcon extends EditorTargetIcon {
  const EditorTargetSymbolIcon(this.name);

  final EditorTargetSymbol name;

  @override
  bool operator ==(Object other) =>
      other is EditorTargetSymbolIcon && other.name == name;

  @override
  int get hashCode => Object.hash(EditorTargetSymbolIcon, name);

  @override
  String toString() => 'EditorTargetSymbolIcon(${name.name})';
}

/// One installed target, as the picker renders it.
final class EditorTargetDescriptor {
  const EditorTargetDescriptor({
    required this.id,
    required this.label,
    required this.kind,
    required this.icon,
  });

  /// Stable across releases — stored preferences persist it.
  final String id;

  final String label;
  final EditorTargetKind kind;
  final EditorTargetIcon icon;

  @override
  bool operator ==(Object other) =>
      other is EditorTargetDescriptor &&
      other.id == id &&
      other.label == label &&
      other.kind == kind &&
      other.icon == icon;

  @override
  int get hashCode => Object.hash(id, label, kind, icon);

  @override
  String toString() =>
      'EditorTargetDescriptor(id: $id, label: $label, kind: $kind, '
      'icon: $icon)';
}

/// What to open, and optionally where inside it.
///
/// [workspacePath] is always opened as the project root; [filePath] (when
/// given) is additionally focused. Remember the JS-truthiness rule: `""` for
/// [filePath] and `0` for [line]/[column] mean "not given".
final class EditorTargetLaunchInput {
  const EditorTargetLaunchInput({
    required this.workspacePath,
    this.filePath,
    this.line,
    this.column,
  });

  final String workspacePath;
  final String? filePath;

  /// 1-based, as every editor CLI expects.
  final int? line;

  /// 1-based. Ignored by targets whose CLI cannot express a column.
  final int? column;
}

/// A launch plus the id of the target that should handle it.
///
/// Deviation: upstream is the intersection type
/// `EditorTargetLaunchInput & { editorId: string }`; Dart expresses that as a
/// subclass, which is legal here only because both live in this library.
final class EditorTargetOpenInput extends EditorTargetLaunchInput {
  const EditorTargetOpenInput({
    required this.editorId,
    required super.workspacePath,
    super.filePath,
    super.line,
    super.column,
  });

  final String editorId;
}

/// Every OS capability the editor rules need, as one injected port.
///
/// Upstream this is backed by `node:fs`, `node:child_process` and Electron's
/// `shell`; nothing in the rules below touches `dart:io`.
abstract interface class EditorTargetRuntime {
  /// Node `process.platform`, already mapped onto the enum.
  EditorTargetPlatform get platform;

  /// Node `process.env`. Only `HOME`, `LOCALAPPDATA` and `ProgramFiles` are
  /// read, and each is JS-truthiness checked, so a blank value is ignored.
  Map<String, String> get env;

  bool pathExists(String path);

  /// Rejects relative paths and remote URIs — a launch argument must be a real
  /// local path before it is handed to a process.
  bool isAbsolutePath(String path);

  /// Returns the first of [commands] that resolves to an executable, or null.
  ///
  /// Ordering is the caller's priority order, so a PATH entry wins over a
  /// guessed install location.
  String? resolveCommand(List<String> commands);

  /// Starts a process that outlives the desktop app.
  Future<void> spawnDetached({
    required String command,
    required List<String> args,
  });

  /// Electron `shell.openPath` — opens a folder in the system file manager.
  Future<void> openPath(String path);

  /// Electron `shell.showItemInFolder` — reveals a file, selected, in its
  /// parent folder. Synchronous in Electron, so it stays synchronous here.
  void revealPath(String path);

  /// Loads a bundled icon by file name and returns it as a `data:` URL.
  Future<EditorTargetIcon> loadIcon(String fileName);

  /// macOS only: whether an `.app` bundle with this name is installed.
  ///
  /// A second detection path for editors that ship no PATH shim.
  bool hasMacApplication(String applicationName);

  /// macOS `open -a <app> <paths...>`.
  ///
  /// Cannot express a line/column, which is why every target prefers a real
  /// command when one exists.
  Future<void> openMacApplication({
    required String applicationName,
    required List<String> paths,
  });
}

/// One external editor or file manager Paseo knows how to drive.
abstract interface class EditorTarget {
  /// Stable id persisted in the user's preferred-editor setting.
  String get id;

  /// The picker row. May hit the disk to load an icon, hence async.
  Future<EditorTargetDescriptor> describe(EditorTargetRuntime runtime);

  Future<bool> isInstalled(EditorTargetRuntime runtime);

  /// Opens [input]. Throws [EditorTargetError] if the target vanished between
  /// detection and launch.
  Future<void> launch(
    EditorTargetLaunchInput input,
    EditorTargetRuntime runtime,
  );
}

/// A launch or lookup that could not be satisfied.
///
/// Deviation: upstream throws bare `Error`s; [message] is preserved verbatim
/// because it is surfaced to the user.
final class EditorTargetError implements Exception {
  const EditorTargetError(this.message);

  final String message;

  @override
  String toString() => 'EditorTargetError: $message';
}

// ---------------------------------------------------------------------------
// editor-targets/targets/*.ts
//
// Upstream ships one small module per editor, each an object literal. They fall
// into five behavioural families, so this port keeps five private classes and
// one public `const` per upstream module — the public surface (ids, labels,
// icons, command lists, argument shapes) is unchanged.
// ---------------------------------------------------------------------------

/// How a target produces its picker icon.
sealed class _IconSource {
  const _IconSource();

  Future<EditorTargetIcon> resolve(EditorTargetRuntime runtime);
}

final class _AssetIcon extends _IconSource {
  const _AssetIcon(this.fileName);

  final String fileName;

  @override
  Future<EditorTargetIcon> resolve(EditorTargetRuntime runtime) =>
      runtime.loadIcon(fileName);
}

final class _SymbolIconSource extends _IconSource {
  const _SymbolIconSource(this.symbol);

  final EditorTargetSymbol symbol;

  @override
  Future<EditorTargetIcon> resolve(EditorTargetRuntime runtime) async =>
      EditorTargetSymbolIcon(symbol);
}

/// `<file>:<line>[:<column>]`, the position syntax the VS Code family uses.
String _gotoLocation(EditorTargetLaunchInput input) {
  // Only reached when `filePath` is truthy; upstream asserts the same with `!`.
  if (!_hasPosition(input.line)) return input.filePath!;
  return _hasPosition(input.column)
      ? '${input.filePath}:${input.line}:${input.column}'
      : '${input.filePath}:${input.line}';
}

/// `[workspace]`, `[workspace, file]`, or `[workspace, --goto, file:l:c]`.
List<String> _gotoLaunchArgs(EditorTargetLaunchInput input) {
  if (!_hasText(input.filePath)) return <String>[input.workspacePath];
  if (!_hasPosition(input.line)) {
    return <String>[input.workspacePath, input.filePath!];
  }
  return <String>[input.workspacePath, '--goto', _gotoLocation(input)];
}

/// The VS Code family: a PATH shim, platform-specific install locations, and a
/// macOS `.app` fallback. Covers VS Code, Insiders, VSCodium and Cursor.
final class _CodeStyleTarget implements EditorTarget {
  const _CodeStyleTarget({
    required this.id,
    required this.label,
    required this.macApplicationName,
    required this.baseCommands,
    required this.icon,
    this.macApplicationSuffixes = const <String>[],
    this.localAppDataSuffixes = const <String>[],
    this.programFilesSuffixes = const <String>[],
  });

  @override
  final String id;

  final String label;

  /// The `.app` bundle name, used both for detection and for `open -a`.
  final String macApplicationName;

  /// Always tried first — a PATH shim beats a guessed install location.
  final List<String> baseCommands;

  /// Absolute-from-`/` bundle paths, tried on macOS both as-is and prefixed
  /// with `$HOME` (upstream lists the same suffix twice for exactly that).
  final List<String> macApplicationSuffixes;

  final List<String> localAppDataSuffixes;
  final List<String> programFilesSuffixes;
  final _IconSource icon;

  List<String> _commands(EditorTargetRuntime runtime) {
    final candidates = <String>[...baseCommands];
    if (runtime.platform == EditorTargetPlatform.darwin) {
      candidates.addAll(macApplicationSuffixes);
      final home = runtime.env['HOME'];
      // JS truthiness: upstream `if (runtime.env.HOME)` skips a blank value.
      if (_hasText(home)) {
        candidates.addAll(macApplicationSuffixes.map((s) => '$home$s'));
      }
    }
    if (runtime.platform == EditorTargetPlatform.win32) {
      final localAppData = runtime.env['LOCALAPPDATA'];
      if (_hasText(localAppData)) {
        candidates.addAll(localAppDataSuffixes.map((s) => '$localAppData$s'));
      }
      final programFiles = runtime.env['ProgramFiles'];
      if (_hasText(programFiles)) {
        candidates.addAll(programFilesSuffixes.map((s) => '$programFiles$s'));
      }
    }
    return candidates;
  }

  @override
  Future<EditorTargetDescriptor> describe(EditorTargetRuntime runtime) async =>
      EditorTargetDescriptor(
        id: id,
        label: label,
        kind: EditorTargetKind.editor,
        icon: await icon.resolve(runtime),
      );

  @override
  Future<bool> isInstalled(EditorTargetRuntime runtime) async =>
      runtime.resolveCommand(_commands(runtime)) != null ||
      runtime.hasMacApplication(macApplicationName);

  @override
  Future<void> launch(
    EditorTargetLaunchInput input,
    EditorTargetRuntime runtime,
  ) async {
    final command = runtime.resolveCommand(_commands(runtime));
    if (command != null) {
      await runtime.spawnDetached(
        command: command,
        args: _gotoLaunchArgs(input),
      );
      return;
    }
    if (runtime.hasMacApplication(macApplicationName)) {
      // `open -a` cannot carry a position, so the line/column is dropped here.
      await runtime.openMacApplication(
        applicationName: macApplicationName,
        paths: _hasText(input.filePath)
            ? <String>[input.workspacePath, input.filePath!]
            : <String>[input.workspacePath],
      );
      return;
    }
    throw EditorTargetError('$label is not installed');
  }
}

/// A VS Code-derived editor detected only through a fixed command list, with no
/// install-location guessing and no macOS bundle fallback. Antigravity, Trae.
final class _SimpleGotoTarget implements EditorTarget {
  const _SimpleGotoTarget({
    required this.id,
    required this.label,
    required this.commands,
    required this.icon,
    this.argumentPrefix = const <String>[],
  });

  @override
  final String id;

  final String label;
  final List<String> commands;

  /// Extra leading arguments, for CLIs with a subcommand (Kiro's `ide`).
  final List<String> argumentPrefix;

  final _IconSource icon;

  @override
  Future<EditorTargetDescriptor> describe(EditorTargetRuntime runtime) async =>
      EditorTargetDescriptor(
        id: id,
        label: label,
        kind: EditorTargetKind.editor,
        icon: await icon.resolve(runtime),
      );

  @override
  Future<bool> isInstalled(EditorTargetRuntime runtime) async =>
      runtime.resolveCommand(commands) != null;

  @override
  Future<void> launch(
    EditorTargetLaunchInput input,
    EditorTargetRuntime runtime,
  ) async {
    final command = runtime.resolveCommand(commands);
    if (command == null) throw EditorTargetError('$label is not installed');
    await runtime.spawnDetached(
      command: command,
      args: <String>[...argumentPrefix, ..._gotoLaunchArgs(input)],
    );
  }
}

/// Zed: positional `file:line:column` instead of `--goto`, plus a macOS bundle
/// fallback.
final class _ZedTarget implements EditorTarget {
  const _ZedTarget();

  @override
  String get id => 'zed';

  static const List<String> _commands = <String>['zed', 'zeditor'];

  @override
  Future<EditorTargetDescriptor> describe(EditorTargetRuntime runtime) async =>
      EditorTargetDescriptor(
        id: id,
        label: 'Zed',
        kind: EditorTargetKind.editor,
        icon: await runtime.loadIcon('zed.png'),
      );

  @override
  Future<bool> isInstalled(EditorTargetRuntime runtime) async =>
      runtime.resolveCommand(_commands) != null ||
      runtime.hasMacApplication('Zed');

  @override
  Future<void> launch(
    EditorTargetLaunchInput input,
    EditorTargetRuntime runtime,
  ) async {
    final command = runtime.resolveCommand(_commands);
    if (command != null) {
      await runtime.spawnDetached(
        command: command,
        args: _hasText(input.filePath)
            ? <String>[input.workspacePath, _gotoLocation(input)]
            : <String>[input.workspacePath],
      );
      return;
    }
    if (runtime.hasMacApplication('Zed')) {
      await runtime.openMacApplication(
        applicationName: 'Zed',
        paths: _hasText(input.filePath)
            ? <String>[input.workspacePath, input.filePath!]
            : <String>[input.workspacePath],
      );
      return;
    }
    throw const EditorTargetError('Zed is not installed');
  }
}

/// The JetBrains family: `--line N --column N <workspace> <file>`, detected via
/// a plain and a `64`-suffixed launcher (the Windows 64-bit executable name).
final class _JetBrainsTarget implements EditorTarget {
  const _JetBrainsTarget({
    required this.id,
    required this.label,
    required this.commands,
    required this.icon,
  });

  @override
  final String id;

  final String label;
  final List<String> commands;
  final _IconSource icon;

  @override
  Future<EditorTargetDescriptor> describe(EditorTargetRuntime runtime) async =>
      EditorTargetDescriptor(
        id: id,
        label: label,
        kind: EditorTargetKind.editor,
        icon: await icon.resolve(runtime),
      );

  @override
  Future<bool> isInstalled(EditorTargetRuntime runtime) async =>
      runtime.resolveCommand(commands) != null;

  @override
  Future<void> launch(
    EditorTargetLaunchInput input,
    EditorTargetRuntime runtime,
  ) async {
    final command = runtime.resolveCommand(commands);
    if (command == null) throw EditorTargetError('$label is not installed');
    if (!_hasText(input.filePath)) {
      await runtime.spawnDetached(
        command: command,
        args: <String>[input.workspacePath],
      );
      return;
    }
    final args = <String>[];
    if (_hasPosition(input.line)) {
      args.addAll(<String>['--line', '${input.line}']);
    }
    if (_hasPosition(input.column)) {
      args.addAll(<String>['--column', '${input.column}']);
    }
    args.addAll(<String>[input.workspacePath, input.filePath!]);
    await runtime.spawnDetached(command: command, args: args);
  }
}

/// The system file manager. Reveals a file when given one, otherwise opens the
/// folder. The three instances differ only in id/label/icon and in which
/// platform reports them installed, so stored preferences keep working when a
/// user moves between machines.
final class _FileManagerTarget implements EditorTarget {
  const _FileManagerTarget({
    required this.id,
    required this.label,
    required this.icon,
    required this.platforms,
  });

  @override
  final String id;

  final String label;

  /// The platforms on which this instance is the file manager. Together the
  /// three instances partition [EditorTargetPlatform] exactly once.
  final List<EditorTargetPlatform> platforms;

  final _IconSource icon;

  @override
  Future<EditorTargetDescriptor> describe(EditorTargetRuntime runtime) async =>
      EditorTargetDescriptor(
        id: id,
        label: label,
        kind: EditorTargetKind.fileManager,
        icon: await icon.resolve(runtime),
      );

  @override
  Future<bool> isInstalled(EditorTargetRuntime runtime) async =>
      platforms.contains(runtime.platform);

  @override
  Future<void> launch(
    EditorTargetLaunchInput input,
    EditorTargetRuntime runtime,
  ) async {
    if (_hasText(input.filePath)) {
      runtime.revealPath(input.filePath!);
      return;
    }
    await runtime.openPath(input.workspacePath);
  }
}

/// Cursor. Ships a bundled macOS command so file positions survive detection.
const EditorTarget cursorTarget = _CodeStyleTarget(
  id: 'cursor',
  label: 'Cursor',
  macApplicationName: 'Cursor',
  baseCommands: <String>['cursor'],
  macApplicationSuffixes: <String>[
    '/Applications/Cursor.app/Contents/Resources/app/bin/cursor',
  ],
  localAppDataSuffixes: <String>[
    '/Programs/cursor/resources/app/bin/cursor.cmd',
    '/Programs/cursor/Cursor.exe',
  ],
  programFilesSuffixes: <String>[
    '/Cursor/resources/app/bin/cursor.cmd',
    '/Cursor/Cursor.exe',
  ],
  icon: _AssetIcon('cursor.png'),
);

/// Trae.
const EditorTarget traeTarget = _SimpleGotoTarget(
  id: 'trae',
  label: 'Trae',
  commands: <String>['trae'],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// Kiro. Its CLI takes an `ide` subcommand before the paths.
const EditorTarget kiroTarget = _SimpleGotoTarget(
  id: 'kiro',
  label: 'Kiro',
  commands: <String>['kiro'],
  argumentPrefix: <String>['ide'],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// Visual Studio Code.
const EditorTarget vscodeTarget = _CodeStyleTarget(
  id: 'vscode',
  label: 'VS Code',
  macApplicationName: 'Visual Studio Code',
  baseCommands: <String>['code'],
  macApplicationSuffixes: <String>[
    '/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code',
  ],
  localAppDataSuffixes: <String>['/Programs/Microsoft VS Code/bin/code.cmd'],
  programFilesSuffixes: <String>['/Microsoft VS Code/bin/code.cmd'],
  icon: _AssetIcon('vscode.png'),
);

/// VS Code Insiders. Note its bundled macOS shim is still named `code`.
const EditorTarget vscodeInsidersTarget = _CodeStyleTarget(
  id: 'vscode-insiders',
  label: 'VS Code Insiders',
  macApplicationName: 'Visual Studio Code - Insiders',
  baseCommands: <String>['code-insiders'],
  macApplicationSuffixes: <String>[
    '/Applications/Visual Studio Code - Insiders.app/Contents/Resources/'
        'app/bin/code',
  ],
  localAppDataSuffixes: <String>[
    '/Programs/Microsoft VS Code Insiders/bin/code-insiders.cmd',
  ],
  programFilesSuffixes: <String>[
    '/Microsoft VS Code Insiders/bin/code-insiders.cmd',
  ],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// VSCodium.
const EditorTarget vscodiumTarget = _CodeStyleTarget(
  id: 'vscodium',
  label: 'VSCodium',
  macApplicationName: 'VSCodium',
  baseCommands: <String>['codium'],
  macApplicationSuffixes: <String>[
    '/Applications/VSCodium.app/Contents/Resources/app/bin/codium',
  ],
  localAppDataSuffixes: <String>['/Programs/VSCodium/bin/codium.cmd'],
  programFilesSuffixes: <String>['/VSCodium/bin/codium.cmd'],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// Zed.
const EditorTarget zedTarget = _ZedTarget();

/// Antigravity.
const EditorTarget antigravityTarget = _SimpleGotoTarget(
  id: 'antigravity',
  label: 'Antigravity',
  commands: <String>['agy', 'antigravity'],
  icon: _AssetIcon('antigravity.png'),
);

/// IntelliJ IDEA.
const EditorTarget intellijIdeaTarget = _JetBrainsTarget(
  id: 'intellij-idea',
  label: 'IntelliJ IDEA',
  commands: <String>['idea', 'idea64'],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// Aqua.
const EditorTarget aquaTarget = _JetBrainsTarget(
  id: 'aqua',
  label: 'Aqua',
  commands: <String>['aqua', 'aqua64'],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// CLion.
const EditorTarget clionTarget = _JetBrainsTarget(
  id: 'clion',
  label: 'CLion',
  commands: <String>['clion', 'clion64'],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// DataGrip.
const EditorTarget datagripTarget = _JetBrainsTarget(
  id: 'datagrip',
  label: 'DataGrip',
  commands: <String>['datagrip', 'datagrip64'],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// DataSpell.
const EditorTarget dataspellTarget = _JetBrainsTarget(
  id: 'dataspell',
  label: 'DataSpell',
  commands: <String>['dataspell', 'dataspell64'],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// GoLand.
const EditorTarget golandTarget = _JetBrainsTarget(
  id: 'goland',
  label: 'GoLand',
  commands: <String>['goland', 'goland64'],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// PhpStorm.
const EditorTarget phpstormTarget = _JetBrainsTarget(
  id: 'phpstorm',
  label: 'PhpStorm',
  commands: <String>['phpstorm', 'phpstorm64'],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// PyCharm.
const EditorTarget pycharmTarget = _JetBrainsTarget(
  id: 'pycharm',
  label: 'PyCharm',
  commands: <String>['pycharm', 'pycharm64'],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// Rider.
const EditorTarget riderTarget = _JetBrainsTarget(
  id: 'rider',
  label: 'Rider',
  commands: <String>['rider', 'rider64'],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// RubyMine.
const EditorTarget rubymineTarget = _JetBrainsTarget(
  id: 'rubymine',
  label: 'RubyMine',
  commands: <String>['rubymine', 'rubymine64'],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// RustRover.
const EditorTarget rustroverTarget = _JetBrainsTarget(
  id: 'rustrover',
  label: 'RustRover',
  commands: <String>['rustrover', 'rustrover64'],
  icon: _SymbolIconSource(EditorTargetSymbol.terminal),
);

/// WebStorm. The only JetBrains IDE upstream ships a bundled icon for.
const EditorTarget webstormTarget = _JetBrainsTarget(
  id: 'webstorm',
  label: 'WebStorm',
  commands: <String>['webstorm', 'webstorm64'],
  icon: _AssetIcon('webstorm.png'),
);

/// macOS Finder.
const EditorTarget finderTarget = _FileManagerTarget(
  id: 'finder',
  label: 'Finder',
  platforms: <EditorTargetPlatform>[EditorTargetPlatform.darwin],
  icon: _AssetIcon('finder.png'),
);

/// Windows Explorer.
const EditorTarget explorerTarget = _FileManagerTarget(
  id: 'explorer',
  label: 'Explorer',
  platforms: <EditorTargetPlatform>[EditorTargetPlatform.win32],
  icon: _SymbolIconSource(EditorTargetSymbol.folder),
);

/// The generic file manager on every non-macOS, non-Windows platform.
const EditorTarget fileManagerTarget = _FileManagerTarget(
  id: 'file-manager',
  label: 'Files',
  platforms: <EditorTargetPlatform>[
    EditorTargetPlatform.linux,
    EditorTargetPlatform.other,
  ],
  icon: _SymbolIconSource(EditorTargetSymbol.folder),
);

// ---------------------------------------------------------------------------
// editor-targets/registry.ts
// ---------------------------------------------------------------------------

/// Every known target, in the order the picker lists them.
///
/// The order is product intent, not alphabetical: AI-first editors, then the VS
/// Code family, then Zed/Antigravity, then JetBrains, then the file managers
/// last.
const List<EditorTarget> editorTargets = <EditorTarget>[
  cursorTarget,
  traeTarget,
  kiroTarget,
  vscodeTarget,
  vscodeInsidersTarget,
  vscodiumTarget,
  zedTarget,
  antigravityTarget,
  intellijIdeaTarget,
  aquaTarget,
  clionTarget,
  datagripTarget,
  dataspellTarget,
  golandTarget,
  phpstormTarget,
  pycharmTarget,
  riderTarget,
  rubymineTarget,
  rustroverTarget,
  webstormTarget,
  finderTarget,
  explorerTarget,
  fileManagerTarget,
];

/// Describes every installed target, preserving registration order.
///
/// Deliberately sequential rather than a `Future.wait`: detection can shell out,
/// and upstream's `for..of` with `await` keeps the probes serialised so a
/// machine with twenty IDEs does not fan out twenty process spawns at once.
Future<List<EditorTargetDescriptor>> listAvailableEditorTargets(
  EditorTargetRuntime runtime, [
  List<EditorTarget> targets = editorTargets,
]) async {
  final descriptors = <EditorTargetDescriptor>[];
  for (final target in targets) {
    if (await target.isInstalled(runtime)) {
      descriptors.add(await target.describe(runtime));
    }
  }
  return descriptors;
}

/// Looks up a target by its persisted id.
///
/// Throws [EditorTargetError] rather than returning null: a stored preference
/// naming a target this build no longer ships is a real error the user should
/// see, not something to silently fall back from.
EditorTarget getEditorTarget(
  String id, [
  List<EditorTarget> targets = editorTargets,
]) {
  for (final candidate in targets) {
    if (candidate.id == id) return candidate;
  }
  throw EditorTargetError('Unknown editor target: $id');
}

/// Validates an open request, then hands it to the chosen target.
///
/// Every check happens *before* any process is spawned, in upstream's order:
/// the workspace path must be absolute and must exist; the file path, when
/// given, must be absolute and must exist; the target must be known; and the
/// target must still be installed. The path checks come first because they
/// guard what is about to become a process argument.
///
/// JS truthiness: an empty [EditorTargetOpenInput.filePath] skips file
/// validation entirely and reaches the target as "no file", matching upstream's
/// `if (input.filePath)`.
Future<void> openEditorTarget(
  EditorTargetOpenInput input,
  EditorTargetRuntime runtime, [
  List<EditorTarget> targets = editorTargets,
]) async {
  if (!runtime.isAbsolutePath(input.workspacePath)) {
    throw const EditorTargetError(
      'Editor target workspace path must be an absolute local path',
    );
  }
  if (!runtime.pathExists(input.workspacePath)) {
    throw EditorTargetError('Path does not exist: ${input.workspacePath}');
  }
  if (_hasText(input.filePath)) {
    if (!runtime.isAbsolutePath(input.filePath!)) {
      throw const EditorTargetError(
        'Editor target file path must be an absolute local path',
      );
    }
    if (!runtime.pathExists(input.filePath!)) {
      throw EditorTargetError('Path does not exist: ${input.filePath}');
    }
  }

  final target = getEditorTarget(input.editorId, targets);
  if (!await target.isInstalled(runtime)) {
    final descriptor = await target.describe(runtime);
    throw EditorTargetError('Editor target unavailable: ${descriptor.label}');
  }
  await target.launch(input, runtime);
}

// ---------------------------------------------------------------------------
// settings/desktop-settings-commands.ts
// ---------------------------------------------------------------------------

/// The daemon half of the persisted desktop settings.
///
/// Deviation: this repo already has a `DesktopSettings` in
/// `state/desktop_settings_provider.dart`, but it is a *different* document —
/// it models tray residency (`autoStartAtLogin`, `keepRunningAfterQuit`) and
/// has no release channel and no `manageBuiltInDaemon`. Only
/// `keepRunningAfterQuit` overlaps, and there it is a top-level Riverpod-backed
/// preference rather than a nested field of an on-disk JSON document. The two
/// cannot be merged without editing that file, so upstream's shape is modelled
/// here under a `Paseo` prefix and the conflict is left for a later
/// reconciliation.
final class PaseoDesktopDaemonSettings {
  const PaseoDesktopDaemonSettings({
    required this.manageBuiltInDaemon,
    required this.keepRunningAfterQuit,
  });

  /// Whether the desktop app owns the built-in daemon's lifecycle.
  final bool manageBuiltInDaemon;

  /// Whether quitting the window leaves the managed daemon running.
  final bool keepRunningAfterQuit;

  PaseoDesktopDaemonSettings copyWith({
    bool? manageBuiltInDaemon,
    bool? keepRunningAfterQuit,
  }) => PaseoDesktopDaemonSettings(
    manageBuiltInDaemon: manageBuiltInDaemon ?? this.manageBuiltInDaemon,
    keepRunningAfterQuit: keepRunningAfterQuit ?? this.keepRunningAfterQuit,
  );

  @override
  bool operator ==(Object other) =>
      other is PaseoDesktopDaemonSettings &&
      other.manageBuiltInDaemon == manageBuiltInDaemon &&
      other.keepRunningAfterQuit == keepRunningAfterQuit;

  @override
  int get hashCode => Object.hash(manageBuiltInDaemon, keepRunningAfterQuit);

  @override
  String toString() =>
      'PaseoDesktopDaemonSettings(manageBuiltInDaemon: $manageBuiltInDaemon, '
      'keepRunningAfterQuit: $keepRunningAfterQuit)';
}

/// The persisted desktop settings document, as the command bus returns it.
///
/// Only the value type is ported here — the on-disk store itself
/// (`desktop-settings.ts`) is outside this cluster and is injected as
/// [PaseoDesktopSettingsStore].
final class PaseoDesktopSettings {
  const PaseoDesktopSettings({
    required this.releaseChannel,
    required this.daemon,
  });

  /// Reuses the existing [DesktopAppReleaseChannel] rather than redeclaring
  /// upstream's identical `AppReleaseChannel` union.
  final DesktopAppReleaseChannel releaseChannel;

  final PaseoDesktopDaemonSettings daemon;

  PaseoDesktopSettings copyWith({
    DesktopAppReleaseChannel? releaseChannel,
    PaseoDesktopDaemonSettings? daemon,
  }) => PaseoDesktopSettings(
    releaseChannel: releaseChannel ?? this.releaseChannel,
    daemon: daemon ?? this.daemon,
  );

  @override
  bool operator ==(Object other) =>
      other is PaseoDesktopSettings &&
      other.releaseChannel == releaseChannel &&
      other.daemon == daemon;

  @override
  int get hashCode => Object.hash(releaseChannel, daemon);

  @override
  String toString() =>
      'PaseoDesktopSettings(releaseChannel: $releaseChannel, '
      'daemon: $daemon)';
}

/// Upstream `DEFAULT_DESKTOP_SETTINGS`: stable channel, app-managed daemon that
/// survives a window quit.
const PaseoDesktopSettings defaultPaseoDesktopSettings = PaseoDesktopSettings(
  releaseChannel: DesktopAppReleaseChannel.stable,
  daemon: PaseoDesktopDaemonSettings(
    manageBuiltInDaemon: true,
    keepRunningAfterQuit: true,
  ),
);

/// The persisted settings store the command handlers wrap.
///
/// [patch] and [migrateLegacyRendererSettings] take `Object?` because upstream
/// types them `unknown`: the payload arrives straight off the command bus from
/// the renderer, so the store — not the handler — owns validation.
abstract interface class PaseoDesktopSettingsStore {
  Future<PaseoDesktopSettings> get();

  /// Applies a partial update. Unknown or malformed keys are the store's
  /// problem, not the caller's.
  Future<PaseoDesktopSettings> patch(Object? patch);

  /// One-shot import of settings that used to live in renderer local storage.
  /// Idempotent inside the store — a second call is a no-op.
  Future<PaseoDesktopSettings> migrateLegacyRendererSettings(
    Object? legacySettings,
  );
}

/// A handler registered on the desktop command bus.
///
/// Deviation: upstream's signature is
/// `(args?: Record<string, unknown>) => unknown` — the bus is heterogeneous,
/// so the return type stays `Object?`
/// rather than being narrowed to [PaseoDesktopSettings], even though all three
/// settings handlers happen to return one. The argument is optional positional
/// because the bus may dispatch a command with no payload at all.
typedef DesktopCommandHandler =
    Future<Object?> Function([Map<String, Object?>? args]);

/// Command name for reading the whole settings document.
const String getDesktopSettingsCommand = 'get_desktop_settings';

/// Command name for applying a partial settings update.
const String patchDesktopSettingsCommand = 'patch_desktop_settings';

/// Command name for the one-shot renderer-settings import.
const String migrateLegacyDesktopSettingsCommand =
    'migrate_legacy_desktop_settings';

/// Builds the three settings entries for the desktop command bus.
///
/// Deliberately a thin pass-through: the handlers add no validation, no
/// defaulting and no error translation, because the store already owns all
/// three. Keeping them empty is what makes the bus registration itself
/// trivially reviewable. Note `get` receives and discards any args, matching
/// upstream's zero-arity arrow assigned into an optional-arg handler type.
Map<String, DesktopCommandHandler> createDesktopSettingsCommandHandlers({
  required PaseoDesktopSettingsStore settingsStore,
}) => <String, DesktopCommandHandler>{
  getDesktopSettingsCommand: ([Map<String, Object?>? args]) =>
      settingsStore.get(),
  patchDesktopSettingsCommand: ([Map<String, Object?>? args]) =>
      settingsStore.patch(args),
  migrateLegacyDesktopSettingsCommand: ([Map<String, Object?>? args]) =>
      settingsStore.migrateLegacyRendererSettings(args),
};

// ---------------------------------------------------------------------------

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
