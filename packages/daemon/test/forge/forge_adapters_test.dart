import 'dart:convert';

import 'package:agent_daemon/src/forge/forge_adapters.dart';
import 'package:agent_daemon/src/forge/forge_cli.dart';
import 'package:agent_daemon/src/forge/forge_models.dart';
import 'package:agent_daemon/src/forge/git_remote.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('git remote parsing', () {
    test('matches Paseo URL and scp normalization', () {
      expect(
        parseGitRemoteLocation('git@GitHub.com:owner/repo.git'),
        isNotNull,
      );
      final scp = parseGitRemoteLocation('git@GitHub.com:owner/repo.git')!;
      expect(scp.transport, 'scp');
      expect(scp.host, 'github.com');
      expect(scp.path, 'owner/repo');

      final https = parseGitRemoteLocation(
        'https://GitLab.com/group/sub/repo.git/',
      )!;
      expect(https.transport, 'https');
      expect(https.host, 'gitlab.com');
      expect(https.path, 'group/sub/repo');

      expect(
        parseGitRemoteLocation('ssh://git@codeberg.org/owner/repo.git')?.path,
        'owner/repo',
      );
      expect(forgeForKnownHost('GITHUB.COM.'), 'github');
      expect(forgeForKnownHost('gitlab.com'), 'gitlab');
      expect(forgeForKnownHost('gitea.com'), 'gitea');
      expect(forgeForKnownHost('codeberg.org'), 'codeberg');
    });

    test('rejects unsupported, malformed, and empty remotes', () {
      expect(parseGitRemoteLocation(''), isNull);
      expect(parseGitRemoteLocation('owner/repo'), isNull);
      expect(parseGitRemoteLocation('git://github.com/owner/repo'), isNull);
      expect(parseGitRemoteLocation('https://bad host/repo'), isNull);
      expect(parseGitRemoteLocation('git@:repo'), isNull);
      expect(forgeForKnownHost('example.com'), isNull);
    });
  });

  group('neutral models', () {
    test('computes exact check aggregate priority and wire values', () {
      const success = ForgeCheck(
        name: 'build',
        status: ForgeCheckStatus.success,
        url: null,
      );
      const pending = ForgeCheck(
        name: 'test',
        status: ForgeCheckStatus.pending,
        url: 'https://checks/1',
        workflow: 'CI',
        duration: '1m 2s',
      );
      const failure = ForgeCheck(
        name: 'lint',
        status: ForgeCheckStatus.failure,
        url: null,
      );
      expect(computeForgeChecksStatus([]), ForgeChecksStatus.none);
      expect(computeForgeChecksStatus([success]), ForgeChecksStatus.success);
      expect(
        computeForgeChecksStatus([success, pending]),
        ForgeChecksStatus.pending,
      );
      expect(
        computeForgeChecksStatus([pending, failure]),
        ForgeChecksStatus.failure,
      );
      expect(pending.toJson(), {
        'name': 'test',
        'status': 'pending',
        'url': 'https://checks/1',
        'workflow': 'CI',
        'duration': '1m 2s',
      });
      expect(ForgeAuthState.cliMissing.wireName, 'cli_missing');
      expect(
        ForgeReviewDecision.changesRequested.wireName,
        'changes_requested',
      );
      expect(ForgeMergeable.conflicting.wireName, 'CONFLICTING');
    });

    test('projects available and unavailable workspace snapshots', () {
      final now = DateTime.utc(2026, 7, 27);
      final unavailable = WorkspaceForgeSnapshot.unavailable(
        ForgeAuthState.unauthenticated,
        forge: 'gitlab',
        error: 'login',
        now: now,
      );
      expect(unavailable.toGithubRuntimeJson(), {
        'featuresEnabled': false,
        'pullRequest': null,
        'error': {'message': 'login'},
        'refreshedAt': '2026-07-27T00:00:00.000Z',
      });
    });
  });

  group('GitHub adapter', () {
    test('normalizes open status, checks, review, and identity', () async {
      final transport = _FakeTransport((executable, args) {
        if (args.take(2).join(' ') == 'auth status') {
          return _ok('');
        }
        return _json([
          {
            'number': 42,
            'url': 'https://github.com/acme/repo/pull/42',
            'title': 'Feature',
            'state': 'OPEN',
            'isDraft': true,
            'baseRefName': 'main',
            'headRefName': 'feature',
            'headRefOid': 'abc',
            'mergedAt': null,
            'reviewDecision': 'CHANGES_REQUESTED',
            'mergeable': 'CONFLICTING',
            'headRepositoryOwner': {'login': 'acme'},
            'statusCheckRollup': [
              {
                '__typename': 'CheckRun',
                'name': 'build',
                'conclusion': 'SUCCESS',
                'status': 'COMPLETED',
                'detailsUrl': 'https://checks/build',
                'workflowName': 'CI',
                'startedAt': '2026-07-27T00:00:00Z',
                'completedAt': '2026-07-27T00:01:02Z',
              },
              {
                '__typename': 'StatusContext',
                'context': 'deploy',
                'state': 'PENDING',
                'targetUrl': 'https://checks/deploy',
              },
            ],
          },
        ]);
      });
      final adapter = GitHubForgeStatusAdapter(transport);

      expect(
        await adapter.isAuthenticated(cwd: '.', host: 'github.com'),
        isTrue,
      );
      final status = await adapter.getCurrentPullRequestStatus(
        cwd: '.',
        headRef: 'feature',
        headSha: 'abc',
        headRepositoryOwner: 'acme',
      );
      expect(status?.number, 42);
      expect(status?.repoOwner, 'acme');
      expect(status?.repoName, 'repo');
      expect(status?.state, 'open');
      expect(status?.isDraft, isTrue);
      expect(status?.mergeable, ForgeMergeable.conflicting);
      expect(status?.reviewDecision, ForgeReviewDecision.changesRequested);
      expect(status?.checksStatus, ForgeChecksStatus.pending);
      expect(status?.checks.first.duration, '1m 2s');
      expect(status?.checks.last.name, 'deploy');
      expect(status?.toJson()['checks'], hasLength(2));
    });

    test(
      'loads exact GitHub merge-policy facts after resolving the PR',
      () async {
        final transport = _FakeTransport((_, args) {
          if (args.take(2).join(' ') == 'api graphql') {
            return _json({
              'data': {
                'repository': {
                  'autoMergeAllowed': true,
                  'mergeCommitAllowed': false,
                  'squashMergeAllowed': true,
                  'rebaseMergeAllowed': true,
                  'viewerDefaultMergeMethod': 'SQUASH',
                  'pullRequest': {
                    'mergeStateStatus': 'CLEAN',
                    'autoMergeRequest': {
                      'enabledAt': '2026-07-27T00:00:00Z',
                      'mergeMethod': 'SQUASH',
                      'enabledBy': {'login': 'octocat'},
                    },
                    'viewerCanEnableAutoMerge': true,
                    'viewerCanDisableAutoMerge': true,
                    'viewerCanMergeAsAdmin': false,
                    'viewerCanUpdateBranch': true,
                    'isMergeQueueEnabled': false,
                    'isInMergeQueue': false,
                  },
                },
              },
            });
          }
          return _json([_githubRow(state: 'OPEN', sha: 'abc', number: 42)]);
        });
        final status = await GitHubForgeStatusAdapter(
          transport,
        ).getCurrentPullRequestStatus(cwd: '.', headRef: 'feature');

        expect(status?.forgeSpecific, {
          'forge': 'github',
          'mergeStateStatus': 'CLEAN',
          'autoMergeRequest': {
            'enabledAt': '2026-07-27T00:00:00Z',
            'mergeMethod': 'SQUASH',
            'enabledBy': 'octocat',
          },
          'viewerCanEnableAutoMerge': true,
          'viewerCanDisableAutoMerge': true,
          'viewerCanMergeAsAdmin': false,
          'viewerCanUpdateBranch': true,
          'repository': {
            'autoMergeAllowed': true,
            'mergeCommitAllowed': false,
            'squashMergeAllowed': true,
            'rebaseMergeAllowed': true,
            'viewerDefaultMergeMethod': 'SQUASH',
          },
          'isMergeQueueEnabled': false,
          'isInMergeQueue': false,
        });
        final graphql = transport.calls.singleWhere(
          (call) => call.$2.take(2).join(' ') == 'api graphql',
        );
        expect(
          graphql.$2,
          containsAll(['owner=acme', 'name=repo', 'number=42']),
        );
        expect(
          graphql.$2.singleWhere((argument) => argument.startsWith('query=')),
          contains('isMergeQueueEnabled'),
        );
      },
    );

    test(
      'defaults missing GitHub facts and keeps status when facts cannot load',
      () async {
        var factsFail = false;
        final transport = _FakeTransport((_, args) {
          if (args.take(2).join(' ') == 'api graphql') {
            if (factsFail) return _fail('GraphQL denied');
            return _json({
              'data': {
                'repository': {'pullRequest': <String, Object?>{}},
              },
            });
          }
          return _json([_githubRow(state: 'OPEN', sha: 'abc', number: 42)]);
        });
        final adapter = GitHubForgeStatusAdapter(transport);
        final withDefaults = await adapter.getCurrentPullRequestStatus(
          cwd: '.',
          headRef: 'feature',
        );
        expect(withDefaults?.forgeSpecific, {
          'forge': 'github',
          'mergeStateStatus': null,
          'autoMergeRequest': null,
          'viewerCanEnableAutoMerge': false,
          'viewerCanDisableAutoMerge': false,
          'viewerCanMergeAsAdmin': false,
          'viewerCanUpdateBranch': false,
          'repository': {
            'autoMergeAllowed': false,
            'mergeCommitAllowed': false,
            'squashMergeAllowed': false,
            'rebaseMergeAllowed': false,
            'viewerDefaultMergeMethod': null,
          },
          'isMergeQueueEnabled': false,
          'isInMergeQueue': false,
        });

        factsFail = true;
        final degraded = await adapter.getCurrentPullRequestStatus(
          cwd: '.',
          headRef: 'feature',
        );
        expect(degraded?.number, 42);
        expect(degraded?.forgeSpecific, isNull);
      },
    );

    test('does not attach a stale closed PR to a reused branch', () async {
      final transport = _FakeTransport(
        (_, _) => _json([
          _githubRow(state: 'CLOSED', sha: 'old', number: 1),
          _githubRow(state: 'MERGED', sha: 'matching', number: 2),
        ]),
      );
      final adapter = GitHubForgeStatusAdapter(transport);
      expect(
        await adapter.getCurrentPullRequestStatus(
          cwd: '.',
          headRef: 'feature',
          headSha: 'new',
          repositoryOwner: 'acme',
          repositoryName: 'repo',
        ),
        isNull,
      );
      final matched = await adapter.getCurrentPullRequestStatus(
        cwd: '.',
        headRef: 'feature',
        headSha: 'matching',
      );
      expect(matched?.number, 2);
      expect(matched?.state, 'merged');
    });

    test('prefers open PR and rejects a different fork owner', () async {
      final transport = _FakeTransport(
        (_, _) => _json([
          _githubRow(state: 'OPEN', sha: 'open', number: 3, owner: 'fork'),
          _githubRow(state: 'CLOSED', sha: 'closed', number: 4),
        ]),
      );
      final adapter = GitHubForgeStatusAdapter(transport);
      expect(
        await adapter.getCurrentPullRequestStatus(
          cwd: '.',
          headRef: 'feature',
          headRepositoryOwner: 'other',
        ),
        isNull,
      );
    });

    test('retries without statusCheckRollup on permission failure', () async {
      var calls = 0;
      final transport = _FakeTransport((_, args) {
        calls += 1;
        if (calls == 1) {
          return _fail(
            'GraphQL: Resource not accessible: statusCheckRollup permission',
          );
        }
        expect(args.last, isNot(contains('statusCheckRollup')));
        return _json([_githubRow(state: 'OPEN', sha: 'abc', number: 5)]);
      });
      final status = await GitHubForgeStatusAdapter(
        transport,
      ).getCurrentPullRequestStatus(cwd: '.', headRef: 'feature');
      expect(status?.number, 5);
      expect(calls, 3);
      expect(transport.calls[2].$2.take(2), ['api', 'graphql']);
    });
  });

  group('GitLab adapter', () {
    test('normalizes MR status and native pipeline facts', () async {
      final transport = _FakeTransport((_, args) {
        if (args.first == 'auth') return _ok('');
        if (args[1] == 'list') {
          return _json([
            {
              'iid': 9,
              'source_branch': 'feature',
              'state': 'opened',
              'sha': 'abc',
            },
          ]);
        }
        return _json({
          'iid': 9,
          'source_branch': 'feature',
          'target_branch': 'main',
          'state': 'opened',
          'sha': 'abc',
          'web_url': 'https://gitlab.com/group/sub/repo/-/merge_requests/9',
          'title': 'MR',
          'draft': false,
          'work_in_progress': false,
          'merged_at': null,
          'references': {'full': 'group/sub/repo!9'},
          'detailed_merge_status': 'mergeable',
          'merge_status': 'can_be_merged',
          'has_conflicts': false,
          'blocking_discussions_resolved': true,
          'approvals_required': 2,
          'approvals_given': 1,
          'head_pipeline': {
            'id': 12,
            'status': 'running',
            'web_url': 'https://gitlab/pipeline/12',
          },
          'merge_when_pipeline_succeeds': true,
        });
      });
      final adapter = GitLabForgeStatusAdapter(transport);
      expect(
        await adapter.isAuthenticated(cwd: '.', host: 'gitlab.com'),
        isTrue,
      );
      final status = await adapter.getCurrentPullRequestStatus(
        cwd: '.',
        headRef: 'feature',
        headSha: 'abc',
      );
      expect(status?.projectPath, 'group/sub/repo');
      expect(status?.repoOwner, 'group/sub');
      expect(status?.checksStatus, ForgeChecksStatus.pending);
      expect(status?.mergeable, ForgeMergeable.mergeable);
      expect(status?.forgeSpecific?['pipelineId'], 12);
      expect(status?.forgeSpecific?['approvalsRequired'], 2);
    });

    test('uses SHA for terminal MR and validates positional refs', () async {
      final transport = _FakeTransport((_, args) {
        if (args[1] == 'list') {
          return _json([
            {
              'iid': 8,
              'source_branch': 'feature',
              'state': 'merged',
              'sha': 'old',
            },
            {
              'iid': 9,
              'source_branch': 'feature',
              'state': 'closed',
              'sha': 'head',
            },
          ]);
        }
        return _json(_gitLabView(iid: 9, state: 'closed'));
      });
      final adapter = GitLabForgeStatusAdapter(transport);
      expect(
        await adapter.getCurrentPullRequestStatus(
          cwd: '.',
          headRef: 'feature',
          headSha: 'missing',
        ),
        isNull,
      );
      expect(
        (await adapter.getCurrentPullRequestStatus(
          cwd: '.',
          headRef: 'feature',
          headSha: 'head',
        ))?.number,
        9,
      );
      expect(
        () => adapter.getCurrentPullRequestStatus(cwd: '.', headRef: '-bad'),
        throwsArgumentError,
      );
    });

    test('auth failures return false while a missing CLI stays classified', () {
      final auth = GitLabForgeStatusAdapter(
        _FakeTransport((_, _) => _fail('401 unauthorized')),
      );
      expect(
        auth.isAuthenticated(cwd: '.', host: 'gitlab.com'),
        completion(isFalse),
      );
      final missing = GitLabForgeStatusAdapter(
        _FakeTransport((_, _) => throw const ForgeCliMissingException('glab')),
      );
      expect(
        missing.isAuthenticated(cwd: '.', host: 'gitlab.com'),
        throwsA(isA<ForgeCliMissingException>()),
      );
    });
  });

  group('Gitea-family adapter', () {
    test('auth matches URL, SSH host, and login name', () async {
      final transport = _FakeTransport(
        (_, _) => _json([
          {
            'name': 'work',
            'url': 'https://forge.example.com',
            'ssh_host': 'ssh.forge.example.com',
          },
        ]),
      );
      final adapter = GiteaForgeStatusAdapter(transport, forge: 'forgejo');
      expect(
        await adapter.isAuthenticated(cwd: '.', host: 'forge.example.com'),
        isTrue,
      );
      expect(
        await adapter.isAuthenticated(cwd: '.', host: 'ssh.forge.example.com'),
        isTrue,
      );
      expect(await adapter.isAuthenticated(cwd: '.', host: 'work'), isTrue);
      expect(
        await adapter.isAuthenticated(cwd: '.', host: 'other.example.com'),
        isFalse,
      );
    });

    test('normalizes open PR and Gitea facts for every family brand', () async {
      final transport = _FakeTransport(
        (_, _) => _json([
          {
            'index': 7,
            'title': 'Forge PR',
            'state': 'open',
            'url': 'https://codeberg.org/acme/repo/pulls/7',
            'base': {'ref': 'main'},
            'head': {'label': 'acme:feature'},
            'head_sha': 'abc',
            'mergeable': true,
            'has_merged': false,
            'draft': false,
            'ci': 'success',
          },
        ]),
      );
      final status = await GiteaForgeStatusAdapter(transport, forge: 'codeberg')
          .getCurrentPullRequestStatus(
            cwd: '.',
            headRef: 'feature',
            headSha: 'abc',
            headRepositoryOwner: 'acme',
          );
      expect(status?.number, 7);
      expect(status?.repoOwner, 'acme');
      expect(status?.repoName, 'repo');
      expect(status?.baseRefName, 'main');
      expect(status?.mergeable, ForgeMergeable.mergeable);
      expect(status?.checksStatus, ForgeChecksStatus.success);
      expect(status?.forgeSpecific?['forge'], 'gitea');
      expect(
        transport.calls.single.$2,
        containsAllInOrder([
          'pr',
          'list',
          '--fields',
          'index,state,author,url,title,body,mergeable,base,head,created,updated,labels,comments,ci',
          '--state',
          'open',
        ]),
      );
    });

    test('terminal PR must match head SHA and owner', () async {
      final transport = _FakeTransport(
        (_, args) => args.first == 'pr'
            ? _json([])
            : _json([
                {
                  'number': 7,
                  'title': 'Old',
                  'state': 'closed',
                  'html_url': 'https://gitea.com/acme/repo/pulls/7',
                  'base': {'ref': 'main'},
                  'head': {
                    'ref': 'feature',
                    'sha': 'old',
                    'repo': {
                      'owner': {'login': 'acme'},
                    },
                  },
                  'mergeable': false,
                  'merged': false,
                  'ci': 'failure',
                },
              ]),
      );
      final adapter = GiteaForgeStatusAdapter(transport, forge: 'gitea');
      expect(
        await adapter.getCurrentPullRequestStatus(
          cwd: '.',
          headRef: 'feature',
          headSha: 'new',
          repositoryOwner: 'acme',
          repositoryName: 'repo',
        ),
        isNull,
      );
      expect(
        await adapter.getCurrentPullRequestStatus(
          cwd: '.',
          headRef: 'feature',
          headSha: 'old',
          headRepositoryOwner: 'other',
          repositoryOwner: 'acme',
          repositoryName: 'repo',
        ),
        isNull,
      );
      expect(transport.calls.where((call) => call.$2.first == 'api').length, 2);
    });
  });

  group('forge create and guarded direct merge', () {
    test(
      'GitHub uses the exact API shape and enforces repository policy',
      () async {
        final transport = _FakeTransport((_, args) {
          if (args.take(3).join(' ') == 'api -X POST') {
            return _json({
              'url': 'https://github.com/acme/repo/pull/8',
              'number': 8,
            });
          }
          return _ok('');
        });
        final adapter = GitHubForgeStatusAdapter(transport);
        final created = await adapter.createPullRequest(
          cwd: '.',
          title: 'Feature',
          body: 'Body',
          head: 'feature',
          base: 'main',
          repositoryOwner: 'acme',
          repositoryName: 'repo',
        );
        expect(created.number, 8);
        expect(transport.calls.first.$2, [
          'api',
          '-X',
          'POST',
          'repos/acme/repo/pulls',
          '-f',
          'title=Feature',
          '-f',
          'head=feature',
          '-f',
          'base=main',
          '-f',
          'body=Body',
        ]);

        await adapter.mergePullRequest(
          cwd: '.',
          number: 8,
          mergeMethod: CheckoutPrMergeMethod.squash,
          status: _mergeStatus({
            'forge': 'github',
            'mergeStateStatus': 'HAS_HOOKS',
            'autoMergeRequest': null,
            'isMergeQueueEnabled': false,
            'isInMergeQueue': false,
            'repository': {
              'mergeCommitAllowed': false,
              'squashMergeAllowed': true,
              'rebaseMergeAllowed': false,
            },
          }),
        );
        expect(transport.calls.last.$2, ['pr', 'merge', '8', '--squash']);

        expect(
          adapter.mergePullRequest(
            cwd: '.',
            number: 8,
            mergeMethod: CheckoutPrMergeMethod.merge,
            status: _mergeStatus({
              'forge': 'github',
              'mergeStateStatus': 'CLEAN',
              'autoMergeRequest': null,
              'isMergeQueueEnabled': false,
              'isInMergeQueue': false,
              'repository': {
                'mergeCommitAllowed': false,
                'squashMergeAllowed': true,
                'rebaseMergeAllowed': false,
              },
            }),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'GitLab parses create output and prevents accidental auto-merge',
      () async {
        final transport = _FakeTransport(
          (_, args) => args.take(2).join(' ') == 'mr create'
              ? _ok(
                  'Creating merge request...\n'
                  'https://gitlab.com/acme/repo/-/merge_requests/12\n',
                )
              : _ok(''),
        );
        final adapter = GitLabForgeStatusAdapter(transport);
        final created = await adapter.createPullRequest(
          cwd: '.',
          title: 'Feature',
          body: '',
          head: 'feature',
          base: 'main',
          repositoryOwner: 'acme',
          repositoryName: 'repo',
        );
        expect(created.number, 12);
        await adapter.mergePullRequest(
          cwd: '.',
          number: 12,
          mergeMethod: CheckoutPrMergeMethod.rebase,
          status: _mergeStatus({
            'forge': 'gitlab',
            'detailedMergeStatus': 'mergeable',
            'mergeStatus': null,
            'hasConflicts': false,
            'mergeWhenPipelineSucceeds': false,
          }),
        );
        expect(transport.calls.last.$2, [
          'mr',
          'merge',
          '12',
          '--auto-merge=false',
          '--yes',
          '--rebase',
        ]);
        expect(
          adapter.mergePullRequest(
            cwd: '.',
            number: 12,
            mergeMethod: CheckoutPrMergeMethod.merge,
            status: _mergeStatus({
              'forge': 'gitlab',
              'detailedMergeStatus': 'mergeable',
              'mergeWhenPipelineSucceeds': true,
            }),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'Gitea family parses create output and requires unmerged facts',
      () async {
        final transport = _FakeTransport(
          (_, args) => args.take(2).join(' ') == 'pr create'
              ? _ok('https://codeberg.org/acme/repo/pulls/4')
              : _ok(''),
        );
        final adapter = GiteaForgeStatusAdapter(transport, forge: 'codeberg');
        final created = await adapter.createPullRequest(
          cwd: '.',
          title: 'Feature',
          body: 'Body',
          head: 'feature',
          base: 'main',
          repositoryOwner: 'acme',
          repositoryName: 'repo',
        );
        expect(created.number, 4);
        await adapter.mergePullRequest(
          cwd: '.',
          number: 4,
          mergeMethod: CheckoutPrMergeMethod.merge,
          status: _mergeStatus({
            'forge': 'gitea',
            'mergeable': true,
            'hasMerged': false,
          }),
        );
        expect(transport.calls.last.$2, [
          'pr',
          'merge',
          '4',
          '--style',
          'merge',
        ]);
        expect(
          adapter.mergePullRequest(
            cwd: '.',
            number: 4,
            mergeMethod: CheckoutPrMergeMethod.merge,
            status: _mergeStatus({
              'forge': 'gitea',
              'mergeable': true,
              'hasMerged': true,
            }),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('GitHub auto-merge uses exact commands and guards', () async {
      final transport = _FakeTransport((_, _) => _ok(''));
      final adapter = GitHubForgeStatusAdapter(transport);
      await adapter.enablePullRequestAutoMerge(
        cwd: '.',
        number: 8,
        mergeMethod: CheckoutPrMergeMethod.squash,
        status: _mergeStatus({
          'forge': 'github',
          'mergeStateStatus': 'BLOCKED',
          'autoMergeRequest': null,
          'viewerCanEnableAutoMerge': true,
          'isMergeQueueEnabled': false,
          'isInMergeQueue': false,
          'repository': {
            'autoMergeAllowed': true,
            'mergeCommitAllowed': false,
            'squashMergeAllowed': true,
            'rebaseMergeAllowed': false,
          },
        }),
      );
      expect(transport.calls.last.$2, [
        'pr',
        'merge',
        '8',
        '--auto',
        '--squash',
      ]);
      await adapter.disablePullRequestAutoMerge(
        cwd: '.',
        number: 8,
        status: _mergeStatus({
          'forge': 'github',
          'autoMergeRequest': {'mergeMethod': 'SQUASH'},
          'viewerCanDisableAutoMerge': true,
          'isMergeQueueEnabled': false,
          'isInMergeQueue': false,
        }),
      );
      expect(transport.calls.last.$2, ['pr', 'merge', '8', '--disable-auto']);

      for (final facts in [
        {'forge': 'github', 'mergeStateStatus': 'CLEAN'},
        {
          'forge': 'github',
          'mergeStateStatus': 'BLOCKED',
          'viewerCanEnableAutoMerge': false,
        },
        {
          'forge': 'github',
          'mergeStateStatus': 'BLOCKED',
          'viewerCanEnableAutoMerge': true,
          'repository': {'autoMergeAllowed': false},
        },
      ]) {
        expect(
          adapter.enablePullRequestAutoMerge(
            cwd: '.',
            number: 8,
            mergeMethod: CheckoutPrMergeMethod.merge,
            status: _mergeStatus(facts),
          ),
          throwsA(isA<StateError>()),
        );
      }
    });

    test('GitLab auto-merge requires a pipeline and cancels via API', () async {
      final transport = _FakeTransport((_, _) => _ok(''));
      final adapter = GitLabForgeStatusAdapter(transport);
      await adapter.enablePullRequestAutoMerge(
        cwd: '.',
        number: 12,
        mergeMethod: CheckoutPrMergeMethod.rebase,
        status: _mergeStatus({
          'forge': 'gitlab',
          'mergeWhenPipelineSucceeds': false,
          'pipelineStatus': 'running',
        }),
      );
      expect(transport.calls.last.$2, [
        'mr',
        'merge',
        '12',
        '--auto-merge',
        '--yes',
        '--rebase',
      ]);
      await adapter.disablePullRequestAutoMerge(
        cwd: '.',
        number: 12,
        status: _mergeStatus({
          'forge': 'gitlab',
          'mergeWhenPipelineSucceeds': true,
        }),
      );
      expect(transport.calls.last.$2, [
        'api',
        '--method',
        'POST',
        'projects/:fullpath/merge_requests/12/cancel_merge_when_pipeline_succeeds',
      ]);
      expect(
        adapter.enablePullRequestAutoMerge(
          cwd: '.',
          number: 12,
          mergeMethod: CheckoutPrMergeMethod.merge,
          status: _mergeStatus({
            'forge': 'gitlab',
            'mergeWhenPipelineSucceeds': false,
            'pipelineStatus': 'success',
          }),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('Gitea family reports auto-merge as unsupported', () {
      final adapter = GiteaForgeStatusAdapter(
        _FakeTransport((_, _) => _ok('')),
        forge: 'forgejo',
      );
      final status = _mergeStatus({
        'forge': 'gitea',
        'mergeable': true,
        'hasMerged': false,
      });
      expect(
        () => adapter.enablePullRequestAutoMerge(
          cwd: '.',
          number: 1,
          mergeMethod: CheckoutPrMergeMethod.merge,
          status: status,
        ),
        throwsUnsupportedError,
      );
      expect(
        () => adapter.disablePullRequestAutoMerge(
          cwd: '.',
          number: 1,
          status: status,
        ),
        throwsUnsupportedError,
      );
    });

    test('forge action guards reject every unsafe fact family', () async {
      final github = GitHubForgeStatusAdapter(
        _FakeTransport((_, _) => _ok('')),
      );
      final enabledBase = {
        'forge': 'github',
        'mergeStateStatus': 'BLOCKED',
        'autoMergeRequest': null,
        'viewerCanEnableAutoMerge': true,
        'isMergeQueueEnabled': false,
        'isInMergeQueue': false,
        'repository': {
          'autoMergeAllowed': true,
          'mergeCommitAllowed': true,
          'squashMergeAllowed': true,
          'rebaseMergeAllowed': false,
        },
      };
      for (final status in [
        _mergeStatus({'forge': 'gitlab'}),
        _mergeStatus({
          ...enabledBase,
          'repository': {
            ...(enabledBase['repository']! as Map),
            'mergeCommitAllowed': false,
          },
        }),
        _mergeStatus({...enabledBase, 'autoMergeRequest': const {}}),
        _mergeStatus({...enabledBase, 'isMergeQueueEnabled': true}),
        _mergeStatus(enabledBase, mergeable: ForgeMergeable.conflicting),
      ]) {
        expect(
          github.enablePullRequestAutoMerge(
            cwd: '.',
            number: 1,
            mergeMethod: CheckoutPrMergeMethod.merge,
            status: status,
          ),
          throwsA(isA<StateError>()),
        );
      }
      for (final status in [
        _mergeStatus({'forge': 'gitlab'}),
        _mergeStatus({'forge': 'github', 'autoMergeRequest': null}),
        _mergeStatus({
          'forge': 'github',
          'autoMergeRequest': const {},
          'viewerCanDisableAutoMerge': false,
        }),
        _mergeStatus({
          'forge': 'github',
          'autoMergeRequest': const {},
          'viewerCanDisableAutoMerge': true,
          'isInMergeQueue': true,
        }),
      ]) {
        expect(
          github.disablePullRequestAutoMerge(
            cwd: '.',
            number: 1,
            status: status,
          ),
          throwsA(isA<StateError>()),
        );
      }
      expect(
        github.mergePullRequest(
          cwd: '.',
          number: 1,
          mergeMethod: CheckoutPrMergeMethod.merge,
          status: _mergeStatus({'forge': 'gitlab'}),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        github.mergePullRequest(
          cwd: '.',
          number: 1,
          mergeMethod: CheckoutPrMergeMethod.merge,
          status: _mergeStatus({
            'forge': 'github',
            'mergeStateStatus': 'CLEAN',
            'autoMergeRequest': null,
            'isMergeQueueEnabled': true,
            'repository': {'mergeCommitAllowed': true},
          }),
        ),
        throwsA(isA<StateError>()),
      );

      final gitlab = GitLabForgeStatusAdapter(
        _FakeTransport((_, _) => _ok('')),
      );
      for (final status in [
        _mergeStatus({'forge': 'github'}),
        _mergeStatus({
          'forge': 'gitlab',
          'detailedMergeStatus': null,
          'mergeStatus': 'cannot_be_merged',
          'hasConflicts': true,
          'mergeWhenPipelineSucceeds': false,
        }),
      ]) {
        expect(
          gitlab.mergePullRequest(
            cwd: '.',
            number: 1,
            mergeMethod: CheckoutPrMergeMethod.merge,
            status: status,
          ),
          throwsA(isA<StateError>()),
        );
      }
      for (final status in [
        _mergeStatus({'forge': 'github'}),
        _mergeStatus({
          'forge': 'gitlab',
          'mergeWhenPipelineSucceeds': true,
          'pipelineStatus': 'running',
        }),
      ]) {
        expect(
          gitlab.enablePullRequestAutoMerge(
            cwd: '.',
            number: 1,
            mergeMethod: CheckoutPrMergeMethod.merge,
            status: status,
          ),
          throwsA(isA<StateError>()),
        );
      }

      final gitea = GiteaForgeStatusAdapter(
        _FakeTransport((_, _) => _ok('')),
        forge: 'gitea',
      );
      for (final status in [
        _mergeStatus({'forge': 'github'}),
        _mergeStatus({
          'forge': 'gitea',
          'mergeable': false,
          'hasMerged': false,
        }),
      ]) {
        expect(
          gitea.mergePullRequest(
            cwd: '.',
            number: 1,
            mergeMethod: CheckoutPrMergeMethod.merge,
            status: status,
          ),
          throwsA(isA<StateError>()),
        );
      }
    });
  });

  group('CLI normalization', () {
    test(
      'classifies auth, command, missing, and malformed JSON failures',
      () async {
        expect(
          runForgeCli(
            _FakeTransport((_, _) => _fail('403 forbidden')),
            'gh',
            const ['x'],
            cwd: '.',
          ),
          throwsA(isA<ForgeAuthenticationException>()),
        );
        expect(
          runForgeCli(_FakeTransport((_, _) => _fail('boom')), 'gh', const [
            'x',
          ], cwd: '.'),
          throwsA(isA<ForgeCommandException>()),
        );
        expect(
          () => decodeForgeJson(
            'not-json',
            executable: 'tea',
            args: const ['x'],
            cwd: '.',
          ),
          throwsA(isA<ForgeCommandException>()),
        );
        expect(const ForgeCliMissingException('gh').toString(), contains('gh'));
      },
    );
  });

  group('forge search', () {
    test(
      'GitHub searches both kinds concurrently and sorts newest first',
      () async {
        final transport = _FakeTransport((executable, args) {
          expect(executable, 'gh');
          if (args.first == 'issue') {
            return _json([
              {
                'number': 1,
                'title': 'Issue',
                'url': 'https://github.com/acme/repo/issues/1',
                'state': 'OPEN',
                'body': null,
                'labels': [
                  {'name': 'bug'},
                ],
                'updatedAt': '2026-07-26T00:00:00Z',
              },
            ]);
          }
          return _json([
            {
              'number': 2,
              'title': 'PR',
              'url': 'https://github.com/acme/repo/pull/2',
              'state': 'OPEN',
              'body': 'body',
              'labels': const [],
              'baseRefName': 'main',
              'headRefName': 'feature',
              'updatedAt': '2026-07-27T00:00:00Z',
            },
          ]);
        });
        final result = await GitHubForgeStatusAdapter(
          transport,
        ).searchIssuesAndPullRequests(cwd: '.', query: 'cache', limit: 5);
        expect(result.authState, ForgeAuthState.authenticated);
        expect(result.items.map((item) => item.number), [2, 1]);
        expect(result.items.first.kind, ForgeSearchKind.changeRequest);
        expect(result.items.first.projectPath, 'acme/repo');
        expect(result.items.first.baseRefName, 'main');
        expect(result.items.last.labels, ['bug']);
        expect(transport.calls, hasLength(2));
        expect(
          transport.calls.first.$2,
          containsAll(['--search', 'cache', '--limit', '5']),
        );
      },
    );

    test(
      'search kind filtering and unavailable auth states are exact',
      () async {
        final onlyIssues = _FakeTransport((_, args) {
          expect(args.first, 'issue');
          return _json([]);
        });
        final filtered = await GitHubForgeStatusAdapter(onlyIssues)
            .searchIssuesAndPullRequests(
              cwd: '.',
              query: '',
              kinds: const [ForgeSearchKind.issue],
            );
        expect(filtered.items, isEmpty);
        expect(onlyIssues.calls, hasLength(1));

        final missing = await GitHubForgeStatusAdapter(
          _FakeTransport((_, _) => throw const ForgeCliMissingException('gh')),
        ).searchIssuesAndPullRequests(cwd: '.', query: '');
        expect(missing.authState, ForgeAuthState.cliMissing);
        expect(missing.featuresEnabled, isFalse);

        final unauthenticated =
            await GitHubForgeStatusAdapter(
              _FakeTransport((_, _) => _fail('401 unauthorized')),
            ).searchIssuesAndPullRequests(
              cwd: '.',
              query: '',
              kinds: const [ForgeSearchKind.changeRequest],
            );
        expect(unauthenticated.authState, ForgeAuthState.unauthenticated);
      },
    );

    test('GitLab uses distinct JSON flags and maps project facts', () async {
      final transport = _FakeTransport((_, args) {
        if (args.first == 'issue') {
          expect(args, containsAllInOrder(['issue', 'list', '-O', 'json']));
          return _json([
            {
              'iid': 3,
              'title': 'Issue',
              'web_url': 'https://gitlab.com/group/repo/-/issues/3',
              'state': 'opened',
              'description': 'desc',
              'labels': ['bug'],
              'updated_at': '2026-07-26T00:00:00Z',
              'references': {'full': 'group/repo#3'},
            },
          ]);
        }
        expect(args, containsAllInOrder(['mr', 'list', '-F', 'json']));
        return _json([
          {
            'iid': 4,
            'title': 'MR',
            'web_url': 'https://gitlab.com/group/repo/-/merge_requests/4',
            'state': 'opened',
            'description': null,
            'labels': const [],
            'target_branch': 'main',
            'source_branch': 'feature',
            'updated_at': '2026-07-27T00:00:00Z',
            'references': {'full': 'group/repo!4'},
          },
        ]);
      });
      final result = await GitLabForgeStatusAdapter(
        transport,
      ).searchIssuesAndPullRequests(cwd: '.', query: 'ship', limit: 10);
      expect(result.items.map((item) => item.number), [4, 3]);
      expect(result.items.first.projectPath, 'group/repo');
      expect(result.items.first.headRefName, 'feature');
      expect(transport.calls.every((call) => call.$2.contains('ship')), isTrue);
    });

    test(
      'Gitea filters titles locally and preserves exact list fields',
      () async {
        final transport = _FakeTransport((_, args) {
          expect(args, isNot(contains('--search')));
          return _json([
            {
              'index': args.first == 'issue' ? 5 : 6,
              'title': args.first == 'issue' ? 'Match issue' : 'Other PR',
              'url':
                  'https://codeberg.org/acme/repo/${args.first == 'issue' ? 'issues/5' : 'pulls/6'}',
              'state': 'open',
              'body': null,
              'labels': const [],
              'base': 'main',
              'head': 'acme:feature',
              'updated': '2026-07-27T00:00:00Z',
            },
          ]);
        });
        final result = await GiteaForgeStatusAdapter(
          transport,
          forge: 'codeberg',
        ).searchIssuesAndPullRequests(cwd: '.', query: 'match', limit: 7);
        expect(result.items, hasLength(1));
        expect(result.items.single.kind, ForgeSearchKind.issue);
        expect(result.items.single.forge, 'codeberg');
        expect(transport.calls.first.$2, contains('--fields'));
        expect(transport.calls.first.$2, containsAll(['--limit', '7']));
      },
    );

    test(
      'GitLab propagates non-auth failures while GitHub keeps partial data',
      () async {
        final gitLab = GitLabForgeStatusAdapter(
          _FakeTransport(
            (_, args) => args.first == 'issue' ? _fail('boom') : _json([]),
          ),
        );
        expect(
          gitLab.searchIssuesAndPullRequests(cwd: '.', query: ''),
          throwsA(isA<ForgeCommandException>()),
        );

        final github = await GitHubForgeStatusAdapter(
          _FakeTransport(
            (_, args) => args.first == 'issue'
                ? _fail('boom')
                : _json([
                    {
                      'number': 9,
                      'title': 'PR',
                      'url': 'https://github.com/acme/repo/pull/9',
                      'state': 'OPEN',
                      'body': null,
                      'labels': const [],
                      'baseRefName': 'main',
                      'headRefName': 'feature',
                      'updatedAt': null,
                    },
                  ]),
          ),
        ).searchIssuesAndPullRequests(cwd: '.', query: '');
        expect(github.items.single.number, 9);
      },
    );
  });
}

ForgePullRequestStatus _mergeStatus(
  Map<String, Object?> facts, {
  ForgeMergeable mergeable = ForgeMergeable.mergeable,
}) => ForgePullRequestStatus(
  number: 1,
  repoOwner: 'acme',
  repoName: 'repo',
  url: 'https://example.test/pr/1',
  title: 'Feature',
  state: 'open',
  baseRefName: 'main',
  headRefName: 'feature',
  isMerged: false,
  mergeable: mergeable,
  checks: const [],
  checksStatus: ForgeChecksStatus.success,
  reviewDecision: null,
  forgeSpecific: facts,
);

Map<String, Object?> _githubRow({
  required String state,
  required String sha,
  required int number,
  String owner = 'acme',
}) => {
  'number': number,
  'url': 'https://github.com/acme/repo/pull/$number',
  'title': 'PR $number',
  'state': state,
  'isDraft': false,
  'baseRefName': 'main',
  'headRefName': 'feature',
  'headRefOid': sha,
  'mergedAt': state == 'MERGED' ? '2026-07-27T00:00:00Z' : null,
  'reviewDecision': null,
  'mergeable': 'UNKNOWN',
  'headRepositoryOwner': {'login': owner},
};

Map<String, Object?> _gitLabView({required int iid, required String state}) => {
  'iid': iid,
  'source_branch': 'feature',
  'target_branch': 'main',
  'state': state,
  'sha': 'head',
  'web_url': 'https://gitlab.com/acme/repo/-/merge_requests/$iid',
  'title': 'MR',
  'merged_at': null,
  'references': {'full': 'acme/repo!$iid'},
};

ForgeCommandResult _ok(String stdout) =>
    ForgeCommandResult(exitCode: 0, stdout: stdout, stderr: '');

ForgeCommandResult _json(Object? value) => _ok(jsonEncode(value));

ForgeCommandResult _fail(String stderr) =>
    ForgeCommandResult(exitCode: 1, stdout: '', stderr: stderr);

typedef _FakeHandler =
    ForgeCommandResult Function(String executable, List<String> args);

final class _FakeTransport implements ForgeCommandTransport {
  _FakeTransport(this.handler);

  final _FakeHandler handler;
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
