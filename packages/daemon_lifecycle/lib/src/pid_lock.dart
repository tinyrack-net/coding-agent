import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'process_ops.dart' as process_ops;

/// Contents of `<dataDir>/daemon.pid`.
final class PidLockData {
  const PidLockData({
    required this.pid,
    required this.startedAtMs,
    required this.host,
    required this.port,
    required this.version,
    required this.desktopManaged,
  });

  final int pid;
  final int startedAtMs;
  final String host;
  final int port;
  final String version;
  final bool desktopManaged;

  static PidLockData? fromJson(Map<String, Object?> json) {
    final pid = (json['pid'] as num?)?.toInt();
    if (pid == null) return null;
    return PidLockData(
      pid: pid,
      startedAtMs: (json['startedAtMs'] as num?)?.toInt() ?? 0,
      host: (json['host'] as String?) ?? '127.0.0.1',
      port: (json['port'] as num?)?.toInt() ?? 0,
      version: (json['version'] as String?) ?? '0.0.0',
      desktopManaged: (json['desktopManaged'] as bool?) ?? false,
    );
  }

  Map<String, Object?> toJson() => {
        'pid': pid,
        'startedAtMs': startedAtMs,
        'host': host,
        'port': port,
        'version': version,
        'desktopManaged': desktopManaged,
      };
}

class LockHeldException implements Exception {
  LockHeldException(this.existing);

  final PidLockData existing;

  @override
  String toString() =>
      'daemon already running (pid ${existing.pid}, port ${existing.port})';
}

/// Exclusive pid lock with heartbeat. The daemon holds it for its lifetime;
/// the app only reads it.
class PidLock {
  PidLock(
    this.path, {
    DateTime Function()? now,
    Future<bool> Function(int pid)? isPidAlive,
    this.staleAfter = const Duration(minutes: 5),
  })  : _now = now ?? DateTime.now,
        _isPidAlive = isPidAlive ?? process_ops.isPidAlive;

  final String path;
  final Duration staleAfter;
  final DateTime Function() _now;
  final Future<bool> Function(int pid) _isPidAlive;

  Timer? _heartbeat;
  PidLockData? _held;
  Future<void> _lastHeartbeatWrite = Future<void>.value();

  /// Acquires the lock exclusively. A stale lock (old heartbeat AND dead pid)
  /// is reclaimed. Throws [LockHeldException] when a live daemon holds it.
  Future<void> acquire(PidLockData data) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final sink = await file.create(exclusive: true);
        await sink.writeAsString(jsonEncode(data.toJson()), flush: true);
        _held = data;
        return;
      } on PathExistsException {
        final existing = await read();
        if (existing == null) {
          // Corrupt or empty lock file: treat as stale.
          await _deleteQuietly(file);
          continue;
        }
        if (await _isStale(file, existing)) {
          await _deleteQuietly(file);
          continue;
        }
        throw LockHeldException(existing);
      }
    }
    throw StateError('could not acquire pid lock at $path');
  }

  /// Updates the held lock (e.g. once the real bound port is known).
  Future<void> update(PidLockData data) async {
    _held = data;
    await File(path).writeAsString(jsonEncode(data.toJson()), flush: true);
  }

  /// Rewrites the file periodically so mtime doubles as a liveness heartbeat.
  void startHeartbeat({Duration interval = const Duration(seconds: 30)}) {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(interval, (_) {
      _lastHeartbeatWrite = _writeHeartbeat();
    });
  }

  Future<void> _writeHeartbeat() async {
    final held = _held;
    if (held == null) return;
    try {
      await File(path).writeAsString(jsonEncode(held.toJson()), flush: true);
    } catch (_) {
      // Best effort; staleness only kicks in after [staleAfter].
    }
  }

  Future<void> release() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    // Cancelling the timer only stops future ticks; wait out any write that
    // was already in flight so it can't recreate the file after we delete it
    // (or still hold it open when a caller removes the containing dir).
    await _lastHeartbeatWrite;
    if (_held != null) {
      _held = null;
      await _deleteQuietly(File(path));
    }
  }

  /// Reads the lock file without taking it. Null when absent or corrupt.
  Future<PidLockData?> read() async {
    try {
      final content = await File(path).readAsString();
      return PidLockData.fromJson(
          jsonDecode(content) as Map<String, Object?>);
    } catch (_) {
      return null;
    }
  }

  /// True when the lock exists but its owner is gone (stale heartbeat AND
  /// dead pid).
  Future<bool> isStale() async {
    final file = File(path);
    final data = await read();
    if (data == null) return file.existsSync();
    return _isStale(file, data);
  }

  Future<bool> _isStale(File file, PidLockData data) async {
    try {
      final age = _now().difference(file.lastModifiedSync());
      if (age < staleAfter) return false;
    } catch (_) {
      return true;
    }
    return !await _isPidAlive(data.pid);
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (_) {}
  }
}
