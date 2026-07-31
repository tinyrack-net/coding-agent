import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/utils/paseo_process_utils.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Hand-written [TreeKillTarget] fake standing in for a child process.
///
/// [signals] records every direct kill so tests can assert on the fallback
/// path, and [exitNow] simulates the child reporting an exit.
final class _FakeTreeKillTarget implements TreeKillTarget {
  _FakeTreeKillTarget({
    this.pid = 4242,
    int? exitCode,
    this.signalCode,
    bool canReportExit = true,
  }) : _exitCode = exitCode,
       _exitCompleter = canReportExit ? Completer<void>() : null;

  @override
  final int? pid;

  @override
  final String? signalCode;

  int? _exitCode;
  final Completer<void>? _exitCompleter;

  final List<ProcessSignal> signals = <ProcessSignal>[];
  bool throwOnKill = false;

  @override
  int? get exitCode => _exitCode;

  @override
  Future<void>? get exited => _exitCompleter?.future;

  @override
  bool kill(ProcessSignal signal) {
    signals.add(signal);
    if (throwOnKill) throw StateError('kill raced with teardown');
    return true;
  }

  void exitNow([int code = 0]) {
    _exitCode = code;
    final completer = _exitCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }
}

/// Records the (pid, signal) pairs a tree signaller was asked for.
final class _RecordingTreeSignaller {
  _RecordingTreeSignaller({this.error, this.onSignal});

  final Object? error;
  final void Function()? onSignal;
  final List<(int, ProcessSignal)> calls = <(int, ProcessSignal)>[];

  Future<Object?> call(int pid, ProcessSignal signal) async {
    calls.add((pid, signal));
    onSignal?.call();
    return error;
  }
}

final class _FakeProcess implements Process {
  _FakeProcess({
    int exitCodeValue = 0,
    List<int> stdoutBytes = const <int>[],
    List<int> stderrBytes = const <int>[],
  }) : _stdout = Stream<List<int>>.value(stdoutBytes),
       _stderr = Stream<List<int>>.value(stderrBytes) {
    _stdinController.stream.drain<void>();
    scheduleMicrotask(() {
      if (!_exit.isCompleted) _exit.complete(exitCodeValue);
    });
  }

  @override
  final int pid = 31337;

  final Stream<List<int>> _stdout;
  final Stream<List<int>> _stderr;
  final Completer<int> _exit = Completer<int>();
  final StreamController<List<int>> _stdinController =
      StreamController<List<int>>();

  final List<ProcessSignal> killSignals = <ProcessSignal>[];

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Stream<List<int>> get stdout => _stdout;

  @override
  Stream<List<int>> get stderr => _stderr;

  @override
  late final IOSink stdin = IOSink(_stdinController.sink);

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killSignals.add(signal);
    if (!_exit.isCompleted) _exit.complete(-1);
    return true;
  }
}

final class _RecordingProcessHost implements ProcessHost {
  _RecordingProcessHost(this.process);

  final Process process;
  final List<ResolvedProcessLaunch> launches = <ResolvedProcessLaunch>[];
  final List<ProcessStartMode> modes = <ProcessStartMode>[];

  @override
  Future<Process> start(
    ResolvedProcessLaunch launch, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    launches.add(launch);
    modes.add(mode);
    return process;
  }
}

final class _ThrowingProcessHost implements ProcessHost {
  const _ThrowingProcessHost();

  @override
  Future<Process> start(
    ResolvedProcessLaunch launch, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async =>
      throw ProcessException(launch.command, launch.arguments, 'ENOENT');
}

// ---------------------------------------------------------------------------
// Real-process helpers (mirrors the daemon's existing *_process_test style)
// ---------------------------------------------------------------------------

/// Wraps a shell command string in the invocation this port builds, so the
/// integration tests dogfood [buildStringCommandShellInvocation].
StringCommandShellInvocation _shell(String command) =>
    buildStringCommandShellInvocation(command: command);

/// Environment a real shell needs to start at all. Copied key-for-key so the
/// Windows case-insensitive names (`Path`, `SystemRoot`, …) survive.
Map<String, String?> _shellBaseEnvironment([
  Map<String, String?> extra = const {},
]) {
  const wanted = {
    'path',
    'pathext',
    'systemroot',
    'windir',
    'comspec',
    'temp',
    'tmp',
    'home',
    'userprofile',
    'systemdrive',
    'psmodulepath',
  };
  final env = <String, String?>{};
  Platform.environment.forEach((key, value) {
    if (wanted.contains(key.toLowerCase())) env[key] = value;
  });
  return {...env, ...extra};
}

String _printEnvCommand(String name) => Platform.isWindows
    ? "[Console]::Out.Write([Environment]::GetEnvironmentVariable('$name'))"
    : 'printf %s "\${$name:-}"';

String _printCwdCommand() => Platform.isWindows
    ? '[Console]::Out.Write((Get-Location).Path)'
    : r'printf %s "$PWD"';

bool _isProcessRunning(int pid) {
  if (pid <= 0) return false;
  if (Platform.isWindows) {
    final result = Process.runSync('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    return '${result.stdout}'.contains('$pid');
  }
  return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
}

Future<bool> _waitUntil(bool Function() check, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (check()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return check();
}

void main() {
  // -------------------------------------------------------------------------
  // terminateWithTreeKill
  // -------------------------------------------------------------------------
  group('terminateWithTreeKill', () {
    const fastOptions = TerminateWithTreeKillOptions(
      gracefulTimeout: Duration(milliseconds: 30),
      forceTimeout: Duration(milliseconds: 30),
    );

    test('reports already-exited when the child has an exit code', () async {
      final child = _FakeTreeKillTarget(exitCode: 0);
      final signaller = _RecordingTreeSignaller();

      final result = await terminateWithTreeKill(
        child,
        fastOptions,
        signalTree: signaller.call,
      );

      expect(result, TerminateWithTreeKillResult.alreadyExited);
      expect(signaller.calls, isEmpty);
      expect(child.signals, isEmpty);
    });

    test('reports already-exited when only a signal code is present', () async {
      final child = _FakeTreeKillTarget(signalCode: 'SIGKILL');
      final signaller = _RecordingTreeSignaller();

      final result = await terminateWithTreeKill(
        child,
        fastOptions,
        signalTree: signaller.call,
      );

      expect(result, TerminateWithTreeKillResult.alreadyExited);
      expect(signaller.calls, isEmpty);
    });

    test('reports terminated when the graceful signal is enough', () async {
      final child = _FakeTreeKillTarget();
      final signaller = _RecordingTreeSignaller(onSignal: child.exitNow);

      final result = await terminateWithTreeKill(
        child,
        fastOptions,
        signalTree: signaller.call,
      );

      expect(result, TerminateWithTreeKillResult.terminated);
      expect(signaller.calls, [(4242, ProcessSignal.sigterm)]);
      expect(child.signals, isEmpty);
    });

    test('escalates to the force signal and reports killed', () async {
      final child = _FakeTreeKillTarget();
      var forceNotifications = 0;
      final signaller = _RecordingTreeSignaller(
        onSignal: () {
          // Only give in once the force signal arrives.
          if (forceNotifications > 0) child.exitNow(137);
        },
      );

      final result = await terminateWithTreeKill(
        child,
        TerminateWithTreeKillOptions(
          gracefulTimeout: const Duration(milliseconds: 30),
          forceTimeout: const Duration(milliseconds: 500),
          onForceSignal: () => forceNotifications++,
        ),
        signalTree: signaller.call,
      );

      expect(result, TerminateWithTreeKillResult.killed);
      expect(forceNotifications, 1);
      expect(signaller.calls, [
        (4242, ProcessSignal.sigterm),
        (4242, ProcessSignal.sigkill),
      ]);
    });

    test(
      'reports killed without waiting when no force timeout is given',
      () async {
        final child = _FakeTreeKillTarget();
        final signaller = _RecordingTreeSignaller();

        final result = await terminateWithTreeKill(
          child,
          const TerminateWithTreeKillOptions(
            gracefulTimeout: Duration(milliseconds: 20),
          ),
          signalTree: signaller.call,
        );

        // The child never exited, yet upstream still reports "killed".
        expect(result, TerminateWithTreeKillResult.killed);
        expect(child.exitCode, isNull);
        expect(signaller.calls.length, 2);
      },
    );

    test('reports kill-timeout when the force signal is ignored', () async {
      final child = _FakeTreeKillTarget();
      final signaller = _RecordingTreeSignaller();

      final result = await terminateWithTreeKill(
        child,
        fastOptions,
        signalTree: signaller.call,
      );

      expect(result, TerminateWithTreeKillResult.killTimeout);
      expect(signaller.calls, [
        (4242, ProcessSignal.sigterm),
        (4242, ProcessSignal.sigkill),
      ]);
    });

    test('honours custom graceful and force signals', () async {
      final child = _FakeTreeKillTarget();
      final signaller = _RecordingTreeSignaller();

      await terminateWithTreeKill(
        child,
        const TerminateWithTreeKillOptions(
          gracefulSignal: ProcessSignal.sighup,
          forceSignal: ProcessSignal.sigint,
          gracefulTimeout: Duration(milliseconds: 20),
          forceTimeout: Duration(milliseconds: 20),
        ),
        signalTree: signaller.call,
      );

      expect(signaller.calls, [
        (4242, ProcessSignal.sighup),
        (4242, ProcessSignal.sigint),
      ]);
    });

    test('falls back to a direct kill when the tree walk fails', () async {
      final child = _FakeTreeKillTarget();
      final signaller = _RecordingTreeSignaller(error: 'taskkill exploded');

      final result = await terminateWithTreeKill(
        child,
        fastOptions,
        signalTree: signaller.call,
      );

      expect(result, TerminateWithTreeKillResult.killTimeout);
      expect(child.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
    });

    test('kills the child directly when there is no usable pid', () async {
      for (final pid in <int?>[null, 0, -1]) {
        final child = _FakeTreeKillTarget(pid: pid);
        final signaller = _RecordingTreeSignaller();

        await terminateWithTreeKill(
          child,
          const TerminateWithTreeKillOptions(
            gracefulTimeout: Duration(milliseconds: 10),
          ),
          signalTree: signaller.call,
        );

        expect(signaller.calls, isEmpty, reason: 'pid $pid');
        expect(child.signals, [
          ProcessSignal.sigterm,
          ProcessSignal.sigkill,
        ], reason: 'pid $pid');
      }
    });

    test('swallows exceptions raised by a racing direct kill', () async {
      final child = _FakeTreeKillTarget(pid: null)..throwOnKill = true;

      final result = await terminateWithTreeKill(
        child,
        const TerminateWithTreeKillOptions(
          gracefulTimeout: Duration(milliseconds: 10),
        ),
      );

      expect(result, TerminateWithTreeKillResult.killed);
      expect(child.signals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
    });

    test(
      'skips the force signal when the child exits mid-escalation',
      () async {
        final child = _FakeTreeKillTarget(canReportExit: false);
        final signaller = _RecordingTreeSignaller(
          onSignal: () {
            // The exit is observed but never announced, exactly like a target
            // whose `once("exit")` hook is missing.
            child._exitCode = 0;
          },
        );

        final result = await terminateWithTreeKill(
          child,
          fastOptions,
          signalTree: signaller.call,
        );

        expect(result, TerminateWithTreeKillResult.killTimeout);
        expect(signaller.calls, [(4242, ProcessSignal.sigterm)]);
        expect(child.signals, isEmpty);
      },
    );

    test(
      'times out on both phases when the target cannot report exit',
      () async {
        final child = _FakeTreeKillTarget(canReportExit: false);
        final signaller = _RecordingTreeSignaller();

        final result = await terminateWithTreeKill(
          child,
          fastOptions,
          signalTree: signaller.call,
        );

        expect(result, TerminateWithTreeKillResult.killTimeout);
        expect(signaller.calls.length, 2);
      },
    );
  });

  // -------------------------------------------------------------------------
  // signalSystemProcessTree
  // -------------------------------------------------------------------------
  group('signalSystemProcessTree', () {
    test('uses taskkill /T /F on Windows', () async {
      final invocations = <(String, List<String>)>[];

      final error = await signalSystemProcessTree(
        99,
        ProcessSignal.sigterm,
        isWindows: true,
        run: (executable, arguments) async {
          invocations.add((executable, arguments));
          return ProcessResult(1, 0, '', '');
        },
        killPid: (_, _) => fail('killPid must not be used on Windows'),
      );

      expect(error, isNull);
      expect(invocations.single.$1, 'taskkill');
      expect(invocations.single.$2, ['/pid', '99', '/T', '/F']);
    });

    test('surfaces a non-zero taskkill exit as an error', () async {
      final error = await signalSystemProcessTree(
        99,
        ProcessSignal.sigterm,
        isWindows: true,
        run: (_, _) async => ProcessResult(1, 128, '', 'not found'),
        killPid: (_, _) => true,
      );

      expect(error, isNotNull);
      expect('$error', contains('128'));
      expect('$error', contains('not found'));
    });

    test('signals POSIX descendants leaf-first', () async {
      final killed = <(int, ProcessSignal)>[];

      final error = await signalSystemProcessTree(
        10,
        ProcessSignal.sigkill,
        isWindows: false,
        run: (executable, arguments) async {
          expect(executable, 'pgrep');
          return switch (arguments[1]) {
            '10' => ProcessResult(1, 0, '11\n12\n', ''),
            '11' => ProcessResult(1, 0, '13\n', ''),
            // pgrep exits 1 when a process simply has no children.
            _ => ProcessResult(1, 1, '', ''),
          };
        },
        killPid: (pid, signal) {
          killed.add((pid, signal));
          return true;
        },
      );

      expect(error, isNull);
      expect(killed, [
        (13, ProcessSignal.sigkill),
        (12, ProcessSignal.sigkill),
        (11, ProcessSignal.sigkill),
        (10, ProcessSignal.sigkill),
      ]);
    });

    test('kills only the root when pgrep reports no children', () async {
      final killed = <int>[];

      final error = await signalSystemProcessTree(
        7,
        ProcessSignal.sigterm,
        isWindows: false,
        run: (_, _) async => ProcessResult(1, 1, '', ''),
        killPid: (pid, _) {
          killed.add(pid);
          return true;
        },
      );

      expect(error, isNull);
      expect(killed, [7]);
    });

    test('ignores duplicate and malformed pgrep output', () async {
      final killed = <int>[];

      await signalSystemProcessTree(
        5,
        ProcessSignal.sigterm,
        isWindows: false,
        run: (_, arguments) async => arguments[1] == '5'
            ? ProcessResult(1, 0, '6\n6\nnot-a-pid\n0\n-3\n\n', '')
            : ProcessResult(1, 1, '', ''),
        killPid: (pid, _) {
          killed.add(pid);
          return true;
        },
      );

      expect(killed, [6, 5]);
    });

    test('returns an error when pgrep fails outright', () async {
      final error = await signalSystemProcessTree(
        5,
        ProcessSignal.sigterm,
        isWindows: false,
        run: (_, _) async => ProcessResult(1, 2, '', 'pgrep: bad usage'),
        killPid: (_, _) => fail('nothing should be killed'),
      );

      expect(error, isA<ProcessException>());
    });

    test('returns the thrown error when the helper cannot run', () async {
      final error = await signalSystemProcessTree(
        5,
        ProcessSignal.sigterm,
        isWindows: false,
        run: (_, _) async =>
            throw const ProcessException('pgrep', [], 'ENOENT'),
      );

      expect(error, isA<ProcessException>());
    });
  });

  // -------------------------------------------------------------------------
  // Windows shell decisions
  // -------------------------------------------------------------------------
  group('isWindowsCommandScript', () {
    test('matches .cmd and .bat case-insensitively on Windows', () {
      for (final command in ['claude.cmd', 'claude.CMD', 'x.bat', 'x.BAT']) {
        expect(
          isWindowsCommandScript(command, isWindows: true),
          isTrue,
          reason: command,
        );
      }
    });

    test('rejects other extensions and bare names', () {
      for (final command in ['node.exe', 'node', 'a.cmdx', r'C:\d.bat\node']) {
        expect(
          isWindowsCommandScript(command, isWindows: true),
          isFalse,
          reason: command,
        );
      }
    });

    test('is always false off Windows', () {
      expect(isWindowsCommandScript('claude.cmd', isWindows: false), isFalse);
    });
  });

  group('shouldUseWindowsShell', () {
    test('always shells out for a Windows command script', () {
      expect(
        shouldUseWindowsShell(
          r'C:\bin\claude.cmd',
          requestedShell: false,
          isWindows: true,
        ),
        isTrue,
      );
    });

    test('honours an explicit request when the command is not a script', () {
      expect(
        shouldUseWindowsShell('node', requestedShell: false, isWindows: true),
        isFalse,
      );
      expect(
        shouldUseWindowsShell(
          '/usr/bin/node',
          requestedShell: true,
          isWindows: false,
        ),
        isTrue,
      );
    });

    test('shells out for bare, extensionless commands on Windows', () {
      expect(shouldUseWindowsShell('git', isWindows: true), isTrue);
      expect(shouldUseWindowsShell('node', isWindows: true), isTrue);
    });

    test('does not shell out when the command names a path', () {
      expect(shouldUseWindowsShell(r'C:\bin\git', isWindows: true), isFalse);
      expect(shouldUseWindowsShell('bin/git', isWindows: true), isFalse);
    });

    test('does not shell out when the command has an extension', () {
      expect(shouldUseWindowsShell('git.exe', isWindows: true), isFalse);
    });

    test('never shells out off Windows without an explicit request', () {
      expect(shouldUseWindowsShell('git', isWindows: false), isFalse);
      expect(shouldUseWindowsShell('claude.cmd', isWindows: false), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Environment construction
  // -------------------------------------------------------------------------
  group('createExternalProcessEnvironment', () {
    test('strips runtime-control variables and unset keys', () {
      final env = createExternalProcessEnvironment(
        baseEnvironment: {
          'PATH': '/usr/bin',
          'CUSTOM': 'from-base',
          'PASEO_NODE_ENV': 'production',
          'PASEO_SUPERVISED': '1',
          'ELECTRON_RUN_AS_NODE': '0',
        },
        overlays: [
          {
            'CUSTOM': 'from-overlay',
            'ELECTRON_NO_ATTACH_CONSOLE': '1',
            'PASEO_DESKTOP_MANAGED': '1',
            'DROPPED': null,
          },
          null,
        ],
      );

      expect(env, {'PATH': '/usr/bin', 'CUSTOM': 'from-overlay'});
    });

    test('also strips the TINYRACK aliases this repo carries', () {
      final env = createExternalProcessEnvironment(
        baseEnvironment: {
          'TINYRACK_NODE_ENV': 'production',
          'TINYRACK_SUPERVISED': '1',
          'TINYRACK_DESKTOP_MANAGED': '1',
          'KEEP': 'yes',
        },
      );

      expect(env, {'KEEP': 'yes'});
    });

    test('returns an unmodifiable map', () {
      final env = createExternalProcessEnvironment(baseEnvironment: {'A': 'b'});
      expect(() => env['C'] = 'd', throwsUnsupportedError);
    });
  });

  group('createInternalProcessEnvironment', () {
    test('preserves Paseo-owned launcher variables', () {
      final env = createInternalProcessEnvironment(
        baseEnvironment: {
          'ELECTRON_RUN_AS_NODE': '1',
          'PASEO_NODE_ENV': 'production',
        },
        overlays: [
          {'CUSTOM': 'internal', 'PASEO_SUPERVISED': '1'},
        ],
      );

      expect(env, {
        'ELECTRON_RUN_AS_NODE': '1',
        'PASEO_NODE_ENV': 'production',
        'CUSTOM': 'internal',
        'PASEO_SUPERVISED': '1',
      });
    });

    test('drops explicitly unset overlay keys', () {
      final env = createInternalProcessEnvironment(
        baseEnvironment: {'GONE': 'x', 'KEPT': 'y'},
        overlays: [
          {'GONE': null},
        ],
      );

      expect(env, {'KEPT': 'y'});
    });
  });

  // -------------------------------------------------------------------------
  // resolveProcessLaunch
  // -------------------------------------------------------------------------
  group('resolveProcessLaunch', () {
    test('treats environment as the replacement base', () {
      final launch = resolveProcessLaunch(
        command: '/bin/node',
        arguments: const ['-v'],
        baseEnvironment: {'CUSTOM': 'from-base', 'ONLY_BASE': '1'},
        environment: {'CUSTOM': 'from-env'},
        environmentOverlay: {'CUSTOM': 'from-overlay'},
        isWindows: false,
        platformEnvironment: {'LEAKED': 'yes'},
      );

      expect(launch.environment, {'CUSTOM': 'from-overlay'});
    });

    test('falls back to baseEnvironment then the platform environment', () {
      expect(
        resolveProcessLaunch(
          command: '/bin/node',
          arguments: const [],
          baseEnvironment: {'FROM': 'base'},
          isWindows: false,
          platformEnvironment: {'LEAKED': 'yes'},
        ).environment,
        {'FROM': 'base'},
      );

      expect(
        resolveProcessLaunch(
          command: '/bin/node',
          arguments: const [],
          isWindows: false,
          platformEnvironment: {'FROM': 'platform'},
        ).environment,
        {'FROM': 'platform'},
      );
    });

    test('applies internal mode when requested', () {
      final launch = resolveProcessLaunch(
        command: '/bin/node',
        arguments: const [],
        environment: {'ELECTRON_RUN_AS_NODE': '1'},
        environmentMode: ProcessEnvironmentMode.internal,
        isWindows: false,
      );

      expect(launch.environment, {'ELECTRON_RUN_AS_NODE': '1'});
    });

    test('carries the shell decision, cwd and argument list', () {
      final launch = resolveProcessLaunch(
        command: 'git',
        arguments: const ['--version'],
        workingDirectory: '/repo',
        environment: const {},
        isWindows: true,
      );

      expect(launch.command, 'git');
      expect(launch.arguments, ['--version']);
      expect(launch.runInShell, isTrue);
      expect(launch.workingDirectory, '/repo');
      expect(() => launch.arguments.add('x'), throwsUnsupportedError);
    });

    test('leaves the command and arguments unquoted', () {
      // Deviation from upstream: dart:io performs its own Windows argument
      // quoting, so re-quoting here would double-escape.
      final launch = resolveProcessLaunch(
        command: r'C:\Program Files\bin\claude.cmd',
        arguments: const ['--format=%(refname)', 'say "hi"'],
        environment: const {},
        isWindows: true,
      );

      expect(launch.command, r'C:\Program Files\bin\claude.cmd');
      expect(launch.arguments, ['--format=%(refname)', 'say "hi"']);
      expect(launch.runInShell, isTrue);
    });
  });

  group('buildWindowsShellCommandLine', () {
    test('quotes a command path containing spaces', () {
      expect(
        buildWindowsShellCommandLine(r'C:\Program Files\node.exe', const [
          '-v',
        ], isWindows: true),
        r'"C:\Program Files\node.exe" -v',
      );
    });

    test('caret-escapes cmd metacharacters', () {
      expect(
        buildWindowsShellCommandLine('build', const [
          'a&b',
          'c|d',
          'e(f)',
        ], isWindows: true),
        'build a^&b c^|d e^(f^)',
      );
    });

    test('never doubles percent signs', () {
      // git's --format atoms break if `%` is doubled for cmd, so only the
      // parentheses are caret-escaped and every `%` survives verbatim.
      expect(
        buildWindowsShellCommandLine('git', const [
          '--format=%(refname)%09%(committerdate:unix)',
        ], isWindows: true),
        'git --format=%^(refname^)%09%^(committerdate:unix^)',
      );
      expect(
        buildWindowsShellCommandLine('git', const [
          '%(refname)',
        ], isWindows: true),
        'git %^(refname^)',
      );
    });

    test('passes values through untouched off Windows', () {
      expect(
        buildWindowsShellCommandLine('/usr/bin/git', const [
          'a&b',
          'c d',
        ], isWindows: false),
        '/usr/bin/git a&b c d',
      );
    });
  });

  // -------------------------------------------------------------------------
  // spawnProcess / execCommand against a fake host
  // -------------------------------------------------------------------------
  group('spawnProcess', () {
    test('hands the resolved launch and start mode to the host', () async {
      final host = _RecordingProcessHost(_FakeProcess());

      await spawnProcess(
        'git',
        const ['status'],
        options: const SpawnProcessOptions(
          workingDirectory: '/repo',
          environment: {'PATH': '/usr/bin', 'PASEO_SUPERVISED': '1'},
          environmentOverlay: {'CUSTOM': 'spawn-overlay'},
          mode: ProcessStartMode.detached,
        ),
        host: host,
        isWindows: true,
      );

      expect(host.launches.single.command, 'git');
      expect(host.launches.single.arguments, ['status']);
      expect(host.launches.single.runInShell, isTrue);
      expect(host.launches.single.workingDirectory, '/repo');
      expect(host.launches.single.environment, {
        'PATH': '/usr/bin',
        'CUSTOM': 'spawn-overlay',
      });
      expect(host.modes.single, ProcessStartMode.detached);
    });
  });

  group('execCommand against a fake host', () {
    test('decodes stdout and stderr with the requested encoding', () async {
      final host = _RecordingProcessHost(
        _FakeProcess(
          stdoutBytes: utf8.encode('hello'),
          stderrBytes: utf8.encode('warn'),
        ),
      );

      final result = await execCommand(
        '/bin/echo',
        const ['hello'],
        options: const ExecCommandOptions(environment: {}),
        host: host,
        isWindows: false,
      );

      expect(result.stdout, 'hello');
      expect(result.stderr, 'warn');
    });

    test('throws with captured output on a non-zero exit', () async {
      final host = _RecordingProcessHost(
        _FakeProcess(exitCodeValue: 3, stderrBytes: utf8.encode('boom')),
      );

      await expectLater(
        execCommand(
          '/bin/false',
          const [],
          options: const ExecCommandOptions(environment: {}),
          host: host,
          isWindows: false,
        ),
        throwsA(
          isA<ExecCommandException>()
              .having((e) => e.exitCode, 'exitCode', 3)
              .having((e) => e.stderr, 'stderr', 'boom')
              .having((e) => e.timedOut, 'timedOut', isFalse),
        ),
      );
    });

    test('kills the child and throws when maxBuffer is exceeded', () async {
      final process = _FakeProcess(stdoutBytes: utf8.encode('0123456789'));
      final host = _RecordingProcessHost(process);

      await expectLater(
        execCommand(
          '/bin/cat',
          const [],
          options: const ExecCommandOptions(environment: {}, maxBuffer: 4),
          host: host,
          isWindows: false,
        ),
        throwsA(
          isA<ExecCommandException>()
              .having((e) => e.stdout, 'stdout', '0123')
              .having((e) => e.reason, 'reason', contains('maxBuffer')),
        ),
      );
      expect(process.killSignals, isNotEmpty);
    });

    test('wraps a spawn failure as ExecCommandException', () async {
      await expectLater(
        execCommand(
          '/does/not/exist',
          const [],
          options: const ExecCommandOptions(environment: {}),
          host: const _ThrowingProcessHost(),
          isWindows: false,
        ),
        throwsA(
          isA<ExecCommandException>()
              .having((e) => e.exitCode, 'exitCode', isNull)
              .having((e) => e.reason, 'reason', 'ENOENT'),
        ),
      );
    });

    test('exposes a readable message', () {
      const exception = ExecCommandException(
        command: 'git',
        arguments: ['status'],
        exitCode: 1,
        stdout: '',
        stderr: 'fatal',
        reason: 'why',
      );

      expect('$exception', contains('git status'));
      expect('$exception', contains('exited with 1 (why)'));
      expect('$exception', contains('fatal'));
    });
  });

  // -------------------------------------------------------------------------
  // execCommand against real processes
  // -------------------------------------------------------------------------
  group('execCommand against real processes', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('paseo-process-utils-');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test('returns stdout and stderr for a successful command', () async {
      final invocation = _shell(
        Platform.isWindows
            ? "[Console]::Out.Write('hello'); [Console]::Error.Write('oops')"
            : r"printf %s hello; printf %s oops >&2",
      );

      final result = await execCommand(
        invocation.shell,
        invocation.args,
        options: ExecCommandOptions(
          baseEnvironment: _shellBaseEnvironment(),
          environmentOverlay: createStringCommandShellEnvOverlay(),
        ),
      );

      expect(result.stdout.trim(), 'hello');
      expect(result.stderr.trim(), 'oops');
    });

    test('throws when the command exits non-zero', () async {
      final invocation = _shell('exit 3');

      await expectLater(
        execCommand(
          invocation.shell,
          invocation.args,
          options: ExecCommandOptions(baseEnvironment: _shellBaseEnvironment()),
        ),
        throwsA(isA<ExecCommandException>().having((e) => e.exitCode, 'e', 3)),
      );
    });

    test('runs the command in the provided working directory', () async {
      final workDir = Directory(p.join(temp.path, 'work'))..createSync();
      final invocation = _shell(_printCwdCommand());

      final result = await execCommand(
        invocation.shell,
        invocation.args,
        options: ExecCommandOptions(
          workingDirectory: workDir.path,
          baseEnvironment: _shellBaseEnvironment(),
        ),
      );

      expect(
        result.stdout.trim().toLowerCase(),
        workDir.resolveSymbolicLinksSync().toLowerCase(),
      );
    });

    test(
      'rejects when the command exceeds its timeout',
      () async {
        final invocation = _shell(
          Platform.isWindows ? 'Start-Sleep -Seconds 30' : 'sleep 30',
        );

        await expectLater(
          execCommand(
            invocation.shell,
            invocation.args,
            options: ExecCommandOptions(
              baseEnvironment: _shellBaseEnvironment(),
              timeout: const Duration(milliseconds: 500),
            ),
          ),
          throwsA(
            isA<ExecCommandException>().having(
              (e) => e.timedOut,
              'timedOut',
              isTrue,
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'finalizes external command env and drops control variables',
      () async {
        final invocation = _shell(
          '${_printEnvCommand('CUSTOM')}; ${_printEnvCommand('PASEO_SUPERVISED')}',
        );

        final result = await execCommand(
          invocation.shell,
          invocation.args,
          options: ExecCommandOptions(
            baseEnvironment: _shellBaseEnvironment({
              'CUSTOM': 'from-base',
              'PASEO_SUPERVISED': '1',
            }),
            environmentOverlay: {'CUSTOM': 'from-overlay'},
          ),
        );

        expect(result.stdout.trim(), 'from-overlay');
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'internal env mode preserves Paseo-owned launcher env',
      () async {
        final invocation = _shell(_printEnvCommand('PASEO_SUPERVISED'));

        final result = await execCommand(
          invocation.shell,
          invocation.args,
          options: ExecCommandOptions(
            environmentMode: ProcessEnvironmentMode.internal,
            baseEnvironment: _shellBaseEnvironment({'PASEO_SUPERVISED': '1'}),
          ),
        );

        expect(result.stdout.trim(), '1');
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'does not inherit the parent environment when env is supplied',
      () async {
        // A variable the real parent process has but the supplied environment
        // deliberately omits; the child must not see it.
        // NUMBER_OF_PROCESSORS and friends are re-injected by the Windows
        // loader regardless of the supplied block, so probe a user-scoped one.
        final leakProbe = Platform.isWindows ? 'USERNAME' : 'USER';
        expect(
          Platform.environment[leakProbe],
          isNotNull,
          reason: '$leakProbe must exist in the parent env for this test',
        );

        final invocation = _shell(
          '${_printEnvCommand('CUSTOM')}; ${_printEnvCommand(leakProbe)}',
        );

        final result = await execCommand(
          invocation.shell,
          invocation.args,
          options: ExecCommandOptions(
            environment: _shellBaseEnvironment({'CUSTOM': 'only-this'}),
          ),
        );

        expect(result.stdout.trim(), 'only-this');
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  // -------------------------------------------------------------------------
  // terminateWithTreeKill against real processes
  // -------------------------------------------------------------------------
  group('terminateWithTreeKill against real processes', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('paseo-tree-kill-');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    test(
      'terminates a real long-running child',
      () async {
        final invocation = _shell(
          Platform.isWindows ? 'Start-Sleep -Seconds 120' : 'sleep 120',
        );

        final process = await spawnProcess(
          invocation.shell,
          invocation.args,
          options: SpawnProcessOptions(
            baseEnvironment: _shellBaseEnvironment(),
          ),
        );
        final target = ProcessTreeKillTarget(process);
        final pid = process.pid;

        final result = await terminateWithTreeKill(
          target,
          const TerminateWithTreeKillOptions(
            gracefulTimeout: Duration(seconds: 5),
            forceTimeout: Duration(seconds: 5),
          ),
        );

        expect(
          result,
          anyOf(
            TerminateWithTreeKillResult.terminated,
            TerminateWithTreeKillResult.killed,
          ),
        );
        await process.exitCode;
        expect(target.exitCode, isNotNull);
        expect(
          await _waitUntil(
            () => !_isProcessRunning(pid),
            const Duration(seconds: 5),
          ),
          isTrue,
        );
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'reports already-exited for a process that has finished',
      () async {
        final invocation = _shell('exit 0');
        final process = await spawnProcess(
          invocation.shell,
          invocation.args,
          options: SpawnProcessOptions(
            baseEnvironment: _shellBaseEnvironment(),
          ),
        );
        final target = ProcessTreeKillTarget(process);
        await process.exitCode;
        // Let the latch in ProcessTreeKillTarget observe the exit.
        await target.exited;

        final result = await terminateWithTreeKill(
          target,
          const TerminateWithTreeKillOptions(
            gracefulTimeout: Duration(seconds: 5),
          ),
        );

        expect(result, TerminateWithTreeKillResult.alreadyExited);
        expect(target.signalCode, isNull);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'kills a descendant that the owner spawned',
      () async {
        final pidFile = p.join(temp.path, 'descendant.pid');
        final Process owner;
        if (Platform.isWindows) {
          // cmd.exe owns a powershell descendant; only a tree kill reaps both.
          owner = await Process.start(
            Platform.environment['COMSPEC'] ?? 'cmd.exe',
            [
              '/d',
              '/c',
              'powershell',
              '-NoProfile',
              '-NonInteractive',
              '-ExecutionPolicy',
              'Bypass',
              '-Command',
              'Set-Content -Path $pidFile -Value \$PID; Start-Sleep -Seconds 120',
            ],
          );
        } else {
          owner = await Process.start('bash', [
            '-c',
            'sleep 120 & echo \$! > $pidFile; wait',
          ]);
        }
        owner.stdout.drain<void>();
        owner.stderr.drain<void>();

        final ready = await _waitUntil(() {
          final file = File(pidFile);
          if (!file.existsSync()) return false;
          final pid = int.tryParse(file.readAsStringSync().trim());
          return pid != null && pid > 0 && _isProcessRunning(pid);
        }, const Duration(seconds: 20));
        expect(ready, isTrue, reason: 'descendant fixture never became ready');
        final descendantPid = int.parse(
          File(pidFile).readAsStringSync().trim(),
        );

        final result = await terminateWithTreeKill(
          ProcessTreeKillTarget(owner),
          const TerminateWithTreeKillOptions(
            gracefulTimeout: Duration(seconds: 5),
            forceTimeout: Duration(seconds: 5),
          ),
        );

        expect(
          result,
          anyOf(
            TerminateWithTreeKillResult.terminated,
            TerminateWithTreeKillResult.killed,
          ),
        );
        expect(
          await _waitUntil(
            () =>
                !_isProcessRunning(owner.pid) &&
                !_isProcessRunning(descendantPid),
            const Duration(seconds: 15),
          ),
          isTrue,
          reason: 'owner or descendant survived terminateWithTreeKill',
        );
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  // -------------------------------------------------------------------------
  // string-command-shell
  // -------------------------------------------------------------------------
  group('buildStringCommandShellInvocation', () {
    test('uses bash script semantics on unix platforms', () {
      expect(
        buildStringCommandShellInvocation(
          command: 'echo "hello"',
          isWindows: false,
        ),
        const StringCommandShellInvocation(
          shell: 'bash',
          args: ['-c', 'echo "hello"'],
        ),
      );
    });

    test('uses powershell command semantics on windows by default', () {
      expect(
        buildStringCommandShellInvocation(
          command: "Write-Output 'hello'",
          isWindows: true,
        ),
        const StringCommandShellInvocation(
          shell: 'powershell',
          args: [
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-Command',
            "Write-Output 'hello'",
          ],
        ),
      );
    });

    test('can preserve cmd command semantics on windows', () {
      expect(
        buildStringCommandShellInvocation(
          command: 'echo %TEMP% && echo ok',
          isWindows: true,
          windowsShell: StringCommandWindowsShell.cmd,
        ),
        const StringCommandShellInvocation(
          shell: 'cmd.exe',
          args: ['/c', 'echo %TEMP% && echo ok'],
        ),
      );
    });

    test('ignores the windows shell choice off Windows', () {
      expect(
        buildStringCommandShellInvocation(
          command: 'true',
          isWindows: false,
          windowsShell: StringCommandWindowsShell.cmd,
        ).shell,
        'bash',
      );
    });

    test('defaults to the host platform', () {
      expect(
        buildStringCommandShellInvocation(command: 'true').shell,
        Platform.isWindows ? 'powershell' : 'bash',
      );
    });

    test('has value equality and a readable description', () {
      const a = StringCommandShellInvocation(shell: 'bash', args: ['-c', 'x']);
      const b = StringCommandShellInvocation(shell: 'bash', args: ['-c', 'x']);
      const c = StringCommandShellInvocation(shell: 'bash', args: ['-c', 'y']);
      const d = StringCommandShellInvocation(shell: 'bash', args: ['-c']);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a, isNot(d));
      expect(a, isNot('bash'));
      expect('$a', contains('bash'));
    });
  });

  group('createStringCommandShellEnv', () {
    test('removes BASH_ENV without mutating the input', () {
      final original = {'BASH_ENV': '/tmp/env.sh', 'PATH': '/usr/bin'};

      final sanitized = createStringCommandShellEnv(original);

      expect(sanitized, {'PATH': '/usr/bin'});
      expect(original.containsKey('BASH_ENV'), isTrue);
    });

    test('is a no-op when BASH_ENV is absent', () {
      expect(createStringCommandShellEnv({'PATH': '/usr/bin'}), {
        'PATH': '/usr/bin',
      });
    });

    test('the overlay form unsets BASH_ENV', () {
      expect(createStringCommandShellEnvOverlay(), {'BASH_ENV': null});
      expect(
        createExternalProcessEnvironment(
          baseEnvironment: {'BASH_ENV': '/tmp/env.sh', 'PATH': '/usr/bin'},
          overlays: [createStringCommandShellEnvOverlay()],
        ),
        {'PATH': '/usr/bin'},
      );
    });
  });

  test(
    'preserves the supplied PATH when login profiles rewrite it',
    () async {
      final home = Directory.systemTemp.createTempSync('paseo-shell-home-');
      addTearDown(() {
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      final binDir = Directory(p.join(home.path, 'bin'))..createSync();

      final shimPath = p.join(binDir.path, 'paseo-shim');
      File(
        shimPath,
      ).writeAsStringSync("#!/bin/sh\nprintf 'shim:%s\\n' \"\$1\"\n");
      Process.runSync('chmod', ['755', shimPath]);
      File(
        p.join(home.path, '.bash_profile'),
      ).writeAsStringSync('export PATH=/usr/bin:/bin\n');
      final bashEnvPath = p.join(home.path, 'bash-env');
      File(bashEnvPath).writeAsStringSync('export PATH=/usr/bin:/bin\n');

      final invocation = buildStringCommandShellInvocation(
        command: 'command -v paseo-shim >/dev/null && paseo-shim ok',
      );
      final result = await execCommand(
        invocation.shell,
        invocation.args,
        options: ExecCommandOptions(
          environment: createStringCommandShellEnv({
            ...Platform.environment,
            'HOME': home.path,
            'PATH':
                '${binDir.path}:${Platform.environment['PATH'] ?? '/usr/bin:/bin'}',
            'BASH_ENV': bashEnvPath,
          }),
        ),
      );

      expect(result.stdout.trim(), 'shim:ok');
    },
    skip: Platform.isWindows ? 'POSIX-only: needs bash and chmod' : null,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // -------------------------------------------------------------------------
  // script-hostname
  // -------------------------------------------------------------------------
  group('buildScriptHostname', () {
    test('builds default branch hostnames with script and project labels', () {
      expect(
        buildScriptHostname(
          projectSlug: 'paseo',
          branchName: null,
          scriptName: 'web',
        ),
        'web--paseo.localhost',
      );
    });

    test('omits the branch label for main and master', () {
      for (final branch in ['main', 'master']) {
        expect(
          buildScriptHostname(
            projectSlug: 'paseo',
            branchName: branch,
            scriptName: 'web',
          ),
          'web--paseo.localhost',
        );
      }
    });

    test('builds non-default branch hostnames with all three labels', () {
      expect(
        buildScriptHostname(
          projectSlug: 'paseo',
          branchName: 'feature-auth',
          scriptName: 'web',
        ),
        'web--feature-auth--paseo.localhost',
      );
    });

    test('slugifies every label', () {
      expect(
        buildScriptHostname(
          projectSlug: 'Paseo App',
          branchName: 'Feature/Auth Flow',
          scriptName: 'Web/API @ Dev',
        ),
        'web-api-dev--feature-auth-flow--paseo-app.localhost',
      );
    });

    test('accepts already slugified labels because slugify is idempotent', () {
      expect(
        buildScriptHostname(
          projectSlug: 'paseo-app',
          branchName: 'feature-auth-flow',
          scriptName: 'web-api-dev',
        ),
        'web-api-dev--feature-auth-flow--paseo-app.localhost',
      );
    });

    test('uses untitled when labels collapse to empty', () {
      expect(
        buildScriptHostname(
          projectSlug: '日本語',
          branchName: '***',
          scriptName: '---',
        ),
        'untitled--untitled--untitled.localhost',
      );
    });
  });

  group('buildPublicScriptHostname', () {
    test('uses one combined label under the public base host', () {
      expect(
        buildPublicScriptHostname(
          publicBaseUrl: 'https://services.example.com',
          projectSlug: 'paseo',
          branchName: 'feature-auth',
          scriptName: 'web',
        ),
        'web--feature-auth--paseo.services.example.com',
      );
    });

    test('omits default branch names from the public service label', () {
      expect(
        buildPublicScriptHostname(
          publicBaseUrl: 'https://services.example.com',
          projectSlug: 'paseo',
          branchName: 'main',
          scriptName: 'web',
        ),
        'web--paseo.services.example.com',
      );
    });

    test('caps the public service label to the DNS label length limit', () {
      final hostname = buildPublicScriptHostname(
        publicBaseUrl: 'https://services.example.com',
        projectSlug: 'project-' * 10,
        branchName: 'branch-' * 10,
        scriptName: 'script-' * 10,
      );
      final serviceLabel = hostname.split('.').first;

      expect(serviceLabel.length, lessThanOrEqualTo(63));
      expect(
        serviceLabel,
        matches(RegExp(r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$')),
      );
      expect(hostname, '$serviceLabel.services.example.com');
    });

    test('rejects a public base URL without a host', () {
      expect(
        () => buildPublicScriptHostname(
          publicBaseUrl: 'not-a-url',
          projectSlug: 'paseo',
          branchName: null,
          scriptName: 'web',
        ),
        throwsFormatException,
      );
    });
  });

  group('buildPublicScriptProxyUrl', () {
    test('preserves the configured public base protocol and port', () {
      expect(
        buildPublicScriptProxyUrl(
          publicBaseUrl: 'https://services.example.com:8443/base-is-ignored',
          projectSlug: 'paseo',
          branchName: 'feature-auth',
          scriptName: 'web',
        ),
        'https://web--feature-auth--paseo.services.example.com:8443',
      );
    });

    test('omits the port when the base URL has none', () {
      expect(
        buildPublicScriptProxyUrl(
          publicBaseUrl: 'http://services.example.com',
          projectSlug: 'paseo',
          branchName: null,
          scriptName: 'web',
        ),
        'http://web--paseo.services.example.com',
      );
    });
  });

  // -------------------------------------------------------------------------
  // tool-call-parsers
  // -------------------------------------------------------------------------
  group('stripCwdPrefix (re-exported)', () {
    test('strips cwd prefixes', () {
      expect(
        stripCwdPrefix('/tmp/repo/src/index.ts', '/tmp/repo'),
        'src/index.ts',
      );
      expect(stripCwdPrefix('/tmp/repo', '/tmp/repo'), '.');
    });
  });

  group('stripShellWrapperPrefix', () {
    test('strips a zsh wrapper together with its cd prefix', () {
      expect(
        stripShellWrapperPrefix('/bin/zsh -lc "cd /tmp/repo && npm test"'),
        'npm test',
      );
    });

    test('handles bash and sh wrappers', () {
      expect(stripShellWrapperPrefix('/bin/bash -c "npm test"'), 'npm test');
      expect(stripShellWrapperPrefix("/bin/sh -lc 'npm test'"), 'npm test');
    });

    test('handles a wrapper without a flag', () {
      expect(stripShellWrapperPrefix('/bin/sh npm test'), 'npm test');
    });

    test('strips quoted cd targets', () {
      expect(
        stripShellWrapperPrefix('/bin/zsh -lc \'cd "/tmp/my repo" && ls\''),
        'ls',
      );
      expect(
        stripShellWrapperPrefix("/bin/bash -c \"cd '/tmp/my repo' && ls\""),
        'ls',
      );
    });

    test('keeps a cd clause whose quoting survived the outer unwrap', () {
      // The inner escaped quotes are not a quoted token to the cd pattern, so
      // the clause stays — matching upstream's regex exactly.
      expect(
        stripShellWrapperPrefix('/bin/zsh -lc "cd \\"/tmp/my repo\\" && ls"'),
        r'cd \"/tmp/my repo\" && ls',
      );
    });

    test('returns the command untouched when there is no wrapper', () {
      expect(stripShellWrapperPrefix('npm test'), 'npm test');
      expect(
        stripShellWrapperPrefix('/usr/bin/zsh -lc "npm test"'),
        '/usr/bin/zsh -lc "npm test"',
      );
      expect(
        stripShellWrapperPrefix('cd /tmp/repo && npm test'),
        'cd /tmp/repo && npm test',
      );
    });

    test('leaves mismatched or single-character quoting alone', () {
      expect(stripShellWrapperPrefix('/bin/sh -c "npm test\''), '"npm test\'');
      expect(stripShellWrapperPrefix('/bin/sh -c "'), '"');
    });

    test('only strips one leading cd clause', () {
      expect(
        stripShellWrapperPrefix('/bin/sh -c "cd a && cd b && ls"'),
        'cd b && ls',
      );
    });
  });

  group('extractTodos', () {
    test('extracts todo entries', () {
      final todos = extractTodos({
        'todos': [
          {'content': 'Task 1', 'status': 'pending'},
          {'content': 'Task 2', 'status': 'completed'},
        ],
      });

      expect(todos, hasLength(2));
      expect(todos.first.content, 'Task 1');
      expect(todos.first.status, PaseoTodoStatus.pending);
      expect(todos.first.activeForm, isNull);
      expect(todos.last.status, PaseoTodoStatus.completed);
    });

    test('keeps activeForm and the in_progress status', () {
      final todos = extractTodos({
        'todos': [
          {
            'content': 'Port utils',
            'status': 'in_progress',
            'activeForm': 'Porting utils',
          },
        ],
      });

      expect(todos.single.status, PaseoTodoStatus.inProgress);
      expect(todos.single.activeForm, 'Porting utils');
    });

    test('ignores unknown keys', () {
      final todos = extractTodos({
        'todos': [
          {'content': 'Task', 'status': 'pending', 'extra': 42},
        ],
        'other': 'ignored',
      });

      expect(todos, hasLength(1));
    });

    test('returns an empty list for unrelated payloads', () {
      expect(extractTodos({'plan': <Object?>[]}), isEmpty);
      expect(extractTodos(null), isEmpty);
      expect(extractTodos('todos'), isEmpty);
      expect(extractTodos(<Object?>[]), isEmpty);
      expect(extractTodos({'todos': 'nope'}), isEmpty);
      expect(extractTodos({'todos': <Object?>[]}), isEmpty);
    });

    test('rejects the whole list when any entry is malformed', () {
      expect(
        extractTodos({
          'todos': [
            {'content': 'ok', 'status': 'pending'},
            {'content': 'bad', 'status': 'blocked'},
          ],
        }),
        isEmpty,
      );
      expect(
        extractTodos({
          'todos': [
            {'status': 'pending'},
          ],
        }),
        isEmpty,
      );
      expect(
        extractTodos({
          'todos': [
            {'content': 42, 'status': 'pending'},
          ],
        }),
        isEmpty,
      );
      expect(
        extractTodos({
          'todos': ['not-an-object'],
        }),
        isEmpty,
      );
      expect(
        extractTodos({
          'todos': [
            {'content': 'x', 'status': 'pending', 'activeForm': 7},
          ],
        }),
        isEmpty,
      );
    });

    test('treats an explicit null activeForm as absent', () {
      // Deviation: zod's `.optional()` rejects null, but a Dart Map cannot
      // distinguish a null value from a missing key.
      final todos = extractTodos({
        'todos': [
          {'content': 'x', 'status': 'pending', 'activeForm': null},
        ],
      });

      expect(todos.single.activeForm, isNull);
    });

    test('returns an unmodifiable list', () {
      final todos = extractTodos({
        'todos': [
          {'content': 'x', 'status': 'pending'},
        ],
      });

      expect(
        () => todos.add(
          const PaseoTodoItem(content: 'y', status: PaseoTodoStatus.pending),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('PaseoTodoStatus and PaseoTodoItem', () {
    test('maps wire names in both directions', () {
      expect(PaseoTodoStatus.inProgress.wireName, 'in_progress');
      expect(
        PaseoTodoStatus.fromWire('in_progress'),
        PaseoTodoStatus.inProgress,
      );
      expect(PaseoTodoStatus.fromWire('pending'), PaseoTodoStatus.pending);
      expect(PaseoTodoStatus.fromWire('completed'), PaseoTodoStatus.completed);
      expect(PaseoTodoStatus.fromWire('inProgress'), isNull);
      expect(PaseoTodoStatus.fromWire(null), isNull);
      expect(PaseoTodoStatus.fromWire(1), isNull);
    });

    test('has value equality and a readable description', () {
      const a = PaseoTodoItem(content: 'x', status: PaseoTodoStatus.pending);
      const b = PaseoTodoItem(content: 'x', status: PaseoTodoStatus.pending);
      const c = PaseoTodoItem(
        content: 'x',
        status: PaseoTodoStatus.pending,
        activeForm: 'doing x',
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a, isNot('x'));
      expect('$c', contains('doing x'));
      expect('$c', contains('pending'));
    });
  });
}
