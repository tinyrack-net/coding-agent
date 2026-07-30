import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/git/git_service.dart';
import 'package:agent_daemon/src/workspace/checkout_commits_service.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<String> _git(String cwd, List<String> args) async {
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

Future<String> _commit(String cwd, String subject) async {
  await _git(cwd, ['add', '-A']);
  await _git(cwd, [
    '-c',
    'user.name=Commit Tester',
    '-c',
    'user.email=commits@example.com',
    '-c',
    'commit.gpgsign=false',
    'commit',
    '-m',
    subject,
  ]);
  return _git(cwd, ['rev-parse', 'HEAD']);
}

void main() {
  late Directory temp;
  late String repo;
  late String remote;
  late GitService git;
  late CheckoutCommitsService service;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('checkout_commits_');
    final root = temp.resolveSymbolicLinksSync();
    repo = p.join(root, 'repo');
    remote = p.join(root, 'remote.git');
    Directory(repo).createSync();
    Directory(remote).createSync();
    await _git(repo, ['init', '-b', 'main']);
    await _git(remote, ['init', '--bare']);
    File(p.join(repo, 'base.txt')).writeAsStringSync('base 0\n');
    await _commit(repo, 'base 0');
    for (var index = 1; index <= 11; index++) {
      File(p.join(repo, 'base.txt')).writeAsStringSync('base $index\n');
      await _commit(repo, 'base $index');
    }
    await _git(repo, ['remote', 'add', 'origin', remote]);
    await _git(repo, ['push', '-u', 'origin', 'main']);
    await _git(repo, ['checkout', '-b', 'feature/history']);
    for (var index = 0; index < 12; index++) {
      File(
        p.join(repo, 'feature-$index.txt'),
      ).writeAsStringSync('feature $index\n');
      await _commit(repo, 'feature $index');
    }
    git = GitService(dataDir: p.join(root, 'data'));
    service = CheckoutCommitsService(
      git: git,
      resolveStoredBaseRef: (_) async => 'main',
    );
  });

  tearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows virus scanners can briefly retain git pack handles.
    }
  });

  test(
    'lists every workspace commit plus ten classified base commits',
    () async {
      final result = await git.listCheckoutCommits(repo, storedBaseRef: 'main');

      expect(result.baseRef, 'main');
      expect(result.commits, hasLength(22));
      final workspace = result.commits.take(12).toList();
      final base = result.commits.skip(12).toList();
      expect(workspace.every((commit) => commit.isOnBase == false), isTrue);
      expect(base.every((commit) => commit.isOnBase == true), isTrue);
      expect(workspace.every((commit) => !commit.isOnRemote), isTrue);
      expect(base.every((commit) => commit.isOnRemote), isTrue);
      expect(workspace.first.subject, 'feature 11');
      expect(workspace.last.subject, 'feature 0');
      expect(
        workspace.first.files.single,
        isA<CheckoutCommitFile>()
            .having((file) => file.path, 'path', 'feature-11.txt')
            .having((file) => file.additions, 'additions', 1)
            .having(
              (file) => file.status,
              'status',
              CheckoutCommitFileStatus.added,
            ),
      );

      await _git(repo, ['push', '-u', 'origin', 'feature/history']);
      final pushed = await git.listCheckoutCommits(repo, storedBaseRef: 'main');
      expect(pushed.commits.every((commit) => commit.isOnRemote), isTrue);
    },
  );

  test(
    'falls back from deleted stored base and returns no detached history',
    () async {
      final fallback = await git.listCheckoutCommits(
        repo,
        storedBaseRef: 'deleted-base',
      );
      expect(fallback.baseRef, 'main');
      expect(
        fallback.commits.where((commit) => commit.isOnBase == false),
        hasLength(12),
      );

      await _git(repo, ['checkout', '--detach']);
      final detached = await git.listCheckoutCommits(
        repo,
        storedBaseRef: 'main',
      );
      expect(detached.baseRef, isNull);
      expect(detached.commits, isEmpty);
    },
  );

  test(
    'returns highlighted text diff and null for binary-only commit',
    () async {
      final textSha = await _git(repo, ['rev-parse', 'HEAD']);
      final text = await git.commitFileDiff(
        repo,
        sha: textSha,
        path: 'feature-11.txt',
      );
      expect(text?.status, DiffFileStatus.added);
      expect(text?.hunks, isNotEmpty);

      File(p.join(repo, 'asset.bin')).writeAsBytesSync([0, 1, 2, 3]);
      final binarySha = await _commit(repo, 'add binary');
      final binary = await git.commitFileDiff(
        repo,
        sha: binarySha,
        path: 'asset.bin',
      );
      expect(binary, isNull);

      final response = CheckoutCommitFileDiffResponse.fromJson(
        await service.handle(
              CheckoutCommitFileDiffRequest(
                cwd: repo,
                sha: textSha,
                path: 'feature-11.txt',
                requestId: 'diff-1',
              ).toJson(),
            )
            as Map<String, Object?>,
      );
      expect(response.error, isNull);
      expect(response.file?.path, 'feature-11.txt');
    },
  );

  test(
    'service preserves request paths and rejects unsafe refs and paths',
    () async {
      final listed = CheckoutCommitsListResponse.fromJson(
        await service.handle(
              CheckoutCommitsListRequest(
                cwd: repo,
                requestId: 'list-1',
              ).toJson(),
            )
            as Map<String, Object?>,
      );
      expect(listed.cwd, repo);
      expect(listed.requestId, 'list-1');
      expect(listed.error, isNull);

      for (final request in [
        CheckoutCommitFileDiffRequest(
          cwd: repo,
          sha: '--output=bad',
          path: 'base.txt',
          requestId: 'bad-ref',
        ),
        CheckoutCommitFileDiffRequest(
          cwd: repo,
          sha: 'HEAD',
          path: '../base.txt',
          requestId: 'bad-path',
        ),
      ]) {
        final response = CheckoutCommitFileDiffResponse.fromJson(
          await service.handle(request.toJson()) as Map<String, Object?>,
        );
        expect(response.file, isNull);
        expect(response.error?.code, CheckoutErrorCode.unknown);
      }
    },
  );
}
