/// Provider discovery + credential messages (`provider.list`,
/// `provider.credential.*`).
library;

enum ProviderId {
  openai,
  deepseek,
  openrouter;

  static ProviderId fromWire(String value) =>
      ProviderId.values.firstWhere((p) => p.name == value);
}

final class ProviderInfo {
  const ProviderInfo({
    required this.id,
    required this.displayName,
    required this.configured,
    this.models = const [],
    this.unavailableReason,
  });

  final ProviderId id;
  final String displayName;

  /// Whether a valid API key is stored for this provider.
  final bool configured;
  final List<ProviderModel> models;
  final String? unavailableReason;

  static ProviderInfo fromJson(Map<String, Object?> json) => ProviderInfo(
        id: ProviderId.fromWire(json['id'] as String),
        displayName: (json['displayName'] as String?) ?? '',
        configured: (json['configured'] as bool?) ?? false,
        models: ((json['models'] as List?) ?? const [])
            .cast<Map<String, Object?>>()
            .map(ProviderModel.fromJson)
            .toList(),
        unavailableReason: json['unavailableReason'] as String?,
      );

  Map<String, Object?> toJson() => {
        'id': id.name,
        'displayName': displayName,
        'configured': configured,
        'models': models.map((m) => m.toJson()).toList(),
        if (unavailableReason != null) 'unavailableReason': unavailableReason,
      };
}

final class ProviderModel {
  const ProviderModel({required this.id, required this.displayName});

  final String id;
  final String displayName;

  static ProviderModel fromJson(Map<String, Object?> json) => ProviderModel(
        id: json['id'] as String,
        displayName: (json['displayName'] as String?) ?? json['id'] as String,
      );

  Map<String, Object?> toJson() => {'id': id, 'displayName': displayName};
}

final class ProviderListResponse {
  const ProviderListResponse({required this.providers});

  final List<ProviderInfo> providers;

  static ProviderListResponse fromJson(Map<String, Object?> json) =>
      ProviderListResponse(
        providers: ((json['providers'] as List?) ?? const [])
            .cast<Map<String, Object?>>()
            .map(ProviderInfo.fromJson)
            .toList(),
      );

  Map<String, Object?> toJson() => {
        'providers': providers.map((p) => p.toJson()).toList(),
      };
}

/// Result of `provider.credential.test.request` — attempts a lightweight call
/// against the provider's API to confirm the stored (or given) key works.
final class ProviderCredentialTestResult {
  const ProviderCredentialTestResult({required this.ok, this.error});

  final bool ok;
  final String? error;

  static ProviderCredentialTestResult fromJson(Map<String, Object?> json) =>
      ProviderCredentialTestResult(
        ok: (json['ok'] as bool?) ?? false,
        error: json['error'] as String?,
      );

  Map<String, Object?> toJson() =>
      {'ok': ok, if (error != null) 'error': error};
}
