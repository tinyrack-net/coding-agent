import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/composer/draft_feature_values.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const features = <AgentFeature>[
    AgentFeatureToggle(id: 'fast', label: 'Fast', value: false),
    AgentFeatureSelect(
      id: 'profile',
      label: 'Profile',
      value: 'safe',
      options: [
        ProviderSelectOption(id: 'safe', label: 'Safe'),
        ProviderSelectOption(id: 'full', label: 'Full'),
      ],
    ),
  ];

  test('resolves local and persisted values without sending defaults', () {
    final values = resolveDraftFeatureValues(
      features: features,
      persisted: const {'fast': true, 'profile': 'full'},
      local: const {'fast': false},
    );

    expect(values, {'fast': false, 'profile': 'full'});
  });

  test('prunes unavailable values and preserves selected payloads', () {
    final values = resolveDraftFeatureValues(
      features: features,
      persisted: const {'fast': 'yes', 'profile': 'missing'},
      local: const {'removed': true, 'profile': false},
    );

    expect(values, {'fast': 'yes', 'profile': false});
  });

  test('applies the provider default only to the rendered control', () {
    expect(applyDraftFeatureValue(features.first, const {}), isFalse);
    expect(
      applyDraftFeatureValue(features.first, const {'fast': true}),
      isTrue,
    );
  });
}
