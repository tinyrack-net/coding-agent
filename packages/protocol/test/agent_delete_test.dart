import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('delete request preserves the frozen root wire shape', () {
    const request = DeleteAgentRequest(
      requestId: 'delete-1',
      agentId: 'agent-1',
    );
    expect(request.toJson(), {
      'type': 'delete_agent_request',
      'agentId': 'agent-1',
      'requestId': 'delete-1',
    });
    expect(DeleteAgentRequest.fromJson(request.toJson()).agentId, 'agent-1');
  });

  test('deleted acknowledgement preserves request correlation', () {
    const response = AgentDeletedResponse(
      requestId: 'delete-1',
      agentId: 'agent-1',
    );
    expect(response.toJson(), {
      'type': 'agent_deleted',
      'payload': {'agentId': 'agent-1', 'requestId': 'delete-1'},
    });
    final decoded = AgentDeletedResponse.fromJson(response.toJson());
    expect(decoded.requestId, 'delete-1');
    expect(decoded.agentId, 'agent-1');
  });

  test('delete boundaries reject malformed values', () {
    expect(
      () => DeleteAgentRequest.fromJson({
        'type': 'delete_agent_request',
        'requestId': 'request',
        'agentId': '',
      }),
      throwsFormatException,
    );
    expect(
      () => AgentDeletedResponse.fromJson({
        'type': 'agent_deleted',
        'payload': {'requestId': 'request'},
      }),
      throwsFormatException,
    );
  });
}
