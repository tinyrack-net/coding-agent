import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';

void main() {
  late List<String> logs;
  late int now;
  late RelaySession session;

  setUp(() {
    logs = [];
    now = 100;
    session = RelaySession(
      connectionIdFactory: () => 'conn_generated',
      clock: () => now++,
      log: logs.add,
      initialControlNudgeDelay: const Duration(milliseconds: 10),
      controlResetDelay: const Duration(milliseconds: 10),
      maxPendingFrames: 2,
    );
    addTearDown(session.dispose);
  });

  RelaySessionAttachment attach(
    FakeRelaySocket socket,
    RelayConnectionRole role, {
    String version = '2',
    String? connectionId,
  }) => session.attach(
    socket,
    RelayAttachRequest(
      serverId: 'server-1',
      role: role,
      version: version,
      connectionId: connectionId,
    ),
  );

  test('v1 replaces equal roles and forwards opaque frames both ways', () {
    final oldServer = FakeRelaySocket();
    final server = FakeRelaySocket();
    final client = FakeRelaySocket();
    attach(oldServer, RelayConnectionRole.server, version: '1');
    attach(server, RelayConnectionRole.server, version: '1');
    attach(client, RelayConnectionRole.client, version: '1');

    expect(oldServer.closes, [(1008, 'Replaced by new connection')]);
    session.handleMessage(client, 'hello');
    session.handleMessage(server, Uint8List.fromList([1, 2, 3]));
    expect(server.sent, ['hello']);
    expect(client.sent.single, orderedEquals([1, 2, 3]));
    expect(session.connectionCount, 2);

    session.handleClose(client, code: 1000, reason: 'done');
    expect(session.connectionCount, 1);
  });

  test('v2 control synchronizes clients and receives connect notices', () {
    final firstClient = FakeRelaySocket();
    final generated = attach(firstClient, RelayConnectionRole.client);
    expect(generated.connectionId, 'conn_generated');

    final control = FakeRelaySocket();
    final controlAttachment = attach(control, RelayConnectionRole.server);
    expect(controlAttachment.connectionId, isNull);
    expect(jsonDecode(control.sent.single as String), {
      'type': 'sync',
      'connectionIds': ['conn_generated'],
    });

    final secondClient = FakeRelaySocket();
    attach(
      secondClient,
      RelayConnectionRole.client,
      connectionId: 'conn_explicit',
    );
    expect(jsonDecode(control.sent.last as String), {
      'type': 'connected',
      'connectionId': 'conn_explicit',
    });

    final replacementControl = FakeRelaySocket();
    attach(replacementControl, RelayConnectionRole.server);
    expect(control.closes, [(1008, 'Replaced by new connection')]);
    expect(
      session.attachmentOf(replacementControl)?.role,
      RelayConnectionRole.server,
    );
  });

  test('v2 buffers client frames, caps them, and flushes on server data', () {
    final client = FakeRelaySocket();
    attach(client, RelayConnectionRole.client, connectionId: 'connection-1');
    session.handleMessage(client, 'dropped');
    session.handleMessage(client, 'kept-1');
    session.handleMessage(client, 'kept-2');

    final server = FakeRelaySocket();
    attach(server, RelayConnectionRole.server, connectionId: 'connection-1');
    expect(server.sent, ['kept-1', 'kept-2']);

    session.handleMessage(client, 'client-to-server');
    session.handleMessage(server, 'server-to-client');
    expect(server.sent.last, 'client-to-server');
    expect(client.sent.last, 'server-to-client');

    final replacement = FakeRelaySocket();
    attach(
      replacement,
      RelayConnectionRole.server,
      connectionId: 'connection-1',
    );
    expect(server.closes, [(1008, 'Replaced by new connection')]);
  });

  test('a failed buffer flush retains the failed frame and its tail', () {
    final client = FakeRelaySocket();
    attach(client, RelayConnectionRole.client, connectionId: 'connection-1');
    session.handleMessage(client, 'one');
    session.handleMessage(client, 'two');

    final failingServer = FakeRelaySocket()..failSendAt = 0;
    attach(
      failingServer,
      RelayConnectionRole.server,
      connectionId: 'connection-1',
    );
    final replacement = FakeRelaySocket();
    attach(
      replacement,
      RelayConnectionRole.server,
      connectionId: 'connection-1',
    );
    expect(replacement.sent, ['one', 'two']);
  });

  test('multiple clients share an id until the final client closes', () {
    final control = FakeRelaySocket();
    final server = FakeRelaySocket();
    final first = FakeRelaySocket();
    final second = FakeRelaySocket();
    attach(control, RelayConnectionRole.server);
    attach(first, RelayConnectionRole.client, connectionId: 'connection-1');
    attach(second, RelayConnectionRole.client, connectionId: 'connection-1');
    attach(server, RelayConnectionRole.server, connectionId: 'connection-1');
    control.sent.clear();

    session.handleClose(first, code: 1001, reason: 'first');
    expect(server.closes, isEmpty);
    expect(control.sent, isEmpty);

    session.handleClose(second, code: 1001, reason: 'last');
    expect(server.closes, [(1001, 'Client disconnected')]);
    expect(jsonDecode(control.sent.single as String), {
      'type': 'disconnected',
      'connectionId': 'connection-1',
    });
  });

  test('server data loss closes every matching client', () {
    final server = FakeRelaySocket();
    final first = FakeRelaySocket();
    final second = FakeRelaySocket();
    attach(first, RelayConnectionRole.client, connectionId: 'connection-1');
    attach(second, RelayConnectionRole.client, connectionId: 'connection-1');
    attach(server, RelayConnectionRole.server, connectionId: 'connection-1');

    session.handleClose(server, code: 1006, reason: 'lost');
    expect(first.closes, [(1012, 'Server disconnected')]);
    expect(second.closes, [(1012, 'Server disconnected')]);
  });

  test('control keepalive replies only to JSON ping', () {
    final control = FakeRelaySocket();
    attach(control, RelayConnectionRole.server);
    control.sent.clear();
    session.handleMessage(control, 'not-json');
    session.handleMessage(control, '{"type":"other"}');
    session.handleMessage(control, '{"type":"ping"}');
    session.handleMessage(control, Uint8List(0));

    expect(jsonDecode(control.sent.single as String), {
      'type': 'pong',
      'ts': greaterThanOrEqualTo(100),
    });
    expect(logs, contains('legacy_json_ping_received'));
  });

  test('control is nudged then reset when daemon data never appears', () async {
    final control = FakeRelaySocket();
    final client = FakeRelaySocket();
    attach(control, RelayConnectionRole.server);
    control.sent.clear();
    attach(client, RelayConnectionRole.client, connectionId: 'connection-1');
    control.sent.clear();

    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(jsonDecode(control.sent.single as String), {
      'type': 'sync',
      'connectionIds': ['connection-1'],
    });
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(control.closes, [(1011, 'Control unresponsive')]);
  });

  test(
    'nudge exits after client disconnect or server data attachment',
    () async {
      final control = FakeRelaySocket();
      final disconnected = FakeRelaySocket();
      attach(control, RelayConnectionRole.server);
      attach(
        disconnected,
        RelayConnectionRole.client,
        connectionId: 'disconnected',
      );
      session.handleClose(disconnected, code: 1000, reason: 'gone');

      final connected = FakeRelaySocket();
      final data = FakeRelaySocket();
      attach(connected, RelayConnectionRole.client, connectionId: 'connected');
      attach(data, RelayConnectionRole.server, connectionId: 'connected');
      control.sent.clear();
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(control.closes, isEmpty);
      expect(control.sent, isEmpty);
    },
  );

  test(
    'invalid boundaries, unknown sockets, errors, and disposal are safe',
    () {
      final socket = FakeRelaySocket();
      expect(
        () => session.attach(
          socket,
          const RelayAttachRequest(
            serverId: '',
            role: RelayConnectionRole.client,
            version: '2',
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => session.attach(
          socket,
          const RelayAttachRequest(
            serverId: 'server-1',
            role: RelayConnectionRole.client,
            version: '3',
          ),
        ),
        throwsFormatException,
      );
      session.handleMessage(socket, 'ignored');
      session.handleClose(socket, code: 1000, reason: 'unknown');
      session.handleError(socket, StateError('test'));
      expect(logs, contains('message_without_attachment'));
      expect(logs.last, contains('websocket_error:unknown'));

      attach(socket, RelayConnectionRole.client, version: '1');
      session.dispose();
      session.dispose();
      expect(socket.closes, [(1001, 'Relay shutting down')]);
      expect(
        () => attach(FakeRelaySocket(), RelayConnectionRole.client),
        throwsStateError,
      );
      session.handleMessage(socket, 'ignored after dispose');
    },
  );

  test('send and close failures are contained and logged', () {
    final control = FakeRelaySocket()..throwOnSend = true;
    attach(control, RelayConnectionRole.server);
    final client = FakeRelaySocket();
    attach(client, RelayConnectionRole.client, connectionId: 'connection-1');
    expect(logs.any((entry) => entry.startsWith('send_failed:')), isTrue);

    final closing = FakeRelaySocket()..throwOnClose = true;
    attach(closing, RelayConnectionRole.server);
    attach(FakeRelaySocket(), RelayConnectionRole.server);
    expect(logs.any((entry) => entry.startsWith('close_failed:')), isTrue);
  });
}

final class FakeRelaySocket implements RelaySocket {
  final List<Object> sent = [];
  final List<(int, String)> closes = [];
  bool throwOnSend = false;
  bool throwOnClose = false;
  int? failSendAt;

  @override
  void send(Object frame) {
    if (throwOnSend || failSendAt == sent.length) {
      throw StateError('send failed');
    }
    sent.add(frame);
  }

  @override
  void close(int code, String reason) {
    if (throwOnClose) throw StateError('close failed');
    closes.add((code, reason));
  }
}
