import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/providers/provider_diagnostic_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const model = ProviderModelDefinition(
    provider: 'codex',
    id: 'gpt-5.4',
    label: 'GPT-5.4',
  );

  test('current discovered models replace the stable cache', () {
    final result = resolveProviderDiscoveredModels(
      serverId: 'host-a',
      provider: 'codex',
      currentModels: const [model],
      providerSnapshotRefreshing: false,
      previousCache: null,
    );

    expect(result.models, const [model]);
    expect(result.cache?.serverId, 'host-a');
    expect(result.cache?.provider, 'codex');
    expect(result.cache?.models, const [model]);
  });

  test('refreshing the same host and provider retains discovered models', () {
    const cache = ProviderDiscoveredModelsCache(
      serverId: 'host-a',
      provider: 'codex',
      models: [model],
    );
    final result = resolveProviderDiscoveredModels(
      serverId: 'host-a',
      provider: 'codex',
      currentModels: const [],
      providerSnapshotRefreshing: true,
      previousCache: cache,
    );

    expect(result.models, const [model]);
    expect(identical(result.cache, cache), isTrue);
  });

  test('stale cache is hidden outside its refreshing provider scope', () {
    const cache = ProviderDiscoveredModelsCache(
      serverId: 'host-a',
      provider: 'codex',
      models: [model],
    );

    for (final input in [
      ('host-b', 'codex', true),
      ('host-a', 'claude', true),
      ('host-a', 'codex', false),
    ]) {
      final result = resolveProviderDiscoveredModels(
        serverId: input.$1,
        provider: input.$2,
        currentModels: null,
        providerSnapshotRefreshing: input.$3,
        previousCache: cache,
      );
      expect(result.models, isEmpty);
      expect(identical(result.cache, cache), isTrue);
    }
  });
}
