import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';
import 'host_registry_provider.dart';

typedef WorkspaceCheckoutStatusKey = ({String serverId, String cwd});

final checkoutStatusDaemonClientProvider =
    Provider.family<DaemonClient?, String>((ref, serverId) {
      final activeHost = ref.watch(activeHostProvider);
      if (activeHost?.serverId == serverId) {
        return ref.watch(daemonClientProvider);
      }
      final hostClient = ref.watch(hostDaemonClientProvider(serverId));
      if (hostClient != null) return hostClient;
      if (activeHost != null && activeHost.serverId != serverId) return null;
      final legacy = ref.watch(daemonClientProvider);
      final actualServerId = legacy.serverInfo?.serverId;
      return actualServerId == null || actualServerId == serverId
          ? legacy
          : null;
    });

final checkoutStatusConnectionProvider =
    StreamProvider.family<DaemonConnectionState, String>((
      ref,
      serverId,
    ) async* {
      final client = ref.watch(checkoutStatusDaemonClientProvider(serverId));
      if (client == null) {
        yield DaemonConnectionState.disconnected;
        return;
      }
      yield client.currentState;
      yield* client.connectionState;
    });

final class WorkspaceCheckoutStatusNotifier
    extends AsyncNotifier<CheckoutStatusPayload?> {
  WorkspaceCheckoutStatusNotifier(this.key);

  final WorkspaceCheckoutStatusKey key;

  @override
  Future<CheckoutStatusPayload?> build() async {
    final client = ref.watch(checkoutStatusDaemonClientProvider(key.serverId));
    final connection = ref
        .watch(checkoutStatusConnectionProvider(key.serverId))
        .value;
    if (client == null ||
        (connection ?? client.currentState) !=
            DaemonConnectionState.connected ||
        key.cwd.trim().isEmpty) {
      return null;
    }

    final updates = client.checkoutStatusUpdates
        .where((update) => update.payload.cwd == key.cwd)
        .listen((update) {
          if (ref.mounted) state = AsyncData(update.payload);
        });
    ref.onDispose(() => unawaited(updates.cancel()));

    final response = CheckoutStatusResponse.fromJson(
      await client.requestSessionMessage(
        CheckoutStatusRequest(
          cwd: key.cwd,
          requestId: const Uuid().v4(),
        ).toJson(),
      ),
    );
    return response.payload;
  }
}

final workspaceCheckoutStatusProvider =
    AsyncNotifierProvider.family<
      WorkspaceCheckoutStatusNotifier,
      CheckoutStatusPayload?,
      WorkspaceCheckoutStatusKey
    >(WorkspaceCheckoutStatusNotifier.new);
