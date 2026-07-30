import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';
import 'host_registry_provider.dart';

typedef WorkspaceCheckoutStatusKey = ({String serverId, String cwd});

final class CheckoutStatusPushCacheNotifier
    extends Notifier<Map<WorkspaceCheckoutStatusKey, CheckoutStatusUpdate>> {
  @override
  Map<WorkspaceCheckoutStatusKey, CheckoutStatusUpdate> build() => const {};

  void apply(String serverId, CheckoutStatusUpdate update) {
    final key = (serverId: serverId, cwd: update.payload.cwd);
    state = Map.unmodifiable({...state, key: update});
    ref
        .read(checkoutCommitsInvalidationProvider.notifier)
        .invalidate(serverId, update.payload.cwd);
  }
}

final checkoutStatusPushCacheProvider =
    NotifierProvider<
      CheckoutStatusPushCacheNotifier,
      Map<WorkspaceCheckoutStatusKey, CheckoutStatusUpdate>
    >(CheckoutStatusPushCacheNotifier.new);

final class CheckoutCommitsInvalidationNotifier
    extends Notifier<Map<WorkspaceCheckoutStatusKey, int>> {
  @override
  Map<WorkspaceCheckoutStatusKey, int> build() => const {};

  void invalidate(String serverId, String cwd) {
    final key = (serverId: serverId, cwd: cwd);
    state = Map.unmodifiable({...state, key: (state[key] ?? 0) + 1});
  }
}

/// Revision token consumed by checkout-commit queries. Every frozen status
/// push invalidates only the matching host/cwd tuple.
final checkoutCommitsInvalidationProvider =
    NotifierProvider<
      CheckoutCommitsInvalidationNotifier,
      Map<WorkspaceCheckoutStatusKey, int>
    >(CheckoutCommitsInvalidationNotifier.new);

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

/// Installs the frozen global checkout-status event boundary for one host.
///
/// Status queries and PR panes share this cache, so push freshness does not
/// depend on which surface mounted first.
final checkoutStatusPushRouterProvider = Provider.family<void, String>((
  ref,
  serverId,
) {
  final client = ref.watch(checkoutStatusDaemonClientProvider(serverId));
  if (client == null) return;
  final updates = client.checkoutStatusUpdates.listen(
    (update) => ref
        .read(checkoutStatusPushCacheProvider.notifier)
        .apply(serverId, update),
  );
  ref.onDispose(() => unawaited(updates.cancel()));
});

final class WorkspaceCheckoutStatusNotifier
    extends AsyncNotifier<CheckoutStatusPayload?> {
  WorkspaceCheckoutStatusNotifier(this.key);

  final WorkspaceCheckoutStatusKey key;

  @override
  Future<CheckoutStatusPayload?> build() async {
    ref.watch(checkoutStatusPushRouterProvider(key.serverId));
    final client = ref.watch(checkoutStatusDaemonClientProvider(key.serverId));
    final pushed = ref.watch(
      checkoutStatusPushCacheProvider.select((cache) => cache[key]),
    );
    final connection = ref
        .watch(checkoutStatusConnectionProvider(key.serverId))
        .value;
    if (client == null || key.cwd.trim().isEmpty) {
      return null;
    }
    if (pushed != null) return pushed.payload;
    if ((connection ?? client.currentState) !=
        DaemonConnectionState.connected) {
      return state.value;
    }

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
