import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:coding_agent_app/attachments/attachment_store.dart';
import 'package:coding_agent_app/attachments/attachment_store_factory_io.dart';
import 'package:coding_agent_app/attachments/file_attachment_store.dart';
import 'package:coding_agent_app/attachments/memory_attachment_store.dart';
import 'package:coding_agent_app/attachments/preferences_attachment_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('IO storage type distinguishes mobile from desktop', () {
    expect(
      ioAttachmentStorageType(isMobile: false),
      AttachmentStorageType.desktopFile,
    );
    expect(
      ioAttachmentStorageType(isMobile: true),
      AttachmentStorageType.nativeFile,
    );
  });

  test('attachment metadata uses the frozen Paseo wire names', () {
    const metadata = AttachmentMetadata(
      id: 'image-1',
      mimeType: 'image/png',
      storageType: AttachmentStorageType.desktopFile,
      storageKey: r'C:\attachments\image-1',
      fileName: 'pixel.png',
      byteSize: 3,
      createdAt: 42,
    );

    expect(AttachmentMetadata.fromJson(metadata.toJson()).toJson(), {
      'id': 'image-1',
      'mimeType': 'image/png',
      'storageType': 'desktop-file',
      'storageKey': r'C:\attachments\image-1',
      'fileName': 'pixel.png',
      'byteSize': 3,
      'createdAt': 42,
    });
  });

  test('file store persists, encodes, deletes, and garbage collects', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'tinyrack-attachments-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final store = FileAttachmentStore(
      rootDirectory: () async => temporary,
      clock: () => DateTime.fromMillisecondsSinceEpoch(42),
    );
    final keep = await store.save(
      id: 'keep',
      mimeType: 'image/png',
      fileName: 'pixel.png',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    final discard = await store.save(
      id: 'discard',
      mimeType: 'image/jpeg',
      bytes: Uint8List.fromList([4]),
    );
    final generated = await store.save(
      mimeType: 'image/png',
      bytes: Uint8List.fromList([5]),
    );

    expect(keep.createdAt, 42);
    expect(keep.byteSize, 3);
    expect(await store.readBytes(keep), [1, 2, 3]);
    expect(await store.encodeBase64(keep), base64Encode([1, 2, 3]));
    expect(
      () => store.save(
        id: '../escape',
        mimeType: 'image/png',
        bytes: Uint8List(0),
      ),
      throwsArgumentError,
    );
    expect(generated.id, isNotEmpty);
    expect(
      () => store.readBytes(
        AttachmentMetadata(
          id: keep.id,
          mimeType: keep.mimeType,
          storageType: AttachmentStorageType.nativeFile,
          storageKey: keep.storageKey,
          createdAt: keep.createdAt,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => store.readBytes(
        AttachmentMetadata(
          id: keep.id,
          mimeType: keep.mimeType,
          storageType: keep.storageType,
          storageKey: '${keep.storageKey}-wrong',
          createdAt: keep.createdAt,
        ),
      ),
      throwsArgumentError,
    );

    await store.garbageCollect({'keep'});
    expect(await File(keep.storageKey).exists(), isTrue);
    expect(await File(discard.storageKey).exists(), isFalse);
    await store.delete(keep);
    expect(await File(keep.storageKey).exists(), isFalse);
  });

  test('preferences store preserves the web attachment contract', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = PreferencesAttachmentStore(
      preferences: () async => preferences,
      clock: () => DateTime.fromMillisecondsSinceEpoch(84),
    );
    final keep = await store.save(
      id: 'keep',
      mimeType: 'image/png',
      fileName: 'pixel.png',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    final discard = await store.save(
      id: 'discard',
      mimeType: 'image/png',
      bytes: Uint8List.fromList([4]),
    );
    final generated = await store.save(
      mimeType: 'image/png',
      bytes: Uint8List.fromList([5]),
    );

    expect(keep.storageType, AttachmentStorageType.webIndexedDb);
    expect(generated.id, isNotEmpty);
    expect(keep.createdAt, 84);
    expect(await store.readBytes(keep), [1, 2, 3]);
    await store.garbageCollect({'keep'});
    expect(await store.encodeBase64(keep), base64Encode([1, 2, 3]));
    expect(() => store.encodeBase64(discard), throwsA(isA<StateError>()));
    await store.delete(keep);
    expect(() => store.readBytes(keep), throwsA(isA<StateError>()));
    expect(
      () => store.readBytes(
        AttachmentMetadata(
          id: 'wrong',
          mimeType: 'image/png',
          storageType: AttachmentStorageType.desktopFile,
          storageKey: 'wrong',
          createdAt: 0,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => store.save(
        id: '../escape',
        mimeType: 'image/png',
        bytes: Uint8List(0),
      ),
      throwsArgumentError,
    );
  });

  test(
    'memory store generates ids and garbage collects unreferenced bytes',
    () async {
      final store = MemoryAttachmentStore();
      final keep = await store.save(
        mimeType: 'image/png',
        bytes: Uint8List.fromList([1]),
      );
      final discard = await store.save(
        mimeType: 'image/png',
        bytes: Uint8List.fromList([2]),
      );

      await store.garbageCollect({keep.id});

      expect(await store.readBytes(keep), [1]);
      expect(() => store.readBytes(discard), throwsA(isA<StateError>()));
    },
  );
}
