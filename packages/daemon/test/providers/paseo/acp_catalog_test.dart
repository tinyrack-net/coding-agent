import 'package:agent_daemon/src/providers/paseo/acp_catalog.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'prefers explicit ACP models and modes and attaches thinking options',
    () {
      final catalog = deriveAcpProviderCatalog(
        provider: 'claude-acp',
        fallbackModes: const [ProviderMode(id: 'fallback', label: 'Fallback')],
        sessionState: {
          'models': {
            'availableModels': [
              {'modelId': 'haiku', 'name': 'Haiku', 'description': 'Fast'},
              {
                'modelId': 'sonnet',
                'name': 'Sonnet',
                'description': 'Balanced',
              },
            ],
            'currentModelId': 'haiku',
          },
          'modes': {
            'availableModes': [
              {
                'id': 'default',
                'name': 'Always Ask',
                'description': 'Prompt before tools',
              },
              {'id': 'plan', 'name': 'Plan', 'description': 'Read only'},
            ],
            'currentModeId': 'plan',
          },
          'configOptions': [
            {
              'id': 'reasoning',
              'name': 'Reasoning',
              'category': 'thought_level',
              'type': 'select',
              'currentValue': 'medium',
              'options': [
                {'value': 'low', 'name': 'Low'},
                {'value': 'medium', 'name': 'Medium'},
                {'value': 'high', 'name': 'High'},
              ],
            },
          ],
        },
      );

      expect(catalog.currentModelId, 'haiku');
      expect(catalog.currentModeId, 'plan');
      expect(catalog.currentThinkingOptionId, 'medium');
      expect(catalog.hasExplicitModels, isTrue);
      expect(catalog.hasExplicitModes, isTrue);
      expect(catalog.models, [
        isA<ProviderModelDefinition>()
            .having((model) => model.id, 'id', 'haiku')
            .having((model) => model.isDefault, 'default', isTrue)
            .having(
              (model) => model.defaultThinkingOptionId,
              'thinking default',
              'medium',
            ),
        isA<ProviderModelDefinition>()
            .having((model) => model.id, 'id', 'sonnet')
            .having((model) => model.isDefault, 'default', isFalse),
      ]);
      expect(catalog.models.first.thinkingOptions, [
        isA<ProviderSelectOption>()
            .having((option) => option.id, 'id', 'low')
            .having((option) => option.isDefault, 'default', isFalse),
        isA<ProviderSelectOption>()
            .having((option) => option.id, 'id', 'medium')
            .having((option) => option.isDefault, 'default', isTrue),
        isA<ProviderSelectOption>().having((option) => option.id, 'id', 'high'),
      ]);
      expect(catalog.modes.map((mode) => mode.id), ['default', 'plan']);
    },
  );

  test('falls back to grouped model and mode config options', () {
    final catalog = deriveAcpProviderCatalog(
      provider: 'config-acp',
      sessionState: {
        'configOptions': [
          {
            'id': 'agent-mode',
            'name': 'Mode',
            'category': 'mode',
            'type': 'select',
            'currentValue': 'review',
            'options': [
              {'value': 'build', 'name': 'Build'},
              {'value': 'review', 'name': 'Review'},
            ],
          },
          {
            'id': 'model-picker',
            'name': 'Model',
            'category': 'model',
            'type': 'select',
            'currentValue': 'opus',
            'options': [
              {
                'group': 'Anthropic',
                'options': [
                  {'value': 'opus', 'name': 'Opus', 'description': 'Deep'},
                ],
              },
            ],
          },
        ],
      },
    );

    expect(catalog.hasExplicitModels, isFalse);
    expect(catalog.hasExplicitModes, isFalse);
    expect(catalog.currentModelId, 'opus');
    expect(catalog.currentModeId, 'review');
    expect(catalog.models.single.toJson(), {
      'provider': 'config-acp',
      'id': 'opus',
      'label': 'Opus',
      'description': 'Deep',
      'isDefault': true,
      'metadata': {'group': 'Anthropic'},
    });
    expect(catalog.modes.map((mode) => mode.id), ['build', 'review']);
    expect(
      catalog.configOptionContains(
        catalog.selectConfigOption('model')!,
        'opus',
      ),
      isTrue,
    );
  });

  test('uses fallback modes and returns no models for unrelated options', () {
    final catalog = deriveAcpProviderCatalog(
      provider: 'empty-acp',
      fallbackModes: const [ProviderMode(id: 'fallback', label: 'Fallback')],
      sessionState: {
        'models': null,
        'modes': null,
        'configOptions': [
          {
            'id': 'theme',
            'name': 'Theme',
            'category': 'ui',
            'type': 'select',
            'currentValue': 'dark',
            'options': [
              {'value': 'dark', 'name': 'Dark'},
            ],
          },
        ],
      },
    );

    expect(catalog.models, isEmpty);
    expect(catalog.modes.single.id, 'fallback');
    expect(catalog.currentModelId, isNull);
    expect(catalog.currentModeId, isNull);
  });
}
