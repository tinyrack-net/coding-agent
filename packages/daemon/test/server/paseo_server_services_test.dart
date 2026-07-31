// Port of the frozen Paseo 0.2.0 suites
// `utils/git-command-runtime-metrics.test.ts`, `server/logger.test.ts`,
// `server/session/git-mutation/git-mutation-service.test.ts`,
// `server/persistence-hooks.test.ts`, `server/agent/agent-loading.test.ts` and
// `server/auto-archive-on-merge/archive-if-safe.test.ts`.
//
// Where upstream crosses the real git boundary (the two git-mutation
// happy-path tests) this suite does too, against a temp repo, following the
// pattern already established in `test/workspace/`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/forge/forge_models.dart';
import 'package:agent_daemon/src/git/git_runner.dart';
import 'package:agent_daemon/src/paseo_server_env.dart';
import 'package:agent_daemon/src/server/paseo_server_services.dart';
import 'package:agent_daemon/src/workspace/polling_workspace_git_backend.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Shared fixtures
// ---------------------------------------------------------------------------

/// Records every line a [PaseoLogger] emits, and doubles as the
/// [PaseoLoggerLike] fake the non-logger sections assert against.
final class RecordingLogger implements PaseoLoggerLike {
  RecordingLogger([this.bindings = const {}]);

  final Map<String, Object?> bindings;
  final List<RecordedLogLine> lines = [];

  List<RecordedLogLine> at(LogLevel level) =>
      lines.where((line) => line.level == level).toList();

  void _record(LogLevel level, String message, Map<String, Object?>? fields) {
    lines.add(
      RecordedLogLine(
        level: level,
        message: message,
        fields: {...bindings, ...?fields},
      ),
    );
  }

  @override
  void trace(String message, [Map<String, Object?>? fields]) =>
      _record(LogLevel.trace, message, fields);

  @override
  void debug(String message, [Map<String, Object?>? fields]) =>
      _record(LogLevel.debug, message, fields);

  @override
  void info(String message, [Map<String, Object?>? fields]) =>
      _record(LogLevel.info, message, fields);

  @override
  void warn(String message, [Map<String, Object?>? fields]) =>
      _record(LogLevel.warn, message, fields);

  @override
  void error(String message, [Map<String, Object?>? fields]) =>
      _record(LogLevel.error, message, fields);

  @override
  void fatal(String message, [Map<String, Object?>? fields]) =>
      _record(LogLevel.fatal, message, fields);

  @override
  PaseoLoggerLike child(Map<String, Object?> childBindings) {
    final childLogger = RecordingLogger({...bindings, ...childBindings});
    // Children are tracked so `allLines` can present one transcript and
    // assertions do not have to know which logger a call site happened to use.
    _children.add(childLogger);
    return childLogger;
  }

  final List<RecordingLogger> _children = [];

  /// Every line this logger and its children emitted.
  List<RecordedLogLine> get allLines => [
    ...lines,
    for (final child in _children) ...child.allLines,
  ];
}

final class RecordedLogLine {
  const RecordedLogLine({
    required this.level,
    required this.message,
    required this.fields,
  });

  final LogLevel level;
  final String message;
  final Map<String, Object?> fields;

  @override
  String toString() => '${level.wireName} $message $fields';
}

WorkspaceLocalGitSnapshot buildSnapshot({
  String cwd = '/tmp/repo',
  bool isDirty = false,
  num? aheadOfOrigin = 0,
  num? behindOfOrigin = 0,
}) => WorkspaceLocalGitSnapshot(
  cwd: cwd,
  repoRoot: '/tmp/repo',
  mainRepoRoot: '/tmp/repo',
  currentBranch: 'feature',
  headSha: 'abc123',
  remoteUrl: 'https://github.com/acme/repo.git',
  isDirty: isDirty,
  baseRef: 'main',
  aheadBehind: const WorkspaceAheadBehind(ahead: 0, behind: 0),
  aheadOfOrigin: aheadOfOrigin,
  behindOfOrigin: behindOfOrigin,
  diffStat: const WorkspaceDiffStat(additions: 0, deletions: 0),
);

// ---------------------------------------------------------------------------
// git-command-runtime-metrics.ts
// ---------------------------------------------------------------------------

final class _ManualClock {
  int now = 1000;

  int call() => now;

  void advance(int ms) => now += ms;
}

void gitCommandRuntimeMetricsTests() {
  group('GitCommandRuntimeMetricsWindow', () {
    late _ManualClock clock;

    GitCommandRuntimeMetricsWindow window([int concurrencyLimit = 2]) =>
        GitCommandRuntimeMetricsWindow(concurrencyLimit, clock.call);

    setUp(() => clock = _ManualClock());

    test('separates queue wait from execution time', () {
      final metrics = window();
      final command = metrics.submit('status');
      clock.advance(40);
      metrics.start(command);
      clock.advance(15);
      metrics.finish(command, success: true, timedOut: false);

      final snapshot = metrics.snapshotAndReset();
      expect(snapshot.submitted, 1);
      expect(snapshot.started, 1);
      expect(snapshot.completed, 1);
      expect(snapshot.failed, 0);
      expect(snapshot.timedOut, 0);
      expect(
        snapshot.queueWaitMs,
        const GitCommandDurationStats(
          count: 1,
          p50Ms: 40,
          p95Ms: 40,
          maxMs: 40,
        ),
      );
      expect(
        snapshot.executionMs,
        const GitCommandDurationStats(
          count: 1,
          p50Ms: 15,
          p95Ms: 15,
          maxMs: 15,
        ),
      );
      expect(snapshot.operationsTop, [
        const GitCommandOperationCount('status', 1),
      ]);
    });

    test('reports live queue pressure across window resets', () {
      final metrics = window(1);
      final active = metrics.submit('fetch');
      metrics.start(active);
      final pending = metrics.submit('rev-parse');
      metrics.observeLimiter(1, 1);
      clock.advance(25);

      final first = metrics.snapshotAndReset();
      expect(first.concurrencyLimit, 1);
      expect(first.active, 1);
      expect(first.pending, 1);
      expect(first.peakActive, 1);
      expect(first.peakPending, 1);
      expect(first.oldestPendingMs, 25);
      expect(first.submitted, 2);
      expect(first.started, 1);

      clock.advance(10);
      metrics.finish(active, success: true, timedOut: false);
      metrics.start(pending);
      metrics.observeLimiter(1, 0);
      clock.advance(5);
      metrics.finish(pending, success: false, timedOut: true);

      final second = metrics.snapshotAndReset();
      expect(second.active, 0);
      expect(second.pending, 0);
      expect(second.peakActive, 1);
      expect(second.peakPending, 1);
      expect(second.submitted, 0);
      expect(second.started, 1);
      expect(second.completed, 2);
      expect(second.failed, 1);
      expect(second.timedOut, 1);
      expect(
        second.queueWaitMs,
        const GitCommandDurationStats(
          count: 1,
          p50Ms: 35,
          p95Ms: 35,
          maxMs: 35,
        ),
      );
    });

    test('an untouched window reports zeroes, not an infinite pending age', () {
      final snapshot = window().snapshotAndReset();
      expect(snapshot.active, 0);
      expect(snapshot.pending, 0);
      expect(snapshot.oldestPendingMs, 0);
      expect(snapshot.queueWaitMs, GitCommandDurationStats.empty);
      expect(snapshot.executionMs, GitCommandDurationStats.empty);
      expect(snapshot.operationsTop, isEmpty);
    });

    test('oldestPendingMs stays zero when the limiter reports no queue', () {
      final metrics = window();
      metrics.submit('status');
      clock.advance(500);

      // The window still holds the pending handle, but the limiter is the
      // authority: it says nothing is queued, so no age is reported.
      final snapshot = metrics.snapshotAndReset(
        const GitCommandLimiterState(active: 0, pending: 0),
      );
      expect(snapshot.oldestPendingMs, 0);
    });

    test('reports the age of the oldest queued command, not the newest', () {
      final metrics = window();
      metrics.submit('old');
      clock.advance(100);
      metrics.submit('new');
      clock.advance(10);

      final snapshot = metrics.snapshotAndReset();
      expect(snapshot.pending, 2);
      expect(snapshot.oldestPendingMs, 110);
    });

    test('finishing a command that never started is ignored', () {
      final metrics = window();
      final command = metrics.submit('status');
      metrics.finish(command, success: false, timedOut: true);

      final snapshot = metrics.snapshotAndReset();
      expect(snapshot.completed, 0);
      expect(snapshot.failed, 0);
      expect(snapshot.timedOut, 0);
      expect(snapshot.executionMs.count, 0);
    });

    test('finishing twice counts once and never drives active negative', () {
      final metrics = window();
      final command = metrics.submit('status');
      metrics.start(command);
      clock.advance(5);
      metrics.finish(command, success: true, timedOut: false);
      metrics.finish(command, success: true, timedOut: false);

      final snapshot = metrics.snapshotAndReset();
      expect(snapshot.completed, 1);
      expect(snapshot.active, 0);
    });

    test('starting the same handle twice counts once', () {
      final metrics = window();
      final command = metrics.submit('status');
      clock.advance(7);
      metrics.start(command);
      clock.advance(7);
      metrics.start(command);

      final snapshot = metrics.snapshotAndReset();
      expect(snapshot.started, 1);
      expect(snapshot.queueWaitMs.count, 1);
      expect(snapshot.queueWaitMs.maxMs, 7);
    });

    test('observeLimiter only ever raises the high-water marks', () {
      final metrics = window();
      metrics.observeLimiter(9, 12);
      metrics.observeLimiter(1, 1);

      final snapshot = metrics.snapshotAndReset(
        const GitCommandLimiterState(active: 0, pending: 0),
      );
      expect(snapshot.peakActive, 9);
      expect(snapshot.peakPending, 12);
    });

    test('operationsTop sorts by count then name and keeps twelve', () {
      final metrics = window();
      for (var index = 0; index < 14; index++) {
        metrics.submit('op-${index.toString().padLeft(2, '0')}');
      }
      // "status" and "diff" tie at two; the alphabetically smaller wins.
      metrics.submit('status');
      metrics.submit('status');
      metrics.submit('diff');
      metrics.submit('diff');

      final snapshot = metrics.snapshotAndReset();
      expect(snapshot.operationsTop.length, gitCommandOperationsTopLimit);
      expect(snapshot.operationsTop.first.operation, 'diff');
      expect(snapshot.operationsTop.first.count, 2);
      expect(snapshot.operationsTop[1].operation, 'status');
      expect(
        snapshot.operationsTop.skip(2).every((entry) => entry.count == 1),
        isTrue,
      );
    });

    test('a repeated operation label yields distinct timing handles', () {
      final metrics = window();
      final first = metrics.submit('status');
      final second = metrics.submit('status');
      expect(identical(first, second), isFalse);

      metrics.start(first);
      clock.advance(3);
      metrics.finish(first, success: true, timedOut: false);

      final snapshot = metrics.snapshotAndReset();
      expect(snapshot.submitted, 2);
      expect(snapshot.started, 1);
      expect(snapshot.operationsTop, [
        const GitCommandOperationCount('status', 2),
      ]);
    });

    test('a clock that runs backwards cannot produce negative samples', () {
      final metrics = window();
      final command = metrics.submit('status');
      clock.now -= 50;
      metrics.start(command);
      clock.now -= 50;
      metrics.finish(command, success: true, timedOut: false);

      final snapshot = metrics.snapshotAndReset();
      expect(snapshot.queueWaitMs.maxMs, 0);
      expect(snapshot.executionMs.maxMs, 0);
    });
  });

  group('summarizeGitCommandDurations', () {
    test('an empty series is all zeroes', () {
      expect(summarizeGitCommandDurations([]), GitCommandDurationStats.empty);
    });

    test('percentiles index the sorted series the way upstream does', () {
      final stats = summarizeGitCommandDurations([
        for (var value = 1; value <= 20; value++) value,
      ]);
      expect(stats.count, 20);
      // floor(20 / 2) == 10 -> the 11th smallest sample.
      expect(stats.p50Ms, 11);
      // ceil(20 * 0.95) - 1 == 18 -> the 19th smallest sample.
      expect(stats.p95Ms, 19);
      expect(stats.maxMs, 20);
    });

    test('a single sample is its own p50, p95 and max', () {
      final stats = summarizeGitCommandDurations([42]);
      expect(
        stats,
        const GitCommandDurationStats(
          count: 1,
          p50Ms: 42,
          p95Ms: 42,
          maxMs: 42,
        ),
      );
    });

    test('the input series is not reordered', () {
      final samples = [5, 1, 3];
      summarizeGitCommandDurations(samples);
      expect(samples, [5, 1, 3]);
    });
  });
}

// ---------------------------------------------------------------------------
// logger.ts
// ---------------------------------------------------------------------------

void loggerTests() {
  group('resolveLogConfig', () {
    const paseoHome = '/tmp/paseo-logger-tests';

    test('defaults to stdout JSON without file logging', () {
      final result = resolveLogConfig(null, paseoHome: paseoHome);

      expect(result.level, LogLevel.info);
      expect(
        result.console,
        const ResolvedConsoleLogConfig(
          level: LogLevel.info,
          format: LogFormat.json,
        ),
      );
      expect(result.file, isNull);
    });

    test('keeps legacy level and format as stdout configuration', () {
      final result = resolveLogConfig(
        const LegacyLoggerConfig(
          level: LogLevel.warn,
          format: LogFormat.pretty,
        ),
        paseoHome: paseoHome,
      );

      expect(result.level, LogLevel.warn);
      expect(
        result.console,
        const ResolvedConsoleLogConfig(
          level: LogLevel.warn,
          format: LogFormat.pretty,
        ),
      );
      expect(result.file, isNull);
    });

    test('enables file output only when log.file is present', () {
      final result = resolveLogConfig(
        const StructuredLoggerConfig(
          log: PersistedLogConfig(
            console: PersistedConsoleLogConfig(
              level: LogLevel.warn,
              format: LogFormat.json,
            ),
            file: PersistedFileLogConfig(
              level: LogLevel.debug,
              path: 'logs/programmatic.log',
            ),
          ),
        ),
        paseoHome: paseoHome,
      );

      expect(result.level, LogLevel.debug);
      expect(
        result.console,
        const ResolvedConsoleLogConfig(
          level: LogLevel.warn,
          format: LogFormat.json,
        ),
      );
      expect(
        result.file,
        ResolvedFileLogConfig(
          level: LogLevel.debug,
          path: p.normalize(p.join(paseoHome, 'logs', 'programmatic.log')),
        ),
      );
    });

    test('defaults file output to info when log.file has no level', () {
      final result = resolveLogConfig(
        const StructuredLoggerConfig(
          log: PersistedLogConfig(
            console: PersistedConsoleLogConfig(level: LogLevel.warn),
            file: PersistedFileLogConfig(path: 'daemon.log'),
          ),
        ),
        paseoHome: paseoHome,
      );

      expect(result.level, LogLevel.info);
      expect(
        result.console,
        const ResolvedConsoleLogConfig(
          level: LogLevel.warn,
          format: LogFormat.json,
        ),
      );
      expect(
        result.file,
        ResolvedFileLogConfig(
          level: LogLevel.info,
          path: p.normalize(p.join(paseoHome, 'daemon.log')),
        ),
      );
    });

    test('the legacy global level seeds both destinations', () {
      final result = resolveLogConfig(
        const StructuredLoggerConfig(
          log: PersistedLogConfig(
            level: LogLevel.debug,
            file: PersistedFileLogConfig(),
          ),
        ),
        paseoHome: paseoHome,
      );

      expect(result.console.level, LogLevel.debug);
      expect(result.file?.level, LogLevel.debug);
      expect(result.level, LogLevel.debug);
    });

    test('a file section with no path falls back to daemon.log', () {
      final result = resolveLogConfig(
        const StructuredLoggerConfig(
          log: PersistedLogConfig(file: PersistedFileLogConfig()),
        ),
        paseoHome: paseoHome,
      );

      expect(result.file?.path, p.join(paseoHome, defaultDaemonLogFilename));
    });

    test('an empty file path is treated as no path at all', () {
      final result = resolveLogConfig(
        const StructuredLoggerConfig(
          log: PersistedLogConfig(file: PersistedFileLogConfig(path: '')),
        ),
        paseoHome: paseoHome,
      );

      expect(result.file?.path, p.join(paseoHome, defaultDaemonLogFilename));
    });

    test('an absolute file path is used verbatim', () {
      final absolute = p.join(
        Directory.systemTemp.path,
        'paseo-explicit',
        'daemon.log',
      );
      final result = resolveLogConfig(
        const StructuredLoggerConfig(
          log: PersistedLogConfig(file: PersistedFileLogConfig()),
        ).withPath(absolute),
        paseoHome: paseoHome,
      );

      expect(result.file?.path, absolute);
    });

    test('file: false suppresses a configured file destination', () {
      final result = resolveLogConfig(
        const StructuredLoggerConfig(
          log: PersistedLogConfig(
            file: PersistedFileLogConfig(level: LogLevel.debug),
          ),
        ),
        paseoHome: paseoHome,
        file: false,
      );

      expect(result.file, isNull);
      // The root level now follows the console alone, not the suppressed file.
      expect(result.level, LogLevel.info);
    });

    test('the root level is the most verbose enabled destination', () {
      final result = resolveLogConfig(
        const StructuredLoggerConfig(
          log: PersistedLogConfig(
            console: PersistedConsoleLogConfig(level: LogLevel.error),
            file: PersistedFileLogConfig(level: LogLevel.trace),
          ),
        ),
        paseoHome: paseoHome,
      );

      expect(result.level, LogLevel.trace);
    });

    test('console overrides beat the legacy globals', () {
      final result = resolveLogConfig(
        const StructuredLoggerConfig(
          log: PersistedLogConfig(
            level: LogLevel.error,
            format: LogFormat.json,
            console: PersistedConsoleLogConfig(
              level: LogLevel.trace,
              format: LogFormat.pretty,
            ),
          ),
        ),
        paseoHome: paseoHome,
      );

      expect(result.console.level, LogLevel.trace);
      expect(result.console.format, LogFormat.pretty);
    });
  });

  group('LoggerConfigInput.fromJson', () {
    test('null stays null', () {
      expect(LoggerConfigInput.fromJson(null), isNull);
    });

    test('a config with a log key is structured', () {
      final input = LoggerConfigInput.fromJson({
        'log': {
          'console': {'level': 'warn'},
          'file': {'level': 'debug', 'path': 'logs/x.log'},
        },
      });

      expect(input, isA<StructuredLoggerConfig>());
      final log = (input! as StructuredLoggerConfig).log;
      expect(log?.console?.level, LogLevel.warn);
      expect(log?.file?.level, LogLevel.debug);
      expect(log?.file?.path, 'logs/x.log');
    });

    test('a bare level/format config is legacy', () {
      final input = LoggerConfigInput.fromJson({
        'level': 'warn',
        'format': 'pretty',
      });

      expect(input, isA<LegacyLoggerConfig>());
      expect((input! as LegacyLoggerConfig).level, LogLevel.warn);
      expect((input as LegacyLoggerConfig).format, LogFormat.pretty);
    });

    test('a config with neither shape has no log section', () {
      final input = LoggerConfigInput.fromJson({'version': 1});
      expect((input! as StructuredLoggerConfig).log, isNull);
    });

    test('an unrecognized level is dropped rather than throwing', () {
      final input = LoggerConfigInput.fromJson({'level': 'shout'});
      expect((input! as LegacyLoggerConfig).level, isNull);
      expect(
        resolveLogConfig(input, paseoHome: '/tmp/x').console.level,
        LogLevel.info,
      );
    });

    test('a non-map log value is treated as no log section', () {
      final input = LoggerConfigInput.fromJson({'log': 'nope'});
      expect((input! as StructuredLoggerConfig).log, isNull);
    });
  });

  group('PaseoLogger', () {
    late List<String> emitted;

    PaseoLogger build(
      ResolvedLogConfig config, {
      String daemonVersion = '9.9.9-test',
    }) => PaseoLogger.root(
      config,
      sink: emitted.add,
      clock: () => DateTime.utc(2026, 7, 31, 12),
      processId: 4242,
      hostname: 'test-host',
      daemonVersion: daemonVersion,
    );

    setUp(() => emitted = []);

    test('includes the daemon version in child logger entries', () {
      final logger = build(
        const ResolvedLogConfig(
          level: LogLevel.info,
          console: ResolvedConsoleLogConfig(
            level: LogLevel.info,
            format: LogFormat.json,
          ),
        ),
      );
      logger.child({'name': 'fixture'}).info('versioned child logger');

      final record = jsonDecode(emitted.single) as Map<String, Object?>;
      expect(record['pid'], 4242);
      expect(record['hostname'], 'test-host');
      expect(record['daemonVersion'], '9.9.9-test');
      expect(record['name'], 'fixture');
      expect(record['msg'], 'versioned child logger');
      expect(record['level'], LogLevel.info.priority);
      expect(
        record['time'],
        DateTime.utc(2026, 7, 31, 12).millisecondsSinceEpoch,
      );
    });

    test('resolves the real daemon version when none is injected', () {
      final logger = PaseoLogger.root(
        const ResolvedLogConfig(
          level: LogLevel.info,
          console: ResolvedConsoleLogConfig(
            level: LogLevel.info,
            format: LogFormat.json,
          ),
        ),
        sink: emitted.add,
      );
      logger.info('hello');

      final record = jsonDecode(emitted.single) as Map<String, Object?>;
      expect(record['daemonVersion'], resolveDaemonVersionWithFallback());
    });

    test('writes JSON by default', () {
      final logger = build(
        const ResolvedLogConfig(
          level: LogLevel.info,
          console: ResolvedConsoleLogConfig(
            level: LogLevel.info,
            format: LogFormat.json,
          ),
        ),
      );
      logger.info('default logger', {'proof': 'stdout-default'});

      expect(emitted.single, contains('"proof":"stdout-default"'));
      expect(emitted.single, contains('"msg":"default logger"'));
    });

    test('keeps pretty output available as a format choice', () {
      final logger = build(
        const ResolvedLogConfig(
          level: LogLevel.info,
          console: ResolvedConsoleLogConfig(
            level: LogLevel.info,
            format: LogFormat.pretty,
          ),
        ),
      );
      logger.info('pretty logger');

      expect(emitted.single, contains('pretty logger'));
      expect(emitted.single, contains('INFO'));
      // pino-pretty is configured `ignore: "pid,hostname"`.
      expect(emitted.single, isNot(contains('4242')));
      expect(emitted.single, isNot(contains('test-host')));
    });

    test('drops records below the configured level', () {
      final logger = build(
        const ResolvedLogConfig(
          level: LogLevel.warn,
          console: ResolvedConsoleLogConfig(
            level: LogLevel.warn,
            format: LogFormat.json,
          ),
        ),
      );
      logger
        ..trace('t')
        ..debug('d')
        ..info('i')
        ..warn('w')
        ..error('e')
        ..fatal('f');

      expect(emitted.length, 3);
      expect(
        emitted.map(
          (line) => (jsonDecode(line) as Map<String, Object?>)['msg'],
        ),
        ['w', 'e', 'f'],
      );
    });

    test('opens at the file level when a file destination exists', () {
      // Upstream deliberately opens the single pino stream at the *file*
      // level, not the console level, so the file gets everything it asked
      // for.
      final logger = build(
        ResolvedLogConfig(
          level: LogLevel.trace,
          console: const ResolvedConsoleLogConfig(
            level: LogLevel.error,
            format: LogFormat.json,
          ),
          file: ResolvedFileLogConfig(
            level: LogLevel.trace,
            path: p.join(Directory.systemTemp.path, 'unused.log'),
          ),
        ),
      );
      expect(logger.level, LogLevel.trace);
      logger.trace('verbose');
      expect(emitted, hasLength(1));
    });

    test('child bindings merge and later bindings win', () {
      final logger = build(
        const ResolvedLogConfig(
          level: LogLevel.info,
          console: ResolvedConsoleLogConfig(
            level: LogLevel.info,
            format: LogFormat.json,
          ),
        ),
      );
      logger
          .child({'module': 'a', 'keep': 1})
          .child({'module': 'b'})
          .info('merged');

      final record = jsonDecode(emitted.single) as Map<String, Object?>;
      expect(record['module'], 'b');
      expect(record['keep'], 1);
    });

    test('createChildLogger binds the name', () {
      final logger = build(
        const ResolvedLogConfig(
          level: LogLevel.info,
          console: ResolvedConsoleLogConfig(
            level: LogLevel.info,
            format: LogFormat.json,
          ),
        ),
      );
      createChildLogger(logger, 'ws-server').info('named');

      final record = jsonDecode(emitted.single) as Map<String, Object?>;
      expect(record['name'], 'ws-server');
    });

    test('non-JSON field values are stringified rather than crashing', () {
      final logger = build(
        const ResolvedLogConfig(
          level: LogLevel.info,
          console: ResolvedConsoleLogConfig(
            level: LogLevel.info,
            format: LogFormat.json,
          ),
        ),
      );
      logger.warn('boom', {'err': StateError('kaboom')});

      final record = jsonDecode(emitted.single) as Map<String, Object?>;
      expect('${record['err']}', contains('kaboom'));
    });

    test('redacts authorization headers out of every record', () {
      final logger = build(
        const ResolvedLogConfig(
          level: LogLevel.info,
          console: ResolvedConsoleLogConfig(
            level: LogLevel.info,
            format: LogFormat.json,
          ),
        ),
      );
      logger.info('request', {
        'authorization': 'Bearer top-secret',
        'req': {
          'headers': {
            'authorization': 'Bearer nested-secret',
            'sec-websocket-protocol': 'paseo.token.secret',
            'accept': 'application/json',
          },
        },
      });

      expect(emitted.single, isNot(contains('secret')));
      final record = jsonDecode(emitted.single) as Map<String, Object?>;
      final headers =
          (record['req']! as Map<String, Object?>)['headers']!
              as Map<String, Object?>;
      expect(headers.containsKey('authorization'), isFalse);
      expect(headers.containsKey('sec-websocket-protocol'), isFalse);
      expect(headers['accept'], 'application/json');
    });
  });

  group('PaseoLogger file destination', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('paseo-logger-'));
    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('writes to an explicit file target without rotation files', () {
      final logPath = p.join(temp.path, 'logs', 'programmatic.log');
      final config = resolveLogConfig(
        const StructuredLoggerConfig(
          log: PersistedLogConfig(file: PersistedFileLogConfig()),
        ).withPath(logPath),
        paseoHome: temp.path,
      );

      PaseoLogger.root(config, daemonVersion: '0.0.0-test')
        ..info('explicit file logger', {'proof': 'file-explicit'});

      final text = File(logPath).readAsStringSync();
      expect(text, contains('"proof":"file-explicit"'));
      expect(text, contains('"msg":"explicit file logger"'));
      expect(
        Directory(
          p.dirname(logPath),
        ).listSync().map((entity) => p.basename(entity.path)).toList(),
        ['programmatic.log'],
      );
    });

    test('does not initialize file logging by default', () {
      final config = resolveLogConfig(null, paseoHome: temp.path);
      expect(config.file, isNull);

      // Deliberately no injected sink: the real destination selection must run
      // so "no file config" is proved to mean "no file, no log directory".
      PaseoLogger.root(
        config,
        daemonVersion: '0.0.0-test',
      ).info('default logger', {'proof': 'stdout-default'});

      expect(File(p.join(temp.path, 'daemon.log')).existsSync(), isFalse);
      expect(Directory(p.join(temp.path, 'logs')).existsSync(), isFalse);
    });

    test('can disable file output for supervised workers', () {
      final logPath = p.join(temp.path, 'daemon.log');
      final config = resolveLogConfig(
        const StructuredLoggerConfig(
          log: PersistedLogConfig(file: PersistedFileLogConfig()),
        ).withPath(logPath),
        paseoHome: temp.path,
        file: false,
      );

      expect(config.file, isNull);
      PaseoLogger.root(
        config,
        daemonVersion: '0.0.0-test',
      ).info('worker logger', {'proof': 'stdout-only'});

      expect(File(logPath).existsSync(), isFalse);
    });
  });

  group('redactLogRecord', () {
    test('leaves an unrelated record untouched and unmutated', () {
      final record = <String, Object?>{'cwd': '/tmp', 'ok': true};
      expect(redactLogRecord(record), record);
      expect(record, {'cwd': '/tmp', 'ok': true});
    });

    test('removes every documented path spelling', () {
      final redacted = redactLogRecord({
        'authorization': 'a',
        'Authorization': 'b',
        'sec-websocket-protocol': 'c',
        'Sec-WebSocket-Protocol': 'd',
        'headers': {
          'authorization': 'e',
          'Authorization': 'f',
          'sec-websocket-protocol': 'g',
          'Sec-WebSocket-Protocol': 'h',
          'keep': 'yes',
        },
        'req': {
          'headers': {
            'authorization': 'i',
            'Authorization': 'j',
            'sec-websocket-protocol': 'k',
            'Sec-WebSocket-Protocol': 'l',
            'keep': 'yes',
          },
        },
      });

      expect(redacted.keys, ['headers', 'req']);
      expect((redacted['headers']! as Map<String, Object?>).keys, ['keep']);
      expect(
        ((redacted['req']! as Map<String, Object?>)['headers']!
                as Map<String, Object?>)
            .keys,
        ['keep'],
      );
    });

    test('does not mutate nested maps belonging to the caller', () {
      final headers = <String, Object?>{'authorization': 'secret'};
      final record = <String, Object?>{'headers': headers};
      redactLogRecord(record);
      expect(headers, {'authorization': 'secret'});
    });

    test('a non-map value on the path is left alone', () {
      final record = <String, Object?>{'headers': 'not-a-map'};
      expect(redactLogRecord(record), {'headers': 'not-a-map'});
    });
  });

  group('parseLogRedactPath', () {
    test('splits dotted paths', () {
      expect(parseLogRedactPath('req.headers.authorization'), [
        'req',
        'headers',
        'authorization',
      ]);
    });

    test('unquotes bracketed segments', () {
      expect(parseLogRedactPath('headers["sec-websocket-protocol"]'), [
        'headers',
        'sec-websocket-protocol',
      ]);
      expect(parseLogRedactPath('["sec-websocket-protocol"]'), [
        'sec-websocket-protocol',
      ]);
      expect(parseLogRedactPath("headers['x']"), ['headers', 'x']);
    });

    test('an unterminated bracket degrades to a plain segment', () {
      expect(parseLogRedactPath('headers[oops'), ['headers', 'oops']);
    });
  });
}

/// Convenience for the file-path cases: rewrites the file section's path.
extension on StructuredLoggerConfig {
  StructuredLoggerConfig withPath(String path) => StructuredLoggerConfig(
    log: PersistedLogConfig(
      level: log?.level,
      format: log?.format,
      console: log?.console,
      file: PersistedFileLogConfig(level: log?.file?.level, path: path),
    ),
  );
}

// ---------------------------------------------------------------------------
// git-mutation-service.ts
// ---------------------------------------------------------------------------

final class SnapshotCall {
  const SnapshotCall(this.cwd, this.force, this.reason);

  final String cwd;
  final bool force;
  final String? reason;

  @override
  bool operator ==(Object other) =>
      other is SnapshotCall &&
      other.cwd == cwd &&
      other.force == force &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(cwd, force, reason);

  @override
  String toString() => 'SnapshotCall($cwd, force: $force, reason: $reason)';
}

/// The production module reads only four members of the workspace git
/// service. This fake implements exactly that slice in memory; the happy-path
/// tests cross the real git boundary against a temp repo, since that is where
/// `checkoutResolvedBranch` and `git checkout -b` actually run.
final class FakeGitMutationSource implements GitMutationGitSource {
  FakeGitMutationSource({
    this.resolution = const LocalBranchCheckoutResolution('main'),
    this.isDirty = false,
    this.branchExists = false,
    this.snapshotThrows = false,
    this.snapshotIsNull = false,
  });

  BranchCheckoutResolution resolution;
  bool isDirty;
  bool branchExists;
  bool snapshotThrows;
  bool snapshotIsNull;

  final List<SnapshotCall> snapshotCalls = [];
  final List<String> invalidateCalls = [];

  @override
  Future<BranchCheckoutResolution> validateBranchRef(
    String cwd,
    String ref,
  ) async => resolution;

  @override
  Future<WorkspaceLocalGitSnapshot?> getSnapshot(
    String cwd, {
    bool force = false,
    String? reason,
  }) async {
    snapshotCalls.add(SnapshotCall(cwd, force, reason));
    if (snapshotThrows) {
      throw StateError('snapshot boom');
    }
    if (snapshotIsNull) return null;
    return buildSnapshot(cwd: cwd, isDirty: isDirty);
  }

  @override
  Future<bool> hasLocalBranch(String cwd, String branch) async => branchExists;

  @override
  void invalidateForge(String cwd) => invalidateCalls.add(cwd);
}

Future<String> runGit(String cwd, List<String> args) async {
  final result = await Process.run(
    'git',
    ['-c', 'core.quotepath=false', ...args],
    workingDirectory: cwd,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw StateError('git $args failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

void gitMutationServiceTests() {
  late FakeGitMutationSource git;
  late RecordingLogger logger;
  late GitMutationService service;
  late Directory temp;

  setUp(() {
    git = FakeGitMutationSource();
    logger = RecordingLogger();
    service = GitMutationService(workspaceGitService: git, logger: logger);
    temp = Directory.systemTemp.createTempSync('git-mutation-');
  });

  tearDown(() {
    if (temp.existsSync()) {
      try {
        temp.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows can still hold a handle on a just-checked-out worktree.
      }
    }
  });

  Future<String> initRepo({String? extraBranch, bool dirty = false}) async {
    final dir = p.join(temp.resolveSymbolicLinksSync(), 'repo');
    Directory(dir).createSync(recursive: true);
    await runGit(dir, ['init', '-b', 'main']);
    await runGit(dir, ['config', 'user.email', 'test@example.com']);
    await runGit(dir, ['config', 'user.name', 'Paseo Test']);
    await runGit(dir, ['config', 'commit.gpgsign', 'false']);
    File(p.join(dir, 'README.md')).writeAsStringSync('hello\n');
    await runGit(dir, ['add', '-A']);
    await runGit(dir, ['commit', '-m', 'init']);
    if (extraBranch != null) {
      await runGit(dir, ['branch', extraBranch]);
    }
    if (dirty) {
      File(p.join(dir, 'README.md')).writeAsStringSync('changed\n');
    }
    return dir;
  }

  Future<String> headBranch(String dir) =>
      runGit(dir, ['rev-parse', '--abbrev-ref', 'HEAD']);

  group('assertSafeGitRef', () {
    test('accepts the characters git refs are allowed to use', () {
      expect(
        () => assertSafeGitRef('feature/api-v2.1_x', 'branch'),
        returnsNormally,
      );
    });

    test('rejects whitespace and shell metacharacters', () {
      for (final ref in ['bad branch', 'a;b', r'a$b', 'a\nb', '']) {
        expect(
          () => assertSafeGitRef(ref, 'branch'),
          throwsA(
            isA<PaseoServerServiceException>().having(
              (error) => error.message,
              'message',
              startsWith('Invalid branch:'),
            ),
          ),
          reason: ref,
        );
      }
    });

    test('rejects parent traversal even though the class allows dots', () {
      expect(
        () => assertSafeGitRef('../etc/passwd', 'branch'),
        throwsA(isA<PaseoServerServiceException>()),
      );
      expect(
        () => assertSafeGitRef('a..b', 'branch'),
        throwsA(isA<PaseoServerServiceException>()),
      );
    });

    test('names the label in the message', () {
      expect(
        () => assertSafeGitRef('bad x', 'new branch'),
        throwsA(
          isA<PaseoServerServiceException>().having(
            (error) => error.message,
            'message',
            'Invalid new branch: bad x',
          ),
        ),
      );
    });
  });

  group('checkoutExistingBranch', () {
    test('rejects an unsafe branch ref before touching git', () async {
      await expectLater(
        service.checkoutExistingBranch('/tmp/nope', 'bad branch'),
        throwsA(
          isA<PaseoServerServiceException>().having(
            (error) => error.message,
            'message',
            contains('Invalid branch'),
          ),
        ),
      );
      expect(git.snapshotCalls, isEmpty);
    });

    test('rejects when the branch does not resolve', () async {
      git.resolution = const NotFoundBranchCheckoutResolution();
      await expectLater(
        service.checkoutExistingBranch('/tmp/nope', 'missing'),
        throwsA(
          isA<PaseoServerServiceException>().having(
            (error) => error.message,
            'message',
            'Branch not found: missing',
          ),
        ),
      );
    });

    test('rejects when the working tree is dirty', () async {
      git
        ..resolution = const LocalBranchCheckoutResolution('x')
        ..isDirty = true;
      await expectLater(
        service.checkoutExistingBranch('/tmp/nope', 'x'),
        throwsA(
          isA<PaseoServerServiceException>().having(
            (error) => error.message,
            'message',
            contains('uncommitted changes'),
          ),
        ),
      );
    });

    test(
      'wraps a git-status failure with the inspecting-status message',
      () async {
        git
          ..resolution = const LocalBranchCheckoutResolution('x')
          ..snapshotThrows = true;
        await expectLater(
          service.checkoutExistingBranch('/tmp/nope', 'x'),
          throwsA(
            isA<PaseoServerServiceException>()
                .having(
                  (error) => error.message,
                  'message',
                  contains('Unable to inspect git status'),
                )
                .having((error) => error.cause, 'cause', isA<StateError>()),
          ),
        );
      },
    );

    test('treats an unreadable (null) snapshot as clean', () async {
      final dir = await initRepo(extraBranch: 'feature');
      git
        ..resolution = const LocalBranchCheckoutResolution('feature')
        ..snapshotIsNull = true;

      await service.checkoutExistingBranch(dir, 'feature');
      expect(await headBranch(dir), 'feature');
    });

    test(
      'checks out the branch and invalidates the forge (real repo)',
      () async {
        final dir = await initRepo(extraBranch: 'feature');
        git.resolution = const LocalBranchCheckoutResolution('feature');

        final result = await service.checkoutExistingBranch(dir, 'feature');

        expect(result.source, BranchCheckoutSource.local);
        expect(await headBranch(dir), 'feature');
        expect(git.invalidateCalls, [dir]);
        expect(
          git.snapshotCalls,
          contains(
            const SnapshotCall('', true, 'switch-branch').copyForCwd(dir),
          ),
        );
      },
    );

    test('is a no-op when already on the branch (real repo)', () async {
      final dir = await initRepo();
      git.resolution = const LocalBranchCheckoutResolution('main');

      final before = await runGit(dir, ['rev-parse', 'HEAD']);
      final result = await service.checkoutExistingBranch(dir, 'main');

      expect(result.source, BranchCheckoutSource.local);
      expect(await headBranch(dir), 'main');
      expect(await runGit(dir, ['rev-parse', 'HEAD']), before);
    });

    test(
      'creates a tracking branch for a remote-only ref (real repo)',
      () async {
        final root = temp.resolveSymbolicLinksSync();
        final origin = p.join(root, 'origin.git');
        Directory(origin).createSync(recursive: true);
        await runGit(origin, ['init', '--bare', '-b', 'main']);
        final dir = await initRepo(extraBranch: 'published');
        await runGit(dir, ['remote', 'add', 'origin', origin]);
        await runGit(dir, ['push', 'origin', 'main', 'published']);
        await runGit(dir, ['branch', '-D', 'published']);

        git.resolution = const RemoteOnlyBranchCheckoutResolution(
          name: 'published',
          remoteRef: 'origin/published',
        );

        final result = await service.checkoutExistingBranch(dir, 'published');

        expect(result.source, BranchCheckoutSource.remote);
        expect(await headBranch(dir), 'published');
      },
    );

    test('a not-found resolution reaching the runner still throws', () async {
      await expectLater(
        checkoutResolvedBranch(
          cwd: '/tmp/nope',
          resolution: const NotFoundBranchCheckoutResolution(),
          requestedBranch: 'ghost',
        ),
        throwsA(
          isA<PaseoServerServiceException>().having(
            (error) => error.message,
            'message',
            'Branch not found: ghost',
          ),
        ),
      );
    });
  });

  group('createBranchFromBase', () {
    test('rejects an unsafe new-branch ref before touching git', () async {
      await expectLater(
        service.createBranchFromBase(
          cwd: '/tmp/nope',
          baseBranch: 'main',
          newBranchName: 'bad x',
        ),
        throwsA(
          isA<PaseoServerServiceException>().having(
            (error) => error.message,
            'message',
            contains('Invalid new'),
          ),
        ),
      );
    });

    test('rejects when the base branch does not resolve', () async {
      git.resolution = const NotFoundBranchCheckoutResolution();
      await expectLater(
        service.createBranchFromBase(
          cwd: '/tmp/nope',
          baseBranch: 'main',
          newBranchName: 'feat',
        ),
        throwsA(
          isA<PaseoServerServiceException>().having(
            (error) => error.message,
            'message',
            'Base branch not found: main',
          ),
        ),
      );
    });

    test('rejects when the new branch already exists', () async {
      git.branchExists = true;
      await expectLater(
        service.createBranchFromBase(
          cwd: '/tmp/nope',
          baseBranch: 'main',
          newBranchName: 'feat',
        ),
        throwsA(
          isA<PaseoServerServiceException>().having(
            (error) => error.message,
            'message',
            'Branch already exists: feat',
          ),
        ),
      );
    });

    test('rejects when the working tree is dirty', () async {
      git.isDirty = true;
      await expectLater(
        service.createBranchFromBase(
          cwd: '/tmp/nope',
          baseBranch: 'main',
          newBranchName: 'feat',
        ),
        throwsA(
          isA<PaseoServerServiceException>().having(
            (error) => error.message,
            'message',
            contains('uncommitted changes'),
          ),
        ),
      );
    });

    test('validates the base ref before the new one', () async {
      // Both are unsafe; the base is reported because it is checked first.
      await expectLater(
        service.createBranchFromBase(
          cwd: '/tmp/nope',
          baseBranch: 'bad base',
          newBranchName: 'bad new',
        ),
        throwsA(
          isA<PaseoServerServiceException>().having(
            (error) => error.message,
            'message',
            'Invalid base branch: bad base',
          ),
        ),
      );
    });

    test('creates the branch and refreshes without forge invalidation '
        '(real repo)', () async {
      final dir = await initRepo();
      git.resolution = const LocalBranchCheckoutResolution('main');

      await service.createBranchFromBase(
        cwd: dir,
        baseBranch: 'main',
        newBranchName: 'feature2',
      );

      expect(await headBranch(dir), 'feature2');
      expect(git.invalidateCalls, isEmpty);
      expect(
        git.snapshotCalls,
        contains(const SnapshotCall('', true, 'create-branch').copyForCwd(dir)),
      );
    });

    test('refuses a dirty real repo before running git (real repo)', () async {
      final dir = await initRepo(dirty: true);
      git
        ..resolution = const LocalBranchCheckoutResolution('main')
        ..isDirty = true;

      await expectLater(
        service.createBranchFromBase(
          cwd: dir,
          baseBranch: 'main',
          newBranchName: 'feature3',
        ),
        throwsA(isA<PaseoServerServiceException>()),
      );
      expect(await headBranch(dir), 'main');
    });
  });

  group('notifyGitMutation', () {
    test('invalidates the forge and force-refreshes when asked', () async {
      await service.notifyGitMutation(
        '/tmp/repo',
        GitMutationRefreshReason.commitChanges,
        invalidateForge: true,
      );

      expect(git.invalidateCalls, ['/tmp/repo']);
      expect(git.snapshotCalls, [
        const SnapshotCall('/tmp/repo', true, 'commit-changes'),
      ]);
    });

    test('force-refreshes without invalidating the forge by default', () async {
      await service.notifyGitMutation(
        '/tmp/repo',
        GitMutationRefreshReason.pull,
      );

      expect(git.invalidateCalls, isEmpty);
      expect(git.snapshotCalls, [
        const SnapshotCall('/tmp/repo', true, 'pull'),
      ]);
    });

    test('swallows and logs a snapshot-refresh failure', () async {
      git.snapshotThrows = true;

      await service.notifyGitMutation(
        '/tmp/repo',
        GitMutationRefreshReason.pull,
      );

      final warning = logger.at(LogLevel.warn).single;
      expect(
        warning.message,
        'Failed to force-refresh workspace git snapshot after mutation',
      );
      expect(warning.fields['cwd'], '/tmp/repo');
      expect(warning.fields['reason'], 'pull');
      expect(warning.fields['err'], isA<StateError>());
    });

    test('still invalidates the forge when the refresh fails', () async {
      git.snapshotThrows = true;

      await service.notifyGitMutation(
        '/tmp/repo',
        GitMutationRefreshReason.mergePr,
        invalidateForge: true,
      );

      expect(git.invalidateCalls, ['/tmp/repo']);
    });

    test('every refresh reason keeps its upstream wire string', () {
      expect(GitMutationRefreshReason.values.map((reason) => reason.wireName), [
        'commit-changes',
        'pull',
        'push',
        'merge-to-base',
        'merge-from-base',
        'merge-pr',
        'enable-pr-auto-merge',
        'disable-pr-auto-merge',
        'create-pr',
        'switch-branch',
        'rename-branch',
        'create-branch',
        'stash-push',
        'stash-pop',
        'create-worktree',
      ]);
    });
  });
}

extension on SnapshotCall {
  SnapshotCall copyForCwd(String cwd) => SnapshotCall(cwd, force, reason);
}

// ---------------------------------------------------------------------------
// persistence-hooks.ts
// ---------------------------------------------------------------------------

StoredAgentRecord createRecord({
  String id = 'agent-record',
  String provider = 'claude',
  String cwd = '/tmp/project',
  String createdAt = '2026-01-01T00:00:00.000Z',
  String updatedAt = '2026-01-01T00:00:00.000Z',
  String? lastActivityAt,
  String? lastUserMessageAt,
  String? lastModeId = 'plan',
  StoredAgentConfig? config = const StoredAgentConfig(
    modeId: 'plan',
    model: 'claude-3.5-sonnet',
  ),
  StoredAgentPersistence? persistence = const StoredAgentPersistence(
    provider: 'claude',
    sessionId: 'session-123',
  ),
  Map<String, String>? labels,
  String? workspaceId,
  String? archivedAt,
  Map<String, Object?>? owner,
}) => StoredAgentRecord(
  id: id,
  provider: provider,
  cwd: cwd,
  createdAt: createdAt,
  updatedAt: updatedAt,
  lastActivityAt: lastActivityAt,
  lastUserMessageAt: lastUserMessageAt,
  lastModeId: lastModeId,
  config: config,
  persistence: persistence,
  labels: labels,
  workspaceId: workspaceId,
  archivedAt: archivedAt,
  owner: owner,
);

void persistenceHooksTests() {
  group('buildConfigOverrides', () {
    test('carries systemPrompt and mcpServers', () {
      final record = createRecord(
        config: const StoredAgentConfig(
          modeId: 'default',
          model: 'gpt-5.4-mini',
          thinkingOptionId: 'minimal',
          systemPrompt: 'Use speak first.',
          mcpServers: {
            'paseo': {
              'type': 'stdio',
              'command': 'node',
              'args': ['/tmp/bridge.mjs', '--socket', '/tmp/agent.sock'],
            },
          },
        ),
      );

      final overrides = buildConfigOverrides(record);
      expect(overrides.cwd, '/tmp/project');
      // The runtime mode wins over the persisted config mode.
      expect(overrides.modeId, 'plan');
      expect(overrides.model, 'gpt-5.4-mini');
      expect(overrides.thinkingOptionId, 'minimal');
      expect(overrides.systemPrompt, 'Use speak first.');
      expect(overrides.mcpServers, {
        'paseo': {
          'type': 'stdio',
          'command': 'node',
          'args': ['/tmp/bridge.mjs', '--socket', '/tmp/agent.sock'],
        },
      });
    });

    test('drops the persisted internal MCP server', () {
      final record = createRecord(
        config: const StoredAgentConfig(
          modeId: 'default',
          model: 'gpt-5.4-mini',
          mcpServers: {
            'paseo': {
              'type': 'http',
              'url':
                  'http://127.0.0.1:6767/mcp/agents?callerAgentId=stale-agent',
            },
            'custom': {'type': 'stdio', 'command': 'custom-mcp'},
          },
        ),
      );

      expect(buildConfigOverrides(record).mcpServers, {
        'custom': {'type': 'stdio', 'command': 'custom-mcp'},
      });
    });

    test('preserves a user-provided server that merely shares the name', () {
      final record = createRecord(
        config: const StoredAgentConfig(
          modeId: 'default',
          model: 'gpt-5.4-mini',
          mcpServers: {
            'paseo': {
              'type': 'http',
              'url': 'https://example.com/custom-paseo',
            },
          },
        ),
      );

      expect(buildConfigOverrides(record).mcpServers, {
        'paseo': {'type': 'http', 'url': 'https://example.com/custom-paseo'},
      });
    });

    test('also drops this daemon\'s own injected server', () {
      final record = createRecord(
        config: const StoredAgentConfig(
          mcpServers: {
            'tinyrack': {
              'type': 'http',
              'url': 'http://127.0.0.1:6868/mcp/agents?callerAgentId=stale',
            },
          },
        ),
      );

      expect(buildConfigOverrides(record).mcpServers, isNull);
    });

    test('an mcpServers map that empties out becomes absent', () {
      final record = createRecord(
        config: const StoredAgentConfig(
          mcpServers: {
            'paseo': {'type': 'http', 'url': 'http://127.0.0.1:1/mcp/agents'},
          },
        ),
      );

      expect(buildConfigOverrides(record).mcpServers, isNull);
    });

    test('falls back to the config mode when there is no runtime mode', () {
      final record = createRecord(
        lastModeId: null,
        config: const StoredAgentConfig(modeId: 'acceptEdits'),
      );

      expect(buildConfigOverrides(record).modeId, 'acceptEdits');
    });

    test('a record with no config yields provider and cwd only', () {
      final record = createRecord(lastModeId: null, config: null);
      final overrides = buildConfigOverrides(record);

      expect(overrides.provider, 'claude');
      expect(overrides.cwd, '/tmp/project');
      expect(overrides.modeId, isNull);
      expect(overrides.model, isNull);
      expect(overrides.mcpServers, isNull);
    });
  });

  group('buildSessionConfig', () {
    test('includes the persisted systemPrompt and mcpServers', () {
      final record = createRecord(
        provider: 'codex',
        config: const StoredAgentConfig(
          modeId: 'default',
          model: 'gpt-5.4-mini',
          systemPrompt: 'Confirm and speak first.',
          mcpServers: {
            'paseo': {
              'type': 'stdio',
              'command': 'node',
              'args': ['/tmp/bridge.mjs', '--socket', '/tmp/agent.sock'],
            },
          },
        ),
      );

      final config = buildSessionConfig(record)!;
      expect(config.provider, 'codex');
      expect(config.cwd, '/tmp/project');
      expect(config.modeId, 'plan');
      expect(config.model, 'gpt-5.4-mini');
      expect(config.systemPrompt, 'Confirm and speak first.');
      expect(config.mcpServers, {
        'paseo': {
          'type': 'stdio',
          'command': 'node',
          'args': ['/tmp/bridge.mjs', '--socket', '/tmp/agent.sock'],
        },
      });
    });

    test('accepts providers from the canonical manifest', () {
      final record = createRecord(config: const StoredAgentConfig());
      final config = buildSessionConfig(record)!;
      expect(config.provider, 'claude');
      expect(config.cwd, '/tmp/project');
    });

    test('skips records whose provider is missing from the registry', () {
      final record = createRecord(
        id: 'agent-missing-provider',
        provider: 'zai',
      );
      expect(
        buildSessionConfig(record, validProviders: const ['claude', 'codex']),
        isNull,
      );
    });

    test('an empty registry rejects every provider', () {
      expect(
        buildSessionConfig(createRecord(), validProviders: const <String>[]),
        isNull,
      );
    });

    test('a null registry accepts every provider', () {
      expect(buildSessionConfig(createRecord(provider: 'anything')), isNotNull);
    });

    test('a Set registry is used directly', () {
      expect(
        buildSessionConfig(
          createRecord(provider: 'codex'),
          validProviders: {'codex'},
        ),
        isNotNull,
      );
    });
  });

  group('isStoredAgentProviderAvailable', () {
    test('defers to the registry when one is supplied', () {
      final record = createRecord(provider: 'gemini');
      expect(isStoredAgentProviderAvailable(record, const ['claude']), isFalse);
      expect(
        isStoredAgentProviderAvailable(record, const ['claude', 'gemini']),
        isTrue,
      );
      expect(isStoredAgentProviderAvailable(record), isTrue);
    });
  });

  group('toAgentPersistenceHandle', () {
    test('rejects handles for unavailable providers', () {
      expect(
        toAgentPersistenceHandle(
          const ['claude', 'codex'],
          const StoredAgentPersistence(
            provider: 'gemini',
            sessionId: 'session-123',
          ),
        ),
        isNull,
      );
    });

    test('rejects a missing handle', () {
      expect(toAgentPersistenceHandle(const ['claude'], null), isNull);
    });

    test('rejects a handle with no session id', () {
      expect(
        toAgentPersistenceHandle(const [
          'claude',
        ], const StoredAgentPersistence(provider: 'claude', sessionId: '')),
        isNull,
      );
    });

    test('carries nativeHandle and metadata when present', () {
      final handle = toAgentPersistenceHandle(
        const ['claude'],
        const StoredAgentPersistence(
          provider: 'claude',
          sessionId: 'session-123',
          nativeHandle: 'native-1',
          metadata: {'k': 'v'},
        ),
      )!;

      expect(handle.provider, 'claude');
      expect(handle.sessionId, 'session-123');
      expect(handle.nativeHandle, 'native-1');
      expect(handle.metadata, {'k': 'v'});
      expect(handle.toJson()['nativeHandle'], 'native-1');
    });

    test('omits an absent nativeHandle on serialization', () {
      final handle = toAgentPersistenceHandle(
        const ['claude'],
        const StoredAgentPersistence(
          provider: 'claude',
          sessionId: 'session-123',
        ),
      )!;

      expect(handle.toJson().containsKey('nativeHandle'), isFalse);
    });
  });

  group('extractTimestamps', () {
    test('prefers lastActivityAt over updatedAt', () {
      final stamps = extractTimestamps(
        createRecord(
          createdAt: '2026-01-01T00:00:00.000Z',
          updatedAt: '2026-01-02T00:00:00.000Z',
          lastActivityAt: '2026-01-03T00:00:00.000Z',
        ),
      );

      expect(stamps.createdAt, DateTime.utc(2026, 1, 1));
      expect(stamps.updatedAt, DateTime.utc(2026, 1, 3));
    });

    test('falls back to updatedAt when there is no activity stamp', () {
      final stamps = extractTimestamps(
        createRecord(updatedAt: '2026-01-02T00:00:00.000Z'),
      );
      expect(stamps.updatedAt, DateTime.utc(2026, 1, 2));
    });

    test('an absent or blank lastUserMessageAt is null', () {
      expect(extractTimestamps(createRecord()).lastUserMessageAt, isNull);
      expect(
        extractTimestamps(
          createRecord(lastUserMessageAt: ''),
        ).lastUserMessageAt,
        isNull,
      );
    });

    test('parses a present lastUserMessageAt', () {
      expect(
        extractTimestamps(
          createRecord(lastUserMessageAt: '2026-02-03T04:05:06.000Z'),
        ).lastUserMessageAt,
        DateTime.utc(2026, 2, 3, 4, 5, 6),
      );
    });

    test('an unparseable stamp becomes null rather than throwing', () {
      final stamps = extractTimestamps(createRecord(createdAt: 'not-a-date'));
      expect(stamps.createdAt, isNull);
    });

    test('copies labels, workspaceId and owner through unchanged', () {
      final stamps = extractTimestamps(
        createRecord(
          labels: const {'team': 'core'},
          workspaceId: 'ws-1',
          owner: const {'kind': 'daemon'},
        ),
      );

      expect(stamps.labels, {'team': 'core'});
      expect(stamps.workspaceId, 'ws-1');
      expect(stamps.owner, {'kind': 'daemon'});
    });
  });

  group('attachAgentStoragePersistence', () {
    test(
      'persists live snapshots, skips closed ones, and unsubscribes',
      () async {
        final manager = FakeAgentStateSource();
        final storage = FakeAgentSnapshotStorage();
        final logger = RecordingLogger();

        final unsubscribe = attachAgentStoragePersistence(
          logger,
          manager,
          storage,
        );

        manager.emit(AgentStateEvent(agent: agentSummary('a'), closed: false));
        manager.emit(AgentStateEvent(agent: agentSummary('b'), closed: true));
        await pumpEventQueue();

        expect(storage.saved.map((agent) => agent.agentId), ['a']);

        unsubscribe();
        expect(manager.listeners, isEmpty);
      },
    );

    test('logs a failed write through the persistence child logger', () async {
      final manager = FakeAgentStateSource();
      final storage = FakeAgentSnapshotStorage()..failWith = StateError('disk');
      final logger = RecordingLogger();

      attachAgentStoragePersistence(logger, manager, storage);
      manager.emit(AgentStateEvent(agent: agentSummary('a'), closed: false));
      await pumpEventQueue();

      final line = logger.allLines.single;
      expect(line.level, LogLevel.error);
      expect(line.message, 'Failed to persist agent snapshot');
      expect(line.fields['agentId'], 'a');
      expect(line.fields['module'], 'persistence');
    });
  });
}

AgentSummary agentSummary(String id, {String? archivedAt}) => AgentSummary(
  agentId: id,
  title: 'agent $id',
  cwd: '/tmp/project',
  provider: 'codex',
  model: 'gpt-5',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1735689600000,
  archivedAt: archivedAt,
);

final class FakeAgentStateSource implements AgentStateSource {
  final List<void Function(AgentStateEvent)> listeners = [];

  void emit(AgentStateEvent event) {
    for (final listener in [...listeners]) {
      listener(event);
    }
  }

  @override
  void Function() subscribe(void Function(AgentStateEvent event) listener) {
    listeners.add(listener);
    return () => listeners.remove(listener);
  }
}

final class FakeAgentSnapshotStorage implements AgentSnapshotStorage {
  final List<AgentSummary> saved = [];
  Object? failWith;

  @override
  Future<void> applySnapshot(AgentSummary agent) async {
    if (failWith != null) throw failWith!;
    saved.add(agent);
  }
}

// ---------------------------------------------------------------------------
// agent-loading.ts
// ---------------------------------------------------------------------------

final class ResumeCall {
  const ResumeCall(this.agentId, this.purpose, this.overrides, this.timestamps);

  final String agentId;
  final AgentResumePurpose? purpose;
  final AgentSessionConfigOverrides overrides;
  final AgentRecordTimestamps timestamps;
}

final class CreateCall {
  const CreateCall(this.agentId, this.config, this.labels, this.workspaceId);

  final String agentId;
  final AgentSessionConfig config;
  final Map<String, String>? labels;
  final String? workspaceId;
}

final class FakeLoaderManager implements ClosableAgentLoaderManager {
  FakeLoaderManager({this.registeredProviders = const ['claude', 'codex']});

  final Iterable<String> registeredProviders;
  final Map<String, AgentSummary> live = {};
  final List<ResumeCall> resumeCalls = [];
  final List<CreateCall> createCalls = [];
  final List<String> closeCalls = [];
  final List<bool> hydrateBroadcasts = [];
  Completer<void>? gate;

  @override
  Future<AgentSummary> createAgent(
    AgentSessionConfig config,
    String agentId, {
    Map<String, String>? labels,
    String? workspaceId,
    Map<String, Object?>? owner,
  }) async {
    if (gate != null) await gate!.future;
    createCalls.add(CreateCall(agentId, config, labels, workspaceId));
    final agent = agentSummary(agentId);
    live[agentId] = agent;
    return agent;
  }

  @override
  AgentSummary? getAgent(String agentId) => live[agentId];

  @override
  Iterable<String> getRegisteredProviderIds() => registeredProviders;

  @override
  Future<void> hydrateTimelineFromProvider(
    String agentId, {
    required bool Function() broadcast,
  }) async {
    hydrateBroadcasts.add(broadcast());
  }

  @override
  Future<AgentSummary> resumeAgentFromPersistence(
    AgentPersistenceHandle handle,
    AgentSessionConfigOverrides overrides,
    String agentId,
    AgentRecordTimestamps timestamps,
    AgentResumePurpose? purpose,
  ) async {
    if (gate != null) await gate!.future;
    resumeCalls.add(ResumeCall(agentId, purpose, overrides, timestamps));
    final agent = agentSummary(agentId);
    live[agentId] = agent;
    return agent;
  }

  @override
  Future<void> closeAgent(String agentId) async {
    closeCalls.add(agentId);
    live.remove(agentId);
  }
}

/// Adds the two optional capabilities upstream models as
/// `Partial<Pick<AgentManager, "touchAgentActivity" | "waitForAgentClose">>`.
final class FakeFullLoaderManager extends FakeLoaderManager
    implements AgentActivityTouchingManager, AgentCloseAwaitingManager {
  FakeFullLoaderManager({super.registeredProviders});

  final List<String> touched = [];
  final List<String> waited = [];

  @override
  AgentSummary? touchAgentActivity(String agentId) {
    touched.add(agentId);
    return live[agentId];
  }

  @override
  Future<void> waitForAgentClose(String agentId) async {
    waited.add(agentId);
  }
}

final class FakeRecordStorage implements AgentRecordStorage {
  FakeRecordStorage([Map<String, StoredAgentRecord>? records])
    : records = {...?records};

  final Map<String, StoredAgentRecord> records;
  final List<String> reads = [];

  @override
  Future<StoredAgentRecord?> get(String agentId) async {
    reads.add(agentId);
    return records[agentId];
  }
}

void agentLoadingTests() {
  late RecordingLogger logger;

  setUp(() {
    logger = RecordingLogger();
    expect(
      pendingAgentInitializationCount,
      0,
      reason: 'the module-level dedupe map must drain between loads',
    );
  });

  EnsureAgentLoadedDeps deps(
    AgentLoaderManager manager,
    AgentRecordStorage storage, {
    Iterable<String>? validProviders,
    bool broadcastTimeline = false,
  }) => EnsureAgentLoadedDeps(
    agentManager: manager,
    agentStorage: storage,
    logger: logger,
    validProviders: validProviders,
    broadcastTimeline: broadcastTimeline,
  );

  test('loads archived records for history and active records with the '
      'interactive default', () async {
    final manager = FakeFullLoaderManager();
    final storage = FakeRecordStorage({
      'archived': createRecord(
        id: 'archived',
        provider: 'codex',
        persistence: const StoredAgentPersistence(
          provider: 'codex',
          sessionId: 'session-archived',
        ),
        archivedAt: '2026-01-02T00:00:00.000Z',
        workspaceId: 'workspace-archived',
      ),
      'active': createRecord(
        id: 'active',
        provider: 'codex',
        persistence: const StoredAgentPersistence(
          provider: 'codex',
          sessionId: 'session-active',
        ),
        workspaceId: 'workspace-active',
      ),
    });

    await ensureAgentLoaded('archived', deps(manager, storage));
    manager.live.clear();
    await ensureAgentLoaded('active', deps(manager, storage));

    expect(manager.resumeCalls.map((call) => call.purpose), [
      AgentResumePurpose.history,
      null,
    ]);
  });

  test(
    'creates from stored config when there is no resumable handle',
    () async {
      final manager = FakeFullLoaderManager();
      final storage = FakeRecordStorage({
        'a': createRecord(
          id: 'a',
          provider: 'codex',
          persistence: null,
          labels: const {'team': 'core'},
          workspaceId: 'ws-1',
        ),
      });

      await ensureAgentLoaded('a', deps(manager, storage));

      final call = manager.createCalls.single;
      expect(call.agentId, 'a');
      expect(call.config.provider, 'codex');
      expect(call.labels, {'team': 'core'});
      expect(call.workspaceId, 'ws-1');
      expect(
        logger.at(LogLevel.info).single.message,
        'Agent created from stored config',
      );
    },
  );

  test('logs the resume path distinctly', () async {
    final manager = FakeFullLoaderManager();
    final storage = FakeRecordStorage({'a': createRecord(id: 'a')});

    await ensureAgentLoaded('a', deps(manager, storage));

    expect(
      logger.at(LogLevel.info).single.message,
      'Agent resumed from persistence',
    );
  });

  test('returns the already-loaded agent without touching storage', () async {
    final manager = FakeFullLoaderManager()..live['a'] = agentSummary('a');
    final storage = FakeRecordStorage();

    final agent = await ensureAgentLoaded('a', deps(manager, storage));

    expect(agent.agentId, 'a');
    expect(storage.reads, isEmpty);
    expect(manager.touched, ['a']);
    expect(manager.waited, ['a']);
  });

  test(
    'falls back to getAgent when the manager cannot touch activity',
    () async {
      final manager = FakeLoaderManager()..live['a'] = agentSummary('a');
      final storage = FakeRecordStorage();

      final agent = await ensureAgentLoaded('a', deps(manager, storage));

      expect(agent.agentId, 'a');
      expect(storage.reads, isEmpty);
    },
  );

  test('throws when the record does not exist', () async {
    await expectLater(
      ensureAgentLoaded(
        'ghost',
        deps(FakeFullLoaderManager(), FakeRecordStorage()),
      ),
      throwsA(
        isA<PaseoServerServiceException>().having(
          (error) => error.message,
          'message',
          'Agent not found: ghost',
        ),
      ),
    );
    expect(pendingAgentInitializationCount, 0);
  });

  test('throws when the record names an unregistered provider', () async {
    final storage = FakeRecordStorage({
      'a': createRecord(id: 'a', provider: 'zai'),
    });

    await expectLater(
      ensureAgentLoaded('a', deps(FakeFullLoaderManager(), storage)),
      throwsA(
        isA<PaseoServerServiceException>().having(
          (error) => error.message,
          'message',
          "Agent a references unavailable provider 'zai'",
        ),
      ),
    );
  });

  test('explicit validProviders override the manager registry', () async {
    final manager = FakeFullLoaderManager(registeredProviders: const ['zai']);
    final storage = FakeRecordStorage({
      'a': createRecord(id: 'a', provider: 'zai'),
    });

    // The manager would accept it; the explicit list does not.
    await expectLater(
      ensureAgentLoaded(
        'a',
        deps(manager, storage, validProviders: const ['codex']),
      ),
      throwsA(isA<PaseoServerServiceException>()),
    );
  });

  test('a handle for an unregistered provider falls back to create', () async {
    final manager = FakeFullLoaderManager(registeredProviders: const ['codex']);
    final storage = FakeRecordStorage({
      'a': createRecord(
        id: 'a',
        provider: 'codex',
        persistence: const StoredAgentPersistence(
          provider: 'gemini',
          sessionId: 'session-1',
        ),
      ),
    });

    await ensureAgentLoaded('a', deps(manager, storage));

    expect(manager.resumeCalls, isEmpty);
    expect(manager.createCalls, hasLength(1));
  });

  test('concurrent loads share one initialization', () async {
    final manager = FakeFullLoaderManager()..gate = Completer<void>();
    final storage = FakeRecordStorage({'a': createRecord(id: 'a')});

    final first = ensureAgentLoaded('a', deps(manager, storage));
    final second = ensureAgentLoaded('a', deps(manager, storage));
    await pumpEventQueue();
    expect(pendingAgentInitializationCount, 1);

    manager.gate!.complete();
    final results = await Future.wait([first, second]);

    expect(manager.resumeCalls, hasLength(1));
    expect(results[0].agentId, results[1].agentId);
    expect(pendingAgentInitializationCount, 0);
  });

  test('a later caller can upgrade an in-flight load to broadcast', () async {
    final manager = FakeFullLoaderManager()..gate = Completer<void>();
    final storage = FakeRecordStorage({'a': createRecord(id: 'a')});

    final first = ensureAgentLoaded('a', deps(manager, storage));
    await pumpEventQueue();
    final second = ensureAgentLoaded(
      'a',
      deps(manager, storage, broadcastTimeline: true),
    );

    manager.gate!.complete();
    await Future.wait([first, second]);

    expect(manager.hydrateBroadcasts, [true]);
  });

  test('a failed initialization clears the dedupe slot', () async {
    final storage = FakeRecordStorage();

    await expectLater(
      ensureAgentLoaded('ghost', deps(FakeFullLoaderManager(), storage)),
      throwsA(isA<PaseoServerServiceException>()),
    );
    expect(pendingAgentInitializationCount, 0);

    // A second attempt must re-read storage rather than reuse the failure.
    storage.records['ghost'] = createRecord(id: 'ghost');
    await ensureAgentLoaded('ghost', deps(FakeFullLoaderManager(), storage));
  });

  test('waits for an in-flight close on both barriers', () async {
    final manager = FakeFullLoaderManager();
    final storage = FakeRecordStorage({'a': createRecord(id: 'a')});

    await ensureAgentLoaded('a', deps(manager, storage));

    expect(manager.waited, ['a', 'a']);
  });

  group('ensureUnarchivedAgentLoaded', () {
    EnsureUnarchivedAgentLoadedDeps unarchivedDeps(
      ClosableAgentLoaderManager manager,
      AgentRecordStorage storage,
    ) => EnsureUnarchivedAgentLoadedDeps(
      agentManager: manager,
      agentStorage: storage,
      logger: logger,
    );

    test('refuses an already-archived record before loading', () async {
      final manager = FakeFullLoaderManager();
      final storage = FakeRecordStorage({
        'a': createRecord(id: 'a', archivedAt: '2026-01-02T00:00:00.000Z'),
      });

      await expectLater(
        ensureUnarchivedAgentLoaded('a', unarchivedDeps(manager, storage)),
        throwsA(
          isA<PaseoServerServiceException>().having(
            (error) => error.message,
            'message',
            'Agent is archived: a',
          ),
        ),
      );
      expect(manager.resumeCalls, isEmpty);
    });

    test('closes an agent archived while the load was in flight', () async {
      final manager = FakeFullLoaderManager();
      final storage = _ArchivingOnSecondReadStorage(createRecord(id: 'a'));

      await expectLater(
        ensureUnarchivedAgentLoaded('a', unarchivedDeps(manager, storage)),
        throwsA(
          isA<PaseoServerServiceException>().having(
            (error) => error.message,
            'message',
            'Agent is archived: a',
          ),
        ),
      );
      expect(manager.closeCalls, ['a']);
    });

    test('a failing close is logged, not thrown', () async {
      final manager = _FailingCloseManager();
      final storage = _ArchivingOnSecondReadStorage(createRecord(id: 'a'));

      await expectLater(
        ensureUnarchivedAgentLoaded('a', unarchivedDeps(manager, storage)),
        throwsA(isA<PaseoServerServiceException>()),
      );
      expect(
        logger.at(LogLevel.warn).single.message,
        'Failed to close concurrently archived agent',
      );
    });

    test('returns the agent when nothing archived it', () async {
      final manager = FakeFullLoaderManager();
      final storage = FakeRecordStorage({'a': createRecord(id: 'a')});

      final agent = await ensureUnarchivedAgentLoaded(
        'a',
        unarchivedDeps(manager, storage),
      );

      expect(agent.agentId, 'a');
      expect(manager.closeCalls, isEmpty);
    });
  });
}

/// Reports the record as live on the first read and archived afterwards,
/// reproducing an archive that lands while the load is in flight.
final class _ArchivingOnSecondReadStorage implements AgentRecordStorage {
  _ArchivingOnSecondReadStorage(this.record);

  final StoredAgentRecord record;
  var _reads = 0;

  @override
  Future<StoredAgentRecord?> get(String agentId) async {
    _reads += 1;
    if (_reads <= 2) return record;
    return StoredAgentRecord(
      id: record.id,
      provider: record.provider,
      cwd: record.cwd,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt,
      persistence: record.persistence,
      config: record.config,
      lastModeId: record.lastModeId,
      archivedAt: '2026-01-02T00:00:00.000Z',
    );
  }
}

final class _FailingCloseManager extends FakeFullLoaderManager {
  @override
  Future<void> closeAgent(String agentId) async {
    throw StateError('close failed');
  }
}

// ---------------------------------------------------------------------------
// archive-if-safe.ts
// ---------------------------------------------------------------------------

const archiveCwd = '/tmp/paseo/worktrees/repo/branch';
const archivePaseoHome = '/tmp/paseo';
const archiveWorktreesRoot = '/tmp/paseo/worktrees/repo';

ForgePullRequestStatus createPullRequest({bool isMerged = true}) =>
    ForgePullRequestStatus(
      url: 'https://github.com/acme/repo/pull/123',
      title: 'Merge me',
      state: 'open',
      baseRefName: 'main',
      headRefName: 'feature',
      isMerged: isMerged,
      mergeable: ForgeMergeable.mergeable,
      checks: const [],
      checksStatus: ForgeChecksStatus.success,
      reviewDecision: null,
    );

final class FakeAutoArchiveConfigStore implements AutoArchiveConfigStore {
  FakeAutoArchiveConfigStore(this.autoArchiveAfterMerge);

  final bool? autoArchiveAfterMerge;
  int calls = 0;

  @override
  AutoArchiveDaemonConfig get() {
    calls += 1;
    return AutoArchiveDaemonConfig(
      autoArchiveAfterMerge: autoArchiveAfterMerge,
    );
  }
}

final class FakeArchiveSnapshotSource implements WorkspaceGitSnapshotSource {
  FakeArchiveSnapshotSource(this.read);

  final Future<WorkspaceLocalGitSnapshot?> Function() read;
  final List<SnapshotCall> calls = [];

  @override
  Future<WorkspaceLocalGitSnapshot?> getSnapshot(
    String cwd, {
    bool force = false,
    String? reason,
  }) {
    calls.add(SnapshotCall(cwd, force, reason));
    return read();
  }
}

final class ArchiveHarness {
  ArchiveHarness({
    bool? autoArchiveAfterMerge = true,
    Future<WorkspaceLocalGitSnapshot?> Function()? getSnapshot,
    PaseoWorktreeOwnership ownership = const PaseoWorktreeOwnership(
      allowed: true,
      repoRoot: '/tmp/repo',
      worktreeRoot: archiveWorktreesRoot,
      worktreePath: archiveCwd,
    ),
    String? workspaceId = 'ws-auto-archive',
    Object? archiveThrows,
    List<PersistedWorkspaceRecord> activeWorkspaces = const [],
  }) : configStore = FakeAutoArchiveConfigStore(autoArchiveAfterMerge),
       snapshots = FakeArchiveSnapshotSource(
         getSnapshot ?? () async => buildSnapshot(cwd: archiveCwd),
       ) {
    lookup = AutoArchiveWorkspaceLookup(
      findWorkspaceIdForCwd: (cwd) async => 'ws-auto-archive',
      listActiveWorkspaces: () async => activeWorkspaces,
    );
    options = AutoArchiveArchiveOptions(
      paseoHome: archivePaseoHome,
      daemonConfigStore: configStore,
      workspaceGitService: snapshots,
      workspaceLookup: lookup,
      archiveWorkspaceRecord: (id) async => archivedWorkspaceIds.add(id),
      markWorkspaceArchiving: (ids, at) => marked.addAll(ids),
      clearWorkspaceArchiving: cleared.addAll,
      emitWorkspaceUpdatesForWorkspaceIds: (ids) async => emitted.addAll(ids),
    );
    deps = ArchiveIfSafeDependencies(
      archiveByScope: (invocation, request) async {
        archiveCalls.add(_ArchiveCall(invocation, request));
        if (archiveThrows != null) throw archiveThrows;
        await invocation.killTerminalsForWorkspace(
          (request.scope as WorkspaceArchiveScope).workspaceId,
        );
      },
      resolveWorkspaceIdAtPath: (lookupArg, targetPath) async {
        resolveCalls.add(_ResolveCall(lookupArg, targetPath));
        return workspaceId;
      },
      isPaseoOwnedWorktreeCwd:
          (cwd, {String? paseoHome, String? worktreesRoot}) async {
            ownershipCalls.add(_OwnershipCall(cwd, paseoHome, worktreesRoot));
            return ownership;
          },
      killTerminalsForWorkspace: (opts, sessionLogger, id) async =>
          killedWorkspaces.add(id),
    );
  }

  final FakeAutoArchiveConfigStore configStore;
  final FakeArchiveSnapshotSource snapshots;
  late final AutoArchiveWorkspaceLookup lookup;
  late final AutoArchiveArchiveOptions options;
  late final ArchiveIfSafeDependencies deps;

  final RecordingLogger log = RecordingLogger();
  final Set<String> inFlight = {};
  final List<String> archivedWorkspaceIds = [];
  final List<String> marked = [];
  final List<String> cleared = [];
  final List<String> emitted = [];
  final List<String> killedWorkspaces = [];
  final List<_ArchiveCall> archiveCalls = [];
  final List<_ResolveCall> resolveCalls = [];
  final List<_OwnershipCall> ownershipCalls = [];

  Future<void> run({String? cwd, ForgePullRequestStatus? pullRequest}) =>
      archiveIfSafe(
        cwd: cwd ?? archiveCwd,
        pullRequest: pullRequest ?? createPullRequest(),
        inFlight: inFlight,
        options: options,
        log: log,
        deps: deps,
      );
}

final class _ArchiveCall {
  const _ArchiveCall(this.invocation, this.request);

  final ArchiveByScopeInvocation invocation;
  final ArchiveByScopeRequest request;
}

final class _ResolveCall {
  const _ResolveCall(this.lookup, this.targetPath);

  final AutoArchiveWorkspaceLookup lookup;
  final String targetPath;
}

final class _OwnershipCall {
  const _OwnershipCall(this.cwd, this.paseoHome, this.worktreesRoot);

  final String cwd;
  final String? paseoHome;
  final String? worktreesRoot;
}

void archiveIfSafeTests() {
  test('does nothing when the pull request is not merged', () async {
    final harness = ArchiveHarness();

    await harness.run(pullRequest: createPullRequest(isMerged: false));

    expect(harness.configStore.calls, 0);
    expect(harness.snapshots.calls, isEmpty);
    expect(harness.archiveCalls, isEmpty);
  });

  test('does nothing when there is no pull request at all', () async {
    final harness = ArchiveHarness();

    await archiveIfSafe(
      cwd: archiveCwd,
      pullRequest: null,
      inFlight: harness.inFlight,
      options: harness.options,
      log: harness.log,
      deps: harness.deps,
    );

    expect(harness.configStore.calls, 0);
  });

  test('does nothing when auto-archive-after-merge is disabled', () async {
    final harness = ArchiveHarness(autoArchiveAfterMerge: false);

    await harness.run();

    expect(harness.configStore.calls, 1);
    expect(harness.snapshots.calls, isEmpty);
    expect(harness.archiveCalls, isEmpty);
  });

  test(
    'an unset auto-archive setting blocks just like a disabled one',
    () async {
      final harness = ArchiveHarness(autoArchiveAfterMerge: null);

      await harness.run();

      expect(harness.configStore.calls, 1);
      expect(harness.archiveCalls, isEmpty);
    },
  );

  test('does nothing when the cwd already has an archive in flight', () async {
    final harness = ArchiveHarness()..inFlight.add(archiveCwd);

    await harness.run();

    expect(harness.snapshots.calls, isEmpty);
    expect(harness.archiveCalls, isEmpty);
    // The pre-existing marker survives; this call must not clear someone
    // else's in-flight archive.
    expect(harness.inFlight.contains(archiveCwd), isTrue);
  });

  test('logs and skips when reading the snapshot fails', () async {
    final harness = ArchiveHarness(
      getSnapshot: () async => throw StateError('snapshot failed'),
    );

    await harness.run();

    final warning = harness.log.at(LogLevel.warn).single;
    expect(
      warning.message,
      'Failed to read snapshot for auto-archive; skipping',
    );
    expect(warning.fields['cwd'], archiveCwd);
    expect(warning.fields['err'], isA<StateError>());
    expect(harness.archiveCalls, isEmpty);
    expect(harness.inFlight.contains(archiveCwd), isFalse);
  });

  test('reads the snapshot with the auto-archive reason', () async {
    final harness = ArchiveHarness();

    await harness.run();

    expect(harness.snapshots.calls, [
      const SnapshotCall(archiveCwd, false, 'auto-archive-on-merge'),
    ]);
  });

  test('does nothing when there is no snapshot', () async {
    final harness = ArchiveHarness(getSnapshot: () async => null);

    await harness.run();

    expect(harness.ownershipCalls, isEmpty);
    expect(harness.archiveCalls, isEmpty);
  });

  test('does nothing when the worktree is dirty', () async {
    final harness = ArchiveHarness(
      getSnapshot: () async => buildSnapshot(cwd: archiveCwd, isDirty: true),
    );

    await harness.run();

    expect(harness.ownershipCalls, isEmpty);
    expect(harness.archiveCalls, isEmpty);
  });

  test('does nothing when the worktree is ahead of origin', () async {
    final harness = ArchiveHarness(
      getSnapshot: () async => buildSnapshot(cwd: archiveCwd, aheadOfOrigin: 1),
    );

    await harness.run();

    expect(harness.ownershipCalls, isEmpty);
    expect(harness.archiveCalls, isEmpty);
  });

  test(
    'archives when the PR is merged and the upstream branch was deleted',
    () async {
      final harness = ArchiveHarness(
        getSnapshot: () async => buildSnapshot(
          cwd: archiveCwd,
          aheadOfOrigin: null,
          behindOfOrigin: null,
        ),
      );

      await harness.run();

      expect(harness.archiveCalls, hasLength(1));
    },
  );

  test('does nothing when the cwd is not a daemon-owned worktree', () async {
    final harness = ArchiveHarness(
      ownership: const PaseoWorktreeOwnership(
        allowed: false,
        worktreePath: archiveCwd,
      ),
    );

    await harness.run();

    final call = harness.ownershipCalls.single;
    expect(call.cwd, archiveCwd);
    expect(call.paseoHome, archivePaseoHome);
    expect(call.worktreesRoot, isNull);
    expect(harness.archiveCalls, isEmpty);
  });

  test('logs and skips when the cwd resolves to no workspace', () async {
    final harness = ArchiveHarness(workspaceId: null);

    await harness.run();

    expect(
      harness.log.at(LogLevel.warn).single.message,
      'Auto-archive could not resolve a workspace for cwd; skipping',
    );
    expect(harness.archiveCalls, isEmpty);
    expect(harness.inFlight.contains(archiveCwd), isFalse);
  });

  test('logs and does not throw when archiving fails', () async {
    final harness = ArchiveHarness(archiveThrows: StateError('archive failed'));

    await harness.run();

    final warning = harness.log.at(LogLevel.warn).single;
    expect(warning.message, 'Auto-archive after merge failed');
    expect(warning.fields['cwd'], archiveCwd);
    expect(warning.fields['err'], isA<StateError>());
    expect(harness.inFlight.contains(archiveCwd), isFalse);
  });

  test('archives a clean daemon-owned worktree after merge', () async {
    final harness = ArchiveHarness();

    await harness.run();

    final resolve = harness.resolveCalls.single;
    expect(identical(resolve.lookup, harness.options.workspaceLookup), isTrue);
    expect(resolve.targetPath, archiveCwd);

    final archive = harness.archiveCalls.single;
    expect(identical(archive.invocation.options, harness.options), isTrue);
    expect(identical(archive.invocation.sessionLogger, harness.log), isTrue);
    expect(
      (archive.request.scope as WorkspaceArchiveScope).workspaceId,
      'ws-auto-archive',
    );
    expect(archive.request.requestId, 'auto-archive-on-merge');
    expect(
      archive.request.scope,
      const WorkspaceArchiveScope('ws-auto-archive'),
    );

    // The terminal kill is forwarded with the workspace being archived.
    expect(harness.killedWorkspaces, ['ws-auto-archive']);

    expect(
      harness.log.at(LogLevel.info).single.message,
      'Auto-archived worktree after PR merge',
    );
    expect(harness.inFlight.contains(archiveCwd), isFalse);
  });

  test('resolves the merged cwd to a single workspace and does not iterate '
      'siblings', () async {
    final harness = ArchiveHarness(
      workspaceId: 'ws-merged-worktree',
      activeWorkspaces: [
        workspaceRecord('ws-merged-worktree', PersistedWorkspaceKind.worktree),
        workspaceRecord('ws-sibling', PersistedWorkspaceKind.localCheckout),
      ],
    );

    await harness.run();

    expect(harness.resolveCalls, hasLength(1));
    expect(harness.archiveCalls, hasLength(1));
    expect(
      harness.archiveCalls.single.request.scope,
      const WorkspaceArchiveScope('ws-merged-worktree'),
    );
    // Nothing enumerated the siblings; the single resolution is authoritative.
    expect(
      (await harness.options.workspaceLookup.listActiveWorkspaces()).length,
      2,
    );
  });

  test('a second run after a completed archive is allowed', () async {
    final harness = ArchiveHarness();

    await harness.run();
    await harness.run();

    expect(harness.archiveCalls, hasLength(2));
  });

  test('real repo: a checkout outside the worktree root is refused', () async {
    final temp = Directory.systemTemp.createTempSync('archive-if-safe-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final root = temp.resolveSymbolicLinksSync();
    final repoDir = p.join(root, 'repo');
    Directory(repoDir).createSync(recursive: true);
    await runGit(repoDir, ['init', '-b', 'main']);
    await runGit(repoDir, ['config', 'user.email', 'test@example.com']);
    await runGit(repoDir, ['config', 'user.name', 'Paseo Test']);
    await runGit(repoDir, ['config', 'commit.gpgsign', 'false']);
    await runGit(repoDir, ['commit', '--allow-empty', '-m', 'initial']);

    // Ownership is decided by path shape, and this real checkout does not live
    // under <paseo-home>/worktrees, so the archive must be refused and the
    // directory must survive.
    final harness = ArchiveHarness(
      getSnapshot: () async => buildSnapshot(cwd: repoDir),
      ownership: PaseoWorktreeOwnership(
        allowed: false,
        repoRoot: repoDir,
        worktreePath: repoDir,
      ),
    );

    await harness.run(cwd: repoDir);

    expect(harness.archiveCalls, isEmpty);
    expect(Directory(repoDir).existsSync(), isTrue);
    expect(harness.inFlight, isEmpty);
  });
}

PersistedWorkspaceRecord workspaceRecord(
  String workspaceId,
  PersistedWorkspaceKind kind,
) => createPersistedWorkspaceRecord(
  workspaceId: workspaceId,
  projectId: 'project-1',
  cwd: archiveCwd,
  kind: kind,
  displayName: workspaceId,
  createdAt: '2026-01-01T00:00:00.000Z',
  updatedAt: '2026-01-01T00:00:00.000Z',
);

// ---------------------------------------------------------------------------

void main() {
  group('git-command-runtime-metrics', gitCommandRuntimeMetricsTests);
  group('logger', loggerTests);
  group('git-mutation-service', gitMutationServiceTests);
  group('persistence-hooks', persistenceHooksTests);
  group('agent-loading', agentLoadingTests);
  group('archive-if-safe', archiveIfSafeTests);

  test('GitRunner is the only git invoker this cluster uses', () {
    // Guards the reuse decision: the service must be constructible with an
    // injected runner rather than reaching for its own process wrapper.
    const service = GitMutationService(
      workspaceGitService: _NullGitSource(),
      logger: SilentPaseoLogger(),
      runner: GitRunner(executable: 'git'),
    );
    expect(service.runner.executable, 'git');
  });
}

final class _NullGitSource implements GitMutationGitSource {
  const _NullGitSource();

  @override
  Future<WorkspaceLocalGitSnapshot?> getSnapshot(
    String cwd, {
    bool force = false,
    String? reason,
  }) async => null;

  @override
  Future<bool> hasLocalBranch(String cwd, String branch) async => false;

  @override
  void invalidateForge(String cwd) {}

  @override
  Future<BranchCheckoutResolution> validateBranchRef(
    String cwd,
    String ref,
  ) async => const NotFoundBranchCheckoutResolution();
}
