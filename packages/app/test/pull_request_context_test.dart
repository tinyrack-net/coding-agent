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

const _gitLabStatus = CheckoutPrStatus(
  forge: 'gitlab',
  projectPath: 'acme/app',
  number: 14,
  url: 'https://gitlab.com/acme/app/-/merge_requests/14',
  title: 'Wire up pipelines',
  state: 'OPEN',
  baseRefName: 'main',
  headRefName: 'feature',
  isMerged: false,
  isDraft: false,
  mergeable: 'MERGEABLE',
  checksStatus: 'failure',
  reviewDecision: null,
  repoOwner: 'acme',
  repoName: 'app',
  checks: [],
);

PullRequestTimelineComment _comment(
  String id, {
  String? body,
  String author = '',
  String? url,
  String? reviewId,
  String? threadId,
  bool? resolved,
  bool outdated = false,
}) => PullRequestTimelineComment(
  id: id,
  author: author.isEmpty ? id : author,
  authorUrl: null,
  avatarUrl: null,
  body: body ?? 'body $id',
  createdAt: 1760000000,
  url: url ?? 'https://example.test/$id',
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
  test('comment and review attachments preserve frozen forge metadata', () {
    final comment = _comment(
      'comment-1',
      body: 'Looks good.',
      author: 'octocat',
      url: 'https://example.test/pull/42#issuecomment-1',
    );
    const review = PullRequestTimelineReview(
      id: 'review-1',
      author: 'reviewer',
      authorUrl: null,
      avatarUrl: null,
      body: 'Please simplify this.',
      createdAt: 1760000000,
      url: 'https://example.test/pull/42#pullrequestreview-1',
      reviewState: PullRequestTimelineReviewState.commented,
    );

    final commentAttachment = buildPullRequestActivityAttachment(
      status: _status,
      activity: comment,
    )!;
    final reviewAttachment = buildPullRequestActivityAttachment(
      status: _status,
      activity: review,
    )!;

    expect(commentAttachment.kind, 'forge.change_request_comment');
    expect(commentAttachment.id, '42:comment-1');
    expect(commentAttachment.title, 'octocat');
    expect(commentAttachment.subtitle, '#42 Match Paseo');
    expect(commentAttachment.url, comment.url);
    expect(commentAttachment.text, startsWith('GitHub pull request comment'));
    expect(commentAttachment.text, contains('Author: octocat'));
    expect(commentAttachment.text, endsWith('\n\nLooks good.'));
    expect(reviewAttachment.kind, 'forge.change_request_review');
    expect(reviewAttachment.id, '42:review-1');
    expect(reviewAttachment.title, 'reviewer');
    expect(reviewAttachment.subtitle, '#42 Match Paseo');
    expect(reviewAttachment.url, review.url);
    expect(reviewAttachment.text, startsWith('GitHub pull request review'));
    expect(reviewAttachment.text, contains('State: commented'));
    expect(reviewAttachment.text, endsWith('\n\nPlease simplify this.'));
  });

  test('GitLab attachments use merge-request nouns and number prefix', () {
    final comment = buildPullRequestActivityAttachment(
      status: _gitLabStatus,
      activity: _comment(
        'comment-1',
        body: 'Looks good.',
        author: 'octocat',
        url: 'https://gitlab.com/acme/app/-/merge_requests/14#note_401',
      ),
    )!;
    const check = CheckoutPrCheck(
      name: 'pipeline',
      status: 'failure',
      url: 'https://gitlab.com/acme/app/-/pipelines/99',
    );
    final checkAttachment = buildPullRequestCheckAttachment(
      status: _gitLabStatus,
      check: check,
    );

    expect(comment.subtitle, '!14 Wire up pipelines');
    expect(comment.text, startsWith('GitLab merge request comment'));
    expect(comment.text, contains('Merge request: !14 Wire up pipelines'));
    expect(checkAttachment.kind, 'forge.change_request_check');
    expect(checkAttachment.id, '14:check:pipeline');
    expect(checkAttachment.subtitle, '!14 Wire up pipelines');
    expect(checkAttachment.url, check.url);
    expect(checkAttachment.text, startsWith('GitLab merge request check'));
    expect(
      checkAttachment.text,
      contains('Merge request URL: ${_gitLabStatus.url}'),
    );
  });

  test('bodyless activity eligibility matches frozen review semantics', () {
    const approval = PullRequestTimelineReview(
      id: 'approval',
      author: 'reviewer',
      authorUrl: null,
      avatarUrl: null,
      body: ' ',
      createdAt: 1760000000,
      url: 'https://example.test/approval',
      reviewState: PullRequestTimelineReviewState.approved,
    );
    const changesRequested = PullRequestTimelineReview(
      id: 'changes',
      author: 'reviewer',
      authorUrl: null,
      avatarUrl: null,
      body: '',
      createdAt: 1760000000,
      url: 'https://example.test/changes',
      reviewState: PullRequestTimelineReviewState.changesRequested,
    );

    expect(canAddPullRequestActivityToChat(approval), isFalse);
    expect(
      buildPullRequestActivityAttachment(status: _status, activity: approval),
      isNull,
    );
    expect(canAddPullRequestActivityToChat(changesRequested), isTrue);
    final attachment = buildPullRequestActivityAttachment(
      status: _status,
      activity: changesRequested,
    )!;
    expect(attachment.text, contains('State: changes_requested'));
    expect(attachment.text, isNot(endsWith('\n\n')));
  });

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

  test('thread attachment keeps the original root URL after filtering', () {
    final emptyRoot = _comment(
      'empty-root',
      body: ' ',
      url: 'https://example.test/original-root',
      threadId: 'PRRT_root',
    );
    final reply = _comment(
      'reply',
      body: 'Actionable reply.',
      url: 'https://example.test/reply',
      threadId: 'PRRT_root',
    );
    final thread = PullRequestThreadEntry(
      id: 'thread:PRRT_root',
      comments: [emptyRoot, reply],
    );

    final attachment = buildPullRequestThreadAttachment(
      status: _status,
      thread: thread,
    )!;

    expect(attachment.url, emptyRoot.url);
    expect(attachment.text, contains('URL: ${emptyRoot.url}'));
    expect(attachment.text, isNot(contains('URL: ${reply.url}')));
    expect(attachment.text, contains('reply ('));
    expect(attachment.text, isNot(contains('empty-root (')));
  });

  test('thread attachment only emits location resolution state', () {
    final thread = PullRequestThreadEntry(
      id: 'thread:general',
      comments: [_comment('root', body: 'Discuss this.')],
      isResolved: true,
    );

    final attachment = buildPullRequestThreadAttachment(
      status: _status,
      thread: thread,
    )!;

    expect(attachment.text, isNot(contains('Thread state:')));
  });

  test('thread attachment is null when every comment body is blank', () {
    final thread = PullRequestThreadEntry(
      id: 'thread:blank',
      comments: [
        _comment('root', body: ' '),
        _comment('reply', body: '\n'),
      ],
    );

    expect(
      buildPullRequestThreadAttachment(status: _status, thread: thread),
      isNull,
    );
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
    expect(
      canAddPullRequestCheckLogsToChat(
        const CheckoutPrCheck(name: 'Build', status: 'pending', url: null),
      ),
      isFalse,
    );
    expect(
      canAddPullRequestCheckLogsToChat(
        const CheckoutPrCheck(name: 'Build', status: 'skipped', url: null),
      ),
      isFalse,
    );
    expect(attachment.id, '42:check:Lint');
    expect(attachment.url, isNull);
    expect(attachment.text, contains('Check URL: null'));
    expect(attachment.text, isNot(contains('Conclusion:')));
  });

  test('same-named checks remain distinct by check-run id', () {
    const ubuntu = CheckoutPrCheck(
      name: 'tests',
      status: 'failure',
      url: 'https://example.test/ubuntu',
      checkRunId: 12345,
      workflowRunId: 456,
    );
    const windows = CheckoutPrCheck(
      name: 'tests',
      status: 'failure',
      url: 'https://example.test/windows',
      checkRunId: 67890,
      workflowRunId: 456,
    );

    expect(
      buildPullRequestCheckAttachment(status: _status, check: ubuntu).id,
      '42:check-run:12345',
    );
    expect(
      buildPullRequestCheckAttachment(status: _status, check: windows).id,
      '42:check-run:67890',
    );
  });
}
