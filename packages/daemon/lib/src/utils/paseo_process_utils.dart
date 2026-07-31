/// Process, shell, hostname and tool-call utilities ported from Paseo 0.2.0
/// (`packages/server/src/utils/{tree-kill,spawn,string-command-shell,
/// script-hostname,tool-call-parsers}.ts`).
///
/// The upstream cluster is a grab-bag of small helpers that every process
/// launch path in the server shares. They are grouped into one Dart library so
/// the port stays a single reviewable parity surface, and because Dart has no
/// equivalent of the TypeScript barrel re-exports that tied them together.
///
/// Reuse note: this library deliberately does **not** re-declare helpers the
/// daemon already owns. It delegates to
/// `providers/paseo/executable_resolver.dart` for Windows quoting,
/// `providers/paseo/provider_launch_config.dart` for the runtime-control env
/// key set, `workspace/service_proxy_names.dart` for hostname construction and
/// `package:agent_protocol` for `stripCwdPrefix`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:path/path.dart' as p;

import '../providers/paseo/executable_resolver.dart'
    show quoteWindowsArgument, quoteWindowsCommand;
import '../providers/paseo/provider_launch_config.dart'
    show externalRuntimeControlEnvironmentVariables;
import '../workspace/service_proxy_names.dart' as service_proxy;

/// Re-exported so callers of this library get the same surface upstream's
/// `tool-call-parsers.ts` exposed via `export { stripCwdPrefix }`.
export 'package:agent_protocol/agent_protocol.dart' show stripCwdPrefix;

// ---------------------------------------------------------------------------
// tree-kill.ts
// ---------------------------------------------------------------------------

/// Outcome of [terminateWithTreeKill], mirroring upstream's string union
/// `"already-exited" | "terminated" | "killed" | "kill-timeout"`.
enum TerminateWithTreeKillResult {
  /// The child had already reported an exit code (or signal) before we started.
  alreadyExited,

  /// The child exited within the graceful window after the graceful signal.
  terminated,

  /// The force signal was sent. When no force timeout was requested this is
  /// reported optimistically without waiting, exactly as upstream does.
  killed,

  /// The force signal was sent and the child still had not exited when the
  /// force timeout elapsed.
  killTimeout,
}

/// The subset of a child process [terminateWithTreeKill] needs.
///
/// Upstream models this as a structural interface so tests can pass a plain
/// object. Dart has no structural typing, so this is an explicit interface with
/// [ProcessTreeKillTarget] adapting a real `dart:io` [Process].
abstract interface class TreeKillTarget {
  /// OS process id, or `null`/non-positive when the child never launched.
  int? get pid;

  /// Exit code once observed, otherwise `null`.
  ///
  /// Deviation: `dart:io` only exposes `Process.exitCode` as a future, so
  /// implementations must latch the value the way [ProcessTreeKillTarget] does.
  int? get exitCode;

  /// Name of the signal that killed the child, otherwise `null`.
  ///
  /// Deviation: `dart:io` never reports this, so [ProcessTreeKillTarget] always
  /// returns `null`. The field is retained because upstream treats a non-null
  /// signal code as "already exited" and fakes still exercise that branch.
  String? get signalCode;

  /// Completes when the child exits, or `null` when the target cannot report
  /// exit at all.
  ///
  /// Upstream's optional `once("exit")` hook has the same meaning: when it is
  /// absent the wait never resolves and only the timeout can end the race.
  Future<void>? get exited;

  /// Sends [signal] directly to this process (not its descendants).
  bool kill(ProcessSignal signal);
}

/// Adapts a `dart:io` [Process] to [TreeKillTarget].
///
/// Constructing this latches the exit code as soon as the process reports one,
/// which is what makes the synchronous [exitCode] getter possible.
final class ProcessTreeKillTarget implements TreeKillTarget {
  ProcessTreeKillTarget(this.process) {
    exited = process.exitCode.then((code) {
      _exitCode = code;
    });
  }

  /// The wrapped process.
  final Process process;

  int? _exitCode;

  @override
  late final Future<void> exited;

  @override
  int? get pid => process.pid;

  @override
  int? get exitCode => _exitCode;

  @override
  String? get signalCode => null;

  @override
  bool kill(ProcessSignal signal) => process.kill(signal);
}

/// Sends [signal] to the whole process tree rooted at [pid].
///
/// Returns `null` on success or an error object on failure; the error shape is
/// opaque because upstream only ever checks truthiness of the `tree-kill`
/// callback argument before falling back to a direct child kill.
typedef ProcessTreeSignaller =
    Future<Object?> Function(int pid, ProcessSignal signal);

/// Runs a helper command (`taskkill`, `pgrep`) for process-tree discovery.
///
/// Injected so the tree-kill strategy can be unit tested without spawning.
typedef ProcessResultRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Sends a signal to a single pid. Defaults to [Process.killPid].
typedef ProcessKiller = bool Function(int pid, ProcessSignal signal);

/// Options for [terminateWithTreeKill].
final class TerminateWithTreeKillOptions {
  const TerminateWithTreeKillOptions({
    this.gracefulSignal = ProcessSignal.sigterm,
    this.forceSignal = ProcessSignal.sigkill,
    required this.gracefulTimeout,
    this.forceTimeout,
    this.onForceSignal,
  });

  /// Signal sent first. Upstream defaults to `SIGTERM`.
  final ProcessSignal gracefulSignal;

  /// Signal sent after [gracefulTimeout] elapses. Upstream defaults to
  /// `SIGKILL`.
  final ProcessSignal forceSignal;

  /// How long to wait for a graceful exit before escalating.
  final Duration gracefulTimeout;

  /// How long to wait after escalating. When `null`, [terminateWithTreeKill]
  /// returns [TerminateWithTreeKillResult.killed] without waiting, matching
  /// upstream's `forceTimeoutMs === undefined` early return.
  final Duration? forceTimeout;

  /// Invoked immediately before the force signal is sent, so callers can log
  /// the escalation.
  final void Function()? onForceSignal;
}

/// Injection seam: production wires [terminateWithTreeKill]; tests wire a fake
/// that records which children were terminated as observable state.
typedef ProcessTerminator =
    Future<TerminateWithTreeKillResult> Function(
      TreeKillTarget child,
      TerminateWithTreeKillOptions options,
    );

/// Terminates [child] and every descendant, escalating from the graceful to the
/// force signal.
///
/// The tree walk is delegated to [signalTree] (defaulting to
/// [signalSystemProcessTree]) so callers can substitute a fake. When the tree
/// walk fails, the signal is sent directly to [child] instead — the same
/// fallback upstream applies when the `tree-kill` callback reports an error.
Future<TerminateWithTreeKillResult> terminateWithTreeKill(
  TreeKillTarget child,
  TerminateWithTreeKillOptions options, {
  ProcessTreeSignaller? signalTree,
}) async {
  if (_isProcessExited(child)) {
    return TerminateWithTreeKillResult.alreadyExited;
  }

  final signaller = signalTree ?? signalSystemProcessTree;
  final exited = _waitForProcessExit(child);
  await _signalTreeOrChild(child, options.gracefulSignal, signaller);
  if (await _waitForExitOrTimeout(exited, options.gracefulTimeout)) {
    return TerminateWithTreeKillResult.terminated;
  }

  options.onForceSignal?.call();
  await _signalTreeOrChild(child, options.forceSignal, signaller);
  final forceTimeout = options.forceTimeout;
  if (forceTimeout == null) {
    return TerminateWithTreeKillResult.killed;
  }
  return await _waitForExitOrTimeout(exited, forceTimeout)
      ? TerminateWithTreeKillResult.killed
      : TerminateWithTreeKillResult.killTimeout;
}

/// Default [ProcessTreeSignaller], replacing the npm `tree-kill` dependency.
///
/// On Windows this shells out to `taskkill /pid <pid> /T /F`, which is what
/// `tree-kill` does — and why a Windows "graceful" termination is already
/// forceful and normally reports [TerminateWithTreeKillResult.terminated].
///
/// On POSIX the descendant set is discovered with `pgrep -P` and each pid is
/// signalled leaf-first. Deviation: upstream's `tree-kill` uses `ps --ppid` on
/// Linux and `pgrep -P` on macOS; `pgrep -P` is used for both here because it
/// is available on every POSIX platform the daemon supports and produces the
/// same child list.
Future<Object?> signalSystemProcessTree(
  int pid,
  ProcessSignal signal, {
  bool? isWindows,
  ProcessResultRunner? run,
  ProcessKiller? killPid,
}) async {
  final windows = isWindows ?? Platform.isWindows;
  final runner = run ?? _runProcess;
  final kill = killPid ?? Process.killPid;

  try {
    if (windows) {
      final result = await runner('taskkill', ['/pid', '$pid', '/T', '/F']);
      if (result.exitCode != 0) {
        return 'taskkill exited with ${result.exitCode}: ${result.stderr}';
      }
      return null;
    }

    final pids = await _collectDescendantPids(pid, runner);
    // Leaf-first so a supervisor cannot respawn a child we already signalled.
    for (final target in pids.reversed) {
      kill(target, signal);
    }
    return null;
  } on Object catch (error) {
    return error;
  }
}

Future<ProcessResult> _runProcess(String executable, List<String> arguments) =>
    Process.run(executable, arguments);

Future<List<int>> _collectDescendantPids(
  int root,
  ProcessResultRunner run,
) async {
  final ordered = <int>[root];
  final seen = <int>{root};
  for (var index = 0; index < ordered.length; index++) {
    final result = await run('pgrep', ['-P', '${ordered[index]}']);
    // pgrep exits 1 when there are simply no children; that is not an error.
    if (result.exitCode != 0 && result.exitCode != 1) {
      throw ProcessException(
        'pgrep',
        ['-P', '${ordered[index]}'],
        '${result.stderr}',
        result.exitCode,
      );
    }
    for (final line in '${result.stdout}'.split('\n')) {
      final value = int.tryParse(line.trim());
      if (value != null && value > 0 && seen.add(value)) {
        ordered.add(value);
      }
    }
  }
  return ordered;
}

Future<void> _signalTreeOrChild(
  TreeKillTarget child,
  ProcessSignal signal,
  ProcessTreeSignaller signalTree,
) async {
  if (_isProcessExited(child)) return;

  final pid = child.pid;
  if (pid == null || pid <= 0) {
    _signalDirectChild(child, signal);
    return;
  }

  final error = await signalTree(pid, signal);
  if (error != null) {
    _signalDirectChild(child, signal);
  }
}

void _signalDirectChild(TreeKillTarget child, ProcessSignal signal) {
  try {
    child.kill(signal);
  } on Object {
    // Ignore cleanup races.
  }
}

bool _isProcessExited(TreeKillTarget child) =>
    child.exitCode != null || child.signalCode != null;

Future<void> _waitForProcessExit(TreeKillTarget child) {
  if (_isProcessExited(child)) return Future<void>.value();
  // A target without an exit future can never resolve, so only the timeout ends
  // the race — the same as upstream's missing `once` hook.
  return child.exited ?? Completer<void>().future;
}

Future<bool> _waitForExitOrTimeout(
  Future<void> exited,
  Duration timeout,
) async {
  final completer = Completer<bool>();
  final timer = Timer(timeout, () {
    if (!completer.isCompleted) completer.complete(false);
  });
  unawaited(
    exited.then(
      (_) {
        if (!completer.isCompleted) completer.complete(true);
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(true);
      },
    ),
  );
  try {
    return await completer.future;
  } finally {
    timer.cancel();
  }
}

// ---------------------------------------------------------------------------
// spawn.ts
// ---------------------------------------------------------------------------

/// Whether a child inherits Paseo's own runtime-control variables.
enum ProcessEnvironmentMode {
  /// Strip runtime-control variables — the default for third-party commands.
  external,

  /// Keep the launcher-owned variables, for processes Paseo itself supervises.
  internal,
}

/// A fully resolved launch: what is actually handed to the process host.
final class ResolvedProcessLaunch {
  const ResolvedProcessLaunch({
    required this.command,
    required this.arguments,
    required this.runInShell,
    required this.environment,
    this.workingDirectory,
  });

  /// Executable, resolved but *not* shell-quoted. See
  /// [buildWindowsShellCommandLine] for why.
  final String command;

  /// Arguments, resolved but not shell-quoted.
  final List<String> arguments;

  /// Whether the command must be routed through the platform shell.
  final bool runInShell;

  /// The complete child environment. Callers pass
  /// `includeParentEnvironment: false` so this fully replaces the parent env,
  /// matching Node's `spawn(..., { env })` semantics.
  final Map<String, String> environment;

  /// Working directory, or `null` to inherit.
  final String? workingDirectory;
}

/// Narrow seam over the process-launching primitive.
///
/// Only [start] is abstracted; `execCommand` is layered on top of it so that
/// timeout, output capping and exit-code handling stay in ported Dart code
/// rather than being delegated to a platform API with different semantics.
abstract interface class ProcessHost {
  /// Starts [launch] and returns the running process.
  Future<Process> start(
    ResolvedProcessLaunch launch, {
    ProcessStartMode mode = ProcessStartMode.normal,
  });
}

/// The real `dart:io` implementation of [ProcessHost].
final class SystemProcessHost implements ProcessHost {
  const SystemProcessHost();

  @override
  Future<Process> start(
    ResolvedProcessLaunch launch, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => Process.start(
    launch.command,
    launch.arguments,
    workingDirectory: launch.workingDirectory,
    environment: launch.environment,
    includeParentEnvironment: false,
    runInShell: launch.runInShell,
    mode: mode,
  );
}

/// Options for [spawnProcess].
final class SpawnProcessOptions {
  const SpawnProcessOptions({
    this.workingDirectory,
    this.baseEnvironment,
    this.environment,
    this.environmentOverlay,
    this.environmentMode = ProcessEnvironmentMode.external,
    this.runInShell,
    this.mode = ProcessStartMode.normal,
  });

  /// Working directory for the child.
  final String? workingDirectory;

  /// Fallback base environment, used when [environment] is `null`.
  final Map<String, String?>? baseEnvironment;

  /// Replacement base environment. Takes precedence over [baseEnvironment];
  /// when both are `null` the current process environment is used.
  final Map<String, String?>? environment;

  /// Applied on top of the resolved base. A `null` value unsets the key.
  final Map<String, String?>? environmentOverlay;

  /// Whether runtime-control variables survive into the child.
  final ProcessEnvironmentMode environmentMode;

  /// Explicit shell request. `null` means "decide from the command", matching
  /// upstream's `shell === undefined` branch.
  final bool? runInShell;

  /// How stdio is wired up. No upstream analogue; Node's `stdio` option is
  /// expressed differently and `windowsHide` has no Dart equivalent at all.
  final ProcessStartMode mode;
}

/// Options for [execCommand].
final class ExecCommandOptions {
  const ExecCommandOptions({
    this.workingDirectory,
    this.baseEnvironment,
    this.environment,
    this.environmentOverlay,
    this.environmentMode = ProcessEnvironmentMode.external,
    this.runInShell,
    this.encoding = utf8,
    this.killSignal = ProcessSignal.sigterm,
    this.timeout,
    this.maxBuffer = defaultExecCommandMaxBuffer,
  });

  /// Working directory for the child.
  final String? workingDirectory;

  /// Fallback base environment, used when [environment] is `null`.
  final Map<String, String?>? baseEnvironment;

  /// Replacement base environment.
  final Map<String, String?>? environment;

  /// Applied on top of the resolved base. A `null` value unsets the key.
  final Map<String, String?>? environmentOverlay;

  /// Whether runtime-control variables survive into the child.
  final ProcessEnvironmentMode environmentMode;

  /// Explicit shell request; `null` decides from the command.
  final bool? runInShell;

  /// Decoder for stdout and stderr. Upstream defaults to `utf8`.
  final Encoding encoding;

  /// Signal used when [timeout] elapses. Upstream defaults to `SIGTERM`.
  final ProcessSignal killSignal;

  /// Wall-clock limit; `null` means no limit.
  final Duration? timeout;

  /// Per-stream byte cap. Exceeding it kills the child and throws, matching
  /// Node's `ERR_CHILD_PROCESS_STDIO_MAXBUFFER`.
  final int maxBuffer;
}

/// Node's `execFile` default `maxBuffer`, retained for parity.
const int defaultExecCommandMaxBuffer = 1024 * 1024;

/// Captured output of a successful [execCommand].
final class ExecCommandResult {
  const ExecCommandResult({required this.stdout, required this.stderr});

  /// Decoded standard output.
  final String stdout;

  /// Decoded standard error.
  final String stderr;
}

/// Thrown when [execCommand] fails, times out, or overflows its output cap.
///
/// Upstream rejects with Node's `ExecFileException`, which carries the same
/// four observable fields (`code`, `stdout`, `stderr`, `killed`).
final class ExecCommandException implements Exception {
  const ExecCommandException({
    required this.command,
    required this.arguments,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
    this.reason,
  });

  /// Executable that failed.
  final String command;

  /// Arguments it was given.
  final List<String> arguments;

  /// Exit code, or `null` when the child never reported one.
  final int? exitCode;

  /// Output captured before the failure.
  final String stdout;

  /// Error output captured before the failure.
  final String stderr;

  /// Whether the failure was caused by the [ExecCommandOptions.timeout].
  final bool timedOut;

  /// Extra explanation (output cap exceeded, spawn failure, …).
  final String? reason;

  @override
  String toString() {
    final suffix = reason == null ? '' : ' ($reason)';
    return 'ExecCommandException: $command ${arguments.join(' ')} '
        'exited with $exitCode$suffix\n$stderr';
  }
}

/// Whether [executablePath] is a Windows batch script that cannot be launched
/// without a shell.
bool isWindowsCommandScript(String executablePath, {bool? isWindows}) {
  final windows = isWindows ?? Platform.isWindows;
  if (!windows) return false;
  final extension = p.windows.extension(executablePath).toLowerCase();
  return extension == '.cmd' || extension == '.bat';
}

/// Decides whether a launch has to go through the platform shell.
///
/// Deviation: upstream's return type is `boolean | string` because Node lets a
/// caller name a specific shell binary. Dart's `runInShell` is a plain flag, so
/// [requestedShell] is a `bool?` and callers that need a specific shell build
/// the invocation explicitly with [buildStringCommandShellInvocation].
bool shouldUseWindowsShell(
  String command, {
  bool? requestedShell,
  bool? isWindows,
}) {
  final windows = isWindows ?? Platform.isWindows;
  if (isWindowsCommandScript(command, isWindows: windows)) return true;
  if (requestedShell != null) return requestedShell;
  return windows &&
      !_hasPathSeparator(command) &&
      p.windows.extension(command).isEmpty;
}

bool _hasPathSeparator(String value) =>
    value.contains('/') || value.contains(r'\');

/// Builds the environment for a third-party command.
///
/// Runtime-control variables are dropped so a child never inherits the flags
/// that tell Paseo's own binaries how to behave. The key set is reused from
/// `provider_launch_config.dart` rather than re-declared; it is a superset of
/// upstream's list because this repo also carries `TINYRACK_*` aliases for the
/// renamed `PASEO_*` variables.
Map<String, String> createExternalProcessEnvironment({
  Map<String, String?>? baseEnvironment,
  List<Map<String, String?>?> overlays = const [],
}) {
  final merged = <String, String?>{...?baseEnvironment};
  for (final overlay in overlays) {
    if (overlay != null) merged.addAll(overlay);
  }
  for (final key in externalRuntimeControlEnvironmentVariables) {
    merged.remove(key);
  }
  merged.removeWhere((_, value) => value == null);
  return Map.unmodifiable(merged.cast<String, String>());
}

/// Builds the environment for a Paseo-owned child, preserving the launcher's
/// runtime-control variables.
///
/// Deviation: upstream keeps `undefined` entries in the object and lets Node
/// drop them at spawn time; Dart's `Process.start` would reject a null value,
/// so unset keys are removed here. The child sees the same environment either
/// way.
Map<String, String> createInternalProcessEnvironment({
  Map<String, String?>? baseEnvironment,
  List<Map<String, String?>?> overlays = const [],
}) {
  final merged = <String, String?>{...?baseEnvironment};
  for (final overlay in overlays) {
    if (overlay != null) merged.addAll(overlay);
  }
  merged.removeWhere((_, value) => value == null);
  return Map.unmodifiable(merged.cast<String, String>());
}

/// Resolves a command, its arguments and its environment into a launch plan.
///
/// This is the pure half of [spawnProcess]/[execCommand]: everything upstream
/// computes before calling `spawn`/`execFile`, with no I/O, so it can be
/// asserted directly in tests.
ResolvedProcessLaunch resolveProcessLaunch({
  required String command,
  required List<String> arguments,
  String? workingDirectory,
  Map<String, String?>? baseEnvironment,
  Map<String, String?>? environment,
  Map<String, String?>? environmentOverlay,
  ProcessEnvironmentMode environmentMode = ProcessEnvironmentMode.external,
  bool? runInShell,
  bool? isWindows,
  Map<String, String>? platformEnvironment,
}) {
  final windows = isWindows ?? Platform.isWindows;
  final resolvedBase =
      environment ?? baseEnvironment ?? platformEnvironment ?? _platformEnv();
  final overlays = <Map<String, String?>?>[environmentOverlay];
  final childEnvironment = environmentMode == ProcessEnvironmentMode.internal
      ? createInternalProcessEnvironment(
          baseEnvironment: resolvedBase,
          overlays: overlays,
        )
      : createExternalProcessEnvironment(
          baseEnvironment: resolvedBase,
          overlays: overlays,
        );

  return ResolvedProcessLaunch(
    // Deviation: upstream also runs the command and every argument through
    // `quoteWindowsCommand`/`quoteWindowsArgument` here, because Node hands
    // `cmd.exe` a single pre-joined command line. `dart:io` builds the Windows
    // command line itself (MSVCRT quoting of every argument), so quoting here
    // would double-escape. Callers that assemble a raw Windows command line
    // themselves use [buildWindowsShellCommandLine] instead.
    command: command,
    arguments: List.unmodifiable(arguments),
    runInShell: shouldUseWindowsShell(
      command,
      requestedShell: runInShell,
      isWindows: windows,
    ),
    environment: childEnvironment,
    workingDirectory: workingDirectory,
  );
}

Map<String, String?> _platformEnv() =>
    Map<String, String?>.from(Platform.environment);

/// Joins [command] and [arguments] into a `cmd.exe`-safe command line using the
/// daemon's existing Windows quoting helpers.
///
/// This preserves upstream's `quoteWindowsCommand` + `quoteWindowsArgument`
/// behavior for the one case where it is still correct: building a command-line
/// string by hand (ConPTY, `cmd /d /s /c "<line>"`) rather than handing an argv
/// list to `dart:io`.
String buildWindowsShellCommandLine(
  String command,
  List<String> arguments, {
  bool? isWindows,
}) {
  final windows = isWindows ?? Platform.isWindows;
  return [
    quoteWindowsCommand(command, isWindows: windows),
    for (final argument in arguments)
      quoteWindowsArgument(argument, isWindows: windows),
  ].join(' ');
}

/// Starts [command] with the resolved environment and shell decision.
Future<Process> spawnProcess(
  String command,
  List<String> arguments, {
  SpawnProcessOptions? options,
  ProcessHost host = const SystemProcessHost(),
  bool? isWindows,
  Map<String, String>? platformEnvironment,
}) {
  final resolved = options ?? const SpawnProcessOptions();
  final launch = resolveProcessLaunch(
    command: command,
    arguments: arguments,
    workingDirectory: resolved.workingDirectory,
    baseEnvironment: resolved.baseEnvironment,
    environment: resolved.environment,
    environmentOverlay: resolved.environmentOverlay,
    environmentMode: resolved.environmentMode,
    runInShell: resolved.runInShell,
    isWindows: isWindows,
    platformEnvironment: platformEnvironment,
  );
  return host.start(launch, mode: resolved.mode);
}

/// Runs [command] to completion and returns its captured output.
///
/// Throws [ExecCommandException] when the child exits non-zero, when the
/// timeout elapses, or when either stream exceeds
/// [ExecCommandOptions.maxBuffer] — the three ways Node's `execFile` rejects.
Future<ExecCommandResult> execCommand(
  String command,
  List<String> arguments, {
  ExecCommandOptions? options,
  ProcessHost host = const SystemProcessHost(),
  bool? isWindows,
  Map<String, String>? platformEnvironment,
}) async {
  final resolved = options ?? const ExecCommandOptions();
  final launch = resolveProcessLaunch(
    command: command,
    arguments: arguments,
    workingDirectory: resolved.workingDirectory,
    baseEnvironment: resolved.baseEnvironment,
    environment: resolved.environment,
    environmentOverlay: resolved.environmentOverlay,
    environmentMode: resolved.environmentMode,
    runInShell: resolved.runInShell,
    isWindows: isWindows,
    platformEnvironment: platformEnvironment,
  );

  final Process process;
  try {
    process = await host.start(launch);
  } on ProcessException catch (error) {
    throw ExecCommandException(
      command: command,
      arguments: arguments,
      exitCode: null,
      stdout: '',
      stderr: '',
      reason: error.message,
    );
  }

  final stdoutSink = _BoundedOutput(resolved.maxBuffer);
  final stderrSink = _BoundedOutput(resolved.maxBuffer);
  var overflowed = false;
  var timedOut = false;

  void killChild() {
    try {
      process.kill(resolved.killSignal);
    } on Object {
      // Ignore cleanup races.
    }
  }

  final stdoutDone = process.stdout.listen((chunk) {
    if (!stdoutSink.add(chunk) && !overflowed) {
      overflowed = true;
      killChild();
    }
  }).asFuture<void>();
  final stderrDone = process.stderr.listen((chunk) {
    if (!stderrSink.add(chunk) && !overflowed) {
      overflowed = true;
      killChild();
    }
  }).asFuture<void>();
  unawaited(process.stdin.close().catchError((_) {}));

  Timer? timer;
  final timeout = resolved.timeout;
  if (timeout != null) {
    timer = Timer(timeout, () {
      timedOut = true;
      killChild();
    });
  }

  final int exitCode;
  try {
    exitCode = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
  } finally {
    timer?.cancel();
  }

  final out = stdoutSink.decode(resolved.encoding);
  final err = stderrSink.decode(resolved.encoding);

  if (timedOut) {
    throw ExecCommandException(
      command: command,
      arguments: arguments,
      exitCode: exitCode,
      stdout: out,
      stderr: err,
      timedOut: true,
      reason: 'timed out after ${timeout!.inMilliseconds}ms',
    );
  }
  if (overflowed) {
    throw ExecCommandException(
      command: command,
      arguments: arguments,
      exitCode: exitCode,
      stdout: out,
      stderr: err,
      reason: 'output exceeded maxBuffer of ${resolved.maxBuffer} bytes',
    );
  }
  if (exitCode != 0) {
    throw ExecCommandException(
      command: command,
      arguments: arguments,
      exitCode: exitCode,
      stdout: out,
      stderr: err,
    );
  }
  return ExecCommandResult(stdout: out, stderr: err);
}

final class _BoundedOutput {
  _BoundedOutput(this.limit);

  final int limit;
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  /// Returns `false` once the limit is exceeded.
  bool add(List<int> chunk) {
    if (_bytes.length >= limit) return false;
    final remaining = limit - _bytes.length;
    if (chunk.length <= remaining) {
      _bytes.add(chunk);
      return true;
    }
    _bytes.add(chunk.sublist(0, remaining));
    return false;
  }

  String decode(Encoding encoding) {
    final bytes = _bytes.toBytes();
    if (encoding is Utf8Codec) {
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    }
    return encoding.decode(bytes);
  }
}

// ---------------------------------------------------------------------------
// string-command-shell.ts
// ---------------------------------------------------------------------------

/// Which Windows shell interprets a project-authored command string.
enum StringCommandWindowsShell {
  /// `powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command`.
  powershell,

  /// `cmd.exe /c`.
  cmd,
}

/// A shell plus the argument vector that makes it run one command string.
final class StringCommandShellInvocation {
  const StringCommandShellInvocation({required this.shell, required this.args});

  /// Shell executable name.
  final String shell;

  /// Arguments, ending with the command string itself.
  final List<String> args;

  @override
  bool operator ==(Object other) =>
      other is StringCommandShellInvocation &&
      other.shell == shell &&
      _listEquals(other.args, args);

  @override
  int get hashCode => Object.hash(shell, Object.hashAll(args));

  @override
  String toString() =>
      'StringCommandShellInvocation(shell: $shell, args: $args)';
}

bool _listEquals(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// Strips `BASH_ENV` from [environment].
///
/// A project-authored command string runs in a stable script shell; a
/// `BASH_ENV` startup file would otherwise rewrite the `PATH` the caller
/// carefully supplied.
Map<String, String> createStringCommandShellEnv(
  Map<String, String> environment,
) {
  final sanitized = Map<String, String>.from(environment)..remove('BASH_ENV');
  return sanitized;
}

/// Overlay form of [createStringCommandShellEnv], for callers that merge
/// overlays instead of replacing the whole environment.
///
/// The `null` value means "unset", matching upstream's `{ BASH_ENV: undefined }`
/// and the convention used by [createExternalProcessEnvironment].
Map<String, String?> createStringCommandShellEnvOverlay() => {'BASH_ENV': null};

/// Builds the shell invocation for a project-authored command string.
///
/// Deviation: upstream takes a `NodeJS.Platform` string; only `win32` is ever
/// distinguished, so this takes `isWindows` instead — the same convention the
/// daemon already uses for `quoteWindowsCommand`.
StringCommandShellInvocation buildStringCommandShellInvocation({
  required String command,
  bool? isWindows,
  StringCommandWindowsShell windowsShell = StringCommandWindowsShell.powershell,
}) {
  final windows = isWindows ?? Platform.isWindows;
  if (!windows) {
    return StringCommandShellInvocation(shell: 'bash', args: ['-c', command]);
  }
  if (windowsShell == StringCommandWindowsShell.cmd) {
    return StringCommandShellInvocation(
      shell: 'cmd.exe',
      args: ['/c', command],
    );
  }
  return StringCommandShellInvocation(
    shell: 'powershell',
    args: [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      command,
    ],
  );
}

// ---------------------------------------------------------------------------
// script-hostname.ts
// ---------------------------------------------------------------------------

/// Local hostname a workspace script is reachable at.
///
/// Compatibility boundary for older callers; `service_proxy_names.dart` owns
/// the hostname rules and this only forwards to it, exactly as upstream's
/// `script-hostname.ts` forwards to `service-proxy.ts`.
String buildScriptHostname({
  required String projectSlug,
  required String? branchName,
  required String scriptName,
}) => service_proxy.buildLocalServiceHostname(
  projectSlug: projectSlug,
  branchName: branchName,
  scriptName: scriptName,
);

/// Public hostname a workspace script is reachable at under [publicBaseUrl].
String buildPublicScriptHostname({
  required String publicBaseUrl,
  required String projectSlug,
  required String? branchName,
  required String scriptName,
}) => service_proxy.buildPublicServiceHostname(
  publicBaseUrl: publicBaseUrl,
  projectSlug: projectSlug,
  branchName: branchName,
  scriptName: scriptName,
);

/// Full public proxy URL, preserving [publicBaseUrl]'s scheme and port.
String buildPublicScriptProxyUrl({
  required String publicBaseUrl,
  required String projectSlug,
  required String? branchName,
  required String scriptName,
}) => service_proxy.buildPublicServiceProxyUrl(
  publicBaseUrl: publicBaseUrl,
  projectSlug: projectSlug,
  branchName: branchName,
  scriptName: scriptName,
);

// ---------------------------------------------------------------------------
// tool-call-parsers.ts
// ---------------------------------------------------------------------------

final RegExp _shellWrapperPrefixPattern = RegExp(
  r'^/bin/(?:zsh|bash|sh)\s+(?:-[a-zA-Z]+\s+)?',
);
final RegExp _cdAndPattern = RegExp(
  '''^cd\\s+(?:"[^"]+"|'[^']+'|\\S+)\\s+&&\\s+''',
);

/// Unwraps a command an agent reported as a `/bin/sh -lc "…"` invocation.
///
/// Agents log the shell wrapper they actually executed; the display surface
/// wants the command the user would recognise, so the wrapper prefix, one layer
/// of matching quotes, and a leading `cd <dir> && ` are removed.
String stripShellWrapperPrefix(String command) {
  final prefixMatch = _shellWrapperPrefixPattern.firstMatch(command);
  if (prefixMatch == null) return command;

  var rest = command.substring(prefixMatch.end).trim();
  if (rest.length >= 2) {
    final first = rest[0];
    final last = rest[rest.length - 1];
    if ((first == '"' || first == "'") && last == first) {
      rest = rest.substring(1, rest.length - 1);
    }
  }

  return rest.replaceFirst(_cdAndPattern, '');
}

/// Lifecycle state of a todo entry emitted by an agent's todo tool.
enum PaseoTodoStatus {
  pending('pending'),
  inProgress('in_progress'),
  completed('completed');

  const PaseoTodoStatus(this.wireName);

  /// The literal used on the wire, which is not the Dart enum name for
  /// [PaseoTodoStatus.inProgress].
  final String wireName;

  /// Parses [value], returning `null` for anything outside the union — the
  /// equivalent of a failed `z.enum` check.
  static PaseoTodoStatus? fromWire(Object? value) {
    for (final status in PaseoTodoStatus.values) {
      if (status.wireName == value) return status;
    }
    return null;
  }
}

/// One entry of an agent's todo list.
///
/// Named with a `Paseo` prefix because `agent_protocol` already exports a
/// `TodoItem` timeline item with a different (text/completed) shape; this is the
/// raw tool-call payload shape, not the projected timeline shape.
final class PaseoTodoItem {
  const PaseoTodoItem({
    required this.content,
    required this.status,
    this.activeForm,
  });

  /// Imperative description of the task.
  final String content;

  /// Current lifecycle state.
  final PaseoTodoStatus status;

  /// Present-tense phrasing used while the task is in progress.
  final String? activeForm;

  @override
  bool operator ==(Object other) =>
      other is PaseoTodoItem &&
      other.content == content &&
      other.status == status &&
      other.activeForm == activeForm;

  @override
  int get hashCode => Object.hash(content, status, activeForm);

  @override
  String toString() =>
      'PaseoTodoItem(content: $content, status: ${status.wireName}, '
      'activeForm: $activeForm)';
}

/// Extracts todo entries from an arbitrary tool-call payload.
///
/// Mirrors upstream's `TodosSchema.safeParse`: the whole list is rejected (and
/// an empty list returned) if any entry is malformed, and unknown keys are
/// ignored rather than being an error.
///
/// Deviation: upstream's `activeForm: z.string().optional()` rejects an
/// explicit `null` while accepting an absent key. A Dart `Map` cannot tell the
/// two apart, so an explicit `null` is treated as absent.
List<PaseoTodoItem> extractTodos(Object? value) {
  if (value is! Map) return const [];
  final todos = value['todos'];
  if (todos is! List) return const [];

  final parsed = <PaseoTodoItem>[];
  for (final raw in todos) {
    if (raw is! Map) return const [];
    final content = raw['content'];
    if (content is! String) return const [];
    final status = PaseoTodoStatus.fromWire(raw['status']);
    if (status == null) return const [];
    final activeForm = raw['activeForm'];
    if (activeForm != null && activeForm is! String) return const [];
    parsed.add(
      PaseoTodoItem(
        content: content,
        status: status,
        activeForm: activeForm as String?,
      ),
    );
  }
  return List.unmodifiable(parsed);
}
