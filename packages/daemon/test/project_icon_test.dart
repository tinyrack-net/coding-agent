import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_daemon/src/server/project_icon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tinyrack-icon-');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test(
    'priority directories, patterns, depth, and monorepos match Paseo',
    () async {
      File(p.join(root.path, 'favicon.svg')).writeAsStringSync('<svg/>');
      final public = Directory(p.join(root.path, 'public'))..createSync();
      File(p.join(public.path, 'logo.svg')).writeAsStringSync('<svg/>');
      File(p.join(public.path, 'icon-z.png')).writeAsBytesSync(_png(1, 1));
      expect(p.basename((await findProjectIcon(root.path))!), 'icon-z.png');

      public.deleteSync(recursive: true);
      final package = Directory(p.join(root.path, 'packages', 'app', 'assets'))
        ..createSync(recursive: true);
      File(p.join(package.path, 'app-icon.svg')).writeAsStringSync('<svg/>');
      expect(
        (await findProjectIcon(root.path))!.replaceAll(r'\', '/'),
        endsWith('packages/app/assets/app-icon.svg'),
      );

      Directory(p.join(root.path, 'packages')).deleteSync(recursive: true);
      expect(p.basename((await findProjectIcon(root.path))!), 'favicon.svg');
      expect(await findProjectIcon(p.join(root.path, 'missing')), isNull);

      File(p.join(root.path, 'favicon.svg')).deleteSync();
      final directPackage = Directory(p.join(root.path, 'apps', 'desktop'))
        ..createSync(recursive: true);
      File(p.join(directPackage.path, 'icon.svg')).writeAsStringSync('<svg/>');
      expect(
        (await findProjectIcon(root.path))!.replaceAll(r'\', '/'),
        endsWith('apps/desktop/icon.svg'),
      );
    },
  );

  test(
    'priority recursion skips ignored directories and honors depth',
    () async {
      final ignored = Directory(p.join(root.path, 'public', 'src'))
        ..createSync(recursive: true);
      File(p.join(ignored.path, 'favicon.svg')).writeAsStringSync('<svg/>');
      final nested = Directory(p.join(root.path, 'public', 'nested'))
        ..createSync(recursive: true);
      File(p.join(nested.path, 'file.txt')).writeAsStringSync('not an icon');
      File(p.join(nested.path, 'icon.svg')).writeAsStringSync('<svg/>');
      expect(
        (await findProjectIcon(root.path))!.replaceAll(r'\', '/'),
        endsWith('public/nested/icon.svg'),
      );
      expect(await findProjectIcon(root.path, maxDepth: 0), isNull);
    },
  );

  test('returns only square icons no larger than 32 KiB', () async {
    final public = Directory(p.join(root.path, 'public'))..createSync();
    final icon = File(p.join(public.path, 'favicon.png'))
      ..writeAsBytesSync(_png(16, 16));
    final result = await getProjectIcon(root.path);
    expect(result!['mimeType'], 'image/png');
    expect(base64Decode(result['data']!), _png(16, 16));

    icon.writeAsBytesSync(_png(16, 8));
    expect(await getProjectIcon(root.path), isNull);
    icon.writeAsBytesSync(List.filled(maxProjectIconBytes + 1, 0));
    expect(await getProjectIcon(root.path), isNull);
    icon.writeAsBytesSync([1, 2, 3]);
    expect(await getProjectIcon(root.path), isNull);
  });

  test('recognizes square SVG and ICO candidates', () async {
    final assets = Directory(p.join(root.path, 'assets'))..createSync();

    Future<void> expectMime(String name, List<int> bytes, String mime) async {
      for (final entity in assets.listSync()) {
        entity.deleteSync();
      }
      File(p.join(assets.path, name)).writeAsBytesSync(bytes);
      expect((await getProjectIcon(root.path))!['mimeType'], mime);
    }

    await expectMime('icon.svg', utf8.encode('<svg/>'), 'image/svg+xml');
    await expectMime('favicon.ico', [0, 0, 1, 0], 'image/x-icon');
  });

  test('dimension readers cover GIF, JPEG, and WebP variants', () {
    expect(isSquareProjectIcon(_gif(12, 12), 'image/gif'), isTrue);
    expect(isSquareProjectIcon(_gif(12, 11), 'image/gif'), isFalse);
    expect(isSquareProjectIcon(_jpeg(10, 10), 'image/jpeg'), isTrue);
    expect(isSquareProjectIcon(_webpLossy(9, 9), 'image/webp'), isTrue);
    expect(isSquareProjectIcon(_webpLossless(7, 7), 'image/webp'), isTrue);
    expect(
      isSquareProjectIcon(Uint8List(0), 'application/octet-stream'),
      isFalse,
    );
    expect(isSquareProjectIcon(_jpegWithPrefix(6, 6), 'image/jpeg'), isTrue);
    expect(isSquareProjectIcon(_jpegWithSegment(5, 5), 'image/jpeg'), isTrue);
    expect(isSquareProjectIcon(_jpegZeroSegment(), 'image/jpeg'), isFalse);
  });

  test('maps every supported project icon MIME extension', () {
    expect(projectIconMimeType('a.jpg'), 'image/jpeg');
    expect(projectIconMimeType('a.jpeg'), 'image/jpeg');
    expect(projectIconMimeType('a.gif'), 'image/gif');
    expect(projectIconMimeType('a.webp'), 'image/webp');
    expect(projectIconMimeType('a.bin'), 'application/octet-stream');
  });
}

Uint8List _png(int width, int height) {
  final bytes = Uint8List(24);
  bytes.setAll(0, [0x89, 0x50, 0x4e, 0x47]);
  final data = ByteData.sublistView(bytes);
  data.setUint32(16, width, Endian.big);
  data.setUint32(20, height, Endian.big);
  return bytes;
}

Uint8List _gif(int width, int height) {
  final bytes = Uint8List(10)..setAll(0, ascii.encode('GIF89a'));
  final data = ByteData.sublistView(bytes);
  data.setUint16(6, width, Endian.little);
  data.setUint16(8, height, Endian.little);
  return bytes;
}

Uint8List _jpeg(int width, int height) {
  final bytes = Uint8List(12)
    ..setAll(0, [0xff, 0xd8, 0xff, 0xc0, 0, 8, 8, 0, 0, 0, 0, 0]);
  final data = ByteData.sublistView(bytes);
  data.setUint16(9, width, Endian.big);
  data.setUint16(7, height, Endian.big);
  return bytes;
}

Uint8List _jpegWithPrefix(int width, int height) {
  final bytes = Uint8List(13)
    ..setAll(0, [0xff, 0xd8, 0, 0xff, 0xc0, 0, 8, 8, 0, 0, 0, 0, 0]);
  final data = ByteData.sublistView(bytes);
  data.setUint16(10, width, Endian.big);
  data.setUint16(8, height, Endian.big);
  return bytes;
}

Uint8List _jpegWithSegment(int width, int height) {
  final bytes = Uint8List(17)
    ..setAll(0, [
      0xff,
      0xd8,
      0xff,
      0xe0,
      0,
      2,
      0xff,
      0xc0,
      0,
      8,
      8,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
  final data = ByteData.sublistView(bytes);
  data.setUint16(13, width, Endian.big);
  data.setUint16(11, height, Endian.big);
  return bytes;
}

Uint8List _jpegZeroSegment() =>
    Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0]);

Uint8List _webpLossy(int width, int height) {
  final bytes = Uint8List(30)
    ..setAll(0, ascii.encode('RIFF'))
    ..setAll(8, ascii.encode('WEBP'))
    ..setAll(12, ascii.encode('VP8 '));
  final data = ByteData.sublistView(bytes);
  data.setUint16(26, width, Endian.little);
  data.setUint16(28, height, Endian.little);
  return bytes;
}

Uint8List _webpLossless(int width, int height) {
  final bytes = Uint8List(30)
    ..setAll(0, ascii.encode('RIFF'))
    ..setAll(8, ascii.encode('WEBP'))
    ..setAll(12, ascii.encode('VP8L'));
  final bits = (width - 1) | ((height - 1) << 14);
  ByteData.sublistView(bytes).setUint32(21, bits, Endian.little);
  return bytes;
}
