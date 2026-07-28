@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tinyrack_relay/tinyrack_relay.dart';

void main() {
  late TinyrackRelayServer relay;

  setUp(() async {
    relay = TinyrackRelayServer(
      sessionFactory: () =>
          RelaySession(initialControlNudgeDelay: const Duration(hours: 1)),
    );
    await relay.start();
  });

  tearDown(() => relay.close());

  Uri http(String path) => relay.httpUri.resolve(path);
  Uri ws(String path) => http(path).replace(scheme: 'ws');

  test('health, routing, validation, and lifecycle match the worker', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    expect(await _get(client, http('/health')), (200, '{"status":"ok"}'));
    expect(await _get(client, http('/missing')), (404, 'Not found'));
    expect(await _get(client, http('/ws?serverId=s&role=nope')), (
      400,
      'Missing or invalid role parameter',
    ));
    expect(await _get(client, http('/ws?role=server')), (
      400,
      'Missing serverId parameter',
    ));
    expect(await _get(client, http('/ws?role=server&serverId=s&v=3')), (
      400,
      'Invalid v parameter (expected 1 or 2)',
    ));
    expect(await _get(client, http('/ws?role=server&serverId=s&v=2')), (
      426,
      'Expected WebSocket upgrade',
    ));
    expect(resolveRelayVersion(null), '1');
    expect(resolveRelayVersion('  '), '1');
    expect(resolveRelayVersion(2), '2');
    expect(resolveRelayVersion('bad'), isNull);
    expect(() => relay.start(), throwsStateError);
    expect(relay.isRunning, isTrue);
    expect(relay.boundPort, greaterThan(0));
  });

  test('legacy v1 sockets forward text and binary frames', () async {
    final server = await WebSocket.connect(
      ws('/ws?serverId=v1&role=server').toString(),
    );
    final client = await WebSocket.connect(
      ws('/ws?serverId=v1&role=client&v=1').toString(),
    );
    addTearDown(server.close);
    addTearDown(client.close);

    final serverText = server.first;
    client.add('client text');
    expect(await serverText, 'client text');

    final clientBytes = client.first;
    server.add(Uint8List.fromList([0xff, 1, 2]));
    expect(await clientBytes, orderedEquals([0xff, 1, 2]));
  });

  test(
    'v2 control/data routes clients independently and preserves buffers',
    () async {
      final control = await WebSocket.connect(
        ws('/ws?serverId=v2&role=server&v=2').toString(),
      );
      final controlReader = _SocketReader(control);
      addTearDown(control.close);
      addTearDown(controlReader.cancel);
      expect(jsonDecode(await controlReader.next() as String), {
        'type': 'sync',
        'connectionIds': <Object?>[],
      });

      final connectedFuture = controlReader.next();
      final firstClient = await WebSocket.connect(
        ws('/ws?serverId=v2&role=client&connectionId=first&v=2').toString(),
      );
      addTearDown(firstClient.close);
      expect(jsonDecode(await connectedFuture as String), {
        'type': 'connected',
        'connectionId': 'first',
      });

      firstClient.add('buffered');
      final firstServer = await WebSocket.connect(
        ws('/ws?serverId=v2&role=server&connectionId=first&v=2').toString(),
      );
      addTearDown(firstServer.close);
      expect(await firstServer.first, 'buffered');

      final secondConnected = controlReader.next();
      final secondClient = await WebSocket.connect(
        ws('/ws?serverId=v2&role=client&connectionId=second&v=2').toString(),
      );
      addTearDown(secondClient.close);
      await secondConnected;
      final secondServer = await WebSocket.connect(
        ws('/ws?serverId=v2&role=server&connectionId=second&v=2').toString(),
      );
      addTearDown(secondServer.close);

      final firstInbound = firstClient.first;
      final secondInbound = secondClient.first;
      firstServer.add('only-first');
      secondServer.add('only-second');
      expect(await firstInbound, 'only-first');
      expect(await secondInbound, 'only-second');
    },
  );

  test('v1 and v2 sessions with the same server id are isolated', () async {
    final v1Server = await WebSocket.connect(
      ws('/ws?serverId=same&role=server&v=1').toString(),
    );
    final v1Client = await WebSocket.connect(
      ws('/ws?serverId=same&role=client&v=1').toString(),
    );
    final v2Control = await WebSocket.connect(
      ws('/ws?serverId=same&role=server&v=2').toString(),
    );
    final controlReader = _SocketReader(v2Control);
    addTearDown(v1Server.close);
    addTearDown(v1Client.close);
    addTearDown(v2Control.close);
    addTearDown(controlReader.cancel);
    await controlReader.next();

    final v1Message = v1Server.first;
    v1Client.add('legacy-only');
    expect(await v1Message, 'legacy-only');
  });

  test(
    'v2 client without id gets a generated connection notification',
    () async {
      final control = await WebSocket.connect(
        ws('/ws?serverId=generated&role=server&v=2').toString(),
      );
      final controlReader = _SocketReader(control);
      addTearDown(control.close);
      addTearDown(controlReader.cancel);
      await controlReader.next();
      final notice = controlReader.next();
      final client = await WebSocket.connect(
        ws('/ws?serverId=generated&role=client&v=2').toString(),
      );
      addTearDown(client.close);

      final decoded = jsonDecode(await notice as String) as Map;
      expect(decoded['type'], 'connected');
      expect(decoded['connectionId'], startsWith('conn_'));
    },
  );
}

Future<(int, String)> _get(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  final response = await request.close();
  return (response.statusCode, await utf8.decodeStream(response));
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
