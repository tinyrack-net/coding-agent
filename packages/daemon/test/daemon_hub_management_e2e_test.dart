@Timeout(Duration(seconds: 20))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/daemon_server.dart';
import 'package:agent_daemon/src/hub/relationship_remote.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:daemon_lifecycle/daemon_lifecycle.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('daemon manages a persisted Hub relationship over v2 RPC', () async {
    final temp = await Directory.systemTemp.createTemp('daemon-hub-rpc-');
    addTearDown(() => temp.delete(recursive: true));
    final remote = _ConnectedHubRemote();
    final handle = await startDaemonServer(
      paths: DaemonPaths(dataDir: temp.path),
      host: '127.0.0.1',
      port: 0,
      dataDir: temp.path,
      hubRelationshipRemote: remote,
      log: (_) {},
    );
    addTearDown(handle.stop);

    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${handle.server.port}/ws'),
    );
    await channel.ready;
    addTearDown(channel.sink.close);
    final frames = channel.stream
        .where((frame) => frame is String)
        .map((frame) => jsonDecode(frame as String) as Map<String, Object?>)
        .asBroadcastStream();
    channel.sink.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'hub-management-e2e',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await frames.firstWhere((frame) => frame['status'] == 'server_info');

    final connectedEnvelope = await _request(
      channel,
      frames,
      const HubManagementDaemonConnectRequest(
        requestId: 'connect-1',
        hubUrl: 'https://hub.example.test',
        token: 'enrollment-token',
      ).toJson(),
    );
    final connected = HubManagementDaemonConnectResponse.fromJson(
      connectedEnvelope,
    );
    expect(connected.status.state, HubConnectionState.connected);
    expect(connected.status.daemonId, isNotEmpty);
    expect(connected.status.scopes, ['hub.execution.*']);
    expect(handle.server.connectionCount, 2);

    final statusEnvelope = await _request(
      channel,
      frames,
      const HubManagementDaemonGetStatusRequest(requestId: 'status-1').toJson(),
    );
    final status = HubManagementDaemonGetStatusResponse.fromJson(
      statusEnvelope,
    );
    expect(status.status.state, HubConnectionState.connected);
    expect(status.status.lastError, isNull);

    final duplicate = await _request(
      channel,
      frames,
      const HubManagementDaemonConnectRequest(
        requestId: 'connect-duplicate',
        hubUrl: 'https://other.example.test',
        token: 'another-token',
      ).toJson(),
    );
    expect(duplicate['type'], 'rpc_error');
    expect(
      (duplicate['payload'] as Map<String, Object?>)['code'],
      'handler_error',
    );

    final disconnectedEnvelope = await _request(
      channel,
      frames,
      const HubManagementDaemonDisconnectRequest(
        requestId: 'disconnect-1',
      ).toJson(),
    );
    final disconnected = HubManagementDaemonDisconnectResponse.fromJson(
      disconnectedEnvelope,
    );
    expect(disconnected.status.state, HubConnectionState.notConnected);
    expect(disconnected.warning, isNull);
    expect(remote.revocations, hasLength(1));
    expect(remote.connection?.closed, isTrue);
  });
}

Future<Map<String, Object?>> _request(
  WebSocketChannel channel,
  Stream<Map<String, Object?>> frames,
  Map<String, Object?> message,
) async {
  channel.sink.add(jsonEncode({'type': 'session', 'message': message}));
  final envelope = await frames.firstWhere(
    (frame) =>
        frame['type'] == 'session' &&
        (frame['message'] as Map?)?['payload'] is Map &&
        ((frame['message'] as Map)['payload'] as Map)['requestId'] ==
            message['requestId'],
  );
  return (envelope['message'] as Map).cast<String, Object?>();
}

final class _ConnectedHubRemote implements HubRelationshipRemote {
  final revocations = <HubRevocation>[];
  _ConnectedHubSocketConnection? connection;

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
    final created = _ConnectedHubSocketConnection();
    connection = created;
    events.connected(created.socket);
    return created;
  }

  @override
  Future<void> revoke(HubRevocation input) async {
    revocations.add(input);
  }
}

final class _ConnectedHubSocketConnection implements HubSocketConnection {
  final socket = _ConnectedHubSocket();
  bool closed = false;

  @override
  Future<void> close() async {
    closed = true;
    await socket.close();
  }
}

final class _ConnectedHubSocket implements HubSocket {
  final framesController = StreamController<Object>.broadcast();

  @override
  Stream<Object> get frames => framesController.stream;

  @override
  void send(Object data) {}

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!framesController.isClosed) await framesController.close();
  }
}
