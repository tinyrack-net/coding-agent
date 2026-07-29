import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('create_agent_request preserves frozen Paseo wire shape', () {
    final request = CreateAgentRequest(
      requestId: 'request-1',
      config: const CreateAgentSessionConfig(
        provider: 'codex',
        cwd: '/repo',
        modeId: 'full-access',
        model: 'gpt-5.4',
        thinkingOptionId: 'high',
        title: 'Task',
        hasTitle: true,
      ),
      env: const {'CI': '1'},
      workspaceId: 'workspace-1',
      callerAgentId: 'parent-1',
      initialPrompt: 'Implement it',
      clientMessageId: 'message-1',
      outputSchema: const {'type': 'object'},
      images: const [AgentPromptImage(data: 'aGVsbG8=', mimeType: 'image/png')],
      labels: const {'team': 'core'},
    );

    expect(CreateAgentRequest.fromJson(request.toJson()).toJson(), {
      'type': 'create_agent_request',
      'config': {
        'provider': 'codex',
        'cwd': '/repo',
        'modeId': 'full-access',
        'model': 'gpt-5.4',
        'thinkingOptionId': 'high',
        'title': 'Task',
      },
      'env': {'CI': '1'},
      'workspaceId': 'workspace-1',
      'callerAgentId': 'parent-1',
      'initialPrompt': 'Implement it',
      'clientMessageId': 'message-1',
      'outputSchema': {'type': 'object'},
      'images': [
        {'data': 'aGVsbG8=', 'mimeType': 'image/png'},
      ],
      'attachments': const [],
      'labels': {'team': 'core'},
      'requestId': 'request-1',
    });
  });

  test('create statuses validate the frozen agent snapshot', () {
    final created = CreateAgentStatus.fromJson({
      'type': 'status',
      'payload': {
        'status': 'agent_created',
        'requestId': 'request-1',
        'agentId': 'agent-1',
        'agent': {
          'id': 'agent-1',
          'provider': 'codex',
          'cwd': '/repo',
          'createdAt': '2026-07-29T00:00:00.000Z',
          'status': 'idle',
          'pendingPermissions': const [],
          'labels': const <String, String>{},
        },
      },
    });
    expect(created, isA<AgentCreatedStatus>());

    final failed =
        CreateAgentStatus.fromJson({
              'type': 'status',
              'payload': {
                'status': 'agent_create_failed',
                'requestId': 'request-2',
                'error': 'provider missing',
                'errorCode': 'provider_unavailable',
              },
            })
            as AgentCreateFailedStatus;
    expect(failed.error, 'provider missing');
    expect(failed.errorCode, 'provider_unavailable');
  });

  test('create request rejects non-string env and labels', () {
    final base = {
      'type': 'create_agent_request',
      'requestId': 'request-1',
      'config': {'provider': 'codex', 'cwd': '/repo'},
      'attachments': const [],
      'labels': const <String, String>{},
    };
    expect(
      () => CreateAgentRequest.fromJson({
        ...base,
        'env': {'PORT': 6868},
      }),
      throwsFormatException,
    );
    expect(
      () => CreateAgentRequest.fromJson({
        ...base,
        'labels': {'priority': 1},
      }),
      throwsFormatException,
    );
  });
}
