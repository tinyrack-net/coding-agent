/// Frozen Paseo 0.2.0 provider-session discovery and import messages.
library;

import '../timeline/paseo_agent_snapshot_codec.dart';
import 'agent.dart';

final class RecentProviderSessionDescriptor {
  const RecentProviderSessionDescriptor({
    required this.providerId,
    required this.providerLabel,
    required this.providerHandleId,
    required this.cwd,
    required this.title,
    required this.firstPromptPreview,
    required this.lastPromptPreview,
    required this.lastActivityAt,
  });

  final String providerId;
  final String providerLabel;
  final String providerHandleId;
  final String cwd;
  final String? title;
  final String? firstPromptPreview;
  final String? lastPromptPreview;
  final String lastActivityAt;

  factory RecentProviderSessionDescriptor.fromJson(Map<String, Object?> json) =>
      RecentProviderSessionDescriptor(
        providerId: _requiredString(json, 'providerId'),
        providerLabel: _requiredString(json, 'providerLabel'),
        providerHandleId: _requiredString(json, 'providerHandleId'),
        cwd: _requiredString(json, 'cwd'),
        title: _requiredNullableString(json, 'title'),
        firstPromptPreview: _requiredNullableString(json, 'firstPromptPreview'),
        lastPromptPreview: _requiredNullableString(json, 'lastPromptPreview'),
        lastActivityAt: _requiredString(json, 'lastActivityAt'),
      );

  Map<String, Object?> toJson() => {
    'providerId': providerId,
    'providerLabel': providerLabel,
    'providerHandleId': providerHandleId,
    'cwd': cwd,
    'title': title,
    'firstPromptPreview': firstPromptPreview,
    'lastPromptPreview': lastPromptPreview,
    'lastActivityAt': lastActivityAt,
  };
}

final class FetchRecentProviderSessionsRequest {
  const FetchRecentProviderSessionsRequest({
    required this.requestId,
    this.cwd,
    this.providers,
    this.since,
    this.limit,
  });

  static const type = 'fetch_recent_provider_sessions_request';

  final String requestId;
  final String? cwd;
  final List<String>? providers;
  final String? since;
  final int? limit;

  factory FetchRecentProviderSessionsRequest.fromJson(
    Map<String, Object?> json,
  ) {
    _expectType(json, type);
    final limit = _optionalInt(json, 'limit');
    if (limit != null && (limit < 1 || limit > 200)) {
      throw const FormatException('limit must be between 1 and 200');
    }
    return FetchRecentProviderSessionsRequest(
      requestId: _requiredString(json, 'requestId'),
      cwd: _optionalString(json, 'cwd'),
      providers: _optionalStringList(json, 'providers'),
      since: _optionalString(json, 'since'),
      limit: limit,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    if (cwd != null) 'cwd': cwd,
    if (providers != null) 'providers': providers,
    if (since != null) 'since': since,
    if (limit != null) 'limit': limit,
  };
}

final class FetchRecentProviderSessionsResponse {
  const FetchRecentProviderSessionsResponse({
    required this.requestId,
    required this.entries,
    this.filteredAlreadyImportedCount,
  });

  static const type = 'fetch_recent_provider_sessions_response';

  final String requestId;
  final List<RecentProviderSessionDescriptor> entries;
  final int? filteredAlreadyImportedCount;

  factory FetchRecentProviderSessionsResponse.fromJson(
    Map<String, Object?> json,
  ) {
    _expectType(json, type);
    final payload = _requiredMap(json, 'payload');
    final count = _optionalInt(payload, 'filteredAlreadyImportedCount');
    if (count != null && count < 0) {
      throw const FormatException(
        'filteredAlreadyImportedCount must be non-negative',
      );
    }
    return FetchRecentProviderSessionsResponse(
      requestId: _requiredString(payload, 'requestId'),
      entries: _requiredMapList(
        payload,
        'entries',
        RecentProviderSessionDescriptor.fromJson,
      ),
      filteredAlreadyImportedCount: count,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'entries': entries.map((entry) => entry.toJson()).toList(),
      if (filteredAlreadyImportedCount != null)
        'filteredAlreadyImportedCount': filteredAlreadyImportedCount,
    },
  };
}

final class ImportAgentRequest {
  const ImportAgentRequest({
    required this.requestId,
    this.provider,
    this.providerId,
    this.sessionId,
    this.providerHandleId,
    this.cwd,
    this.workspaceId,
    this.labels,
  });

  static const type = 'import_agent_request';

  final String requestId;
  final String? provider;
  final String? providerId;
  final String? sessionId;
  final String? providerHandleId;
  final String? cwd;
  final String? workspaceId;
  final Map<String, String>? labels;

  factory ImportAgentRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return ImportAgentRequest(
      requestId: _requiredString(json, 'requestId'),
      provider: _optionalString(json, 'provider'),
      providerId: _optionalString(json, 'providerId'),
      sessionId: _optionalString(json, 'sessionId'),
      providerHandleId: _optionalString(json, 'providerHandleId'),
      cwd: _optionalString(json, 'cwd'),
      workspaceId: _optionalString(json, 'workspaceId'),
      labels: _optionalStringMap(json, 'labels'),
    );
  }

  String? get normalizedProvider => providerId ?? provider;
  String? get normalizedProviderHandleId => providerHandleId ?? sessionId;

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    if (provider != null) 'provider': provider,
    if (providerId != null) 'providerId': providerId,
    if (sessionId != null) 'sessionId': sessionId,
    if (providerHandleId != null) 'providerHandleId': providerHandleId,
    if (cwd != null) 'cwd': cwd,
    if (workspaceId != null) 'workspaceId': workspaceId,
    if (labels != null) 'labels': labels,
  };
}

final class ImportAgentStatusResponse {
  const ImportAgentStatusResponse({
    required this.requestId,
    required this.status,
    this.agentId,
    this.timelineSize,
    this.agent,
    this.error,
  });

  final String requestId;
  final String status;
  final String? agentId;
  final int? timelineSize;
  final AgentSummary? agent;
  final String? error;

  bool get succeeded => status == 'agent_resumed';

  factory ImportAgentStatusResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'status');
    final payload = _requiredMap(json, 'payload');
    final status = _requiredString(payload, 'status');
    if (status != 'agent_resumed' && status != 'agent_create_failed') {
      throw FormatException('Unknown import agent status: $status');
    }
    final timelineSize = _optionalInt(payload, 'timelineSize');
    if (timelineSize != null && timelineSize < 0) {
      throw const FormatException('timelineSize must be non-negative');
    }
    final rawAgent = payload['agent'];
    if (rawAgent != null && rawAgent is! Map) {
      throw const FormatException('agent must be an object');
    }
    final agent = rawAgent == null
        ? null
        : PaseoAgentSnapshotCodec.decode(
            (rawAgent as Map).cast<String, Object?>(),
          );
    final response = ImportAgentStatusResponse(
      requestId: _requiredString(payload, 'requestId'),
      status: status,
      agentId: _optionalString(payload, 'agentId'),
      timelineSize: timelineSize,
      agent: agent,
      error: _optionalString(payload, 'error'),
    );
    if (response.succeeded &&
        (response.agentId == null || response.agent == null)) {
      throw const FormatException('agent_resumed requires agentId and agent');
    }
    if (!response.succeeded && response.error == null) {
      throw const FormatException('agent_create_failed requires error');
    }
    return response;
  }
}

void _expectType(Map<String, Object?> json, String expected) {
  if (json['type'] != expected) {
    throw FormatException('Expected $expected');
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String? _requiredNullableString(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) throw FormatException('$key is required');
  final value = json[key];
  if (value != null && value is! String) {
    throw FormatException('$key must be a string or null');
  }
  return value as String?;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value != null && value is! String) {
    throw FormatException('$key must be a string');
  }
  return value as String?;
}

int? _optionalInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! num || value.toInt() != value) {
    throw FormatException('$key must be an integer');
  }
  return value.toInt();
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return value.cast<String, Object?>();
}

List<String>? _optionalStringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! List || value.any((entry) => entry is! String)) {
    throw FormatException('$key must be an array of strings');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

Map<String, String>? _optionalStringMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! Map ||
      value.keys.any((entry) => entry is! String) ||
      value.values.any((entry) => entry is! String)) {
    throw FormatException('$key must be a string map');
  }
  return Map<String, String>.unmodifiable(value.cast<String, String>());
}

List<T> _requiredMapList<T>(
  Map<String, Object?> json,
  String key,
  T Function(Map<String, Object?>) decode,
) {
  final value = json[key];
  if (value is! List) throw FormatException('$key must be an array');
  return List<T>.unmodifiable(
    value.map((entry) {
      if (entry is! Map) throw FormatException('$key entries must be objects');
      return decode(entry.cast<String, Object?>());
    }),
  );
}
