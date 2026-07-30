library;

enum ProviderUsageTone {
  defaultTone('default'),
  ok('ok'),
  warning('warning'),
  danger('danger');

  const ProviderUsageTone(this.wireValue);

  final String wireValue;

  static ProviderUsageTone fromWire(Object? value) => values.firstWhere(
    (tone) => tone.wireValue == value,
    orElse: () => throw FormatException('Unknown provider usage tone: $value'),
  );
}

enum ProviderUsageStatus {
  available,
  unavailable,
  error;

  static ProviderUsageStatus fromWire(Object? value) => values.firstWhere(
    (status) => status.name == value,
    orElse: () =>
        throw FormatException('Unknown provider usage status: $value'),
  );
}

enum ProviderUsageBalanceUnit {
  usd,
  credits,
  requests,
  tokens;

  static ProviderUsageBalanceUnit fromWire(Object? value) => values.firstWhere(
    (unit) => unit.name == value,
    orElse: () =>
        throw FormatException('Unknown provider usage balance unit: $value'),
  );
}

final class ProviderUsageWindow {
  const ProviderUsageWindow({
    required this.id,
    required this.label,
    this.usedPct,
    this.remainingPct,
    this.resetsAt,
    this.runsOutAt,
    this.shortfallPct,
    this.tone,
  });

  final String id;
  final String label;
  final double? usedPct;
  final double? remainingPct;
  final String? resetsAt;
  final String? runsOutAt;
  final double? shortfallPct;
  final ProviderUsageTone? tone;

  static ProviderUsageWindow fromJson(Map<String, Object?> json) =>
      ProviderUsageWindow(
        id: _requiredString(json, 'id'),
        label: _requiredString(json, 'label'),
        usedPct: _optionalFiniteDouble(json, 'usedPct'),
        remainingPct: _optionalFiniteDouble(json, 'remainingPct'),
        resetsAt: _optionalString(json, 'resetsAt'),
        runsOutAt: _optionalString(json, 'runsOutAt'),
        shortfallPct: _optionalFiniteDouble(json, 'shortfallPct'),
        tone: json['tone'] == null
            ? null
            : ProviderUsageTone.fromWire(json['tone']),
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    if (usedPct != null) 'usedPct': usedPct,
    if (remainingPct != null) 'remainingPct': remainingPct,
    if (resetsAt != null) 'resetsAt': resetsAt,
    if (runsOutAt != null) 'runsOutAt': runsOutAt,
    if (shortfallPct != null) 'shortfallPct': shortfallPct,
    if (tone != null) 'tone': tone!.wireValue,
  };
}

final class ProviderUsageBalance {
  const ProviderUsageBalance({
    required this.id,
    required this.label,
    required this.unit,
    this.used,
    this.remaining,
    this.limit,
    this.resetsAt,
    this.tone,
  });

  final String id;
  final String label;
  final double? used;
  final double? remaining;
  final double? limit;
  final ProviderUsageBalanceUnit unit;
  final String? resetsAt;
  final ProviderUsageTone? tone;

  static ProviderUsageBalance fromJson(Map<String, Object?> json) =>
      ProviderUsageBalance(
        id: _requiredString(json, 'id'),
        label: _requiredString(json, 'label'),
        used: _optionalFiniteDouble(json, 'used'),
        remaining: _optionalFiniteDouble(json, 'remaining'),
        limit: _optionalFiniteDouble(json, 'limit'),
        unit: ProviderUsageBalanceUnit.fromWire(json['unit']),
        resetsAt: _optionalString(json, 'resetsAt'),
        tone: json['tone'] == null
            ? null
            : ProviderUsageTone.fromWire(json['tone']),
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    if (used != null) 'used': used,
    if (remaining != null) 'remaining': remaining,
    if (limit != null) 'limit': limit,
    'unit': unit.name,
    if (resetsAt != null) 'resetsAt': resetsAt,
    if (tone != null) 'tone': tone!.wireValue,
  };
}

final class ProviderUsageDetail {
  const ProviderUsageDetail({
    required this.id,
    required this.label,
    required this.value,
    this.tone,
  });

  final String id;
  final String label;
  final String value;
  final ProviderUsageTone? tone;

  static ProviderUsageDetail fromJson(Map<String, Object?> json) =>
      ProviderUsageDetail(
        id: _requiredString(json, 'id'),
        label: _requiredString(json, 'label'),
        value: _requiredString(json, 'value'),
        tone: json['tone'] == null
            ? null
            : ProviderUsageTone.fromWire(json['tone']),
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'value': value,
    if (tone != null) 'tone': tone!.wireValue,
  };
}

final class ProviderUsage {
  const ProviderUsage({
    required this.providerId,
    required this.displayName,
    required this.status,
    required this.planLabel,
    required this.windows,
    this.sourceLabel,
    this.fetchedAt,
    this.nextRefreshAt,
    this.balances = const [],
    this.details = const [],
    this.error,
  });

  final String providerId;
  final String displayName;
  final ProviderUsageStatus status;
  final String? planLabel;
  final String? sourceLabel;
  final String? fetchedAt;
  final String? nextRefreshAt;
  final List<ProviderUsageWindow> windows;
  final List<ProviderUsageBalance> balances;
  final List<ProviderUsageDetail> details;
  final String? error;

  static ProviderUsage fromJson(Map<String, Object?> json) => ProviderUsage(
    providerId: _requiredString(json, 'providerId'),
    displayName: _requiredString(json, 'displayName'),
    status: ProviderUsageStatus.fromWire(json['status']),
    planLabel: _nullableString(json, 'planLabel', required: true),
    sourceLabel: _optionalString(json, 'sourceLabel'),
    fetchedAt: _optionalString(json, 'fetchedAt'),
    nextRefreshAt: _optionalString(json, 'nextRefreshAt'),
    windows: _objectList(
      json,
      'windows',
    ).map(ProviderUsageWindow.fromJson).toList(growable: false),
    balances: _objectList(
      json,
      'balances',
      required: false,
    ).map(ProviderUsageBalance.fromJson).toList(growable: false),
    details: _objectList(
      json,
      'details',
      required: false,
    ).map(ProviderUsageDetail.fromJson).toList(growable: false),
    error: _optionalString(json, 'error'),
  );

  Map<String, Object?> toJson() => {
    'providerId': providerId,
    'displayName': displayName,
    'status': status.name,
    'planLabel': planLabel,
    if (sourceLabel != null) 'sourceLabel': sourceLabel,
    if (fetchedAt != null) 'fetchedAt': fetchedAt,
    if (nextRefreshAt != null) 'nextRefreshAt': nextRefreshAt,
    'windows': windows.map((window) => window.toJson()).toList(),
    if (balances.isNotEmpty)
      'balances': balances.map((balance) => balance.toJson()).toList(),
    if (details.isNotEmpty)
      'details': details.map((detail) => detail.toJson()).toList(),
    if (error != null) 'error': error,
  };
}

final class ProviderUsageListRequest {
  const ProviderUsageListRequest({required this.requestId});

  static const type = 'provider.usage.list.request';
  final String requestId;

  static ProviderUsageListRequest fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw FormatException('Expected $type, got ${json['type']}');
    }
    return ProviderUsageListRequest(
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {'type': type, 'requestId': requestId};
}

final class ProviderUsageListResponse {
  const ProviderUsageListResponse({
    required this.requestId,
    required this.fetchedAt,
    required this.providers,
  });

  static const type = 'provider.usage.list.response';
  final String requestId;
  final String fetchedAt;
  final List<ProviderUsage> providers;

  static ProviderUsageListResponse fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw FormatException('Expected $type, got ${json['type']}');
    }
    final payload = _requiredObject(json, 'payload');
    return ProviderUsageListResponse(
      requestId: _requiredString(payload, 'requestId'),
      fetchedAt: _requiredString(payload, 'fetchedAt'),
      providers: _objectList(
        payload,
        'providers',
      ).map(ProviderUsage.fromJson).toList(growable: false),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'fetchedAt': fetchedAt,
      'providers': providers.map((provider) => provider.toJson()).toList(),
    },
  };
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  if (!json.containsKey(key) || json[key] == null) return null;
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string or null');
  return value;
}

String? _nullableString(
  Map<String, Object?> json,
  String key, {
  required bool required,
}) {
  if (!json.containsKey(key)) {
    if (required) throw FormatException('$key is required');
    return null;
  }
  return _optionalString(json, key);
}

double? _optionalFiniteDouble(Map<String, Object?> json, String key) {
  if (!json.containsKey(key) || json[key] == null) return null;
  final value = json[key];
  if (value is! num || !value.isFinite) {
    throw FormatException('$key must be a finite number or null');
  }
  return value.toDouble();
}

Map<String, Object?> _requiredObject(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}

List<Map<String, Object?>> _objectList(
  Map<String, Object?> json,
  String key, {
  bool required = true,
}) {
  if (!json.containsKey(key)) {
    if (required) throw FormatException('$key is required');
    return const [];
  }
  final value = json[key];
  if (value is! List || value.any((entry) => entry is! Map)) {
    throw FormatException('$key must be a list of objects');
  }
  return [for (final entry in value) Map<String, Object?>.from(entry as Map)];
}
