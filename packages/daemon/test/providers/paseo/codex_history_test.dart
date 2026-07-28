import 'package:agent_daemon/src/providers/paseo/codex_history.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('projects ordered Codex turns and PascalCase compatibility items', () {
    final history = projectCodexThreadHistory({
      'thread': {
        'turns': [
          {
            'items': [
              {
                'id': 'user',
                'type': 'UserMessage',
                'content': [
                  {'type': 'text', 'text': 'first'},
                  {'type': 'image', 'url': 'ignored'},
                  {'type': 'text', 'text': 'second'},
                ],
              },
              {'id': 'assistant', 'type': 'AgentMessage', 'text': 'answer'},
              {
                'id': 'reason',
                'type': 'Reasoning',
                'summary': ['summary one', 'summary two'],
                'content': ['not preferred'],
              },
              {
                'id': 'command',
                'type': 'CommandExecution',
                'command': ['git', 'status'],
                'cwd': '/other',
                'aggregatedOutput': 'clean',
                'exitCode': 0,
                'status': 'completed',
              },
              {
                'id': 'file',
                'type': 'FileChange',
                'file_path': 'lib/main.dart',
                'unifiedDiff': '+line',
                'status': 'failed',
              },
            ],
          },
          {
            'items': [
              {'id': 'compact', 'type': 'context_compaction'},
              {'id': 'plan', 'type': 'Plan', 'text': '# Plan'},
              {
                'id': 'mcp',
                'type': 'McpToolCall',
                'server': 'docs',
                'tool': 'search',
              },
              {
                'id': 'web',
                'type': 'WebSearch',
                'query': 'Paseo',
                'status': 'running',
              },
              {
                'id': 'sub',
                'type': 'CollabAgentToolCall',
                'receiverThreadIds': ['child'],
              },
              {
                'id': 'activity',
                'type': 'SubAgentActivity',
                'agentThreadId': 'child',
                'kind': 'interrupted',
                'status': 'error',
              },
              {'id': 'image', 'type': 'ImageView', 'path': 'C:/tmp/image.png'},
              {'id': 'unknown', 'type': 'FutureItem'},
            ],
          },
        ],
      },
    }, cwd: '/workspace');

    expect(history.map((item) => item.id), [
      'user',
      'assistant',
      'reason',
      'command',
      'file',
      'compact',
      'plan',
      'mcp',
      'web',
      'sub',
      'image',
    ]);
    expect((history[0] as UserMessageItem).text, 'first\nsecond');
    expect((history[1] as AssistantMessageItem).complete, isTrue);
    expect((history[2] as ReasoningItem).text, 'summary one\nsummary two');
    final command = history[3] as ToolCallItem;
    expect((command.detail as ShellDetail).command, 'cd /other && git status');
    expect((command.detail as ShellDetail).output, 'clean');
    expect(command.status, ToolCallStatus.success);
    final file = history[4] as ToolCallItem;
    expect(file.status, ToolCallStatus.error);
    expect((file.detail as EditDetail).path, 'lib/main.dart');
    expect((file.detail as EditDetail).diff, '+line');
    expect(history[5], isA<CompactionItem>());
    expect((history[6] as ToolCallItem).toolName, 'plan');
    expect((history[7] as ToolCallItem).toolName, 'mcp');
    expect((history[8] as ToolCallItem).status, ToolCallStatus.running);
    final subagent = history[9] as ToolCallItem;
    expect(subagent.toolName, 'Sub-agent');
    expect(subagent.status, ToolCallStatus.canceled);
    expect(subagent.detail, isA<SubAgentDetail>());
    expect((history[10] as AssistantMessageItem).text, '![](C:/tmp/image.png)');

    final projection = projectCodexThreadHistoryWithSubagents({
      'thread': {
        'turns': [
          {
            'items': [
              {
                'id': 'sub',
                'type': 'CollabAgentToolCall',
                'receiverThreadIds': ['child'],
              },
            ],
          },
        ],
      },
    }, cwd: '/workspace');
    expect(projection.subagentRoutes, hasLength(1));
    expect(projection.subagentRoutes.single.childThreadId, 'child');
    expect(
      (projection.subagentRoutes.single.toolCall.detail as SubAgentDetail)
          .childSessionId,
      'child',
    );
  });

  test('applies defaults, fallbacks, and skips empty projections', () {
    final history = projectCodexThreadHistory({
      'thread': {
        'turns': [
          {
            'items': [
              {'type': 'userMessage'},
              {'type': 'agentMessage'},
              {
                'type': 'reasoning',
                'content': ['detail'],
              },
              {'type': 'reasoning', 'summary': <Object?>[]},
              {'type': 'commandExecution', 'command': 7},
              {'type': 'imageGeneration'},
              7,
            ],
          },
        ],
      },
    }, cwd: '/workspace');

    expect(history, hasLength(4));
    expect(history.map((item) => item.id), [
      'codex-history-1',
      'codex-history-2',
      'codex-history-3',
      'codex-history-5',
    ]);
    expect((history[0] as UserMessageItem).text, '');
    expect((history[2] as ReasoningItem).text, 'detail');
    expect(((history[3] as ToolCallItem).detail as ShellDetail).command, '');
    expect(projectCodexThreadHistory({'thread': {}}, cwd: '/w'), isEmpty);
    expect(projectCodexThreadHistory({}, cwd: '/w'), isEmpty);
  });

  test('rejects malformed thread/read boundaries', () {
    expect(
      () => projectCodexThreadHistory(null, cwd: '/w'),
      throwsFormatException,
    );
    expect(
      () => projectCodexThreadHistory({'thread': 1}, cwd: '/w'),
      throwsFormatException,
    );
    expect(
      () => projectCodexThreadHistory({
        'thread': {'turns': 1},
      }, cwd: '/w'),
      throwsFormatException,
    );
    expect(
      () => projectCodexThreadHistory({
        'thread': {
          'turns': [1],
        },
      }, cwd: '/w'),
      throwsFormatException,
    );
    expect(
      () => projectCodexThreadHistory({
        'thread': {
          'turns': [
            {'items': 1},
          ],
        },
      }, cwd: '/w'),
      throwsFormatException,
    );
  });
}
