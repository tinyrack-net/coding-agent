/// Frozen Paseo 0.2.0 agent metadata update contract.
library;

import 'agent_config.dart';

final class UpdateAgentRequest {
  const UpdateAgentRequest({
    required this.requestId,
    required this.agentId,
    this.name,
    this.labels,
  });

  static const type = 'update_agent_request';

  final String requestId;
  final String agentId;
  final String? name;
  final Map<String, String>? labels;

  factory UpdateAgentRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected update_agent_request');
    }
    final name = json['name'];
    final rawLabels = json['labels'];
    if ((name != null && name is! String) ||
        (rawLabels != null && rawLabels is! Map)) {
      throw const FormatException('Invalid update_agent_request');
    }
    Map<String, String>? labels;
    if (rawLabels is Map) {
      try {
        labels = Map<String, String>.unmodifiable(
          Map<String, String>.from(rawLabels),
        );
      } on Object {
        throw const FormatException('labels must contain string values');
      }
    }
    return UpdateAgentRequest(
      requestId: _string(json, 'requestId'),
      agentId: _string(json, 'agentId'),
      name: name as String?,
      labels: labels,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'agentId': agentId,
    if (name != null) 'name': name,
    if (labels != null) 'labels': labels,
    'requestId': requestId,
  };
}

final class UpdateAgentResponse {
  const UpdateAgentResponse({
    required this.requestId,
    required this.agentId,
    required this.accepted,
    required this.error,
    this.notice,
  });

  static const type = 'update_agent_response';

  final String requestId;
  final String agentId;
  final bool accepted;
  final String? error;
  final AgentProviderNotice? notice;

  factory UpdateAgentResponse.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected update_agent_response');
    }
    final rawPayload = json['payload'];
    if (rawPayload is! Map) {
      throw const FormatException(
        'update_agent_response payload must be an object',
      );
    }
    final payload = Map<String, Object?>.from(rawPayload);
    final accepted = payload['accepted'];
    final error = payload['error'];
    final rawNotice = payload['notice'];
    if (accepted is! bool ||
        (error != null && error is! String) ||
        (rawNotice != null && rawNotice is! Map)) {
      throw const FormatException('Invalid update_agent_response');
    }
    return UpdateAgentResponse(
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
