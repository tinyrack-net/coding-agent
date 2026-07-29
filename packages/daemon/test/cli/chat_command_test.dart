import 'dart:async';
import 'dart:convert';

import 'package:agent_daemon/src/cli/chat_command.dart';
import 'package:test/test.dart';

const _timestamp = '2026-07-30T00:00:00.000Z';

void main() {
  test('create/list/inspect/delete map room RPCs and output schemas', () async {
    for (final scenario in [
      (
        arguments: ['create', 'Review', '--purpose', 'Coordinate', '--json'],
        type: 'chat/create',
      ),
      (arguments: ['ls', '--json'], type: 'chat/list'),
      (arguments: ['inspect', 'Review', '--json'], type: 'chat/inspect'),
      (arguments: ['delete', 'Review', '--json'], type: 'chat/delete'),
    ]) {
      final client = _FakeChatClient();
      final output = StringBuffer();
      final code = await runChatCommand(
        arguments: scenario.arguments,
        connect: _connector(client),
        writeOutput: output.write,
      );

      expect(code, 0);
      expect(client.requests.first['type'], scenario.type);
      expect(output.toString(), contains('"name": "Review"'));
      final decoded = jsonDecode(output.toString());
      expect(
        decoded,
        scenario.type == 'chat/list' ? isA<List<dynamic>>() : isA<Map>(),
      );
      expect(client.closed, isTrue);
    }
  });

  test('post sends author/reply and renders resolved transcript', () async {
    final client = _FakeChatClient();
    final output = StringBuffer();
    final code = await runChatCommand(
      arguments: ['post', 'Review', 'hello @agent-2', '--reply-to', 'parent'],
      environment: const {'TINYRACK_AGENT_ID': 'agent-1'},
      connect: _connector(client),
      writeOutput: output.write,
    );

    expect(code, 0);
    expect(client.requests.first, containsPair('authorAgentId', 'agent-1'));
    expect(client.requests.first, containsPair('replyToMessageId', 'parent'));
    expect(output.toString(), contains('Alice (agent-1)'));
    expect(output.toString(), contains('mentions: Bob (agent-2)'));
    expect(output.toString(), contains('reply-to: msg parent'));
  });

  test('message rendering falls back when agent enrichment fails', () async {
    final output = StringBuffer();
    expect(
      await runChatCommand(
        arguments: ['post', 'Review', 'hello @agent-2'],
        connect: _connector(
          _FakeChatClient(failAgents: true, invalidTimestamp: true),
        ),
        writeOutput: output.write,
      ),
      0,
    );
    expect(output.toString(), contains('┌─ agent-1'));
    expect(output.toString(), contains(_invalidTimestamp));
    expect(output.toString(), contains('mentions: agent-2'));
  });

  test('read parses duration, filters, limit, and JSON rows', () async {
    final client = _FakeChatClient();
    final output = StringBuffer();
    final before = DateTime.now().toUtc();
    final code = await runChatCommand(
      arguments: [
        'read',
        'Review',
        '--limit',
        '5',
        '--since',
        '10m',
        '--agent',
        'agent-1',
        '--json',
      ],
      connect: _connector(client),
      writeOutput: output.write,
    );

    expect(code, 0);
    final request = client.requests.first;
    expect(request['limit'], 5);
    expect(request['authorAgentId'], 'agent-1');
    final since = DateTime.parse(request['since']! as String);
    expect(since.isBefore(before.subtract(const Duration(minutes: 9))), isTrue);
    expect(output.toString(), contains('"authorName": "Alice"'));
    expect(output.toString(), contains('"replyTo": "parent"'));
  });

  test('wait preflights latest cursor and forwards bounded timeout', () async {
    final client = _FakeChatClient();
    final output = StringBuffer();
    final code = await runChatCommand(
      arguments: ['wait', 'Review', '--timeout', '2s', '--json'],
      connect: _connector(client),
      writeOutput: output.write,
    );

    expect(code, 0);
    expect(client.requests[0]['type'], 'chat/read');
    expect(client.requests[0]['limit'], 1);
    expect(client.requests[1]['type'], 'chat/wait');
    expect(client.requests[1]['afterMessageId'], 'message-1');
    expect(client.requests[1]['timeoutMs'], greaterThan(0));
    expect(output.toString(), contains('"id": "message-2"'));
  });

  test('parser rejects invalid command boundaries before connecting', () async {
    var connects = 0;
    Future<ChatRpcClient> connector({
      required String? host,
      required String? home,
      required Map<String, String> environment,
    }) async {
      connects++;
      return _FakeChatClient();
    }

    for (final arguments in [
      <String>[],
      ['unknown'],
      ['create'],
      ['ls', 'extra'],
      ['post', 'room'],
      ['read', 'room', '--limit', '-1'],
      ['read', 'room', '--since', 'later'],
      ['wait', 'room', '--timeout', '0ms'],
      ['read', 'room', '--purpose', 'nope'],
      ['read', 'room', '--reply-to', 'nope'],
      ['read', 'room', '--timeout', '1s'],
      ['post', 'room', 'body', '--limit', '1'],
      ['ls', '--host'],
      ['ls', '--home'],
      ['create', 'room', '--purpose'],
      ['post', 'room', 'body', '--reply-to'],
      ['read', 'room', '--agent'],
      ['read', 'room', '--since'],
      ['wait', 'room', '--timeout'],
      ['ls', '--wat'],
    ]) {
      final errors = StringBuffer();
      expect(
        await runChatCommand(
          arguments: arguments,
          connect: connector,
          writeError: errors.write,
        ),
        64,
      );
      expect(errors.toString(), contains('Usage: coding-agent chat'));
    }
    expect(connects, 0);
  });

  test('RPC and connection failures return stable non-usage exit', () async {
    final errors = StringBuffer();
    expect(
      await runChatCommand(
        arguments: ['inspect', 'missing'],
        connect: _connector(_FakeChatClient(fail: true)),
        writeError: errors.write,
      ),
      1,
    );
    expect(errors.toString(), contains('chat_room_not_found'));

    errors.clear();
    expect(
      await runChatCommand(
        arguments: ['inspect', 'missing', '--json'],
        connect: _connector(_FakeChatClient(fail: true)),
        writeError: errors.write,
      ),
      1,
    );
    final jsonError =
        (jsonDecode(errors.toString()) as Map<String, dynamic>)['error']
            as Map<String, dynamic>;
    expect(jsonError['code'], 'CHAT_INSPECT_FAILED');
    expect(jsonError['message'], contains('chat_room_not_found'));

    errors.clear();
    expect(
      await runChatCommand(
        arguments: ['ls'],
        connect: ({required host, required home, required environment}) async =>
            throw StateError('offline'),
        writeError: errors.write,
      ),
      1,
    );
    expect(errors.toString(), contains('offline'));

    errors.clear();
    expect(
      await runChatCommand(
        arguments: ['ls', '--format', 'yaml'],
        connect: ({required host, required home, required environment}) async =>
            throw StateError('offline'),
        writeError: errors.write,
      ),
      1,
    );
    expect(errors.toString(), startsWith('error:\n'));
    expect(errors.toString(), contains('code: CHAT_LIST_FAILED'));
    expect(errors.toString(), contains('message: "Failed to list chat rooms:'));

    errors.clear();
    expect(
      await runChatCommand(
        arguments: ['ls', '--host', '127.0.0.1:1'],
        environment: const {},
        writeError: errors.write,
      ),
      1,
    );
    expect(errors.toString(), contains('Cannot connect to daemon'));

    errors.clear();
    expect(
      await runChatCommand(
        arguments: ['inspect', 'Review'],
        connect: _connector(_FakeChatClient(invalidRoom: true)),
        writeError: errors.write,
      ),
      1,
    );
    expect(errors.toString(), contains('room must be an object'));
  });

  test('human room output and empty transcript are deterministic', () async {
    final output = StringBuffer();
    expect(
      await runChatCommand(
        arguments: ['ls'],
        connect: _connector(_FakeChatClient()),
        writeOutput: output.write,
      ),
      0,
    );
    expect(output.toString(), contains('NAME'));
    expect(output.toString(), contains('Review'));

    output.clear();
    expect(
      await runChatCommand(
        arguments: ['create', 'A very long room name that is clipped'],
        connect: _connector(_FakeChatClient(longRoom: true)),
        writeOutput: output.write,
      ),
      0,
    );
    expect(
      output.toString(),
      contains('A very long room name that is clipped'),
    );
    expect(output.toString(), isNot(contains('…')));

    output.clear();
    expect(
      await runChatCommand(
        arguments: ['read', 'empty'],
        connect: _connector(_FakeChatClient(empty: true)),
        writeOutput: output.write,
      ),
      0,
    );
    expect(output.toString(), isEmpty);
  });

  test('chat supports frozen yaml quiet and header output options', () async {
    final yaml = StringBuffer();
    expect(
      await runChatCommand(
        arguments: ['ls', '--format=yaml'],
        connect: _connector(_FakeChatClient()),
        writeOutput: yaml.write,
      ),
      0,
    );
    expect(yaml.toString(), contains('- name: Review'));
    expect(yaml.toString(), contains('  id: room-1'));
    expect(yaml.toString(), contains('  messages: 1'));

    final compactYaml = StringBuffer();
    expect(
      await runChatCommand(
        arguments: ['post', 'Review', 'hello', '-oyaml'],
        connect: _connector(_FakeChatClient()),
        writeOutput: compactYaml.write,
      ),
      0,
    );
    expect(compactYaml.toString(), startsWith('id: message-1\n'));
    expect(compactYaml.toString(), contains('mentionAgentIds:\n  - agent-2'));

    for (final scenario in [
      (arguments: ['create', 'Review', '--quiet'], id: 'room-1\n'),
      (arguments: ['ls', '-q'], id: 'room-1\n'),
      (arguments: ['post', 'Review', 'hello', '-q'], id: 'message-1\n'),
      (arguments: ['read', 'Review', '--quiet'], id: 'message-1\n'),
    ]) {
      final output = StringBuffer();
      expect(
        await runChatCommand(
          arguments: scenario.arguments,
          connect: _connector(_FakeChatClient()),
          writeOutput: output.write,
        ),
        0,
      );
      expect(output.toString(), scenario.id);
    }

    final noHeaders = StringBuffer();
    expect(
      await runChatCommand(
        arguments: ['ls', '--no-headers', '--no-color'],
        connect: _connector(_FakeChatClient()),
        writeOutput: noHeaders.write,
      ),
      0,
    );
    expect(noHeaders.toString(), isNot(contains('NAME')));
    expect(noHeaders.toString(), contains('Review'));

    final jsonWins = StringBuffer();
    expect(
      await runChatCommand(
        arguments: ['ls', '--json', '--format', 'yaml'],
        connect: _connector(_FakeChatClient()),
        writeOutput: jsonWins.write,
      ),
      0,
    );
    expect(jsonDecode(jsonWins.toString()), isA<List<dynamic>>());
  });

  test('ISO since and hour/day durations are accepted', () async {
    final client = _FakeChatClient();
    expect(
      await runChatCommand(
        arguments: ['read', 'Review', '--since', '2026-07-30T00:00:00Z'],
        connect: _connector(client),
        writeOutput: (_) {},
      ),
      0,
    );
    expect(client.requests.first['since'], '2026-07-30T00:00:00.000Z');

    for (final timeout in ['1h', '1d']) {
      final waiting = _FakeChatClient();
      expect(
        await runChatCommand(
          arguments: ['wait', 'Review', '--timeout', timeout, '--json'],
          connect: _connector(waiting),
          writeOutput: (_) {},
        ),
        0,
      );
      expect(
        waiting.requests[1]['timeoutMs'],
        timeout == '1h' ? lessThanOrEqualTo(3600000) : greaterThan(3600000),
      );
    }
  });
}

ChatClientConnector _connector(_FakeChatClient client) =>
    ({
      required String? host,
      required String? home,
      required Map<String, String> environment,
    }) async => client;

final class _FakeChatClient implements ChatRpcClient {
  _FakeChatClient({
    this.fail = false,
    this.empty = false,
    this.failAgents = false,
    this.invalidTimestamp = false,
    this.invalidRoom = false,
    this.longRoom = false,
  });
  final bool fail;
  final bool empty;
  final bool failAgents;
  final bool invalidTimestamp;
  final bool invalidRoom;
  final bool longRoom;
  final requests = <Map<String, Object?>>[];
  var closed = false;

  @override
  Future<Map<String, Object?>> request(
    Map<String, Object?> request, {
    Duration? timeout,
  }) async {
    requests.add(request);
    if (fail) {
      throw StateError('chat_room_not_found: Chat room not found');
    }
    if (request['type'] == 'fetch_agents_request' && failAgents) {
      throw StateError('agent directory unavailable');
    }
    return switch (request['type']) {
      'chat/create' || 'chat/inspect' || 'chat/delete' => {
        'room': invalidRoom ? null : _room(longName: longRoom),
        'error': null,
      },
      'chat/list' => {
        'rooms': [_room(longName: longRoom)],
        'error': null,
      },
      'chat/post' => {
        'message': _message(
          'message-1',
          timestamp: invalidTimestamp ? _invalidTimestamp : _timestamp,
        ),
        'error': null,
      },
      'chat/read' when empty => {'messages': <Object?>[], 'error': null},
      'chat/read' => {
        'messages': [_message('message-1')],
        'error': null,
      },
      'chat/wait' => {
        'messages': [_message('message-2')],
        'timedOut': false,
        'error': null,
      },
      'fetch_agents_request' => {
        'entries': [
          {
            'agent': {'id': 'agent-1', 'title': 'Alice'},
          },
          {
            'agent': {'id': 'agent-2', 'title': 'Bob'},
          },
        ],
      },
      _ => throw StateError('unexpected request ${request['type']}'),
    };
  }

  @override
  Future<void> close() async => closed = true;
}

Map<String, Object?> _room({bool longName = false}) => {
  'id': 'room-1',
  'name': longName ? 'A very long room name that is clipped' : 'Review',
  'purpose': 'Coordinate',
  'createdAt': _timestamp,
  'updatedAt': _timestamp,
  'messageCount': 1,
  'lastMessageAt': _timestamp,
};

const _invalidTimestamp = 'not-a-timestamp';

Map<String, Object?> _message(String id, {String timestamp = _timestamp}) => {
  'id': id,
  'roomId': 'room-1',
  'authorAgentId': 'agent-1',
  'body': 'hello @agent-2',
  'replyToMessageId': 'parent',
  'mentionAgentIds': ['agent-2'],
  'createdAt': timestamp,
};
