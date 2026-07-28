import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

typedef TerminalOutputFlush = void Function(TerminalOutputBatch batch);
typedef TerminalOutputClock = int Function();
typedef TerminalOutputTimerFactory =
    Timer Function(Duration delay, void Function() callback);

final class TerminalOutputBatch {
  const TerminalOutputBatch({
    required this.payload,
    required this.bytes,
    required this.chars,
  });

  final Uint8List payload;
  final int bytes;
  final int chars;
}

/// Coalesces PTY output with Paseo's 5 ms leading/trailing-edge policy.
final class TerminalOutputCoalescer {
  TerminalOutputCoalescer({
    required TerminalOutputFlush onFlush,
    Duration delay = const Duration(milliseconds: 5),
    TerminalOutputClock? now,
    TerminalOutputTimerFactory? createTimer,
  }) : _onFlush = onFlush,
       _delay = delay,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _createTimer =
           createTimer ?? ((delay, callback) => Timer(delay, callback));

  final TerminalOutputFlush _onFlush;
  final Duration _delay;
  final TerminalOutputClock _now;
  final TerminalOutputTimerFactory _createTimer;
  final List<Uint8List> _chunks = [];

  Timer? _timer;
  int? _lastFlushAt;
  int _bytes = 0;
  int _chars = 0;
  bool _disposed = false;

  void handle(Uint8List data) {
    if (_disposed || data.isEmpty) return;
    final copy = Uint8List.fromList(data);
    _chunks.add(copy);
    _bytes += copy.length;
    _chars += utf8.decode(copy, allowMalformed: true).length;

    if (_timer != null) return;
    final lastFlushAt = _lastFlushAt;
    if (lastFlushAt == null || _now() - lastFlushAt >= _delay.inMilliseconds) {
      flush();
      return;
    }
    _timer = _createTimer(_delay, flush);
  }

  void flush() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    if (_chunks.isEmpty) return;

    final payload = Uint8List(_bytes);
    var offset = 0;
    for (final chunk in _chunks) {
      payload.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    final batch = TerminalOutputBatch(
      payload: payload,
      bytes: _bytes,
      chars: _chars,
    );
    _chunks.clear();
    _bytes = 0;
    _chars = 0;
    _lastFlushAt = _now();
    _onFlush(batch);
  }

  /// Records an out-of-band frame so the next chunk takes the trailing path.
  void markFlushed() {
    if (!_disposed) _lastFlushAt = _now();
  }

  /// Cancels timers and deliberately drops pending output.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _chunks.clear();
    _bytes = 0;
    _chars = 0;
  }
}
