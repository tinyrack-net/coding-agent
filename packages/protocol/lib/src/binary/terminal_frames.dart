/// Binary WebSocket frame codec for terminal streams.
///
/// Layout: `[1 byte opcode][4 bytes slotId little-endian][payload]`.
/// A "slot" is a per-connection subscription handle assigned by the daemon in
/// the `terminal.subscribe` response, so binary frames avoid string ids.
library;

import 'dart:typed_data';

enum TerminalOpcode {
  /// daemon -> client: raw PTY output bytes.
  output(0x01),

  /// client -> daemon: user keystrokes / pasted bytes.
  input(0x02),

  /// client -> daemon: resize; payload is 2x uint16 LE (cols, rows).
  resize(0x03),

  /// daemon -> client: replay of the retained scrollback buffer, sent once
  /// right after subscribe before any live output.
  snapshot(0x04);

  const TerminalOpcode(this.value);

  final int value;

  static TerminalOpcode? fromValue(int value) => switch (value) {
        0x01 => output,
        0x02 => input,
        0x03 => resize,
        0x04 => snapshot,
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

  static TerminalFrame resize(int slotId, {required int cols, required int rows}) {
    final payload = Uint8List(4)
      ..buffer.asByteData().setUint16(0, cols, Endian.little)
      ..buffer.asByteData().setUint16(2, rows, Endian.little);
    return TerminalFrame(
      opcode: TerminalOpcode.resize,
      slotId: slotId,
      payload: payload,
    );
  }

  /// Returns (cols, rows) for a resize frame.
  (int, int) get resizeSize {
    final data = ByteData.sublistView(payload);
    return (data.getUint16(0, Endian.little), data.getUint16(2, Endian.little));
  }

  Uint8List encode() {
    final bytes = Uint8List(5 + payload.length);
    bytes[0] = opcode.value;
    bytes.buffer.asByteData().setUint32(1, slotId, Endian.little);
    bytes.setRange(5, bytes.length, payload);
    return bytes;
  }

  /// Returns null for malformed or unknown frames.
  static TerminalFrame? decode(Uint8List bytes) {
    if (bytes.length < 5) return null;
    final opcode = TerminalOpcode.fromValue(bytes[0]);
    if (opcode == null) return null;
    return TerminalFrame(
      opcode: opcode,
      slotId: ByteData.sublistView(bytes).getUint32(1, Endian.little),
      payload: Uint8List.sublistView(bytes, 5),
    );
  }
}
