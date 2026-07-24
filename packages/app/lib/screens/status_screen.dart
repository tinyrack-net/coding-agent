import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../state/daemon_lifecycle_provider.dart';
import '../state/daemon_providers.dart';

/// M0 screen: shows daemon connection state and available providers.
class StatusScreen extends ConsumerWidget {
  const StatusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(daemonClientProvider);
    final connection =
        ref.watch(connectionStateProvider).value ?? client.currentState;
    final providers = ref.watch(providerListProvider);
    final rejectedHello = client.rejectedHello;
    final lifecycle = ref.watch(daemonLifecycleProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Coding Agent')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 12,
                  color: switch (connection) {
                    DaemonConnectionState.connected => Colors.greenAccent,
                    DaemonConnectionState.connecting => Colors.amber,
                    DaemonConnectionState.disconnected => Colors.redAccent,
                    DaemonConnectionState.versionMismatch =>
                      Colors.orangeAccent,
                  },
                ),
                const SizedBox(width: 8),
                Text(
                  switch (connection) {
                    DaemonConnectionState.connected => 'Daemon connected',
                    DaemonConnectionState.connecting => 'Connecting…',
                    DaemonConnectionState.disconnected =>
                      'Daemon not reachable (retrying)',
                    DaemonConnectionState.versionMismatch =>
                      'Incompatible daemon version',
                  },
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            if (connection == DaemonConnectionState.versionMismatch &&
                rejectedHello != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  versionMismatchMessage(rejectedHello),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            if (lifecycle case AsyncError(:final error))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Failed to start local daemon:\n$error',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            Text('Providers', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Expanded(
              child: providers.when(
                data: (list) => list.isEmpty
                    ? const Text('No providers reported yet.')
                    : ListView(
                        children: [
                          for (final provider in list)
                            Card(
                              child: ListTile(
                                leading: Icon(
                                  provider.available
                                      ? Icons.check_circle
                                      : Icons.cancel,
                                  color: provider.available
                                      ? Colors.greenAccent
                                      : Colors.redAccent,
                                ),
                                title: Text(provider.displayName),
                                subtitle: Text(
                                  provider.available
                                      ? '${provider.version}\n${provider.executablePath}'
                                      : provider.unavailableReason ??
                                          'unavailable',
                                ),
                                isThreeLine: provider.available,
                              ),
                            ),
                        ],
                      ),
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Text('Failed to list providers: $e'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
