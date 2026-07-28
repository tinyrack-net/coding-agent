import 'package:agent_daemon/src/providers/paseo/codex_agent_client.dart';
import 'package:agent_daemon/src/providers/paseo/codex_app_server_client.dart';
import 'package:agent_daemon/src/providers/paseo/jsonl_rpc_process.dart';
import 'package:agent_daemon/src/providers/paseo/provider_launch_config.dart';
import 'package:agent_daemon/src/providers/agent_client.dart';
import 'package:agent_daemon/src/providers/agent_session.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';
import 'dart:io';

final class _ClientConnection implements CodexAppServerConnection {
  final requests = <(String, Object?, Duration?)>[];
  CodexAppServerNotificationHandler? notifications;
  var disposed = false;

  @override
  bool get isClosed => disposed;

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<CodexThreadForkResponse> forkThread(CodexThreadForkParams params) {
    throw UnimplementedError();
  }

  @override
  void Function() onExit(void Function(JsonlRpcExit exit) handler) => () {};

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
      'thread/loaded/list' => {
        'data': ['resume-id'],
      },
      'thread/read' => {
        'thread': {
          'turns': [
            {
              'items': [
                {'id': 'history', 'type': 'agentMessage', 'text': 'restored'},
              ],
            },
          ],
        },
      },
      'thread/list' => {
        'data': [
          {
            'id': 'thread-1',
            'cwd': 'C:/workspace',
            'name': 'Named thread',
            'preview': 'First prompt',
            'createdAt': 10,
            'updatedAt': 20,
          },
          {
            'id': 'thread-2',
            'cwd': 'C:/other',
            'name': '',
            'preview': 'Other prompt',
            'createdAt': 30,
          },
        ],
      },
      _ => <String, Object?>{},
    };
  }

  @override
  Future<CodexThreadRollbackResponse> rollbackThread(
    CodexThreadRollbackParams params,
  ) {
    throw UnimplementedError();
  }

  @override
  void setNotificationHandler(CodexAppServerNotificationHandler handler) {
    notifications = handler;
  }

  @override
  void setRequestHandler(String method, CodexAppServerRequestHandler handler) {}
}

void main() {
  test('lists model-scoped draft features without launching Codex', () async {
    final client = CodexAgentClient(
      resolveExecutable: () async => throw StateError('must not probe'),
    );

    final features = await client.listFeatures(
      const ListCommandsDraftConfig(
        provider: 'codex',
        cwd: '/repo',
        model: 'gpt-5',
        featureValues: {'plan_mode': true},
      ),
    );

    expect(features.map((feature) => feature.id), ['fast_mode', 'plan_mode']);
    expect((features.last as AgentFeatureToggle).value, isTrue);
  });

  test('lists importable Codex threads from cheap thread metadata', () async {
    final connection = _ClientConnection();
    JsonlRpcLaunch? capturedLaunch;
    final client = CodexAgentClient(
      resolveExecutable: () async => 'codex',
      startConnection: (launch) async {
        capturedLaunch = launch;
        return connection;
      },
    );

    final sessions = await client.listImportableSessions(
      const ListImportableSessionsOptions(limit: 1, cwd: 'C:/workspace'),
    );

    expect(capturedLaunch?.args, ['app-server']);
    expect(sessions, hasLength(1));
    expect(sessions.single.providerHandleId, 'thread-1');
    expect(sessions.single.title, 'Named thread');
    expect(sessions.single.firstPromptPreview, 'First prompt');
    expect(
      sessions.single.lastActivityAt,
      DateTime.fromMillisecondsSinceEpoch(20000, isUtc: true),
    );
    expect(connection.requests.map((request) => request.$1), [
      'initialize',
      'thread/list',
    ]);
    expect(connection.requests.last.$2, {'limit': 50, 'cwd': 'C:/workspace'});
    expect(connection.disposed, isTrue);
  });

  test('rejects import listing when Codex is unavailable', () async {
    final client = CodexAgentClient(resolveExecutable: () async => null);
    await expectLater(
      client.listImportableSessions(),
      throwsA(isA<StateError>()),
    );
  });

  test('resolves Codex and launches app-server with cwd and env', () async {
    final connection = _ClientConnection();
    JsonlRpcLaunch? capturedLaunch;
    final client = CodexAgentClient(
      resolveExecutable: () async => 'C:/bin/codex.exe',
      environment: const {'CODEX_HOME': 'C:/codex-home'},
      startConnection: (launch) async {
        capturedLaunch = launch;
        return connection;
      },
    );

    final session = await client.createSession(
      cwd: 'C:/workspace',
      model: 'gpt-5.4',
      mode: AgentMode.normal,
      sessionId: 'resume-id',
    );
    addTearDown(session.dispose);

    expect(capturedLaunch?.command, 'C:/bin/codex.exe');
    expect(capturedLaunch?.args, ['app-server']);
    expect(capturedLaunch?.cwd, 'C:/workspace');
    expect(
      capturedLaunch?.environment,
      containsPair('CODEX_HOME', 'C:/codex-home'),
    );
    expect(capturedLaunch?.environment, containsPair('PATH', isNotEmpty));
    expect(capturedLaunch?.includeParentEnvironment, isFalse);
    expect(connection.requests.map((request) => request.$1), [
      'initialize',
      'thread/loaded/list',
      'thread/read',
    ]);
    expect(session, isA<HistoryRestoringAgentSession>());
    expect(
      ((session as HistoryRestoringAgentSession).restoredHistory!.single
              as AssistantMessageItem)
          .text,
      'restored',
    );
  });

  test('applies provider command prefix and runtime environment', () async {
    final connection = _ClientConnection();
    JsonlRpcLaunch? capturedLaunch;
    final client = CodexAgentClient(
      runtimeSettings: ProviderRuntimeSettings(
        command: ProviderCommand.replace([
          Platform.resolvedExecutable,
          'codex-wrapper',
        ]),
        environment: const {'CODEX_RUNTIME': 'configured'},
      ),
      startConnection: (launch) async {
        capturedLaunch = launch;
        return connection;
      },
    );

    final session = await client.createSession(
      cwd: 'C:/workspace',
      model: 'gpt-5.4',
      mode: AgentMode.normal,
    );
    addTearDown(session.dispose);

    expect(capturedLaunch?.command, Platform.resolvedExecutable);
    expect(capturedLaunch?.args, ['codex-wrapper', 'app-server']);
    expect(
      capturedLaunch?.environment,
      containsPair('CODEX_RUNTIME', 'configured'),
    );
  });

  test('maps legacy modes to Paseo Codex modes on thread start', () async {
    for (final entry in {
      AgentMode.plan: ('on-request', 'read-only', null),
      AgentMode.normal: ('on-request', 'workspace-write', 'auto_review'),
      AgentMode.fullAccess: ('never', 'danger-full-access', null),
    }.entries) {
      final connection = _ThreadStartingConnection();
      final client = CodexAgentClient(
        resolveExecutable: () async => 'codex',
        startConnection: (_) async => connection,
      );
      final session = await client.createSession(
        cwd: 'C:/workspace',
        model: 'gpt',
        mode: entry.key,
      );
      await session.prompt('go');
      await session.dispose();

      final params =
          connection.requests
                  .singleWhere((request) => request.$1 == 'thread/start')
                  .$2
              as Map;
      expect(params['approvalPolicy'], entry.value.$1);
      expect(params['sandbox'], entry.value.$2);
      expect(params['approvalsReviewer'], entry.value.$3);
    }
  });

  test('forwards system prompt as Codex developer instructions', () async {
    final connection = _ThreadStartingConnection();
    final client = CodexAgentClient(
      resolveExecutable: () async => 'codex',
      startConnection: (_) async => connection,
    );
    final session = await client.createSession(
      cwd: 'C:/workspace',
      model: 'gpt',
      mode: AgentMode.normal,
      systemPrompt: 'Voice instructions',
    );
    await session.prompt('go');
    await session.dispose();

    final params =
        connection.requests
                .singleWhere((request) => request.$1 == 'thread/start')
                .$2
            as Map<String, Object?>;
    expect(params['developerInstructions'], 'Voice instructions');
  });

  test('uses exact Paseo mode and thinking option when supplied', () async {
    final connection = _ThreadStartingConnection();
    final client = CodexAgentClient(
      resolveExecutable: () async => 'codex',
      startConnection: (_) async => connection,
    );
    final session = await client.createSession(
      cwd: 'C:/workspace',
      model: 'gpt-5.4',
      mode: AgentMode.normal,
      modeId: 'full-access',
      thinkingOptionId: 'high',
    );
    await session.prompt('go');
    await session.dispose();

    final params =
        connection.requests
                .singleWhere((request) => request.$1 == 'turn/start')
                .$2
            as Map;
    expect(params['approvalPolicy'], 'never');
    expect(params['sandboxPolicy'], {'type': 'dangerFullAccess'});
    expect(params['effort'], 'high');
  });

  test('rejects a missing executable without starting a process', () async {
    var started = false;
    final client = CodexAgentClient(
      resolveExecutable: () async => null,
      startConnection: (_) async {
        started = true;
        return _ClientConnection();
      },
    );

    await expectLater(
      client.createSession(
        cwd: 'C:/workspace',
        model: 'gpt',
        mode: AgentMode.normal,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('Codex CLI is not installed'),
        ),
      ),
    );
    expect(started, isFalse);
  });

  test('disposes a started process when initialize fails', () async {
    final connection = _FailingConnection();
    final client = CodexAgentClient(
      resolveExecutable: () async => 'codex',
      startConnection: (_) async => connection,
    );

    await expectLater(
      client.createSession(
        cwd: 'C:/workspace',
        model: 'gpt',
        mode: AgentMode.normal,
      ),
      throwsA(isA<StateError>()),
    );
    expect(connection.disposed, isTrue);
  });
}

final class _ThreadStartingConnection extends _ClientConnection {
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
        'config': {'modelReasoningEffort': 'high'},
      },
      'thread/start' => {
        'thread': {'id': 'thread'},
      },
      'turn/start' => <String, Object?>{},
      _ => <String, Object?>{},
    };
  }
}

final class _FailingConnection extends _ClientConnection {
  @override
  Future<Object?> request(String method, [Object? params, Duration? timeout]) {
    throw StateError('initialize failed');
  }
}
