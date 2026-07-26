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
    await _replaceAtomically(data);
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
      await _replaceAtomically(held);
    } catch (_) {
      // Best effort; staleness only kicks in after [staleAfter].
    }
  }

  /// Replaces the lock file in one step (write a sibling temp, then rename).
  ///
  /// A plain `writeAsString` truncates before writing, so a concurrent reader
  /// can observe a zero-byte file. That matters because [read] reports an
  /// unparseable file as `null`, and [acquire] treats `null` as "corrupt lock,
  /// therefore stale" and *deletes* it — so a second daemon could start on the
  /// same data dir purely because it sampled the file mid-heartbeat. `rename`
  /// replaces the target atomically (including on Windows), so a reader always
  /// sees either the old or the new content.
  Future<void> _replaceAtomically(PidLockData data) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode(data.toJson()), flush: true);
    await tmp.rename(path);
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
    // A heartbeat that died between write and rename leaves this behind.
    await _deleteQuietly(File('$path.tmp'));
  }

  /// Reads the lock file without taking it. Null when absent or corrupt.
  ///
  /// Retries a few times before giving up, because a concurrent heartbeat
  /// rewrite makes a single read fail transiently — replacing the file briefly
  /// locks the path on Windows, and a torn read yields unparseable content.
  /// Reporting that as "corrupt" is actively dangerous: [acquire] treats null
  /// as a stale lock and *deletes* it, so one unlucky sample would let a second
  /// daemon start on the same data dir. A genuinely corrupt file stays
  /// unreadable across every attempt and still returns null.
  Future<PidLockData?> read() async {
    for (var attempt = 0;; attempt++) {
      // An absent file is a legitimate answer, not a transient failure.
      if (!File(path).existsSync()) return null;
      try {
        final content = await File(path).readAsString();
        final data =
            PidLockData.fromJson(jsonDecode(content) as Map<String, Object?>);
        if (data != null) return data;
      } catch (_) {
        // Fall through and retry.
      }
      if (attempt >= 4) return null;
      await Future<void>.delayed(const Duration(milliseconds: 20));
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
      if (age < staleAfter) {
        if (!await _isPidAlive(data.pid)) return true;
        return false;
      }
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
