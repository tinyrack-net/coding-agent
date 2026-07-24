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
      expect(bytes.length, 5);
      final decoded = TerminalFrame.decode(bytes)!;
      expect(decoded.opcode, TerminalOpcode.input);
      expect(decoded.slotId, 0);
      expect(decoded.payload, isEmpty);
    });

    test('round-trips large slotId using full uint32 range', () {
      final frame = TerminalFrame(
        opcode: TerminalOpcode.snapshot,
        slotId: 0xFFFFFFFF,
        payload: Uint8List.fromList([9]),
      );
      final decoded = TerminalFrame.decode(frame.encode())!;
      expect(decoded.slotId, 0xFFFFFFFF);
      expect(decoded.payload, [9]);
    });

    test('encode places opcode byte first and slotId little-endian', () {
      final frame = TerminalFrame(
        opcode: TerminalOpcode.output,
        slotId: 0x01020304,
        payload: Uint8List.fromList([0xAA]),
      );
      final bytes = frame.encode();
      expect(bytes[0], 0x01); // opcode value for output
      // little-endian slotId bytes
      expect(bytes.sublist(1, 5), [0x04, 0x03, 0x02, 0x01]);
      expect(bytes[5], 0xAA);
    });

    test('decode returns null for buffers shorter than 5 bytes', () {
      expect(TerminalFrame.decode(Uint8List(0)), isNull);
      expect(TerminalFrame.decode(Uint8List(4)), isNull);
    });

    test('decode returns null for unknown opcode byte', () {
      final bytes = Uint8List(5)..[0] = 0x99;
      expect(TerminalFrame.decode(bytes), isNull);
    });

    test('decode accepts exactly 5 bytes (empty payload boundary)', () {
      final bytes = Uint8List(5)..[0] = TerminalOpcode.resize.value;
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

    test('handles boundary uint16 values for cols/rows', () {
      final frame = TerminalFrame.resize(1, cols: 0, rows: 65535);
      expect(frame.resizeSize, (0, 65535));
    });
  });
}
