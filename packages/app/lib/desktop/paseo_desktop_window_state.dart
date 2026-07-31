/// Port of four frozen Paseo 0.2.0 desktop-host modules that all share one
/// shape: a rule the Electron main process ran *around* a host capability
/// (the filesystem, the display layout, the compositor, the OS clock). Every
/// capability here is a narrow injected interface, so none of these rules
/// touch `dart:io`, a real `Timer`, or `DateTime.now()`.
///
/// - `desktop/settings/window-state.ts` — the on-disk window geometry document
///   (atomic async writes plus one synchronous final write on quit) and the
///   pure clamp that keeps a restored window reachable after the monitor
///   layout changed.
/// - `desktop/settings/desktop-settings.ts` — the on-disk desktop settings
///   document, its coercion rules, and the one-shot import of settings that
///   used to live in renderer local storage.
/// - `desktop/window/compositor-watchdog/index.ts` — the macOS display-sleep
///   compositor-stall detector and its GPU-process restart policy.
/// - `desktop/integrations/skills/sync.ts` — the file-copying half of the
///   bundled-skill installer: mirror a bundle into a managed directory,
///   delete only files this installer itself wrote, and leave user files
///   alone.
///
/// ## Reuse
///
/// Nothing in this library redeclares a type that already exists in the repo:
///
/// - **Settings.** There are three settings shapes here and this port extends
///   exactly one of them. [PaseoDesktopSettings] /
///   [PaseoDesktopDaemonSettings] / [defaultPaseoDesktopSettings] /
///   [PaseoDesktopSettingsStore] in `paseo_desktop_features.dart` are the port
///   of *this same* `{releaseChannel, daemon:{...}}` document — that library
///   ports `desktop-settings-commands.ts` and explicitly leaves the store
///   itself as an injected interface for exactly this file to implement.
///   [PaseoDesktopSettingsFileStore] below is that implementation, so the two
///   halves of upstream's settings feature (bus handlers, on-disk store) meet
///   on one value type. The other two shapes are deliberately *not* touched:
///   `state/desktop_settings_provider.dart`'s `DesktopSettings` is a different
///   document (tray residency: `autoStartAtLogin`, `keepRunningAfterQuit`,
///   Riverpod-backed, no release channel), and
///   `hooks/paseo_agent_settings_rules.dart`'s `DesktopOwnedSettings` is the
///   *renderer's* read-only view of this document, reached over IPC through
///   `DesktopSettingsBridge`. Merging any of them would mean editing those
///   files and would fuse a main-process document with a renderer one.
/// - **Skills.** `paseo_desktop_browser.dart` ports `skills/operations.ts`,
///   whose sibling this is. [PaseoSkillsSync] therefore *implements* that
///   library's [PaseoSkillsSyncGateway] and reuses its
///   [PaseoSkillsFileSystem], [PaseoSkillContentHasher],
///   [DesktopDirectoryEntry], [DesktopBrowserPathOps] and
///   [paseoManagedFilesManifestName] rather than defining a parallel set.
///
/// ## Deviation: JS idioms with no Dart analogue
///
/// Called out again at each site, collected here for review:
///
/// - **`Math.round` ties.** JS rounds halves toward +Infinity (`-2.5` -> `-2`);
///   Dart's `num.round()` rounds away from zero (`-2.5` -> `-3`). See
///   [_jsRound].
/// - **Truthiness.** `if (!raw)`, `if (!parsed)` and `if (!result)` treat `""`,
///   `0` and `false` as absent. Reproduced explicitly where a JSON value can
///   reach the check.
/// - **`unknown` payloads.** Upstream validates `unknown` from the IPC bus and
///   from disk in one place; the Dart equivalents take `Object?` and do the
///   same structural narrowing rather than relying on a typed decode.
/// - **Node error codes.** `error.code === "ENOENT"` becomes
///   [DesktopFileNotFoundException]; every other failure propagates.
/// - **Sort stability.** `Array.prototype.sort` is stable, `List.sort` is not.
///   Noted at the one comparison-by-depth site where it could matter.
library;

import 'dart:async' show unawaited;
import 'dart:convert';
import 'dart:typed_data';

import 'paseo_desktop_browser.dart'
    show
        DesktopBrowserPathOps,
        DesktopDirectoryEntry,
        PaseoSkillContentHasher,
        PaseoSkillsFileSystem,
        PaseoSkillsSyncGateway,
        paseoManagedFilesManifestName;
import 'paseo_desktop_features.dart'
    show
        DesktopAppReleaseChannel,
        PaseoDesktopDaemonSettings,
        PaseoDesktopSettings,
        PaseoDesktopSettingsStore,
        defaultPaseoDesktopSettings;

// Re-exported because they appear throughout this library's public signatures.
// A host wiring up the settings store or the skill sync should not have to
// know which sibling port introduced each type.
export 'paseo_desktop_browser.dart'
    show
        DesktopBrowserPathOps,
        DesktopDirectoryEntry,
        PaseoSkillContentHasher,
        PaseoSkillsFileSystem,
        PaseoSkillsSyncGateway,
        paseoManagedFilesManifestName;
export 'paseo_desktop_features.dart'
    show
        DesktopAppReleaseChannel,
        PaseoDesktopDaemonSettings,
        PaseoDesktopSettings,
        PaseoDesktopSettingsStore,
        defaultPaseoDesktopSettings;

// ---------------------------------------------------------------------------
// Shared host ports
// ---------------------------------------------------------------------------

/// The one Node error code these stores branch on: `ENOENT`.
///
/// Upstream writes `if (isNodeError(error) && error.code === "ENOENT")`. Dart
/// has no errno on exceptions, so the host filesystem raises this type for a
/// missing path and anything else it throws propagates untouched — which is
/// what upstream does with every non-ENOENT error.
final class DesktopFileNotFoundException implements Exception {
  const DesktopFileNotFoundException(this.path);

  /// The path that was not there.
  final String path;

  @override
  String toString() => 'DesktopFileNotFoundException: $path';
}

/// The `node:fs/promises` slice both on-disk settings documents use.
///
/// Every write in this library is the same three-step atomic dance upstream
/// performs — write a uniquely named temp file, then `rename` it over the real
/// path — so a crash mid-write can never leave a half-written document behind.
/// The interface is therefore deliberately shaped around that dance rather
/// than offering a single "write this file" call.
abstract interface class DesktopAtomicFileSystem {
  /// `readFile(path, "utf8")`.
  ///
  /// Must throw [DesktopFileNotFoundException] when the path does not exist;
  /// every other failure is passed through to the caller, matching upstream's
  /// `throw error` for non-ENOENT codes.
  Future<String> readAsString(String path);

  /// `mkdir(path, { recursive: true })` — must succeed when the directory is
  /// already there.
  Future<void> createDirectory(String path);

  /// `writeFile(path, contents, "utf8")`.
  Future<void> writeAsString(String path, String contents);

  /// `rename(from, to)`, which must replace an existing `to` atomically.
  Future<void> rename(String from, String to);

  /// `unlink(path)`. Only reached for a temp file this library just wrote, and
  /// the one caller swallows failures exactly as upstream's `.catch(() =>
  /// undefined)` does.
  Future<void> deleteFile(String path);
}

/// The extra *synchronous* calls the window-state store makes.
///
/// Split out from [DesktopAtomicFileSystem] because only
/// [DesktopWindowStateStore.saveSync] needs them: it is the last writer on
/// window close / app quit, where the event loop is about to stop and an
/// awaited write would simply not land.
abstract interface class DesktopWindowStateFileSystem
    implements DesktopAtomicFileSystem {
  /// `mkdirSync(path, { recursive: true })`.
  void createDirectorySync(String path);

  /// `writeFileSync(path, contents, "utf8")`.
  void writeAsStringSync(String path, String contents);

  /// `renameSync(from, to)`.
  void renameSync(String from, String to);
}

/// Produces the unique part of a temp filename.
///
/// Upstream builds `${filePath}.tmp.${process.pid}.${randomUUID()}`; both the
/// pid and the UUID are host capabilities, so the whole suffix is injected.
/// Only uniqueness matters — two concurrent writers must never pick the same
/// temp path.
typedef DesktopTempFileToken = String Function();

/// `JSON.stringify(value, null, 2)`.
const JsonEncoder _prettyJson = JsonEncoder.withIndent('  ');

/// Upstream's `isRecord`: a non-null, non-array object.
///
/// A Dart [Map] is exactly that set — `List` is a separate type here, so the
/// `!Array.isArray` half needs no explicit check.
bool _isRecord(Object? value) => value is Map;

/// JS `Math.round`.
///
/// Deviation: ties round toward +Infinity in JS (`Math.round(-2.5) === -2`)
/// but away from zero in Dart (`(-2.5).round() == -3`). Persisted window
/// coordinates on a secondary monitor are negative, so the difference is
/// reachable from a real settings file and is reproduced with `floor(v + 0.5)`.
/// Magnitudes at or above 2^53 have no fractional part left in a double, so
/// rounding there is the identity and the shift is skipped.
int _jsRound(num value) {
  if (value is int) return value;
  final shifted = value + 0.5;
  if (shifted.abs() >= 9007199254740992.0) return value.toInt();
  return shifted.floor();
}

/// Runs [write] behind [queue], reproducing upstream's
/// `persistQueue.then(write, write)` — the same continuation on both settle
/// paths, so one failed write never stalls the queue for every later one.
///
/// Returns the future the caller awaits and the future the next write chains
/// off; the latter has its errors absorbed, which is upstream's
/// `persistQueue = queued.catch(() => undefined)`.
({Future<void> awaited, Future<void> next}) _enqueue(
  Future<void> queue,
  Future<void> Function() write,
) {
  final queued = queue.then<void>(
    (_) => write(),
    onError: (Object _) => write(),
  );
  return (
    awaited: queued,
    next: queued.then<void>((_) {}, onError: (Object _) {}),
  );
}

// ---------------------------------------------------------------------------
// settings/window-state.ts
// ---------------------------------------------------------------------------

/// The narrowest window the app will restore to, in DIP.
const int desktopMinWindowWidth = 400;

/// The shortest window the app will restore to, in DIP.
const int desktopMinWindowHeight = 300;

/// Smallest slice of the window that must remain on a display for the saved
/// position to count as "still reachable" after the monitor layout changes.
const int _minVisibleWidth = 100;

/// Vertical twin of [_minVisibleWidth].
const int _minVisibleHeight = 80;

/// Filename [DesktopWindowStateStore] owns inside the user-data directory.
const String desktopWindowStateFileName = 'window-state.json';

/// A restorable window geometry.
///
/// [x] and [y] are jointly optional: upstream types them `x?: number` and only
/// ever sets both or neither, because a half-known position is worse than
/// letting the OS place the window. That invariant is enforced in
/// [coerceDesktopWindowState] rather than in the constructor, so a caller can
/// still describe whatever Electron reported.
final class DesktopWindowState {
  const DesktopWindowState({
    required this.width,
    required this.height,
    required this.isMaximized,
    this.x,
    this.y,
  });

  /// Left edge in DIP, or null to let the OS place the window.
  final int? x;

  /// Top edge in DIP, or null to let the OS place the window.
  final int? y;

  final int width;
  final int height;

  /// Restored maximized rather than at [width] x [height].
  final bool isMaximized;

  /// The `state` half of the persisted document.
  ///
  /// Absent coordinates are omitted rather than emitted as `null`, matching
  /// `JSON.stringify`, which drops `undefined` properties. That is what lets a
  /// round-trip through disk come back with no position at all instead of a
  /// position of `null`, which [coerceDesktopWindowState] would reject anyway.
  Map<String, Object?> toJson() => <String, Object?>{
    if (x != null) 'x': x,
    if (y != null) 'y': y,
    'width': width,
    'height': height,
    'isMaximized': isMaximized,
  };

  @override
  bool operator ==(Object other) =>
      other is DesktopWindowState &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.isMaximized == isMaximized;

  @override
  int get hashCode => Object.hash(x, y, width, height, isMaximized);

  @override
  String toString() =>
      'DesktopWindowState(x: $x, y: $y, width: $width, height: $height, '
      'isMaximized: $isMaximized)';
}

/// A display's usable area (excludes the menu bar / taskbar), in DIP.
final class DesktopWorkArea {
  const DesktopWorkArea({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is DesktopWorkArea &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() =>
      'DesktopWorkArea(x: $x, y: $y, width: $width, height: $height)';
}

int? _coerceFiniteNumber(Object? value) =>
    value is num && value.isFinite ? _jsRound(value) : null;

int? _coerceDimension(Object? value, int minimum) {
  final rounded = _coerceFiniteNumber(value);
  if (rounded == null) return null;
  return rounded < minimum ? minimum : rounded;
}

/// Narrows an untrusted value — the `state` field of the persisted document —
/// into a [DesktopWindowState], or null when it carries no usable size.
///
/// Public because it is upstream's exported entry point for validating a
/// geometry that arrived from anywhere, not just from this store's own file.
/// The size is the load-bearing part: without a width and a height there is
/// nothing to restore, so the whole state is discarded. A position, by
/// contrast, is optional and is only trusted when *both* coordinates survive
/// coercion.
DesktopWindowState? coerceDesktopWindowState(Object? input) {
  if (!_isRecord(input)) return null;
  final record = input! as Map<Object?, Object?>;

  final width = _coerceDimension(record['width'], desktopMinWindowWidth);
  final height = _coerceDimension(record['height'], desktopMinWindowHeight);
  if (width == null || height == null) return null;

  final x = _coerceFiniteNumber(record['x']);
  final y = _coerceFiniteNumber(record['y']);
  final positioned = x != null && y != null;

  return DesktopWindowState(
    x: positioned ? x : null,
    y: positioned ? y : null,
    width: width,
    height: height,
    // `input.isMaximized === true`: anything else, including a truthy
    // non-boolean, restores un-maximized.
    isMaximized: record['isMaximized'] == true,
  );
}

/// Adjusts a saved window state to the current display layout so the window
/// never opens off-screen.
///
/// Pure on purpose — the caller supplies the work areas (from Electron's
/// `screen`), which is what makes multi-monitor behaviour testable without a
/// display server. Two things can happen:
///
/// - The saved position is dropped when no display would show a meaningful
///   slice of the window ([_minVisibleWidth] x [_minVisibleHeight], or the
///   whole window when it is smaller than that). The OS then places it.
/// - The size is clamped into the chosen display, and the position is nudged
///   back inside *after* that clamp, so an oversized state saved near a screen
///   edge cannot end up mostly off-screen.
///
/// Deviation: overlap area is compared with `>`, so among displays that show
/// the window equally well the *first* in [workAreas] wins — the same
/// tie-break upstream's loop has, preserved because Electron lists the primary
/// display first.
DesktopWindowState clampDesktopWindowStateToWorkAreas(
  DesktopWindowState state,
  List<DesktopWorkArea> workAreas,
) {
  if (workAreas.isEmpty) {
    // No display info — keep the size, let the OS place the window.
    return DesktopWindowState(
      width: state.width,
      height: state.height,
      isMaximized: state.isMaximized,
    );
  }

  var target = workAreas.first;
  final x = state.x;
  final y = state.y;
  var positioned = false;

  if (x != null && y != null) {
    final requiredWidth = _minVisibleWidth < state.width
        ? _minVisibleWidth
        : state.width;
    final requiredHeight = _minVisibleHeight < state.height
        ? _minVisibleHeight
        : state.height;
    var bestOverlap = 0;

    for (final workArea in workAreas) {
      final overlapWidth = _atLeastZero(
        _min(x + state.width, workArea.x + workArea.width) -
            _max(x, workArea.x),
      );
      final overlapHeight = _atLeastZero(
        _min(y + state.height, workArea.y + workArea.height) -
            _max(y, workArea.y),
      );
      final overlap = overlapWidth * overlapHeight;
      final isVisibleEnough =
          overlapWidth >= requiredWidth && overlapHeight >= requiredHeight;
      if (isVisibleEnough && overlap > bestOverlap) {
        bestOverlap = overlap;
        target = workArea;
        positioned = true;
      }
    }
  }

  final width = _min(_max(state.width, desktopMinWindowWidth), target.width);
  final height = _min(
    _max(state.height, desktopMinWindowHeight),
    target.height,
  );

  if (positioned && x != null && y != null) {
    final clampedX = _min(_max(x, target.x), target.x + target.width - width);
    final clampedY = _min(_max(y, target.y), target.y + target.height - height);
    return DesktopWindowState(
      x: clampedX,
      y: clampedY,
      width: width,
      height: height,
      isMaximized: state.isMaximized,
    );
  }
  return DesktopWindowState(
    width: width,
    height: height,
    isMaximized: state.isMaximized,
  );
}

int _min(int a, int b) => a < b ? a : b;

int _max(int a, int b) => a > b ? a : b;

int _atLeastZero(int value) => value < 0 ? 0 : value;

/// The persisted window geometry, as `window-state.json` in the user-data
/// directory.
///
/// Two writers with different urgency share one file:
///
/// - [save] is the steady-state writer, serialized behind a queue so two
///   resize events can never interleave their temp files onto the real path
///   out of order.
/// - [saveSync] is the final writer on window close / app quit. Once it runs
///   the store is *finalized*: any async write still in flight discards itself
///   rather than overwriting the freshest snapshot with an older one.
final class DesktopWindowStateStore {
  DesktopWindowStateStore({
    required this.userDataPath,
    required this.fileSystem,
    required this.tempFileToken,
    this.pathOps = DesktopBrowserPathOps.posix,
  });

  /// Directory the document lives in. Created on demand by both writers.
  final String userDataPath;

  final DesktopWindowStateFileSystem fileSystem;

  /// Supplies the unique suffix of each temp file. See [DesktopTempFileToken].
  final DesktopTempFileToken tempFileToken;

  /// Injected so a test can pin Win32 semantics on a POSIX host and vice
  /// versa; upstream simply uses the host's own `node:path`.
  final DesktopBrowserPathOps pathOps;

  Future<void> _persistQueue = Future<void>.value();

  /// Once the synchronous final write lands, pending async writes must not
  /// clobber it with an older snapshot.
  bool _finalized = false;

  String get _filePath =>
      pathOps.join(<String>[userDataPath, desktopWindowStateFileName]);

  String _tempFilePath() => '$_filePath.tmp.${tempFileToken()}';

  /// Whether [saveSync] has run and closed the door on async writes.
  bool get isFinalized => _finalized;

  /// Returns the persisted state, or null when nothing usable is stored.
  ///
  /// Three separate "nothing usable" cases all collapse to null, because
  /// window geometry is non-critical state that must never block launch: no
  /// file yet (first run), a corrupted file, and a file whose contents fail
  /// [coerceDesktopWindowState]. Anything else — a permission error, an I/O
  /// error — is rethrown, since silently discarding those would hide a real
  /// problem with the user-data directory.
  Future<DesktopWindowState?> load() async {
    final String raw;
    try {
      raw = await fileSystem.readAsString(_filePath);
    } on DesktopFileNotFoundException {
      return null;
    }

    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException {
      // Upstream narrows to `error instanceof SyntaxError`; `FormatException`
      // is what `jsonDecode` raises for the same malformed input.
      return null;
    }

    if (!_isRecord(parsed)) return null;
    return coerceDesktopWindowState(
      (parsed! as Map<Object?, Object?>)['state'],
    );
  }

  /// Persists the state atomically off the main thread (serialized writes).
  ///
  /// The finalized flag is checked twice on purpose: once before doing any
  /// work, and again after the temp file exists, because [saveSync] can land
  /// while this write is in flight. In that window the temp file is deleted
  /// instead of renamed, so a stale snapshot never wins and no orphan temp
  /// file accumulates in the user-data directory.
  Future<void> save(DesktopWindowState state) {
    final contents = _serializeDocument(state);

    Future<void> write() async {
      if (_finalized) return;
      await fileSystem.createDirectory(userDataPath);
      final tempPath = _tempFilePath();
      await fileSystem.writeAsString(tempPath, contents);
      if (_finalized) {
        try {
          await fileSystem.deleteFile(tempPath);
        } on Object {
          // Upstream `.catch(() => undefined)`: a temp file that cannot be
          // removed is not worth failing the save over.
        }
        return;
      }
      await fileSystem.rename(tempPath, _filePath);
    }

    final queued = _enqueue(_persistQueue, write);
    _persistQueue = queued.next;
    return queued.awaited;
  }

  /// Persists the state synchronously — the final writer on close/quit.
  ///
  /// Marks the store finalized *before* touching the disk so an async write
  /// that is already awaiting cannot slip its rename in afterwards.
  void saveSync(DesktopWindowState state) {
    _finalized = true;
    final contents = _serializeDocument(state);
    fileSystem.createDirectorySync(userDataPath);
    final tempPath = _tempFilePath();
    fileSystem.writeAsStringSync(tempPath, contents);
    fileSystem.renameSync(tempPath, _filePath);
  }

  /// `{ version: 1, state }` plus a trailing newline, so the file is a
  /// well-formed text file rather than something only a JSON parser will
  /// accept.
  ///
  /// Deviation: JS serializes the caller's object, whose key order is whatever
  /// that object literal had. Dart has no such identity, so the order is fixed
  /// by [DesktopWindowState.toJson] to the declaration order of upstream's
  /// interface. Nothing reads the file positionally, so only the bytes of a
  /// no-op rewrite could differ — and this store never compares bytes.
  String _serializeDocument(DesktopWindowState state) {
    final document = <String, Object?>{'version': 1, 'state': state.toJson()};
    return '${_prettyJson.convert(document)}\n';
  }
}

// ---------------------------------------------------------------------------
// settings/desktop-settings.ts
// ---------------------------------------------------------------------------

/// Filename [PaseoDesktopSettingsFileStore] owns inside the user-data
/// directory.
const String desktopSettingsFileName = 'desktop-settings.json';

DesktopAppReleaseChannel? _coerceReleaseChannel(Object? value) {
  if (value == 'beta') return DesktopAppReleaseChannel.beta;
  if (value == 'stable') return DesktopAppReleaseChannel.stable;
  return null;
}

bool? _coerceBoolean(Object? value) => value is bool ? value : null;

/// The partial update shape: every field independently absent.
///
/// Private because it is upstream's internal `DesktopSettingsPatch`; callers
/// hand the store an untrusted `Object?` and the store owns the narrowing.
final class _DesktopSettingsPatch {
  const _DesktopSettingsPatch({this.releaseChannel, this.daemon});

  final DesktopAppReleaseChannel? releaseChannel;
  final _DaemonSettingsPatch? daemon;
}

/// `Partial<DesktopSettings["daemon"]>`.
final class _DaemonSettingsPatch {
  const _DaemonSettingsPatch({
    this.manageBuiltInDaemon,
    this.keepRunningAfterQuit,
  });

  final bool? manageBuiltInDaemon;
  final bool? keepRunningAfterQuit;

  /// Upstream's `Object.keys(daemonPatch).length > 0`.
  bool get isEmpty =>
      manageBuiltInDaemon == null && keepRunningAfterQuit == null;
}

/// The whole persisted document: the settings plus the migration bookkeeping
/// that makes the legacy import a one-shot.
final class _DesktopSettingsDocument {
  const _DesktopSettingsDocument({
    required this.settings,
    required this.legacyRendererSettingsImported,
  });

  final PaseoDesktopSettings settings;
  final bool legacyRendererSettingsImported;

  _DesktopSettingsDocument copyWith({
    PaseoDesktopSettings? settings,
    bool? legacyRendererSettingsImported,
  }) => _DesktopSettingsDocument(
    settings: settings ?? this.settings,
    legacyRendererSettingsImported:
        legacyRendererSettingsImported ?? this.legacyRendererSettingsImported,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'settings': <String, Object?>{
      'releaseChannel': settings.releaseChannel.name,
      'daemon': <String, Object?>{
        'manageBuiltInDaemon': settings.daemon.manageBuiltInDaemon,
        'keepRunningAfterQuit': settings.daemon.keepRunningAfterQuit,
      },
    },
    'migrations': <String, Object?>{
      'legacyRendererSettingsImported': legacyRendererSettingsImported,
    },
  };
}

_DesktopSettingsDocument _buildDefaultDocument() =>
    const _DesktopSettingsDocument(
      settings: defaultPaseoDesktopSettings,
      legacyRendererSettingsImported: false,
    );

/// Every field falls back to its default independently, so one bad value in a
/// hand-edited file cannot reset the rest of the document.
PaseoDesktopSettings _coerceDesktopSettings(Object? input) {
  var result = defaultPaseoDesktopSettings;
  if (!_isRecord(input)) return result;
  final record = input! as Map<Object?, Object?>;

  final releaseChannel = _coerceReleaseChannel(record['releaseChannel']);
  if (releaseChannel != null) {
    result = result.copyWith(releaseChannel: releaseChannel);
  }

  final daemon = record['daemon'];
  if (_isRecord(daemon)) {
    final daemonRecord = daemon! as Map<Object?, Object?>;
    final manageBuiltInDaemon = _coerceBoolean(
      daemonRecord['manageBuiltInDaemon'],
    );
    if (manageBuiltInDaemon != null) {
      result = result.copyWith(
        daemon: result.daemon.copyWith(
          manageBuiltInDaemon: manageBuiltInDaemon,
        ),
      );
    }

    final keepRunningAfterQuit = _coerceBoolean(
      daemonRecord['keepRunningAfterQuit'],
    );
    if (keepRunningAfterQuit != null) {
      result = result.copyWith(
        daemon: result.daemon.copyWith(
          keepRunningAfterQuit: keepRunningAfterQuit,
        ),
      );
    }
  }

  return result;
}

_DesktopSettingsPatch _coerceDesktopSettingsPatch(Object? input) {
  if (!_isRecord(input)) return const _DesktopSettingsPatch();
  final record = input! as Map<Object?, Object?>;

  final releaseChannel = _coerceReleaseChannel(record['releaseChannel']);

  _DaemonSettingsPatch? daemonPatch;
  final daemon = record['daemon'];
  if (_isRecord(daemon)) {
    final daemonRecord = daemon! as Map<Object?, Object?>;
    final candidate = _DaemonSettingsPatch(
      manageBuiltInDaemon: _coerceBoolean(daemonRecord['manageBuiltInDaemon']),
      keepRunningAfterQuit: _coerceBoolean(
        daemonRecord['keepRunningAfterQuit'],
      ),
    );
    // Upstream only attaches `patch.daemon` when at least one key survived, so
    // `{ daemon: { nonsense: 1 } }` stays a no-op rather than an empty spread.
    if (!candidate.isEmpty) daemonPatch = candidate;
  }

  return _DesktopSettingsPatch(
    releaseChannel: releaseChannel,
    daemon: daemonPatch,
  );
}

/// The two desktop-owned fields that used to live in the renderer's settings
/// blob, read out of that flat blob rather than out of this document's shape.
///
/// Note the asymmetry, which is upstream's: `keepRunningAfterQuit` is *not*
/// imported, because the renderer never owned it.
_DesktopSettingsPatch _pickDesktopSettingsFromLegacyRendererSettings(
  Object? legacySettings,
) {
  if (!_isRecord(legacySettings)) return const _DesktopSettingsPatch();
  final record = legacySettings! as Map<Object?, Object?>;

  final manageBuiltInDaemon = _coerceBoolean(record['manageBuiltInDaemon']);
  return _DesktopSettingsPatch(
    releaseChannel: _coerceReleaseChannel(record['releaseChannel']),
    daemon: manageBuiltInDaemon == null
        ? null
        : _DaemonSettingsPatch(manageBuiltInDaemon: manageBuiltInDaemon),
  );
}

PaseoDesktopSettings _mergeDesktopSettings(
  PaseoDesktopSettings current,
  _DesktopSettingsPatch patch,
) => PaseoDesktopSettings(
  releaseChannel: patch.releaseChannel ?? current.releaseChannel,
  // `{ ...current.daemon, ...patch.daemon }`: absent keys in the patch keep
  // the current value, which is exactly what `copyWith` does with nulls.
  daemon: current.daemon.copyWith(
    manageBuiltInDaemon: patch.daemon?.manageBuiltInDaemon,
    keepRunningAfterQuit: patch.daemon?.keepRunningAfterQuit,
  ),
);

/// Whether a patch touched a field the legacy renderer blob also carries.
///
/// Once the user has set one of these explicitly from the desktop UI, the
/// legacy import must be considered done — otherwise a stale renderer value
/// would silently overwrite the newer choice on the next launch.
bool _hasLegacyRendererOwnedPatch(_DesktopSettingsPatch patch) =>
    patch.releaseChannel != null || patch.daemon?.manageBuiltInDaemon != null;

_DesktopSettingsDocument _coerceDocument(Object? input) {
  if (!_isRecord(input)) return _buildDefaultDocument();
  final record = input! as Map<Object?, Object?>;

  final migrations = record['migrations'];
  return _DesktopSettingsDocument(
    settings: _coerceDesktopSettings(record['settings']),
    legacyRendererSettingsImported: _isRecord(migrations)
        ? (migrations!
                  as Map<Object?, Object?>)['legacyRendererSettingsImported'] ==
              true
        : false,
  );
}

/// The on-disk half of upstream's desktop settings feature.
///
/// Implements [PaseoDesktopSettingsStore], the interface
/// `paseo_desktop_features.dart` already declared for the command-bus handlers
/// to depend on, so the bus handlers and this store agree on one
/// [PaseoDesktopSettings] value type.
///
/// Two behaviours here are subtle and deliberate:
///
/// - **[get] never rewrites an existing file.** It only writes when the file is
///   missing, so reading settings cannot churn the user's file (or its
///   timestamp) on every launch.
/// - **A corrupted file throws out of [get] but not out of
///   [migrateLegacyRendererSettings].** The migration runs on a launch path
///   where there is nothing sensible to fall back to except defaults, so it
///   swallows the parse failure and rewrites; [get] surfaces it, because a
///   caller reading settings should not silently receive defaults for a file
///   that is still on disk.
final class PaseoDesktopSettingsFileStore implements PaseoDesktopSettingsStore {
  PaseoDesktopSettingsFileStore({
    required this.userDataPath,
    required this.fileSystem,
    required this.tempFileToken,
    this.pathOps = DesktopBrowserPathOps.posix,
  });

  final String userDataPath;
  final DesktopAtomicFileSystem fileSystem;

  /// See [DesktopTempFileToken].
  final DesktopTempFileToken tempFileToken;

  final DesktopBrowserPathOps pathOps;

  _DesktopSettingsDocument? _cachedDocument;
  Future<void> _persistQueue = Future<void>.value();

  String get _filePath =>
      pathOps.join(<String>[userDataPath, desktopSettingsFileName]);

  @override
  Future<PaseoDesktopSettings> get() async {
    final document = await _loadDocument();
    return document.settings;
  }

  @override
  Future<PaseoDesktopSettings> patch(Object? patch) async {
    final current = await _loadWritableDocument();
    final coercedPatch = _coerceDesktopSettingsPatch(patch);
    final next = _mergeDesktopSettings(current.settings, coercedPatch);
    await _persistDocument(
      current.copyWith(
        settings: next,
        legacyRendererSettingsImported:
            current.legacyRendererSettingsImported ||
            _hasLegacyRendererOwnedPatch(coercedPatch),
      ),
    );
    return next;
  }

  @override
  Future<PaseoDesktopSettings> migrateLegacyRendererSettings(
    Object? legacySettings,
  ) async {
    final current = await _initializeLegacyRendererMigration();
    if (current.legacyRendererSettingsImported) return current.settings;

    final next = _mergeDesktopSettings(
      current.settings,
      _pickDesktopSettingsFromLegacyRendererSettings(legacySettings),
    );
    await _persistDocument(
      current.copyWith(settings: next, legacyRendererSettingsImported: true),
    );
    return next;
  }

  Future<void> _persistDocument(_DesktopSettingsDocument document) {
    Future<void> write() async {
      await fileSystem.createDirectory(userDataPath);
      final tempFilePath = '$_filePath.tmp.${tempFileToken()}';
      await fileSystem.writeAsString(
        tempFilePath,
        '${_prettyJson.convert(document.toJson())}\n',
      );
      await fileSystem.rename(tempFilePath, _filePath);
      _cachedDocument = document;
    }

    final queued = _enqueue(_persistQueue, write);
    _persistQueue = queued.next;
    return queued.awaited;
  }

  Future<_DesktopSettingsDocument> _loadDocument() async {
    final cached = _cachedDocument;
    if (cached != null) return cached;

    final String raw;
    try {
      raw = await fileSystem.readAsString(_filePath);
    } on DesktopFileNotFoundException {
      // First launch: seed the file so the next reader hits the fast path and
      // so an external tool can see what the app is actually using.
      final document = _buildDefaultDocument();
      await _persistDocument(document);
      return document;
    }

    // Deliberately unguarded, unlike the window-state store's parse: a
    // corrupted settings file is a real problem the caller should hear about.
    final document = _coerceDocument(jsonDecode(raw));
    _cachedDocument = document;
    return document;
  }

  /// Guarantees the file exists before a mutation reads-modifies-writes it.
  Future<_DesktopSettingsDocument> _loadWritableDocument() async {
    final document = await _loadDocument();
    await _persistDocument(document);
    return document;
  }

  Future<_DesktopSettingsDocument> _initializeLegacyRendererMigration() async {
    try {
      return await _loadDocument();
    } on Object {
      // Includes the corrupted-JSON case: the migration cannot ask the user,
      // so it starts from defaults rather than aborting launch.
      final document = _buildDefaultDocument();
      await _persistDocument(document);
      return document;
    }
  }
}

// ---------------------------------------------------------------------------
// window/compositor-watchdog/index.ts
// ---------------------------------------------------------------------------
//
// COMPAT(darwinCompositorWatchdog): added upstream in v0.1.78, target removal
// after 2026-11-19. Workaround for Electron/Chromium macOS display-sleep
// compositor stalls; re-test when Electron/Chromium is upgraded.

/// `process.platform` value the watchdog is scoped to.
const String desktopDarwinPlatform = 'darwin';

/// How often the host probes the renderer for frame production.
const Duration desktopFrameProbeInterval = Duration(seconds: 2);

/// A probed frame must arrive within this window or the probe counts as
/// stalled.
const Duration desktopFrameProbeDeadline = Duration(milliseconds: 300);

/// Consecutive stalled probes before the watchdog restarts the GPU process
/// (~6 s at [desktopFrameProbeInterval]).
const int desktopFrameStallChecksToRecover = 3;

/// Minimum gap between GPU-process restarts.
const Duration desktopCompositorRecoveryCooldown = Duration(seconds: 60);

/// Grace period for Chromium to relaunch the GPU process before probing
/// resumes.
const Duration desktopGpuRelaunchGrace = Duration(seconds: 5);

/// Stop restarting the GPU process after this many tries without frames
/// returning.
const int desktopMaxConsecutiveRecoveries = 3;

/// Resolves `{ producedFrame, visibilityState }` for the renderer.
///
/// The frame is requested with `requestAnimationFrame`; `setTimeout` (not
/// vsync-driven) bounds the wait so the probe always resolves even when frame
/// production has stopped — which is the entire point, since a vsync-driven
/// timer would hang exactly in the case being detected.
///
/// The literal `300` is [desktopFrameProbeDeadline] in milliseconds, inlined
/// because this is a JS source string and Dart cannot interpolate into a
/// `const`.
const String desktopFrameProbeSource = '''new Promise((resolve) => {
  let settled = false;
  const finish = (producedFrame) => {
    if (settled) return;
    settled = true;
    resolve({ producedFrame, visibilityState: document.visibilityState });
  };
  requestAnimationFrame(() => finish(true));
  setTimeout(() => finish(false), 300);
})''';

/// The four numbers [shouldRecoverFromFrameStall] weighs.
final class DesktopFrameStallState {
  const DesktopFrameStallState({
    required this.stalledChecks,
    required this.recovering,
    required this.msSinceLastRecovery,
    required this.consecutiveRecoveries,
  });

  /// Consecutive probes that saw a visible window produce no frame.
  final int stalledChecks;

  /// A recovery is already running (including its relaunch grace period).
  final bool recovering;

  /// Milliseconds since the last recovery started. Before any recovery this is
  /// "now", because upstream initialises `lastRecoveryAt` to 0 — the cooldown
  /// is therefore never in force on the first stall.
  final int msSinceLastRecovery;

  /// Recoveries since the last time a frame actually arrived.
  final int consecutiveRecoveries;

  @override
  String toString() =>
      'DesktopFrameStallState(stalledChecks: $stalledChecks, '
      'recovering: $recovering, msSinceLastRecovery: $msSinceLastRecovery, '
      'consecutiveRecoveries: $consecutiveRecoveries)';
}

/// Whether a sustained frame stall warrants restarting the GPU process.
///
/// All four guards must hold, and each rules out a different way the restart
/// would be harmful: too few stalled probes is indistinguishable from a
/// momentarily busy renderer; a restart while one is in flight would kill the
/// freshly spawned GPU process; the cooldown stops a restart loop from
/// thrashing the machine; and the consecutive cap gives up entirely once
/// restarting has demonstrably stopped helping, leaving the user a frozen
/// window rather than a permanently churning one.
bool shouldRecoverFromFrameStall(DesktopFrameStallState state) =>
    state.stalledChecks >= desktopFrameStallChecksToRecover &&
    !state.recovering &&
    state.msSinceLastRecovery >=
        desktopCompositorRecoveryCooldown.inMilliseconds &&
    state.consecutiveRecoveries < desktopMaxConsecutiveRecoveries;

/// One row of Electron's `app.getAppMetrics()`.
final class DesktopProcessMetric {
  const DesktopProcessMetric({required this.type, required this.pid});

  /// Electron's process type: `"Browser"`, `"GPU"`, `"Tab"`, `"Utility"`, ...
  final String type;

  final int pid;

  @override
  String toString() => 'DesktopProcessMetric(type: $type, pid: $pid)';
}

/// The pid of the GPU process, or null when Electron does not report one.
///
/// Split out as a pure function so the "first metric whose type is GPU" rule
/// is testable without an Electron app object. Returning null is a real case,
/// not a defensive one: a GPU process that already died is simply absent from
/// the metrics, and the watchdog then logs and waits rather than killing an
/// unrelated pid.
int? findGpuProcessPid(List<DesktopProcessMetric> metrics) {
  for (final metric in metrics) {
    if (metric.type == 'GPU') return metric.pid;
  }
  return null;
}

/// The `BrowserWindow` slice the watchdog touches.
abstract interface class DesktopCompositorWindow {
  /// `win.isDestroyed()`.
  bool get isDestroyed;

  /// `win.isVisible()`.
  bool get isVisible;

  /// `win.isMinimized()`.
  bool get isMinimized;

  /// `win.webContents.executeJavaScript(source)`. May reject; the watchdog
  /// treats a rejection as "no information", not as a stall.
  Future<Object?> executeJavaScript(String source);

  /// `win.once("closed", handler)`.
  void onceClosed(void Function() handler);
}

/// Electron's `powerMonitor`, narrowed to the two screen-lock events.
///
/// Deviation: upstream pairs `on(event, fn)` with `off(event, fn)` using the
/// same function reference. Dart has no idiomatic equivalent, so each
/// registration returns its own remover — the same lifetime, expressed as a
/// closure instead of as reference identity.
abstract interface class DesktopPowerMonitor {
  /// Registers for `lock-screen`; the returned callback is upstream's `off`.
  void Function() onLockScreen(void Function() handler);

  /// Registers for `unlock-screen`; the returned callback is upstream's `off`.
  void Function() onUnlockScreen(void Function() handler);
}

/// The process-level capabilities the recovery step needs.
abstract interface class DesktopCompositorHost {
  /// `app.getAppMetrics()`.
  List<DesktopProcessMetric> getAppMetrics();

  /// `process.kill(pid, "SIGKILL")`. May throw — the caller logs and carries
  /// on, because a GPU process that vanished between the metrics read and the
  /// kill has already achieved what the restart wanted.
  void killProcess(int pid);
}

/// `setInterval` and `setTimeout`, injected so no real timer runs in tests.
abstract interface class DesktopCompositorScheduler {
  /// `setInterval(callback, interval)`; the returned callback is
  /// `clearInterval`.
  void Function() periodic(Duration interval, void Function() callback);

  /// `await new Promise((resolve) => setTimeout(resolve, duration))`.
  Future<void> delay(Duration duration);
}

/// Upstream's `console.warn`, as an injected sink so this library picks no
/// logging framework.
typedef DesktopCompositorWarn = void Function(String message, [Object? error]);

/// Reads the host clock in milliseconds since the epoch — upstream `Date.now()`.
typedef DesktopMillisecondClock = int Function();

/// Detects a macOS compositor stall and restarts the GPU process to clear it.
///
/// macOS display sleep can leave Chromium's GPU-process display link (the
/// vsync source that drives frame production) stuck on a stale display. The
/// compositor then stops producing frames and the window looks frozen —
/// unresponsive to clicks and keys — even though the renderer and every
/// process stay alive. This watchdog polls the renderer for frame production
/// and, on a sustained stall, restarts the GPU process so Chromium rebuilds
/// the display link.
///
/// Two design points carried over verbatim from upstream, both of which look
/// like omissions until explained:
///
/// - **Background throttling is deliberately left on.** Disabling it would
///   keep the compositor producing frames continuously, pinning ProMotion
///   displays at 120 Hz forever and draining the battery while the app idles.
///   The probe does not need it, because the visibility guards below (screen
///   lock, `isVisible`, `isMinimized`, `document.visibilityState`) already
///   skip every window that legitimately stops producing frames. The freeze
///   this targets happens while the window is visible and focused, just after
///   display wake, where throttling never applies.
/// - **Every guard resets [stalledChecks] to 0.** A window that was hidden and
///   comes back must start its stall count from scratch, otherwise a long
///   stretch of legitimate idleness would trigger a spurious GPU restart the
///   moment the window reappears.
final class DesktopCompositorWatchdog {
  DesktopCompositorWatchdog({
    required this.window,
    required this.powerMonitor,
    required this.host,
    required this.scheduler,
    required this.now,
    this.onWarning,
  });

  final DesktopCompositorWindow window;
  final DesktopPowerMonitor powerMonitor;
  final DesktopCompositorHost host;
  final DesktopCompositorScheduler scheduler;
  final DesktopMillisecondClock now;
  final DesktopCompositorWarn? onWarning;

  int _stalledChecks = 0;
  bool _recovering = false;

  /// Upstream initialises this to 0, not to "now", so the cooldown cannot
  /// block the very first recovery.
  int _lastRecoveryAt = 0;
  int _consecutiveRecoveries = 0;
  bool _screenLocked = false;

  void Function()? _cancelProbeTimer;
  void Function()? _removeLockListener;
  void Function()? _removeUnlockListener;
  bool _started = false;

  /// Consecutive probes that saw a visible window produce no frame.
  int get stalledChecks => _stalledChecks;

  /// A recovery is in flight, including its relaunch grace period.
  bool get isRecovering => _recovering;

  /// Recoveries since a frame last arrived.
  int get consecutiveRecoveries => _consecutiveRecoveries;

  /// Whether the host reported the screen as locked.
  bool get isScreenLocked => _screenLocked;

  /// Starts probing and subscribes to the screen-lock events and to the
  /// window's `closed` event, which tears everything down again.
  ///
  /// Idempotent, so a host that wires this up twice does not end up with two
  /// probe timers racing each other.
  void start() {
    if (_started) return;
    _started = true;
    _cancelProbeTimer = scheduler.periodic(desktopFrameProbeInterval, () {
      // Upstream `() => void probeFrameProduction()`: the interval never waits
      // for the probe, so a slow probe cannot delay the next tick.
      unawaited(probeFrameProduction());
    });
    _removeLockListener = powerMonitor.onLockScreen(() {
      _screenLocked = true;
      _stalledChecks = 0;
    });
    _removeUnlockListener = powerMonitor.onUnlockScreen(() {
      _screenLocked = false;
      _stalledChecks = 0;
    });
    window.onceClosed(dispose);
  }

  /// One probe tick.
  ///
  /// Public (upstream keeps it in a closure) so a host or a test can drive a
  /// single tick deterministically instead of waiting on a real interval.
  Future<void> probeFrameProduction() async {
    if (window.isDestroyed || _recovering) return;
    // A freeze is only meaningful, and only distinguishable from a normal idle
    // window, while the window is actually on screen. A locked screen, a
    // minimized window, or a hidden one legitimately stops producing frames.
    if (_screenLocked || !window.isVisible || window.isMinimized) {
      _stalledChecks = 0;
      return;
    }

    final Object? result;
    try {
      result = await window.executeJavaScript(desktopFrameProbeSource);
    } on Object {
      // The renderer went away mid-probe. No information either way, so the
      // stall count is left untouched rather than reset.
      return;
    }

    // Upstream `if (!result || result.visibilityState !== "visible")`. A
    // non-object result (a number, a string) is truthy in JS but has no
    // `visibilityState`, so it lands in this same branch — which is why the
    // shape check and the value check are folded together here.
    if (result is! Map || result['visibilityState'] != 'visible') {
      _stalledChecks = 0;
      return;
    }
    if (result['producedFrame'] == true) {
      _stalledChecks = 0;
      _consecutiveRecoveries = 0;
      return;
    }

    _stalledChecks += 1;
    if (shouldRecoverFromFrameStall(
      DesktopFrameStallState(
        stalledChecks: _stalledChecks,
        recovering: _recovering,
        msSinceLastRecovery: now() - _lastRecoveryAt,
        consecutiveRecoveries: _consecutiveRecoveries,
      ),
    )) {
      unawaited(recoverCompositor());
    }
  }

  /// Restarts the GPU process and holds off probing for
  /// [desktopGpuRelaunchGrace] while Chromium rebuilds it.
  ///
  /// The bookkeeping is done up front — before the kill — so a probe that
  /// fires during the grace period sees [isRecovering] and bows out.
  Future<void> recoverCompositor() async {
    _recovering = true;
    _lastRecoveryAt = now();
    _consecutiveRecoveries += 1;
    _stalledChecks = 0;
    final gpuPid = findGpuProcessPid(host.getAppMetrics());
    onWarning?.call(
      '[compositor-watchdog] Desktop window stopped producing frames; '
      'restarting GPU process (pid=${gpuPid ?? 'unknown'}, '
      'attempt $_consecutiveRecoveries) to recover',
    );
    if (gpuPid != null) {
      try {
        host.killProcess(gpuPid);
      } on Object catch (error) {
        onWarning?.call(
          '[compositor-watchdog] Could not restart GPU process',
          error,
        );
      }
    }
    await scheduler.delay(desktopGpuRelaunchGrace);
    _recovering = false;
  }

  /// Upstream's `win.once("closed", ...)` teardown. Idempotent.
  void dispose() {
    _cancelProbeTimer?.call();
    _cancelProbeTimer = null;
    _removeLockListener?.call();
    _removeLockListener = null;
    _removeUnlockListener?.call();
    _removeUnlockListener = null;
  }
}

/// Installs the compositor watchdog, but only on macOS.
///
/// Returns null on every other platform — upstream's bare `return` — so a
/// caller can assert the watchdog is genuinely inert on Windows and Linux
/// instead of having to trust that it is.
DesktopCompositorWatchdog? setupDarwinCompositorWatchdog({
  required String platform,
  required DesktopCompositorWindow window,
  required DesktopPowerMonitor powerMonitor,
  required DesktopCompositorHost host,
  required DesktopCompositorScheduler scheduler,
  required DesktopMillisecondClock now,
  DesktopCompositorWarn? onWarning,
}) {
  if (platform != desktopDarwinPlatform) return null;
  final watchdog = DesktopCompositorWatchdog(
    window: window,
    powerMonitor: powerMonitor,
    host: host,
    scheduler: scheduler,
    now: now,
    onWarning: onWarning,
  );
  watchdog.start();
  return watchdog;
}

// ---------------------------------------------------------------------------
// integrations/skills/sync.ts
// ---------------------------------------------------------------------------

/// What one [PaseoSkillsSync.syncSkillsWithResult] pass did.
final class PaseoSkillSyncResult {
  const PaseoSkillSyncResult({
    required this.changedFiles,
    required this.processedSkills,
  });

  /// File writes, deletions and manifest rewrites combined.
  ///
  /// A no-op resync reports 0, which is what lets a caller decide whether the
  /// installed skills actually moved without diffing them again.
  final int changedFiles;

  /// Skills that were present in the bundle and synced without raising. A
  /// skill listed in `skillNames` but missing from the bundle is not counted,
  /// and neither is one whose sync failed.
  final int processedSkills;

  @override
  bool operator ==(Object other) =>
      other is PaseoSkillSyncResult &&
      other.changedFiles == changedFiles &&
      other.processedSkills == processedSkills;

  @override
  int get hashCode => Object.hash(changedFiles, processedSkills);

  @override
  String toString() =>
      'PaseoSkillSyncResult(changedFiles: $changedFiles, '
      'processedSkills: $processedSkills)';
}

/// Reports a per-skill failure instead of aborting the whole sync.
///
/// Deviation: upstream's `onSkillError(skillName, error)` has no stack trace
/// because a JS `Error` carries its own; Dart's does not, so the trace is a
/// third parameter.
typedef PaseoSkillSyncErrorHandler =
    void Function(String skillName, Object error, StackTrace stackTrace);

/// The `node:fs/promises` calls the skill sync makes, on top of the read-only
/// set `paseo_desktop_browser.dart` already declared for the drift diff.
///
/// Extending [PaseoSkillsFileSystem] rather than restating it means one host
/// object can serve both the diff (`operations.ts`) and the copy (`sync.ts`)
/// halves of the same feature, which is how upstream wires them.
abstract interface class PaseoSkillsSyncFileSystem
    implements PaseoSkillsFileSystem {
  /// `mkdir(path, { recursive: true })`.
  Future<void> createDirectory(String path);

  /// `writeFile(path, bytes)`.
  Future<void> writeFile(String path, Uint8List bytes);

  /// `rm(path, { force: true })` — must not throw when the file is missing.
  Future<void> removeFile(String path);

  /// `rm(path, { recursive: true, force: true })` — must not throw when the
  /// directory is missing.
  Future<void> removeDirectoryRecursive(String path);

  /// `rmdir(path)`. Unlike the two above this *may* throw, and the one caller
  /// relies on that: a directory that still holds files must survive the
  /// prune.
  Future<void> removeEmptyDirectory(String path);
}

/// The three directories a skill is removed from.
///
/// Mirrors upstream's `RemoveSkillTargets`, kept separate from
/// `PaseoSkillTargets` (which also names the bundle) because a removal has no
/// source to read from.
final class PaseoRemoveSkillTargets {
  const PaseoRemoveSkillTargets({
    required this.agentsDir,
    required this.claudeDir,
    required this.codexDir,
  });

  final String agentsDir;
  final String claudeDir;
  final String codexDir;

  /// In the order upstream removes them.
  List<String> get directories => <String>[agentsDir, claudeDir, codexDir];
}

/// Mirrors bundled skills onto disk without ever destroying a user's own file.
///
/// That guarantee is the whole reason this module exists rather than being a
/// recursive copy plus a `rm -rf`. Managed directories are *shared* with the
/// user: they can drop their own notes next to a bundled skill. So the sync
/// keeps a manifest ([paseoManagedFilesManifestName]) of every file it wrote,
/// with that file's hash, and only ever deletes a file when
///
/// 1. the manifest says this installer wrote it,
/// 2. the bundle no longer contains it, and
/// 3. its current content still hashes to what the manifest recorded — i.e.
///    the user has not since edited it.
///
/// A file the user added is in none of those, and a file the user edited fails
/// the third check, so both survive.
///
/// Implements [PaseoSkillsSyncGateway] so `PaseoSkillsOperations` in
/// `paseo_desktop_browser.dart` — the port of this module's sibling,
/// `operations.ts` — can drive it directly.
final class PaseoSkillsSync implements PaseoSkillsSyncGateway {
  const PaseoSkillsSync({
    required this.fileSystem,
    required this.hashContent,
    this.pathOps = DesktopBrowserPathOps.posix,
    this.onSkillError,
  });

  final PaseoSkillsSyncFileSystem fileSystem;

  /// Content digest used for change detection. Upstream uses SHA-256 hex; only
  /// equality of the returned strings matters here.
  final PaseoSkillContentHasher hashContent;

  final DesktopBrowserPathOps pathOps;

  /// Deviation: upstream takes this per call, as a field of `SkillSyncOptions`.
  /// It is an instance field here because [PaseoSkillsSyncGateway.syncSkills]
  /// — the interface `operations.ts` calls through — has no slot for it, and a
  /// host's error sink does not vary call to call. When null, a failing skill
  /// aborts the whole sync by rethrowing, exactly as upstream does.
  final PaseoSkillSyncErrorHandler? onSkillError;

  /// Every file under [rootDir], as paths relative to it, excluding the
  /// managed-files manifest at the root.
  ///
  /// Public because upstream exports it. Only the manifest *at the root* is
  /// skipped — a nested file that happens to share the name belongs to the
  /// user and is listed.
  ///
  /// Deviation: upstream computes each relative path with `path.relative`;
  /// this accumulates the prefix during the walk instead, which is equivalent
  /// for a walk that never leaves [rootDir] and avoids needing `path.relative`
  /// in the injected path ops.
  Future<List<String>> listFilesRecursive(String rootDir) async {
    final out = <String>[];

    Future<void> walk(String dir, String prefix) async {
      final entries = await fileSystem.readDirectory(dir);
      for (final entry in entries) {
        final relative = prefix.isEmpty
            ? entry.name
            : '$prefix${pathOps.separator}${entry.name}';
        if (relative == paseoManagedFilesManifestName) continue;
        if (entry.isDirectory) {
          await walk(pathOps.join(<String>[dir, entry.name]), relative);
        } else if (entry.isFile) {
          out.add(relative);
        }
      }
    }

    await walk(rootDir, '');
    return out;
  }

  /// Syncs each of [skillNames] from the bundle into all three targets.
  ///
  /// A name that is not a directory in the bundle is skipped silently rather
  /// than reported: that is how a retired skill name stays in the list without
  /// producing an error on every launch.
  Future<PaseoSkillSyncResult> syncSkillsWithResult({
    required String sourceDir,
    required String agentsDir,
    required String claudeDir,
    required String codexDir,
    required List<String> skillNames,
  }) async {
    var changedFiles = 0;
    var processedSkills = 0;

    for (final skillName in skillNames) {
      final bundleSkillDir = pathOps.join(<String>[sourceDir, skillName]);
      // Upstream `stat(...).catch(() => null)` then `!stat?.isDirectory()`:
      // both "missing" and "not a directory" skip.
      if (!await fileSystem.isDirectory(bundleSkillDir)) continue;

      try {
        for (final targetDir in <String>[agentsDir, claudeDir, codexDir]) {
          changedFiles += await _syncDirectoryFiles(
            bundleSkillDir,
            pathOps.join(<String>[targetDir, skillName]),
          );
        }
        processedSkills++;
      } on Object catch (error, stackTrace) {
        final handler = onSkillError;
        if (handler == null) rethrow;
        handler(skillName, error, stackTrace);
      }
    }

    return PaseoSkillSyncResult(
      changedFiles: changedFiles,
      processedSkills: processedSkills,
    );
  }

  @override
  Future<void> syncSkills({
    required String sourceDir,
    required String agentsDir,
    required String claudeDir,
    required String codexDir,
    required List<String> skillNames,
  }) async {
    await syncSkillsWithResult(
      sourceDir: sourceDir,
      agentsDir: agentsDir,
      claudeDir: claudeDir,
      codexDir: codexDir,
      skillNames: skillNames,
    );
  }

  @override
  Future<void> removeSkill(
    String skillName, {
    required String agentsDir,
    required String claudeDir,
    required String codexDir,
  }) => removeSkillFromTargets(
    skillName,
    PaseoRemoveSkillTargets(
      agentsDir: agentsDir,
      claudeDir: claudeDir,
      codexDir: codexDir,
    ),
  );

  /// Upstream's exported `removeSkill`.
  ///
  /// Unlike the sync, this *is* a plain recursive delete: uninstalling a skill
  /// is an explicit user action, so files the user added inside that skill's
  /// directory go with it.
  Future<void> removeSkillFromTargets(
    String skillName,
    PaseoRemoveSkillTargets targets,
  ) async {
    for (final directory in targets.directories) {
      await fileSystem.removeDirectoryRecursive(
        pathOps.join(<String>[directory, skillName]),
      );
    }
  }

  /// Mirrors one bundled skill directory into one target, returning the number
  /// of changes made.
  Future<int> _syncDirectoryFiles(String srcDir, String dstDir) async {
    final files = await listFilesRecursive(srcDir);
    final srcFileSet = files.toSet();
    final srcHashes = <String, String>{};
    for (final rel in files) {
      srcHashes[rel] = await _hashFile(pathOps.join(<String>[srcDir, rel]));
    }
    // Read *before* writing: the manifest still describes the previous sync,
    // which is what the deletion pass below needs.
    final previousManifest = await _readManagedFilesManifest(dstDir);
    var changed = 0;
    for (final rel in files) {
      if (await _writeFileIfChanged(
        pathOps.join(<String>[srcDir, rel]),
        pathOps.join(<String>[dstDir, rel]),
      )) {
        changed++;
      }
    }

    final deletedRels = <String>[];
    for (final entry
        in (previousManifest ?? const <String, Object?>{}).entries) {
      if (srcFileSet.contains(entry.key)) continue;
      final dstPath = pathOps.join(<String>[dstDir, entry.key]);
      final currentHash = await _hashFileOrNull(dstPath);
      // The user edited (or already removed) this file since the last sync, so
      // it is no longer ours to delete.
      if (currentHash != entry.value) continue;
      await fileSystem.removeFile(dstPath);
      deletedRels.add(entry.key);
      changed++;
    }
    await _pruneEmptyParentDirs(dstDir, deletedRels);
    if (await _writeManifestIfChanged(dstDir, srcHashes)) changed++;
    return changed;
  }

  /// Copies `src` over `dst` only when their bytes differ, so a no-op resync
  /// leaves every mtime alone.
  Future<bool> _writeFileIfChanged(String srcPath, String dstPath) async {
    final src = await fileSystem.readFile(srcPath);
    final dst = await _readFileOrNull(dstPath);
    // Upstream `if (dst && src.equals(dst))`: an *empty* Buffer is truthy in
    // JS, so only a missing destination skips the comparison.
    if (dst != null && _bytesEqual(src, dst)) return false;
    await fileSystem.createDirectory(_dirnameOf(dstPath));
    await fileSystem.writeFile(dstPath, src);
    return true;
  }

  /// The previous sync's `{ relativePath: hash }` map, or null when there is
  /// no readable, well-formed manifest.
  ///
  /// Values are left as `Object?`: upstream casts them to `string` without
  /// checking, and a non-string value then simply never compares equal to a
  /// computed hash, which conservatively keeps the file. Reproduced rather
  /// than tightened, because tightening would start deleting files upstream
  /// keeps.
  Future<Map<String, Object?>?> _readManagedFilesManifest(String dstDir) async {
    final raw = await _readTextOrNull(
      pathOps.join(<String>[dstDir, paseoManagedFilesManifestName]),
    );
    // Upstream `if (!raw) return null`: an empty file is falsy, not just a
    // missing one.
    if (raw == null || raw.isEmpty) return null;
    final parsed = _safeParseJson(raw);
    // `if (!parsed)` — null, 0, "" and false all bail out here.
    if (parsed == null || parsed == false || parsed == 0 || parsed == '') {
      return null;
    }
    if (parsed is! Map) return null;
    if (parsed['version'] != 1) return null;
    final files = parsed['files'];
    // Deviation: `typeof files === "object"` also admits an array, which
    // `Object.entries` would then key by index. This rejects arrays, because
    // an index-keyed manifest can only describe relative paths named "0", "1",
    // ... which this installer never writes.
    if (files is! Map) return null;
    return <String, Object?>{
      for (final entry in files.entries) '${entry.key}': entry.value,
    };
  }

  /// `JSON.parse` that yields null instead of throwing.
  Object? _safeParseJson(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  Future<String> _hashFile(String filePath) async =>
      hashContent(await fileSystem.readFile(filePath));

  Future<String?> _hashFileOrNull(String filePath) async {
    final bytes = await _readFileOrNull(filePath);
    return bytes == null ? null : hashContent(bytes);
  }

  /// Rewrites the manifest only when it would change, so an unchanged sync
  /// reports 0 changed files.
  Future<bool> _writeManifestIfChanged(
    String dstDir,
    Map<String, String> files,
  ) async {
    final next =
        '${_prettyJson.convert(<String, Object?>{'version': 1, 'files': files})}\n';
    final manifestPath = pathOps.join(<String>[
      dstDir,
      paseoManagedFilesManifestName,
    ]);
    final current = await _readTextOrNull(manifestPath);
    if (current == next) return false;
    await fileSystem.createDirectory(dstDir);
    await fileSystem.writeFile(manifestPath, _encodeUtf8(next));
    return true;
  }

  /// Removes the directories that held deleted files, deepest first, so a
  /// nested `references/` does not outlive the last file in it.
  ///
  /// Every removal is attempted and every failure swallowed, which is how a
  /// directory that still holds a user's own file survives: `rmdir` refuses to
  /// empty it, and that refusal is the check.
  ///
  /// Deviation: `Array.prototype.sort` is stable and `List.sort` is not, so
  /// directories of equal depth may be visited in a different order than
  /// upstream. `rmdir` on siblings is order-independent, and depth ordering —
  /// the part that matters — is preserved.
  Future<void> _pruneEmptyParentDirs(String rootDir, List<String> rels) async {
    final dirs = <String>{};
    for (final rel in rels) {
      var dir = _dirnameOf(rel);
      while (dir != '.') {
        dirs.add(dir);
        dir = _dirnameOf(dir);
      }
    }
    final deepestFirst = dirs.toList()
      ..sort(
        (a, b) =>
            b.split(pathOps.separator).length -
            a.split(pathOps.separator).length,
      );
    for (final rel in deepestFirst) {
      try {
        await fileSystem.removeEmptyDirectory(
          pathOps.join(<String>[rootDir, rel]),
        );
      } on Object {
        // Upstream `.catch(() => {})`: a non-empty directory is the expected
        // failure here, not an error.
      }
    }
  }

  Future<Uint8List?> _readFileOrNull(String path) async {
    try {
      return await fileSystem.readFile(path);
    } on Object {
      // Upstream `.catch(() => null)`: any read failure, not just ENOENT.
      return null;
    }
  }

  Future<String?> _readTextOrNull(String path) async {
    final bytes = await _readFileOrNull(path);
    if (bytes == null) return null;
    // Node's `readFile(path, "utf-8")` substitutes U+FFFD for malformed bytes
    // rather than throwing, which `allowMalformed` reproduces.
    return utf8.decode(bytes, allowMalformed: true);
  }

  Uint8List _encodeUtf8(String value) => Uint8List.fromList(utf8.encode(value));

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  /// `path.dirname`, which [DesktopBrowserPathOps] does not expose.
  ///
  /// Deviation: a Windows drive root yields `"C:"` rather than Node's `"C:\"`.
  /// Every call site here passes either a path relative to a skill directory
  /// or a path joined under one of the three target directories, so a drive
  /// root is never the answer.
  String _dirnameOf(String path) {
    if (path.isEmpty) return '.';
    var end = path.length;
    while (end > 1 && _isSeparator(path[end - 1])) {
      end--;
    }
    var index = -1;
    for (var i = end - 1; i > 0; i--) {
      if (_isSeparator(path[i])) {
        index = i;
        break;
      }
    }
    if (index == -1) return _isSeparator(path[0]) ? path[0] : '.';
    var parentEnd = index;
    while (parentEnd > 1 && _isSeparator(path[parentEnd - 1])) {
      parentEnd--;
    }
    return path.substring(0, parentEnd == 0 ? 1 : parentEnd);
  }

  /// Win32 accepts either slash flavour; POSIX accepts only `/`.
  bool _isSeparator(String character) =>
      character == pathOps.separator ||
      (pathOps.separator == r'\' && character == '/');
}
