import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/workspace_catalog_provider.dart';
import 'package:coding_agent_app/state/workspace_recovery_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/legacy_agent_list_fetch_mixin.dart';

void main() {
  const request = WorkspaceRecoveryRequest(
    workspaceId: 'workspace-1',
    agentId: 'agent-1',
  );

  test('inspects and exposes supported recovery actions', () async {
    final transport = _FakeRecoveryTransport(
      inspection: const RecoverableWorkspaceState(
        workspaceId: 'workspace-1',
        workspaceName: 'Feature branch',
        action: 'restore',
        branch: 'feature',
      ),
    );
    final container = _container(transport);
    addTearDown(container.dispose);

    expect(
      container.read(workspaceRecoveryProvider(request)),
      isA<WorkspaceRecoveryChecking>(),
    );
    await _flush();

    final state = container.read(workspaceRecoveryProvider(request));
    expect(state, isA<WorkspaceRecoveryRecoverable>());
    final recoverable = state as WorkspaceRecoveryRecoverable;
    expect(recoverable.phase, WorkspaceRecoveryPhase.ready);
    expect(recoverable.recovery.action, 'restore');
    expect(transport.inspected, ['workspace-1']);
  });

  test(
    'restores workspace then selected agent and refreshes catalog',
    () async {
      final restoreGate = Completer<void>();
      final transport = _FakeRecoveryTransport(
        inspection: const RecoverableWorkspaceState(
          workspaceId: 'workspace-1',
          workspaceName: 'Feature branch',
          action: 'unarchive',
          branch: 'feature',
        ),
        restoreGate: restoreGate,
      );
      final container = _container(transport);
      addTearDown(container.dispose);
      container.read(workspaceRecoveryProvider(request));
      await _flush();

      final future = container
          .read(workspaceRecoveryProvider(request).notifier)
          .restore();
      expect(
        (container.read(workspaceRecoveryProvider(request))
                as WorkspaceRecoveryRecoverable)
            .phase,
        WorkspaceRecoveryPhase.restoring,
      );
      await container
          .read(workspaceRecoveryProvider(request).notifier)
          .restore();
      restoreGate.complete();
      await future;

      expect(transport.operations, [
        'restore:workspace-1',
        'agent:agent-1',
        'workspaces',
      ]);
      expect(
        (container.read(workspaceRecoveryProvider(request))
                as WorkspaceRecoveryRecoverable)
            .phase,
        WorkspaceRecoveryPhase.ready,
      );
    },
  );

  test('keeps restore failure recoverable for retry', () async {
    final transport = _FakeRecoveryTransport(
      inspection: const RecoverableWorkspaceState(
        workspaceId: 'workspace-1',
        workspaceName: 'Feature branch',
        action: 'restore',
        branch: 'feature',
      ),
      restoreError: StateError('Project root is missing'),
    );
    final container = _container(transport);
    addTearDown(container.dispose);
    container.read(workspaceRecoveryProvider(request));
    await _flush();

    await container.read(workspaceRecoveryProvider(request).notifier).restore();

    final state =
        container.read(workspaceRecoveryProvider(request))
            as WorkspaceRecoveryRecoverable;
    expect(state.phase, WorkspaceRecoveryPhase.failed);
    expect(state.error, 'Project root is missing');
  });

  test(
    'maps unavailable, unsupported, inspection error, and old host',
    () async {
      final unavailable = _FakeRecoveryTransport(
        inspection: const UnavailableWorkspaceState(
          workspaceId: 'workspace-1',
          reason: 'workspace_not_found',
          message: 'This workspace is no longer known to the host.',
        ),
      );
      final unavailableContainer = _container(unavailable);
      addTearDown(unavailableContainer.dispose);
      unavailableContainer.read(workspaceRecoveryProvider(request));
      await _flush();
      expect(
        unavailableContainer.read(workspaceRecoveryProvider(request)),
        isA<WorkspaceRecoveryUnavailable>(),
      );

      final unsupported = _FakeRecoveryTransport(
        inspection: const RecoverableWorkspaceState(
          workspaceId: 'workspace-1',
          workspaceName: 'Feature branch',
          action: 'repair_from_snapshot',
          branch: 'feature',
        ),
      );
      final unsupportedContainer = _container(unsupported);
      addTearDown(unsupportedContainer.dispose);
      unsupportedContainer.read(workspaceRecoveryProvider(request));
      await _flush();
      expect(
        unsupportedContainer.read(workspaceRecoveryProvider(request)),
        isA<WorkspaceRecoveryUnsupportedAction>(),
      );

      final failed = _FakeRecoveryTransport(
        inspection: const RecoverableWorkspaceState(
          workspaceId: 'unused',
          workspaceName: 'unused',
          action: 'restore',
          branch: null,
        ),
        inspectError: Exception('transport closed'),
      );
      final failedContainer = _container(failed);
      addTearDown(failedContainer.dispose);
      failedContainer.read(workspaceRecoveryProvider(request));
      await _flush();
      expect(
        failedContainer.read(workspaceRecoveryProvider(request)),
        isA<WorkspaceRecoveryInspectionFailed>(),
      );

      final oldHost = ProviderContainer(
        overrides: [
          workspaceRecoveryCapabilityProvider.overrideWithValue(false),
        ],
      );
      addTearDown(oldHost.dispose);
      expect(
        oldHost.read(workspaceRecoveryProvider(request)),
        isA<WorkspaceRecoveryNeedsHostUpgrade>(),
      );

      final waitingForHello = ProviderContainer(
        overrides: [
          workspaceRecoveryCapabilityProvider.overrideWithValue(null),
        ],
      );
      addTearDown(waitingForHello.dispose);
      expect(
        waitingForHello.read(workspaceRecoveryProvider(request)),
        isA<WorkspaceRecoveryChecking>(),
      );

      final disabled = ProviderContainer(
        overrides: [
          workspaceRecoveryCapabilityProvider.overrideWithValue(true),
        ],
      );
      addTearDown(disabled.dispose);
      expect(
        disabled.read(
          workspaceRecoveryProvider(
            const WorkspaceRecoveryRequest(
              workspaceId: 'workspace-1',
              agentId: null,
              enabled: false,
            ),
          ),
        ),
        isA<WorkspaceRecoveryIdle>(),
      );
    },
  );

  test(
    'daemon transport validates typed inspect and restore responses',
    () async {
      final client = _RecoveryDaemonClient();
      final container = ProviderContainer(
        overrides: [
          daemonClientProvider.overrideWithValue(client),
          workspaceCatalogProvider.overrideWithValue(const AsyncData([])),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(client.dispose);
      final transport = container.read(workspaceRecoveryTransportProvider);

      final inspected = await transport.inspect('workspace-1');
      expect(inspected, isA<RecoverableWorkspaceState>());
      await transport.restore('workspace-1');
      await transport.refreshAgent('agent-1');
      await transport.refreshWorkspaces();
      expect(client.sessionTypes, [
        'workspace.recovery.inspect.request',
        'workspace.recovery.restore.request',
        'refresh_agent_request',
      ]);

      client.rejectRestore = true;
      await expectLater(
        transport.restore('workspace-1'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'restore rejected',
          ),
        ),
      );
    },
  );
}

ProviderContainer _container(_FakeRecoveryTransport transport) =>
    ProviderContainer(
      overrides: [
        workspaceRecoveryCapabilityProvider.overrideWithValue(true),
        workspaceRecoveryLoadingDelayProvider.overrideWithValue(Duration.zero),
        workspaceRecoveryTransportProvider.overrideWithValue(transport),
      ],
    );

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _FakeRecoveryTransport implements WorkspaceRecoveryTransport {
  _FakeRecoveryTransport({
    required this.inspection,
    this.inspectError,
    this.restoreError,
    this.restoreGate,
  });

  final WorkspaceRecoveryState inspection;
  final Object? inspectError;
  final Object? restoreError;
  final Completer<void>? restoreGate;
  final List<String> inspected = [];
  final List<String> operations = [];

  @override
  Future<WorkspaceRecoveryState> inspect(String workspaceId) async {
    inspected.add(workspaceId);
    if (inspectError case final error?) throw error;
    return inspection;
  }

  @override
  Future<void> restore(String workspaceId) async {
    operations.add('restore:$workspaceId');
    await restoreGate?.future;
    if (restoreError case final error?) throw error;
  }

  @override
  Future<void> refreshAgent(String agentId) async {
    operations.add('agent:$agentId');
  }

  @override
  Future<void> refreshWorkspaces() async {
    operations.add('workspaces');
  }
}

final class _RecoveryDaemonClient extends DaemonClient
    with LegacyAgentListFetchMixin {
  _RecoveryDaemonClient() : super(uri: Uri.parse('ws://fake'));

  bool rejectRestore = false;
  final List<String> sessionTypes = [];

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async => switch (type) {
    MessageTypes.agentListRequest => const {'agents': []},
    _ => const {},
  };

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final type = message['type']! as String;
    sessionTypes.add(type);
    final requestId = message['requestId']! as String;
    return switch (type) {
      'workspace.recovery.inspect.request' => WorkspaceRecoveryInspectResponse(
        requestId: requestId,
        state: const RecoverableWorkspaceState(
          workspaceId: 'workspace-1',
          workspaceName: 'Feature branch',
          action: 'restore',
          branch: 'feature',
        ),
      ).toJson(),
      'workspace.recovery.restore.request' => WorkspaceRecoveryRestoreResponse(
        requestId: requestId,
        workspaceId: 'workspace-1',
        accepted: !rejectRestore,
        error: rejectRestore ? 'restore rejected' : null,
      ).toJson(),
      'refresh_agent_request' => AgentRefreshedStatus(
        requestId: requestId,
        agentId: message['agentId']! as String,
        timelineSize: 2,
      ).toJson(),
      _ => throw StateError('unexpected session message: $type'),
    };
  }
}
