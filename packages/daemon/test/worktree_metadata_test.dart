import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/git/worktree_metadata.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<void> _git(List<String> args, String cwd) async {
  final result = await Process.run('git', args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw StateError('git $args failed: ${result.stderr}');
  }
}

void main() {
  late Directory temporary;
  late String repository;
  late String worktree;

  setUp(() async {
    temporary = Directory.systemTemp.createTempSync('worktree-metadata-');
    repository = p.join(temporary.path, 'repository');
    worktree = p.join(temporary.path, 'linked');
    Directory(repository).createSync();
    await _git(['init', '-b', 'main'], repository);
    await File(p.join(repository, 'README.md')).writeAsString('test\n');
    await _git(['add', '.'], repository);
    await _git([
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.com',
      'commit',
      '-m',
      'initial',
    ], repository);
    await _git(['worktree', 'add', '-b', 'feature', worktree], repository);
  });

  tearDown(() {
    try {
      temporary.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('writes v1 base metadata in the linked worktree git directory', () {
    writeWorktreeBaseMetadata(
      worktree,
      baseRefName: 'origin/main',
      changeRequestLookupTarget: {
        'headRef': 'feature',
        'headRepositoryOwner': 'tinyrack',
        'changeRequestNumber': 42,
      },
    );

    final path = worktreeMetadataPath(worktree);
    expect(
      path,
      contains('${p.separator}.git${p.separator}worktrees${p.separator}'),
    );
    expect(jsonDecode(File(path).readAsStringSync()), {
      'version': 1,
      'baseRefName': 'main',
      'changeRequestLookupTarget': {
        'headRef': 'feature',
        'headRepositoryOwner': 'tinyrack',
        'changeRequestNumber': 42,
      },
    });
  });

  test('upgrades to v2 runtime metadata and preserves v2 extension fields', () {
    writeWorktreeBaseMetadata(worktree, baseRefName: 'main');
    writeWorktreeRuntimeMetadata(worktree, worktreePort: 45678);
    final first = readWorktreeMetadata(worktree)!;
    expect(first.version, 2);
    expect(first.baseRefName, 'main');
    expect(first.worktreePort, 45678);

    final path = worktreeMetadataPath(worktree);
    File(path).writeAsStringSync(
      jsonEncode({
        ...first.toJson(),
        'firstAgentBranchAutoName': {
          'status': 'pending',
          'placeholderBranchName': 'feature',
        },
      }),
    );
    writeWorktreeRuntimeMetadata(worktree, worktreePort: 45679);
    final second = readWorktreeMetadata(worktree)!;
    expect(second.worktreePort, 45679);
    expect(second.firstAgentBranchAutoName, {
      'status': 'pending',
      'placeholderBranchName': 'feature',
    });
  });

  test('persists the first-agent branch auto-name state transition', () {
    writeWorktreeBaseMetadata(worktree, baseRefName: 'main');
    writeWorktreeRuntimeMetadata(worktree, worktreePort: 45678);

    writeWorktreeFirstAgentBranchAutoNameMetadata(
      worktree,
      placeholderBranchName: 'dazzling-yak',
    );
    final pending = readWorktreeMetadata(worktree)!;
    expect(pending.version, 2);
    expect(pending.worktreePort, 45678);
    expect(pending.firstAgentBranchAutoName, {
      'status': 'pending',
      'placeholderBranchName': 'dazzling-yak',
    });

    final attemptedAt = DateTime.utc(2026, 7, 29, 1, 2, 3);
    final attempted = markWorktreeFirstAgentBranchAutoNameAttempted(
      worktree,
      attemptedAt: attemptedAt,
    );
    expect(attempted?.firstAgentBranchAutoName, {
      'status': 'attempted',
      'placeholderBranchName': 'dazzling-yak',
      'attemptedAt': '2026-07-29T01:02:03.000Z',
    });
    expect(
      markWorktreeFirstAgentBranchAutoNameAttempted(worktree)?.toJson(),
      attempted?.toJson(),
    );
  });

  test('validates base refs, ports, and persisted schema boundaries', () {
    for (final value in ['', 'HEAD', 'main..bad', 'main@{1}', 'bad name']) {
      expect(
        () => writeWorktreeBaseMetadata(worktree, baseRefName: value),
        throwsArgumentError,
      );
    }
    expect(
      () => writeWorktreeRuntimeMetadata(worktree, worktreePort: 0),
      throwsArgumentError,
    );
    expect(
      () => writeWorktreeRuntimeMetadata(repository, worktreePort: 1234),
      throwsStateError,
    );

    writeWorktreeBaseMetadata(worktree, baseRefName: 'main');
    File(worktreeMetadataPath(worktree)).writeAsStringSync(
      '{"version":2,"baseRefName":"main","runtime":{"worktreePort":0}}',
    );
    expect(() => readWorktreeMetadata(worktree), throwsFormatException);
  });
}
