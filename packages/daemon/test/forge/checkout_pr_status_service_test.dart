import 'dart:convert';

import 'package:agent_daemon/src/forge/checkout_pr_status_service.dart';
import 'package:agent_daemon/src/forge/forge_cli.dart';
import 'package:agent_daemon/src/forge/forge_resolver.dart';
import 'package:agent_daemon/src/forge/workspace_forge_status_service.dart';
import 'package:agent_daemon/src/git/git_runner.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'projects the shared forge snapshot onto the exact status response',
    () async {
      final transport = _FakeTransport((_, args) {
        final command = args.take(2).join(' ');
        if (command == 'auth status') return _ok('');
        if (command == 'pr list') {
          return _json([
            {
              'number': 7,
              'url': 'https://github.com/acme/repo/pull/7',
              'title': 'Feature',
              'state': 'OPEN',
              'isDraft': null,
              'baseRefName': 'main',
              'headRefName': 'feature',
              'headRefOid': 'abc',
              'mergedAt': null,
              'reviewDecision': 'APPROVED',
              'mergeable': 'MERGEABLE',
              'headRepositoryOwner': {'login': 'acme'},
              'statusCheckRollup': [
                {
                  '__typename': 'CheckRun',
                  'name': 'build',
                  'status': 'COMPLETED',
                  'conclusion': 'SUCCESS',
                  'detailsUrl': 'https://checks/build',
                },
              ],
            },
          ]);
        }
        if (command == 'api graphql') {
          return _json({
            'data': {
              'repository': {
                'autoMergeAllowed': true,
                'mergeCommitAllowed': true,
                'squashMergeAllowed': true,
                'rebaseMergeAllowed': false,
                'viewerDefaultMergeMethod': 'SQUASH',
                'pullRequest': {
                  'mergeStateStatus': 'CLEAN',
                  'autoMergeRequest': null,
                  'viewerCanEnableAutoMerge': false,
                  'viewerCanDisableAutoMerge': false,
                  'viewerCanMergeAsAdmin': true,
                  'viewerCanUpdateBranch': true,
                  'isMergeQueueEnabled': false,
                  'isInMergeQueue': false,
                },
              },
            },
          });
        }
        throw StateError('unexpected ${args.join(' ')}');
      });
      final resolver = ForgeResolver(transport: transport);
      final service = CheckoutPrStatusService(
        statusService: WorkspaceForgeStatusService(resolver: resolver),
        runGit: _gitContext,
      );

      final response = CheckoutPrStatusResponse.fromJson(
        (await service.handle(_request()))!,
      );
      expect(response.authState, 'authenticated');
      expect(response.forge, 'github');
      expect(response.hasExplicitForge, isTrue);
      expect(response.githubFeaturesEnabled, isTrue);
      expect(response.error, isNull);
      expect(response.status?.projectPath, 'acme/repo');
      expect(response.status?.isDraft, isFalse);
      expect(response.status?.checks.single.status, 'success');
      expect(response.status?.reviewDecision, 'approved');
      expect(response.status?.forgeSpecific, isA<Map>());
      expect(response.status?.github?['mergeStateStatus'], 'CLEAN');
      expect(response.status?.github?.containsKey('forge'), isFalse);
    },
  );

  test(
    'missing git context returns no_remote without inventing a forge',
    () async {
      final transport = _FakeTransport((_, _) => throw StateError('unused'));
      final service = CheckoutPrStatusService(
        statusService: WorkspaceForgeStatusService(
          resolver: ForgeResolver(transport: transport),
        ),
        runGit: (args, {required cwd, check = true}) async =>
            const GitResult(exitCode: 1, stdout: '', stderr: ''),
      );
      final raw = (await service.handle(_request()))!;
      final response = CheckoutPrStatusResponse.fromJson(raw);
      expect(response.authState, 'no_remote');
      expect(response.githubFeaturesEnabled, isFalse);
      expect(response.status, isNull);
      expect(response.hasExplicitForge, isFalse);
      expect((raw['payload'] as Map).containsKey('forge'), isFalse);
      expect(transport.calls, 0);
      expect(await service.handle({'type': 'other'}), isNull);
    },
  );

  test(
    'status and composition failures retain visible error semantics',
    () async {
      final statusFailure = CheckoutPrStatusService(
        statusService: WorkspaceForgeStatusService(
          resolver: ForgeResolver(
            transport: _FakeTransport((_, args) {
              if (args.take(2).join(' ') == 'auth status') return _ok('');
              return _fail('API unavailable');
            }),
          ),
        ),
        runGit: _gitContext,
      );
      final statusResponse = CheckoutPrStatusResponse.fromJson(
        (await statusFailure.handle(_request()))!,
      );
      expect(statusResponse.githubFeaturesEnabled, isTrue);
      expect(statusResponse.authState, 'authenticated');
      expect(statusResponse.error?.code, CheckoutErrorCode.unknown);
      expect(statusResponse.error?.message, contains('gh CLI command failed'));

      final compositionFailure = CheckoutPrStatusService(
        statusService: WorkspaceForgeStatusService(
          resolver: ForgeResolver(
            transport: _FakeTransport((_, _) => throw StateError('unused')),
          ),
        ),
        runGit: (args, {required cwd, check = true}) =>
            throw StateError('git unavailable'),
      );
      final failed = CheckoutPrStatusResponse.fromJson(
        (await compositionFailure.handle(_request()))!,
      );
      expect(failed.authState, 'error');
      expect(failed.githubFeaturesEnabled, isTrue);
      expect(failed.error?.message, contains('git unavailable'));
    },
  );
}

Map<String, Object?> _request() => {
  'type': CheckoutPrStatusRequest.type,
  'cwd': '/repo',
  'requestId': 'status-1',
};

Future<GitResult> _gitContext(
  List<String> args, {
  required String cwd,
  bool check = true,
}) async {
  final key = args.join(' ');
  return GitResult(
    exitCode: 0,
    stdout: switch (key) {
      'config --get remote.origin.url' => 'https://github.com/acme/repo.git\n',
      'symbolic-ref --quiet --short HEAD' => 'feature\n',
      'rev-parse HEAD' => 'abc\n',
      _ => throw StateError('unexpected git $key'),
    },
    stderr: '',
  );
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
