import 'dart:convert';

import 'package:agent_daemon/src/providers/exe_resolver.dart';
import 'package:agent_daemon/src/providers/provider_registry.dart';
import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  late WsServer server;

  setUp(() async {
    final registry = ProviderRegistry(ExeResolver());
    final router = RpcRouter()
      ..on(MessageTypes.providerListRequest, (_, __) async {
        final providers = await registry.list();
        return ProviderListResponse(providers: providers).toJson();
      });
    server = WsServer(router: router);
    await server.start(host: '127.0.0.1', port: 0);
  });

  tearDown(() => server.stop());

  Future<(WebSocketChannel, Stream<Map<String, Object?>>)> connect() async {
    final channel =
        WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${server.port}'));
    await channel.ready;
    final frames = channel.stream
        .map((f) => jsonDecode(f as String) as Map<String, Object?>)
        .asBroadcastStream();
    return (channel, frames);
  }

  test('hello handshake then provider.list', () async {
    final (channel, frames) = await connect();

    channel.sink.add(jsonEncode(const RpcRequest(
      type: MessageTypes.clientHelloRequest,
      requestId: 'h1',
      payload: {'clientName': 'test', 'clientVersion': '0.0.1'},
    ).toJson()));
    final hello = await frames.first;
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
    expect(list.providers, hasLength(2));

    await channel.sink.close();
  });

  test('requests before hello are rejected', () async {
    final (channel, frames) = await connect();
    channel.sink.add(jsonEncode(const RpcRequest(
      type: MessageTypes.providerListRequest,
      requestId: 'p1',
    ).toJson()));
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
        Uri.parse('ws://127.0.0.1:${tokenServer.port}'));
    await channel.ready;
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
}
