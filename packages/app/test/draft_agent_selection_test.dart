import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/composer/draft_agent_selection.dart';
import 'package:flutter_test/flutter_test.dart';

const _models = [
  ProviderModelDefinition(provider: 'codex', id: 'mini', label: 'Mini'),
  ProviderModelDefinition(
    provider: 'codex',
    id: 'full',
    label: 'Full',
    isDefault: true,
    defaultThinkingOptionId: 'high',
  ),
];

const _provider = ProviderSnapshotEntry(
  provider: 'codex',
  status: ProviderCatalogStatus.ready,
  defaultModeId: 'auto-review',
  modes: [
    ProviderMode(id: 'read-only', label: 'Read only'),
    ProviderMode(id: 'auto-review', label: 'Auto review'),
  ],
);

void main() {
  test('resolves Paseo model, thinking, and mode defaults', () {
    expect(
      resolveEffectiveDraftModelId(
        selectedModelId: null,
        availableModels: _models,
      ),
      'full',
    );
    expect(
      resolveEffectiveDraftThinkingOptionId(
        selectedThinkingOptionId: null,
        effectiveModelId: 'full',
        availableModels: _models,
      ),
      'high',
    );
    expect(
      resolveEffectiveDraftModeId(
        selectedModeId: 'missing',
        provider: _provider,
      ),
      'auto-review',
    );
  });

  test('preserves explicit trimmed model and thinking selections', () {
    expect(
      resolveEffectiveDraftModelId(
        selectedModelId: ' custom ',
        availableModels: const [],
      ),
      'custom',
    );
    expect(
      resolveEffectiveDraftThinkingOptionId(
        selectedThinkingOptionId: ' medium ',
        effectiveModelId: 'custom',
        availableModels: const [],
      ),
      'medium',
    );
    expect(
      resolveEffectiveDraftModeId(
        selectedModeId: 'read-only',
        provider: _provider,
      ),
      'read-only',
    );
  });

  test('builds normalized draft command config and omits empty options', () {
    expect(
      buildDraftCommandConfig(
        provider: ' codex ',
        cwd: ' C:/repo ',
        modeId: '',
        modelId: ' full ',
        thinkingOptionId: '',
        featureValues: const {'fast_mode': true},
      )?.toJson(),
      {
        'provider': 'codex',
        'cwd': 'C:/repo',
        'model': 'full',
        'featureValues': {'fast_mode': true},
      },
    );
    expect(
      buildDraftCommandConfig(
        provider: null,
        cwd: '/repo',
        modeId: '',
        modelId: '',
        thinkingOptionId: '',
      ),
      isNull,
    );
    expect(
      resolveEffectiveDraftModeId(
        selectedModeId: null,
        provider: const ProviderSnapshotEntry(
          provider: 'empty',
          status: ProviderCatalogStatus.ready,
        ),
      ),
      '',
    );
    expect(
      resolveEffectiveDraftThinkingOptionId(
        selectedThinkingOptionId: null,
        effectiveModelId: 'missing',
        availableModels: _models,
      ),
      '',
    );
  });
}
