import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/pull_request_activity_state.dart';
import 'package:coding_agent_app/core/pull_request_context.dart';
import 'package:flutter_test/flutter_test.dart';

PullRequestTimelineComment _comment(
  String id, {
  PullRequestTimelineCommentLocation? location,
}) => PullRequestTimelineComment(
  id: id,
  author: 'octocat',
  authorUrl: null,
  avatarUrl: null,
  body: 'Looks good.',
  createdAt: 1760000000,
  url: 'https://example.test/$id',
  location: location,
);

PullRequestSingleEntry _single(
  String id, {
  bool resolved = false,
  bool outdated = false,
}) => PullRequestSingleEntry(
  id,
  _comment(
    id,
    location: resolved || outdated
        ? PullRequestTimelineCommentLocation(
            path: 'a.dart',
            line: 1,
            isResolved: resolved,
            isOutdated: outdated,
          )
        : null,
  ),
);

PullRequestThreadEntry _thread(
  String id, {
  bool resolved = false,
  bool outdated = false,
  bool hasLocation = true,
}) => PullRequestThreadEntry(
  id: 'thread:$id',
  comments: [_comment(id)],
  location: hasLocation
      ? PullRequestTimelineCommentLocation(
          path: 'a.dart',
          line: 1,
          isResolved: resolved,
          isOutdated: outdated,
        )
      : null,
  isResolved: resolved,
);

PullRequestReviewEntry _review(
  String id,
  List<PullRequestThreadEntry> threads,
) => PullRequestReviewEntry(
  id: id,
  review: PullRequestTimelineReview(
    id: id,
    author: 'octocat',
    authorUrl: null,
    avatarUrl: null,
    body: 'Review body.',
    createdAt: 1760000000,
    url: 'https://example.test/$id',
    reviewState: PullRequestTimelineReviewState.commented,
  ),
  threads: threads,
);

void main() {
  test('collapses and expands activity by PR-scoped stable key', () {
    final collapsed = const PullRequestActivityState().collapse(
      prNumber: 42,
      activityId: 'comment-1',
    );
    expect(collapsed.collapsedKeys, {'42:comment-1'});
    expect(collapsed.expandedKeys, isEmpty);

    final expanded = collapsed.expand(prNumber: 42, activityId: 'comment-1');
    expect(expanded.collapsedKeys, isEmpty);
    expect(expanded.expandedKeys, {'42:comment-1'});
  });

  test('explicit state never leaks across pull requests', () {
    final entry = _thread('shared');
    final state = const PullRequestActivityState().collapse(
      prNumber: 42,
      activityId: entry.id,
    );

    expect(state.isCollapsed(prNumber: 42, entry: entry), isTrue);
    expect(state.isCollapsed(prNumber: 43, entry: entry), isFalse);
    expect(state.collapsedEntryIds(prNumber: 43, entries: [entry]), isEmpty);
  });

  test('resolved and outdated entries collapse by default', () {
    final entries = <PullRequestTimelineEntry>[
      _single('normal'),
      _single('resolved', resolved: true),
      _single('outdated', outdated: true),
      _thread('normal'),
      _thread('resolved', resolved: true),
      _thread('outdated', outdated: true),
    ];

    final visible = const PullRequestActivityState().visibleEntries(
      prNumber: 42,
      entries: entries,
    );

    expect(
      {for (final item in visible) item.entry.id: item.collapsed},
      {
        'normal': false,
        'resolved': true,
        'outdated': true,
        'thread:normal': false,
        'thread:resolved': true,
        'thread:outdated': true,
      },
    );
  });

  test('resolved general thread collapses without a location', () {
    final entry = _thread('general', resolved: true, hasLocation: false);
    expect(
      const PullRequestActivityState().isCollapsed(prNumber: 42, entry: entry),
      isTrue,
    );
  });

  test('explicit state overrides both default directions', () {
    final resolved = _thread('resolved', resolved: true);
    final normal = _thread('normal');
    final state = const PullRequestActivityState()
        .expand(prNumber: 42, activityId: resolved.id)
        .collapse(prNumber: 42, activityId: normal.id);

    expect(state.isCollapsed(prNumber: 42, entry: resolved), isFalse);
    expect(state.isCollapsed(prNumber: 42, entry: normal), isTrue);
  });

  test('includes default-collapsed nested review threads recursively', () {
    final resolved = _thread('resolved', resolved: true);
    final outdated = _thread('outdated', outdated: true);
    final review = _review('review', [_thread('normal'), resolved, outdated]);

    expect(
      const PullRequestActivityState().collapsedEntryIds(
        prNumber: 42,
        entries: [review],
      ),
      {resolved.id, outdated.id},
    );
  });

  test('explicit expansion removes a nested default-collapsed thread', () {
    final resolved = _thread('resolved', resolved: true);
    final review = _review('review', [resolved]);
    final state = const PullRequestActivityState().expand(
      prNumber: 42,
      activityId: resolved.id,
    );

    expect(state.collapsedEntryIds(prNumber: 42, entries: [review]), isEmpty);
  });
}
