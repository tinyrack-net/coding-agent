import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/host_routes.dart';
import '../state/host_registry_provider.dart';

/// Compatibility route for Paseo's stable host-scoped open-project URL.
///
/// The host boundary must hydrate before the leaf redirects so a cold native
/// deep link cannot outrun the persisted host registry.
class HostOpenProjectRouteScreen extends ConsumerStatefulWidget {
  const HostOpenProjectRouteScreen({super.key});

  @override
  ConsumerState<HostOpenProjectRouteScreen> createState() =>
      _HostOpenProjectRouteScreenState();
}

class _HostOpenProjectRouteScreenState
    extends ConsumerState<HostOpenProjectRouteScreen> {
  var _redirectScheduled = false;

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(hostRegistryProvider);
    if (!registry.loaded) {
      return const Center(
        child: ProgressRing(key: ValueKey('host-open-project-loading')),
      );
    }
    if (!_redirectScheduled) {
      _redirectScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.replace(buildOpenProjectRoute());
      });
    }
    return const Center(
      child: ProgressRing(key: ValueKey('host-open-project-redirecting')),
    );
  }
}
