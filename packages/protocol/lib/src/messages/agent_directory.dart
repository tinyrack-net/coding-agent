/// Frozen Paseo 0.2.0 paginated agent-directory messages.
library;

import '../timeline/paseo_agent_snapshot_codec.dart';
import 'agent.dart';

enum AgentDirectorySortKey {
  statusPriority('status_priority'),
  createdAt('created_at'),
  updatedAt('updated_at'),
  title('title');

  const AgentDirectorySortKey(this.wireName);
  final String wireName;

  static AgentDirectorySortKey fromWire(Object? value) => values.firstWhere(
    (entry) => entry.wireName == value,
    orElse: () =>
        throw FormatException('Unknown agent directory sort key: $value'),
  );
}

enum AgentDirectorySortDirection { asc, desc }

final class AgentDirectorySort {
  const AgentDirectorySort({required this.key, required this.direction});

  final AgentDirectorySortKey key;
  final AgentDirectorySortDirection direction;

  factory AgentDirectorySort.fromJson(Map<String, Object?> json) =>
      AgentDirectorySort(
        key: AgentDirectorySortKey.fromWire(json['key']),
        direction: AgentDirectorySortDirection.values.byName(
          _requiredString(json, 'direction'),
        ),
      );

  Map<String, Object?> toJson() => {
    'key': key.wireName,
    'direction': direction.name,
  };
}

final class AgentDirectoryFilter {
  const AgentDirectoryFilter({
    this.labels = const {},
    this.projectKeys = const [],
    this.statuses = const [],
    this.includeArchived,
    this.requiresAttention,
    this.thinkingOptionId,
    this.hasThinkingOptionId = false,
  });

  final Map<String, String> labels;
  final List<String> projectKeys;
  final List<String> statuses;
  final bool? includeArchived;
  final bool? requiresAttention;
  final String? thinkingOptionId;
  final bool hasThinkingOptionId;

  factory AgentDirectoryFilter.fromJson(Map<String, Object?> json) {
    final labels = _stringMap(json, 'labels');
    final statuses = _stringList(json, 'statuses');
    const lifecycleStatuses = {
      'initializing',
      'idle',
      'running',
      'error',
      'closed',
    };
    for (final status in statuses) {
      if (!lifecycleStatuses.contains(status)) {
        throw FormatException('Unknown agent lifecycle status: $status');
      }
    }
    return AgentDirectoryFilter(
      labels: labels,
      projectKeys: _stringList(json, 'projectKeys'),
      statuses: statuses,
      includeArchived: _nullableBool(json, 'includeArchived'),
      requiresAttention: _nullableBool(json, 'requiresAttention'),
      thinkingOptionId: _nullableString(json, 'thinkingOptionId'),
      hasThinkingOptionId: json.containsKey('thinkingOptionId'),
    );
  }

  Map<String, Object?> toJson() => {
    if (labels.isNotEmpty) 'labels': labels,
    if (projectKeys.isNotEmpty) 'projectKeys': projectKeys,
    if (statuses.isNotEmpty) 'statuses': statuses,
    if (includeArchived != null) 'includeArchived': includeArchived,
    if (requiresAttention != null) 'requiresAttention': requiresAttention,
    if (hasThinkingOptionId) 'thinkingOptionId': thinkingOptionId,
  };
}

final class FetchAgentsRequest {
  const FetchAgentsRequest({
    required this.requestId,
    this.activeScope = false,
    this.filter,
    this.sort = const [],
    this.limit,
    this.cursor,
    this.hasSubscription = false,
    this.subscriptionId,
  });

  static const type = 'fetch_agents_request';

  final String requestId;
  final bool activeScope;
  final AgentDirectoryFilter? filter;
  final List<AgentDirectorySort> sort;
  final int? limit;
  final String? cursor;
  final bool hasSubscription;
  final String? subscriptionId;

  factory FetchAgentsRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final scope = json['scope'];
    if (scope != null && scope != 'active') {
      throw FormatException('Unknown agent directory scope: $scope');
    }
    final filter = _nullableMap(json, 'filter');
    final page = _nullableMap(json, 'page');
    final subscribe = _nullableMap(json, 'subscribe');
    final limit = page == null ? null : _requiredInt(page, 'limit');
    if (limit != null && (limit < 1 || limit > 200)) {
      throw const FormatException('page.limit must be between 1 and 200');
    }
    final cursor = page == null ? null : _nullableString(page, 'cursor');
    if (cursor != null && cursor.isEmpty) {
      throw const FormatException('page.cursor must not be empty');
    }
    return FetchAgentsRequest(
      requestId: _requiredString(json, 'requestId'),
      activeScope: scope == 'active',
      filter: filter == null ? null : AgentDirectoryFilter.fromJson(filter),
      sort: _mapList(json, 'sort', AgentDirectorySort.fromJson),
      limit: limit,
      cursor: cursor,
      hasSubscription: subscribe != null,
      subscriptionId: subscribe == null
          ? null
          : _nullableString(subscribe, 'subscriptionId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    if (activeScope) 'scope': 'active',
    if (filter != null && filter!.toJson().isNotEmpty)
      'filter': filter!.toJson(),
    if (sort.isNotEmpty) 'sort': sort.map((entry) => entry.toJson()).toList(),
    if (limit != null || cursor != null)
      'page': {
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      },
    if (hasSubscription)
      'subscribe': {
        if (subscriptionId != null) 'subscriptionId': subscriptionId,
      },
  };
}

final class FetchAgentHistoryRequest {
  const FetchAgentHistoryRequest({
    required this.requestId,
    this.filter,
    this.sort = const [],
    this.limit,
    this.cursor,
  });

  static const type = 'fetch_agent_history_request';

  final String requestId;
  final AgentDirectoryFilter? filter;
  final List<AgentDirectorySort> sort;
  final int? limit;
  final String? cursor;

  factory FetchAgentHistoryRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final filter = _nullableMap(json, 'filter');
    final page = _nullableMap(json, 'page');
    final limit = page == null ? null : _requiredInt(page, 'limit');
    if (limit != null && (limit < 1 || limit > 200)) {
      throw const FormatException('page.limit must be between 1 and 200');
    }
    final cursor = page == null ? null : _nullableString(page, 'cursor');
    if (cursor != null && cursor.isEmpty) {
      throw const FormatException('page.cursor must not be empty');
    }
    return FetchAgentHistoryRequest(
      requestId: _requiredString(json, 'requestId'),
      filter: filter == null ? null : AgentDirectoryFilter.fromJson(filter),
      sort: _mapList(json, 'sort', AgentDirectorySort.fromJson),
      limit: limit,
      cursor: cursor,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    if (filter != null && filter!.toJson().isNotEmpty)
      'filter': filter!.toJson(),
    if (sort.isNotEmpty) 'sort': sort.map((entry) => entry.toJson()).toList(),
    if (limit != null || cursor != null)
      'page': {
        if (limit != null) 'limit': limit,
        if (cursor != null) 'cursor': cursor,
      },
  };
}

final class FetchAgentRequest {
  const FetchAgentRequest({required this.requestId, required this.agentId});

  static const type = 'fetch_agent_request';

  final String requestId;
  final String agentId;

  factory FetchAgentRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return FetchAgentRequest(
      requestId: _requiredString(json, 'requestId'),
      agentId: _requiredString(json, 'agentId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'agentId': agentId,
  };
}

final class AgentDirectoryEntry {
  const AgentDirectoryEntry({required this.agent, required this.project});

  final AgentSummary agent;
  final Map<String, Object?> project;

  factory AgentDirectoryEntry.fromJson(Map<String, Object?> json) =>
      AgentDirectoryEntry(
        agent: PaseoAgentSnapshotCodec.decode(_requiredMap(json, 'agent')),
        project: Map.unmodifiable(_requiredMap(json, 'project')),
      );

  Map<String, Object?> toJson() => {
    'agent': PaseoAgentSnapshotCodec.encode(agent),
    'project': project,
  };
}

final class AgentDirectoryPageInfo {
  const AgentDirectoryPageInfo({
    required this.nextCursor,
    required this.prevCursor,
    required this.hasMore,
  });

  final String? nextCursor;
  final String? prevCursor;
  final bool hasMore;

  factory AgentDirectoryPageInfo.fromJson(Map<String, Object?> json) =>
      AgentDirectoryPageInfo(
        nextCursor: _nullableString(json, 'nextCursor'),
        prevCursor: _nullableString(json, 'prevCursor'),
        hasMore: _requiredBool(json, 'hasMore'),
      );

  Map<String, Object?> toJson() => {
    'nextCursor': nextCursor,
    'prevCursor': prevCursor,
    'hasMore': hasMore,
  };
}

final class FetchAgentsResponse {
  const FetchAgentsResponse({
    required this.requestId,
    required this.entries,
    required this.pageInfo,
    this.subscriptionId,
  });

  static const type = 'fetch_agents_response';

  final String requestId;
  final String? subscriptionId;
  final List<AgentDirectoryEntry> entries;
  final AgentDirectoryPageInfo pageInfo;

  factory FetchAgentsResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredMap(json, 'payload');
    return FetchAgentsResponse(
      requestId: _requiredString(payload, 'requestId'),
      subscriptionId: _nullableString(payload, 'subscriptionId'),
      entries: _mapList(payload, 'entries', AgentDirectoryEntry.fromJson),
      pageInfo: AgentDirectoryPageInfo.fromJson(
        _requiredMap(payload, 'pageInfo'),
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      if (subscriptionId != null) 'subscriptionId': subscriptionId,
      'entries': entries.map((entry) => entry.toJson()).toList(),
      'pageInfo': pageInfo.toJson(),
    },
  };
}

final class FetchAgentHistoryResponse {
  const FetchAgentHistoryResponse({
    required this.requestId,
    required this.entries,
    required this.pageInfo,
  });

  static const type = 'fetch_agent_history_response';

  final String requestId;
  final List<AgentDirectoryEntry> entries;
  final AgentDirectoryPageInfo pageInfo;

  factory FetchAgentHistoryResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredMap(json, 'payload');
    return FetchAgentHistoryResponse(
      requestId: _requiredString(payload, 'requestId'),
      entries: _mapList(payload, 'entries', AgentDirectoryEntry.fromJson),
      pageInfo: AgentDirectoryPageInfo.fromJson(
        _requiredMap(payload, 'pageInfo'),
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'entries': entries.map((entry) => entry.toJson()).toList(),
      'pageInfo': pageInfo.toJson(),
    },
  };
}

final class FetchAgentResponse {
  const FetchAgentResponse({
    required this.requestId,
    required this.agent,
    required this.project,
    required this.error,
  });

  static const type = 'fetch_agent_response';

  final String requestId;
  final AgentSummary? agent;
  final Map<String, Object?>? project;
  final String? error;

  factory FetchAgentResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredMap(json, 'payload');
    if (!payload.containsKey('agent')) {
      throw const FormatException('agent is required');
    }
    if (!payload.containsKey('error')) {
      throw const FormatException('error is required');
    }
    final agent = _nullableMap(payload, 'agent');
    return FetchAgentResponse(
      requestId: _requiredString(payload, 'requestId'),
      agent: agent == null ? null : PaseoAgentSnapshotCodec.decode(agent),
      project: _nullableMap(payload, 'project'),
      error: _nullableString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'agent': agent == null ? null : PaseoAgentSnapshotCodec.encode(agent!),
      'project': project,
      'error': error,
    },
  };
}

void _expectType(Map<String, Object?> json, String expected) {
  if (json['type'] != expected) {
    throw FormatException('Expected $expected');
  }
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is Map) return Map<String, Object?>.from(value);
  throw FormatException('$key must be an object');
}

Map<String, Object?>? _nullableMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is Map) return Map<String, Object?>.from(value);
  throw FormatException('$key must be an object');
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('$key must be a non-empty string');
}

String? _nullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is String) return value;
  throw FormatException('$key must be a string or null');
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('$key must be an integer');
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('$key must be a boolean');
}

bool? _nullableBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is bool) return value;
  throw FormatException('$key must be a boolean');
}

Map<String, String> _stringMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return const {};
  if (value is! Map) throw FormatException('$key must be an object');
  final result = <String, String>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! String) {
      throw FormatException('$key must contain string values');
    }
    result[entry.key as String] = entry.value as String;
  }
  return Map.unmodifiable(result);
}

List<String> _stringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return const [];
  if (value is! List || value.any((entry) => entry is! String)) {
    throw FormatException('$key must be a string array');
  }
  return List<String>.unmodifiable(value.cast<String>());
}

List<T> _mapList<T>(
  Map<String, Object?> json,
  String key,
  T Function(Map<String, Object?>) parse,
) {
  final value = json[key];
  if (value == null) return const [];
  if (value is! List) throw FormatException('$key must be an array');
  return List<T>.unmodifiable(
    value.map((entry) {
      if (entry is! Map) throw FormatException('$key entry must be an object');
      return parse(Map<String, Object?>.from(entry));
    }),
  );
}
