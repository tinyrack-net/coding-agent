/// Frozen Paseo 0.2.0 agent cancellation request/response contract.
library;

import '../timeline/paseo_agent_snapshot_codec.dart';

final class CancelAgentRequest {
  const CancelAgentRequest({required this.agentId, this.requestId});

  static const type = 'cancel_agent_request';

  final String agentId;
  final String? requestId;

  factory CancelAgentRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected cancel_agent_request');
    }
    final agentId = json['agentId'];
    final requestId = json['requestId'];
    if (agentId is! String ||
        agentId.isEmpty ||
        (requestId != null && requestId is! String)) {
      throw const FormatException('Invalid cancel_agent_request');
    }
    return CancelAgentRequest(
      agentId: agentId,
      requestId: requestId as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'agentId': agentId,
    if (requestId != null) 'requestId': requestId,
  };
}

final class CancelAgentResponse {
  const CancelAgentResponse({
    required this.requestId,
    required this.agentId,
    required this.agent,
    required this.error,
  });

  static const type = 'cancel_agent_response';

  final String requestId;
  final String agentId;
  final Map<String, Object?>? agent;
  final String? error;

  factory CancelAgentResponse.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected cancel_agent_response');
    }
    final payload = _requiredMap(json, 'payload');
    final requestId = payload['requestId'];
    final agentId = payload['agentId'];
    final rawAgent = payload['agent'];
    final error = payload['error'];
    if (requestId is! String ||
        agentId is! String ||
        (rawAgent != null && rawAgent is! Map) ||
        (error != null && error is! String)) {
      throw const FormatException('Invalid cancel_agent_response');
    }
    final agent = rawAgent == null
        ? null
        : Map<String, Object?>.from(rawAgent as Map);
    if (agent != null) PaseoAgentSnapshotCodec.decode(agent);
    return CancelAgentResponse(
      requestId: requestId,
      agentId: agentId,
      agent: agent,
      error: error as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'agentId': agentId,
      'agent': agent,
      'error': error,
    },
  };
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}
