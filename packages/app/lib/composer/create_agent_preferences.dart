import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const createAgentPreferencesStorageKey = '@tinyrack:create-agent-preferences';

final class FavoriteModelPreference {
  const FavoriteModelPreference({
    required this.provider,
    required this.modelId,
  });

  final String provider;
  final String modelId;

  Map<String, Object?> toJson() => {'provider': provider, 'modelId': modelId};

  @override
  bool operator ==(Object other) =>
      other is FavoriteModelPreference &&
      other.provider == provider &&
      other.modelId == modelId;

  @override
  int get hashCode => Object.hash(provider, modelId);
}

final class ProviderCreateAgentPreferences {
  const ProviderCreateAgentPreferences({
    this.model,
    this.mode,
    this.thinkingByModel = const {},
    this.featureValues = const {},
  });

  final String? model;
  final String? mode;
  final Map<String, String> thinkingByModel;
  final Map<String, Object?> featureValues;

  ProviderCreateAgentPreferences copyWith({
    String? model,
    String? mode,
    Map<String, String>? thinkingByModel,
    Map<String, Object?>? featureValues,
  }) => ProviderCreateAgentPreferences(
    model: model ?? this.model,
    mode: mode ?? this.mode,
    thinkingByModel: {...this.thinkingByModel, ...?thinkingByModel},
    featureValues: {...this.featureValues, ...?featureValues},
  );

  Map<String, Object?> toJson() => {
    'model': ?model,
    'mode': ?mode,
    if (thinkingByModel.isNotEmpty) 'thinkingByModel': thinkingByModel,
    if (featureValues.isNotEmpty) 'featureValues': featureValues,
  };
}

final class CreateAgentPreferences {
  const CreateAgentPreferences({
    this.provider,
    this.providerPreferences = const {},
    this.favoriteModels = const [],
    this.isolation,
  });

  final String? provider;
  final Map<String, ProviderCreateAgentPreferences> providerPreferences;
  final List<FavoriteModelPreference> favoriteModels;
  final String? isolation;

  CreateAgentPreferences mergeProvider(
    String provider,
    ProviderCreateAgentPreferences Function(
      ProviderCreateAgentPreferences current,
    )
    update,
  ) => CreateAgentPreferences(
    provider: provider,
    providerPreferences: {
      ...providerPreferences,
      provider: update(
        providerPreferences[provider] ?? const ProviderCreateAgentPreferences(),
      ),
    },
    favoriteModels: favoriteModels,
    isolation: isolation,
  );

  Map<String, Object?> toJson() => {
    'provider': ?provider,
    if (providerPreferences.isNotEmpty)
      'providerPreferences': {
        for (final entry in providerPreferences.entries)
          entry.key: entry.value.toJson(),
      },
    if (favoriteModels.isNotEmpty)
      'favoriteModels': [
        for (final favorite in favoriteModels) favorite.toJson(),
      ],
    'isolation': ?isolation,
  };

  static CreateAgentPreferences fromJson(Object? value) {
    if (value is! Map) return const CreateAgentPreferences();
    final record = _stringMap(value);
    if (!_optionalString(record, 'provider') ||
        !_optionalString(record, 'isolation') ||
        (record['isolation'] != null &&
            record['isolation'] != 'local' &&
            record['isolation'] != 'worktree')) {
      return const CreateAgentPreferences();
    }
    final rawProviders = record['providerPreferences'];
    final providers = <String, ProviderCreateAgentPreferences>{};
    if (rawProviders != null && rawProviders is! Map) {
      return const CreateAgentPreferences();
    }
    if (rawProviders is Map) {
      for (final entry in rawProviders.entries) {
        if (entry.key is! String) return const CreateAgentPreferences();
        final parsed = _parseProviderPreferences(entry.value);
        if (parsed == null) return const CreateAgentPreferences();
        providers[entry.key as String] = parsed;
      }
    }
    final rawFavorites = record['favoriteModels'];
    final favorites = <FavoriteModelPreference>[];
    if (rawFavorites != null && rawFavorites is! List) {
      return const CreateAgentPreferences();
    }
    if (rawFavorites is List) {
      for (final value in rawFavorites) {
        final favorite = _stringMap(value);
        if (favorite['provider'] is! String || favorite['modelId'] is! String) {
          return const CreateAgentPreferences();
        }
        favorites.add(
          FavoriteModelPreference(
            provider: favorite['provider']! as String,
            modelId: favorite['modelId']! as String,
          ),
        );
      }
    }
    return CreateAgentPreferences(
      provider: record['provider'] is String
          ? record['provider'] as String
          : null,
      providerPreferences: Map.unmodifiable(providers),
      favoriteModels: List.unmodifiable(favorites),
      isolation: record['isolation'] as String?,
    );
  }

  CreateAgentPreferences copyWith({
    String? provider,
    Map<String, ProviderCreateAgentPreferences>? providerPreferences,
    List<FavoriteModelPreference>? favoriteModels,
    String? isolation,
  }) => CreateAgentPreferences(
    provider: provider ?? this.provider,
    providerPreferences: providerPreferences ?? this.providerPreferences,
    favoriteModels: favoriteModels ?? this.favoriteModels,
    isolation: isolation ?? this.isolation,
  );
}

CreateAgentPreferences mergeCreateAgentSelectionPreferences({
  required CreateAgentPreferences preferences,
  required String? provider,
  String? modelId,
  String? modeId,
  String? thinkingOptionId,
  Map<String, Object?>? featureValues,
}) {
  if (provider == null) return preferences;
  final model = modelId?.trim() ?? '';
  final mode = modeId?.trim() ?? '';
  final thinking = thinkingOptionId?.trim() ?? '';
  return preferences.mergeProvider(
    provider,
    (current) => current.copyWith(
      model: model.isEmpty ? null : model,
      mode: mode.isEmpty ? null : mode,
      thinkingByModel: model.isNotEmpty && thinking.isNotEmpty
          ? {model: thinking}
          : null,
      featureValues: featureValues,
    ),
  );
}

String buildFavoriteModelKey({
  required String provider,
  required String modelId,
}) => '$provider:$modelId';

bool isFavoriteModel({
  required CreateAgentPreferences preferences,
  required String provider,
  required String modelId,
}) {
  final key = buildFavoriteModelKey(provider: provider, modelId: modelId);
  return preferences.favoriteModels.any(
    (favorite) =>
        buildFavoriteModelKey(
          provider: favorite.provider,
          modelId: favorite.modelId,
        ) ==
        key,
  );
}

CreateAgentPreferences toggleFavoriteModel({
  required CreateAgentPreferences preferences,
  required String provider,
  required String modelId,
}) {
  final favorite = FavoriteModelPreference(
    provider: provider,
    modelId: modelId,
  );
  final key = buildFavoriteModelKey(provider: provider, modelId: modelId);
  final hasFavorite = isFavoriteModel(
    preferences: preferences,
    provider: provider,
    modelId: modelId,
  );
  return preferences.copyWith(
    favoriteModels: hasFavorite
        ? [
            for (final entry in preferences.favoriteModels)
              if (buildFavoriteModelKey(
                    provider: entry.provider,
                    modelId: entry.modelId,
                  ) !=
                  key)
                entry,
          ]
        : [...preferences.favoriteModels, favorite],
  );
}

abstract interface class CreateAgentPreferenceStorage {
  Future<Object?> read();
  Future<void> write(CreateAgentPreferences preferences);
}

final class PreferencesCreateAgentPreferenceStorage
    implements CreateAgentPreferenceStorage {
  PreferencesCreateAgentPreferenceStorage({
    Future<SharedPreferences> Function()? preferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _preferences;

  @override
  Future<Object?> read() async {
    final stored = (await _preferences()).getString(
      createAgentPreferencesStorageKey,
    );
    if (stored == null) return null;
    try {
      return jsonDecode(stored);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(CreateAgentPreferences preferences) async {
    await (await _preferences()).setString(
      createAgentPreferencesStorageKey,
      jsonEncode(preferences.toJson()),
    );
  }
}

final class CreateAgentPreferencesService {
  CreateAgentPreferencesService([CreateAgentPreferenceStorage? storage])
    : _storage = storage ?? PreferencesCreateAgentPreferenceStorage();

  final CreateAgentPreferenceStorage _storage;
  CreateAgentPreferences _preferences = const CreateAgentPreferences();
  Future<CreateAgentPreferences>? _loadOperation;
  Future<void> _writeQueue = Future.value();

  Future<CreateAgentPreferences> load() =>
      _loadOperation ??= _storage.read().then(CreateAgentPreferences.fromJson);

  Future<CreateAgentPreferences> update(
    CreateAgentPreferences Function(CreateAgentPreferences current) update,
  ) {
    final operation = _applyAfter(_writeQueue, update);
    _writeQueue = operation.then<void>((_) {}, onError: (_) {});
    return operation;
  }

  Future<CreateAgentPreferences> _applyAfter(
    Future<void> previous,
    CreateAgentPreferences Function(CreateAgentPreferences current) update,
  ) async {
    await previous;
    _preferences = update(await load());
    _loadOperation = Future.value(_preferences);
    await _storage.write(_preferences);
    return _preferences;
  }
}

final createAgentPreferencesService = CreateAgentPreferencesService();

Map<String, Object?> _stringMap(Object? value) {
  if (value is! Map) return const {};
  return {
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

Map<String, String> _stringStringMap(Object? value) => {
  for (final entry in _stringMap(value).entries)
    if (entry.value is String) entry.key: entry.value! as String,
};

ProviderCreateAgentPreferences? _parseProviderPreferences(Object? value) {
  if (value is! Map) return null;
  final record = _stringMap(value);
  if (!_optionalString(record, 'model') || !_optionalString(record, 'mode')) {
    return null;
  }
  final rawThinking = record['thinkingByModel'];
  if (rawThinking != null && rawThinking is! Map) return null;
  final thinking = _stringStringMap(rawThinking);
  if (rawThinking is Map && thinking.length != rawThinking.length) return null;
  final rawFeatures = record['featureValues'];
  if (rawFeatures != null && rawFeatures is! Map) return null;
  final features = _stringMap(rawFeatures);
  if (rawFeatures is Map && features.length != rawFeatures.length) return null;
  return ProviderCreateAgentPreferences(
    model: record['model'] as String?,
    mode: record['mode'] as String?,
    thinkingByModel: Map.unmodifiable(thinking),
    featureValues: Map.unmodifiable(features),
  );
}

bool _optionalString(Map<String, Object?> record, String key) =>
    !record.containsKey(key) || record[key] == null || record[key] is String;
