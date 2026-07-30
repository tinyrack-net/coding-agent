import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/forge/forge_cli.dart';
import 'package:agent_daemon/src/forge/forge_resolver.dart';
import 'package:agent_daemon/src/forge/workspace_forge_status_service.dart';
import 'package:agent_daemon/src/workspace/polling_workspace_git_backend.dart';
import 'package:agent_daemon/src/workspace/workspace_git_observer_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory repo;
  late PollingWorkspaceGitBackend backend;

  setUp(() async {
    repo = Directory.systemTemp.createTempSync('polling-git-backend-');
    await _git(repo.path, ['init', '-b', 'main']);
    await _git(repo.path, ['config', 'user.email', 'test@example.com']);
    await _git(repo.path, ['config', 'user.name', 'Test']);
    File(
      '${repo.path}${Platform.pathSeparator}file.txt',
    ).writeAsStringSync('one\n');
    await _git(repo.path, ['add', '.']);
    await _git(repo.path, ['commit', '-m', 'initial']);
    await _git(repo.path, ['remote', 'add', 'origin', repo.path]);
    await _git(repo.path, ['fetch', 'origin']);
    await _git(repo.path, [
      'branch',
      '--set-upstream-to',
      'origin/main',
      'main',
    ]);
    backend = PollingWorkspaceGitBackend(
      pollInterval: const Duration(days: 1),
      watchDirectory: _noWatch,
    );
  });

  tearDown(() {
    backend.dispose();
    if (repo.existsSync()) repo.deleteSync(recursive: true);
  });

  test('emits initial, branch, and working-tree fingerprint changes', () async {
    final snapshots = <WorkspaceGitObserverSnapshot>[];
    final subscription = backend.registerWorkspace(repo.path, snapshots.add);
    await _waitFor(() => snapshots.isNotEmpty);
    expect(snapshots.single.currentBranch, 'main');
    final initial = snapshots.single.value! as WorkspaceLocalGitSnapshot;
    expect(
      Directory(initial.repoRoot).resolveSymbolicLinksSync(),
      repo.resolveSymbolicLinksSync(),
    );
    expect(initial.mainRepoRoot, isNull);
    expect(initial.remoteUrl, repo.path);
    expect(initial.hasRemote, isTrue);
    expect(initial.isDirty, isFalse);
    expect(initial.aheadOfOrigin, 0);
    expect(initial.behindOfOrigin, 0);
    expect(initial.diffStat.additions, 0);
    expect(initial.diffStat.deletions, 0);
    expect(initial.toWire(isPaseoOwnedWorktree: true).toJson(), {
      'currentBranch': 'main',
      'remoteUrl': repo.path,
      'isPaseoOwnedWorktree': true,
      'isDirty': false,
      'aheadOfOrigin': 0,
      'behindOfOrigin': 0,
    });

    await _git(repo.path, ['checkout', '-b', 'feature']);
    File(
      '${repo.path}${Platform.pathSeparator}feature.txt',
    ).writeAsStringSync('feature\n');
    await _git(repo.path, ['add', '.']);
    await _git(repo.path, ['commit', '-m', 'feature']);
    backend.setBaseRef(repo.path, 'main');
    await backend.refreshNow(repo.path);
    expect(snapshots.last.currentBranch, 'feature');
    expect(snapshots, hasLength(2));
    expect(backend.peekSnapshot(repo.path)?.aheadBehind?.ahead, 1);
    expect(backend.peekSnapshot(repo.path)?.aheadBehind?.behind, 0);

    File(
      '${repo.path}${Platform.pathSeparator}file.txt',
    ).writeAsStringSync('changed\n');
    await backend.refreshNow(repo.path);
    expect(snapshots, hasLength(3));
    expect(snapshots.last.currentBranch, 'feature');
    final dirty = backend.peekSnapshot(repo.path)!;
    expect(dirty.isDirty, isTrue);
    expect(dirty.diffStat.additions, 1);
    expect(dirty.diffStat.deletions, 1);

    File(
      '${repo.path}${Platform.pathSeparator}untracked.txt',
    ).writeAsStringSync('one\ntwo');
    File(
      '${repo.path}${Platform.pathSeparator}binary.dat',
    ).writeAsBytesSync([0, 1, 2]);
    File(
      '${repo.path}${Platform.pathSeparator}large.txt',
    ).writeAsBytesSync(List<int>.filled(1024 * 1024 + 1, 65));
    await backend.refreshNow(repo.path);
    expect(snapshots, hasLength(4));
    expect(backend.peekSnapshot(repo.path)?.diffStat.additions, 3);
    expect(backend.peekSnapshot(repo.path)?.diffStat.deletions, 1);

    await backend.refreshNow(repo.path);
    expect(snapshots, hasLength(4));
    subscription.unsubscribe();
    subscription.unsubscribe();
  });

  test('resolves the main repository root for a linked worktree', () async {
    final linked = Directory('${repo.path}-linked');
    await _git(repo.path, ['worktree', 'add', '-b', 'linked', linked.path]);
    final snapshots = <WorkspaceGitObserverSnapshot>[];
    final subscription = backend.registerWorkspace(linked.path, snapshots.add);
    try {
      await backend.refreshNow(linked.path);
      final snapshot = backend.peekSnapshot(linked.path)!;
      expect(
        Directory(snapshot.repoRoot).resolveSymbolicLinksSync(),
        linked.resolveSymbolicLinksSync(),
      );
      expect(
        Directory(snapshot.mainRepoRoot!).resolveSymbolicLinksSync(),
        repo.resolveSymbolicLinksSync(),
      );
    } finally {
      subscription.unsubscribe();
      await _git(repo.path, ['worktree', 'remove', '--force', linked.path]);
    }
  });

  test('detached HEAD is represented as null', () async {
    final snapshots = <WorkspaceGitObserverSnapshot>[];
    backend.registerWorkspace(repo.path, snapshots.add);
    await _waitFor(() => snapshots.isNotEmpty);
    await _git(repo.path, ['checkout', '--detach', 'HEAD']);
    await backend.refreshNow(repo.path);
    expect(snapshots.last.currentBranch, isNull);
  });

  test(
    'native working-tree events debounce refresh and share one watcher',
    () async {
      backend.dispose();
      final events = StreamController<FileSystemEvent>.broadcast();
      var watchCalls = 0;
      backend = PollingWorkspaceGitBackend(
        pollInterval: const Duration(days: 1),
        watchDebounce: Duration.zero,
        watchDirectory: (_, {required recursive}) {
          watchCalls++;
          expect(recursive, !Platform.isLinux);
          return events.stream;
        },
      );
      addTearDown(events.close);
      final firstSnapshots = <WorkspaceGitObserverSnapshot>[];
      final secondSnapshots = <WorkspaceGitObserverSnapshot>[];
      final first = backend.registerWorkspace(repo.path, firstSnapshots.add);
      final second = backend.registerWorkspace(repo.path, secondSnapshots.add);
      await _waitFor(
        () => firstSnapshots.isNotEmpty && secondSnapshots.isNotEmpty,
      );
      expect(watchCalls, 1);
      expect(events.hasListener, isTrue);

      File(
        '${repo.path}${Platform.pathSeparator}file.txt',
      ).writeAsStringSync('native watch\n');
      events.add(
        FileSystemModifyEvent(
          '${repo.path}${Platform.pathSeparator}file.txt',
          false,
          true,
        ),
      );
      await _waitFor(
        () => (firstSnapshots.last.value! as WorkspaceLocalGitSnapshot).isDirty,
      );
      expect(
        (secondSnapshots.last.value! as WorkspaceLocalGitSnapshot).isDirty,
        isTrue,
      );

      first.unsubscribe();
      expect(events.hasListener, isTrue);
      second.unsubscribe();
      await Future<void>.delayed(Duration.zero);
      expect(events.hasListener, isFalse);
    },
  );

  test(
    'one-shot checkout snapshots do not retain an observer target',
    () async {
      final snapshot = await backend.getSnapshot(repo.path, baseRef: 'main');

      expect(snapshot?.currentBranch, 'main');
      expect(snapshot?.isDirty, isFalse);
      expect(snapshot?.baseRef, 'main');
      expect(backend.peekSnapshot(repo.path), isNull);

      final directory = Directory.systemTemp.createTempSync('not-git-status-');
      addTearDown(() => directory.deleteSync(recursive: true));
      expect(await backend.getSnapshot(directory.path), isNull);
      expect(backend.peekSnapshot(directory.path), isNull);
    },
  );

  test(
    'refreshes pending forge checks at 20s and settled state at 120s',
    () async {
      backend.dispose();
      await _git(repo.path, [
        'remote',
        'set-url',
        'origin',
        'https://github.com/acme/repo.git',
      ]);
      var now = DateTime.utc(2026, 7, 27);
      var pending = true;
      final headSha = await _headSha(repo.path);
      final transport = _FakeForgeTransport((_, args) {
        if (args.take(2).join(' ') == 'auth status') {
          return const ForgeCommandResult(exitCode: 0, stdout: '', stderr: '');
        }
        return ForgeCommandResult(
          exitCode: 0,
          stdout: jsonEncode([
            {
              'number': 7,
              'url': 'https://github.com/acme/repo/pull/7',
              'title': 'Feature',
              'state': 'OPEN',
              'isDraft': false,
              'baseRefName': 'main',
              'headRefName': 'main',
              'headRefOid': headSha,
              'mergedAt': null,
              'reviewDecision': null,
              'mergeable': 'MERGEABLE',
              'headRepositoryOwner': {'login': 'acme'},
              'statusCheckRollup': [
                {
                  '__typename': 'StatusContext',
                  'context': 'build',
                  'state': pending ? 'PENDING' : 'SUCCESS',
                  'targetUrl': 'https://checks/build',
                },
              ],
            },
          ]),
          stderr: '',
        );
      });
      final forgeStatus = WorkspaceForgeStatusService(
        resolver: ForgeResolver(transport: transport, now: () => now),
        now: () => now,
      );
      backend = PollingWorkspaceGitBackend(
        forgeStatus: forgeStatus,
        pollInterval: const Duration(days: 1),
        watchDirectory: _noWatch,
        now: () => now,
      );
      final snapshots = <WorkspaceGitObserverSnapshot>[];
      backend.registerWorkspace(repo.path, snapshots.add);
      await _waitFor(() => snapshots.isNotEmpty);
      expect(
        backend.peekForgeSnapshot(repo.path)?.pullRequest?.checksStatus.name,
        'pending',
      );
      final initialCalls = transport.calls;

      now = now.add(const Duration(seconds: 19));
      await backend.refreshNow(repo.path, force: false);
      expect(transport.calls, initialCalls);

      now = now.add(const Duration(seconds: 1));
      pending = false;
      await backend.refreshNow(repo.path, force: false);
      expect(transport.calls, greaterThan(initialCalls));
      expect(
        backend.peekForgeSnapshot(repo.path)?.pullRequest?.checksStatus.name,
        'success',
      );
      final settledCalls = transport.calls;

      now = now.add(const Duration(seconds: 119));
      await backend.refreshNow(repo.path, force: false);
      expect(transport.calls, settledCalls);
      now = now.add(const Duration(seconds: 1));
      await backend.refreshNow(repo.path, force: false);
      expect(transport.calls, greaterThan(settledCalls));
    },
  );

  test(
    'does not attach terminal PRs after a same-name branch advances',
    () async {
      backend.dispose();
      await _git(repo.path, [
        'remote',
        'set-url',
        'origin',
        'https://github.com/acme/repo.git',
      ]);
      final staleHeadSha = await _headSha(repo.path);
      File(
        '${repo.path}${Platform.pathSeparator}reused.txt',
      ).writeAsStringSync('new branch lifetime\n');
      await _git(repo.path, ['add', '.']);
      await _git(repo.path, ['commit', '-m', 'reuse branch after terminal PR']);
      final currentHeadSha = await _headSha(repo.path);
      expect(currentHeadSha, isNot(staleHeadSha));

      final transport = _FakeForgeTransport((_, args) {
        if (args.take(2).join(' ') == 'auth status') {
          return const ForgeCommandResult(exitCode: 0, stdout: '', stderr: '');
        }
        expect(args.take(2), ['pr', 'list']);
        return ForgeCommandResult(
          exitCode: 0,
          stdout: jsonEncode([
            _githubTerminalPullRequest(
              number: 7,
              state: 'MERGED',
              headSha: staleHeadSha,
            ),
            _githubTerminalPullRequest(
              number: 8,
              state: 'CLOSED',
              headSha: staleHeadSha,
            ),
          ]),
          stderr: '',
        );
      });
      backend = PollingWorkspaceGitBackend(
        forgeStatus: WorkspaceForgeStatusService(
          resolver: ForgeResolver(transport: transport),
        ),
        pollInterval: const Duration(days: 1),
        watchDirectory: _noWatch,
      );

      final snapshots = <WorkspaceGitObserverSnapshot>[];
      backend.registerWorkspace(repo.path, snapshots.add);
      await _waitFor(() => snapshots.isNotEmpty);

      expect(
        (snapshots.single.value! as WorkspaceLocalGitSnapshot).headSha,
        currentHeadSha,
      );
      expect(backend.peekForgeSnapshot(repo.path)?.pullRequest, isNull);
    },
  );

  test(
    'non-git failures are silent and dispose rejects registration',
    () async {
      final directory = Directory.systemTemp.createTempSync('not-git-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final snapshots = <WorkspaceGitObserverSnapshot>[];
      backend.registerWorkspace(directory.path, snapshots.add);
      await backend.refreshNow(directory.path);
      expect(snapshots, isEmpty);
      backend.dispose();
      expect(
        () => backend.registerWorkspace(repo.path, (_) {}),
        throwsStateError,
      );
    },
  );
}

Stream<FileSystemEvent> _noWatch(String path, {required bool recursive}) =>
    const Stream.empty();

Future<void> _git(String cwd, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
}

Future<String> _headSha(String cwd) async {
  final result = await Process.run('git', [
    'rev-parse',
    'HEAD',
  ], workingDirectory: cwd);
  return (result.stdout as String).trim();
}

Map<String, Object?> _githubTerminalPullRequest({
  required int number,
  required String state,
  required String headSha,
}) => {
  'number': number,
  'url': 'https://github.com/acme/repo/pull/$number',
  'title': 'Historical pull request $number',
  'state': state,
  'isDraft': false,
  'baseRefName': 'main',
  'headRefName': 'main',
  'headRefOid': headSha,
  'mergedAt': state == 'MERGED' ? '2026-07-17T12:00:00Z' : null,
  'reviewDecision': null,
  'mergeable': 'UNKNOWN',
  'headRepositoryOwner': {'login': 'acme'},
  'statusCheckRollup': const <Object?>[],
};

typedef _ForgeHandler =
    ForgeCommandResult Function(String executable, List<String> args);

final class _FakeForgeTransport implements ForgeCommandTransport {
  _FakeForgeTransport(this.handler);

  final _ForgeHandler handler;
  int calls = 0;

  @override
  Future<ForgeCommandResult> run(
    String executable,
    List<String> args, {
    required String cwd,
    Map<String, String> environment = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls += 1;
    return handler(executable, args);
  }
}

Future<void> _waitFor(bool Function() predicate) async {
  // Coverage instrumentation plus real Windows git subprocess startup can
  // exceed three seconds on a loaded runner. The backend poll itself remains
  // deterministic; allow enough wall-clock time for the observable snapshot.
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for Git snapshot');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
