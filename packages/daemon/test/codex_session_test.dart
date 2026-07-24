/// Unit tests for [CodexSession] event mapping over a fake JSON-RPC
/// transport (no real codex CLI required).
library;

import 'dart:async';
import 'dart:convert';

import 'package:agent_daemon/src/providers/codex/codex_session.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

/// Scripted `codex app-server`: parses client lines, auto-answers the
/// handshake, records everything, and lets tests push notifications and
/// server->client approval requests.
class FakeCodexServer {
  FakeCodexServer({this.threadId = 'thread-1'});

  final String threadId;
  final _toSession = StreamController<String>();
  final List<Map<String, Object?>> sent = [];
  final _requests = StreamController<Map<String, Object?>>.broadcast();

  Stream<String> get lines => _toSession.stream;

  void onClientLine(String line) {
    final msg = jsonDecode(line) as Map<String, Object?>;
    sent.add(msg);
    _requests.add(msg);
    final method = msg['method'];
    final id = msg['id'];
    if (id == null || method is! String) return;
    switch (method) {
      case 'initialize':
        respond(id, {'userAgent': 'fake/0.0.0'});
      case 'thread/start':
        respond(id, {
          'thread': {'id': threadId, 'sessionId': threadId},
        });
        notify('thread/started', {
          'thread': {'id': threadId},
        });
      case 'thread/resume':
        respond(id, {
          'thread': {'id': threadId},
        });
      case 'turn/start':
        respond(id, {
          'turn': {'id': 'turn-1', 'status': 'inProgress'},
        });
        notify('turn/started', {
          'threadId': threadId,
          'turn': {'id': 'turn-1'},
        });
      case 'turn/interrupt':
        respond(id, const {});
    }
  }

  void respond(Object id, Map<String, Object?> result) =>
      _toSession.add(jsonEncode({'id': id, 'result': result}));

  void notify(String method, Map<String, Object?> params) =>
      _toSession.add(jsonEncode({'method': method, 'params': params}));

  /// Server->client request (approval); returns the client's eventual reply.
  Future<Map<String, Object?>> request(
    int id,
    String method,
    Map<String, Object?> params,
  ) {
    final reply = _requests.stream
        .firstWhere((m) => m['id'] == id && !m.containsKey('method'));
    _toSession.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    return reply;
  }

  Future<Map<String, Object?>> waitForRequest(String method) =>
      _requests.stream.firstWhere((m) => m['method'] == method);

  Future<void> close() => _toSession.close();
}

Future<(CodexSession, FakeCodexServer, List<ProviderEvent>)> startSession({
  AgentMode mode = AgentMode.normal,
  String? sessionId,
}) async {
  final server = FakeCodexServer();
  final session = CodexSession.forTransport(
    lines: server.lines,
    sendLine: server.onClientLine,
    cwd: '/tmp/work',
    mode: mode,
    sessionId: sessionId,
  );
  final events = <ProviderEvent>[];
  session.events.listen(events.add);
  // Let the handshake settle.
  await server.waitForRequest(sessionId == null ? 'thread/start' : 'thread/resume');
  await pump();
  return (session, server, events);
}

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  test('handshake emits SessionStarted with the thread id', () async {
    final (session, server, events) = await startSession();
    expect(events, [
      isA<SessionStarted>()
          .having((e) => e.sessionId, 'sessionId', 'thread-1'),
    ]);
    final init = server.sent.firstWhere((m) => m['method'] == 'initialize');
    expect((init['params'] as Map)['clientInfo'], isNotNull);
    expect(
      server.sent.any((m) => m['method'] == 'initialized' && m['id'] == null),
      isTrue,
    );
    await session.dispose();
  });

  test('resume uses thread/resume with the prior session id', () async {
    final (session, server, events) =
        await startSession(sessionId: 'thread-1');
    final resume =
        server.sent.firstWhere((m) => m['method'] == 'thread/resume');
    expect((resume['params'] as Map)['threadId'], 'thread-1');
    expect(events.whereType<SessionStarted>().single.sessionId, 'thread-1');
    await session.dispose();
  });

  test('mode maps to approvalPolicy/sandbox on thread and turn start',
      () async {
    for (final (mode, policy, sandbox, sandboxType) in [
      (AgentMode.plan, 'on-request', 'read-only', 'readOnly'),
      (AgentMode.normal, 'on-request', 'workspace-write', 'workspaceWrite'),
      (AgentMode.fullAccess, 'never', 'danger-full-access', 'dangerFullAccess'),
    ]) {
      final (session, server, _) = await startSession(mode: mode);
      final threadStart =
          server.sent.firstWhere((m) => m['method'] == 'thread/start');
      final threadParams = threadStart['params'] as Map;
      expect(threadParams['approvalPolicy'], policy);
      expect(threadParams['sandbox'], sandbox);

      await session.prompt('hello');
      final turnStart =
          server.sent.firstWhere((m) => m['method'] == 'turn/start');
      final turnParams = turnStart['params'] as Map;
      expect(turnParams['threadId'], 'thread-1');
      expect(turnParams['input'], [
        {'type': 'text', 'text': 'hello'},
      ]);
      expect(turnParams['approvalPolicy'], policy);
      expect((turnParams['sandboxPolicy'] as Map)['type'], sandboxType);
      await session.dispose();
    }
  });

  test('agent message deltas and completion map to assistant events',
      () async {
    final (session, server, events) = await startSession();
    await session.prompt('hi');
    server.notify('item/agentMessage/delta',
        {'threadId': 'thread-1', 'itemId': 'msg-1', 'delta': 'Hel'});
    server.notify('item/agentMessage/delta',
        {'threadId': 'thread-1', 'itemId': 'msg-1', 'delta': 'lo'});
    server.notify('item/completed', {
      'threadId': 'thread-1',
      'item': {'type': 'agentMessage', 'id': 'msg-1', 'text': 'Hello'},
    });
    server.notify('turn/completed', {
      'threadId': 'thread-1',
      'turn': {'status': 'completed', 'error': null},
    });
    await pump();

    expect(
      events.whereType<AssistantTextDelta>().map((e) => e.text).toList(),
      ['Hel', 'lo'],
    );
    final complete = events.whereType<AssistantMessageComplete>().single;
    expect(complete.itemId, 'msg-1');
    expect(complete.fullText, 'Hello');
    expect(events.last, isA<TurnCompleted>());
    await session.dispose();
  });

  test('reasoning deltas and completion map to reasoning events', () async {
    final (session, server, events) = await startSession();
    server.notify('item/reasoning/summaryTextDelta',
        {'threadId': 'thread-1', 'itemId': 'r-1', 'delta': 'thinking...'});
    server.notify('item/completed', {
      'threadId': 'thread-1',
      'item': {
        'type': 'reasoning',
        'id': 'r-1',
        'summary': ['thinking...', 'done'],
      },
    });
    await pump();
    expect(events.whereType<ReasoningDelta>().single.text, 'thinking...');
    final complete = events.whereType<ReasoningComplete>().single;
    expect(complete.fullText, 'thinking...\ndone');
    await session.dispose();
  });

  test('command execution maps to shell tool calls with truncated output',
      () async {
    final (session, server, events) = await startSession();
    server.notify('item/started', {
      'threadId': 'thread-1',
      'item': {
        'type': 'commandExecution',
        'id': 'cmd-1',
        'command': ['bash', '-lc', 'echo hi'],
        'status': 'inProgress',
      },
    });
    server.notify('item/completed', {
      'threadId': 'thread-1',
      'item': {
        'type': 'commandExecution',
        'id': 'cmd-1',
        'command': ['bash', '-lc', 'echo hi'],
        'status': 'completed',
        'aggregatedOutput': 'x' * 5000,
        'exitCode': 0,
      },
    });
    await pump();

    final started = events.whereType<ToolCallStarted>().single;
    expect(started.itemId, 'cmd-1');
    expect(started.toolName, 'shell');
    expect(started.status, ToolCallStatus.running);
    expect((started.detail as ShellDetail).command, 'echo hi');

    final updated = events.whereType<ToolCallUpdated>().single;
    final detail = updated.detail as ShellDetail;
    expect(updated.status, ToolCallStatus.success);
    expect(detail.exitCode, 0);
    expect(detail.output!.length, 4096);
    await session.dispose();
  });

  test('failing command maps to error status', () async {
    final (session, server, events) = await startSession();
    server.notify('item/completed', {
      'threadId': 'thread-1',
      'item': {
        'type': 'commandExecution',
        'id': 'cmd-2',
        'command': 'false',
        'status': 'failed',
        'aggregatedOutput': 'boom',
        'exitCode': 1,
      },
    });
    await pump();
    final updated = events.whereType<ToolCallUpdated>().single;
    expect(updated.status, ToolCallStatus.error);
    expect((updated.detail as ShellDetail).exitCode, 1);
    await session.dispose();
  });

  test('file changes map to edit/write details per file', () async {
    final (session, server, events) = await startSession();
    server.notify('item/completed', {
      'threadId': 'thread-1',
      'item': {
        'type': 'fileChange',
        'id': 'fc-1',
        'status': 'completed',
        'changes': [
          {'path': 'src/a.dart', 'kind': 'modify', 'diff': '@@ -1 +1 @@'},
          {'path': 'src/b.dart', 'kind': 'add', 'content': 'new file'},
        ],
      },
    });
    await pump();
    final updates = events.whereType<ToolCallUpdated>().toList();
    expect(updates, hasLength(2));
    final edit = updates[0].detail as EditDetail;
    expect(edit.path, 'src/a.dart');
    expect(edit.diff, '@@ -1 +1 @@');
    expect(updates[0].status, ToolCallStatus.success);
    final write = updates[1].detail as WriteDetail;
    expect(write.path, 'src/b.dart');
    expect(write.contentPreview, 'new file');
    await session.dispose();
  });

  test('web search and unknown items map to search/generic details',
      () async {
    final (session, server, events) = await startSession();
    server.notify('item/completed', {
      'threadId': 'thread-1',
      'item': {'type': 'webSearch', 'id': 'ws-1', 'query': 'dart streams'},
    });
    server.notify('item/completed', {
      'threadId': 'thread-1',
      'item': {'type': 'imageGeneration', 'id': 'img-1'},
    });
    await pump();
    final updates = events.whereType<ToolCallUpdated>().toList();
    expect((updates[0].detail as SearchDetail).query, 'dart streams');
    expect(updates[1].toolName, 'imageGeneration');
    expect(updates[1].detail, isA<GenericDetail>());
    await session.dispose();
  });

  test('command approval round-trip: allow answers accept', () async {
    final (session, server, events) = await startSession();
    final replyFuture = server.request(
      99,
      'item/commandExecution/requestApproval',
      {
        'itemId': 'cmd-9',
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'command': 'rm -rf build',
        'cwd': '/tmp/work',
      },
    );
    await pump();
    final permission = events.whereType<PermissionRequested>().single;
    expect(permission.permissionId, 'cmd-9');
    expect(permission.toolName, 'shell');
    expect((permission.detail as ShellDetail).command, 'rm -rf build');

    await permission.respond(PermissionDecision.allow);
    final reply = await replyFuture;
    expect(reply['result'], {'decision': 'accept'});

    // Double-respond is a no-op.
    await permission.respond(PermissionDecision.deny);
    expect(
      server.sent.where((m) => m['id'] == 99 && !m.containsKey('method')),
      hasLength(1),
    );
    await session.dispose();
  });

  test('file change approval round-trip: deny answers decline', () async {
    final (session, server, events) = await startSession();
    final replyFuture = server.request(
      42,
      'item/fileChange/requestApproval',
      {
        'itemId': 'fc-9',
        'threadId': 'thread-1',
        'turnId': 'turn-1',
        'reason': 'outside workspace',
      },
    );
    await pump();
    final permission = events.whereType<PermissionRequested>().single;
    expect(permission.toolName, 'apply_patch');
    await permission.respond(PermissionDecision.deny);
    final reply = await replyFuture;
    expect(reply['result'], {'decision': 'decline'});
    await session.dispose();
  });

  test('unknown server requests are acked with an empty result', () async {
    final (session, server, _) = await startSession();
    final reply = await server.request(
      7,
      'item/tool/requestUserInput',
      {'itemId': 'q-1', 'threadId': 'thread-1', 'turnId': 'turn-1'},
    );
    expect(reply['result'], isEmpty);
    await session.dispose();
  });

  test('failed turn maps to TurnFailed with the error message', () async {
    final (session, server, events) = await startSession();
    await session.prompt('hi');
    server.notify('turn/completed', {
      'threadId': 'thread-1',
      'turn': {
        'status': 'failed',
        'error': {'message': 'usage limit exceeded'},
      },
    });
    await pump();
    expect(
      events.whereType<TurnFailed>().single.error,
      'usage limit exceeded',
    );
    await session.dispose();
  });

  test('interrupt sends turn/interrupt with thread and turn ids', () async {
    final (session, server, _) = await startSession();
    await session.prompt('hi');
    await pump(); // let turn/started arrive
    await session.interrupt();
    final interrupt =
        server.sent.firstWhere((m) => m['method'] == 'turn/interrupt');
    expect(interrupt['params'], {
      'threadId': 'thread-1',
      'turnId': 'turn-1',
    });
    await session.dispose();
  });

  test('interrupt before a turn is a no-op', () async {
    final (session, server, _) = await startSession();
    await session.interrupt();
    expect(server.sent.any((m) => m['method'] == 'turn/interrupt'), isFalse);
    await session.dispose();
  });

  test('transport closure emits SessionExited and closes the stream',
      () async {
    final (session, server, events) = await startSession();
    await server.close();
    await session.events.drain<void>();
    expect(events.last, isA<SessionExited>());
  });
}
