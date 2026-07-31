import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/host_registry_provider.dart';
import '../state/daemon_providers.dart';
import '../core/host_routes.dart';
import '../widgets/host_daemon_update_card.dart';
import '../widgets/provider_usage_settings_section.dart';
import 'host_connections_settings_screen.dart';
import 'host_providers_settings_section.dart';
import 'settings_screen.dart';

class HostSettingsRouteScreen extends ConsumerStatefulWidget {
  const HostSettingsRouteScreen({
    super.key,
    required this.serverId,
    required this.section,
  });

  final String serverId;
  final String section;

  @override
  ConsumerState<HostSettingsRouteScreen> createState() =>
      _HostSettingsRouteScreenState();
}

class _HostSettingsRouteScreenState
    extends ConsumerState<HostSettingsRouteScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(_activate);
  }

  @override
  void didUpdateWidget(covariant HostSettingsRouteScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId != widget.serverId) Future.microtask(_activate);
  }

  Future<void> _activate() async {
    final registry = ref.read(hostRegistryProvider);
    if (registry.hosts.any((host) => host.serverId == widget.serverId)) {
      await ref.read(hostRegistryProvider.notifier).selectHost(widget.serverId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(hostRegistryProvider);
    final section =
        normalizeHostSectionSlug(widget.section)?.name ??
        HostSectionSlug.connections.name;
    if (!registry.loaded) {
      return const Center(child: ProgressRing());
    }
    if (!registry.hosts.any((host) => host.serverId == widget.serverId)) {
      return const Center(child: Text('Host not found'));
    }
    if (section == 'connections') {
      return HostConnectionsSettingsScreen(serverId: widget.serverId);
    }
    if (section == 'providers') {
      return HostProvidersSettingsSection(serverId: widget.serverId);
    }
    if (section == 'usage') {
      return ScaffoldPage(
        header: const PageHeader(title: Text('Plan usage')),
        content: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                ProviderUsageSettingsSection(serverId: widget.serverId),
              ],
            ),
          ),
        ),
      );
    }
    if (section == 'host') {
      ref.watch(hostConnectionStateProvider(widget.serverId));
      final host = registry.hosts.firstWhere(
        (host) => host.serverId == widget.serverId,
      );
      final client = ref.watch(hostDaemonClientProvider(widget.serverId));
      return ScaffoldPage(
        header: const PageHeader(title: Text('Overview')),
        content: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(host.label),
                if (client != null) ...[
                  const SizedBox(height: 12),
                  HostDaemonUpdateCard(
                    hostLabel: host.label,
                    transport: ClientDaemonUpdateTransport(client),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    return SettingsScreen(section: section);
  }
}
