/// Unit tests for [ClaudeSession] event mapping over a fake stream-json
/// transport (no real `claude` CLI required), mirroring
/// `codex_session_test.dart`'s approach for the parallel Codex implementation.
library;

import 'dart:async';
import 'dart:convert';

import 'package:agent_daemon/src/providers/claude/claude_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

/// Scripted `claude -p --output-format stream-json` process: records every
/// line the session sends and lets tests push scripted stdout lines back.
class FakeClaudeServer {
  final _toSession = StreamController<String>();
  final List<Map<String, Object?>> sent = [];

  Stream<String> get lines => _toSession.stream;

  void onClientLine(String line) {
    sent.add(jsonDecode(line) as Map<String, Object?>);
  }

  void send(Map<String, Object?> msg) => _toSession.add(jsonEncode(msg));

  void sendInit({String sessionId = 'sess-1'}) => send({
        'type': 'system',
        'subtype': 'init',
        'session_id': sessionId,
      });

  Future<void> close() => _toSession.close();
}

(ClaudeSession, FakeClaudeServer, List<ProviderEvent>) startSession() {
  final server = FakeClaudeServer();
  final session = ClaudeSession.forTransport(
    lines: server.lines,
    sendLine: server.onClientLine,
  );
  final events = <ProviderEvent>[];
  session.events.listen(events.add);
  return (session, server, events);
}

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  test('sends a control_request initialize handshake on construction', () {
    final (session, server, _) = startSession();
    expect(server.sent, hasLength(1));
    expect(server.sent.single['type'], 'control_request');
    expect((server.sent.single['request'] as Map)['subtype'], 'initialize');
    session.dispose();
  });

  test('system/init sets the session id and emits SessionStarted', () async {
    final (session, server, events) = startSession();
    server.sendInit(sessionId: 'thread-abc');
    await pump();
    expect(events.whereType<SessionStarted>().single.sessionId, 'thread-abc');
    await session.dispose();
  });

  test('system/init with a missing session_id still emits SessionStarted '
      'with an empty id', () async {
    final (session, server, events) = startSession();
    server.send({'type': 'system', 'subtype': 'init'});
    await pump();
    expect(events.whereType<SessionStarted>().single.sessionId, '');
    await session.dispose();
  });

  test('prompt sends a user message with the current session id', () async {
    final (session, server, _) = startSession();
    server.sendInit(sessionId: 'sess-9');
    await pump();
    await session.prompt('hello there');

    final userMsg = server.sent.firstWhere((m) => m['type'] == 'user');
    expect(userMsg['session_id'], 'sess-9');
    final content = (userMsg['message'] as Map)['content'] as List;
    expect(content.single, {'type': 'text', 'text': 'hello there'});
    await session.dispose();
  });

  test('prompt before session id is known sends an empty session_id',
      () async {
    final (session, server, _) = startSession();
    await session.prompt('hi');
    final userMsg = server.sent.firstWhere((m) => m['type'] == 'user');
    expect(userMsg['session_id'], '');
    await session.dispose();
  });

  test('interrupt sends a control_request with subtype interrupt', () async {
    final (session, server, _) = startSession();
    await session.interrupt();
    final interrupt = server.sent
        .firstWhere((m) => (m['request'] as Map?)?['subtype'] == 'interrupt');
    expect(interrupt['type'], 'control_request');
    await session.dispose();
  });

  test('assistant text stream: message_start, block_start and deltas map to '
      'AssistantTextDelta events', () async {
    final (session, server, events) = startSession();
    server.send({
      'type': 'stream_event',
      'event': {
        'type': 'message_start',
        'message': {'id': 'msg-1'},
      },
    });
    server.send({
      'type': 'stream_event',
      'event': {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'text'},
      },
    });
    server.send({
      'type': 'stream_event',
      'event': {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': 'Hel'},
      },
    });
    server.send({
      'type': 'stream_event',
      'event': {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': 'lo'},
      },
    });
    await pump();

    final deltas = events.whereType<AssistantTextDelta>().toList();
    expect(deltas.map((e) => e.text).toList(), ['Hel', 'lo']);
    expect(deltas.every((e) => e.itemId == 'msg-1_0'), isTrue);
    await session.dispose();
  });

  test('reasoning (thinking) deltas map to ReasoningDelta events', () async {
    final (session, server, events) = startSession();
    server.send({
      'type': 'stream_event',
      'event': {
        'type': 'message_start',
        'message': {'id': 'msg-2'},
      },
    });
    server.send({
      'type': 'stream_event',
      'event': {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'thinking'},
      },
    });
    server.send({
      'type': 'stream_event',
      'event': {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'thinking_delta', 'thinking': 'pondering'},
      },
    });
    await pump();
    expect(events.whereType<ReasoningDelta>().single.text, 'pondering');
    await session.dispose();
  });

  test('content_block_delta for an unknown index is ignored', () async {
    final (session, server, events) = startSession();
    server.send({
      'type': 'stream_event',
      'event': {
        'type': 'content_block_delta',
        'index': 5,
        'delta': {'type': 'text_delta', 'text': 'oops'},
      },
    });
    await pump();
    expect(events.whereType<AssistantTextDelta>(), isEmpty);
    await session.dispose();
  });

  test('tool_use content_block_start emits ToolCallStarted with mapped '
      'detail', () async {
    final (session, server, events) = startSession();
    server.send({
      'type': 'stream_event',
      'event': {
        'type': 'message_start',
        'message': {'id': 'msg-3'},
      },
    });
    server.send({
      'type': 'stream_event',
      'event': {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {
          'type': 'tool_use',
          'id': 'toolu_1',
          'name': 'Bash',
        },
      },
    });
    await pump();
    final started = events.whereType<ToolCallStarted>().single;
    expect(started.itemId, 'toolu_1');
    expect(started.toolName, 'Bash');
    expect(started.status, ToolCallStatus.pending);
    expect((started.detail as ShellDetail).command, ''); // no input yet
    await session.dispose();
  });

  test('assistant snapshot maps text/thinking/tool_use blocks', () async {
    final (session, server, events) = startSession();
    server.send({
      'type': 'assistant',
      'message': {
        'id': 'msg-4',
        'content': [
          {'type': 'text', 'text': 'Hello!'},
          {'type': 'thinking', 'thinking': 'because reasons'},
          {
            'type': 'tool_use',
            'id': 'toolu_2',
            'name': 'Read',
            'input': {'file_path': 'a.txt'},
          },
        ],
      },
    });
    await pump();

    final text = events.whereType<AssistantMessageComplete>().single;
    expect(text.itemId, 'msg-4_0');
    expect(text.fullText, 'Hello!');

    final reasoning = events.whereType<ReasoningComplete>().single;
    expect(reasoning.itemId, 'msg-4_1');
    expect(reasoning.fullText, 'because reasons');

    final tool = events.whereType<ToolCallUpdated>().single;
    expect(tool.itemId, 'toolu_2');
    expect(tool.status, ToolCallStatus.running);
    expect((tool.detail as ReadDetail).path, 'a.txt');
    await session.dispose();
  });

  test('user message tool_result updates a known shell tool call with '
      'truncated output and success/error status', () async {
    final (session, server, events) = startSession();
    server.send({
      'type': 'assistant',
      'message': {
        'id': 'msg-5',
        'content': [
          {
            'type': 'tool_use',
            'id': 'toolu_3',
            'name': 'Bash',
            'input': {'command': 'echo hi'},
          },
        ],
      },
    });
    await pump();

    server.send({
      'type': 'user',
      'message': {
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_3',
            'content': 'x' * 5000,
            'is_error': false,
          },
        ],
      },
    });
    await pump();

    final updates = events.whereType<ToolCallUpdated>().toList();
    final result = updates.last;
    expect(result.status, ToolCallStatus.success);
    final detail = result.detail as ShellDetail;
    expect(detail.command, 'echo hi');
    expect(detail.output!.length, 4096);
    await session.dispose();
  });

  test('failing tool_result marks the tool call as error', () async {
    final (session, server, events) = startSession();
    server.send({
      'type': 'assistant',
      'message': {
        'id': 'msg-6',
        'content': [
          {
            'type': 'tool_use',
            'id': 'toolu_4',
            'name': 'Bash',
            'input': {'command': 'false'},
          },
        ],
      },
    });
    await pump();
    server.send({
      'type': 'user',
      'message': {
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_4',
            'content': 'boom',
            'is_error': true,
          },
        ],
      },
    });
    await pump();
    final updates = events.whereType<ToolCallUpdated>().toList();
    expect(updates.last.status, ToolCallStatus.error);
    await session.dispose();
  });

  test('tool_result for an unknown tool_use_id or non-shell detail is '
      'handled gracefully', () async {
    final (session, server, events) = startSession();
    // Unknown id: no matching tool registered yet.
    server.send({
      'type': 'user',
      'message': {
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'no-such-tool',
            'content': 'ignored',
          },
        ],
      },
    });
    await pump();
    expect(events.whereType<ToolCallUpdated>(), isEmpty);

    // Known id but non-shell detail (Read): result still emits an update,
    // just without touching `output` (which only ShellDetail has).
    server.send({
      'type': 'assistant',
      'message': {
        'id': 'msg-7',
        'content': [
          {
            'type': 'tool_use',
            'id': 'toolu_5',
            'name': 'Read',
            'input': {'file_path': 'x.txt'},
          },
        ],
      },
    });
    await pump();
    server.send({
      'type': 'user',
      'message': {
        'content': [
          {'type': 'tool_result', 'tool_use_id': 'toolu_5', 'content': 'ok'},
        ],
      },
    });
    await pump();
    final readUpdate = events.whereType<ToolCallUpdated>().last;
    expect(readUpdate.itemId, 'toolu_5');
    expect(readUpdate.status, ToolCallStatus.success);
    expect(readUpdate.detail, isA<ReadDetail>());
    await session.dispose();
  });

  test('permission round-trip: allow sends behavior=allow with updatedInput',
      () async {
    final (session, server, events) = startSession();
    server.send({
      'type': 'control_request',
      'request_id': 'req-1',
      'request': {
        'subtype': 'can_use_tool',
        'tool_name': 'Write',
        'input': {'file_path': 'a.txt', 'content': 'hi'},
      },
    });
    await pump();
    final permission = events.whereType<PermissionRequested>().single;
    expect(permission.permissionId, 'req-1');
    expect(permission.toolName, 'Write');
    expect((permission.detail as WriteDetail).path, 'a.txt');

    await permission.respond(PermissionDecision.allow);
    final response = server.sent
        .firstWhere((m) => m['type'] == 'control_response');
    final inner = (response['response'] as Map)['response'] as Map;
    expect(inner['behavior'], 'allow');
    expect((inner['updatedInput'] as Map)['file_path'], 'a.txt');

    // Double-respond is a no-op: no second control_response is sent.
    await permission.respond(PermissionDecision.deny);
    expect(
      server.sent.where((m) => m['type'] == 'control_response'),
      hasLength(1),
    );
    await session.dispose();
  });

  test('permission round-trip: deny sends behavior=deny with a message',
      () async {
    final (session, server, events) = startSession();
    server.send({
      'type': 'control_request',
      'request_id': 'req-2',
      'request': {
        'subtype': 'can_use_tool',
        'tool_name': 'Bash',
        'input': {'command': 'rm -rf /'},
      },
    });
    await pump();
    final permission = events.whereType<PermissionRequested>().single;
    await permission.respond(PermissionDecision.deny, message: 'not today');
    final response = server.sent
        .firstWhere((m) => m['type'] == 'control_response');
    final inner = (response['response'] as Map)['response'] as Map;
    expect(inner['behavior'], 'deny');
    expect(inner['message'], 'not today');
    await session.dispose();
  });

  test('deny without an explicit message falls back to a default message',
      () async {
    final (session, server, events) = startSession();
    server.send({
      'type': 'control_request',
      'request_id': 'req-3',
      'request': {
        'subtype': 'can_use_tool',
        'tool_name': 'Bash',
        'input': {'command': 'ls'},
      },
    });
    await pump();
    final permission = events.whereType<PermissionRequested>().single;
    await permission.respond(PermissionDecision.deny);
    final response = server.sent
        .firstWhere((m) => m['type'] == 'control_response');
    final inner = (response['response'] as Map)['response'] as Map;
    expect(inner['message'], 'denied by user');
    await session.dispose();
  });

  test('non can_use_tool control_requests (e.g. hook callbacks) are '
      'auto-acked and do not surface as PermissionRequested', () async {
    final (session, server, events) = startSession();
    server.send({
      'type': 'control_request',
      'request_id': 'hook-1',
      'request': {'subtype': 'hook_callback'},
    });
    await pump();
    expect(events.whereType<PermissionRequested>(), isEmpty);
    final ack = server.sent
        .firstWhere((m) => m['type'] == 'control_response');
    final inner = (ack['response'] as Map)['response'] as Map;
    expect(inner, isEmpty);
    await session.dispose();
  });

  test('result message without is_error maps to TurnCompleted', () async {
    final (session, server, events) = startSession();
    server.send({'type': 'result'});
    await pump();
    expect(events.last, isA<TurnCompleted>());
    await session.dispose();
  });

  test('result message with is_error true maps to TurnFailed with the '
      'result string', () async {
    final (session, server, events) = startSession();
    server.send({'type': 'result', 'is_error': true, 'result': 'usage limit'});
    await pump();
    expect(events.whereType<TurnFailed>().single.error, 'usage limit');
    await session.dispose();
  });

  test('failing result without a result string falls back to subtype, then '
      'a generic message', () async {
    final (session, server, events) = startSession();
    server.send({'type': 'result', 'is_error': true, 'subtype': 'error_max_turns'});
    await pump();
    expect(events.whereType<TurnFailed>().single.error, 'error_max_turns');
    await session.dispose();
  });

  test('malformed JSON lines are ignored without crashing the session',
      () async {
    final (session, server, events) = startSession();
    server.send({'type': 'system', 'subtype': 'init', 'session_id': 's1'});
    server._toSession.add('not valid json {{{');
    server._toSession.add('   ');
    await pump();
    expect(events.whereType<SessionStarted>(), hasLength(1));
    await session.dispose();
  });

  test('unknown top-level message types are ignored', () async {
    final (session, server, events) = startSession();
    server.send({'type': 'rate_limit_event', 'foo': 'bar'});
    await pump();
    expect(events, isEmpty);
    await session.dispose();
  });

  test('transport closure emits SessionExited(exitCode: null) and closes '
      'the event stream', () async {
    final (session, server, events) = startSession();
    await server.close();
    await session.events.drain<void>();
    expect(events.last, isA<SessionExited>());
    expect((events.last as SessionExited).exitCode, isNull);
  });

  test('dispose() on a fake-transport session (no real process) also emits '
      'SessionExited and is idempotent', () async {
    final (session, server, events) = startSession();
    await session.dispose();
    await pump();
    expect(events.last, isA<SessionExited>());

    // Second dispose is a no-op (guarded by _disposed).
    await session.dispose();
    unawaited(server.close());
  });

  test('sending after dispose is a silent no-op', () async {
    final (session, server, _) = startSession();
    await session.dispose();
    final before = server.sent.length;
    await session.prompt('too late');
    expect(server.sent.length, before);
  });

  test('message_start without a message id synthesizes one', () async {
    final (session, server, events) = startSession();
    server.send({
      'type': 'stream_event',
      'event': {'type': 'message_start'},
    });
    server.send({
      'type': 'stream_event',
      'event': {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'text'},
      },
    });
    server.send({
      'type': 'stream_event',
      'event': {
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': 'hi'},
      },
    });
    await pump();
    final delta = events.whereType<AssistantTextDelta>().single;
    expect(delta.itemId, startsWith('msg_'));
    await session.dispose();
  });

  test('tool_result content given as a list of blocks is joined from the '
      'text blocks', () async {
    final (session, server, events) = startSession();
    server.send({
      'type': 'assistant',
      'message': {
        'id': 'msg-list',
        'content': [
          {
            'type': 'tool_use',
            'id': 'toolu_list',
            'name': 'Bash',
            'input': {'command': 'echo hi'},
          },
        ],
      },
    });
    await pump();
    server.send({
      'type': 'user',
      'message': {
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': 'toolu_list',
            'content': [
              {'type': 'text', 'text': 'line one'},
              {'type': 'other', 'text': 'should be ignored'},
              {'type': 'text', 'text': 'line two'},
            ],
            'is_error': false,
          },
        ],
      },
    });
    await pump();
    final updates = events.whereType<ToolCallUpdated>().toList();
    final detail = updates.last.detail as ShellDetail;
    expect(detail.output, 'line one\nline two');
    await session.dispose();
  });

  group('ClaudeSession.mapToolDetail', () {
    test('Bash maps to ShellDetail', () {
      final detail =
          ClaudeSession.mapToolDetail('Bash', {'command': 'ls -la'});
      expect(detail, isA<ShellDetail>());
      expect((detail as ShellDetail).command, 'ls -la');
    });

    test('Read maps to ReadDetail', () {
      final detail =
          ClaudeSession.mapToolDetail('Read', {'file_path': 'a.dart'});
      expect((detail as ReadDetail).path, 'a.dart');
    });

    test('Edit and MultiEdit map to EditDetail', () {
      final edit = ClaudeSession.mapToolDetail('Edit', {'file_path': 'a.dart'});
      expect((edit as EditDetail).path, 'a.dart');
      final multi =
          ClaudeSession.mapToolDetail('MultiEdit', {'file_path': 'b.dart'});
      expect((multi as EditDetail).path, 'b.dart');
    });

    test('Write maps to WriteDetail with a truncated content preview', () {
      final longContent = 'x' * 1000;
      final detail = ClaudeSession.mapToolDetail(
        'Write',
        {'file_path': 'c.dart', 'content': longContent},
      );
      expect(detail, isA<WriteDetail>());
      final write = detail as WriteDetail;
      expect(write.path, 'c.dart');
      expect(write.contentPreview!.length, 500);
    });

    test('Grep and Glob map to SearchDetail', () {
      final grep = ClaudeSession.mapToolDetail(
          'Grep', {'pattern': 'foo', 'path': 'src'});
      final grepDetail = grep as SearchDetail;
      expect(grepDetail.query, 'foo');
      expect(grepDetail.path, 'src');

      final glob = ClaudeSession.mapToolDetail('Glob', {'pattern': '*.dart'});
      expect((glob as SearchDetail).query, '*.dart');
      expect(glob.path, isNull);
    });

    test('unknown tool names map to GenericDetail with the raw input', () {
      final detail =
          ClaudeSession.mapToolDetail('SomeOtherTool', {'a': 1, 'b': 'c'});
      expect(detail, isA<GenericDetail>());
      expect((detail as GenericDetail).input, {'a': 1, 'b': 'c'});
    });
  });
}
