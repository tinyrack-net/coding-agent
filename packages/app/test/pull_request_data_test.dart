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
  String title = 'Fix the panel',
  String? repoOwner = 'acme',
  String? repoName = 'app',
}) => CheckoutPrStatus(
  forge: 'github',
  projectPath: 'acme/app',
  number: number,
  url: url,
  title: title,
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
  repoOwner: repoOwner,
  repoName: repoName,
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
  test('extracts identity and applies every frozen timeline gate', () {
    final identity = extractPullRequestRepoIdentity(_status());
    expect(identity.prNumber, 42);
    expect(identity.repoOwner, 'acme');
    expect(identity.repoName, 'app');
    expect(
      extractPullRequestRepoIdentity(
        _status(repoOwner: '', repoName: ''),
      ).repoOwner,
      isNull,
    );
    final base = (
      hasClient: true,
      isConnected: true,
      timelineEnabled: true,
      githubFeaturesEnabled: true,
      cwd: '/repo',
      identity: identity,
      timelineUnsupported: false,
    );
    bool shouldFetch({
      bool? hasClient,
      bool? isConnected,
      bool? timelineEnabled,
      bool? githubFeaturesEnabled,
      String? cwd,
      PullRequestRepoIdentity? identity,
      bool? timelineUnsupported,
    }) => shouldFetchPullRequestTimeline(
      hasClient: hasClient ?? base.hasClient,
      isConnected: isConnected ?? base.isConnected,
      timelineEnabled: timelineEnabled ?? base.timelineEnabled,
      githubFeaturesEnabled:
          githubFeaturesEnabled ?? base.githubFeaturesEnabled,
      cwd: cwd ?? base.cwd,
      identity: identity ?? base.identity,
      timelineUnsupported: timelineUnsupported ?? base.timelineUnsupported,
    );

    expect(shouldFetch(), isTrue);
    expect(shouldFetch(hasClient: false), isFalse);
    expect(shouldFetch(isConnected: false), isFalse);
    expect(shouldFetch(timelineEnabled: false), isFalse);
    expect(shouldFetch(githubFeaturesEnabled: false), isFalse);
    expect(shouldFetch(cwd: ''), isFalse);
    expect(
      shouldFetch(identity: extractPullRequestRepoIdentity(null)),
      isFalse,
    );
    expect(
      shouldFetch(
        identity: extractPullRequestRepoIdentity(_status(repoOwner: '')),
      ),
      isFalse,
    );
    expect(
      shouldFetch(
        identity: extractPullRequestRepoIdentity(_status(repoName: '')),
      ),
      isFalse,
    );
    expect(shouldFetch(timelineUnsupported: true), isFalse);

    final registry = PullRequestTimelineUnsupportedRegistry();
    final key = pullRequestTimelineUnsupportedKey(
      serverId: 'host',
      cwd: '/repo',
      prNumber: 42,
    );
    expect(registry.has(key), isFalse);
    registry.add(key);
    expect(registry.has(key), isTrue);
    expect(
      key,
      isNot(
        pullRequestTimelineUnsupportedKey(
          serverId: 'other',
          cwd: '/repo',
          prNumber: 42,
        ),
      ),
    );
  });

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
      container
          .read(pullRequestPaneProvider('/repo').notifier)
          .setTimelineEnabled(true);

      final initial = await container.read(
        pullRequestPaneProvider('/repo').future,
      );
      expect(initial.activityLoading, isTrue);
      final data = await _waitForTimeline(container, '/repo');

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
      container
          .read(pullRequestPaneProvider('/repo').notifier)
          .setTimelineEnabled(true);

      final initial = await container.read(
        pullRequestPaneProvider('/repo').future,
      );
      expect(initial.activityLoading, isTrue);
      final data = await _waitForTimeline(container, '/repo');

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
    container
        .read(pullRequestPaneProvider('/repo').notifier)
        .setTimelineEnabled(true);

    final data = await container.read(pullRequestPaneProvider('/repo').future);

    expect(data.status, isNull);
    expect(client.timelineRequest, isNull);
  });

  test('provider reveals status while the first timeline is pending', () async {
    final gate = Completer<void>();
    final client = _PullRequestDataClient(
      status: _status(),
      timelineNumber: 42,
      timeline: [_comment('visible', 'body')],
      timelineGate: gate,
    );
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    container
        .read(pullRequestPaneProvider('/pending').notifier)
        .setTimelineEnabled(true);

    final initial = await container.read(
      pullRequestPaneProvider('/pending').future,
    );

    expect(initial.status?.number, 42);
    expect(initial.timeline, isEmpty);
    expect(initial.activityLoading, isTrue);
    expect(client.timelineRequests, 0);
    await Future<void>.delayed(Duration.zero);
    expect(client.timelineRequests, 1);

    gate.complete();
    final resolved = await _waitForTimeline(container, '/pending');
    expect(resolved.activityLoading, isFalse);
    expect(resolved.timelineResolved, isTrue);
    expect(resolved.timeline.single.id, 'visible');
  });

  test(
    'provider remembers unsupported timeline tuples without surfacing errors',
    () async {
      final client = _PullRequestDataClient(
        status: _status(),
        timelineNumber: 42,
        timelineFailure: DaemonRpcException(
          const RpcError(code: 'unknown_schema', message: 'unsupported'),
        ),
      );
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);
      final provider = pullRequestPaneProvider('/unsupported');
      container.read(provider.notifier).setTimelineEnabled(true);

      final initial = await container.read(provider.future);
      expect(initial.activityLoading, isTrue);
      final failed = await _waitForTimeline(container, '/unsupported');
      expect(failed.activityLoading, isFalse);
      expect(failed.timelineError, isNull);
      expect(client.timelineRequests, 1);
      expect(
        isUnsupportedPullRequestTimelineError(client.timelineFailure!),
        isTrue,
      );
      expect(
        isUnsupportedPullRequestTimelineError(StateError('network')),
        isFalse,
      );

      await container.read(provider.notifier).refresh();
      await Future<void>.delayed(Duration.zero);
      expect(client.timelineRequests, 1);
    },
  );

  test('provider honors feature and empty-identity timeline gates', () async {
    final featureOff = _PullRequestDataClient(
      status: _status(),
      timelineNumber: 42,
      githubFeaturesEnabled: false,
    );
    final emptyIdentity = _PullRequestDataClient(
      status: _status(repoOwner: ''),
      timelineNumber: 42,
    );
    final first = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(featureOff)],
    );
    final second = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(emptyIdentity)],
    );
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    first
        .read(pullRequestPaneProvider('/feature-off').notifier)
        .setTimelineEnabled(true);
    second
        .read(pullRequestPaneProvider('/empty-identity').notifier)
        .setTimelineEnabled(true);

    final featureData = await first.read(
      pullRequestPaneProvider('/feature-off').future,
    );
    final identityData = await second.read(
      pullRequestPaneProvider('/empty-identity').future,
    );

    expect(featureData.githubFeaturesEnabled, isFalse);
    expect(featureData.activityLoading, isFalse);
    expect(identityData.activityLoading, isFalse);
    expect(featureOff.timelineRequests, 0);
    expect(emptyIdentity.timelineRequests, 0);
  });

  test('provider defers timeline until the PR pane enables it', () async {
    final client = _PullRequestDataClient(
      status: _status(),
      timelineNumber: 42,
      timeline: [_comment('visible', 'body')],
    );
    final container = ProviderContainer(
      overrides: [daemonClientProvider.overrideWithValue(client)],
    );
    addTearDown(container.dispose);
    final provider = pullRequestPaneProvider('/lazy');

    final statusOnly = await container.read(provider.future);
    await Future<void>.delayed(Duration.zero);
    expect(statusOnly.status?.number, 42);
    expect(statusOnly.activityLoading, isFalse);
    expect(client.timelineRequests, 0);

    container.read(provider.notifier).setTimelineEnabled(true);
    expect(container.read(provider).value?.activityLoading, isTrue);
    final resolved = await _waitForTimeline(container, '/lazy');
    expect(client.timelineRequests, 1);
    expect(resolved.timeline.single.id, 'visible');

    container.read(provider.notifier).setTimelineEnabled(false);
    container.read(provider.notifier).setTimelineEnabled(true);
    await Future<void>.delayed(Duration.zero);
    expect(client.timelineRequests, 1);
  });

  test(
    'provider applies pushed PR status and invalidates details only on change',
    () async {
      final client = _PullRequestDataClient(
        status: _status(),
        timelineNumber: 42,
        timeline: [_comment('visible', 'body')],
      );
      final container = ProviderContainer(
        overrides: [daemonClientProvider.overrideWithValue(client)],
      );
      addTearDown(container.dispose);
      addTearDown(client.dispose);
      final provider = pullRequestPaneProvider('/repo');
      container.read(provider.notifier).setTimelineEnabled(true);

      await container.read(provider.future);
      final initial = await _waitForTimeline(container, '/repo');
      expect(initial.timeline.single.id, 'visible');
      expect(client.statusRequests, 1);
      expect(client.timelineRequests, 1);

      client.updates.add(_checkoutUpdateWithPr(_status(), requestId: 'same'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(provider).value?.timeline.single.id, 'visible');
      expect(container.read(provider).value?.pipelineCacheRevision, 0);
      expect(client.statusRequests, 1);
      expect(client.timelineRequests, 1);

      client.updates.add(
        _checkoutUpdateWithPr(
          _status(title: 'Updated title'),
          requestId: 'changed',
        ),
      );
      final changed = await _waitForPushedTitle(
        container,
        '/repo',
        'Updated title',
      );
      expect(changed.status?.title, 'Updated title');
      expect(changed.pipelineCacheRevision, 1);
      expect(changed.timeline.single.id, 'visible');
      expect(client.statusRequests, 1);
      expect(client.timelineRequests, 2);
    },
  );
}

Future<PullRequestPaneData> _waitForTimeline(
  ProviderContainer container,
  String cwd,
) async {
  final provider = pullRequestPaneProvider(cwd);
  for (var attempt = 0; attempt < 100; attempt++) {
    final data = container.read(provider).value;
    if (data != null && !data.activityLoading) return data;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  throw TimeoutException('timeline did not settle for $cwd');
}

Future<PullRequestPaneData> _waitForPushedTitle(
  ProviderContainer container,
  String cwd,
  String title,
) async {
  final provider = pullRequestPaneProvider(cwd);
  for (var attempt = 0; attempt < 200; attempt++) {
    final data = container.read(provider).value;
    if (data?.status?.title == title && data?.activityLoading == false) {
      return data!;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  throw TimeoutException('pushed PR status did not settle for $cwd');
}

final class _PullRequestDataClient extends DaemonClient {
  _PullRequestDataClient({
    required this.status,
    required this.timelineNumber,
    this.timeline = const [],
    this.timelineTruncated = false,
    this.timelineError,
    this.timelineGate,
    this.timelineFailure,
    this.githubFeaturesEnabled = true,
  }) : super(uri: Uri.parse('ws://fake'));

  final CheckoutPrStatus status;
  final num? timelineNumber;
  final List<PullRequestTimelineItem> timeline;
  final bool timelineTruncated;
  final PullRequestTimelineError? timelineError;
  final Completer<void>? timelineGate;
  final Object? timelineFailure;
  final bool githubFeaturesEnabled;
  final updates = StreamController<CheckoutStatusUpdate>.broadcast();
  PullRequestTimelineRequest? timelineRequest;
  var statusRequests = 0;
  var timelineRequests = 0;

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Stream<CheckoutStatusUpdate> get checkoutStatusUpdates => updates.stream;

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (message['type'] == CheckoutPrStatusRequest.type) {
      statusRequests += 1;
      return CheckoutPrStatusResponse(
        cwd: '/repo',
        status: status,
        githubFeaturesEnabled: githubFeaturesEnabled,
        authState: null,
        forge: status.forge,
        error: null,
        requestId: message['requestId']! as String,
      ).toJson();
    }
    if (message['type'] == PullRequestTimelineRequest.type) {
      timelineRequests += 1;
      timelineRequest = PullRequestTimelineRequest.fromJson(message);
      await timelineGate?.future;
      if (timelineFailure case final failure?) throw failure;
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

  @override
  void dispose() {
    unawaited(updates.close());
    super.dispose();
  }
}

CheckoutStatusUpdate _checkoutUpdateWithPr(
  CheckoutPrStatus status, {
  required String requestId,
}) => CheckoutStatusUpdate(
  payload: CheckoutStatusGitNonPaseo(
    cwd: '/repo',
    repoRoot: '/repo',
    mainRepoRoot: null,
    currentBranch: 'feature',
    isDirty: false,
    baseRef: 'main',
    aheadBehind: const CheckoutAheadBehind(ahead: 1, behind: 0),
    aheadOfOrigin: 0,
    behindOfOrigin: 0,
    hasRemote: true,
    remoteUrl: 'https://github.com/acme/app.git',
    error: null,
    requestId: 'subscription:/repo',
  ),
  prStatus: CheckoutPrStatusResponse(
    cwd: '/repo',
    status: status,
    githubFeaturesEnabled: true,
    authState: 'authenticated',
    forge: 'github',
    error: null,
    requestId: requestId,
  ),
);
