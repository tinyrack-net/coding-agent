import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../core/theme.dart';
import '../state/daemon_lifecycle_provider.dart';
import '../state/daemon_providers.dart';
import '../widgets/fluent/page_back_button.dart';

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

    return ScaffoldPage(
      header: const PageHeader(
        leading: PageBackButton(),
        title: Text('Coding Agent'),
      ),
      content: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  FluentIcons.circle_fill,
                  size: 12,
                  color: switch (connection) {
                    DaemonConnectionState.connected => Colors.green,
                    DaemonConnectionState.connecting => Colors.yellow,
                    DaemonConnectionState.disconnected => Colors.red,
                    DaemonConnectionState.versionMismatch => Colors.orange,
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                  switch (connection) {
                    DaemonConnectionState.connected => 'Daemon connected',
                    DaemonConnectionState.connecting => 'Connecting…',
                    DaemonConnectionState.disconnected =>
                      'Daemon not reachable (retrying)',
                    DaemonConnectionState.versionMismatch =>
                      'Incompatible daemon version',
                  },
                  style: context.textStyles.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (connection == DaemonConnectionState.versionMismatch &&
                rejectedHello != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  versionMismatchMessage(rejectedHello),
                  style: TextStyle(color: context.tokens.error),
                ),
              ),
            if (lifecycle case AsyncError(:final error))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Failed to start local daemon:\n$error',
                  style: TextStyle(color: context.tokens.error),
                ),
              ),
            const SizedBox(height: 24),
            Text('Providers', style: context.textStyles.titleLarge),
            const SizedBox(height: 8),
            Expanded(
              child: providers.when(
                data: (list) => list.isEmpty
                    ? const Text('No providers reported yet.')
                    : ListView(
                        children: [
                          for (final provider in list)
                            Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: ListTile(
                                leading: Icon(
                                  provider.configured
                                      ? FluentIcons.completed_solid
                                      : FluentIcons.status_error_full,
                                  color: provider.configured
                                      ? Colors.green
                                      : Colors.red,
                                ),
                                title: Text(provider.displayName),
                                subtitle: Text(
                                  provider.configured
                                      ? '${provider.models.length} models available'
                                      : provider.unavailableReason ??
                                          'not configured',
                                ),
                              ),
                            ),
                        ],
                      ),
                loading: () => const Center(child: ProgressRing()),
                error: (e, _) => Text('Failed to list providers: $e'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
