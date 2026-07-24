/// Unit tests for [RpcRouter] itself. `ws_server_test.dart` already exercises
/// dispatch indirectly through a live WebSocket connection (hello handshake,
/// a registered handler, and the unauthenticated-request path); these tests
/// fill in the gaps that only make sense at the router level: unknown
/// request types, [RpcException] mapping, uncaught-exception mapping, and
/// that the handler receives the exact connection/payload it was given.
library;

import 'dart:async';

import 'package:agent_daemon/src/server/connection.dart';
import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Minimal in-memory [WebSocketChannel] double; dispatch() never touches the
/// channel directly, but [Connection] requires one to construct.
class FakeWebSocketChannel extends StreamChannelMixin
    implements WebSocketChannel {
  final _incoming = StreamController<Object?>.broadcast();
  late final WebSocketSink _sink =
      _FakeSink(_Collector());

  @override
  String? get protocol => null;
  @override
  int? closeCode;
  @override
  String? closeReason;
  @override
  Future<void> get ready => Future.value();
  @override
  Stream get stream => _incoming.stream;
  @override
  WebSocketSink get sink => _sink;
}

class _FakeSink extends DelegatingStreamSink implements WebSocketSink {
  _FakeSink(super.inner);
  @override
  Future close([int? closeCode, String? closeReason]) => super.close();
}

class _Collector implements StreamSink<Object?> {
  @override
  void add(Object? event) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future addStream(Stream event) async {}
  @override
  Future close() async {}
  @override
  Future get done => Future.value();
}

void main() {
  late RpcRouter router;
  late Connection connection;

  setUp(() {
    router = RpcRouter();
    connection = Connection(FakeWebSocketChannel(), id: 'conn-1');
  });

  test('on() asserts request types end with ".request"', () {
    expect(
      () => router.on('agent.state', (_, __) async => {}),
      throwsA(isA<AssertionError>()),
    );
  });

  test('dispatch returns unknownType error for an unregistered type',
      () async {
    const request = RpcRequest(type: 'nope.request', requestId: 'r1');
    final response = await router.dispatch(connection, request);
    expect(response.isError, isTrue);
    expect(response.error!.code, RpcErrorCodes.unknownType);
    expect(response.type, 'nope.response');
    expect(response.requestId, 'r1');
  });

  test('dispatch routes to the registered handler with the same connection '
      'and payload, and wraps the result as a success response', () async {
    Connection? seenConnection;
    Map<String, Object?>? seenPayload;
    router.on('echo.request', (conn, payload) async {
      seenConnection = conn;
      seenPayload = payload;
      return {'ok': true};
    });

    final request = RpcRequest(
      type: 'echo.request',
      requestId: 'r2',
      payload: const {'a': 1},
    );
    final response = await router.dispatch(connection, request);

    expect(identical(seenConnection, connection), isTrue);
    expect(seenPayload, {'a': 1});
    expect(response.isError, isFalse);
    expect(response.payload, {'ok': true});
    expect(response.type, 'echo.response');
    expect(response.requestId, 'r2');
  });

  test('dispatch supports synchronous handlers (FutureOr)', () async {
    router.on('sync.request', (conn, payload) => {'value': 42});
    final response = await router.dispatch(
      connection,
      const RpcRequest(type: 'sync.request', requestId: 'r3'),
    );
    expect(response.payload, {'value': 42});
  });

  test('RpcException thrown by a handler is converted to a typed error '
      'response', () async {
    router.on('boom.request', (conn, payload) async {
      throw RpcException(RpcErrorCodes.invalidPayload, 'bad stuff');
    });
    final response = await router.dispatch(
      connection,
      const RpcRequest(type: 'boom.request', requestId: 'r4'),
    );
    expect(response.isError, isTrue);
    expect(response.error!.code, RpcErrorCodes.invalidPayload);
    expect(response.error!.message, 'bad stuff');
  });

  test('an uncaught non-RpcException from a handler is mapped to an '
      'internal error carrying its toString()', () async {
    router.on('crash.request', (conn, payload) async {
      throw StateError('unexpected crash');
    });
    final response = await router.dispatch(
      connection,
      const RpcRequest(type: 'crash.request', requestId: 'r5'),
    );
    expect(response.isError, isTrue);
    expect(response.error!.code, RpcErrorCodes.internal);
    expect(response.error!.message, contains('unexpected crash'));
  });

  test('RpcException.toString() delegates to the underlying error', () {
    final e = RpcException('some_code', 'some message');
    expect(e.toString(), contains('some_code'));
    expect(e.toString(), contains('some message'));
    expect(e.error.code, 'some_code');
    expect(e.error.message, 'some message');
  });

  test('later registrations for the same type overwrite earlier ones',
      () async {
    router.on('dup.request', (conn, payload) async => {'v': 1});
    router.on('dup.request', (conn, payload) async => {'v': 2});
    final response = await router.dispatch(
      connection,
      const RpcRequest(type: 'dup.request', requestId: 'r6'),
    );
    expect(response.payload, {'v': 2});
  });
}
