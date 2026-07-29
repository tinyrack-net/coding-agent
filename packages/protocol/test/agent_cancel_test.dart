import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('cancel request preserves optional request correlation', () {
    for (final request in const [
      CancelAgentRequest(agentId: 'agent'),
      CancelAgentRequest(agentId: 'agent', requestId: 'request'),
    ]) {
      expect(
        CancelAgentRequest.fromJson(request.toJson()).toJson(),
        request.toJson(),
      );
    }
  });

  test('cancel response round trips snapshot and structured error', () {
    final response = CancelAgentResponse(
      requestId: 'request',
      agentId: 'agent',
      agent: PaseoAgentSnapshotCodec.encode(
        const AgentSummary(
          agentId: 'agent',
          title: 'Agent',
          cwd: '/repo',
          provider: 'codex',
          model: 'gpt-5.4',
          mode: AgentMode.normal,
          runState: AgentRunState.idle,
          createdAtMs: 1,
        ),
      ),
      error: null,
    );
    expect(
      CancelAgentResponse.fromJson(response.toJson()).toJson(),
      response.toJson(),
    );
    expect(
      CancelAgentResponse.fromJson(
        const CancelAgentResponse(
          requestId: 'request',
          agentId: 'missing',
          agent: null,
          error: 'Agent missing not found',
        ).toJson(),
      ).error,
      'Agent missing not found',
    );
  });

  test('cancel boundaries reject malformed payloads', () {
    for (final json in <Map<String, Object?>>[
      {'type': 'cancel_agent_request', 'agentId': 1},
      {'type': 'cancel_agent_request', 'agentId': '', 'requestId': 'r'},
      {'type': 'cancel_agent_request', 'agentId': 'a', 'requestId': 1},
      {
        'type': 'cancel_agent_response',
        'payload': {'requestId': 1},
      },
      {
        'type': 'cancel_agent_response',
        'payload': {
          'requestId': 'r',
          'agentId': 'a',
          'agent': [],
          'error': null,
        },
      },
      {
        'type': 'cancel_agent_response',
        'payload': {
          'requestId': 'r',
          'agentId': 'a',
          'agent': {'id': 'a'},
          'error': null,
        },
      },
    ]) {
      expect(
        () => json['type'] == CancelAgentRequest.type
            ? CancelAgentRequest.fromJson(json)
            : CancelAgentResponse.fromJson(json),
        throwsFormatException,
      );
    }
  });
}
