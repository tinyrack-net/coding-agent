/// Frozen Paseo 0.2.0 managed-subagent detach contract.
library;

import 'agent_config.dart';

final class AgentDetachRequest {
  const AgentDetachRequest({required this.requestId, required this.agentId});

  static const type = 'agent.detach.request';

  final String requestId;
  final String agentId;

  factory AgentDetachRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected agent.detach.request');
    }
    return AgentDetachRequest(
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

final class AgentDetachResponse {
  const AgentDetachResponse({
    required this.requestId,
    required this.agentId,
    required this.accepted,
    required this.error,
    this.notice,
  });

  static const type = 'agent.detach.response';

  final String requestId;
  final String agentId;
  final bool accepted;
  final String? error;
  final AgentProviderNotice? notice;

  factory AgentDetachResponse.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected agent.detach.response');
    }
    final rawPayload = json['payload'];
    if (rawPayload is! Map) {
      throw const FormatException(
        'agent.detach.response payload must be an object',
      );
    }
    final payload = Map<String, Object?>.from(rawPayload);
    final accepted = payload['accepted'];
    final error = payload['error'];
    final rawNotice = payload['notice'];
    if (accepted is! bool ||
        (error != null && error is! String) ||
        (rawNotice != null && rawNotice is! Map)) {
      throw const FormatException('Invalid agent.detach.response');
    }
    return AgentDetachResponse(
      requestId: _string(payload, 'requestId'),
      agentId: _string(payload, 'agentId'),
      accepted: accepted,
      error: error as String?,
      notice: rawNotice == null
          ? null
          : AgentProviderNotice.fromJson(
              Map<String, Object?>.from(rawNotice as Map),
            ),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'agentId': agentId,
      'accepted': accepted,
      'error': error,
      if (notice != null) 'notice': notice!.toJson(),
    },
  };
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}
