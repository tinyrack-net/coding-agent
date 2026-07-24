/// Terminal session registry: owns PTYs, retains scrollback, and fans binary
/// output frames out to per-connection subscription slots.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:uuid/uuid.dart';

import 'pty/pty.dart';

/// Matches [Pty.spawn]; injectable so tests can supply a fake.
typedef PtySpawner = Pty Function({
  required String cwd,
  int cols,
  int rows,
  String? shell,
});

/// Max retained scrollback per terminal (snapshot sent on subscribe).
const int kScrollbackLimit = 256 * 1024;

class TerminalManager {
  TerminalManager({
    required this.sendBinary,
    required this.onExited,
    PtySpawner? spawn,
    this.scrollbackLimit = kScrollbackLimit,
  }) : _spawn = spawn ?? Pty.spawn;

  /// Sends a raw binary WebSocket frame to one connection.
  final void Function(String connectionId, Uint8List bytes) sendBinary;

  /// Called after a shell dies and its session is cleaned up (broadcast the
  /// `terminal.exited` event from here).
  final void Function(String terminalId, int? exitCode) onExited;

  final PtySpawner _spawn;
  final int scrollbackLimit;

  final Map<String, _Session> _sessions = {};

  /// connectionId -> slotId -> terminalId (input/resize routing).
  final Map<String, Map<int, String>> _slots = {};
  final Map<String, int> _nextSlot = {};
  final _uuid = const Uuid();
  bool _disposed = false;

  /// {terminalId, cwd, shell} for the create response.
  Map<String, Object?> create({required String cwd, int? cols, int? rows}) {
    final pty = _spawn(cwd: cwd, cols: cols ?? 80, rows: rows ?? 24);
    final id = _uuid.v4();
    final session = _Session(
      terminalId: id,
      pty: pty,
      cwd: cwd,
      scrollback: _RingBuffer(scrollbackLimit),
    );
    _sessions[id] = session;

    session.outputSub = pty.output.listen((chunk) {
      session.scrollback.add(chunk);
      session.subscribers.forEach((connectionId, slotId) {
        sendBinary(
          connectionId,
          TerminalFrame(
            opcode: TerminalOpcode.output,
            slotId: slotId,
            payload: chunk,
          ).encode(),
        );
      });
    });

    unawaited(pty.exitCode.then((code) => _onSessionExit(id, code)));

    return {'terminalId': id, 'cwd': cwd, 'shell': pty.shell};
  }

  List<Map<String, Object?>> list() => [
        for (final s in _sessions.values)
          {'terminalId': s.terminalId, 'cwd': s.cwd, 'shell': s.pty.shell},
      ];

  void kill(String terminalId) {
    _require(terminalId).pty.kill();
    // Cleanup + exited broadcast happen when the exit future completes.
  }

  /// Registers [connectionId] on [terminalId]; returns the assigned slotId and
  /// immediately sends the scrollback snapshot frame.
  int subscribe(String connectionId, String terminalId) {
    final session = _require(terminalId);
    final existing = session.subscribers[connectionId];
    if (existing != null) return existing;

    final slotId = _nextSlot[connectionId] ?? 1;
    _nextSlot[connectionId] = slotId + 1;
    session.subscribers[connectionId] = slotId;
    (_slots[connectionId] ??= {})[slotId] = terminalId;

    sendBinary(
      connectionId,
      TerminalFrame(
        opcode: TerminalOpcode.snapshot,
        slotId: slotId,
        payload: session.scrollback.snapshot(),
      ).encode(),
    );
    return slotId;
  }

  void unsubscribe(String connectionId, String terminalId) {
    final session = _require(terminalId);
    final slotId = session.subscribers.remove(connectionId);
    if (slotId != null) _slots[connectionId]?.remove(slotId);
  }

  /// Routes a client binary frame (input/resize) by (connection, slot).
  /// Unknown slots and daemon->client opcodes are ignored.
  void handleFrame(String connectionId, TerminalFrame frame) {
    final terminalId = _slots[connectionId]?[frame.slotId];
    if (terminalId == null) return;
    final session = _sessions[terminalId];
    if (session == null) return;
    switch (frame.opcode) {
      case TerminalOpcode.input:
        session.pty.write(frame.payload);
      case TerminalOpcode.resize:
        if (frame.payload.length < 4) return;
        final (cols, rows) = frame.resizeSize;
        session.pty.resize(cols, rows);
      case TerminalOpcode.output:
      case TerminalOpcode.snapshot:
        break; // daemon -> client only
    }
  }

  /// Drops all subscriptions held by a closed connection.
  void onConnectionClosed(String connectionId) {
    final slots = _slots.remove(connectionId);
    _nextSlot.remove(connectionId);
    if (slots == null) return;
    for (final terminalId in slots.values) {
      _sessions[terminalId]?.subscribers.remove(connectionId);
    }
  }

  void _onSessionExit(String terminalId, int? exitCode) {
    final session = _sessions.remove(terminalId);
    if (session == null) return;
    unawaited(session.outputSub?.cancel());
    for (final entry in session.subscribers.entries) {
      _slots[entry.key]?.remove(entry.value);
    }
    if (!_disposed) onExited(terminalId, exitCode);
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final session in _sessions.values.toList()) {
      session.pty.kill();
    }
    _sessions.clear();
    _slots.clear();
    _nextSlot.clear();
  }

  _Session _require(String terminalId) {
    final session = _sessions[terminalId];
    if (session == null) {
      throw StateError('unknown terminal: $terminalId');
    }
    return session;
  }
}

class _Session {
  _Session({
    required this.terminalId,
    required this.pty,
    required this.cwd,
    required this.scrollback,
  });

  final String terminalId;
  final Pty pty;
  final String cwd;
  final _RingBuffer scrollback;

  /// connectionId -> slotId.
  final Map<String, int> subscribers = {};
  StreamSubscription<Uint8List>? outputSub;
}

/// Byte ring buffer built from chunks; trims oldest bytes past [limit].
class _RingBuffer {
  _RingBuffer(this.limit);

  final int limit;
  final Queue<Uint8List> _chunks = Queue();
  int _length = 0;

  void add(Uint8List chunk) {
    if (chunk.isEmpty) return;
    if (chunk.length >= limit) {
      _chunks.clear();
      _chunks.add(Uint8List.sublistView(chunk, chunk.length - limit));
      _length = limit;
      return;
    }
    _chunks.add(chunk);
    _length += chunk.length;
    while (_length > limit) {
      final excess = _length - limit;
      final head = _chunks.first;
      if (head.length <= excess) {
        _chunks.removeFirst();
        _length -= head.length;
      } else {
        _chunks
          ..removeFirst()
          ..addFirst(Uint8List.sublistView(head, excess));
        _length -= excess;
      }
    }
  }

  Uint8List snapshot() {
    final out = Uint8List(_length);
    var offset = 0;
    for (final chunk in _chunks) {
      out.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return out;
  }
}
