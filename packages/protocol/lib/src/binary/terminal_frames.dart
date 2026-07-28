/// Binary WebSocket frame codec for terminal streams.
///
/// Layout: `[1 byte opcode][1 byte slot][payload]`.
/// A "slot" is a per-connection subscription handle assigned by the daemon in
/// the `terminal.subscribe` response, so binary frames avoid string ids.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../messages/terminal_state.dart';
import '../terminal/terminal_snapshot.dart';

enum TerminalOpcode {
  /// daemon -> client: raw PTY output bytes.
  output(0x01),

  /// client -> daemon: user keystrokes / pasted bytes.
  input(0x02),

  /// client -> daemon: resize; payload is 2x uint16 LE (cols, rows).
  resize(0x03),

  /// daemon -> client: replay of the retained scrollback buffer, sent once
  /// right after subscribe before any live output.
  snapshot(0x04),

  /// client -> daemon: restore a previously captured terminal state.
  restore(0x05);

  const TerminalOpcode(this.value);

  final int value;

  static TerminalOpcode? fromValue(int value) => switch (value) {
    0x01 => output,
    0x02 => input,
    0x03 => resize,
    0x04 => snapshot,
    0x05 => restore,
    _ => null,
  };
}

final class TerminalFrame {
  const TerminalFrame({
    required this.opcode,
    required this.slotId,
    required this.payload,
  });

  final TerminalOpcode opcode;
  final int slotId;
  final Uint8List payload;

  static TerminalFrame resize(
    int slotId, {
    required int cols,
    required int rows,
  }) {
    final payload = Uint8List.fromList(
      utf8.encode(jsonEncode({'rows': rows, 'cols': cols})),
    );
    return TerminalFrame(
      opcode: TerminalOpcode.resize,
      slotId: slotId,
      payload: payload,
    );
  }

  /// Returns (cols, rows) for a resize frame.
  (int, int) get resizeSize {
    final value = tryResizeSize;
    if (value == null) throw const FormatException('invalid resize payload');
    return value;
  }

  (int, int)? get tryResizeSize {
    try {
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is! Map) return null;
      final rows = decoded['rows'];
      final cols = decoded['cols'];
      if (rows is! int || cols is! int || rows <= 0 || cols <= 0) return null;
      return (cols, rows);
    } on Object {
      return null;
    }
  }

  TerminalState get snapshotState {
    final value = trySnapshotState;
    if (value == null) throw const FormatException('invalid snapshot payload');
    return value;
  }

  TerminalState? get trySnapshotState {
    try {
      final decoded = jsonDecode(utf8.decode(payload));
      if (decoded is! Map) return null;
      return TerminalState.fromJson(decoded.cast<String, Object?>());
    } on Object {
      return null;
    }
  }

  static TerminalFrame snapshot(int slotId, TerminalState state) =>
      TerminalFrame(
        opcode: TerminalOpcode.snapshot,
        slotId: slotId,
        payload: Uint8List.fromList(utf8.encode(jsonEncode(state.toJson()))),
      );

  static TerminalFrame restore(int slotId, TerminalState state) =>
      TerminalFrame(
        opcode: TerminalOpcode.restore,
        slotId: slotId,
        payload: Uint8List.fromList(
          utf8.encode(renderTerminalSnapshotToAnsi(state)),
        ),
      );

  Uint8List encode() {
    final bytes = Uint8List(2 + payload.length);
    bytes[0] = opcode.value;
    bytes[1] = slotId & 0xff;
    bytes.setRange(2, bytes.length, payload);
    return bytes;
  }

  /// Returns null for malformed or unknown frames.
  static TerminalFrame? decode(Uint8List bytes) {
    if (bytes.length < 2) return null;
    final opcode = TerminalOpcode.fromValue(bytes[0]);
    if (opcode == null) return null;
    return TerminalFrame(
      opcode: opcode,
      slotId: bytes[1],
      payload: Uint8List.sublistView(bytes, 2),
    );
  }
}
