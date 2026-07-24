/// Provider discovery messages (`provider.list`).
library;

enum ProviderId {
  claude,
  codex;

  static ProviderId fromWire(String value) =>
      ProviderId.values.firstWhere((p) => p.name == value);
}

final class ProviderInfo {
  const ProviderInfo({
    required this.id,
    required this.displayName,
    required this.available,
    this.executablePath,
    this.version,
    this.models = const [],
    this.unavailableReason,
  });

  final ProviderId id;
  final String displayName;

  /// Whether the provider CLI was found and responds on this machine.
  final bool available;
  final String? executablePath;
  final String? version;
  final List<ProviderModel> models;
  final String? unavailableReason;

  static ProviderInfo fromJson(Map<String, Object?> json) => ProviderInfo(
        id: ProviderId.fromWire(json['id'] as String),
        displayName: (json['displayName'] as String?) ?? '',
        available: (json['available'] as bool?) ?? false,
        executablePath: json['executablePath'] as String?,
        version: json['version'] as String?,
        models: ((json['models'] as List?) ?? const [])
            .cast<Map<String, Object?>>()
            .map(ProviderModel.fromJson)
            .toList(),
        unavailableReason: json['unavailableReason'] as String?,
      );

  Map<String, Object?> toJson() => {
        'id': id.name,
        'displayName': displayName,
        'available': available,
        if (executablePath != null) 'executablePath': executablePath,
        if (version != null) 'version': version,
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
