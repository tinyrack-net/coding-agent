import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/pull_request_context.dart';
import 'package:flutter_test/flutter_test.dart';

const _status = CheckoutPrStatus(
  forge: 'github',
  projectPath: 'tinyrack/coding-agent',
  number: 42,
  url: 'https://example.test/pull/42',
  title: 'Match Paseo',
  state: 'OPEN',
  baseRefName: 'main',
  headRefName: 'feature',
  isMerged: false,
  isDraft: false,
  mergeable: 'MERGEABLE',
  checksStatus: 'success',
  reviewDecision: 'APPROVED',
  repoOwner: 'tinyrack',
  repoName: 'coding-agent',
  checks: [],
);

PullRequestTimelineComment _comment(
  String id, {
  String? reviewId,
  String? threadId,
  bool? resolved,
  bool outdated = false,
}) => PullRequestTimelineComment(
  id: id,
  author: id,
  authorUrl: null,
  avatarUrl: null,
  body: 'body $id',
  createdAt: 1760000000,
  url: 'https://example.test/$id',
  reviewId: reviewId,
  threadId: threadId,
  threadIsResolved: resolved,
  location: threadId == null
      ? null
      : PullRequestTimelineCommentLocation(
          path: 'lib/a.dart',
          startLine: 4,
          line: 8,
          threadId: threadId,
          isResolved: resolved,
          isOutdated: outdated,
        ),
);

void main() {
  test('groups reply chains and nests them under their review', () {
    const review = PullRequestTimelineReview(
      id: 'review-1',
      author: 'reviewer',
      authorUrl: null,
      avatarUrl: null,
      body: 'Review body',
      createdAt: 1760000000,
      url: 'https://example.test/review',
      reviewState: PullRequestTimelineReviewState.changesRequested,
    );
    final root = _comment(
      'root',
      reviewId: 'review-1',
      threadId: 'thread-1',
      resolved: false,
    );
    final reply = _comment('reply', threadId: 'thread-1', resolved: false);
    final standalone = _comment('standalone');

    final entries = buildPullRequestTimeline([review, root, reply, standalone]);

    expect(entries, hasLength(2));
    final reviewEntry = entries.first as PullRequestReviewEntry;
    expect(reviewEntry.threads.single.comments, [root, reply]);
    expect((entries.last as PullRequestSingleEntry).activity, same(standalone));
  });

  test('resolved and outdated threads collapse by default', () {
    final resolved =
        buildPullRequestTimeline([
              _comment('resolved', threadId: 'T1', resolved: true),
            ]).single
            as PullRequestThreadEntry;
    final outdated =
        buildPullRequestTimeline([
              _comment('outdated', threadId: 'T2', outdated: true),
            ]).single
            as PullRequestThreadEntry;
    expect(resolved.collapsedByDefault, isTrue);
    expect(outdated.collapsedByDefault, isTrue);
  });

  test('activity and whole-thread attachments match Paseo text context', () {
    final root = _comment(
      'root',
      threadId: 'PRRT_1',
      resolved: false,
      outdated: true,
    );
    final reply = _comment('reply', threadId: 'PRRT_1', resolved: false);
    final thread =
        buildPullRequestTimeline([root, reply]).single
            as PullRequestThreadEntry;

    final single = buildPullRequestActivityAttachment(
      status: _status,
      activity: root,
    )!;
    expect(single.kind, 'forge.change_request_comment');
    expect(single.text, contains('GitHub pull request comment'));
    expect(
      single.text,
      contains(
        'Location: lib/a.dart:4-8 · unresolved · outdated · thread PRRT_1',
      ),
    );

    final combined = buildPullRequestThreadAttachment(
      status: _status,
      thread: thread,
    )!;
    expect(combined.title, 'lib/a.dart:4-8');
    expect(combined.text, contains('review thread'));
    expect(combined.text, contains('root'));
    expect(combined.text, contains('reply'));
    expect(combined.text, contains('this thread is outdated'));
  });

  test('formats path-only locations and year-scale activity ages', () {
    const location = PullRequestTimelineCommentLocation(path: 'README.md');
    expect(formatPullRequestThreadPath(location), 'README.md');
    expect(formatPullRequestAge(0), matches(RegExp(r'^\d+y ago$')));
  });

  test('formats failed check details using Paseo context order', () {
    const check = CheckoutPrCheck(
      name: 'Flutter tests',
      status: 'failure',
      url: 'https://example.test/check/99',
      checkRunId: 99,
      workflowRunId: 12,
    );
    const details = CheckoutCheckDetails(
      checkRunId: 99,
      workflowRunId: 12,
      name: 'Flutter tests',
      status: 'completed',
      conclusion: 'failure',
      url: 'https://api.example.test/check/99',
      detailsUrl: 'https://example.test/check/99/details',
      output: {
        'title': 'Widget tests failed',
        'summary': 'One suite failed',
        'text': 'Review the assertion output.',
      },
      annotations: [
        CheckoutCheckAnnotation(
          path: 'test/pane_test.dart',
          startLine: 40,
          endLine: 42,
          annotationLevel: 'failure',
          message: 'Expected success',
        ),
        CheckoutCheckAnnotation(message: 'Runner stopped'),
      ],
      failedJobs: [
        CheckoutCheckFailedJob(
          jobId: 7,
          name: 'windows',
          status: 'completed',
          conclusion: 'failure',
          url: 'https://example.test/job/7',
          logTail: 'line one\nline two',
          logTruncated: true,
        ),
      ],
      truncated: true,
    );

    final attachment = buildPullRequestCheckAttachment(
      status: _status,
      check: check,
      details: details,
    );

    expect(attachment.kind, 'forge.change_request_check');
    expect(attachment.id, '42:check-run:99');
    expect(attachment.title, 'Flutter tests');
    expect(attachment.url, details.detailsUrl);
    expect(
      attachment.text,
      equals(
        'GitHub pull request check\n'
        'Pull request: #42 Match Paseo\n'
        'Pull request URL: https://example.test/pull/42\n'
        'Check: Flutter tests\n'
        'Status: failure\n'
        'Conclusion: failure\n'
        'Check URL: https://example.test/check/99\n'
        'Details URL: https://example.test/check/99/details\n'
        'Output title: Widget tests failed\n'
        'Output summary: One suite failed\n'
        'Output text:\n'
        'Review the assertion output.\n'
        '\n'
        'Annotations:\n'
        '- test/pane_test.dart:40-42 failure: Expected success\n'
        '- unknown location: Runner stopped\n'
        '\n'
        'Failed jobs:\n'
        '- windows: failure\n'
        '  https://example.test/job/7\n'
        '  ```\n'
        '  line one\n'
        '  line two\n'
        '  ```\n'
        '  Log tail truncated to the latest capped lines.\n'
        '\n'
        'Note: Check details were truncated by GitHub/API or local caps.',
      ),
    );
  });

  test('failed check metadata remains attachable when details are missing', () {
    const check = CheckoutPrCheck(name: 'Lint', status: 'failure', url: null);
    final attachment = buildPullRequestCheckAttachment(
      status: _status,
      check: check,
    );

    expect(canAddPullRequestCheckLogsToChat(check), isTrue);
    expect(
      canAddPullRequestCheckLogsToChat(
        const CheckoutPrCheck(name: 'Build', status: 'success', url: null),
      ),
      isFalse,
    );
    expect(attachment.id, '42:check:Lint');
    expect(attachment.url, isNull);
    expect(attachment.text, contains('Check URL: null'));
    expect(attachment.text, isNot(contains('Conclusion:')));
  });
}
