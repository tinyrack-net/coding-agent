@Timeout(Duration(seconds: 20))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:agent_daemon/src/cli/hub_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/hub/relationship_remote.dart';
import 'package:agent_daemon/src/server/daemon_config.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

const _connectedStatus = HubRelationshipStatus(
  state: HubConnectionState.connected,
  daemonId: 'daemon-1',
  hubOrigin: 'https://hub.example.test',
  scopes: ['hub.execution.*'],
  connectedAt: null,
  lastError: null,
);

void main() {
  test('prints stable JSON and human status output', () async {
    final output = StringBuffer();
    final code = await runHubCommand(
      options: const HubCommandOptions(
        action: HubCommandAction.status,
        json: true,
      ),
      environment: const {},
      request: (_, __) async => const HubCommandResult(
        status: HubRelationshipStatus(
          state: HubConnectionState.connected,
          daemonId: 'daemon-1',
          hubOrigin: 'https://hub.example.test',
          scopes: ['hub.execution.*'],
          connectedAt: '2026-07-27T00:00:00.000Z',
          lastError: null,
        ),
      ),
      writeOutput: output.write,
    );

    expect(code, 0);
    final decoded = jsonDecode(output.toString()) as List;
    expect(decoded.single, {
      'state': 'connected',
      'daemonId': 'daemon-1',
      'hub': 'https://hub.example.test',
      'scopes': 'hub.execution.*',
      'connectedAt': '2026-07-27T00:00:00.000Z',
      'error': null,
    });

    output.clear();
    await runHubCommand(
      options: const HubCommandOptions(action: HubCommandAction.disconnect),
      environment: const {},
      request: (_, __) async => const HubCommandResult(
        status: HubRelationshipStatus.notConnected(),
        warning: 'forced warning',
      ),
      writeOutput: output.write,
    );
    expect(output.toString(), startsWith('STATE'));
    expect(output.toString(), contains('not_connected'));
    expect(output.toString(), contains('forced warning'));
  });

  test('reports daemon request failures with exit code one', () async {
    final errors = StringBuffer();
    final code = await runHubCommand(
      options: const HubCommandOptions(action: HubCommandAction.status),
      environment: const {},
      request: (_, __) => Future.error(StateError('offline')),
      writeError: errors.write,
    );
    expect(code, 1);
    expect(errors.toString(), contains('offline'));
  });

  test('binary exposes the frozen Hub command help surface', () async {
    final library = await Isolate.resolvePackageUri(
      Uri.parse('package:agent_daemon/agent_daemon.dart'),
    );
    final packageRoot = File.fromUri(library!).parent.parent.path;
    final results = await Future.wait([
      for (final arguments in const [
        ['hub', '--help'],
        ['hub', 'connect', '--help'],
        ['hub', 'status', '--help'],
        ['hub', 'disconnect', '--help'],
      ])
        Process.run(Platform.resolvedExecutable, [
          'run',
          'agent_daemon:coding_agent',
          ...arguments,
        ], workingDirectory: packageRoot),
    ]);
    for (final result in results) {
      expect(result.exitCode, 0);
      expect(result.stdout, contains('Usage: coding-agent hub'));
      expect(result.stderr, isEmpty);
    }
  });

  test('direct-token connect uses positional URL and forwards host', () async {
    final home = Directory.systemTemp.createTempSync('hub-cli-direct-');
    addTearDown(() => home.deleteSync(recursive: true));
    final calls = <HubCommandOptions>[];
    var output = '';
    final code = await runHubCliCommand(
      arguments: [
        'connect',
        'https://hub.example.test',
        '--token=enrollment-token',
        '--host=tcp://daemon.example:7443?ssl=true&password=secret',
        '--json',
      ],
      environment: {'TINYRACK_HOME': home.path},
      request: (_, options) async {
        calls.add(options);
        return const HubCommandResult(status: _connectedStatus);
      },
      authorize: (_, __) async => fail('explicit token must skip browser auth'),
      writeOutput: (value) => output += value,
    );

    expect(code, 0);
    expect(calls, hasLength(1));
    expect(calls.single.action, HubCommandAction.connect);
    expect(calls.single.hubUrl, 'https://hub.example.test');
    expect(calls.single.token, 'enrollment-token');
    expect(
      calls.single.host,
      'tcp://daemon.example:7443?ssl=true&password=secret',
    );
    expect(jsonDecode(output), [
      {
        'state': 'connected',
        'daemonId': 'daemon-1',
        'hub': 'https://hub.example.test',
        'scopes': 'hub.execution.*',
        'connectedAt': null,
        'error': null,
      },
    ]);
  });

  test('tokenless connect authorizes only an unconnected daemon', () async {
    final home = Directory.systemTemp.createTempSync('hub-cli-browser-');
    addTearDown(() => home.deleteSync(recursive: true));
    final calls = <HubCommandOptions>[];
    final authorizations = <(String, String)>[];
    final repeatedName = List.filled(10, 'very-long-hostname').join();
    final longName = '  $repeatedName  ';
    final code = await runHubCliCommand(
      arguments: ['connect', 'https://hub.example.test'],
      environment: {'TINYRACK_HOME': home.path},
      request: (_, options) async {
        calls.add(options);
        return options.action == HubCommandAction.status
            ? const HubCommandResult(
                status: HubRelationshipStatus.notConnected(),
              )
            : const HubCommandResult(status: _connectedStatus);
      },
      authorize: (url, name) async {
        authorizations.add((url, name));
        return 'approved-enrollment-token';
      },
      displayName: () => longName,
      writeOutput: (_) {},
    );

    expect(code, 0);
    expect(calls.map((call) => call.action), [
      HubCommandAction.status,
      HubCommandAction.connect,
    ]);
    expect(calls.last.token, 'approved-enrollment-token');
    expect(authorizations.single.$1, 'https://hub.example.test');
    expect(authorizations.single.$2, repeatedName.substring(0, 100));

    calls.clear();
    var error = '';
    expect(
      await runHubCliCommand(
        arguments: ['connect', 'https://hub.example.test', '--json'],
        environment: {'TINYRACK_HOME': home.path},
        request: (_, options) async {
          calls.add(options);
          return const HubCommandResult(status: _connectedStatus);
        },
        authorize: (_, __) async => fail('connected daemon must reject auth'),
        writeError: (value) => error += value,
      ),
      1,
    );
    expect(calls, hasLength(1));
    expect(
      (jsonDecode(error) as Map)['error'],
      containsPair('message', 'This daemon already has a Hub relationship'),
    );
  });

  test('status and force disconnect preserve row schema and flags', () async {
    final home = Directory.systemTemp.createTempSync('hub-cli-actions-');
    addTearDown(() => home.deleteSync(recursive: true));
    final calls = <HubCommandOptions>[];
    var output = '';
    expect(
      await runHubCliCommand(
        arguments: ['status', '--host=remote:6868'],
        environment: {'TINYRACK_HOME': home.path},
        request: (_, options) async {
          calls.add(options);
          return const HubCommandResult(status: _connectedStatus);
        },
        writeOutput: (value) => output += value,
      ),
      0,
    );
    expect(output, startsWith('STATE'));
    expect(output, contains('https://hub.example.test'));
    expect(calls.single.host, 'remote:6868');

    calls.clear();
    output = '';
    expect(
      await runHubCliCommand(
        arguments: ['disconnect', '--force', '--json'],
        environment: {'TINYRACK_HOME': home.path},
        request: (_, options) async {
          calls.add(options);
          return const HubCommandResult(
            status: HubRelationshipStatus.notConnected(),
            warning: 'remote revocation pending',
          );
        },
        writeOutput: (value) => output += value,
      ),
      0,
    );
    expect(calls.single.force, isTrue);
    expect(
      (jsonDecode(output) as List).single,
      containsPair('warning', 'remote revocation pending'),
    );
  });

  test('Hub parser enforces frozen action-specific boundaries', () async {
    final home = Directory.systemTemp.createTempSync('hub-cli-syntax-');
    addTearDown(() => home.deleteSync(recursive: true));
    for (final arguments in const [
      <String>[],
      ['future'],
      ['connect'],
      ['connect', 'one', 'two'],
      ['status', 'unexpected'],
      ['status', '--force'],
      ['disconnect', '--token', 'invalid'],
      ['disconnect', '--host'],
    ]) {
      var error = '';
      expect(
        await runHubCliCommand(
          arguments: arguments,
          environment: {'TINYRACK_HOME': home.path},
          request: (_, __) async => fail('syntax must not reach daemon'),
          writeError: (value) => error += value,
        ),
        64,
        reason: '$arguments',
      );
      expect(error, contains('Usage: coding-agent hub'));
    }
  });

  test('connect, status, and force disconnect cross the live daemon', () async {
    final home = await Directory.systemTemp.createTemp('hub-command-test-');
    addTearDown(() => home.delete(recursive: true));
    final remote = _HubCommandRemote();
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: home.path),
      host: '127.0.0.1',
      port: 0,
      dataDir: home.path,
      relayConfig: const DaemonRelayConfig(
        enabled: false,
        endpoint: '127.0.0.1:1',
        publicEndpoint: '127.0.0.1:1',
        useTls: false,
        publicUseTls: false,
      ),
      hubRelationshipRemote: remote,
      log: (_) {},
    );
    addTearDown(handle.stop);
    final host = '127.0.0.1:${handle.server.port}';

    Future<Map<String, Object?>> command(List<String> arguments) async {
      var output = '';
      var error = '';
      final code = await runHubCliCommand(
        arguments: [...arguments, '--host', host, '--json'],
        environment: {'TINYRACK_HOME': home.path},
        writeOutput: (value) => output += value,
        writeError: (value) => error += value,
      );
      expect(code, 0, reason: error);
      return ((jsonDecode(output) as List).single as Map)
          .cast<String, Object?>();
    }

    final connected = await command([
      'connect',
      'https://hub.example.test',
      '--token',
      'token',
    ]);
    expect(connected['state'], 'connected');

    final status = await command(['status']);
    expect(status['daemonId'], connected['daemonId']);

    final disconnected = await command(['disconnect', '--force']);
    expect(disconnected['state'], 'not_connected');
    expect(
      disconnected['warning'],
      'Local Hub credential removed; remote revocation may remain pending.',
    );
  });
}

final class _HubCommandRemote implements HubRelationshipRemote {
  _HubCommandSocketConnection? connection;

  @override
  Future<HubEnrollmentResult> enroll(HubEnrollment input) async =>
      HubEnrollmentResult(
        daemonId: input.daemonId,
        scopes: input.scopes,
        webSocketUrl: 'wss://hub.example.test/socket',
      );

  @override
  HubSocketConnection openSocket(
    HubSocketCredentials input,
    HubSocketEvents events,
  ) {
    final value = _HubCommandSocketConnection();
    connection = value;
    events.connected(value.socket);
    return value;
  }

  @override
  Future<void> revoke(HubRevocation input) async {}
}

final class _HubCommandSocketConnection implements HubSocketConnection {
  final socket = _HubCommandSocket();

  @override
  Future<void> close() => socket.close();
}

final class _HubCommandSocket implements HubSocket {
  final controller = StreamController<Object>.broadcast();

  @override
  Stream<Object> get frames => controller.stream;

  @override
  void send(Object data) {}

  @override
  Future<void> close([int? code, String? reason]) => controller.close();
}
