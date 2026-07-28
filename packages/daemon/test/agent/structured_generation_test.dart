import 'package:agent_daemon/src/agent/structured_generation.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('fully configured providers do not load a catalog', () async {
    var loads = 0;
    final providers = await resolveStructuredGenerationProviders(
      cwd: 'repo',
      configured: const [
        MutableStructuredGenerationProvider(
          provider: 'codex',
          model: 'gpt-5',
          thinkingOptionId: 'low',
        ),
      ],
      loadSnapshot: ({required cwd, required wait}) async {
        loads++;
        return const [];
      },
    );
    expect(loads, 0);
    expect(providers.single.provider, 'codex');
    expect(providers.single.model, 'gpt-5');
    expect(providers.single.thinkingOptionId, 'low');
  });

  test('waits for catalog then applies Paseo preferred model order', () async {
    final waits = <bool>[];
    final providers = await resolveStructuredGenerationProviders(
      cwd: 'repo',
      configured: const [],
      loadSnapshot: ({required cwd, required wait}) async {
        waits.add(wait);
        if (!wait) return const [];
        return const [
          ProviderSnapshotEntry(
            provider: 'codex',
            status: ProviderCatalogStatus.ready,
            models: [
              ProviderModelDefinition(
                provider: 'codex',
                id: 'gpt-5.4-mini',
                label: 'GPT 5.4 Mini',
                thinkingOptions: [
                  ProviderSelectOption(id: 'low', label: 'Low'),
                ],
              ),
            ],
          ),
          ProviderSnapshotEntry(
            provider: 'claude',
            status: ProviderCatalogStatus.ready,
            models: [
              ProviderModelDefinition(
                provider: 'claude',
                id: 'claude-haiku',
                label: 'Haiku',
              ),
            ],
          ),
        ];
      },
    );
    expect(waits, [true]);
    expect(providers.map((provider) => provider.provider), ['claude', 'codex']);
    expect(providers.last.thinkingOptionId, 'low');
  });

  test('resolves an incomplete configured provider without waiting', () async {
    final waits = <bool>[];
    final providers = await resolveStructuredGenerationProviders(
      cwd: 'repo',
      configured: const [
        MutableStructuredGenerationProvider(provider: 'claude'),
      ],
      loadSnapshot: ({required cwd, required wait}) async {
        waits.add(wait);
        return const [
          ProviderSnapshotEntry(
            provider: 'claude',
            status: ProviderCatalogStatus.ready,
            models: [
              ProviderModelDefinition(
                provider: 'claude',
                id: 'sonnet',
                label: 'Sonnet',
                isDefault: true,
              ),
            ],
          ),
        ];
      },
    );
    expect(waits, [false]);
    expect(providers.single.model, 'sonnet');
  });

  test(
    'maps nested provider metadata for an incomplete configured list',
    () async {
      final providers = await resolveStructuredGenerationProviders(
        cwd: 'repo',
        configured: const [
          MutableStructuredGenerationProvider(
            provider: 'openrouter',
            model: 'mini',
            thinkingOptionId: 'low',
          ),
          MutableStructuredGenerationProvider(provider: 'missing'),
        ],
        loadSnapshot: ({required cwd, required wait}) async => const [
          ProviderSnapshotEntry(
            provider: 'opencode',
            status: ProviderCatalogStatus.ready,
            models: [
              ProviderModelDefinition(
                provider: 'opencode',
                id: 'openrouter/mini',
                label: 'Mini',
                metadata: {'providerId': 'openrouter', 'modelId': 'mini'},
                thinkingOptions: [
                  ProviderSelectOption(id: 'low', label: 'Low'),
                ],
              ),
            ],
          ),
        ],
      );
      expect(providers.first.provider, 'opencode');
      expect(providers.first.model, 'openrouter/mini');
      expect(providers.first.thinkingOptionId, 'low');
    },
  );

  test('appends an explicit current selection after defaults', () async {
    final providers = await resolveStructuredGenerationProviders(
      cwd: 'repo',
      configured: const [],
      currentSelection: const StructuredGenerationSelection(
        provider: 'custom',
        model: 'chosen',
      ),
      loadSnapshot: ({required cwd, required wait}) async => const [],
    );
    expect(providers.single.provider, 'custom');
    expect(providers.single.model, 'chosen');
  });
}
