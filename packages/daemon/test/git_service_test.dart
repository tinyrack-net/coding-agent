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
  });
}
