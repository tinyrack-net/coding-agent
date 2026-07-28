import 'agent_commands.dart';
import 'provider_v2.dart';

sealed class AgentFeature {
  const AgentFeature({
    required this.id,
    required this.label,
    this.description,
    this.tooltip,
    this.icon,
  });

  final String id;
  final String label;
  final String? description;
  final String? tooltip;
  final String? icon;

  Object? get value;

  static AgentFeature fromJson(Map<String, Object?> json) =>
      switch (json['type']) {
        'toggle' => AgentFeatureToggle.fromJson(json),
        'select' => AgentFeatureSelect.fromJson(json),
        final value => throw FormatException(
          'unknown agent feature type "$value"',
        ),
      };

  Map<String, Object?> baseJson(String type) => {
    'type': type,
    'id': id,
    'label': label,
    if (description != null) 'description': description,
    if (tooltip != null) 'tooltip': tooltip,
    if (icon != null) 'icon': icon,
  };

  Map<String, Object?> toJson();
}

final class AgentFeatureToggle extends AgentFeature {
  const AgentFeatureToggle({
    required super.id,
    required super.label,
    required this.value,
    super.description,
    super.tooltip,
    super.icon,
  });

  @override
  final bool value;

  factory AgentFeatureToggle.fromJson(Map<String, Object?> json) {
    final value = json['value'];
    if (value is! bool) {
      throw const FormatException('toggle feature value must be a boolean');
    }
    return AgentFeatureToggle(
      id: _requiredString(json, 'id'),
      label: _requiredString(json, 'label'),
      description: _optionalString(json, 'description'),
      tooltip: _optionalString(json, 'tooltip'),
      icon: _optionalString(json, 'icon'),
      value: value,
    );
  }

  @override
  Map<String, Object?> toJson() => {...baseJson('toggle'), 'value': value};
}

final class AgentFeatureSelect extends AgentFeature {
  const AgentFeatureSelect({
    required super.id,
    required super.label,
    required this.value,
    required this.options,
    super.description,
    super.tooltip,
    super.icon,
  });

  @override
  final String? value;
  final List<ProviderSelectOption> options;

  factory AgentFeatureSelect.fromJson(Map<String, Object?> json) {
    final value = json['value'];
    if (value != null && value is! String) {
      throw const FormatException(
        'select feature value must be a string or null',
      );
    }
    final rawOptions = json['options'];
    if (rawOptions is! List) {
      throw const FormatException('select feature options must be an array');
    }
    return AgentFeatureSelect(
      id: _requiredString(json, 'id'),
      label: _requiredString(json, 'label'),
      description: _optionalString(json, 'description'),
      tooltip: _optionalString(json, 'tooltip'),
      icon: _optionalString(json, 'icon'),
      value: value as String?,
      options: List.unmodifiable([
        for (final option in rawOptions)
          if (option is Map)
            ProviderSelectOption.fromJson(Map<String, Object?>.from(option))
          else
            throw const FormatException(
              'select feature options entries must be objects',
            ),
      ]),
    );
  }

  @override
  Map<String, Object?> toJson() => {
    ...baseJson('select'),
    'value': value,
    'options': options.map((option) => option.toJson()).toList(),
  };
}

final class ListProviderFeaturesRequest {
  const ListProviderFeaturesRequest({
    required this.draftConfig,
    required this.requestId,
  });

  static const type = 'list_provider_features_request';

  final ListCommandsDraftConfig draftConfig;
  final String requestId;

  factory ListProviderFeaturesRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final draft = json['draftConfig'];
    if (draft is! Map) {
      throw const FormatException('draftConfig must be an object');
    }
    return ListProviderFeaturesRequest(
      draftConfig: ListCommandsDraftConfig.fromJson(
        Map<String, Object?>.from(draft),
      ),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'draftConfig': draftConfig.toJson(),
    'requestId': requestId,
  };
}

final class ListProviderFeaturesResponse {
  const ListProviderFeaturesResponse({
    required this.provider,
    required this.fetchedAt,
    required this.requestId,
    this.features,
    this.error,
  });

  static const type = 'list_provider_features_response';

  final String provider;
  final List<AgentFeature>? features;
  final String? error;
  final String fetchedAt;
  final String requestId;

  factory ListProviderFeaturesResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = json['payload'];
    if (payload is! Map) {
      throw const FormatException('payload must be an object');
    }
    final body = Map<String, Object?>.from(payload);
    final rawFeatures = body['features'];
    if (rawFeatures != null && rawFeatures is! List) {
      throw const FormatException('features must be an array');
    }
    final featureList = rawFeatures as List?;
    return ListProviderFeaturesResponse(
      provider: _requiredString(body, 'provider'),
      features: featureList == null
          ? null
          : List.unmodifiable([
              for (final feature in featureList)
                if (feature is Map)
                  AgentFeature.fromJson(Map<String, Object?>.from(feature))
                else
                  throw const FormatException(
                    'features entries must be objects',
                  ),
            ]),
      error: _optionalString(body, 'error'),
      fetchedAt: _requiredString(body, 'fetchedAt'),
      requestId: _requiredString(body, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'provider': provider,
      if (features != null)
        'features': features!.map((feature) => feature.toJson()).toList(),
      'error': error,
      'fetchedAt': fetchedAt,
      'requestId': requestId,
    },
  };
}

void _expectType(Map<String, Object?> json, String expected) {
  if (json['type'] != expected) {
    throw FormatException('expected type "$expected"');
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}
