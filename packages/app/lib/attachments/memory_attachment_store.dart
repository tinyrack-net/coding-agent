import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'attachment_store.dart';

final class MemoryAttachmentStore implements AttachmentStore {
  MemoryAttachmentStore({
    this.uuid = const Uuid(),
    DateTime Function()? clock,
    this.storageType = AttachmentStorageType.desktopFile,
  }) : _clock = clock ?? DateTime.now;

  final Uuid uuid;
  final DateTime Function() _clock;
  final Map<String, Uint8List> _bytes = {};

  @override
  final AttachmentStorageType storageType;

  @override
  Future<AttachmentMetadata> save({
    String? id,
    required String mimeType,
    String? fileName,
    required Uint8List bytes,
  }) async {
    final attachmentId = id ?? uuid.v4();
    _bytes[attachmentId] = Uint8List.fromList(bytes);
    return AttachmentMetadata(
      id: attachmentId,
      mimeType: mimeType,
      storageType: storageType,
      storageKey: attachmentId,
      fileName: fileName,
      byteSize: bytes.length,
      createdAt: _clock().millisecondsSinceEpoch,
    );
  }

  @override
  Future<String> encodeBase64(AttachmentMetadata attachment) async =>
      base64Encode(await readBytes(attachment));

  @override
  Future<Uint8List> readBytes(AttachmentMetadata attachment) async {
    final bytes = _bytes[attachment.storageKey];
    if (bytes == null) {
      throw StateError('Attachment ${attachment.id} is missing.');
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(AttachmentMetadata attachment) async {
    _bytes.remove(attachment.storageKey);
  }

  @override
  Future<void> garbageCollect(Set<String> referencedIds) async {
    _bytes.removeWhere((id, _) => !referencedIds.contains(id));
  }
}
