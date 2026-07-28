import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/providers/paseo/jsonl_rpc_process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<JsonlRpcProcess> startProcess({
  void Function(String message, Object? error, String? line)? onWarning,
}) {
  return JsonlRpcProcess.start(
    launch: JsonlRpcLaunch(
      command: Platform.resolvedExecutable,
      args: [_fixturePath(), 'resolved-arg'],
      cwd: Directory.current.path,
      environment: const {'JSONL_RPC_TEST_VALUE': 'resolved-env'},
    ),
    onWarning: onWarning,
  );
}

String _fixturePath() {
  final packageRelative = p.join(
    Directory.current.path,
    'test',
    'fixtures',
    'jsonl_rpc_child.dart',
  );
  if (File(packageRelative).existsSync()) {
    return packageRelative;
  }
  return p.join(
    Directory.current.path,
    'packages',
    'daemon',
    'test',
    'fixtures',
    'jsonl_rpc_child.dart',
  );
}

Future<JsonlRpcExit> nextExit(JsonlRpcProcess transport) {
  final completer = Completer<JsonlRpcExit>();
  late final void Function() unsubscribe;
  unsubscribe = transport.onExit((exit) {
    unsubscribe();
    completer.complete(exit);
  });
  return completer.future;
}

void main() {
  test(
    'spawns a resolved command and correlates concurrent requests',
    () async {
      final transport = await startProcess();
      addTearDown(transport.close);

      final slow = transport.request({
        'type': 'echo',
        'value': 'first',
        'delayMs': 20,
      });
      final fast = transport.request({'type': 'echo', 'value': 'second'});

      expect(await Future.wait([slow, fast]), [
        {
          'value': 'first',
          'cwd': Directory.current.path,
          'env': 'resolved-env',
          'args': ['resolved-arg'],
        },
        {
          'value': 'second',
          'cwd': Directory.current.path,
          'env': 'resolved-env',
          'args': ['resolved-arg'],
        },
      ]);
    },
  );

  test('publishes complete LF-delimited JSON messages', () async {
    final warnings = <String>[];
    final transport = await startProcess(
      onWarning: (message, error, line) => warnings.add('$message:$line'),
    );
    addTearDown(transport.close);
    final messages = <Map<String, Object?>>[];
    transport.onMessage(messages.add);

    await transport.request({'type': 'emit'});

    expect(messages, [
      {'type': 'notice', 'text': 'a\u2028b'},
    ]);
    expect(warnings.single, contains('Ignoring non-JSON'));
  });

  test('rejects unsuccessful and default-error responses', () async {
    final transport = await startProcess();
    addTearDown(transport.close);

    await expectLater(
      transport.request({'type': 'fail'}),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'child rejected the request',
        ),
      ),
    );
    await expectLater(
      transport.request({'type': 'default-fail'}),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'JSONL RPC default-fail failed',
        ),
      ),
    );
  });

  test('includes buffered stderr when a request times out', () async {
    final transport = await startProcess();
    addTearDown(transport.close);
    await transport.request({'type': 'echo', 'value': 'ready'});

    await expectLater(
      transport.request({
        'type': 'hang',
      }, timeout: const Duration(milliseconds: 50)),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'JSONL RPC request timed out for hang\nstill waiting',
        ),
      ),
    );
  });

  test('null and non-positive timeouts wait for delayed responses', () async {
    final transport = await startProcess();
    addTearDown(transport.close);

    for (final timeout in <Duration?>[null, Duration.zero]) {
      await expectLater(
        transport.request({
          'type': 'echo',
          'value': 'slow',
          'delayMs': 80,
        }, timeout: timeout),
        completion(containsPair('value', 'slow')),
      );
    }
  });

  test('close rejects pending requests and future requests', () async {
    final transport = await startProcess();
    await transport.request({'type': 'echo', 'value': 'ready'});
    final pending = transport.request({'type': 'hang'}, timeout: null);

    final rejection = expectLater(
      pending,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'JSONL RPC process is closed',
        ),
      ),
    );
    await transport.close();
    await rejection;
    expect(transport.isClosed, isTrue);
    final closedRequest = transport.startRequest({'type': 'echo'});
    expect(closedRequest.id, isEmpty);
    await expectLater(closedRequest.response, throwsStateError);
    await expectLater(transport.request({'type': 'echo'}), throwsStateError);
  });

  test('rejects pending requests and publishes stderr on child exit', () async {
    final transport = await startProcess();
    final exit = nextExit(transport);

    await expectLater(
      transport.request({'type': 'exit'}),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('child exploded'),
        ),
      ),
    );
    final result = await exit;
    expect(result.code, 7);
    expect(result.error.message, contains('code 7 and signal null'));
    expect(result.error.message, contains('child exploded'));
  });

  test('bounds stderr to the final 8192 characters', () async {
    final transport = await startProcess();
    addTearDown(transport.close);
    await transport.request({'type': 'large-stderr'});

    await expectLater(
      transport.request({
        'type': 'hang',
      }, timeout: const Duration(milliseconds: 50)),
      throwsA(
        isA<StateError>()
            .having((error) => error.message, 'message', contains('tail'))
            .having(
              (error) => error.message.length,
              'bounded message length',
              lessThan(8300),
            ),
      ),
    );
  });

  test('ignores scalar messages and responses without pending ids', () async {
    Process? process;
    final transport = await JsonlRpcProcess.start(
      launch: const JsonlRpcLaunch(command: '', args: [], cwd: ''),
      spawn: (_) async {
        process = await Process.start(Platform.resolvedExecutable, [
          _fixturePath(),
        ], workingDirectory: Directory.current.path);
        return process!;
      },
    );
    addTearDown(transport.close);
    final messages = <Map<String, Object?>>[];
    transport.onMessage(messages.add);

    transport.send({'type': 'echo', 'id': 'unknown', 'value': 'ignored'});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(messages, isEmpty);
  });
}
