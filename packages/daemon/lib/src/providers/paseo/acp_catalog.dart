import 'package:agent_protocol/agent_protocol.dart';

final class AcpProviderCatalog {
  const AcpProviderCatalog({
    required this.models,
    required this.modes,
    required this.currentModelId,
    required this.currentModeId,
    required this.currentThinkingOptionId,
    required this.configOptions,
    required this.hasExplicitModels,
    required this.hasExplicitModes,
  });

  final List<ProviderModelDefinition> models;
  final List<ProviderMode> modes;
  final String? currentModelId;
  final String? currentModeId;
  final String? currentThinkingOptionId;
  final List<Map<String, Object?>> configOptions;
  final bool hasExplicitModels;
  final bool hasExplicitModes;

  Map<String, Object?>? selectConfigOption(String category) {
    for (final option in configOptions) {
      if (option['type'] == 'select' && option['category'] == category) {
        return option;
      }
    }
    return null;
  }

  bool configOptionContains(Map<String, Object?> option, String value) =>
      flattenAcpSelectOptions(option).any((entry) => entry['value'] == value);
}

AcpProviderCatalog deriveAcpProviderCatalog({
  required String provider,
  required Map<String, Object?> sessionState,
  List<ProviderMode> fallbackModes = const [],
}) {
  final configOptions = _listOfMaps(sessionState['configOptions']);
  final modeState = _map(sessionState['modes']);
  final explicitModes = _listOfMaps(modeState?['availableModes']);
  final modeOption = _selectOption(configOptions, 'mode');
  final modes = explicitModes.isNotEmpty
      ? [
          for (final mode in explicitModes)
            ProviderMode(
              id: _string(mode['id']) ?? '',
              label: _string(mode['name']) ?? _string(mode['id']) ?? '',
              description: _string(mode['description']),
            ),
        ].where((mode) => mode.id.isNotEmpty).toList(growable: false)
      : modeOption == null
      ? List<ProviderMode>.unmodifiable(fallbackModes)
      : [
          for (final option in flattenAcpSelectOptions(modeOption))
            ProviderMode(
              id: _string(option['value']) ?? '',
              label: _string(option['name']) ?? _string(option['value']) ?? '',
              description: _string(option['description']),
            ),
        ].where((mode) => mode.id.isNotEmpty).toList(growable: false);

  final thinkingOptions = _selectorOptions(configOptions, 'thought_level');
  final defaultThinkingOptionId = thinkingOptions
      .where((option) => option.isDefault == true)
      .firstOrNull
      ?.id;
  final modelState = _map(sessionState['models']);
  final explicitModels = _listOfMaps(modelState?['availableModels']);
  final currentModelId =
      _string(modelState?['currentModelId']) ??
      _currentConfigValue(configOptions, 'model');
  final models = explicitModels.isNotEmpty
      ? [
          for (final model in explicitModels)
            ProviderModelDefinition(
              provider: provider,
              id: _string(model['modelId']) ?? '',
              label: _string(model['name']) ?? _string(model['modelId']) ?? '',
              description: _string(model['description']),
              isDefault: model['modelId'] == currentModelId,
              thinkingOptions: thinkingOptions.isEmpty ? null : thinkingOptions,
              defaultThinkingOptionId: defaultThinkingOptionId,
            ),
        ].where((model) => model.id.isNotEmpty).toList(growable: false)
      : [
          for (final option in _selectorOptions(configOptions, 'model'))
            ProviderModelDefinition(
              provider: provider,
              id: option.id,
              label: option.label,
              description: option.description,
              isDefault: option.isDefault,
              metadata: option.metadata,
              thinkingOptions: thinkingOptions.isEmpty ? null : thinkingOptions,
              defaultThinkingOptionId: defaultThinkingOptionId,
            ),
        ];

  return AcpProviderCatalog(
    models: List.unmodifiable(models),
    modes: List.unmodifiable(modes),
    currentModelId: currentModelId,
    currentModeId:
        _string(modeState?['currentModeId']) ??
        (explicitModes.isEmpty
            ? _currentConfigValue(configOptions, 'mode')
            : null),
    currentThinkingOptionId: _currentConfigValue(
      configOptions,
      'thought_level',
    ),
    configOptions: List.unmodifiable(configOptions),
    hasExplicitModels: explicitModels.isNotEmpty,
    hasExplicitModes: explicitModes.isNotEmpty,
  );
}

List<Map<String, Object?>> flattenAcpSelectOptions(
  Map<String, Object?> option,
) {
  final result = <Map<String, Object?>>[];
  for (final entry in _listOfMaps(option['options'])) {
    if (entry.containsKey('value')) {
      result.add(entry);
      continue;
    }
    final group = _string(entry['group']);
    for (final child in _listOfMaps(entry['options'])) {
      result.add({...child, if (group != null) 'group': group});
    }
  }
  return result;
}

List<ProviderSelectOption> _selectorOptions(
  List<Map<String, Object?>> configOptions,
  String category,
) {
  final option = _selectOption(configOptions, category);
  if (option == null) return const [];
  return [
    for (final choice in flattenAcpSelectOptions(option))
      if (_string(choice['value']) case final String value)
        ProviderSelectOption(
          id: value,
          label: _string(choice['name']) ?? value,
          description: _string(choice['description']),
          isDefault: option['currentValue'] == value,
          metadata: _groupMetadata(choice['group']),
        ),
  ];
}

Map<String, Object?>? _selectOption(
  List<Map<String, Object?>> configOptions,
  String category,
) {
  for (final option in configOptions) {
    if (option['type'] == 'select' && option['category'] == category) {
      return option;
    }
  }
  return null;
}

String? _currentConfigValue(
  List<Map<String, Object?>> configOptions,
  String category,
) => _string(_selectOption(configOptions, category)?['currentValue']);

Map<String, Object?>? _map(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

List<Map<String, Object?>> _listOfMaps(Object? value) => value is List
    ? value.map(_map).whereType<Map<String, Object?>>().toList()
    : const [];

String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

Map<String, Object?>? _groupMetadata(Object? value) {
  final group = _string(value);
  return group == null ? null : {'group': group};
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
