import 'dart:async';
import 'dart:convert';

import 'package:agent_daemon/src/server/relay_transport.dart';
import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';

void main() {
  test('control sync creates E2EE data socket attached to v2 server', () async {
    final control = _FakeSocket();
    final data = _FakeSocket();
    final urls = <Uri>[];
    final server = WsServer(router: RpcRouter(), serverId: 'srv_test');
    final logs = <String>[];
    final controller = RelayTransportController(
      server: server,
      relayEndpoint: '127.0.0.1:8787',
      relayUseTls: false,
      serverId: 'srv_test',
      daemonKeyPair: RelayKeyPair.generate(),
      connect: (rawUrl) async {
        final url = Uri.parse(rawUrl);
        urls.add(url);
        return url.queryParameters.containsKey('connectionId') ? data : control;
      },
      controlPingInterval: const Duration(seconds: 10),
      reconnectUnit: const Duration(milliseconds: 20),
      log: logs.add,
    );
    addTearDown(() async {
      await controller.stop();
      await server.stop();
    });

    await _waitUntil(() => control.sent.isNotEmpty);
    expect(urls.single.queryParameters, {
      'serverId': 'srv_test',
      'role': 'server',
      'v': '2',
    });
    control.emit('not-json');
    control.emit(
      jsonEncode({
        'type': 'sync',
        'connectionIds': [' conn_one ', '', 4],
      }),
    );
    await _waitUntil(() => urls.length == 2);
    expect(urls.last.queryParameters['connectionId'], 'conn_one');
    expect(controller.controlReady, isTrue);

    final received = <Object>[];
    final client = RelayE2eeClientChannel(
      daemonPublicKeyB64: exportRelayPublicKey(
        controller.daemonKeyPair.publicKey,
      ),
      transportSend: data.emit,
      transportClose: data.close,
      onMessage: received.add,
      handshakeRetry: const Duration(milliseconds: 20),
    );
    data.onSend = client.handleFrame;
    client.start();
    await client.ready.timeout(const Duration(seconds: 2));
    client.send(
      jsonEncode({
        'type': 'hello',
        'protocolVersion': paseoWebSocketProtocolVersion,
        'clientId': 'relay-test',
        'clientType': 'browser',
        'capabilities': <String, Object?>{},
      }),
    );
    await _waitUntil(
      () => received.any(
        (frame) =>
            frame is String &&
            (jsonDecode(frame) as Map<String, Object?>)['status'] ==
                'server_info',
      ),
    );

    expect(server.authenticatedV2Connections, hasLength(1));
    final connection = server.authenticatedV2Connections.single;
    expect(connection.transport, 'relay');
    expect(connection.externalSessionKey, 'session:conn_one');
    expect(connection.relayConnectionId, 'conn_one');

    control.emit(
      jsonEncode({'type': 'disconnected', 'connectionId': 'conn_one'}),
    );
    await _waitUntil(() => data.closeCode == 1001);
    expect(controller.dataSocketCount, 0);
    expect(logs, contains('relay control connected'));
  });

  test('control close reconnects and stop closes all sockets', () async {
    final controls = <_FakeSocket>[];
    final server = WsServer(router: RpcRouter());
    final controller = RelayTransportController(
      server: server,
      relayEndpoint: 'relay.test:80',
      relayUseTls: false,
      serverId: 'srv_test',
      daemonKeyPair: RelayKeyPair.generate(),
      connect: (_) async {
        final socket = _FakeSocket();
        controls.add(socket);
        return socket;
      },
      controlPingInterval: const Duration(seconds: 1),
      reconnectUnit: const Duration(milliseconds: 10),
      maxReconnectDelay: const Duration(milliseconds: 20),
    );
    addTearDown(server.stop);

    await _waitUntil(() => controls.isNotEmpty);
    controls.first.emit(jsonEncode({'type': 'pong'}));
    await controls.first.remoteClose(1006, 'lost');
    await _waitUntil(() => controls.length == 2);

    await controller.stop();
    expect(controller.stopped, isTrue);
    expect(controls.last.closeCode, 1000);
  });

  test('control ready timeout closes a silent socket', () async {
    final control = _FakeSocket();
    final server = WsServer(router: RpcRouter());
    final controller = RelayTransportController(
      server: server,
      relayEndpoint: 'relay.test:80',
      relayUseTls: false,
      serverId: 'srv_test',
      daemonKeyPair: RelayKeyPair.generate(),
      connect: (_) async => control,
      controlReadyTimeout: const Duration(milliseconds: 20),
      reconnectUnit: const Duration(seconds: 10),
    );
    addTearDown(() async {
      await controller.stop();
      await server.stop();
    });

    await _waitUntil(() => control.closeCode == 1011);
    expect(control.closeReason, 'Relay control ready timeout');
  });

  test('control keepalive answers ping and terminates stale sockets', () async {
    final control = _FakeSocket();
    final server = WsServer(router: RpcRouter());
    final controller = RelayTransportController(
      server: server,
      relayEndpoint: 'relay.test:80',
      relayUseTls: false,
      serverId: 'srv_test',
      daemonKeyPair: RelayKeyPair.generate(),
      connect: (_) async => control,
      controlPingInterval: const Duration(milliseconds: 10),
      controlStaleTimeout: const Duration(milliseconds: 25),
      reconnectUnit: const Duration(seconds: 10),
    );
    addTearDown(() async {
      await controller.stop();
      await server.stop();
    });

    await _waitUntil(() => control.sent.isNotEmpty);
    control.emit(jsonEncode({'type': 'ping'}));
    await _waitUntil(
      () => control.sent.any(
        (message) =>
            message is String &&
            (jsonDecode(message) as Map<String, Object?>)['type'] == 'pong',
      ),
    );
    await _waitUntil(() => control.closeReason == 'Relay control stale');
  });

  test(
    'connection and initial ping failures recover without escaping',
    () async {
      final control = _FakeSocket()..throwOnSend = true;
      final server = WsServer(router: RpcRouter());
      var attempts = 0;
      final logs = <String>[];
      final controller = RelayTransportController(
        server: server,
        relayEndpoint: 'relay.test:80',
        relayUseTls: false,
        serverId: 'srv_test',
        daemonKeyPair: RelayKeyPair.generate(),
        connect: (_) async {
          attempts += 1;
          if (attempts == 1) throw StateError('offline');
          return control;
        },
        reconnectUnit: const Duration(milliseconds: 10),
        log: logs.add,
      );
      addTearDown(() async {
        await controller.stop();
        await server.stop();
      });

      await _waitUntil(
        () => control.closeReason == 'Relay control ping failed',
      );
      expect(logs, contains(contains('relay control connection failed')));
      expect(logs, contains(contains('relay control initial ping failed')));
    },
  );

  test('data connect and E2EE handshake failures are isolated', () async {
    final control = _FakeSocket();
    final badHandshake = _FakeSocket();
    final server = WsServer(router: RpcRouter());
    final logs = <String>[];
    final controller = RelayTransportController(
      server: server,
      relayEndpoint: 'relay.test:80',
      relayUseTls: false,
      serverId: 'srv_test',
      daemonKeyPair: RelayKeyPair.generate(),
      connect: (rawUrl) async {
        final id = Uri.parse(rawUrl).queryParameters['connectionId'];
        if (id == 'connect_fail') throw StateError('data offline');
        return id == null ? control : badHandshake;
      },
      dataOpenTimeout: const Duration(milliseconds: 100),
      log: logs.add,
    );
    addTearDown(() async {
      await controller.stop();
      await server.stop();
    });

    await _waitUntil(() => control.sent.isNotEmpty);
    control.emit(
      jsonEncode({
        'type': 'sync',
        'connectionIds': ['connect_fail', 'bad_handshake'],
      }),
    );
    await _waitUntil(
      () => logs.any((line) => line.contains('connect_fail connection failed')),
    );
    badHandshake.emit('not-an-e2ee-hello');
    await _waitUntil(
      () => logs.any((line) => line.contains('E2EE handshake failed')),
    );
    await _waitUntil(() => controller.dataSocketCount == 0);
  });
}

final class _FakeSocket implements RelayTransportSocket {
  final _frames = StreamController<Object>();
  final sent = <Object>[];
  void Function(Object data)? onSend;
  bool throwOnSend = false;

  @override
  int? closeCode;

  @override
  String? closeReason;

  @override
  Stream<Object> get frames => _frames.stream;

  void emit(Object data) {
    if (!_frames.isClosed) _frames.add(data);
  }

  @override
  void send(Object data) {
    if (throwOnSend) throw StateError('send failed');
    sent.add(data);
    onSend?.call(data);
  }

  @override
  Future<void> close([int? code, String? reason]) => remoteClose(code, reason);

  Future<void> remoteClose([int? code, String? reason]) async {
    if (_frames.isClosed) return;
    closeCode = code;
    closeReason = reason;
    await _frames.close();
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
