import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'connection.dart';
import 'directory_suggestions.dart';
import 'project_icon.dart';
import 'ws_server.dart';

const maxEditableFileBytes = 1024 * 1024;
const _outsideWorkspace = 'Access outside of workspace is not allowed';

final class WorkspaceFileExplorerService {
  WorkspaceFileExplorerService({FileObserver? observer})
    : _observer = observer ?? FileObserver();

  final FileObserver _observer;
  final Map<String, Map<String, FileObservation>> _subscriptions = {};

  Future<Object?> handle(
    Connection connection,
    Map<String, Object?> message,
  ) async {
    switch (message['type']) {
      case 'file_explorer_request':
        return _explore(connection, FileExplorerRequest.fromJson(message));
      case DirectorySuggestionsRequest.type:
        return _directorySuggestions(
          DirectorySuggestionsRequest.fromJson(message),
        );
      case 'fs.file.subscribe.request':
        return _subscribe(connection, FileSubscribeRequest.fromJson(message));
      case 'fs.file.unsubscribe.request':
        return _unsubscribe(
          connection,
          FileUnsubscribeRequest.fromJson(message),
        );
      case 'fs.file.write.request':
        final request = FileWriteRequest.fromJson(message);
        return {
          'type': 'fs.file.write.response',
          'payload': {
            'result': await writeExplorerFile(request),
            'requestId': request.requestId,
          },
        };
      case 'project_icon_request':
        final request = ProjectIconRequest.fromJson(message);
        try {
          return {
            'type': 'project_icon_response',
            'payload': {
              'cwd': request.cwd,
              'icon': await getProjectIcon(request.cwd),
              'error': null,
              'requestId': request.requestId,
            },
          };
        } catch (error) {
          return {
            'type': 'project_icon_response',
            'payload': {
              'cwd': request.cwd,
              'icon': null,
              'error': _errorMessage(error),
              'requestId': request.requestId,
            },
          };
        }
      default:
        return null;
    }
  }

  void onConnectionClosed(String connectionId) {
    final subscriptions = _subscriptions.remove(connectionId);
    if (subscriptions != null) {
      for (final observation in subscriptions.values) {
        observation.cancel();
      }
    }
  }

  void close() {
    for (final subscriptions in _subscriptions.values) {
      for (final observation in subscriptions.values) {
        observation.cancel();
      }
    }
    _subscriptions.clear();
    _observer.close();
  }

  Future<Object> _explore(
    Connection connection,
    FileExplorerRequest request,
  ) async {
    final cwd = request.cwd.trim();
    if (cwd.isEmpty) return _explorerError(request, 'cwd is required');
    try {
      if (request.mode == FileExplorerMode.list) {
        final directory = await listDirectoryEntries(cwd, request.path);
        return _explorerResponse(request, cwd: cwd, directory: directory);
      }
      final file = await readExplorerFileBytes(cwd, request.path);
      if (request.acceptBinary) {
        connection.sendBinary(
          FileTransferFrame(
            opcode: FileTransferOpcode.fileBegin,
            requestId: request.requestId,
            metadata: FileBeginMetadata(
              mime: file.mimeType,
              size: file.size,
              encoding: file.encoding,
              modifiedAt: file.modifiedAt,
              revision: file.revision,
            ),
          ).encode(),
        );
        connection.sendBinary(
          FileTransferFrame(
            opcode: FileTransferOpcode.fileChunk,
            requestId: request.requestId,
            payload: file.bytes,
          ).encode(),
        );
        connection.sendBinary(
          FileTransferFrame(
            opcode: FileTransferOpcode.fileEnd,
            requestId: request.requestId,
          ).encode(),
        );
        return v2HandledNoResponse;
      }
      return _explorerResponse(request, cwd: cwd, file: file.toInlineJson());
    } catch (error) {
      return _explorerError(request, _errorMessage(error), cwd: cwd);
    }
  }

  Future<Object> _directorySuggestions(
    DirectorySuggestionsRequest request,
  ) async {
    try {
      final workspaceCwd = request.cwd?.trim();
      final searchesWorkspace = workspaceCwd != null && workspaceCwd.isNotEmpty;
      final home =
          Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          Directory.current.path;
      final root = searchesWorkspace ? workspaceCwd : home;
      final entries = await searchDirectoryEntries(
        SearchDirectoryEntriesOptions(
          root: root,
          query: request.query,
          pathFormat: searchesWorkspace
              ? DirectorySuggestionPathFormat.relative
              : DirectorySuggestionPathFormat.absolute,
          pathQueryPolicy: searchesWorkspace
              ? PathQueryPolicy.slashes
              : PathQueryPolicy.rooted,
          blankQueryBehavior: searchesWorkspace
              ? BlankQueryBehavior.children
              : BlankQueryBehavior.none,
          rootAliases: searchesWorkspace ? const [] : const ['~'],
          traversableHiddenDirectoryNames: searchesWorkspace
              ? workspaceSearchHiddenDirectories
              : const [],
          confidentResultScanThreshold: searchesWorkspace ? null : 5000,
          includeFiles: request.includeFiles,
          includeDirectories: request.includeDirectories,
          matchMode: request.matchMode,
          limit: request.limit,
        ),
      );
      return DirectorySuggestionsResponse(
        directories: [
          for (final entry in entries)
            if (entry.kind == DirectorySuggestionKind.directory) entry.path,
        ],
        entries: entries,
        requestId: request.requestId,
      ).toJson();
    } catch (error) {
      return DirectorySuggestionsResponse(
        directories: const [],
        entries: const [],
        requestId: request.requestId,
        error: _errorMessage(error),
      ).toJson();
    }
  }

  Future<Object> _subscribe(
    Connection connection,
    FileSubscribeRequest request,
  ) async {
    final byId = _subscriptions.putIfAbsent(connection.id, () => {});
    byId.remove(request.subscriptionId)?.cancel();
    try {
      final observation = await _observer.observe(
        cwd: request.cwd,
        path: request.path,
        onChange: (version) {
          connection.sendJson({
            'type': 'session',
            'message': {
              'type': 'fs.file.update',
              'payload': {
                'subscriptionId': request.subscriptionId,
                'version': version,
              },
            },
          });
        },
      );
      byId[request.subscriptionId] = observation;
      return {
        'type': 'fs.file.subscribe.response',
        'payload': {
          'subscriptionId': request.subscriptionId,
          'initial': observation.initial,
          'requestId': request.requestId,
        },
      };
    } catch (error) {
      return {
        'type': 'fs.file.subscribe.response',
        'payload': {
          'subscriptionId': request.subscriptionId,
          'initial': {
            'status': 'error',
            'cwd': request.cwd,
            'path': request.path,
            'error': _errorMessage(error),
          },
          'requestId': request.requestId,
        },
      };
    }
  }

  Object _unsubscribe(Connection connection, FileUnsubscribeRequest request) {
    _subscriptions[connection.id]?.remove(request.subscriptionId)?.cancel();
    return {
      'type': 'fs.file.unsubscribe.response',
      'payload': {
        'subscriptionId': request.subscriptionId,
        'requestId': request.requestId,
      },
    };
  }
}

Future<Map<String, Object?>> listDirectoryEntries(
  String root,
  String relativePath,
) async {
  final scoped = await _resolveScopedPath(root, relativePath);
  final directory = Directory(scoped.resolved);
  final stat = await directory.stat();
  if (stat.type != FileSystemEntityType.directory) {
    throw StateError('Requested path is not a directory');
  }
  final entries = <Map<String, Object?>>[];
  await for (final entity in directory.list(followLinks: false)) {
    try {
      final relative = _normalizeRelative(root, entity.path);
      // coverage:ignore-start
      // Link creation on Windows requires host policy/developer privileges.
      final entryStat = entity is Link
          ? await FileStat.stat(
              (await _resolveScopedPath(root, relative)).resolved,
            )
          : await entity.stat();
      // coverage:ignore-end
      final kind = entryStat.type == FileSystemEntityType.directory
          ? 'directory'
          : 'file';
      if (entryStat.type != FileSystemEntityType.file &&
          entryStat.type != FileSystemEntityType.directory) {
        continue;
      }
      entries.add({
        'name': p.basename(entity.path),
        'path': relative,
        'kind': kind,
        'size': entryStat.size,
        'modifiedAt': _timestamp(entryStat.modified),
      });
      // coverage:ignore-start
      // Dangling/out-of-root link fixtures are privilege-dependent.
    } on FileSystemException {
      // Paseo skips dangling and out-of-root links while listing.
    } on StateError catch (error) {
      if (error.message != _outsideWorkspace) rethrow;
    }
    // coverage:ignore-end
  }
  entries.sort((left, right) {
    final modified = (right['modifiedAt']! as String).compareTo(
      left['modifiedAt']! as String,
    );
    return modified != 0
        ? modified
        : (left['name']! as String).compareTo(right['name']! as String);
  });
  return {
    'path': _normalizeRelative(root, scoped.requested),
    'entries': entries,
  };
}

Future<ExplorerFileBytes> readExplorerFileBytes(
  String root,
  String relativePath,
) async {
  final scoped = await _resolveScopedPath(root, relativePath);
  final file = File(scoped.resolved);
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file) {
    throw StateError('Requested path is not a file');
  }
  final bytes = await file.readAsBytes();
  final extension = p.extension(scoped.resolved).toLowerCase();
  final imageMime = _imageMimeTypes[extension];
  final kind = imageMime != null
      ? 'image'
      : (_isBinary(bytes) ? 'binary' : 'text');
  return ExplorerFileBytes(
    path: _normalizeRelative(root, scoped.requested),
    kind: kind,
    encoding: kind == 'text' ? 'utf-8' : 'binary',
    bytes: bytes,
    mimeType:
        imageMime ??
        (kind == 'text' ? _textMime(extension) : 'application/octet-stream'),
    size: stat.size,
    modifiedAt: _timestamp(stat.modified),
    revision: _revision(stat, bytes),
  );
}

Future<Map<String, Object?>> getExplorerFileVersion(
  String root,
  String relativePath,
) async {
  final cwd = p.normalize(p.absolute(root));
  try {
    final scoped = await _resolveScopedPath(root, relativePath);
    final stat = await File(scoped.resolved).stat();
    if (stat.type == FileSystemEntityType.notFound) {
      return {'status': 'missing', 'cwd': cwd, 'path': relativePath};
    }
    if (stat.type != FileSystemEntityType.file) {
      return {
        'status': 'error',
        'cwd': cwd,
        'path': relativePath,
        'error': 'Requested path is not a file',
      };
    }
    return {
      'status': 'ready',
      'cwd': cwd,
      'path': _normalizeRelative(root, scoped.requested),
      'size': stat.size,
      'modifiedAt': _timestamp(stat.modified),
      'revision': _revision(stat, await File(scoped.resolved).readAsBytes()),
    };
  } on FileSystemException {
    return {'status': 'missing', 'cwd': cwd, 'path': relativePath};
  } catch (error) {
    return {
      'status': 'error',
      'cwd': cwd,
      'path': relativePath,
      'error': _errorMessage(error),
    };
  }
}

Future<Map<String, Object?>> writeExplorerFile(FileWriteRequest request) async {
  final encoded = utf8.encode(request.content);
  if (encoded.length > maxEditableFileBytes) {
    return {'status': 'error', 'error': 'File is too large to edit'};
  }
  _ScopedPath scoped;
  FileStat current;
  try {
    scoped = await _resolveScopedPath(request.cwd, request.path);
    current = await File(scoped.resolved).stat();
    if (current.type == FileSystemEntityType.notFound) {
      return {
        'status': 'conflict',
        'version': {
          'status': 'missing',
          'cwd': p.normalize(p.absolute(request.cwd)),
          'path': request.path,
        },
      };
    }
    if (current.type != FileSystemEntityType.file) {
      return {'status': 'error', 'error': 'Requested path is not a file'};
    }
    if (current.size > maxEditableFileBytes) {
      return {'status': 'error', 'error': 'File is too large to edit'};
    }
    final currentBytes = await File(scoped.resolved).readAsBytes();
    if (_isBinary(currentBytes)) {
      return {'status': 'error', 'error': 'Binary files cannot be edited'};
    }
    if (!_matchesExpected(current, currentBytes, request)) {
      return {
        'status': 'conflict',
        'version': await getExplorerFileVersion(request.cwd, request.path),
      };
    }
  } on FileSystemException {
    return {
      'status': 'conflict',
      'version': {
        'status': 'missing',
        'cwd': p.normalize(p.absolute(request.cwd)),
        'path': request.path,
      },
    };
  } catch (error) {
    return {'status': 'error', 'error': _errorMessage(error)};
  }

  final temporary = File(
    p.join(
      p.dirname(scoped.resolved),
      '.${p.basename(scoped.resolved)}.paseo-${const Uuid().v4()}.tmp',
    ),
  );
  try {
    await temporary.writeAsBytes(encoded, flush: true);
    final latest = await File(scoped.resolved).stat();
    final latestBytes = await File(scoped.resolved).readAsBytes();
    // coverage:ignore-start
    // Requires another process to replace the file between adjacent stats.
    if (!_matchesExpected(latest, latestBytes, request)) {
      return {
        'status': 'conflict',
        'version': await getExplorerFileVersion(request.cwd, request.path),
      };
    }
    // coverage:ignore-end
    if (!Platform.isWindows) await temporary.setLastModified(DateTime.now());
    await temporary.rename(scoped.resolved);
    final stat = await File(scoped.resolved).stat();
    return {
      'status': 'written',
      'modifiedAt': _timestamp(stat.modified),
      'size': stat.size,
      'revision': _revision(stat, await File(scoped.resolved).readAsBytes()),
    };
    // coverage:ignore-start
    // Filesystem failure after the guarded write requires an external race.
  } catch (error) {
    return {'status': 'error', 'error': _errorMessage(error)};
    // coverage:ignore-end
  } finally {
    try {
      if (await temporary.exists()) await temporary.delete();
      // coverage:ignore-start
      // Best-effort cleanup failure is platform/filesystem dependent.
    } on FileSystemException {
      // Best effort cleanup.
    }
    // coverage:ignore-end
  }
}

final class ExplorerFileBytes {
  const ExplorerFileBytes({
    required this.path,
    required this.kind,
    required this.encoding,
    required this.bytes,
    required this.mimeType,
    required this.size,
    required this.modifiedAt,
    required this.revision,
  });

  final String path;
  final String kind;
  final String encoding;
  final Uint8List bytes;
  final String mimeType;
  final int size;
  final String modifiedAt;
  final String revision;

  Map<String, Object?> toInlineJson() => {
    'path': path,
    'kind': kind,
    'encoding': switch (kind) {
      'image' => 'base64',
      'binary' => 'none',
      _ => 'utf-8',
    },
    if (kind == 'image') 'content': base64Encode(bytes),
    if (kind == 'text') 'content': utf8.decode(bytes),
    'mimeType': mimeType,
    'size': size,
    'modifiedAt': modifiedAt,
    'revision': revision,
  };
}

final class FileObservation {
  FileObservation({required this.initial, required void Function() onCancel})
    : _onCancel = onCancel;

  final Map<String, Object?> initial;
  final void Function() _onCancel;
  bool _active = true;

  void cancel() {
    if (!_active) return;
    _active = false;
    _onCancel();
  }
}

final class FileObserver {
  final Map<String, _ObservedFile> _files = {};

  Future<FileObservation> observe({
    required String cwd,
    required String path,
    required void Function(Map<String, Object?> version) onChange,
  }) async {
    final target = (await _resolveScopedPath(cwd, path)).resolved;
    var observed = _files[target];
    final initial = await getExplorerFileVersion(cwd, path);
    observed ??= _ObservedFile(
      cwd: cwd,
      path: path,
      fingerprint: _fingerprint(initial),
    );
    _files[target] = observed;
    observed.listeners[onChange] = (cwd, path);
    observed.fingerprint = _fingerprint(initial);
    _start(target, observed);
    return FileObservation(
      initial: initial,
      onCancel: () {
        observed!.listeners.remove(onChange);
        if (observed.listeners.isEmpty) {
          observed.close();
          _files.remove(target);
        }
      },
    );
  }

  void close() {
    for (final observed in _files.values) {
      observed.close();
    }
    _files.clear();
  }

  void _start(String target, _ObservedFile observed) {
    if (observed.watcher != null || observed.poller != null) return;
    try {
      observed.watcher = Directory(p.dirname(target)).watch().listen((event) {
        if (p.basename(event.path) == p.basename(target)) {
          observed.debounce?.cancel();
          observed.debounce = Timer(
            const Duration(milliseconds: 50),
            () => unawaited(_restat(target, observed)),
          );
        }
        // coverage:ignore-start
        // Native watcher failure cannot be induced portably.
      }, onError: (_) => _fallback(target, observed));
    } on FileSystemException {
      _fallback(target, observed);
    }
  }

  void _fallback(String target, _ObservedFile observed) {
    unawaited(observed.watcher?.cancel());
    observed.watcher = null;
    observed.poller ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_restat(target, observed)),
    );
  }
  // coverage:ignore-end

  Future<void> _restat(String target, _ObservedFile observed) async {
    if (_files[target] != observed) return;
    final version = await getExplorerFileVersion(observed.cwd, observed.path);
    final fingerprint = _fingerprint(version);
    if (fingerprint == observed.fingerprint) return;
    observed.fingerprint = fingerprint;
    for (final entry in observed.listeners.entries) {
      entry.key({...version, 'cwd': entry.value.$1, 'path': entry.value.$2});
    }
  }
}

final class _ObservedFile {
  _ObservedFile({
    required this.cwd,
    required this.path,
    required this.fingerprint,
  });

  final String cwd;
  final String path;
  String fingerprint;
  final Map<void Function(Map<String, Object?>), (String, String)> listeners =
      {};
  StreamSubscription<FileSystemEvent>? watcher;
  Timer? debounce;
  Timer? poller;

  void close() {
    unawaited(watcher?.cancel());
    debounce?.cancel();
    poller?.cancel();
  }
}

final class _ScopedPath {
  const _ScopedPath(this.requested, this.resolved);
  final String requested;
  final String resolved;
}

Future<_ScopedPath> _resolveScopedPath(String root, String relativePath) async {
  final absoluteRoot = p.normalize(p.absolute(root));
  final requested = p.normalize(p.join(absoluteRoot, relativePath));
  if (!p.equals(requested, absoluteRoot) &&
      !p.isWithin(absoluteRoot, requested)) {
    throw StateError(_outsideWorkspace);
  }
  final realRoot = await Directory(absoluteRoot).resolveSymbolicLinks();
  try {
    final type = await FileSystemEntity.type(requested, followLinks: true);
    if (type == FileSystemEntityType.notFound) {
      return _ScopedPath(requested, requested);
    }
    final realPath = await switch (type) {
      FileSystemEntityType.directory => Directory(
        requested,
      ).resolveSymbolicLinks(),
      _ => File(requested).resolveSymbolicLinks(),
    };
    final comparableRoot = _canonicalForComparison(realRoot);
    final comparablePath = _canonicalForComparison(realPath);
    // coverage:ignore-start
    // Out-of-root symlink fixtures require platform symlink privileges.
    if (!p.equals(comparablePath, comparableRoot) &&
        !p.isWithin(comparableRoot, comparablePath)) {
      throw StateError(_outsideWorkspace);
    }
    // coverage:ignore-end
    return _ScopedPath(requested, realPath);
    // coverage:ignore-start
    // A resolve race requires the target to disappear during resolution.
  } on FileSystemException {
    return _ScopedPath(requested, requested);
  }
  // coverage:ignore-end
}

Object _explorerResponse(
  FileExplorerRequest request, {
  required String cwd,
  Map<String, Object?>? directory,
  Map<String, Object?>? file,
}) => {
  'type': 'file_explorer_response',
  'payload': {
    'cwd': cwd,
    'path': directory?['path'] ?? file?['path'] ?? request.path,
    'mode': request.mode.name,
    'directory': directory,
    'file': file,
    'error': null,
    'requestId': request.requestId,
  },
};

Object _explorerError(
  FileExplorerRequest request,
  String error, {
  String? cwd,
}) => {
  'type': 'file_explorer_response',
  'payload': {
    'cwd': cwd ?? request.cwd,
    'path': request.path,
    'mode': request.mode.name,
    'directory': null,
    'file': null,
    'error': error,
    'requestId': request.requestId,
  },
};

bool _matchesExpected(
  FileStat stat,
  List<int> bytes,
  FileWriteRequest request,
) => request.expectedRevision != null
    ? _revision(stat, bytes) == request.expectedRevision
    : _timestamp(stat.modified) == request.expectedModifiedAt;

String _revision(FileStat stat, List<int> bytes) =>
    '${stat.mode}:${stat.size}:${stat.modified.microsecondsSinceEpoch}:'
    '${stat.changed.microsecondsSinceEpoch}:${_contentFingerprint(bytes)}';

String _contentFingerprint(List<int> bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

String _timestamp(DateTime value) => value.toUtc().toIso8601String();

String _normalizeRelative(String root, String target) {
  final relative = p.relative(target, from: p.normalize(p.absolute(root)));
  return relative == '.' ? '.' : relative.replaceAll(r'\', '/');
}

// coverage:ignore-start
// This branch depends on Windows returning an extended-length resolved path.
String _canonicalForComparison(String value) =>
    Platform.isWindows && value.startsWith(r'\\?\')
    ? value.substring(4)
    : value;
// coverage:ignore-end

String _fingerprint(Map<String, Object?> version) =>
    version['status'] == 'ready'
    ? 'ready:${version['revision'] ?? '${version['size']}:${version['modifiedAt']}'}'
    : '${version['status']}';

String _errorMessage(Object error) => switch (error) {
  StateError value => value.message,
  FileSystemException value => value.message,
  _ => '$error',
};

bool _isBinary(List<int> bytes) {
  if (bytes.isEmpty) return false;
  var suspicious = 0;
  for (final byte in bytes) {
    if (byte == 0) return true;
    if ((byte < 32 && byte != 9 && byte != 10 && byte != 13) || byte == 127) {
      suspicious++;
    }
  }
  if (suspicious / bytes.length > .3) return true;
  try {
    utf8.decode(bytes, allowMalformed: false);
    return false;
  } on FormatException {
    return true;
  }
}

const _imageMimeTypes = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
};

String _textMime(String extension) =>
    extension == '.json' ? 'application/json' : 'text/plain';
