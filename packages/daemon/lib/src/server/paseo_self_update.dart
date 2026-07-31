/// Frozen Paseo 0.2.0 daemon self-update + hub execution cluster, ported to
/// Dart.
///
/// Upstream modules covered by this library
/// (`paseo/packages/server/src/server/`):
///
/// | Upstream                                        | Section here                        |
/// | ----------------------------------------------- | ----------------------------------- |
/// | `session/daemon/npm-global-cli.ts`               | [GlobalCliDistribution] and friends |
/// | `session/daemon/install-origin.ts`               | [validateDaemonInstallOrigin]       |
/// | `session/daemon/daemon-self-updater.ts`          | [DaemonSelfUpdater]                 |
/// | `session/daemon/daemon-self-update-session-controller.ts` | [DaemonSelfUpdateSessionController] |
/// | `hub/execution-controller.ts`                    | [HubExecutionController]            |
///
/// `install-origin.ts` is not in the nominal cluster, but `daemon-self-updater`
/// imports it and the upstream self-updater suite pins its four rejection
/// messages, so it is ported here rather than stubbed.
///
/// ## Branding
///
/// Upstream's self-update is "re-run the package manager that installed my
/// CLI". The literal names are Paseo's and are **not** copied. Mapping:
///
/// | Paseo                              | Tinyrack                                    |
/// | ---------------------------------- | ------------------------------------------- |
/// | `@getpaseo/cli` (npm package)      | `agent_daemon` (pub package, [daemonPackageName]) |
/// | `paseo` (executable on PATH)       | `coding-agent` ([tinyrackCliExecutable])    |
/// | `@getpaseo/server` (daemon package)| `agent_daemon` — the same package here      |
/// | `npm -g ls … --json`               | `dart pub global list`                      |
/// | `npm install -g …@latest`          | `dart pub global activate agent_daemon`     |
/// | npm global root `<root>/node_modules` | the pub cache root (`PUB_CACHE`)         |
/// | `link: true` (an `npm link`)       | a `dart pub global activate --source path` activation |
/// | "managed by Paseo Desktop"         | "managed by the Tinyrack desktop app"       |
///
/// npm global installs map onto **pub global activations** because that is the
/// Dart ecosystem's global-CLI mechanism, and because the two share the one
/// distinction the port actually depends on: a *developer* activation (npm
/// `link` / pub `--source path`) must never be overwritten by a self-update,
/// while a registry activation may.
///
/// Caveat, stated plainly: this repo publishes to **no** registry today
/// (`publish_to: none` everywhere) and ships the daemon as a compiled binary
/// through GitHub Releases, so [PubGlobalTinyrackCli] is the behavioral
/// analogue rather than a live install path. That follows the precedent set by
/// `packages/app/lib/desktop/paseo_desktop_daemon_launch.dart`, which ports
/// upstream's supervisor path resolution and documents that it is not wired.
/// The real port surface is [GlobalCliDistribution]: swapping in a
/// releases-backed implementation later changes nothing above it.
///
/// ## Relationship to the code that already exists
///
/// * `packages/daemon_lifecycle` owns daemon *supervision* — `DaemonSupervisor`
///   (`ensureRunning`/`stop`/`restart`), `spawnDaemonDetached`, `PidLock`. This
///   library never restarts anything; it emits a
///   [DaemonSelfUpdateRestartIntent] and lets the session layer decide, exactly
///   as upstream does. The intent is the seam between the two.
/// * `packages/app/lib/desktop/paseo_desktop_services.dart` ports the *desktop
///   app* updater (release channels, check/install over host IPC). That updates
///   the Flutter app; this updates the daemon's own install. The only contact
///   point is [desktopManagedSelfUpdateError]: a desktop-managed daemon refuses
///   to self-update and defers to that updater.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart'
    show
        CreateAgentWorktreeTarget,
        DaemonUpdatePhase,
        DaemonUpdateProgress,
        DaemonUpdateRequest,
        DaemonUpdateResponse;
import 'package:path/path.dart' as p;

import '../cli/cli_errors.dart' show getErrorMessage;
import '../paseo_server_env.dart' show daemonPackageName;
import '../utils/paseo_process_utils.dart'
    show
        ExecCommandException,
        ExecCommandOptions,
        ProcessHost,
        SystemProcessHost,
        execCommand;

// ---------------------------------------------------------------------------
// Branding constants
// ---------------------------------------------------------------------------

/// Package identity of the CLI this daemon ships as.
///
/// Aliases [daemonPackageName] rather than re-declaring the literal, so the
/// self-updater and `resolveDaemonVersion` can never disagree about which
/// package the running daemon claims to be.
const String tinyrackCliPackage = daemonPackageName;

/// Executable name the CLI installs onto `PATH`.
///
/// Declared in `packages/daemon/pubspec.yaml` under `executables:`. Kept here
/// so a future releases-backed [GlobalCliDistribution] has one place to look.
const String tinyrackCliExecutable = 'coding-agent';

/// Server-info feature flag the client uses to decide whether to offer the
/// "update daemon" affordance.
///
/// `packages/app/lib/widgets/host_daemon_update_card.dart` hides the card when
/// this flag is absent, so wiring [DaemonSelfUpdateSessionController] into the
/// websocket server means advertising this flag in the same change.
const String daemonSelfUpdateFeatureFlag = 'daemonSelfUpdate';

/// Refusal returned to a client that asks a desktop-managed daemon to update
/// itself.
///
/// A desktop-managed daemon was spawned by the Flutter app
/// (`daemon_lifecycle`'s `spawnDaemonDetached` sets `TINYRACK_DESKTOP_MANAGED`)
/// and will be replaced wholesale the next time the app starts, so updating the
/// global install underneath it would be undone and could desynchronise the two
/// versions.
const String desktopManagedSelfUpdateError =
    'This daemon is managed by the Tinyrack desktop app. '
    'Update the desktop app on the host.';

// ---------------------------------------------------------------------------
// npm-global-cli.ts
// ---------------------------------------------------------------------------

/// How long the install probe may run before it is killed.
const Duration globalCliProbeTimeout = Duration(seconds: 10);

/// How long the install command may run before it is killed.
const Duration globalCliInstallTimeout = Duration(minutes: 5);

/// Per-stream output cap for both commands, matching upstream's 10 MiB.
const int globalCliMaxBufferBytes = 10 * 1024 * 1024;

/// Captured outcome of one package-manager command.
///
/// Deviation: this is deliberately *not*
/// `paseo_process_utils.dart`'s `ExecCommandResult`. Upstream's helper never
/// throws — a non-zero exit is data, because [DaemonSelfUpdater] has to read the
/// installer's own stderr to build its error message. `execCommand` throws on
/// non-zero exit, so [createProcessGlobalCliCommandRunner] converts that back
/// into a value.
final class GlobalCliCommandResult {
  const GlobalCliCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// Process exit code; `0` on success.
  final int exitCode;

  /// Decoded standard output.
  final String stdout;

  /// Decoded standard error.
  final String stderr;

  @override
  bool operator ==(Object other) =>
      other is GlobalCliCommandResult &&
      other.exitCode == exitCode &&
      other.stdout == stdout &&
      other.stderr == stderr;

  @override
  int get hashCode => Object.hash(exitCode, stdout, stderr);

  @override
  String toString() =>
      'GlobalCliCommandResult(exitCode: $exitCode, stdout: $stdout, '
      'stderr: $stderr)';
}

/// Runs one package-manager command and reports its outcome as data.
///
/// Injected so tests never spawn a process, install anything, or touch the
/// network — the same seam upstream's `CommandRunner` provides.
typedef GlobalCliCommandRunner =
    Future<GlobalCliCommandResult> Function(
      String command,
      List<String> arguments, {
      Duration? timeout,
      int? maxBuffer,
    });

/// Converts a failed `execCommand` into a [GlobalCliCommandResult].
///
/// Reproduces upstream's `CommandErrorSchema` fallbacks exactly:
/// * a non-numeric/absent exit code becomes `1`;
/// * absent stdout becomes `''`;
/// * a **blank** stderr falls back to the error's own message, because
///   upstream's `parsed.data.stderr || getErrorMessage(error)` treats the empty
///   string as falsy. Dart has no truthiness, so the check is explicit.
GlobalCliCommandResult globalCliResultFromFailure(Object error) {
  if (error is ExecCommandException) {
    return GlobalCliCommandResult(
      exitCode: error.exitCode ?? 1,
      stdout: error.stdout,
      stderr: error.stderr.isNotEmpty ? error.stderr : getErrorMessage(error),
    );
  }
  // Upstream's schema parse fails for anything that is not an exec rejection,
  // and it reports exit code 1 with empty output.
  return GlobalCliCommandResult(
    exitCode: 1,
    stdout: '',
    stderr: getErrorMessage(error),
  );
}

/// Builds the production [GlobalCliCommandRunner] on top of the daemon's shared
/// [execCommand].
///
/// Reuse note: process launching, environment scrubbing, timeout handling and
/// output capping all live in `utils/paseo_process_utils.dart`; this only
/// adapts the throw-on-failure contract to upstream's value contract.
GlobalCliCommandRunner createProcessGlobalCliCommandRunner({
  ProcessHost host = const SystemProcessHost(),
}) {
  return (
    String command,
    List<String> arguments, {
    Duration? timeout,
    int? maxBuffer,
  }) async {
    try {
      final result = await execCommand(
        command,
        arguments,
        options: ExecCommandOptions(
          timeout: timeout,
          maxBuffer: maxBuffer ?? globalCliMaxBufferBytes,
        ),
        host: host,
      );
      return GlobalCliCommandResult(
        exitCode: 0,
        stdout: result.stdout,
        stderr: result.stderr,
      );
    } on Object catch (error) {
      return globalCliResultFromFailure(error);
    }
  };
}

/// What the package manager reports about the globally installed CLI.
///
/// Repo style: an upstream `interface` becomes a `final class` with named
/// parameters and value equality.
final class GlobalCliInstall {
  const GlobalCliInstall({
    required this.version,
    required this.packagePath,
    required this.globalRootPath,
    required this.isLinked,
  });

  /// Version the package manager currently has activated.
  final String version;

  /// Directory the activated package's sources live in.
  ///
  /// Deviation: upstream's npm equivalent is always present, because `npm ls
  /// --long` prints a `path` for every dependency. `dart pub global list` prints
  /// a path only for `--source path` activations, so for a registry activation
  /// this is *derived* from the pub cache and is `null` when the cache root
  /// cannot be resolved. [validateDaemonInstallOrigin] treats a `null` here as
  /// "one fewer root to match", never as an error.
  final String? packagePath;

  /// Root of the global install tree, or `null` when it cannot be resolved.
  final String? globalRootPath;

  /// Whether this is a developer activation that self-update must refuse.
  final bool isLinked;

  @override
  bool operator ==(Object other) =>
      other is GlobalCliInstall &&
      other.version == version &&
      other.packagePath == packagePath &&
      other.globalRootPath == globalRootPath &&
      other.isLinked == isLinked;

  @override
  int get hashCode =>
      Object.hash(version, packagePath, globalRootPath, isLinked);

  @override
  String toString() =>
      'GlobalCliInstall(version: $version, packagePath: $packagePath, '
      'globalRootPath: $globalRootPath, isLinked: $isLinked)';
}

/// Raised when the global install cannot be inspected.
///
/// Deviation: upstream throws bare `Error`s and its tests only assert on the
/// message. A named type is used here so callers can tell an inspection failure
/// apart from an arbitrary bug, while [getErrorMessage] still yields the same
/// string upstream produced.
final class GlobalCliInspectionException implements Exception {
  const GlobalCliInspectionException(this.message);

  /// Human-readable explanation, surfaced verbatim to the client.
  final String message;

  @override
  String toString() => message;
}

/// The package manager that installed this daemon's CLI.
///
/// Everything above this interface — origin validation, phase reporting,
/// concurrency fencing, the session protocol — is package-manager agnostic, so
/// replacing the implementation is the whole extension point.
abstract interface class GlobalCliDistribution {
  /// Reads the currently activated global install.
  ///
  /// Throws [GlobalCliInspectionException] when the toolchain is missing or the
  /// CLI is not globally installed.
  Future<GlobalCliInstall> inspect();

  /// Installs (or re-installs) the newest available CLI.
  ///
  /// Never throws for a non-zero exit: the caller needs the installer's own
  /// output to report *why* it failed.
  Future<GlobalCliCommandResult> installLatest();
}

/// Resolves the pub cache root the way the Dart SDK does.
///
/// `PUB_CACHE` wins; otherwise `%LOCALAPPDATA%\Pub\Cache` on Windows and
/// `$HOME/.pub-cache` elsewhere. Returns `null` rather than guessing when
/// neither anchor is set, because a wrong root would silently widen the
/// containment check in [validateDaemonInstallOrigin].
String? resolvePubCacheRoot({
  Map<String, String>? environment,
  bool? isWindows,
}) {
  final env = environment ?? Platform.environment;
  final explicit = env['PUB_CACHE'];
  if (explicit != null && explicit.trim().isNotEmpty) return explicit;

  if (isWindows ?? Platform.isWindows) {
    final localAppData = env['LOCALAPPDATA'];
    if (localAppData != null && localAppData.trim().isNotEmpty) {
      return p.join(localAppData, 'Pub', 'Cache');
    }
    return null;
  }

  final home = env['HOME'];
  if (home != null && home.trim().isNotEmpty) {
    return p.join(home, '.pub-cache');
  }
  return null;
}

final RegExp _pubGlobalListLinePattern = RegExp(r'^(\S+)\s+(\S+)(?:\s+(.*))?$');
final RegExp _pubGlobalListPathSuffixPattern = RegExp(r'^at path\s+"(.*)"$');

/// Parses `dart pub global list` output into a [GlobalCliInstall].
///
/// Returns `null` when [packageName] is not among the activated packages —
/// upstream's "the CLI is not a dependency of the global root" case.
///
/// Deviation: upstream parses `npm ls --json` with two zod schemas. `dart pub
/// global list` has no JSON mode, so this is a line parser. It reproduces the
/// same three observations the schemas extracted: the version, the package
/// directory, and whether the activation is a developer link. Unparseable lines
/// are skipped rather than failing the whole read, which is how the upstream
/// `passthrough()` schemas tolerate unknown npm output.
GlobalCliInstall? parsePubGlobalCliInstall(
  String stdout, {
  required String packageName,
  String? pubCacheRoot,
}) {
  for (final line in const LineSplitter().convert(stdout)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;

    final match = _pubGlobalListLinePattern.firstMatch(trimmed);
    if (match == null) continue;
    if (match.group(1) != packageName) continue;

    final version = match.group(2)!;
    final suffix = match.group(3)?.trim();
    final pathMatch = suffix == null || suffix.isEmpty
        ? null
        : _pubGlobalListPathSuffixPattern.firstMatch(suffix);
    final activatedPath = pathMatch?.group(1);

    return GlobalCliInstall(
      version: version,
      packagePath:
          activatedPath ??
          (pubCacheRoot == null
              ? null
              : p.join(
                  pubCacheRoot,
                  'hosted',
                  'pub.dev',
                  '$packageName-$version',
                )),
      globalRootPath: pubCacheRoot,
      // A `--source path` activation is the pub analogue of `npm link`: it
      // points at a working tree, so reinstalling would clobber a developer's
      // checkout instead of upgrading anything.
      isLinked: activatedPath != null,
    );
  }
  return null;
}

/// [GlobalCliDistribution] backed by `dart pub global`.
///
/// The argv, timeouts and output caps mirror upstream's npm invocations
/// one-for-one so the failure modes (probe timeout, install timeout, runaway
/// output) stay identical.
final class PubGlobalTinyrackCli implements GlobalCliDistribution {
  PubGlobalTinyrackCli({
    GlobalCliCommandRunner? runCommand,
    this.packageName = tinyrackCliPackage,
    this.toolchainExecutable = 'dart',
    Map<String, String>? environment,
    bool? isWindows,
  }) : _runCommand = runCommand ?? createProcessGlobalCliCommandRunner(),
       _environment = environment,
       _isWindows = isWindows;

  final GlobalCliCommandRunner _runCommand;
  final Map<String, String>? _environment;
  final bool? _isWindows;

  /// Package identity to look for in the activation list.
  final String packageName;

  /// Toolchain driver used to run `pub global …`.
  final String toolchainExecutable;

  @override
  Future<GlobalCliInstall> inspect() async {
    final result = await _runCommand(
      toolchainExecutable,
      const ['pub', 'global', 'list'],
      timeout: globalCliProbeTimeout,
      maxBuffer: globalCliMaxBufferBytes,
    );

    // A non-zero exit with usable output is still usable output: upstream
    // deliberately only treats "failed *and* said nothing" as a missing
    // toolchain, because npm exits non-zero merely for reporting a missing
    // dependency.
    if (result.exitCode != 0 && result.stdout.trim().isEmpty) {
      final stderr = result.stderr.trim();
      throw GlobalCliInspectionException(
        stderr.isNotEmpty
            ? stderr
            : '$toolchainExecutable is not available on this host',
      );
    }

    final install = parsePubGlobalCliInstall(
      result.stdout,
      packageName: packageName,
      pubCacheRoot: resolvePubCacheRoot(
        environment: _environment,
        isWindows: _isWindows,
      ),
    );
    if (install == null) {
      throw GlobalCliInspectionException(
        '$packageName is not installed with '
        '$toolchainExecutable pub global on this host',
      );
    }
    return install;
  }

  @override
  Future<GlobalCliCommandResult> installLatest() => _runCommand(
    toolchainExecutable,
    ['pub', 'global', 'activate', packageName],
    timeout: globalCliInstallTimeout,
    maxBuffer: globalCliMaxBufferBytes,
  );
}

// ---------------------------------------------------------------------------
// install-origin.ts
// ---------------------------------------------------------------------------

/// Locates the package root the *running* daemon was loaded from.
///
/// Self-update is only safe when the process about to be replaced is the one
/// the package manager controls; this is how that is established.
abstract interface class DaemonInstallOriginProbe {
  /// Absolute package root, or `null` when it cannot be determined.
  String? resolveCurrentDaemonPackageRoot();
}

/// [DaemonInstallOriginProbe] that walks the filesystem upward looking for the
/// daemon's own `pubspec.yaml`.
///
/// Deviations from upstream `resolveCurrentServerPackageRoot`:
/// * `package.json` with `"name": "@getpaseo/server"` becomes `pubspec.yaml`
///   with `name: agent_daemon`.
/// * Node seeds the walk from `import.meta.url`, the compiled module's own
///   location. Dart libraries have no runtime self-location, so the walk is
///   seeded from the running executable's directory — which for the shipped
///   daemon *is* inside the install — and is overridable for tests.
/// * A malformed pubspec aborts the walk with `null`, matching upstream's
///   `catch { return null; }` rather than continuing upward.
final class FilesystemDaemonInstallOriginProbe
    implements DaemonInstallOriginProbe {
  const FilesystemDaemonInstallOriginProbe({
    this.packageName = tinyrackCliPackage,
    this.startDirectory,
  });

  /// Pubspec `name:` that identifies the daemon package.
  final String packageName;

  /// Where the upward walk begins. Defaults to the running executable's
  /// directory.
  final String? startDirectory;

  @override
  String? resolveCurrentDaemonPackageRoot() {
    var currentDir = p.normalize(
      p.absolute(startDirectory ?? p.dirname(Platform.resolvedExecutable)),
    );

    while (true) {
      final pubspecPath = p.join(currentDir, 'pubspec.yaml');
      final file = File(pubspecPath);
      bool exists;
      try {
        exists = file.existsSync();
      } on Object {
        return null;
      }
      if (exists) {
        final String source;
        try {
          source = file.readAsStringSync();
        } on Object {
          return null;
        }
        if (_readTopLevelPubspecName(source) == packageName) return currentDir;
      }

      final parentDir = p.dirname(currentDir);
      if (parentDir == currentDir) return null;
      currentDir = parentDir;
    }
  }
}

/// Reads a pubspec's top-level `name:` without pulling in a YAML parser.
///
/// Only unindented, non-comment lines count, so a nested `name:` under
/// `dependencies:` can never be mistaken for the package's own. This mirrors
/// the reader `paseo_server_env.dart` uses for `resolvePackageVersion`, which is
/// library-private there and so cannot be shared.
String? _readTopLevelPubspecName(String source) {
  for (final line in const LineSplitter().convert(source)) {
    if (line.isEmpty) continue;
    if (line.startsWith(' ') || line.startsWith('\t') || line.startsWith('#')) {
      continue;
    }
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    if (line.substring(0, colon).trim() != 'name') continue;

    var value = line.substring(colon + 1).trim();
    final comment = value.indexOf(' #');
    if (comment >= 0) value = value.substring(0, comment).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    return value;
  }
  return null;
}

/// Returns why [install] must not be self-updated, or `null` when it may be.
///
/// The four refusals, in upstream's order:
/// 1. developer (path) activations, which a reinstall would clobber;
/// 2. a version disagreement between the daemon and the global install, which
///    proves the daemon is running from somewhere else;
/// 3. an unlocatable daemon package root, which means we cannot prove anything;
/// 4. a daemon package root outside the global install tree.
///
/// Deviation: upstream guards the version check with `if (daemonVersion && …)`,
/// so an **empty string** skips it just like `null` does. Dart has no
/// truthiness, so the blank case is spelled out.
String? validateDaemonInstallOrigin({
  required GlobalCliInstall install,
  required String? daemonVersion,
  required DaemonInstallOriginProbe probe,
}) {
  if (install.isLinked) {
    return 'The global $tinyrackCliPackage install is a path activation; '
        'self-update only supports normal global installs.';
  }

  if (daemonVersion != null &&
      daemonVersion.isNotEmpty &&
      install.version != daemonVersion) {
    return 'This daemon is not running from the global $tinyrackCliPackage '
        'install (the global install has ${install.version}, '
        'daemon is $daemonVersion).';
  }

  final currentRoot = probe.resolveCurrentDaemonPackageRoot();
  if (currentRoot == null) {
    return 'Unable to verify that this daemon is running from a global install.';
  }

  if (!_isCurrentDaemonUnderGlobalInstall(currentRoot, install)) {
    return 'This daemon is not running from the global $tinyrackCliPackage '
        'install.';
  }

  return null;
}

bool _isCurrentDaemonUnderGlobalInstall(
  String currentDaemonPackageRoot,
  GlobalCliInstall install,
) {
  // Deviation: upstream's second root is `<npmGlobalRoot>/node_modules`,
  // because npm nests every global package under that directory. Pub's cache
  // root already *is* the container for both `hosted/` and `global_packages/`,
  // so it is used unmodified. Either root matching is enough, exactly as
  // upstream's `roots.some(...)`.
  final roots = <String>[
    if (install.packagePath != null) install.packagePath!,
    if (install.globalRootPath != null) install.globalRootPath!,
  ];
  return roots.any(
    (root) => isRealpathInsideRoot(root, currentDaemonPackageRoot),
  );
}

/// Whether [candidate] is [root] or lives under it, comparing symlink-resolved
/// variants as well as the literal strings.
///
/// Port of upstream `utils/path.ts`'s `isRealpathInsideRoot`. This repo has no
/// shared equivalent — the existing containment helpers
/// (`server/directory_suggestions.dart`, `server/web_ui.dart`,
/// `server/public_static.dart`) are all library-private and none of them
/// resolves symlinks, which is the whole point here: a pub cache reached
/// through a symlinked `HOME` must still compare equal.
bool isRealpathInsideRoot(String root, String candidate) {
  for (final resolvedRoot in _pathVariants(root)) {
    for (final resolvedCandidate in _pathVariants(candidate)) {
      if (_isPathInsideRoot(resolvedRoot, resolvedCandidate)) return true;
    }
  }
  return false;
}

/// The literal path plus its symlink-resolved form, when the path exists.
///
/// Deviation: Node tries both `realpathSync.native` and `realpathSync`. Dart
/// exposes one resolver, reached through whichever entity type the path happens
/// to be, so both are attempted and failures are ignored — a non-existent path
/// simply contributes no extra variant, which is upstream's fallback too.
List<String> _pathVariants(String value) {
  final variants = <String>{value};
  try {
    variants.add(Directory(value).resolveSymbolicLinksSync());
  } on Object {
    // Not a directory, or does not exist.
  }
  try {
    variants.add(File(value).resolveSymbolicLinksSync());
  } on Object {
    // Not a file, or does not exist.
  }
  return variants.toList(growable: false);
}

bool _isPathInsideRoot(String root, String candidate) {
  final compareAsWindows =
      _looksLikeDefiniteWindowsPath(root) ||
      _looksLikeDefiniteWindowsPath(candidate);
  final context = compareAsWindows ? p.windows : p.posix;
  final normalizedRoot = _normalizePathForComparison(
    root,
    context,
    compareAsWindows,
  );
  final normalizedCandidate = _normalizePathForComparison(
    candidate,
    context,
    compareAsWindows,
  );

  final String relative;
  try {
    relative = context.relative(normalizedCandidate, from: normalizedRoot);
  } on Object {
    // `relative` throws when one path is absolute and the other is not; upstream
    // simply produces a `..`-prefixed result there, which is also a rejection.
    return false;
  }

  // Deviation: Node's `path.relative` returns `''` for identical paths while
  // Dart's returns `'.'`. Both mean "the candidate is the root".
  return relative.isEmpty ||
      relative == '.' ||
      (!relative.startsWith('..') && !context.isAbsolute(relative));
}

final RegExp _windowsDrivePattern = RegExp(r'^[a-zA-Z]:[\\/]');
final RegExp _windowsNamespacePattern = RegExp(r'^[/\\]{2}\?[/\\]');
final RegExp _windowsUncPattern = RegExp(r'^\\{2}[^/\\]+[/\\][^/\\]+');
final RegExp _windowsNamespaceDrivePattern = RegExp(
  r'^[/\\]{2}\?[/\\]([a-zA-Z]:)[/\\](.*)$',
);
final RegExp _windowsNamespaceUncPattern = RegExp(
  r'^[/\\]{2}\?[/\\]UNC[/\\]([^/\\]+)[/\\]([^/\\]+)(?:[/\\](.*))?$',
  caseSensitive: false,
);

bool _looksLikeDefiniteWindowsPath(String value) =>
    _windowsDrivePattern.hasMatch(value) ||
    _windowsNamespacePattern.hasMatch(value) ||
    _windowsUncPattern.hasMatch(value);

String _normalizePathForComparison(
  String value,
  p.Context context,
  bool compareAsWindows,
) {
  final comparable = compareAsWindows
      ? _stripWindowsNamespacePrefix(value)
      : value;
  final normalized = _stripTrailingSeparators(
    context.normalize(comparable),
    context,
    compareAsWindows,
  );
  // Windows paths are case-insensitive; POSIX paths are not.
  return compareAsWindows ? normalized.toLowerCase() : normalized;
}

String _stripWindowsNamespacePrefix(String value) {
  final drive = _windowsNamespaceDrivePattern.firstMatch(value);
  if (drive != null) {
    return '${drive.group(1)}\\${drive.group(2) ?? ''}';
  }

  final unc = _windowsNamespaceUncPattern.firstMatch(value);
  if (unc != null) {
    final rest = unc.group(3);
    return '\\\\${unc.group(1)}\\${unc.group(2)}'
        '${rest != null ? '\\$rest' : ''}';
  }

  return value;
}

String _stripTrailingSeparators(
  String value,
  p.Context context,
  bool compareAsWindows,
) {
  final root = context.rootPrefix(value);
  var result = value;
  while (result.length > root.length &&
      (result.endsWith('/') || (compareAsWindows && result.endsWith('\\')))) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

// ---------------------------------------------------------------------------
// daemon-self-updater.ts
// ---------------------------------------------------------------------------

/// Receives each self-update phase as it starts.
///
/// Reuses the protocol package's [DaemonUpdatePhase] rather than re-declaring
/// upstream's `"starting" | "downloading" | "installing" | "complete"` union,
/// so the daemon can never emit a phase the client cannot decode.
typedef DaemonSelfUpdateProgressCallback =
    void Function(DaemonUpdatePhase phase);

/// Structured logging sink for the self-updater.
///
/// Ported as its own narrow interface because upstream declares one too: the
/// updater needs exactly `error` and `warn`, and this repo has no general daemon
/// logger (server code logs through a severity-less
/// `void Function(String)` callback). Keeping the interface narrow means the
/// eventual wiring can adapt whatever logger exists then.
abstract interface class DaemonSelfUpdateLogger {
  /// Records a failure, with structured [context] and an optional summary.
  void error(Map<String, Object?> context, [String? message]);

  /// Records a recoverable anomaly.
  void warn(Map<String, Object?> context, [String? message]);
}

/// Outcome of one self-update attempt.
final class DaemonSelfUpdateResult {
  const DaemonSelfUpdateResult({
    required this.success,
    required this.error,
    required this.newVersion,
  });

  /// Whether the install completed.
  final bool success;

  /// Why it did not, or `null` on success.
  final String? error;

  /// Version observed after installing, or `null` when unknown or unchanged.
  final String? newVersion;

  @override
  bool operator ==(Object other) =>
      other is DaemonSelfUpdateResult &&
      other.success == success &&
      other.error == error &&
      other.newVersion == newVersion;

  @override
  int get hashCode => Object.hash(success, error, newVersion);

  @override
  String toString() =>
      'DaemonSelfUpdateResult(success: $success, error: $error, '
      'newVersion: $newVersion)';
}

/// Everything one self-update attempt needs from its caller.
final class DaemonSelfUpdateInput {
  const DaemonSelfUpdateInput({
    required this.daemonVersion,
    required this.desktopManaged,
    required this.onProgress,
    required this.logger,
  });

  /// Version this daemon believes it is, or `null` when unknown.
  final String? daemonVersion;

  /// Whether the desktop app owns this daemon's lifecycle.
  final bool desktopManaged;

  /// Phase callback, invoked synchronously as each phase begins.
  final DaemonSelfUpdateProgressCallback onProgress;

  /// Where failures are recorded.
  final DaemonSelfUpdateLogger logger;
}

/// Collaborators [DaemonSelfUpdater] needs, bundled so tests replace both at
/// once.
final class DaemonSelfUpdateRuntime {
  const DaemonSelfUpdateRuntime({
    required this.cli,
    required this.installOrigin,
  });

  /// The package manager driving the install.
  final GlobalCliDistribution cli;

  /// How the running daemon's own package root is located.
  final DaemonInstallOriginProbe installOrigin;
}

/// Thrown when a second update is requested while one is running.
///
/// This is the one failure the updater *throws* rather than returning, because
/// it is a caller error rather than an update outcome: the session controller
/// maps it onto an `rpc_error` instead of a `daemon.update.response`.
final class DaemonSelfUpdateInProgressException implements Exception {
  const DaemonSelfUpdateInProgressException();

  /// Message surfaced to the client, matching upstream verbatim.
  String get message => 'An update is already in progress';

  @override
  String toString() => message;
}

/// The narrow slice of [DaemonSelfUpdater] the session controller depends on.
///
/// Repo style equivalent of upstream's `Pick<DaemonSelfUpdater, "update">`.
abstract interface class DaemonSelfUpdatePerformer {
  /// Runs one self-update attempt.
  Future<DaemonSelfUpdateResult> update(DaemonSelfUpdateInput input);
}

/// Replaces this daemon's global install with the newest published one.
///
/// The sequence is: refuse desktop-managed hosts, fence concurrent attempts,
/// probe the install, prove the running daemon came from it, install, then
/// re-probe to report the new version. Every refusal before the install is a
/// returned [DaemonSelfUpdateResult], not a throw, so the client always gets a
/// `daemon.update.response` explaining itself.
class DaemonSelfUpdater implements DaemonSelfUpdatePerformer {
  DaemonSelfUpdater(this.runtime);

  /// Injected collaborators.
  final DaemonSelfUpdateRuntime runtime;

  bool _inProgress = false;

  /// Whether an attempt is currently running.
  bool get isInProgress => _inProgress;

  @override
  Future<DaemonSelfUpdateResult> update(DaemonSelfUpdateInput input) async {
    if (input.desktopManaged) {
      return const DaemonSelfUpdateResult(
        success: false,
        error: desktopManagedSelfUpdateError,
        newVersion: null,
      );
    }

    // Both the check and the latch run before the first `await`, so a second
    // synchronous call cannot slip past — the same guarantee upstream gets from
    // JavaScript's run-to-completion semantics.
    if (_inProgress) throw const DaemonSelfUpdateInProgressException();
    _inProgress = true;

    try {
      input.onProgress(DaemonUpdatePhase.starting);
      final install = await runtime.cli.inspect();
      final unsupportedReason = validateDaemonInstallOrigin(
        install: install,
        daemonVersion: input.daemonVersion,
        probe: runtime.installOrigin,
      );
      if (unsupportedReason != null) {
        return DaemonSelfUpdateResult(
          success: false,
          error: unsupportedReason,
          newVersion: null,
        );
      }

      // Upstream emits both phases back to back: the package manager does not
      // report download and install separately, so the client's progress bar is
      // driven by the transition rather than by real timing.
      input.onProgress(DaemonUpdatePhase.downloading);
      input.onProgress(DaemonUpdatePhase.installing);

      final result = await runtime.cli.installLatest();
      if (result.exitCode != 0) {
        // Upstream's `stderr.trim() || stdout.trim() || <fallback>` chain:
        // blank strings fall through, so the client never sees an empty error.
        final stderr = result.stderr.trim();
        final stdout = result.stdout.trim();
        final error = stderr.isNotEmpty
            ? stderr
            : stdout.isNotEmpty
            ? stdout
            : 'The global install command exited with code ${result.exitCode}';
        input.logger.error({
          'exitCode': result.exitCode,
          'stderr': result.stderr,
        }, 'Daemon self-update failed');
        return DaemonSelfUpdateResult(
          success: false,
          error: error,
          newVersion: null,
        );
      }

      // The install already succeeded, so failing to read the new version is
      // only a reporting gap — it must not turn a good update into a failure.
      GlobalCliInstall? updatedInstall;
      try {
        updatedInstall = await runtime.cli.inspect();
      } on Object catch (error) {
        input.logger.warn({
          'err': error,
        }, 'Unable to read updated global install version');
        updatedInstall = null;
      }

      input.onProgress(DaemonUpdatePhase.complete);
      return DaemonSelfUpdateResult(
        success: true,
        error: null,
        newVersion: updatedInstall?.version,
      );
    } on Object catch (error) {
      input.logger.error({
        'err': error,
      }, 'Daemon self-update failed with exception');
      return DaemonSelfUpdateResult(
        success: false,
        error: getErrorMessage(error),
        newVersion: null,
      );
    } finally {
      _inProgress = false;
    }
  }
}

// ---------------------------------------------------------------------------
// daemon-self-update-session-controller.ts
// ---------------------------------------------------------------------------

/// Emits one outbound session message.
typedef DaemonSessionEmit = void Function(Map<String, Object?> message);

/// Asks the session layer to restart this daemon after a successful update.
///
/// Deliberately a value, not an action: `packages/daemon_lifecycle` already owns
/// restart (`DaemonSupervisor.restart`, `spawnDaemonDetached`, `stopDaemon`) and
/// only the session layer knows whether the connection may trigger it — the
/// daemon's existing `restart_server_request` path, for instance, requires a
/// loopback connection. Emitting an intent keeps that policy where it belongs.
final class DaemonSelfUpdateRestartIntent {
  const DaemonSelfUpdateRestartIntent({
    required this.clientId,
    required this.requestId,
    required this.reason,
  });

  /// Discriminator, retained from upstream's `{ type: "restart" }`.
  static const String type = 'restart';

  /// Connection that requested the update.
  final String clientId;

  /// Correlates the restart with the originating request.
  final String requestId;

  /// Why the restart is being requested.
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is DaemonSelfUpdateRestartIntent &&
      other.clientId == clientId &&
      other.requestId == requestId &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(clientId, requestId, reason);

  @override
  String toString() =>
      'DaemonSelfUpdateRestartIntent(clientId: $clientId, '
      'requestId: $requestId, reason: $reason)';
}

/// Reason carried by the restart intent a completed self-update emits.
const String daemonSelfUpdateRestartReason = 'daemon_update';

/// `rpc_error` code returned when an update is already running.
///
/// Not a member of the protocol's `RpcErrorCodes`: that set is the shared
/// envelope vocabulary, while this — like `handler_error` and
/// `agent_resume_failed` elsewhere in the daemon — is a per-request code the
/// client matches on directly.
const String daemonSelfUpdateAlreadyUpdatingCode = 'already_updating';

/// Inbound message types this controller owns.
///
/// A single-element set, kept as a set because upstream's is one and because
/// adding a second self-update request type should not require touching
/// [DaemonSelfUpdateSessionController.dispatch].
const Set<String> daemonSelfUpdateMessageTypes = <String>{
  DaemonUpdateRequest.type,
};

/// Whether [message] belongs to the self-update subsystem.
bool isDaemonSelfUpdateMessage(Map<String, Object?> message) =>
    daemonSelfUpdateMessageTypes.contains(message['type']);

/// Bridges `daemon.update.request` onto [DaemonSelfUpdater].
///
/// Translates one update attempt into the three things a client observes: a
/// `daemon.update.progress` per phase, exactly one terminal message
/// (`daemon.update.response` or `rpc_error`), and — only on success — a restart
/// intent handed back to the session layer.
final class DaemonSelfUpdateSessionController {
  DaemonSelfUpdateSessionController({
    required this.clientId,
    required this.daemonVersion,
    required this.emit,
    required this.emitLifecycleIntent,
    required this.logger,
    required this.updater,
    this.desktopManaged = false,
  });

  /// Connection this controller serves.
  final String clientId;

  /// Version reported as `previousVersion`, or `null` when unknown.
  final String? daemonVersion;

  /// Whether the desktop app owns this daemon's lifecycle.
  final bool desktopManaged;

  /// Sends an outbound session message.
  final DaemonSessionEmit emit;

  /// Hands a restart request back to the session layer.
  final void Function(DaemonSelfUpdateRestartIntent intent) emitLifecycleIntent;

  /// Where unexpected failures are recorded.
  final DaemonSelfUpdateLogger logger;

  /// Performs the update.
  final DaemonSelfUpdatePerformer updater;

  /// Handles [message] when it belongs to this subsystem.
  ///
  /// Returns `null` **synchronously** for anything else, which is what lets a
  /// dispatch chain try each controller in turn without awaiting. Deviation:
  /// upstream returns `undefined`; Dart's nearest equivalent for a
  /// `Future<void>?` return is `null`.
  Future<void>? dispatch(Map<String, Object?> message) {
    if (!isDaemonSelfUpdateMessage(message)) return null;
    return _handleDaemonUpdateRequest(message);
  }

  Future<void> _handleDaemonUpdateRequest(Map<String, Object?> message) async {
    // The daemon's existing handlers correlate on `''` when a request arrives
    // without a usable id (see `ws_server.dart`), rather than dropping it; a
    // reply the client cannot match is still better than silence.
    final rawRequestId = message['requestId'];
    final requestId = rawRequestId is String ? rawRequestId : '';
    final previousVersion = daemonVersion;

    try {
      final result = await updater.update(
        DaemonSelfUpdateInput(
          daemonVersion: previousVersion,
          desktopManaged: desktopManaged,
          onProgress: (phase) => _emitProgress(requestId, phase),
          logger: logger,
        ),
      );

      _emitResponse(
        requestId: requestId,
        success: result.success,
        error: result.error,
        previousVersion: previousVersion,
        newVersion: result.newVersion,
      );
      if (!result.success) return;

      emitLifecycleIntent(
        DaemonSelfUpdateRestartIntent(
          clientId: clientId,
          requestId: requestId,
          reason: daemonSelfUpdateRestartReason,
        ),
      );
    } on DaemonSelfUpdateInProgressException catch (error) {
      // A concurrent request is not an update outcome, so it must not produce a
      // second `daemon.update.response` that would race the first one's client
      // state machine.
      emit(<String, Object?>{
        'type': 'rpc_error',
        'payload': <String, Object?>{
          'requestId': requestId,
          'requestType': DaemonUpdateRequest.type,
          'error': error.message,
          'code': daemonSelfUpdateAlreadyUpdatingCode,
        },
      });
    } on Object catch (error) {
      logger.error({'err': error}, 'Daemon update failed with exception');
      _emitResponse(
        requestId: requestId,
        success: false,
        error: getErrorMessage(error),
        previousVersion: previousVersion,
        newVersion: null,
      );
    }
  }

  void _emitProgress(String requestId, DaemonUpdatePhase phase) {
    emit(<String, Object?>{
      'type': DaemonUpdateProgress.type,
      'payload': <String, Object?>{'requestId': requestId, 'phase': phase.name},
    });
  }

  void _emitResponse({
    required String requestId,
    required bool success,
    required String? error,
    required String? previousVersion,
    required String? newVersion,
  }) {
    emit(<String, Object?>{
      'type': DaemonUpdateResponse.type,
      'payload': <String, Object?>{
        'requestId': requestId,
        'success': success,
        'error': error,
        'previousVersion': previousVersion,
        'newVersion': newVersion,
      },
    });
  }
}

// ---------------------------------------------------------------------------
// hub/execution-controller.ts
// ---------------------------------------------------------------------------

/// Wire type for a hub-initiated agent create request.
///
/// These three types are not in `agent_protocol`: this repo's protocol package
/// models hub *management* (`hub.management.daemon.*`) and only knows
/// `hub.execution.*` as an enrolment scope string
/// (`hub/relationship_controller.dart`). They are declared here so the port is
/// self-contained; promoting them into the protocol package is the natural
/// follow-up when the hub execution path is actually served.
const String hubExecutionAgentCreateResponseType =
    'hub.execution.agent.create.response';

/// Wire type for an owned-agent snapshot update pushed to the hub.
const String hubExecutionAgentUpdateType = 'hub.execution.agent.update';

/// Wire type for an owned-agent stream event pushed to the hub.
const String hubExecutionAgentStreamType = 'hub.execution.agent.stream';

/// Fields a hub sends to create an agent it will own.
final class HubExecutionAgentCreateRequest {
  const HubExecutionAgentCreateRequest({
    required this.requestId,
    required this.executionId,
    required this.provider,
    required this.cwd,
    required this.prompt,
    this.workspaceId,
    this.model,
    this.modeId,
    this.thinkingOptionId,
    this.featureValues,
    this.env,
    this.worktree,
    this.autoArchive,
  });

  /// Wire discriminator for the inbound request.
  static const String type = 'hub.execution.agent.create.request';

  /// Correlates the response.
  final String requestId;

  /// Hub-side execution this agent belongs to.
  final String executionId;

  /// Provider id the agent runs on.
  final String provider;

  /// Working directory; must be absolute.
  final String cwd;

  /// Initial prompt.
  final String prompt;

  /// Optional workspace scope.
  final String? workspaceId;

  /// Optional model override.
  final String? model;

  /// Optional permission/mode id.
  final String? modeId;

  /// Optional thinking-effort option id.
  final String? thinkingOptionId;

  /// Provider-specific feature toggles.
  final Map<String, Object?>? featureValues;

  /// Extra environment for the agent's processes.
  final Map<String, String>? env;

  /// Worktree to create or check out first.
  ///
  /// Reuses the protocol package's [CreateAgentWorktreeTarget] hierarchy rather
  /// than re-modelling upstream's `CreateAgentWorktreeTarget` union.
  final CreateAgentWorktreeTarget? worktree;

  /// Whether the agent's worktree is archived when it finishes.
  final bool? autoArchive;
}

/// Validated arguments handed to [HubExecutionAgents.create].
///
/// Distinct from [HubExecutionAgentCreateRequest] because the transport fields
/// (`type`, `requestId`) are not the agent factory's business — the same split
/// upstream makes.
final class HubExecutionAgentCreateInput {
  const HubExecutionAgentCreateInput({
    required this.executionId,
    required this.provider,
    required this.cwd,
    required this.prompt,
    this.workspaceId,
    this.model,
    this.modeId,
    this.thinkingOptionId,
    this.featureValues,
    this.env,
    this.worktree,
    this.autoArchive,
  });

  /// Hub-side execution this agent belongs to.
  final String executionId;

  /// Provider id the agent runs on.
  final String provider;

  /// Absolute working directory.
  final String cwd;

  /// Initial prompt.
  final String prompt;

  /// Optional workspace scope.
  final String? workspaceId;

  /// Optional model override.
  final String? model;

  /// Optional permission/mode id.
  final String? modeId;

  /// Optional thinking-effort option id.
  final String? thinkingOptionId;

  /// Provider-specific feature toggles.
  final Map<String, Object?>? featureValues;

  /// Extra environment for the agent's processes.
  final Map<String, String>? env;

  /// Worktree to create or check out first.
  final CreateAgentWorktreeTarget? worktree;

  /// Whether the agent's worktree is archived when it finishes.
  final bool? autoArchive;
}

/// A created agent, tagged with the execution that owns it.
final class OwnedAgentSnapshot {
  const OwnedAgentSnapshot({required this.executionId, required this.agent});

  /// Hub-side execution that owns the agent.
  final String executionId;

  /// Wire snapshot, as produced by `serializeAgentSnapshot`.
  ///
  /// Deviation: upstream types this as `AgentSnapshotPayload`. This repo has no
  /// such class — the projection lives in `PaseoAgentSnapshotCodec` and returns
  /// a map — so the already-encoded map is carried directly.
  final Map<String, Object?> agent;
}

/// Something that happened to an agent the hub owns.
///
/// Repo style: upstream's discriminated union becomes a sealed hierarchy, so the
/// switch in [HubExecutionController] is exhaustive at compile time.
sealed class OwnedAgentEvent {
  const OwnedAgentEvent({required this.executionId});

  /// Execution the agent belongs to.
  final String executionId;
}

/// The agent's snapshot changed.
final class OwnedAgentUpdateEvent extends OwnedAgentEvent {
  const OwnedAgentUpdateEvent({
    required super.executionId,
    required this.agent,
  });

  /// New wire snapshot.
  final Map<String, Object?> agent;
}

/// The agent emitted a stream event.
final class OwnedAgentStreamEvent extends OwnedAgentEvent {
  const OwnedAgentStreamEvent({
    required super.executionId,
    required this.agentId,
    required this.event,
  });

  /// Agent that emitted it.
  final String agentId;

  /// Already-serialized stream event.
  final Map<String, Object?> event;
}

/// The agents a hub execution owns on this daemon.
abstract interface class HubExecutionAgents {
  /// Creates an agent for an execution.
  Future<OwnedAgentSnapshot> create(HubExecutionAgentCreateInput input);

  /// Subscribes to owned-agent events; the returned callback unsubscribes.
  void Function() subscribe(void Function(OwnedAgentEvent event) listener);

  /// Drops this daemon's claim to the executions it owns.
  Future<void> invalidateAuthority();
}

/// Serves one hub connection's execution traffic.
///
/// The load-bearing behavior is the shutdown fence: once [cleanup] starts, no
/// further message is sent, and [cleanup] does not complete until every in-flight
/// create has settled. Without it a create that finishes after the socket died
/// would push a response into a dead session — and, worse, the hub would never
/// learn the agent exists.
final class HubExecutionController {
  HubExecutionController({
    required HubExecutionAgents agents,
    required DaemonSessionEmit send,
    p.Context? pathContext,
  }) : _agents = agents,
       _send = send,
       // Deviation: upstream calls Node's platform-bound `isAbsolute`. Injecting
       // the context lets the absolute-cwd rule be asserted for both platforms
       // regardless of where the tests run.
       _pathContext = pathContext ?? p.context {
    _unsubscribe = _agents.subscribe(_sendOwnedEvent);
  }

  final HubExecutionAgents _agents;
  final DaemonSessionEmit _send;
  final p.Context _pathContext;
  final Set<Future<void>> _pendingCreates = <Future<void>>{};

  late final void Function() _unsubscribe;
  Future<void>? _cleanupFuture;
  bool _closed = false;

  /// Whether this controller has been shut down.
  bool get isClosed => _closed;

  /// Stops sending and waits for in-flight creates to settle.
  ///
  /// Idempotent: repeated calls return the same future, so several teardown
  /// paths can await the one shutdown.
  Future<void> cleanup() => _cleanupFuture ??= _cleanupOnce();

  Future<void> _cleanupOnce() async {
    _closed = true;
    _unsubscribe();
    // `Promise.allSettled` semantics: a failed create must not prevent the rest
    // of shutdown. `Future.wait` propagates the first error, so each future is
    // neutralised first.
    await Future.wait(
      _pendingCreates
          .toList(growable: false)
          .map((create) => create.then<void>((_) {}, onError: (_) {})),
    );
  }

  /// Creates an agent and answers the hub, unless the session is already gone.
  Future<void> createAgent(HubExecutionAgentCreateRequest message) async {
    if (_closed) return;
    final create = _createAgentWithResponse(message);
    _pendingCreates.add(create);
    try {
      await create;
    } finally {
      _pendingCreates.remove(create);
    }
  }

  Future<void> _createAgentWithResponse(
    HubExecutionAgentCreateRequest message,
  ) async {
    try {
      _requireNonBlankHubAgentField('executionId', message.executionId);
      _requireNonBlankHubAgentField('prompt', message.prompt);
      _requireNonBlankHubAgentField('cwd', message.cwd);
      if (!_pathContext.isAbsolute(message.cwd)) {
        throw StateError('Hub agent cwd must be absolute');
      }

      final result = await _agents.create(
        HubExecutionAgentCreateInput(
          executionId: message.executionId,
          provider: message.provider,
          cwd: message.cwd,
          workspaceId: message.workspaceId,
          prompt: message.prompt,
          model: message.model,
          modeId: message.modeId,
          thinkingOptionId: message.thinkingOptionId,
          featureValues: message.featureValues,
          env: message.env,
          worktree: message.worktree,
          autoArchive: message.autoArchive,
        ),
      );
      // Re-checked after the await: the session may have died while the agent
      // was being created.
      if (_closed) return;
      _send(<String, Object?>{
        'type': hubExecutionAgentCreateResponseType,
        'payload': <String, Object?>{
          'requestId': message.requestId,
          'executionId': message.executionId,
          'agentId': result.agent['id'],
          'agent': result.agent,
          'success': true,
          'error': null,
        },
      });
    } on Object catch (error) {
      if (_closed) return;
      _send(<String, Object?>{
        'type': hubExecutionAgentCreateResponseType,
        'payload': <String, Object?>{
          'requestId': message.requestId,
          'executionId': message.executionId,
          'agentId': null,
          'agent': null,
          'success': false,
          // Upstream's `error instanceof Error ? error.message : String(error)`
          // is exactly what the daemon's shared [getErrorMessage] does.
          'error': getErrorMessage(error),
        },
      });
    }
  }

  void _sendOwnedEvent(OwnedAgentEvent event) {
    if (_closed) return;
    switch (event) {
      case OwnedAgentUpdateEvent(:final executionId, :final agent):
        _send(<String, Object?>{
          'type': hubExecutionAgentUpdateType,
          'payload': <String, Object?>{
            'executionId': executionId,
            'agentId': agent['id'],
            'agent': agent,
          },
        });
      case OwnedAgentStreamEvent(
        :final executionId,
        :final agentId,
        :final event,
      ):
        _send(<String, Object?>{
          'type': hubExecutionAgentStreamType,
          'payload': <String, Object?>{
            'executionId': executionId,
            'agentId': agentId,
            'event': event,
          },
        });
    }
  }

  void _requireNonBlankHubAgentField(String field, String value) {
    // Deviation: upstream throws `Error`; Dart's closest "caller violated a
    // precondition" type without adding a public exception class is
    // [StateError], whose `message` is what [getErrorMessage] surfaces.
    if (value.trim().isEmpty) {
      throw StateError('Hub agent $field cannot be blank');
    }
  }
}
