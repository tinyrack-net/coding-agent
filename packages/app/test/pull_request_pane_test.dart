import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/external_url_launcher.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/workspace_attachments_provider.dart';
import 'package:coding_agent_app/widgets/pull_request_pane.dart';
import 'package:coding_agent_app/widgets/workspace_explorer.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
    this.checkDetailsSuccess = true,
    this.checkDetailsGate,
  }) : super(uri: Uri.parse('ws://fake'));

  final bool hasPullRequest;
  final String statusState;
  final bool isMerged;
  final bool isDraft;
  final String forge;
  final String timelineMode;
  final String fileMode;
  final bool checkDetailsSuccess;
  final Completer<void>? checkDetailsGate;
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
    if (message['type'] == CheckoutForgeGetCheckDetailsRequest.modernType) {
      await checkDetailsGate?.future;
      return CheckoutForgeGetCheckDetailsResponse(
        type: CheckoutForgeGetCheckDetailsResponse.modernType,
        cwd: _cwd,
        success: checkDetailsSuccess,
        details: checkDetailsSuccess
            ? const CheckoutCheckDetails(
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
                number: 42,
                url: 'https://example.test/pr/42',
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
                          url: null,
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
                  'gitlab' => const {
                    'forge': 'gitlab',
                    'detailedMergeStatus': 'mergeable',
                    'hasConflicts': false,
                    'blockingDiscussionsResolved': true,
                    'approvalsRequired': 2,
                    'approvalsGiven': 1,
                    'pipelineStatus': 'running',
                    'pipelineId': 306,
                    'pipelineUrl': 'https://gitlab.example/pipelines/306',
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
            : [
                const PullRequestTimelineReview(
                  id: 'review-1',
                  author: 'octocat',
                  authorUrl: null,
                  avatarUrl: null,
                  body: 'Looks good to me.',
                  createdAt: 1760000000,
                  url: 'https://example.test/review/1',
                  reviewState: PullRequestTimelineReviewState.approved,
                ),
                const PullRequestTimelineComment(
                  id: 'comment-1',
                  author: 'reviewer',
                  authorUrl: null,
                  avatarUrl: null,
                  body: 'Please keep this covered.',
                  createdAt: 1760000100,
                  url: 'https://example.test/comment/1',
                  location: PullRequestTimelineCommentLocation(
                    path: 'lib/pane.dart',
                    line: 18,
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

void _noop() {}

void main() {
  testWidgets('shows the PR explorer tab and renders checks and activity', (
    tester,
  ) async {
    final client = _FakeDaemonClient();
    await _pumpExplorer(tester, client);

    expect(find.text('Changes'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('#42'), findsOneWidget);

    await tester.tap(find.text('#42'));
    await tester.pump(const Duration(milliseconds: 150));

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

      await tester.tap(find.text('#42'));
      await tester.pumpAndSettle();

      expect(find.text('CI'), findsOneWidget);
      expect(find.text('No checks reported'), findsNothing);
      expect(find.byIcon(FluentIcons.error_badge), findsWidgets);
    },
  );

  testWidgets('renders GitLab approval progress in the PR header', (
    tester,
  ) async {
    await _pumpExplorer(tester, _FakeDaemonClient(forge: 'gitlab'));

    await tester.tap(find.text('#42'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('pr-pane-approvals')), findsOneWidget);
    expect(find.text('1 of 2 approvals'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('pr-pane-approvals-icon')),
      findsOneWidget,
    );
  });

  testWidgets('section headers collapse and refresh reloads native data', (
    tester,
  ) async {
    final client = _FakeDaemonClient();
    await _pumpExplorer(tester, client);
    await tester.tap(find.text('#42'));
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
    await tester.tap(find.text('#42'));
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.text('View'));
    await tester.tap(find.text('Flutter tests'));
    await tester.tap(find.byKey(const ValueKey('open-activity-review-1')));
    await tester.pump(const Duration(milliseconds: 150));

    expect(launcher.opened, [
      'https://example.test/pr/42',
      'https://example.test/check/1',
      'https://example.test/review/1',
    ]);
  });

  testWidgets('Add to chat publishes a deduplicated composer attachment', (
    tester,
  ) async {
    final client = _FakeDaemonClient();
    final container = await _pumpExplorer(tester, client);
    await tester.tap(find.text('#42'));
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
    await tester.tap(find.text('#42'));
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
    await tester.tap(find.text('#42'));
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
    await tester.tap(find.text('#42'));
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
    await tester.pumpWidget(
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
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('No pull request for this branch'), findsOneWidget);
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
      await tester.tap(find.text('#42'));
      await tester.pump(const Duration(milliseconds: 150));

      expect(find.text('Lint'), findsOneWidget);
      expect(find.text('Please revise this.'), findsOneWidget);
      expect(find.text('requested changes'), findsOneWidget);
      expect(find.text('reviewed'), findsOneWidget);
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
    await tester.tap(find.text('#42'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('No activity yet'), findsOneWidget);

    await _pumpExplorer(tester, _FakeDaemonClient(timelineMode: 'error'));
    await tester.tap(find.text('#42'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('Timeline is unavailable'), findsOneWidget);
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
      await tester.tap(find.text('#42'));
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
    await tester.tap(find.text('#42'));
    await tester.pump(const Duration(milliseconds: 150));

    await expectLater(
      find.byType(WorkspaceExplorer),
      matchesGoldenFile('goldens/workspace_pr_explorer.png'),
    );
  });
}
