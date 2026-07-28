import 'dart:convert';

import 'package:agent_daemon/src/forge/forge_cli.dart';
import 'package:agent_daemon/src/forge/forge_models.dart';
import 'package:agent_daemon/src/forge/forge_resolver.dart';
import 'package:agent_daemon/src/forge/workspace_forge_status_service.dart';
import 'package:test/test.dart';

void main() {
  group('ForgeResolver', () {
    test('resolves known cloud hosts synchronously and reuses adapters', () {
      final resolver = ForgeResolver(
        transport: _FakeTransport((_, _) => _ok()),
      );
      final github = resolver.resolveFromRemoteUrl(
        'git@github.com:acme/repo.git',
      );
      final githubAgain = resolver.resolveFromRemoteUrl(
        'https://github.com/acme/repo',
      );
      expect(github?.forge, 'github');
      expect(github?.host, 'github.com');
      expect(identical(github?.adapter, githubAgain?.adapter), isTrue);
      expect(
        resolver.resolveFromRemoteUrl('https://gitlab.com/acme/repo')?.forge,
        'gitlab',
      );
      expect(
        resolver.resolveFromRemoteUrl('https://codeberg.org/acme/repo')?.forge,
        'codeberg',
      );
      expect(resolver.resolveFromRemoteUrl(null), isNull);
      expect(resolver.resolveFromRemoteUrl('not-a-remote'), isNull);
    });

    test('probes GitHub and GitLab self-managed hosts', () async {
      final githubTransport = _FakeTransport((executable, _) {
        expect(executable, 'gh');
        return _ok();
      });
      final github = ForgeResolver(transport: githubTransport);
      expect(
        (await github.resolveFromRemoteUrlAsync(
          'ssh://git@ghe.example.com/acme/repo',
          cwd: '.',
        ))?.forge,
        'github',
      );
      final calls = githubTransport.calls.length;
      expect(
        (await github.resolveFromRemoteUrlAsync(
          'ssh://git@ghe.example.com/acme/other',
          cwd: '.',
        ))?.forge,
        'github',
      );
      expect(githubTransport.calls, hasLength(calls));

      final gitlabTransport = _FakeTransport((executable, _) {
        if (executable == 'gh') return _fail('401 unauthorized');
        if (executable == 'glab') return _ok();
        throw StateError('unexpected $executable');
      });
      final gitlab = ForgeResolver(transport: gitlabTransport);
      expect(
        (await gitlab.resolveFromRemoteUrlAsync(
          'https://forge.company.test/group/repo',
          cwd: '.',
        ))?.forge,
        'gitlab',
      );
    });

    test('detects Forgejo through authenticated tea headers', () async {
      final transport = _FakeTransport((executable, args) {
        if (executable == 'gh' || executable == 'glab') {
          return _fail('not configured');
        }
        if (args.first == 'login') {
          return _json([
            {
              'name': 'company',
              'url': 'https://forge.company.test',
              'ssh_host': 'forge.company.test',
            },
          ]);
        }
        if (args.first == 'api') {
          return const ForgeCommandResult(
            exitCode: 0,
            stdout: '{"version":"11"}',
            stderr: 'HTTP/1.1 200 OK',
          );
        }
        throw StateError('unexpected $args');
      });
      final resolution = await ForgeResolver(transport: transport)
          .resolveFromRemoteUrlAsync(
            'git@forge.company.test:acme/repo.git',
            cwd: '.',
          );
      expect(resolution?.forge, 'forgejo');
      expect(transport.calls.where((call) => call.$1 == 'tea'), hasLength(3));
    });

    test('defaults an inconclusive authenticated family to Gitea', () async {
      final transport = _FakeTransport((executable, args) {
        if (executable != 'tea') return _fail('no');
        if (args.first == 'login') {
          return _json([
            {'name': 'gitea', 'url': 'https://git.example.test'},
          ]);
        }
        return const ForgeCommandResult(
          exitCode: 0,
          stdout: '',
          stderr: 'HTTP/1.1 404 Not Found',
        );
      });
      final result = await ForgeResolver(transport: transport)
          .resolveFromRemoteUrlAsync(
            'https://git.example.test/acme/repo',
            cwd: '.',
          );
      expect(result?.forge, 'gitea');
    });

    test(
      'negative probes expire, can be invalidated, and are bounded',
      () async {
        var now = DateTime.utc(2026, 7, 27);
        final transport = _FakeTransport((_, _) => _fail('not configured'));
        final resolver = ForgeResolver(
          transport: transport,
          now: () => now,
          maximumEntries: 1,
        );
        const first = 'https://one.example/acme/repo';
        expect(
          await resolver.resolveFromRemoteUrlAsync(first, cwd: '.'),
          isNull,
        );
        final calls = transport.calls.length;
        expect(
          await resolver.resolveFromRemoteUrlAsync(first, cwd: '.'),
          isNull,
        );
        expect(transport.calls, hasLength(calls));
        now = now.add(const Duration(minutes: 2));
        expect(
          await resolver.resolveFromRemoteUrlAsync(first, cwd: '.'),
          isNull,
        );
        expect(transport.calls.length, greaterThan(calls));
        resolver.invalidateHost('one.example');
        final afterInvalidate = transport.calls.length;
        expect(
          await resolver.resolveFromRemoteUrlAsync(first, cwd: '.'),
          isNull,
        );
        expect(transport.calls.length, greaterThan(afterInvalidate));
        await resolver.resolveFromRemoteUrlAsync(
          'https://two.example/acme/repo',
          cwd: '.',
        );
        expect(resolver.resolveFromRemoteUrl(first), isNull);
      },
    );
  });

  group('WorkspaceForgeStatusService', () {
    test('returns no_remote without invoking a resolver', () async {
      final transport = _FakeTransport((_, _) => throw StateError('unused'));
      final service = WorkspaceForgeStatusService(
        resolver: ForgeResolver(transport: transport),
        now: () => DateTime.utc(2026, 7, 27),
      );
      expect(
        (await service.load(
          cwd: '.',
          remoteUrl: null,
          headRef: 'main',
        )).authState,
        ForgeAuthState.noRemote,
      );
      expect(
        (await service.load(
          cwd: '.',
          remoteUrl: 'https://github.com/acme/repo',
          headRef: null,
        )).authState,
        ForgeAuthState.noRemote,
      );
      expect(transport.calls, isEmpty);
    });

    test(
      'distinguishes malformed, unresolved, missing, and unauthenticated',
      () async {
        final unresolved = WorkspaceForgeStatusService(
          resolver: ForgeResolver(
            transport: _FakeTransport((_, _) => _fail('no')),
          ),
        );
        expect(
          (await unresolved.load(
            cwd: '.',
            remoteUrl: 'local-path',
            headRef: 'main',
          )).authState,
          ForgeAuthState.noRemote,
        );
        final unknown = await unresolved.load(
          cwd: '.',
          remoteUrl: 'https://unknown.example/acme/repo',
          headRef: 'main',
        );
        expect(unknown.authState, ForgeAuthState.unauthenticated);
        expect(unknown.forge, 'unknown.example');

        final missing = WorkspaceForgeStatusService(
          resolver: ForgeResolver(
            transport: _FakeTransport(
              (_, _) => throw const ForgeCliMissingException('gh'),
            ),
          ),
        );
        expect(
          (await missing.load(
            cwd: '.',
            remoteUrl: 'https://github.com/acme/repo',
            headRef: 'main',
          )).authState,
          ForgeAuthState.cliMissing,
        );

        final unauthenticated = WorkspaceForgeStatusService(
          resolver: ForgeResolver(
            transport: _FakeTransport((_, _) => _fail('401 unauthorized')),
          ),
        );
        expect(
          (await unauthenticated.load(
            cwd: '.',
            remoteUrl: 'https://gitlab.com/acme/repo',
            headRef: 'main',
          )).authState,
          ForgeAuthState.unauthenticated,
        );
      },
    );

    test(
      'caches, forces, invalidates, and projects authenticated PR state',
      () async {
        var now = DateTime.utc(2026, 7, 27);
        final transport = _FakeTransport((_, args) {
          if (args.first == 'auth') return _ok();
          return _json([
            {
              'number': 2,
              'url': 'https://github.com/acme/repo/pull/2',
              'title': 'Current',
              'state': 'OPEN',
              'isDraft': false,
              'baseRefName': 'main',
              'headRefName': 'feature',
              'headRefOid': 'abc',
              'mergedAt': null,
              'reviewDecision': 'APPROVED',
              'mergeable': 'MERGEABLE',
              'headRepositoryOwner': {'login': 'acme'},
              'statusCheckRollup': [],
            },
          ]);
        });
        final service = WorkspaceForgeStatusService(
          resolver: ForgeResolver(transport: transport, now: () => now),
          now: () => now,
        );
        Future<WorkspaceForgeSnapshot> load({bool force = false}) =>
            service.load(
              cwd: 'C:/repo',
              remoteUrl: 'https://github.com/acme/repo',
              headRef: 'feature',
              headSha: 'abc',
              force: force,
            );

        final first = await load();
        expect(first.authState, ForgeAuthState.authenticated);
        expect(first.featuresEnabled, isTrue);
        expect(first.forge, 'github');
        expect(first.pullRequest?.number, 2);
        expect(first.toGithubRuntimeJson()['pullRequest'], isA<Map>());
        final calls = transport.calls.length;
        expect(identical(await load(), first), isTrue);
        expect(transport.calls, hasLength(calls));

        await load(force: true);
        expect(transport.calls.length, greaterThan(calls));
        final forcedCalls = transport.calls.length;
        service.invalidate('C:/repo');
        await load();
        expect(transport.calls.length, greaterThan(forcedCalls));

        final beforeExpiry = transport.calls.length;
        now = now.add(const Duration(seconds: 16));
        await load();
        expect(transport.calls.length, greaterThan(beforeExpiry));
      },
    );

    test(
      'keeps features enabled when an authenticated status command fails',
      () async {
        var calls = 0;
        final service = WorkspaceForgeStatusService(
          resolver: ForgeResolver(
            transport: _FakeTransport((_, args) {
              calls += 1;
              if (args.first == 'auth') return _ok();
              return _fail('network exploded');
            }),
          ),
        );
        final snapshot = await service.load(
          cwd: '.',
          remoteUrl: 'https://github.com/acme/repo',
          headRef: 'feature',
        );
        expect(snapshot.authState, ForgeAuthState.authenticated);
        expect(snapshot.featuresEnabled, isTrue);
        expect(snapshot.error, contains('gh CLI command failed'));
        expect(calls, 2);
      },
    );

    test('maps status-time authentication failure precisely', () async {
      final service = WorkspaceForgeStatusService(
        resolver: ForgeResolver(
          transport: _FakeTransport((_, args) {
            if (args.first == 'auth') return _ok();
            return _fail('401 token expired');
          }),
        ),
      );
      expect(
        (await service.load(
          cwd: '.',
          remoteUrl: 'https://github.com/acme/repo',
          headRef: 'feature',
        )).authState,
        ForgeAuthState.unauthenticated,
      );
    });

    test(
      'maps auth and status command failures to exact runtime states',
      () async {
        Future<WorkspaceForgeSnapshot> loadWith(_FakeHandler handler) {
          return WorkspaceForgeStatusService(
            resolver: ForgeResolver(transport: _FakeTransport(handler)),
          ).load(
            cwd: '.',
            remoteUrl: 'https://github.com/acme/repo',
            headRef: 'feature',
          );
        }

        final authError = await loadWith((_, _) => _fail('network exploded'));
        expect(authError.authState, ForgeAuthState.error);
        expect(authError.featuresEnabled, isFalse);
        expect(authError.error, contains('gh CLI command failed'));

        final statusMissing = await loadWith((_, args) {
          if (args.first == 'auth') return _ok();
          throw const ForgeCliMissingException('gh');
        });
        expect(statusMissing.authState, ForgeAuthState.cliMissing);
        expect(statusMissing.featuresEnabled, isFalse);

        final malformedStatus = await loadWith((_, args) {
          if (args.first == 'auth') return _ok();
          return _json([<String, Object?>{}]);
        });
        expect(malformedStatus.authState, ForgeAuthState.authenticated);
        expect(malformedStatus.featuresEnabled, isTrue);
        expect(malformedStatus.error, contains('must be'));
      },
    );

    test(
      'bounds cache entries and evicts an unexpected failed future',
      () async {
        var calls = 0;
        var failUnexpectedly = false;
        final transport = _FakeTransport((_, args) {
          calls += 1;
          if (failUnexpectedly) throw StateError('transport bug');
          if (args.first == 'auth') return _ok();
          return _json([]);
        });
        final service = WorkspaceForgeStatusService(
          resolver: ForgeResolver(transport: transport),
          maximumEntries: 1,
        );
        Future<WorkspaceForgeSnapshot> load(String headRef) => service.load(
          cwd: '.',
          remoteUrl: 'https://github.com/acme/repo',
          headRef: headRef,
        );

        await load('one');
        await load('two');
        final afterTwoKeys = calls;
        await load('one');
        expect(calls, greaterThan(afterTwoKeys));

        failUnexpectedly = true;
        await expectLater(load('broken'), throwsStateError);
        final afterFailure = calls;
        await expectLater(load('broken'), throwsStateError);
        expect(calls, greaterThan(afterFailure));
      },
    );
  });
}

ForgeCommandResult _ok([String stdout = '']) =>
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
