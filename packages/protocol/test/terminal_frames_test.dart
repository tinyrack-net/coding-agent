import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('TerminalOpcode', () {
    test('fromValue resolves all known opcodes', () {
      expect(TerminalOpcode.fromValue(0x01), TerminalOpcode.output);
      expect(TerminalOpcode.fromValue(0x02), TerminalOpcode.input);
      expect(TerminalOpcode.fromValue(0x03), TerminalOpcode.resize);
      expect(TerminalOpcode.fromValue(0x04), TerminalOpcode.snapshot);
      expect(TerminalOpcode.fromValue(0x05), TerminalOpcode.restore);
    });

    test('fromValue returns null for unknown opcode', () {
      expect(TerminalOpcode.fromValue(0xFF), isNull);
      expect(TerminalOpcode.fromValue(0x00), isNull);
    });
  });

  group('TerminalFrame encode/decode', () {
    test('round-trips an output frame with payload', () {
      final frame = TerminalFrame(
        opcode: TerminalOpcode.output,
        slotId: 7,
        payload: Uint8List.fromList([1, 2, 3, 4, 5]),
      );
      final decoded = TerminalFrame.decode(frame.encode())!;
      expect(decoded.opcode, TerminalOpcode.output);
      expect(decoded.slotId, 7);
      expect(decoded.payload, [1, 2, 3, 4, 5]);
    });

    test('round-trips an empty payload', () {
      final frame = TerminalFrame(
        opcode: TerminalOpcode.input,
        slotId: 0,
        payload: Uint8List(0),
      );
      final bytes = frame.encode();
      expect(bytes.length, 2);
      final decoded = TerminalFrame.decode(bytes)!;
      expect(decoded.opcode, TerminalOpcode.input);
      expect(decoded.slotId, 0);
      expect(decoded.payload, isEmpty);
    });

    test('encodes the slot as one byte like Paseo', () {
      final frame = TerminalFrame(
        opcode: TerminalOpcode.snapshot,
        slotId: 0x1ff,
        payload: Uint8List.fromList([9]),
      );
      final decoded = TerminalFrame.decode(frame.encode())!;
      expect(decoded.slotId, 0xff);
      expect(decoded.payload, [9]);
    });

    test('encode places opcode and one-byte slot first', () {
      final frame = TerminalFrame(
        opcode: TerminalOpcode.output,
        slotId: 0x04,
        payload: Uint8List.fromList([0xAA]),
      );
      final bytes = frame.encode();
      expect(bytes, [0x01, 0x04, 0xAA]);
    });

    test('decode returns null for buffers shorter than 2 bytes', () {
      expect(TerminalFrame.decode(Uint8List(0)), isNull);
      expect(TerminalFrame.decode(Uint8List(1)), isNull);
    });

    test('decode returns null for unknown opcode byte', () {
      final bytes = Uint8List(2)..[0] = 0x99;
      expect(TerminalFrame.decode(bytes), isNull);
    });

    test('decode accepts exactly 2 bytes (empty payload boundary)', () {
      final bytes = Uint8List(2)..[0] = TerminalOpcode.resize.value;
      final decoded = TerminalFrame.decode(bytes)!;
      expect(decoded.payload, isEmpty);
    });
  });

  group('TerminalFrame.resize helper', () {
    test('encodes cols/rows and round-trips via resizeSize', () {
      final frame = TerminalFrame.resize(3, cols: 120, rows: 40);
      expect(frame.opcode, TerminalOpcode.resize);
      expect(frame.slotId, 3);
      expect(frame.resizeSize, (120, 40));
    });

    test('resize payload round-trips through encode/decode', () {
      final frame = TerminalFrame.resize(1, cols: 200, rows: 55);
      final decoded = TerminalFrame.decode(frame.encode())!;
      expect(decoded.resizeSize, (200, 55));
    });

    test('rejects non-positive and malformed JSON resize payloads', () {
      final zero = TerminalFrame.resize(1, cols: 0, rows: 65535);
      expect(zero.tryResizeSize, isNull);
      expect(() => zero.resizeSize, throwsFormatException);
      final malformed = TerminalFrame(
        opcode: TerminalOpcode.resize,
        slotId: 1,
        payload: Uint8List.fromList([0xff]),
      );
      expect(malformed.tryResizeSize, isNull);
    });
  });

  group('TerminalFrame structured snapshots', () {
    const state = TerminalState(
      rows: 1,
      cols: 1,
      grid: [
        [TerminalCell(char: 'A')],
      ],
      scrollback: [],
      cursor: TerminalCursor(row: 0, col: 0),
    );

    test('snapshot payload round-trips exact terminal state JSON', () {
      final decoded = TerminalFrame.decode(
        TerminalFrame.snapshot(4, state).encode(),
      )!;
      expect(decoded.opcode, TerminalOpcode.snapshot);
      expect(decoded.snapshotState.toJson(), state.toJson());
    });

    test('restore payload contains an ANSI replay', () {
      final decoded = TerminalFrame.decode(
        TerminalFrame.restore(5, state).encode(),
      )!;
      expect(decoded.opcode, TerminalOpcode.restore);
      expect(decoded.payload, isNotEmpty);
      expect(decoded.trySnapshotState, isNull);
    });
  });
}
