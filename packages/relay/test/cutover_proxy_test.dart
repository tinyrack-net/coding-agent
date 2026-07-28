@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';

void main() {
  test('URI rewriting preserves path and query on the configured origin', () {
    expect(
      rewriteRelayCutoverUri(
        Uri.parse(
          'https://relay.tinyrack.dev/ws?serverId=server-1&role=server&v=2',
        ),
        Uri.parse('http://127.0.0.1:8787/base?ignored=yes'),
      ),
      Uri.parse('http://127.0.0.1:8787/ws?serverId=server-1&role=server&v=2'),
    );
    expect(
      () => RelayCutoverProxy(Uri.parse('ftp://example.com')),
      throwsFormatException,
    );
  });

  test(
    'HTTP cutover forwards method, route, headers, body, and response',
    () async {
      final received = Completer<Map<String, Object?>>();
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((request) async {
        received.complete({
          'method': request.method,
          'path': request.uri.toString(),
          'probe': request.headers.value('x-relay-probe'),
          'body': await utf8.decodeStream(request),
        });
        request.response.statusCode = HttpStatus.accepted;
        request.response.headers.set('x-relay-origin', 'reference');
        request.response.write('forwarded');
        await request.response.close();
      });
      addTearDown(() => origin.close(force: true));

      final relay = TinyrackRelayServer(
        upstream: Uri.parse('http://127.0.0.1:${origin.port}'),
      );
      await relay.start();
      addTearDown(relay.close);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.postUrl(
        relay.httpUri.resolve('/ws?serverId=server-1&role=server&v=2'),
      );
      request.headers.set('x-relay-probe', 'production');
      request.write('payload');
      final response = await request.close();

      expect(response.statusCode, HttpStatus.accepted);
      expect(response.headers.value('x-relay-origin'), 'reference');
      expect(await utf8.decodeStream(response), 'forwarded');
      expect(await received.future, {
        'method': 'POST',
        'path': '/ws?serverId=server-1&role=server&v=2',
        'probe': 'production',
        'body': 'payload',
      });
    },
  );

  test(
    'WebSocket cutover forwards text and binary in both directions',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((message) {
          if (message is String) {
            socket.add('origin:$message');
          } else {
            socket.add(message);
          }
        });
      });
      addTearDown(() => origin.close(force: true));

      final relay = TinyrackRelayServer(
        upstream: Uri.parse('http://127.0.0.1:${origin.port}'),
      );
      await relay.start();
      addTearDown(relay.close);
      final socket = await WebSocket.connect(
        relay.httpUri
            .resolve('/ws?serverId=server-1&role=client&v=2')
            .replace(scheme: 'ws')
            .toString(),
      );
      final reader = _SocketReader(socket);
      addTearDown(socket.close);
      addTearDown(reader.cancel);

      final text = reader.next();
      socket.add('hello');
      expect(await text, 'origin:hello');
      final bytes = reader.next();
      socket.add(<int>[0xff, 1, 2]);
      expect(await bytes, orderedEquals([0xff, 1, 2]));
    },
  );

  test('unavailable cutover origin returns a bad gateway', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final relay = TinyrackRelayServer(
      upstream: Uri.parse('http://127.0.0.1:$port'),
    );
    await relay.start();
    addTearDown(relay.close);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(relay.httpUri.resolve('/health'));
    final response = await request.close();

    expect(response.statusCode, HttpStatus.badGateway);
    expect(await utf8.decodeStream(response), contains('upstream unavailable'));
  });
}

final class _SocketReader {
  _SocketReader(Stream<dynamic> stream) : _iterator = StreamIterator(stream);

  final StreamIterator<dynamic> _iterator;

  Future<dynamic> next() async {
    if (!await _iterator.moveNext()) throw StateError('Socket closed');
    return _iterator.current;
  }

  Future<void> cancel() => _iterator.cancel();
}
