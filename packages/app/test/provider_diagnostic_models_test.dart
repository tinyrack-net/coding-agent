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

  test(
    'model ranking matches exact, prefix, word, substring, and fuzzy tiers',
    () {
      const values = [
        ('substring', 'TheSonnetModel', 'anthropic/model'),
        ('fuzzy', 'Claude SNT', 'claude-snt'),
        ('exact', 'sonnet', 'other'),
        ('prefix', 'Sonnet 4', 'sonnet-4'),
        ('word', 'Claude Sonnet', 'claude-sonnet'),
      ];

      final ranked = rankProviderModels(
        values,
        'sonnet',
        (value) => [value.$2, value.$3],
      );

      expect(ranked.map((value) => value.$1), [
        'exact',
        'prefix',
        'word',
        'substring',
      ]);
      expect(
        rankProviderModels(
          values,
          'snt',
          (value) => [value.$2, value.$3],
        ).map((value) => value.$1),
        contains('fuzzy'),
      );
    },
  );

  test('formats provider fetch ages with frozen boundaries', () {
    final now = DateTime(2026, 7, 30, 12);
    expect(
      formatProviderFetchedAt(
        now.subtract(const Duration(seconds: 9)),
        now: now,
      ),
      'just now',
    );
    expect(
      formatProviderFetchedAt(
        now.subtract(const Duration(seconds: 30)),
        now: now,
      ),
      '30s ago',
    );
    expect(
      formatProviderFetchedAt(
        now.subtract(const Duration(minutes: 5)),
        now: now,
      ),
      '5m ago',
    );
    expect(
      formatProviderFetchedAt(now.subtract(const Duration(hours: 2)), now: now),
      '2h ago',
    );
    expect(
      formatProviderFetchedAt(now.subtract(const Duration(days: 3)), now: now),
      '3d ago',
    );
    expect(formatProviderFetchedAt(DateTime(2026, 7, 15), now: now), 'Jul 15');
  });
}
