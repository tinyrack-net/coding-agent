import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/sidebar_callout_provider.dart';
import 'sidebar_callout.dart';

/// Native sidebar viewport. Paseo intentionally leaves the web slot empty.
class SidebarCalloutSlot extends ConsumerWidget {
  const SidebarCalloutSlot({super.key, this.webOverride});

  @visibleForTesting
  final bool? webOverride;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (webOverride ?? kIsWeb) return const SizedBox.shrink();
    final entry = ref.watch(activeSidebarCalloutProvider);
    if (entry == null) return const SizedBox.shrink();
    final options = entry.options;
    return SizedBox(
      key: const ValueKey('sidebar-callout-slot'),
      width: double.infinity,
      child: SidebarCallout(
        title: options.title,
        description: options.description,
        icon: options.icon,
        variant: options.variant,
        actions: options.actions,
        onDismiss: options.dismissible
            ? () =>
                  ref.read(sidebarCalloutProvider.notifier).dismiss(options.id)
            : null,
        testId: options.testId,
      ),
    );
  }
}
