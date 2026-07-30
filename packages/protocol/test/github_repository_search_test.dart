import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  const repository = GithubRepository(
    id: 'R_1',
    name: 'paseo',
    nameWithOwner: 'getpaseo/paseo',
    description: null,
    visibility: GithubRepositoryVisibility.public,
    updatedAt: '2026-07-15T12:00:00Z',
    cloneUrl: 'git@github.com:getpaseo/paseo.git',
  );

  test('GitHub repository request preserves query and bounded limit', () {
    const request = WorkspaceGithubSearchRepositoriesRequest(
      query: 'agent',
      limit: 30,
      requestId: 'search-1',
    );
    expect(
      WorkspaceGithubSearchRepositoriesRequest.fromJson(
        request.toJson(),
      ).toJson(),
      request.toJson(),
    );
    for (final limit in [0, 51, 1.5]) {
      expect(
        () => WorkspaceGithubSearchRepositoriesRequest.fromJson({
          ...request.toJson(),
          'limit': limit,
        }),
        throwsFormatException,
      );
    }
  });

  test('GitHub repository search discriminated outcomes round trip', () {
    for (final response in const [
      WorkspaceGithubSearchRepositoriesResponse(
        status: WorkspaceGithubSearchStatus.success,
        requestId: 'success',
        repositories: [repository],
        available: true,
        error: null,
      ),
      WorkspaceGithubSearchRepositoriesResponse(
        status: WorkspaceGithubSearchStatus.unavailable,
        requestId: 'missing',
        repositories: [],
        reason: 'gh_missing',
        available: false,
        error: 'GitHub CLI is not installed',
      ),
      WorkspaceGithubSearchRepositoriesResponse(
        status: WorkspaceGithubSearchStatus.unauthenticated,
        requestId: 'auth',
        repositories: [],
        available: false,
        error: 'GitHub CLI authentication failed',
      ),
      WorkspaceGithubSearchRepositoriesResponse(
        status: WorkspaceGithubSearchStatus.error,
        requestId: 'error',
        repositories: [],
        available: true,
        error: 'Search failed',
      ),
    ]) {
      expect(
        WorkspaceGithubSearchRepositoriesResponse.fromJson(
          response.toJson(),
        ).toJson(),
        response.toJson(),
      );
    }
  });

  test('GitHub repository search rejects inconsistent outcome shapes', () {
    expect(
      () => WorkspaceGithubSearchRepositoriesResponse.fromJson(const {
        'type': WorkspaceGithubSearchRepositoriesResponse.type,
        'payload': {
          'status': 'success',
          'requestId': 'bad',
          'repositories': [],
          'available': false,
          'error': null,
        },
      }),
      throwsFormatException,
    );
    expect(
      () => GithubRepository.fromJson(const {
        'id': '',
        'name': 'repo',
        'nameWithOwner': 'a/b',
        'description': null,
        'visibility': 'public',
        'updatedAt': 'now',
        'cloneUrl': 'a/b',
      }),
      throwsFormatException,
    );
  });
}
