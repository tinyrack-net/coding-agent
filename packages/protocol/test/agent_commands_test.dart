import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('list commands request preserves the frozen draft config shape', () {
    const request = ListCommandsRequest(
      agentId: '__new_agent__',
      requestId: 'request-1',
      draftConfig: ListCommandsDraftConfig(
        provider: 'codex',
        cwd: 'C:/repo',
        modeId: 'auto-review',
        model: 'gpt-5.4',
        thinkingOptionId: 'high',
        featureValues: {'fast_mode': true},
      ),
    );

    expect(ListCommandsRequest.fromJson(request.toJson()).toJson(), {
      'type': 'list_commands_request',
      'agentId': '__new_agent__',
      'draftConfig': {
        'provider': 'codex',
        'cwd': 'C:/repo',
        'modeId': 'auto-review',
        'model': 'gpt-5.4',
        'thinkingOptionId': 'high',
        'featureValues': {'fast_mode': true},
      },
      'requestId': 'request-1',
    });
  });

  test('list commands response defaults missing kind and preserves skill', () {
    final response = ListCommandsResponse.fromJson({
      'type': 'list_commands_response',
      'payload': {
        'agentId': 'agent-1',
        'commands': [
          {
            'name': 'compact',
            'description': 'Compact context',
            'argumentHint': '',
          },
          {
            'name': 'review',
            'description': 'Review changes',
            'argumentHint': '<path>',
            'kind': 'skill',
          },
        ],
        'error': null,
        'requestId': 'request-2',
      },
    });

    expect(response.commands.first.kind, AgentSlashCommandKind.command);
    expect(response.commands.last.kind, AgentSlashCommandKind.skill);
    expect(
      ListCommandsResponse.fromJson(response.toJson()).commands,
      hasLength(2),
    );
  });

  test('list commands schemas reject malformed boundaries', () {
    expect(
      () => ListCommandsRequest.fromJson({
        'type': 'other',
        'agentId': 'a',
        'requestId': 'r',
      }),
      throwsFormatException,
    );
    expect(
      () => ListCommandsRequest.fromJson({
        'type': 'list_commands_request',
        'agentId': 'a',
        'draftConfig': [],
        'requestId': 'r',
      }),
      throwsFormatException,
    );
    expect(
      () => ListCommandsDraftConfig.fromJson({
        'provider': 'codex',
        'cwd': 'C:/repo',
        'featureValues': [],
      }),
      throwsFormatException,
    );
    expect(
      () => ListCommandsResponse.fromJson({
        'type': 'list_commands_response',
        'payload': {
          'agentId': 'a',
          'commands': [false],
          'error': null,
          'requestId': 'r',
        },
      }),
      throwsFormatException,
    );
    expect(
      AgentSlashCommand.fromJson({
        'name': 'x',
        'description': 'x',
        'argumentHint': '',
        'kind': 'future-kind',
      }).kind,
      AgentSlashCommandKind.command,
    );
  });
}
