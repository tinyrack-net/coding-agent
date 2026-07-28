import 'package:coding_agent_app/composer/create_agent_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _MemoryStorage implements CreateAgentPreferenceStorage {
  Object? value;
  final writes = <CreateAgentPreferences>[];

  @override
  Future<Object?> read() async => value;

  @override
  Future<void> write(CreateAgentPreferences preferences) async {
    writes.add(preferences);
    value = preferences.toJson();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('rejects a malformed preferences object as one unit', () {
    final preferences = CreateAgentPreferences.fromJson({
      'provider': 'codex',
      'isolation': 'invalid',
      'providerPreferences': {
        'codex': {
          'model': 'gpt-5',
          'thinkingByModel': {'gpt-5': 'high', 'bad': 1},
          'featureValues': {'fast_mode': true},
        },
      },
    });

    expect(preferences.provider, isNull);
    expect(preferences.isolation, isNull);
    expect(preferences.providerPreferences, isEmpty);
    expect(preferences.favoriteModels, isEmpty);
  });

  test('parses valid provider preferences and favorite models', () {
    final preferences = CreateAgentPreferences.fromJson({
      'provider': 'codex',
      'isolation': 'worktree',
      'providerPreferences': {
        'codex': {
          'model': 'gpt-5',
          'mode': 'plan',
          'thinkingByModel': {'gpt-5': 'high'},
          'featureValues': {'fast_mode': true},
        },
      },
      'favoriteModels': [
        {'provider': 'codex', 'modelId': 'gpt-5', 'futureField': true},
      ],
    });

    expect(preferences.provider, 'codex');
    expect(preferences.isolation, 'worktree');
    expect(preferences.providerPreferences['codex']?.thinkingByModel, {
      'gpt-5': 'high',
    });
    expect(preferences.favoriteModels, const [
      FavoriteModelPreference(provider: 'codex', modelId: 'gpt-5'),
    ]);
    expect(preferences.favoriteModels.single.hashCode, isA<int>());
    expect(preferences.toJson()['favoriteModels'], [
      {'provider': 'codex', 'modelId': 'gpt-5'},
    ]);
  });

  test('merges selection state and toggles favorite models', () {
    final merged = mergeCreateAgentSelectionPreferences(
      preferences: const CreateAgentPreferences(),
      provider: 'codex',
      modelId: 'gpt-5',
      modeId: 'plan',
      thinkingOptionId: 'high',
      featureValues: const {'fast_mode': true},
    );

    expect(merged.provider, 'codex');
    expect(merged.providerPreferences['codex']?.model, 'gpt-5');
    expect(merged.providerPreferences['codex']?.mode, 'plan');
    expect(merged.providerPreferences['codex']?.thinkingByModel, {
      'gpt-5': 'high',
    });
    expect(
      buildFavoriteModelKey(provider: 'codex', modelId: 'gpt-5'),
      'codex:gpt-5',
    );
    final favorited = toggleFavoriteModel(
      preferences: merged.copyWith(
        favoriteModels: const [
          FavoriteModelPreference(provider: 'claude', modelId: 'sonnet'),
        ],
      ),
      provider: 'codex',
      modelId: 'gpt-5',
    );
    expect(
      isFavoriteModel(
        preferences: favorited,
        provider: 'codex',
        modelId: 'gpt-5',
      ),
      isTrue,
    );
    expect(
      toggleFavoriteModel(
        preferences: favorited,
        provider: 'codex',
        modelId: 'gpt-5',
      ).favoriteModels,
      const [FavoriteModelPreference(provider: 'claude', modelId: 'sonnet')],
    );
  });

  test(
    'queues provider-scoped feature updates without losing values',
    () async {
      final storage = _MemoryStorage();
      final service = CreateAgentPreferencesService(storage);

      await Future.wait([
        service.update(
          (current) => current.mergeProvider(
            'codex',
            (provider) => provider.copyWith(featureValues: {'fast_mode': true}),
          ),
        ),
        service.update(
          (current) => current.mergeProvider(
            'codex',
            (provider) =>
                provider.copyWith(featureValues: {'plan_mode': false}),
          ),
        ),
      ]);

      expect(storage.writes, hasLength(2));
      expect(
        (await service.load()).providerPreferences['codex']?.featureValues,
        {'fast_mode': true, 'plan_mode': false},
      );
    },
  );

  test(
    'SharedPreferences storage handles absent, malformed, and valid JSON',
    () async {
      final storage = PreferencesCreateAgentPreferenceStorage();
      expect(await storage.read(), isNull);

      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(createAgentPreferencesStorageKey, '{bad');
      expect(await storage.read(), isNull);

      const value = CreateAgentPreferences(
        provider: 'claude',
        isolation: 'worktree',
      );
      await storage.write(value);
      expect(await storage.read(), value.toJson());
    },
  );
}
