import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../state/provider_usage_provider.dart';
import 'provider_usage.dart';

class ProviderUsageSettingsSection extends ConsumerWidget {
  const ProviderUsageSettingsSection({super.key, this.serverId});

  final String? serverId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = serverId == null
        ? ref.watch(providerUsageProvider)
        : ref.watch(hostProviderUsageProvider(serverId!));
    void refresh() {
      if (serverId == null) {
        ref.invalidate(providerUsageProvider);
      } else {
        ref.invalidate(hostProviderUsageProvider(serverId!));
      }
    }

    return Column(
      key: const ValueKey('provider-usage-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Plan usage', style: context.textStyles.titleMedium),
            ),
            Button(
              key: const ValueKey('provider-usage-refresh'),
              onPressed: usage.isLoading ? null : refresh,
              child: Text(usage.isLoading ? 'Refreshing...' : 'Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        switch (usage) {
          AsyncData(:final value) when value.providers.isEmpty => const Card(
            padding: EdgeInsets.all(16),
            child: Center(child: Text('No usage data')),
          ),
          AsyncData(:final value) => Column(
            children: [
              for (var index = 0; index < value.providers.length; index++) ...[
                ProviderUsageCard(usage: value.providers[index]),
                if (index != value.providers.length - 1)
                  const SizedBox(height: 12),
              ],
            ],
          ),
          AsyncError(:final error) => InfoBar(
            title: const Text('Unable to load usage'),
            content: Text('$error'),
            severity: InfoBarSeverity.error,
            action: Button(onPressed: refresh, child: const Text('Try again')),
          ),
          _ => const Card(
            padding: EdgeInsets.all(16),
            child: Center(child: Text('Loading usage...')),
          ),
        },
      ],
    );
  }
}
