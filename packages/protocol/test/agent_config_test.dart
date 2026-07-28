import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('parses all frozen agent config request variants', () {
    expect(
      (AgentConfigRequest.fromJson({
                'type': 'set_agent_mode_request',
                'agentId': 'a',
                'modeId': 'read-only',
                'requestId': '1',
              })
              as SetAgentModeRequest)
          .modeId,
      'read-only',
    );
    expect(
      (AgentConfigRequest.fromJson({
                'type': 'set_agent_model_request',
                'agentId': 'a',
                'modelId': null,
                'requestId': '2',
              })
              as SetAgentModelRequest)
          .modelId,
      isNull,
    );
    expect(
      (AgentConfigRequest.fromJson({
                'type': 'set_agent_thinking_request',
                'agentId': 'a',
                'thinkingOptionId': 'high',
                'requestId': '3',
              })
              as SetAgentThinkingRequest)
          .thinkingOptionId,
      'high',
    );
    expect(
      (AgentConfigRequest.fromJson({
                'type': 'set_agent_feature_request',
                'agentId': 'a',
                'featureId': 'search',
                'value': {'nested': true},
                'requestId': '4',
              })
              as SetAgentFeatureRequest)
          .value,
      {'nested': true},
    );
  });

  test('provider notice and AgentSummary config fields round trip', () {
    const notice = AgentProviderNotice(
      type: AgentProviderNoticeType.warning,
      message: 'restart required',
    );
    expect(AgentProviderNotice.fromJson(notice.toJson()).toJson(), {
      'type': 'warning',
      'message': 'restart required',
    });
    final summary = AgentSummary.fromJson({
      'agentId': 'a',
      'model': 'm',
      'thinkingOptionId': 'high',
      'featureValues': {'search': true},
      'systemPrompt': 'Voice instructions',
    });
    expect(summary.toJson()['thinkingOptionId'], 'high');
    expect(summary.featureValues, {'search': true});
    expect(summary.systemPrompt, 'Voice instructions');
    expect(
      summary
          .copyWith(model: null, thinkingOptionId: null, systemPrompt: null)
          .toJson(),
      allOf(
        isNot(contains('thinkingOptionId')),
        isNot(contains('systemPrompt')),
      ),
    );
  });

  test('parses optional provider notices on config responses', () {
    final response = AgentConfigResponse.fromJson({
      'type': 'set_agent_mode_response',
      'payload': {
        'requestId': 'request',
        'agentId': 'agent',
        'accepted': true,
        'error': null,
        'notice': {
          'type': 'warning',
          'message': 'Permission mode applies next turn',
        },
      },
    });

    expect(response.requestId, 'request');
    expect(response.agentId, 'agent');
    expect(response.accepted, isTrue);
    expect(response.notice?.type, AgentProviderNoticeType.warning);
    expect(response.notice?.message, 'Permission mode applies next turn');
    expect(
      AgentConfigResponse.fromJson({
        'type': 'set_agent_thinking_response',
        'payload': {
          'requestId': 'thinking',
          'agentId': 'agent',
          'accepted': true,
          'error': null,
        },
      }).notice,
      isNull,
    );
  });

  test('rejects malformed and unknown request boundaries', () {
    for (final value in <Map<String, Object?>>[
      {'type': 'unknown', 'agentId': 'a', 'requestId': 'r'},
      {
        'type': 'set_agent_mode_request',
        'agentId': 'a',
        'modeId': 1,
        'requestId': 'r',
      },
      {
        'type': 'set_agent_model_request',
        'agentId': 'a',
        'modelId': 1,
        'requestId': 'r',
      },
      {
        'type': 'set_agent_feature_request',
        'agentId': 1,
        'featureId': 'x',
        'requestId': 'r',
      },
    ]) {
      expect(() => AgentConfigRequest.fromJson(value), throwsFormatException);
    }
    for (final value in <Map<String, Object?>>[
      {
        'type': 'set_agent_mode_response',
        'payload': {
          'requestId': 'r',
          'agentId': 'a',
          'accepted': true,
          'error': null,
          'notice': {'type': 'unknown', 'message': 'bad'},
        },
      },
      {
        'type': 'unknown_response',
        'payload': {
          'requestId': 'r',
          'agentId': 'a',
          'accepted': true,
          'error': null,
        },
      },
      {
        'type': 'set_agent_mode_response',
        'payload': {'accepted': 'yes'},
      },
    ]) {
      expect(() => AgentConfigResponse.fromJson(value), throwsFormatException);
    }
  });
}
