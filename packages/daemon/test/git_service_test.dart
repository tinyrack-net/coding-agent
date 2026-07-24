import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/git/git_runner.dart';
import 'package:agent_daemon/src/git/git_service.dart';
import 'package:agent_daemon/src/store/project_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
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

Future<void> _commit(String cwd, String message) => _git(
      [
        '-c', 'user.email=test@example.com',
        '-c', 'user.name=Test',
        '-c', 'commit.gpgsign=false',
        'commit', '-m', message,
      ],
      cwd,
    );

void main() {
  late Directory tempDir;
  late String repo;
  late String dataDir;
  late GitService service;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('git_service_test_');
    final base = tempDir.resolveSymbolicLinksSync();
    repo = p.join(base, 'myproject');
    dataDir = p.join(base, 'data');
    Directory(repo).createSync(recursive: true);
    service = GitService(dataDir: dataDir);

    await _git(['init', '-b', 'main'], repo);
    File(p.join(repo, 'readme.md')).writeAsStringSync('hello\nworld\n');
    await _git(['add', '-A'], repo);
    await _commit(repo, 'initial');
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('isGitRepo', () {
    test('true inside a repo, false outside', () async {
      expect(await service.isGitRepo(repo), isTrue);
      final plain = Directory(p.join(tempDir.path, 'plain'))..createSync();
      expect(await service.isGitRepo(plain.path), isFalse);
      expect(await service.isGitRepo(p.join(tempDir.path, 'missing')), isFalse);
    });
  });

  group('worktrees', () {
    test('create, list, archive round-trip', () async {
      final created = await service.createWorktree(repo, 'feature/login');
      expect(created.branch, 'feature/login');
      expect(created.isMain, isFalse);
      expect(p.isWithin(p.join(dataDir, 'worktrees'), created.path), isTrue);
      expect(p.basename(created.path), startsWith('myproject-feature-login'));
      expect(Directory(created.path).existsSync(), isTrue);

      final listed = await service.listWorktrees(repo);
      expect(listed, hasLength(2));
      final main = listed.singleWhere((w) => w.isMain);
      expect(p.equals(main.path, repo), isTrue);
      expect(main.branch, 'main');
      final wt = listed.singleWhere((w) => !w.isMain);
      expect(p.equals(wt.path, created.path), isTrue);
      expect(wt.branch, 'feature/login');
      expect(p.equals(wt.projectPath, repo), isTrue);

      await service.archiveWorktree(created.path);
      expect(Directory(created.path).existsSync(), isFalse);
      expect(await service.listWorktrees(repo), hasLength(1));
    });

    test('create for an existing branch reuses it', () async {
      await _git(['branch', 'existing'], repo);
      final created = await service.createWorktree(repo, 'existing');
      expect(created.branch, 'existing');
      final branches = await _git(['branch', '--list', 'existing'], repo);
      expect(branches.trim(), isNotEmpty);
    });

    test('create with baseRef branches off that ref instead of HEAD',
        () async {
      await _git(['branch', 'base-branch'], repo);
      File(p.join(repo, 'readme.md')).writeAsStringSync('hello\nworld\nmore\n');
      await _git(['add', '-A'], repo);
      await _commit(repo, 'advance main past base-branch');

      final created = await service.createWorktree(
        repo,
        'off-base',
        baseRef: 'base-branch',
      );
      final head = (await _git(['rev-parse', 'HEAD'], created.path)).trim();
      final baseHead = (await _git(['rev-parse', 'base-branch'], repo)).trim();
      expect(head, baseHead);
    });

    test('listBranches returns local branches, most recently committed '
        'first', () async {
      await _git(['branch', 'older'], repo);
      await _git(['checkout', '-b', 'newer'], repo);
      File(p.join(repo, 'readme.md')).writeAsStringSync('hello\nnewer\n');
      await _git(['add', '-A'], repo);
      // Force a committer date strictly after the initial commit: same-second
      // wall-clock commits would otherwise tie under `--sort=-committerdate`.
      final result = await Process.run(
        'git',
        [
          '-c', 'user.email=test@example.com',
          '-c', 'user.name=Test',
          '-c', 'commit.gpgsign=false',
          'commit', '-m', 'advance newer',
        ],
        workingDirectory: repo,
        environment: {
          'GIT_COMMITTER_DATE': '2030-01-01T00:00:00',
          'GIT_AUTHOR_DATE': '2030-01-01T00:00:00',
        },
      );
      expect(result.exitCode, 0, reason: result.stderr as String);
      await _git(['checkout', 'main'], repo);

      final branches = await service.listBranches(repo);
      expect(branches.first, 'newer');
      expect(branches, containsAll(['main', 'older', 'newer']));
    });

    test('currentBranch reports the checked-out branch, and "main" when '
        'HEAD is detached', () async {
      expect(await service.currentBranch(repo), 'main');

      final head = (await _git(['rev-parse', 'HEAD'], repo)).trim();
      await _git(['checkout', '--detach', head], repo);
      expect(await service.currentBranch(repo), 'main');
    });

    test('archiving the main worktree is rejected', () async {
      await expectLater(
        service.archiveWorktree(repo),
        throwsA(isA<StateError>()),
      );
    });

    test('worktree list from within a linked worktree still maps projectPath',
        () async {
      final created = await service.createWorktree(repo, 'side');
      final listed = await service.listWorktrees(created.path);
      expect(listed, hasLength(2));
      expect(p.equals(listed.first.path, repo), isTrue);
      expect(listed.first.isMain, isTrue);
    });

    test('collides with an existing directory at the target path and picks '
        'a numbered suffix', () async {
      // Pre-create the directory createWorktree would normally pick first.
      Directory(p.join(dataDir, 'worktrees', 'myproject-collide'))
          .createSync(recursive: true);
      final created = await service.createWorktree(repo, 'collide');
      expect(p.basename(created.path), 'myproject-collide-2');
    });

    test('falls back to a synthesized WorktreeInfo when the newly created '
        'worktree cannot be found by `git worktree list`', () async {
      final svc = GitService(dataDir: dataDir, runner: const _NoListRunner());
      final created = await svc.createWorktree(repo, 'ghost');
      expect(created.branch, 'ghost');
      expect(created.isMain, isFalse);
      expect(p.equals(created.projectPath, repo), isTrue);
      expect(p.basename(created.path), startsWith('myproject-ghost'));
    });

    test('archiving a plain directory that is not a registered worktree '
        'fails with "not a worktree"', () async {
      final plain = Directory(p.join(repo, 'just_a_folder'))
        ..createSync(recursive: true);
      await expectLater(
        service.archiveWorktree(plain.path),
        throwsA(isA<GitException>().having(
          (e) => e.message,
          'message',
          contains('not a worktree'),
        )),
      );
    });

    test('tolerates worktree directories that were deleted without '
        '`git worktree remove` when canonicalizing paths', () async {
      final ghost = await service.createWorktree(repo, 'ghost-del');
      final keep = await service.createWorktree(repo, 'keep-me');
      // Remove ghost's directory by hand; git still lists its path even
      // though it no longer exists on disk.
      await Directory(ghost.path).delete(recursive: true);

      await service.archiveWorktree(keep.path);
      expect(Directory(keep.path).existsSync(), isFalse);
    });

    test('detached-HEAD worktrees are reported with a synthesized branch '
        'label', () async {
      final head = (await _git(['rev-parse', 'HEAD'], repo)).trim();
      final target = p.join(dataDir, 'worktrees', 'detached-one');
      await Directory(p.dirname(target)).create(recursive: true);
      await _git(['worktree', 'add', '--detach', target, head], repo);

      final listed = await service.listWorktrees(repo);
      final detached = listed.singleWhere((w) => p.equals(w.path, target));
      expect(detached.branch, '(detached)');
    });

    test('uncommittedPaths is empty for a clean worktree', () async {
      final created = await service.createWorktree(repo, 'clean');
      expect(await service.uncommittedPaths(created.path), isEmpty);
    });

    test('uncommittedPaths reports tracked and untracked changes', () async {
      final created = await service.createWorktree(repo, 'dirty');
      File(p.join(created.path, 'readme.md')).writeAsStringSync('changed\n');
      File(p.join(created.path, 'new.txt')).writeAsStringSync('new\n');

      final dirty = await service.uncommittedPaths(created.path);
      expect(dirty, containsAll(['readme.md', 'new.txt']));
    });

    test('archiveWorktree refuses to remove a dirty worktree without force',
        () async {
      final created = await service.createWorktree(repo, 'guarded');
      File(p.join(created.path, 'readme.md')).writeAsStringSync('changed\n');

      await expectLater(
        service.archiveWorktree(created.path),
        throwsA(isA<GitDirtyWorktreeException>().having(
          (e) => e.uncommittedPaths,
          'uncommittedPaths',
          contains('readme.md'),
        )),
      );
      expect(Directory(created.path).existsSync(), isTrue);
    });

    test('archiveWorktree removes a dirty worktree when force is true',
        () async {
      final created = await service.createWorktree(repo, 'forced');
      File(p.join(created.path, 'readme.md')).writeAsStringSync('changed\n');

      await service.archiveWorktree(created.path, force: true);
      expect(Directory(created.path).existsSync(), isFalse);
    });
  });

  group('diff', () {
    test('working tree vs HEAD includes tracked changes and untracked files',
        () async {
      File(p.join(repo, 'readme.md')).writeAsStringSync('hello\nplanet\n');
      File(p.join(repo, 'untracked.txt'))
          .writeAsStringSync('new 1\nnew 2\nnew 3\n');
      File(p.join(repo, 'blob.bin')).writeAsBytesSync([1, 0, 2, 0, 3]);

      final response = await service.diff(repo);
      final byPath = {for (final f in response.files) f.path: f};
      expect(byPath.keys.toSet(), {'readme.md', 'untracked.txt', 'blob.bin'});

      final modified = byPath['readme.md']!;
      expect(modified.status, DiffFileStatus.modified);
      expect(modified.additions, 1);
      expect(modified.deletions, 1);
      final add = modified.hunks[0].lines
          .firstWhere((l) => l.type == DiffLineType.add);
      expect(add.text, 'planet');
      expect(add.newLineNo, 2);

      final untracked = byPath['untracked.txt']!;
      expect(untracked.status, DiffFileStatus.added);
      expect(untracked.binary, isFalse);
      expect(untracked.additions, 3);
      expect(untracked.hunks, hasLength(1));
      expect(untracked.hunks[0].header, '@@ -0,0 +1,3 @@');
      expect(
        untracked.hunks[0].lines.map((l) => l.text).toList(),
        ['new 1', 'new 2', 'new 3'],
      );
      expect(untracked.hunks[0].lines[2].newLineNo, 3);
      expect(
        untracked.hunks[0].lines.every((l) => l.type == DiffLineType.add),
        isTrue,
      );

      final binary = byPath['blob.bin']!;
      expect(binary.status, DiffFileStatus.added);
      expect(binary.binary, isTrue);
      expect(binary.hunks, isEmpty);
    });

    test('with baseRef diffs against that ref and skips untracked synthesis',
        () async {
      File(p.join(repo, 'readme.md')).writeAsStringSync('hello\nmoon\n');
      await _git(['add', '-A'], repo);
      await _commit(repo, 'second');
      File(p.join(repo, 'untracked.txt')).writeAsStringSync('x\n');

      final response = await service.diff(repo, baseRef: 'HEAD~1');
      expect(response.files, hasLength(1));
      final file = response.files.single;
      expect(file.path, 'readme.md');
      expect(file.status, DiffFileStatus.modified);
      expect(file.additions, 1);
      expect(file.deletions, 1);
    });

    test('clean tree yields empty diff', () async {
      final response = await service.diff(repo);
      expect(response.files, isEmpty);
    });

    test('bad baseRef throws GitException', () async {
      await expectLater(
        service.diff(repo, baseRef: 'no-such-ref'),
        throwsA(isA<GitException>()),
      );
    });

    test('untracked files larger than the cap are synthesized as binary',
        () async {
      File(p.join(repo, 'huge.bin'))
          .writeAsStringSync('a' * (1024 * 1024 + 10));
      final response = await service.diff(repo);
      final huge = response.files.singleWhere((f) => f.path == 'huge.bin');
      expect(huge.status, DiffFileStatus.added);
      expect(huge.binary, isTrue);
      expect(huge.hunks, isEmpty);
    });

    test('untracked files with CRLF line endings have the trailing \\r '
        'stripped from each line', () async {
      File(p.join(repo, 'crlf.txt'))
          .writeAsBytesSync(utf8.encode('one\r\ntwo\r\n'));
      final response = await service.diff(repo);
      final file = response.files.singleWhere((f) => f.path == 'crlf.txt');
      expect(
        file.hunks[0].lines.map((l) => l.text).toList(),
        ['one', 'two'],
      );
      expect(file.hunks[0].lines.every((l) => !l.text.contains('\r')), isTrue);
    });
  });

  group('ProjectStore', () {
    test('add persists and list survives reload; dedup by path', () async {
      final store = ProjectStore(dataDir: dataDir);
      await store.add(
        ProjectInfo(path: repo, name: 'myproject', isGitRepo: true),
      );
      await store.add(
        ProjectInfo(path: repo, name: 'myproject', isGitRepo: true),
      );
      expect(await store.list(), hasLength(1));

      final reloaded = ProjectStore(dataDir: dataDir);
      final projects = await reloaded.list();
      expect(projects, hasLength(1));
      expect(projects.single.name, 'myproject');
      expect(projects.single.isGitRepo, isTrue);
      expect(p.equals(projects.single.path, repo), isTrue);
      expect(File(p.join(dataDir, 'projects.json')).existsSync(), isTrue);
    });

    test('defaultDataDir resolves under the user home directory', () {
      final dir = ProjectStore.defaultDataDir();
      expect(dir, endsWith('.tinyrack-agent'));
    });
  });
}

/// A [GitRunner] that runs every command for real except `worktree list`,
/// which it fakes as empty — used to force [GitService.createWorktree]'s
/// "not found by listWorktrees" fallback path.
class _NoListRunner extends GitRunner {
  const _NoListRunner();

  @override
  Future<GitResult> run(
    List<String> args, {
    required String cwd,
    bool check = true,
  }) async {
    final result = await super.run(args, cwd: cwd, check: check);
    if (args.isNotEmpty && args[0] == 'worktree' && args.length > 1 && args[1] == 'list') {
      return const GitResult(exitCode: 0, stdout: '', stderr: '');
    }
    return result;
  }
}
