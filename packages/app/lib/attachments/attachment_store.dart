import 'dart:typed_data';

import 'attachment_store_factory_stub.dart'
    if (dart.library.io) 'attachment_store_factory_io.dart'
    if (dart.library.html) 'attachment_store_factory_web.dart'
    as platform;

enum AttachmentStorageType {
  webIndexedDb('web-indexeddb'),
  desktopFile('desktop-file'),
  nativeFile('native-file');

  const AttachmentStorageType(this.wireName);

  final String wireName;
}

final class AttachmentMetadata {
  const AttachmentMetadata({
    required this.id,
    required this.mimeType,
    required this.storageType,
    required this.storageKey,
    required this.createdAt,
    this.fileName,
    this.byteSize,
  });

  final String id;
  final String mimeType;
  final AttachmentStorageType storageType;
  final String storageKey;
  final String? fileName;
  final int? byteSize;
  final int createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'mimeType': mimeType,
    'storageType': storageType.wireName,
    'storageKey': storageKey,
    'fileName': fileName,
    'byteSize': byteSize,
    'createdAt': createdAt,
  };

  factory AttachmentMetadata.fromJson(Map<String, Object?> json) {
    final storageTypeName = json['storageType'] as String;
    return AttachmentMetadata(
      id: json['id'] as String,
      mimeType: json['mimeType'] as String,
      storageType: AttachmentStorageType.values.singleWhere(
        (value) => value.wireName == storageTypeName,
      ),
      storageKey: json['storageKey'] as String,
      fileName: json['fileName'] as String?,
      byteSize: json['byteSize'] as int?,
      createdAt: json['createdAt'] as int,
    );
  }
}

abstract interface class AttachmentStore {
  AttachmentStorageType get storageType;

  Future<AttachmentMetadata> save({
    String? id,
    required String mimeType,
    String? fileName,
    required Uint8List bytes,
  });

  Future<String> encodeBase64(AttachmentMetadata attachment);

  Future<Uint8List> readBytes(AttachmentMetadata attachment);

  Future<void> delete(AttachmentMetadata attachment);

  Future<void> garbageCollect(Set<String> referencedIds);
}

Future<AttachmentStore> createDefaultAttachmentStore() =>
    platform.createPlatformAttachmentStore();
