import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/providers/paseo/codex_app_server_client.dart';
import 'package:agent_daemon/src/providers/paseo/codex_session_runtime.dart';
import 'package:agent_daemon/src/providers/paseo/jsonl_rpc_process.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _fixturePath() {
  final parts = ['test', 'fixtures', 'codex_app_server_child.dart'];
  final packageRelative = p.joinAll([Directory.current.path, ...parts]);
  return File(packageRelative).existsSync()
      ? packageRelative
      : p.joinAll([Directory.current.path, 'packages', 'daemon', ...parts]);
}

Future<CodexAppServerClient> _startClient({
  Map<String, String> environment = const {},
}) {
  return CodexAppServerClient.start(
    launch: JsonlRpcLaunch(
      command: Platform.resolvedExecutable,
      args: [_fixturePath()],
      cwd: Directory.current.path,
      environment: environment,
    ),
  );
}

Map<String, Object?> _record(Object? value) {
  return (value as Map).cast<String, Object?>();
}

void main() {
  test(
    'normalizes Codex output schemas recursively and rejects open objects',
    () {
      expect(
        normalizeCodexOutputSchema({
          'type': 'object',
          'properties': {
            'answer': {'type': 'string'},
            'nested': {
              'type': 'object',
              'properties': {
                'count': {'type': 'integer'},
              },
            },
          },
        }),
        {
          'type': 'object',
          'properties': {
            'answer': {'type': 'string'},
            'nested': {
              'type': 'object',
              'properties': {
                'count': {'type': 'integer'},
              },
              'additionalProperties': false,
              'required': ['count'],
            },
          },
          'additionalProperties': false,
          'required': ['answer', 'nested'],
        },
      );
      expect(
        () => normalizeCodexOutputSchema({
          'type': 'object',
          'additionalProperties': true,
        }),
        throwsStateError,
      );
      expect(
        () => normalizeCodexOutputSchema({'type': 'string'}),
        throwsStateError,
      );
    },
  );

  test('live mode, model, and thinking changes affect the next turn', () async {
    final client = await _startClient();
    final runtime = CodexSessionRuntime(
      client: client,
      config: CodexRuntimeConfig(
        cwd: Directory.current.path,
        modeId: 'auto-review',
      ),
    );
    addTearDown(runtime.close);
    final requests = <Map<String, Object?>>[];
    runtime.onNotification((method, params) {
      if (method == 'test/request') requests.add(_record(params));
    });
    runtime
      ..setMode('read-only')
      ..setModel(' gpt-live ')
      ..setThinkingOption(' medium ');
    expect(runtime.modeId, 'read-only');
    expect(runtime.model, 'gpt-live');
    expect(runtime.thinkingOptionId, 'medium');
    await runtime.startTurn('configured');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final turn = requests.firstWhere(
      (request) => request['method'] == 'turn/start',
    );
    final params = turn['params'] as Map;
    expect(params['model'], 'gpt-live');
    expect(params['effort'], 'medium');
    expect(params['approvalPolicy'], 'on-request');
    expect(() => runtime.setMode('invalid'), throwsArgumentError);
  });

  test('initializes with the non-originating Codex client identity', () async {
    final client = await _startClient();
    final runtime = CodexSessionRuntime(
      client: client,
      config: CodexRuntimeConfig(cwd: Directory.current.path, modeId: 'auto'),
    );
    addTearDown(runtime.close);
    final requests = <Map<String, Object?>>[];
    final initialized = Completer<void>();
    runtime.onNotification((method, params) {
      if (method != 'test/request') return;
      final request = _record(params);
      requests.add(request);
      if (request['method'] == 'initialized') {
        initialized.complete();
      }
    });

    await runtime.connect();
    await initialized.future;
    await runtime.connect();

    expect(requests.where((request) => request['method'] == 'initialize'), [
      {'method': 'initialize', 'params': codexInitializeParams},
    ]);
    expect(runtime.isConnected, isTrue);
  });

  test('starts a thread from saved defaults and sends an exact turn', () async {
    final client = await _startClient();
    final runtime = CodexSessionRuntime(
      client: client,
      config: CodexRuntimeConfig(
        cwd: Directory.current.path,
        modeId: 'auto-review',
        systemPrompt: '  system  ',
        daemonAppendSystemPrompt: ' daemon ',
        innerConfig: const {
          'mcp_servers': {
            'tinyrack': {'url': 'http://localhost'},
          },
        },
        serviceTier: 'fast',
        ephemeral: true,
      ),
    );
    addTearDown(runtime.close);
    final requests = <Map<String, Object?>>[];
    runtime.onNotification((method, params) {
      if (method == 'test/request') requests.add(_record(params));
    });

    await runtime.startTurn('Implement this');
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(runtime.threadId, 'thread-1');
    expect(runtime.turnId, 'turn-1');
    expect(runtime.model, 'gpt-saved');
    expect(runtime.thinkingOptionId, 'high');
    final start = requests.singleWhere(
      (request) => request['method'] == 'thread/start',
    );
    expect(_record(start['params']), {
      'model': 'gpt-saved',
      'cwd': Directory.current.path,
      'approvalPolicy': 'on-request',
      'sandbox': 'workspace-write',
      'developerInstructions': 'system\n\ndaemon',
      'config': {
        'mcp_servers': {
          'tinyrack': {'url': 'http://localhost'},
        },
      },
      'ephemeral': true,
      'approvalsReviewer': 'auto_review',
    });
    final turn = requests.singleWhere(
      (request) => request['method'] == 'turn/start',
    );
    expect(_record(turn['params']), {
      'threadId': 'thread-1',
      'input': [
        {
          'type': 'text',
          'text': 'Implement this',
          'text_elements': <Object?>[],
        },
      ],
      'approvalPolicy': 'on-request',
      'sandboxPolicy': {'type': 'workspaceWrite', 'networkAccess': false},
      'model': 'gpt-saved',
      'effort': 'high',
      'serviceTier': 'fast',
      'cwd': Directory.current.path,
      'developerInstructions': 'system\n\ndaemon',
      'config': {
        'mcp_servers': {
          'tinyrack': {'url': 'http://localhost'},
        },
      },
      'approvalsReviewer': 'auto_review',
    });
  });

  test('resumes only when a persisted thread is not already loaded', () async {
    final client = await _startClient();
    final runtime = CodexSessionRuntime(
      client: client,
      config: CodexRuntimeConfig(
        cwd: Directory.current.path,
        modeId: 'auto',
        systemPrompt: 'resume system',
        innerConfig: const {'feature': true},
      ),
      resumeThreadId: 'resume-thread',
    );
    addTearDown(runtime.close);
    final requests = <Map<String, Object?>>[];
    runtime.onNotification((method, params) {
      if (method == 'test/request') requests.add(_record(params));
    });

    await runtime.connect();

    expect(runtime.threadId, 'resume-thread');
    final resume = requests.singleWhere(
      (request) => request['method'] == 'thread/resume',
    );
    expect(_record(resume['params']), {
      'threadId': 'resume-thread',
      'developerInstructions': 'resume system',
      'config': {'feature': true},
    });
    final read = requests.singleWhere(
      (request) => request['method'] == 'thread/read',
    );
    expect(_record(read['params']), {
      'threadId': 'resume-thread',
      'includeTurns': true,
    });
    expect(runtime.restoredHistory, hasLength(2));
    expect(runtime.restoredHistory?.first, isA<UserMessageItem>());
    expect(
      (runtime.restoredHistory?.last as AssistantMessageItem).text,
      'persisted answer',
    );
  });

  test('does not resume a thread already loaded by app-server', () async {
    final client = await _startClient(
      environment: const {'CODEX_FIXTURE_THREAD_LOADED': 'true'},
    );
    final runtime = CodexSessionRuntime(
      client: client,
      config: CodexRuntimeConfig(cwd: Directory.current.path, modeId: 'auto'),
      resumeThreadId: 'resume-thread',
    );
    addTearDown(runtime.close);
    final methods = <String>[];
    runtime.onNotification((method, params) {
      if (method == 'test/request') {
        methods.add(_record(params)['method']! as String);
      }
    });

    await runtime.connect();

    expect(methods, contains('thread/loaded/list'));
    expect(methods, isNot(contains('thread/resume')));
  });

  test(
    'recursively restores provider-managed child thread histories',
    () async {
      final client = await _startClient(
        environment: const {'CODEX_FIXTURE_SUBAGENTS': 'true'},
      );
      final runtime = CodexSessionRuntime(
        client: client,
        config: CodexRuntimeConfig(cwd: Directory.current.path, modeId: 'auto'),
        resumeThreadId: 'resume-thread',
      );
      addTearDown(runtime.close);
      final requests = <Map<String, Object?>>[];
      runtime.onNotification((method, params) {
        if (method == 'test/request') requests.add(_record(params));
      });

      await runtime.connect();

      expect(runtime.restoredHistory, hasLength(1));
      expect(runtime.restoredProviderSubagents.map((child) => child.id), [
        'child-thread',
        'grandchild-thread',
      ]);
      expect(
        (runtime.restoredProviderSubagents.first.timeline.first
                as AssistantMessageItem)
            .text,
        'nested answer',
      );
      expect(
        (runtime.restoredProviderSubagents.last.timeline.single
                as AssistantMessageItem)
            .text,
        'deep answer',
      );
      expect(
        requests
            .where((request) => request['method'] == 'thread/read')
            .map((request) => _record(request['params'])['threadId']),
        ['resume-thread', 'child-thread', 'grandchild-thread'],
      );
    },
  );

  test('falls back from config APIs to the model catalog', () async {
    final client = await _startClient(
      environment: const {'CODEX_FIXTURE_CONFIG_MODE': 'model-list'},
    );
    final runtime = CodexSessionRuntime(
      client: client,
      config: CodexRuntimeConfig(
        cwd: Directory.current.path,
        modeId: 'full-access',
      ),
    );
    addTearDown(runtime.close);
    final requests = <Map<String, Object?>>[];
    runtime.onNotification((method, params) {
      if (method == 'test/request') requests.add(_record(params));
    });

    await runtime.startTurn('ship');

    expect(runtime.model, 'gpt-fallback');
    expect(runtime.thinkingOptionId, 'low');
    final turn = requests.singleWhere(
      (request) => request['method'] == 'turn/start',
    );
    expect(_record(turn['params'])['sandboxPolicy'], {
      'type': 'dangerFullAccess',
    });
    expect(_record(turn['params'])['approvalPolicy'], 'never');
  });

  test(
    'interrupt requires thread and turn then clears completed turn',
    () async {
      final client = await _startClient();
      final runtime = CodexSessionRuntime(
        client: client,
        config: CodexRuntimeConfig(cwd: Directory.current.path, modeId: 'auto'),
      );
      addTearDown(runtime.close);

      await expectLater(runtime.interrupt(), throwsStateError);
      await runtime.startTurn('wait');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(runtime.turnId, 'turn-1');

      await runtime.interrupt();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(runtime.turnId, isNull);
    },
  );

  test('forks and rolls back the active thread non-destructively', () async {
    final client = await _startClient();
    final runtime = CodexSessionRuntime(
      client: client,
      config: CodexRuntimeConfig(
        cwd: Directory.current.path,
        modeId: 'auto',
        model: 'gpt-saved',
        thinkingOptionId: 'default',
      ),
    );
    addTearDown(runtime.close);
    await runtime.startTurn('first');

    final forked = await runtime.fork();
    expect(forked.thread.id, 'fork-1');
    final rolledBack = await runtime.rollback(
      threadId: forked.thread.id,
      numTurns: 1,
    );
    expect(rolledBack.thread.id, 'rollback-1');
    expect(runtime.threadId, 'rollback-1');
    expect(runtime.turnId, isNull);
  });

  test('rejects invalid modes and missing interrupt turn', () async {
    final invalidClient = await _startClient();
    expect(
      () => CodexSessionRuntime(
        client: invalidClient,
        config: CodexRuntimeConfig(
          cwd: Directory.current.path,
          modeId: 'invalid',
        ),
      ),
      throwsArgumentError,
    );
    await invalidClient.dispose();

    final client = await _startClient(
      environment: const {'CODEX_FIXTURE_THREAD_LOADED': 'true'},
    );
    final runtime = CodexSessionRuntime(
      client: client,
      config: CodexRuntimeConfig(cwd: Directory.current.path, modeId: 'auto'),
      resumeThreadId: 'resume-thread',
    );
    addTearDown(runtime.close);
    await runtime.connect();
    await expectLater(runtime.interrupt(), throwsStateError);
  });
}
