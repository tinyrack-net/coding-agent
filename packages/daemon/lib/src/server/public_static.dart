import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

/// Express-static-compatible `/public` file surface used by the daemon.
class PublicStaticHandler {
  const PublicStaticHandler(this.root);

  final String root;

  Future<Response?> call(Request request) async {
    if (request.method != 'GET' && request.method != 'HEAD') return null;
    final path = request.url.path;
    if (path != 'public' && !path.startsWith('public/')) return null;

    final relative = path == 'public' ? '' : path.substring('public/'.length);
    if (relative.split('/').any((segment) => segment.startsWith('.'))) {
      return null;
    }
    final absoluteRoot = p.normalize(p.absolute(root));
    var target = p.normalize(p.join(absoluteRoot, relative));
    if (!_inside(target, absoluteRoot)) return null;
    final type = FileSystemEntity.typeSync(target);
    if (type == FileSystemEntityType.directory) {
      if (!request.requestedUri.path.endsWith('/')) {
        final location = request.requestedUri.replace(
          path: '${request.requestedUri.path}/',
        );
        return Response.movedPermanently(location.toString());
      }
      target = p.join(target, 'index.html');
    }
    final file = File(target);
    if (!_inside(target, absoluteRoot) || !file.existsSync()) return null;

    final stat = file.statSync();
    final etag =
        'W/"${stat.size.toRadixString(16)}-${stat.modified.millisecondsSinceEpoch.toRadixString(16)}"';
    final headers = <String, String>{
      'accept-ranges': 'bytes',
      'cache-control': 'public, max-age=0',
      'content-type': _contentType(target),
      'etag': etag,
      'last-modified': HttpDate.format(stat.modified.toUtc()),
    };
    if (_isNotModified(request, etag, stat.modified)) {
      return Response.notModified(headers: headers);
    }

    final range = _parseRange(
      request.headers[HttpHeaders.rangeHeader],
      stat.size,
    );
    if (range == _invalidRange) {
      return Response(
        HttpStatus.requestedRangeNotSatisfiable,
        headers: {...headers, 'content-range': 'bytes */${stat.size}'},
      );
    }
    final start = range?.start ?? 0;
    final end = range?.end ?? stat.size - 1;
    final length = stat.size == 0 ? 0 : end - start + 1;
    final responseHeaders = <String, String>{
      ...headers,
      'content-length': '$length',
      if (range != null) 'content-range': 'bytes $start-$end/${stat.size}',
    };
    if (request.method == 'HEAD' || length == 0) {
      return Response(
        range == null ? HttpStatus.ok : HttpStatus.partialContent,
        headers: responseHeaders,
      );
    }
    return Response(
      range == null ? HttpStatus.ok : HttpStatus.partialContent,
      body: file.openRead(start, end + 1),
      headers: responseHeaders,
    );
  }
}

bool _inside(String target, String root) =>
    p.equals(target, root) || p.isWithin(root, target);

bool _isNotModified(Request request, String etag, DateTime modified) {
  final ifNoneMatch = request.headers[HttpHeaders.ifNoneMatchHeader];
  if (ifNoneMatch != null) {
    return ifNoneMatch == '*' ||
        ifNoneMatch.split(',').map((value) => value.trim()).contains(etag);
  }
  final raw = request.headers[HttpHeaders.ifModifiedSinceHeader];
  if (raw == null) return false;
  try {
    final since = HttpDate.parse(raw);
    final roundedModified = DateTime.fromMillisecondsSinceEpoch(
      modified.millisecondsSinceEpoch ~/ 1000 * 1000,
      isUtc: true,
    );
    return !roundedModified.isAfter(since.toUtc());
  } on HttpException {
    return false;
  }
}

const _ByteRange _invalidRange = _ByteRange(-1, -1);

_ByteRange? _parseRange(String? header, int size) {
  if (header == null || header.isEmpty) return null;
  final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
  if (match == null || size == 0) return _invalidRange;
  final rawStart = match.group(1)!;
  final rawEnd = match.group(2)!;
  if (rawStart.isEmpty && rawEnd.isEmpty) return _invalidRange;
  if (rawStart.isEmpty) {
    final suffix = int.tryParse(rawEnd);
    if (suffix == null || suffix <= 0) return _invalidRange;
    return _ByteRange(size - suffix.clamp(0, size), size - 1);
  }
  final start = int.tryParse(rawStart);
  final parsedEnd = rawEnd.isEmpty ? size - 1 : int.tryParse(rawEnd);
  if (start == null ||
      parsedEnd == null ||
      start < 0 ||
      start >= size ||
      parsedEnd < start) {
    return _invalidRange;
  }
  return _ByteRange(start, parsedEnd.clamp(start, size - 1));
}

String _contentType(String path) => switch (p.extension(path).toLowerCase()) {
  '.html' => 'text/html; charset=utf-8',
  '.js' || '.mjs' => 'application/javascript; charset=utf-8',
  '.css' => 'text/css; charset=utf-8',
  '.json' || '.map' => 'application/json; charset=utf-8',
  '.txt' => 'text/plain; charset=utf-8',
  '.png' => 'image/png',
  '.jpg' || '.jpeg' => 'image/jpeg',
  '.gif' => 'image/gif',
  '.svg' => 'image/svg+xml',
  '.ico' => 'image/x-icon',
  '.woff' => 'font/woff',
  '.woff2' => 'font/woff2',
  '.ttf' => 'font/ttf',
  '.otf' => 'font/otf',
  '.eot' => 'application/vnd.ms-fontobject',
  _ => 'application/octet-stream',
};

class _ByteRange {
  const _ByteRange(this.start, this.end);
  final int start;
  final int end;
}
