import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('encodes and decodes Paseo file begin metadata exactly', () {
    final frame = FileTransferFrame(
      opcode: FileTransferOpcode.fileBegin,
      requestId: 'req-1',
      metadata: const FileBeginMetadata(
        mime: 'image/png',
        size: 6,
        encoding: 'binary',
        modifiedAt: '2026-05-02T00:00:00.000Z',
        fileName: 'image.png',
      ),
    );
    final bytes = frame.encode();
    expect(bytes[0], 0x10);
    expect(bytes[1], 5);
    expect(utf8.decode(bytes.sublist(2, 7)), 'req-1');
    final decoded = FileTransferFrame.decode(bytes)!;
    expect(decoded.opcode, FileTransferOpcode.fileBegin);
    expect(decoded.requestId, 'req-1');
    expect(decoded.metadata!.mime, 'image/png');
    expect(decoded.metadata!.fileName, 'image.png');
  });

  test('round-trips chunks and end frames', () {
    final chunk = FileTransferFrame(
      opcode: FileTransferOpcode.fileChunk,
      requestId: 'upload',
      payload: const [0, 1, 2, 253, 254, 255],
    );
    expect(FileTransferFrame.decode(chunk.encode())!.payload, chunk.payload);
    final end = FileTransferFrame(
      opcode: FileTransferOpcode.fileEnd,
      requestId: 'upload',
    );
    expect(FileTransferFrame.decode(end.encode())!.payload, isEmpty);
  });

  test('rejects malformed and cross-protocol frames', () {
    expect(FileTransferFrame.decode(Uint8List(0)), isNull);
    expect(FileTransferFrame.decode(Uint8List.fromList([0x01, 0])), isNull);
    expect(FileTransferFrame.decode(Uint8List.fromList([0x10, 0])), isNull);
    expect(
      FileTransferFrame.decode(Uint8List.fromList([0x12, 1, 65, 1])),
      isNull,
    );
    expect(
      FileTransferFrame.decode(Uint8List.fromList([0x10, 1, 65, 0, 2, 1])),
      isNull,
    );
    expect(
      () => FileTransferFrame(
        opcode: FileTransferOpcode.fileChunk,
        requestId: '',
      ).encode(),
      throwsRangeError,
    );
    expect(
      () => FileTransferFrame(
        opcode: FileTransferOpcode.fileChunk,
        requestId: 'x' * 256,
      ).encode(),
      throwsRangeError,
    );
    expect(
      () => const FileTransferFrame(
        opcode: FileTransferOpcode.fileBegin,
        requestId: 'x',
      ).encode(),
      throwsArgumentError,
    );
    expect(
      () => FileTransferFrame(
        opcode: FileTransferOpcode.fileBegin,
        requestId: 'x',
        metadata: FileBeginMetadata(
          mime: 'text/plain',
          size: 1,
          encoding: 'binary',
          modifiedAt: 'now',
          revision: 'x' * 70000,
        ),
      ).encode(),
      throwsRangeError,
    );
    expect(
      FileBeginMetadata.fromJson({
        'mime': 'text/plain',
        'size': 1,
        'encoding': 'binary',
        'modifiedAt': 'now',
        'revision': 1,
      }),
      isNull,
    );
    expect(
      FileTransferFrame.decode(Uint8List.fromList([0x10, 1, 65, 0, 1, 0xff])),
      isNull,
    );
  });
}
