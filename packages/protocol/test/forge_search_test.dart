import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('forge search request normalizes modern and compatibility kinds', () {
    final request = ForgeSearchRequest.fromJson({
      'type': 'forge.search.request',
      'cwd': 'C:/repo',
      'query': '',
      'limit': 12,
      'kinds': ['issue', 'github-pr', 'pr'],
      'requestId': 'r1',
    });
    expect(request.kinds, [
      ForgeSearchKind.issue,
      ForgeSearchKind.changeRequest,
      ForgeSearchKind.changeRequest,
    ]);
    expect(request.toJson()['kinds'], [
      'issue',
      'change_request',
      'change_request',
    ]);
  });

  test('forge search response round trips all item fields', () {
    final response = ForgeSearchResponse(
      items: const [
        ForgeSearchItem(
          kind: ForgeSearchKind.changeRequest,
          forge: 'gitlab',
          number: 17,
          title: 'Ship',
          url: 'https://gitlab.com/acme/repo/-/merge_requests/17',
          state: 'opened',
          body: null,
          labels: ['release'],
          projectPath: 'acme/repo',
          baseRefName: 'main',
          headRefName: 'feature',
          updatedAt: '2026-07-27T00:00:00Z',
        ),
      ],
      authState: 'authenticated',
      error: null,
      requestId: 'r2',
    );
    expect(
      ForgeSearchResponse.fromJson(response.toJson()).toJson(),
      response.toJson(),
    );
  });

  test('forge search boundaries reject invalid kinds, limits, and items', () {
    Map<String, Object?> request(Object? limit, Object? kinds) => {
      'type': 'forge.search.request',
      'cwd': '.',
      'query': 'x',
      'limit': limit,
      'kinds': kinds,
      'requestId': 'r',
    };
    expect(
      () => ForgeSearchRequest.fromJson(request(0, null)),
      throwsFormatException,
    );
    expect(
      () => ForgeSearchRequest.fromJson(request(1, ['unknown'])),
      throwsFormatException,
    );
    expect(
      () => ForgeSearchResponse.fromJson({
        'type': 'forge.search.response',
        'payload': {
          'items': [1],
          'error': null,
          'requestId': 'r',
        },
      }),
      throwsFormatException,
    );
  });
}
