/// Frozen Paseo 0.2.0 server-service cluster, ported to Dart.
///
/// Six upstream modules that the daemon's request paths all lean on, grouped
/// into one library because each is too small to justify a file of its own and
/// because they share the same logger seam:
///
/// | Upstream (`paseo/packages/server/src/`)              | Section here          |
/// | --------------------------------------------------- | --------------------- |
/// | `utils/git-command-runtime-metrics.ts`               | [GitCommandRuntimeMetricsWindow] |
/// | `server/logger.ts`                                   | [resolveLogConfig], [PaseoLogger] |
/// | `server/session/git-mutation/git-mutation-service.ts`| [GitMutationService]  |
/// | `server/persistence-hooks.ts`                        | [buildSessionConfig] and friends |
/// | `server/agent/agent-loading.ts`                      | [ensureAgentLoaded]   |
/// | `server/auto-archive-on-merge/archive-if-safe.ts`    | [archiveIfSafe]       |
///
/// ## Reuse
///
/// Nothing here re-declares a value the daemon already owns:
///
/// * git is run through [GitRunner] (`git/git_runner.dart`), never through a
///   second process wrapper;
/// * the git snapshot passed around is the daemon's
///   [WorkspaceLocalGitSnapshot] (`workspace/polling_workspace_git_backend.dart`),
///   which is this repo's `WorkspaceGitRuntimeSnapshot["git"]`;
/// * an active workspace reference is the daemon's [PersistedWorkspaceRecord]
///   (`workspace/workspace_registry.dart`);
/// * a merged pull request is the daemon's [ForgePullRequestStatus]
///   (`forge/forge_models.dart`);
/// * the internal-MCP-server strip is [stripInternalAgentMcpServers]
///   (`agent/runtime_mcp_config.dart`);
/// * persistence handles and config overrides are the protocol's
///   [AgentPersistenceHandle] and [AgentSessionConfigOverrides];
/// * a live agent is the protocol's [AgentSummary] — upstream's `ManagedAgent`;
/// * the daemon home and version come from `paseo_server_env.dart`.
///
/// ## Deviations
///
/// Every place a JavaScript idiom has no Dart analogue (truthiness, `Invalid
/// Date`, structural unions, pino) is called out inline at the point of the
/// deviation rather than collected here.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../agent/runtime_mcp_config.dart';
import '../forge/forge_models.dart';
import '../git/git_runner.dart';
import '../paseo_server_env.dart';
import '../workspace/polling_workspace_git_backend.dart';
import '../workspace/workspace_registry.dart';

// ===========================================================================
// Shared
// ===========================================================================

/// The single failure type this cluster raises.
///
/// Upstream throws bare `Error`s whose messages the suites match on; Dart has
/// no equivalent catch-all that carries a `cause`, so one exception type is
/// declared and every message string is preserved verbatim.
final class PaseoServerServiceException implements Exception {
  const PaseoServerServiceException(this.message, {this.cause});

  /// The upstream message, character for character.
  final String message;

  /// The error that triggered this one, when there was one. Mirrors the
  /// `{ cause }` option upstream passes to `new Error`.
  final Object? cause;

  @override
  String toString() => 'PaseoServerServiceException: $message';
}

/// Upstream `@getpaseo/protocol/error-utils#getErrorMessage`.
///
/// Returns the `message` of an error-like value and the stringification of
/// anything else, so a thrown string still reads sensibly in a log line.
String describeError(Object? error) => switch (error) {
  PaseoServerServiceException(:final message) => message,
  GitException(:final message) => message,
  final Error error => error.toString(),
  null => 'null',
  _ => '$error',
};

/// The structured-logging surface this cluster needs.
///
/// This daemon has no pino: it logs through plain callbacks. Rather than add a
/// logging dependency, the *shape* pino gives call sites — levelled methods
/// that take a message plus a bag of structured fields, and `child()` bindings
/// that are merged into every subsequent record — is declared here as an
/// interface, and [PaseoLogger] is the concrete implementation of it.
///
/// Deviation: pino's call signature is `logger.warn({fields}, "message")`.
/// Dart has no overloads and reads better message-first, so the arguments are
/// swapped. The emitted record is identical.
abstract interface class PaseoLoggerLike {
  /// Emits at `trace`.
  void trace(String message, [Map<String, Object?>? fields]);

  /// Emits at `debug`.
  void debug(String message, [Map<String, Object?>? fields]);

  /// Emits at `info`.
  void info(String message, [Map<String, Object?>? fields]);

  /// Emits at `warn`.
  void warn(String message, [Map<String, Object?>? fields]);

  /// Emits at `error`.
  void error(String message, [Map<String, Object?>? fields]);

  /// Emits at `fatal`.
  void fatal(String message, [Map<String, Object?>? fields]);

  /// A logger that merges [bindings] into every record it writes.
  PaseoLoggerLike child(Map<String, Object?> bindings);
}

/// A [PaseoLoggerLike] that discards everything.
///
/// Upstream's suites pass `pino({ level: "silent" })` for the same purpose.
final class SilentPaseoLogger implements PaseoLoggerLike {
  /// Creates the shared no-op logger.
  const SilentPaseoLogger();

  @override
  void trace(String message, [Map<String, Object?>? fields]) {}

  @override
  void debug(String message, [Map<String, Object?>? fields]) {}

  @override
  void info(String message, [Map<String, Object?>? fields]) {}

  @override
  void warn(String message, [Map<String, Object?>? fields]) {}

  @override
  void error(String message, [Map<String, Object?>? fields]) {}

  @override
  void fatal(String message, [Map<String, Object?>? fields]) {}

  @override
  PaseoLoggerLike child(Map<String, Object?> bindings) => this;
}

// ===========================================================================
// utils/git-command-runtime-metrics.ts
// ===========================================================================

/// The p50/p95/max summary of one duration series inside a metrics window.
final class GitCommandDurationStats {
  /// Creates a duration summary.
  const GitCommandDurationStats({
    required this.count,
    required this.p50Ms,
    required this.p95Ms,
    required this.maxMs,
  });

  /// The all-zero summary an empty sample set produces.
  static const empty = GitCommandDurationStats(
    count: 0,
    p50Ms: 0,
    p95Ms: 0,
    maxMs: 0,
  );

  /// Number of samples observed in the window.
  final int count;

  /// Median sample, rounded to whole milliseconds.
  final int p50Ms;

  /// 95th-percentile sample, rounded to whole milliseconds.
  final int p95Ms;

  /// Largest sample, rounded to whole milliseconds.
  final int maxMs;

  @override
  bool operator ==(Object other) =>
      other is GitCommandDurationStats &&
      other.count == count &&
      other.p50Ms == p50Ms &&
      other.p95Ms == p95Ms &&
      other.maxMs == maxMs;

  @override
  int get hashCode => Object.hash(count, p50Ms, p95Ms, maxMs);

  @override
  String toString() =>
      'GitCommandDurationStats(count: $count, p50Ms: $p50Ms, '
      'p95Ms: $p95Ms, maxMs: $maxMs)';
}

/// One `[operation, count]` pair of the `operationsTop` leaderboard.
///
/// Upstream uses a bare `[string, number]` tuple; Dart has no structural tuple
/// with a stable `==`, so the pair is a value class instead.
final class GitCommandOperationCount {
  /// Creates an operation/count pair.
  const GitCommandOperationCount(this.operation, this.count);

  /// The git operation label handed to [GitCommandRuntimeMetricsWindow.submit].
  final String operation;

  /// How many times it was submitted during the window.
  final int count;

  @override
  bool operator ==(Object other) =>
      other is GitCommandOperationCount &&
      other.operation == operation &&
      other.count == count;

  @override
  int get hashCode => Object.hash(operation, count);

  @override
  String toString() => '($operation, $count)';
}

/// One window's worth of git-command runtime telemetry.
final class GitCommandRuntimeMetricsSnapshot {
  /// Creates a snapshot. Every field is a plain observation; nothing derived
  /// is recomputed by consumers.
  const GitCommandRuntimeMetricsSnapshot({
    required this.concurrencyLimit,
    required this.active,
    required this.pending,
    required this.peakActive,
    required this.peakPending,
    required this.oldestPendingMs,
    required this.submitted,
    required this.started,
    required this.completed,
    required this.failed,
    required this.timedOut,
    required this.queueWaitMs,
    required this.executionMs,
    required this.operationsTop,
  });

  /// Configured maximum number of concurrent git commands.
  final int concurrencyLimit;

  /// Commands running right now, as reported by the limiter.
  final int active;

  /// Commands queued right now, as reported by the limiter.
  final int pending;

  /// High-water mark of [active] during the window.
  final int peakActive;

  /// High-water mark of [pending] during the window.
  final int peakPending;

  /// Age of the longest-waiting queued command, or `0` when nothing is queued.
  final int oldestPendingMs;

  /// Commands submitted during the window.
  final int submitted;

  /// Commands that began executing during the window.
  final int started;

  /// Commands that finished during the window.
  final int completed;

  /// Of [completed], how many reported failure.
  final int failed;

  /// Of [completed], how many reported a timeout.
  final int timedOut;

  /// Time between submit and start.
  final GitCommandDurationStats queueWaitMs;

  /// Time between start and finish.
  final GitCommandDurationStats executionMs;

  /// The twelve most-submitted operations, most frequent first.
  final List<GitCommandOperationCount> operationsTop;
}

/// A single in-flight git command's timing handle.
///
/// Deliberately mutable and identity-compared: the window keys its pending set
/// on the object itself, exactly as upstream's `Set<GitCommandRuntimeMetric>`
/// does, so re-submitting the same operation label yields a distinct handle.
final class GitCommandRuntimeMetric {
  GitCommandRuntimeMetric._(this.queuedAtMs);

  /// When the command entered the queue.
  final int queuedAtMs;

  /// When it began executing, or `null` before it starts and again after it
  /// finishes. The reset-to-`null` on finish is what makes a double `finish`
  /// a no-op.
  int? startedAtMs;
}

/// The limiter's live occupancy at snapshot time.
final class GitCommandLimiterState {
  /// Creates a limiter observation.
  const GitCommandLimiterState({required this.active, required this.pending});

  /// Commands the limiter is currently running.
  final int active;

  /// Commands the limiter currently has queued.
  final int pending;
}

/// Reads a monotonic-ish wall clock in milliseconds.
///
/// Injected everywhere so window arithmetic is deterministic in tests; the
/// production default is the same `Date.now` upstream uses.
typedef GitCommandMetricsClock = int Function();

/// Accumulates git-command telemetry between two `snapshotAndReset` calls.
///
/// The window separates *queue wait* (submit to start) from *execution*
/// (start to finish) so a saturated limiter is distinguishable from slow git.
class GitCommandRuntimeMetricsWindow {
  /// Creates a window for a limiter allowing [concurrencyLimit] concurrent
  /// commands.
  ///
  /// [clock] defaults to the wall clock, matching upstream's `Date.now`
  /// default; every test injects one instead.
  GitCommandRuntimeMetricsWindow(
    this.concurrencyLimit, [
    GitCommandMetricsClock? clock,
  ]) : _clock = clock ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// Configured maximum number of concurrent git commands.
  final int concurrencyLimit;

  final GitCommandMetricsClock _clock;

  // Identity set: `Set<GitCommandRuntimeMetric>` upstream. Dart's default
  // `==` on a class without an override is identity, so this matches.
  final Set<GitCommandRuntimeMetric> _pendingCommands =
      <GitCommandRuntimeMetric>{};
  int _active = 0;
  int _peakActive = 0;
  int _peakPending = 0;
  int _submittedCount = 0;
  int _startedCount = 0;
  int _completedCount = 0;
  int _failedCount = 0;
  int _timedOutCount = 0;
  final List<int> _queueWaitSamples = <int>[];
  final List<int> _executionSamples = <int>[];
  final Map<String, int> _operationCounts = <String, int>{};

  /// Records that [operation] was queued, returning its timing handle.
  GitCommandRuntimeMetric submit(String operation) {
    final metric = GitCommandRuntimeMetric._(_clock());
    _pendingCommands.add(metric);
    _submittedCount += 1;
    _operationCounts[operation] = (_operationCounts[operation] ?? 0) + 1;
    return metric;
  }

  /// Folds a limiter occupancy reading into the window's high-water marks.
  void observeLimiter(int active, int pending) {
    _peakActive = math.max(_peakActive, active);
    _peakPending = math.max(_peakPending, pending);
  }

  /// Records that [metric] began executing.
  ///
  /// A handle that is not pending — already started, already finished, or from
  /// a previous window — is ignored rather than double-counted.
  void start(GitCommandRuntimeMetric metric) {
    if (!_pendingCommands.remove(metric)) {
      return;
    }
    final now = _clock();
    metric.startedAtMs = now;
    _active += 1;
    _startedCount += 1;
    _peakActive = math.max(_peakActive, _active);
    _queueWaitSamples.add(math.max(0, now - metric.queuedAtMs));
  }

  /// Adapts this window to the observer [GitRunner] accepts.
  ///
  /// Upstream records telemetry inside `runGitCommand` itself. Here the runner
  /// and the window are separate ports, so this is the join: without it the
  /// window is live but observes nothing that real git does.
  GitCommandObserver asGitCommandObserver() => _WindowGitCommandObserver(this);

  /// Records that [metric] finished.
  ///
  /// A handle that never started is ignored, so a command cancelled while
  /// queued does not pollute the execution series.
  void finish(
    GitCommandRuntimeMetric metric, {
    required bool success,
    required bool timedOut,
  }) {
    final startedAtMs = metric.startedAtMs;
    if (startedAtMs == null) {
      return;
    }
    metric.startedAtMs = null;
    _active = math.max(0, _active - 1);
    _completedCount += 1;
    if (!success) {
      _failedCount += 1;
    }
    if (timedOut) {
      _timedOutCount += 1;
    }
    _executionSamples.add(math.max(0, _clock() - startedAtMs));
  }

  /// Reads the window and starts a new one.
  ///
  /// [limiter] is the authoritative live occupancy; when omitted the window's
  /// own bookkeeping is used. The peaks carry the live values forward into the
  /// next window rather than resetting to zero, so a limiter that stays
  /// saturated keeps reporting saturation.
  GitCommandRuntimeMetricsSnapshot snapshotAndReset([
    GitCommandLimiterState? limiter,
  ]) {
    final state =
        limiter ??
        GitCommandLimiterState(
          active: _active,
          pending: _pendingCommands.length,
        );
    final now = _clock();

    // Upstream spreads the pending set into `Math.min`, which returns
    // `Infinity` for an empty set and is then rejected by `Number.isFinite`.
    // Dart has no variadic min, so "no pending commands" is spelled as a null
    // oldest timestamp; the guard below is otherwise identical.
    int? oldestPendingAtMs;
    for (final metric in _pendingCommands) {
      final queuedAt = metric.queuedAtMs;
      if (oldestPendingAtMs == null || queuedAt < oldestPendingAtMs) {
        oldestPendingAtMs = queuedAt;
      }
    }

    final snapshot = GitCommandRuntimeMetricsSnapshot(
      concurrencyLimit: concurrencyLimit,
      active: state.active,
      pending: state.pending,
      peakActive: _peakActive,
      peakPending: _peakPending,
      oldestPendingMs: state.pending > 0 && oldestPendingAtMs != null
          ? math.max(0, now - oldestPendingAtMs)
          : 0,
      submitted: _submittedCount,
      started: _startedCount,
      completed: _completedCount,
      failed: _failedCount,
      timedOut: _timedOutCount,
      queueWaitMs: summarizeGitCommandDurations(_queueWaitSamples),
      executionMs: summarizeGitCommandDurations(_executionSamples),
      operationsTop: _topOperations(),
    );

    _peakActive = state.active;
    _peakPending = state.pending;
    _submittedCount = 0;
    _startedCount = 0;
    _completedCount = 0;
    _failedCount = 0;
    _timedOutCount = 0;
    _queueWaitSamples.clear();
    _executionSamples.clear();
    _operationCounts.clear();
    return snapshot;
  }

  List<GitCommandOperationCount> _topOperations() {
    final entries = _operationCounts.entries.toList();
    // Deviation: upstream breaks count ties with `localeCompare`, which is
    // locale-sensitive. Dart's `compareTo` is ordinal. The two agree for the
    // ASCII operation labels the git layer actually emits ("status",
    // "rev-parse", ...); they can disagree for non-ASCII labels, which nothing
    // produces.
    entries.sort((left, right) {
      final byCount = right.value.compareTo(left.value);
      return byCount != 0 ? byCount : left.key.compareTo(right.key);
    });
    return List.unmodifiable(
      entries
          .take(gitCommandOperationsTopLimit)
          .map((entry) => GitCommandOperationCount(entry.key, entry.value)),
    );
  }
}

/// How many operations `operationsTop` keeps.
const int gitCommandOperationsTopLimit = 12;

/// Summarizes a duration series the way the metrics window reports it.
///
/// Exposed because the percentile index arithmetic is the part most likely to
/// drift from upstream, and it is worth pinning directly.
GitCommandDurationStats summarizeGitCommandDurations(List<int> samples) {
  if (samples.isEmpty) {
    return GitCommandDurationStats.empty;
  }
  final sorted = [...samples]..sort();
  return GitCommandDurationStats(
    count: sorted.length,
    // Deviation: upstream rounds with `Math.round` (half up); Dart's `round`
    // is half away from zero. Samples are clamped to >= 0 at collection time,
    // so the two are identical here. The samples are already integers, so the
    // rounding is a no-op in this port and is kept only for shape.
    p50Ms: _sampleAt(sorted, sorted.length ~/ 2),
    p95Ms: _sampleAt(sorted, (sorted.length * 0.95).ceil() - 1),
    maxMs: _sampleAt(sorted, sorted.length - 1),
  );
}

/// Upstream indexes with `sorted[i] ?? 0`, which yields `0` for an
/// out-of-range index instead of throwing. Reproduced explicitly.
int _sampleAt(List<int> sorted, int index) =>
    index >= 0 && index < sorted.length ? sorted[index] : 0;

// ===========================================================================
// server/logger.ts
// ===========================================================================

/// Severity levels, ordered by pino's numeric priorities.
enum LogLevel {
  /// Most verbose.
  trace('trace', 10),

  /// Developer diagnostics.
  debug('debug', 20),

  /// Default level.
  info('info', 30),

  /// Recoverable problems.
  warn('warn', 40),

  /// Failures.
  error('error', 50),

  /// Unrecoverable failures.
  fatal('fatal', 60);

  const LogLevel(this.wireName, this.priority);

  /// The string form used in config files and in emitted records.
  final String wireName;

  /// pino's numeric priority; lower is more verbose.
  final int priority;

  /// Parses a config value, returning `null` for anything unrecognized.
  ///
  /// Upstream validates levels with a zod enum at the config boundary and so
  /// never sees a bad value here; returning `null` lets this port fall back to
  /// the default instead of throwing during startup.
  static LogLevel? fromWireName(Object? value) {
    for (final level in LogLevel.values) {
      if (level.wireName == value) return level;
    }
    return null;
  }
}

/// Console rendering styles.
enum LogFormat {
  /// Human-readable single-line output.
  pretty('pretty'),

  /// One JSON object per line.
  json('json');

  const LogFormat(this.wireName);

  /// The string form used in config files.
  final String wireName;

  /// Parses a config value, returning `null` for anything unrecognized.
  static LogFormat? fromWireName(Object? value) {
    for (final format in LogFormat.values) {
      if (format.wireName == value) return format;
    }
    return null;
  }
}

/// Default level when nothing is configured.
const LogLevel defaultConsoleLogLevel = LogLevel.info;

/// Default console rendering when nothing is configured.
const LogFormat defaultConsoleLogFormat = LogFormat.json;

/// Default level for file output that is enabled without an explicit level.
const LogLevel defaultFileLogLevel = LogLevel.info;

/// Filename used when file logging is enabled without a path.
const String defaultDaemonLogFilename = 'daemon.log';

/// Record paths stripped from every log line before it is written.
///
/// These carry bearer tokens and the WebSocket subprotocol the daemon smuggles
/// its auth token through, so they must never reach a log file. Kept in
/// upstream's order and spelling, including both the dotted and the
/// bracket-quoted forms, so the redaction surface is auditable against pino's
/// config.
const List<String> logRedactPaths = [
  'authorization',
  'Authorization',
  'headers.authorization',
  'headers.Authorization',
  'req.headers.authorization',
  'req.headers.Authorization',
  '["sec-websocket-protocol"]',
  'Sec-WebSocket-Protocol',
  'headers["sec-websocket-protocol"]',
  'headers.Sec-WebSocket-Protocol',
  'req.headers["sec-websocket-protocol"]',
  'req.headers.Sec-WebSocket-Protocol',
];

/// Console half of a [ResolvedLogConfig].
final class ResolvedConsoleLogConfig {
  /// Creates the console configuration.
  const ResolvedConsoleLogConfig({required this.level, required this.format});

  /// Minimum level written to the console.
  final LogLevel level;

  /// How console records are rendered.
  final LogFormat format;

  @override
  bool operator ==(Object other) =>
      other is ResolvedConsoleLogConfig &&
      other.level == level &&
      other.format == format;

  @override
  int get hashCode => Object.hash(level, format);

  @override
  String toString() =>
      'ResolvedConsoleLogConfig(level: ${level.wireName}, '
      'format: ${format.wireName})';
}

/// File half of a [ResolvedLogConfig]; absent when file logging is off.
final class ResolvedFileLogConfig {
  /// Creates the file configuration.
  const ResolvedFileLogConfig({required this.level, required this.path});

  /// Minimum level written to the file.
  final LogLevel level;

  /// Absolute path of the log file.
  final String path;

  @override
  bool operator ==(Object other) =>
      other is ResolvedFileLogConfig &&
      other.level == level &&
      other.path == path;

  @override
  int get hashCode => Object.hash(level, path);

  @override
  String toString() =>
      'ResolvedFileLogConfig(level: ${level.wireName}, path: $path)';
}

/// The fully resolved logging plan: what gets written, where, and how.
final class ResolvedLogConfig {
  /// Creates a resolved plan.
  const ResolvedLogConfig({
    required this.level,
    required this.console,
    this.file,
  });

  /// The most verbose of the enabled destinations, i.e. the level the
  /// underlying logger must be opened at for every destination to see what it
  /// asked for.
  final LogLevel level;

  /// Console destination; always present.
  final ResolvedConsoleLogConfig console;

  /// File destination, or `null` when file logging is disabled.
  final ResolvedFileLogConfig? file;

  @override
  bool operator ==(Object other) =>
      other is ResolvedLogConfig &&
      other.level == level &&
      other.console == console &&
      other.file == file;

  @override
  int get hashCode => Object.hash(level, console, file);

  @override
  String toString() =>
      'ResolvedLogConfig(level: ${level.wireName}, console: $console, '
      'file: $file)';
}

/// `log.console` as written in the persisted config.
final class PersistedConsoleLogConfig {
  /// Creates a console config section.
  const PersistedConsoleLogConfig({this.level, this.format});

  /// Console level override.
  final LogLevel? level;

  /// Console format override.
  final LogFormat? format;
}

/// `log.file` as written in the persisted config.
///
/// Presence of this section — not the value of any field — is what enables
/// file logging.
final class PersistedFileLogConfig {
  /// Creates a file config section.
  const PersistedFileLogConfig({this.level, this.path});

  /// File level override.
  final LogLevel? level;

  /// File path, absolute or relative to the daemon home. `null` (and, as
  /// upstream's `!configuredPath` check implies, the empty string) means
  /// `daemon.log` in the daemon home.
  final String? path;
}

/// The `log` section of the persisted config.
final class PersistedLogConfig {
  /// Creates a `log` section.
  const PersistedLogConfig({this.level, this.format, this.console, this.file});

  /// Legacy global level, used as the fallback for both destinations.
  final LogLevel? level;

  /// Legacy global format, used as the console fallback.
  final LogFormat? format;

  /// Console overrides.
  final PersistedConsoleLogConfig? console;

  /// File destination; its presence enables file logging.
  final PersistedFileLogConfig? file;

  /// Reads a `log` object out of a raw config map.
  static PersistedLogConfig fromJson(Map<String, Object?> json) {
    final console = json['console'];
    final file = json['file'];
    return PersistedLogConfig(
      level: LogLevel.fromWireName(json['level']),
      format: LogFormat.fromWireName(json['format']),
      console: console is Map
          ? PersistedConsoleLogConfig(
              level: LogLevel.fromWireName(console['level']),
              format: LogFormat.fromWireName(console['format']),
            )
          : null,
      file: file is Map
          ? PersistedFileLogConfig(
              level: LogLevel.fromWireName(file['level']),
              path: file['path'] is String ? file['path']! as String : null,
            )
          : null,
    );
  }
}

/// What a caller hands [resolveLogConfig].
///
/// Upstream accepts a structural union — either a whole `PersistedConfig` (a
/// `log` key) or a bare legacy `{ level, format }` — and discriminates it with
/// `in` checks. Dart has no structural typing, so the union is a sealed
/// hierarchy and [LoggerConfigInput.fromJson] reproduces the `in` checks for
/// callers that only hold the raw decoded config map.
sealed class LoggerConfigInput {
  const LoggerConfigInput();

  /// Discriminates a raw config map exactly as upstream's
  /// `normalizeLoggerConfigInput` does.
  ///
  /// * `null` stays `null`;
  /// * a map with a `log` key is a [StructuredLoggerConfig];
  /// * a map with `level` or `format` at the top level is a
  ///   [LegacyLoggerConfig];
  /// * anything else is a [StructuredLoggerConfig] with no `log` section.
  ///
  /// Deviation: upstream's legacy branch copies `level`/`format` only when
  /// they are truthy, so an empty-string level is dropped. Here an
  /// unrecognized level parses to `null`, which has the same effect.
  static LoggerConfigInput? fromJson(Map<String, Object?>? config) {
    if (config == null) return null;
    if (config.containsKey('log')) {
      final log = config['log'];
      return StructuredLoggerConfig(
        log: log is Map
            ? PersistedLogConfig.fromJson(Map<String, Object?>.from(log))
            : null,
      );
    }
    if (config.containsKey('level') || config.containsKey('format')) {
      return LegacyLoggerConfig(
        level: LogLevel.fromWireName(config['level']),
        format: LogFormat.fromWireName(config['format']),
      );
    }
    return const StructuredLoggerConfig();
  }
}

/// A config carrying a `log` section (or carrying none at all).
final class StructuredLoggerConfig extends LoggerConfigInput {
  /// Creates a structured config input.
  const StructuredLoggerConfig({this.log});

  /// The `log` section, or `null` when the config has none.
  final PersistedLogConfig? log;
}

/// The pre-`log`-section shape: a bare global level and format.
final class LegacyLoggerConfig extends LoggerConfigInput {
  /// Creates a legacy config input.
  const LegacyLoggerConfig({this.level, this.format});

  /// Global level, applied to the console.
  final LogLevel? level;

  /// Global format, applied to the console.
  final LogFormat? format;
}

/// Turns any [LoggerConfigInput] into the single normalized `log` section
/// upstream's `normalizeLoggerConfigInput` produces.
PersistedLogConfig? _normalizeLoggerConfigInput(LoggerConfigInput? config) =>
    switch (config) {
      null => null,
      StructuredLoggerConfig(:final log) => log,
      LegacyLoggerConfig(:final level, :final format) => PersistedLogConfig(
        level: level,
        format: format,
      ),
    };

String _resolveLogFilePath(String paseoHome, String? configuredPath) {
  final fallback = p.join(paseoHome, defaultDaemonLogFilename);
  // Deviation: upstream's `!configuredPath` is JS truthiness, so an empty
  // string also falls back. Spelled out because Dart has no truthiness.
  if (configuredPath == null || configuredPath.isEmpty) {
    return fallback;
  }
  if (p.isAbsolute(configuredPath)) {
    return configuredPath;
  }
  return p.normalize(p.join(paseoHome, configuredPath));
}

LogLevel _minLogLevel(List<LogLevel> levels) {
  var minLevel = levels.first;
  for (final level in levels) {
    if (level.priority < minLevel.priority) {
      minLevel = level;
    }
  }
  return minLevel;
}

/// Resolves the effective logging plan.
///
/// [paseoHome] overrides the daemon home used to anchor a relative file path;
/// when omitted the ambient home is resolved (creating it, as
/// [resolveTinyrackServerHome] does).
///
/// [file] set to `false` suppresses file output even when the config asks for
/// it. Supervised workers use this: the supervisor already owns the log file,
/// and two processes appending to it would interleave.
ResolvedLogConfig resolveLogConfig(
  LoggerConfigInput? configInput, {
  String? paseoHome,
  bool file = true,
}) {
  final persistedLog = _normalizeLoggerConfigInput(configInput);
  final home = paseoHome ?? resolveTinyrackServerHome();

  final consoleLevel =
      persistedLog?.console?.level ??
      persistedLog?.level ??
      defaultConsoleLogLevel;
  final fileLevel = persistedLog?.file != null
      ? (persistedLog!.file!.level ?? persistedLog.level ?? defaultFileLogLevel)
      : null;
  final consoleFormat =
      persistedLog?.console?.format ??
      persistedLog?.format ??
      defaultConsoleLogFormat;

  final persistedFile = persistedLog?.file;
  final resolvedFile = file && persistedFile != null
      ? ResolvedFileLogConfig(
          level: fileLevel ?? defaultFileLogLevel,
          path: _resolveLogFilePath(home, persistedFile.path),
        )
      : null;

  return ResolvedLogConfig(
    level: _minLogLevel(
      resolvedFile != null
          ? [consoleLevel, resolvedFile.level]
          : [consoleLevel],
    ),
    console: ResolvedConsoleLogConfig(
      level: consoleLevel,
      format: consoleFormat,
    ),
    file: resolvedFile,
  );
}

/// Where a [PaseoLogger] writes finished lines.
typedef PaseoLogSink = void Function(String line);

/// Reads wall-clock time for the `time` field of a record.
typedef PaseoLogClock = DateTime Function();

/// The daemon's structured logger.
///
/// This is the behavioral port of the pino instance upstream builds: the same
/// level gate, the same redaction set, the same JSON record shape, the same
/// `child()` binding merge, and the same choice between a pretty single line
/// and a JSON line. It is *not* pino — there is no transport, no worker
/// thread, and no async destination, because the daemon has no such dependency
/// and none of that is observable in a log line.
final class PaseoLogger implements PaseoLoggerLike {
  const PaseoLogger._({
    required this.level,
    required this.format,
    required PaseoLogSink sink,
    required Map<String, Object?> bindings,
    required PaseoLogClock clock,
    required int processId,
    required String hostname,
  }) : _sink = sink,
       _bindings = bindings,
       _clock = clock,
       _processId = processId,
       _hostname = hostname;

  /// Builds a root logger for [config].
  ///
  /// Mirrors upstream's `createRootLogger`: when a file destination is
  /// configured its parent directory is created, the single underlying stream
  /// is opened at the file level (falling back to the console level), and the
  /// returned logger is already a child carrying `daemonVersion`.
  ///
  /// [sink] overrides the destination entirely, which is how tests observe
  /// emitted lines without touching the filesystem.
  factory PaseoLogger.root(
    ResolvedLogConfig config, {
    PaseoLogSink? sink,
    PaseoLogClock? clock,
    int? processId,
    String? hostname,
    String? daemonVersion,
  }) {
    final fileConfig = config.file;
    if (fileConfig != null && sink == null) {
      Directory(p.dirname(fileConfig.path)).createSync(recursive: true);
    }
    final resolvedSink =
        sink ??
        (fileConfig != null
            ? _fileSink(fileConfig.path)
            : (String line) => stdout.writeln(line));
    final root = PaseoLogger._(
      level: fileConfig?.level ?? config.console.level,
      format: config.console.format,
      sink: resolvedSink,
      bindings: const <String, Object?>{},
      clock: clock ?? DateTime.now,
      processId: processId ?? pid,
      hostname: hostname ?? Platform.localHostname,
    );
    return root.child({
      'daemonVersion': daemonVersion ?? resolveDaemonVersionWithFallback(),
    });
  }

  static PaseoLogSink _fileSink(String path) {
    final file = File(path);
    return (String line) =>
        file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  }

  /// Minimum level this logger emits.
  final LogLevel level;

  /// How records are rendered.
  final LogFormat format;

  final PaseoLogSink _sink;
  final Map<String, Object?> _bindings;
  final PaseoLogClock _clock;
  final int _processId;
  final String _hostname;

  @override
  PaseoLogger child(Map<String, Object?> bindings) => PaseoLogger._(
    level: level,
    format: format,
    sink: _sink,
    bindings: Map.unmodifiable({..._bindings, ...bindings}),
    clock: _clock,
    processId: _processId,
    hostname: _hostname,
  );

  @override
  void trace(String message, [Map<String, Object?>? fields]) =>
      log(LogLevel.trace, message, fields);

  @override
  void debug(String message, [Map<String, Object?>? fields]) =>
      log(LogLevel.debug, message, fields);

  @override
  void info(String message, [Map<String, Object?>? fields]) =>
      log(LogLevel.info, message, fields);

  @override
  void warn(String message, [Map<String, Object?>? fields]) =>
      log(LogLevel.warn, message, fields);

  @override
  void error(String message, [Map<String, Object?>? fields]) =>
      log(LogLevel.error, message, fields);

  @override
  void fatal(String message, [Map<String, Object?>? fields]) =>
      log(LogLevel.fatal, message, fields);

  /// Emits one record at [recordLevel], dropping it when the level is below
  /// this logger's threshold.
  void log(
    LogLevel recordLevel,
    String message, [
    Map<String, Object?>? fields,
  ]) {
    if (recordLevel.priority < level.priority) return;
    final merged = redactLogRecord({..._bindings, ...?fields});
    _sink(_render(recordLevel, message, merged));
  }

  String _render(
    LogLevel recordLevel,
    String message,
    Map<String, Object?> merged,
  ) {
    final time = _clock();
    switch (format) {
      case LogFormat.json:
        return jsonEncode({
          'level': recordLevel.priority,
          'time': time.millisecondsSinceEpoch,
          'pid': _processId,
          'hostname': _hostname,
          ...merged,
          'msg': message,
        }, toEncodable: _encodeLogValue);
      case LogFormat.pretty:
        // Deviation: pino-pretty is configured `colorize: true` upstream.
        // ANSI colour is a terminal capability, not information, and emitting
        // escapes into a captured stream makes the output harder to assert on,
        // so this port renders the same single line uncoloured. `pid` and
        // `hostname` are omitted, matching upstream's `ignore: "pid,hostname"`.
        final rest = merged.isEmpty
            ? ''
            : ' ${jsonEncode(merged, toEncodable: _encodeLogValue)}';
        return '[${time.toUtc().toIso8601String()}] '
            '${recordLevel.wireName.toUpperCase()}: $message$rest';
    }
  }
}

Object? _encodeLogValue(Object? value) => value.toString();

/// Names a child logger, mirroring upstream's `createChildLogger`.
///
/// pino renders a `name` binding specially in pretty mode; this port simply
/// binds it like any other field, which is the observable behavior in JSON.
PaseoLoggerLike createChildLogger(PaseoLoggerLike parent, String name) =>
    parent.child({'name': name});

/// Strips every [logRedactPaths] entry out of [record].
///
/// Exposed because redaction is the one part of logging that is a security
/// property rather than a formatting choice, and it must be assertable on its
/// own. The input is never mutated: each removal rebuilds only the maps on the
/// path it touches.
Map<String, Object?> redactLogRecord(Map<String, Object?> record) {
  var result = record;
  for (final path in _parsedRedactPaths) {
    result = _removeRedactedPath(result, path, 0);
  }
  return result;
}

final List<List<String>> _parsedRedactPaths = List.unmodifiable(
  logRedactPaths.map(parseLogRedactPath),
);

/// Splits a pino redaction path into its segments.
///
/// Handles both the dotted form (`headers.authorization`) and the
/// bracket-quoted form (`headers["sec-websocket-protocol"]`) pino needs for
/// keys containing a hyphen. Exposed so the path grammar is testable.
List<String> parseLogRedactPath(String path) {
  final segments = <String>[];
  final buffer = StringBuffer();
  var index = 0;
  while (index < path.length) {
    final character = path[index];
    if (character == '.') {
      if (buffer.isNotEmpty) {
        segments.add(buffer.toString());
        buffer.clear();
      }
      index += 1;
      continue;
    }
    if (character == '[') {
      if (buffer.isNotEmpty) {
        segments.add(buffer.toString());
        buffer.clear();
      }
      final end = path.indexOf(']', index);
      if (end == -1) {
        buffer.write(path.substring(index + 1));
        index = path.length;
        continue;
      }
      segments.add(_unquote(path.substring(index + 1, end).trim()));
      index = end + 1;
      continue;
    }
    buffer.write(character);
    index += 1;
  }
  if (buffer.isNotEmpty) {
    segments.add(buffer.toString());
  }
  return List.unmodifiable(segments);
}

String _unquote(String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

Map<String, Object?> _removeRedactedPath(
  Map<String, Object?> map,
  List<String> segments,
  int offset,
) {
  if (offset >= segments.length) return map;
  final head = segments[offset];
  if (!map.containsKey(head)) return map;
  if (offset == segments.length - 1) {
    return Map<String, Object?>.of(map)..remove(head);
  }
  final child = map[head];
  if (child is! Map) return map;
  final childMap = Map<String, Object?>.from(child);
  final updated = _removeRedactedPath(childMap, segments, offset + 1);
  return Map<String, Object?>.of(map)..[head] = updated;
}

// ===========================================================================
// server/session/git-mutation/git-mutation-service.ts
// ===========================================================================

/// Why a workspace git snapshot is being force-refreshed.
///
/// Upstream models this as a string union. The wire strings are load-bearing
/// (they surface in refresh telemetry and in the snapshot cache key), so they
/// are preserved verbatim on the enum.
enum GitMutationRefreshReason {
  /// A commit was created.
  commitChanges('commit-changes'),

  /// `git pull`.
  pull('pull'),

  /// `git push`.
  push('push'),

  /// The working branch was merged into its base.
  mergeToBase('merge-to-base'),

  /// The base was merged into the working branch.
  mergeFromBase('merge-from-base'),

  /// A pull request was merged.
  mergePr('merge-pr'),

  /// Auto-merge was enabled on a pull request.
  enablePrAutoMerge('enable-pr-auto-merge'),

  /// Auto-merge was disabled on a pull request.
  disablePrAutoMerge('disable-pr-auto-merge'),

  /// A pull request was opened.
  createPr('create-pr'),

  /// The checkout switched to an existing branch.
  switchBranch('switch-branch'),

  /// The current branch was renamed.
  renameBranch('rename-branch'),

  /// A branch was created.
  createBranch('create-branch'),

  /// Changes were stashed.
  stashPush('stash-push'),

  /// A stash was applied.
  stashPop('stash-pop'),

  /// A worktree was created.
  createWorktree('create-worktree');

  const GitMutationRefreshReason(this.wireName);

  /// The literal upstream string.
  final String wireName;
}

/// How a requested branch name resolves against a checkout.
sealed class BranchCheckoutResolution {
  const BranchCheckoutResolution();
}

/// The branch already exists locally.
final class LocalBranchCheckoutResolution extends BranchCheckoutResolution {
  /// Creates a local resolution.
  const LocalBranchCheckoutResolution(this.name);

  /// The local branch name.
  final String name;
}

/// The branch exists only on a remote and must be created with tracking.
final class RemoteOnlyBranchCheckoutResolution
    extends BranchCheckoutResolution {
  /// Creates a remote-only resolution.
  const RemoteOnlyBranchCheckoutResolution({
    required this.name,
    required this.remoteRef,
  });

  /// The local branch name to create.
  final String name;

  /// The remote ref to track, e.g. `origin/feature`.
  final String remoteRef;
}

/// The branch does not exist anywhere.
final class NotFoundBranchCheckoutResolution extends BranchCheckoutResolution {
  /// Creates a not-found resolution.
  const NotFoundBranchCheckoutResolution();
}

/// Where a completed checkout got its branch from.
enum BranchCheckoutSource {
  /// The branch already existed locally.
  local('local'),

  /// The branch was created from a remote-tracking ref.
  remote('remote');

  const BranchCheckoutSource(this.wireName);

  /// The literal upstream string.
  final String wireName;
}

/// Result of checking out an existing branch.
final class CheckoutExistingBranchResult {
  /// Creates a checkout result.
  const CheckoutExistingBranchResult({required this.source});

  /// Where the branch came from.
  final BranchCheckoutSource source;

  @override
  bool operator ==(Object other) =>
      other is CheckoutExistingBranchResult && other.source == source;

  @override
  int get hashCode => source.hashCode;

  @override
  String toString() => 'CheckoutExistingBranchResult(${source.wireName})';
}

/// The only characters a git ref this daemon accepts may contain.
final RegExp safeGitRefPattern = RegExp(r'^[A-Za-z0-9._/-]+$');

/// Rejects any ref that could be misread by git or smuggle an option.
///
/// This is upstream's two-layer check collapsed into one function: the
/// git-mutation module applies its own character-class test and *then* calls
/// `worktree-session.assertSafeGitRef`, which repeats that test and
/// additionally rejects `..` (parent traversal in a pathspec) and `@{}`
/// (git's reflog/upstream revision syntax). The character class already
/// excludes `@` and `{`, so the `@{` clause is defensive; `..` is not
/// excluded by the class and is the clause that actually bites.
void assertSafeGitRef(String ref, String label) {
  if (!safeGitRefPattern.hasMatch(ref) ||
      ref.contains('..') ||
      ref.contains('@{')) {
    throw PaseoServerServiceException('Invalid $label: $ref');
  }
}

/// The read side of the workspace git layer this cluster depends on.
///
/// Both [GitMutationService] and [archiveIfSafe] need exactly one thing from
/// the workspace git service — a possibly-forced snapshot — so the seam is
/// declared once. [reason] is a free string rather than a
/// [GitMutationRefreshReason] because the auto-archive path passes its own
/// label (`auto-archive-on-merge`) that is not a mutation reason.
abstract interface class WorkspaceGitSnapshotSource {
  /// Reads (or force-refreshes) the git snapshot for [cwd].
  ///
  /// Returns `null` when [cwd] has no readable git state.
  Future<WorkspaceLocalGitSnapshot?> getSnapshot(
    String cwd, {
    bool force,
    String? reason,
  });
}

/// The slice of the workspace git service [GitMutationService] mutates
/// against.
///
/// Upstream expresses this as `Pick<WorkspaceGitService, ...>`; Dart has no
/// structural picks, so it is an explicit interface. It intentionally does not
/// extend the daemon's full workspace git service: keeping the surface at four
/// members is what lets the mutation sequence be tested without one.
abstract interface class GitMutationGitSource
    implements WorkspaceGitSnapshotSource {
  /// Resolves [ref] against [cwd].
  Future<BranchCheckoutResolution> validateBranchRef(String cwd, String ref);

  /// Whether [branch] exists locally in [cwd].
  Future<bool> hasLocalBranch(String cwd, String branch);

  /// Drops any cached forge (pull-request) state for [cwd].
  void invalidateForge(String cwd);
}

/// Performs the git commands a resolved branch checkout implies.
///
/// Reuses the daemon's [GitRunner] rather than a second process wrapper.
///
/// Deviation: [GitRunner] always prepends `-c core.quotepath=false`, which
/// upstream's `runGitCommand` does not. It only affects how git *prints*
/// non-ASCII paths, and neither command here reads a path from git's output,
/// so nothing observable changes.
Future<CheckoutExistingBranchResult> checkoutResolvedBranch({
  required String cwd,
  required BranchCheckoutResolution resolution,
  String? requestedBranch,
  GitRunner runner = const GitRunner(),
}) async {
  switch (resolution) {
    case LocalBranchCheckoutResolution(:final name):
      final head = await runner.run([
        'rev-parse',
        '--abbrev-ref',
        'HEAD',
      ], cwd: cwd);
      // Already on the branch: upstream skips the checkout entirely so a
      // no-op switch does not touch mtimes and retrigger every file watcher.
      if (head.stdout.trim() == name) {
        return const CheckoutExistingBranchResult(
          source: BranchCheckoutSource.local,
        );
      }
      await runner.run(['checkout', name], cwd: cwd);
      return const CheckoutExistingBranchResult(
        source: BranchCheckoutSource.local,
      );
    case RemoteOnlyBranchCheckoutResolution(:final name, :final remoteRef):
      await runner.run([
        'checkout',
        '-b',
        name,
        '--track',
        remoteRef,
      ], cwd: cwd);
      return const CheckoutExistingBranchResult(
        source: BranchCheckoutSource.remote,
      );
    case NotFoundBranchCheckoutResolution():
      throw PaseoServerServiceException(
        'Branch not found: ${requestedBranch ?? ''}',
      );
  }
}

/// The git branch / working-tree mutation primitives a client session performs
/// on a workspace.
///
/// CheckoutSession (the branch/commit/merge commands), the worktree
/// session-config builder, and the auto-naming + worktree-creation paths all
/// funnel their git mutations through this one class, so the
/// validate-ref -> clean-tree -> execute -> refresh sequence lives in a single
/// place instead of being smeared across the session as loose callbacks.
final class GitMutationService {
  /// Creates the service.
  ///
  /// [runner] is injectable so the real-git tests can point at a temp repo
  /// while everything else uses the default.
  const GitMutationService({
    required this.workspaceGitService,
    required this.logger,
    this.runner = const GitRunner(),
  });

  /// The workspace git layer this service reads and invalidates.
  final GitMutationGitSource workspaceGitService;

  /// Where a failed post-mutation refresh is reported.
  final PaseoLoggerLike logger;

  /// How git itself is invoked.
  final GitRunner runner;

  /// Switches [cwd] onto an existing [branch].
  ///
  /// Order matters and is upstream's: validate the ref before touching git,
  /// confirm the branch resolves, refuse a dirty tree, then check out. The
  /// forge cache is invalidated because a branch switch changes which pull
  /// request (if any) is current.
  Future<CheckoutExistingBranchResult> checkoutExistingBranch(
    String cwd,
    String branch,
  ) async {
    assertSafeGitRef(branch, 'branch');
    final resolution = await workspaceGitService.validateBranchRef(cwd, branch);
    if (resolution is NotFoundBranchCheckoutResolution) {
      throw PaseoServerServiceException('Branch not found: $branch');
    }
    await _ensureCleanWorkingTree(cwd);
    final result = await checkoutResolvedBranch(
      cwd: cwd,
      resolution: resolution,
      runner: runner,
    );
    await notifyGitMutation(
      cwd,
      GitMutationRefreshReason.switchBranch,
      invalidateForge: true,
    );
    return result;
  }

  /// Creates [newBranchName] off [baseBranch] and checks it out.
  ///
  /// No forge invalidation here: a brand-new branch cannot already have a pull
  /// request, so the cached forge state for [cwd] is still correct.
  Future<void> createBranchFromBase({
    required String cwd,
    required String baseBranch,
    required String newBranchName,
  }) async {
    assertSafeGitRef(baseBranch, 'base branch');
    assertSafeGitRef(newBranchName, 'new branch');

    final baseResolution = await workspaceGitService.validateBranchRef(
      cwd,
      baseBranch,
    );
    if (baseResolution is NotFoundBranchCheckoutResolution) {
      throw PaseoServerServiceException('Base branch not found: $baseBranch');
    }

    final exists = await workspaceGitService.hasLocalBranch(cwd, newBranchName);
    if (exists) {
      throw PaseoServerServiceException(
        'Branch already exists: $newBranchName',
      );
    }

    await _ensureCleanWorkingTree(cwd);
    await runner.run(['checkout', '-b', newBranchName, baseBranch], cwd: cwd);
    await notifyGitMutation(cwd, GitMutationRefreshReason.createBranch);
  }

  /// Forces a snapshot refresh after a mutation, optionally dropping the forge
  /// cache first.
  ///
  /// A failed refresh is logged and swallowed: the mutation already happened,
  /// and turning a stale snapshot into a failed command would be worse than
  /// letting the next poll catch up.
  Future<void> notifyGitMutation(
    String cwd,
    GitMutationRefreshReason reason, {
    bool invalidateForge = false,
  }) async {
    if (invalidateForge) {
      workspaceGitService.invalidateForge(cwd);
    }
    try {
      await workspaceGitService.getSnapshot(
        cwd,
        force: true,
        reason: reason.wireName,
      );
    } on Object catch (error) {
      logger.warn(
        'Failed to force-refresh workspace git snapshot after mutation',
        {'err': error, 'cwd': cwd, 'reason': reason.wireName},
      );
    }
  }

  Future<bool> _isWorkingTreeDirty(String cwd) async {
    final WorkspaceLocalGitSnapshot? snapshot;
    try {
      snapshot = await workspaceGitService.getSnapshot(cwd);
    } on Object catch (error) {
      throw PaseoServerServiceException(
        'Unable to inspect git status for $cwd: ${describeError(error)}',
        cause: error,
      );
    }
    // Upstream reads `snapshot.git.isDirty === true`, so anything that is not
    // literally `true` counts as clean. This repo's snapshot is nullable
    // (a non-git directory yields `null`) and its `isDirty` is non-nullable,
    // so the strict comparison collapses to this null-safe read.
    return snapshot?.isDirty == true;
  }

  Future<void> _ensureCleanWorkingTree(String cwd) async {
    if (await _isWorkingTreeDirty(cwd)) {
      throw const PaseoServerServiceException(
        'Working directory has uncommitted changes. Commit or stash before '
        'switching branches.',
      );
    }
  }
}

// ===========================================================================
// server/persistence-hooks.ts
// ===========================================================================

/// The serializable half of a stored agent's session config.
///
/// Only the fields persistence actually round-trips; the runtime-only parts of
/// `AgentSessionConfig` (daemon-appended prompts, launch context) are
/// deliberately absent because persisting them would freeze a daemon setting
/// into an agent record.
final class StoredAgentConfig {
  /// Creates a stored config section.
  const StoredAgentConfig({
    this.modeId,
    this.model,
    this.thinkingOptionId,
    this.featureValues,
    this.extra,
    this.systemPrompt,
    this.mcpServers,
  });

  /// Provider mode id at the time of the last save.
  final String? modeId;

  /// Model id.
  final String? model;

  /// Provider thinking-effort option id.
  final String? thinkingOptionId;

  /// Provider feature toggles.
  final Map<String, Object?>? featureValues;

  /// Provider-specific escape hatch.
  final Map<String, Object?>? extra;

  /// Persisted system prompt.
  final String? systemPrompt;

  /// Persisted MCP server map.
  final Map<String, Object?>? mcpServers;
}

/// The persistence handle as it sits inside a stored agent record.
///
/// Distinct from the protocol's [AgentPersistenceHandle] because a *stored*
/// handle may be incomplete — a record written before the provider reported a
/// session id has an empty `sessionId` — and [toAgentPersistenceHandle] is the
/// function that decides whether it is usable.
final class StoredAgentPersistence {
  /// Creates a stored persistence handle.
  const StoredAgentPersistence({
    required this.provider,
    required this.sessionId,
    this.nativeHandle,
    this.metadata,
  });

  /// Provider that owns the session.
  final String provider;

  /// Provider-native session id. May be empty in a partially written record.
  final String sessionId;

  /// Provider-native resume token, when the provider needs one.
  final String? nativeHandle;

  /// Free-form provider metadata.
  final Map<String, Object?>? metadata;
}

/// One agent as it is persisted to disk.
///
/// Deviation: this daemon's on-disk agent (`agent/agent_store.dart`'s
/// `PersistedAgent`, wrapping the protocol's [AgentSummary]) splits the same
/// information differently — it has no `config` sub-object, keeps `createdAt`
/// as epoch milliseconds, and carries the timeline inline. Rather than bend
/// either shape, upstream's record is ported as its own value type; it is the
/// input contract of these hooks, and a daemon adapter can map into it.
final class StoredAgentRecord {
  /// Creates a stored agent record.
  const StoredAgentRecord({
    required this.id,
    required this.provider,
    required this.cwd,
    required this.createdAt,
    required this.updatedAt,
    this.workspaceId,
    this.lastActivityAt,
    this.lastUserMessageAt,
    this.title,
    this.labels,
    this.lastModeId,
    this.config,
    this.persistence,
    this.archivedAt,
    this.owner,
  });

  /// Agent id.
  final String id;

  /// Provider id the agent runs on.
  final String provider;

  /// Working directory.
  final String cwd;

  /// ISO-8601 creation stamp.
  final String createdAt;

  /// ISO-8601 stamp of the last record write.
  final String updatedAt;

  /// Owning workspace, when the agent was created against one.
  final String? workspaceId;

  /// ISO-8601 stamp of the last *activity*, which supersedes [updatedAt] when
  /// present.
  final String? lastActivityAt;

  /// ISO-8601 stamp of the last user message.
  final String? lastUserMessageAt;

  /// Display title.
  final String? title;

  /// Free-form labels.
  final Map<String, String>? labels;

  /// Mode id observed most recently at runtime, which wins over the persisted
  /// config's mode.
  final String? lastModeId;

  /// Persisted session config.
  final StoredAgentConfig? config;

  /// Persisted resume handle.
  final StoredAgentPersistence? persistence;

  /// ISO-8601 archive stamp, or `null` while the agent is live.
  final String? archivedAt;

  /// Opaque owner descriptor.
  ///
  /// Upstream types this as `DaemonAgentOwner`, a schema this cluster never
  /// inspects — it only copies it through — so it stays an opaque map here
  /// instead of pulling an unrelated schema into the port.
  final Map<String, Object?>? owner;
}

/// A resolved session config, i.e. everything needed to start a provider
/// session.
final class AgentSessionConfig {
  /// Creates a session config.
  const AgentSessionConfig({
    required this.provider,
    required this.cwd,
    this.modeId,
    this.model,
    this.thinkingOptionId,
    this.featureValues,
    this.extra,
    this.systemPrompt,
    this.mcpServers,
  });

  /// Provider id.
  final String provider;

  /// Working directory.
  final String cwd;

  /// Provider mode id.
  final String? modeId;

  /// Model id.
  final String? model;

  /// Thinking-effort option id.
  final String? thinkingOptionId;

  /// Provider feature toggles.
  final Map<String, Object?>? featureValues;

  /// Provider-specific escape hatch.
  final Map<String, Object?>? extra;

  /// System prompt.
  final String? systemPrompt;

  /// MCP server map, or `null` when there is none left after stripping the
  /// internal server.
  final Map<String, Object?>? mcpServers;
}

/// The timestamp/identity block a resume needs to restore alongside the
/// session.
final class AgentRecordTimestamps {
  /// Creates a timestamp block.
  const AgentRecordTimestamps({
    required this.createdAt,
    required this.updatedAt,
    required this.lastUserMessageAt,
    this.labels,
    this.workspaceId,
    this.owner,
  });

  /// Parsed [StoredAgentRecord.createdAt].
  ///
  /// Deviation: JavaScript's `new Date("garbage")` yields an `Invalid Date`
  /// object rather than throwing. Dart has no such sentinel, so an unparseable
  /// stamp becomes `null` — the closest observable analogue, since both are
  /// unusable and neither throws.
  final DateTime? createdAt;

  /// Parsed [StoredAgentRecord.lastActivityAt], falling back to
  /// [StoredAgentRecord.updatedAt].
  final DateTime? updatedAt;

  /// Parsed [StoredAgentRecord.lastUserMessageAt], or `null`.
  final DateTime? lastUserMessageAt;

  /// Labels copied through unchanged.
  final Map<String, String>? labels;

  /// Workspace id copied through unchanged.
  final String? workspaceId;

  /// Owner copied through unchanged.
  final Map<String, Object?>? owner;
}

/// Whether [provider] is usable given the registered set.
///
/// A `null` [validProviders] means "no registry to check against", which
/// upstream treats as permissive. An *empty* iterable is not the same thing:
/// it means the registry is known and contains nothing, so every provider is
/// rejected.
bool isProviderRegistered(Iterable<String>? validProviders, String provider) {
  if (validProviders == null) {
    return true;
  }
  if (validProviders is Set<String>) {
    return validProviders.contains(provider);
  }
  return validProviders.toSet().contains(provider);
}

/// Whether the provider named by [record] is available.
bool isStoredAgentProviderAvailable(
  StoredAgentRecord record, [
  Iterable<String>? validProviders,
]) => isProviderRegistered(validProviders, record.provider);

/// Applies the internal-MCP-server strip to a persisted server map.
///
/// Reuses the daemon's [stripInternalAgentMcpServers] rather than re-deriving
/// the "is this our own injected server?" rule.
///
/// Deviation: the daemon's helper strips both the `tinyrack` and the legacy
/// `paseo` internal server, where upstream only knows about `paseo`. That is a
/// superset of upstream's behavior and is correct here — this daemon injects
/// the `tinyrack`-named server, so a record that persisted one must be
/// stripped for exactly the same reason.
///
/// Returns `null` when nothing survives, because upstream deletes the
/// `mcpServers` key entirely rather than leaving an empty object behind.
Map<String, Object?>? stripInternalMcpServers(Map<String, Object?>? servers) {
  if (servers == null) return null;
  final stripped = stripInternalAgentMcpServers(servers);
  return stripped.isEmpty ? null : stripped;
}

/// Projects a stored record onto the override set a resume applies.
///
/// Reuses the protocol's [AgentSessionConfigOverrides], which is exactly
/// upstream's `Partial<AgentSessionConfig>` for the fields persistence writes.
///
/// The mode precedence is `lastModeId` before `config.modeId`: the runtime
/// mode the agent was actually last in wins over the mode it was configured
/// with, so resuming a session that switched to plan mode does not silently
/// drop back.
AgentSessionConfigOverrides buildConfigOverrides(StoredAgentRecord record) {
  final config = record.config;
  return AgentSessionConfigOverrides(
    provider: record.provider,
    cwd: record.cwd,
    modeId: record.lastModeId ?? config?.modeId,
    model: config?.model,
    thinkingOptionId: config?.thinkingOptionId,
    featureValues: config?.featureValues,
    extra: config?.extra,
    systemPrompt: config?.systemPrompt,
    mcpServers: stripInternalMcpServers(config?.mcpServers),
  );
}

/// Builds the full session config a stored record should be restarted with.
///
/// Returns `null` when the record's provider is not registered, which is how
/// the loader distinguishes "cannot start this agent" from "failed to start
/// it".
///
/// The internal-MCP strip runs twice — once inside [buildConfigOverrides] and
/// once on the assembled config — exactly as upstream does. The second pass is
/// a no-op on the already-stripped map and is kept so the two functions stay
/// independently correct.
AgentSessionConfig? buildSessionConfig(
  StoredAgentRecord record, {
  Iterable<String>? validProviders,
}) {
  if (!isProviderRegistered(validProviders, record.provider)) {
    return null;
  }
  final overrides = buildConfigOverrides(record);
  return AgentSessionConfig(
    provider: record.provider,
    cwd: record.cwd,
    modeId: overrides.modeId,
    model: overrides.model,
    thinkingOptionId: overrides.thinkingOptionId,
    featureValues: overrides.featureValues,
    extra: overrides.extra,
    systemPrompt: overrides.systemPrompt,
    mcpServers: stripInternalMcpServers(overrides.mcpServers),
  );
}

/// Reads the timestamp/identity block off a stored record.
AgentRecordTimestamps extractTimestamps(StoredAgentRecord record) =>
    AgentRecordTimestamps(
      createdAt: DateTime.tryParse(record.createdAt),
      updatedAt: DateTime.tryParse(record.lastActivityAt ?? record.updatedAt),
      // Deviation: upstream guards with `record.lastUserMessageAt ? ... :
      // null`, JS truthiness, so an empty string yields `null` rather than an
      // Invalid Date. Spelled out here.
      lastUserMessageAt:
          record.lastUserMessageAt == null || record.lastUserMessageAt!.isEmpty
          ? null
          : DateTime.tryParse(record.lastUserMessageAt!),
      labels: record.labels,
      workspaceId: record.workspaceId,
      owner: record.owner,
    );

/// Converts a stored handle into a resumable protocol handle, or `null`.
///
/// Rejects three ways, all of which mean "resume is not possible, create a
/// fresh session instead": no handle at all, a handle for a provider that is
/// no longer registered, and a handle with no session id.
///
/// Deviation: upstream checks `!handle.sessionId`, JS truthiness, so an empty
/// string is rejected — reproduced explicitly. Upstream also distinguishes an
/// absent `nativeHandle` from an explicitly null one when spreading it into
/// the result; Dart's `String?` cannot express that difference, and the
/// protocol's [AgentPersistenceHandle] omits a null `nativeHandle` on
/// serialization, which matches the absent case.
AgentPersistenceHandle? toAgentPersistenceHandle(
  Iterable<String>? registeredProviders,
  StoredAgentPersistence? handle,
) {
  if (handle == null) {
    return null;
  }
  if (!isProviderRegistered(registeredProviders, handle.provider)) {
    return null;
  }
  if (handle.sessionId.isEmpty) {
    return null;
  }
  return AgentPersistenceHandle(
    provider: handle.provider,
    sessionId: handle.sessionId,
    nativeHandle: handle.nativeHandle,
    metadata: handle.metadata,
  );
}

/// One event from the agent manager's state stream.
///
/// Only `agent_state` matters to persistence, so the seam is narrowed to that
/// rather than mirroring the whole upstream event union.
final class AgentStateEvent {
  /// Creates an agent-state event.
  const AgentStateEvent({required this.agent, required this.closed});

  /// The agent's current snapshot.
  final AgentSummary agent;

  /// Whether the agent's lifecycle has reached `closed`.
  ///
  /// Deviation: upstream reads `event.agent.lifecycle === "closed"`. This
  /// daemon's [AgentSummary] has no `lifecycle` field — closure is a manager
  /// concern, not a persisted one — so the manager reports it alongside the
  /// snapshot.
  final bool closed;
}

/// The slice of the agent manager persistence subscribes to.
abstract interface class AgentStateSource {
  /// Subscribes to agent state changes, returning an unsubscribe callback.
  void Function() subscribe(void Function(AgentStateEvent event) listener);
}

/// The slice of agent storage persistence writes through.
abstract interface class AgentSnapshotStorage {
  /// Persists [agent] to disk.
  Future<void> applySnapshot(AgentSummary agent);
}

/// Flushes every `agent_state` snapshot to disk.
///
/// Closed agents are skipped: their final state was already written by the
/// close path, and re-persisting a torn-down agent would resurrect it in the
/// next load.
///
/// A failed write is logged, never thrown — persistence must not be able to
/// take down the manager's event loop.
///
/// Returns the unsubscribe callback.
void Function() attachAgentStoragePersistence(
  PaseoLoggerLike logger,
  AgentStateSource agentManager,
  AgentSnapshotStorage storage,
) {
  final log = logger.child({'module': 'persistence'});
  return agentManager.subscribe((event) {
    if (event.closed) {
      return;
    }
    unawaited(
      storage.applySnapshot(event.agent).catchError((Object error) {
        log.error('Failed to persist agent snapshot', {
          'err': error,
          'agentId': event.agent.agentId,
        });
      }),
    );
  });
}

// ===========================================================================
// server/agent/agent-loading.ts
// ===========================================================================

/// Why a provider session is being resumed.
///
/// Upstream models this as `AgentResumeSessionOptions { purpose?: "history" }`
/// and passes `undefined` for the interactive default. A nullable enum carries
/// the same two-state information.
enum AgentResumePurpose {
  /// Resumed only to read its timeline, never to take a turn. Providers use
  /// this to skip expensive interactive setup.
  history('history');

  const AgentResumePurpose(this.wireName);

  /// The literal upstream string.
  final String wireName;
}

/// The slice of the agent manager the loader drives.
///
/// Upstream expresses this as a `Pick` over `AgentManager`; Dart has no
/// structural picks, so it is an explicit interface. The optional halves of
/// the upstream `Partial<Pick<...>>` are separate interfaces below, following
/// this repo's existing capability-interface pattern
/// (`providers/agent_client.dart`).
///
/// A live agent is the protocol's [AgentSummary] — upstream's `ManagedAgent`.
abstract interface class AgentLoaderManager {
  /// Starts a brand-new session for [agentId] from [config].
  Future<AgentSummary> createAgent(
    AgentSessionConfig config,
    String agentId, {
    Map<String, String>? labels,
    String? workspaceId,
    Map<String, Object?>? owner,
  });

  /// The live agent for [agentId], or `null` when it is not loaded.
  AgentSummary? getAgent(String agentId);

  /// Providers currently registered in the runtime.
  Iterable<String> getRegisteredProviderIds();

  /// Pulls the provider's own history into the agent's timeline.
  ///
  /// [broadcast] is read at hydration time rather than passed as a flag so a
  /// second caller arriving mid-hydration can still upgrade the decision to
  /// "broadcast", which is the whole reason the pending map carries mutable
  /// options.
  Future<void> hydrateTimelineFromProvider(
    String agentId, {
    required bool Function() broadcast,
  });

  /// Resumes a persisted provider session.
  Future<AgentSummary> resumeAgentFromPersistence(
    AgentPersistenceHandle handle,
    AgentSessionConfigOverrides overrides,
    String agentId,
    AgentRecordTimestamps timestamps,
    AgentResumePurpose? purpose,
  );
}

/// Optional capability: managers that track per-agent activity can return the
/// live agent and mark it as touched in one step.
abstract interface class AgentActivityTouchingManager {
  /// Marks [agentId] active and returns it if loaded.
  AgentSummary? touchAgentActivity(String agentId);
}

/// Optional capability: managers that tear agents down asynchronously expose a
/// barrier so a reload cannot race an in-flight close.
abstract interface class AgentCloseAwaitingManager {
  /// Completes once no close for [agentId] is in flight.
  Future<void> waitForAgentClose(String agentId);
}

/// Optional capability: closing an agent.
abstract interface class AgentClosingManager {
  /// Closes [agentId].
  Future<void> closeAgent(String agentId);
}

/// A manager that can both load and close, which is what
/// [ensureUnarchivedAgentLoaded] needs.
///
/// Dart has no intersection types, so the combination upstream spells as
/// `AgentLoaderManager & Pick<AgentManager, "closeAgent">` is a named
/// interface.
abstract interface class ClosableAgentLoaderManager
    implements AgentLoaderManager, AgentClosingManager {}

/// The slice of agent storage the loader reads.
abstract interface class AgentRecordStorage {
  /// Reads the stored record for [agentId], or `null`.
  Future<StoredAgentRecord?> get(String agentId);
}

/// Everything [ensureAgentLoaded] needs.
class EnsureAgentLoadedDeps {
  /// Creates the dependency bundle.
  const EnsureAgentLoadedDeps({
    required this.agentManager,
    required this.agentStorage,
    required this.logger,
    this.validProviders,
    this.broadcastTimeline = false,
  });

  /// Manager that owns live agents.
  final AgentLoaderManager agentManager;

  /// Storage the record is read from.
  final AgentRecordStorage agentStorage;

  /// Where load outcomes are reported.
  final PaseoLoggerLike logger;

  /// Overrides the manager's registered provider set. `null` defers to the
  /// manager.
  final Iterable<String>? validProviders;

  /// Whether the hydrated timeline should be broadcast to subscribers.
  final bool broadcastTimeline;
}

/// [EnsureAgentLoadedDeps] narrowed to a manager that can also close.
final class EnsureUnarchivedAgentLoadedDeps extends EnsureAgentLoadedDeps {
  /// Creates the dependency bundle.
  EnsureUnarchivedAgentLoadedDeps({
    required ClosableAgentLoaderManager agentManager,
    required super.agentStorage,
    required super.logger,
    super.validProviders,
    super.broadcastTimeline,
  }) : closableAgentManager = agentManager,
       super(agentManager: agentManager);

  /// The same manager as [EnsureAgentLoadedDeps.agentManager], typed so
  /// `closeAgent` is reachable.
  final ClosableAgentLoaderManager closableAgentManager;
}

final class _PendingAgentInitializationOptions {
  _PendingAgentInitializationOptions(this.broadcastTimeline);

  bool broadcastTimeline;
}

final class _PendingAgentInitialization {
  const _PendingAgentInitialization(this.promise, this.options);

  final Future<AgentSummary> promise;
  final _PendingAgentInitializationOptions options;
}

/// Process-wide dedupe of concurrent loads.
///
/// Deliberately module-level, exactly as upstream: two RPC handlers racing to
/// open the same agent must share one initialization, and a per-instance map
/// would not deduplicate across the several call sites that build their own
/// dependency bundle. Entries are removed in a `finally`, so the map is empty
/// again between loads.
final Map<String, _PendingAgentInitialization> _pendingAgentInitializations =
    <String, _PendingAgentInitialization>{};

/// How many agent loads are currently in flight.
///
/// Exposed only so the dedupe invariant — the map drains — is assertable.
int get pendingAgentInitializationCount => _pendingAgentInitializations.length;

/// Loads [agentId], refusing if it is archived.
///
/// The archive check runs twice: once before loading, and once after, because
/// an archive request can land while the load is in flight. Losing that race
/// would leave an archived agent live and attached, so the second check closes
/// it back down before reporting the failure.
Future<AgentSummary> ensureUnarchivedAgentLoaded(
  String agentId,
  EnsureUnarchivedAgentLoadedDeps deps,
) async {
  final record = await deps.agentStorage.get(agentId);
  if (record?.archivedAt != null) {
    throw PaseoServerServiceException('Agent is archived: $agentId');
  }

  final agent = await ensureAgentLoaded(agentId, deps);
  final latestRecord = await deps.agentStorage.get(agentId);
  if (latestRecord?.archivedAt != null) {
    try {
      await deps.closableAgentManager.closeAgent(agentId);
    } on Object catch (error) {
      deps.logger.warn('Failed to close concurrently archived agent', {
        'err': error,
        'agentId': agentId,
      });
    }
    throw PaseoServerServiceException('Agent is archived: $agentId');
  }

  return agent;
}

/// Loads [agentId] into the manager, resuming or recreating it as needed.
///
/// The sequence is deliberately barrier, lookup, barrier, initialize:
/// a close may begin *after* the first barrier observed no in-flight work, so
/// once the live lookup comes back empty a second barrier closes that gap
/// before storage-backed resume begins. Without it a resume can attach to a
/// session the close is still tearing down.
Future<AgentSummary> ensureAgentLoaded(
  String agentId,
  EnsureAgentLoadedDeps deps,
) async {
  final manager = deps.agentManager;
  // Dart only promotes on `is` when the tested type is a subtype of the
  // declared one, and these capability interfaces deliberately are not, so the
  // optional halves of upstream's `Partial<Pick<...>>` are matched with a
  // binding pattern instead.
  if (manager case final AgentCloseAwaitingManager closeAwaiter) {
    await closeAwaiter.waitForAgentClose(agentId);
  }

  final inflight = _pendingAgentInitializations[agentId];
  if (inflight != null) {
    inflight.options.broadcastTimeline =
        inflight.options.broadcastTimeline || deps.broadcastTimeline;
    return inflight.promise;
  }

  final AgentSummary? existing;
  if (manager case final AgentActivityTouchingManager toucher) {
    existing = toucher.touchAgentActivity(agentId);
  } else {
    existing = manager.getAgent(agentId);
  }
  if (existing != null) {
    return existing;
  }

  if (manager case final AgentCloseAwaitingManager closeAwaiter) {
    await closeAwaiter.waitForAgentClose(agentId);
  }

  final laterInflight = _pendingAgentInitializations[agentId];
  if (laterInflight != null) {
    laterInflight.options.broadcastTimeline =
        laterInflight.options.broadcastTimeline || deps.broadcastTimeline;
    return laterInflight.promise;
  }

  final pendingOptions = _PendingAgentInitializationOptions(
    deps.broadcastTimeline,
  );
  final initFuture = _initializeAgent(agentId, deps, pendingOptions);
  final pending = _PendingAgentInitialization(initFuture, pendingOptions);
  _pendingAgentInitializations[agentId] = pending;

  try {
    return await initFuture;
  } finally {
    // Only clear the slot this call installed: a later load that already
    // replaced it must keep its own entry.
    if (identical(_pendingAgentInitializations[agentId], pending)) {
      _pendingAgentInitializations.remove(agentId);
    }
  }
}

Future<AgentSummary> _initializeAgent(
  String agentId,
  EnsureAgentLoadedDeps deps,
  _PendingAgentInitializationOptions pendingOptions,
) async {
  final record = await deps.agentStorage.get(agentId);
  if (record == null) {
    throw PaseoServerServiceException('Agent not found: $agentId');
  }

  final validProviders =
      deps.validProviders ?? deps.agentManager.getRegisteredProviderIds();
  if (!isStoredAgentProviderAvailable(record, validProviders)) {
    throw PaseoServerServiceException(
      "Agent $agentId references unavailable provider '${record.provider}'",
    );
  }

  final handle = toAgentPersistenceHandle(validProviders, record.persistence);

  final AgentSummary snapshot;
  if (handle != null) {
    snapshot = await deps.agentManager.resumeAgentFromPersistence(
      handle,
      buildConfigOverrides(record),
      agentId,
      extractTimestamps(record),
      // An archived record is only ever reopened to read its history, never to
      // take a turn, so the provider is told not to spin up interactive
      // machinery.
      record.archivedAt != null ? AgentResumePurpose.history : null,
    );
    deps.logger.info('Agent resumed from persistence', {
      'agentId': agentId,
      'provider': record.provider,
    });
  } else {
    final config = buildSessionConfig(record, validProviders: validProviders);
    if (config == null) {
      throw PaseoServerServiceException(
        "Agent $agentId references unavailable provider '${record.provider}'",
      );
    }
    snapshot = await deps.agentManager.createAgent(
      config,
      agentId,
      labels: record.labels,
      workspaceId: record.workspaceId,
      owner: record.owner,
    );
    deps.logger.info('Agent created from stored config', {
      'agentId': agentId,
      'provider': record.provider,
    });
  }

  await deps.agentManager.hydrateTimelineFromProvider(
    agentId,
    broadcast: () => pendingOptions.broadcastTimeline,
  );
  return deps.agentManager.getAgent(agentId) ?? snapshot;
}

// ===========================================================================
// server/auto-archive-on-merge/archive-if-safe.ts
// ===========================================================================

/// Whether a path is inside this daemon's private worktree tree.
final class PaseoWorktreeOwnership {
  /// Creates an ownership verdict.
  const PaseoWorktreeOwnership({
    required this.allowed,
    this.repoRoot,
    this.worktreeRoot,
    this.worktreePath,
  });

  /// Whether the daemon may delete this directory.
  final bool allowed;

  /// Main repository root, when git could still be reached. Best-effort: a
  /// half-removed worktree may have lost its admin directory and still be
  /// safe to archive.
  final String? repoRoot;

  /// The `<worktrees-base>/<hash>` directory that owns this worktree.
  final String? worktreeRoot;

  /// The normalized path that was checked.
  final String? worktreePath;
}

/// The daemon config fields auto-archive reads.
final class AutoArchiveDaemonConfig {
  /// Creates a config snapshot.
  const AutoArchiveDaemonConfig({this.autoArchiveAfterMerge});

  /// Whether merged worktrees should be archived automatically.
  ///
  /// Deliberately tri-state: upstream tests `!== true`, so an unset value
  /// blocks archiving just as `false` does. Modelling it as a non-nullable
  /// `bool` would silently pick a default for a config the user never wrote.
  final bool? autoArchiveAfterMerge;
}

/// The daemon config store slice auto-archive reads.
abstract interface class AutoArchiveConfigStore {
  /// Reads the current config.
  AutoArchiveDaemonConfig get();
}

/// The workspace lookup pair forwarded into workspace resolution.
///
/// Kept as its own value so the forwarding is observable — upstream's suite
/// asserts that `resolveWorkspaceIdAtPath` receives exactly these two
/// callbacks.
final class AutoArchiveWorkspaceLookup {
  /// Creates the lookup pair.
  const AutoArchiveWorkspaceLookup({
    required this.findWorkspaceIdForCwd,
    required this.listActiveWorkspaces,
  });

  /// Resolves a path to a workspace id.
  ///
  /// In this daemon the natural implementation is
  /// `resolveWorkspaceIdForPath` from
  /// `workspace/paseo_workspace_identity.dart`, which already owns the
  /// exact-match-then-deepest-enclosing rule.
  final Future<String?> Function(String cwd) findWorkspaceIdForCwd;

  /// Lists every live workspace.
  final Future<List<PersistedWorkspaceRecord>> Function() listActiveWorkspaces;
}

/// Everything the auto-archive path needs to actually archive.
///
/// Most of these exist to be forwarded verbatim into the archive routine; only
/// [daemonConfigStore], [workspaceGitService], [paseoHome] and
/// [paseoWorktreesBaseRoot] are read by [archiveIfSafe] itself.
final class AutoArchiveArchiveOptions {
  /// Creates the options bundle.
  const AutoArchiveArchiveOptions({
    required this.paseoHome,
    required this.daemonConfigStore,
    required this.workspaceGitService,
    required this.workspaceLookup,
    required this.archiveWorkspaceRecord,
    required this.markWorkspaceArchiving,
    required this.clearWorkspaceArchiving,
    required this.emitWorkspaceUpdatesForWorkspaceIds,
    this.paseoWorktreesBaseRoot,
  });

  /// The daemon home, which anchors the private worktree tree.
  final String paseoHome;

  /// Overrides the worktree base root; `null` derives it from [paseoHome].
  final String? paseoWorktreesBaseRoot;

  /// Where the `autoArchiveAfterMerge` setting is read from.
  final AutoArchiveConfigStore daemonConfigStore;

  /// Where the post-merge git snapshot is read from.
  final WorkspaceGitSnapshotSource workspaceGitService;

  /// How a path becomes a workspace id.
  final AutoArchiveWorkspaceLookup workspaceLookup;

  /// Marks a workspace record archived.
  final Future<void> Function(String workspaceId) archiveWorkspaceRecord;

  /// Flags workspaces as archiving so clients can render the transition.
  final void Function(Iterable<String> workspaceIds, String archivingAt)
  markWorkspaceArchiving;

  /// Clears the archiving flag.
  final void Function(Iterable<String> workspaceIds) clearWorkspaceArchiving;

  /// Pushes workspace updates to subscribers.
  final Future<void> Function(Iterable<String> workspaceIds)
  emitWorkspaceUpdatesForWorkspaceIds;
}

/// What is being archived.
///
/// Upstream's union also has a `worktree` arm keyed by path; auto-archive only
/// ever produces the workspace arm, so only that arm is ported and the type is
/// left sealed so adding the other one later is a compile error at every match
/// site rather than a silent fallthrough.
sealed class ArchiveScope {
  const ArchiveScope();
}

/// Archive one workspace by id.
final class WorkspaceArchiveScope extends ArchiveScope {
  /// Creates a workspace scope.
  const WorkspaceArchiveScope(this.workspaceId);

  /// The workspace to archive.
  final String workspaceId;

  @override
  bool operator ==(Object other) =>
      other is WorkspaceArchiveScope && other.workspaceId == workspaceId;

  @override
  int get hashCode => workspaceId.hashCode;

  @override
  String toString() => 'WorkspaceArchiveScope($workspaceId)';
}

/// The request handed to the archive routine.
final class ArchiveByScopeRequest {
  /// Creates an archive request.
  const ArchiveByScopeRequest({required this.scope, required this.requestId});

  /// What to archive.
  final ArchiveScope scope;

  /// Correlation id; auto-archive always uses `auto-archive-on-merge`.
  final String requestId;
}

/// The dependency bundle the archive routine is invoked with.
///
/// Upstream builds this object inline; it is named here so the forwarding of
/// [AutoArchiveArchiveOptions] and of the per-workspace terminal kill is
/// observable to a test.
final class ArchiveByScopeInvocation {
  /// Creates an invocation bundle.
  const ArchiveByScopeInvocation({
    required this.options,
    required this.killTerminalsForWorkspace,
    required this.sessionLogger,
  });

  /// The forwarded options.
  final AutoArchiveArchiveOptions options;

  /// Terminates every terminal attached to a workspace.
  final Future<void> Function(String workspaceId) killTerminalsForWorkspace;

  /// Logger the archive routine should report through.
  final PaseoLoggerLike sessionLogger;
}

/// Archives everything in scope. No daemon counterpart exists yet — this
/// daemon archives workspaces through `workspace/workspace_v2_service.dart`,
/// which is not scope-shaped — so it stays an injected seam.
typedef ArchiveByScope =
    Future<void> Function(
      ArchiveByScopeInvocation invocation,
      ArchiveByScopeRequest request,
    );

/// Resolves a filesystem path to the single workspace that owns it.
typedef ResolveWorkspaceIdAtPath =
    Future<String?> Function(
      AutoArchiveWorkspaceLookup lookup,
      String targetPath,
    );

/// Decides whether a path is a daemon-owned worktree.
typedef IsPaseoOwnedWorktreeCwd =
    Future<PaseoWorktreeOwnership> Function(
      String cwd, {
      String? paseoHome,
      String? worktreesRoot,
    });

/// Kills a workspace's terminals.
typedef KillTerminalsForWorkspace =
    Future<void> Function(
      AutoArchiveArchiveOptions options,
      PaseoLoggerLike sessionLogger,
      String workspaceId,
    );

/// The four collaborators [archiveIfSafe] calls out to.
///
/// Injected as a bundle so the decision logic — which is the whole point of
/// the module — can be tested without a real archive.
final class ArchiveIfSafeDependencies {
  /// Creates the dependency bundle.
  const ArchiveIfSafeDependencies({
    required this.archiveByScope,
    required this.resolveWorkspaceIdAtPath,
    required this.isPaseoOwnedWorktreeCwd,
    required this.killTerminalsForWorkspace,
  });

  /// Performs the archive.
  final ArchiveByScope archiveByScope;

  /// Resolves the merged path to a workspace.
  final ResolveWorkspaceIdAtPath resolveWorkspaceIdAtPath;

  /// Guards against archiving a directory the daemon does not own.
  final IsPaseoOwnedWorktreeCwd isPaseoOwnedWorktreeCwd;

  /// Terminates the workspace's terminals during the archive.
  final KillTerminalsForWorkspace killTerminalsForWorkspace;
}

/// The correlation id every auto-archive uses.
const String autoArchiveOnMergeRequestId = 'auto-archive-on-merge';

/// Archives the worktree at [cwd] if — and only if — doing so cannot lose
/// work.
///
/// The guards are ordered cheapest-first and each one is a reason not to
/// archive:
///
/// 1. the pull request is not merged (nothing to clean up);
/// 2. the user has not opted in;
/// 3. an archive for this cwd is already running;
/// 4. the snapshot cannot be read (fail closed, and say so);
/// 5. there is no snapshot at all;
/// 6. the tree is dirty — uncommitted work would be destroyed;
/// 7. the branch is ahead of origin — unpushed commits would be destroyed;
/// 8. the directory is not one this daemon created.
///
/// Every exit path clears the in-flight marker, including the failure paths,
/// so a transient error cannot wedge a cwd out of auto-archiving forever.
Future<void> archiveIfSafe({
  required String cwd,
  required ForgePullRequestStatus? pullRequest,
  required Set<String> inFlight,
  required AutoArchiveArchiveOptions options,
  required PaseoLoggerLike log,
  required ArchiveIfSafeDependencies deps,
}) async {
  // Upstream's `!pullRequest?.isMerged` is JS truthiness over an optional
  // chain: a missing PR and an unmerged PR are the same answer.
  if (pullRequest?.isMerged != true) {
    return;
  }
  if (options.daemonConfigStore.get().autoArchiveAfterMerge != true) {
    return;
  }
  if (inFlight.contains(cwd)) {
    return;
  }

  inFlight.add(cwd);
  try {
    final WorkspaceLocalGitSnapshot? snapshot;
    try {
      snapshot = await options.workspaceGitService.getSnapshot(
        cwd,
        reason: autoArchiveOnMergeRequestId,
      );
    } on Object catch (error) {
      log.warn('Failed to read snapshot for auto-archive; skipping', {
        'err': error,
        'cwd': cwd,
      });
      return;
    }
    if (snapshot == null) {
      return;
    }

    if (snapshot.isDirty) {
      return;
    }
    // Upstream guards with `typeof ... === "number"`, which excludes the
    // "unknown" case where the upstream branch was deleted along with the
    // merge. That case must still archive, so a null ahead-count is not a
    // reason to stop.
    final aheadOfOrigin = snapshot.aheadOfOrigin;
    if (aheadOfOrigin != null && aheadOfOrigin > 0) {
      return;
    }

    final ownership = await deps.isPaseoOwnedWorktreeCwd(
      cwd,
      paseoHome: options.paseoHome,
      worktreesRoot: options.paseoWorktreesBaseRoot,
    );
    if (!ownership.allowed) {
      return;
    }

    try {
      final workspaceId = await deps.resolveWorkspaceIdAtPath(
        options.workspaceLookup,
        cwd,
      );
      if (workspaceId == null) {
        log.warn(
          'Auto-archive could not resolve a workspace for cwd; '
          'skipping',
          {'cwd': cwd},
        );
        return;
      }

      await deps.archiveByScope(
        ArchiveByScopeInvocation(
          options: options,
          killTerminalsForWorkspace: (workspaceIdToKill) =>
              deps.killTerminalsForWorkspace(options, log, workspaceIdToKill),
          sessionLogger: log,
        ),
        ArchiveByScopeRequest(
          scope: WorkspaceArchiveScope(workspaceId),
          requestId: autoArchiveOnMergeRequestId,
        ),
      );
      log.info('Auto-archived worktree after PR merge', {'cwd': cwd});
    } on Object catch (error) {
      log.warn('Auto-archive after merge failed', {'err': error, 'cwd': cwd});
    }
  } finally {
    inFlight.remove(cwd);
  }
}

/// Bridges [GitCommandRuntimeMetricsWindow] onto [GitCommandObserver].
///
/// `GitRunner` has no queue of its own — it starts the process immediately —
/// so submit and start collapse into one call and every queue-wait sample is
/// zero. That is accurate rather than a shortcut: the wait upstream measures
/// is limiter backpressure, and this runner has no limiter.
final class _WindowGitCommandObserver implements GitCommandObserver {
  _WindowGitCommandObserver(this._window);

  final GitCommandRuntimeMetricsWindow _window;

  @override
  Object? begin(String operation) {
    final metric = _window.submit(operation);
    _window.start(metric);
    return metric;
  }

  @override
  void end(Object? handle, {required bool success}) {
    if (handle is! GitCommandRuntimeMetric) return;
    // `timedOut` is always false: this runner imposes no deadline, so a hang
    // shows up as a never-completed command rather than a timeout.
    _window.finish(handle, success: success, timedOut: false);
  }
}
