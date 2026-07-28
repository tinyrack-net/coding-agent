import 'dart:convert';

import 'package:agent_daemon/src/forge/forge_adapters.dart';
import 'package:agent_daemon/src/forge/forge_cli.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'GitHub maps reviews, comments, threads, attachments, and truncation',
    () async {
      final transport = _FakeTransport((_, args) {
        expect(args.take(2), ['api', 'graphql']);
        expect(args, contains('owner=acme'));
        expect(args, contains('name=repo'));
        expect(args, contains('number=42'));
        return _json({
          'data': {
            'repository': {
              'pullRequest': {
                'number': 42,
                'reviews': {
                  'nodes': [
                    {
                      'id': 'R1',
                      'state': 'APPROVED',
                      'body': 'Looks good',
                      'bodyHTML': '<p>Looks good</p>',
                      'url': 'https://github.test/reviews/1',
                      'submittedAt': '2026-07-27T00:00:02Z',
                      'author': {
                        'login': 'reviewer',
                        'url': 'https://github.test/reviewer',
                        'avatarUrl': null,
                      },
                    },
                    {'id': 'R2', 'state': 'PENDING', 'body': ''},
                  ],
                  'pageInfo': {'hasNextPage': false},
                },
                'comments': {
                  'nodes': [
                    {
                      'id': 'C1',
                      'body':
                          '![shot](https://github.com/user-attachments/assets/raw)',
                      'bodyHTML':
                          '<img src="https://private-user-images.githubusercontent.com/rendered">',
                      'url': 'https://github.test/comments/1',
                      'createdAt': '2026-07-27T00:00:01Z',
                      'author': null,
                    },
                    {'id': 'TC1', 'body': 'duplicate thread comment'},
                  ],
                  'pageInfo': {'hasNextPage': true},
                },
                'reviewThreads': {
                  'nodes': [
                    {
                      'id': 'T1',
                      'path': 'lib/main.dart',
                      'line': 12,
                      'startLine': 10,
                      'isResolved': true,
                      'isOutdated': false,
                      'comments': {
                        'nodes': [
                          {
                            'id': 'TC1',
                            'body': 'inline',
                            'bodyHTML': '<p>inline</p>',
                            'url': 'https://github.test/comments/2',
                            'createdAt': '2026-07-27T00:00:03Z',
                            'author': {'login': 'octo'},
                            'pullRequestReview': {'id': 'R1'},
                          },
                        ],
                        'pageInfo': {'hasNextPage': false},
                      },
                    },
                  ],
                  'pageInfo': {'hasNextPage': false},
                },
              },
            },
          },
        });
      });

      final timeline = await GitHubForgeStatusAdapter(transport)
          .getPullRequestTimeline(
            cwd: '.',
            prNumber: 42,
            repositoryOwner: 'acme',
            repositoryName: 'repo',
          );

      expect(timeline.error, isNull);
      expect(timeline.truncated, isTrue);
      expect(timeline.items.map((item) => item.id), ['C1', 'R1', 'TC1']);
      expect(
        timeline.items.first.body,
        contains('private-user-images.githubusercontent.com'),
      );
      final inline = timeline.items.last as PullRequestTimelineComment;
      expect(inline.reviewId, 'R1');
      expect(inline.location?.path, 'lib/main.dart');
      expect(inline.location?.threadId, 'T1');
      expect(inline.location?.isResolved, isTrue);
    },
  );

  test('GitHub returns typed not-found and command errors', () async {
    final missing =
        await GitHubForgeStatusAdapter(
          _FakeTransport(
            (_, _) => _json({
              'data': {
                'repository': {'pullRequest': null},
              },
            }),
          ),
        ).getPullRequestTimeline(
          cwd: '.',
          prNumber: 1,
          repositoryOwner: 'acme',
          repositoryName: 'repo',
        );
    expect(missing.error?.kind, PullRequestTimelineErrorKind.notFound);

    final forbidden =
        await GitHubForgeStatusAdapter(
          _FakeTransport((_, _) => _fail('HTTP 403 forbidden')),
        ).getPullRequestTimeline(
          cwd: '.',
          prNumber: 1,
          repositoryOwner: 'acme',
          repositoryName: 'repo',
        );
    expect(forbidden.error?.kind, PullRequestTimelineErrorKind.forbidden);
  });

  test(
    'GitLab maps discussion threads and probes an exactly full page',
    () async {
      final discussions = [
        for (var index = 0; index < 100; index++)
          {
            'id': 'D$index',
            'individual_note': index != 0,
            'notes': [
              {
                'id': index + 1,
                'body': 'note $index',
                'system': index == 99,
                'created_at': '2026-07-27T00:00:00Z',
                'author': {'username': 'gitlab-user'},
                if (index == 0) ...{
                  'resolvable': true,
                  'resolved': false,
                  'position': {
                    'new_path': 'lib/a.dart',
                    'new_line': 9,
                    'line_range': {
                      'start': {'new_line': 7},
                    },
                  },
                },
              },
            ],
          },
      ];
      final transport = _FakeTransport((_, args) {
        if (args.take(2).join(' ') == 'mr view') {
          return _json({
            'iid': 9,
            'web_url': 'https://gitlab.test/acme/repo/-/merge_requests/9',
            'references': {'full': 'acme/sub/repo!9'},
          });
        }
        if (args
            .singleWhere((arg) => arg.contains('discussions'))
            .contains('page=101')) {
          return _json([]);
        }
        return _json(discussions);
      });

      final timeline = await GitLabForgeStatusAdapter(transport)
          .getPullRequestTimeline(
            cwd: '.',
            prNumber: 9,
            repositoryOwner: 'ignored',
            repositoryName: 'ignored',
          );

      expect(timeline.error, isNull);
      expect(timeline.truncated, isFalse);
      expect(timeline.items, hasLength(99));
      final first = timeline.items.first as PullRequestTimelineComment;
      expect(first.threadId, 'D0');
      expect(first.location?.path, 'lib/a.dart');
      expect(first.location?.startLine, 7);
      expect(first.location?.isResolved, isFalse);
      expect(
        transport.calls.last.$2.singleWhere(
          (arg) => arg.contains('discussions'),
        ),
        contains('per_page=1&page=101'),
      );
    },
  );

  test(
    'Gitea combines issue comments, reviews, and inline review comments',
    () async {
      final transport = _FakeTransport((_, args) {
        final joined = args.join(' ');
        if (joined == 'pr 5 -o json') {
          return _json({'url': 'https://codeberg.org/acme/repo/pulls/5'});
        }
        if (joined.contains('issues/5/comments')) {
          return _json([
            {
              'id': 1,
              'type': 'comment',
              'body': 'general',
              'created_at': '2026-07-27T00:00:01Z',
              'user': {'login': 'alice'},
            },
            {'id': 2, 'type': 'label', 'body': 'system'},
          ]);
        }
        if (joined.contains('reviews/7/comments')) {
          return _json([
            {
              'id': 8,
              'body': 'inline',
              'pull_request_review_id': 7,
              'path': 'lib/a.dart',
              'position': 11,
              'resolver': {'login': 'maintainer'},
              'created_at': '2026-07-27T00:00:03Z',
              'user': {'full_name': 'Bob'},
            },
          ]);
        }
        if (joined.contains('pulls/5/reviews')) {
          return _json([
            {
              'id': 7,
              'state': 'REQUEST_CHANGES',
              'body': 'Needs work',
              'comments_count': 1,
              'submitted_at': '2026-07-27T00:00:02Z',
              'user': {'login': 'reviewer'},
            },
          ]);
        }
        throw StateError('unexpected $joined');
      });

      final timeline =
          await GiteaForgeStatusAdapter(
            transport,
            forge: 'codeberg',
          ).getPullRequestTimeline(
            cwd: '.',
            prNumber: 5,
            repositoryOwner: 'acme',
            repositoryName: 'repo',
          );

      expect(timeline.error, isNull);
      expect(timeline.items.map((item) => item.id), ['1', '7', '8']);
      expect(
        (timeline.items[1] as PullRequestTimelineReview).reviewState,
        PullRequestTimelineReviewState.changesRequested,
      );
      final inline = timeline.items.last as PullRequestTimelineComment;
      expect(inline.reviewId, '7');
      expect(inline.location?.threadId, 'lib/a.dart#pos-11');
      expect(inline.location?.isResolved, isTrue);
    },
  );

  test(
    'Gitea keeps one successful bucket and classifies dual failure',
    () async {
      final partial =
          await GiteaForgeStatusAdapter(
            _FakeTransport((_, args) {
              final joined = args.join(' ');
              if (joined == 'pr 2 -o json') return _json({'url': 'pr'});
              if (joined.contains('issues/2/comments')) {
                return _json([
                  {'id': 1, 'body': 'kept'},
                ]);
              }
              return _fail('reviews unavailable');
            }),
            forge: 'gitea',
          ).getPullRequestTimeline(
            cwd: '.',
            prNumber: 2,
            repositoryOwner: 'a',
            repositoryName: 'b',
          );
      expect(partial.error, isNull);
      expect(partial.items.single.id, '1');

      final failed =
          await GiteaForgeStatusAdapter(
            _FakeTransport((_, args) {
              if (args.join(' ') == 'pr 2 -o json') return _json({'url': 'pr'});
              return _fail('404 not found');
            }),
            forge: 'gitea',
          ).getPullRequestTimeline(
            cwd: '.',
            prNumber: 2,
            repositoryOwner: 'a',
            repositoryName: 'b',
          );
      expect(failed.error?.kind, PullRequestTimelineErrorKind.notFound);
    },
  );
}

ForgeCommandResult _json(Object? value) =>
    ForgeCommandResult(exitCode: 0, stdout: jsonEncode(value), stderr: '');

ForgeCommandResult _fail(String value) =>
    ForgeCommandResult(exitCode: 1, stdout: '', stderr: value);

typedef _Handler =
    ForgeCommandResult Function(String executable, List<String> args);

final class _FakeTransport implements ForgeCommandTransport {
  _FakeTransport(this.handler);
  final _Handler handler;
  final List<(String, List<String>)> calls = [];

  @override
  Future<ForgeCommandResult> run(
    String executable,
    List<String> args, {
    required String cwd,
    Map<String, String> environment = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((executable, List.unmodifiable(args)));
    return handler(executable, args);
  }
}
