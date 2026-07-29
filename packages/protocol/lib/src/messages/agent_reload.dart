/// Frozen Paseo 0.2.0 user-facing agent refresh contract.
library;

final class RefreshAgentRequest {
  const RefreshAgentRequest({required this.requestId, required this.agentId});

  static const type = 'refresh_agent_request';

  final String requestId;
  final String agentId;

  factory RefreshAgentRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected refresh_agent_request');
    }
    return RefreshAgentRequest(
      requestId: _string(json, 'requestId'),
      agentId: _string(json, 'agentId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'agentId': agentId,
    'requestId': requestId,
  };
}

final class AgentRefreshedStatus {
  const AgentRefreshedStatus({
    required this.requestId,
    required this.agentId,
    this.timelineSize,
  });

  static const type = 'status';
  static const status = 'agent_refreshed';

  final String requestId;
  final String agentId;
  final num? timelineSize;

  factory AgentRefreshedStatus.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected status');
    }
    final rawPayload = json['payload'];
    if (rawPayload is! Map) {
      throw const FormatException('status payload must be an object');
    }
    final payload = Map<String, Object?>.from(rawPayload);
    if (payload['status'] != status) {
      throw const FormatException('Expected agent_refreshed status');
    }
    final timelineSize = payload['timelineSize'];
    if (timelineSize != null && timelineSize is! num) {
      throw const FormatException('timelineSize must be a number');
    }
    return AgentRefreshedStatus(
      requestId: _string(payload, 'requestId'),
      agentId: _string(payload, 'agentId'),
      timelineSize: timelineSize as num?,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'status': status,
      'agentId': agentId,
      'requestId': requestId,
      if (timelineSize != null) 'timelineSize': timelineSize,
    },
  };
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}
