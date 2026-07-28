import 'dart:typed_data';

import 'package:coding_agent_app/attachments/memory_attachment_store.dart';
import 'package:coding_agent_app/composer/composer_image_attachment_service.dart';
import 'package:coding_agent_app/composer/composer_image_attachments.dart';
import 'package:coding_agent_app/composer/composer_clipboard_reader.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('picker persists supported images and isolates invalid files', () async {
    final store = MemoryAttachmentStore();
    final service = ComposerImageAttachmentService(
      store: () async => store,
      picker: () async => [
        XFile.fromData(
          Uint8List.fromList([1, 2, 3]),
          path: 'pixel.png',
          name: 'pixel.png',
          mimeType: 'image/png',
        ),
        XFile.fromData(
          Uint8List.fromList([4]),
          path: 'notes.txt',
          name: 'notes.txt',
          mimeType: 'text/plain',
        ),
      ],
    );

    final images = await service.pick();

    expect(images, hasLength(1));
    expect(images.single.fileName, 'pixel.png');
    expect(images.single.metadata?.byteSize, 3);
    expect((await service.encodeForSend(images)).single.mimeType, 'image/png');
    await service.deleteAll(images);
    expect(await service.encodeForSend(images), isEmpty);
  });

  test('supports in-memory images and dropped fallback file names', () async {
    final store = MemoryAttachmentStore();
    final service = ComposerImageAttachmentService(store: () async => store);
    final pending = PendingComposerImage(
      id: 'memory',
      fileName: 'memory.png',
      mimeType: 'image/png',
      bytes: Uint8List.fromList([1]),
    );

    expect((await service.encodeForSend([pending])).single.data, 'AQ==');
    await service.delete(pending);

    final dropped = await service.persistDropped([
      DropItemFile.fromData(
        Uint8List.fromList([2]),
        name: '',
        path: r'C:\images\fallback.png',
        mimeType: 'image/png',
      ),
      DropItemDirectory.fromData(
        Uint8List(0),
        const [],
        name: 'ignored',
        path: 'ignored',
      ),
    ]);
    expect(dropped.single.fileName, 'fallback.png');
  });

  test('clipboard distinguishes no image from a persisted image', () async {
    final store = MemoryAttachmentStore();
    final service = ComposerImageAttachmentService(store: () async => store);

    expect(
      await service.paste(const _ClipboardReader(text: 'text only')),
      isNull,
    );
    final images = await service.paste(
      _ClipboardReader(image: Uint8List.fromList([1, 2, 3])),
    );
    expect(images, hasLength(1));
    expect(images!.single.fileName, 'pasted-image.png');
    expect(images.single.mimeType, 'image/png');
    expect(images.single.metadata?.byteSize, 3);
  });

  test(
    'restores persisted images independently from attachment metadata',
    () async {
      final store = MemoryAttachmentStore();
      final service = ComposerImageAttachmentService(store: () async => store);
      final first = await store.save(
        id: 'first',
        mimeType: 'image/png',
        fileName: 'first.png',
        bytes: Uint8List.fromList([1, 2]),
      );
      final missing = await store.save(
        id: 'missing',
        mimeType: 'image/png',
        fileName: 'missing.png',
        bytes: Uint8List.fromList([3]),
      );
      await store.delete(missing);

      final restored = await service.restore([first, missing]);

      expect(restored, hasLength(1));
      expect(restored.single.id, 'first');
      expect(restored.single.bytes, [1, 2]);
      expect(restored.single.metadata, same(first));
    },
  );

  test('encodes browser screenshot metadata with per-item isolation', () async {
    final store = MemoryAttachmentStore();
    final service = ComposerImageAttachmentService(store: () async => store);
    final first = await store.save(
      id: 'first',
      mimeType: 'image/png',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    final missing = await store.save(
      id: 'missing',
      mimeType: 'image/png',
      bytes: Uint8List.fromList([4]),
    );
    await store.delete(missing);

    final encoded = await service.encodeMetadataForSend([first, missing]);

    expect(encoded, hasLength(1));
    expect(encoded.single.mimeType, 'image/png');
    expect(encoded.single.data, 'AQID');
  });

  test('garbage collection preserves only referenced attachment ids', () async {
    final store = MemoryAttachmentStore();
    final service = ComposerImageAttachmentService(store: () async => store);
    final first = await store.save(
      id: 'first',
      mimeType: 'image/png',
      bytes: Uint8List.fromList([1]),
    );
    final second = await store.save(
      id: 'second',
      mimeType: 'image/png',
      bytes: Uint8List.fromList([2]),
    );

    await service.garbageCollectReferenced({'first'});

    expect(await store.readBytes(first), [1]);
    expect(() => store.readBytes(second), throwsStateError);
  });

  test('file selector type group covers the frozen raster surface', () {
    expect(
      composerImageTypeGroup.extensions,
      containsAll(['png', 'heic', 'tiff']),
    );
    expect(composerImageTypeGroup.mimeTypes, contains('image/avif'));
    expect(composerImageTypeGroup.uniformTypeIdentifiers, ['public.image']);
    expect(composerImageTypeGroup.webWildCards, ['image/*']);
  });
}

final class _ClipboardReader implements ComposerClipboardReader {
  const _ClipboardReader({this.image, this.text});

  final Uint8List? image;
  final String? text;

  @override
  Future<Uint8List?> readPngImage() async => image;

  @override
  Future<String?> readText() async => text;
}
