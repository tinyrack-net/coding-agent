import 'dart:convert';
import 'dart:typed_data';

import 'package:coding_agent_app/composer/composer_image_attachments.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts cross-platform attachment file names', () {
    expect(composerImageFileName(r'C:\images\pixel.png'), 'pixel.png');
    expect(composerImageFileName('/images/pixel.png'), 'pixel.png');
    expect(composerImageFileName(''), '');
  });

  test('resolves the frozen raster MIME surface', () {
    expect(resolveRasterImageMimeType(mimeType: 'image/jpg'), 'image/jpeg');
    expect(
      resolveRasterImageMimeType(mimeType: 'IMAGE/PNG; charset=binary'),
      'image/png',
    );
    expect(resolveRasterImageMimeType(path: 'photo.HEIC?raw=1'), 'image/heic');
    expect(resolveRasterImageMimeType(path: 'photo.svg'), isNull);
    expect(resolveRasterImageMimeType(), isNull);
  });

  test(
    'converts only readable dropped raster files to prompt images',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final images = await droppedItemsToComposerImages([
        DropItemFile.fromData(
          bytes,
          name: 'photo.png',
          mimeType: 'image/png',
          path: 'photo.png',
        ),
        DropItemFile.fromData(
          bytes,
          name: 'notes.txt',
          mimeType: 'text/plain',
          path: 'notes.txt',
        ),
        DropItemFile.fromData(
          bytes,
          name: '',
          mimeType: 'image/png',
          path: r'C:\images\fallback.png',
        ),
        DropItemDirectory.fromData(
          bytes,
          const [],
          name: 'folder',
          path: 'folder',
        ),
        _UnreadableDropItem(),
      ]);

      expect(images, hasLength(2));
      expect(images.first.fileName, 'photo.png');
      expect(images.last.fileName, 'fallback.png');
      expect(images.first.mimeType, 'image/png');
      expect(images.first.bytes, bytes);
      expect(images.first.toPromptImage().data, base64Encode(bytes));
    },
  );
}

final class _UnreadableDropItem extends DropItemFile {
  _UnreadableDropItem()
    : super('broken.png', mimeType: 'image/png', name: 'broken.png');

  @override
  Future<Uint8List> readAsBytes() =>
      Future<Uint8List>.error(StateError('unreadable'));
}
