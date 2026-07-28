import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/src/providers/native/credential_store.dart';
import 'package:agent_daemon/src/providers/provider_registry.dart';
import 'package:agent_daemon/src/server/connection.dart';
import 'package:agent_daemon/src/server/daemon_auth.dart';
import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  late WsServer server;
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('ws_server_test_');
    final registry = ProviderRegistry(CredentialStore(dataDir: tempDir.path));
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

  Future<(WebSocketChannel, Stream<Map<String, Object?>>)> connect() async {
    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${server.port}'),
    );
    await channel.ready;
    final frames = channel.stream
        .map((f) => jsonDecode(f as String) as Map<String, Object?>)
        .asBroadcastStream();
    return (channel, frames);
  }

  test('hello handshake then provider.list', () async {
    final (channel, frames) = await connect();

    channel.sink.add(
      jsonEncode(
        const RpcRequest(
          type: MessageTypes.clientHelloRequest,
          requestId: 'h1',
          payload: {'clientName': 'test', 'clientVersion': '0.0.1'},
        ).toJson(),
      ),
    );
    final hello = await frames.first;
    expect(hello['type'], 'client.hello.response');
    final serverHello = ServerHello.fromJson(
      hello['payload'] as Map<String, Object?>,
    );
    expect(serverHello.protocolVersion, protocolVersion);

    channel.sink.add(
      jsonEncode(
        const RpcRequest(
          type: MessageTypes.providerListRequest,
          requestId: 'p1',
        ).toJson(),
      ),
    );
    final response = await frames.firstWhere(
      (f) => f['type'] == 'provider.list.response',
    );
    final list = ProviderListResponse.fromJson(
      response['payload'] as Map<String, Object?>,
    );
    expect(list.providers, hasLength(3));

    await channel.sink.close();
  });

  test(
    'serves unauthenticated health and server status HTTP endpoints',
    () async {
      final health = await http.get(
        Uri.parse('http://127.0.0.1:${server.port}/api/health'),
        headers: {'origin': 'http://127.0.0.1:${server.port}'},
      );
      expect(health.statusCode, 200);
      expect(jsonDecode(health.body), containsPair('status', 'ok'));
      expect(
        health.headers['access-control-allow-origin'],
        'http://127.0.0.1:${server.port}',
      );

      final status = await http.get(
        Uri.parse('http://127.0.0.1:${server.port}/api/status'),
      );
      expect(status.statusCode, 200);
      final payload = jsonDecode(status.body) as Map<String, Object?>;
      expect(payload['status'], 'server_info');
      expect(payload['serverId'], isNotEmpty);
    },
  );

  test(
    'v2 /ws hello emits server_info and wraps RPC session responses',
    () async {
      String? nativeConnectionId;
      server.onV2SessionMessage = (connection, message) {
        if (message['type'] != 'native.request') return null;
        nativeConnectionId = connection.id;
        return {'type': 'native.response', 'requestId': message['requestId']};
      };
      final channel = WebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${server.port}/ws'),
      );
      await channel.ready;
      final frames = channel.stream
          .map((frame) => jsonDecode(frame as String) as Map<String, Object?>)
          .asBroadcastStream();

      channel.sink.add(jsonEncode(const {'type': 'ping'}));
      expect(await frames.first, const {'type': 'pong'});

      channel.sink.add(
        jsonEncode(
          const WebSocketHello(
            clientId: 'flutter-desktop',
            clientType: WebSocketClientType.browser,
            protocolVersion: paseoWebSocketProtocolVersion,
            appVersion: '0.2.0',
            capabilities: {'voice': true},
          ).toJson(),
        ),
      );
      final serverInfo = await frames.firstWhere(
        (frame) => frame['status'] == 'server_info',
      );
      expect(serverInfo['serverId'], server.serverId);
      expect(serverInfo['features'], containsPair('workspaceRecovery', true));
      expect(
        serverInfo['features'],
        containsPair('importSessionWorkspaceTarget', true),
      );

      server.broadcast(const RpcEvent(type: 'agent.state', payload: {'id': 1}));
      final event = await frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map<String, Object?>)['type'] == 'agent.state',
      );
      expect((event['message'] as Map<String, Object?>)['payload'], {'id': 1});

      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': const RpcRequest(
            type: MessageTypes.providerListRequest,
            requestId: 'v2-list',
          ).toJson(),
        }),
      );
      final wrapped = await frames.firstWhere(
        (frame) => frame['type'] == 'session',
      );
      final response = wrapped['message'] as Map<String, Object?>;
      expect(response['type'], 'provider.list.response');

      channel.sink.add(
        jsonEncode({
          'type': 'session',
          'message': {'type': 'native.request', 'requestId': 'native-1'},
        }),
      );
      final native = await frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map<String, Object?>)['type'] ==
                'native.response',
      );
      expect(
        (native['message'] as Map<String, Object?>)['requestId'],
        'native-1',
      );
      expect(server.connectionById(nativeConnectionId!)?.appVersion, '0.2.0');

      server.broadcastV2(
        const {
          'type': 'workspace_update',
          'payload': {'kind': 'remove'},
        },
        connectionIds: {nativeConnectionId!},
      );
      final broadcast = await frames.firstWhere(
        (frame) =>
            frame['type'] == 'session' &&
            (frame['message'] as Map<String, Object?>)['type'] ==
                'workspace_update',
      );
      expect((broadcast['message'] as Map<String, Object?>)['payload'], {
        'kind': 'remove',
      });
      await channel.sink.close();
    },
  );

  test('v2 server_info publishes deduplicated speech capabilities', () async {
    const ready = {
      'voice': {
        'dictation': {'enabled': true, 'reason': ''},
        'voice': {'enabled': true, 'reason': ''},
      },
    };
    server.updateServerCapabilities(ready);
    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${server.port}/ws'),
    );
    await channel.ready;
    final frames = channel.stream
        .map((frame) => jsonDecode(frame as String) as Map<String, Object?>)
        .asBroadcastStream();
    channel.sink.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'speech-capabilities',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    final initial = await frames.firstWhere(
      (frame) => frame['status'] == 'server_info',
    );
    expect(initial['capabilities'], ready);

    server.updateServerCapabilities(ready);
    server.updateServerCapabilities(const {
      'voice': {
        'dictation': {'enabled': false, 'reason': 'Disabled'},
        'voice': {'enabled': true, 'reason': ''},
      },
    });
    final changed = await frames.firstWhere(
      (frame) => frame['status'] == 'server_info',
    );
    expect(((changed['capabilities'] as Map)['voice'] as Map)['dictation'], {
      'enabled': false,
      'reason': 'Disabled',
    });

    server.updateServerCapabilities(null);
    final cleared = await frames.firstWhere(
      (frame) => frame['status'] == 'server_info',
    );
    expect(cleared, isNot(contains('capabilities')));
    await channel.sink.close();
  });

  test('v2 session response runs its post-send flush in wire order', () async {
    server.onV2SessionMessage = (connection, message) {
      if (message['type'] != 'snapshot.request') return null;
      return V2SessionResponse(
        message: const {
          'type': 'snapshot.response',
          'payload': {'requestId': 'snapshot-1'},
        },
        afterSend: () => connection.sendJson(const {
          'type': 'session',
          'message': {
            'type': 'agent_update',
            'payload': {'kind': 'remove', 'agentId': 'agent-1'},
          },
        }),
      );
    };
    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${server.port}/ws'),
    );
    await channel.ready;
    final frames = channel.stream
        .map((frame) => jsonDecode(frame as String) as Map<String, Object?>)
        .asBroadcastStream();
    channel.sink.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'flutter-desktop',
          clientType: WebSocketClientType.browser,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await frames.firstWhere((frame) => frame['status'] == 'server_info');

    final nextTwo = frames
        .where((frame) => frame['type'] == 'session')
        .take(2)
        .toList();
    channel.sink.add(
      jsonEncode({
        'type': 'session',
        'message': {'type': 'snapshot.request', 'requestId': 'snapshot-1'},
      }),
    );
    final messages = [
      for (final frame in await nextTwo)
        frame['message'] as Map<String, Object?>,
    ];

    expect(messages.map((message) => message['type']), [
      'snapshot.response',
      'agent_update',
    ]);
    await channel.sink.close();
  });

  test(
    'v2 broadcast selects canonical timeline unless legacy is requested',
    () async {
      Future<(WebSocketChannel, Stream<Map<String, Object?>>)> connectV2(
        String clientId,
        Map<String, Object?> capabilities,
      ) async {
        final channel = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${server.port}/ws'),
        );
        await channel.ready;
        final frames = channel.stream
            .map((frame) => jsonDecode(frame as String) as Map<String, Object?>)
            .asBroadcastStream();
        channel.sink.add(
          jsonEncode(
            WebSocketHello(
              clientId: clientId,
              clientType: WebSocketClientType.browser,
              protocolVersion: paseoWebSocketProtocolVersion,
              capabilities: capabilities,
            ).toJson(),
          ),
        );
        await frames.firstWhere((frame) => frame['status'] == 'server_info');
        return (channel, frames);
      }

      final (canonicalChannel, canonicalFrames) = await connectV2(
        'canonical',
        const {},
      );
      final (legacyChannel, legacyFrames) = await connectV2('legacy', const {
        'tinyrackLegacyTimelineV1': true,
      });
      const legacy = RpcEvent(type: 'agent.stream', payload: {'seq': 1});
      const canonical = {
        'type': 'agent_stream',
        'payload': {'seq': 1},
      };

      final canonicalEnvelopeFuture = canonicalFrames.firstWhere(
        (frame) => frame['type'] == 'session',
      );
      final legacyEnvelopeFuture = legacyFrames.firstWhere(
        (frame) => frame['type'] == 'session',
      );
      server.broadcast(
        legacy,
        v2Message: canonical,
        legacyV2Capability: 'tinyrackLegacyTimelineV1',
      );

      final canonicalEnvelope = await canonicalEnvelopeFuture;
      final legacyEnvelope = await legacyEnvelopeFuture;
      expect(canonicalEnvelope['message'], canonical);
      expect(
        (legacyEnvelope['message'] as Map<String, Object?>)['type'],
        'agent.stream',
      );

      await canonicalChannel.sink.close();
      await legacyChannel.sink.close();
    },
  );

  test('v2 broadcast only reaches selected connection ids', () async {
    Future<(WebSocketChannel, Stream<Map<String, Object?>>)> connectV2(
      String clientId,
    ) async {
      final channel = WebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${server.port}/ws'),
      );
      await channel.ready;
      final frames = channel.stream
          .map((frame) => jsonDecode(frame as String) as Map<String, Object?>)
          .asBroadcastStream();
      channel.sink.add(
        jsonEncode(
          WebSocketHello(
            clientId: clientId,
            clientType: WebSocketClientType.browser,
            protocolVersion: paseoWebSocketProtocolVersion,
            capabilities: const {},
          ).toJson(),
        ),
      );
      await frames.firstWhere((frame) => frame['status'] == 'server_info');
      return (channel, frames);
    }

    final (selectedChannel, selectedFrames) = await connectV2('selected');
    final (otherChannel, otherFrames) = await connectV2('other');
    final selectedId = server.authenticatedV2Connections
        .singleWhere((connection) => connection.clientName == 'selected')
        .id;

    server.broadcast(
      const RpcEvent(type: 'legacy.marker'),
      v2Message: const {'type': 'selected_update'},
      v2ConnectionIds: {selectedId},
    );
    server.broadcastV2(const {'type': 'all_clients_marker'});

    final selectedEnvelope = await selectedFrames.firstWhere(
      (frame) => frame['type'] == 'session',
    );
    final otherEnvelope = await otherFrames.firstWhere(
      (frame) => frame['type'] == 'session',
    );
    expect(
      (selectedEnvelope['message'] as Map<String, Object?>)['type'],
      'selected_update',
    );
    expect(
      (otherEnvelope['message'] as Map<String, Object?>)['type'],
      'all_clients_marker',
    );

    await selectedChannel.sink.close();
    await otherChannel.sink.close();
  });

  test(
    'password protects HTTP status and authenticates /ws subprotocol',
    () async {
      final hash = hashDaemonPassword('correct-password');
      final protected = WsServer(router: RpcRouter(), passwordHash: hash);
      await protected.start(host: '127.0.0.1', port: 0);
      addTearDown(protected.stop);

      final statusUri = Uri.parse(
        'http://127.0.0.1:${protected.port}/api/status',
      );
      expect((await http.get(statusUri)).statusCode, 401);
      expect(
        (await http.get(
          statusUri,
          headers: {'authorization': 'Bearer correct-password'},
        )).statusCode,
        200,
      );
      expect(
        (await http.get(
          Uri.parse('http://127.0.0.1:${protected.port}/api/health'),
        )).statusCode,
        200,
      );

      final channel = WebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${protected.port}/ws'),
        protocols: const ['paseo.bearer.correct-password'],
      );
      await channel.ready;
      expect(channel.protocol, 'paseo.bearer.correct-password');
      channel.sink.add(
        jsonEncode(
          const WebSocketHello(
            clientId: 'authenticated-client',
            clientType: WebSocketClientType.cli,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      final info =
          jsonDecode(await channel.stream.first as String)
              as Map<String, Object?>;
      expect(info['status'], 'server_info');
      await channel.sink.close();

      final rejected = WebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${protected.port}/ws'),
        protocols: const ['paseo.bearer.wrong-password'],
      );
      await rejected.ready;
      await rejected.stream.drain<void>();
      expect(rejected.closeCode, 4401);
      expect(rejected.closeReason, 'Incorrect password');
    },
  );

  test('v2 closes incompatible protocol hello with Paseo close code', () async {
    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${server.port}/ws'),
    );
    await channel.ready;
    channel.sink.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'old-client',
          clientType: WebSocketClientType.browser,
          protocolVersion: 99,
        ).toJson(),
      ),
    );
    await channel.stream.drain<void>();
    expect(channel.closeCode, 4003);
    expect(channel.closeReason, 'Incompatible protocol version');
  });

  test(
    'HTTP preflight, unknown routes, and disallowed origins are gated',
    () async {
      final client = http.Client();
      addTearDown(client.close);
      final preflight = http.Request(
        'OPTIONS',
        Uri.parse('http://127.0.0.1:${server.port}/api/status'),
      )..headers['origin'] = 'http://127.0.0.1:${server.port}';
      expect((await client.send(preflight)).statusCode, 204);
      expect(
        (await http.get(
          Uri.parse('http://127.0.0.1:${server.port}/unknown'),
        )).statusCode,
        404,
      );
      expect(
        (await http.get(
          Uri.parse('http://127.0.0.1:${server.port}/api/terminal-activity'),
        )).statusCode,
        404,
      );
      expect(
        (await http.get(
          Uri.parse('http://127.0.0.1:${server.port}/api/files/download'),
        )).statusCode,
        404,
      );
      expect(
        (await http.get(
          Uri.parse('http://127.0.0.1:${server.port}/ws'),
          headers: {'origin': 'https://evil.test'},
        )).statusCode,
        403,
      );

      final rejectedHost = http.Request(
        'GET',
        Uri.parse('http://127.0.0.1:${server.port}/api/health'),
      )..headers['host'] = 'evil.test:${server.port}';
      final rejectedHostResponse = await client.send(rejectedHost);
      expect(rejectedHostResponse.statusCode, 403);
      expect(
        await rejectedHostResponse.stream.bytesToString(),
        contains('Invalid Host header'),
      );
      expect(
        (server.flushRuntimeMetrics()['counters'] as Map)['hostRejected'],
        1,
      );

      final hostnameServer = WsServer(
        router: RpcRouter(),
        hostnames: const ['.example.test'],
      );
      await hostnameServer.start(host: '127.0.0.1', port: 0);
      addTearDown(hostnameServer.stop);
      final allowedHost =
          http.Request(
              'GET',
              Uri.parse('http://127.0.0.1:${hostnameServer.port}/api/health'),
            )
            ..headers['host'] = 'api.example.test:${hostnameServer.port}'
            ..headers['origin'] =
                'http://api.example.test:${hostnameServer.port}';
      final allowedHostResponse = await client.send(allowedHost);
      expect(allowedHostResponse.statusCode, 200);
      expect(
        allowedHostResponse.headers['access-control-allow-origin'],
        'http://api.example.test:${hostnameServer.port}',
      );
    },
  );

  test(
    'v2 rejects missing, malformed, and repeated hello/session flow',
    () async {
      Future<WebSocketChannel> open() async {
        final channel = WebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${server.port}/ws'),
        );
        await channel.ready;
        return channel;
      }

      final beforeHello = await open();
      beforeHello.sink.add(
        jsonEncode({
          'type': 'session',
          'message': const RpcRequest(
            type: MessageTypes.providerListRequest,
            requestId: 'early',
          ).toJson(),
        }),
      );
      await beforeHello.stream.drain<void>();
      expect(beforeHello.closeCode, 4002);

      final malformed = await open();
      malformed.sink.add(
        jsonEncode({
          'type': 'hello',
          'clientId': '',
          'clientType': 'browser',
          'protocolVersion': 1,
        }),
      );
      await malformed.stream.drain<void>();
      expect(malformed.closeCode, 4002);

      final repeated = await open();
      const hello = WebSocketHello(
        clientId: 'repeat',
        clientType: WebSocketClientType.browser,
        protocolVersion: paseoWebSocketProtocolVersion,
      );
      final repeatedFrames = StreamIterator<dynamic>(repeated.stream);
      repeated.sink.add(jsonEncode(hello.toJson()));
      expect(await repeatedFrames.moveNext(), isTrue);
      repeated.sink.add(jsonEncode(hello.toJson()));
      expect(await repeatedFrames.moveNext(), isFalse);
      expect(repeated.closeCode, 4002);

      final invalidSession = await open();
      final invalidSessionFrames = StreamIterator<dynamic>(
        invalidSession.stream,
      );
      invalidSession.sink.add(
        jsonEncode(
          const WebSocketHello(
            clientId: 'invalid-session',
            clientType: WebSocketClientType.cli,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      expect(await invalidSessionFrames.moveNext(), isTrue);
      invalidSession.sink.add(
        jsonEncode({
          'type': 'session',
          'message': {'not': 'an rpc frame'},
        }),
      );
      expect(await invalidSessionFrames.moveNext(), isFalse);
      expect(invalidSession.closeCode, 4002);

      final invalidSessionEnvelope = await open();
      final invalidSessionEnvelopeFrames = StreamIterator<dynamic>(
        invalidSessionEnvelope.stream,
      );
      invalidSessionEnvelope.sink.add(
        jsonEncode(
          const WebSocketHello(
            clientId: 'invalid-session-envelope',
            clientType: WebSocketClientType.cli,
            protocolVersion: paseoWebSocketProtocolVersion,
          ).toJson(),
        ),
      );
      expect(await invalidSessionEnvelopeFrames.moveNext(), isTrue);
      invalidSessionEnvelope.sink.add(
        jsonEncode({'type': 'not-session', 'message': <String, Object?>{}}),
      );
      expect(await invalidSessionEnvelopeFrames.moveNext(), isFalse);
      expect(invalidSessionEnvelope.closeCode, 4002);
    },
  );

  test('v2 hello timeout and shutdown cancel pending handshakes', () async {
    final timeoutServer = WsServer(
      router: RpcRouter(),
      helloTimeout: const Duration(milliseconds: 20),
    );
    await timeoutServer.start(host: '127.0.0.1', port: 0);
    addTearDown(timeoutServer.stop);
    final timedOut = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${timeoutServer.port}/ws'),
    );
    await timedOut.ready;
    await timedOut.stream.drain<void>();
    expect(timedOut.closeCode, 4001);

    final pendingServer = WsServer(router: RpcRouter());
    await pendingServer.start(host: '127.0.0.1', port: 0);
    final pending = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${pendingServer.port}/ws'),
    );
    await pending.ready;
    await pendingServer.stop();
    await pending.stream.drain<void>();
  });

  test('requests before hello are rejected', () async {
    final (channel, frames) = await connect();
    channel.sink.add(
      jsonEncode(
        const RpcRequest(
          type: MessageTypes.providerListRequest,
          requestId: 'p1',
        ).toJson(),
      ),
    );
    final response = await frames.first;
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
      Uri.parse('ws://127.0.0.1:${tokenServer.port}'),
    );
    await channel.ready;
    final frames = channel.stream.map(
      (f) => jsonDecode(f as String) as Map<String, Object?>,
    );
    channel.sink.add(
      jsonEncode(
        const RpcRequest(
          type: MessageTypes.clientHelloRequest,
          requestId: 'h1',
          payload: {
            'clientName': 'test',
            'clientVersion': '0.0.1',
            'token': 'wrong',
          },
        ).toJson(),
      ),
    );
    final response = await frames.first;
    expect(
      ((response['error'] as Map<String, Object?>?) ?? const {})['code'],
      RpcErrorCodes.unauthorized,
    );
  });

  Future<void> hello(
    WebSocketChannel channel,
    Stream<Map<String, Object?>> frames, {
    String id = 'h',
  }) async {
    channel.sink.add(
      jsonEncode(
        RpcRequest(
          type: MessageTypes.clientHelloRequest,
          requestId: id,
          payload: const {'clientName': 'test', 'clientVersion': '0.0.1'},
        ).toJson(),
      ),
    );
    await frames.first;
  }

  test('malformed JSON frames get a protocol.error response', () async {
    final (channel, frames) = await connect();
    channel.sink.add('not valid json {{{');
    final response = await frames.first;
    expect(response['type'], 'protocol.error');
    await channel.sink.close();
  });

  test(
    'valid JSON with an invalid legacy RPC shape gets protocol.error',
    () async {
      final (channel, frames) = await connect();
      channel.sink.add(jsonEncode({'unexpected': true}));
      final response = await frames.first;
      expect(response['type'], 'protocol.error');
      await channel.sink.close();
    },
  );

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

  test('connectionById returns the authenticated connection or null', () async {
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
    final captured = await gotFrame.future.timeout(const Duration(seconds: 5));
    expect(server.connectionById(captured.id), same(captured));

    await channel.sink.close();
  });

  test(
    'binary frames route through onBinaryFrame only once authenticated',
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
      channel.sink.add(Uint8List.fromList([1]));
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
    },
  );

  test(
    'binary frames with no onBinaryFrame handler registered are no-ops',
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
    },
  );

  test('flushes the Paseo WebSocket runtime metrics window', () async {
    server.onV2SessionMessage = (_, message) => {
      'type': 'metrics.response',
      'requestId': message['requestId'],
    };
    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${server.port}/ws'),
    );
    await channel.ready;
    final frames = channel.stream
        .map((frame) => jsonDecode(frame as String) as Map<String, Object?>)
        .asBroadcastStream();
    channel.sink.add(
      jsonEncode(
        const WebSocketHello(
          clientId: 'metrics-client',
          clientType: WebSocketClientType.cli,
          protocolVersion: paseoWebSocketProtocolVersion,
        ).toJson(),
      ),
    );
    await frames.firstWhere((frame) => frame['status'] == 'server_info');
    channel.sink.add(
      jsonEncode({
        'type': 'session',
        'message': {'type': 'metrics.request', 'requestId': 'metrics-1'},
      }),
    );
    await frames.firstWhere(
      (frame) =>
          frame['type'] == 'session' &&
          (frame['message'] as Map?)?['type'] == 'metrics.response',
    );

    final snapshot = server.flushRuntimeMetrics();
    expect(snapshot['final'], isFalse);
    expect((snapshot['counters'] as Map)['connectedAwaitingHello'], 1);
    expect((snapshot['counters'] as Map)['helloNew'], 1);
    expect(
      snapshot['inboundMessageTypesTop'],
      contains(equals(['session', 1])),
    );
    expect(
      snapshot['inboundSessionRequestTypesTop'],
      contains(equals(['metrics.request', 1])),
    );
    expect(
      snapshot['outboundSessionMessageTypesTop'],
      contains(equals(['metrics.response', 1])),
    );
    expect(
      snapshot['latency'],
      contains(containsPair('type', 'metrics.request')),
    );
    expect(snapshot['sessions'], containsPair('activeConnections', 1));
    expect(snapshot['sockets'], containsPair('activeSockets', 1));
    await channel.sink.close();
  });

  test(
    'external relay channels use the normal v2 hello/session path',
    () async {
      final inbound = StreamController<Object>();
      final outbound = StreamController<Object>();
      final sent = <Object>[];
      final outboundSubscription = outbound.stream.listen(sent.add);
      int? closeCode;
      String? closeReason;
      addTearDown(() async {
        await inbound.close();
        await outbound.close();
        await outboundSubscription.cancel();
      });
      server.onV2SessionMessage = (connection, message) {
        expect(connection.transport, 'relay');
        expect(connection.externalSessionKey, 'session:conn_test');
        expect(connection.relayConnectionId, 'conn_test');
        return {'type': 'external.response', 'requestId': message['requestId']};
      };

      final connection = server.attachExternal(
        frames: inbound.stream,
        send: outbound.add,
        close: (code, reason) {
          closeCode = code;
          closeReason = reason;
        },
        transport: 'relay',
        externalSessionKey: 'session:conn_test',
        relayConnectionId: 'conn_test',
      );
      expect(connection.isLoopback, isFalse);
      expect(server.connectionCount, 1);

      inbound.add(
        jsonEncode({
          'type': 'hello',
          'protocolVersion': paseoWebSocketProtocolVersion,
          'clientId': 'relay-client',
          'clientType': 'browser',
          'capabilities': <String, Object?>{},
        }),
      );
      await _waitUntil(
        () => sent.any(
          (frame) =>
              frame is String &&
              (jsonDecode(frame) as Map<String, Object?>)['status'] ==
                  'server_info',
        ),
      );
      expect(connection.authenticated, isTrue);

      inbound.add(
        jsonEncode({
          'type': 'session',
          'message': {'type': 'external.request', 'requestId': 'r1'},
        }),
      );
      await _waitUntil(
        () => sent.any(
          (frame) =>
              frame is String && frame.contains('"type":"external.response"'),
        ),
      );

      await connection.close(1000, 'done');
      expect(closeCode, 1000);
      expect(closeReason, 'done');
    },
  );

  test('external stream errors disconnect the attached connection', () async {
    final inbound = StreamController<Object>();
    server.attachExternal(
      frames: inbound.stream,
      send: (_) {},
      close: (_, __) {},
      transport: 'relay',
      externalSessionKey: 'session:error',
      relayConnectionId: 'error',
    );
    expect(server.connectionCount, 1);

    inbound.addError(StateError('relay transport failed'));
    await _waitUntil(() => server.connectionCount == 0);
    await inbound.close();
  });
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
