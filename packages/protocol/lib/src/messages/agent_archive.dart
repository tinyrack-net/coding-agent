/// Frozen Paseo 0.2.0 agent archive request and acknowledgement.
library;

final class ArchiveAgentRequest {
  const ArchiveAgentRequest({required this.requestId, required this.agentId});

  static const type = 'archive_agent_request';

  final String requestId;
  final String agentId;

  factory ArchiveAgentRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected archive_agent_request');
    }
    return ArchiveAgentRequest(
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

final class AgentArchivedResponse {
  const AgentArchivedResponse({
    required this.requestId,
    required this.agentId,
    required this.archivedAt,
  });

  static const type = 'agent_archived';

  final String requestId;
  final String agentId;
  final String archivedAt;

  factory AgentArchivedResponse.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected agent_archived');
    }
    final payload = json['payload'];
    if (payload is! Map) {
      throw const FormatException('agent_archived payload must be an object');
    }
    final normalized = Map<String, Object?>.from(payload);
    final archivedAt = _requiredString(normalized, 'archivedAt');
    return AgentArchivedResponse(
      requestId: _requiredString(normalized, 'requestId'),
      agentId: _requiredString(normalized, 'agentId'),
      archivedAt: archivedAt,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'agentId': agentId,
      'archivedAt': archivedAt,
      'requestId': requestId,
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
