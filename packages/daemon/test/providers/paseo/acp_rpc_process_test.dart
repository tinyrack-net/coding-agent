import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/providers/paseo/acp_rpc_process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String fixturePath() {
  final local = p.join(
    Directory.current.path,
    'test',
    'fixtures',
    'acp_rpc_child.dart',
  );
  if (File(local).existsSync()) return local;
  return p.join(
    Directory.current.path,
    'packages',
    'daemon',
    'test',
    'fixtures',
    'acp_rpc_child.dart',
  );
}

Future<AcpRpcProcess> startProcess() => AcpRpcProcess.start(
  launch: AcpRpcProcessLaunch(
    command: Platform.resolvedExecutable,
    args: [fixturePath()],
    cwd: Directory.current.path,
  ),
  onIncoming: (_, _) async => null,
);

Future<AcpRpcExit> nextExit(AcpRpcProcess transport) {
  final completer = Completer<AcpRpcExit>();
  late final void Function() unsubscribe;
  unsubscribe = transport.onExit((exit) {
    unsubscribe();
    completer.complete(exit);
  });
  return completer.future;
}

void main() {
  test(
    'bounded control RPC times out while no-timeout waits for summary',
    () async {
      final transport = await startProcess();
      addTearDown(transport.close);

      await expectLater(
        transport.request('echo', const {
          'value': 'too-late',
          'delayMs': 80,
        }, timeout: const Duration(milliseconds: 30)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('request timed out for echo'),
          ),
        ),
      );

      await expectLater(
        transport.request('echo', const {
          'value': 'summary',
          'delayMs': 80,
        }, timeout: acpRpcNoTimeout),
        completion({'value': 'summary'}),
      );
    },
  );

  test('no-timeout request still rejects when the session closes', () async {
    final transport = await startProcess();
    final pending = transport.request(
      'hang',
      const {},
      timeout: acpRpcNoTimeout,
    );
    final rejection = expectLater(
      pending,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'ACP process is closed',
        ),
      ),
    );

    await transport.close();
    await rejection;
  });

  test('no-timeout request still rejects when the provider exits', () async {
    final transport = await startProcess();
    final exit = nextExit(transport);

    await expectLater(
      transport.request('exit', const {}, timeout: acpRpcNoTimeout),
      throwsA(
        isA<StateError>()
            .having((error) => error.message, 'message', contains('code 7'))
            .having(
              (error) => error.message,
              'stderr',
              contains('provider exited'),
            ),
      ),
    );
    expect((await exit).code, 7);
  });
}
