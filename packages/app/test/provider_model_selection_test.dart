import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/composer/provider_model_selection.dart';
import 'package:flutter_test/flutter_test.dart';

const _codexModel = ProviderModelDefinition(
  provider: 'codex',
  id: 'gpt-5.4',
  label: 'GPT-5.4',
);

ProviderSnapshotEntry _entry({
  required String provider,
  ProviderCatalogStatus status = ProviderCatalogStatus.ready,
  bool enabled = true,
  String? label,
  String? error,
  List<ProviderModelDefinition>? models = const [_codexModel],
}) => ProviderSnapshotEntry(
  provider: provider,
  status: status,
  enabled: enabled,
  label: label ?? provider,
  error: error,
  models: models,
);

void main() {
  test('builds model, synthetic default, loading, and error selections', () {
    final providers = buildSelectableProviderSelectorProviders([
      _entry(provider: 'codex', label: 'Codex'),
      _entry(provider: 'default', label: 'Default CLI', models: const []),
      _entry(
        provider: 'loading',
        status: ProviderCatalogStatus.loading,
        models: null,
      ),
      _entry(
        provider: 'error',
        status: ProviderCatalogStatus.error,
        error: 'boom',
        models: const [],
      ),
      _entry(provider: 'disabled', enabled: false),
    ]);

    expect(providers, hasLength(4));
    final codex = getProviderModelRows(providers[0]).single;
    expect(codex.favoriteKey, 'codex:gpt-5.4');
    expect(codex.providerLabel, 'Codex');
    expect(codex.description, 'gpt-5.4');
    final fallback = getProviderModelRows(providers[1]).single;
    expect(fallback.modelId, '');
    expect(fallback.modelLabel, 'Default');
    expect(fallback.isDefault, isTrue);
    expect(providers[2].modelSelection, isA<ProviderModelsLoading>());
    expect(
      (providers[3].modelSelection as ProviderModelsError).message,
      'boom',
    );
    final fallbackErrors = buildSelectableProviderSelectorProviders([
      _entry(
        provider: 'unavailable',
        status: ProviderCatalogStatus.unavailable,
        models: const [],
      ),
      _entry(
        provider: 'unknown',
        status: ProviderCatalogStatus.error,
        models: const [],
      ),
    ]);
    expect(
      (fallbackErrors[0].modelSelection as ProviderModelsError).message,
      'Unavailable',
    );
    expect(
      (fallbackErrors[1].modelSelection as ProviderModelsError).message,
      'Unknown error',
    );
  });

  test('resolves trigger labels and initial browser views', () {
    final providers = buildSelectableProviderSelectorProviders([
      _entry(provider: 'codex', label: 'Codex'),
      _entry(provider: 'default', models: const []),
    ]);

    expect(
      resolveSelectedModelLabel(
        providers: providers,
        selectedProvider: 'codex',
        selectedModel: 'gpt-5.4',
        isLoading: false,
      ),
      'GPT-5.4',
    );
    expect(
      resolveSelectedModelLabel(
        providers: providers,
        selectedProvider: 'codex',
        selectedModel: 'removed-model',
        isLoading: false,
      ),
      'removed-model',
    );
    expect(
      resolveSelectedModelLabel(
        providers: providers,
        selectedProvider: '',
        selectedModel: '',
        isLoading: true,
      ),
      'Loading...',
    );
    expect(
      resolveSelectedModelLabel(
        providers: providers,
        selectedProvider: 'missing',
        selectedModel: '',
        isLoading: false,
      ),
      'Select model',
    );
    expect(
      resolveSelectedModelLabel(
        providers: [
          ProviderSelectorProvider(
            id: 'rows',
            label: 'Rows',
            modelSelection: ProviderModelRows(const [
              ProviderSelectionModelRow(
                favoriteKey: 'rows:first',
                provider: 'rows',
                providerLabel: 'Rows',
                modelId: 'first',
                modelLabel: 'First',
              ),
            ]),
          ),
        ],
        selectedProvider: 'rows',
        selectedModel: '',
        isLoading: false,
      ),
      'First',
    );
    expect(
      resolveInitialModelBrowserView(
        providers: providers,
        selectedProvider: 'codex',
        selectedModel: 'gpt-5.4',
        favoriteKeys: const {},
      ),
      isA<ProviderModelsView>(),
    );
    expect(
      resolveInitialModelBrowserView(
        providers: providers,
        selectedProvider: 'codex',
        selectedModel: 'gpt-5.4',
        favoriteKeys: const {'codex:gpt-5.4'},
      ),
      isA<AllModelsView>(),
    );
    expect(
      resolveInitialModelBrowserView(
        providers: [providers.first],
        selectedProvider: '',
        selectedModel: '',
        favoriteKeys: const {},
      ),
      isA<ProviderModelsView>(),
    );
  });

  test('fuzzy search matches every field and ranks the best row', () {
    const rows = [
      ProviderSelectionModelRow(
        favoriteKey: 'openai:gpt-4.1',
        provider: 'openai',
        providerLabel: 'OpenAI',
        modelId: 'gpt-4.1',
        modelLabel: 'GPT-4.1',
      ),
      ProviderSelectionModelRow(
        favoriteKey: 'openai:gpt-5.4',
        provider: 'openai',
        providerLabel: 'OpenAI',
        modelId: 'gpt-5.4',
        modelLabel: 'GPT-5.4',
        description: 'Frontier coding model',
      ),
      ProviderSelectionModelRow(
        favoriteKey: 'google:gemini',
        provider: 'google',
        providerLabel: 'Google',
        modelId: 'gemini',
        modelLabel: 'Gemini',
      ),
    ];

    expect(filterAndRankModelRows(rows, 'gpt54').map((row) => row.modelId), [
      'gpt-5.4',
    ]);
    expect(
      filterAndRankModelRows(rows, 'frontier openai').map((row) => row.modelId),
      ['gpt-5.4'],
    );
    expect(filterAndRankModelRows(rows, 'missing'), isEmpty);
    expect(filterAndRankModelRows(rows, ''), same(rows));
    expect(
      filterAndRankModelRows(const [
        ProviderSelectionModelRow(
          favoriteKey: 'test:b',
          provider: 'test',
          providerLabel: 'Test',
          modelId: 'same-b',
          modelLabel: 'Beta',
          description: 'same',
        ),
        ProviderSelectionModelRow(
          favoriteKey: 'test:a',
          provider: 'test',
          providerLabel: 'Test',
          modelId: 'same-a',
          modelLabel: 'Alpha',
          description: 'same',
        ),
      ], 'same').map((row) => row.modelLabel),
      ['Alpha', 'Beta'],
    );
  });

  test(
    'reports every frozen submission readiness reason in priority order',
    () {
      ProviderSelectionReadiness readiness({
        String text = 'hello',
        bool allowsEmptyAutoSubmit = false,
        int providerCount = 1,
        String? provider = 'codex',
        String modelId = 'gpt-5.4',
        List<Object?> availableModels = const [Object()],
        bool isModelLoading = false,
        String? autoSubmitProvider,
        String? autoSubmitModel,
        String? workspaceDirectory = '/repo',
        bool hasClient = true,
      }) => resolveSubmissionReadiness(
        text: text,
        allowsEmptyAutoSubmit: allowsEmptyAutoSubmit,
        providerCount: providerCount,
        provider: provider,
        modelId: modelId,
        availableModels: availableModels,
        isModelLoading: isModelLoading,
        autoSubmitProvider: autoSubmitProvider,
        autoSubmitModel: autoSubmitModel,
        workspaceDirectory: workspaceDirectory,
        hasClient: hasClient,
      );

      expect(readiness(text: ' ').reason, 'Initial prompt is required');
      expect(
        readiness(providerCount: 0).reason,
        'No available providers on the selected host',
      );
      expect(readiness(provider: null).reason, 'Select model');
      expect(
        readiness(isModelLoading: true).reason,
        'Model defaults are still loading',
      );
      expect(
        readiness(modelId: '').reason,
        'No model is available for the selected provider',
      );
      expect(
        readiness(workspaceDirectory: null).reason,
        'Workspace directory not found',
      );
      expect(readiness(hasClient: false).reason, 'Host is not connected');
      expect(readiness().ok, isTrue);
      expect(
        readiness(
          provider: null,
          modelId: '',
          autoSubmitProvider: 'codex',
          autoSubmitModel: 'gpt-5.4',
        ).ok,
        isTrue,
      );
      expect(
        readiness(
          text: '',
          allowsEmptyAutoSubmit: true,
          modelId: '',
          availableModels: const [],
        ).ok,
        isTrue,
      );
    },
  );
}
