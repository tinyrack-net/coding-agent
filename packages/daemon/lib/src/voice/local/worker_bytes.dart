import 'dart:convert';
import 'dart:typed_data';

Uint8List bufferToWorkerBytes(List<int> buffer) => Uint8List.fromList(buffer);

Uint8List workerBytesToBuffer(List<int> bytes) => Uint8List.fromList(bytes);

String workerBytesToJson(List<int> bytes) => base64Encode(bytes);

Uint8List workerBytesFromJson(Object? value) {
  if (value is! String) {
    throw const FormatException('Invalid local speech worker bytes');
  }
  try {
    return Uint8List.fromList(base64Decode(value));
  } on FormatException {
    throw const FormatException('Invalid local speech worker bytes');
  }
}
