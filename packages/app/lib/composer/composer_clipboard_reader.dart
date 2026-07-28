import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:pasteboard/pasteboard.dart';

abstract interface class ComposerClipboardReader {
  Future<Uint8List?> readPngImage();

  Future<String?> readText();
}

final class SystemComposerClipboardReader implements ComposerClipboardReader {
  const SystemComposerClipboardReader();

  @override
  Future<Uint8List?> readPngImage() async {
    final bytes = await Pasteboard.image;
    if (bytes == null || bytes.isEmpty) return null;
    return compute(normalizeClipboardImageToPng, bytes);
  }

  @override
  Future<String?> readText() => Pasteboard.text;
}

Uint8List normalizeClipboardImageToPng(Uint8List bytes) {
  try {
    final decoded = image.decodeImage(bytes);
    if (decoded != null) {
      return Uint8List.fromList(image.encodePng(decoded));
    }
  } catch (_) {
    // Normalize decoder-specific range/format failures below.
  }
  throw const FormatException('Clipboard image format is not decodable.');
}
