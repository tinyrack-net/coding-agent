import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/host_registry_provider.dart';
import 'sessions_screen.dart';

/// Global Sessions route boundary.
///
/// Paseo does not render the all-host history until the persisted host
/// registry has hydrated. Otherwise a cold deep link can briefly commit an
/// empty history before the known hosts and their runtime clients exist.
class SessionsRouteScreen extends ConsumerWidget {
  const SessionsRouteScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(hostRegistryProvider).loaded) {
      return const Center(
        child: ProgressRing(key: ValueKey('sessions-route-loading')),
      );
    }
    return const SessionsScreen();
  }
}
