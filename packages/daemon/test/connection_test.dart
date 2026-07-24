import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_daemon/src/server/connection.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// In-memory [WebSocketChannel] double: `incoming` simulates frames arriving
/// from the network (readable via [Connection.frames]); everything written
/// to `sink` is captured in [written] for assertions.
class FakeWebSocketChannel extends StreamChannelMixin
    implements WebSocketChannel {
  FakeWebSocketChannel();

  final _incoming = StreamController<Object?>.broadcast();
  final List<Object?> written = [];
  late final WebSocketSink _sink = _FakeSink(this);

  int? closeCode;
  String? closeReason;

  void emitIncoming(Object? frame) => _incoming.add(frame);

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future.value();

  @override
  Stream get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;
}

class _FakeSink extends DelegatingStreamSink implements WebSocketSink {
  _FakeSink(this._channel) : super(_Collector(_channel));

  final FakeWebSocketChannel _channel;

  @override
  Future close([int? closeCode, String? closeReason]) {
    _channel.closeCode = closeCode;
    _channel.closeReason = closeReason;
    return super.close();
  }
}

class _Collector implements StreamSink<Object?> {
  _Collector(this._channel);
  final FakeWebSocketChannel _channel;

  @override
  void add(Object? event) => _channel.written.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream event) async {
    await for (final e in event) {
      add(e);
    }
  }

  @override
  Future close() async {}

  @override
  Future get done => Future.value();
}

void main() {
  test('defaults: not authenticated, unknown clientName, not loopback',
      () {
    final connection = Connection(FakeWebSocketChannel(), id: 'c1');
    expect(connection.id, 'c1');
    expect(connection.authenticated, isFalse);
    expect(connection.clientName, 'unknown');
    expect(connection.isLoopback, isFalse);
  });

  test('isLoopback reflects the constructor argument', () {
    final connection =
        Connection(FakeWebSocketChannel(), id: 'c2', isLoopback: true);
    expect(connection.isLoopback, isTrue);
  });

  test('authenticated and clientName can be mutated after construction', () {
    final connection = Connection(FakeWebSocketChannel(), id: 'c3');
    connection
      ..authenticated = true
      ..clientName = 'my-client';
    expect(connection.authenticated, isTrue);
    expect(connection.clientName, 'my-client');
  });

  test('frames exposes the underlying channel stream', () async {
    final channel = FakeWebSocketChannel();
    final connection = Connection(channel, id: 'c4');
    final received = <Object?>[];
    connection.frames.listen(received.add);

    channel.emitIncoming('hello');
    channel.emitIncoming('world');
    await Future<void>.delayed(Duration.zero);
    expect(received, ['hello', 'world']);
  });

  test('sendFrame serializes the frame to JSON text on the sink', () {
    final channel = FakeWebSocketChannel();
    final connection = Connection(channel, id: 'c5');
    connection.sendFrame(const RpcEvent(
      type: 'agent.state',
      payload: {'foo': 'bar'},
    ));

    expect(channel.written, hasLength(1));
    final decoded =
        jsonDecode(channel.written.single as String) as Map<String, Object?>;
    expect(decoded['type'], 'agent.state');
    expect(decoded['payload'], {'foo': 'bar'});
  });

  test('sendBinary writes raw bytes to the sink unmodified', () {
    final channel = FakeWebSocketChannel();
    final connection = Connection(channel, id: 'c6');
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    connection.sendBinary(bytes);

    expect(channel.written, hasLength(1));
    expect(channel.written.single, same(bytes));
  });

  test('close forwards the code and reason to the channel sink', () async {
    final channel = FakeWebSocketChannel();
    final connection = Connection(channel, id: 'c7');
    await connection.close(4001, 'bye');
    expect(channel.closeCode, 4001);
    expect(channel.closeReason, 'bye');
  });

  test('close with no arguments still closes the sink', () async {
    final channel = FakeWebSocketChannel();
    final connection = Connection(channel, id: 'c8');
    await connection.close();
    expect(channel.closeCode, isNull);
    expect(channel.closeReason, isNull);
  });
}
