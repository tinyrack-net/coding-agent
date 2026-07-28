import 'package:agent_protocol/agent_protocol.dart';
import 'package:uuid/uuid.dart';

import '../agent/agent_manager.dart';
import 'connection.dart';

final class AgentConfigService {
  const AgentConfigService(this.manager);
  final AgentManager manager;

  Future<Object?> handle(
    Connection connection,
    Map<String, Object?> message,
  ) async {
    final type = message['type'];
    if (type != 'set_agent_mode_request' &&
        type != 'set_agent_model_request' &&
        type != 'set_agent_thinking_request' &&
        type != 'set_agent_feature_request') {
      return null;
    }
    final request = AgentConfigRequest.fromJson(message);
    final responseType = switch (request) {
      SetAgentModeRequest() => 'set_agent_mode_response',
      SetAgentModelRequest() => 'set_agent_model_response',
      SetAgentThinkingRequest() => 'set_agent_thinking_response',
      SetAgentFeatureRequest() => 'set_agent_feature_response',
    };
    final failureText = switch (request) {
      SetAgentModeRequest() => 'Failed to set agent mode',
      SetAgentModelRequest() => 'Failed to set agent model',
      SetAgentThinkingRequest() => 'Failed to set agent thinking option',
      SetAgentFeatureRequest() => 'Failed to set agent feature',
    };
    try {
      await manager.ensureLoaded(request.agentId);
      final notice = await switch (request) {
        SetAgentModeRequest value => manager.setModeId(
          value.agentId,
          value.modeId,
        ),
        SetAgentModelRequest value =>
          manager
              .setModelId(value.agentId, value.modelId)
              .then<AgentProviderNotice?>((_) => null),
        SetAgentThinkingRequest value => manager.setThinkingOption(
          value.agentId,
          value.thinkingOptionId,
        ),
        SetAgentFeatureRequest value =>
          manager
              .setFeature(value.agentId, value.featureId, value.value)
              .then<AgentProviderNotice?>((_) => null),
      };
      return _response(responseType, request, accepted: true, notice: notice);
    } catch (error) {
      final message = _errorMessage(error);
      connection.sendJson({
        'type': 'session',
        'message': {
          'type': 'activity_log',
          'payload': {
            'id': const Uuid().v4(),
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'type': 'error',
            'content': '$failureText: $message',
          },
        },
      });
      return _response(
        responseType,
        request,
        accepted: false,
        error: message.isEmpty ? failureText : message,
      );
    }
  }
}

Map<String, Object?> _response(
  String type,
  AgentConfigRequest request, {
  required bool accepted,
  String? error,
  AgentProviderNotice? notice,
}) => {
  'type': type,
  'payload': {
    'requestId': request.requestId,
    'agentId': request.agentId,
    'accepted': accepted,
    'error': error,
    if (notice != null) 'notice': notice.toJson(),
  },
};

String _errorMessage(Object error) {
  if (error case final ArgumentError value)
    return value.message?.toString() ?? '';
  if (error case final UnsupportedError value) return value.message ?? '';
  return '$error'.replaceFirst(RegExp(r'^[^:]+Exception: '), '');
}
