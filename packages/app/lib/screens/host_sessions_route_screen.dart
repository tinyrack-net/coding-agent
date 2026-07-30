import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/host_routes.dart';
import '../state/host_registry_provider.dart';

/// Compatibility route for Paseo's former host-scoped Sessions URL.
///
/// Sessions are global in Paseo 0.2.0. The host route still waits for the
/// registry boundary to decide whether the host is valid, then replaces
/// itself with `/sessions` without changing the active host.
class HostSessionsRouteScreen extends ConsumerStatefulWidget {
  const HostSessionsRouteScreen({super.key, required this.serverId});

  final String serverId;

  @override
  ConsumerState<HostSessionsRouteScreen> createState() =>
      _HostSessionsRouteScreenState();
}

class _HostSessionsRouteScreenState
    extends ConsumerState<HostSessionsRouteScreen> {
  String? _redirectTarget;

  void _redirect(String target) {
    if (_redirectTarget == target) return;
    _redirectTarget = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.replace(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(hostRegistryProvider);
    if (!registry.loaded) {
      return const Center(
        child: ProgressRing(key: ValueKey('host-sessions-route-loading')),
      );
    }

    final target = switch (resolveKnownHostRoute(
      routeServerId: widget.serverId,
      serverIds: registry.hosts.map((host) => host.serverId),
    )) {
      KnownHostRouteResolution.render => buildSessionsRoute(),
      KnownHostRouteResolution.openProject => buildOpenProjectRoute(),
      KnownHostRouteResolution.welcome => '/welcome',
    };
    _redirect(target);
    return const Center(
      child: ProgressRing(key: ValueKey('host-sessions-route-redirecting')),
    );
  }
}
