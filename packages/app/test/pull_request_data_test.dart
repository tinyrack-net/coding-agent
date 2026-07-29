import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/pull_request_data.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/pull_request_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

CheckoutPrStatus _status({
  num? number = 42,
  String url = 'https://github.com/acme/app/pull/42',
  String state = 'open',
  bool isMerged = false,
  bool isDraft = false,
}) => CheckoutPrStatus(
  forge: 'github',
  projectPath: 'acme/app',
  number: number,
  url: url,
  title: 'Fix the panel',
  state: state,
  baseRefName: 'main',
  headRefName: 'feature',
  isMerged: isMerged,
  isDraft: isDraft,
  mergeable: 'MERGEABLE',
  checks: const [
    CheckoutPrCheck(
      name: 'tests',
      status: 'success',
      url: 'https://example.test/check',
      checkRunId: 1,
    ),
  ],
  checksStatus: 'success',
  reviewDecision: 'approved',
  repoOwner: 'acme',
  repoName: 'app',
  github: const {'mergeStateStatus': 'CLEAN'},
  forgeSpecific: const {'forge': 'github'},
);

PullRequestTimelineComment _comment(String id, String body) =>
    PullRequestTimelineComment(
      id: id,
      author: 'octocat',
      authorUrl: null,
      avatarUrl: null,
      body: body,
      createdAt: 1000,
      url: 'https://example.test/$id',
    );

PullRequestTimelineReview _review(
  String id,
  String body,
  PullRequestTimelineReviewState state,
) => PullRequestTimelineReview(
  id: id,
  author: 'reviewer',
  authorUrl: null,
  avatarUrl: null,
  body: body,
  createdAt: 2000,
  url: 'https://example.test/$id',
  reviewState: state,
);

void main() {
  test('recovers only frozen GitHub pull URL numbers and preserves status', () {
    final raw = _status(number: null);
    final normalized = normalizePullRequestStatus(raw)!;

    expect(normalized.number, 42);
    expect(normalized.forge, raw.forge);
    expect(normalized.projectPath, raw.projectPath);
    expect(normalized.checks, same(raw.checks));
    expect(normalized.github, same(raw.github));
    expect(normalized.forgeSpecific, same(raw.forgeSpecific));
    expect(
      resolvePullRequestNumber(
        _status(
          number: null,
          url: 'https://gitlab.com/acme/app/-/merge_requests/42',
        ),
      ),
      isNull,
    );
    expect(
      resolvePullRequestNumber(_status(number: null, url: '/acme/app/pull/42')),
      isNull,
    );
    expect(
      resolvePullRequestNumber(_status(number: null, url: 'not a URL')),
      isNull,
    );
  });

  test('derives frozen state precedence and labels', () {
    expect(
      derivePullRequestState(
        _status(state: 'closed', isMerged: true, isDraft: true),
      ),
      PullRequestChangeState.merged,
    );
    expect(
      derivePullRequestState(_status(state: 'merged')),
      PullRequestChangeState.merged,
    );
    expect(
      derivePullRequestState(_status(state: 'closed', isDraft: true)),
      PullRequestChangeState.closed,
    );
    expect(
      derivePullRequestState(_status(state: 'OPEN', isDraft: true)),
      PullRequestChangeState.draft,
    );
    expect(
      derivePullRequestState(_status(state: 'OPEN')),
      PullRequestChangeState.open,
    );
    expect(PullRequestChangeState.values.map(pullRequestStateLabel), [
      'Open',
      'Draft',
      'Merged',
      'Closed',
    ]);
  });

  test('rejects stale timelines and filters invisible activity in order', () {
    final items = <PullRequestTimelineItem>[
      _comment('empty-comment', ' '),
      _review(
        'empty-commented-review',
        '',
        PullRequestTimelineReviewState.commented,
      ),
      _review(
        'blocking-review',
        '',
        PullRequestTimelineReviewState.changesRequested,
      ),
      _comment('comment', 'body'),
    ];

    expect(
      normalizePullRequestTimeline(
        statusNumber: 42,
        timelineNumber: 41,
        items: items,
      ),
      isEmpty,
    );
    expect(
      normalizePullRequestTimeline(
        statusNumber: 42,
        timelineNumber: 42,
        items: items,
      ).map((item) => item.id),
      ['blocking-review', 'comment'],
    );
  });

  test('normalizes review decisions, verbs, avatar colors, and ages', () {
    expect(normalizePullRequestReviewDecision('approved'), 'approved');
    expect(
      normalizePullRequestReviewDecision('CHANGES_REQUESTED'),
      'changes_requested',
    );
    expect(normalizePullRequestReviewDecision('review_required'), 'pending');
    expect(normalizePullRequestReviewDecision(null), 'pending');
    expect(pullRequestActivityVerb(_comment('comment', 'body')), 'Commented');
    expect(
      pullRequestActivityVerb(
        _review('approved', '', PullRequestTimelineReviewState.approved),
      ),
      'Approved',
    );
    expect(
      pullRequestActivityVerb(
        _review('changes', '', PullRequestTimelineReviewState.changesRequested),
      ),
      'Requested changes',
    );
    expect(
      pullRequestActivityVerb(
        _review('reviewed', 'body', PullRequestTimelineReviewState.commented),
      ),
      'Reviewed',
    );
    expect(derivePullRequestAvatarColor('octocat'), '#6366f1');

    final now = DateTime.utc(2026, 1, 1);
    expect(
      formatPullRequestAge(
        now.subtract(const Duration(seconds: 59)).millisecondsSinceEpoch,
        now: now,
      ),
      'just now',
    );
    expect(
      formatPullRequestAge(
        now.subtract(const Duration(minutes: 8)).millisecondsSinceEpoch,
        now: now,
      ),
      '8m ago',
    );
    expect(
      formatPullRequestAge(
        now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch,
        now: now,
      ),
      '3h ago',
    );
    expect(
      formatPullRequestAge(
        now.subtract(const Duration(days: 20)).millisecondsSinceEpoch,
        now: now,
      ),
      '20d ago',
    );
    expect(
      formatPullRequestAge(
        now.subtract(const Duration(days: 90)).millisecondsSinceEpoch,
        now: now,
      ),
      '3mo ago',
    );
    expect(
      formatPullRequestAge(
        now.subtract(const Duration(days: 730)).millisecondsSinceEpoch,
        now: now,
      ),
      '2y ago',
    );
  });

  test(
    'provider uses recovered number and suppresses stale timeline payload',
    () async {
      final client = _PullRequestDataClient(
        status: _status(number: null),
        timelineNumber: 41,
        timeline: [_comment('stale', 'stale body')],
        timelineTruncated: true,
        timelineError: const PullRequestTimelineError(
          kind: PullRequestTimelineErrorKind.unknown,
          message: 'stale error',
        ),
      );
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);

      final data = await container.read(
        pullRequestPaneProvider('/repo').future,
      );

      expect(data.status?.number, 42);
      expect(data.timeline, isEmpty);
      expect(data.timelineTruncated, isFalse);
      expect(data.timelineError, isNull);
      expect(client.timelineRequest?.prNumber, 42);
    },
  );

  test(
    'provider filters invisible activity before pane summary consumption',
    () async {
      final client = _PullRequestDataClient(
        status: _status(),
        timelineNumber: 42,
        timeline: [
          _comment('empty', ''),
          _review('commented', '', PullRequestTimelineReviewState.commented),
          _review(
            'blocking',
            '',
            PullRequestTimelineReviewState.changesRequested,
          ),
          _comment('visible', 'body'),
        ],
      );
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);

      final data = await container.read(
        pullRequestPaneProvider('/repo').future,
      );

      expect(data.timeline.map((item) => item.id), ['blocking', 'visible']);
    },
  );

  test('provider rejects status without number or parseable URL', () async {
    final client = _PullRequestDataClient(
      status: _status(number: null, url: 'https://example.test/change/42'),
      timelineNumber: 42,
    );
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);

    final data = await container.read(pullRequestPaneProvider('/repo').future);

    expect(data.status, isNull);
    expect(client.timelineRequest, isNull);
  });
}

final class _PullRequestDataClient extends DaemonClient {
  _PullRequestDataClient({
    required this.status,
    required this.timelineNumber,
    this.timeline = const [],
    this.timelineTruncated = false,
    this.timelineError,
  }) : super(uri: Uri.parse('ws://fake'));

  final CheckoutPrStatus status;
  final num? timelineNumber;
  final List<PullRequestTimelineItem> timeline;
  final bool timelineTruncated;
  final PullRequestTimelineError? timelineError;
  PullRequestTimelineRequest? timelineRequest;

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (message['type'] == CheckoutPrStatusRequest.type) {
      return CheckoutPrStatusResponse(
        cwd: '/repo',
        status: status,
        githubFeaturesEnabled: true,
        authState: null,
        forge: status.forge,
        error: null,
        requestId: message['requestId']! as String,
      ).toJson();
    }
    if (message['type'] == PullRequestTimelineRequest.type) {
      timelineRequest = PullRequestTimelineRequest.fromJson(message);
      return PullRequestTimelineResponse(
        cwd: '/repo',
        prNumber: timelineNumber,
        items: timeline,
        truncated: timelineTruncated,
        error: timelineError,
        requestId: message['requestId']! as String,
        githubFeaturesEnabled: true,
        authState: null,
      ).toJson();
    }
    throw StateError('Unexpected request: ${message['type']}');
  }
}
