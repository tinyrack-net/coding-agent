import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:uuid/uuid.dart';

import '../attachments/attachment_store.dart';

const rasterImageMimeTypeByExtension = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.bmp': 'image/bmp',
  '.heic': 'image/heic',
  '.heif': 'image/heif',
  '.avif': 'image/avif',
  '.tif': 'image/tiff',
  '.tiff': 'image/tiff',
};

final class PendingComposerImage {
  const PendingComposerImage({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.bytes,
    this.metadata,
  });

  final String id;
  final String fileName;
  final String mimeType;
  final Uint8List bytes;
  final AttachmentMetadata? metadata;

  AgentPromptImage toPromptImage() =>
      AgentPromptImage(data: base64Encode(bytes), mimeType: mimeType);
}

String? resolveRasterImageMimeType({String? mimeType, String? path}) {
  final supplied = mimeType?.split(';').first.trim().toLowerCase();
  if (supplied != null && supplied.isNotEmpty) {
    final normalized = supplied == 'image/jpg' ? 'image/jpeg' : supplied;
    return rasterImageMimeTypeByExtension.containsValue(normalized)
        ? normalized
        : null;
  }
  if (path == null) return null;
  final normalized = path.split('#').first.split('?').first.toLowerCase();
  for (final entry in rasterImageMimeTypeByExtension.entries) {
    if (normalized.endsWith(entry.key)) return entry.value;
  }
  return null;
}

Future<List<PendingComposerImage>> droppedItemsToComposerImages(
  Iterable<DropItem> items, {
  Uuid uuid = const Uuid(),
}) async {
  final images = <PendingComposerImage>[];
  for (final item in items) {
    if (item is DropItemDirectory) continue;
    final mimeType = resolveRasterImageMimeType(
      mimeType: item.mimeType,
      path: item.name.isEmpty ? item.path : item.name,
    );
    if (mimeType == null) continue;
    try {
      images.add(
        PendingComposerImage(
          id: uuid.v4(),
          fileName: composerImageFileName(item.name),
          mimeType: mimeType,
          bytes: await item.readAsBytes(),
        ),
      );
    } catch (_) {
      // Match Paseo's per-file isolation: one unreadable image does not reject
      // the remaining dropped images.
    }
  }
  return images;
}

String composerImageFileName(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  return parts.lastWhere((part) => part.isNotEmpty, orElse: () => path);
}
