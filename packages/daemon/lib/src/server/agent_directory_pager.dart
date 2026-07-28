import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';

final class AgentDirectoryCursorException implements Exception {
  const AgentDirectoryCursorException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class AgentDirectoryCursor {
  const AgentDirectoryCursor({
    required this.sort,
    required this.values,
    required this.agentId,
  });

  final List<AgentDirectorySort> sort;
  final Map<String, Object?> values;
  final String agentId;
}

List<AgentDirectorySort> normalizeAgentDirectorySort(
  List<AgentDirectorySort> sort,
) {
  if (sort.isEmpty) {
    return const [
      AgentDirectorySort(
        key: AgentDirectorySortKey.updatedAt,
        direction: AgentDirectorySortDirection.desc,
      ),
    ];
  }
  final seen = <AgentDirectorySortKey>{};
  return List.unmodifiable([
    for (final entry in sort)
      if (seen.add(entry.key)) entry,
  ]);
}

int compareAgentDirectoryEntries(
  AgentSummary left,
  AgentSummary right,
  List<AgentDirectorySort> sort,
) {
  for (final spec in sort) {
    final comparison = _compareValues(
      agentDirectorySortValue(left, spec.key),
      agentDirectorySortValue(right, spec.key),
    );
    if (comparison == 0) continue;
    return spec.direction == AgentDirectorySortDirection.asc
        ? comparison
        : -comparison;
  }
  return left.agentId.compareTo(right.agentId);
}

int compareAgentDirectoryEntryWithCursor(
  AgentSummary agent,
  AgentDirectoryCursor cursor,
  List<AgentDirectorySort> sort,
) {
  for (final spec in sort) {
    final comparison = _compareValues(
      agentDirectorySortValue(agent, spec.key),
      cursor.values[spec.key.wireName],
    );
    if (comparison == 0) continue;
    return spec.direction == AgentDirectorySortDirection.asc
        ? comparison
        : -comparison;
  }
  return agent.agentId.compareTo(cursor.agentId);
}

String encodeAgentDirectoryCursor(
  AgentSummary agent,
  List<AgentDirectorySort> sort,
) {
  final payload = jsonEncode({
    'sort': sort.map((entry) => entry.toJson()).toList(),
    'values': {
      for (final entry in sort)
        entry.key.wireName: agentDirectorySortValue(agent, entry.key),
    },
    'id': agent.agentId,
  });
  return base64Url.encode(utf8.encode(payload)).replaceAll('=', '');
}

AgentDirectoryCursor decodeAgentDirectoryCursor(
  String token,
  List<AgentDirectorySort> sort,
) {
  const invalid = AgentDirectoryCursorException('Invalid fetch_agents cursor');
  Object? decoded;
  try {
    decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(token))),
    );
  } on Object {
    throw invalid;
  }
  if (decoded is! Map || decoded is List) throw invalid;
  final payload = Map<String, Object?>.from(decoded);
  final rawSort = payload['sort'];
  final rawValues = payload['values'];
  final id = payload['id'];
  if (rawSort is! List ||
      rawValues is! Map ||
      rawValues is List ||
      id is! String) {
    throw invalid;
  }

  final cursorSort = <AgentDirectorySort>[];
  for (final rawEntry in rawSort) {
    if (rawEntry is! Map || rawEntry is List) throw invalid;
    try {
      cursorSort.add(
        AgentDirectorySort.fromJson(Map<String, Object?>.from(rawEntry)),
      );
    } on Object {
      throw invalid;
    }
  }
  if (cursorSort.length != sort.length) {
    throw const AgentDirectoryCursorException(
      'fetch_agents cursor does not match current sort',
    );
  }
  for (var index = 0; index < sort.length; index++) {
    if (cursorSort[index].key != sort[index].key ||
        cursorSort[index].direction != sort[index].direction) {
      throw const AgentDirectoryCursorException(
        'fetch_agents cursor does not match current sort',
      );
    }
  }
  return AgentDirectoryCursor(
    sort: List.unmodifiable(cursorSort),
    values: Map.unmodifiable(Map<String, Object?>.from(rawValues)),
    agentId: id,
  );
}

Object? agentDirectorySortValue(
  AgentSummary agent,
  AgentDirectorySortKey key,
) => switch (key) {
  AgentDirectorySortKey.statusPriority => agentDirectoryStatusPriority(agent),
  AgentDirectorySortKey.createdAt => agent.createdAtMs,
  AgentDirectorySortKey.updatedAt =>
    DateTime.tryParse(agent.updatedAt ?? '')?.millisecondsSinceEpoch ??
        agent.createdAtMs,
  AgentDirectorySortKey.title => agent.title.toLowerCase(),
};

int agentDirectoryStatusPriority(AgentSummary agent) {
  if (agent.runState == AgentRunState.awaitingPermission ||
      agent.attentionReason == AgentAttentionReason.permission) {
    return 0;
  }
  if (agent.runState == AgentRunState.error ||
      agent.attentionReason == AgentAttentionReason.error) {
    return 1;
  }
  if (agent.runState == AgentRunState.running) return 2;
  if (agent.runState == AgentRunState.initializing) return 3;
  return 4;
}

int _compareValues(Object? left, Object? right) {
  if (left == right) return 0;
  if (left == null) return -1;
  if (right == null) return 1;
  if (left is num && right is num) return left.compareTo(right);
  return left.toString().compareTo(right.toString());
}
