import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('update request preserves optional name and label patch', () {
    const request = UpdateAgentRequest(
      requestId: 'request-1',
      agentId: 'agent-1',
      name: 'Renamed',
      labels: {'team': 'infra', 'empty': ''},
    );
    expect(request.toJson(), {
      'type': 'update_agent_request',
      'agentId': 'agent-1',
      'name': 'Renamed',
      'labels': {'team': 'infra', 'empty': ''},
      'requestId': 'request-1',
    });
    final decoded = UpdateAgentRequest.fromJson(request.toJson());
    expect(decoded.name, 'Renamed');
    expect(decoded.labels, {'team': 'infra', 'empty': ''});
  });

  test('update response preserves action acceptance and optional notice', () {
    const response = UpdateAgentResponse(
      requestId: 'request-1',
      agentId: 'agent-1',
      accepted: false,
      error: 'Nothing to update',
      notice: AgentProviderNotice(
        type: AgentProviderNoticeType.info,
        message: 'notice',
      ),
    );
    final decoded = UpdateAgentResponse.fromJson(response.toJson());
    expect(decoded.accepted, isFalse);
    expect(decoded.error, 'Nothing to update');
    expect(decoded.notice?.message, 'notice');
  });

  test('update boundaries reject non-string fields', () {
    expect(
      () => UpdateAgentRequest.fromJson({
        'type': 'update_agent_request',
        'agentId': 'agent',
        'requestId': 'request',
        'labels': {'team': 1},
      }),
      throwsFormatException,
    );
    expect(
      () => UpdateAgentResponse.fromJson({
        'type': 'update_agent_response',
        'payload': {
          'requestId': 'request',
          'agentId': 'agent',
          'accepted': true,
          'error': 1,
        },
      }),
      throwsFormatException,
    );
  });
}
