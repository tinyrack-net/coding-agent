import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_daemon/src/cli/agent_logs_command.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('help and nested/top-level binary aliases are exposed', () async {
    final output = StringBuffer();
    expect(
      await runAgentLogsCommand(
        arguments: const ['--help'],
        writeOutput: output.write,
      ),
      0,
    );
    expect(output.toString(), contains('Usage: coding-agent agent logs'));

    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:agent_daemon/agent_daemon.dart'),
    );
    final packageRoot = File.fromUri(library!).parent.parent.path;
    for (final arguments in const [
      ['agent', 'logs', '--help'],
      ['logs', '--help'],
    ]) {
      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'agent_daemon:coding_agent',
        ...arguments,
      ], workingDirectory: packageRoot);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('View agent activity/timeline'));
      expect(result.stderr, isEmpty);
    }
  });

  test('fetches the frozen projected tail and formats activity', () async {
    final requests = <Map<String, Object?>>[];
    final output = StringBuffer();
    expect(
      await runAgentLogsCommand(
        arguments: const ['agent-prefix', '--since', 'ignored'],
        request: (message) async {
          requests.add(message);
          return switch (message['type']) {
            'fetch_agent_request' => _agentPayload(message, 'agent-full'),
            'fetch_agent_timeline_request' => _timelinePayload(message, [
              const UserMessageItem(id: 'u', text: 'Fix it'),
              const ReasoningItem(id: 'r', text: 'Checking', complete: true),
              const ToolCallItem(
                id: 't',
                toolName: 'read',
                status: ToolCallStatus.success,
                detail: ReadDetail(path: 'lib/main.dart'),
              ),
              const AssistantMessageItem(id: 'a', text: 'Done', complete: true),
              const ErrorItem(id: 'e', message: 'boom'),
            ]),
            _ => throw StateError('unexpected request'),
          };
        },
        writeOutput: output.write,
      ),
      0,
    );
    expect(requests, hasLength(2));
    expect(requests.first['agentId'], 'agent-prefix');
    expect(requests.last, {
      'type': 'fetch_agent_timeline_request',
      'agentId': 'agent-full',
      'requestId': isA<String>(),
      'direction': 'tail',
      'limit': 0,
      'projection': 'projected',
    });
    expect(
      output.toString(),
      '[User] Fix it\n'
      '[Thought] Checking\n'
      '[Read] lib/main.dart\n'
      'Done\n'
      '[Error] boom\n',
    );
  });

  test('filter is applied before tail truncation', () async {
    final output = StringBuffer();
    await runAgentLogsCommand(
      arguments: const ['agent', '--filter', 'text', '--tail', '2'],
      request: (message) async => message['type'] == 'fetch_agent_request'
          ? _agentPayload(message, 'agent')
          : _timelinePayload(message, [
              const UserMessageItem(id: 'u', text: 'first'),
              const ToolCallItem(
                id: 't',
                toolName: 'bash',
                status: ToolCallStatus.success,
                detail: ShellDetail(command: 'dart test'),
              ),
              const AssistantMessageItem(
                id: 'a',
                text: 'second',
                complete: true,
              ),
              const ReasoningItem(id: 'r', text: 'third', complete: true),
            ]),
      writeOutput: output.write,
    );
    expect(output.toString(), 'second\n[Thought] third\n');
  });

  test(
    'tail parsing matches Number.parseInt and zero suppresses output',
    () async {
      final accepted = StringBuffer();
      await runAgentLogsCommand(
        arguments: const ['agent', '--tail', '1trailing'],
        request: (message) async => message['type'] == 'fetch_agent_request'
            ? _agentPayload(message, 'agent')
            : _timelinePayload(message, [
                const UserMessageItem(id: 'u', text: 'first'),
                const AssistantMessageItem(
                  id: 'a',
                  text: 'second',
                  complete: true,
                ),
              ]),
        writeOutput: accepted.write,
      );
      expect(accepted.toString(), 'second\n');

      final zero = StringBuffer();
      var timelineFetched = false;
      await runAgentLogsCommand(
        arguments: const ['agent', '--tail', '0'],
        request: (message) async {
          if (message['type'] == 'fetch_agent_request') {
            return _agentPayload(message, 'agent');
          }
          timelineFetched = true;
          return _timelinePayload(message, const []);
        },
        writeOutput: zero.write,
      );
      expect(timelineFetched, isTrue);
      expect(zero, isEmpty);

      final invalid = StringBuffer();
      expect(
        await runAgentLogsCommand(
          arguments: const ['agent', '--tail', '-1'],
          request: (message) async => _agentPayload(message, 'agent'),
          writeError: invalid.write,
        ),
        1,
      );
      expect(invalid.toString(), contains('Invalid --tail value: -1'));
      expect(invalid.toString(), contains('where n is >= 0'));
    },
  );

  test('not-found and daemon failures use frozen human errors', () async {
    final notFound = StringBuffer();
    expect(
      await runAgentLogsCommand(
        arguments: const ['missing'],
        request: (message) async => {
          'requestId': message['requestId'],
          'agent': null,
          'project': null,
          'error': null,
        },
        writeError: notFound.write,
      ),
      1,
    );
    expect(notFound.toString(), contains('No agent found matching: missing'));
    expect(notFound.toString(), contains('coding-agent ls'));

    final failed = StringBuffer();
    expect(
      await runAgentLogsCommand(
        arguments: const ['ambiguous'],
        request: (message) async => {
          'requestId': message['requestId'],
          'agent': null,
          'project': null,
          'error': 'Agent identifier is ambiguous',
        },
        writeError: failed.write,
      ),
      1,
    );
    expect(
      failed.toString(),
      contains('Failed to get logs: Agent identifier is ambiguous'),
    );
  });

  test('follow prints history, streams matching timeline, and stops', () async {
    final messages = StreamController<Map<String, Object?>>();
    final iterator = StreamIterator(messages.stream);
    final stops = StreamController<void>();
    addTearDown(() async {
      await iterator.cancel();
      await messages.close();
      await stops.close();
    });
    final output = StringBuffer();
    final future = runAgentLogsCommand(
      arguments: const ['agent', '--follow', '--tail', '1'],
      request: (message) async => message['type'] == 'fetch_agent_request'
          ? _agentPayload(message, 'agent-full')
          : _timelinePayload(message, [
              const AssistantMessageItem(
                id: 'history',
                text: 'history',
                complete: true,
              ),
            ]),
      receiveMessage: () async {
        if (!await iterator.moveNext()) {
          throw StateError('messages closed');
        }
        return iterator.current;
      },
      stopSignals: stops.stream,
      writeOutput: output.write,
    );
    await _waitFor(() => output.toString().contains('Following logs'));
    messages.add(
      _streamMessage(
        agentId: 'other',
        item: const ErrorItem(id: 'ignored', message: 'wrong agent'),
      ),
    );
    messages.add({
      'type': 'agent_stream',
      'payload': {
        'agentId': 'agent-full',
        'event': {'type': 'turn_completed', 'provider': 'codex'},
        'timestamp': '2026-07-29T00:00:00Z',
        'seq': 2,
        'epoch': '1',
      },
    });
    messages.add(
      _streamMessage(
        agentId: 'agent-full',
        item: const ErrorItem(id: 'live', message: 'live boom'),
      ),
    );
    await _waitFor(() => output.toString().contains('[Error] live boom'));
    stops.add(null);
    expect(await future, 0);
    expect(
      output.toString(),
      'history\n'
      '\n--- Following logs (last 1 entry; Ctrl+C to stop) ---\n\n'
      '[Error] live boom\n',
    );
  });

  test('follow tail zero skips history and respects filters', () async {
    final messages = StreamController<Map<String, Object?>>();
    final iterator = StreamIterator(messages.stream);
    final stops = StreamController<void>();
    addTearDown(() async {
      await iterator.cancel();
      await messages.close();
      await stops.close();
    });
    final output = StringBuffer();
    final future = runAgentLogsCommand(
      arguments: const [
        'agent',
        '--follow',
        '--tail',
        '0',
        '--filter',
        'errors',
      ],
      request: (message) async => message['type'] == 'fetch_agent_request'
          ? _agentPayload(message, 'agent')
          : _timelinePayload(message, [
              const ErrorItem(id: 'history', message: 'hidden history'),
            ]),
      receiveMessage: () async {
        if (!await iterator.moveNext()) throw StateError('closed');
        return iterator.current;
      },
      stopSignals: stops.stream,
      writeOutput: output.write,
    );
    await _waitFor(() => output.toString().contains('Following logs'));
    messages.add(
      _streamMessage(
        agentId: 'agent',
        item: const AssistantMessageItem(
          id: 'ignored',
          text: 'not an error',
          complete: true,
        ),
      ),
    );
    messages.add(
      _streamMessage(
        agentId: 'agent',
        item: const ErrorItem(id: 'shown', message: 'shown'),
      ),
    );
    await _waitFor(() => output.toString().contains('[Error] shown'));
    stops.add(null);
    expect(await future, 0);
    expect(output.toString(), isNot(contains('hidden history')));
    expect(output.toString(), isNot(contains('not an error')));
    expect(output.toString(), startsWith('\n--- Following logs (no history'));
  });

  test('filter aliases and fallback matching cover timeline kinds', () {
    const tool = ToolCallItem(
      id: 'tool',
      toolName: 'bash',
      status: ToolCallStatus.running,
      detail: GenericDetail(input: {}),
    );
    const user = UserMessageItem(id: 'user', text: 'hello');
    const error = ErrorItem(id: 'error', message: 'boom');
    const permission = PermissionItem(
      id: 'permission',
      permissionId: 'permission-1',
      toolName: 'Bash',
      status: PermissionStatus.pending,
      detail: GenericDetail(input: {}),
    );
    expect(matchesAgentLogsFilter(tool, 'tools'), isTrue);
    expect(matchesAgentLogsFilter(user, 'text'), isTrue);
    expect(matchesAgentLogsFilter(error, 'errors'), isTrue);
    expect(matchesAgentLogsFilter(permission, 'permissions'), isTrue);
    expect(matchesAgentLogsFilter(tool, 'call'), isTrue);
    expect(matchesAgentLogsFilter(user, 'errors'), isFalse);
  });

  test('parser failures use usage exit code', () async {
    for (final arguments in const [
      <String>[],
      ['one', 'two'],
      ['agent', '--unknown'],
      ['agent', '--tail'],
    ]) {
      final error = StringBuffer();
      expect(
        await runAgentLogsCommand(
          arguments: arguments,
          writeError: error.write,
        ),
        64,
      );
      expect(error.toString(), contains('Usage: coding-agent agent logs'));
    }
  });
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

Map<String, Object?> _streamMessage({
  required String agentId,
  required TimelineItem item,
}) => {
  'type': 'agent_stream',
  'payload': {
    'agentId': agentId,
    'event': {
      'type': 'timeline',
      'provider': 'codex',
      'item': PaseoTimelineCodec.encode(item),
    },
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
  'status': 'idle',
  'capabilities': const <String, bool>{},
  'currentModeId': 'auto-review',
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
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition was not reached');
}
