/// Paseo 0.2 provider catalog and availability wire contracts.
library;

enum ProviderCatalogStatus {
  ready,
  loading,
  error,
  unavailable;

  static ProviderCatalogStatus fromWire(Object? value) {
    if (value is! String) {
      throw const FormatException('provider status must be a string');
    }
    return ProviderCatalogStatus.values.firstWhere(
      (entry) => entry.name == value,
      orElse: () => throw FormatException('unknown provider status "$value"'),
    );
  }
}

final class ProviderMode {
  const ProviderMode({
    required this.id,
    required this.label,
    this.description,
    this.icon,
    this.colorTier,
  });

  final String id;
  final String label;
  final String? description;
  final String? icon;
  final String? colorTier;

  factory ProviderMode.fromJson(Map<String, Object?> json) => ProviderMode(
    id: _requiredString(json, 'id'),
    label: _requiredString(json, 'label'),
    description: _optionalString(json, 'description'),
    icon: _optionalString(json, 'icon'),
    colorTier: _optionalString(json, 'colorTier'),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    if (description != null) 'description': description,
    if (icon != null) 'icon': icon,
    if (colorTier != null) 'colorTier': colorTier,
  };
}

final class ProviderSelectOption {
  const ProviderSelectOption({
    required this.id,
    required this.label,
    this.description,
    this.isDefault,
    this.metadata,
  });

  final String id;
  final String label;
  final String? description;
  final bool? isDefault;
  final Map<String, Object?>? metadata;

  factory ProviderSelectOption.fromJson(Map<String, Object?> json) =>
      ProviderSelectOption(
        id: _requiredString(json, 'id'),
        label: _requiredString(json, 'label'),
        description: _optionalString(json, 'description'),
        isDefault: _optionalBool(json, 'isDefault'),
        metadata: _optionalMap(json, 'metadata'),
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    if (description != null) 'description': description,
    if (isDefault != null) 'isDefault': isDefault,
    if (metadata != null) 'metadata': metadata,
  };
}

final class ProviderModelDefinition {
  const ProviderModelDefinition({
    required this.provider,
    required this.id,
    required this.label,
    this.description,
    this.isDefault,
    this.metadata,
    this.contextWindowMaxTokens,
    this.thinkingOptions,
    this.defaultThinkingOptionId,
  });

  final String provider;
  final String id;
  final String label;
  final String? description;
  final bool? isDefault;
  final Map<String, Object?>? metadata;
  final num? contextWindowMaxTokens;
  final List<ProviderSelectOption>? thinkingOptions;
  final String? defaultThinkingOptionId;

  factory ProviderModelDefinition.fromJson(Map<String, Object?> json) =>
      ProviderModelDefinition(
        provider: _requiredString(json, 'provider'),
        id: _requiredString(json, 'id'),
        label: _requiredString(json, 'label'),
        description: _optionalString(json, 'description'),
        isDefault: _optionalBool(json, 'isDefault'),
        metadata: _optionalMap(json, 'metadata'),
        contextWindowMaxTokens: _optionalNum(json, 'contextWindowMaxTokens'),
        thinkingOptions: json['thinkingOptions'] == null
            ? null
            : _mapList(json, 'thinkingOptions', ProviderSelectOption.fromJson),
        defaultThinkingOptionId: _optionalString(
          json,
          'defaultThinkingOptionId',
        ),
      );

  Map<String, Object?> toJson() => {
    'provider': provider,
    'id': id,
    'label': label,
    if (description != null) 'description': description,
    if (isDefault != null) 'isDefault': isDefault,
    if (metadata != null) 'metadata': metadata,
    if (contextWindowMaxTokens != null)
      'contextWindowMaxTokens': contextWindowMaxTokens,
    if (thinkingOptions != null)
      'thinkingOptions': thinkingOptions!
          .map((entry) => entry.toJson())
          .toList(),
    if (defaultThinkingOptionId != null)
      'defaultThinkingOptionId': defaultThinkingOptionId,
  };
}

final class ProviderSnapshotEntry {
  const ProviderSnapshotEntry({
    required this.provider,
    required this.status,
    this.enabled = true,
    this.source,
    this.error,
    this.models,
    this.modes,
    this.fetchedAt,
    this.label,
    this.description,
    this.defaultModeId,
  });

  final String provider;
  final ProviderCatalogStatus status;
  final bool enabled;
  final String? source;
  final String? error;
  final List<ProviderModelDefinition>? models;
  final List<ProviderMode>? modes;
  final String? fetchedAt;
  final String? label;
  final String? description;
  final String? defaultModeId;

  factory ProviderSnapshotEntry.fromJson(Map<String, Object?> json) =>
      ProviderSnapshotEntry(
        provider: _requiredString(json, 'provider'),
        status: ProviderCatalogStatus.fromWire(json['status']),
        enabled: _optionalBool(json, 'enabled') ?? true,
        source: _optionalEnumString(json, 'source', const {
          'builtin',
          'custom',
        }),
        error: _optionalString(json, 'error'),
        models: json['models'] == null
            ? null
            : _mapList(json, 'models', ProviderModelDefinition.fromJson),
        modes: json['modes'] == null
            ? null
            : _mapList(json, 'modes', ProviderMode.fromJson),
        fetchedAt: _optionalString(json, 'fetchedAt'),
        label: _optionalString(json, 'label'),
        description: _optionalString(json, 'description'),
        defaultModeId: _optionalString(json, 'defaultModeId'),
      );

  Map<String, Object?> toJson() => {
    'provider': provider,
    'status': status.name,
    'enabled': enabled,
    if (source != null) 'source': source,
    if (error != null) 'error': error,
    if (models != null)
      'models': models!.map((entry) => entry.toJson()).toList(),
    if (modes != null) 'modes': modes!.map((entry) => entry.toJson()).toList(),
    if (fetchedAt != null) 'fetchedAt': fetchedAt,
    if (label != null) 'label': label,
    if (description != null) 'description': description,
    'defaultModeId': defaultModeId,
  };
}

final class ProviderAvailabilityV2 {
  const ProviderAvailabilityV2({
    required this.provider,
    required this.available,
    this.error,
  });

  final String provider;
  final bool available;
  final String? error;

  factory ProviderAvailabilityV2.fromJson(Map<String, Object?> json) =>
      ProviderAvailabilityV2(
        provider: _requiredString(json, 'provider'),
        available: _requiredBool(json, 'available'),
        error: _optionalString(json, 'error'),
      );

  Map<String, Object?> toJson() => {
    'provider': provider,
    'available': available,
    'error': error,
  };
}

final class ListAvailableProvidersRequest {
  const ListAvailableProvidersRequest({required this.requestId});

  final String requestId;

  factory ListAvailableProvidersRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'list_available_providers_request');
    return ListAvailableProvidersRequest(
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'list_available_providers_request',
    'requestId': requestId,
  };
}

final class ListAvailableProvidersResponse {
  const ListAvailableProvidersResponse({
    required this.requestId,
    required this.providers,
    required this.fetchedAt,
    this.error,
  });

  final String requestId;
  final List<ProviderAvailabilityV2> providers;
  final String fetchedAt;
  final String? error;

  factory ListAvailableProvidersResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'list_available_providers_response');
    final payload = _requiredMap(json, 'payload');
    return ListAvailableProvidersResponse(
      requestId: _requiredString(payload, 'requestId'),
      providers: _mapList(
        payload,
        'providers',
        ProviderAvailabilityV2.fromJson,
      ),
      fetchedAt: _requiredString(payload, 'fetchedAt'),
      error: _optionalString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'list_available_providers_response',
    'payload': {
      'providers': providers.map((entry) => entry.toJson()).toList(),
      'error': error,
      'fetchedAt': fetchedAt,
      'requestId': requestId,
    },
  };
}

final class ListProviderModelsRequest {
  const ListProviderModelsRequest({
    required this.provider,
    required this.requestId,
    this.cwd,
  });

  final String provider;
  final String? cwd;
  final String requestId;

  factory ListProviderModelsRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'list_provider_models_request');
    return ListProviderModelsRequest(
      provider: _requiredString(json, 'provider'),
      cwd: _optionalString(json, 'cwd'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'list_provider_models_request',
    'provider': provider,
    if (cwd != null) 'cwd': cwd,
    'requestId': requestId,
  };
}

final class ListProviderModelsResponse {
  const ListProviderModelsResponse({
    required this.provider,
    required this.requestId,
    required this.fetchedAt,
    this.models,
    this.error,
  });

  final String provider;
  final String requestId;
  final String fetchedAt;
  final List<ProviderModelDefinition>? models;
  final String? error;

  factory ListProviderModelsResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'list_provider_models_response');
    final payload = _requiredMap(json, 'payload');
    return ListProviderModelsResponse(
      provider: _requiredString(payload, 'provider'),
      requestId: _requiredString(payload, 'requestId'),
      fetchedAt: _requiredString(payload, 'fetchedAt'),
      models: payload['models'] == null
          ? null
          : _mapList(payload, 'models', ProviderModelDefinition.fromJson),
      error: _optionalString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'list_provider_models_response',
    'payload': {
      'provider': provider,
      if (models != null)
        'models': models!.map((entry) => entry.toJson()).toList(),
      'error': error,
      'fetchedAt': fetchedAt,
      'requestId': requestId,
    },
  };
}

final class ListProviderModesRequest {
  const ListProviderModesRequest({
    required this.provider,
    required this.requestId,
    this.cwd,
  });

  final String provider;
  final String? cwd;
  final String requestId;

  factory ListProviderModesRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'list_provider_modes_request');
    return ListProviderModesRequest(
      provider: _requiredString(json, 'provider'),
      cwd: _optionalString(json, 'cwd'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'list_provider_modes_request',
    'provider': provider,
    if (cwd != null) 'cwd': cwd,
    'requestId': requestId,
  };
}

final class ListProviderModesResponse {
  const ListProviderModesResponse({
    required this.provider,
    required this.requestId,
    required this.fetchedAt,
    this.modes,
    this.error,
  });

  final String provider;
  final String requestId;
  final String fetchedAt;
  final List<ProviderMode>? modes;
  final String? error;

  factory ListProviderModesResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'list_provider_modes_response');
    final payload = _requiredMap(json, 'payload');
    return ListProviderModesResponse(
      provider: _requiredString(payload, 'provider'),
      requestId: _requiredString(payload, 'requestId'),
      fetchedAt: _requiredString(payload, 'fetchedAt'),
      modes: payload['modes'] == null
          ? null
          : _mapList(payload, 'modes', ProviderMode.fromJson),
      error: _optionalString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'list_provider_modes_response',
    'payload': {
      'provider': provider,
      if (modes != null)
        'modes': modes!.map((entry) => entry.toJson()).toList(),
      'error': error,
      'fetchedAt': fetchedAt,
      'requestId': requestId,
    },
  };
}

final class GetProvidersSnapshotRequest {
  const GetProvidersSnapshotRequest({required this.requestId, this.cwd});

  final String requestId;
  final String? cwd;

  factory GetProvidersSnapshotRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'get_providers_snapshot_request');
    return GetProvidersSnapshotRequest(
      requestId: _requiredString(json, 'requestId'),
      cwd: _optionalString(json, 'cwd'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'get_providers_snapshot_request',
    if (cwd != null) 'cwd': cwd,
    'requestId': requestId,
  };
}

final class GetProvidersSnapshotResponse {
  const GetProvidersSnapshotResponse({
    required this.entries,
    required this.generatedAt,
    required this.requestId,
  });

  final List<ProviderSnapshotEntry> entries;
  final String generatedAt;
  final String requestId;

  factory GetProvidersSnapshotResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'get_providers_snapshot_response');
    final payload = _requiredMap(json, 'payload');
    return GetProvidersSnapshotResponse(
      entries: _mapList(payload, 'entries', ProviderSnapshotEntry.fromJson),
      generatedAt: _requiredString(payload, 'generatedAt'),
      requestId: _requiredString(payload, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'get_providers_snapshot_response',
    'payload': {
      'entries': entries.map((entry) => entry.toJson()).toList(),
      'generatedAt': generatedAt,
      'requestId': requestId,
    },
  };
}

final class ProvidersSnapshotUpdate {
  const ProvidersSnapshotUpdate({
    required this.entries,
    required this.generatedAt,
    this.cwd,
  });

  static const type = 'providers_snapshot_update';

  final String? cwd;
  final List<ProviderSnapshotEntry> entries;
  final String generatedAt;

  factory ProvidersSnapshotUpdate.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredMap(json, 'payload');
    return ProvidersSnapshotUpdate(
      cwd: _optionalString(payload, 'cwd'),
      entries: _mapList(payload, 'entries', ProviderSnapshotEntry.fromJson),
      generatedAt: _requiredString(payload, 'generatedAt'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      if (cwd != null) 'cwd': cwd,
      'entries': entries.map((entry) => entry.toJson()).toList(),
      'generatedAt': generatedAt,
    },
  };
}

final class RefreshProvidersSnapshotRequest {
  const RefreshProvidersSnapshotRequest({
    required this.requestId,
    this.cwd,
    this.providers,
  });

  final String requestId;
  final String? cwd;
  final List<String>? providers;

  factory RefreshProvidersSnapshotRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'refresh_providers_snapshot_request');
    return RefreshProvidersSnapshotRequest(
      requestId: _requiredString(json, 'requestId'),
      cwd: _optionalString(json, 'cwd'),
      providers: json['providers'] == null
          ? null
          : _stringList(json, 'providers'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'refresh_providers_snapshot_request',
    if (cwd != null) 'cwd': cwd,
    if (providers != null) 'providers': providers,
    'requestId': requestId,
  };
}

final class RefreshProvidersSnapshotResponse {
  const RefreshProvidersSnapshotResponse({
    required this.requestId,
    required this.acknowledged,
  });

  final String requestId;
  final bool acknowledged;

  factory RefreshProvidersSnapshotResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'refresh_providers_snapshot_response');
    final payload = _requiredMap(json, 'payload');
    return RefreshProvidersSnapshotResponse(
      requestId: _requiredString(payload, 'requestId'),
      acknowledged: _requiredBool(payload, 'acknowledged'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'refresh_providers_snapshot_response',
    'payload': {'requestId': requestId, 'acknowledged': acknowledged},
  };
}

final class ProviderDiagnosticRequest {
  const ProviderDiagnosticRequest({
    required this.provider,
    required this.requestId,
  });

  static const type = 'provider_diagnostic_request';

  final String provider;
  final String requestId;

  factory ProviderDiagnosticRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return ProviderDiagnosticRequest(
      provider: _requiredString(json, 'provider'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'provider': provider,
    'requestId': requestId,
  };
}

final class ProviderDiagnosticResponse {
  const ProviderDiagnosticResponse({
    required this.provider,
    required this.diagnostic,
    required this.requestId,
  });

  static const type = 'provider_diagnostic_response';

  final String provider;
  final String diagnostic;
  final String requestId;

  factory ProviderDiagnosticResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredMap(json, 'payload');
    return ProviderDiagnosticResponse(
      provider: _requiredString(payload, 'provider'),
      diagnostic: _requiredString(payload, 'diagnostic'),
      requestId: _requiredString(payload, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'provider': provider,
      'diagnostic': diagnostic,
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
  if (value is! String) {
    throw FormatException('$key must be a string');
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String? _optionalEnumString(
  Map<String, Object?> json,
  String key,
  Set<String> allowed,
) {
  final value = _optionalString(json, key);
  if (value != null && !allowed.contains(value)) {
    throw FormatException('$key has an unsupported value');
  }
  return value;
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

bool? _optionalBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

num? _optionalNum(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! num) throw FormatException('$key must be a number');
  return value;
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}

Map<String, Object?>? _optionalMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}

List<T> _mapList<T>(
  Map<String, Object?> json,
  String key,
  T Function(Map<String, Object?>) decode,
) {
  final value = json[key];
  if (value is! List) throw FormatException('$key must be an array');
  return [
    for (final item in value)
      if (item is Map)
        decode(Map<String, Object?>.from(item))
      else
        throw FormatException('$key entries must be objects'),
  ];
}

List<String> _stringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List || value.any((entry) => entry is! String)) {
    throw FormatException('$key must be a string array');
  }
  return value.cast<String>();
}
