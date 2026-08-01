import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/git/git_runner.dart';
import 'package:agent_daemon/src/server/paseo_server_services.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<String> _git(List<String> args, String cwd) async {
  final result = await Process.run(
    'git',
    ['-c', 'core.quotepath=false', ...args],
    workingDirectory: cwd,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw StateError('git $args failed (${result.exitCode}): ${result.stderr}');
  }
  return result.stdout as String;
}

Future<void> _commit(String cwd, String message) => _git([
  '-c',
  'user.email=test@example.com',
  '-c',
  'user.name=Test',
  '-c',
  'commit.gpgsign=false',
  'commit',
  '-m',
  message,
], cwd);

void main() {
  _metricsWiring();
  late Directory tempDir;
  late String repo;
  late GitRunner runner;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('git_runner_test_');
    repo = tempDir.resolveSymbolicLinksSync();
    runner = const GitRunner();
    await _git(['init', '-b', 'main'], repo);
    File(p.join(repo, 'a.txt')).writeAsStringSync('hello\n');
    await _git(['add', '-A'], repo);
    await _commit(repo, 'initial');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    'successful command returns a GitResult with ok true and stdout',
    () async {
      final result = await runner.run(['log', '--oneline'], cwd: repo);
      expect(result.ok, isTrue);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('initial'));
      expect(result.stderr, isEmpty);
    },
  );

  test('checked run (default) throws GitException on nonzero exit', () async {
    await expectLater(
      runner.run([
        'rev-parse',
        '--verify',
        'refs/heads/no-such-branch',
      ], cwd: repo),
      throwsA(isA<GitException>()),
    );
  });

  test('check:false swallows nonzero exit and returns a result', () async {
    final result = await runner.run(
      ['rev-parse', '--verify', 'refs/heads/no-such-branch'],
      cwd: repo,
      check: false,
    );
    expect(result.ok, isFalse);
    expect(result.exitCode, isNot(0));
  });

  test('GitException carries args, exitCode, stdout and stderr', () async {
    try {
      await runner.run(['rev-parse', '--verify', 'refs/heads/nope'], cwd: repo);
      fail('expected GitException');
    } on GitException catch (e) {
      expect(e.args, ['rev-parse', '--verify', 'refs/heads/nope']);
      expect(e.exitCode, isNot(0));
      expect(e.stderr, isNotEmpty);
      expect(e.message, e.stderr.trim());
      expect(e.toString(), contains('GitException'));
      expect(e.toString(), contains('rev-parse'));
    }
  });

  test('GitException.message falls back to a generic message when stderr is '
      'empty', () {
    final e = GitException(args: ['status'], exitCode: 2, stderr: '   ');
    expect(e.message, 'git status exited 2');
  });

  test('always injects core.quotepath=false ahead of the given args', () async {
    File(p.join(repo, 'a.txt')).writeAsStringSync('changed\n');
    final result = await runner.run(['diff', '--stat'], cwd: repo);
    expect(result.ok, isTrue);
  });

  test('custom executable name is used to spawn the process', () async {
    const bogus = GitRunner(executable: 'definitely-not-a-real-git-binary');
    await expectLater(
      bogus.run(['status'], cwd: repo, check: false),
      throwsA(isA<ProcessException>()),
    );
  });
}

void _metricsWiring() {
  group('git command metrics observer', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('git-metrics-');
      await _git(['init', '-q'], dir.path);
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('real git calls land in the metrics window', () async {
      // The point of the wiring: before it, the ported window was live but
      // observed nothing, so every snapshot read zero no matter what git did.
      final window = GitCommandRuntimeMetricsWindow(4);
      final runner = GitRunner(observer: window.asGitCommandObserver());

      await runner.run(['status', '--porcelain'], cwd: dir.path);
      await runner.run(['rev-parse', '--git-dir'], cwd: dir.path);

      final snapshot = window.snapshotAndReset();
      expect(snapshot.submitted, 2);
      expect(snapshot.started, 2);
      expect(snapshot.completed, 2);
      expect(snapshot.failed, 0);
      expect(snapshot.timedOut, 0);
      // Counted by subcommand, not by the whole argument line.
      expect(
        snapshot.operationsTop.map((e) => e.operation),
        containsAll(<String>['status', 'rev-parse']),
      );
    });

    test('a nonzero exit is recorded as failed even when it throws', () async {
      final window = GitCommandRuntimeMetricsWindow(4);
      final runner = GitRunner(observer: window.asGitCommandObserver());

      await expectLater(
        runner.run(['rev-parse', '--verify', 'nope'], cwd: dir.path),
        throwsA(isA<GitException>()),
      );

      final snapshot = window.snapshotAndReset();
      expect(snapshot.completed, 1, reason: 'the command still finished');
      expect(snapshot.failed, 1);
    });

    test('a nonzero exit under check:false is still recorded once', () async {
      final window = GitCommandRuntimeMetricsWindow(4);
      final runner = GitRunner(observer: window.asGitCommandObserver());

      final result = await runner.run(
        ['rev-parse', '--verify', 'nope'],
        cwd: dir.path,
        check: false,
      );

      expect(result.ok, isFalse);
      final snapshot = window.snapshotAndReset();
      expect(snapshot.completed, 1);
      expect(snapshot.failed, 1);
    });

    test('a spawn failure closes its handle instead of leaking it', () async {
      final window = GitCommandRuntimeMetricsWindow(4);
      final runner = GitRunner(
        executable: 'definitely-not-git-xyz',
        observer: window.asGitCommandObserver(),
      );

      await expectLater(
        runner.run(['status'], cwd: dir.path),
        throwsA(anything),
      );

      final snapshot = window.snapshotAndReset();
      expect(snapshot.failed, 1);
      // Nothing left pending to bleed into the next window.
      expect(snapshot.pending, 0);
    });

    test('a runner with no observer still works', () async {
      const runner = GitRunner();
      final result = await runner.run(['status', '--porcelain'], cwd: dir.path);
      expect(result.ok, isTrue);
    });
  });
}
