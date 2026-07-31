// Ports of the frozen Paseo 0.2.0 Vitest suites for the desktop host cluster in
// `lib/desktop/paseo_desktop_window_state.dart` — `settings/window-state.test.ts`,
// `settings/desktop-settings.test.ts`,
// `window/compositor-watchdog/index.test.ts` and
// `integrations/skills/sync.test.ts` — plus the edge cases those suites leave
// unpinned.
//
// The unpinned cases worth naming, because each is a behaviour a reader would
// otherwise have to guess at:
//
//  * JS `Math.round` tie-breaking on negative coordinates (`-2.5` -> `-2`),
//    which a saved window on a left-hand monitor really does hit and which
//    Dart's `num.round()` gets wrong in the opposite direction.
//  * The window-state store's write ordering: the queue that serializes async
//    saves, the `finalized` latch that makes `saveSync` the last writer, and
//    the temp file an in-flight save discards rather than renaming over a
//    fresher snapshot. Upstream's suite only checks that no temp file is left
//    behind on the happy path.
//  * The settings store's deliberate asymmetry — a corrupted file throws out of
//    `get()` but is swallowed by `migrateLegacyRendererSettings` — and the
//    "which patches count as the legacy import" rule that upstream only
//    exercises through `manageBuiltInDaemon`.
//  * Every branch of the compositor watchdog's probe, which upstream never
//    tests at all: it pins only the pure `shouldRecoverFromFrameStall` policy.
//  * The skill sync's three-way delete rule (manifest says ours + gone from the
//    bundle + unmodified on disk), the empty-parent prune, and the manifest
//    rewrite's contribution to the changed-file count.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:coding_agent_app/desktop/paseo_desktop_window_state.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// In-memory `node:fs` for the two user-data documents.
///
/// Paths are compared verbatim, so every test uses POSIX separators to match
/// [DesktopBrowserPathOps.posix]. [writeGate] exists so a test can freeze an
/// async write exactly between "temp file written" and "rename", which is the
/// only window in which `saveSync` can overtake it.
final class _MemoryUserDataFileSystem implements DesktopWindowStateFileSystem {
  final Map<String, String> files = <String, String>{};
  final Set<String> directories = <String>{};

  /// Every mutating call, in order.
  final List<String> log = <String>[];

  /// When set, the *first* [writeAsString] parks after storing the content
  /// until the completer finishes. [writeReached] fires as it parks. That is
  /// the only window in which `saveSync` can overtake an async save.
  Completer<void>? writeGate;
  Completer<void>? writeReached;
  bool _writeGateConsumed = false;

  /// Paths whose next [writeAsString] should fail instead.
  final Set<String> failWritesFor = <String>{};

  /// When set, [readAsString] throws this instead of reporting the file.
  Object? readFailure;

  List<String> get fileNames => files.keys.toList()..sort();

  @override
  Future<String> readAsString(String path) async {
    log.add('read $path');
    final failure = readFailure;
    if (failure != null) throw failure;
    final contents = files[path];
    if (contents == null) throw DesktopFileNotFoundException(path);
    return contents;
  }

  @override
  Future<void> createDirectory(String path) async {
    log.add('mkdir $path');
    directories.add(path);
  }

  @override
  Future<void> writeAsString(String path, String contents) async {
    log.add('write $path');
    if (failWritesFor.remove(path)) {
      throw StateError('write refused: $path');
    }
    files[path] = contents;
    final gate = writeGate;
    if (gate != null && !_writeGateConsumed) {
      _writeGateConsumed = true;
      writeReached?.complete();
      await gate.future;
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    log.add('rename $from -> $to');
    final contents = files.remove(from);
    if (contents == null) throw DesktopFileNotFoundException(from);
    files[to] = contents;
  }

  @override
  Future<void> deleteFile(String path) async {
    log.add('unlink $path');
    if (files.remove(path) == null) throw DesktopFileNotFoundException(path);
  }

  @override
  void createDirectorySync(String path) {
    log.add('mkdirSync $path');
    directories.add(path);
  }

  @override
  void writeAsStringSync(String path, String contents) {
    log.add('writeSync $path');
    files[path] = contents;
  }

  @override
  void renameSync(String from, String to) {
    log.add('renameSync $from -> $to');
    final contents = files.remove(from);
    if (contents == null) throw DesktopFileNotFoundException(from);
    files[to] = contents;
  }
}

/// Monotonic, collision-free stand-in for `${pid}.${randomUUID()}`.
DesktopTempFileToken _sequentialTokens() {
  var next = 0;
  return () => '4242.${++next}';
}

/// In-memory `node:fs` for the skill sync.
///
/// Directories are tracked explicitly, so "a file is sitting where a directory
/// should be" — the case upstream uses to force a per-skill error — behaves the
/// way Node does.
final class _MemorySkillsFileSystem implements PaseoSkillsSyncFileSystem {
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final Set<String> directories = <String>{'/'};

  static const String _separator = '/';

  void seedFile(String path, String contents) {
    _ensureAncestors(path);
    files[path] = Uint8List.fromList(utf8.encode(contents));
  }

  void seedDirectory(String path) {
    directories.add(path);
    _ensureAncestors(path);
  }

  String? textAt(String path) {
    final bytes = files[path];
    return bytes == null ? null : utf8.decode(bytes);
  }

  bool exists(String path) =>
      files.containsKey(path) || directories.contains(path);

  void _ensureAncestors(String path) {
    final parts = path.split(_separator);
    for (var index = 1; index < parts.length; index++) {
      final ancestor = parts.sublist(0, index).join(_separator);
      directories.add(ancestor.isEmpty ? '/' : ancestor);
    }
  }

  /// Whether a plain file sits on [path]'s way down — Node's `ENOTDIR`.
  bool _hasFileAncestor(String path) {
    final parts = path.split(_separator);
    for (var index = 1; index < parts.length; index++) {
      final ancestor = parts.sublist(0, index).join(_separator);
      if (files.containsKey(ancestor)) return true;
    }
    return false;
  }

  @override
  Future<bool> isDirectory(String path) async => directories.contains(path);

  @override
  Future<List<DesktopDirectoryEntry>> readDirectory(String path) async {
    if (!directories.contains(path)) {
      throw StateError('ENOTDIR: $path');
    }
    final prefix = '$path$_separator';
    final names = <String, bool>{};
    for (final file in files.keys) {
      if (!file.startsWith(prefix)) continue;
      final rest = file.substring(prefix.length);
      final slash = rest.indexOf(_separator);
      if (slash == -1) {
        names[rest] = false;
      } else {
        names[rest.substring(0, slash)] = true;
      }
    }
    for (final directory in directories) {
      if (!directory.startsWith(prefix)) continue;
      final rest = directory.substring(prefix.length);
      final slash = rest.indexOf(_separator);
      names[slash == -1 ? rest : rest.substring(0, slash)] = true;
    }
    final sorted = names.keys.toList()..sort();
    return <DesktopDirectoryEntry>[
      for (final name in sorted)
        DesktopDirectoryEntry(
          name: name,
          isFile: !names[name]!,
          isDirectory: names[name]!,
        ),
    ];
  }

  @override
  Future<Uint8List> readFile(String path) async {
    final bytes = files[path];
    if (bytes == null) throw DesktopFileNotFoundException(path);
    return bytes;
  }

  @override
  Future<void> createDirectory(String path) async {
    // `mkdir` also fails when the path itself is already a plain file, which
    // is how upstream forces a per-skill error.
    if (files.containsKey(path) || _hasFileAncestor(path)) {
      throw StateError('ENOTDIR: $path is (or is under) a file');
    }
    seedDirectory(path);
  }

  @override
  Future<void> writeFile(String path, Uint8List bytes) async {
    if (_hasFileAncestor(path)) {
      throw StateError('ENOTDIR: $path');
    }
    files[path] = bytes;
  }

  @override
  Future<void> removeFile(String path) async {
    files.remove(path);
  }

  @override
  Future<void> removeDirectoryRecursive(String path) async {
    final prefix = '$path$_separator';
    files.removeWhere(
      (candidate, _) => candidate == path || candidate.startsWith(prefix),
    );
    directories.removeWhere(
      (candidate) => candidate == path || candidate.startsWith(prefix),
    );
  }

  @override
  Future<void> removeEmptyDirectory(String path) async {
    if (!directories.contains(path)) {
      throw DesktopFileNotFoundException(path);
    }
    final prefix = '$path$_separator';
    final occupied =
        files.keys.any((candidate) => candidate.startsWith(prefix)) ||
        directories.any((candidate) => candidate.startsWith(prefix));
    if (occupied) throw StateError('ENOTEMPTY: $path');
    directories.remove(path);
  }
}

/// Content-addressed and collision-free, which is all the sync needs of a hash.
String _base64Hash(Uint8List bytes) => base64Encode(bytes);

final class _FakeCompositorWindow implements DesktopCompositorWindow {
  @override
  bool isDestroyed = false;

  @override
  bool isVisible = true;

  @override
  bool isMinimized = false;

  final List<String> executedSources = <String>[];

  /// Returned from [executeJavaScript] when [failure] is null.
  Object? result;

  /// Thrown from [executeJavaScript] when non-null.
  Object? failure;

  void Function()? closedHandler;

  @override
  Future<Object?> executeJavaScript(String source) async {
    executedSources.add(source);
    final thrown = failure;
    if (thrown != null) throw thrown;
    return result;
  }

  @override
  void onceClosed(void Function() handler) {
    closedHandler = handler;
  }
}

final class _FakePowerMonitor implements DesktopPowerMonitor {
  void Function()? lockHandler;
  void Function()? unlockHandler;
  int removedLockListeners = 0;
  int removedUnlockListeners = 0;

  @override
  void Function() onLockScreen(void Function() handler) {
    lockHandler = handler;
    return () {
      removedLockListeners++;
      lockHandler = null;
    };
  }

  @override
  void Function() onUnlockScreen(void Function() handler) {
    unlockHandler = handler;
    return () {
      removedUnlockListeners++;
      unlockHandler = null;
    };
  }
}

final class _FakeCompositorHost implements DesktopCompositorHost {
  List<DesktopProcessMetric> metrics = <DesktopProcessMetric>[];
  final List<int> killed = <int>[];
  Object? killFailure;

  @override
  List<DesktopProcessMetric> getAppMetrics() => metrics;

  @override
  void killProcess(int pid) {
    killed.add(pid);
    final failure = killFailure;
    if (failure != null) throw failure;
  }
}

final class _FakeCompositorScheduler implements DesktopCompositorScheduler {
  final List<Duration> intervals = <Duration>[];
  final List<Duration> delays = <Duration>[];
  void Function()? tick;
  int cancelledTimers = 0;

  /// When set, [delay] parks on it instead of returning immediately.
  Completer<void>? delayGate;

  @override
  void Function() periodic(Duration interval, void Function() callback) {
    intervals.add(interval);
    tick = callback;
    return () {
      cancelledTimers++;
      tick = null;
    };
  }

  @override
  Future<void> delay(Duration duration) {
    delays.add(duration);
    return delayGate?.future ?? Future<void>.value();
  }
}

/// Bundles a watchdog with the fakes it was built from.
final class _WatchdogHarness {
  final _FakeCompositorWindow window = _FakeCompositorWindow();
  final _FakePowerMonitor powerMonitor = _FakePowerMonitor();
  final _FakeCompositorHost host = _FakeCompositorHost();
  final _FakeCompositorScheduler scheduler = _FakeCompositorScheduler();
  final List<String> warnings = <String>[];
  final List<Object?> warningErrors = <Object?>[];

  int _nowMs = 1000000;

  set nowMs(int value) => _nowMs = value;

  DesktopCompositorWatchdog build() {
    final watchdog = DesktopCompositorWatchdog(
      window: window,
      powerMonitor: powerMonitor,
      host: host,
      scheduler: scheduler,
      now: () => _nowMs,
      onWarning: (String message, [Object? error]) {
        warnings.add(message);
        warningErrors.add(error);
      },
    );
    watchdog.start();
    return watchdog;
  }

  DesktopCompositorWatchdog? setup({String platform = 'darwin'}) =>
      setupDarwinCompositorWatchdog(
        platform: platform,
        window: window,
        powerMonitor: powerMonitor,
        host: host,
        scheduler: scheduler,
        now: () => _nowMs,
        onWarning: (String message, [Object? error]) {
          warnings.add(message);
          warningErrors.add(error);
        },
      );

  /// A probe result the watchdog reads as "visible window, no frame".
  static const Map<String, Object?> stalledResult = <String, Object?>{
    'producedFrame': false,
    'visibilityState': 'visible',
  };

  /// A probe result the watchdog reads as "visible window, frame arrived".
  static const Map<String, Object?> healthyResult = <String, Object?>{
    'producedFrame': true,
    'visibilityState': 'visible',
  };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const String _userDataPath = '/user-data';
const String _windowStatePath = '/user-data/window-state.json';
const String _settingsPath = '/user-data/desktop-settings.json';

const DesktopWorkArea _primary = DesktopWorkArea(
  x: 0,
  y: 0,
  width: 1920,
  height: 1080,
);

DesktopWindowStateStore _windowStore(_MemoryUserDataFileSystem fileSystem) =>
    DesktopWindowStateStore(
      userDataPath: _userDataPath,
      fileSystem: fileSystem,
      tempFileToken: _sequentialTokens(),
    );

PaseoDesktopSettingsFileStore _settingsStore(
  _MemoryUserDataFileSystem fileSystem,
) => PaseoDesktopSettingsFileStore(
  userDataPath: _userDataPath,
  fileSystem: fileSystem,
  tempFileToken: _sequentialTokens(),
);

Map<String, Object?> _persistedDocument(
  _MemoryUserDataFileSystem fileSystem,
  String path,
) => jsonDecode(fileSystem.files[path]!) as Map<String, Object?>;

/// Sandbox mirroring upstream's skill-sync fixture layout.
final class _SkillSandbox {
  final _MemorySkillsFileSystem fileSystem = _MemorySkillsFileSystem();

  final String sourceDir = '/root/bundle';
  final String agentsDir = '/root/home/.agents/skills';
  final String claudeDir = '/root/home/.claude/skills';
  final String codexDir = '/root/home/.codex/skills';

  final List<String> reportedErrors = <String>[];

  _SkillSandbox() {
    fileSystem.seedDirectory(sourceDir);
  }

  void writeBundleSkill(String name, Map<String, String> files) {
    fileSystem.seedDirectory('$sourceDir/$name');
    files.forEach((String relative, String contents) {
      fileSystem.seedFile('$sourceDir/$name/$relative', contents);
    });
  }

  PaseoSkillsSync sync({bool reportErrors = false}) => PaseoSkillsSync(
    fileSystem: fileSystem,
    hashContent: _base64Hash,
    onSkillError: reportErrors
        ? (String name, Object error, StackTrace stackTrace) =>
              reportedErrors.add(name)
        : null,
  );

  Future<PaseoSkillSyncResult> run(
    List<String> skillNames, {
    bool reportErrors = false,
    String? sourceOverride,
  }) => sync(reportErrors: reportErrors).syncSkillsWithResult(
    sourceDir: sourceOverride ?? sourceDir,
    agentsDir: agentsDir,
    claudeDir: claudeDir,
    codexDir: codexDir,
    skillNames: skillNames,
  );
}

void main() {
  // -------------------------------------------------------------------------
  // settings/window-state.ts — coercion
  // -------------------------------------------------------------------------

  group('coerceDesktopWindowState', () {
    test('rejects everything that is not a record', () {
      expect(coerceDesktopWindowState(null), isNull);
      expect(coerceDesktopWindowState('nope'), isNull);
      expect(coerceDesktopWindowState(<Object?>[]), isNull);
      expect(coerceDesktopWindowState(7), isNull);
    });

    test('rejects a record without usable dimensions', () {
      expect(
        coerceDesktopWindowState(<String, Object?>{'isMaximized': true}),
        isNull,
      );
      expect(
        coerceDesktopWindowState(<String, Object?>{
          'width': 900,
          'height': 'tall',
        }),
        isNull,
      );
    });

    test('clamps dimensions up to the minimum window size', () {
      final state = coerceDesktopWindowState(<String, Object?>{
        'width': 100,
        'height': 50,
        'isMaximized': false,
      });

      expect(state!.width, desktopMinWindowWidth);
      expect(state.height, desktopMinWindowHeight);
    });

    test('keeps a position only when both coordinates survive coercion', () {
      final both = coerceDesktopWindowState(<String, Object?>{
        'x': 12,
        'y': 34,
        'width': 900,
        'height': 700,
      });
      final onlyX = coerceDesktopWindowState(<String, Object?>{
        'x': 12,
        'width': 900,
        'height': 700,
      });

      expect(both!.x, 12);
      expect(both.y, 34);
      expect(onlyX!.x, isNull);
      expect(onlyX.y, isNull);
    });

    test('drops non-finite and non-numeric coordinates', () {
      expect(
        coerceDesktopWindowState(<String, Object?>{
          'x': 'nope',
          'y': null,
          'width': 1000,
          'height': 700,
          'isMaximized': false,
        }),
        const DesktopWindowState(width: 1000, height: 700, isMaximized: false),
      );
      expect(
        coerceDesktopWindowState(<String, Object?>{
          'x': double.nan,
          'y': double.infinity,
          'width': 1000,
          'height': 700,
        })!.x,
        isNull,
      );
    });

    test('treats only a literal true as maximized', () {
      Object? maximized(Object? value) => coerceDesktopWindowState(
        <String, Object?>{'width': 900, 'height': 700, 'isMaximized': value},
      )!.isMaximized;

      expect(maximized(true), isTrue);
      expect(maximized('true'), isFalse);
      expect(maximized(1), isFalse);
      expect(maximized(null), isFalse);
    });

    test('rounds halves toward positive infinity, as JS Math.round does', () {
      // The deviation this port exists to preserve: Dart's `num.round()` would
      // give -3 and -2 here, moving a window a pixel further off a left-hand
      // monitor every time it is saved and restored.
      int? xOf(num value) => coerceDesktopWindowState(<String, Object?>{
        'x': value,
        'y': 0,
        'width': 900,
        'height': 700,
      })!.x;

      expect(xOf(-2.5), -2);
      expect(xOf(-0.5), 0);
      expect(xOf(2.5), 3);
      expect(xOf(-1.5), -1);
      expect(xOf(1.4), 1);
      expect(xOf(-1.6), -2);
    });

    test('leaves a magnitude past 2^53 alone, as Math.round does', () {
      // A double that large has no fractional part left, so rounding is the
      // identity and the `+ 0.5` shift is skipped rather than reintroducing
      // precision noise.
      expect(
        coerceDesktopWindowState(<String, Object?>{
          'x': 1e17,
          'y': 0,
          'width': 900,
          'height': 700,
        })!.x,
        100000000000000000,
      );
    });

    test('rounds a fractional dimension before applying the minimum', () {
      final state = coerceDesktopWindowState(<String, Object?>{
        'width': 399.5,
        'height': 700.4,
      });

      expect(state!.width, desktopMinWindowWidth);
      expect(state.height, 700);
    });
  });

  // -------------------------------------------------------------------------
  // settings/window-state.ts — clamping
  // -------------------------------------------------------------------------

  group('clampDesktopWindowStateToWorkAreas', () {
    test('keeps a state fully inside the primary display unchanged', () {
      const state = DesktopWindowState(
        x: 100,
        y: 100,
        width: 1000,
        height: 700,
        isMaximized: false,
      );

      expect(
        clampDesktopWindowStateToWorkAreas(state, <DesktopWorkArea>[_primary]),
        state,
      );
    });

    test('keeps valid negative coordinates from a left-side monitor', () {
      const left = DesktopWorkArea(x: -1920, y: 0, width: 1920, height: 1080);
      const state = DesktopWindowState(
        x: -1800,
        y: 80,
        width: 1000,
        height: 700,
        isMaximized: false,
      );

      expect(
        clampDesktopWindowStateToWorkAreas(state, <DesktopWorkArea>[
          left,
          _primary,
        ]),
        state,
      );
    });

    test('drops x/y when the window meets no display meaningfully', () {
      const state = DesktopWindowState(
        x: 5000,
        y: 5000,
        width: 1000,
        height: 700,
        isMaximized: false,
      );

      final clamped = clampDesktopWindowStateToWorkAreas(
        state,
        <DesktopWorkArea>[_primary],
      );

      expect(clamped.x, isNull);
      expect(clamped.y, isNull);
      expect(clamped.width, 1000);
      expect(clamped.height, 700);
    });

    test('drops x/y when the visible sliver is under the minimum', () {
      // 60px of width on screen: below the 100px slice the rule demands.
      const state = DesktopWindowState(
        x: -940,
        y: 100,
        width: 1000,
        height: 700,
        isMaximized: false,
      );

      final clamped = clampDesktopWindowStateToWorkAreas(
        state,
        <DesktopWorkArea>[_primary],
      );

      expect(clamped.x, isNull);
      expect(clamped.y, isNull);
    });

    test('accepts a window narrower than the minimum visible slice', () {
      // The requirement is min(100, width), so a 400px-wide window fully on
      // screen is reachable even though the rule's constant is 100.
      const state = DesktopWindowState(
        x: 0,
        y: 0,
        width: 400,
        height: 300,
        isMaximized: false,
      );

      expect(
        clampDesktopWindowStateToWorkAreas(state, <DesktopWorkArea>[
          _primary,
        ]).x,
        0,
      );
    });

    test('shrinks an oversized window to the target work area', () {
      const state = DesktopWindowState(
        x: 0,
        y: 0,
        width: 5000,
        height: 4000,
        isMaximized: false,
      );

      final clamped = clampDesktopWindowStateToWorkAreas(
        state,
        <DesktopWorkArea>[_primary],
      );

      expect(clamped.width, _primary.width);
      expect(clamped.height, _primary.height);
    });

    test('repositions an oversized edge window so it stays on-screen', () {
      // Saved near the right edge and larger than the display: a naive clamp
      // would keep x=1820 and shrink to 1920 wide, leaving it mostly off.
      const state = DesktopWindowState(
        x: 1820,
        y: 0,
        width: 3000,
        height: 2000,
        isMaximized: false,
      );

      final clamped = clampDesktopWindowStateToWorkAreas(
        state,
        <DesktopWorkArea>[_primary],
      );

      expect(clamped.width, _primary.width);
      expect(clamped.height, _primary.height);
      expect(clamped.x, 0);
      expect(clamped.y, 0);
    });

    test('drops position when there are no known displays', () {
      const state = DesktopWindowState(
        x: 100,
        y: 100,
        width: 1000,
        height: 700,
        isMaximized: false,
      );

      final clamped = clampDesktopWindowStateToWorkAreas(
        state,
        const <DesktopWorkArea>[],
      );

      expect(clamped.x, isNull);
      expect(clamped.y, isNull);
      expect(clamped.width, 1000);
      expect(clamped.height, 700);
    });

    test('keeps the size unclamped when there are no known displays', () {
      const state = DesktopWindowState(
        width: 5000,
        height: 4000,
        isMaximized: false,
      );

      final clamped = clampDesktopWindowStateToWorkAreas(
        state,
        const <DesktopWorkArea>[],
      );

      expect(clamped.width, 5000);
      expect(clamped.height, 4000);
    });

    test('preserves the maximized flag through clamping', () {
      const state = DesktopWindowState(
        x: 100,
        y: 100,
        width: 1000,
        height: 700,
        isMaximized: true,
      );

      expect(
        clampDesktopWindowStateToWorkAreas(state, <DesktopWorkArea>[
          _primary,
        ]).isMaximized,
        isTrue,
      );
    });

    test('picks the display showing the most of the window', () {
      const right = DesktopWorkArea(x: 1920, y: 0, width: 1920, height: 1080);
      // 800px on the primary, 200px on the right-hand display.
      const state = DesktopWindowState(
        x: 1120,
        y: 100,
        width: 1000,
        height: 700,
        isMaximized: false,
      );

      final clamped = clampDesktopWindowStateToWorkAreas(
        state,
        <DesktopWorkArea>[_primary, right],
      );

      // Clamped into the primary, whose right edge is 1920.
      expect(clamped.x, 920);
      expect(clamped.y, 100);
    });

    test('clamps an undersized state up to the minimum window size', () {
      const state = DesktopWindowState(
        x: 10,
        y: 10,
        width: 10,
        height: 10,
        isMaximized: false,
      );

      final clamped = clampDesktopWindowStateToWorkAreas(
        state,
        <DesktopWorkArea>[_primary],
      );

      expect(clamped.width, desktopMinWindowWidth);
      expect(clamped.height, desktopMinWindowHeight);
    });

    test('clamps a position into a work area with a non-zero origin', () {
      // A macOS-style work area that starts below the menu bar: the vertical
      // clamp must land on the work area's origin, not on 0.
      const offset = DesktopWorkArea(x: 0, y: 25, width: 1440, height: 875);
      const state = DesktopWindowState(
        x: 1300,
        y: 0,
        width: 800,
        height: 600,
        isMaximized: false,
      );

      final clamped = clampDesktopWindowStateToWorkAreas(
        state,
        <DesktopWorkArea>[offset],
      );

      expect(clamped.x, 640);
      expect(clamped.y, 25);
    });
  });

  // -------------------------------------------------------------------------
  // settings/window-state.ts — store
  // -------------------------------------------------------------------------

  group('DesktopWindowStateStore', () {
    test('returns null when no state has been persisted yet', () async {
      final fileSystem = _MemoryUserDataFileSystem();

      expect(await _windowStore(fileSystem).load(), isNull);
    });

    test('round-trips a saved state through disk', () async {
      final fileSystem = _MemoryUserDataFileSystem();
      final store = _windowStore(fileSystem);
      const state = DesktopWindowState(
        x: 100,
        y: 200,
        width: 1000,
        height: 700,
        isMaximized: false,
      );

      await store.save(state);

      expect(await store.load(), state);
    });

    test('persists the maximized flag', () async {
      final fileSystem = _MemoryUserDataFileSystem();
      final store = _windowStore(fileSystem);

      await store.save(
        const DesktopWindowState(
          x: 0,
          y: 0,
          width: 1280,
          height: 800,
          isMaximized: true,
        ),
      );

      expect((await store.load())!.isMaximized, isTrue);
    });

    test('leaves no temp files behind after an async save', () async {
      final fileSystem = _MemoryUserDataFileSystem();

      await _windowStore(fileSystem).save(
        const DesktopWindowState(
          x: 10,
          y: 10,
          width: 800,
          height: 600,
          isMaximized: false,
        ),
      );

      expect(fileSystem.fileNames, <String>[_windowStatePath]);
    });

    test('writes a versioned document with a trailing newline', () async {
      final fileSystem = _MemoryUserDataFileSystem();

      await _windowStore(fileSystem).save(
        const DesktopWindowState(
          x: 5,
          y: 6,
          width: 900,
          height: 650,
          isMaximized: false,
        ),
      );

      final raw = fileSystem.files[_windowStatePath]!;
      expect(raw.endsWith('\n'), isTrue);
      expect(raw, contains('  "version": 1'));
      expect(
        _persistedDocument(fileSystem, _windowStatePath)['state'],
        <String, Object?>{
          'x': 5,
          'y': 6,
          'width': 900,
          'height': 650,
          'isMaximized': false,
        },
      );
    });

    test('omits absent coordinates rather than writing nulls', () async {
      final fileSystem = _MemoryUserDataFileSystem();

      await _windowStore(fileSystem).save(
        const DesktopWindowState(width: 900, height: 650, isMaximized: false),
      );

      final state =
          _persistedDocument(fileSystem, _windowStatePath)['state']!
              as Map<String, Object?>;
      expect(state.containsKey('x'), isFalse);
      expect(state.containsKey('y'), isFalse);
    });

    test('writes atomically and synchronously via saveSync', () async {
      final fileSystem = _MemoryUserDataFileSystem();

      _windowStore(fileSystem).saveSync(
        const DesktopWindowState(
          x: 5,
          y: 6,
          width: 900,
          height: 650,
          isMaximized: false,
        ),
      );

      expect(
        _persistedDocument(fileSystem, _windowStatePath)['state'],
        <String, Object?>{
          'x': 5,
          'y': 6,
          'width': 900,
          'height': 650,
          'isMaximized': false,
        },
      );
      expect(fileSystem.fileNames, <String>[_windowStatePath]);
      // The whole point of saveSync: it never yields to the event loop.
      expect(fileSystem.log, <String>[
        'mkdirSync $_userDataPath',
        'writeSync $_windowStatePath.tmp.4242.1',
        'renameSync $_windowStatePath.tmp.4242.1 -> $_windowStatePath',
      ]);
    });

    test('returns null for corrupted JSON instead of throwing', () async {
      final fileSystem = _MemoryUserDataFileSystem()
        ..files[_windowStatePath] = '{ not valid json';

      expect(await _windowStore(fileSystem).load(), isNull);
    });

    test('returns null when the document is not an object', () async {
      final fileSystem = _MemoryUserDataFileSystem()
        ..files[_windowStatePath] = '[1, 2, 3]';

      expect(await _windowStore(fileSystem).load(), isNull);
    });

    test('rethrows a read failure that is not a missing file', () async {
      final fileSystem = _MemoryUserDataFileSystem()
        ..readFailure = StateError('EACCES');

      await expectLater(
        _windowStore(fileSystem).load(),
        throwsA(isA<StateError>()),
      );
    });

    test('returns null when persisted state lacks usable dimensions', () async {
      final fileSystem = _MemoryUserDataFileSystem()
        ..files[_windowStatePath] = jsonEncode(<String, Object?>{
          'version': 1,
          'state': <String, Object?>{'isMaximized': true},
        });

      expect(await _windowStore(fileSystem).load(), isNull);
    });

    test('clamps persisted dimensions up to the minimum size', () async {
      final fileSystem = _MemoryUserDataFileSystem()
        ..files[_windowStatePath] = jsonEncode(<String, Object?>{
          'version': 1,
          'state': <String, Object?>{
            'width': 100,
            'height': 50,
            'isMaximized': false,
          },
        });

      final loaded = await _windowStore(fileSystem).load();

      expect(loaded!.width, desktopMinWindowWidth);
      expect(loaded.height, desktopMinWindowHeight);
    });

    test('drops non-finite coordinates while keeping dimensions', () async {
      final fileSystem = _MemoryUserDataFileSystem()
        ..files[_windowStatePath] = jsonEncode(<String, Object?>{
          'version': 1,
          'state': <String, Object?>{
            'x': 'nope',
            'y': null,
            'width': 1000,
            'height': 700,
            'isMaximized': false,
          },
        });

      expect(
        await _windowStore(fileSystem).load(),
        const DesktopWindowState(width: 1000, height: 700, isMaximized: false),
      );
    });

    test('serializes queued saves so the last one wins', () async {
      final fileSystem = _MemoryUserDataFileSystem();
      final store = _windowStore(fileSystem);

      final first = store.save(
        const DesktopWindowState(width: 800, height: 600, isMaximized: false),
      );
      final second = store.save(
        const DesktopWindowState(width: 900, height: 650, isMaximized: false),
      );
      await Future.wait<void>(<Future<void>>[first, second]);

      expect(
        fileSystem.log.where((String entry) => entry.startsWith('rename')),
        <String>[
          'rename $_windowStatePath.tmp.4242.1 -> $_windowStatePath',
          'rename $_windowStatePath.tmp.4242.2 -> $_windowStatePath',
        ],
      );
      expect((await store.load())!.width, 900);
    });

    test('keeps draining the queue after a failed write', () async {
      final fileSystem = _MemoryUserDataFileSystem()
        ..failWritesFor.add('$_windowStatePath.tmp.4242.1');
      final store = _windowStore(fileSystem);

      final failing = store.save(
        const DesktopWindowState(width: 800, height: 600, isMaximized: false),
      );
      final following = store.save(
        const DesktopWindowState(width: 900, height: 650, isMaximized: false),
      );

      await expectLater(failing, throwsA(isA<StateError>()));
      await following;
      expect((await store.load())!.width, 900);
    });

    test(
      'ignores async saves issued after saveSync finalized the store',
      () async {
        final fileSystem = _MemoryUserDataFileSystem();
        final store = _windowStore(fileSystem);

        store.saveSync(
          const DesktopWindowState(width: 900, height: 650, isMaximized: false),
        );
        await store.save(
          const DesktopWindowState(width: 111, height: 999, isMaximized: true),
        );

        expect(store.isFinalized, isTrue);
        expect((await store.load())!.width, 900);
        expect(fileSystem.fileNames, <String>[_windowStatePath]);
      },
    );

    test(
      'discards an in-flight async save when saveSync overtakes it',
      () async {
        final fileSystem = _MemoryUserDataFileSystem()
          ..writeGate = Completer<void>()
          ..writeReached = Completer<void>();
        final store = _windowStore(fileSystem);

        final inFlight = store.save(
          const DesktopWindowState(width: 111, height: 999, isMaximized: true),
        );
        await fileSystem.writeReached!.future;
        store.saveSync(
          const DesktopWindowState(width: 900, height: 650, isMaximized: false),
        );
        fileSystem.writeGate?.complete();
        // The gate consumed by the async write; release whatever remains.
        await inFlight;

        expect((await store.load())!.width, 900);
        // The stale temp file was unlinked rather than renamed over the fresh
        // synchronous snapshot.
        expect(fileSystem.fileNames, <String>[_windowStatePath]);
        expect(fileSystem.log, contains('unlink $_windowStatePath.tmp.4242.1'));
      },
    );

    test('swallows a failure to unlink the discarded temp file', () async {
      final fileSystem = _MemoryUserDataFileSystem()
        ..writeGate = Completer<void>()
        ..writeReached = Completer<void>();
      final store = _windowStore(fileSystem);

      final inFlight = store.save(
        const DesktopWindowState(width: 111, height: 999, isMaximized: true),
      );
      await fileSystem.writeReached!.future;
      store.saveSync(
        const DesktopWindowState(width: 900, height: 650, isMaximized: false),
      );
      // Make the temp file vanish so the unlink fails.
      fileSystem.files.remove('$_windowStatePath.tmp.4242.1');
      fileSystem.writeGate?.complete();

      await expectLater(inFlight, completes);
      expect((await store.load())!.width, 900);
    });
  });

  // -------------------------------------------------------------------------
  // settings/desktop-settings.ts
  // -------------------------------------------------------------------------

  group('PaseoDesktopSettingsFileStore', () {
    test('persists default settings for new users', () async {
      final fileSystem = _MemoryUserDataFileSystem();
      final store = _settingsStore(fileSystem);

      final settings = await store.get();

      expect(settings, defaultPaseoDesktopSettings);
      expect(
        _persistedDocument(fileSystem, _settingsPath)['settings'],
        <String, Object?>{
          'releaseChannel': 'stable',
          'daemon': <String, Object?>{
            'manageBuiltInDaemon': true,
            'keepRunningAfterQuit': true,
          },
        },
      );
      expect(fileSystem.fileNames, <String>[_settingsPath]);
    });

    test('handles concurrent first-launch reads without racing', () async {
      final fileSystem = _MemoryUserDataFileSystem();
      final store = _settingsStore(fileSystem);

      final settings = await Future.wait<PaseoDesktopSettings>(
        List<Future<PaseoDesktopSettings>>.generate(20, (_) => store.get()),
      );

      expect(
        settings,
        List<PaseoDesktopSettings>.filled(20, defaultPaseoDesktopSettings),
      );
      expect(
        _persistedDocument(fileSystem, _settingsPath)['settings'],
        <String, Object?>{
          'releaseChannel': 'stable',
          'daemon': <String, Object?>{
            'manageBuiltInDaemon': true,
            'keepRunningAfterQuit': true,
          },
        },
      );
      expect(fileSystem.fileNames, <String>[_settingsPath]);
    });

    test('coerces invalid persisted values back to safe defaults', () async {
      final fileSystem = _MemoryUserDataFileSystem()
        ..files[_settingsPath] = jsonEncode(<String, Object?>{
          'version': 1,
          'settings': <String, Object?>{
            'releaseChannel': 'nightly',
            'daemon': <String, Object?>{
              'manageBuiltInDaemon': 'sometimes',
              'keepRunningAfterQuit': false,
            },
          },
        });

      final settings = await _settingsStore(fileSystem).get();

      expect(settings.releaseChannel, DesktopAppReleaseChannel.stable);
      expect(settings.daemon.manageBuiltInDaemon, isTrue);
      expect(settings.daemon.keepRunningAfterQuit, isFalse);
    });

    test('coerces a document that is not an object to defaults', () async {
      final fileSystem = _MemoryUserDataFileSystem()
        ..files[_settingsPath] = '[]';

      expect(
        await _settingsStore(fileSystem).get(),
        defaultPaseoDesktopSettings,
      );
    });

    test('coerces a non-record daemon section to defaults', () async {
      final fileSystem = _MemoryUserDataFileSystem()
        ..files[_settingsPath] = jsonEncode(<String, Object?>{
          'version': 1,
          'settings': <String, Object?>{
            'releaseChannel': 'beta',
            'daemon': 'nope',
          },
        });

      final settings = await _settingsStore(fileSystem).get();

      expect(settings.releaseChannel, DesktopAppReleaseChannel.beta);
      expect(settings.daemon, defaultPaseoDesktopSettings.daemon);
    });

    test('patches nested settings and leaves no temp files behind', () async {
      final fileSystem = _MemoryUserDataFileSystem();
      final store = _settingsStore(fileSystem);

      await store.get();
      final next = await store.patch(<String, Object?>{
        'releaseChannel': 'beta',
        'daemon': <String, Object?>{'keepRunningAfterQuit': false},
      });

      expect(next.releaseChannel, DesktopAppReleaseChannel.beta);
      expect(next.daemon.manageBuiltInDaemon, isTrue);
      expect(next.daemon.keepRunningAfterQuit, isFalse);
      expect(fileSystem.fileNames, <String>[_settingsPath]);
    });

    test('ignores a patch that carries nothing recognizable', () async {
      final fileSystem = _MemoryUserDataFileSystem();
      final store = _settingsStore(fileSystem);

      final fromString = await store.patch('nonsense');
      final fromEmptyDaemon = await store.patch(<String, Object?>{
        'daemon': <String, Object?>{'nonsense': 1},
      });

      expect(fromString, defaultPaseoDesktopSettings);
      expect(fromEmptyDaemon, defaultPaseoDesktopSettings);
      expect(
        (_persistedDocument(fileSystem, _settingsPath)['migrations']!
            as Map<String, Object?>)['legacyRendererSettingsImported'],
        isFalse,
      );
    });

    test(
      'does not let stale legacy settings override an explicit patch',
      () async {
        final fileSystem = _MemoryUserDataFileSystem();
        final store = _settingsStore(fileSystem);

        final patched = await store.patch(<String, Object?>{
          'daemon': <String, Object?>{'manageBuiltInDaemon': false},
        });
        final migrated = await store.migrateLegacyRendererSettings(
          <String, Object?>{
            'manageBuiltInDaemon': true,
            'releaseChannel': 'beta',
          },
        );
        final document = _persistedDocument(fileSystem, _settingsPath);

        expect(patched.daemon.manageBuiltInDaemon, isFalse);
        expect(migrated.daemon.manageBuiltInDaemon, isFalse);
        expect(migrated.releaseChannel, DesktopAppReleaseChannel.stable);
        expect(
          (document['migrations']!
              as Map<String, Object?>)['legacyRendererSettingsImported'],
          isTrue,
        );
        expect(
          ((document['settings']! as Map<String, Object?>)['daemon']!
              as Map<String, Object?>)['manageBuiltInDaemon'],
          isFalse,
        );
      },
    );

    test(
      'a keepRunningAfterQuit-only patch does not close the migration',
      () async {
        // The renderer never owned keepRunningAfterQuit, so setting it must not
        // pre-empt the one-shot import of the fields it did own.
        final fileSystem = _MemoryUserDataFileSystem();
        final store = _settingsStore(fileSystem);

        await store.patch(<String, Object?>{
          'daemon': <String, Object?>{'keepRunningAfterQuit': false},
        });
        final migrated = await store.migrateLegacyRendererSettings(
          <String, Object?>{'releaseChannel': 'beta'},
        );

        expect(migrated.releaseChannel, DesktopAppReleaseChannel.beta);
        expect(migrated.daemon.keepRunningAfterQuit, isFalse);
      },
    );

    test('does not rewrite existing settings while reading them', () async {
      final raw = jsonEncode(<String, Object?>{
        'version': 1,
        'settings': <String, Object?>{
          'releaseChannel': 'stable',
          'daemon': <String, Object?>{
            'manageBuiltInDaemon': false,
            'keepRunningAfterQuit': true,
          },
        },
        'migrations': <String, Object?>{
          'legacyRendererSettingsImported': false,
        },
      });
      final fileSystem = _MemoryUserDataFileSystem()
        ..files[_settingsPath] = raw;

      final settings = await _settingsStore(fileSystem).get();

      expect(settings.daemon.manageBuiltInDaemon, isFalse);
      expect(fileSystem.files[_settingsPath], raw);
    });

    test(
      'migrates desktop-owned values from legacy settings exactly once',
      () async {
        final fileSystem = _MemoryUserDataFileSystem();
        final store = _settingsStore(fileSystem);

        await store.patch(<String, Object?>{
          'daemon': <String, Object?>{'keepRunningAfterQuit': false},
        });
        final migrated = await store.migrateLegacyRendererSettings(
          <String, Object?>{
            'releaseChannel': 'beta',
            'manageBuiltInDaemon': false,
            'theme': 'dark',
          },
        );
        final ignoredSecondMigration = await store
            .migrateLegacyRendererSettings(<String, Object?>{
              'releaseChannel': 'stable',
              'manageBuiltInDaemon': true,
            });

        expect(migrated.releaseChannel, DesktopAppReleaseChannel.beta);
        expect(migrated.daemon.manageBuiltInDaemon, isFalse);
        expect(migrated.daemon.keepRunningAfterQuit, isFalse);
        expect(ignoredSecondMigration, migrated);
      },
    );

    test('ignores a legacy blob that is not a record', () async {
      final fileSystem = _MemoryUserDataFileSystem();

      expect(
        await _settingsStore(fileSystem).migrateLegacyRendererSettings('nope'),
        defaultPaseoDesktopSettings,
      );
    });

    test(
      'surfaces a corrupted file from get but recovers in the migration',
      () async {
        // The asymmetry is upstream's: reading settings must not silently hand
        // back defaults for a file that is still sitting on disk, but the
        // migration runs where there is nothing else to fall back to.
        final corrupted = _MemoryUserDataFileSystem()
          ..files[_settingsPath] = '{ not valid json';
        final recovering = _MemoryUserDataFileSystem()
          ..files[_settingsPath] = '{ not valid json';

        await expectLater(
          _settingsStore(corrupted).get(),
          throwsA(isA<FormatException>()),
        );
        expect(
          await _settingsStore(recovering).migrateLegacyRendererSettings(
            <String, Object?>{'releaseChannel': 'beta'},
          ),
          const PaseoDesktopSettings(
            releaseChannel: DesktopAppReleaseChannel.beta,
            daemon: PaseoDesktopDaemonSettings(
              manageBuiltInDaemon: true,
              keepRunningAfterQuit: true,
            ),
          ),
        );
      },
    );

    test('serves later reads from the cache without touching disk', () async {
      final fileSystem = _MemoryUserDataFileSystem();
      final store = _settingsStore(fileSystem);

      await store.get();
      final readsAfterFirstGet = fileSystem.log
          .where((String entry) => entry.startsWith('read'))
          .length;
      await store.get();

      expect(
        fileSystem.log.where((String entry) => entry.startsWith('read')).length,
        readsAfterFirstGet,
      );
    });

    test('satisfies the injected PaseoDesktopSettingsStore interface', () {
      // The reuse claim in this port's library doc, asserted rather than
      // assumed: the command-bus handlers in `paseo_desktop_features.dart`
      // depend on this interface, not on this class.
      expect(
        _settingsStore(_MemoryUserDataFileSystem()),
        isA<PaseoDesktopSettingsStore>(),
      );
    });
  });

  // -------------------------------------------------------------------------
  // window/compositor-watchdog/index.ts
  // -------------------------------------------------------------------------

  group('shouldRecoverFromFrameStall', () {
    const recoverable = DesktopFrameStallState(
      stalledChecks: 3,
      recovering: false,
      msSinceLastRecovery: 120000,
      consecutiveRecoveries: 0,
    );

    test('recovers once the stall threshold is reached', () {
      expect(shouldRecoverFromFrameStall(recoverable), isTrue);
    });

    test('waits until the stall threshold is reached', () {
      expect(
        shouldRecoverFromFrameStall(
          const DesktopFrameStallState(
            stalledChecks: 2,
            recovering: false,
            msSinceLastRecovery: 120000,
            consecutiveRecoveries: 0,
          ),
        ),
        isFalse,
      );
    });

    test('does not recover while a recovery is already in progress', () {
      expect(
        shouldRecoverFromFrameStall(
          const DesktopFrameStallState(
            stalledChecks: 3,
            recovering: true,
            msSinceLastRecovery: 120000,
            consecutiveRecoveries: 0,
          ),
        ),
        isFalse,
      );
    });

    test('respects the cooldown between recoveries', () {
      expect(
        shouldRecoverFromFrameStall(
          const DesktopFrameStallState(
            stalledChecks: 3,
            recovering: false,
            msSinceLastRecovery: 30000,
            consecutiveRecoveries: 0,
          ),
        ),
        isFalse,
      );
    });

    test('treats the cooldown boundary as elapsed', () {
      expect(
        shouldRecoverFromFrameStall(
          const DesktopFrameStallState(
            stalledChecks: 3,
            recovering: false,
            msSinceLastRecovery: 60000,
            consecutiveRecoveries: 0,
          ),
        ),
        isTrue,
      );
    });

    test('stops recovering after the consecutive-recovery cap', () {
      expect(
        shouldRecoverFromFrameStall(
          const DesktopFrameStallState(
            stalledChecks: 3,
            recovering: false,
            msSinceLastRecovery: 120000,
            consecutiveRecoveries: 3,
          ),
        ),
        isFalse,
      );
    });

    test('still recovers on the last attempt below the cap', () {
      expect(
        shouldRecoverFromFrameStall(
          const DesktopFrameStallState(
            stalledChecks: 3,
            recovering: false,
            msSinceLastRecovery: 120000,
            consecutiveRecoveries: 2,
          ),
        ),
        isTrue,
      );
    });
  });

  group('findGpuProcessPid', () {
    test('returns the first GPU process pid', () {
      expect(
        findGpuProcessPid(const <DesktopProcessMetric>[
          DesktopProcessMetric(type: 'Browser', pid: 1),
          DesktopProcessMetric(type: 'GPU', pid: 2),
          DesktopProcessMetric(type: 'GPU', pid: 3),
        ]),
        2,
      );
    });

    test('returns null when Electron reports no GPU process', () {
      expect(
        findGpuProcessPid(const <DesktopProcessMetric>[
          DesktopProcessMetric(type: 'Browser', pid: 1),
        ]),
        isNull,
      );
      expect(findGpuProcessPid(const <DesktopProcessMetric>[]), isNull);
    });
  });

  group('setupDarwinCompositorWatchdog', () {
    test('does nothing off macOS', () {
      final harness = _WatchdogHarness();

      expect(harness.setup(platform: 'win32'), isNull);
      expect(harness.setup(platform: 'linux'), isNull);
      expect(harness.scheduler.intervals, isEmpty);
      expect(harness.powerMonitor.lockHandler, isNull);
      expect(harness.window.closedHandler, isNull);
    });

    test('starts probing and subscribes on macOS', () {
      final harness = _WatchdogHarness();

      final watchdog = harness.setup();

      expect(watchdog, isNotNull);
      expect(harness.scheduler.intervals, <Duration>[
        desktopFrameProbeInterval,
      ]);
      expect(harness.powerMonitor.lockHandler, isNotNull);
      expect(harness.powerMonitor.unlockHandler, isNotNull);
      expect(harness.window.closedHandler, isNotNull);
    });

    test('ignores a second start', () {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();

      watchdog.start();

      expect(harness.scheduler.intervals.length, 1);
    });
  });

  group('DesktopCompositorWatchdog', () {
    test('probes the renderer with the frame-production source', () async {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();
      harness.window.result = _WatchdogHarness.healthyResult;

      await watchdog.probeFrameProduction();

      expect(harness.window.executedSources, <String>[desktopFrameProbeSource]);
      expect(desktopFrameProbeSource, contains('requestAnimationFrame'));
      // The deadline is inlined into the JS source, so a drift between the two
      // would silently change the probe's meaning.
      expect(
        desktopFrameProbeSource,
        contains('finish(false), ${desktopFrameProbeDeadline.inMilliseconds}'),
      );
    });

    test('drives a probe from the interval callback', () async {
      final harness = _WatchdogHarness();
      harness.build();
      harness.window.result = _WatchdogHarness.healthyResult;

      harness.scheduler.tick!();
      await pumpEventQueue();

      expect(harness.window.executedSources.length, 1);
    });

    test('skips the probe entirely when the window is destroyed', () async {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();
      harness.window.isDestroyed = true;

      await watchdog.probeFrameProduction();

      expect(harness.window.executedSources, isEmpty);
    });

    test('skips the probe while a recovery is in flight', () async {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();
      harness.scheduler.delayGate = Completer<void>();
      unawaited(watchdog.recoverCompositor());

      await watchdog.probeFrameProduction();

      expect(watchdog.isRecovering, isTrue);
      expect(harness.window.executedSources, isEmpty);
      harness.scheduler.delayGate!.complete();
      await pumpEventQueue();
      expect(watchdog.isRecovering, isFalse);
    });

    test('resets the stall count for a hidden or minimized window', () async {
      for (final scenario in <String>['hidden', 'minimized', 'locked']) {
        final harness = _WatchdogHarness();
        final watchdog = harness.build();
        harness.window.result = _WatchdogHarness.stalledResult;
        await watchdog.probeFrameProduction();
        expect(watchdog.stalledChecks, 1, reason: scenario);

        switch (scenario) {
          case 'hidden':
            harness.window.isVisible = false;
          case 'minimized':
            harness.window.isMinimized = true;
          case 'locked':
            harness.powerMonitor.lockHandler!();
        }
        await watchdog.probeFrameProduction();

        expect(watchdog.stalledChecks, 0, reason: scenario);
        expect(harness.window.executedSources.length, 1, reason: scenario);
      }
    });

    test('resets the stall count when the screen unlocks', () async {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();
      harness.window.result = _WatchdogHarness.stalledResult;

      harness.powerMonitor.lockHandler!();
      expect(watchdog.isScreenLocked, isTrue);
      await watchdog.probeFrameProduction();
      harness.powerMonitor.unlockHandler!();

      expect(watchdog.isScreenLocked, isFalse);
      expect(watchdog.stalledChecks, 0);
    });

    test('leaves the stall count untouched when the probe throws', () async {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();
      harness.window.result = _WatchdogHarness.stalledResult;
      await watchdog.probeFrameProduction();

      harness.window.failure = StateError('renderer went away');
      await watchdog.probeFrameProduction();

      expect(watchdog.stalledChecks, 1);
    });

    test('resets the stall count for a non-visible document', () async {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();
      harness.window.result = _WatchdogHarness.stalledResult;
      await watchdog.probeFrameProduction();

      harness.window.result = const <String, Object?>{
        'producedFrame': false,
        'visibilityState': 'hidden',
      };
      await watchdog.probeFrameProduction();

      expect(watchdog.stalledChecks, 0);
    });

    test('resets the stall count for a result that is not an object', () async {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();
      harness.window.result = _WatchdogHarness.stalledResult;
      await watchdog.probeFrameProduction();

      harness.window.result = null;
      await watchdog.probeFrameProduction();
      expect(watchdog.stalledChecks, 0);

      harness.window.result = _WatchdogHarness.stalledResult;
      await watchdog.probeFrameProduction();
      harness.window.result = 7;
      await watchdog.probeFrameProduction();
      expect(watchdog.stalledChecks, 0);
    });

    test('a produced frame clears both counters', () async {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();
      harness.host.metrics = const <DesktopProcessMetric>[
        DesktopProcessMetric(type: 'GPU', pid: 4242),
      ];
      harness.window.result = _WatchdogHarness.stalledResult;
      for (var index = 0; index < 3; index++) {
        await watchdog.probeFrameProduction();
      }
      await pumpEventQueue();
      expect(watchdog.consecutiveRecoveries, 1);

      harness.window.result = _WatchdogHarness.healthyResult;
      await watchdog.probeFrameProduction();

      expect(watchdog.stalledChecks, 0);
      expect(watchdog.consecutiveRecoveries, 0);
    });

    test('restarts the GPU process after three stalled probes', () async {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();
      harness.host.metrics = const <DesktopProcessMetric>[
        DesktopProcessMetric(type: 'Browser', pid: 1),
        DesktopProcessMetric(type: 'GPU', pid: 4242),
      ];
      harness.window.result = _WatchdogHarness.stalledResult;

      await watchdog.probeFrameProduction();
      await watchdog.probeFrameProduction();
      expect(harness.host.killed, isEmpty);
      await watchdog.probeFrameProduction();
      await pumpEventQueue();

      expect(harness.host.killed, <int>[4242]);
      expect(harness.scheduler.delays, <Duration>[desktopGpuRelaunchGrace]);
      expect(watchdog.stalledChecks, 0);
      expect(watchdog.consecutiveRecoveries, 1);
      expect(watchdog.isRecovering, isFalse);
      expect(
        harness.warnings.single,
        '[compositor-watchdog] Desktop window stopped producing frames; '
        'restarting GPU process (pid=4242, attempt 1) to recover',
      );
    });

    test('logs an unknown pid and skips the kill', () async {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();

      await watchdog.recoverCompositor();

      expect(harness.host.killed, isEmpty);
      expect(harness.warnings.single, contains('pid=unknown, attempt 1'));
    });

    test('logs a failed kill and still serves out the grace period', () async {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();
      harness.host.metrics = const <DesktopProcessMetric>[
        DesktopProcessMetric(type: 'GPU', pid: 99),
      ];
      harness.host.killFailure = StateError('ESRCH');

      await watchdog.recoverCompositor();

      expect(harness.host.killed, <int>[99]);
      expect(
        harness.warnings.last,
        '[compositor-watchdog] Could not restart GPU process',
      );
      expect(harness.warningErrors.last, isA<StateError>());
      expect(harness.scheduler.delays, <Duration>[desktopGpuRelaunchGrace]);
    });

    test('gives up after the consecutive-recovery cap', () async {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();
      harness.host.metrics = const <DesktopProcessMetric>[
        DesktopProcessMetric(type: 'GPU', pid: 4242),
      ];
      harness.window.result = _WatchdogHarness.stalledResult;

      for (var recovery = 0; recovery < 4; recovery++) {
        for (var probe = 0; probe < 3; probe++) {
          await watchdog.probeFrameProduction();
        }
        await pumpEventQueue();
        // Push the clock past the cooldown so only the cap can stop the next
        // recovery.
        harness.nowMs = 1000000 + (recovery + 1) * 120000;
      }

      expect(harness.host.killed.length, desktopMaxConsecutiveRecoveries);
      expect(watchdog.consecutiveRecoveries, desktopMaxConsecutiveRecoveries);
    });

    test('holds off a second recovery until the cooldown elapses', () async {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();
      harness.host.metrics = const <DesktopProcessMetric>[
        DesktopProcessMetric(type: 'GPU', pid: 4242),
      ];
      harness.window.result = _WatchdogHarness.stalledResult;

      for (var probe = 0; probe < 3; probe++) {
        await watchdog.probeFrameProduction();
      }
      await pumpEventQueue();
      // Only 30s later: inside the 60s cooldown.
      harness.nowMs = 1000000 + 30000;
      for (var probe = 0; probe < 3; probe++) {
        await watchdog.probeFrameProduction();
      }
      await pumpEventQueue();

      expect(harness.host.killed, <int>[4242]);
      expect(watchdog.stalledChecks, 3);
    });

    test('tears down the timer and both listeners on close', () {
      final harness = _WatchdogHarness();
      harness.build();

      harness.window.closedHandler!();

      expect(harness.scheduler.cancelledTimers, 1);
      expect(harness.powerMonitor.removedLockListeners, 1);
      expect(harness.powerMonitor.removedUnlockListeners, 1);
    });

    test('dispose is idempotent', () {
      final harness = _WatchdogHarness();
      final watchdog = harness.build();

      watchdog
        ..dispose()
        ..dispose();

      expect(harness.scheduler.cancelledTimers, 1);
      expect(harness.powerMonitor.removedLockListeners, 1);
    });
  });

  // -------------------------------------------------------------------------
  // integrations/skills/sync.ts
  // -------------------------------------------------------------------------

  group('PaseoSkillsSync.syncSkills', () {
    test('overwrites on-disk skill content when the bundle differs', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{
          'SKILL.md': 'new paseo content',
        });
      sandbox.fileSystem.seedFile(
        '${sandbox.agentsDir}/paseo/SKILL.md',
        'old paseo content',
      );

      final result = await sandbox.run(<String>['paseo']);

      expect(result.processedSkills, 1);
      expect(result.changedFiles, greaterThan(0));
      expect(
        sandbox.fileSystem.textAt('${sandbox.agentsDir}/paseo/SKILL.md'),
        'new paseo content',
      );
      expect(
        sandbox.fileSystem.textAt('${sandbox.claudeDir}/paseo/SKILL.md'),
        'new paseo content',
      );
      expect(
        sandbox.fileSystem.textAt('${sandbox.codexDir}/paseo/SKILL.md'),
        'new paseo content',
      );
    });

    test('installs new bundled skills, including references/', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo-committee', <String, String>{
          'SKILL.md': 'committee content',
          'references/roles.md': 'roles content',
        });

      await sandbox.run(<String>['paseo-committee']);

      for (final target in <String>[
        sandbox.agentsDir,
        sandbox.claudeDir,
        sandbox.codexDir,
      ]) {
        expect(
          sandbox.fileSystem.textAt('$target/paseo-committee/SKILL.md'),
          'committee content',
        );
        expect(
          sandbox.fileSystem.textAt(
            '$target/paseo-committee/references/roles.md',
          ),
          'roles content',
        );
      }
      expect(
        await sandbox.fileSystem.isDirectory(
          '${sandbox.claudeDir}/paseo-committee',
        ),
        isTrue,
      );
    });

    test('leaves on-disk skills not in the bundle untouched', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{'SKILL.md': 'new'});
      sandbox.fileSystem.seedFile(
        '${sandbox.agentsDir}/user-custom-skill/SKILL.md',
        'user content',
      );

      await sandbox.run(<String>['paseo']);

      expect(
        sandbox.fileSystem.textAt(
          '${sandbox.agentsDir}/user-custom-skill/SKILL.md',
        ),
        'user content',
      );
    });

    test(
      'removes stale files previously written to managed skill dirs',
      () async {
        final sandbox = _SkillSandbox()
          ..writeBundleSkill('paseo', <String, String>{
            'SKILL.md': 'old',
            'references/stale.md': 'stale',
          });
        await sandbox.run(<String>['paseo']);

        await sandbox.fileSystem.removeDirectoryRecursive(
          '${sandbox.sourceDir}/paseo',
        );
        sandbox.writeBundleSkill('paseo', <String, String>{'SKILL.md': 'new'});
        await sandbox.run(<String>['paseo']);

        expect(
          sandbox.fileSystem.textAt('${sandbox.agentsDir}/paseo/SKILL.md'),
          'new',
        );
        expect(
          sandbox.fileSystem.exists(
            '${sandbox.agentsDir}/paseo/references/stale.md',
          ),
          isFalse,
        );
        // The now-empty parent directory is pruned too.
        expect(
          sandbox.fileSystem.exists('${sandbox.agentsDir}/paseo/references'),
          isFalse,
        );
      },
    );

    test('keeps a stale file the user has since edited', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{
          'SKILL.md': 'old',
          'references/stale.md': 'stale',
        });
      await sandbox.run(<String>['paseo']);

      await sandbox.fileSystem.removeDirectoryRecursive(
        '${sandbox.sourceDir}/paseo',
      );
      sandbox.writeBundleSkill('paseo', <String, String>{'SKILL.md': 'new'});
      // The third arm of the delete rule: the hash no longer matches what the
      // manifest recorded, so this file is the user's now.
      sandbox.fileSystem.seedFile(
        '${sandbox.agentsDir}/paseo/references/stale.md',
        'user edited this',
      );
      await sandbox.run(<String>['paseo']);

      expect(
        sandbox.fileSystem.textAt(
          '${sandbox.agentsDir}/paseo/references/stale.md',
        ),
        'user edited this',
      );
    });

    test('keeps a stale-directory prune from deleting a user file', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{
          'SKILL.md': 'old',
          'references/stale.md': 'stale',
        });
      await sandbox.run(<String>['paseo']);

      await sandbox.fileSystem.removeDirectoryRecursive(
        '${sandbox.sourceDir}/paseo',
      );
      sandbox.writeBundleSkill('paseo', <String, String>{'SKILL.md': 'new'});
      sandbox.fileSystem.seedFile(
        '${sandbox.agentsDir}/paseo/references/notes.md',
        'user notes',
      );
      await sandbox.run(<String>['paseo']);

      expect(
        sandbox.fileSystem.textAt(
          '${sandbox.agentsDir}/paseo/references/notes.md',
        ),
        'user notes',
      );
      expect(
        sandbox.fileSystem.exists('${sandbox.agentsDir}/paseo/references'),
        isTrue,
      );
    });

    test('preserves user-added files in managed skill dirs', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{'SKILL.md': 'new'});
      sandbox.fileSystem
        ..seedFile('${sandbox.agentsDir}/paseo/SKILL.md', 'old')
        ..seedFile('${sandbox.agentsDir}/paseo/my-context.md', 'user context')
        ..seedFile(
          '${sandbox.agentsDir}/paseo/references/notes.md',
          'user notes',
        );

      await sandbox.run(<String>['paseo']);

      expect(
        sandbox.fileSystem.textAt('${sandbox.agentsDir}/paseo/SKILL.md'),
        'new',
      );
      expect(
        sandbox.fileSystem.textAt('${sandbox.agentsDir}/paseo/my-context.md'),
        'user context',
      );
      expect(
        sandbox.fileSystem.textAt(
          '${sandbox.agentsDir}/paseo/references/notes.md',
        ),
        'user notes',
      );
    });

    test('reports zero changed files on a no-op resync', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{
          'SKILL.md': 'content',
          'references/extra.md': 'ref',
        });

      final first = await sandbox.run(<String>['paseo']);
      final second = await sandbox.run(<String>['paseo']);

      expect(first.changedFiles, greaterThan(0));
      expect(
        second,
        const PaseoSkillSyncResult(changedFiles: 0, processedSkills: 1),
      );
    });

    test('counts the manifest rewrite among the changed files', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{'SKILL.md': 'content'});

      final result = await sandbox.run(<String>['paseo']);

      // One file plus one manifest, in each of three targets.
      expect(result.changedFiles, 6);
      expect(
        sandbox.fileSystem.exists(
          '${sandbox.agentsDir}/paseo/$paseoManagedFilesManifestName',
        ),
        isTrue,
      );
    });

    test('writes a versioned manifest keyed by relative path', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{
          'SKILL.md': 'content',
          'references/extra.md': 'ref',
        });

      await sandbox.run(<String>['paseo']);
      final manifest =
          jsonDecode(
                sandbox.fileSystem.textAt(
                  '${sandbox.agentsDir}/paseo/$paseoManagedFilesManifestName',
                )!,
              )
              as Map<String, Object?>;

      expect(manifest['version'], 1);
      expect(
        (manifest['files']! as Map<String, Object?>).keys.toList(),
        <String>['SKILL.md', 'references/extra.md'],
      );
    });

    test('skips bundle names that are missing from disk', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{'SKILL.md': 'content'});

      final result = await sandbox.run(<String>[
        'paseo',
        'paseo-removed',
      ], reportErrors: true);

      expect(sandbox.reportedErrors, isEmpty);
      expect(result.processedSkills, 1);
      expect(
        sandbox.fileSystem.exists('${sandbox.agentsDir}/paseo-removed'),
        isFalse,
      );
    });

    test(
      'leaves on-disk content alone for a skill dropped from the bundle',
      () async {
        final sandbox = _SkillSandbox()
          ..writeBundleSkill('paseo', <String, String>{'SKILL.md': 'current'});
        sandbox.fileSystem.seedFile(
          '${sandbox.agentsDir}/paseo-deprecated/SKILL.md',
          'old content',
        );

        await sandbox.run(<String>['paseo', 'paseo-deprecated']);

        expect(
          sandbox.fileSystem.textAt(
            '${sandbox.agentsDir}/paseo-deprecated/SKILL.md',
          ),
          'old content',
        );
      },
    );

    test(
      'does not crash when the source bundle directory is missing',
      () async {
        final sandbox = _SkillSandbox();

        final result = await sandbox.run(
          <String>['paseo'],
          reportErrors: true,
          sourceOverride: '/root/no-bundle-here',
        );

        expect(sandbox.reportedErrors, isEmpty);
        expect(
          result,
          const PaseoSkillSyncResult(changedFiles: 0, processedSkills: 0),
        );
      },
    );

    test(
      'reports per-skill errors via onSkillError without throwing',
      () async {
        final sandbox = _SkillSandbox()
          ..writeBundleSkill('paseo', <String, String>{'SKILL.md': 'content'});
        // A file where the skill directory should go forces a write error.
        sandbox.fileSystem.seedFile('${sandbox.agentsDir}/paseo', 'blocking');

        final result = await sandbox.run(<String>['paseo'], reportErrors: true);

        expect(sandbox.reportedErrors, <String>['paseo']);
        expect(result.processedSkills, 0);
      },
    );

    test('rethrows a per-skill error when no handler is installed', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{'SKILL.md': 'content'});
      sandbox.fileSystem.seedFile('${sandbox.agentsDir}/paseo', 'blocking');

      await expectLater(
        sandbox.run(<String>['paseo']),
        throwsA(isA<StateError>()),
      );
    });

    test('keeps syncing the remaining skills after one fails', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{'SKILL.md': 'a'})
        ..writeBundleSkill('paseo-loop', <String, String>{'SKILL.md': 'b'});
      sandbox.fileSystem.seedFile('${sandbox.agentsDir}/paseo', 'blocking');

      final result = await sandbox.run(<String>[
        'paseo',
        'paseo-loop',
      ], reportErrors: true);

      expect(sandbox.reportedErrors, <String>['paseo']);
      expect(result.processedSkills, 1);
      expect(
        sandbox.fileSystem.textAt('${sandbox.agentsDir}/paseo-loop/SKILL.md'),
        'b',
      );
    });

    test(
      'satisfies the PaseoSkillsSyncGateway the operations port calls',
      () async {
        // The gateway signature returns void, so the void-returning override is
        // exercised separately from `syncSkillsWithResult`.
        final sandbox = _SkillSandbox()
          ..writeBundleSkill('paseo', <String, String>{'SKILL.md': 'content'});
        final PaseoSkillsSyncGateway gateway = sandbox.sync();

        await gateway.syncSkills(
          sourceDir: sandbox.sourceDir,
          agentsDir: sandbox.agentsDir,
          claudeDir: sandbox.claudeDir,
          codexDir: sandbox.codexDir,
          skillNames: <String>['paseo'],
        );

        expect(
          sandbox.fileSystem.textAt('${sandbox.agentsDir}/paseo/SKILL.md'),
          'content',
        );
      },
    );
  });

  group('PaseoSkillsSync manifest robustness', () {
    /// Syncs a two-file skill, drops one file from the bundle, replaces the
    /// agents-target manifest with [manifest], then resyncs. Returns whether
    /// the dropped file survived — it should whenever the manifest is
    /// unreadable, because without it the sync cannot prove the file is one it
    /// wrote.
    Future<bool> staleFileSurvives(Object manifest) async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{
          'SKILL.md': 'old',
          'references/stale.md': 'stale',
        });
      await sandbox.run(<String>['paseo']);

      await sandbox.fileSystem.removeDirectoryRecursive(
        '${sandbox.sourceDir}/paseo',
      );
      sandbox.writeBundleSkill('paseo', <String, String>{'SKILL.md': 'new'});
      final manifestPath =
          '${sandbox.agentsDir}/paseo/$paseoManagedFilesManifestName';
      if (manifest is Uint8List) {
        sandbox.fileSystem.files[manifestPath] = manifest;
      } else {
        sandbox.fileSystem.seedFile(manifestPath, manifest as String);
      }
      await sandbox.run(<String>['paseo']);

      return sandbox.fileSystem.exists(
        '${sandbox.agentsDir}/paseo/references/stale.md',
      );
    }

    test('treats an empty manifest as absent', () async {
      expect(await staleFileSurvives(''), isTrue);
    });

    test('treats an unparseable manifest as absent', () async {
      expect(await staleFileSurvives('{ not valid json'), isTrue);
    });

    test('treats a manifest of malformed bytes as absent', () async {
      // Node's `readFile(path, "utf-8")` substitutes U+FFFD rather than
      // throwing, so the failure surfaces as a parse error, not a decode one.
      expect(
        await staleFileSurvives(Uint8List.fromList(<int>[0xff, 0xfe, 0xfd])),
        isTrue,
      );
    });

    test('treats a falsy or non-object manifest as absent', () async {
      expect(await staleFileSurvives('null'), isTrue);
      expect(await staleFileSurvives('0'), isTrue);
      expect(await staleFileSurvives('false'), isTrue);
      expect(await staleFileSurvives('""'), isTrue);
      expect(await staleFileSurvives('123'), isTrue);
      expect(await staleFileSurvives('[]'), isTrue);
    });

    test('treats a manifest of the wrong version as absent', () async {
      expect(
        await staleFileSurvives(
          jsonEncode(<String, Object?>{
            'version': 2,
            'files': <String, Object?>{},
          }),
        ),
        isTrue,
      );
    });

    test('treats a manifest with a non-object files map as absent', () async {
      expect(
        await staleFileSurvives(
          jsonEncode(<String, Object?>{'version': 1, 'files': 'nope'}),
        ),
        isTrue,
      );
    });

    test('keeps a file whose recorded hash is not a string', () async {
      // Upstream casts manifest values to `string` unchecked; a non-string
      // then never equals a computed hash, which conservatively keeps the
      // file. Reproduced rather than tightened.
      expect(
        await staleFileSurvives(
          jsonEncode(<String, Object?>{
            'version': 1,
            'files': <String, Object?>{'references/stale.md': 7},
          }),
        ),
        isTrue,
      );
    });

    test('deletes a file the manifest genuinely accounts for', () async {
      // The control for the cases above: a well-formed manifest whose hash
      // still matches does let the delete through.
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{
          'SKILL.md': 'old',
          'references/stale.md': 'stale',
        });
      await sandbox.run(<String>['paseo']);
      await sandbox.fileSystem.removeDirectoryRecursive(
        '${sandbox.sourceDir}/paseo',
      );
      sandbox.writeBundleSkill('paseo', <String, String>{'SKILL.md': 'new'});

      await sandbox.run(<String>['paseo']);

      expect(
        sandbox.fileSystem.exists(
          '${sandbox.agentsDir}/paseo/references/stale.md',
        ),
        isFalse,
      );
    });
  });

  group('PaseoSkillsSync.listFilesRecursive', () {
    test('lists nested files relative to the root', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{
          'SKILL.md': 'a',
          'references/one.md': 'b',
          'references/deep/two.md': 'c',
        });

      expect(
        await sandbox.sync().listFilesRecursive('${sandbox.sourceDir}/paseo'),
        <String>['SKILL.md', 'references/deep/two.md', 'references/one.md'],
      );
    });

    test('skips only the manifest at the root', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{
          'SKILL.md': 'a',
          paseoManagedFilesManifestName: '{}',
          'references/$paseoManagedFilesManifestName': 'user file',
        });

      expect(
        await sandbox.sync().listFilesRecursive('${sandbox.sourceDir}/paseo'),
        <String>['SKILL.md', 'references/$paseoManagedFilesManifestName'],
      );
    });
  });

  group('PaseoSkillsSync.removeSkill', () {
    test('removes the skill from all three targets when present', () async {
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{'SKILL.md': 'content'});
      await sandbox.run(<String>['paseo']);

      await sandbox.sync().removeSkillFromTargets(
        'paseo',
        PaseoRemoveSkillTargets(
          agentsDir: sandbox.agentsDir,
          claudeDir: sandbox.claudeDir,
          codexDir: sandbox.codexDir,
        ),
      );

      expect(sandbox.fileSystem.exists('${sandbox.agentsDir}/paseo'), isFalse);
      expect(sandbox.fileSystem.exists('${sandbox.claudeDir}/paseo'), isFalse);
      expect(sandbox.fileSystem.exists('${sandbox.codexDir}/paseo'), isFalse);
    });

    test('does not throw when targets are missing', () async {
      final sandbox = _SkillSandbox();

      await expectLater(
        sandbox.sync().removeSkill(
          'does-not-exist',
          agentsDir: sandbox.agentsDir,
          claudeDir: sandbox.claudeDir,
          codexDir: sandbox.codexDir,
        ),
        completes,
      );
    });

    test('removes user-added files along with the skill', () async {
      // Unlike the sync, an uninstall is explicit, so it takes everything.
      final sandbox = _SkillSandbox()
        ..writeBundleSkill('paseo', <String, String>{'SKILL.md': 'content'});
      await sandbox.run(<String>['paseo']);
      sandbox.fileSystem.seedFile(
        '${sandbox.agentsDir}/paseo/mine.md',
        'user file',
      );

      await sandbox.sync().removeSkill(
        'paseo',
        agentsDir: sandbox.agentsDir,
        claudeDir: sandbox.claudeDir,
        codexDir: sandbox.codexDir,
      );

      expect(
        sandbox.fileSystem.exists('${sandbox.agentsDir}/paseo/mine.md'),
        isFalse,
      );
    });
  });

  group('PaseoSkillSyncResult', () {
    test('compares by value', () {
      expect(
        const PaseoSkillSyncResult(changedFiles: 2, processedSkills: 1),
        const PaseoSkillSyncResult(changedFiles: 2, processedSkills: 1),
      );
      expect(
        const PaseoSkillSyncResult(
          changedFiles: 2,
          processedSkills: 1,
        ).hashCode,
        const PaseoSkillSyncResult(
          changedFiles: 2,
          processedSkills: 1,
        ).hashCode,
      );
      expect(
        const PaseoSkillSyncResult(changedFiles: 2, processedSkills: 1),
        isNot(const PaseoSkillSyncResult(changedFiles: 3, processedSkills: 1)),
      );
    });
  });

  group('value types', () {
    test('DesktopWindowState compares by value and prints its fields', () {
      const state = DesktopWindowState(
        x: 1,
        y: 2,
        width: 800,
        height: 600,
        isMaximized: true,
      );

      expect(
        state,
        const DesktopWindowState(
          x: 1,
          y: 2,
          width: 800,
          height: 600,
          isMaximized: true,
        ),
      );
      expect(
        state.hashCode,
        const DesktopWindowState(
          x: 1,
          y: 2,
          width: 800,
          height: 600,
          isMaximized: true,
        ).hashCode,
      );
      expect(
        state,
        isNot(
          const DesktopWindowState(width: 800, height: 600, isMaximized: true),
        ),
      );
      expect(state.toString(), contains('isMaximized: true'));
    });

    test('DesktopWorkArea compares by value and prints its fields', () {
      expect(
        _primary,
        const DesktopWorkArea(x: 0, y: 0, width: 1920, height: 1080),
      );
      expect(
        _primary.hashCode,
        const DesktopWorkArea(x: 0, y: 0, width: 1920, height: 1080).hashCode,
      );
      expect(
        _primary,
        isNot(const DesktopWorkArea(x: 1, y: 0, width: 1920, height: 1080)),
      );
      expect(_primary.toString(), contains('width: 1920'));
    });

    test('diagnostic strings name their fields', () {
      expect(
        const DesktopFrameStallState(
          stalledChecks: 1,
          recovering: false,
          msSinceLastRecovery: 2,
          consecutiveRecoveries: 3,
        ).toString(),
        contains('consecutiveRecoveries: 3'),
      );
      expect(
        const DesktopProcessMetric(type: 'GPU', pid: 7).toString(),
        contains('pid: 7'),
      );
      expect(
        const PaseoSkillSyncResult(
          changedFiles: 1,
          processedSkills: 2,
        ).toString(),
        contains('processedSkills: 2'),
      );
      expect(
        const DesktopFileNotFoundException('/nope').toString(),
        contains('/nope'),
      );
    });

    test('PaseoRemoveSkillTargets lists its directories in order', () {
      expect(
        const PaseoRemoveSkillTargets(
          agentsDir: '/a',
          claudeDir: '/c',
          codexDir: '/x',
        ).directories,
        <String>['/a', '/c', '/x'],
      );
    });
  });
}
