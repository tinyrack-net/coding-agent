import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('refresh request preserves the frozen root wire shape', () {
    const request = RefreshAgentRequest(
      requestId: 'request-1',
      agentId: 'agent-1',
    );
    expect(request.toJson(), {
      'type': 'refresh_agent_request',
      'agentId': 'agent-1',
      'requestId': 'request-1',
    });
    expect(RefreshAgentRequest.fromJson(request.toJson()).agentId, 'agent-1');
  });

  test('refreshed status preserves correlation and optional timeline size', () {
    const response = AgentRefreshedStatus(
      requestId: 'request-1',
      agentId: 'agent-1',
      timelineSize: 2.5,
    );
    expect(response.toJson(), {
      'type': 'status',
      'payload': {
        'status': 'agent_refreshed',
        'agentId': 'agent-1',
        'requestId': 'request-1',
        'timelineSize': 2.5,
      },
    });
    expect(AgentRefreshedStatus.fromJson(response.toJson()).timelineSize, 2.5);
  });

  test('reload boundaries reject malformed values', () {
    expect(
      () => RefreshAgentRequest.fromJson({
        'type': 'refresh_agent_request',
        'agentId': 1,
        'requestId': 'request',
      }),
      throwsFormatException,
    );
    expect(
      () => AgentRefreshedStatus.fromJson({
        'type': 'status',
        'payload': {
          'status': 'agent_resumed',
          'agentId': 'agent',
          'requestId': 'request',
        },
      }),
      throwsFormatException,
    );
  });
}
