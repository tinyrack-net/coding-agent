import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/cli_daemon_client.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('normalizes frozen TCP, IPC, path, port, and host forms', () {
    expect(normalizeDaemonHost(''), isNull);
    expect(normalizeDaemonHost(' host '), isNull);
    expect(normalizeDaemonHost(' 6767 '), '127.0.0.1:6767');
    expect(normalizeDaemonHost('example.test:7000'), 'example.test:7000');
    expect(normalizeDaemonHost('/tmp/paseo.sock'), 'unix:///tmp/paseo.sock');
    expect(normalizeDaemonHost('~/paseo.sock'), 'unix://~/paseo.sock');
    expect(
      normalizeDaemonHost('unix:///tmp/paseo.sock'),
      'unix:///tmp/paseo.sock',
    );
    expect(normalizeDaemonHost(r'\\.\pipe\paseo'), r'pipe://\\.\pipe\paseo');
    expect(normalizeDaemonHost(r'C:\Users\paseo.sock'), isNull);
    expect(
      normalizeDaemonHost('tcp://[::1]:6767?ssl=true&password=a%20secret'),
      'tcp://[::1]:6767?ssl=true&password=a+secret',
    );
    expect(normalizeDaemonHost('tcp://localhost'), isNull);
  });

  test('resolves TCP and IPC daemon targets', () {
    final plain = resolveDaemonTarget('localhost:6767');
    expect(plain, isA<CliTcpDaemonTarget>());
    expect(plain.url, 'ws://localhost:6767/ws');

    final tls = resolveDaemonTarget('tcp://[::1]:6767?ssl=true');
    expect(tls, isA<CliTcpDaemonTarget>());
    expect(tls.url, 'wss://[::1]:6767/ws');

    final unix = resolveDaemonTarget('unix:///tmp/paseo.sock');
    expect(unix, isA<CliIpcDaemonTarget>());
    expect(unix.url, 'ws+unix:///tmp/paseo.sock:/ws');
    expect((unix as CliIpcDaemonTarget).socketPath, '/tmp/paseo.sock');

    final pipe = resolveDaemonTarget(r'\\.\pipe\paseo');
    expect(pipe.url, 'ws://localhost/ws');
    expect((pipe as CliIpcDaemonTarget).socketPath, r'\\.\pipe\paseo');

    expect(
      () => resolveDaemonTarget('unix://'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Invalid IPC daemon target: missing socket path',
        ),
      ),
    );
  });

  test('resolves password and connection errors with frozen precedence', () {
    expect(
      resolveDaemonPassword(
        'tcp://localhost:6767?password=uri',
        environment: const {'TINYRACK_PASSWORD': 'environment'},
      ),
      'uri',
    );
    expect(
      resolveDaemonPassword(
        'localhost:6767',
        environment: const {'TINYRACK_PASSWORD': ' environment '},
      ),
      ' environment ',
    );
    expect(
      resolveDaemonPassword('localhost:6767', environment: const {}),
      isNull,
    );

    final error = buildDaemonConnectionCommandError(
      host: 'remote.test:7000',
      error: StateError('offline'),
      environment: const {},
    );
    expect(error.code, 'DAEMON_NOT_RUNNING');
    expect(
      error.message,
      'Cannot connect to daemon at remote.test:7000: offline',
    );
    expect(error.details, 'Start the daemon with: coding-agent daemon start');
  });

  test('orders PID, configured TCP, and frozen default host candidates', () {
    final home = Directory.systemTemp.createTempSync('cli-daemon-client-');
    addTearDown(() => home.deleteSync(recursive: true));
    File(p.join(home.path, 'config.json')).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'daemon': {'listen': '127.0.0.1:7777'},
      }),
    );
    File(
      p.join(home.path, 'daemon.pid'),
    ).writeAsStringSync(jsonEncode({'sockPath': '/tmp/paseo.sock'}));

    expect(resolveDefaultDaemonHosts(home: home.path, environment: const {}), [
      'unix:///tmp/paseo.sock',
      '127.0.0.1:7777',
      'localhost:6767',
    ]);
    expect(
      resolveDaemonHostCandidates(
        host: 'explicit.test:7000',
        home: home.path,
        environment: const {'TINYRACK_HOST': 'environment.test:7001'},
      ),
      ['explicit.test:7000'],
    );
    expect(
      resolveDaemonHostCandidates(
        home: home.path,
        environment: const {'TINYRACK_HOST': 'environment.test:7001'},
      ),
      ['environment.test:7001'],
    );
  });

  test('uses only the frozen default for an unconfigured home', () {
    final home = Directory.systemTemp.createTempSync('cli-daemon-default-');
    addTearDown(() => home.deleteSync(recursive: true));

    expect(resolveDefaultDaemonHosts(home: home.path, environment: const {}), [
      'localhost:6767',
    ]);
    expect(
      resolveDefaultDaemonHost(home: home.path, environment: const {}),
      defaultCliDaemonHost,
    );
    expect(
      getDaemonHost(home: home.path, environment: const {}),
      defaultCliDaemonHost,
    );
    expect(defaultCliDaemonConnectTimeout, const Duration(seconds: 15));
  });

  test('resolves agent IDs with frozen match precedence', () {
    const agents = [
      CliAgentIdentity(id: 'abc-111', title: 'First Agent'),
      CliAgentIdentity(id: 'abc-222', title: 'Second Agent'),
      CliAgentIdentity(id: 'xyz-333', title: 'ABC'),
    ];

    expect(resolveAgentId('abc-111', agents), 'abc-111');
    expect(resolveAgentId('XYZ', agents), 'xyz-333');
    expect(resolveAgentId('second agent', agents), 'abc-222');
    expect(resolveAgentId('First', agents), 'abc-111');
    expect(resolveAgentId('abc', agents), 'xyz-333');
    expect(resolveAgentId('missing', agents), isNull);
    expect(resolveAgentId('', agents), isNull);
  });
}
