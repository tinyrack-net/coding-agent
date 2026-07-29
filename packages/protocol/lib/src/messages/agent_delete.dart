/// Frozen Paseo 0.2.0 hard-delete request and acknowledgement.
library;

final class DeleteAgentRequest {
  const DeleteAgentRequest({required this.requestId, required this.agentId});

  static const type = 'delete_agent_request';

  final String requestId;
  final String agentId;

  factory DeleteAgentRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected delete_agent_request');
    }
    return DeleteAgentRequest(
      requestId: _requiredString(json, 'requestId'),
      agentId: _requiredString(json, 'agentId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'agentId': agentId,
    'requestId': requestId,
  };
}

final class AgentDeletedResponse {
  const AgentDeletedResponse({required this.requestId, required this.agentId});

  static const type = 'agent_deleted';

  final String requestId;
  final String agentId;

  factory AgentDeletedResponse.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected agent_deleted');
    }
    final payload = json['payload'];
    if (payload is! Map) {
      throw const FormatException('agent_deleted payload must be an object');
    }
    final normalized = Map<String, Object?>.from(payload);
    return AgentDeletedResponse(
      requestId: _requiredString(normalized, 'requestId'),
      agentId: _requiredString(normalized, 'agentId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {'agentId': agentId, 'requestId': requestId},
  };
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}
