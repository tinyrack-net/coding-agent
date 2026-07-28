import 'dart:convert';
import 'dart:io';

import 'package:agent_daemon/src/server/rpc_router.dart';
import 'package:agent_daemon/src/server/web_ui.dart';
import 'package:agent_daemon/src/server/ws_server.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory dist;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tinyrack-web-ui-');
    dist = Directory(p.join(root.path, 'dist'))..createSync(recursive: true);
    File(p.join(dist.path, 'index.html')).writeAsStringSync(
      '<!doctype html><html><head></head><body>app</body></html>',
    );
    File(p.join(dist.path, 'styles.css')).writeAsStringSync('body { red: 1; }');
    final assetDir = Directory(p.join(dist.path, '_expo', 'static'))
      ..createSync(recursive: true);
    final asset = File(p.join(assetDir.path, 'index-abc123def4567890.js'))
      ..writeAsStringSync('plain');
    File('${asset.path}.br').writeAsStringSync('brotli');
    File('${asset.path}.gz').writeAsStringSync('gzip');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'disabled, excluded, and non-GET routes match middleware behavior',
    () async {
      final disabled = DaemonWebUi(
        enabled: false,
        distDir: dist.path,
        label: 'test',
      );
      expect((await disabled(_request('/')))!.statusCode, 404);
      expect(await disabled(_request('/api/health')), isNull);
      expect(await disabled(_request('/mcp/agents')), isNull);
      expect(await disabled(_request('/public/asset')), isNull);
      expect(await disabled(_request('/', method: 'POST')), isNull);
    },
  );

  test(
    'serves and safely injects the initial daemon connection hint',
    () async {
      final handler = _handler(dist);
      final response = await handler(
        _request('/', host: r'evil.test</script><script>alert(1)</script>'),
      );
      final body = await response!.readAsString();
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'text/html; charset=utf-8');
      expect(body, contains('window.__PASEO_INITIAL_DAEMON_CONNECTION__'));
      expect(body, contains(r'evil.test\u003C/script\u003E'));
      expect(body, isNot(contains('evil.test</script>')));
      expect(body, matches(RegExp(r'window\.__PASEO_.*</head>')));
      expect(
        response.headers['cache-control'],
        'no-store, no-cache, must-revalidate, proxy-revalidate',
      );
    },
  );

  test('handles a missing dist and index without a head tag', () async {
    final missing = DaemonWebUi(
      enabled: true,
      distDir: p.join(root.path, 'missing'),
      label: 'test',
    );
    expect((await missing(_request('/')))!.statusCode, 404);

    File(p.join(dist.path, 'index.html')).writeAsStringSync('<body>app</body>');
    final response = await _handler(dist)(_request('/'));
    final body = await response!.readAsString();
    expect(body, startsWith('<script>window.__PASEO_'));
  });

  test('falls back to index for SPA routes and handles HEAD', () async {
    final handler = _handler(dist);
    final deepLink = await handler(_request('/h/server/agent/123'));
    expect(await deepLink!.readAsString(), contains('<body>app</body>'));

    final head = await handler(_request('/', method: 'HEAD'));
    expect(head!.statusCode, 200);
    expect(await head.readAsString(), isEmpty);
  });

  test(
    'serves static and precompressed assets with upstream cache rules',
    () async {
      final handler = _handler(dist);
      final css = await handler(_request('/styles.css'));
      expect(await css!.readAsString(), 'body { red: 1; }');
      expect(css.headers['content-type'], 'text/css; charset=utf-8');
      expect(css.headers['cache-control'], 'no-cache');

      final brotli = await handler(
        _request(
          '/_expo/static/index-abc123def4567890.js',
          headers: {'accept-encoding': 'br, gzip'},
        ),
      );
      expect(await brotli!.readAsString(), 'brotli');
      expect(brotli.headers['content-encoding'], 'br');
      expect(brotli.headers['vary'], 'Accept-Encoding');
      expect(
        brotli.headers['cache-control'],
        'public, max-age=31536000, immutable',
      );

      final gzip = await handler(
        _request(
          '/_expo/static/index-abc123def4567890.js',
          headers: {'accept-encoding': 'gzip'},
        ),
      );
      expect(await gzip!.readAsString(), 'gzip');
      expect(gzip.headers['content-encoding'], 'gzip');
    },
  );

  test('maps every upstream static content type', () async {
    const expected = <String, String>{
      'data.json': 'application/json; charset=utf-8',
      'pixel.png': 'image/png',
      'photo.jpg': 'image/jpeg',
      'photo.jpeg': 'image/jpeg',
      'image.gif': 'image/gif',
      'icon.svg': 'image/svg+xml',
      'favicon.ico': 'image/x-icon',
      'font.woff': 'font/woff',
      'font.woff2': 'font/woff2',
      'font.ttf': 'font/ttf',
      'font.otf': 'font/otf',
      'font.eot': 'application/vnd.ms-fontobject',
      'bundle.map': 'application/json',
      'blob.bin': 'application/octet-stream',
      'module.mjs': 'application/javascript; charset=utf-8',
    };
    final handler = _handler(dist);
    for (final entry in expected.entries) {
      File(p.join(dist.path, entry.key)).writeAsStringSync('asset');
      final response = await handler(_request('/${entry.key}'));
      expect(response!.headers['content-type'], entry.value, reason: entry.key);
      await response.read().drain<void>();
    }
  });

  test('never serves paths outside the distribution root', () async {
    File(p.join(root.path, 'secret.txt')).writeAsStringSync('secret');
    final response = await _handler(dist)(_request('/%2e%2e/secret.txt'));
    expect(response!.statusCode, 200);
    final body = await response.readAsString();
    expect(body, contains('<body>app</body>'));
    expect(body, isNot(contains('secret')));
  });

  test(
    'WsServer mounts SPA fallback and honors trusted forwarded TLS',
    () async {
      final server = WsServer(
        router: RpcRouter(),
        hostnames: true,
        webUiHandler: DaemonWebUi(
          enabled: true,
          distDir: dist.path,
          label: 'daemon-label',
        ).call,
      );
      await server.start(host: '127.0.0.1', port: 0);
      addTearDown(server.stop);

      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/h/server/agent/123'),
      );
      request.headers
        ..set(HttpHeaders.hostHeader, 'daemon.example.test:${server.port}')
        ..set('x-forwarded-proto', 'https');
      final response = await request.close();
      final body = await utf8.decodeStream(response);
      expect(response.statusCode, 200);
      expect(body, contains('"listen":"daemon.example.test:${server.port}"'));
      expect(body, contains('"useTls":true'));
      expect(body, contains('"label":"daemon-label"'));
    },
  );
}

DaemonWebUi _handler(Directory dist) =>
    DaemonWebUi(enabled: true, distDir: dist.path, label: 'test-label');

Request _request(
  String path, {
  String method = 'GET',
  String host = 'localhost:6868',
  Map<String, String> headers = const {},
}) => Request(
  method,
  Uri.parse('http://localhost$path'),
  headers: {'host': host, ...headers},
);
