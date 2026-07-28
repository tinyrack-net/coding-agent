import 'dart:async';

import 'package:agent_daemon/src/providers/paseo/codex_agent_session.dart';
import 'package:agent_daemon/src/providers/paseo/codex_app_server_client.dart';
import 'package:agent_daemon/src/providers/paseo/codex_session_runtime.dart';
import 'package:agent_daemon/src/providers/paseo/jsonl_rpc_process.dart';
import 'package:agent_daemon/src/providers/provider_event.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

final class _FakeCodexConnection implements CodexAppServerConnection {
  CodexAppServerNotificationHandler? notificationHandler;
  final Map<String, CodexAppServerRequestHandler> handlers = {};
  final Set<void Function(JsonlRpcExit)> exitHandlers = {};
  final List<(String, Object?, Duration?)> requests = [];
  var disposed = false;

  @override
  bool get isClosed => disposed;

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  void emit(String method, Object? params) {
    notificationHandler?.call(method, params);
  }

  void exit([int code = 7]) {
    final exit = JsonlRpcExit(
      code: code,
      error: StateError('Codex app-server exited'),
    );
    for (final handler in exitHandlers.toList(growable: false)) {
      handler(exit);
    }
  }

  Future<Object?> serverRequest(String method, Object? params) {
    return Future<Object?>.value(handlers[method]!(params, 700));
  }

  @override
  Future<CodexThreadForkResponse> forkThread(
    CodexThreadForkParams params,
  ) async {
    return CodexThreadForkResponse(
      thread: const CodexThreadSummary(id: 'fork'),
      model: 'gpt',
      modelProvider: 'openai',
      serviceTier: null,
      cwd: '/workspace',
      runtimeWorkspaceRoots: const [],
      instructionSources: const [],
      approvalPolicy: null,
      approvalsReviewer: null,
      sandbox: null,
    );
  }

  @override
  void Function() onExit(void Function(JsonlRpcExit exit) handler) {
    exitHandlers.add(handler);
    return () => exitHandlers.remove(handler);
  }

  @override
  void notify(String method, [Object? params]) {}

  @override
  Future<Object?> request(
    String method, [
    Object? params,
    Duration? timeout,
  ]) async {
    requests.add((method, params, timeout));
    return switch (method) {
      'initialize' => <String, Object?>{},
      'getUserSavedConfig' => {
        'config': {'model': 'gpt', 'modelReasoningEffort': 'high'},
      },
      'thread/start' => () {
        emit('thread/started', {
          'thread': {'id': 'thread'},
        });
        return {
          'thread': {'id': 'thread'},
        };
      }(),
      'turn/start' => <String, Object?>{},
      _ => <String, Object?>{},
    };
  }

  @override
  Future<CodexThreadRollbackResponse> rollbackThread(
    CodexThreadRollbackParams params,
  ) async {
    return const CodexThreadRollbackResponse(
      thread: CodexThreadSummary(id: 'rollback'),
    );
  }

  @override
  void setNotificationHandler(CodexAppServerNotificationHandler handler) {
    notificationHandler = handler;
  }

  @override
  void setRequestHandler(String method, CodexAppServerRequestHandler handler) {
    handlers[method] = handler;
  }
}

(CodexAgentSession, _FakeCodexConnection) _createSession() {
  final connection = _FakeCodexConnection();
  final runtime = CodexSessionRuntime(
    client: connection,
    config: const CodexRuntimeConfig(cwd: '/workspace', modeId: 'auto'),
  );
  return (CodexAgentSession(runtime), connection);
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'warns when mode and thinking changes apply after an active turn',
    () async {
      final (session, connection) = _createSession();
      addTearDown(session.dispose);

      await session.prompt('hello');
      connection.emit('turn/started', {
        'threadId': 'thread',
        'turn': {'id': 'turn-1'},
      });

      final modeNotice = await session.setMode('full-access');
      final thinkingNotice = await session.setThinkingOption('high');
      expect(modeNotice?.type, AgentProviderNoticeType.warning);
      expect(modeNotice?.message, 'Permission mode applies next turn');
      expect(thinkingNotice?.type, AgentProviderNoticeType.warning);
      expect(thinkingNotice?.message, 'Thinking level applies next turn');

      connection.emit('turn/completed', {
        'threadId': 'thread',
        'turn': {'id': 'turn-1', 'status': 'completed'},
      });
      expect(await session.setMode('read-only'), isNull);
      expect(await session.setThinkingOption('low'), isNull);
    },
  );

  test('normalizes session, streaming text, completion, and turn', () async {
    final (session, connection) = _createSession();
    addTearDown(session.dispose);
    final events = <ProviderEvent>[];
    session.events.listen(events.add);

    await session.prompt('hello');
    connection.emit('item/agentMessage/delta', {
      'threadId': 'thread',
      'itemId': 'msg-1',
      'delta': 'Hel',
    });
    connection.emit('item/agentMessage/delta', {
      'threadId': 'thread',
      'itemId': 'msg-1',
      'delta': 'lo',
    });
    connection.emit('item/completed', {
      'threadId': 'thread',
      'item': {'id': 'msg-1', 'type': 'agentMessage', 'text': 'Hello!'},
    });
    connection.emit('turn/completed', {
      'threadId': 'thread',
      'turn': {'status': 'completed'},
    });
    await _flush();

    expect(events.whereType<SessionStarted>().single.sessionId, 'thread');
    expect(events.whereType<AssistantTextDelta>().map((event) => event.text), [
      'Hel',
      'lo',
    ]);
    expect(
      events.whereType<AssistantMessageComplete>().single.fullText,
      'Hello!',
    );
    expect(events.whereType<TurnCompleted>(), hasLength(1));
  });

  test('preserves Paseo structured attachment block order', () async {
    final (session, connection) = _createSession();
    addTearDown(session.dispose);

    await session.promptWithAttachments('  Fix the failure  ', const [
      TextAgentAttachment(
        title: 'Older chat',
        text: 'Prior conversation',
        contextKind: 'chat_history',
      ),
      TextAgentAttachment(title: 'Check logs', text: 'Assertion failed'),
    ]);

    final turn = connection.requests.singleWhere(
      (request) => request.$1 == 'turn/start',
    );
    final params = turn.$2! as Map<String, Object?>;
    expect(params['input'], [
      {
        'type': 'text',
        'text': 'Prior conversation',
        'text_elements': <Object?>[],
      },
      {'type': 'text', 'text': 'Fix the failure', 'text_elements': <Object?>[]},
      {
        'type': 'text',
        'text': 'Assertion failed',
        'text_elements': <Object?>[],
      },
    ]);
  });

  test(
    'normalizes reasoning and uses buffered text when final omits it',
    () async {
      final (session, connection) = _createSession();
      addTearDown(session.dispose);
      final events = <ProviderEvent>[];
      session.events.listen(events.add);

      connection.emit('item/reasoning/summaryTextDelta', {
        'itemId': 'reason-1',
        'delta': 'think',
      });
      connection.emit('item/completed', {
        'item': {'id': 'reason-1', 'type': 'reasoning'},
      });
      await _flush();

      expect(events.whereType<ReasoningDelta>().single.text, 'think');
      expect(events.whereType<ReasoningComplete>().single.fullText, 'think');
    },
  );

  test(
    'normalizes token usage and de-duplicates compaction channels',
    () async {
      final (session, connection) = _createSession();
      addTearDown(session.dispose);
      final events = <ProviderEvent>[];
      session.events.listen(events.add);
      await session.prompt('start thread');

      connection.emit('thread/tokenUsage/updated', {
        'threadId': 'thread',
        'tokenUsage': {
          'model_context_window': 200000,
          'last': {
            'inputTokens': 120,
            'cachedInputTokens': 30,
            'outputTokens': 45,
            'total_tokens': 42000,
          },
        },
      });
      connection.emit('item/started', {
        'item': {'id': 'compact-item', 'type': 'contextCompaction'},
      });
      connection.emit('item/completed', {
        'item': {'id': 'compact-item', 'type': 'contextCompaction'},
      });
      connection.emit('thread/compacted', {
        'threadId': 'thread',
        'turnId': 'turn-1',
      });
      connection.emit('thread/compacted', {
        'threadId': 'other-thread',
        'turnId': 'ignored',
      });
      await _flush();

      final usage = events.whereType<UsageUpdated>().single.usage;
      expect(usage.inputTokens, 120);
      expect(usage.cachedInputTokens, 30);
      expect(usage.outputTokens, 45);
      expect(usage.contextWindowMaxTokens, 200000);
      expect(usage.contextWindowUsedTokens, 42000);

      final compactions = events.whereType<CompactionUpdated>().toList();
      expect(compactions, hasLength(2));
      expect(compactions.first.status, CompactionStatus.loading);
      expect(compactions.last.status, CompactionStatus.completed);
      expect(compactions.map((event) => event.itemId).toSet(), {
        'compact-item',
      });

      connection.emit('thread/compacted', {
        'threadId': 'thread',
        'turnId': 'turn-2',
      });
      connection.emit('item/completed', {
        'item': {'id': 'second-item', 'type': 'context_compaction'},
      });
      await _flush();
      expect(events.whereType<CompactionUpdated>(), hasLength(3));
      expect(
        events.whereType<CompactionUpdated>().last.itemId,
        'compaction-turn-2',
      );
    },
  );

  test('maps command and file lifecycle items', () async {
    final (session, connection) = _createSession();
    addTearDown(session.dispose);
    final events = <ProviderEvent>[];
    session.events.listen(events.add);

    connection.emit('item/started', {
      'item': {
        'id': 'cmd',
        'type': 'commandExecution',
        'command': 'git status',
      },
    });
    connection.emit('item/completed', {
      'item': {
        'id': 'cmd',
        'type': 'commandExecution',
        'command': 'git status',
        'aggregatedOutput': 'clean',
        'exitCode': 0,
      },
    });
    connection.emit('item/started', {
      'item': {'id': 'edit', 'type': 'fileChange', 'path': 'lib/main.dart'},
    });
    connection.emit('item/completed', {
      'item': {
        'id': 'edit',
        'type': 'fileChange',
        'path': 'lib/main.dart',
        'diff': '+change',
        'status': 'failed',
      },
    });
    await _flush();

    final started = events.whereType<ToolCallStarted>().toList();
    final updated = events.whereType<ToolCallUpdated>().toList();
    expect(started.map((event) => event.toolName), ['shell', 'apply_patch']);
    expect(updated.first.status, ToolCallStatus.success);
    expect(updated.first.detail, isA<ShellDetail>());
    expect((updated.first.detail as ShellDetail).output, 'clean');
    expect(updated.last.status, ToolCallStatus.error);
    expect((updated.last.detail as EditDetail).diff, '+change');
  });

  test('round-trips command and file approval decisions', () async {
    final (session, connection) = _createSession();
    addTearDown(session.dispose);
    final permissions = <PermissionRequested>[];
    session.events
        .where((event) => event is PermissionRequested)
        .cast<PermissionRequested>()
        .listen(permissions.add);

    final commandResponse = connection
        .serverRequest('item/commandExecution/requestApproval', {
          'itemId': 'cmd',
          'threadId': 'thread',
          'turnId': 'turn',
          'command': 'git status',
          'cwd': '/workspace',
        });
    await _flush();
    expect(permissions.single.permissionId, 'permission-cmd');
    expect(permissions.single.toolName, 'CodexBash');
    expect(
      (permissions.single.detail as ShellDetail).command,
      'cd /workspace && git status',
    );
    await permissions.single.respond(PermissionDecision.allow);
    expect(await commandResponse, {'decision': 'accept'});

    final fileResponse = connection.serverRequest(
      'item/fileChange/requestApproval',
      {
        'itemId': 'edit',
        'threadId': 'thread',
        'turnId': 'turn',
        'reason': 'apply patch',
      },
    );
    await _flush();
    expect(permissions.last.toolName, 'CodexFileChange');
    await permissions.last.respond(PermissionDecision.deny);
    expect(await fileResponse, {'decision': 'decline'});
  });

  test('normalizes user questions and falls back to first options', () async {
    final (session, connection) = _createSession();
    addTearDown(session.dispose);
    final events = <ProviderEvent>[];
    session.events.listen(events.add);

    final response = connection.serverRequest('item/tool/requestUserInput', {
      'itemId': 'question-1',
      'threadId': 'thread',
      'turnId': 'turn',
      'questions': [
        {
          'id': 'color',
          'header': 'Color',
          'question': 'Pick a color',
          'options': [
            {'label': 'Blue', 'description': 'Calm'},
            {'label': 'Red'},
            {'label': '  '},
          ],
          'multiSelect': true,
          'isOther': true,
        },
        {'id': '', 'header': 'Invalid', 'question': 'Skipped'},
      ],
    });
    await _flush();

    final started = events.whereType<ToolCallStarted>().single;
    expect(started.itemId, 'question-1');
    expect(started.toolName, 'request_user_input');
    final detail = started.detail as GenericDetail;
    expect(detail.input['text'], 'Color: Pick a color\nOptions: Blue, Red');
    final questions = detail.input['questions']! as List<Object?>;
    expect(questions, hasLength(1));
    expect((questions.single as Map<String, Object?>)['multiSelect'], isTrue);

    final permission = events.whereType<PermissionRequested>().single;
    await permission.respond(PermissionDecision.allow);
    expect(await response, {
      'answers': {
        'color': {
          'answers': ['Blue'],
        },
      },
    });
    final completed = events.whereType<ToolCallUpdated>().single;
    expect(completed.status, ToolCallStatus.success);

    final aliasResponse = connection.serverRequest('tool/requestUserInput', {
      'itemId': 'question-2',
      'threadId': 'thread',
      'turnId': 'turn',
      'questions': <Object?>[],
    });
    await _flush();
    await events.whereType<PermissionRequested>().last.respond(
      PermissionDecision.deny,
      message: 'dismissed',
    );
    expect(await aliasResponse, {'answers': <String, Object?>{}});
    expect(
      events.whereType<ToolCallUpdated>().last.status,
      ToolCallStatus.error,
    );
  });

  test('handles MCP elicitation acceptance and safety declines', () async {
    final (session, connection) = _createSession();
    addTearDown(session.dispose);
    final permissions = <PermissionRequested>[];
    session.events
        .where((event) => event is PermissionRequested)
        .cast<PermissionRequested>()
        .listen(permissions.add);

    final accepted = connection.serverRequest('mcpServer/elicitation/request', {
      'threadId': 'thread',
      'turnId': null,
      'serverName': 'optional-form',
      'mode': 'form',
      'message': 'Optional fields',
      'requestedSchema': {'type': 'object', 'required': <Object?>[]},
    });
    await _flush();
    expect(permissions.single.permissionId, 'permission-mcp-700');
    expect(permissions.single.toolName, 'CodexMcpElicitation');
    await permissions.single.respond(PermissionDecision.allow);
    expect(await accepted, {
      'action': 'accept',
      'content': <String, Object?>{},
      '_meta': null,
    });

    expect(
      await connection.serverRequest('mcpServer/elicitation/request', {
        'threadId': 'thread',
        'serverName': 'link',
        'mode': 'url',
        'message': 'Open link',
        'url': 'https://example.test',
      }),
      {'action': 'decline', 'content': null, '_meta': null},
    );
    expect(
      await connection.serverRequest('mcpServer/elicitation/request', {
        'threadId': 'thread',
        'serverName': 'required-form',
        'mode': 'openai/form',
        'message': 'Required fields',
        'requestedSchema': {
          'required': ['token'],
        },
      }),
      {'action': 'decline', 'content': null, '_meta': null},
    );
    expect(permissions, hasLength(1));
  });

  test(
    'declines MCP prompts and rejects malformed interaction requests',
    () async {
      final (session, connection) = _createSession();
      addTearDown(session.dispose);
      final permissions = <PermissionRequested>[];
      session.events
          .where((event) => event is PermissionRequested)
          .cast<PermissionRequested>()
          .listen(permissions.add);

      final declined = connection
          .serverRequest('mcpServer/elicitation/request', {
            'threadId': 'thread',
            'turnId': 'turn',
            'serverName': 'optional-form',
            'mode': 'openai/form',
            'message': 'Optional fields',
          });
      await _flush();
      await permissions.single.respond(PermissionDecision.deny);
      expect(await declined, {
        'action': 'decline',
        'content': null,
        '_meta': null,
      });

      expect(
        () => connection.serverRequest('item/tool/requestUserInput', {
          'itemId': 'question',
          'threadId': 'thread',
          'turnId': 'turn',
        }),
        throwsFormatException,
      );
      expect(
        () => connection.serverRequest('mcpServer/elicitation/request', {
          'threadId': 'thread',
          'serverName': 'server',
          'mode': 'unsupported',
          'message': 'bad mode',
        }),
        throwsFormatException,
      );
      expect(
        () => connection.serverRequest('mcpServer/elicitation/request', {
          'threadId': 'thread',
          'serverName': 'server',
          'mode': 'form',
        }),
        throwsFormatException,
      );
    },
  );

  test('maps failed and interrupted turns', () async {
    final (session, connection) = _createSession();
    addTearDown(session.dispose);
    final failures = <TurnFailed>[];
    session.events
        .where((event) => event is TurnFailed)
        .cast<TurnFailed>()
        .listen(failures.add);

    connection.emit('turn/completed', {
      'turn': {
        'status': 'failed',
        'error': {'message': 'provider failed'},
      },
    });
    connection.emit('turn/completed', {
      'turn': {'status': 'interrupted'},
    });
    await _flush();

    expect(failures.map((event) => event.error), [
      'provider failed',
      'interrupted',
    ]);
  });

  test(
    'buffers early child notifications and routes nested subagent timelines',
    () async {
      final (session, connection) = _createSession();
      addTearDown(session.dispose);
      final events = <ProviderEvent>[];
      session.events.listen(events.add);
      await session.prompt('delegate');

      connection.emit('item/agentMessage/delta', {
        'threadId': 'child-thread',
        'itemId': 'child-message',
        'delta': 'early',
      });
      connection.emit('item/started', {
        'threadId': 'thread',
        'item': {
          'id': 'spawn-child',
          'type': 'collabAgentToolCall',
          'prompt': 'Inspect',
          'receiverThreadIds': ['child-thread'],
          'agentsStates': {
            'child-thread': {'status': 'pendingInit'},
          },
        },
      });
      connection.emit('item/completed', {
        'threadId': 'child-thread',
        'item': {
          'id': 'child-message',
          'type': 'agentMessage',
          'text': 'early result',
        },
      });
      connection.emit('item/started', {
        'threadId': 'child-thread',
        'item': {
          'id': 'spawn-grandchild',
          'type': 'collabAgentToolCall',
          'receiverThreadIds': ['grandchild-thread'],
        },
      });
      connection.emit('turn/completed', {
        'threadId': 'grandchild-thread',
        'turn': {'status': 'interrupted'},
      });
      await _flush();

      final upserts = events.whereType<ProviderSubagentUpserted>().toList();
      expect(upserts.map((event) => event.subagentId), [
        'child-thread',
        'grandchild-thread',
        'grandchild-thread',
      ]);
      expect(upserts.last.status, ProviderSubagentStatus.canceled);
      final childTimeline = events
          .whereType<ProviderSubagentTimelineChanged>()
          .where((event) => event.subagentId == 'child-thread')
          .toList();
      expect(childTimeline, hasLength(3));
      expect((childTimeline[0].item as AssistantMessageItem).text, 'early');
      expect(
        (childTimeline[1].item as AssistantMessageItem).text,
        'early result',
      );
      expect(childTimeline[2].item, isA<ToolCallItem>());
      expect(
        (childTimeline[2].item as ToolCallItem).detail,
        isA<SubAgentDetail>(),
      );
    },
  );

  test(
    'covers child activity, reasoning, compaction, and buffer bounds',
    () async {
      final (session, connection) = _createSession();
      addTearDown(session.dispose);
      final events = <ProviderEvent>[];
      session.events.listen(events.add);
      await session.prompt('delegate deeply');

      for (var thread = 0; thread < 33; thread++) {
        connection.emit('item/agentMessage/delta', {
          'threadId': 'pending-$thread',
          'itemId': 'message',
          'delta': 'x',
        });
      }
      for (var index = 0; index < 129; index++) {
        connection.emit('item/agentMessage/delta', {
          'threadId': 'overflow',
          'itemId': 'message-$index',
          'delta': 'x',
        });
      }

      connection.emit('item/started', {
        'threadId': 'thread',
        'item': {
          'id': 'activity',
          'type': 'subAgentActivity',
          'kind': 'started',
          'agentThreadId': 'child',
          'agentPath': '/root/research_one',
        },
      });
      connection.emit('item/reasoning/summaryTextDelta', {
        'threadId': 'child',
        'itemId': 'reason',
        'delta': 'thinking',
      });
      connection.emit('item/completed', {
        'threadId': 'child',
        'item': {
          'id': 'reason',
          'type': 'reasoning',
          'content': 'final thought',
        },
      });
      connection.emit('thread/compacted', {'threadId': 'child'});
      connection.emit('item/started', {
        'threadId': 'child',
        'item': {'id': 'search', 'type': 'webSearch', 'query': 'Paseo'},
      });
      connection.emit('turn/completed', {
        'threadId': 'child',
        'turn': {'status': 'failed'},
      });

      connection.emit('item/completed', {
        'threadId': 'thread',
        'item': {
          'id': 'completed-child',
          'type': 'collabAgentToolCall',
          'receiverThreadIds': ['done-child'],
          'agentsStates': {
            'done-child': {'status': 'completed'},
          },
        },
      });
      connection.emit('item/completed', {
        'threadId': 'thread',
        'item': {
          'id': 'failed-child',
          'type': 'CollabAgentToolCall',
          'receiverThreadIds': ['failed-child-thread'],
          'agentsStates': {
            'failed-child-thread': {'status': 'failed'},
          },
        },
      });
      await _flush();

      final child = events
          .whereType<ProviderSubagentTimelineChanged>()
          .where((event) => event.subagentId == 'child')
          .map((event) => event.item)
          .toList();
      expect(child.whereType<ReasoningItem>().first.complete, isFalse);
      expect(child.whereType<ReasoningItem>().last.text, 'final thought');
      expect(child.whereType<CompactionItem>(), hasLength(1));
      expect(child.whereType<ToolCallItem>().single.toolName, 'web_search');
      final upserts = events.whereType<ProviderSubagentUpserted>().toList();
      expect(
        upserts.firstWhere((event) => event.subagentId == 'child').title,
        'Research one',
      );
      expect(
        upserts.lastWhere((event) => event.subagentId == 'child').status,
        ProviderSubagentStatus.failed,
      );
      expect(
        upserts.singleWhere((event) => event.subagentId == 'done-child').status,
        ProviderSubagentStatus.completed,
      );
      expect(
        upserts
            .singleWhere((event) => event.subagentId == 'failed-child-thread')
            .status,
        ProviderSubagentStatus.failed,
      );
    },
  );

  test('rejects malformed approvals and closes once', () async {
    final (session, connection) = _createSession();
    final events = <ProviderEvent>[];
    final done = Completer<void>();
    session.events.listen(events.add, onDone: done.complete);

    expect(
      () => connection.serverRequest('item/commandExecution/requestApproval', {
        'itemId': 'missing-context',
      }),
      throwsFormatException,
    );
    await session.dispose();
    await session.dispose();
    await done.future;

    expect(connection.disposed, isTrue);
    expect(events.whereType<SessionExited>(), hasLength(1));
    expect(() => session.prompt('after close'), throwsStateError);
  });

  test('publishes process exit once and closes the event stream', () async {
    final (session, connection) = _createSession();
    final events = <ProviderEvent>[];
    final done = Completer<void>();
    session.events.listen(events.add, onDone: done.complete);

    connection.exit(19);
    connection.exit(20);
    await done.future;

    expect(events.whereType<SessionExited>(), hasLength(1));
    expect(events.whereType<SessionExited>().single.exitCode, 19);
    expect(() => session.prompt('after exit'), throwsStateError);
    await session.dispose();
  });
}
