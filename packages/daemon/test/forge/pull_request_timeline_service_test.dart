import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/forge/forge_cli.dart';
import 'package:agent_daemon/src/forge/forge_resolver.dart';
import 'package:agent_daemon/src/forge/pull_request_timeline_service.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory repo;

  setUp(() async {
    repo = Directory.systemTemp.createTempSync('forge-timeline-service-');
    await _git(repo.path, ['init', '-b', 'main']);
  });

  tearDown(() {
    if (repo.existsSync()) repo.deleteSync(recursive: true);
  });

  test(
    'resolves, authenticates, and returns the exact timeline envelope',
    () async {
      await _git(repo.path, [
        'remote',
        'add',
        'origin',
        'https://github.com/acme/repo.git',
      ]);
      final transport = _FakeTransport((_, args) {
        if (args.take(2).join(' ') == 'auth status') return _ok('');
        return _json({
          'data': {
            'repository': {
              'pullRequest': {
                'number': 3,
                'reviews': {
                  'nodes': const [],
                  'pageInfo': {'hasNextPage': false},
                },
                'comments': {
                  'nodes': [
                    {
                      'id': 'C1',
                      'body': 'hello',
                      'createdAt': '2026-07-27T00:00:00Z',
                    },
                  ],
                  'pageInfo': {'hasNextPage': false},
                },
                'reviewThreads': {
                  'nodes': const [],
                  'pageInfo': {'hasNextPage': false},
                },
              },
            },
          },
        });
      });
      final service = PullRequestTimelineService(
        resolver: ForgeResolver(transport: transport),
      );

      final response = PullRequestTimelineResponse.fromJson(
        (await service.handle(_request(repo.path)))!,
      );
      expect(response.prNumber, 3);
      expect(response.items.single.body, 'hello');
      expect(response.error, isNull);
      expect(response.githubFeaturesEnabled, isTrue);
      expect(response.authState, isNull);
    },
  );

  test('validates identity before resolving or invoking a forge', () async {
    final transport = _FakeTransport((_, _) => throw StateError('unused'));
    final service = PullRequestTimelineService(
      resolver: ForgeResolver(transport: transport),
    );
    final response = PullRequestTimelineResponse.fromJson(
      (await service.handle({
        ..._request(repo.path),
        'prNumber': 0,
        'repoOwner': 'bad/owner',
      }))!,
    );
    expect(response.error?.message, contains('invalid PR identity'));
    expect(response.githubFeaturesEnabled, isTrue);
    expect(transport.calls, 0);
    expect(await service.handle({'type': 'other'}), isNull);
  });

  test('reports no remote and preserves auth probe precision', () async {
    final noRemote = PullRequestTimelineResponse.fromJson(
      (await PullRequestTimelineService(
        resolver: ForgeResolver(
          transport: _FakeTransport((_, _) => throw StateError('unused')),
        ),
      ).handle(_request(repo.path)))!,
    );
    expect(noRemote.authState, 'no_remote');
    expect(noRemote.githubFeaturesEnabled, isFalse);

    await _git(repo.path, [
      'remote',
      'add',
      'origin',
      'https://github.com/acme/repo.git',
    ]);
    final missing = PullRequestTimelineResponse.fromJson(
      (await PullRequestTimelineService(
        resolver: ForgeResolver(
          transport: _FakeTransport(
            (_, _) => throw const ForgeCliMissingException('gh'),
          ),
        ),
      ).handle(_request(repo.path)))!,
    );
    expect(missing.authState, 'cli_missing');
    expect(missing.githubFeaturesEnabled, isFalse);
    expect(missing.error?.message, contains('GitHub CLI'));
  });

  test('a false auth probe omits richer auth state like Paseo', () async {
    await _git(repo.path, [
      'remote',
      'add',
      'origin',
      'https://gitlab.com/acme/repo.git',
    ]);
    final response = PullRequestTimelineResponse.fromJson(
      (await PullRequestTimelineService(
        resolver: ForgeResolver(
          transport: _FakeTransport((_, _) => _fail('expired token')),
        ),
      ).handle(_request(repo.path)))!,
    );
    expect(response.authState, isNull);
    expect(response.githubFeaturesEnabled, isFalse);
    expect(response.error?.message, contains('GitLab CLI'));
  });

  test(
    'unexpected adapter failures preserve auth and generic states',
    () async {
      await _git(repo.path, [
        'remote',
        'add',
        'origin',
        'https://github.com/acme/repo.git',
      ]);
      Future<PullRequestTimelineResponse> load(Object error) async {
        final service = PullRequestTimelineService(
          resolver: ForgeResolver(transport: _FakeTransport((_, _) => _ok(''))),
          loadTimeline: (_, _) => throw error,
        );
        return PullRequestTimelineResponse.fromJson(
          (await service.handle(_request(repo.path)))!,
        );
      }

      final auth = await load(
        const ForgeAuthenticationException('expired credential'),
      );
      expect(auth.authState, 'unauthenticated');
      expect(auth.githubFeaturesEnabled, isFalse);
      expect(auth.error?.message, 'expired credential');

      final generic = await load(StateError('network failed'));
      expect(generic.authState, 'error');
      expect(generic.githubFeaturesEnabled, isTrue);
      expect(generic.error?.message, contains('network failed'));
    },
  );
}

Map<String, Object?> _request(String cwd) => {
  'type': PullRequestTimelineRequest.type,
  'cwd': cwd,
  'prNumber': 3,
  'repoOwner': 'acme',
  'repoName': 'repo',
  'requestId': 'timeline-1',
};

Future<void> _git(String cwd, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: cwd);
  if (result.exitCode != 0) throw StateError('${result.stderr}');
}

ForgeCommandResult _ok(String value) =>
    ForgeCommandResult(exitCode: 0, stdout: value, stderr: '');

ForgeCommandResult _json(Object? value) => _ok(jsonEncode(value));

ForgeCommandResult _fail(String value) =>
    ForgeCommandResult(exitCode: 1, stdout: '', stderr: value);

typedef _Handler =
    ForgeCommandResult Function(String executable, List<String> args);

final class _FakeTransport implements ForgeCommandTransport {
  _FakeTransport(this.handler);
  final _Handler handler;
  int calls = 0;

  @override
  Future<ForgeCommandResult> run(
    String executable,
    List<String> args, {
    required String cwd,
    Map<String, String> environment = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls += 1;
    return handler(executable, args);
  }
}
