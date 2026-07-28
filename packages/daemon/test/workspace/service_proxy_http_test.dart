import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:agent_daemon/src/workspace/service_proxy_http.dart';
import 'package:agent_daemon/src/workspace/service_proxy_route_registry.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer upstream;
  late WsServer daemon;
  late ServiceProxyRouteRegistry routes;

  setUp(() async {
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen(socket.add);
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = 201
        ..headers.set('x-upstream', 'yes')
        ..write(
          jsonEncode({
            'method': request.method,
            'uri': request.uri.toString(),
            'body': body,
            'forwardedFor': request.headers.value('x-forwarded-for'),
            'forwardedHost': request.headers.value('x-forwarded-host'),
            'forwardedProto': request.headers.value('x-forwarded-proto'),
            'custom': request.headers.value('x-custom'),
          }),
        );
      await request.response.close();
    });

    routes = ServiceProxyRouteRegistry();
    routes.registerWorkspaceService(
      workspaceId: 'workspace-1',
      projectSlug: 'repo',
      branchName: null,
      scriptName: 'web',
      port: upstream.port,
    );
    daemon = WsServer(
      router: RpcRouter(),
      serviceProxyHandler: ServiceProxyHttpHandler(routes: routes).call,
    );
    await daemon.start(host: '127.0.0.1', port: 0);
  });

  tearDown(() async {
    await daemon.stop();
    await upstream.close(force: true);
  });

  test('forwards method, path, query, body, and proxy headers', () async {
    final client = HttpClient();
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${daemon.port}/nested/path?q=hello'),
    );
    request.headers
      ..host = 'web--repo.localhost'
      ..set('x-custom', 'present')
      ..set('connection', 'keep-alive');
    request.write('payload');
    final response = await request.close();
    final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
    client.close();

    expect(response.statusCode, 201);
    expect(response.headers.value('x-upstream'), 'yes');
    expect(body['method'], 'POST');
    expect(body['uri'], '/nested/path?q=hello');
    expect(body['body'], 'payload');
    expect(body['forwardedFor'], '127.0.0.1');
    expect(body['forwardedHost'], 'web--repo.localhost');
    expect(body['forwardedProto'], 'http');
    expect(body['custom'], 'present');
  });

  test('returns exact known-miss and unreachable responses', () async {
    final client = HttpClient();
    final missingRequest = await client.getUrl(
      Uri.parse('http://127.0.0.1:${daemon.port}/'),
    );
    missingRequest.headers.host = 'missing--repo.localhost';
    final missing = await missingRequest.close();
    expect(missing.statusCode, 404);
    expect(await utf8.decoder.bind(missing).join(), '404 Not Found');

    routes.registerWorkspaceService(
      workspaceId: 'workspace-1',
      projectSlug: 'repo',
      branchName: null,
      scriptName: 'dead',
      port: 1,
    );
    final deadRequest = await client.getUrl(
      Uri.parse('http://127.0.0.1:${daemon.port}/'),
    );
    deadRequest.headers.host = 'dead--repo.localhost';
    final dead = await deadRequest.close();
    expect(dead.statusCode, 502);
    expect(await utf8.decoder.bind(dead).join(), '502 Bad Gateway');
    client.close();
  });

  test('daemon traffic falls through to the existing server', () async {
    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:${daemon.port}/api/health'),
    );
    final response = await request.close();
    final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
    client.close();
    expect(response.statusCode, 200);
    expect(body['status'], 'ok');
  });

  test('forwards WebSocket upgrades and bidirectional frames', () async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${daemon.port}/socket?channel=one',
      headers: {'Host': 'web--repo.localhost'},
    );
    socket.add('hello');
    expect(await socket.first, 'hello');
    await socket.close();
  });
}
