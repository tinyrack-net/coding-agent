// Exercises the real DaemonClient (the class every other test fakes out)
// against an actual local dart:io WebSocket server, covering what
// daemon_lifecycle_provider_test.dart / daemon_version_gate_test.dart don't:
// connect/hello handshake, request/response correlation, error responses,
// timeouts, binary terminal frames, sendTerminalFrame, disconnect + backoff
// reconnect. isLoopbackHost/shouldRejectHello/versionMismatchMessage are
// already covered by daemon_version_gate_test.dart and are not repeated here.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// One accepted server-side connection. [frames] is a broadcast view of the
/// raw socket so tests can attach multiple sequential listeners to it (a raw
/// [WebSocket] only supports a single subscription for its whole lifetime).
class ServerConn {
  ServerConn(this.socket) : frames = socket.asBroadcastStream();

  final WebSocket socket;
  final Stream<dynamic> frames;

  Stream<Map<String, Object?>> get jsonFrames => frames
      .where((f) => f is String)
      .map((f) => jsonDecode(f as String) as Map<String, Object?>);

  /// Waits for the next request of [type] and returns its decoded frame.
  Future<Map<String, Object?>> nextRequest(String type) =>
      jsonFrames.firstWhere((f) => f['type'] == type);

  void respond(String requestId, String responseType, Map<String, Object?> payload) {
    socket.add(jsonEncode(
      RpcResponse(type: responseType, requestId: requestId, payload: payload)
          .toJson(),
    ));
  }

  void fail(String requestId, String responseType, RpcError error) {
    socket.add(jsonEncode(
      RpcResponse(type: responseType, requestId: requestId, error: error)
          .toJson(),
    ));
  }

  /// Answers a `client.hello.request` with a canned [hello] as soon as one
  /// arrives, returning the decoded request payload.
  Future<Map<String, Object?>> respondToHello(ServerHello hello) async {
    final frame = await nextRequest(MessageTypes.clientHelloRequest);
    respond(frame['requestId'] as String, 'client.hello.response', hello.toJson());
    return (frame['payload'] as Map<String, Object?>?) ?? const {};
  }
}

/// Minimal local WebSocket test server: hands each accepted connection to
/// [connections] as a [ServerConn] so tests can script the daemon side.
class TestDaemonServer {
  TestDaemonServer._(this._server);

  final HttpServer _server;
  final _sockets = <WebSocket>[];
  final _connections = StreamController<ServerConn>.broadcast();

  Stream<ServerConn> get connections => _connections.stream;
  int get connectionCount => _connectionCount;
  int _connectionCount = 0;

  static Future<TestDaemonServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final daemon = TestDaemonServer._(server);
    unawaited(daemon._serve());
    return daemon;
  }

  Uri get uri => Uri(scheme: 'ws', host: '127.0.0.1', port: _server.port);

  Future<void> _serve() async {
    await for (final request in _server) {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        continue;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      _connectionCount++;
      _sockets.add(socket);
      _connections.add(ServerConn(socket));
    }
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _connections.close();
    await _server.close(force: true);
  }
}

Future<ServerConn> nextConnection(TestDaemonServer server) =>
    server.connections.first;

void main() {
  late TestDaemonServer server;
  late DaemonClient client;

  setUp(() async {
    server = await TestDaemonServer.start();
  });

  tearDown(() async {
    client.dispose();
    await server.close();
  });

  test('connect() performs the hello handshake and reaches connected state',
      () async {
    client = DaemonClient(uri: server.uri);
    final states = <DaemonConnectionState>[];
    final sub = client.connectionState.listen(states.add);

    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    final helloPayload = await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1, pid: 999),
    );

    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(helloPayload['clientName'], 'coding-agent-app');
    expect(client.currentState, DaemonConnectionState.connected);
    expect(client.serverHello?.pid, 999);
    expect(states, contains(DaemonConnectionState.connecting));
    expect(states, contains(DaemonConnectionState.connected));
    await sub.cancel();
  });

  test('request() resolves with the response payload for its requestId',
      () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(conn.nextRequest('agent.list.request').then((frame) {
      conn.respond(
        frame['requestId'] as String,
        'agent.list.response',
        const {'agents': []},
      );
    }));

    final response = await client.request('agent.list.request', const {});

    expect(response, <String, Object?>{'agents': []});
  });

  test('request() throws DaemonRpcException on an error response', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    unawaited(conn.nextRequest('agent.prompt.request').then((frame) {
      conn.fail(
        frame['requestId'] as String,
        'agent.prompt.response',
        const RpcError(code: 'not_found', message: 'no such agent'),
      );
    }));

    await expectLater(
      client.request('agent.prompt.request', const {'agentId': 'missing'}),
      throwsA(
        isA<DaemonRpcException>().having(
          (e) => e.toString(),
          'message',
          contains('no such agent'),
        ),
      ),
    );
  });

  test('request() times out when the daemon never responds', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await expectLater(
      client.request(
        'agent.list.request',
        const {},
        timeout: const Duration(milliseconds: 100),
      ),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('request() throws StateError before a connection exists', () async {
    client = DaemonClient(uri: server.uri);

    await expectLater(
      client.request('agent.list.request', const {}),
      throwsA(isA<StateError>()),
    );
  });

  test('terminal frames: binary output from the daemon is decoded and '
      'exposed via terminalFrames', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final framesFuture = client.terminalFrames.first;
    final frame = TerminalFrame(
      opcode: TerminalOpcode.output,
      slotId: 7,
      payload: Uint8List.fromList(utf8.encode('hello from daemon')),
    );
    conn.socket.add(frame.encode());

    final decoded = await framesFuture;
    expect(decoded.opcode, TerminalOpcode.output);
    expect(decoded.slotId, 7);
    expect(utf8.decode(decoded.payload), 'hello from daemon');
  });

  test('sendTerminalFrame() writes the encoded binary frame to the socket',
      () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final received = conn.frames.firstWhere((f) => f is List<int>);
    client.sendTerminalFrame(TerminalFrame(
      opcode: TerminalOpcode.input,
      slotId: 3,
      payload: Uint8List.fromList(utf8.encode('ls')),
    ));

    final bytes = await received as List<int>;
    final decoded = TerminalFrame.decode(Uint8List.fromList(bytes));
    expect(decoded!.opcode, TerminalOpcode.input);
    expect(decoded.slotId, 3);
    expect(utf8.decode(decoded.payload), 'ls');
  });

  test('events: an unsolicited RpcEvent frame is exposed via events',
      () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final eventFuture = client.events.first;
    conn.socket.add(jsonEncode(const RpcEvent(
      type: 'terminal.exited',
      payload: {'terminalId': 't1', 'exitCode': 1},
    ).toJson()));

    final event = await eventFuture;
    expect(event.type, 'terminal.exited');
    expect(event.payload['exitCode'], 1);
  });

  test('disconnect: server closing the socket surfaces disconnected state '
      'and pending requests fail', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(client.currentState, DaemonConnectionState.connected);

    final pending = client.request('agent.list.request', const {});
    // Attach the failure expectation before yielding control (the socket
    // close below completes `pending` with an error synchronously on its
    // callback; a listener must already be attached or Dart reports it as
    // an unhandled zone error instead of surfacing it through expectLater).
    final pendingExpectation = expectLater(pending, throwsA(isA<StateError>()));
    final disconnected = client.connectionState.firstWhere(
      (s) => s == DaemonConnectionState.disconnected,
    );
    await conn.socket.close();

    await pendingExpectation;
    await disconnected;
    expect(client.currentState, DaemonConnectionState.disconnected);
  });

  test('reconnect: after a disconnect the client retries and can '
      're-handshake on a new socket', () async {
    client = DaemonClient(uri: server.uri);
    final firstConnFuture = nextConnection(server);
    unawaited(client.connect());
    final firstConn = await firstConnFuture;
    await firstConn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final secondConnFuture = nextConnection(server);
    await firstConn.socket.close();
    // Initial backoff is 1s; give the retry timer time to fire and dial in.
    final secondConn = await secondConnFuture.timeout(
      const Duration(seconds: 3),
    );
    await secondConn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(server.connectionCount, 2);
    expect(client.currentState, DaemonConnectionState.connected);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('a same-major-version hello on loopback is always accepted '
      '(remote-only version gate is covered by daemon_version_gate_test.dart)',
      () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '9.9.9', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(client.currentState, DaemonConnectionState.connected);
    expect(client.rejectedHello, isNull);
  });

  test('an unsolicited request-shaped frame from the daemon is ignored '
      '(the MVP never expects the daemon to send requests)', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Send a request-shaped frame; the client should just ignore it (no
    // crash, no response sent back, no effect on connection state).
    conn.socket.add(jsonEncode(const RpcRequest(
      type: 'some.made_up.request',
      requestId: 'req-1',
      payload: {'foo': 'bar'},
    ).toJson()));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(client.currentState, DaemonConnectionState.connected);
    // A subsequent real request still resolves normally, proving the client
    // wasn't left in a broken state.
    unawaited(conn.nextRequest('agent.list.request').then((frame) {
      conn.respond(
        frame['requestId'] as String,
        'agent.list.response',
        const {'agents': []},
      );
    }));
    final response = await client.request('agent.list.request', const {});
    expect(response, <String, Object?>{'agents': []});
  });

  test('connect() swallows a connection failure and schedules a retry '
      'instead of throwing', () async {
    // Port 0 with no listener: WebSocketChannel.connect's `ready` future
    // rejects, exercising connect()'s catch-and-retry path instead of the
    // hello handshake.
    final unreachable = Uri(scheme: 'ws', host: '127.0.0.1', port: 1);
    client = DaemonClient(uri: unreachable);
    final states = <DaemonConnectionState>[];
    final sub = client.connectionState.listen(states.add);

    await client.connect();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(client.currentState, DaemonConnectionState.disconnected);
    expect(states, contains(DaemonConnectionState.connecting));
    expect(states, contains(DaemonConnectionState.disconnected));
    await sub.cancel();
  });

  test('dispose() closes the socket and stops the reconnect loop', () async {
    client = DaemonClient(uri: server.uri);
    final connFuture = nextConnection(server);
    unawaited(client.connect());
    final conn = await connFuture;
    await conn.respondToHello(
      const ServerHello(daemonVersion: '0.2.0', protocolVersion: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final secondConnection = nextConnection(server);
    client.dispose();
    await conn.socket.close();

    // No new connection should show up after dispose, even after waiting
    // past the first backoff interval.
    final gotAnother = await secondConnection
        .timeout(const Duration(milliseconds: 1500))
        .then((_) => true, onError: (_) => false);
    expect(gotAnother, isFalse);
  });
}
