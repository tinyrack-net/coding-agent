import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';
import 'host_registry_provider.dart';

final class WorkspaceSetupKey {
  const WorkspaceSetupKey({required this.serverId, required this.workspaceId});

  final String serverId;
  final String workspaceId;

  @override
  bool operator ==(Object other) =>
      other is WorkspaceSetupKey &&
      other.serverId == serverId &&
      other.workspaceId == workspaceId;

  @override
  int get hashCode => Object.hash(serverId, workspaceId);
}

final class WorkspaceSetupEntry {
  const WorkspaceSetupEntry({required this.snapshot, required this.updatedAt});

  final WorkspaceSetupSnapshot snapshot;
  final DateTime updatedAt;
}

final class WorkspaceSetupStoreState {
  const WorkspaceSetupStoreState({
    this.snapshots = const {},
    this.inFlight = const {},
  });

  final Map<WorkspaceSetupKey, WorkspaceSetupEntry> snapshots;
  final Set<WorkspaceSetupKey> inFlight;

  WorkspaceSetupStoreState copyWith({
    Map<WorkspaceSetupKey, WorkspaceSetupEntry>? snapshots,
    Set<WorkspaceSetupKey>? inFlight,
  }) => WorkspaceSetupStoreState(
    snapshots: snapshots ?? this.snapshots,
    inFlight: inFlight ?? this.inFlight,
  );
}

abstract interface class WorkspaceSetupStatusTransport {
  Future<WorkspaceSetupStatusResponse> fetch(String workspaceId);
}

final class DaemonWorkspaceSetupStatusTransport
    implements WorkspaceSetupStatusTransport {
  const DaemonWorkspaceSetupStatusTransport(this.client);

  final DaemonClient client;

  @override
  Future<WorkspaceSetupStatusResponse> fetch(String workspaceId) =>
      client.fetchWorkspaceSetupStatus(workspaceId);
}

final workspaceSetupStatusTransportProvider =
    Provider<WorkspaceSetupStatusTransport>(
      (ref) =>
          DaemonWorkspaceSetupStatusTransport(ref.watch(daemonClientProvider)),
    );

final workspaceSetupStoreProvider =
    NotifierProvider<WorkspaceSetupStoreNotifier, WorkspaceSetupStoreState>(
      WorkspaceSetupStoreNotifier.new,
    );

class WorkspaceSetupStoreNotifier extends Notifier<WorkspaceSetupStoreState> {
  @override
  WorkspaceSetupStoreState build() => const WorkspaceSetupStoreState();

  void upsert({
    required String serverId,
    required String workspaceId,
    required WorkspaceSetupSnapshot snapshot,
    DateTime? updatedAt,
  }) {
    final key = WorkspaceSetupKey(serverId: serverId, workspaceId: workspaceId);
    state = state.copyWith(
      snapshots: Map.unmodifiable({
        ...state.snapshots,
        key: WorkspaceSetupEntry(
          snapshot: snapshot,
          updatedAt: updatedAt ?? DateTime.now(),
        ),
      }),
    );
  }

  Future<void> ensureStatus({
    required String serverId,
    required String workspaceId,
  }) async {
    final key = WorkspaceSetupKey(serverId: serverId, workspaceId: workspaceId);
    if (state.snapshots.containsKey(key) || state.inFlight.contains(key)) {
      return;
    }
    state = state.copyWith(
      inFlight: Set.unmodifiable({...state.inFlight, key}),
    );
    try {
      final response = await ref
          .read(workspaceSetupStatusTransportProvider)
          .fetch(workspaceId);
      if (response.workspaceId == workspaceId && response.snapshot != null) {
        upsert(
          serverId: serverId,
          workspaceId: workspaceId,
          snapshot: response.snapshot!,
        );
      }
    } on Object {
      // Unsupported/failed requests remain retryable, matching Paseo.
    } finally {
      if (ref.mounted) {
        state = state.copyWith(
          inFlight: Set.unmodifiable({...state.inFlight}..remove(key)),
        );
      }
    }
  }

  void removeWorkspace({
    required String serverId,
    required String workspaceId,
  }) {
    final key = WorkspaceSetupKey(serverId: serverId, workspaceId: workspaceId);
    if (!state.snapshots.containsKey(key)) return;
    state = state.copyWith(
      snapshots: Map.unmodifiable({...state.snapshots}..remove(key)),
    );
  }

  void clearServer(String serverId) {
    final snapshots = Map<WorkspaceSetupKey, WorkspaceSetupEntry>.from(
      state.snapshots,
    )..removeWhere((key, _) => key.serverId == serverId);
    final inFlight = {...state.inFlight}
      ..removeWhere((key) => key.serverId == serverId);
    state = WorkspaceSetupStoreState(
      snapshots: Map.unmodifiable(snapshots),
      inFlight: Set.unmodifiable(inFlight),
    );
  }
}

/// Connects the active daemon's live progress stream to the host-keyed store.
///
/// The store itself does not watch host selection, so switching hosts does not
/// discard snapshots belonging to another host.
final workspaceSetupProgressBridgeProvider = Provider<void>((ref) {
  final client = ref.watch(daemonClientProvider);
  final activeHost = ref.watch(activeHostProvider);
  final fallbackServerId = client.serverInfo?.serverId ?? 'local';
  final serverId = activeHost?.serverId ?? fallbackServerId;
  final subscription = client.workspaceSetupProgress.listen((progress) {
    ref
        .read(workspaceSetupStoreProvider.notifier)
        .upsert(
          serverId: serverId,
          workspaceId: progress.workspaceId,
          snapshot: progress.snapshot,
        );
  });
  ref.onDispose(subscription.cancel);
});

final workspaceSetupEntryProvider =
    Provider.family<WorkspaceSetupEntry?, WorkspaceSetupKey>((ref, key) {
      ref.watch(workspaceSetupProgressBridgeProvider);
      return ref.watch(
        workspaceSetupStoreProvider.select((state) => state.snapshots[key]),
      );
    });

bool shouldShowWorkspaceSetup(WorkspaceSetupSnapshot? snapshot) =>
    snapshot != null &&
    (snapshot.error != null || snapshot.detail.commands.isNotEmpty);

String processWorkspaceSetupCarriageReturns(String text) {
  if (!text.contains('\r')) return text;
  return text
      .split('\n')
      .map((line) => line.contains('\r') ? line.split('\r').last : line)
      .join('\n');
}

int? workspaceSetupAutoExpandIndex(List<WorkspaceSetupCommand> commands) {
  for (final command in commands) {
    if (command.status == WorkspaceSetupCommandStatus.running) {
      return command.index;
    }
  }
  return commands.isEmpty ? null : commands.last.index;
}

String formatWorkspaceSetupDuration(num milliseconds) {
  final ms = milliseconds.floor();
  if (ms < 1000) return '${ms}ms';
  final seconds = ms ~/ 1000;
  if (seconds < 60) return '${seconds}s';
  return '${seconds ~/ 60}m ${seconds % 60}s';
}
