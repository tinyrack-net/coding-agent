import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('send message request round trips prompt content', () {
    const request = SendAgentMessageRequest(
      requestId: 'request',
      agentId: 'agent',
      text: 'Fix it',
      messageId: 'message',
      images: [AgentPromptImage(data: 'aGVsbG8=', mimeType: 'image/png')],
      attachments: [
        TextAgentAttachment(
          text: 'Context',
          title: 'notes.txt',
          contextKind: 'chat_history',
        ),
      ],
    );

    expect(
      SendAgentMessageRequest.fromJson(request.toJson()).toJson(),
      request.toJson(),
    );
  });

  test('send response and wait request preserve correlation', () {
    const send = SendAgentMessageResponse(
      requestId: 'send',
      agentId: 'agent',
      accepted: false,
      error: 'busy',
    );
    expect(
      SendAgentMessageResponse.fromJson(send.toJson()).toJson(),
      send.toJson(),
    );
    for (final request in const [
      WaitForFinishRequest(requestId: 'wait', agentId: 'agent'),
      WaitForFinishRequest(
        requestId: 'wait',
        agentId: 'agent',
        timeoutMs: 600000,
      ),
    ]) {
      expect(
        WaitForFinishRequest.fromJson(request.toJson()).toJson(),
        request.toJson(),
      );
    }
  });

  test('wait response validates and round trips the final snapshot', () {
    final response = WaitForFinishResponse(
      requestId: 'wait',
      status: WaitForFinishStatus.permission,
      finalAgent: PaseoAgentSnapshotCodec.encode(
        const AgentSummary(
          agentId: 'agent',
          title: 'Agent',
          cwd: '/repo',
          provider: 'codex',
          model: 'gpt-5.4',
          mode: AgentMode.normal,
          runState: AgentRunState.awaitingPermission,
          createdAtMs: 1,
        ),
        pendingPermissions: const [
          PermissionItem(
            id: 'permission',
            permissionId: 'permission',
            toolName: 'Bash',
            status: PermissionStatus.pending,
            detail: PlainTextDetail(label: 'Command', text: 'git status'),
          ),
        ],
      ),
      error: null,
      lastMessage: 'Working',
    );

    expect(
      WaitForFinishResponse.fromJson(response.toJson()).toJson(),
      response.toJson(),
    );
  });

  test('interaction boundaries reject malformed payloads', () {
    for (final json in <Map<String, Object?>>[
      {
        'type': SendAgentMessageRequest.type,
        'requestId': 'r',
        'agentId': 'a',
        'text': 1,
      },
      {
        'type': SendAgentMessageRequest.type,
        'requestId': 'r',
        'agentId': 'a',
        'text': 'x',
        'images': [
          {'data': 1, 'mimeType': 'image/png'},
        ],
      },
      {
        'type': WaitForFinishRequest.type,
        'requestId': 'r',
        'agentId': 'a',
        'timeoutMs': 0,
      },
      {
        'type': WaitForFinishResponse.type,
        'payload': {
          'requestId': 'r',
          'status': 'done',
          'final': null,
          'error': null,
          'lastMessage': null,
        },
      },
      {
        'type': WaitForFinishResponse.type,
        'payload': {
          'requestId': 'r',
          'status': 'idle',
          'final': {'id': 'a'},
          'error': null,
          'lastMessage': null,
        },
      },
    ]) {
      expect(
        () => switch (json['type']) {
          SendAgentMessageRequest.type => SendAgentMessageRequest.fromJson(
            json,
          ),
          WaitForFinishRequest.type => WaitForFinishRequest.fromJson(json),
          _ => WaitForFinishResponse.fromJson(json),
        },
        throwsFormatException,
      );
    }
  });
}
