import 'dart:convert';

import 'package:agent_daemon/src/forge/forge_adapters.dart';
import 'package:agent_daemon/src/forge/forge_check_details_service.dart';
import 'package:agent_daemon/src/forge/forge_cli.dart';
import 'package:agent_daemon/src/forge/forge_resolver.dart';
import 'package:agent_daemon/src/git/git_runner.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('forge check-details adapters', () {
    test(
      'GitHub maps annotations, failed jobs, and bounded log tails',
      () async {
        final transport = _FakeTransport((executable, args) {
          expect(executable, 'gh');
          final target = args[1];
          if (target.endsWith('/check-runs/41')) {
            return _json({
              'id': 41,
              'name': 'build',
              'status': 'completed',
              'conclusion': 'failure',
              'html_url': 'https://github/check/41',
              'details_url': 'https://ci/build',
              'output': {
                'title': 'Build failed',
                'summary': 'summary',
                'text': null,
                'future': 'stripped at the wire boundary',
              },
              'check_suite': {
                'workflow_run': {'id': 52},
              },
            });
          }
          if (target.endsWith('/check-runs/41/annotations')) {
            return _json([
              for (var index = 0; index < 20; index++)
                {
                  'path': 'lib/file$index.dart',
                  'start_line': index + 1,
                  'end_line': index + 2,
                  'annotation_level': 'failure',
                  'message': 'message $index',
                  'title': 'Lint',
                  'raw_details': 'raw',
                },
            ]);
          }
          if (target.endsWith('/actions/runs/52/jobs')) {
            return _json({
              'jobs': [
                {
                  'id': 61,
                  'name': 'unit',
                  'status': 'completed',
                  'conclusion': 'failure',
                  'html_url': 'https://github/job/61',
                },
                {
                  'id': 62,
                  'name': 'lint',
                  'status': 'completed',
                  'conclusion': 'success',
                },
              ],
            });
          }
          if (target.endsWith('/actions/jobs/61/logs')) {
            return _ok(
              [
                for (var index = 0; index < 205; index++) 'line $index',
              ].join('\n'),
            );
          }
          throw StateError('unexpected ${args.join(' ')}');
        });
        final adapter = createForgeStatusAdapter(
          'github',
          transport: transport,
        );

        final details = await adapter.getCheckDetails(
          cwd: '/repo',
          repositoryOwner: 'acme',
          repositoryName: 'repo',
          checkRunId: 41,
        );

        expect(details.checkRunId, 41);
        expect(details.workflowRunId, 52);
        expect(details.annotations, hasLength(20));
        expect(details.annotations.first.path, 'lib/file0.dart');
        expect(details.failedJobs, hasLength(1));
        expect(details.failedJobs.single.jobId, 61);
        expect(details.failedJobs.single.logTruncated, isTrue);
        expect(details.failedJobs.single.logTail, startsWith('line 5\n'));
        expect(details.truncated, isTrue);
        expect(details.toJson()['output'], {
          'title': 'Build failed',
          'summary': 'summary',
          'text': null,
        });
        expect(
          transport.calls
              .where((call) => call.args.contains('per_page=20'))
              .length,
          1,
        );
      },
    );

    test('GitLab normalizes pipeline stages and selector precedence', () async {
      final transport = _FakeTransport((executable, args) {
        expect(executable, 'glab');
        expect(args, containsAllInOrder(['--merge-request', '9']));
        expect(args, isNot(contains('--pipeline-id')));
        return _json({
          'id': 70,
          'status': 'failed',
          'web_url': 'https://gitlab/pipelines/70',
          'ref': 'feature',
          'sha': 'abc',
          'jobs': [
            {
              'id': 3,
              'name': 'allowed failure',
              'stage': 'test',
              'status': 'failed',
              'allow_failure': true,
              'duration': 1.5,
            },
            {
              'id': 1,
              'name': 'build',
              'stage': 'build',
              'status': 'success',
              'allow_failure': false,
              'web_url': 'https://gitlab/jobs/1',
            },
            {
              'id': 2,
              'name': 'unit',
              'stage': 'test',
              'status': 'running',
              'allow_failure': false,
            },
          ],
        });
      });
      final adapter = createForgeStatusAdapter('gitlab', transport: transport);

      final details = await adapter.getCheckDetails(
        cwd: '/repo',
        checkRunId: 70,
        changeRequestNumber: 9,
      );

      expect(details.name, 'Pipeline (feature)');
      expect(details.pipeline?.status, 'failed');
      expect(details.pipeline?.stages.map((stage) => stage.name), [
        'build',
        'test',
      ]);
      expect(details.pipeline?.stages.last.status, 'running');
      expect(details.pipeline?.stages.last.jobs.map((job) => job.id), [2, 3]);
    });

    test('Gitea resolves commit status and Actions run details', () async {
      var actions = false;
      final transport = _FakeTransport((executable, args) {
        expect(executable, 'tea');
        if (args.take(2).join(' ') == 'pr 12') {
          return _json({'headSha': 'abc'});
        }
        if (args[0] == 'api' && args[1].endsWith('/commits/abc/status')) {
          return _json({
            'statuses': actions
                ? []
                : [
                    {
                      'id': 81,
                      'context': 'ci/test',
                      'description': 'Tests failed',
                      'status': 'failure',
                      'target_url': 'https://ci/81',
                      'url': 'https://gitea/status/81',
                    },
                  ],
          });
        }
        if (args[0] == 'api' && args[1].contains('/actions/tasks?')) {
          return _json({
            'total_count': 1,
            'workflow_runs': [
              {
                'id': 91,
                'name': 'Build',
                'display_title': 'Feature build',
                'workflow_id': 'build.yml',
                'status': 'failed',
                'head_sha': 'abc',
                'url': 'https://gitea/actions/91',
              },
            ],
          });
        }
        throw StateError('unexpected ${args.join(' ')}');
      });
      final adapter = createForgeStatusAdapter('gitea', transport: transport);

      final status = await adapter.getCheckDetails(
        cwd: '/repo',
        repositoryOwner: 'acme',
        repositoryName: 'repo',
        checkRunId: 81,
        changeRequestNumber: 12,
      );
      expect(status.name, 'ci/test');
      expect(status.conclusion, 'failure');
      expect(status.output?['summary'], 'Tests failed');

      actions = true;
      final run = await adapter.getCheckDetails(
        cwd: '/repo',
        repositoryOwner: 'acme',
        repositoryName: 'repo',
        workflowRunId: 91,
        changeRequestNumber: 12,
      );
      expect(run.workflowRunId, 91);
      expect(run.name, 'Build');
      expect(run.conclusion, 'failure');
      expect(run.output?['title'], 'Feature build');
    });

    test('provider-specific identity requirements fail visibly', () async {
      final unused = _FakeTransport(
        (_, _) => throw StateError('transport must remain unused'),
      );
      await expectLater(
        createForgeStatusAdapter(
          'github',
          transport: unused,
        ).getCheckDetails(cwd: '/repo', checkRunId: 1),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        createForgeStatusAdapter(
          'gitlab',
          transport: unused,
        ).getCheckDetails(cwd: '/repo'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        createForgeStatusAdapter('gitea', transport: unused).getCheckDetails(
          cwd: '/repo',
          repositoryOwner: 'acme',
          repositoryName: 'repo',
        ),
        throwsA(isA<StateError>()),
      );
      expect(unused.calls, isEmpty);
    });
  });

  group('forge check-details service', () {
    test('routes modern and legacy requests to matching responses', () async {
      final transport = _FakeTransport((executable, args) {
        expect(executable, 'gh');
        if (args[1].endsWith('/check-runs/41')) {
          return _json({'id': 41, 'name': 'build'});
        }
        if (args[1].endsWith('/check-runs/41/annotations')) {
          return _json([]);
        }
        throw StateError('unexpected ${args.join(' ')}');
      });
      final service = ForgeCheckDetailsService(
        resolver: ForgeResolver(transport: transport),
        runGit: _githubRemote,
      );

      for (final type in const [
        CheckoutForgeGetCheckDetailsRequest.modernType,
        CheckoutForgeGetCheckDetailsRequest.legacyGithubType,
      ]) {
        final response = CheckoutForgeGetCheckDetailsResponse.fromJson(
          (await service.handle(_request(type: type)))!,
        );
        expect(
          response.type,
          type == CheckoutForgeGetCheckDetailsRequest.modernType
              ? CheckoutForgeGetCheckDetailsResponse.modernType
              : CheckoutForgeGetCheckDetailsResponse.legacyGithubType,
        );
        expect(response.success, isTrue);
        expect(response.details?.checkRunId, 41);
        expect(response.error, isNull);
      }
      expect(await service.handle({'type': 'other'}), isNull);
    });

    test(
      'returns paired unknown errors for invalid target and no remote',
      () async {
        final transport = _FakeTransport(
          (_, _) => throw StateError('transport must remain unused'),
        );
        final invalid = ForgeCheckDetailsService(
          resolver: ForgeResolver(transport: transport),
          runGit: _githubRemote,
        );
        final invalidResponse = CheckoutForgeGetCheckDetailsResponse.fromJson(
          (await invalid.handle({
            ..._request(),
            'checkRunId': null,
            'workflowRunId': null,
          }))!,
        );
        expect(invalidResponse.success, isFalse);
        expect(invalidResponse.error?.code, CheckoutErrorCode.unknown);
        expect(
          invalidResponse.error?.message,
          contains('must address a check'),
        );

        final noRemote = ForgeCheckDetailsService(
          resolver: ForgeResolver(transport: transport),
          runGit: (args, {required cwd, check = true}) async =>
              const GitResult(exitCode: 1, stdout: '', stderr: ''),
        );
        final noRemoteResponse = CheckoutForgeGetCheckDetailsResponse.fromJson(
          (await noRemote.handle(_request()))!,
        );
        expect(noRemoteResponse.success, isFalse);
        expect(
          noRemoteResponse.error?.message,
          'No supported forge remote is configured for this workspace',
        );
        expect(transport.calls, isEmpty);
      },
    );
  });
}

Map<String, Object?> _request({
  String type = CheckoutForgeGetCheckDetailsRequest.modernType,
}) => {
  'type': type,
  'cwd': '/repo',
  'repoOwner': 'acme',
  'repoName': 'repo',
  'checkRunId': 41,
  'requestId': 'details-1',
};

Future<GitResult> _githubRemote(
  List<String> args, {
  required String cwd,
  bool check = true,
}) async {
  expect(args, ['config', '--get', 'remote.origin.url']);
  return const GitResult(
    exitCode: 0,
    stdout: 'https://github.com/acme/repo.git\n',
    stderr: '',
  );
}

ForgeCommandResult _ok(String value) =>
    ForgeCommandResult(exitCode: 0, stdout: value, stderr: '');

ForgeCommandResult _json(Object? value) => _ok(jsonEncode(value));

typedef _Handler =
    ForgeCommandResult Function(String executable, List<String> args);

final class _Call {
  const _Call(this.executable, this.args);
  final String executable;
  final List<String> args;
}

final class _FakeTransport implements ForgeCommandTransport {
  _FakeTransport(this.handler);

  final _Handler handler;
  final List<_Call> calls = [];

  @override
  Future<ForgeCommandResult> run(
    String executable,
    List<String> args, {
    required String cwd,
    Map<String, String> environment = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add(_Call(executable, List.unmodifiable(args)));
    return handler(executable, args);
  }
}
