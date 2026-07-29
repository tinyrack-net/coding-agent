import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/pull_request_context.dart';
import 'package:flutter_test/flutter_test.dart';

PullRequestTimelineComment _comment(
  String id, {
  String author = 'alice',
  String? threadId,
  bool? threadIsResolved,
  String? reviewId,
  PullRequestTimelineCommentLocation? location,
}) => PullRequestTimelineComment(
  id: id,
  author: author,
  authorUrl: null,
  avatarUrl: null,
  body: 'body',
  createdAt: 1760000000,
  url: 'https://example.test/$id',
  reviewId: reviewId,
  threadId: threadId,
  threadIsResolved: threadIsResolved,
  location: location,
);

PullRequestTimelineReview _review(
  String id, {
  PullRequestTimelineReviewState state =
      PullRequestTimelineReviewState.approved,
}) => PullRequestTimelineReview(
  id: id,
  author: 'alice',
  authorUrl: null,
  avatarUrl: null,
  body: 'Review body.',
  createdAt: 1760000000,
  url: 'https://example.test/$id',
  reviewState: state,
);

void main() {
  test('keeps standalone comments and reviews in source order', () {
    final comment = _comment('c1');
    final review = _review('r1');

    final entries = buildPullRequestTimeline([comment, review]);

    expect(entries, hasLength(2));
    expect((entries[0] as PullRequestSingleEntry).activity, same(comment));
    expect((entries[1] as PullRequestSingleEntry).activity, same(review));
  });

  test('groups a thread at its first comment position', () {
    final before = _comment('c1');
    final root = _comment(
      'root',
      location: const PullRequestTimelineCommentLocation(
        path: 'src/a.dart',
        line: 12,
        threadId: 'T1',
        isResolved: false,
      ),
    );
    final between = _comment('c2');
    final reply = _comment(
      'reply',
      author: 'bob',
      location: const PullRequestTimelineCommentLocation(
        path: 'src/a.dart',
        line: 12,
        threadId: 'T1',
        isResolved: false,
      ),
    );

    final entries = buildPullRequestTimeline([before, root, between, reply]);

    expect(entries.map((entry) => entry.id), ['c1', 'thread:T1', 'c2']);
    final thread = entries[1] as PullRequestThreadEntry;
    expect(thread.comments, [root, reply]);
    expect(thread.location, same(root.location));
    expect(thread.isResolved, isFalse);
  });

  test('groups general discussions without a file location', () {
    final root = _comment('root', threadId: 'disc-1');
    final between = _comment('c1');
    final reply = _comment('reply', author: 'bob', threadId: 'disc-1');

    final entries = buildPullRequestTimeline([root, between, reply]);

    expect(entries.map((entry) => entry.id), ['thread:disc-1', 'c1']);
    final thread = entries.first as PullRequestThreadEntry;
    expect(thread.location, isNull);
    expect(thread.isResolved, isNull);
    expect(thread.comments, [root, reply]);
  });

  test('surfaces general-discussion resolution without a location', () {
    final root = _comment('root', threadId: 'disc-2', threadIsResolved: true);
    final reply = _comment('reply', threadId: 'disc-2', threadIsResolved: true);

    final thread =
        buildPullRequestTimeline([root, reply]).single
            as PullRequestThreadEntry;

    expect(thread.location, isNull);
    expect(thread.isResolved, isTrue);
    expect(thread.collapsedByDefault, isTrue);
  });

  test('keeps located comments without a thread id as singles', () {
    final comment = _comment(
      'c1',
      location: const PullRequestTimelineCommentLocation(
        path: 'src/a.dart',
        line: 3,
      ),
    );

    final entry = buildPullRequestTimeline([comment]).single;

    expect(entry, isA<PullRequestSingleEntry>());
    expect((entry as PullRequestSingleEntry).activity, same(comment));
  });

  test('keeps distinct thread identities separate', () {
    final a = _comment(
      'a',
      location: const PullRequestTimelineCommentLocation(
        path: 'x.dart',
        threadId: 'T1',
      ),
    );
    final b = _comment(
      'b',
      location: const PullRequestTimelineCommentLocation(
        path: 'y.dart',
        threadId: 'T2',
      ),
    );
    final a2 = _comment(
      'a2',
      location: const PullRequestTimelineCommentLocation(
        path: 'x.dart',
        threadId: 'T1',
      ),
    );

    final entries = buildPullRequestTimeline([a, b, a2]);

    expect(entries.map((entry) => entry.id), ['thread:T1', 'thread:T2']);
    expect((entries[0] as PullRequestThreadEntry).comments, [a, a2]);
    expect((entries[1] as PullRequestThreadEntry).comments, [b]);
  });

  test('nests only threads signaled by their root review id', () {
    final review = _review(
      'R1',
      state: PullRequestTimelineReviewState.changesRequested,
    );
    final root = _comment(
      't1',
      reviewId: 'R1',
      location: const PullRequestTimelineCommentLocation(
        path: 'src/a.dart',
        line: 4,
        threadId: 'T1',
      ),
    );
    final reply = _comment(
      't1-reply',
      reviewId: 'R2-later',
      location: const PullRequestTimelineCommentLocation(
        path: 'src/a.dart',
        line: 4,
        threadId: 'T1',
      ),
    );
    final unrelated = _comment(
      't2',
      reviewId: 'unknown',
      location: const PullRequestTimelineCommentLocation(
        path: 'src/b.dart',
        threadId: 'T2',
      ),
    );

    final entries = buildPullRequestTimeline([review, root, reply, unrelated]);

    expect(entries.map((entry) => entry.id), ['R1', 'thread:T2']);
    final reviewEntry = entries.first as PullRequestReviewEntry;
    expect(reviewEntry.review, same(review));
    expect(reviewEntry.threads.single.comments, [root, reply]);
    expect((entries.last as PullRequestThreadEntry).comments, [unrelated]);
  });

  test('keeps reviews without nested threads as singles', () {
    final review = _review('R1');

    final entry = buildPullRequestTimeline([review]).single;

    expect(entry, isA<PullRequestSingleEntry>());
    expect((entry as PullRequestSingleEntry).activity, same(review));
  });

  test('formats range, state, and concise thread identity', () {
    const location = PullRequestTimelineCommentLocation(
      path: 'packages/app/src/panel.dart',
      startLine: 10,
      line: 12,
      threadId: 'PRRT_1',
      isResolved: false,
      isOutdated: true,
    );

    expect(
      formatPullRequestActivityLocation(location),
      'packages/app/src/panel.dart:10-12 · unresolved · outdated · '
      'thread PRRT_1',
    );
  });

  test('omits noisy thread identity while retaining current state', () {
    const location = PullRequestTimelineCommentLocation(
      path: 'packages/app/src/panel.dart',
      line: 12,
      threadId: 'PRRT_kwDOAReallyLongOpaqueThreadIdentifier',
      isResolved: true,
      isOutdated: false,
    );

    expect(
      formatPullRequestActivityLocation(location),
      'packages/app/src/panel.dart:12 · resolved · current',
    );
  });
}
