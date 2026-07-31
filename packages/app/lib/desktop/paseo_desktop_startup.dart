/// Port of Paseo 0.2.0's desktop *host-process* rules — the cluster that runs
/// in the Electron main process before (and around) the app UI exists:
///
/// - `desktop/desktop-startup.ts` — the ordered decision at process boot:
///   whether this launch is really a CLI invocation that should never open a
///   window, and what the GUI path must do first when it is not.
/// - `desktop/open-project-routing.ts` — which argv entry, if any, names a
///   project directory to open, given that the OS and Chromium both inject
///   arguments of their own.
/// - `desktop/pending-open-project-store.ts` — the per-window mailbox that
///   holds that path until the freshly created window asks for it.
/// - `desktop/system/arm64-translation.ts` — whether the app is an x64 build
///   running under Rosetta on Apple silicon.
/// - `desktop/integrations/cli-install/path.ts` — which file the `paseo` CLI
///   symlink should point at for the current platform and packaging mode.
/// - `desktop/diagnostics/tail-file.ts` — the last N non-empty lines of a log
///   file, and which read failures a diagnostics bundle is allowed to swallow.
/// - `desktop/features/opener.ts` — the allowlist guarding the "open this URL
///   in the user's browser" IPC channel.
///
/// This repo has no Electron main process; the equivalent responsibilities live
/// in `core/desktop/` and `packages/daemon_lifecycle`. Only the *rules* are
/// ported here. Every host capability upstream reaches for as an ambient global
/// — `node:fs`, `node:child_process`, `node:path`, `process.platform`,
/// `electron.app`, `electron.ipcMain`, `electron.shell` — is an injected
/// parameter, so nothing in this library imports `dart:io` and the whole file
/// is exercisable with no desktop host present.
///
/// ## Reuse notes
///
/// - The URL opener takes the repo's existing [ExternalUrlLauncher]
///   (`core/external_url_launcher.dart`) as its shell port rather than
///   declaring a parallel one.
/// - No route type is declared. Upstream's open-project path stays a raw
///   filesystem path the whole way through this cluster (`main.ts` hands it to
///   the renderer over IPC verbatim), so `core/host_routes.dart` — which owns
///   `buildOpenProjectRoute` and friends — is deliberately *not* involved. The
///   renderer-side hop from path to route is a different module.
/// - [DesktopHostBridge] (`paseo_desktop_daemon_rules.dart`) is **not** reused
///   by [registerOpenerHandlers]: that bridge models the renderer *invoking* a
///   host command, whereas the opener is the host *receiving* one. They are
///   opposite ends of the same channel, so [DesktopIpcRegistrar] is a genuinely
///   new port rather than a duplicate of an existing one.
/// - `core/paseo_platform_rules.dart` already owns `DesktopLogTail`, the
///   `{logPath, contents}` pair `collectDesktopDiagnosticSections` consumes.
///   [tailFile] produces the `contents` half, so no log-tail payload type is
///   redeclared here.
/// - `desktop_browser_window_open.dart`'s `isAllowedDesktopBrowserUrl` is a
///   *different* allowlist (it deliberately admits `about:blank` and the empty
///   string, which an "open in the user's browser" channel must not), so
///   [isAllowedExternalUrl] is its own predicate. See its doc for details.
library;

import '../core/external_url_launcher.dart' show ExternalUrlLauncher;

// Re-exported because it appears in this library's public signatures, so a
// caller wiring up the opener need not know which existing module it came from.
export '../core/external_url_launcher.dart' show ExternalUrlLauncher;

// ---------------------------------------------------------------------------
// Shared: the host platform
// ---------------------------------------------------------------------------

/// Which OS family the host process reports.
///
/// Upstream threads Node's `NodeJS.Platform` — an open union of strings
/// (`"darwin" | "win32" | "linux" | "aix" | "freebsd" | ...`) — through both
/// [detectRunningUnderARM64Translation] and [resolveCliInstallSourcePath].
///
/// Deviation: a Dart enum is closed, so the long tail of Node platforms that
/// neither rule names collapses into [other]. That is observably identical,
/// because both rules only ever branch on `darwin`, `win32` and `linux` and
/// treat every other value as "none of the above".
///
/// The existing `TerminalHostPlatform` (`terminal/terminal_file_drop.dart`) is
/// deliberately not reused: it is a windows/non-windows split, which cannot
/// express the darwin-vs-linux distinction both rules here depend on.
enum DesktopHostPlatform {
  /// Node's `"darwin"` — macOS.
  darwin('darwin'),

  /// Node's `"linux"`.
  linux('linux'),

  /// Node's `"win32"` — every Windows build, 32- and 64-bit alike.
  windows('win32'),

  /// Any platform neither rule in this library names (`freebsd`, `aix`, ...).
  ///
  /// Carries an empty wire name because it stands for a set of values, not one.
  other('');

  const DesktopHostPlatform(this.nodeName);

  /// The `process.platform` string this constant corresponds to.
  final String nodeName;

  /// Maps a raw `process.platform` string onto this enum, folding anything
  /// unrecognised into [other] exactly as upstream's branching does.
  static DesktopHostPlatform fromNodeName(String nodeName) =>
      switch (nodeName) {
        'darwin' => DesktopHostPlatform.darwin,
        'linux' => DesktopHostPlatform.linux,
        'win32' => DesktopHostPlatform.windows,
        _ => DesktopHostPlatform.other,
      };
}

// ---------------------------------------------------------------------------
// desktop-startup.ts
// ---------------------------------------------------------------------------

/// The four (plus one optional) effects [runDesktopStartup] sequences.
///
/// Upstream declares this as `DesktopStartupDependencies`, an interface of bare
/// closures that `main.ts` fills in with module-level functions. It is a class
/// with named parameters here to match repo style; the members keep their
/// upstream names so the two files read side by side.
final class DesktopStartupPorts {
  /// Creates a startup port bundle.
  const DesktopStartupPorts({
    required this.hasPendingGuiLaunchRequest,
    required this.runCliPassthroughIfRequested,
    required this.inheritLoginShellEnv,
    required this.bootstrapGui,
    this.autoUpdateInstalledSkills,
  });

  /// Whether this launch already knows it must show a window — because argv
  /// named a project directory, or a deep link named an agent to navigate to.
  ///
  /// When true the CLI passthrough is skipped *entirely*, not merely ignored:
  /// `paseo /some/project` and `paseo://agent/...` must open the GUI, and
  /// letting the CLI branch run first would consume the launch.
  ///
  /// Upstream `main.ts` computes this as
  /// `Boolean(pendingOpenProjectPath || pendingAgentNavigation)`; composing the
  /// two sources is the caller's job, outside this cluster.
  final bool hasPendingGuiLaunchRequest;

  /// Runs the bundled CLI if argv asked for it, resolving `true` when it did.
  ///
  /// A `true` result means the process has finished its work headlessly and
  /// must not continue into GUI bootstrap.
  final Future<bool> Function() runCliPassthroughIfRequested;

  /// Copies the user's login-shell environment into this process.
  ///
  /// Only the GUI path needs it: a GUI launched from Finder/Dock inherits a
  /// bare environment, so `PATH` would be missing the tools agents shell out
  /// to. A CLI launch already has the user's shell environment, which is why
  /// this deliberately runs *after* the passthrough check.
  final void Function() inheritLoginShellEnv;

  /// Brings up windows, tray, IPC — everything the GUI needs.
  final Future<void> Function() bootstrapGui;

  /// Kicks off the background refresh of installed skills.
  ///
  /// Optional and fire-and-forget: it is started after the GUI is up and is
  /// never awaited, so a slow or failing skills registry cannot delay or block
  /// the window appearing.
  final void Function()? autoUpdateInstalledSkills;
}

/// Runs the desktop host's boot sequence, returning early when the launch was
/// really a CLI invocation.
///
/// The ordering is the whole point of the module, and all of it is observable:
///
/// 1. A pending GUI launch request short-circuits the CLI check, so
///    [DesktopStartupPorts.runCliPassthroughIfRequested] is not merely ignored
///    but never called.
/// 2. Otherwise the CLI passthrough runs first, and a `true` result ends
///    startup before any GUI-only environment work happens.
/// 3. Login-shell environment inheritance precedes GUI bootstrap, so windows
///    and agents see the finished `PATH`.
/// 4. Skills auto-update starts last, after the GUI is up.
Future<void> runDesktopStartup(DesktopStartupPorts ports) async {
  // Dart's `&&` short-circuits around the `await` exactly as JS's does, so the
  // "never called" guarantee in step 1 survives the port unchanged.
  if (!ports.hasPendingGuiLaunchRequest &&
      await ports.runCliPassthroughIfRequested()) {
    return;
  }

  ports.inheritLoginShellEnv();
  await ports.bootstrapGui();
  // Upstream `deps.autoUpdateInstalledSkills?.()` — absent means "this build
  // has no skills registry", not "skip it this once".
  ports.autoUpdateInstalledSkills?.call();
}

// ---------------------------------------------------------------------------
// open-project-routing.ts
// ---------------------------------------------------------------------------

/// The explicit flag form, kept for launches from older shell integrations.
const String openProjectFlag = '--open-project';

/// Argument prefixes dropped before anything else is considered.
///
/// `-psn_` is the process serial number macOS appends when an app is launched
/// from Finder; `--no-sandbox` is one of the Chromium switches Electron may
/// inject. Neither is a user argument, and both would otherwise shift the
/// positional scan. Matching is by *prefix*, so `--no-sandbox-foo` is dropped
/// too — upstream uses `startsWith`, and that is reproduced verbatim.
const List<String> openProjectIgnoredArgPrefixes = <String>[
  '-psn_',
  '--no-sandbox',
];

/// The filesystem questions [parseOpenProjectPathFromArgv] needs answered.
///
/// Upstream calls `path.isAbsolute`, `existsSync` and `statSync` directly. They
/// are injected here so the rule carries no `dart:io` dependency, and so the
/// *order* of the two questions stays observable — see [isAbsolutePath].
abstract interface class OpenProjectPathProbe {
  /// Upstream `path.isAbsolute(candidate)`.
  ///
  /// Kept separate from [isExistingDirectory] because upstream short-circuits
  /// on it: a relative argument is rejected without ever touching the disk.
  /// Implementations must use the *host's* rules, which differ by platform
  /// (`/x` is absolute on POSIX; `C:\x` and `\\server\share` on Windows).
  bool isAbsolutePath(String candidate);

  /// Whether [candidate] exists and is a directory.
  ///
  /// Deviation: this collapses upstream's `existsSync(c)` guard, the
  /// `statSync(c).isDirectory()` call and the `try/catch` around it into one
  /// question, because all three failure shapes — missing, unstattable,
  /// not-a-directory — produce the same `false`. Implementations must follow
  /// symlinks, as `statSync` does, so a symlink to a directory counts.
  bool isExistingDirectory(String candidate);
}

bool _isExistingDirectoryAbsolutePath(
  String candidate,
  OpenProjectPathProbe probe,
) {
  if (!probe.isAbsolutePath(candidate)) {
    return false;
  }
  return probe.isExistingDirectory(candidate);
}

/// Extracts the project directory a launch asked to open, or `null`.
///
/// Two forms are accepted, in this order:
///
/// 1. A bare positional argument that is an absolute path to an existing
///    directory. This is what `paseo ~/code/thing` and a Finder "Open With"
///    produce, and the existence check is what makes it safe to scan
///    positionally at all: a stray non-flag argument that is not a real
///    directory is skipped rather than mistaken for one.
/// 2. `--open-project <path>`, retained for backward compatibility with
///    launchers that predate form 1.
///
/// [argv] is the raw process argv and [isDefaultApp] mirrors Electron's
/// `process.defaultApp`: it is true when running unpackaged (`electron .`),
/// where argv is `[electron, appPath, ...userArgs]` and two entries must be
/// dropped instead of one.
///
/// Deviation (JS truthiness): upstream guards the positional result with
/// `if (positionalProjectPath)`, so an empty-string match would be treated as
/// "not found" and fall through to the flag branch rather than ending the
/// search. That arm is unreachable with a real filesystem — `path.isAbsolute("")`
/// is false — but it is reproduced exactly, because it is a [probe]
/// implementation detail rather than a law. The same truthiness guard applies
/// to the flag's value, where `undefined` (flag was the last argument) and `""`
/// both yield `null`.
String? parseOpenProjectPathFromArgv({
  required List<String> argv,
  required bool isDefaultApp,
  required OpenProjectPathProbe probe,
}) {
  // `Iterable.skip` mirrors `Array.prototype.slice(n)` for a short argv: both
  // yield nothing rather than throwing, which `List.sublist` would.
  final List<String> effectiveArgs = <String>[
    for (final String arg in argv.skip(isDefaultApp ? 2 : 1))
      if (!openProjectIgnoredArgPrefixes.any(arg.startsWith)) arg,
  ];

  String? positionalProjectPath;
  for (final String arg in effectiveArgs) {
    if (!arg.startsWith('-') && _isExistingDirectoryAbsolutePath(arg, probe)) {
      positionalProjectPath = arg;
      break;
    }
  }
  if (positionalProjectPath != null && positionalProjectPath.isNotEmpty) {
    return positionalProjectPath;
  }

  final int openProjectIndex = effectiveArgs.indexOf(openProjectFlag);
  if (openProjectIndex == -1) {
    return null;
  }

  // Upstream reads `effectiveArgs[i + 1]`, which is `undefined` past the end;
  // the bounds check stands in for that, and the emptiness check for the
  // `flaggedProjectPath && ...` truthiness guard that follows it.
  final int valueIndex = openProjectIndex + 1;
  if (valueIndex >= effectiveArgs.length) {
    return null;
  }
  final String flaggedProjectPath = effectiveArgs[valueIndex];
  if (flaggedProjectPath.isEmpty) {
    return null;
  }
  return _isExistingDirectoryAbsolutePath(flaggedProjectPath, probe)
      ? flaggedProjectPath
      : null;
}

// ---------------------------------------------------------------------------
// pending-open-project-store.ts
// ---------------------------------------------------------------------------

/// A per-window mailbox holding the project path a window should open on mount.
///
/// The host cannot hand the path to a window directly: the window is created
/// before its renderer exists, and the renderer only asks for the path once it
/// has booted. So the path is parked under the window's id and collected later.
/// Keying by window id — upstream's `webContentsId` — is what keeps two windows
/// opened in the same second from stealing each other's project.
///
/// The same shape as `PendingDesktopBrowserWindowOpens`
/// (`core/desktop/desktop_browser_window_open.dart`), which parks pending popup
/// URLs per guest id. They are not merged: that one accumulates a capped *list*
/// of URLs and validates them, this one holds a single normalised path.
final class PendingOpenProjectStore {
  /// Creates an empty store.
  PendingOpenProjectStore();

  final Map<int, String> _pendingPathByWebContentsId = <int, String>{};

  /// Parks [projectPath] for [webContentsId].
  ///
  /// A blank path *clears* any previously parked one rather than storing it, so
  /// a window explicitly created with no project cannot inherit a stale path
  /// from a recycled window id.
  ///
  /// Deviation: upstream accepts `string | null | undefined` and additionally
  /// runs a `typeof projectPath !== "string"` guard, because `main.ts` forwards
  /// this value straight off an untyped IPC payload. Dart collapses `null` and
  /// `undefined` into one value, and the static type makes non-strings
  /// unrepresentable, so that guard has no runtime counterpart here — its two
  /// reachable outcomes (null clears, string is trimmed) are preserved exactly.
  void set(int webContentsId, String? projectPath) {
    final String? normalizedPath = _normalizeProjectPath(projectPath);
    if (normalizedPath == null) {
      _pendingPathByWebContentsId.remove(webContentsId);
      return;
    }

    _pendingPathByWebContentsId[webContentsId] = normalizedPath;
  }

  /// Returns and clears the path parked for [webContentsId], or `null`.
  ///
  /// Consuming is destructive by design: the pending path answers "what should
  /// this window open *at startup*", so a renderer that reloads must not open
  /// the project a second time.
  String? take(int webContentsId) =>
      _pendingPathByWebContentsId.remove(webContentsId);

  /// Drops the path parked for [webContentsId] without reading it.
  ///
  /// Called when a window closes before its renderer ever asked, so a closed
  /// window's id does not leak an entry.
  void delete(int webContentsId) {
    _pendingPathByWebContentsId.remove(webContentsId);
  }

  /// Upstream `normalizeProjectPath`: blank and whitespace-only become `null`.
  ///
  /// Dart's `String.trim` and JS's `String.prototype.trim` strip the same set
  /// here — Unicode whitespace, line terminators and U+FEFF — so a value that
  /// normalises to empty in one normalises to empty in the other.
  ///
  /// Note that a *non-blank* path is stored trimmed, so the trailing newline a
  /// shell pipeline leaves on a path never reaches the renderer.
  static String? _normalizeProjectPath(String? projectPath) {
    if (projectPath == null) {
      return null;
    }

    final String trimmedPath = projectPath.trim();
    return trimmedPath.isEmpty ? null : trimmedPath;
  }
}

// ---------------------------------------------------------------------------
// system/arm64-translation.ts
// ---------------------------------------------------------------------------

/// The `sysctl` key that reports whether the calling process is translated.
const String sysctlTranslatedKey = 'sysctl.proc_translated';

/// The options [ExecFileSync] is called with.
///
/// Modelled as a value class rather than loose parameters so a test can assert
/// the exact call shape upstream's suite pins, and so the two settings that
/// matter cannot silently drift: `utf-8` (without it Node hands back a Buffer
/// and the `=== "1"` comparison would never hold) and the 1 s timeout (this
/// runs on the startup path, so a wedged `sysctl` must not stall boot).
final class ExecFileSyncOptions {
  /// Creates a set of exec options.
  const ExecFileSyncOptions({required this.encoding, required this.timeoutMs});

  /// Upstream `encoding` — the text encoding the child's stdout is decoded as.
  final String encoding;

  /// Upstream `timeout`, in milliseconds.
  final int timeoutMs;

  @override
  bool operator ==(Object other) =>
      other is ExecFileSyncOptions &&
      other.encoding == encoding &&
      other.timeoutMs == timeoutMs;

  @override
  int get hashCode => Object.hash(encoding, timeoutMs);

  @override
  String toString() =>
      'ExecFileSyncOptions(encoding: $encoding, timeoutMs: $timeoutMs)';
}

/// Runs a program to completion and returns its decoded stdout.
///
/// The port for Node's `execFileSync`. Implementations throw when the program
/// is missing, exits non-zero, or exceeds the timeout — every one of which
/// [detectRunningUnderARM64Translation] reads as "not translated".
typedef ExecFileSync =
    String Function(
      String file,
      List<String> args,
      ExecFileSyncOptions options,
    );

/// Whether this process is an x64 build running under Rosetta 2.
///
/// The answer changes what the app may assume about the machine: a translated
/// process reports x64 while the hardware is arm64, so architecture-specific
/// downloads and native tooling must be picked for the *real* CPU, and the user
/// is better served by the arm64 build.
///
/// Two sources, cheapest first:
///
/// 1. Non-macOS is never translated, and is answered without spawning anything.
///    The early return is observable: [execFileSync] must not be called.
/// 2. Electron's own `app.runningUnderARM64Translation`, passed in as
///    [hostReportedTranslation], is trusted when it says `true`.
/// 3. Otherwise `sysctl -in sysctl.proc_translated`, whose stdout is `1` when
///    translated. Any failure — no `sysctl`, unknown key on older macOS, or a
///    timeout — means "not translated", because a diagnostic probe must never
///    take the app down.
///
/// Deviation: upstream reads [hostReportedTranslation] as
/// `electronReportedTranslation === true`, a strict comparison that treats both
/// `false` and `undefined` as "no opinion" and falls through to `sysctl`. The
/// nullable `bool?` reproduces that three-state input directly, and the
/// comparison stays explicit for the same reason. Upstream also *defaults*
/// [execFileSync] to Node's implementation; there is no ambient process here,
/// so it is required.
bool detectRunningUnderARM64Translation({
  required DesktopHostPlatform platform,
  required ExecFileSync execFileSync,
  bool? hostReportedTranslation,
}) {
  if (platform != DesktopHostPlatform.darwin) {
    return false;
  }

  if (hostReportedTranslation == true) {
    return true;
  }

  try {
    final String output = execFileSync('sysctl', const <String>[
      '-in',
      sysctlTranslatedKey,
    ], const ExecFileSyncOptions(encoding: 'utf-8', timeoutMs: 1000));
    return output.trim() == '1';
  } catch (_) {
    return false;
  }
}

/// Caches [detectRunningUnderARM64Translation] for the life of the process.
///
/// The answer cannot change while the process runs, and the fallback spawns a
/// subprocess, so it is computed at most once — including when the answer is
/// `false`, which is the common case and the one worth not re-probing.
///
/// Deviation: upstream caches in a module-level `let cached: boolean | null`
/// and reads `process.platform` and `app.runningUnderARM64Translation` from
/// ambient globals inside the getter. A mutable library-level variable in Dart
/// would be unresettable between tests and would bake in a host dependency this
/// library is meant not to have, so the cache and its inputs are an instance.
/// One instance per process reproduces upstream's semantics exactly; the class
/// simply makes that lifetime the caller's explicit choice.
final class Arm64TranslationDetector {
  /// Creates a detector over a fixed host environment.
  Arm64TranslationDetector({
    required this.platform,
    required this.execFileSync,
    this.hostReportedTranslation,
  });

  /// The host's `process.platform`.
  final DesktopHostPlatform platform;

  /// The `sysctl` runner used by the fallback probe.
  final ExecFileSync execFileSync;

  /// Electron's `app.runningUnderARM64Translation`, or `null` when the host
  /// has no opinion.
  final bool? hostReportedTranslation;

  bool? _cachedRunningUnderARM64Translation;

  /// Upstream `isRunningUnderARM64Translation()`.
  ///
  /// Computes on first call and returns the memoised answer thereafter.
  bool isRunningUnderARM64Translation() =>
      _cachedRunningUnderARM64Translation ??=
          detectRunningUnderARM64Translation(
            platform: platform,
            execFileSync: execFileSync,
            hostReportedTranslation: hostReportedTranslation,
          );
}

// ---------------------------------------------------------------------------
// integrations/cli-install/path.ts
// ---------------------------------------------------------------------------

/// Which file the user-installed `paseo` CLI entry should point at.
///
/// The install writes a symlink (or a shim on Windows) into the user's `PATH`,
/// and the interesting question is what it must resolve to *later*, long after
/// this call:
///
/// - **Windows** always gets the shim, packaged or not: the launcher is a
///   `.cmd`, and the `.exe` is not directly invocable as a CLI.
/// - **Unpackaged** builds always get the shim, because the "executable" during
///   development is the Electron binary, which would ignore the app entirely.
/// - **macOS** packaged builds get the shim inside the bundle. The bundle is
///   relocatable as a unit, so a path into `Contents/Resources` stays valid.
/// - **Linux AppImage** builds get [appImagePath] — the *original* `.AppImage`
///   the user keeps around. The running executable lives under a `/tmp/.mount_*`
///   FUSE mount that disappears the moment the app exits, so linking to it
///   would produce a symlink that is broken by the time it is used.
/// - Everything else falls back to the running executable, which for a packaged
///   non-AppImage Linux install is a real, stable path.
///
/// Note the ordering: the Windows check precedes the packaging check, so an
/// unpackaged Windows build takes the Windows branch — same answer, but it is
/// why `win32` never reaches the AppImage logic.
///
/// [appImagePath] is trimmed, and a whitespace-only value counts as absent:
/// upstream reads it from the `APPIMAGE` environment variable, which is an
/// empty string rather than unset when the app was not launched from one. The
/// *trimmed* value is what gets returned.
String resolveCliInstallSourcePath({
  required DesktopHostPlatform platform,
  required bool isPackaged,
  required String executablePath,
  required String shimPath,
  String? appImagePath,
}) {
  if (platform == DesktopHostPlatform.windows) {
    return shimPath;
  }

  if (!isPackaged) {
    return shimPath;
  }

  if (platform == DesktopHostPlatform.darwin) {
    return shimPath;
  }

  if (platform == DesktopHostPlatform.linux) {
    // Upstream `const appImagePath = input.appImagePath?.trim(); if (appImagePath)`
    // — JS truthiness, where both `undefined` and `""` fall through.
    final String? trimmedAppImagePath = appImagePath?.trim();
    if (trimmedAppImagePath != null && trimmedAppImagePath.isNotEmpty) {
      return trimmedAppImagePath;
    }
  }

  return executablePath;
}

// ---------------------------------------------------------------------------
// diagnostics/tail-file.ts
// ---------------------------------------------------------------------------

/// Thrown by a [ReadTextFileSync] port when the file does not exist.
///
/// Deviation: upstream identifies this case by duck-typing whatever was thrown
/// — `typeof e === "object" && e !== null && "code" in e && e.code === "ENOENT"`
/// — because Node throws a plain `Error` with a `code` property. Dart has no
/// equivalent structural test over an arbitrary thrown object, so the port's
/// contract is inverted: it must raise *this* exception for a missing file and
/// anything it likes for other failures. The distinction is load-bearing, see
/// [tailFile].
final class MissingFileError implements Exception {
  /// Creates a missing-file error for [path].
  const MissingFileError(this.path);

  /// The path that did not exist.
  final String path;

  /// Stable discriminator, matching the `name` convention the other error
  /// types in `lib/desktop/` use.
  String get name => 'MissingFileError';

  @override
  String toString() => '$name: $path';
}

/// Reads a whole text file, throwing on failure.
///
/// The port for Node's `readFileSync(path, "utf-8")`. Implementations must
/// throw [MissingFileError] when the file is absent and any other object for
/// other failures (a directory, a permissions error, undecodable bytes).
typedef ReadTextFileSync = String Function(String filePath);

/// Returns the last [lines] non-empty lines of a log file.
///
/// This feeds the log-tail half of a support bundle — the `contents` field of
/// `DesktopLogTail` in `core/paseo_platform_rules.dart`.
///
/// The two failure modes are deliberately different, which is the point of
/// [throwOnReadError]:
///
/// - A **missing** file is *always* empty, never an error, under either
///   setting. A log that was never written is a normal state, and a support
///   bundle that refuses to generate because one optional log is absent is
///   worse than one with a blank section.
/// - Any **other** read failure is empty by default, but rethrown when
///   [throwOnReadError] is set. Callers assembling a best-effort bundle want
///   the blank section; a caller that specifically asked for one file's tail
///   wants to know the read broke.
///
/// Blank lines are dropped (upstream's `.filter(Boolean)`), which is mostly
/// there to absorb the trailing newline every log file ends with. Note it drops
/// only *empty* lines — a whitespace-only line survives — and that splitting on
/// `\n` alone leaves a `\r` attached on CRLF files, both exactly as upstream.
///
/// Deviation (JS `slice(-n)`): [lines] is applied through
/// `Array.prototype.slice(-lines)`, which has two surprising arms that are
/// reproduced rather than corrected, since callers may rely on them:
/// `lines == 0` becomes `slice(-0)` — and `-0` is `0` — so it returns the
/// *whole* file rather than nothing; a negative [lines] becomes a positive
/// start offset and so drops that many lines from the *front*.
///
/// Deviation (scope of the guard): upstream wraps the split/filter/join inside
/// the same `try` as the read. None of those can throw, so only the read is
/// guarded here; the observable behaviour is identical.
String tailFile(
  String filePath, {
  required ReadTextFileSync readTextFile,
  int lines = 50,
  bool throwOnReadError = false,
}) {
  final String content;
  try {
    content = readTextFile(filePath);
  } catch (error) {
    if (throwOnReadError && error is! MissingFileError) {
      rethrow;
    }
    return '';
  }

  final List<String> nonEmptyLines = <String>[
    for (final String line in content.split('\n'))
      if (line.isNotEmpty) line,
  ];
  return _jsSliceFromEnd(nonEmptyLines, lines).join('\n');
}

/// Reproduces `values.slice(-lines)` including its `-0` and negative-index arms.
List<String> _jsSliceFromEnd(List<String> values, int lines) {
  final int relativeStart = -lines;
  final int start;
  if (relativeStart < 0) {
    // `slice` clamps a negative start at the front of the array.
    final int fromEnd = values.length + relativeStart;
    start = fromEnd < 0 ? 0 : fromEnd;
  } else {
    // `-0 < 0` is false in JS too, so `lines == 0` lands here with start 0.
    start = relativeStart > values.length ? values.length : relativeStart;
  }
  return values.sublist(start);
}

// ---------------------------------------------------------------------------
// features/opener.ts
// ---------------------------------------------------------------------------

/// The IPC channel the renderer calls to open a URL in the user's browser.
///
/// Frozen: it is a wire contract with the preload script, which ships
/// separately from the app bundle.
const String openerOpenUrlChannel = 'paseo:opener:openUrl';

/// The only URL schemes the opener will hand to the OS.
const Set<String> allowedExternalUrlSchemes = <String>{'http', 'https'};

/// Whether [value] may be handed to the OS's default browser.
///
/// This is a security boundary, not a convenience check. `shell.openExternal`
/// dispatches through the OS handler registry, so without an allowlist a
/// compromised or merely careless renderer could reach `file:` (exfiltrating
/// local files into whatever app claims the scheme), a custom app scheme, or
/// on some platforms a scheme that executes. Only `http` and `https` pass.
///
/// Upstream declares this as a TS type guard (`value is string`), so a `true`
/// result narrows the value at the call site. Dart has no equivalent narrowing
/// from a `bool`-returning function, so [registerOpenerHandlers] casts after
/// the check. The parameter stays `Object?` to preserve the
/// `typeof value !== "string"` arm, which upstream's suite pins with `null` and
/// which matters because the value arrives untyped off IPC.
///
/// Deviations (URL parsing): upstream calls `new URL(value)`, a WHATWG parser
/// with no Dart equivalent; `Uri.tryParse` differs in three places, and every
/// difference here rejects where upstream accepts — the safe direction for an
/// allowlist:
///
/// 1. `Uri` treats a missing authority as valid, so a `hasAuthority` and
///    non-empty-host check is added. Without it `http://` would pass here while
///    WHATWG throws on it. The same check also rejects the scheme-relative
///    special-scheme forms WHATWG silently repairs — `http:example.com` and
///    `https:/foo` both become `https://example.com/` there, and are rejected
///    here.
/// 2. Whitespace is rejected outright. WHATWG strips leading/trailing spaces
///    and removes embedded tabs and newlines before parsing, whereas `Uri`
///    percent-encodes an embedded space *into the host* — so
///    `http://exa mple.com` would otherwise pass as host `exa%20mple.com`.
///    Rejecting is both simpler and safer than replaying WHATWG's stripping.
///    (This mirrors the same guard in `isAllowedDesktopBrowserUrl`.)
/// 3. Scheme case is not a deviation: both parsers lower-case it, so
///    `HTTPS://example.com` passes in each.
bool isAllowedExternalUrl(Object? value) {
  if (value is! String) {
    return false;
  }

  if (value.contains(RegExp(r'\s'))) {
    return false;
  }

  final Uri? url = Uri.tryParse(value);
  if (url == null) {
    return false;
  }

  return allowedExternalUrlSchemes.contains(url.scheme) &&
      url.hasAuthority &&
      url.host.isNotEmpty;
}

/// Raised when the renderer asked to open a URL the allowlist rejects.
///
/// The message is frozen at upstream's `new Error("Unsupported external URL")`:
/// it crosses the IPC boundary and the renderer matches on it.
final class UnsupportedExternalUrlError implements Exception {
  /// Creates the error.
  const UnsupportedExternalUrlError();

  /// Stable discriminator, matching the `name` convention used by the error
  /// types in `paseo_desktop_daemon_rules.dart`.
  String get name => 'UnsupportedExternalUrlError';

  /// The message the renderer sees.
  String get message => 'Unsupported external URL';

  @override
  String toString() => '$name: $message';
}

/// Raised when an allowed URL was rejected by the OS.
///
/// Deviation: upstream awaits Electron's `shell.openExternal`, which resolves
/// to `void` and *rejects* when the OS refuses, letting the rejection propagate
/// out of the IPC handler. The repo's [ExternalUrlLauncher] signals that same
/// condition by resolving `false` instead, so it is translated back into a
/// thrown error and the channel's observable contract — "the invoke rejects
/// when the URL did not open" — is preserved.
final class ExternalUrlOpenFailure implements Exception {
  /// Creates a failure for [url].
  const ExternalUrlOpenFailure(this.url);

  /// The URL the OS declined to open.
  final String url;

  /// Stable discriminator.
  String get name => 'ExternalUrlOpenFailure';

  /// The message the renderer sees.
  String get message => 'Failed to open external URL';

  @override
  String toString() => '$name: $message: $url';
}

/// An IPC handler registered on a channel.
///
/// Mirrors the `(event, argument)` shape Electron's `ipcMain.handle` invokes,
/// including the leading event object the opener ignores.
typedef DesktopIpcHandler =
    Future<Object?> Function(Object? event, Object? argument);

/// The slice of the host's IPC surface this library registers against.
///
/// Deliberately *not* [DesktopHostBridge] from
/// `paseo_desktop_daemon_rules.dart`: that models the renderer invoking a host
/// command, this models the host receiving one. Opposite directions of the same
/// channel, so a shared type would fit neither.
abstract interface class DesktopIpcRegistrar {
  /// Upstream `ipcMain.handle(channel, handler)`.
  void handle(String channel, DesktopIpcHandler handler);
}

/// Registers the opener's IPC handlers on [registrar].
///
/// The allowlist runs *before* [launcher] is touched, so a rejected URL never
/// reaches the OS — the ordering, not just the outcome, is the security
/// property worth pinning.
void registerOpenerHandlers({
  required DesktopIpcRegistrar registrar,
  required ExternalUrlLauncher launcher,
}) {
  registrar.handle(openerOpenUrlChannel, (Object? event, Object? url) async {
    if (!isAllowedExternalUrl(url)) {
      throw const UnsupportedExternalUrlError();
    }

    // Safe by construction: `isAllowedExternalUrl` returned true, which upstream
    // expresses as a type guard. See its doc for why the cast is needed here.
    final String allowedUrl = url! as String;
    if (!await launcher.open(allowedUrl)) {
      throw ExternalUrlOpenFailure(allowedUrl);
    }
    return null;
  });
}
