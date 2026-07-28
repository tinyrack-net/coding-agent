import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import 'trusted_proxies.dart';

class DaemonWebUi {
  const DaemonWebUi({
    required this.enabled,
    required this.distDir,
    required this.label,
    this.trustedProxies = defaultTrustedProxies,
  });

  final bool enabled;
  final String? distDir;
  final String label;
  final TrustedProxiesConfig trustedProxies;

  Future<Response?> call(Request request) async {
    if (request.method != 'GET' && request.method != 'HEAD') return null;
    final requestPath = '/${request.url.path}';
    if (_isExcludedPath(requestPath)) return null;
    if (!enabled || distDir == null) return Response.notFound('');

    final target = _resolveTargetFile(distDir!, request.url.path);
    if (target == null) return Response.notFound('');
    final encoding = target.isIndexHtml
        ? const _EncodedFile(null, null)
        : _resolveContentEncoding(
            target.file,
            request.headers['accept-encoding'],
          );
    final finalFile = encoding.file ?? target.file;
    final headers = <String, String>{
      'content-type': _contentType(target.file),
      'cache-control': target.isIndexHtml
          ? 'no-store, no-cache, must-revalidate, proxy-revalidate'
          : _isHashedAsset(target.file)
          ? 'public, max-age=31536000, immutable'
          : 'no-cache',
      if (target.isIndexHtml) ...{'pragma': 'no-cache', 'expires': '0'},
      if (encoding.encoding != null) ...{
        'content-encoding': encoding.encoding!,
        'vary': 'Accept-Encoding',
      },
    };
    if (request.method == 'HEAD') return Response.ok('', headers: headers);

    if (target.isIndexHtml) {
      try {
        final html = await File(finalFile).readAsString();
        return Response.ok(
          _injectConnectionHint(html, request),
          headers: headers,
        );
        // coverage:ignore-start
        // A file can disappear only in the race after the synchronous stat.
      } on FileSystemException {
        return Response.internalServerError();
      }
      // coverage:ignore-end
    }
    try {
      return Response.ok(File(finalFile).openRead(), headers: headers);
      // coverage:ignore-start
      // A file can disappear only in the race after the synchronous stat.
    } on FileSystemException {
      return Response.internalServerError();
    }
    // coverage:ignore-end
  }

  String _injectConnectionHint(String html, Request request) {
    final hint = <String, Object?>{
      'listen': request.headers['host'] ?? '',
      'useTls': effectiveRequestScheme(request, trustedProxies) == 'https',
      'label': label,
    };
    final json = jsonEncode(hint)
        .replaceAll('<', r'\u003C')
        .replaceAll('>', r'\u003E')
        .replaceAll('&', r'\u0026');
    final script =
        '<script>window.__PASEO_INITIAL_DAEMON_CONNECTION__=$json</script>';
    final headClose = RegExp('</head>', caseSensitive: false);
    return headClose.hasMatch(html)
        ? html.replaceFirst(headClose, '$script</head>')
        : '$script$html';
  }
}

bool _isExcludedPath(String path) =>
    path == '/api' ||
    path.startsWith('/api/') ||
    path == '/mcp' ||
    path.startsWith('/mcp/') ||
    path == '/public' ||
    path.startsWith('/public/');

_ResolvedFile? _resolveTargetFile(String distDir, String requestPath) {
  final root = p.normalize(p.absolute(distDir));
  var candidate = p.normalize(p.join(root, requestPath));
  if (!_isInside(candidate, root)) return null;
  final type = FileSystemEntity.typeSync(candidate);
  if (type == FileSystemEntityType.directory) {
    candidate = p.join(candidate, 'index.html');
  }
  if (FileSystemEntity.typeSync(candidate) != FileSystemEntityType.file) {
    candidate = p.join(root, 'index.html');
  }
  if (!_isInside(candidate, root) || !File(candidate).existsSync()) return null;
  return _ResolvedFile(
    p.normalize(p.absolute(candidate)),
    p.basename(candidate).toLowerCase() == 'index.html',
  );
}

bool _isInside(String target, String root) =>
    p.equals(target, root) || p.isWithin(root, target);

_EncodedFile _resolveContentEncoding(String file, String? acceptEncoding) {
  final normalized = acceptEncoding?.toLowerCase() ?? '';
  final encoding = normalized.contains('br')
      ? 'br'
      : normalized.contains('gzip')
      ? 'gzip'
      : null;
  if (encoding == null) return const _EncodedFile(null, null);
  final compressed = '$file.${encoding == 'br' ? 'br' : 'gz'}';
  return File(compressed).existsSync()
      ? _EncodedFile(compressed, encoding)
      : const _EncodedFile(null, null);
}

bool _isHashedAsset(String path) => RegExp(
  r'[-.][0-9a-f]{16,}[-.]',
  caseSensitive: false,
).hasMatch(p.basename(path));

String _contentType(String path) => switch (p.extension(path).toLowerCase()) {
  '.html' => 'text/html; charset=utf-8',
  '.js' || '.mjs' => 'application/javascript; charset=utf-8',
  '.css' => 'text/css; charset=utf-8',
  '.json' => 'application/json; charset=utf-8',
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
  '.map' => 'application/json',
  _ => 'application/octet-stream',
};

class _ResolvedFile {
  const _ResolvedFile(this.file, this.isIndexHtml);
  final String file;
  final bool isIndexHtml;
}

class _EncodedFile {
  const _EncodedFile(this.file, this.encoding);
  final String? file;
  final String? encoding;
}
