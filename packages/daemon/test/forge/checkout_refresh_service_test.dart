import 'dart:io';

import 'package:agent_daemon/src/forge/checkout_refresh_service.dart';
import 'package:agent_daemon/src/forge/workspace_forge_status_service.dart';
import 'package:agent_daemon/src/git/git_runner.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'manual refresh validates git, invalidates forge, and refreshes observers',
    () async {
      final status = WorkspaceForgeStatusService();
      final gitCalls = <(List<String>, String)>[];
      final observerCalls = <String>[];
      final service = CheckoutRefreshService(
        statusService: status,
        runGit: (args, {required cwd, check = true}) async {
          gitCalls.add((args, cwd));
          return const GitResult(exitCode: 0, stdout: 'true\n', stderr: '');
        },
        refreshObserver: (cwd) async => observerCalls.add(cwd),
      );

      final response = CheckoutRefreshResponse.fromJson(
        (await service.handle(_request()))!,
      );

      expect(response.success, isTrue);
      expect(response.error, isNull);
      expect(response.cwd, '/repo');
      expect(response.requestId, 'refresh-1');
      expect(gitCalls, hasLength(1));
      expect(gitCalls.single.$1, ['rev-parse', '--is-inside-work-tree']);
      expect(gitCalls.single.$2, '/repo');
      expect(observerCalls, ['/repo']);
      expect(await service.handle({'type': 'other'}), isNull);
    },
  );

  test('manual refresh returns the frozen failure payload', () async {
    final service = CheckoutRefreshService(
      statusService: WorkspaceForgeStatusService(),
      runGit: (_, {required cwd, check = true}) async {
        throw GitException(
          args: const ['rev-parse', '--is-inside-work-tree'],
          exitCode: 128,
          stderr: 'fatal: not a git repository',
        );
      },
      refreshObserver: (_) async => fail('observer must not run'),
    );

    final response = CheckoutRefreshResponse.fromJson(
      (await service.handle(_request()))!,
    );

    expect(response.success, isFalse);
    expect(response.error?.code, CheckoutErrorCode.notGitRepo);
    expect(response.error?.message, 'fatal: not a git repository');
  });

  test('manual refresh normalizes non-git failures as unknown', () async {
    final service = CheckoutRefreshService(
      statusService: WorkspaceForgeStatusService(),
      runGit: (_, {required cwd, check = true}) async =>
          const GitResult(exitCode: 0, stdout: 'true\n', stderr: ''),
      refreshObserver: (_) async => throw StateError('observer unavailable'),
    );

    final response = CheckoutRefreshResponse.fromJson(
      (await service.handle(_request()))!,
    );

    expect(response.success, isFalse);
    expect(response.error?.code, CheckoutErrorCode.unknown);
    expect(response.error?.message, 'Bad state: observer unavailable');
  });

  test('manual refresh expands frozen tilde cwd forms', () async {
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home == null || home.isEmpty) return;
    final observed = <String>[];
    final service = CheckoutRefreshService(
      statusService: WorkspaceForgeStatusService(),
      runGit: (_, {required cwd, check = true}) async {
        observed.add(cwd);
        return const GitResult(exitCode: 0, stdout: 'true\n', stderr: '');
      },
      refreshObserver: (_) async {},
    );

    for (final cwd in ['~', '~/repo']) {
      final response = CheckoutRefreshResponse.fromJson(
        (await service.handle(
          CheckoutRefreshRequest(cwd: cwd, requestId: cwd).toJson(),
        ))!,
      );
      expect(response.cwd, cwd);
    }

    expect(observed, [home, p.join(home, 'repo')]);
  });
}

Map<String, Object?> _request() =>
    const CheckoutRefreshRequest(cwd: '/repo', requestId: 'refresh-1').toJson();
