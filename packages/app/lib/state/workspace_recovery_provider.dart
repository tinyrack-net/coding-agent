import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import 'agents_provider.dart';
import 'daemon_providers.dart';
import 'workspace_catalog_provider.dart';

enum WorkspaceRecoveryPhase { ready, restoring, failed }

sealed class WorkspaceRecoveryModel {
  const WorkspaceRecoveryModel();
}

final class WorkspaceRecoveryIdle extends WorkspaceRecoveryModel {
  const WorkspaceRecoveryIdle();
}

final class WorkspaceRecoveryChecking extends WorkspaceRecoveryModel {
  const WorkspaceRecoveryChecking();
}

final class WorkspaceRecoveryNeedsHostUpgrade extends WorkspaceRecoveryModel {
  const WorkspaceRecoveryNeedsHostUpgrade();
}

final class WorkspaceRecoveryRecoverable extends WorkspaceRecoveryModel {
  const WorkspaceRecoveryRecoverable({
    required this.recovery,
    required this.phase,
    this.error,
  });

  final RecoverableWorkspaceState recovery;
  final WorkspaceRecoveryPhase phase;
  final String? error;
}

final class WorkspaceRecoveryUnsupportedAction extends WorkspaceRecoveryModel {
  const WorkspaceRecoveryUnsupportedAction(this.action);
  final String action;
}

final class WorkspaceRecoveryUnavailable extends WorkspaceRecoveryModel {
  const WorkspaceRecoveryUnavailable(this.recovery);
  final UnavailableWorkspaceState recovery;
}

final class WorkspaceRecoveryInspectionFailed extends WorkspaceRecoveryModel {
  const WorkspaceRecoveryInspectionFailed(this.error);
  final String error;
}

final class WorkspaceRecoveryRequest {
  const WorkspaceRecoveryRequest({
    required this.workspaceId,
    required this.agentId,
    this.enabled = true,
  });

  final String workspaceId;
  final String? agentId;
  final bool enabled;

  @override
  bool operator ==(Object other) =>
      other is WorkspaceRecoveryRequest &&
      other.workspaceId == workspaceId &&
      other.agentId == agentId &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(workspaceId, agentId, enabled);
}

abstract interface class WorkspaceRecoveryTransport {
  Future<WorkspaceRecoveryState> inspect(String workspaceId);
  Future<void> restore(String workspaceId);
  Future<void> refreshAgent(String agentId);
  Future<void> refreshWorkspaces();
}

final class DaemonWorkspaceRecoveryTransport
    implements WorkspaceRecoveryTransport {
  DaemonWorkspaceRecoveryTransport(this._ref);

  static const _uuid = Uuid();
  final Ref _ref;

  DaemonClient get _client => _ref.read(daemonClientProvider);

  @override
  Future<WorkspaceRecoveryState> inspect(String workspaceId) async {
    final response = WorkspaceRecoveryInspectResponse.fromJson(
      await _client.requestSessionMessage(
        WorkspaceRecoveryInspectRequest(
          workspaceId: workspaceId,
          requestId: _uuid.v4(),
        ).toJson(),
      ),
    );
    return response.state;
  }

  @override
  Future<void> restore(String workspaceId) async {
    final response = WorkspaceRecoveryRestoreResponse.fromJson(
      await _client.requestSessionMessage(
        WorkspaceRecoveryRestoreRequest(
          workspaceId: workspaceId,
          requestId: _uuid.v4(),
        ).toJson(),
      ),
    );
    if (!response.accepted) {
      throw StateError(response.error ?? 'Failed to recover workspace');
    }
  }

  @override
  Future<void> refreshAgent(String agentId) =>
      _ref.read(agentsProvider.notifier).refresh();

  @override
  Future<void> refreshWorkspaces() async {
    _ref.invalidate(workspaceCatalogProvider);
    await _ref.read(workspaceCatalogProvider.future);
  }
}

final workspaceRecoveryTransportProvider = Provider<WorkspaceRecoveryTransport>(
  DaemonWorkspaceRecoveryTransport.new,
);

/// `null` means the v2 hello has not arrived yet.
final workspaceRecoveryCapabilityProvider = Provider<bool?>((ref) {
  ref.watch(connectionStateProvider);
  return ref
      .watch(daemonClientProvider)
      .serverInfo
      ?.features['workspaceRecovery'];
});

final workspaceRecoveryLoadingDelayProvider = Provider<Duration>(
  (_) => const Duration(milliseconds: 350),
);

final class WorkspaceRecoveryNotifier extends Notifier<WorkspaceRecoveryModel> {
  WorkspaceRecoveryNotifier(this.request);

  final WorkspaceRecoveryRequest request;
  bool _inspectionStarted = false;

  WorkspaceRecoveryTransport get _transport =>
      ref.read(workspaceRecoveryTransportProvider);

  @override
  WorkspaceRecoveryModel build() {
    if (!request.enabled) return const WorkspaceRecoveryIdle();
    final supported = ref.watch(workspaceRecoveryCapabilityProvider);
    if (supported == null) return const WorkspaceRecoveryChecking();
    if (!supported) return const WorkspaceRecoveryNeedsHostUpgrade();
    if (!_inspectionStarted) {
      _inspectionStarted = true;
      scheduleMicrotask(inspect);
    }
    return const WorkspaceRecoveryChecking();
  }

  Future<void> inspect() async {
    state = const WorkspaceRecoveryChecking();
    try {
      final recovery = await _transport.inspect(request.workspaceId);
      state = switch (recovery) {
        RecoverableWorkspaceState(:final action)
            when action == 'restore' || action == 'unarchive' =>
          WorkspaceRecoveryRecoverable(
            recovery: recovery,
            phase: WorkspaceRecoveryPhase.ready,
          ),
        RecoverableWorkspaceState(:final action) =>
          WorkspaceRecoveryUnsupportedAction(action),
        UnavailableWorkspaceState() => WorkspaceRecoveryUnavailable(recovery),
      };
    } on Object catch (error) {
      state = WorkspaceRecoveryInspectionFailed(_errorMessage(error));
    }
  }

  Future<void> restore() async {
    final current = state;
    if (current is! WorkspaceRecoveryRecoverable ||
        current.phase == WorkspaceRecoveryPhase.restoring) {
      return;
    }
    state = WorkspaceRecoveryRecoverable(
      recovery: current.recovery,
      phase: WorkspaceRecoveryPhase.restoring,
    );
    try {
      final delay = ref.read(workspaceRecoveryLoadingDelayProvider);
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      await _transport.restore(request.workspaceId);
      if (request.agentId case final agentId? when agentId.isNotEmpty) {
        await _transport.refreshAgent(agentId);
      }
      await _transport.refreshWorkspaces();
      state = WorkspaceRecoveryRecoverable(
        recovery: current.recovery,
        phase: WorkspaceRecoveryPhase.ready,
      );
    } on Object catch (error) {
      state = WorkspaceRecoveryRecoverable(
        recovery: current.recovery,
        phase: WorkspaceRecoveryPhase.failed,
        error: _errorMessage(error),
      );
    }
  }
}

final workspaceRecoveryProvider =
    NotifierProvider.family<
      WorkspaceRecoveryNotifier,
      WorkspaceRecoveryModel,
      WorkspaceRecoveryRequest
    >(WorkspaceRecoveryNotifier.new);

String _errorMessage(Object error) {
  if (error is StateError) return error.message.toString();
  return error.toString();
}
