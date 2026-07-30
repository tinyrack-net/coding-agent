import 'dart:io';

import 'package:agent_daemon/src/workspace/github_repository_search_service.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('lists recent repositories and honors configured SSH cloning', () async {
    final calls = <List<String>>[];
    final service = WorkspaceGithubRepositorySearchService(
      environment: const {'HOME': '/home/test'},
      runner: (arguments, {required cwd}) async {
        expect(cwd, '/home/test');
        calls.add(arguments);
        if (arguments.first == 'config') {
          return const GithubCommandResult(
            exitCode: 0,
            stdout: 'ssh\n',
            stderr: '',
          );
        }
        return const GithubCommandResult(
          exitCode: 0,
          stdout:
              '[{"id":" R_1 ","name":" paseo ",'
              '"nameWithOwner":" getpaseo/paseo ","description":null,'
              '"visibility":"PUBLIC","updatedAt":"2026-07-15T12:00:00Z",'
              '"sshUrl":" git@github.com:getpaseo/paseo.git ",'
              '"url":"https://github.com/getpaseo/paseo"}]',
          stderr: '',
        );
      },
    );

    final response = WorkspaceGithubSearchRepositoriesResponse.fromJson(
      (await service.handle(
        const WorkspaceGithubSearchRepositoriesRequest(
          query: ' ',
          limit: 8,
          requestId: 'list',
        ).toJson(),
      ))!,
    );

    expect(response.status, WorkspaceGithubSearchStatus.success);
    expect(response.repositories.single.cloneUrl, startsWith('git@github.com'));
    expect(calls.first, containsAllInOrder(['repo', 'list', '--json']));
    expect(calls.first, containsAllInOrder(['--limit', '8']));
  });

  test('searches accessible repositories and normalizes HTTPS data', () async {
    final service = WorkspaceGithubRepositorySearchService(
      environment: const {'HOME': '/home/test'},
      runner: (arguments, {required cwd}) async => arguments.first == 'config'
          ? const GithubCommandResult(
              exitCode: 0,
              stdout: 'https\n',
              stderr: '',
            )
          : const GithubCommandResult(
              exitCode: 0,
              stdout:
                  '[{"id":42,"name":"private-repo",'
                  '"fullName":"octo/private-repo",'
                  '"description":"Private project","visibility":"PRIVATE",'
                  '"updatedAt":"2026-07-14T08:00:00Z",'
                  '"url":"https://github.com/octo/private-repo"}]',
              stderr: '',
            ),
    );

    final repositories = await service.search(
      query: ' private project ',
      limit: 5,
    );
    expect(repositories.single.id, '42');
    expect(repositories.single.visibility, GithubRepositoryVisibility.private);
    expect(
      repositories.single.cloneUrl,
      'https://github.com/octo/private-repo',
    );
  });

  test('maps missing, unauthenticated, and command failures', () async {
    Future<WorkspaceGithubSearchRepositoriesResponse> run(
      GithubCommandRunner runner,
      String requestId,
    ) async => WorkspaceGithubSearchRepositoriesResponse.fromJson(
      (await WorkspaceGithubRepositorySearchService(runner: runner).handle(
        WorkspaceGithubSearchRepositoriesRequest(
          query: '',
          requestId: requestId,
        ).toJson(),
      ))!,
    );

    final missing = await run(
      (arguments, {required cwd}) =>
          throw const ProcessException('gh', [], 'missing'),
      'missing',
    );
    expect(missing.status, WorkspaceGithubSearchStatus.unavailable);
    expect(missing.reason, 'gh_missing');

    final auth = await run(
      (arguments, {required cwd}) async => const GithubCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'not logged into any GitHub hosts; run gh auth login',
      ),
      'auth',
    );
    expect(auth.status, WorkspaceGithubSearchStatus.unauthenticated);

    final failed = await run(
      (arguments, {required cwd}) async => const GithubCommandResult(
        exitCode: 1,
        stdout: '',
        stderr: 'network unavailable',
      ),
      'failed',
    );
    expect(failed.status, WorkspaceGithubSearchStatus.error);
    expect(failed.available, isTrue);
  });

  test('unknown messages fall through', () async {
    final service = WorkspaceGithubRepositorySearchService();
    expect(await service.handle(const {'type': 'other'}), isNull);
  });
}
