import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

import 'support/fake_daemon_server.dart';

void main() {
  test(
    'probeDaemon returns the ServerHello on a successful handshake',
    () async {
      final server = FakeDaemonServer(
        daemonVersion: '0.2.0',
        protocolVersion: 3,
        pid: 4242,
        desktopManaged: true,
      );
      await server.start();
      addTearDown(server.stop);

      final hello = await probeDaemon('127.0.0.1', server.port);

      expect(hello, isNotNull);
      expect(hello!.daemonVersion, '0.2.0');
      expect(hello.protocolVersion, 3);
      expect(hello.pid, 4242);
      expect(hello.desktopManaged, isTrue);
    },
  );

  test('probeDaemon returns null when nothing is listening', () async {
    // Port 1 is a privileged/reserved port essentially guaranteed to have no
    // listener bound to it on loopback in a test environment.
    final hello = await probeDaemon(
      '127.0.0.1',
      1,
      timeout: const Duration(milliseconds: 300),
    );
    expect(hello, isNull);
  });

  test(
    'probeDaemon returns null when the server never answers hello',
    () async {
      final server = FakeDaemonServer(respondToHello: false);
      await server.start();
      addTearDown(server.stop);

      final hello = await probeDaemon(
        '127.0.0.1',
        server.port,
        timeout: const Duration(milliseconds: 300),
      );

      expect(hello, isNull);
    },
  );

  test(
    'probe and lifecycle request forward the daemon password token',
    () async {
      final server = FakeDaemonServer(requiredToken: 'secret');
      await server.start();
      addTearDown(server.stop);

      expect(await probeDaemon('127.0.0.1', server.port), isNull);
      expect(
        await probeDaemon('127.0.0.1', server.port, token: 'secret'),
        isNotNull,
      );
      expect(
        await sendLifecycleRequest(
          '127.0.0.1',
          server.port,
          MessageTypes.daemonShutdownRequest,
          token: 'secret',
        ),
        isTrue,
      );
    },
  );

  test('sendLifecycleRequest returns true on a non-error response', () async {
    final server = FakeDaemonServer();
    await server.start();
    addTearDown(server.stop);

    final ok = await sendLifecycleRequest(
      '127.0.0.1',
      server.port,
      MessageTypes.daemonShutdownRequest,
    );

    expect(ok, isTrue);
  });

  test(
    'sendLifecycleRequest returns false for an unhandled request type',
    () async {
      final server = FakeDaemonServer();
      await server.start();
      addTearDown(server.stop);

      final ok = await sendLifecycleRequest(
        '127.0.0.1',
        server.port,
        'some.unknown.request',
      );

      expect(ok, isFalse);
    },
  );

  test(
    'sendLifecycleRequest returns false when nothing is listening',
    () async {
      final ok = await sendLifecycleRequest(
        '127.0.0.1',
        1,
        MessageTypes.daemonShutdownRequest,
        timeout: const Duration(milliseconds: 300),
      );
      expect(ok, isFalse);
    },
  );
}
