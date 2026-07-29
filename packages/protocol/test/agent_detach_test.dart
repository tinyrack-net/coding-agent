import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('detach request preserves the frozen namespaced wire shape', () {
    const request = AgentDetachRequest(
      requestId: 'request-1',
      agentId: 'child-agent',
    );
    expect(request.toJson(), {
      'type': 'agent.detach.request',
      'agentId': 'child-agent',
      'requestId': 'request-1',
    });
    expect(
      AgentDetachRequest.fromJson(request.toJson()).agentId,
      'child-agent',
    );
  });

  test('detach response preserves accepted, error, and optional notice', () {
    const response = AgentDetachResponse(
      requestId: 'request-1',
      agentId: 'child-agent',
      accepted: false,
      error: 'Agent not found',
      notice: AgentProviderNotice(
        type: AgentProviderNoticeType.warning,
        message: 'notice',
      ),
    );
    final decoded = AgentDetachResponse.fromJson(response.toJson());
    expect(decoded.requestId, 'request-1');
    expect(decoded.agentId, 'child-agent');
    expect(decoded.accepted, isFalse);
    expect(decoded.error, 'Agent not found');
    expect(decoded.notice?.type, AgentProviderNoticeType.warning);
  });

  test('detach boundaries reject malformed fields', () {
    expect(
      () => AgentDetachRequest.fromJson({
        'type': 'agent.detach.request',
        'agentId': 1,
        'requestId': 'request',
      }),
      throwsFormatException,
    );
    expect(
      () => AgentDetachResponse.fromJson({
        'type': 'agent.detach.response',
        'payload': {
          'requestId': 'request',
          'agentId': 'agent',
          'accepted': 'yes',
          'error': null,
        },
      }),
      throwsFormatException,
    );
  });
}
