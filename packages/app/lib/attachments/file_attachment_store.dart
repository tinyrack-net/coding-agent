import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'attachment_store.dart';

typedef AttachmentRootDirectory = Future<Directory> Function();

final class FileAttachmentStore implements AttachmentStore {
  FileAttachmentStore({
    AttachmentRootDirectory? rootDirectory,
    this.uuid = const Uuid(),
    DateTime Function()? clock,
    this.storageType = AttachmentStorageType.desktopFile,
  }) : _rootDirectory =
           rootDirectory ??
           (() async {
             final support = await getApplicationSupportDirectory();
             return Directory(
               '${support.path}${Platform.pathSeparator}attachments',
             );
           }),
       _clock = clock ?? DateTime.now;

  final AttachmentRootDirectory _rootDirectory;
  final Uuid uuid;
  final DateTime Function() _clock;

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
    _validateId(attachmentId);
    final root = await _ensureRoot();
    final file = File('${root.path}${Platform.pathSeparator}$attachmentId');
    await file.writeAsBytes(bytes, flush: true);
    return AttachmentMetadata(
      id: attachmentId,
      mimeType: mimeType,
      storageType: storageType,
      storageKey: file.path,
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
    _requireOwnedMetadata(attachment);
    return File(attachment.storageKey).readAsBytes();
  }

  @override
  Future<void> delete(AttachmentMetadata attachment) async {
    _requireOwnedMetadata(attachment);
    final file = File(attachment.storageKey);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> garbageCollect(Set<String> referencedIds) async {
    final root = await _ensureRoot();
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File) continue;
      final id = entity.uri.pathSegments.last;
      if (!referencedIds.contains(id)) await entity.delete();
    }
  }

  Future<Directory> _ensureRoot() async {
    final root = await _rootDirectory();
    await root.create(recursive: true);
    return root;
  }

  void _requireOwnedMetadata(AttachmentMetadata attachment) {
    if (attachment.storageType != storageType) {
      throw ArgumentError.value(
        attachment.storageType,
        'attachment.storageType',
        'does not belong to this store',
      );
    }
    _validateId(attachment.id);
    final fileName = File(attachment.storageKey).uri.pathSegments.last;
    if (fileName != attachment.id) {
      throw ArgumentError.value(
        attachment.storageKey,
        'attachment.storageKey',
        'does not match attachment id',
      );
    }
  }

  static void _validateId(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'must be a safe storage key');
    }
  }
}
