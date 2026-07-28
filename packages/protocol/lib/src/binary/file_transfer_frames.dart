import 'dart:convert';
import 'dart:typed_data';

enum FileTransferOpcode {
  fileBegin(0x10),
  fileChunk(0x11),
  fileEnd(0x12);

  const FileTransferOpcode(this.value);
  final int value;

  static FileTransferOpcode? fromValue(int value) => switch (value) {
    0x10 => fileBegin,
    0x11 => fileChunk,
    0x12 => fileEnd,
    _ => null,
  };
}

final class FileBeginMetadata {
  const FileBeginMetadata({
    required this.mime,
    required this.size,
    required this.encoding,
    required this.modifiedAt,
    this.revision,
    this.fileName,
  });

  final String mime;
  final int size;
  final String encoding;
  final String modifiedAt;
  final String? revision;
  final String? fileName;

  Map<String, Object?> toJson() => {
    'mime': mime,
    'size': size,
    'encoding': encoding,
    'modifiedAt': modifiedAt,
    if (revision != null) 'revision': revision,
    if (fileName != null) 'fileName': fileName,
  };

  static FileBeginMetadata? fromJson(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final mime = value['mime'];
    final size = value['size'];
    final encoding = value['encoding'];
    final modifiedAt = value['modifiedAt'];
    final revision = value['revision'];
    final fileName = value['fileName'];
    if (mime is! String ||
        mime.isEmpty ||
        size is! int ||
        size < 0 ||
        encoding is! String ||
        (encoding != 'utf-8' && encoding != 'binary') ||
        modifiedAt is! String ||
        (revision != null && revision is! String) ||
        (fileName != null && fileName is! String)) {
      return null;
    }
    return FileBeginMetadata(
      mime: mime,
      size: size,
      encoding: encoding,
      modifiedAt: modifiedAt,
      revision: revision as String?,
      fileName: fileName as String?,
    );
  }
}

final class FileTransferFrame {
  const FileTransferFrame({
    required this.opcode,
    required this.requestId,
    this.metadata,
    this.payload = const <int>[],
  });

  final FileTransferOpcode opcode;
  final String requestId;
  final FileBeginMetadata? metadata;
  final List<int> payload;

  Uint8List encode() {
    final requestIdBytes = utf8.encode(requestId);
    if (requestIdBytes.isEmpty) {
      throw RangeError('File transfer requestId is required');
    }
    if (requestIdBytes.length > 0xff) {
      throw RangeError('File transfer requestId is too long');
    }
    if (opcode == FileTransferOpcode.fileBegin) {
      final value = metadata;
      if (value == null) throw ArgumentError.notNull('metadata');
      final metadataBytes = utf8.encode(jsonEncode(value.toJson()));
      if (metadataBytes.length > 0xffff) {
        throw RangeError('FileBegin metadata is too long');
      }
      final bytes = Uint8List(4 + requestIdBytes.length + metadataBytes.length);
      bytes[0] = opcode.value;
      bytes[1] = requestIdBytes.length;
      bytes.setRange(2, 2 + requestIdBytes.length, requestIdBytes);
      ByteData.sublistView(
        bytes,
      ).setUint16(2 + requestIdBytes.length, metadataBytes.length, Endian.big);
      bytes.setRange(4 + requestIdBytes.length, bytes.length, metadataBytes);
      return bytes;
    }
    final body = opcode == FileTransferOpcode.fileChunk
        ? Uint8List.fromList(payload)
        : Uint8List(0);
    final bytes = Uint8List(2 + requestIdBytes.length + body.length);
    bytes[0] = opcode.value;
    bytes[1] = requestIdBytes.length;
    bytes.setRange(2, 2 + requestIdBytes.length, requestIdBytes);
    bytes.setRange(2 + requestIdBytes.length, bytes.length, body);
    return bytes;
  }

  static FileTransferFrame? decode(Uint8List bytes) {
    if (bytes.length < 2) return null;
    final opcode = FileTransferOpcode.fromValue(bytes[0]);
    if (opcode == null) return null;
    final requestIdLength = bytes[1];
    if (requestIdLength == 0 || requestIdLength > bytes.length - 2) {
      return null;
    }
    final requestId = utf8.decode(
      bytes.sublist(2, 2 + requestIdLength),
      allowMalformed: true,
    );
    final body = Uint8List.sublistView(bytes, 2 + requestIdLength);
    if (opcode == FileTransferOpcode.fileBegin) {
      if (body.length < 2) return null;
      final metadataLength = ByteData.sublistView(
        body,
      ).getUint16(0, Endian.big);
      if (metadataLength != body.length - 2) return null;
      try {
        final decoded = jsonDecode(utf8.decode(body.sublist(2)));
        final metadata = FileBeginMetadata.fromJson(decoded);
        return metadata == null
            ? null
            : FileTransferFrame(
                opcode: opcode,
                requestId: requestId,
                metadata: metadata,
              );
      } on FormatException {
        return null;
      }
    }
    if (opcode == FileTransferOpcode.fileChunk) {
      return FileTransferFrame(
        opcode: opcode,
        requestId: requestId,
        payload: body,
      );
    }
    return body.isEmpty
        ? FileTransferFrame(opcode: opcode, requestId: requestId)
        : null;
  }
}
