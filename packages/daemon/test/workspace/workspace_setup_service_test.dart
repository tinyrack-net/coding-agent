import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/agent_daemon.dart';
import 'package:agent_daemon/src/git/worktree_metadata.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  const snapshot = WorkspaceSetupSnapshot(
    status: WorkspaceSetupStatus.running,
    detail: WorkspaceSetupDetail(
      worktreePath: '/repo/feature',
      branchName: 'feature',
      log: 'installing',
      commands: [
        WorkspaceSetupCommand(
          index: 1,
          command: 'dart pub get',
          cwd: '/repo/feature',
          status: WorkspaceSetupCommandStatus.running,
          exitCode: null,
        ),
      ],
    ),
    error: null,
  );

  test('returns null before progress and cached snapshot after progress', () {
    final broadcasts = <Map<String, Object?>>[];
    final service = WorkspaceSetupService(broadcast: broadcasts.add);
    final request = const WorkspaceSetupStatusRequest(
      workspaceId: 'workspace-1',
      requestId: 'request-1',
    ).toJson();

    final empty = WorkspaceSetupStatusResponse.fromJson(
      service.handle(request)!,
    );
    expect(empty.snapshot, isNull);

    service.upsert('workspace-1', snapshot);
    expect(broadcasts, hasLength(1));
    final progress = WorkspaceSetupProgress.fromJson(broadcasts.single);
    expect(progress.workspaceId, 'workspace-1');
    expect(progress.snapshot.status, WorkspaceSetupStatus.running);

    final cached = WorkspaceSetupStatusResponse.fromJson(
      service.handle(request)!,
    );
    expect(cached.snapshot?.detail.log, 'installing');
    expect(service.snapshots, contains('workspace-1'));
  });

  test('ignores unrelated messages and supports cache removal', () {
    final service = WorkspaceSetupService(broadcast: (_) {});
    expect(service.handle({'type': 'other'}), isNull);
    service.upsert('workspace-1', snapshot);
    service.remove('workspace-1');
    expect(service.snapshotFor('workspace-1'), isNull);
    service.upsert('workspace-2', snapshot);
    service.clear();
    expect(service.snapshots, isEmpty);
  });

  test('streams configured commands and stops on the first failure', () async {
    final broadcasts = <Map<String, Object?>>[];
    final executed = <String>[];
    final service = WorkspaceSetupService(
      broadcast: broadcasts.add,
      loadCommands: (_) async => const ['first', 'second', 'never'],
      executeCommand: (command, cwd, environment, onOutput) async {
        executed.add(command);
        onOutput('$command output\r$command done\n');
        return WorkspaceSetupExecutionResult(
          exitCode: command == 'second' ? 7 : 0,
          output: '$command output\r$command done\n',
        );
      },
    );

    await service.run(
      workspaceId: 'workspace-1',
      workspacePath: '/repo/feature',
      branchName: 'feature',
      shouldBootstrap: true,
    );

    expect(executed, ['first', 'second']);
    final finalSnapshot = service.snapshotFor('workspace-1')!;
    expect(finalSnapshot.status, WorkspaceSetupStatus.failed);
    expect(finalSnapshot.detail.commands, hasLength(2));
    expect(finalSnapshot.detail.commands.map((command) => command.status), [
      WorkspaceSetupCommandStatus.completed,
      WorkspaceSetupCommandStatus.failed,
    ]);
    expect(finalSnapshot.detail.commands.first.log, 'first doneut\n');
    expect(finalSnapshot.detail.log, contains('==> [1/2] Running: first'));
    expect(finalSnapshot.detail.log, contains('<== [2/2] Exit 7 in '));
    expect(finalSnapshot.error, contains('second'));
    expect(
      broadcasts
          .map(WorkspaceSetupProgress.fromJson)
          .where(
            (progress) =>
                progress.snapshot.status == WorkspaceSetupStatus.running,
          ),
      isNotEmpty,
    );
  });

  test('emits running then completed when bootstrap is skipped', () async {
    final statuses = <WorkspaceSetupStatus>[];
    final service = WorkspaceSetupService(
      broadcast: (message) => statuses.add(
        WorkspaceSetupProgress.fromJson(message).snapshot.status,
      ),
      loadCommands: (_) => throw StateError('must not load'),
    );
    await service.run(
      workspaceId: 'workspace-1',
      workspacePath: '/repo/feature',
      branchName: 'feature',
      shouldBootstrap: false,
    );
    expect(statuses, [
      WorkspaceSetupStatus.running,
      WorkspaceSetupStatus.completed,
    ]);
  });

  test('configuration and executor failures become failed snapshots', () async {
    final configFailure = WorkspaceSetupService(
      broadcast: (_) {},
      loadCommands: (_) => throw const FormatException('bad config'),
    );
    await configFailure.run(
      workspaceId: 'config',
      workspacePath: '/repo',
      branchName: 'feature',
      shouldBootstrap: true,
    );
    expect(configFailure.snapshotFor('config')?.error, contains('bad config'));

    final executionFailure = WorkspaceSetupService(
      broadcast: (_) {},
      loadCommands: (_) async => const ['install'],
      executeCommand: (_, _, _, _) => throw StateError('spawn failed'),
    );
    await executionFailure.run(
      workspaceId: 'spawn',
      workspacePath: '/repo',
      branchName: 'feature',
      shouldBootstrap: true,
    );
    expect(
      executionFailure.snapshotFor('spawn')?.status,
      WorkspaceSetupStatus.failed,
    );
  });

  test('resolves branded and compatibility runtime env before execution '
      'and registers it for later terminals', () async {
    Map<String, String>? executedEnvironment;
    Map<String, String>? registeredEnvironment;
    final service = WorkspaceSetupService(
      broadcast: (_) {},
      loadCommands: (_) async => const ['install'],
      resolveEnvironment: (workspace, branch, source) async {
        expect(workspace, '/repo/worktree');
        expect(branch, 'feature');
        expect(source, '/repo/source');
        return const {
          'TINYRACK_WORKTREE_PORT': '45678',
          'PASEO_WORKTREE_PORT': '45678',
        };
      },
      registerEnvironment: (cwd, environment) {
        expect(cwd, '/repo/worktree');
        registeredEnvironment = environment;
      },
      executeCommand: (command, cwd, environment, onOutput) async {
        executedEnvironment = environment;
        return const WorkspaceSetupExecutionResult(exitCode: 0, output: '');
      },
    );

    final result = await service.run(
      workspaceId: 'workspace-1',
      workspacePath: '/repo/worktree',
      sourceCheckoutPath: '/repo/source',
      branchName: 'feature',
      shouldBootstrap: true,
    );

    expect(result.status, WorkspaceSetupStatus.completed);
    expect(result.setupStarted, isTrue);
    expect(executedEnvironment, {
      'TINYRACK_WORKTREE_PORT': '45678',
      'PASEO_WORKTREE_PORT': '45678',
    });
    expect(registeredEnvironment, executedEnvironment);
  });

  test('preflight failure is distinguishable from a started setup', () async {
    final service = WorkspaceSetupService(
      broadcast: (_) {},
      loadCommands: (_) async => const ['install'],
      resolveEnvironment: (_, _, _) => throw StateError('port unavailable'),
    );

    final result = await service.run(
      workspaceId: 'workspace-1',
      workspacePath: '/repo/worktree',
      branchName: 'feature',
      shouldBootstrap: true,
    );

    expect(result.status, WorkspaceSetupStatus.failed);
    expect(result.setupStarted, isFalse);
    expect(
      service.snapshotFor('workspace-1')?.error,
      contains('port unavailable'),
    );
  });

  test('bounds ANSI-stripped command output with middle truncation', () async {
    final service = WorkspaceSetupService(
      broadcast: (_) {},
      loadCommands: (_) async => const ['verbose'],
      executeCommand: (_, _, _, onOutput) async {
        onOutput('\x1b[31m${'a' * 70000}\x1b[0m');
        return const WorkspaceSetupExecutionResult(exitCode: 0, output: '');
      },
    );

    await service.run(
      workspaceId: 'workspace-1',
      workspacePath: '/repo/worktree',
      branchName: 'feature',
      shouldBootstrap: true,
    );

    final detail = service.snapshotFor('workspace-1')!.detail;
    expect(detail.truncated, isTrue);
    expect(
      detail.commands.single.log,
      contains('output truncated in the middle'),
    );
    expect(detail.commands.single.log, isNot(contains('\x1b')));
    expect(
      utf8.encode(detail.commands.single.log).length,
      lessThanOrEqualTo(65536),
    );
  });

  test('loads branded setup config before compatible paseo config', () async {
    final temp = await Directory.systemTemp.createTemp('workspace-setup-');
    addTearDown(() => temp.delete(recursive: true));
    await File(
      '${temp.path}${Platform.pathSeparator}paseo.json',
    ).writeAsString('{"worktree":{"setup":["paseo"]}}');
    await File(
      '${temp.path}${Platform.pathSeparator}tinyrack.json',
    ).writeAsString('{"worktree":{"setup":"tinyrack"}}');
    final executed = <String>[];
    final service = WorkspaceSetupService(
      broadcast: (_) {},
      executeCommand: (command, _, _, _) async {
        executed.add(command);
        return const WorkspaceSetupExecutionResult(exitCode: 0, output: '');
      },
    );

    await service.run(
      workspaceId: 'workspace-1',
      workspacePath: temp.path,
      branchName: 'feature',
      shouldBootstrap: true,
    );

    expect(executed, ['tinyrack']);
    expect(
      service.snapshotFor('workspace-1')?.status,
      WorkspaceSetupStatus.completed,
    );
  });

  test('default executor streams shell output', () async {
    final temp = await Directory.systemTemp.createTemp(
      'workspace-setup-shell-',
    );
    addTearDown(() => temp.delete(recursive: true));
    await File(
      '${temp.path}${Platform.pathSeparator}tinyrack.json',
    ).writeAsString('{"worktree":{"setup":"echo setup-ok"}}');
    final service = WorkspaceSetupService(broadcast: (_) {});

    await service.run(
      workspaceId: 'workspace-1',
      workspacePath: temp.path,
      branchName: 'feature',
      shouldBootstrap: true,
    );

    final result = service.snapshotFor('workspace-1')!;
    expect(result.status, WorkspaceSetupStatus.completed);
    expect(result.detail.log, contains('setup-ok'));
    expect(result.detail.commands.single.exitCode, 0);
  });

  test(
    'default runtime environment exposes branded and Paseo aliases',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'workspace-setup-environment-',
      );
      final source = await Directory.systemTemp.createTemp(
        'workspace-setup-source-',
      );
      addTearDown(() async {
        await temp.delete(recursive: true);
        await source.delete(recursive: true);
      });
      await File(
        '${temp.path}${Platform.pathSeparator}tinyrack.json',
      ).writeAsString('{"worktree":{"setup":"inspect"}}');
      await Process.run('git', [
        'init',
        '-b',
        'main',
      ], workingDirectory: temp.path);
      writeWorktreeBaseMetadata(temp.path, baseRefName: 'main');
      Map<String, String>? captured;
      final service = WorkspaceSetupService(
        broadcast: (_) {},
        executeCommand: (_, _, environment, _) async {
          captured = environment;
          return const WorkspaceSetupExecutionResult(exitCode: 0, output: '');
        },
      );

      await service.run(
        workspaceId: 'workspace-1',
        workspacePath: temp.path,
        sourceCheckoutPath: source.path,
        branchName: 'feature/runtime',
        shouldBootstrap: true,
      );

      expect(captured?['TINYRACK_SOURCE_CHECKOUT_PATH'], source.absolute.path);
      expect(captured?['PASEO_SOURCE_CHECKOUT_PATH'], source.absolute.path);
      expect(captured?['TINYRACK_WORKTREE_PATH'], temp.absolute.path);
      expect(captured?['PASEO_BRANCH_NAME'], 'feature/runtime');
      expect(
        int.parse(captured!['TINYRACK_WORKTREE_PORT']!),
        inInclusiveRange(1, 65535),
      );
      expect(
        captured?['PASEO_WORKTREE_PORT'],
        captured?['TINYRACK_WORKTREE_PORT'],
      );
      expect(
        readWorktreeRuntimePort(temp.path),
        int.parse(captured!['TINYRACK_WORKTREE_PORT']!),
      );

      Map<String, String>? repeated;
      final second = WorkspaceSetupService(
        broadcast: (_) {},
        executeCommand: (_, _, environment, _) async {
          repeated = environment;
          return const WorkspaceSetupExecutionResult(exitCode: 0, output: '');
        },
      );
      await second.run(
        workspaceId: 'workspace-2',
        workspacePath: temp.path,
        sourceCheckoutPath: source.path,
        branchName: 'feature/runtime',
        shouldBootstrap: true,
      );
      expect(
        repeated?['TINYRACK_WORKTREE_PORT'],
        captured?['TINYRACK_WORKTREE_PORT'],
      );
    },
  );

  test('persisted occupied runtime port fails before setup starts', () async {
    final temp = await Directory.systemTemp.createTemp(
      'workspace-setup-occupied-port-',
    );
    addTearDown(() async {
      await temp.delete(recursive: true);
    });
    await Process.run('git', [
      'init',
      '-b',
      'main',
    ], workingDirectory: temp.path);
    writeWorktreeBaseMetadata(temp.path, baseRefName: 'main');
    final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(occupied.close);
    writeWorktreeRuntimeMetadata(temp.path, worktreePort: occupied.port);
    await File(
      '${temp.path}${Platform.pathSeparator}tinyrack.json',
    ).writeAsString('{"worktree":{"setup":"must-not-run"}}');
    var executed = false;
    final service = WorkspaceSetupService(
      broadcast: (_) {},
      executeCommand: (_, _, _, _) async {
        executed = true;
        return const WorkspaceSetupExecutionResult(exitCode: 0, output: '');
      },
    );

    final result = await service.run(
      workspaceId: 'workspace-occupied',
      workspacePath: temp.path,
      sourceCheckoutPath: temp.path,
      branchName: 'feature/occupied',
      shouldBootstrap: true,
    );

    expect(result.status, WorkspaceSetupStatus.failed);
    expect(result.setupStarted, isFalse);
    expect(executed, isFalse);
    expect(service.snapshotFor('workspace-occupied')?.error, isNotEmpty);
  });
}
