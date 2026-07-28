import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  const detail = WorkspaceSetupDetail(
    worktreePath: r'C:\repo\feature',
    branchName: 'feature',
    log: 'installing',
    commands: [
      WorkspaceSetupCommand(
        index: 1,
        command: 'dart pub get',
        cwd: r'C:\repo\feature',
        status: WorkspaceSetupCommandStatus.completed,
        exitCode: 0,
        durationMs: 1250,
      ),
    ],
    truncated: false,
  );
  const snapshot = WorkspaceSetupSnapshot(
    status: WorkspaceSetupStatus.completed,
    detail: detail,
    error: null,
  );

  test('round trips setup progress and cached response', () {
    final progress = WorkspaceSetupProgress.fromJson(
      const WorkspaceSetupProgress(
        workspaceId: 'workspace-1',
        snapshot: snapshot,
      ).toJson(),
    );
    expect(progress.workspaceId, 'workspace-1');
    expect(progress.snapshot.detail.commands.single.log, '');
    expect(progress.snapshot.detail.commands.single.durationMs, 1250);

    final response = WorkspaceSetupStatusResponse.fromJson(
      const WorkspaceSetupStatusResponse(
        requestId: 'request-1',
        workspaceId: 'workspace-1',
        snapshot: snapshot,
      ).toJson(),
    );
    expect(response.snapshot?.status, WorkspaceSetupStatus.completed);
    expect(response.toJson()['type'], WorkspaceSetupStatusResponse.type);
  });

  test('accepts null snapshot and defaults omitted command log', () {
    final request = WorkspaceSetupStatusRequest.fromJson({
      'type': WorkspaceSetupStatusRequest.type,
      'workspaceId': 'workspace-1',
      'requestId': 'request-1',
    });
    expect(request.workspaceId, 'workspace-1');

    final response = WorkspaceSetupStatusResponse.fromJson({
      'type': WorkspaceSetupStatusResponse.type,
      'payload': {
        'requestId': 'request-1',
        'workspaceId': 'workspace-1',
        'snapshot': null,
      },
    });
    expect(response.snapshot, isNull);

    final command = WorkspaceSetupCommand.fromJson({
      'index': 1,
      'command': 'flutter pub get',
      'cwd': 'repo',
      'status': 'running',
      'exitCode': null,
    });
    expect(command.log, '');
  });

  test('rejects schema boundary violations', () {
    expect(
      () => WorkspaceSetupCommand.fromJson({
        'index': 0,
        'command': 'bad',
        'cwd': 'repo',
        'status': 'running',
        'exitCode': null,
      }),
      throwsFormatException,
    );
    expect(
      () => WorkspaceSetupCommand.fromJson({
        'index': 1,
        'command': 'bad',
        'cwd': 'repo',
        'status': 'running',
        'exitCode': null,
        'durationMs': -1,
      }),
      throwsFormatException,
    );
    expect(
      () => WorkspaceSetupDetail.fromJson({
        'type': 'shell',
        'worktreePath': 'repo',
        'branchName': 'feature',
        'log': '',
        'commands': const [],
      }),
      throwsFormatException,
    );
  });
}
