import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/src/providers/native/credential_store.dart';
import 'package:agent_daemon/src/providers/native/provider_config_store.dart';
import 'package:agent_daemon/src/providers/provider_registry.dart';
import 'package:agent_daemon/src/server/connection.dart';
import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Buffers every frame a connection receives.
///
/// A plain `channel.stream.asBroadcastStream()` loses frames: `first` /
/// `firstWhere` cancel their subscription once satisfied, and anything the
/// server sends while no listener is attached is dropped — which made the
/// broadcast test flaky, because `server.broadcast()` often fired in exactly
/// that window. Buffering decouples "has the frame arrived" from "is someone
/// currently listening".
class FrameLog {
  FrameLog(Stream<dynamic> raw) {
    _sub = raw.listen((frame) {
      // Only JSON (text) frames are RPC; binary frames are terminal I/O.
      if (frame is! String) return;
      _buffer.add(jsonDecode(frame) as Map<String, Object?>);
      final waiter = _waiter;
      if (waiter != null && !waiter.isCompleted) {
        _waiter = null;
        waiter.complete();
      }
    });
  }

  late final StreamSubscription<dynamic> _sub;
  final List<Map<String, Object?>> _buffer = [];
  Completer<void>? _waiter;

  /// How many buffered frames the caller has already consumed via [next].
  int _cursor = 0;

  Future<void> dispose() => _sub.cancel();

  /// The next frame not yet returned by [next], waiting if none has arrived.
  Future<Map<String, Object?>> next({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    while (_cursor >= _buffer.length) {
      await _wait(timeout);
    }
    return _buffer[_cursor++];
  }

  /// The first buffered-or-future frame matching [test]. Scans frames that
  /// already arrived, so it can't miss one sent before this call.
  Future<Map<String, Object?>> firstWhere(
    bool Function(Map<String, Object?>) test, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    var i = 0;
    while (true) {
      for (; i < _buffer.length; i++) {
        if (test(_buffer[i])) return _buffer[i];
      }
      await _wait(timeout);
    }
  }

  Future<void> _wait(Duration timeout) {
    final waiter = _waiter ??= Completer<void>();
    return waiter.future.timeout(
      timeout,
      onTimeout: () => throw StateError(
        'no matching frame within $timeout (buffered: '
        '${_buffer.map((f) => f['type']).toList()})',
      ),
    );
  }
}

void main() {
  late WsServer server;
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('ws_server_test_');
    final registry = ProviderRegistry(
      credentials: CredentialStore(dataDir: tempDir.path),
      configs: ProviderConfigStore(dataDir: tempDir.path),
    );
    // Providers are user-configured now, so seed one to give provider.list
    // something to return.
    await registry.upsert(const ProviderConfig(
      id: '',
      displayName: 'Claude',
      kind: ProviderKind.anthropic,
      baseUrl: 'https://api.anthropic.example/v1',
    ));
    final router = RpcRouter()
      ..on(MessageTypes.providerListRequest, (_, __) async {
        final providers = await registry.list();
        return ProviderListResponse(providers: providers).toJson();
      });
    server = WsServer(router: router);
    await server.start(host: '127.0.0.1', port: 0);
  });

  tearDown(() async {
    await server.stop();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<(WebSocketChannel, FrameLog)> connect() async {
    final channel =
        WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${server.port}'));
    await channel.ready;
    final log = FrameLog(channel.stream);
    addTearDown(log.dispose);
    return (channel, log);
  }

  test('hello handshake then provider.list', () async {
    final (channel, frames) = await connect();

    channel.sink.add(jsonEncode(const RpcRequest(
      type: MessageTypes.clientHelloRequest,
      requestId: 'h1',
      payload: {'clientName': 'test', 'clientVersion': '0.0.1'},
    ).toJson()));
    final hello = await frames.next();
    expect(hello['type'], 'client.hello.response');
    final serverHello =
        ServerHello.fromJson(hello['payload'] as Map<String, Object?>);
    expect(serverHello.protocolVersion, protocolVersion);

    channel.sink.add(jsonEncode(const RpcRequest(
      type: MessageTypes.providerListRequest,
      requestId: 'p1',
    ).toJson()));
    final response = await frames
        .firstWhere((f) => f['type'] == 'provider.list.response');
    final list = ProviderListResponse.fromJson(
        response['payload'] as Map<String, Object?>);
    expect(list.providers, hasLength(1));
    expect(list.providers.single.displayName, 'Claude');
    expect(list.providers.single.kind, ProviderKind.anthropic);

    await channel.sink.close();
  });

  test('requests before hello are rejected', () async {
    final (channel, frames) = await connect();
    channel.sink.add(jsonEncode(const RpcRequest(
      type: MessageTypes.providerListRequest,
      requestId: 'p1',
    ).toJson()));
    final response = await frames.next();
    expect(
      ((response['error'] as Map<String, Object?>?) ?? const {})['code'],
      RpcErrorCodes.unauthorized,
    );
    await channel.sink.close();
  });

  test('wrong token is rejected when token set', () async {
    final tokenServer = WsServer(router: RpcRouter(), token: 'secret');
    await tokenServer.start(host: '127.0.0.1', port: 0);
    addTearDown(tokenServer.stop);

    final channel = WebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${tokenServer.port}'));
    await channel.ready;
    // This test uses its own server, so it holds a plain stream rather than a
    // FrameLog — it only ever reads one frame.
    final frames = channel.stream
        .map((f) => jsonDecode(f as String) as Map<String, Object?>);
    channel.sink.add(jsonEncode(const RpcRequest(
      type: MessageTypes.clientHelloRequest,
      requestId: 'h1',
      payload: {
        'clientName': 'test',
        'clientVersion': '0.0.1',
        'token': 'wrong',
      },
    ).toJson()));
    final response = await frames.first;
    expect(
      ((response['error'] as Map<String, Object?>?) ?? const {})['code'],
      RpcErrorCodes.unauthorized,
    );
  });

  Future<void> hello(WebSocketChannel channel, FrameLog frames,
      {String id = 'h'}) async {
    channel.sink.add(jsonEncode(RpcRequest(
      type: MessageTypes.clientHelloRequest,
      requestId: id,
      payload: const {'clientName': 'test', 'clientVersion': '0.0.1'},
    ).toJson()));
    await frames.next();
  }

  test('malformed JSON frames get a protocol.error response', () async {
    final (channel, frames) = await connect();
    channel.sink.add('not valid json {{{');
    final response = await frames.next();
    expect(response['type'], 'protocol.error');
    await channel.sink.close();
  });

  test('connectionCount reflects live connections; broadcast reaches every '
      'authenticated client', () async {
    final (channelA, framesA) = await connect();
    await hello(channelA, framesA, id: 'a');
    final (channelB, framesB) = await connect();
    await hello(channelB, framesB, id: 'b');

    expect(server.connectionCount, 2);

    server.broadcast(const RpcEvent(type: 'test.event', payload: {'x': 1}));
    final eventA = await framesA.firstWhere((f) => f['type'] == 'test.event');
    final eventB = await framesB.firstWhere((f) => f['type'] == 'test.event');
    expect(eventA['payload'], {'x': 1});
    expect(eventB['payload'], {'x': 1});

    await channelA.sink.close();
    await channelB.sink.close();
  });

  test('connectionById returns the authenticated connection or null',
      () async {
    final gotFrame = Completer<Connection>();
    server.onBinaryFrame = (connection, frame) {
      if (!gotFrame.isCompleted) gotFrame.complete(connection);
    };

    final (channel, frames) = await connect();
    await hello(channel, frames);

    expect(server.connectionById('no-such-id'), isNull);

    channel.sink.add(
      TerminalFrame(
        opcode: TerminalOpcode.input,
        slotId: 1,
        payload: Uint8List.fromList([1, 2, 3]),
      ).encode(),
    );
    final captured =
        await gotFrame.future.timeout(const Duration(seconds: 5));
    expect(server.connectionById(captured.id), same(captured));

    await channel.sink.close();
  });

  test('binary frames route through onBinaryFrame only once authenticated',
      () async {
    final received = <TerminalFrame>[];
    var gotFrame = Completer<void>();
    server.onBinaryFrame = (connection, frame) {
      received.add(frame);
      if (!gotFrame.isCompleted) gotFrame.complete();
    };

    final (channel, frames) = await connect();

    // Before hello: binary frames are dropped silently (not authenticated).
    channel.sink.add(
      TerminalFrame(
        opcode: TerminalOpcode.input,
        slotId: 5,
        payload: Uint8List.fromList([9]),
      ).encode(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(received, isEmpty);

    await hello(channel, frames);

    // Malformed (too-short) binary frame: dropped.
    channel.sink.add(Uint8List.fromList([1, 2]));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(received, isEmpty);

    // Well-formed binary frame: delivered.
    channel.sink.add(
      TerminalFrame(
        opcode: TerminalOpcode.output,
        slotId: 7,
        payload: Uint8List.fromList([42]),
      ).encode(),
    );
    await gotFrame.future.timeout(const Duration(seconds: 5));
    expect(received, hasLength(1));
    expect(received.single.slotId, 7);
    expect(received.single.payload, [42]);

    await channel.sink.close();
  });

  test('binary frames with no onBinaryFrame handler registered are no-ops',
      () async {
    final (channel, frames) = await connect();
    await hello(channel, frames);
    // server.onBinaryFrame left null (default): should not throw.
    channel.sink.add(
      TerminalFrame(
        opcode: TerminalOpcode.input,
        slotId: 1,
        payload: Uint8List.fromList([1]),
      ).encode(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await channel.sink.close();
  });
}
