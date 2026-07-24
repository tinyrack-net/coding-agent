// Throwaway generator for placeholder tray icons.
// Run from packages/app: `dart run tool/gen_tray_icons.dart`
// Produces assets/tray/tray_icon.png (32x32) and assets/tray/tray_icon.ico
// (single 32x32 entry wrapping the same bitmap).
import 'dart:io';
import 'dart:typed_data';

const size = 32;

/// RGBA pixels for a simple monochrome-ish glyph: a rounded filled square
/// with a hollow ">" prompt cut out — works as a macOS template image
/// (black + alpha) and is visible on Windows.
Uint8List buildPixels() {
  final pixels = Uint8List(size * size * 4);
  bool inSquare(int x, int y) {
    const margin = 3;
    const radius = 6;
    if (x < margin || x >= size - margin || y < margin || y >= size - margin) {
      return false;
    }
    // Rounded corners.
    final cx = x < size ~/ 2 ? margin + radius : size - margin - 1 - radius;
    final cy = y < size ~/ 2 ? margin + radius : size - margin - 1 - radius;
    final inCornerBox = (x < margin + radius || x >= size - margin - radius) &&
        (y < margin + radius || y >= size - margin - radius);
    if (!inCornerBox) return true;
    final dx = x - cx;
    final dy = y - cy;
    return dx * dx + dy * dy <= radius * radius;
  }

  // ">" prompt strokes (cut out of the square so the glyph reads inverted).
  bool inPrompt(int x, int y) {
    // Diagonal chevron from (10,10) to (16,16) to (10,22), 3px thick.
    for (var t = 0; t <= 6; t++) {
      if ((x - (10 + t)).abs() <= 1 && (y - (10 + t)).abs() <= 1) return true;
      if ((x - (10 + t)).abs() <= 1 && (y - (22 - t)).abs() <= 1) return true;
    }
    // Underscore cursor.
    if (y >= 21 && y <= 22 && x >= 19 && x <= 24) return true;
    return false;
  }

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final i = (y * size + x) * 4;
      final on = inSquare(x, y) && !inPrompt(x, y);
      pixels[i] = 0; // R
      pixels[i + 1] = 0; // G
      pixels[i + 2] = 0; // B
      pixels[i + 3] = on ? 255 : 0; // A
    }
  }
  return pixels;
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

Uint8List _chunk(String type, List<int> data) {
  final out = BytesBuilder();
  out.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
  final body = [...type.codeUnits, ...data];
  out.add(body);
  out.add((ByteData(4)..setUint32(0, _crc32(body))).buffer.asUint8List());
  return out.toBytes();
}

Uint8List buildPng(Uint8List rgba) {
  final ihdr = ByteData(13)
    ..setUint32(0, size)
    ..setUint32(4, size)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6) // color type RGBA
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  // Raw scanlines with filter byte 0.
  final raw = BytesBuilder();
  for (var y = 0; y < size; y++) {
    raw.addByte(0);
    raw.add(rgba.sublist(y * size * 4, (y + 1) * size * 4));
  }
  final compressed = ZLibCodec().encoder.convert(raw.toBytes());
  final png = BytesBuilder();
  png.add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  png.add(_chunk('IHDR', ihdr.buffer.asUint8List()));
  png.add(_chunk('IDAT', compressed));
  png.add(_chunk('IEND', const []));
  return png.toBytes();
}

Uint8List buildIco(Uint8List rgba) {
  // Single 32x32 BMP entry: BITMAPINFOHEADER + BGRA rows (bottom-up) + AND mask.
  final xorSize = size * size * 4;
  final andRowBytes = ((size + 31) ~/ 32) * 4;
  final andSize = andRowBytes * size;
  final imageSize = 40 + xorSize + andSize;

  final ico = BytesBuilder();
  // ICONDIR
  ico.add((ByteData(6)
        ..setUint16(0, 0, Endian.little)
        ..setUint16(2, 1, Endian.little) // type: icon
        ..setUint16(4, 1, Endian.little)) // count
      .buffer
      .asUint8List());
  // ICONDIRENTRY
  final entry = ByteData(16)
    ..setUint8(0, size)
    ..setUint8(1, size)
    ..setUint8(2, 0) // palette
    ..setUint8(3, 0)
    ..setUint16(4, 1, Endian.little) // planes
    ..setUint16(6, 32, Endian.little) // bpp
    ..setUint32(8, imageSize, Endian.little)
    ..setUint32(12, 6 + 16, Endian.little); // offset
  ico.add(entry.buffer.asUint8List());
  // BITMAPINFOHEADER (height doubled: XOR + AND masks)
  final header = ByteData(40)
    ..setUint32(0, 40, Endian.little)
    ..setInt32(4, size, Endian.little)
    ..setInt32(8, size * 2, Endian.little)
    ..setUint16(12, 1, Endian.little)
    ..setUint16(14, 32, Endian.little)
    ..setUint32(16, 0, Endian.little)
    ..setUint32(20, xorSize + andSize, Endian.little);
  ico.add(header.buffer.asUint8List());
  // XOR mask: BGRA, bottom-up.
  for (var y = size - 1; y >= 0; y--) {
    for (var x = 0; x < size; x++) {
      final i = (y * size + x) * 4;
      ico.add([rgba[i + 2], rgba[i + 1], rgba[i], rgba[i + 3]]);
    }
  }
  // AND mask: all zero (opacity handled by alpha channel).
  ico.add(Uint8List(andSize));
  return ico.toBytes();
}

void main() {
  final rgba = buildPixels();
  Directory('assets/tray').createSync(recursive: true);
  File('assets/tray/tray_icon.png').writeAsBytesSync(buildPng(rgba));
  File('assets/tray/tray_icon.ico').writeAsBytesSync(buildIco(rgba));
  stdout.writeln('wrote assets/tray/tray_icon.png and tray_icon.ico');
}
