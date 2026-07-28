@Timeout(Duration(seconds: 20))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/cli/hub_command.dart';
import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/hub/relationship_remote.dart';
import 'package:agent_daemon/src/server/daemon_config.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';

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
    final decoded = jsonDecode(output.toString()) as Map<String, dynamic>;
    expect(decoded['status'], containsPair('state', 'connected'));

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
    expect(output.toString(), contains('State: not_connected'));
    expect(output.toString(), contains('Warning: forced warning'));
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
    final config = _runtimeConfig(home.path, handle.server.port);

    final connected = await requestRunningDaemonHubManagement(
      config,
      const HubCommandOptions(
        action: HubCommandAction.connect,
        hubUrl: 'https://hub.example.test',
        token: 'token',
      ),
    );
    expect(connected.status.state, HubConnectionState.connected);

    final status = await requestRunningDaemonHubManagement(
      config,
      const HubCommandOptions(action: HubCommandAction.status),
    );
    expect(status.status.daemonId, connected.status.daemonId);

    final disconnected = await requestRunningDaemonHubManagement(
      config,
      const HubCommandOptions(action: HubCommandAction.disconnect, force: true),
    );
    expect(disconnected.status.state, HubConnectionState.notConnected);
    expect(
      disconnected.warning,
      'Local Hub credential removed; remote revocation may remain pending.',
    );
  });
}

DaemonRuntimeConfig _runtimeConfig(String home, int port) =>
    DaemonRuntimeConfig(
      home: home,
      listen: '127.0.0.1:$port',
      corsAllowedOrigins: const [],
      trustedProxies: const ['loopback'],
      relay: const DaemonRelayConfig(
        enabled: false,
        endpoint: '127.0.0.1:1',
        publicEndpoint: '127.0.0.1:1',
        useTls: false,
        publicUseTls: false,
      ),
      appBaseUrl: 'https://app.example.test',
      webUiEnabled: false,
      logLevel: 'info',
      logFormat: 'pretty',
      enableTerminalAgentHooks: false,
    );

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
