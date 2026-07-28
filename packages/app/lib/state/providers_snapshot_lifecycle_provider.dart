import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../providers/providers_snapshot.dart';
import 'daemon_providers.dart';
import 'providers_snapshot_provider.dart';

final providersSnapshotReplicaLifecycleProvider = Provider<void>((ref) {
  final clients = ref.watch(hostRuntimeClientsProvider);
  final subscriptions = <StreamSubscription<DaemonConnectionState>>[];

  void prefetch(String serverId, DaemonClient client) {
    if (client.currentState != DaemonConnectionState.connected ||
        client.serverInfo?.features['providersSnapshot'] != true) {
      return;
    }
    unawaited(
      Future<void>.microtask(() async {
        if (!ref.mounted) return;
        await ref
            .read(
              providersSnapshotProvider(
                ProvidersSnapshotScope(client: client, serverId: serverId),
              ).notifier,
            )
            .ensureLoaded();
      }),
    );
  }

  for (final entry in clients.entries) {
    prefetch(entry.key, entry.value);
    subscriptions.add(
      entry.value.connectionState.listen((connection) {
        if (connection == DaemonConnectionState.connected) {
          prefetch(entry.key, entry.value);
        }
      }),
    );
  }
  ref.onDispose(() {
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
  });
});
