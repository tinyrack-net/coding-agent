enum AgentProviderNoticeType { info, warning, error }

final class AgentProviderNotice {
  const AgentProviderNotice({required this.type, required this.message});
  final AgentProviderNoticeType type;
  final String message;

  factory AgentProviderNotice.fromJson(Map<String, Object?> json) {
    final type = json['type'];
    final message = json['message'];
    if (type is! String || message is! String) {
      throw const FormatException('Invalid agent provider notice');
    }
    return AgentProviderNotice(
      type:
          AgentProviderNoticeType.values
              .where((value) => value.name == type)
              .firstOrNull ??
          (throw FormatException('Unknown agent provider notice type: $type')),
      message: message,
    );
  }

  Map<String, Object?> toJson() => {'type': type.name, 'message': message};
}

final class AgentConfigResponse {
  const AgentConfigResponse({
    required this.type,
    required this.requestId,
    required this.agentId,
    required this.accepted,
    required this.error,
    required this.notice,
  });

  final String type;
  final String requestId;
  final String agentId;
  final bool accepted;
  final String? error;
  final AgentProviderNotice? notice;

  factory AgentConfigResponse.fromJson(Map<String, Object?> json) {
    final type = json['type'];
    if (!const {
      'set_agent_mode_response',
      'set_agent_model_response',
      'set_agent_thinking_response',
      'set_agent_feature_response',
    }.contains(type)) {
      throw FormatException('Unknown agent config response: $type');
    }
    final payload = _map(json['payload'], 'agent config response payload');
    final accepted = payload['accepted'];
    final error = payload['error'];
    final notice = payload['notice'];
    if (accepted is! bool || (error != null && error is! String)) {
      throw const FormatException('Invalid agent config response');
    }
    return AgentConfigResponse(
      type: type! as String,
      requestId: _requiredString(payload, 'requestId'),
      agentId: _requiredString(payload, 'agentId'),
      accepted: accepted,
      error: error as String?,
      notice: notice == null
          ? null
          : AgentProviderNotice.fromJson(_map(notice, 'agent provider notice')),
    );
  }
}

sealed class AgentConfigRequest {
  const AgentConfigRequest({required this.agentId, required this.requestId});
  final String agentId;
  final String requestId;

  static AgentConfigRequest fromJson(Map<String, Object?> json) {
    final agentId = json['agentId'];
    final requestId = json['requestId'];
    if (agentId is! String || requestId is! String) {
      throw const FormatException('Invalid agent config request');
    }
    return switch (json['type']) {
      'set_agent_mode_request' => SetAgentModeRequest(
        agentId: agentId,
        modeId: _requiredString(json, 'modeId'),
        requestId: requestId,
      ),
      'set_agent_model_request' => SetAgentModelRequest(
        agentId: agentId,
        modelId: _nullableString(json, 'modelId'),
        requestId: requestId,
      ),
      'set_agent_thinking_request' => SetAgentThinkingRequest(
        agentId: agentId,
        thinkingOptionId: _nullableString(json, 'thinkingOptionId'),
        requestId: requestId,
      ),
      'set_agent_feature_request' => SetAgentFeatureRequest(
        agentId: agentId,
        featureId: _requiredString(json, 'featureId'),
        value: json['value'],
        requestId: requestId,
      ),
      _ => throw const FormatException('Unknown agent config request'),
    };
  }
}

final class SetAgentModeRequest extends AgentConfigRequest {
  const SetAgentModeRequest({
    required super.agentId,
    required this.modeId,
    required super.requestId,
  });
  final String modeId;
}

final class SetAgentModelRequest extends AgentConfigRequest {
  const SetAgentModelRequest({
    required super.agentId,
    required this.modelId,
    required super.requestId,
  });
  final String? modelId;
}

final class SetAgentThinkingRequest extends AgentConfigRequest {
  const SetAgentThinkingRequest({
    required super.agentId,
    required this.thinkingOptionId,
    required super.requestId,
  });
  final String? thinkingOptionId;
}

final class SetAgentFeatureRequest extends AgentConfigRequest {
  const SetAgentFeatureRequest({
    required super.agentId,
    required this.featureId,
    required this.value,
    required super.requestId,
  });
  final String featureId;
  final Object? value;
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('Invalid $key');
  return value;
}

String? _nullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value != null && value is! String) throw FormatException('Invalid $key');
  return value as String?;
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is! Map) throw FormatException('$field must be an object');
  return Map<String, Object?>.from(value);
}
