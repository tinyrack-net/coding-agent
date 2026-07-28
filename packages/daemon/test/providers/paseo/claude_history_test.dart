import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/providers/paseo/claude_history.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X1r0AAAAASUVORK5CYII=';

void main() {
  test('extracts strings, text blocks, and Claude slash commands', () {
    expect(extractClaudeUserMessageText('  Hello  '), 'Hello');
    expect(
      extractClaudeUserMessageText([
        {'type': 'text', 'text': ' First '},
        {'type': 'image', 'source': 'ignored'},
        {'type': 'text', 'text': 'Second'},
      ]),
      'First\n\nSecond',
    );
    expect(
      extractClaudeUserMessageText(
        '<command-message>diagnose</command-message>\n'
        '<command-name>/diagnose</command-name>\n'
        '<command-args>recent PR</command-args>',
      ),
      '/diagnose recent PR',
    );
    expect(extractClaudeUserMessageText(const []), isNull);
    expect(extractClaudeUserMessageText({'type': 'image'}), isNull);
  });

  test('projects conversation, tool results, reasoning, and compaction', () {
    final lines = [
      jsonEncode({
        'type': 'user',
        'uuid': 'user-1',
        'message': {'role': 'user', 'content': 'hello'},
      }),
      '{malformed',
      jsonEncode({
        'type': 'assistant',
        'uuid': 'assistant-1',
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'thinking', 'thinking': 'reason'},
            {'type': 'text', 'text': 'reply'},
            {
              'type': 'tool_use',
              'id': 'tool-1',
              'name': 'Read',
              'input': {'file_path': 'README.md'},
            },
          ],
        },
      }),
      jsonEncode({
        'type': 'user',
        'uuid': 'tool-result-user',
        'message': {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'tool-1',
              'content': 'contents',
            },
          ],
        },
      }),
      jsonEncode({
        'type': 'system',
        'subtype': 'compact_boundary',
        'uuid': 'compact-1',
        'compactMetadata': {'trigger': 'manual', 'preTokens': 1200},
      }),
      jsonEncode({
        'type': 'assistant',
        'isSidechain': true,
        'message': {'content': 'hidden child'},
      }),
    ];

    final timeline = projectClaudeHistory(lines);

    expect(timeline.whereType<UserMessageItem>().single.text, 'hello');
    expect(timeline.whereType<ReasoningItem>().single.text, 'reason');
    expect(timeline.whereType<AssistantMessageItem>().single.text, 'reply');
    final tools = timeline.whereType<ToolCallItem>().toList();
    expect(tools, hasLength(2));
    expect(tools.first.status, ToolCallStatus.running);
    expect(tools.last.status, ToolCallStatus.success);
    expect(tools.last.toolName, 'Read');
    expect((tools.last.detail as GenericDetail).input, {
      'file_path': 'README.md',
    });
    expect((tools.last.detail as GenericDetail).output, 'contents');
    final compaction = timeline.whereType<CompactionItem>().single;
    expect(compaction.trigger, CompactionTrigger.manual);
    expect(compaction.preTokens, 1200);
  });

  test('filters frozen synthetic and transcript-noise history rows', () {
    final lines = [
      jsonEncode({
        'type': 'user',
        'isSynthetic': true,
        'message': {'content': 'synthetic prompt'},
      }),
      jsonEncode({
        'type': 'user',
        'isMeta': true,
        'message': {'content': 'metadata prompt'},
      }),
      jsonEncode({
        'type': 'user',
        'toolUseResult': {'status': 'done'},
        'message': {'content': 'tool metadata'},
      }),
      jsonEncode({
        'type': 'assistant',
        'isCompactSummary': true,
        'message': {'content': 'compact summary'},
      }),
      jsonEncode({
        'type': 'user',
        'message': {'content': '[Request interrupted by user for tool use]'},
      }),
      jsonEncode({
        'type': 'assistant',
        'message': {
          'content': [
            {'type': 'text', 'text': 'No response requested.'},
          ],
        },
      }),
      jsonEncode({
        'type': 'user',
        'message': {
          'content':
              '<local-command-stdout>local output</local-command-stdout>',
        },
      }),
      jsonEncode({
        'type': 'user',
        'isMeta': true,
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'tool-still-visible',
              'content': 'result',
            },
          ],
        },
      }),
    ];

    final timeline = projectClaudeHistory(lines);

    expect(timeline, hasLength(1));
    expect(timeline.single, isA<ToolCallItem>());
    expect((timeline.single as ToolCallItem).id, 'tool-still-visible');
    expect(extractClaudeUserMessageText('No response requested.'), isNull);
  });

  test('materializes restored image results and excludes their base64', () {
    final timeline = projectClaudeHistory([
      jsonEncode({
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'image-result',
              'tool_name': 'Read',
              'content': [
                {
                  'type': 'image',
                  'source': {
                    'type': 'base64',
                    'media_type': 'image/png',
                    'data': _onePixelPng,
                  },
                },
              ],
            },
          ],
        },
      }),
    ]);

    final tool = timeline.whereType<ToolCallItem>().single;
    expect((tool.detail as GenericDetail).output, '[image]');
    final markdown = timeline.whereType<AssistantMessageItem>().single.text;
    expect(
      jsonEncode(timeline.map((item) => item.toJson()).toList()),
      isNot(contains(_onePixelPng)),
    );
    final file = File.fromUri(
      Uri.parse(markdown.substring(4, markdown.length - 1)),
    );
    expect(file.existsSync(), isTrue);
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
  });

  test('loads the exact encoded project session path', () async {
    final root = Directory.systemTemp.createTempSync('claude_history_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    final cwd = Directory(p.join(root.path, 'workspace with spaces'))
      ..createSync(recursive: true);
    final configDir = Directory(p.join(root.path, 'claude'))
      ..createSync(recursive: true);
    final sessionDir = Directory(
      claudeProjectDir(cwd.path, configDir: configDir.path),
    )..createSync(recursive: true);
    final history = File(p.join(sessionDir.path, 'session-1.jsonl'));
    await history.writeAsString(
      [
        jsonEncode({
          'type': 'assistant',
          'uuid': 'reply-1',
          'message': {'content': 'restored'},
        }),
        jsonEncode({
          'type': 'assistant',
          'message': {
            'content': [
              {
                'type': 'tool_use',
                'id': 'task-1',
                'name': 'Task',
                'input': {
                  'name': 'researcher',
                  'description': 'Inspect history',
                },
              },
            ],
          },
        }),
        jsonEncode({
          'type': 'user',
          'message': {
            'content': [
              {
                'type': 'tool_result',
                'tool_use_id': 'task-1',
                'content': 'done\nagentId: child-1',
              },
            ],
          },
        }),
      ].join('\n'),
    );
    final subagentDir = Directory(
      p.join(sessionDir.path, 'session-1', 'subagents', 'nested'),
    )..createSync(recursive: true);
    await File(p.join(subagentDir.path, 'child.jsonl')).writeAsString(
      jsonEncode({
        'type': 'assistant',
        'isSidechain': true,
        'agentId': 'child-1',
        'message': {'content': 'child restored'},
      }),
    );

    final restored = await loadClaudeHistory(
      cwd: cwd.path,
      sessionId: 'session-1',
      environment: {
        'CLAUDE_CONFIG_DIR': configDir.path,
        'USERPROFILE': root.path,
      },
    );

    expect(restored?.whereType<AssistantMessageItem>().single.text, 'restored');
    final snapshot = await loadClaudeHistorySnapshot(
      cwd: cwd.path,
      sessionId: 'session-1',
      environment: {'CLAUDE_CONFIG_DIR': configDir.path},
    );
    final child = snapshot?.providerSubagents.single;
    expect(child, isA<RestoredProviderSubagent>());
    expect(child?.id, 'task-1');
    expect(child?.toolCallId, 'task-1');
    expect(child?.title, 'researcher');
    expect(child?.description, 'Inspect history');
    expect(child?.status, ProviderSubagentStatus.completed);
    expect(
      child?.timeline.whereType<AssistantMessageItem>().single.text,
      'child restored',
    );
    expect(
      await loadClaudeHistory(
        cwd: cwd.path,
        sessionId: 'missing',
        environment: {'CLAUDE_CONFIG_DIR': configDir.path},
      ),
      isNull,
    );
  });

  test('restores embedded failed Claude sidechains by parent tool call', () {
    final parent = [
      jsonEncode({
        'type': 'assistant',
        'message': {
          'content': [
            {
              'type': 'tool_use',
              'id': 'agent-tool',
              'name': 'Agent',
              'input': {
                'subagent_type': 'reviewer',
                'description': 'Review the patch',
              },
            },
          ],
        },
      }),
      jsonEncode({
        'type': 'assistant',
        'isSidechain': true,
        'agentId': 'child-failed',
        'message': {'content': 'found a problem'},
      }),
      jsonEncode({
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'agent-tool',
              'is_error': true,
              'content': 'failed\nagentId: child-failed',
            },
          ],
        },
      }),
    ];

    final child = projectClaudeProviderSubagents(parent, const []).single;

    expect(child.id, 'agent-tool');
    expect(child.title, 'reviewer');
    expect(child.status, ProviderSubagentStatus.failed);
    expect(
      child.timeline.whereType<AssistantMessageItem>().single.text,
      'found a problem',
    );
  });

  test('deep project paths use the frozen 200-character hash cap', () {
    final cwd = 'C:/${List.filled(80, 'segment').join('/')}';
    final encoded = p.basename(claudeProjectDir(cwd, configDir: 'config'));
    expect(encoded.length, greaterThan(200));
    expect(encoded.substring(0, 200), hasLength(200));
    expect(encoded.substring(200), matches(RegExp(r'^-[0-9a-z]+$')));
  });
}
