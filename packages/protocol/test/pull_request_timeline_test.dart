import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('request round-trips the frozen pull request identity', () {
    const request = PullRequestTimelineRequest(
      cwd: r'C:\repo',
      prNumber: 42,
      repoOwner: 'tinyrack',
      repoName: 'coding-agent',
      requestId: 'timeline-1',
    );
    expect(
      PullRequestTimelineRequest.fromJson(request.toJson()).toJson(),
      request.toJson(),
    );
  });

  test('response defaults match the Paseo compatibility schema', () {
    final response = PullRequestTimelineResponse.fromJson({
      'type': PullRequestTimelineResponse.type,
    });
    expect(response.cwd, '');
    expect(response.prNumber, isNull);
    expect(response.items, isEmpty);
    expect(response.truncated, isFalse);
    expect(response.error, isNull);
    expect(response.requestId, '');
    expect(response.githubFeaturesEnabled, isTrue);
    expect(response.authState, isNull);
  });

  test('review and threaded comment preserve every neutral field', () {
    const response = PullRequestTimelineResponse(
      cwd: '/repo',
      prNumber: 7,
      items: [
        PullRequestTimelineReview(
          id: 'R1',
          author: 'octo',
          authorUrl: 'https://example.test/octo',
          avatarUrl: null,
          body: 'Approved',
          createdAt: 1720000000000,
          url: 'https://example.test/reviews/1',
          reviewState: PullRequestTimelineReviewState.approved,
        ),
        PullRequestTimelineComment(
          id: 'C1',
          author: 'cat',
          authorUrl: null,
          avatarUrl: 'https://example.test/cat.png',
          body: 'Please adjust this',
          createdAt: 1720000001000,
          url: 'https://example.test/comments/1',
          reviewId: 'R1',
          threadId: 'discussion-1',
          threadIsResolved: false,
          location: PullRequestTimelineCommentLocation(
            path: 'lib/main.dart',
            line: 12,
            startLine: 10,
            threadId: 'thread-1',
            isResolved: false,
            isOutdated: true,
          ),
        ),
      ],
      truncated: true,
      error: null,
      requestId: 'timeline-2',
      githubFeaturesEnabled: true,
      authState: 'authenticated',
    );
    final decoded = PullRequestTimelineResponse.fromJson(response.toJson());
    expect(decoded.toJson(), response.toJson());
  });

  test('unknown item and error kinds normalize to compatible fallbacks', () {
    final response = PullRequestTimelineResponse.fromJson({
      'type': PullRequestTimelineResponse.type,
      'payload': {
        'items': [
          {'kind': 'future_kind'},
          {'kind': 'review'},
        ],
        'error': {'kind': 'future_error'},
      },
    });
    expect(response.items.first, isA<PullRequestTimelineComment>());
    expect(
      (response.items[1] as PullRequestTimelineReview).reviewState,
      PullRequestTimelineReviewState.commented,
    );
    expect(response.error!.kind, PullRequestTimelineErrorKind.unknown);
    expect(response.error!.message, '');
  });

  test('malformed request and nested fields are rejected at the boundary', () {
    expect(
      () => PullRequestTimelineRequest.fromJson({
        'type': PullRequestTimelineRequest.type,
        'cwd': '/repo',
        'prNumber': '7',
        'repoOwner': 'owner',
        'repoName': 'repo',
        'requestId': 'id',
      }),
      throwsFormatException,
    );
    expect(
      () => PullRequestTimelineResponse.fromJson({
        'type': PullRequestTimelineResponse.type,
        'payload': {
          'items': [
            {
              'kind': 'comment',
              'location': {'path': 3},
            },
          ],
        },
      }),
      throwsFormatException,
    );
  });
}
