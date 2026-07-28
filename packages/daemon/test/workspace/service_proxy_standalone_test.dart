import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/workspace/service_proxy_http.dart';
import 'package:agent_daemon/src/workspace/service_proxy_route_registry.dart';
import 'package:agent_daemon/src/workspace/service_proxy_standalone.dart';
import 'package:dart_ipc/dart_ipc.dart' as ipc;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late HttpServer upstream;
  late ServiceProxyRouteRegistry routes;
  late ServiceProxyStandaloneServer standalone;

  setUp(() async {
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen(socket.add);
        return;
      }
      request.response.write(
        jsonEncode({
          'path': request.uri.toString(),
          'forwardedHost': request.headers.value('x-forwarded-host'),
        }),
      );
      await request.response.close();
    });
    routes = ServiceProxyRouteRegistry()
      ..registerWorkspaceService(
        workspaceId: 'workspace',
        projectSlug: 'repo',
        branchName: null,
        scriptName: 'web',
        port: upstream.port,
      );
    standalone = ServiceProxyStandaloneServer(
      proxy: ServiceProxyHttpHandler(routes: routes),
    );
  });

  tearDown(() async {
    await standalone.stop();
    await upstream.close(force: true);
  });

  test('TCP lifecycle resolves port, proxies, and is idempotent', () async {
    final bound = await standalone.start(
      const ServiceProxyTcpTarget(host: '127.0.0.1', port: 0),
    );
    expect(bound, isA<ServiceProxyTcpTarget>());
    final port = (bound as ServiceProxyTcpTarget).port;
    expect(port, greaterThan(0));
    expect(standalone.isRunning, isTrue);
    expect(
      identical(
        await standalone.start(
          const ServiceProxyTcpTarget(host: '127.0.0.1', port: 1),
        ),
        bound,
      ),
      isTrue,
    );

    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/path?q=one'),
    );
    request.headers.host = 'web--repo.localhost';
    final response = await request.close();
    final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
    expect(response.statusCode, 200);
    expect(body['path'], '/path?q=one');
    expect(body['forwardedHost'], 'web--repo.localhost');

    final missingRequest = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/'),
    );
    final missing = await missingRequest.close();
    expect(missing.statusCode, 404);
    await missing.drain<void>();
    client.close();

    await standalone.stop();
    expect(standalone.isRunning, isFalse);
    expect(standalone.boundTarget, isNull);
    await standalone.stop();
    await expectLater(
      HttpClient().getUrl(Uri.parse('http://127.0.0.1:$port/')),
      throwsA(isA<SocketException>()),
    );
  });

  test('Unix socket lifecycle serves and removes its socket file', () async {
    if (Platform.isWindows) return;
    final directory = Directory.systemTemp.createTempSync(
      'service-proxy-socket-',
    );
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    final path = p.join(directory.path, 'proxy.sock');
    final bound = await standalone.start(ServiceProxySocketTarget(path));
    expect(bound, isA<ServiceProxySocketTarget>());
    expect(File(path).existsSync(), isTrue);
    await standalone.stop();
    expect(File(path).existsSync(), isFalse);
  });

  test('Windows named pipe proxies HTTP and WebSocket traffic', () async {
    if (!Platform.isWindows) return;
    final path =
        r'\\.\pipe\tinyrack-service-proxy-' +
        '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final bound = await standalone.start(ServiceProxyPipeTarget(path));
    expect(bound, isA<ServiceProxyPipeTarget>());
    expect((bound as ServiceProxyPipeTarget).path, path);
    expect(standalone.isRunning, isTrue);

    final client = HttpClient()
      ..connectionFactory = (uri, proxyHost, proxyPort) async =>
          ConnectionTask.fromSocket(ipc.connect(path), () {});
    final request = await client.getUrl(
      Uri.parse('http://localhost/named-pipe?q=one'),
    );
    request.headers.host = 'web--repo.localhost';
    final response = await request.close();
    final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
    expect(response.statusCode, 200);
    expect(body['path'], '/named-pipe?q=one');
    expect(body['forwardedHost'], 'web--repo.localhost');

    final socket = await WebSocket.connect(
      'ws://localhost/socket',
      headers: {'Host': 'web--repo.localhost'},
      customClient: client,
    );
    socket.add('hello over pipe');
    expect(await socket.first, 'hello over pipe');
    await socket.close();
    client.close(force: true);

    await standalone.stop();
    expect(standalone.isRunning, isFalse);
    await expectLater(ipc.connect(path), throwsA(isA<IOException>()));
  });

  test('platform-incompatible local transports fail cleanly', () async {
    if (!Platform.isWindows) {
      await expectLater(
        standalone.start(const ServiceProxyPipeTarget(r'\\.\pipe\tinyrack')),
        throwsUnsupportedError,
      );
      expect(standalone.isRunning, isFalse);
    }
    if (Platform.isWindows) {
      await expectLater(
        standalone.start(const ServiceProxySocketTarget('proxy.sock')),
        throwsUnsupportedError,
      );
      expect(standalone.isRunning, isFalse);
    }
  });

  test('listen target parser covers TCP, IPv6, socket, and pipe forms', () {
    final tcp = parseServiceProxyListenTarget('127.0.0.1:7000');
    expect(tcp, isA<ServiceProxyTcpTarget>());
    expect((tcp as ServiceProxyTcpTarget).host, '127.0.0.1');
    expect(tcp.port, 7000);

    final ipv6 = parseServiceProxyListenTarget('[::1]:7001');
    expect((ipv6 as ServiceProxyTcpTarget).host, '::1');
    expect(ipv6.port, 7001);
    expect(
      (parseServiceProxyListenTarget('unix:///tmp/proxy.sock')
              as ServiceProxySocketTarget)
          .path,
      '/tmp/proxy.sock',
    );
    expect(
      parseServiceProxyListenTarget('/tmp/direct.sock'),
      isA<ServiceProxySocketTarget>(),
    );
    expect(
      parseServiceProxyListenTarget(r'\\.\pipe\tinyrack'),
      isA<ServiceProxyPipeTarget>(),
    );
    for (final invalid in ['', 'localhost', 'localhost:70000', '://']) {
      expect(
        () => parseServiceProxyListenTarget(invalid),
        throwsFormatException,
      );
    }
  });
}
