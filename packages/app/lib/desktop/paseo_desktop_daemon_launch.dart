/// Port of Paseo 0.2.0's desktop daemon *launch and quit* rules. Upstream these
/// live in the Electron host (`packages/desktop`); every one of them is a
/// decision rule that answers "which path / which argv / which order", so they
/// port cleanly once the host capability is an injected port:
///
/// - `desktop/daemon/runtime-paths.ts` — the resolution *order* for the daemon
///   runner entrypoint (packaged bundle → built `dist` → source + a loader
///   flag) and for the Node-capable executable (a packaged macOS app must
///   re-exec its `… Helper.app` binary, never the main app binary).
/// - `desktop/daemon/node-entrypoint-launcher.ts` — how an entrypoint spec plus
///   arguments become a concrete `{command, args, env}` invocation, and which
///   environment variables a packaged launch forces.
/// - `desktop/daemon/node-entrypoint-runner.ts` — the argv contract on the
///   other side of that launch: `<argvMode> <entryPath> [...args]`, validated
///   and then rewritten into the argv the loaded entrypoint observes.
/// - `desktop/daemon/quit-lifecycle.ts` — the quit sequencing: stop the
///   desktop-managed daemon only when the user asked for it, then give the
///   auto-updater a bounded window to take ownership of process exit before
///   forcing it.
/// - `desktop/daemon/cli/passthrough.ts` — which of the OS-injected launch
///   arguments count as a CLI invocation and which are GUI noise.
/// - `desktop/daemon/cli/external.ts` — how a one-shot CLI subprocess's exit
///   code, stdout and stderr become either a value or a diagnosable failure.
///
/// It also ports the two `desktop/daemon/package-paths.ts` helpers the rules
/// above are built on ([assertDaemonLaunchPathExists] and
/// [findNodePackageRootFromResolvedPath]), because the resolution *order* is
/// meaningless without them.
///
/// ## Architecture note — what this is and is not
///
/// Upstream launches a bundled **Node** entrypoint out of an Electron host.
/// This repo has no Electron and its daemon is a **Dart** binary, supervised by
/// `package:daemon_lifecycle` ([DaemonStatus], `resolveDaemonExe`,
/// `spawnDaemonDetached`, `stopDaemon`). So this library deliberately does
/// **not** launch anything: it is the frozen decision layer, exercisable with
/// no host at all, and every effect it needs — filesystem probing, module
/// resolution, process spawn, module import, app exit, logging — arrives as a
/// narrow injected interface. Nothing here imports `dart:io`.
///
/// Where an upstream concept has a live counterpart in this repo it is reused
/// rather than re-declared: [DaemonStatus] from `package:daemon_lifecycle` and
/// [DesktopSettings] from the app's own settings store. See
/// [isDesktopManagedDaemonRunning] and [shouldStopDesktopManagedDaemonOnQuit].
library;

import 'dart:async' show Completer;
import 'dart:convert' show jsonDecode;

import 'package:daemon_lifecycle/daemon_lifecycle.dart' show DaemonStatus;

import '../state/desktop_settings_provider.dart' show DesktopSettings;

// Re-exported because they appear in this library's public signatures, so a
// caller should not need to know which existing module they were reused from.
export 'package:daemon_lifecycle/daemon_lifecycle.dart' show DaemonStatus;

export '../state/desktop_settings_provider.dart' show DesktopSettings;

// ---------------------------------------------------------------------------
// Shared failure type
// ---------------------------------------------------------------------------

/// Every `throw new Error(...)` in the ported cluster.
///
/// Upstream compares these by `error.message`, so [message] is the load-bearing
/// field and [toString] is only for debugger output.
final class DesktopDaemonLaunchException implements Exception {
  const DesktopDaemonLaunchException(this.message, {this.cause});

  /// The verbatim upstream `Error.message`.
  final String message;

  /// Upstream `new Error(msg, { cause })`. Dart has no language-level cause, so
  /// it is carried as a field; only [ExternalCliCommands.runJsonCommand]
  /// populates it, matching the one upstream site that passes `cause`.
  final Object? cause;

  @override
  String toString() => 'DesktopDaemonLaunchException: $message';
}

// ---------------------------------------------------------------------------
// Host ports
// ---------------------------------------------------------------------------

/// The `node:fs` slice these rules touch.
///
/// Kept to two methods on purpose: the launch rules only ever ask "is this
/// there?" and "what does this `package.json` say?".
abstract interface class DaemonLaunchFileSystem {
  /// Upstream `existsSync`. Must not throw — a permission error reads as
  /// "absent", exactly as `existsSync` reports it.
  bool exists(String path);

  /// Upstream `readFileSync(path, "utf-8")`. May throw; every caller in this
  /// library already treats a read failure the same as malformed content,
  /// because upstream's `try` block encloses the read as well as the parse.
  String readAsString(String path);
}

/// Node's `require.resolve`, which maps a package specifier to the file the
/// package's exports map points at.
///
/// Dart has no runtime module resolution, so this has no in-process
/// implementation here — it exists so the *resolution order* in
/// [DesktopDaemonRuntimePaths] stays testable and so a future host (a Node
/// sidecar, a build-time manifest) can supply it.
abstract interface class NodeModuleResolver {
  /// Throws (like `require.resolve`) when the specifier cannot be resolved.
  String resolve(String specifier);
}

/// Upstream `electron-log/main`'s `log.warn(scope, message, details)`.
abstract interface class DesktopDaemonLaunchLogger {
  void warn(String scope, String message, Map<String, Object?> details);
}

// ---------------------------------------------------------------------------
// package-paths.ts — path primitives
// ---------------------------------------------------------------------------

/// The subset of `node:path` these rules need, as an injectable value so tests
/// can pin POSIX semantics on a Windows machine (upstream's suites all assume
/// POSIX, and `resolveNodeExecPath` reaches for `path.posix` explicitly).
///
/// Deviation note: this implements only `join`, `dirname`, `basename` and
/// `pathToFileURL`, and only the subset of their semantics the call sites use —
/// no `..`/`.` collapsing and no trailing-separator preservation, because every
/// upstream call site joins plain literal segments onto an absolute base.
final class DesktopPathOps {
  const DesktopPathOps._(this.separator, this._separators);

  /// `node:path.posix`.
  static const DesktopPathOps posix = DesktopPathOps._('/', '/');

  /// `node:path.win32`, which accepts both slash flavours as separators.
  static const DesktopPathOps windows = DesktopPathOps._('\\', '/\\');

  /// The separator emitted when joining.
  final String separator;

  final String _separators;

  bool _isSeparator(String character) => _separators.contains(character);

  /// `path.join(...)` for plain segments. Empty segments are dropped, as in
  /// Node; an all-empty call yields `"."`.
  String join(List<String> parts) {
    final present = parts.where((part) => part.isNotEmpty).toList();
    if (present.isEmpty) return '.';

    final leading = _leadingSeparators(present.first);
    final segments = <String>[];
    for (final part in present) {
      for (final piece in _split(part)) {
        if (piece.isNotEmpty) segments.add(piece);
      }
    }
    if (segments.isEmpty) return leading.isEmpty ? '.' : leading;
    return '$leading${segments.join(separator)}';
  }

  /// `path.dirname(...)`. Reaches a fixpoint at the filesystem root, which is
  /// what terminates [findNodePackageRootFromResolvedPath]'s upward walk.
  String dirname(String path) {
    if (path.isEmpty) return '.';

    var end = path.length;
    while (end > 0 && _isSeparator(path[end - 1])) {
      end--;
    }
    if (end == 0) return path[0];

    var index = -1;
    for (var i = end - 1; i >= 0; i--) {
      if (_isSeparator(path[i])) {
        index = i;
        break;
      }
    }
    if (index < 0) {
      // A bare Windows drive (`C:` or `C:\`) is its own parent upstream; give
      // it the same fixpoint so the package-root walk cannot escape into a
      // relative `./package.json` probe.
      if (separator == '\\' && end == 2 && path[1] == ':') {
        return path.length >= 3 ? path.substring(0, 3) : path.substring(0, 2);
      }
      return '.';
    }
    final head = path.substring(0, index);
    if (head.isEmpty) return path[0];
    if (separator == '\\' && head.length == 2 && head[1] == ':') {
      return '$head${path[index]}';
    }
    return head;
  }

  /// `path.basename(...)`.
  String basename(String path) {
    var end = path.length;
    while (end > 0 && _isSeparator(path[end - 1])) {
      end--;
    }
    if (end == 0) return '';

    var start = 0;
    for (var i = end - 1; i >= 0; i--) {
      if (_isSeparator(path[i])) {
        start = i + 1;
        break;
      }
    }
    return path.substring(start, end);
  }

  /// `pathToFileURL(path).href`.
  ///
  /// Deviation note: Node resolves a relative path against `process.cwd()`
  /// first. That is a `dart:io` capability and no upstream call site passes a
  /// relative path, so a relative input yields a relative URI here instead.
  String fileUri(String path) =>
      Uri.file(path, windows: separator == '\\').toString();

  String _leadingSeparators(String part) {
    var index = 0;
    while (index < part.length && _isSeparator(part[index])) {
      index++;
    }
    return part.substring(0, index);
  }

  Iterable<String> _split(String part) {
    final pieces = <String>[];
    final buffer = StringBuffer();
    for (var i = 0; i < part.length; i++) {
      if (_isSeparator(part[i])) {
        pieces.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(part[i]);
      }
    }
    pieces.add(buffer.toString());
    return pieces;
  }
}

/// Upstream `assertPathExists` — turns a missing bundled asset into a message
/// that names *which* asset was expected and where, because these failures show
/// up in packaged builds where nobody can attach a debugger.
String assertDaemonLaunchPathExists({
  required String label,
  required String filePath,
  required DaemonLaunchFileSystem fileSystem,
}) {
  if (!fileSystem.exists(filePath)) {
    throw DesktopDaemonLaunchException('$label is missing at $filePath');
  }
  return filePath;
}

/// Upstream `PackageInfo`.
final class NodePackageInfo {
  const NodePackageInfo({required this.root});

  /// The directory holding the matching `package.json`.
  final String root;

  @override
  bool operator ==(Object other) =>
      other is NodePackageInfo && other.root == root;

  @override
  int get hashCode => Object.hash(NodePackageInfo, root);

  @override
  String toString() => 'NodePackageInfo($root)';
}

/// Upstream `findPackageRootFromResolvedPath` — walks up from a resolved file
/// until it finds the `package.json` whose `name` matches, which is the only
/// reliable way to locate a package root under pnpm's symlinked layout.
///
/// A `package.json` that cannot be read or parsed, or whose payload is not a
/// JSON object, is skipped rather than fatal: upstream's `try` block encloses
/// both the read and the parse, and a JS property read on a non-object payload
/// yields `undefined` instead of throwing.
NodePackageInfo findNodePackageRootFromResolvedPath({
  required String resolvedPath,
  required String packageName,
  required DaemonLaunchFileSystem fileSystem,
  DesktopPathOps paths = DesktopPathOps.posix,
}) {
  var currentDir = paths.dirname(resolvedPath);

  while (true) {
    final packageJsonPath = paths.join([currentDir, 'package.json']);
    if (fileSystem.exists(packageJsonPath)) {
      try {
        final decoded = jsonDecode(fileSystem.readAsString(packageJsonPath));
        final name = decoded is Map ? decoded['name'] : null;
        if (name == packageName) {
          return NodePackageInfo(root: currentDir);
        }
      } catch (_) {
        // Ignore malformed package metadata while walking up.
      }
    }

    final parent = paths.dirname(currentDir);
    if (parent == currentDir) break;
    currentDir = parent;
  }

  throw DesktopDaemonLaunchException(
    'Unable to resolve $packageName package root',
  );
}

// ---------------------------------------------------------------------------
// node-entrypoint-launcher.ts
// ---------------------------------------------------------------------------

/// Upstream `PASEO_NODE_ENV`. A packaged launch stamps this rather than
/// `NODE_ENV` so an inherited developer `NODE_ENV=development` cannot downgrade
/// a shipped build.
const String paseoNodeEnvVar = 'PASEO_NODE_ENV';

/// Electron's "run this binary as plain Node" switch.
const String electronRunAsNodeVar = 'ELECTRON_RUN_AS_NODE';

/// Which argv shape the launched entrypoint expects to observe.
///
/// Upstream is the string union `"bare" | "node-script"`; each member keeps its
/// wire spelling because the value is passed verbatim on the command line.
enum NodeEntrypointArgvMode {
  /// The entrypoint reads argv as if it were the executable itself, so its own
  /// path is *not* present at `argv[1]`.
  bare('bare'),

  /// Standard Node argv: `[execPath, scriptPath, ...args]`.
  nodeScript('node-script');

  const NodeEntrypointArgvMode(this.wireName);

  /// The literal upstream string union member.
  final String wireName;

  /// Parses the command-line spelling; null for anything unrecognised,
  /// including the missing-argument case.
  static NodeEntrypointArgvMode? fromWireName(String? wireName) {
    for (final mode in NodeEntrypointArgvMode.values) {
      if (mode.wireName == wireName) return mode;
    }
    return null;
  }
}

/// Upstream `NodeEntrypointSpec` — a script plus the interpreter flags it needs
/// (e.g. `--import tsx` when only TypeScript sources exist).
final class NodeEntrypointSpec {
  const NodeEntrypointSpec({required this.entryPath, required this.execArgv});

  /// Absolute path of the script to load.
  final String entryPath;

  /// Interpreter flags that must precede [entryPath] on an unpackaged launch.
  final List<String> execArgv;

  @override
  bool operator ==(Object other) =>
      other is NodeEntrypointSpec &&
      other.entryPath == entryPath &&
      _listEquals(other.execArgv, execArgv);

  @override
  int get hashCode => Object.hash(entryPath, Object.hashAll(execArgv));

  @override
  String toString() => 'NodeEntrypointSpec($entryPath, $execArgv)';
}

/// Upstream `NodeEntrypointInvocation` — a fully resolved spawn request.
final class NodeEntrypointInvocation {
  const NodeEntrypointInvocation({
    required this.command,
    required this.args,
    required this.env,
  });

  /// The executable to spawn.
  final String command;

  /// Its argument vector.
  final List<String> args;

  /// The complete child environment, not a delta.
  final Map<String, String> env;

  @override
  bool operator ==(Object other) =>
      other is NodeEntrypointInvocation &&
      other.command == command &&
      _listEquals(other.args, args) &&
      _mapEquals(other.env, env);

  @override
  int get hashCode =>
      Object.hash(command, Object.hashAll(args), Object.hashAll(env.keys));

  @override
  String toString() => 'NodeEntrypointInvocation($command, $args, $env)';
}

/// Upstream `createElectronNodeEnv`.
///
/// `ELECTRON_RUN_AS_NODE` is always set: the command being spawned is the
/// Electron/app binary, and without this it would boot a second GUI instead of
/// running the script. [paseoNodeEnvVar] is added only for packaged launches.
Map<String, String> createElectronNodeEnv(
  Map<String, String> baseEnv, {
  bool isPackaged = false,
}) => {
  ...baseEnv,
  electronRunAsNodeVar: '1',
  if (isPackaged) paseoNodeEnvVar: 'production',
};

/// Upstream `createNodeEntrypointInvocation` (the pure, host-free one).
///
/// The two branches differ in *who interprets the entrypoint*. Unpackaged, the
/// binary is a real Node/Electron on disk and can take `execArgv` directly.
/// Packaged, `execArgv` cannot be honoured (the flags would have to precede a
/// binary that is already running), so a bundled runner script is launched
/// instead and re-dispatches to the entrypoint in-process — which is why
/// [packagedRunnerPath] is mandatory there.
NodeEntrypointInvocation createNodeEntrypointInvocation({
  required String execPath,
  required bool isPackaged,
  required String? packagedRunnerPath,
  required NodeEntrypointSpec entrypoint,
  required NodeEntrypointArgvMode argvMode,
  required List<String> args,
  required Map<String, String> baseEnv,
}) => _buildNodeEntrypointInvocation(
  execPath: execPath,
  isPackaged: isPackaged,
  packagedRunnerPath: packagedRunnerPath,
  entrypoint: entrypoint,
  argvMode: argvMode,
  args: args,
  baseEnv: baseEnv,
);

NodeEntrypointInvocation _buildNodeEntrypointInvocation({
  required String execPath,
  required bool isPackaged,
  required String? packagedRunnerPath,
  required NodeEntrypointSpec entrypoint,
  required NodeEntrypointArgvMode argvMode,
  required List<String> args,
  required Map<String, String> baseEnv,
}) {
  final env = createElectronNodeEnv(baseEnv, isPackaged: isPackaged);

  if (isPackaged) {
    if (packagedRunnerPath == null || packagedRunnerPath.isEmpty) {
      // Deviation note: upstream's guard is `if (!input.packagedRunnerPath)`,
      // which is JS-falsy — so an empty string trips it too, not just null.
      throw const DesktopDaemonLaunchException(
        'Packaged node entrypoint runner is required for desktop launches.',
      );
    }

    return NodeEntrypointInvocation(
      command: execPath,
      args: [
        '--disable-warning=DEP0040',
        packagedRunnerPath,
        argvMode.wireName,
        entrypoint.entryPath,
        ...args,
      ],
      env: env,
    );
  }

  return NodeEntrypointInvocation(
    command: execPath,
    args: [...entrypoint.execArgv, entrypoint.entryPath, ...args],
    env: env,
  );
}

/// The factory shape [ExternalCliCommands] depends on, satisfied by
/// [DesktopDaemonRuntimePaths.createNodeEntrypointInvocation].
typedef NodeEntrypointInvocationFactory =
    NodeEntrypointInvocation Function({
      required NodeEntrypointSpec entrypoint,
      required NodeEntrypointArgvMode argvMode,
      required List<String> args,
      required Map<String, String> baseEnv,
    });

// ---------------------------------------------------------------------------
// runtime-paths.ts
// ---------------------------------------------------------------------------

/// Upstream `process.platform`, narrowed to the values the rules branch on.
enum DesktopLaunchPlatform {
  /// macOS — the only platform with the app-bundle Helper indirection.
  darwin,

  /// Windows.
  win32,

  /// Linux and everything else.
  linux,
}

/// The npm package holding the daemon supervisor entrypoint upstream.
const String paseoServerPackageName = '@getpaseo/server';

/// Upstream `runtime-paths.ts`: where the daemon runner and the Node-capable
/// executable live, given how the app was built and which OS it runs on.
///
/// Every ambient global upstream reads (`app.isPackaged`, `process.platform`,
/// `process.execPath`, `process.resourcesPath`) is a constructor field here, so
/// a packaged-macOS decision can be exercised from a Windows test run.
///
/// Counterpart note: this repo's daemon is a Dart binary and is located by
/// `daemon_lifecycle`'s `resolveDaemonExe()` (app-sibling → dev build → PATH).
/// [resolveDaemonRunnerEntrypoint] is the *frozen upstream* ordering, kept for
/// parity; it is not wired into this app's supervision path.
final class DesktopDaemonRuntimePaths {
  const DesktopDaemonRuntimePaths({
    required this.fileSystem,
    required this.isPackaged,
    required this.platform,
    required this.execPath,
    required this.resourcesPath,
    this.moduleResolver,
    this.paths = DesktopPathOps.posix,
  });

  /// Existence probing for bundled assets.
  final DaemonLaunchFileSystem fileSystem;

  /// Upstream `app.isPackaged`.
  final bool isPackaged;

  /// Upstream `process.platform`.
  final DesktopLaunchPlatform platform;

  /// Upstream `process.execPath` — the binary currently running.
  final String execPath;

  /// Upstream `process.resourcesPath` — the packaged `Resources` directory.
  final String resourcesPath;

  /// Only consulted on unpackaged launches; a packaged build never walks
  /// `node_modules`, so a packaged-only host may leave this null.
  final NodeModuleResolver? moduleResolver;

  /// Path flavour used for joining. Defaults to POSIX to match upstream's
  /// suites; a real Windows host would inject [DesktopPathOps.windows].
  final DesktopPathOps paths;

  /// Upstream `resolvePackagedAsarPath`.
  String resolvePackagedAsarPath() => paths.join([resourcesPath, 'app.asar']);

  /// Upstream `resolvePackagedNodeEntrypointRunnerPath`.
  ///
  /// Note the `app.asar.unpacked` root: the runner must be a real file on disk
  /// because it is passed to the binary as a script path, and paths inside the
  /// asar archive are not visible to a plain Node process.
  String resolvePackagedNodeEntrypointRunnerPath() => paths.join([
    resourcesPath,
    'app.asar.unpacked',
    'dist',
    'daemon',
    'node-entrypoint-runner.js',
  ]);

  /// Upstream `resolveDaemonRunnerEntrypoint` — the three-step order.
  ///
  /// 1. Packaged: the bundled JS inside the asar, and a miss is fatal.
  /// 2. Unpackaged with a built `dist/`: use it, no TypeScript loader needed.
  /// 3. Unpackaged without one: fall back to the TS source and ask for the
  ///    `tsx` loader, so a fresh checkout runs before anyone builds it.
  NodeEntrypointSpec resolveDaemonRunnerEntrypoint() {
    if (isPackaged) {
      return NodeEntrypointSpec(
        entryPath: assertDaemonLaunchPathExists(
          label: 'Bundled daemon runner',
          filePath: paths.join([
            resolvePackagedAsarPath(),
            'node_modules',
            '@getpaseo',
            'server',
            'dist',
            'scripts',
            'supervisor-entrypoint.js',
          ]),
          fileSystem: fileSystem,
        ),
        execArgv: const [],
      );
    }

    final serverPackage = _resolveServerPackageInfo();
    final distRunner = paths.join([
      serverPackage.root,
      'dist',
      'scripts',
      'supervisor-entrypoint.js',
    ]);
    if (fileSystem.exists(distRunner)) {
      return NodeEntrypointSpec(entryPath: distRunner, execArgv: const []);
    }

    return NodeEntrypointSpec(
      entryPath: assertDaemonLaunchPathExists(
        label: 'Daemon runner source',
        filePath: paths.join([
          serverPackage.root,
          'scripts',
          'supervisor-entrypoint.ts',
        ]),
        fileSystem: fileSystem,
      ),
      execArgv: const ['--import', 'tsx'],
    );
  }

  /// Upstream `resolveNodeExecPath`.
  ///
  /// A packaged macOS app must spawn `Contents/Frameworks/<name> Helper.app`,
  /// not the main binary: the main binary is the already-running GUI process
  /// and re-execing it is what macOS treats as a second app instance. Every
  /// guard falls back to [execPath], so an unrecognised bundle layout degrades
  /// rather than failing.
  String resolveNodeExecPath() {
    if (isPackaged && platform == DesktopLaunchPlatform.darwin) {
      const marker = '.app/Contents/MacOS/';
      final markerIndex = execPath.indexOf(marker);
      if (markerIndex != -1) {
        final bundleRoot = execPath.substring(0, markerIndex + '.app'.length);
        final name = paths.basename(execPath);
        // Upstream uses `path.posix.join` here specifically — this branch is
        // macOS-only, so the separator must not follow the host's flavour.
        final helperPath = DesktopPathOps.posix.join([
          bundleRoot,
          'Contents',
          'Frameworks',
          '$name Helper.app',
          'Contents',
          'MacOS',
          '$name Helper',
        ]);
        if (fileSystem.exists(helperPath)) {
          return helperPath;
        }
      }
    }
    return execPath;
  }

  /// Upstream `createNodeEntrypointInvocation` (the host-bound one): binds the
  /// resolved executable, the packaged flag and the runner path, then defers to
  /// the pure rule.
  NodeEntrypointInvocation createNodeEntrypointInvocation({
    required NodeEntrypointSpec entrypoint,
    required NodeEntrypointArgvMode argvMode,
    required List<String> args,
    required Map<String, String> baseEnv,
  }) => _buildNodeEntrypointInvocation(
    execPath: resolveNodeExecPath(),
    isPackaged: isPackaged,
    packagedRunnerPath: isPackaged
        ? assertDaemonLaunchPathExists(
            label: 'Bundled node entrypoint runner',
            filePath: resolvePackagedNodeEntrypointRunnerPath(),
            fileSystem: fileSystem,
          )
        : null,
    entrypoint: entrypoint,
    argvMode: argvMode,
    args: args,
    baseEnv: baseEnv,
  );

  NodePackageInfo _resolveServerPackageInfo() {
    final resolver = moduleResolver;
    if (resolver == null) {
      throw const DesktopDaemonLaunchException(
        'A NodeModuleResolver is required to resolve '
        '$paseoServerPackageName outside a packaged build.',
      );
    }
    return findNodePackageRootFromResolvedPath(
      resolvedPath: resolver.resolve(paseoServerPackageName),
      packageName: paseoServerPackageName,
      fileSystem: fileSystem,
      paths: paths,
    );
  }
}

// ---------------------------------------------------------------------------
// node-entrypoint-runner.ts
// ---------------------------------------------------------------------------

/// Upstream's runner exits with this code after printing the failure.
const int nodeEntrypointRunnerFailureExitCode = 1;

/// The argv rewrite the runner performs before handing control over.
final class NodeEntrypointRunnerPlan {
  const NodeEntrypointRunnerPlan({
    required this.argvMode,
    required this.entryPath,
    required this.argv,
  });

  /// The mode taken from `argv[2]`.
  final NodeEntrypointArgvMode argvMode;

  /// The script to load, taken from `argv[3]`.
  final String entryPath;

  /// The argv the loaded entrypoint will observe.
  final List<String> argv;

  @override
  bool operator ==(Object other) =>
      other is NodeEntrypointRunnerPlan &&
      other.argvMode == argvMode &&
      other.entryPath == entryPath &&
      _listEquals(other.argv, argv);

  @override
  int get hashCode => Object.hash(argvMode, entryPath, Object.hashAll(argv));

  @override
  String toString() =>
      'NodeEntrypointRunnerPlan(${argvMode.wireName}, $entryPath, $argv)';
}

/// Upstream `node-entrypoint-runner.ts`'s argv parsing and rewrite, split out
/// as a pure rule.
///
/// The runner's whole job is to make a script that was launched *indirectly*
/// (binary → runner → script) see the argv it would have seen if it had been
/// launched directly. [NodeEntrypointArgvMode.bare] drops the script path so a
/// CLI reads its first user argument at `argv[1]`;
/// [NodeEntrypointArgvMode.nodeScript] keeps it.
///
/// Environment is deliberately untouched: `ELECTRON_RUN_AS_NODE` and friends
/// must survive into the loaded module, and upstream achieves that by simply
/// not clearing them.
NodeEntrypointRunnerPlan planNodeEntrypointRunner(List<String> processArgv) {
  final rest = processArgv.length > 2
      ? processArgv.sublist(2)
      : const <String>[];
  final rawMode = rest.isNotEmpty ? rest[0] : null;
  final entryPath = rest.length > 1 ? rest[1] : null;
  final args = rest.length > 2 ? rest.sublist(2) : const <String>[];

  final argvMode = NodeEntrypointArgvMode.fromWireName(rawMode);
  if (argvMode == null) {
    throw DesktopDaemonLaunchException(
      'Unsupported node entrypoint argv mode: ${rawMode ?? '<missing>'}',
    );
  }
  if (entryPath == null || entryPath.isEmpty) {
    // Upstream's `if (!entryPath)` is JS-falsy, so an explicitly empty path
    // fails here too rather than being imported as `""`.
    throw const DesktopDaemonLaunchException('Missing node entrypoint path.');
  }

  // Upstream writes `process.argv[0] ?? "node"`. That fallback is unreachable:
  // reaching this line requires `argv.length >= 4`. It is reproduced anyway so
  // the observable output is identical for a hand-constructed argv.
  final executable = processArgv.isNotEmpty ? processArgv[0] : 'node';

  return NodeEntrypointRunnerPlan(
    argvMode: argvMode,
    entryPath: entryPath,
    argv: switch (argvMode) {
      NodeEntrypointArgvMode.bare => [executable, ...args],
      NodeEntrypointArgvMode.nodeScript => [executable, entryPath, ...args],
    },
  );
}

/// The process-global surface the runner mutates, as a port.
///
/// Counterpart note: `importModule` has **no Dart analogue** — Dart cannot load
/// a module at runtime. It exists so the argv contract stays verifiable and so
/// a real host (a Node sidecar, or an isolate entrypoint registry) can supply
/// the dispatch.
abstract interface class NodeEntrypointRunnerHost {
  /// Upstream `process.argv`.
  List<String> get argv;

  /// Upstream's in-place `process.argv = [...]` rewrite.
  set argv(List<String> value);

  /// Upstream `await import(pathToFileURL(entryPath).href)`.
  Future<void> importModule(String moduleUrl);
}

/// Upstream `main()` — validate, rewrite argv, then hand over.
///
/// The argv rewrite happens *before* the import on purpose: an ES module's
/// top-level body runs during the import, so it must already observe the
/// corrected argv.
Future<void> runNodeEntrypointRunner({
  required NodeEntrypointRunnerHost host,
  DesktopPathOps paths = DesktopPathOps.posix,
}) async {
  final plan = planNodeEntrypointRunner(host.argv);
  host.argv = plan.argv;
  await host.importModule(paths.fileUri(plan.entryPath));
}

/// Upstream's top-level `catch` formatting: the stack when there is one, else
/// the message, else the stringified value — always newline-terminated because
/// it goes straight to `process.stderr.write`.
///
/// Deviation note: JS `error.stack` embeds the message; Dart keeps them apart,
/// so an error with a [stackTrace] renders as message-then-stack to preserve
/// the same information in the same single write.
String formatNodeEntrypointRunnerFailure(
  Object error, [
  StackTrace? stackTrace,
]) {
  final message = error is DesktopDaemonLaunchException
      ? error.message
      : '$error';
  if (stackTrace == null) return '$message\n';
  return '$message\n$stackTrace\n';
}

// ---------------------------------------------------------------------------
// cli/passthrough.ts
// ---------------------------------------------------------------------------

/// Env var a terminal shim sets to force CLI mode even with no arguments.
const String paseoDesktopCliEnvVar = 'PASEO_DESKTOP_CLI';

/// Launch arguments the OS or the Electron wrapper injects, which must never be
/// mistaken for a user's CLI invocation.
///
/// These are matched as *prefixes*, exactly as upstream: `-psn_<n>_<pid>` is
/// the macOS Process Serial Number, `--remote-debugging-port=` carries a value,
/// and `--no-sandbox` is prefix-matched too — so a hypothetical
/// `--no-sandboxing` would also be swallowed. That looseness is preserved.
const List<String> ignoredPassthroughArgPrefixes = [
  '-psn_',
  '--no-sandbox',
  '--remote-debugging-port=',
];

/// Upstream `parsePassthroughCliArgs`.
///
/// Returns null for "this was a GUI launch, show a window"; a list (possibly
/// empty) for "this was a CLI invocation, run it and exit". The start index
/// differs because an unpackaged Electron run puts the app path at `argv[1]`,
/// while a packaged binary's own path is already `argv[0]`.
List<String>? parsePassthroughCliArgs({
  required List<String> argv,
  required bool isDefaultApp,
  required bool forceCli,
}) {
  final startIndex = isDefaultApp ? 2 : 1;
  final effective = <String>[];

  for (final arg
      in argv.length > startIndex
          ? argv.sublist(startIndex)
          : const <String>[]) {
    if (ignoredPassthroughArgPrefixes.any(arg.startsWith)) {
      continue;
    }
    effective.add(arg);
  }

  if (forceCli) {
    return effective;
  }

  return effective.isNotEmpty ? effective : null;
}

/// The two process globals upstream's `parsePassthroughCliArgsFromArgv` reads,
/// as an injected value.
final class PassthroughCliLaunchEnvironment {
  const PassthroughCliLaunchEnvironment({
    required this.isDefaultApp,
    this.environment = const {},
  });

  /// Upstream `process.defaultApp` — true when Electron was started with a
  /// project path rather than as a packaged binary.
  final bool isDefaultApp;

  /// Upstream `process.env`.
  final Map<String, String> environment;

  /// Upstream `process.env.PASEO_DESKTOP_CLI === "1"` — an exact match, so
  /// `"true"` or `"0"` do not force CLI mode.
  bool get forceCli => environment[paseoDesktopCliEnvVar] == '1';
}

/// Upstream `parsePassthroughCliArgsFromArgv`.
List<String>? parsePassthroughCliArgsFromArgv({
  required List<String> argv,
  required PassthroughCliLaunchEnvironment environment,
}) => parsePassthroughCliArgs(
  argv: argv,
  isDefaultApp: environment.isDefaultApp,
  forceCli: environment.forceCli,
);

/// Upstream `PassthroughCliRunner` — the CLI's programmatic entrypoint,
/// resolving to the process exit code.
typedef PassthroughCliRunner = Future<int> Function(List<String> argv);

/// Upstream `importPassthroughCliRunner`'s two steps, as a port.
///
/// Counterpart note: like [NodeEntrypointRunnerHost.importModule], the dynamic
/// import has **no Dart analogue**; the export-shape check it guards is the
/// part worth keeping.
abstract interface class PassthroughCliModuleLoader {
  /// Upstream `resolvePassthroughCliEntrypoint()` from `cli/entrypoints.ts`.
  String resolveEntrypoint();

  /// Loads [entrypoint] and returns its `runCli` export, or null when the
  /// module does not export one as a function.
  Future<PassthroughCliRunner?> loadRunCli(String entrypoint);
}

/// Upstream `runPassthroughCli`.
///
/// [runCli] short-circuits the load, which is how the desktop process runs the
/// CLI in-process when it already has it linked.
///
/// Deviation note: upstream falls back to a module-global import when [runCli]
/// is absent. Dart has no such global, so [loader] supplies it; omitting both
/// is a programming error and raises rather than silently doing nothing.
Future<int> runPassthroughCli(
  List<String> args, {
  PassthroughCliRunner? runCli,
  PassthroughCliModuleLoader? loader,
}) async {
  if (runCli != null) return runCli(args);

  if (loader == null) {
    throw const DesktopDaemonLaunchException(
      'runPassthroughCli requires either runCli or a '
      'PassthroughCliModuleLoader.',
    );
  }

  final entrypoint = loader.resolveEntrypoint();
  final resolved = await loader.loadRunCli(entrypoint);
  if (resolved == null) {
    throw DesktopDaemonLaunchException(
      'Passthrough CLI entrypoint did not export runCli: $entrypoint',
    );
  }
  return resolved(args);
}

// ---------------------------------------------------------------------------
// cli/external.ts
// ---------------------------------------------------------------------------

/// Upstream's `spawnProcess(command, args, options)` call, as a value so the
/// spawn *options* stay assertable without a live process.
final class ExternalCliSpawnRequest {
  const ExternalCliSpawnRequest({
    required this.command,
    required this.args,
    required this.env,
    this.envMode = 'internal',
    this.stdio = const ['ignore', 'pipe', 'pipe'],
  });

  /// The executable.
  final String command;

  /// Its argument vector.
  final List<String> args;

  /// The complete child environment.
  final Map<String, String> env;

  /// Upstream `envMode: "internal"` — the child gets exactly [env], with no
  /// user-shell augmentation.
  final String envMode;

  /// Upstream `stdio: ["ignore", "pipe", "pipe"]` — stdin closed so a CLI that
  /// prompts fails fast instead of hanging the desktop process.
  final List<String> stdio;

  @override
  bool operator ==(Object other) =>
      other is ExternalCliSpawnRequest &&
      other.command == command &&
      _listEquals(other.args, args) &&
      _mapEquals(other.env, env) &&
      other.envMode == envMode &&
      _listEquals(other.stdio, stdio);

  @override
  int get hashCode => Object.hash(
    command,
    Object.hashAll(args),
    Object.hashAll(env.keys),
    envMode,
    Object.hashAll(stdio),
  );

  @override
  String toString() =>
      'ExternalCliSpawnRequest($command, $args, envMode: $envMode, '
      'stdio: $stdio)';
}

/// The collected result of a finished CLI subprocess.
final class ExternalCliResult {
  const ExternalCliResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  /// Everything written to stdout, concatenated.
  final String stdout;

  /// Everything written to stderr, concatenated.
  final String stderr;

  /// Null when the child was killed by a signal instead of exiting, which
  /// upstream surfaces verbatim in the failure message.
  final int? exitCode;

  @override
  bool operator ==(Object other) =>
      other is ExternalCliResult &&
      other.stdout == stdout &&
      other.stderr == stderr &&
      other.exitCode == exitCode;

  @override
  int get hashCode => Object.hash(stdout, stderr, exitCode);

  @override
  String toString() => 'ExternalCliResult($exitCode, $stdout, $stderr)';
}

/// The process-spawn capability, narrowed to "run this to completion and give
/// me everything it printed".
abstract interface class ExternalCliProcessRunner {
  /// Completes when the child closes. Should complete with an error for a
  /// spawn failure, mirroring upstream's `child.on("error", reject)`.
  Future<ExternalCliResult> spawn(ExternalCliSpawnRequest request);
}

/// Upstream `externalCliFailureMessage`.
///
/// stderr wins when there is any, because a CLI that explained itself is more
/// useful than a numeric code. Otherwise the exit code is reported plus a
/// bounded slice of stdout, since some tools report errors there.
String externalCliFailureMessage({
  required int? exitCode,
  required String stdout,
  required String stderr,
}) {
  if (stderr.isNotEmpty) {
    return stderr;
  }
  return 'CLI command failed with exit code $exitCode'
      '${stdout.isNotEmpty ? '\nstdout: ${_slice(stdout, 200)}' : ''}';
}

/// Upstream `cli/external.ts` — running the CLI as an isolated subprocess and
/// turning its output into a value.
///
/// The desktop process shells out rather than linking the CLI so a CLI crash,
/// a `process.exit`, or a runaway allocation cannot take the window down.
final class ExternalCliCommands {
  const ExternalCliCommands({
    required this.resolveEntrypoint,
    required this.createInvocation,
    required this.processRunner,
    required this.logger,
    required this.baseEnv,
  });

  /// Upstream `resolveExternalCliEntrypoint()` from `cli/entrypoints.ts`,
  /// injected because it is exactly the seam upstream's own suite mocks.
  final NodeEntrypointSpec Function() resolveEntrypoint;

  /// Normally [DesktopDaemonRuntimePaths.createNodeEntrypointInvocation].
  final NodeEntrypointInvocationFactory createInvocation;

  /// Spawns the child.
  final ExternalCliProcessRunner processRunner;

  /// Receives the diagnostic breadcrumbs upstream logs before throwing.
  final DesktopDaemonLaunchLogger logger;

  /// Upstream `process.env`, the base the invocation env is derived from.
  final Map<String, String> baseEnv;

  /// Upstream's log scope string.
  static const String logScope = '[desktop external-cli]';

  /// Upstream `runExternalCliTextCommand`.
  ///
  /// Only the trailing newline is stripped from a success, so leading
  /// indentation in human-readable output survives.
  Future<String> runTextCommand(List<String> args) async {
    final invocation = _createExternalCliInvocation(args);
    final result = await processRunner.spawn(_toSpawnRequest(invocation));

    if (result.exitCode != 0) {
      final stderr = result.stderr.trim();
      final stdout = result.stdout.trim();
      logger.warn(logScope, 'CLI text command failed', {
        'args': args,
        'exitCode': result.exitCode,
        'stdout': _slice(stdout, 500),
        'stderr': _slice(stderr, 500),
      });
      throw DesktopDaemonLaunchException(
        externalCliFailureMessage(
          exitCode: result.exitCode,
          stdout: stdout,
          stderr: stderr,
        ),
      );
    }

    return _trimEnd(result.stdout);
  }

  /// Upstream `runExternalCliJsonCommand`.
  ///
  /// The scan for the first `{` or `[` is deliberate: a CLI may emit banners or
  /// warnings before its JSON payload, and discarding that prefix is cheaper
  /// than teaching every CLI to be silent.
  Future<Object?> runJsonCommand(List<String> args) async {
    final invocation = _createExternalCliInvocation(args);
    final result = await processRunner.spawn(_toSpawnRequest(invocation));

    if (result.exitCode != 0) {
      final stderr = result.stderr.trim();
      final stdout = result.stdout.trim();
      logger.warn(logScope, 'CLI JSON command failed', {
        'args': args,
        'exitCode': result.exitCode,
        'stdout': _slice(stdout, 500),
        'stderr': _slice(stderr, 500),
        'command': invocation.command,
      });
      throw DesktopDaemonLaunchException(
        externalCliFailureMessage(
          exitCode: result.exitCode,
          stdout: stdout,
          stderr: stderr,
        ),
      );
    }

    final stdout = result.stdout.trim();
    if (stdout.isEmpty) {
      logger.warn(logScope, 'CLI command produced no output', {'args': args});
      throw const DesktopDaemonLaunchException(
        'CLI command did not produce JSON output.',
      );
    }

    final jsonStart = _findJsonStart(stdout);
    if (jsonStart < 0) {
      logger.warn(logScope, 'CLI command output contained no JSON', {
        'args': args,
        'stdout': _slice(stdout, 500),
      });
      throw DesktopDaemonLaunchException(
        'CLI command output contained no JSON. '
        'Output: ${_slice(stdout, 200)}',
      );
    }

    try {
      return jsonDecode(stdout.substring(jsonStart));
    } catch (error) {
      // Deviation note: the interpolated text is the Dart decoder's message,
      // not V8's. Only the prefix is a stable contract.
      throw DesktopDaemonLaunchException(
        'CLI command returned invalid JSON: '
        '${error is FormatException ? error.message : error}',
        cause: error,
      );
    }
  }

  NodeEntrypointInvocation _createExternalCliInvocation(List<String> args) =>
      createInvocation(
        entrypoint: resolveEntrypoint(),
        argvMode: NodeEntrypointArgvMode.nodeScript,
        args: args,
        baseEnv: baseEnv,
      );

  ExternalCliSpawnRequest _toSpawnRequest(
    NodeEntrypointInvocation invocation,
  ) => ExternalCliSpawnRequest(
    command: invocation.command,
    args: invocation.args,
    env: invocation.env,
  );
}

// ---------------------------------------------------------------------------
// quit-lifecycle.ts
// ---------------------------------------------------------------------------

/// Upstream `shouldStopDesktopManagedDaemonOnQuit`.
///
/// Reuses this app's own [DesktopSettings] rather than re-declaring the
/// upstream shape. Deviation note: upstream nests the flag as
/// `settings.daemon.keepRunningAfterQuit`; here it is flat. The rule is
/// identical — a daemon is left alive unless the user explicitly opted out, so
/// closing the window never kills work in flight.
bool shouldStopDesktopManagedDaemonOnQuit(DesktopSettings settings) =>
    !settings.keepRunningAfterQuit;

/// Upstream's `isDesktopManagedDaemonRunning: () => boolean` dependency,
/// expressed against this repo's [DaemonStatus].
///
/// Reuse note: this is the same predicate
/// `paseo_desktop_daemon_rules.dart`'s management toggle applies before
/// stopping the daemon — a daemon the user started by hand is not ours to kill,
/// whether the trigger is a settings toggle or an app quit.
bool isDesktopManagedDaemonRunning(DaemonStatus? status) =>
    status != null &&
    status.isRunning &&
    (status.hello?.desktopManaged ?? false);

/// Upstream `StopOnQuitDeps`.
final class StopOnQuitPorts {
  const StopOnQuitPorts({
    required this.readSettings,
    required this.isDesktopManagedDaemonRunning,
    required this.stopDaemon,
    required this.showShutdownFeedback,
  });

  /// Upstream `settingsStore.get()`.
  final Future<DesktopSettings> Function() readSettings;

  /// Whether there is a daemon this app owns and may stop; typically
  /// `() => isDesktopManagedDaemonRunning(currentStatus)`.
  final bool Function() isDesktopManagedDaemonRunning;

  /// Performs the stop.
  final Future<void> Function() stopDaemon;

  /// Shows the user *before* the stop begins, because a daemon shutdown can
  /// outlast the window and an app that vanishes mid-shutdown looks hung.
  final void Function() showShutdownFeedback;
}

/// Upstream `stopDesktopManagedDaemonOnQuitIfNeeded`.
///
/// Returns whether a stop was actually performed. Both guards short-circuit
/// before any effect runs: the setting is consulted first so a keep-running
/// user never even has the daemon inspected.
Future<bool> stopDesktopManagedDaemonOnQuitIfNeeded(
  StopOnQuitPorts ports,
) async {
  final settings = await ports.readSettings();
  if (!shouldStopDesktopManagedDaemonOnQuit(settings)) {
    return false;
  }

  if (!ports.isDesktopManagedDaemonRunning()) {
    return false;
  }

  ports.showShutdownFeedback();
  await ports.stopDaemon();
  return true;
}

/// Upstream's `AbortSignal`, narrowed to what the quit rules read.
abstract interface class QuitDeadlineSignal {
  /// Upstream `signal.aborted`.
  bool get isAborted;

  /// Completes when the deadline fires. Never completes with an error, and may
  /// never complete at all if the deadline is never reached.
  Future<void> get onAbort;
}

/// Upstream's `AbortController`, as a concrete signal source.
final class QuitDeadlineController implements QuitDeadlineSignal {
  QuitDeadlineController();

  final _completer = Completer<void>();

  @override
  bool get isAborted => _completer.isCompleted;

  @override
  Future<void> get onAbort => _completer.future;

  /// Fires the deadline. Idempotent, matching `AbortController.abort()`.
  void abort() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// Upstream's `event.preventDefault()`.
typedef PreventQuitDefault = void Function();

/// Upstream `createQuitLifecycle`'s dependency bag.
final class QuitLifecyclePorts {
  const QuitLifecyclePorts({
    required this.exitApp,
    required this.closeTransportSessions,
    required this.stopDesktopManagedDaemonIfNeeded,
    required this.installAppUpdateOnQuit,
    required this.createUpdateDeadlineSignal,
    required this.onStopError,
    required this.onUpdateError,
  });

  /// Upstream `app.exit(code)` — the hard exit that bypasses Electron's
  /// `window-all-closed` veto.
  final void Function(int code) exitApp;

  /// Runs on *every* quit attempt, before any branching: sockets should not
  /// outlive a user-visible quit even if the quit is later intercepted.
  final void Function() closeTransportSessions;

  /// Normally wraps [stopDesktopManagedDaemonOnQuitIfNeeded].
  final Future<bool> Function() stopDesktopManagedDaemonIfNeeded;

  /// Resolves true when a validated update has begun installing and will own
  /// process exit itself.
  final Future<bool> Function(QuitDeadlineSignal signal) installAppUpdateOnQuit;

  /// Called once per bounded wait — first for update revalidation, then again
  /// for the handoff — so each gets its own budget.
  final QuitDeadlineSignal Function() createUpdateDeadlineSignal;

  /// A failed daemon stop must not block the quit.
  final void Function(Object error) onStopError;

  /// A failed update check must not block the quit either.
  final void Function(Object error) onUpdateError;
}

/// Upstream `QuitLifecycle`.
abstract interface class QuitLifecycle {
  /// Upstream Electron `before-quit`.
  void handleBeforeQuit({required PreventQuitDefault preventDefault});

  /// Upstream Electron `before-quit-for-update`.
  void handleBeforeQuitForUpdate();
}

/// Upstream `createQuitLifecycle`.
///
/// The sequencing exists because two parties want to own process exit. The
/// first quit is intercepted so the daemon can shut down cleanly and the
/// updater can revalidate; if no update is installing, the app forces its own
/// exit. If one *is* installing, the app waits — bounded — for evidence the
/// updater has taken over, and only forces the exit when that evidence never
/// arrives. The evidence is either a `before-quit-for-update` event or a second
/// `before-quit`, because `MacUpdater`'s no-relaunch path re-fires plain
/// `app.quit()` without emitting the update-specific event.
QuitLifecycle createQuitLifecycle(QuitLifecyclePorts ports) =>
    _QuitLifecycle(ports);

final class _QuitLifecycle implements QuitLifecycle {
  _QuitLifecycle(this._ports);

  final QuitLifecyclePorts _ports;

  bool _quitting = false;
  bool _quittingForUpdate = false;
  final Completer<bool> _updateQuit = Completer<bool>();

  /// Deviation note: JS promise resolution is idempotent, while completing a
  /// Dart [Completer] twice throws. Repeated handoff evidence is normal (a
  /// second quit followed by `before-quit-for-update`), so it is guarded.
  void _resolveUpdateQuit() {
    if (!_updateQuit.isCompleted) _updateQuit.complete(true);
  }

  @override
  void handleBeforeQuit({required PreventQuitDefault preventDefault}) {
    _ports.closeTransportSessions();
    if (_quittingForUpdate) return;
    if (_quitting) {
      _resolveUpdateQuit();
      return;
    }
    _quitting = true;
    preventDefault();

    // Fire-and-forget, exactly like upstream's `void (async () => {...})()`:
    // the body runs synchronously to its first await, so the caller returns
    // having only observed the transport close and the preventDefault.
    _runQuitSequence();
  }

  @override
  void handleBeforeQuitForUpdate() {
    _quittingForUpdate = true;
    _resolveUpdateQuit();
  }

  Future<void> _runQuitSequence() async {
    try {
      await _ports.stopDesktopManagedDaemonIfNeeded();
    } catch (error) {
      _ports.onStopError(error);
    }

    final signal = _ports.createUpdateDeadlineSignal();
    final updateInstallation = _ports
        .installAppUpdateOnQuit(signal)
        .then<bool>(
          (installing) => installing,
          onError: (Object error) {
            _ports.onUpdateError(error);
            return false;
          },
        );
    final installingUpdate = await Future.any([
      updateInstallation,
      _waitForUpdateDeadline(signal),
    ]);

    if (installingUpdate) {
      final handoffStarted = await Future.any([
        _updateQuit.future,
        _waitForUpdateDeadline(_ports.createUpdateDeadlineSignal()),
      ]);
      if (handoffStarted) {
        return;
      }
    }

    _ports.exitApp(0);
  }
}

/// Upstream `waitForUpdateDeadline` — resolves false when the deadline fires,
/// and never resolves otherwise, so it can only lose a race it should lose.
Future<bool> _waitForUpdateDeadline(QuitDeadlineSignal signal) {
  if (signal.isAborted) {
    return Future<bool>.value(false);
  }
  return signal.onAbort.then((_) => false);
}

// ---------------------------------------------------------------------------
// Local helpers
// ---------------------------------------------------------------------------

/// JS `String.prototype.slice(0, n)`, which clamps instead of throwing.
String _slice(String value, int length) =>
    value.length <= length ? value : value.substring(0, length);

/// JS `String.prototype.trimEnd()`.
String _trimEnd(String value) => value.replaceFirst(RegExp(r'\s+$'), '');

/// JS `stdout.search(/[{[]/)`.
int _findJsonStart(String value) {
  for (var index = 0; index < value.length; index++) {
    final character = value[index];
    if (character == '{' || character == '[') return index;
  }
  return -1;
}

bool _listEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}
