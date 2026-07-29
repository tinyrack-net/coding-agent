import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_daemon/src/cli/agent_attach_command.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test(
    'top-level and nested binary attach aliases are exposed',
    () async {
      final library = await Isolate.resolvePackageUri(
        Uri.parse('package:agent_daemon/agent_daemon.dart'),
      );
      final packageRoot = File.fromUri(library!).parent.parent.path;
      final results = await Future.wait([
        for (final arguments in const [
          ['attach', '--help'],
          ['agent', 'attach', '--help'],
        ])
          Process.run(Platform.resolvedExecutable, [
            'run',
            'agent_daemon:coding_agent',
            ...arguments,
          ], workingDirectory: packageRoot),
      ]);
      for (final result in results) {
        expect(result.exitCode, 0);
        expect(result.stdout, contains('Usage: coding-agent agent attach'));
        expect(result.stderr, isEmpty);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('help and parser failures preserve the frozen direct output', () async {
    final help = StringBuffer();
    expect(
      await runAgentAttachCommand(
        arguments: const ['--help'],
        writeOutput: help.write,
      ),
      0,
    );
    expect(help.toString(), contains("Attach to a running agent's"));

    final missing = StringBuffer();
    expect(
      await runAgentAttachCommand(
        arguments: const [],
        writeError: missing.write,
      ),
      1,
    );
    expect(
      missing.toString(),
      'Error: Agent ID required\nUsage: coding-agent attach <id>\n',
    );

    for (final arguments in const [
      ['one', 'two'],
      ['one', '--unknown'],
      ['one', '--host'],
    ]) {
      final error = StringBuffer();
      expect(
        await runAgentAttachCommand(
          arguments: arguments,
          writeError: error.write,
        ),
        64,
      );
      expect(error.toString(), contains('Usage: coding-agent agent attach'));
    }
  });

  test('prints frozen projected history item shapes', () async {
    final stops = StreamController<void>();
    addTearDown(stops.close);
    final output = StringBuffer();
    final error = StringBuffer();
    final attached = runAgentAttachCommand(
      arguments: const ['agent-prefix'],
      request: (message) async => message['type'] == 'fetch_agent_request'
          ? _agentPayload(message, 'agent-full-id')
          : _timelinePayload(message, [
              const UserMessageItem(id: 'user', text: 'hello'),
              const AssistantMessageItem(
                id: 'assistant',
                text: 'world',
                complete: true,
              ),
              const ReasoningItem(
                id: 'reasoning',
                text: 'think',
                complete: true,
              ),
              const ToolCallItem(
                id: 'tool',
                toolName: 'Bash',
                status: ToolCallStatus.success,
                detail: GenericDetail(input: {}),
              ),
              const TodoItem(
                id: 'todo',
                items: [
                  TodoEntry(text: 'done', completed: true),
                  TodoEntry(text: 'open', completed: false),
                ],
              ),
              const ErrorItem(id: 'error', message: 'boom'),
            ]),
      receiveMessage: () => Completer<Map<String, Object?>>().future,
      stopSignals: stops.stream,
      writeOutput: output.write,
      writeError: error.write,
    );
    await _waitFor(() => output.toString().contains('[Todo]'));
    stops.add(null);
    expect(await attached, 0);
    expect(
      output.toString(),
      'Attaching to agent agent-f...\n'
      '(Press Ctrl+C to detach)\n\n'
      '\n[User] hello\n'
      'world'
      '\n[Reasoning] think\n'
      '\n[Tool: Bash] completed\n'
      '\n[Todo] 1/2 completed\n'
      '\n\nDetaching from agent...\n',
    );
    expect(error.toString(), '\n[Error] boom\n');
  });

  test(
    'streams only the resolved agent and formats lifecycle events',
    () async {
      final messages = StreamController<Map<String, Object?>>();
      final iterator = StreamIterator(messages.stream);
      final stops = StreamController<void>();
      addTearDown(() async {
        await iterator.cancel();
        await messages.close();
        await stops.close();
      });
      final output = StringBuffer();
      final error = StringBuffer();
      final attached = runAgentAttachCommand(
        arguments: const ['agent'],
        request: (message) async => message['type'] == 'fetch_agent_request'
            ? _agentPayload(message, 'agent-full')
            : _timelinePayload(message, const []),
        receiveMessage: () async {
          if (!await iterator.moveNext()) throw StateError('closed');
          return iterator.current;
        },
        stopSignals: stops.stream,
        writeOutput: output.write,
        writeError: error.write,
      );
      await _waitFor(() => output.toString().contains('Press Ctrl+C'));
      messages.add(
        _timelineStream(
          'other',
          const AssistantMessageItem(
            id: 'ignored',
            text: 'ignored',
            complete: true,
          ),
        ),
      );
      messages.add(
        _timelineStream(
          'agent-full',
          const AssistantMessageItem(id: 'live', text: 'live', complete: false),
        ),
      );
      messages.add(
        _eventStream('agent-full', {
          'type': 'permission_requested',
          'provider': 'codex',
          'request': {
            'id': 'permission-1',
            'name': 'Bash',
            'description': 'Run tests',
          },
        }),
      );
      messages.add(
        _eventStream('agent-full', {
          'type': 'permission_resolved',
          'provider': 'codex',
          'requestId': 'permission-1',
          'resolution': {'behavior': 'allow'},
        }),
      );
      messages.add(
        _eventStream('agent-full', {
          'type': 'turn_failed',
          'provider': 'codex',
          'error': 'provider failed',
        }),
      );
      messages.add(
        _eventStream('agent-full', {
          'type': 'attention_required',
          'provider': 'codex',
          'reason': 'permission',
        }),
      );
      await _waitFor(
        () => output.toString().contains('[Attention Required: permission]'),
      );
      stops.add(null);
      expect(await attached, 0);
      expect(output.toString(), isNot(contains('ignored')));
      expect(output.toString(), contains('live'));
      expect(
        output.toString(),
        contains('[Permission Required] Bash\n  Run tests\n'),
      );
      expect(output.toString(), contains('[Permission allow]'));
      expect(output.toString(), contains('[Attention Required: permission]'));
      expect(error.toString(), contains('[Turn Failed] provider failed'));
    },
  );

  test(
    'missing agent and history failure remain non-fatal where frozen',
    () async {
      final missing = StringBuffer();
      expect(
        await runAgentAttachCommand(
          arguments: const ['missing'],
          request: (message) async => {
            'requestId': message['requestId'],
            'agent': null,
            'project': null,
            'error': 'not found',
          },
          writeError: missing.write,
        ),
        1,
      );
      expect(missing.toString(), contains('No agent found matching: missing'));
      expect(missing.toString(), contains('coding-agent ls'));

      final stops = StreamController<void>();
      addTearDown(stops.close);
      final warning = StringBuffer();
      final output = StringBuffer();
      final attached = runAgentAttachCommand(
        arguments: const ['agent'],
        request: (message) async {
          if (message['type'] == 'fetch_agent_request') {
            return _agentPayload(message, 'agent-full');
          }
          throw StateError('history unavailable');
        },
        receiveMessage: () => Completer<Map<String, Object?>>().future,
        stopSignals: stops.stream,
        writeOutput: output.write,
        writeError: warning.write,
      );
      await _waitFor(() => warning.toString().contains('Warning:'));
      stops.add(null);
      expect(await attached, 0);
      expect(warning.toString(), contains('history unavailable'));
    },
  );
}

Map<String, Object?> _agentPayload(
  Map<String, Object?> request,
  String agentId,
) => {
  'requestId': request['requestId'],
  'agent': _snapshot(agentId),
  'project': null,
  'error': null,
};

Map<String, Object?> _timelinePayload(
  Map<String, Object?> request,
  List<TimelineItem> items,
) => {
  'requestId': request['requestId'],
  'agentId': request['agentId'],
  'agent': _snapshot('${request['agentId']}'),
  'direction': 'tail',
  'projection': 'projected',
  'epoch': '1',
  'reset': false,
  'staleCursor': false,
  'gap': false,
  'window': {'minSeq': 1, 'maxSeq': items.length, 'nextSeq': items.length + 1},
  'startCursor': items.isEmpty ? null : {'epoch': '1', 'seq': 1},
  'endCursor': items.isEmpty ? null : {'epoch': '1', 'seq': items.length},
  'hasOlder': false,
  'hasNewer': false,
  'entries': [
    for (var index = 0; index < items.length; index++)
      {
        'provider': 'codex',
        'item': PaseoTimelineCodec.encode(items[index]),
        'timestamp': '2026-07-29T00:00:0${index}Z',
        'seqStart': index + 1,
        'seqEnd': index + 1,
        'sourceSeqRanges': [
          {'startSeq': index + 1, 'endSeq': index + 1},
        ],
        'collapsed': <Object?>[],
      },
  ],
  'error': null,
};

Map<String, Object?> _timelineStream(String agentId, TimelineItem item) =>
    _eventStream(agentId, {
      'type': 'timeline',
      'provider': 'codex',
      'item': PaseoTimelineCodec.encode(item),
    });

Map<String, Object?> _eventStream(String agentId, Map<String, Object?> event) =>
    {
      'type': 'agent_stream',
      'payload': {
        'agentId': agentId,
        'event': event,
        'timestamp': '2026-07-29T00:00:00Z',
        'seq': 1,
        'epoch': '1',
      },
    };

Map<String, Object?> _snapshot(String agentId) => {
  'id': agentId,
  'provider': 'codex',
  'cwd': '/repo',
  'model': 'gpt-5.4',
  'thinkingOptionId': null,
  'effectiveThinkingOptionId': null,
  'createdAt': '2026-07-29T00:00:00Z',
  'updatedAt': '2026-07-29T00:00:00Z',
  'lastUserMessageAt': null,
  'status': 'running',
  'capabilities': const <String, bool>{},
  'currentModeId': 'normal',
  'availableModes': const <Object?>[],
  'pendingPermissions': const <Object?>[],
  'persistence': null,
  'runtimeInfo': const <String, Object?>{},
  'title': 'Agent',
  'labels': const <String, String>{},
  'requiresAttention': false,
  'attentionReason': null,
  'attentionTimestamp': null,
  'archivedAt': null,
  'providerUnavailable': false,
};

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not reached');
}
