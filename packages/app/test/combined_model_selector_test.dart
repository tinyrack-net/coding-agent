import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/composer/provider_model_selection.dart';
import 'package:coding_agent_app/widgets/combined_model_selector.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';

const _snapshots = [
  ProviderSnapshotEntry(
    provider: 'claude',
    label: 'Claude',
    status: ProviderCatalogStatus.ready,
    models: [
      ProviderModelDefinition(
        provider: 'claude',
        id: 'sonnet',
        label: 'Sonnet',
        isDefault: true,
      ),
      ProviderModelDefinition(
        provider: 'claude',
        id: 'opus',
        label: 'Opus',
        description: 'Hard reasoning',
      ),
    ],
  ),
  ProviderSnapshotEntry(
    provider: 'codex',
    label: 'Codex',
    status: ProviderCatalogStatus.ready,
    models: [
      ProviderModelDefinition(
        provider: 'codex',
        id: 'gpt-5.4',
        label: 'GPT-5.4',
      ),
    ],
  ),
];

void main() {
  testWidgets('opens the selected provider, searches, favorites, and selects', (
    tester,
  ) async {
    String? favorite;
    String? selection;
    await tester.pumpWidget(
      FluentApp(
        home: CombinedModelSelector(
          providers: buildSelectableProviderSelectorProviders(_snapshots),
          selectedProvider: 'claude',
          selectedModel: 'sonnet',
          onSelect: (provider, model) => selection = '$provider:$model',
          onToggleFavorite: (provider, model) => favorite = '$provider:$model',
        ),
      ),
    );

    expect(find.text('Sonnet'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('combined-model-selector')));
    await tester.pumpAndSettle();
    expect(find.text('Claude'), findsOneWidget);
    expect(find.byKey(const ValueKey('model-search-input')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('model-search-input')),
      'hard',
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('model-row-claude-opus')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-row-claude-sonnet')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('favorite-model-claude-opus')));
    await tester.pump();
    expect(favorite, 'claude:opus');

    await tester.tap(find.byKey(const ValueKey('model-row-claude-opus')));
    await tester.pumpAndSettle();
    expect(selection, 'claude:opus');
    expect(find.byType(ContentDialog), findsNothing);
  });

  testWidgets('a selected favorite opens the all-provider overview', (
    tester,
  ) async {
    final favorites = <String>[];
    await tester.pumpWidget(
      FluentApp(
        home: CombinedModelSelector(
          providers: buildSelectableProviderSelectorProviders(_snapshots),
          selectedProvider: 'claude',
          selectedModel: 'sonnet',
          favoriteKeys: const {'claude:sonnet'},
          onSelect: (_, _) {},
          onToggleFavorite: (provider, model) =>
              favorites.add('$provider:$model'),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('combined-model-selector')));
    await tester.pumpAndSettle();
    expect(find.text('Models'), findsOneWidget);
    expect(find.text('Favorites'), findsOneWidget);
    expect(find.byKey(const ValueKey('model-provider-claude')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-provider-codex')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('favorite-model-claude-sonnet')),
    );
    await tester.pump();
    expect(favorites, ['claude:sonnet']);

    await tester.tap(find.byKey(const ValueKey('model-provider-codex')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('model-search-input')), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('model-browser-back')));
    await tester.pumpAndSettle();
    expect(find.text('Models'), findsOneWidget);
  });

  testWidgets(
    'overview reports loading and error providers and handles empty',
    (tester) async {
      await tester.pumpWidget(
        FluentApp(
          home: CombinedModelSelector(
            providers: buildSelectableProviderSelectorProviders(const [
              ProviderSnapshotEntry(
                provider: 'loading',
                status: ProviderCatalogStatus.loading,
                models: null,
              ),
              ProviderSnapshotEntry(
                provider: 'error',
                status: ProviderCatalogStatus.error,
                models: [],
              ),
            ]),
            selectedProvider: '',
            selectedModel: '',
            onSelect: (_, _) {},
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('combined-model-selector')));
      await tester.pumpAndSettle();
      expect(find.text('Loading...'), findsOneWidget);
      expect(find.text('Error'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        FluentApp(
          home: CombinedModelSelector(
            providers: const [],
            selectedProvider: '',
            selectedModel: '',
            onSelect: (_, _) {},
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('combined-model-selector')));
      await tester.pumpAndSettle();
      expect(find.text('No matching models.'), findsOneWidget);
    },
  );

  testWidgets('error state exposes retry and empty model selects Default', (
    tester,
  ) async {
    var retried = false;
    await tester.pumpWidget(
      FluentApp(
        home: CombinedModelSelector(
          providers: buildSelectableProviderSelectorProviders(const [
            ProviderSnapshotEntry(
              provider: 'broken',
              label: 'Broken',
              status: ProviderCatalogStatus.error,
              error: 'boom',
              models: [],
            ),
          ]),
          selectedProvider: 'broken',
          selectedModel: '',
          onSelect: (_, _) {},
          onRetryProvider: (_) => retried = true,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('combined-model-selector')));
    await tester.pumpAndSettle();
    expect(find.text('boom'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retry-model-provider-broken')));
    expect(retried, isTrue);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    String? selected;
    await tester.pumpWidget(
      FluentApp(
        home: CombinedModelSelector(
          providers: buildSelectableProviderSelectorProviders(const [
            ProviderSnapshotEntry(
              provider: 'plain',
              label: 'Plain CLI',
              status: ProviderCatalogStatus.ready,
              models: [],
            ),
          ]),
          selectedProvider: 'plain',
          selectedModel: '',
          onSelect: (provider, model) => selected = '$provider:$model',
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('combined-model-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('model-row-plain-')));
    await tester.pumpAndSettle();
    expect(selected, 'plain:');
  });
}
