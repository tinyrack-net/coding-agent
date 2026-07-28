import 'dart:convert';
import 'dart:typed_data';

String relayBase64Encode(List<int> bytes) => base64.encode(bytes);

/// Decodes standard or URL-safe base64 with optional omitted padding.
Uint8List relayBase64Decode(String encoded) {
  final standard = encoded.trim().replaceAll('-', '+').replaceAll('_', '/');
  final paddingLength = (4 - standard.length % 4) % 4;
  final padding = List.filled(paddingLength, '=').join();
  return base64.decode('$standard$padding');
}
