import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('archive request preserves the frozen root wire shape', () {
    const request = ArchiveAgentRequest(
      requestId: 'archive-1',
      agentId: 'agent-1',
    );
    expect(request.toJson(), {
      'type': 'archive_agent_request',
      'requestId': 'archive-1',
      'agentId': 'agent-1',
    });
    expect(ArchiveAgentRequest.fromJson(request.toJson()).agentId, 'agent-1');
  });

  test('archived acknowledgement preserves correlation and timestamp', () {
    const response = AgentArchivedResponse(
      requestId: 'archive-1',
      agentId: 'agent-1',
      archivedAt: '2026-07-29T12:34:56.000Z',
    );
    expect(response.toJson(), {
      'type': 'agent_archived',
      'payload': {
        'agentId': 'agent-1',
        'archivedAt': '2026-07-29T12:34:56.000Z',
        'requestId': 'archive-1',
      },
    });
    final decoded = AgentArchivedResponse.fromJson(response.toJson());
    expect(decoded.requestId, 'archive-1');
    expect(decoded.agentId, 'agent-1');
  });

  test('archive boundaries reject malformed values', () {
    expect(
      () => ArchiveAgentRequest.fromJson({
        'type': 'archive_agent_request',
        'requestId': '',
        'agentId': 'agent',
      }),
      throwsFormatException,
    );
    expect(
      () => AgentArchivedResponse.fromJson({
        'type': 'agent_archived',
        'payload': {
          'requestId': 'request',
          'agentId': 'agent',
          'archivedAt': '',
        },
      }),
      throwsFormatException,
    );
  });
}
