import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/providers/paseo/codex_app_server_client.dart';
import 'package:agent_daemon/src/providers/paseo/jsonl_rpc_process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String fixturePath() {
  final parts = ['test', 'fixtures', 'codex_app_server_child.dart'];
  final packageRelative = p.joinAll([Directory.current.path, ...parts]);
  return File(packageRelative).existsSync()
      ? packageRelative
      : p.joinAll([Directory.current.path, 'packages', 'daemon', ...parts]);
}

Future<CodexAppServerClient> startClient({
  Map<String, String> environment = const {},
}) {
  return CodexAppServerClient.start(
    launch: JsonlRpcLaunch(
      command: Platform.resolvedExecutable,
      args: [fixturePath()],
      cwd: Directory.current.path,
      environment: environment,
    ),
  );
}

void main() {
  test('correlates JSON-RPC results including an explicit null', () async {
    final client = await startClient();
    addTearDown(client.dispose);

    final values = await Future.wait([
      client.request('echo', {'value': 1}),
      client.request('echo', {'value': 2}),
    ]);
    expect(values, [
      {'value': 1},
      {'value': 2},
    ]);
    expect(await client.request('null-result'), isNull);
  });

  test('maps structured and unknown errors', () async {
    final client = await startClient();
    addTearDown(client.dispose);

    await expectLater(
      client.request('fail'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'codex rejected the request',
        ),
      ),
    );
    await expectLater(
      client.request('unknown-fail'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Unknown error',
        ),
      ),
    );
  });

  test('delivers notifications and omits them after dispose', () async {
    final client = await startClient();
    final notifications = <(String, Object?)>[];
    final firstNotification = Completer<void>();
    client.setNotificationHandler((method, params) {
      notifications.add((method, params));
      firstNotification.complete();
    });

    client.notify('trigger-notification', {'turnId': 'turn-1'});
    await firstNotification.future;
    expect(notifications, hasLength(1));
    expect(notifications.single.$1, 'turn/completed');
    expect(notifications.single.$2, {'turnId': 'turn-1'});

    await client.dispose();
    client.notify('trigger-notification');
    expect(client.isClosed, isTrue);
  });

  test('answers server requests with handler results', () async {
    final client = await startClient();
    addTearDown(client.dispose);
    final result = Completer<Object?>();
    client.setRequestHandler('item/commandExecution/requestApproval', (
      params,
      id,
    ) {
      expect(id, 700);
      expect(params, {'command': 'git status'});
      return {'decision': 'accept'};
    });
    client.setNotificationHandler((method, params) {
      if (method == 'test/serverRequestResult') {
        result.complete(params);
      }
    });

    client.notify('trigger-request', {'command': 'git status'});

    expect(await result.future, {'decision': 'accept'});
  });

  test('answers unknown and throwing server handlers', () async {
    final client = await startClient();
    addTearDown(client.dispose);
    final results = <(String, Object?)>[];
    final firstReceived = Completer<void>();
    final received = Completer<void>();
    client.setNotificationHandler((method, params) {
      results.add((method, params));
      if (results.length == 1) {
        firstReceived.complete();
      }
      if (results.length == 2) {
        received.complete();
      }
    });

    client.notify('trigger-request');
    await firstReceived.future;
    client.setRequestHandler(
      'item/commandExecution/requestApproval',
      (_, _) => throw StateError('approval failed'),
    );
    client.notify('trigger-request');

    await received.future;
    expect(results.first.$1, 'test/serverRequestResult');
    expect(results.first.$2, isEmpty);
    expect(results.last.$1, 'test/serverRequestError');
    expect(results.last.$2, {'message': 'Bad state: approval failed'});
  });

  test('times out and rejects pending requests on process exit', () async {
    final client = await startClient();
    addTearDown(client.dispose);

    await expectLater(
      client.request('hang', null, const Duration(milliseconds: 50)),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Codex app-server request timed out for hang',
        ),
      ),
    );
    await expectLater(
      client.request('exit'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('app-server exploded'),
        ),
      ),
    );
    expect(client.isClosed, isTrue);
    await expectLater(client.request('echo'), throwsStateError);
  });

  test('dispose rejects an indefinitely pending request', () async {
    final client = await startClient();
    final pending = client.request('hang', null, null);
    final rejection = expectLater(
      pending,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Codex app-server client is closed',
        ),
      ),
    );

    await client.dispose();
    await rejection;
    await client.dispose();
  });

  test('fork and rollback validate typed lifecycle responses', () async {
    final client = await startClient();
    addTearDown(client.dispose);

    final forked = await client.forkThread(
      const CodexThreadForkParams(
        threadId: 'thread-1',
        cwd: 'C:/workspace',
        model: 'gpt-saved',
        serviceTier: 'fast',
        excludeTurns: false,
        persistExtendedHistory: true,
      ),
    );
    expect(forked.thread.id, 'fork-1');
    expect(forked.thread.sessionId, 'session-1');
    expect(forked.thread.forkedFromId, 'thread-1');
    expect(forked.thread.turns, isEmpty);
    expect(forked.modelProvider, 'openai');
    expect(forked.runtimeWorkspaceRoots, [Directory.current.path]);
    expect(forked.instructionSources, ['AGENTS.md']);
    expect(forked.reasoningEffort, 'high');

    final rolledBack = await client.rollbackThread(
      const CodexThreadRollbackParams(threadId: 'fork-1', numTurns: 2),
    );
    expect(rolledBack.thread.id, 'rollback-1');
  });

  test('typed lifecycle parsers reject incomplete responses', () {
    expect(() => CodexThreadSummary.fromJson({'id': 1}), throwsFormatException);
    expect(
      () => CodexThreadSummary.fromJson({'id': 'thread', 'turns': 'bad'}),
      throwsFormatException,
    );
    expect(
      () => CodexThreadForkResponse.fromJson({
        'thread': {'id': 'thread'},
      }),
      throwsFormatException,
    );
    expect(
      () => CodexThreadRollbackResponse.fromJson(<String, Object?>{}),
      throwsFormatException,
    );
  });

  test('fork params distinguish omitted and explicit nullable fields', () {
    expect(const CodexThreadForkParams(threadId: 'thread').toJson(), {
      'threadId': 'thread',
    });
    expect(
      const CodexThreadForkParams(
        threadId: 'thread',
        includeNullValues: true,
      ).toJson(),
      {
        'threadId': 'thread',
        'path': null,
        'model': null,
        'modelProvider': null,
        'serviceTier': null,
        'cwd': null,
        'runtimeWorkspaceRoots': null,
      },
    );
  });
}
