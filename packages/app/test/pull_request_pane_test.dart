import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/external_url_launcher.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/pull_request_provider.dart';
import 'package:coding_agent_app/state/workspace_attachments_provider.dart';
import 'package:coding_agent_app/widgets/pull_request_pane.dart';
import 'package:coding_agent_app/widgets/pull_request_section_kit.dart';
import 'package:coding_agent_app/widgets/pull_request_tab.dart';
import 'package:coding_agent_app/widgets/workspace_explorer.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _cwd = '/repo/worktree';

class _FakeExternalUrlLauncher implements ExternalUrlLauncher {
  final opened = <String>[];

  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return true;
  }
}

class _FakeDaemonClient extends DaemonClient {
  _FakeDaemonClient({
    this.hasPullRequest = true,
    this.statusState = 'OPEN',
    this.isMerged = false,
    this.isDraft = false,
    this.forge = 'github',
    this.timelineMode = 'default',
    this.fileMode = 'default',
    this.pipelineMode = 'populated',
    this.pipelineStatus = 'running',
    this.includeSkippedCheck = false,
    this.forgeProvidersEnabled = true,
    this.forgeCheckDetailsEnabled = true,
    this.checkDetailsSuccess = true,
    this.checkDetailsGate,
    this.statusGate,
    this.statusFailuresRemaining = 0,
  }) : super(uri: Uri.parse('ws://fake')) {
    serverInfo = ServerInfoStatus(
      serverId: 'test-host',
      hostname: 'test-host',
      version: '0.2.0',
      desktopManaged: true,
      features: {
        'forgeProviders': forgeProvidersEnabled,
        'forgeCheckDetails': forgeCheckDetailsEnabled,
      },
    );
  }

  final bool hasPullRequest;
  final String statusState;
  final bool isMerged;
  final bool isDraft;
  final String forge;
  final String timelineMode;
  final String fileMode;
  final String pipelineMode;
  final String pipelineStatus;
  final bool includeSkippedCheck;
  int changeRequestNumber = 42;
  int pipelineId = 306;
  final bool forgeProvidersEnabled;
  final bool forgeCheckDetailsEnabled;
  final bool checkDetailsSuccess;
  final Completer<void>? checkDetailsGate;
  final Completer<void>? statusGate;
  int statusFailuresRemaining;
  Completer<void>? pipelineDetailsGate;
  final nativeRequests = <Map<String, Object?>>[];

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState => const Stream.empty();

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (type == MessageTypes.diffGetRequest) {
      return const DiffResponse(files: []).toJson();
    }
    return const {};
  }

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    nativeRequests.add(message);
    if (message['type'] == CheckoutPrStatusRequest.type) {
      await statusGate?.future;
      if (statusFailuresRemaining > 0) {
        statusFailuresRemaining -= 1;
        throw StateError('status unavailable');
      }
    }
    if (message['type'] == CheckoutForgeGetCheckDetailsRequest.modernType) {
      final isGitlabPipeline = forge == 'gitlab';
      if (isGitlabPipeline) {
        await pipelineDetailsGate?.future;
      } else {
        await checkDetailsGate?.future;
      }
      final requestedPipelineId = message['checkRunId'] as int?;
      return CheckoutForgeGetCheckDetailsResponse(
        type: CheckoutForgeGetCheckDetailsResponse.modernType,
        cwd: _cwd,
        success: checkDetailsSuccess,
        details: checkDetailsSuccess
            ? isGitlabPipeline
                  ? CheckoutCheckDetails(
                      checkRunId: requestedPipelineId!,
                      name: 'Pipeline #$requestedPipelineId',
                      annotations: const [],
                      failedJobs: const [],
                      truncated: false,
                      pipeline: CheckoutPipeline(
                        id: requestedPipelineId,
                        status: 'running',
                        rawStatus: 'running',
                        url:
                            'https://gitlab.example/pipelines/$requestedPipelineId',
                        ref: 'pr-pane',
                        sha: 'abc123',
                        stages: pipelineMode == 'empty'
                            ? const []
                            : const [
                                CheckoutPipelineStage(
                                  name: 'verify',
                                  status: 'failed',
                                  jobs: [
                                    CheckoutPipelineJob(
                                      id: 501,
                                      name: 'analyze',
                                      stage: 'verify',
                                      status: 'success',
                                      rawStatus: 'success',
                                      url: 'https://gitlab.example/jobs/501',
                                      allowFailure: false,
                                      durationSeconds: 72,
                                    ),
                                    CheckoutPipelineJob(
                                      id: 502,
                                      name: 'windows',
                                      stage: 'verify',
                                      status: 'failed',
                                      rawStatus: 'failed',
                                      url: 'https://gitlab.example/jobs/502',
                                      allowFailure: true,
                                      durationSeconds: null,
                                    ),
                                    CheckoutPipelineJob(
                                      id: 503,
                                      name: 'mobile',
                                      stage: 'verify',
                                      status: 'running',
                                      rawStatus: 'running',
                                      url: null,
                                      allowFailure: false,
                                      durationSeconds: 5,
                                    ),
                                    CheckoutPipelineJob(
                                      id: 504,
                                      name: 'web',
                                      stage: 'verify',
                                      status: 'skipped',
                                      rawStatus: 'skipped',
                                      url: null,
                                      allowFailure: false,
                                      durationSeconds: null,
                                    ),
                                  ],
                                ),
                              ],
                      ),
                    )
                  : const CheckoutCheckDetails(
                      checkRunId: 99,
                      workflowRunId: 12,
                      name: 'Lint',
                      status: 'completed',
                      conclusion: 'failure',
                      url: 'https://api.example.test/check/99',
                      detailsUrl: 'https://example.test/check/99/details',
                      output: {
                        'title': 'Lint failed',
                        'summary': 'One error',
                        'text': 'Analyze this output.',
                      },
                      annotations: [
                        CheckoutCheckAnnotation(
                          path: 'lib/pane.dart',
                          startLine: 18,
                          endLine: 18,
                          annotationLevel: 'failure',
                          message: 'Avoid nested controls',
                        ),
                      ],
                      failedJobs: [
                        CheckoutCheckFailedJob(
                          jobId: 7,
                          name: 'lint',
                          conclusion: 'failure',
                          logTail: 'error: nested control',
                        ),
                      ],
                      truncated: false,
                    )
            : null,
        error: checkDetailsSuccess
            ? null
            : const CheckoutError(
                code: CheckoutErrorCode.unknown,
                message: 'details unavailable',
              ),
        requestId: message['requestId']! as String,
      ).toJson();
    }
    return switch (message['type']) {
      CheckoutPrStatusRequest.type => CheckoutPrStatusResponse(
        cwd: _cwd,
        status: hasPullRequest
            ? CheckoutPrStatus(
                forge: forge,
                projectPath: 'tinyrack/coding-agent',
                number: changeRequestNumber,
                url: 'https://example.test/pr/$changeRequestNumber',
                title: 'Port the pull request panel',
                state: statusState,
                baseRefName: 'main',
                headRefName: 'pr-pane',
                isMerged: isMerged,
                isDraft: isDraft,
                mergeable: 'MERGEABLE',
                checksStatus: 'success',
                reviewDecision: 'APPROVED',
                repoOwner: 'tinyrack',
                repoName: 'coding-agent',
                checks: forge == 'gitea'
                    ? const []
                    : [
                        CheckoutPrCheck(
                          name: 'Flutter tests',
                          status: 'success',
                          url: 'https://example.test/check/1',
                          workflow: 'CI',
                          duration: '1m 12s',
                        ),
                        CheckoutPrCheck(
                          name: 'Package',
                          status: 'pending',
                          url: includeSkippedCheck
                              ? 'https://example.test/check/package'
                              : null,
                        ),
                        if (includeSkippedCheck)
                          const CheckoutPrCheck(
                            name: 'Web',
                            status: 'skipped',
                            url: 'https://example.test/check/web',
                          ),
                        if (timelineMode == 'edge')
                          const CheckoutPrCheck(
                            name: 'Lint',
                            status: 'failure',
                            url: 'https://example.test/check/2',
                            checkRunId: 99,
                            workflowRunId: 12,
                          ),
                      ],
                forgeSpecific: switch (forge) {
                  'gitea' => const {
                    'forge': 'gitea',
                    'mergeable': true,
                    'hasMerged': false,
                    'ciStatus': 'warning',
                  },
                  'gitlab' => {
                    'forge': 'gitlab',
                    'detailedMergeStatus': 'mergeable',
                    'hasConflicts': false,
                    'blockingDiscussionsResolved': true,
                    'approvalsRequired': 2,
                    'approvalsGiven': 1,
                    'pipelineStatus': pipelineStatus,
                    'pipelineId': pipelineId,
                    'pipelineUrl':
                        'https://gitlab.example/pipelines/$pipelineId',
                    'mergeWhenPipelineSucceeds': false,
                  },
                  _ => null,
                },
              )
            : null,
        githubFeaturesEnabled: true,
        authState: null,
        forge: forge,
        error: null,
        requestId: message['requestId']! as String,
      ).toJson(),
      PullRequestTimelineRequest.type => PullRequestTimelineResponse(
        cwd: _cwd,
        prNumber: 42,
        items: timelineMode == 'empty' || timelineMode == 'error'
            ? const []
            : timelineMode == 'thread-menu'
            ? const [
                PullRequestTimelineComment(
                  id: 'comment-2',
                  author: 'reviewer',
                  authorUrl: null,
                  avatarUrl: null,
                  body: 'Range comment.',
                  createdAt: 1760000200,
                  url: 'https://example.test/comment/2',
                  threadId: 'PRRT_1',
                  location: PullRequestTimelineCommentLocation(
                    path: 'lib/range.dart',
                    startLine: 4,
                    line: 8,
                    threadId: 'PRRT_1',
                    isResolved: false,
                    isOutdated: false,
                  ),
                ),
              ]
            : [
                PullRequestTimelineReview(
                  id: 'review-1',
                  author: 'octocat',
                  authorUrl: null,
                  avatarUrl: timelineMode == 'avatar'
                      ? 'https://example.test/avatar.png'
                      : null,
                  body: timelineMode == 'links'
                      ? '[Review link](https://example.test/review-link)'
                      : 'Looks good to me.',
                  createdAt: 1760000000,
                  url: 'https://example.test/review/1',
                  reviewState: PullRequestTimelineReviewState.approved,
                ),
                PullRequestTimelineComment(
                  id: 'comment-1',
                  author: 'reviewer',
                  authorUrl: null,
                  avatarUrl: null,
                  body: timelineMode == 'links'
                      ? '[Activity link](https://example.test/activity-link)'
                      : 'Please keep this covered.',
                  createdAt: 1760000100,
                  url: 'https://example.test/comment/1',
                  location: PullRequestTimelineCommentLocation(
                    path: 'lib/pane.dart',
                    line: 18,
                  ),
                ),
                if (timelineMode == 'links')
                  const PullRequestTimelineComment(
                    id: 'comment-link-thread',
                    author: 'maintainer',
                    authorUrl: null,
                    avatarUrl: null,
                    body: '[Thread link](https://example.test/thread-link)',
                    createdAt: 1760000150,
                    url: 'https://example.test/comment/thread-link',
                    threadId: 'PRRT_LINK',
                    location: PullRequestTimelineCommentLocation(
                      path: 'lib/thread.dart',
                      line: 3,
                      threadId: 'PRRT_LINK',
                      isResolved: false,
                      isOutdated: false,
                    ),
                  ),
                if (timelineMode == 'edge') ...[
                  const PullRequestTimelineReview(
                    id: 'review-2',
                    author: 'maintainer',
                    authorUrl: null,
                    avatarUrl: null,
                    body: 'Please revise this.',
                    createdAt: 1760000200,
                    url: 'https://example.test/review/2',
                    reviewState:
                        PullRequestTimelineReviewState.changesRequested,
                  ),
                  const PullRequestTimelineReview(
                    id: 'review-3',
                    author: 'observer',
                    authorUrl: null,
                    avatarUrl: null,
                    body: '',
                    createdAt: 1760000300,
                    url: 'https://example.test/review/3',
                    reviewState: PullRequestTimelineReviewState.commented,
                  ),
                  const PullRequestTimelineComment(
                    id: 'comment-2',
                    author: 'reviewer',
                    authorUrl: null,
                    avatarUrl: null,
                    body: 'Range comment.',
                    createdAt: 9999999999999,
                    url: 'https://example.test/comment/2',
                    reviewId: 'review-2',
                    threadId: 'PRRT_1',
                    location: PullRequestTimelineCommentLocation(
                      path: 'lib/range.dart',
                      startLine: 4,
                      line: 8,
                      threadId: 'PRRT_1',
                      isResolved: false,
                      isOutdated: true,
                    ),
                  ),
                  const PullRequestTimelineComment(
                    id: 'comment-3',
                    author: 'maintainer',
                    authorUrl: null,
                    avatarUrl: null,
                    body: 'Thread reply.',
                    createdAt: 9999999999999,
                    url: 'https://example.test/comment/3',
                    threadId: 'PRRT_1',
                    location: PullRequestTimelineCommentLocation(
                      path: 'lib/range.dart',
                      startLine: 4,
                      line: 8,
                      threadId: 'PRRT_1',
                      isResolved: false,
                      isOutdated: true,
                    ),
                  ),
                  const PullRequestTimelineComment(
                    id: 'comment-resolved',
                    author: 'reviewer',
                    authorUrl: null,
                    avatarUrl: null,
                    body: 'This resolved thread must be skipped.',
                    createdAt: 1760000400,
                    url: 'https://example.test/comment/resolved',
                    threadId: 'PRRT_RESOLVED',
                    location: PullRequestTimelineCommentLocation(
                      path: 'lib/resolved.dart',
                      line: 9,
                      threadId: 'PRRT_RESOLVED',
                      isResolved: true,
                      isOutdated: false,
                    ),
                  ),
                ],
              ],
        truncated: timelineMode == 'edge',
        error: timelineMode == 'error'
            ? const PullRequestTimelineError(
                kind: PullRequestTimelineErrorKind.forbidden,
                message: 'Timeline is unavailable',
              )
            : null,
        requestId: message['requestId']! as String,
        githubFeaturesEnabled: true,
        authState: null,
      ).toJson(),
      'file_explorer_request' => {
        'type': 'file_explorer_response',
        'payload': {
          'cwd': _cwd,
          'path': '.',
          'mode': 'list',
          'directory': {
            'path': '.',
            'entries': fileMode == 'empty'
                ? <Object?>[]
                : message['path'] == 'lib'
                ? [
                    {
                      'name': 'small.dart',
                      'path': 'lib/small.dart',
                      'kind': 'file',
                      'size': 512,
                      'modifiedAt': '2026-01-01T00:00:00Z',
                    },
                    {
                      'name': 'medium.bin',
                      'path': 'lib/medium.bin',
                      'kind': 'file',
                      'size': 2048,
                      'modifiedAt': '2026-01-01T00:00:00Z',
                    },
                    {
                      'name': 'large.bin',
                      'path': 'lib/large.bin',
                      'kind': 'file',
                      'size': 2097152,
                      'modifiedAt': '2026-01-01T00:00:00Z',
                    },
                  ]
                : [
                    {
                      'name': 'lib',
                      'path': 'lib',
                      'kind': 'directory',
                      'size': 0,
                      'modifiedAt': '2026-01-01T00:00:00Z',
                    },
                  ],
          },
          'file': null,
          'error': fileMode == 'error' ? 'directory unavailable' : null,
          'requestId': message['requestId'],
        },
      },
      _ => throw StateError('unexpected native request: ${message['type']}'),
    };
  }
}

Future<ProviderContainer> _pumpExplorer(
  WidgetTester tester,
  _FakeDaemonClient client, {
  _FakeExternalUrlLauncher? launcher,
}) async {
  final container = ProviderContainer(
    overrides: [
      daemonClientProvider.overrideWithValue(client),
      externalUrlLauncherProvider.overrideWithValue(
        launcher ?? _FakeExternalUrlLauncher(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        theme: buildAppTheme(),
        darkTheme: buildAppTheme(),
        themeMode: ThemeMode.dark,
        home: const SizedBox(
          width: 380,
          height: 700,
          child: WorkspaceExplorer(cwd: _cwd, onClose: _noop),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

Future<void> _pumpPane(WidgetTester tester, _FakeDaemonClient client) =>
    tester.pumpWidget(
      ProviderScope(
        overrides: [daemonClientProvider.overrideWithValue(client)],
        child: FluentApp(
          theme: buildAppTheme(),
          darkTheme: buildAppTheme(),
          themeMode: ThemeMode.dark,
          home: const SizedBox(
            width: 380,
            height: 700,
            child: PullRequestPane(cwd: _cwd),
          ),
        ),
      ),
    );

void _noop() {}

Future<void> _tapPullRequestTab(WidgetTester tester) =>
    tester.tap(find.byKey(const ValueKey('explorer-tab-pr')));

void main() {
  testWidgets('shows the PR explorer tab and renders checks and activity', (
    tester,
  ) async {
    final client = _FakeDaemonClient();
    await _pumpExplorer(tester, client);

    expect(find.text('Changes'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('#42'), findsNothing);
    expect(find.byKey(const ValueKey('explorer-tab-pr-icon')), findsOneWidget);
    expect(
      tester
          .widget<PullRequestTabIcon>(
            find.byKey(const ValueKey('explorer-tab-pr-icon')),
          )
          .color,
      const Color(0xffa1a5a4),
    );

    await tester.tap(find.text('42'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      tester
          .widget<PullRequestTabIcon>(
            find.byKey(const ValueKey('explorer-tab-pr-icon')),
          )
          .color,
      const Color(0xfffafafa),
    );
    expect(find.textContaining('Port the pull request panel'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Checks'), findsOneWidget);
    expect(find.text('Flutter tests'), findsOneWidget);
    expect(find.text('Package'), findsNothing);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Looks good to me.'), findsOneWidget);
    expect(find.text('lib/pane.dart:18'), findsOneWidget);
  });

  testWidgets(
    'renders the Gitea aggregate CI fallback with failure semantics',
    (tester) async {
      await _pumpExplorer(tester, _FakeDaemonClient(forge: 'gitea'));

      await _tapPullRequestTab(tester);
      await tester.pumpAndSettle();

      expect(find.text('CI'), findsOneWidget);
      expect(find.text('No checks reported'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is PullRequestGlyph &&
              widget.kind == PullRequestGlyphKind.circleX,
        ),
        findsWidgets,
      );
    },
  );

  testWidgets('does not count skipped checks as pending', (tester) async {
    await _pumpExplorer(tester, _FakeDaemonClient(includeSkippedCheck: true));
    await _tapPullRequestTab(tester);
    await tester.pumpAndSettle();

    final pending = find.byKey(const ValueKey('pr-pane-check-pending'));
    expect(
      find.descendant(of: pending, matching: find.text('1')),
      findsOneWidget,
    );
    expect(find.text('Web'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('check-Web')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is PullRequestGlyph &&
              widget.kind == PullRequestGlyphKind.circleSlash,
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('renders GitLab approval progress in the PR header', (
    tester,
  ) async {
    await _pumpExplorer(tester, _FakeDaemonClient(forge: 'gitlab'));

    await _tapPullRequestTab(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('pr-pane-approvals')), findsOneWidget);
    expect(find.text('1 of 2 approvals'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pr-pane-approvals-icon')),
      findsOneWidget,
    );
  });

  testWidgets('renders and opens the complete GitLab pipeline tree', (
    tester,
  ) async {
    final client = _FakeDaemonClient(forge: 'gitlab');
    final launcher = _FakeExternalUrlLauncher();
    await _pumpExplorer(tester, client, launcher: launcher);

    await _tapPullRequestTab(tester);
    await tester.pumpAndSettle();

    expect(find.text('Pipeline'), findsOneWidget);
    expect(find.text('Checks'), findsNothing);
    expect(find.text('Pipeline #306'), findsOneWidget);
    expect(find.text('running'), findsOneWidget);
    expect(find.text('VERIFY'), findsOneWidget);
    expect(find.text('analyze'), findsOneWidget);
    expect(find.text('windows'), findsOneWidget);
    expect(find.text('mobile'), findsOneWidget);
    expect(find.text('web'), findsOneWidget);
    expect(find.text('allowed to fail'), findsOneWidget);
    expect(find.text('1m 12s'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pr-pane-pipeline-passed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('pr-pane-pipeline-failed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('pr-pane-pipeline-pending')),
      findsOneWidget,
    );

    final request = client.nativeRequests.lastWhere(
      (request) =>
          request['type'] == CheckoutForgeGetCheckDetailsRequest.modernType &&
          request['checkRunId'] == 306,
    );
    expect(request['cwd'], _cwd);
    expect(request['changeRequestNumber'], 42);
    expect(request.containsKey('repoOwner'), isFalse);
    expect(request.containsKey('repoName'), isFalse);

    await tester.tap(find.byKey(const ValueKey('pr-pane-pipeline-link')));
    await tester.tap(find.text('analyze'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(launcher.opened, [
      'https://gitlab.example/pipelines/306',
      'https://gitlab.example/jobs/501',
    ]);
  });

  testWidgets('polls only an open live GitLab pipeline', (tester) async {
    final client = _FakeDaemonClient(forge: 'gitlab');
    await _pumpExplorer(tester, client);
    await _tapPullRequestTab(tester);
    await tester.pumpAndSettle();

    int pipelineRequests() => client.nativeRequests
        .where(
          (request) =>
              request['type'] ==
                  CheckoutForgeGetCheckDetailsRequest.modernType &&
              request['checkRunId'] == 306,
        )
        .length;

    expect(pipelineRequests(), 1);
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(pipelineRequests(), 2);

    await tester.tap(find.text('Pipeline'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(pipelineRequests(), 2);
  });

  testWidgets('does not poll a finished GitLab pipeline', (tester) async {
    final client = _FakeDaemonClient(
      forge: 'gitlab',
      pipelineStatus: 'success',
    );
    await _pumpExplorer(tester, client);
    await _tapPullRequestTab(tester);
    await tester.pumpAndSettle();

    int pipelineRequests() => client.nativeRequests
        .where(
          (request) =>
              request['type'] ==
                  CheckoutForgeGetCheckDetailsRequest.modernType &&
              request['checkRunId'] == 306,
        )
        .length;

    expect(pipelineRequests(), 1);
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(pipelineRequests(), 1);

    await tester.tap(find.text('Pipeline'));
    await tester.pump();
    await tester.tap(find.text('Pipeline'));
    await tester.pumpAndSettle();
    expect(pipelineRequests(), 1);
  });

  testWidgets('manual refresh invalidates a finished pipeline cache', (
    tester,
  ) async {
    final client = _FakeDaemonClient(
      forge: 'gitlab',
      pipelineStatus: 'success',
    );
    await _pumpExplorer(tester, client);
    await _tapPullRequestTab(tester);
    await tester.pumpAndSettle();

    int pipelineRequests() => client.nativeRequests
        .where(
          (request) =>
              request['type'] ==
                  CheckoutForgeGetCheckDetailsRequest.modernType &&
              request['checkRunId'] == 306,
        )
        .length;

    expect(pipelineRequests(), 1);
    await tester.tap(find.byIcon(FluentIcons.refresh).last);
    await tester.pumpAndSettle();
    expect(pipelineRequests(), 2);
  });

  testWidgets('remounts with cached data while refetching the pipeline', (
    tester,
  ) async {
    final client = _FakeDaemonClient(
      forge: 'gitlab',
      pipelineStatus: 'success',
    );
    await _pumpExplorer(tester, client);
    await _tapPullRequestTab(tester);
    await tester.pumpAndSettle();
    expect(find.text('analyze'), findsOneWidget);

    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    final gate = Completer<void>();
    client.pipelineDetailsGate = gate;
    await _tapPullRequestTab(tester);
    await tester.pump();
    await tester.pump();

    expect(find.text('analyze'), findsOneWidget);
    expect(find.text('Loading pipeline…'), findsNothing);
    expect(
      client.nativeRequests
          .where(
            (request) =>
                request['type'] ==
                    CheckoutForgeGetCheckDetailsRequest.modernType &&
                request['checkRunId'] == 306,
          )
          .length,
      2,
    );

    gate.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('keeps previous pipeline data while a new identity loads', (
    tester,
  ) async {
    final client = _FakeDaemonClient(forge: 'gitlab');
    await _pumpExplorer(tester, client);
    await _tapPullRequestTab(tester);
    await tester.pumpAndSettle();

    expect(find.text('Pipeline #306'), findsOneWidget);
    expect(find.text('analyze'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pr-pane-pipeline-passed')),
      findsOneWidget,
    );

    final gate = Completer<void>();
    client
      ..changeRequestNumber = 43
      ..pipelineId = 307
      ..pipelineDetailsGate = gate;
    await tester.tap(find.byIcon(FluentIcons.refresh).last);
    await tester.pump();
    await tester.pump();

    expect(find.text('Pipeline #307'), findsOneWidget);
    expect(find.text('analyze'), findsOneWidget);
    expect(find.text('Loading pipeline…'), findsNothing);
    expect(find.byKey(const ValueKey('pr-pane-pipeline-passed')), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Pipeline #307'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pr-pane-pipeline-passed')),
      findsOneWidget,
    );
    final request = client.nativeRequests.lastWhere(
      (request) =>
          request['type'] == CheckoutForgeGetCheckDetailsRequest.modernType &&
          request['checkRunId'] == 307,
    );
    expect(request['changeRequestNumber'], 43);
  });

  testWidgets('honors GitLab forge feature capability gates', (tester) async {
    final providersDisabled = _FakeDaemonClient(
      forge: 'gitlab',
      forgeProvidersEnabled: false,
    );
    await _pumpExplorer(tester, providersDisabled);
    await _tapPullRequestTab(tester);
    await tester.pumpAndSettle();
    expect(find.text('Checks'), findsOneWidget);
    expect(find.text('Pipeline'), findsNothing);

    final detailsDisabled = _FakeDaemonClient(
      forge: 'gitlab',
      forgeCheckDetailsEnabled: false,
    );
    await _pumpExplorer(tester, detailsDisabled);
    await _tapPullRequestTab(tester);
    await tester.pumpAndSettle();
    expect(find.text('Pipeline'), findsOneWidget);
    expect(find.text('Pipeline #306'), findsOneWidget);
    expect(find.text('analyze'), findsNothing);
    expect(
      detailsDisabled.nativeRequests.where(
        (request) =>
            request['type'] == CheckoutForgeGetCheckDetailsRequest.modernType,
      ),
      isEmpty,
    );
  });

  testWidgets('shows GitLab pipeline loading before the first response', (
    tester,
  ) async {
    final gate = Completer<void>();
    final client = _FakeDaemonClient(forge: 'gitlab', checkDetailsGate: gate);
    await _pumpExplorer(tester, client);
    await _tapPullRequestTab(tester);
    await tester.pump();

    expect(find.text('Loading pipeline…'), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Loading pipeline…'), findsNothing);
    expect(find.text('analyze'), findsOneWidget);
  });

  testWidgets('renders GitLab pipeline empty and failure states', (
    tester,
  ) async {
    await _pumpExplorer(
      tester,
      _FakeDaemonClient(forge: 'gitlab', pipelineMode: 'empty'),
    );
    await _tapPullRequestTab(tester);
    await tester.pumpAndSettle();
    expect(find.text('No jobs'), findsOneWidget);

    await _pumpExplorer(
      tester,
      _FakeDaemonClient(forge: 'gitlab', checkDetailsSuccess: false),
    );
    await _tapPullRequestTab(tester);
    await tester.pumpAndSettle();
    expect(find.text('Could not load pipeline jobs'), findsOneWidget);
  });

  testWidgets('section headers collapse and refresh reloads native data', (
    tester,
  ) async {
    final client = _FakeDaemonClient();
    await _pumpExplorer(tester, client);
    await _tapPullRequestTab(tester);
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.text('Checks'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Flutter tests'), findsNothing);

    final before = client.nativeRequests
        .where((request) => request['type'] == CheckoutPrStatusRequest.type)
        .length;
    await tester.tap(find.byIcon(FluentIcons.refresh).last);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    final after = client.nativeRequests
        .where((request) => request['type'] == CheckoutPrStatusRequest.type)
        .length;
    expect(after, before + 1);
  });

  testWidgets('View, check, and activity links open through the platform', (
    tester,
  ) async {
    final client = _FakeDaemonClient();
    final launcher = _FakeExternalUrlLauncher();
    await _pumpExplorer(tester, client, launcher: launcher);
    await _tapPullRequestTab(tester);
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.text('View'));
    await tester.tap(find.text('Flutter tests'));
    await tester.tap(find.byKey(const ValueKey('activity-actions-review-1')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('activity-action-open-review-1')),
    );
    await tester.pumpAndSettle();

    expect(launcher.opened, [
      'https://example.test/pr/42',
      'https://example.test/check/1',
      'https://example.test/review/1',
    ]);
  });

  testWidgets('activity uses remote avatars with deterministic fallback', (
    tester,
  ) async {
    await _pumpExplorer(tester, _FakeDaemonClient(timelineMode: 'avatar'));
    await _tapPullRequestTab(tester);
    await tester.pump(const Duration(milliseconds: 150));

    final image = tester.widget<Image>(
      find.byKey(const ValueKey('activity-avatar-image-review-1')),
    );
    expect(image.width, 20);
    expect(image.height, 20);
    expect(image.fit, BoxFit.cover);
    expect(image.excludeFromSemantics, isTrue);
    expect(image.image, isA<NetworkImage>());
    expect(
      (image.image as NetworkImage).url,
      'https://example.test/avatar.png',
    );

    final fallback = tester.widget<Container>(
      find.byKey(const ValueKey('activity-avatar-fallback-comment-1')),
    );
    final decoration = fallback.decoration! as BoxDecoration;
    expect(decoration.shape, BoxShape.circle);
    expect(decoration.color, const Color(0xffeab308));
    expect(find.text('R'), findsOneWidget);
  });

  testWidgets('PR Markdown links open through the platform', (tester) async {
    final launcher = _FakeExternalUrlLauncher();
    await _pumpExplorer(
      tester,
      _FakeDaemonClient(timelineMode: 'links'),
      launcher: launcher,
    );
    await _tapPullRequestTab(tester);
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.text('Review link'));
    await tester.tap(find.text('Activity link'));
    await tester.pumpAndSettle();

    final threadLink = find.text('Thread link');
    await tester.drag(find.byType(ListView).first, const Offset(0, -240));
    await tester.pumpAndSettle();
    await tester.tap(threadLink);
    await tester.pumpAndSettle();

    expect(launcher.opened, [
      'https://example.test/review-link',
      'https://example.test/activity-link',
      'https://example.test/thread-link',
    ]);
  });

  testWidgets('activity menu matches Paseo add, copy, and forge-open actions', (
    tester,
  ) async {
    String? copiedText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final container = await _pumpExplorer(tester, _FakeDaemonClient());
    await _tapPullRequestTab(tester);
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.byKey(const ValueKey('activity-actions-review-1')));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(MenuFlyout)).width, 200);
    expect(
      find.byKey(const ValueKey('activity-action-add-review-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('activity-action-copy-review-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('activity-action-open-review-1')),
      findsOneWidget,
    );
    expect(find.text('Open on GitHub'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('activity-action-copy-review-1')),
    );
    await tester.pumpAndSettle();
    expect(copiedText, 'Looks good to me.');

    await tester.tap(find.byKey(const ValueKey('activity-actions-review-1')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('activity-action-add-review-1')),
    );
    await tester.pumpAndSettle();
    expect(container.read(workspaceAttachmentsProvider(_cwd)), hasLength(1));
  });

  testWidgets('thread menu only opens the thread on the active forge', (
    tester,
  ) async {
    final launcher = _FakeExternalUrlLauncher();
    await _pumpExplorer(
      tester,
      _FakeDaemonClient(timelineMode: 'thread-menu', forge: 'gitlab'),
      launcher: launcher,
    );
    await _tapPullRequestTab(tester);
    await tester.pump(const Duration(milliseconds: 150));
    const threadId = 'thread:PRRT_1';
    final trigger = find.byKey(const ValueKey('thread-actions-$threadId'));

    await tester.tap(trigger);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('thread-action-open-$threadId')),
      findsOneWidget,
    );
    expect(find.text('Open on GitLab'), findsOneWidget);
    expect(find.text('Copy'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('thread-action-open-$threadId')),
    );
    await tester.pumpAndSettle();
    expect(launcher.opened, ['https://example.test/comment/2']);
  });

  testWidgets('Add to chat publishes a deduplicated composer attachment', (
    tester,
  ) async {
    final client = _FakeDaemonClient();
    final container = await _pumpExplorer(tester, client);
    await _tapPullRequestTab(tester);
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.text('Add to chat').first);
    await tester.tap(find.text('Add to chat').first);
    await tester.pump(const Duration(milliseconds: 150));

    final attachments = container.read(workspaceAttachmentsProvider(_cwd));
    expect(attachments, hasLength(1));
    expect(attachments.single.title, 'octocat');
    expect(attachments.single.text, contains('GitHub pull request review'));
    expect(
      attachments.single.text,
      contains('#42 Port the pull request panel'),
    );
  });

  testWidgets('failed check fetches details and exposes loading state', (
    tester,
  ) async {
    final gate = Completer<void>();
    final client = _FakeDaemonClient(
      timelineMode: 'edge',
      checkDetailsGate: gate,
    );
    final container = await _pumpExplorer(tester, client);
    await _tapPullRequestTab(tester);
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Add to chat'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('add-check-99')));
    await tester.pump();
    expect(find.text('Adding...'), findsOneWidget);

    gate.complete();
    await tester.pump(const Duration(milliseconds: 150));
    final attachments = container.read(workspaceAttachmentsProvider(_cwd));
    final checkAttachment = attachments.singleWhere(
      (attachment) => attachment.kind == 'forge.change_request_check',
    );
    expect(checkAttachment.id, '42:check-run:99');
    expect(checkAttachment.text, contains('Output title: Lint failed'));
    expect(checkAttachment.text, contains('error: nested control'));
    expect(
      client.nativeRequests.any(
        (request) =>
            request['type'] == CheckoutForgeGetCheckDetailsRequest.modernType,
      ),
      isTrue,
    );
    expect(find.text('Adding...'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('add-check-99')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      container
          .read(workspaceAttachmentsProvider(_cwd))
          .where(
            (attachment) => attachment.kind == 'forge.change_request_check',
          ),
      hasLength(1),
    );
  });

  testWidgets('failed check falls back to metadata when details fail', (
    tester,
  ) async {
    final client = _FakeDaemonClient(
      timelineMode: 'edge',
      checkDetailsSuccess: false,
    );
    final container = await _pumpExplorer(tester, client);
    await _tapPullRequestTab(tester);
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.byKey(const ValueKey('add-check-99')));
    await tester.pump(const Duration(milliseconds: 150));

    final checkAttachment = container
        .read(workspaceAttachmentsProvider(_cwd))
        .singleWhere(
          (attachment) => attachment.kind == 'forge.change_request_check',
        );
    expect(checkAttachment.text, contains('Check: Lint'));
    expect(checkAttachment.text, isNot(contains('Output title:')));
    expect(find.text('Adding...'), findsNothing);
  });

  testWidgets('Add all to chat skips resolved review threads', (tester) async {
    final container = await _pumpExplorer(
      tester,
      _FakeDaemonClient(timelineMode: 'edge'),
    );
    await _tapPullRequestTab(tester);
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.text('Add all to chat'));
    await tester.pump(const Duration(milliseconds: 150));

    final attachments = container.read(workspaceAttachmentsProvider(_cwd));
    expect(attachments, isNotEmpty);
    expect(
      attachments.any(
        (attachment) =>
            attachment.text.contains('This resolved thread must be skipped.'),
      ),
      isFalse,
    );
    expect(
      attachments.any(
        (attachment) => attachment.text.contains('Range comment.'),
      ),
      isTrue,
    );
  });

  testWidgets('hides the PR tab when the branch has no pull request', (
    tester,
  ) async {
    await _pumpExplorer(tester, _FakeDaemonClient(hasPullRequest: false));
    expect(find.text('#42'), findsNothing);
    expect(find.text('Changes'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
  });

  testWidgets('pull request pane explains when the branch has no PR', (
    tester,
  ) async {
    final client = _FakeDaemonClient(hasPullRequest: false);
    await _pumpPane(tester, client);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('No pull request for this branch'), findsOneWidget);
  });

  testWidgets('pull request pane uses the frozen skeleton while loading', (
    tester,
  ) async {
    final gate = Completer<void>();
    await _pumpPane(tester, _FakeDaemonClient(statusGate: gate));
    await tester.pump();

    expect(find.byKey(const ValueKey('pr-pane-skeleton')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pr-pane-activity-skeleton')),
      findsOneWidget,
    );
    expect(find.byType(ProgressRing), findsNothing);

    gate.complete();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('pr-pane-skeleton')), findsNothing);
    expect(find.textContaining('Port the pull request panel'), findsOneWidget);
  });

  testWidgets('fatal pull request load error retries through the notifier', (
    tester,
  ) async {
    final client = _FakeDaemonClient(statusFailuresRemaining: 1);
    await _pumpPane(tester, client);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byKey(const ValueKey('pr-pane-error')), findsOneWidget);
    expect(find.text('Failed to refresh git state.'), findsOneWidget);
    expect(find.textContaining('status unavailable'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pr-pane-error-retry')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('pr-pane-error')), findsNothing);
    expect(find.textContaining('Port the pull request panel'), findsOneWidget);
    expect(
      client.nativeRequests.where(
        (request) => request['type'] == CheckoutPrStatusRequest.type,
      ),
      hasLength(2),
    );
  });

  testWidgets('files tab loads the root directory', (tester) async {
    await _pumpExplorer(tester, _FakeDaemonClient());
    await tester.tap(find.text('Files'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('lib'), findsOneWidget);
  });

  testWidgets(
    'renders failure checks, review variants, ranges, and truncation',
    (tester) async {
      final container = await _pumpExplorer(
        tester,
        _FakeDaemonClient(timelineMode: 'edge'),
      );
      await _tapPullRequestTab(tester);
      await tester.pump(const Duration(milliseconds: 150));

      expect(find.text('Lint'), findsOneWidget);
      expect(find.text('Please revise this.'), findsOneWidget);
      expect(find.text('requested changes'), findsOneWidget);
      expect(find.text('reviewed'), findsNothing);
      expect(find.text('observer'), findsNothing);
      expect(find.text('lib/range.dart:4-8'), findsOneWidget);
      expect(find.text('Outdated'), findsOneWidget);
      expect(find.text('Range comment.'), findsNothing);
      expect(find.text('Older activity is not shown'), findsOneWidget);

      await tester.drag(find.byType(ListView).first, const Offset(0, -260));
      await tester.pump();
      await tester.tap(find.text('lib/range.dart:4-8'));
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('Range comment.'), findsOneWidget);
      expect(find.text('Thread reply.'), findsOneWidget);

      await tester.drag(find.byType(ListView).first, const Offset(0, -220));
      await tester.pump();
      await tester.tap(find.text('Add to chat').last);
      await tester.pump(const Duration(milliseconds: 150));
      final attachments = container.read(workspaceAttachmentsProvider(_cwd));
      expect(
        attachments.any(
          (attachment) => attachment.text.contains('review thread'),
        ),
        isTrue,
      );

      await tester.drag(find.byType(ListView).first, const Offset(0, 480));
      await tester.pump();
      await tester.tap(find.text('Activity'));
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('Please revise this.'), findsNothing);
    },
  );

  testWidgets('renders empty and failed activity states', (tester) async {
    await _pumpExplorer(tester, _FakeDaemonClient(timelineMode: 'empty'));
    await _tapPullRequestTab(tester);
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('No activity yet'), findsOneWidget);

    await _pumpExplorer(tester, _FakeDaemonClient(timelineMode: 'error'));
    await _tapPullRequestTab(tester);
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Timeline is unavailable'), findsOneWidget);
  });

  testWidgets('scopes expanded activity state to the pull request number', (
    tester,
  ) async {
    final client = _FakeDaemonClient(timelineMode: 'edge');
    final container = await _pumpExplorer(tester, client);
    await _tapPullRequestTab(tester);
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('This resolved thread must be skipped.'), findsNothing);
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pump();
    await tester.ensureVisible(find.text('lib/resolved.dart:9'));
    await tester.tap(find.text('lib/resolved.dart:9'));
    await tester.pumpAndSettle();
    expect(find.text('This resolved thread must be skipped.'), findsOneWidget);

    client.changeRequestNumber = 43;
    await container.read(pullRequestPaneProvider(_cwd).notifier).refresh();
    await tester.pumpAndSettle();
    expect(find.text('43'), findsOneWidget);
    expect(find.text('This resolved thread must be skipped.'), findsNothing);

    client.changeRequestNumber = 42;
    await container.read(pullRequestPaneProvider(_cwd).notifier).refresh();
    await tester.pumpAndSettle();
    expect(find.text('This resolved thread must be skipped.'), findsOneWidget);
  });

  for (final variant in [
    (label: 'Merged', state: 'CLOSED', merged: true, draft: false),
    (label: 'Draft', state: 'OPEN', merged: false, draft: true),
    (label: 'Closed', state: 'CLOSED', merged: false, draft: false),
  ]) {
    testWidgets('renders the ${variant.label.toLowerCase()} PR state', (
      tester,
    ) async {
      await _pumpExplorer(
        tester,
        _FakeDaemonClient(
          statusState: variant.state,
          isMerged: variant.merged,
          isDraft: variant.draft,
        ),
      );
      await _tapPullRequestTab(tester);
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text(variant.label), findsOneWidget);
    });
  }

  testWidgets('files navigate into a directory, format sizes, go up, refresh', (
    tester,
  ) async {
    final client = _FakeDaemonClient();
    await _pumpExplorer(tester, client);
    await tester.tap(find.text('Files'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('lib'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('512 B'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.text('2.0 MB'), findsOneWidget);
    await tester.tap(find.byIcon(FluentIcons.refresh).last);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byIcon(FluentIcons.up));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('lib'), findsOneWidget);
  });

  testWidgets('files render empty and error states', (tester) async {
    await _pumpExplorer(tester, _FakeDaemonClient(fileMode: 'empty'));
    await tester.tap(find.text('Files'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Empty folder'), findsOneWidget);

    await _pumpExplorer(tester, _FakeDaemonClient(fileMode: 'error'));
    await tester.tap(find.text('Files'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('directory unavailable'), findsOneWidget);
  });

  testWidgets('PR explorer matches the frozen Windows golden', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(380, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await _pumpExplorer(tester, _FakeDaemonClient());
    await _tapPullRequestTab(tester);
    await tester.pump(const Duration(milliseconds: 150));

    await expectLater(
      find.byType(WorkspaceExplorer),
      matchesGoldenFile('goldens/workspace_pr_explorer.png'),
    );
  });

  testWidgets('GitLab pipeline matches the frozen Windows golden', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(380, 700);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await _pumpExplorer(tester, _FakeDaemonClient(forge: 'gitlab'));
    await _tapPullRequestTab(tester);
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(WorkspaceExplorer),
      matchesGoldenFile('goldens/workspace_gitlab_pipeline_explorer.png'),
    );
  });
}
