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
    expect(
      const AgentProviderNotice(
        type: AgentProviderNoticeType.warning,
        message: 'restart required',
      ).toJson(),
      {'type': 'warning', 'message': 'restart required'},
    );
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
  });
}
