import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/state/workspace_setup_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const snapshot = WorkspaceSetupSnapshot(
    status: WorkspaceSetupStatus.running,
    detail: WorkspaceSetupDetail(
      worktreePath: '/repo/feature',
      branchName: 'feature',
      log: 'one\rupdated\nnext',
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

  test('deduplicates in-flight status and stores matching snapshot', () async {
    final transport = _Transport();
    final container = ProviderContainer(
      overrides: [
        workspaceSetupStatusTransportProvider.overrideWithValue(transport),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(workspaceSetupStoreProvider.notifier);
    final first = notifier.ensureStatus(
      serverId: 'server-1',
      workspaceId: 'workspace-1',
    );
    final second = notifier.ensureStatus(
      serverId: 'server-1',
      workspaceId: 'workspace-1',
    );
    expect(transport.requests, ['workspace-1']);
    transport.completer.complete(
      const WorkspaceSetupStatusResponse(
        requestId: 'request-1',
        workspaceId: 'workspace-1',
        snapshot: snapshot,
      ),
    );
    await Future.wait([first, second]);

    const key = WorkspaceSetupKey(
      serverId: 'server-1',
      workspaceId: 'workspace-1',
    );
    expect(
      container.read(workspaceSetupStoreProvider).snapshots[key]?.snapshot,
      same(snapshot),
    );
    await notifier.ensureStatus(
      serverId: 'server-1',
      workspaceId: 'workspace-1',
    );
    expect(transport.requests, hasLength(1));
  });

  test('null, mismatch, and errors remain retryable', () async {
    final transport = _SequenceTransport([
      const WorkspaceSetupStatusResponse(
        requestId: '1',
        workspaceId: 'workspace-1',
        snapshot: null,
      ),
      const WorkspaceSetupStatusResponse(
        requestId: '2',
        workspaceId: 'other',
        snapshot: snapshot,
      ),
      StateError('offline'),
    ]);
    final container = ProviderContainer(
      overrides: [
        workspaceSetupStatusTransportProvider.overrideWithValue(transport),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(workspaceSetupStoreProvider.notifier);
    for (var index = 0; index < 3; index++) {
      await notifier.ensureStatus(
        serverId: 'server-1',
        workspaceId: 'workspace-1',
      );
    }
    expect(transport.calls, 3);
    expect(container.read(workspaceSetupStoreProvider).snapshots, isEmpty);
    expect(container.read(workspaceSetupStoreProvider).inFlight, isEmpty);
  });

  test('keeps hosts isolated and supports removal', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(workspaceSetupStoreProvider.notifier);
    notifier
      ..upsert(
        serverId: 'server-1',
        workspaceId: 'workspace-1',
        snapshot: snapshot,
      )
      ..upsert(
        serverId: 'server-2',
        workspaceId: 'workspace-1',
        snapshot: snapshot,
      )
      ..removeWorkspace(serverId: 'server-1', workspaceId: 'workspace-1');
    expect(container.read(workspaceSetupStoreProvider).snapshots, hasLength(1));
    notifier.clearServer('server-2');
    expect(container.read(workspaceSetupStoreProvider).snapshots, isEmpty);
  });

  test('live progress bridge upserts against the active daemon host', () async {
    final client = _ProgressClient();
    final container = ProviderContainer(
      overrides: [
        daemonClientProvider.overrideWithValue(client),
        activeHostProvider.overrideWithValue(null),
      ],
    );
    addTearDown(() {
      container.dispose();
      client.dispose();
    });
    const key = WorkspaceSetupKey(
      serverId: 'server-live',
      workspaceId: 'workspace-live',
    );
    container.read(workspaceSetupEntryProvider(key));

    client.add(
      const WorkspaceSetupProgress(
        workspaceId: 'workspace-live',
        snapshot: snapshot,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      container.read(workspaceSetupStoreProvider).snapshots[key]?.snapshot,
      same(snapshot),
    );
  });

  test('matches setup presentation helpers', () {
    expect(shouldShowWorkspaceSetup(null), isFalse);
    expect(shouldShowWorkspaceSetup(snapshot), isTrue);
    expect(
      shouldShowWorkspaceSetup(
        const WorkspaceSetupSnapshot(
          status: WorkspaceSetupStatus.completed,
          detail: WorkspaceSetupDetail(
            worktreePath: '/repo',
            branchName: 'main',
            log: '',
            commands: [],
          ),
          error: null,
        ),
      ),
      isFalse,
    );
    expect(
      shouldShowWorkspaceSetup(
        const WorkspaceSetupSnapshot(
          status: WorkspaceSetupStatus.failed,
          detail: WorkspaceSetupDetail(
            worktreePath: '/repo',
            branchName: 'main',
            log: '',
            commands: [],
          ),
          error: 'failed',
        ),
      ),
      isTrue,
    );
    expect(
      processWorkspaceSetupCarriageReturns('one\rupdated\nnext'),
      'updated\nnext',
    );
    expect(processWorkspaceSetupCarriageReturns('plain'), 'plain');
    expect(workspaceSetupAutoExpandIndex(snapshot.detail.commands), 1);
    expect(workspaceSetupAutoExpandIndex(const []), isNull);
    expect(
      workspaceSetupAutoExpandIndex(const [
        WorkspaceSetupCommand(
          index: 3,
          command: 'done',
          cwd: '/repo',
          status: WorkspaceSetupCommandStatus.completed,
          exitCode: 0,
        ),
      ]),
      3,
    );
    expect(formatWorkspaceSetupDuration(999), '999ms');
    expect(formatWorkspaceSetupDuration(2500), '2s');
    expect(formatWorkspaceSetupDuration(65000), '1m 5s');
  });
}

final class _Transport implements WorkspaceSetupStatusTransport {
  final completer = Completer<WorkspaceSetupStatusResponse>();
  final requests = <String>[];

  @override
  Future<WorkspaceSetupStatusResponse> fetch(String workspaceId) {
    requests.add(workspaceId);
    return completer.future;
  }
}

final class _SequenceTransport implements WorkspaceSetupStatusTransport {
  _SequenceTransport(this.results);

  final List<Object> results;
  var calls = 0;

  @override
  Future<WorkspaceSetupStatusResponse> fetch(String workspaceId) async {
    final result = results[calls++];
    if (result is WorkspaceSetupStatusResponse) return result;
    throw result;
  }
}

final class _ProgressClient extends DaemonClient {
  _ProgressClient() : super(uri: Uri.parse('ws://fake')) {
    serverInfo = const ServerInfoStatus(
      serverId: 'server-live',
      hostname: 'fake',
      version: '0.2.0',
      desktopManaged: false,
    );
  }

  final controller = StreamController<WorkspaceSetupProgress>.broadcast();

  @override
  Stream<WorkspaceSetupProgress> get workspaceSetupProgress =>
      controller.stream;

  void add(WorkspaceSetupProgress progress) => controller.add(progress);

  @override
  void dispose() {
    controller.close();
    super.dispose();
  }
}
