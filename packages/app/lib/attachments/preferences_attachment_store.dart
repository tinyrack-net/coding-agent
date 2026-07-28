import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'attachment_store.dart';

final class PreferencesAttachmentStore implements AttachmentStore {
  PreferencesAttachmentStore({
    Future<SharedPreferences> Function()? preferences,
    this.uuid = const Uuid(),
    DateTime Function()? clock,
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _clock = clock ?? DateTime.now;

  static const _keyPrefix = 'tinyrack.attachments.';

  final Future<SharedPreferences> Function() _preferences;
  final Uuid uuid;
  final DateTime Function() _clock;

  @override
  AttachmentStorageType get storageType => AttachmentStorageType.webIndexedDb;

  @override
  Future<AttachmentMetadata> save({
    String? id,
    required String mimeType,
    String? fileName,
    required Uint8List bytes,
  }) async {
    final attachmentId = id ?? uuid.v4();
    _validateId(attachmentId);
    final key = '$_keyPrefix$attachmentId';
    final preferences = await _preferences();
    if (!await preferences.setString(key, base64Encode(bytes))) {
      throw StateError('Failed to persist attachment $attachmentId.');
    }
    return AttachmentMetadata(
      id: attachmentId,
      mimeType: mimeType,
      storageType: storageType,
      storageKey: key,
      fileName: fileName,
      byteSize: bytes.length,
      createdAt: _clock().millisecondsSinceEpoch,
    );
  }

  @override
  Future<String> encodeBase64(AttachmentMetadata attachment) async {
    _requireOwnedMetadata(attachment);
    final value = (await _preferences()).getString(attachment.storageKey);
    if (value == null) {
      throw StateError('Attachment ${attachment.id} is missing.');
    }
    return value;
  }

  @override
  Future<Uint8List> readBytes(AttachmentMetadata attachment) async =>
      base64Decode(await encodeBase64(attachment));

  @override
  Future<void> delete(AttachmentMetadata attachment) async {
    _requireOwnedMetadata(attachment);
    await (await _preferences()).remove(attachment.storageKey);
  }

  @override
  Future<void> garbageCollect(Set<String> referencedIds) async {
    final preferences = await _preferences();
    for (final key in preferences.getKeys()) {
      if (!key.startsWith(_keyPrefix)) continue;
      final id = key.substring(_keyPrefix.length);
      if (!referencedIds.contains(id)) await preferences.remove(key);
    }
  }

  void _requireOwnedMetadata(AttachmentMetadata attachment) {
    if (attachment.storageType != storageType ||
        attachment.storageKey != '$_keyPrefix${attachment.id}') {
      throw ArgumentError.value(attachment, 'attachment');
    }
  }

  static void _validateId(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'must be a safe storage key');
    }
  }
}
