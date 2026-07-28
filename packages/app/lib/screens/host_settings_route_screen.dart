import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/host_registry_provider.dart';
import 'host_connections_settings_screen.dart';
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
    if (!registry.loaded) {
      return const Center(child: ProgressRing());
    }
    if (!registry.hosts.any((host) => host.serverId == widget.serverId)) {
      return const Center(child: Text('Host not found'));
    }
    if (widget.section == 'connections') {
      return HostConnectionsSettingsScreen(serverId: widget.serverId);
    }
    return SettingsScreen(section: widget.section);
  }
}
