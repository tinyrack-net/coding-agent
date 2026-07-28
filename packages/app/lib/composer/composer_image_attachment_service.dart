import 'dart:typed_data';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:uuid/uuid.dart';

import '../attachments/attachment_store.dart';
import 'composer_clipboard_reader.dart';
import 'composer_image_attachments.dart';

typedef ComposerImagePicker = Future<List<XFile>> Function();

const composerImageTypeGroup = XTypeGroup(
  label: 'Images',
  extensions: [
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
    'avif',
    'tif',
    'tiff',
  ],
  mimeTypes: [
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'image/bmp',
    'image/heic',
    'image/heif',
    'image/avif',
    'image/tiff',
  ],
  uniformTypeIdentifiers: ['public.image'],
  webWildCards: ['image/*'],
);

Future<List<XFile>> _pickImages() =>
    openFiles(acceptedTypeGroups: const [composerImageTypeGroup]);

final class ComposerImageAttachmentService {
  ComposerImageAttachmentService({
    Future<AttachmentStore> Function()? store,
    ComposerImagePicker? picker,
    this.uuid = const Uuid(),
  }) : _store = (store ?? createDefaultAttachmentStore)(),
       _picker = picker ?? _pickImages;

  final Future<AttachmentStore> _store;
  final ComposerImagePicker _picker;
  final Uuid uuid;

  Future<List<PendingComposerImage>> pick() async {
    final files = await _picker();
    return _persistFiles(
      files.map(
        (file) => _ImageInput(
          fileName: file.name,
          path: file.path,
          mimeType: file.mimeType,
          readBytes: file.readAsBytes,
        ),
      ),
    );
  }

  /// Returns `null` when the clipboard contains no image. An empty list means
  /// an image was present but could not be persisted, matching Paseo's
  /// per-file failure isolation without falling through to text paste.
  Future<List<PendingComposerImage>?> paste(
    ComposerClipboardReader clipboard,
  ) async {
    final bytes = await clipboard.readPngImage();
    if (bytes == null) return null;
    return _persistFiles([
      _ImageInput(
        fileName: 'pasted-image.png',
        path: 'pasted-image.png',
        mimeType: 'image/png',
        readBytes: () async => bytes,
      ),
    ]);
  }

  Future<List<PendingComposerImage>> persistDropped(Iterable<DropItem> items) {
    return _persistFiles(
      items
          .where((item) => item is! DropItemDirectory)
          .map(
            (item) => _ImageInput(
              fileName: composerImageFileName(item.name),
              path: item.path,
              mimeType: item.mimeType,
              readBytes: item.readAsBytes,
            ),
          ),
    );
  }

  Future<List<AgentPromptImage>> encodeForSend(
    Iterable<PendingComposerImage> images,
  ) async {
    final store = await _store;
    final encoded = <AgentPromptImage>[];
    for (final image in images) {
      try {
        final metadata = image.metadata;
        encoded.add(
          metadata == null
              ? image.toPromptImage()
              : AgentPromptImage(
                  data: await store.encodeBase64(metadata),
                  mimeType: metadata.mimeType,
                ),
        );
      } catch (_) {
        // Paseo isolates failed encodes so the remaining attachments still send.
      }
    }
    return encoded;
  }

  Future<List<AgentPromptImage>> encodeMetadataForSend(
    Iterable<AttachmentMetadata> attachments,
  ) async {
    final store = await _store;
    final encoded = <AgentPromptImage>[];
    for (final attachment in attachments) {
      try {
        encoded.add(
          AgentPromptImage(
            data: await store.encodeBase64(attachment),
            mimeType: attachment.mimeType,
          ),
        );
      } catch (_) {
        // Browser-element screenshots use the same per-attachment isolation
        // as regular composer images.
      }
    }
    return encoded;
  }

  Future<List<PendingComposerImage>> restore(
    Iterable<AttachmentMetadata> attachments,
  ) async {
    final store = await _store;
    final restored = <PendingComposerImage>[];
    for (final metadata in attachments) {
      try {
        restored.add(
          PendingComposerImage(
            id: metadata.id,
            fileName: metadata.fileName ?? metadata.id,
            mimeType: metadata.mimeType,
            bytes: await store.readBytes(metadata),
            metadata: metadata,
          ),
        );
      } catch (_) {
        // One missing or corrupt attachment must not discard the rest of a
        // hydrated draft.
      }
    }
    return restored;
  }

  Future<void> delete(PendingComposerImage image) async {
    final metadata = image.metadata;
    if (metadata == null) return;
    await (await _store).delete(metadata);
  }

  Future<void> deleteAll(Iterable<PendingComposerImage> images) async {
    for (final image in images) {
      try {
        await delete(image);
      } catch (_) {
        // Cleanup must not turn a successful prompt into a failed prompt.
      }
    }
  }

  Future<void> garbageCollectReferenced(Set<String> referencedIds) async {
    await (await _store).garbageCollect(referencedIds);
  }

  Future<List<PendingComposerImage>> _persistFiles(
    Iterable<_ImageInput> inputs,
  ) async {
    final store = await _store;
    final result = <PendingComposerImage>[];
    for (final input in inputs) {
      final mimeType = resolveRasterImageMimeType(
        mimeType: input.mimeType,
        path: input.fileName.isEmpty ? input.path : input.fileName,
      );
      if (mimeType == null) continue;
      try {
        final bytes = await input.readBytes();
        final id = uuid.v4();
        final metadata = await store.save(
          id: id,
          mimeType: mimeType,
          fileName: input.fileName,
          bytes: bytes,
        );
        result.add(
          PendingComposerImage(
            id: id,
            fileName: input.fileName,
            mimeType: mimeType,
            bytes: bytes,
            metadata: metadata,
          ),
        );
      } catch (_) {
        // One unreadable or unpersistable image does not reject the selection.
      }
    }
    return result;
  }
}

final class _ImageInput {
  const _ImageInput({
    required this.fileName,
    required this.path,
    required this.mimeType,
    required this.readBytes,
  });

  final String fileName;
  final String path;
  final String? mimeType;
  final Future<Uint8List> Function() readBytes;
}
