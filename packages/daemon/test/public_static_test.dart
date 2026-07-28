import 'dart:io';

import 'package:agent_daemon/src/server/public_static.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late PublicStaticHandler handler;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tinyrack-public-');
    File(p.join(root.path, 'asset.txt')).writeAsStringSync('0123456789');
    final nested = Directory(p.join(root.path, 'nested'))
      ..createSync(recursive: true);
    File(p.join(nested.path, 'index.html')).writeAsStringSync('<p>index</p>');
    File(p.join(root.path, '.secret')).writeAsStringSync('secret');
    handler = PublicStaticHandler(root.path);
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'falls through for unrelated, unsafe, missing, and mutating paths',
    () async {
      expect(await handler(_request('/api/health')), isNull);
      expect(await handler(_request('/public/missing.txt')), isNull);
      expect(await handler(_request('/public/.secret')), isNull);
      expect(await handler(_request('/public/%2e%2e/secret.txt')), isNull);
      expect(
        await handler(_request('/public/asset.txt', method: 'POST')),
        isNull,
      );
    },
  );

  test('serves files with Express static validators and metadata', () async {
    final response = await handler(_request('/public/asset.txt'));
    expect(response!.statusCode, HttpStatus.ok);
    expect(await response.readAsString(), '0123456789');
    expect(response.headers['accept-ranges'], 'bytes');
    expect(response.headers['cache-control'], 'public, max-age=0');
    expect(response.headers['content-type'], 'text/plain; charset=utf-8');
    expect(response.headers['content-length'], '10');
    expect(response.headers['etag'], startsWith('W/"a-'));
    expect(response.headers['last-modified'], isNotEmpty);

    final notModified = await handler(
      _request(
        '/public/asset.txt',
        headers: {'if-none-match': response.headers['etag']!},
      ),
    );
    expect(notModified!.statusCode, HttpStatus.notModified);

    final since = await handler(
      _request(
        '/public/asset.txt',
        headers: {'if-modified-since': response.headers['last-modified']!},
      ),
    );
    expect(since!.statusCode, HttpStatus.notModified);
  });

  test('supports HEAD, bounded ranges, suffix ranges, and 416', () async {
    final head = await handler(_request('/public/asset.txt', method: 'HEAD'));
    expect(head!.statusCode, HttpStatus.ok);
    expect(head.headers['content-length'], '10');
    expect(await head.readAsString(), isEmpty);

    final range = await handler(
      _request('/public/asset.txt', headers: {'range': 'bytes=2-5'}),
    );
    expect(range!.statusCode, HttpStatus.partialContent);
    expect(range.headers['content-range'], 'bytes 2-5/10');
    expect(await range.readAsString(), '2345');

    final suffix = await handler(
      _request('/public/asset.txt', headers: {'range': 'bytes=-3'}),
    );
    expect(await suffix!.readAsString(), '789');

    for (final value in ['bytes=20-30', 'items=1-2', 'bytes=-0']) {
      final invalid = await handler(
        _request('/public/asset.txt', headers: {'range': value}),
      );
      expect(invalid!.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      expect(invalid.headers['content-range'], 'bytes */10');
    }
  });

  test('redirects directories and serves their index', () async {
    final redirect = await handler(_request('/public/nested'));
    expect(redirect!.statusCode, HttpStatus.movedPermanently);
    expect(redirect.headers['location'], 'http://localhost/public/nested/');

    final index = await handler(_request('/public/nested/'));
    expect(index!.statusCode, HttpStatus.ok);
    expect(await index.readAsString(), '<p>index</p>');
    expect(index.headers['content-type'], 'text/html; charset=utf-8');
  });

  test('maps the public asset MIME surface', () async {
    const expected = <String, String>{
      'app.js': 'application/javascript; charset=utf-8',
      'app.mjs': 'application/javascript; charset=utf-8',
      'app.css': 'text/css; charset=utf-8',
      'data.json': 'application/json; charset=utf-8',
      'bundle.map': 'application/json; charset=utf-8',
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
      'blob.bin': 'application/octet-stream',
    };
    for (final entry in expected.entries) {
      File(p.join(root.path, entry.key)).writeAsStringSync('x');
      final response = await handler(_request('/public/${entry.key}'));
      expect(response!.headers['content-type'], entry.value, reason: entry.key);
      await response.read().drain<void>();
    }
  });
}

Request _request(
  String path, {
  String method = 'GET',
  Map<String, String> headers = const {},
}) => Request(method, Uri.parse('http://localhost$path'), headers: headers);
