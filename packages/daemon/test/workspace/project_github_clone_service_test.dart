import 'dart:io';

import 'package:agent_daemon/src/workspace/project_github_clone_service.dart';
import 'package:agent_daemon/src/workspace/workspace_registry.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('normalizes shorthand and complete remotes exactly', () {
    final https = normalizeCloneRepository(
      repo: 'owner/repo.git',
      cloneProtocol: ProjectGithubCloneProtocol.https,
    );
    expect(https.name, 'repo');
    expect(https.displayName, 'owner/repo');
    expect(https.cloneUrl, 'https://github.com/owner/repo.git');

    final ssh = normalizeCloneRepository(
      repo: 'owner/repo',
      cloneProtocol: ProjectGithubCloneProtocol.ssh,
    );
    expect(ssh.cloneUrl, 'git@github.com:owner/repo.git');

    final remote = normalizeCloneRepository(
      repo: ' git@internal.example:group/repo.git ',
    );
    expect(remote.name, 'repo');
    expect(remote.displayName, 'group/repo');
    expect(remote.cloneUrl, 'git@internal.example:group/repo.git');
  });

  test('rejects invalid shorthand and missing protocols', () {
    for (final invocation
        in <
          ({String repo, ProjectGithubCloneProtocol? protocol, String message})
        >[
          (
            repo: '',
            protocol: ProjectGithubCloneProtocol.https,
            message: 'Repository is required',
          ),
          (
            repo: 'owner',
            protocol: ProjectGithubCloneProtocol.https,
            message: 'owner/repo format',
          ),
          (
            repo: 'owner/repo/extra',
            protocol: ProjectGithubCloneProtocol.https,
            message: 'owner/repo format',
          ),
          (
            repo: 'bad owner/repo',
            protocol: ProjectGithubCloneProtocol.https,
            message: 'invalid characters',
          ),
          (
            repo: 'owner/repo',
            protocol: null,
            message: 'Clone protocol is required',
          ),
        ]) {
      expect(
        () => normalizeCloneRepository(
          repo: invocation.repo,
          cloneProtocol: invocation.protocol,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => '${error.message}',
            'message',
            contains(invocation.message),
          ),
        ),
      );
    }
  });

  test(
    'clones through staging, atomically renames, and registers project',
    () async {
      final fixture = await _CloneFixture.create();
      addTearDown(fixture.dispose);
      final calls = <Map<String, Object?>>[];
      final service = ProjectGithubCloneService(
        registries: fixture.registries,
        now: () => DateTime.parse('2026-07-30T03:00:00Z'),
        runClone:
            ({
              required cloneUrl,
              required targetPath,
              required cwd,
              required timeout,
              required maxOutputBytes,
            }) async {
              calls.add({
                'cloneUrl': cloneUrl,
                'targetPath': targetPath,
                'cwd': cwd,
                'timeout': timeout,
                'maxOutputBytes': maxOutputBytes,
              });
              await File(p.join(targetPath, 'README.md')).writeAsString('ok');
            },
      );

      final response = ProjectGithubCloneResponse.fromJson(
        (await service.handle(
          ProjectGithubCloneRequest(
            requestId: 'clone',
            repo: 'owner/repo',
            cloneProtocol: ProjectGithubCloneProtocol.https,
            targetDirectory: fixture.target.path,
          ).toJson(),
        ))!,
      );

      expect(response.error, isNull);
      expect(response.repo, 'owner/repo');
      expect(response.checkoutPath, p.join(fixture.target.path, 'repo'));
      expect(
        File(p.join(response.checkoutPath!, 'README.md')).readAsStringSync(),
        'ok',
      );
      expect(response.project?.projectDisplayName, 'repo');
      expect(response.project?.projectRootPath, response.checkoutPath);
      expect(response.project?.projectKind, WorkspaceProjectKind.git);
      expect(calls.single['cloneUrl'], 'https://github.com/owner/repo.git');
      expect(calls.single['cwd'], fixture.target.path);
      expect(calls.single['timeout'], projectGithubCloneTimeout);
      expect(calls.single['maxOutputBytes'], projectGithubCloneMaxOutputBytes);
      expect(
        fixture.target.listSync().where(
          (entry) => p.basename(entry.path).startsWith('.tinyrack-clone-'),
        ),
        isEmpty,
      );
      final projects = await fixture.registries.projects.list();
      expect(projects.single.projectId, response.project?.projectId);
    },
  );

  test('reports existing checkout without invoking git', () async {
    final fixture = await _CloneFixture.create();
    addTearDown(fixture.dispose);
    await Directory(p.join(fixture.target.path, 'repo')).create();
    var called = false;
    final service = ProjectGithubCloneService(
      registries: fixture.registries,
      runClone:
          ({
            required cloneUrl,
            required targetPath,
            required cwd,
            required timeout,
            required maxOutputBytes,
          }) async {
            called = true;
          },
    );
    final response = ProjectGithubCloneResponse.fromJson(
      (await service.handle(
        ProjectGithubCloneRequest(
          requestId: 'clone',
          repo: 'owner/repo',
          cloneProtocol: ProjectGithubCloneProtocol.ssh,
          targetDirectory: fixture.target.path,
        ).toJson(),
      ))!,
    );
    expect(response.checkoutPath, p.join(fixture.target.path, 'repo'));
    expect(response.project, isNull);
    expect(response.error, contains('Checkout path already exists'));
    expect(called, isFalse);
  });

  test('cleans partial staging after clone failure', () async {
    final fixture = await _CloneFixture.create();
    addTearDown(fixture.dispose);
    final service = ProjectGithubCloneService(
      registries: fixture.registries,
      runClone:
          ({
            required cloneUrl,
            required targetPath,
            required cwd,
            required timeout,
            required maxOutputBytes,
          }) async {
            await File(p.join(targetPath, 'partial')).writeAsString('partial');
            throw StateError('clone failed');
          },
    );
    final response = ProjectGithubCloneResponse.fromJson(
      (await service.handle(
        ProjectGithubCloneRequest(
          requestId: 'clone',
          repo: 'https://github.com/owner/repo.git',
          targetDirectory: fixture.target.path,
        ).toJson(),
      ))!,
    );
    expect(response.repo, 'owner/repo');
    expect(response.project, isNull);
    expect(response.error, 'clone failed');
    expect(
      fixture.target.listSync().where(
        (entry) => p.basename(entry.path).startsWith('.tinyrack-clone-'),
      ),
      isEmpty,
    );
  });

  test('expands tilde and ignores unrelated message types', () async {
    final fixture = await _CloneFixture.create();
    addTearDown(fixture.dispose);
    final service = ProjectGithubCloneService(
      registries: fixture.registries,
      environment: {'USERPROFILE': fixture.target.path},
      runClone:
          ({
            required cloneUrl,
            required targetPath,
            required cwd,
            required timeout,
            required maxOutputBytes,
          }) async {
            await File(p.join(targetPath, 'ok')).writeAsString('ok');
          },
    );
    expect(await service.handle(const {'type': 'other'}), isNull);
    final response = ProjectGithubCloneResponse.fromJson(
      (await service.handle(
        const ProjectGithubCloneRequest(
          requestId: 'clone',
          repo: 'owner/repo',
          cloneProtocol: ProjectGithubCloneProtocol.https,
          targetDirectory: '~/nested',
        ).toJson(),
      ))!,
    );
    expect(
      response.checkoutPath,
      p.join(fixture.target.path, 'nested', 'repo'),
    );
  });
}

final class _CloneFixture {
  const _CloneFixture({
    required this.root,
    required this.target,
    required this.registries,
  });

  final Directory root;
  final Directory target;
  final WorkspaceRegistries registries;

  static Future<_CloneFixture> create() async {
    final root = Directory.systemTemp.createTempSync('project-clone-test-');
    final target = await Directory(p.join(root.path, 'target')).create();
    final registries = WorkspaceRegistries(dataDir: root.path);
    await registries.initialize();
    return _CloneFixture(root: root, target: target, registries: registries);
  }

  Future<void> dispose() async {
    if (root.existsSync()) await root.delete(recursive: true);
  }
}
