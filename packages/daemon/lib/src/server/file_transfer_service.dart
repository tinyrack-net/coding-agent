import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:uuid/uuid.dart';

import 'connection.dart';
import 'ws_server.dart';

typedef DownloadClock = DateTime Function();

final class DownloadTokenEntry {
  const DownloadTokenEntry({
    required this.token,
    required this.path,
    required this.absolutePath,
    required this.fileName,
    required this.mimeType,
    required this.size,
    required this.expiresAt,
  });

  final String token;
  final String path;
  final String absolutePath;
  final String fileName;
  final String mimeType;
  final int size;
  final DateTime expiresAt;
}

final class DownloadTokenStore {
  DownloadTokenStore({
    this.ttl = const Duration(minutes: 1),
    DownloadClock? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final DownloadClock _clock;
  final Map<String, DownloadTokenEntry> _tokens = {};

  DownloadTokenEntry issueToken({
    required String path,
    required String absolutePath,
    required String fileName,
    required String mimeType,
    required int size,
  }) {
    _tokens.removeWhere((_, entry) => !entry.expiresAt.isAfter(_clock()));
    final token = const Uuid().v4();
    final entry = DownloadTokenEntry(
      token: token,
      path: path,
      absolutePath: absolutePath,
      fileName: fileName,
      mimeType: mimeType,
      size: size,
      expiresAt: _clock().add(ttl),
    );
    _tokens[token] = entry;
    return entry;
  }

  DownloadTokenEntry? consumeToken(String token) {
    final entry = _tokens.remove(token);
    return entry != null && entry.expiresAt.isAfter(_clock()) ? entry : null;
  }
}

final class FileDownloadHandler {
  const FileDownloadHandler(this.tokens);
  final DownloadTokenStore tokens;

  Future<Response?> call(Request request) async {
    if (request.method != 'GET' || request.url.path != 'api/files/download') {
      return null;
    }
    final token = request.url.queryParameters['token']?.trim();
    if (token == null || token.isEmpty) {
      return _jsonError(HttpStatus.badRequest, 'Missing download token');
    }
    final entry = tokens.consumeToken(token);
    if (entry == null) {
      return _jsonError(HttpStatus.forbidden, 'Invalid or expired token');
    }
    final file = File(entry.absolutePath);
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        return _jsonError(HttpStatus.notFound, 'File not found');
      }
      final safeName = entry.fileName.replaceAll(RegExp(r'["\r\n]'), '_');
      return Response.ok(
        file.openRead(),
        headers: {
          'content-type': entry.mimeType,
          'content-disposition': 'attachment; filename="$safeName"',
          'content-length': '${stat.size}',
        },
      );
      // coverage:ignore-start
      // stat/open races are platform filesystem behavior, not deterministic.
    } on FileSystemException {
      return _jsonError(HttpStatus.notFound, 'File not found');
    }
    // coverage:ignore-end
  }
}

final class WorkspaceFileTransferService {
  WorkspaceFileTransferService({
    required this.home,
    required this.downloadTokens,
    this.staleUploadTimeout = const Duration(minutes: 10),
  });

  final String home;
  final DownloadTokenStore downloadTokens;
  final Duration staleUploadTimeout;
  final Map<String, FileUploadStore> _uploadsByConnection = {};

  Future<Object?> handle(
    Connection connection,
    Map<String, Object?> message,
  ) async {
    switch (message['type']) {
      case 'file_download_token_request':
        return _handleDownloadToken(message);
      case 'file.upload.request':
        final request = _parseUploadRequest(message);
        _uploads(connection.id).beginUpload(request);
        return v2HandledNoResponse;
      default:
        return null;
    }
  }

  Future<void> handleFrame(
    Connection connection,
    FileTransferFrame frame,
  ) async {
    final response = await _uploads(connection.id).receiveFrame(frame);
    if (response != null) {
      connection.sendJson({'type': 'session', 'message': response});
    }
  }

  void onConnectionClosed(String connectionId) {
    _uploadsByConnection.remove(connectionId)?.close();
  }

  FileUploadStore _uploads(String connectionId) =>
      _uploadsByConnection.putIfAbsent(
        connectionId,
        () =>
            FileUploadStore(home: home, staleUploadTimeout: staleUploadTimeout),
      );

  Future<Map<String, Object?>> _handleDownloadToken(
    Map<String, Object?> message,
  ) async {
    final rawCwd = message['cwd'];
    final path = message['path'];
    final requestId = message['requestId'];
    if (rawCwd is! String || path is! String || requestId is! String) {
      throw const FormatException('Invalid file download token request');
    }
    final cwd = rawCwd.trim();
    if (cwd.isEmpty) {
      return _downloadResponse(
        cwd: rawCwd,
        path: path,
        requestId: requestId,
        error: 'cwd is required',
      );
    }
    try {
      final info = await _getDownloadableFileInfo(cwd, path);
      final entry = downloadTokens.issueToken(
        path: info.path,
        absolutePath: info.absolutePath,
        fileName: info.fileName,
        mimeType: info.mimeType,
        size: info.size,
      );
      return _downloadResponse(
        cwd: cwd,
        path: info.path,
        requestId: requestId,
        entry: entry,
      );
    } catch (error) {
      return _downloadResponse(
        cwd: cwd,
        path: path,
        requestId: requestId,
        error: '$error'.replaceFirst('FileSystemException: ', ''),
      );
    }
  }
}

final class FileUploadStore {
  FileUploadStore({
    required this.home,
    this.staleUploadTimeout = const Duration(minutes: 10),
  });

  final String home;
  final Duration staleUploadTimeout;
  final Map<String, _PendingUpload> _pending = {};
  final Map<String, FileTransferFrame> _earlyBegins = {};

  void beginUpload(FileUploadRequest request) {
    final existing = _pending.remove(request.requestId);
    existing?.timer.cancel();
    if (existing != null) {
      unawaited(existing.queue.then((_) => _removeDirectory(existing)));
    }
    final attempt = (existing?.attempt ?? 0) + 1;
    final id = _uploadId(request.requestId, attempt);
    final fileName = _sanitizeFileName(request.fileName);
    final upload = _PendingUpload(
      request: request,
      id: id,
      attempt: attempt,
      fileName: fileName,
      path: p.join(home, 'uploads', id, fileName),
    );
    upload.timer = _staleTimer(upload);
    _pending[request.requestId] = upload;
    final earlyBegin = _earlyBegins.remove(request.requestId);
    if (earlyBegin != null) {
      unawaited(receiveFrame(earlyBegin));
    }
  }

  Future<Map<String, Object?>?> receiveFrame(FileTransferFrame frame) {
    final upload = _pending[frame.requestId];
    if (upload == null) {
      // Some WebSocket clients can surface an immediately queued binary
      // frame before the preceding text request callback completes. Retain
      // only the idempotent begin marker; beginUpload replays it onto the
      // normal per-upload queue before any later chunk can run.
      if (frame.opcode == FileTransferOpcode.fileBegin) {
        _earlyBegins[frame.requestId] = frame;
      }
      return Future.value();
    }
    upload.timer..cancel();
    upload.timer = _staleTimer(upload);
    final operation = upload.queue.then((_) => _applyFrame(upload, frame));
    upload.queue = operation.then<void>((_) {}, onError: (_) {});
    return operation;
  }

  void close() {
    for (final upload in _pending.values) {
      upload.timer.cancel();
      unawaited(upload.queue.then((_) => _removeDirectory(upload)));
    }
    _pending.clear();
    _earlyBegins.clear();
  }

  Future<Map<String, Object?>?> _applyFrame(
    _PendingUpload upload,
    FileTransferFrame frame,
  ) async {
    if (_pending[upload.request.requestId] != upload) return null;
    try {
      switch (frame.opcode) {
        case FileTransferOpcode.fileBegin:
          await File(upload.path).parent.create(recursive: true);
          await File(upload.path).writeAsBytes(const []);
          upload.started = true;
          return null;
        case FileTransferOpcode.fileChunk:
          if (!upload.started) {
            throw StateError('Upload chunks arrived before file begin.');
          }
          final next = upload.receivedBytes + frame.payload.length;
          if (next > upload.request.size) {
            throw StateError(
              'Upload exceeded declared size: expected '
              '${upload.request.size}, received $next.',
            );
          }
          await File(
            upload.path,
          ).writeAsBytes(frame.payload, mode: FileMode.append);
          upload.receivedBytes = next;
          return null;
        case FileTransferOpcode.fileEnd:
          _clear(upload);
          if (upload.receivedBytes != upload.request.size) {
            await _removeDirectory(upload);
            return _uploadResponse(
              upload,
              'Upload size mismatch: expected ${upload.request.size}, '
              'received ${upload.receivedBytes}.',
            );
          }
          return _uploadResponse(upload, null);
      }
    } catch (error) {
      _clear(upload);
      await _removeDirectory(upload);
      return _uploadResponse(
        upload,
        error is StateError ? error.message : '$error',
      );
    }
  }

  Timer _staleTimer(_PendingUpload upload) => Timer(staleUploadTimeout, () {
    if (_pending[upload.request.requestId] != upload) return;
    _clear(upload);
    unawaited(upload.queue.then((_) => _removeDirectory(upload)));
  });

  void _clear(_PendingUpload upload) {
    upload.timer.cancel();
    if (_pending[upload.request.requestId] == upload) {
      _pending.remove(upload.request.requestId);
    }
  }

  Future<void> _removeDirectory(_PendingUpload upload) async {
    try {
      await Directory(
        p.join(home, 'uploads', upload.id),
      ).delete(recursive: true);
    } on FileSystemException {
      // Cleanup is best effort, matching Paseo's force removal.
    }
  }
}

Map<String, Object?> _downloadResponse({
  required String cwd,
  required String path,
  required String requestId,
  DownloadTokenEntry? entry,
  String? error,
}) => {
  'type': 'file_download_token_response',
  'payload': {
    'cwd': cwd,
    'path': path,
    'token': entry?.token,
    'fileName': entry?.fileName,
    'mimeType': entry?.mimeType,
    'size': entry?.size,
    'error': error,
    'requestId': requestId,
  },
};

Map<String, Object?> _uploadResponse(_PendingUpload upload, String? error) => {
  'type': 'file.upload.response',
  'payload': {
    'requestId': upload.request.requestId,
    'file': error == null
        ? UploadedFileAttachment(
            id: upload.id,
            fileName: upload.fileName,
            mimeType: upload.request.mimeType,
            size: upload.request.size,
            path: upload.path,
          ).toJson()
        : null,
    'error': error,
  },
};

FileUploadRequest _parseUploadRequest(Map<String, Object?> message) {
  final fileName = message['fileName'];
  final mimeType = message['mimeType'];
  final size = message['size'];
  final modifiedAt = message['modifiedAt'];
  final requestId = message['requestId'];
  if (fileName is! String ||
      fileName.isEmpty ||
      mimeType is! String ||
      mimeType.isEmpty ||
      size is! int ||
      size < 0 ||
      modifiedAt is! String ||
      requestId is! String) {
    throw const FormatException('Invalid file upload request');
  }
  return FileUploadRequest(
    fileName: fileName,
    mimeType: mimeType,
    size: size,
    modifiedAt: modifiedAt,
    requestId: requestId,
  );
}

Future<_DownloadableFile> _getDownloadableFileInfo(
  String root,
  String relativePath,
) async {
  final absoluteRoot = p.normalize(p.absolute(root));
  final requested = p.normalize(p.join(absoluteRoot, relativePath));
  if (!p.equals(requested, absoluteRoot) &&
      !p.isWithin(absoluteRoot, requested)) {
    throw StateError('Access outside workspace is not allowed');
  }
  final realRoot = await Directory(absoluteRoot).resolveSymbolicLinks();
  final realPath = await File(requested).resolveSymbolicLinks();
  // coverage:ignore-start
  // Out-of-root symlink fixtures require POSIX symlink support/privileges.
  if (!p.equals(realPath, realRoot) && !p.isWithin(realRoot, realPath)) {
    throw StateError('Access outside workspace is not allowed');
  }
  // coverage:ignore-end
  final file = File(realPath);
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file) {
    throw StateError('Requested path is not a file');
  }
  final bytes = await file
      .openRead(0, stat.size.clamp(0, 4096))
      .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
  return _DownloadableFile(
    path: p.relative(requested, from: absoluteRoot).replaceAll(r'\', '/'),
    absolutePath: realPath,
    fileName: p.basename(requested),
    mimeType: _downloadMimeType(p.extension(requested), bytes),
    size: stat.size,
  );
}

String _downloadMimeType(String extension, List<int> sample) {
  final ext = extension.toLowerCase();
  const images = {
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.svg': 'image/svg+xml',
  };
  if (images.containsKey(ext)) return images[ext]!;
  if (sample.any((byte) => byte == 0)) return 'application/octet-stream';
  return switch (ext) {
    '.json' => 'application/json',
    '.html' || '.htm' => 'text/html',
    '.css' => 'text/css',
    '.js' || '.mjs' => 'application/javascript',
    '.md' || '.txt' || '.dart' || '.ts' || '.tsx' || '.jsx' => 'text/plain',
    _ => 'text/plain',
  };
}

Response _jsonError(int status, String error) => Response(
  status,
  body: jsonEncode({'error': error}),
  headers: {'content-type': 'application/json'},
);

String _sanitizeFileName(String value) {
  final name = p
      .basename(value)
      .replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'), '_')
      .trim();
  return name.isNotEmpty && name != '.' && name != '..' ? name : 'upload';
}

String _uploadId(String requestId, int attempt) {
  final safe = requestId.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  final base = 'upload_${safe.isEmpty ? 'file' : safe}';
  return attempt == 1 ? base : '${base}_$attempt';
}

final class _PendingUpload {
  _PendingUpload({
    required this.request,
    required this.id,
    required this.attempt,
    required this.fileName,
    required this.path,
  });
  final FileUploadRequest request;
  final String id;
  final int attempt;
  final String fileName;
  final String path;
  int receivedBytes = 0;
  bool started = false;
  Future<void> queue = Future.value();
  late Timer timer;
}

final class _DownloadableFile {
  const _DownloadableFile({
    required this.path,
    required this.absolutePath,
    required this.fileName,
    required this.mimeType,
    required this.size,
  });
  final String path;
  final String absolutePath;
  final String fileName;
  final String mimeType;
  final int size;
}
