import 'package:agent_protocol/agent_protocol.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../core/theme.dart';
import '../state/daemon_providers.dart';
import '../state/host_registry_provider.dart';

class HostConnectionsSettingsScreen extends ConsumerWidget {
  const HostConnectionsSettingsScreen({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(hostRegistryProvider);
    final host = registry.hosts.where(
      (candidate) => candidate.serverId == serverId,
    );
    if (host.isEmpty) {
      return const ScaffoldPage(
        header: PageHeader(title: Text('Connections')),
        content: Center(child: Text('Host not found')),
      );
    }
    final profile = host.first;
    final client = ref.watch(daemonClientProvider);
    final connection =
        ref.watch(connectionStateProvider).value ?? client.currentState;

    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Connections'),
        commandBar: Text(
          profile.label,
          overflow: TextOverflow.ellipsis,
          style: context.textStyles.bodySmall,
        ),
      ),
      content: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Card(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (
                      var index = 0;
                      index < profile.connections.length;
                      index++
                    ) ...[
                      if (index > 0) const Divider(),
                      _ConnectionRow(
                        connection: profile.connections[index],
                        active:
                            registry.activeServerId == serverId &&
                            _matchesClient(
                              profile.connections[index],
                              client.uri,
                            ),
                        connectionState: connection,
                        remove: () => _confirmRemove(
                          context,
                          ref,
                          profile.connections[index],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    HostConnection connection,
  ) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => ContentDialog(
        title: const Text('Remove connection?'),
        content: Text(
          'Remove ${formatHostConnectionLabel(connection)} from this host?',
        ),
        actions: [
          Button(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove != true) return;
    await ref
        .read(hostRegistryProvider.notifier)
        .removeConnection(serverId, connection.id);
  }
}

class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({
    required this.connection,
    required this.active,
    required this.connectionState,
    required this.remove,
  });

  final HostConnection connection;
  final bool active;
  final DaemonConnectionState connectionState;
  final VoidCallback remove;

  @override
  Widget build(BuildContext context) {
    final status = active
        ? switch (connectionState) {
            DaemonConnectionState.connected => 'Connected',
            DaemonConnectionState.connecting => 'Connecting…',
            DaemonConnectionState.disconnected => 'Timeout',
            DaemonConnectionState.versionMismatch => 'Version mismatch',
          }
        : '—';
    return Padding(
      key: ValueKey('host-connection-${connection.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              formatHostConnectionLabel(connection),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(status, style: context.textStyles.bodySmall),
          const SizedBox(width: 8),
          Button(onPressed: remove, child: const Text('Remove')),
        ],
      ),
    );
  }
}

String formatHostConnectionLabel(HostConnection connection) {
  return switch (connection) {
    DirectTcpHostConnection() =>
      '${connection.useTls ? 'wss' : 'ws'}://${connection.endpoint}',
    DirectSocketHostConnection() => connection.path,
    DirectPipeHostConnection() => connection.path,
    RelayHostConnection() => 'Relay · ${connection.relayEndpoint}',
  };
}

bool _matchesClient(HostConnection connection, Uri uri) {
  if (connection is! DirectTcpHostConnection) return false;
  final endpoint = parseHostPort(connection.endpoint);
  return endpoint.host == uri.host &&
      endpoint.port == uri.port &&
      connection.useTls == (uri.scheme == 'wss');
}
