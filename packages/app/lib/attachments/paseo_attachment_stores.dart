/// Ports of Paseo 0.2.0's three attachment *byte* stores and the desktop
/// preview-URL resolver they lean on:
///
/// - `attachments/local-file-attachment-store.ts` — writes bytes into a managed
///   cache directory on desktop/native, addressing them by absolute path.
/// - `attachments/web/indexeddb-attachment-store.ts` — parks bytes in a browser
///   object store, addressing them by record key.
/// - `desktop/attachments/desktop-attachment-store.ts` — hands bytes to the
///   desktop host over IPC and remembers the path the host chose.
/// - `desktop/attachments/desktop-preview-url.ts` — turns a stored desktop file
///   into something an `<img>` can point at, and takes it back afterwards.
///
/// Attachment *metadata* is persisted in drafts and messages; only the bytes
/// live here. That split is why every backend returns the same
/// [AttachmentMetadata] shape no matter where the bytes actually landed — a
/// draft written on desktop and re-read on web still describes an attachment,
/// even if this device cannot resolve its bytes.
///
/// Every backend takes its platform primitive as an injected dependency (a
/// filesystem, an object-store connection factory, a desktop IPC bridge), so
/// none of this file imports `dart:io`, `dart:html`, or a plugin, and all three
/// backends are exercised in tests against fakes.
///
/// Reuse notes: [AttachmentMetadata] and [AttachmentStorageType] come from
/// `attachments/attachment_store.dart` and are re-exported rather than
/// redeclared. All the string plumbing — [generateAttachmentId],
/// [normalizeMimeType], [parseDataUrl], [pathToFileUri], [fileUriToPath],
/// [getFileExtensionFromName] and [attachmentBytesToBase64] (upstream's
/// `blobToBase64`) — comes from `attachments/paseo_attachment_rules.dart`.
/// The pre-existing `AttachmentStore` in `attachment_store.dart` is a narrower,
/// bytes-only contract used by the app's own preferences/file/memory stores; it
/// has no notion of save-sources or preview URLs, so [PaseoAttachmentStore] is
/// declared here as the faithful port of upstream's richer interface instead of
/// widening the existing one.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'attachment_store.dart' show AttachmentMetadata, AttachmentStorageType;
import 'paseo_attachment_rules.dart';

export 'attachment_store.dart' show AttachmentMetadata, AttachmentStorageType;

// ---------------------------------------------------------------------------
// Shared contract
// ---------------------------------------------------------------------------

/// An in-memory payload plus the media type the producer claimed for it.
///
/// Deviation: upstream passes web `Blob` values around. Dart has no `Blob`, and
/// the only two things any store reads off one are its bytes and its `type`, so
/// this carries exactly those. `Blob.slice(0, size, type)` — upstream's idiom
/// for re-labelling a blob without copying — becomes [withType].
final class AttachmentBlob {
  const AttachmentBlob({required this.bytes, required this.type});

  final Uint8List bytes;

  /// The claimed media type. A browser reports "unknown" as `''`, not as a
  /// missing value, which is why this is non-nullable and empty-by-default at
  /// every call site that builds one from an untyped payload.
  final String type;

  /// Upstream's `Blob.size`.
  int get size => bytes.length;

  /// The same bytes under a different media type.
  AttachmentBlob withType(String type) =>
      type == this.type ? this : AttachmentBlob(bytes: bytes, type: type);

  @override
  bool operator ==(Object other) =>
      other is AttachmentBlob &&
      other.type == type &&
      _bytesEqual(other.bytes, bytes);

  @override
  int get hashCode => Object.hash(type, Object.hashAll(bytes));

  @override
  String toString() => 'AttachmentBlob(type: $type, size: $size)';
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

/// Where the bytes of an attachment being saved are coming from.
///
/// The four variants exist because each platform can shortcut a different one:
/// desktop copies a [FileUriAttachmentSource] without ever loading the file,
/// web keeps a [BlobAttachmentSource] as-is, and only the remaining cases pay
/// for an encode/decode round trip.
sealed class AttachmentDataSource {
  const AttachmentDataSource();
}

/// Bytes already in memory — a screenshot crop, a decoded paste.
final class BytesAttachmentSource extends AttachmentDataSource {
  const BytesAttachmentSource(this.bytes);

  final Uint8List bytes;

  @override
  bool operator ==(Object other) =>
      other is BytesAttachmentSource && _bytesEqual(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'BytesAttachmentSource(${bytes.length} bytes)';
}

/// A payload that already carries its own media type.
final class BlobAttachmentSource extends AttachmentDataSource {
  const BlobAttachmentSource(this.blob);

  final AttachmentBlob blob;

  @override
  bool operator ==(Object other) =>
      other is BlobAttachmentSource && other.blob == blob;

  @override
  int get hashCode => blob.hashCode;

  @override
  String toString() => 'BlobAttachmentSource($blob)';
}

/// A base64 `data:` URL, the shape clipboard and canvas exports arrive in.
final class DataUrlAttachmentSource extends AttachmentDataSource {
  const DataUrlAttachmentSource(this.dataUrl);

  final String dataUrl;

  @override
  bool operator ==(Object other) =>
      other is DataUrlAttachmentSource && other.dataUrl == dataUrl;

  @override
  int get hashCode => dataUrl.hashCode;

  @override
  String toString() => 'DataUrlAttachmentSource(${dataUrl.length} chars)';
}

/// A file the OS handed us by reference. Bytes are read by the backend, or not
/// at all when the backend can copy the file directly.
final class FileUriAttachmentSource extends AttachmentDataSource {
  const FileUriAttachmentSource(this.uri);

  final String uri;

  @override
  bool operator ==(Object other) =>
      other is FileUriAttachmentSource && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;

  @override
  String toString() => 'FileUriAttachmentSource($uri)';
}

/// Everything a caller knows about an attachment before it has been stored.
///
/// [id] and [mimeType] are optional because the common caller — a drop or a
/// paste — knows neither; the store mints an id and infers a type from the
/// source. Callers that *do* know (a preview whose id must stay stable across
/// re-renders) pass them so the store does not invent a second identity.
final class SaveAttachmentInput {
  const SaveAttachmentInput({
    required this.source,
    this.id,
    this.mimeType,
    this.fileName,
  });

  final AttachmentDataSource source;
  final String? id;
  final String? mimeType;
  final String? fileName;
}

/// Async storage contract for attachment bytes, one implementation per
/// platform.
///
/// Deviation: upstream marks `releasePreviewUrl` optional and callers probe it
/// with `store.releasePreviewUrl?.(...)`. A Dart interface cannot omit a
/// method, so [releasePreviewUrl] is always callable and does nothing when the
/// backend mints URLs that need no cleanup; [supportsPreviewUrlRelease] carries
/// the presence bit for callers that used to branch on it. Every caller
/// observes the same outcome either way.
abstract interface class PaseoAttachmentStore {
  /// Which backend this is, mirrored onto every [AttachmentMetadata] it writes
  /// so a later read knows whether *this* device can resolve the bytes.
  AttachmentStorageType get storageType;

  /// Persists [input]'s bytes and returns the metadata that addresses them.
  Future<AttachmentMetadata> save(SaveAttachmentInput input);

  /// The stored bytes, base64-encoded for the wire.
  Future<String> encodeBase64(AttachmentMetadata attachment);

  /// A URL the UI can render the attachment from.
  Future<String> resolvePreviewUrl(AttachmentMetadata attachment);

  /// Whether [releasePreviewUrl] does anything on this backend.
  bool get supportsPreviewUrlRelease;

  /// Hands a URL from [resolvePreviewUrl] back, so a host that pinned bytes
  /// behind it can drop them.
  Future<void> releasePreviewUrl({
    required AttachmentMetadata attachment,
    required String url,
  });

  /// Forgets one attachment's bytes. Deleting bytes that are already gone is
  /// not an error on any backend — GC and explicit removal race routinely.
  Future<void> delete(AttachmentMetadata attachment);

  /// Drops every stored attachment whose id is absent from [referencedIds].
  ///
  /// Drafts are the only thing that keeps an attachment alive, so this is what
  /// stops an abandoned paste from occupying disk forever.
  Future<void> garbageCollect(Set<String> referencedIds);
}

/// Produces a preview URL for an attachment whose bytes this store owns.
typedef ResolveAttachmentPreviewUrl =
    Future<String> Function(AttachmentMetadata attachment);

/// Releases a URL previously produced by a [ResolveAttachmentPreviewUrl].
typedef ReleaseAttachmentPreviewUrl =
    Future<void> Function({
      required AttachmentMetadata attachment,
      required String url,
    });

/// Mints and revokes host-owned URLs that point at in-memory bytes.
///
/// Deviation: upstream's `ObjectUrlMinter.tryCreate` takes `{mimeType, base64}`
/// and decodes internally. This takes the decoded bytes, because the IndexedDB
/// backend already holds bytes and would otherwise encode them only for the
/// minter to decode them again. The null return is upstream's, and means the
/// host has no `URL.createObjectURL` — a data URL fallback is the caller's job.
abstract interface class AttachmentObjectUrlMinter {
  /// A host URL for [bytes], or `null` when this runtime cannot mint one.
  String? tryCreate({required String mimeType, required Uint8List bytes});

  /// Releases a URL from [tryCreate]. Revoking an unknown URL is a no-op, as it
  /// is in the browser.
  void revoke(String url);
}

/// The mime-type -> file-extension table both file-backed stores use to name
/// the file they are about to write.
///
/// Deliberately *not* derived from `rasterImageMimeTypeByExtension`: this table
/// maps the other direction, includes `image/svg+xml` (which is a file, not a
/// raster image, but still deserves a truthful `.svg` on disk), spells TIFF
/// `.tiff` rather than `.tif`, and accepts the non-standard `image/jpg`.
const Map<String, String> attachmentExtensionByImageMimeType = {
  'image/png': '.png',
  'image/jpeg': '.jpg',
  'image/jpg': '.jpg',
  'image/gif': '.gif',
  'image/webp': '.webp',
  'image/avif': '.avif',
  'image/heic': '.heic',
  'image/heif': '.heif',
  'image/tiff': '.tiff',
  'image/bmp': '.bmp',
  'image/svg+xml': '.svg',
};

/// The extension to give a stored attachment file, including the leading dot.
///
/// The user's own file name wins, then the source path it was copied from, then
/// the mime table. `.img` is the last resort: a wrong-but-present extension
/// keeps the managed directory greppable and keeps the OS from treating the
/// file as an executable-of-unknown-kind.
///
/// [sourcePath] is only consulted by the desktop backend — the local-file
/// backend passes `null`, matching upstream, where the two copies of this
/// helper differ in exactly that one lookup.
String attachmentFileExtension({
  required String mimeType,
  String? fileName,
  String? sourcePath,
}) {
  final fromName = getFileExtensionFromName(fileName);
  if (fromName.isNotEmpty) return fromName;

  final fromSourcePath = getFileExtensionFromName(sourcePath);
  if (fromSourcePath.isNotEmpty) return fromSourcePath;

  return attachmentExtensionByImageMimeType[mimeType] ?? '.img';
}

/// Decodes a base64 payload the way a browser's `atob`/`fetch(dataUrl)` would.
///
/// Deviation: Dart's [base64Decode] rejects unpadded input where JavaScript
/// accepts it, so the padding is restored first. Everything else about the
/// decode is identical.
Uint8List decodeAttachmentBase64(String value) {
  final remainder = value.length % 4;
  final padded = remainder == 0
      ? value
      : value.padRight(value.length + (4 - remainder), '=');
  return base64Decode(padded);
}

// ---------------------------------------------------------------------------
// local-file-attachment-store.ts
// ---------------------------------------------------------------------------

/// What a filesystem reports about one path.
sealed class AttachmentFileInfo {
  const AttachmentFileInfo();
}

/// The path exists. [size] is `null` for directories and for hosts that do not
/// report a size, which is why the local store can produce metadata with a null
/// `byteSize` even for a file it just wrote.
final class AttachmentFileFound extends AttachmentFileInfo {
  const AttachmentFileFound({required this.isDirectory, this.size});

  final bool isDirectory;
  final int? size;
}

/// The path does not exist.
final class AttachmentFileMissing extends AttachmentFileInfo {
  const AttachmentFileMissing();
}

/// The slice of filesystem the local-file store needs.
///
/// Kept this narrow on purpose: it is the whole surface a platform has to
/// implement to gain attachment storage, and the whole surface a test has to
/// fake. Every path is a URI (`file:///...`), not an OS path, because that is
/// the form the underlying expo/desktop APIs upstream take.
abstract interface class AttachmentFileSystem {
  /// The host's cache root, or `null` when this runtime has no writable cache.
  /// A store built on a null cache directory refuses to save rather than
  /// silently writing somewhere unmanaged.
  String? get cacheDirectory;

  Future<AttachmentFileInfo> getInfo(String uri);

  Future<void> makeDirectory(String uri, {required bool intermediates});

  Future<void> writeBytes(String uri, Uint8List bytes);

  Future<void> copy({required String from, required String to});

  Future<String> readAsBase64(String uri);

  Future<void> delete(String uri, {required bool idempotent});

  /// The entry *names* directly under [uri], not full paths.
  Future<List<String>> listDirectory(String uri);
}

/// Stores attachment bytes as real files under a managed cache subdirectory.
///
/// Used by both the desktop and the native builds, which differ only in the
/// [AttachmentStorageType] they stamp on the metadata and in how they turn a
/// stored file into a preview URL — hence both being injected.
final class LocalFileAttachmentStore implements PaseoAttachmentStore {
  /// Throws an [ArgumentError] for [AttachmentStorageType.webIndexedDb].
  ///
  /// Deviation: upstream constrains the parameter to `"desktop-file" |
  /// "native-file"` in the type system, which Dart's enum cannot express at a
  /// call site, so the same constraint is enforced at construction.
  LocalFileAttachmentStore({
    required this.storageType,
    required String baseDirectoryName,
    required AttachmentFileSystem fileSystem,
    required this.resolvePreviewUrlWith,
    this.releasePreviewUrlWith,
    String Function()? generateId,
    DateTime Function()? clock,
  }) : _fileSystem = fileSystem,
       _generateId = generateId ?? generateAttachmentId,
       _clock = clock ?? DateTime.now,
       // Deviation: upstream tests `fileSystem.cacheDirectory` for truthiness,
       // so an empty-string cache directory disables the store exactly as a
       // null one does. Dart's `??` would keep `''` and write to a relative
       // path, so emptiness is checked explicitly.
       _baseDirectory =
           (fileSystem.cacheDirectory == null ||
               fileSystem.cacheDirectory!.isEmpty)
           ? null
           : '${fileSystem.cacheDirectory}$baseDirectoryName/' {
    if (storageType == AttachmentStorageType.webIndexedDb) {
      throw ArgumentError.value(
        storageType,
        'storageType',
        'must be desktop-file or native-file',
      );
    }
  }

  @override
  final AttachmentStorageType storageType;

  /// How a stored file becomes something the UI can render. Named `…With`
  /// rather than `resolvePreviewUrl` so it does not collide with the store
  /// method that forwards to it.
  final ResolveAttachmentPreviewUrl resolvePreviewUrlWith;

  /// `null` on backends whose preview URLs need no cleanup, which is what makes
  /// [supportsPreviewUrlRelease] false.
  final ReleaseAttachmentPreviewUrl? releasePreviewUrlWith;

  final AttachmentFileSystem _fileSystem;
  final String Function() _generateId;
  final DateTime Function() _clock;
  final String? _baseDirectory;

  @override
  bool get supportsPreviewUrlRelease => releasePreviewUrlWith != null;

  @override
  Future<AttachmentMetadata> save(SaveAttachmentInput input) async {
    final baseDirectory = _baseDirectory;
    if (baseDirectory == null) {
      throw StateError('Attachment file-system cacheDirectory is unavailable.');
    }

    await _ensureDirectory(baseDirectory);

    final id = input.id ?? _generateId();
    // Computed before the mime type is resolved, and unconditionally, so a
    // malformed data URL fails the save even when the caller supplied a
    // mimeType that would have made parsing unnecessary. Matches upstream's
    // statement order.
    final String? mimeTypeFromSource = switch (input.source) {
      DataUrlAttachmentSource(:final dataUrl) => parseDataUrl(dataUrl).mimeType,
      BlobAttachmentSource(:final blob) => blob.type,
      _ => null,
    };
    final mimeType = normalizeMimeType(input.mimeType ?? mimeTypeFromSource);
    final fileName = input.fileName;
    final extension = attachmentFileExtension(
      mimeType: mimeType,
      fileName: fileName,
    );
    final createdAt = _clock().millisecondsSinceEpoch;
    final targetUri = '$baseDirectory$id$extension';
    final storageKey = fileUriToPath(targetUri);

    await _writeFromSource(source: input.source, targetUri: targetUri);

    final info = await _fileSystem.getInfo(targetUri);
    return AttachmentMetadata(
      id: id,
      mimeType: mimeType,
      storageType: storageType,
      storageKey: storageKey,
      fileName: fileName,
      byteSize: info is AttachmentFileFound ? info.size : null,
      createdAt: createdAt,
    );
  }

  @override
  Future<String> encodeBase64(AttachmentMetadata attachment) =>
      _fileSystem.readAsBase64(_attachmentUri(attachment));

  @override
  Future<String> resolvePreviewUrl(AttachmentMetadata attachment) =>
      resolvePreviewUrlWith(attachment);

  @override
  Future<void> releasePreviewUrl({
    required AttachmentMetadata attachment,
    required String url,
  }) async {
    await releasePreviewUrlWith?.call(attachment: attachment, url: url);
  }

  @override
  Future<void> delete(AttachmentMetadata attachment) =>
      _fileSystem.delete(_attachmentUri(attachment), idempotent: true);

  @override
  Future<void> garbageCollect(Set<String> referencedIds) async {
    final baseDirectory = _baseDirectory;
    // A store that could never write also has nothing to collect, so this is a
    // silent no-op where `save` throws.
    if (baseDirectory == null) return;

    await _ensureDirectory(baseDirectory);
    final entries = await _fileSystem.listDirectory(baseDirectory);
    await Future.wait([
      for (final entryName in entries)
        _collectEntry(baseDirectory, entryName, referencedIds),
    ]);
  }

  Future<void> _collectEntry(
    String baseDirectory,
    String entryName,
    Set<String> referencedIds,
  ) async {
    // The id is everything before the *first* dot, so `att_1.tar.gz` collects
    // under `att_1` and a dotfile yields `''` and is left alone entirely.
    final id = entryName.split('.').first;
    if (id.isEmpty || referencedIds.contains(id)) return;
    await _fileSystem.delete('$baseDirectory$entryName', idempotent: true);
  }

  Future<void> _ensureDirectory(String uri) async {
    final info = await _fileSystem.getInfo(uri);
    if (info is AttachmentFileFound && info.isDirectory) return;
    await _fileSystem.makeDirectory(uri, intermediates: true);
  }

  Future<void> _writeFromSource({
    required AttachmentDataSource source,
    required String targetUri,
  }) async {
    if (source is FileUriAttachmentSource) {
      final from = pathToFileUri(source.uri);
      // Re-saving a file that already lives at the managed path (a preview
      // being re-attached) must not copy a file onto itself.
      if (from == targetUri) return;
      await _fileSystem.copy(from: from, to: targetUri);
      return;
    }

    final bytes = switch (source) {
      // Deviation: upstream decodes with `fetch(dataUrl)`, which also accepts
      // percent-encoded (non-base64) data URLs. `parseDataUrl` rejects those —
      // but `save` already parsed this same URL above and would have thrown
      // first, so the save path behaves identically.
      DataUrlAttachmentSource(:final dataUrl) => decodeAttachmentBase64(
        parseDataUrl(dataUrl).base64,
      ),
      BlobAttachmentSource(:final blob) => blob.bytes,
      BytesAttachmentSource(:final bytes) => bytes,
      FileUriAttachmentSource() => throw StateError('unreachable'),
    };

    await _fileSystem.writeBytes(targetUri, bytes);
  }

  /// Metadata stores an OS path; the filesystem takes URIs.
  String _attachmentUri(AttachmentMetadata attachment) =>
      pathToFileUri(attachment.storageKey);
}

// ---------------------------------------------------------------------------
// web/indexeddb-attachment-store.ts
// ---------------------------------------------------------------------------

/// One row of the browser object store.
final class StoredAttachmentBlob {
  const StoredAttachmentBlob({
    required this.id,
    required this.blob,
    required this.createdAt,
    required this.fileName,
  });

  final String id;
  final AttachmentBlob blob;
  final int createdAt;
  final String? fileName;

  @override
  bool operator ==(Object other) =>
      other is StoredAttachmentBlob &&
      other.id == id &&
      other.blob == blob &&
      other.createdAt == createdAt &&
      other.fileName == fileName;

  @override
  int get hashCode => Object.hash(id, blob, createdAt, fileName);

  @override
  String toString() =>
      'StoredAttachmentBlob(id: $id, blob: $blob, createdAt: $createdAt, '
      'fileName: $fileName)';
}

/// An open connection to the attachment object store.
///
/// Deviation: upstream wraps every operation in an IndexedDB transaction and
/// rejects on either the request's or the transaction's `error` event. Dart has
/// no equivalent event pair, so each method is a single future that completes
/// with the value or throws — the observable outcome of both rejection paths.
/// Upstream's `openCursor` walk is exposed as [keys] plus [delete]; both shapes
/// visit every stored key and remove exactly the unreferenced ones.
abstract interface class AttachmentBlobSession {
  Future<void> put(StoredAttachmentBlob record);

  /// The record for [id], or `null` when nothing is stored under it.
  Future<StoredAttachmentBlob?> get(String id);

  Future<void> delete(String id);

  /// Every key currently in the store.
  Future<List<String>> keys();

  Future<void> close();
}

/// Opens connections to the attachment object store.
///
/// Upstream opens and closes a connection around *every* operation rather than
/// holding one open, so a browser that needs to upgrade or delete the database
/// is never blocked by an idle app tab. That per-operation lifecycle is
/// preserved here, which is why this is a factory rather than a session.
abstract interface class AttachmentBlobDatabase {
  Future<AttachmentBlobSession> open();
}

/// Reads bytes for a URI the browser can fetch (`blob:`, `http:`, …).
typedef AttachmentUriFetcher = Future<AttachmentBlob> Function(String uri);

/// Stores attachment bytes in a browser object store, keyed by attachment id.
///
/// The web build has no filesystem to hand the agent a path to, so bytes are
/// re-encoded on every send. Preview URLs are host object URLs minted from the
/// stored payload and are the caller's to release.
final class IndexedDbAttachmentStore implements PaseoAttachmentStore {
  IndexedDbAttachmentStore({
    required this.database,
    required this.objectUrls,
    this.fetchUri,
    String Function()? generateId,
    DateTime Function()? clock,
  }) : _generateId = generateId ?? generateAttachmentId,
       _clock = clock ?? DateTime.now;

  final AttachmentBlobDatabase database;
  final AttachmentObjectUrlMinter objectUrls;

  /// `null` on hosts with no fetch equivalent, which makes
  /// [FileUriAttachmentSource] unsupported rather than silently empty.
  final AttachmentUriFetcher? fetchUri;

  final String Function() _generateId;
  final DateTime Function() _clock;

  @override
  AttachmentStorageType get storageType => AttachmentStorageType.webIndexedDb;

  /// Object URLs pin their bytes until revoked, so releasing is always
  /// meaningful here.
  @override
  bool get supportsPreviewUrlRelease => true;

  @override
  Future<AttachmentMetadata> save(SaveAttachmentInput input) async {
    final id = input.id ?? _generateId();
    // Stamped before the source is materialised, so a slow fetch does not push
    // the attachment's creation time past the message it belongs to.
    final createdAt = _clock().millisecondsSinceEpoch;
    final blob = await _sourceToBlob(input);
    final fileName = input.fileName;
    final session = await database.open();

    try {
      await session.put(
        StoredAttachmentBlob(
          id: id,
          blob: blob,
          createdAt: createdAt,
          fileName: fileName,
        ),
      );
    } finally {
      await session.close();
    }

    return AttachmentMetadata(
      id: id,
      mimeType: blob.type,
      storageType: AttachmentStorageType.webIndexedDb,
      // The record key *is* the attachment id on this backend — there is no
      // second namespace to translate through.
      storageKey: id,
      fileName: fileName,
      byteSize: blob.size,
      createdAt: createdAt,
    );
  }

  @override
  Future<String> encodeBase64(AttachmentMetadata attachment) async {
    final session = await database.open();
    try {
      final blob = await _loadBlob(session, attachment.storageKey);
      return await attachmentBytesToBase64(blob.bytes);
    } finally {
      await session.close();
    }
  }

  @override
  Future<String> resolvePreviewUrl(AttachmentMetadata attachment) async {
    final session = await database.open();
    try {
      final blob = await _loadBlob(session, attachment.storageKey);
      final url = objectUrls.tryCreate(mimeType: blob.type, bytes: blob.bytes);
      if (url == null) {
        // Deviation: upstream calls `URL.createObjectURL` unguarded, so a host
        // without it throws a TypeError. Throwing here keeps that failure loud
        // instead of returning a null-ish URL the UI would render as broken.
        throw StateError('Object URLs are unavailable in this runtime.');
      }
      return url;
    } finally {
      await session.close();
    }
  }

  /// Revokes unconditionally — unlike the desktop resolver, this backend keeps
  /// no ledger of what it minted, matching upstream's bare
  /// `URL.revokeObjectURL(url)`.
  @override
  Future<void> releasePreviewUrl({
    required AttachmentMetadata attachment,
    required String url,
  }) async {
    objectUrls.revoke(url);
  }

  @override
  Future<void> delete(AttachmentMetadata attachment) async {
    final session = await database.open();
    try {
      await session.delete(attachment.storageKey);
    } finally {
      await session.close();
    }
  }

  @override
  Future<void> garbageCollect(Set<String> referencedIds) async {
    final session = await database.open();
    try {
      for (final key in await session.keys()) {
        if (referencedIds.contains(key)) continue;
        await session.delete(key);
      }
    } finally {
      await session.close();
    }
  }

  Future<AttachmentBlob> _loadBlob(
    AttachmentBlobSession session,
    String id,
  ) async {
    final record = await session.get(id);
    if (record == null) {
      throw StateError('Attachment $id was not found in IndexedDB.');
    }
    return record.blob;
  }

  Future<AttachmentBlob> _sourceToBlob(SaveAttachmentInput input) async {
    final source = input.source;

    if (source is BytesAttachmentSource) {
      // Raw bytes carry no type of their own, so only the caller's claim (or
      // the JPEG fallback) can name them.
      return AttachmentBlob(
        bytes: source.bytes,
        type: normalizeMimeType(input.mimeType),
      );
    }

    if (source is BlobAttachmentSource) {
      return source.blob.withType(
        normalizeMimeType(input.mimeType ?? source.blob.type),
      );
    }

    if (source is DataUrlAttachmentSource) {
      final parsed = parseDataUrl(source.dataUrl);
      final blob = AttachmentBlob(
        bytes: decodeAttachmentBase64(parsed.base64),
        type: parsed.mimeType,
      );
      return blob.withType(
        normalizeMimeType(input.mimeType ?? parsed.mimeType),
      );
    }

    final fetchUri = this.fetchUri;
    if (fetchUri == null) {
      // Deviation: upstream reaches for the global `fetch`. There is no
      // platform-free analogue, so a store built without a fetcher rejects
      // file/blob URI sources rather than importing `dart:html` here.
      throw UnsupportedError(
        'This attachment store cannot read bytes from a URI source.',
      );
    }
    final blob = await fetchUri((source as FileUriAttachmentSource).uri);
    return blob.withType(normalizeMimeType(input.mimeType ?? blob.type));
  }
}

// ---------------------------------------------------------------------------
// desktop/attachments/desktop-attachment-store.ts
// ---------------------------------------------------------------------------

/// Where the desktop host put an attachment file, and how big it turned out.
final class DesktopAttachmentFileResult {
  const DesktopAttachmentFileResult({
    required this.path,
    required this.byteSize,
  });

  final String path;
  final int byteSize;

  @override
  bool operator ==(Object other) =>
      other is DesktopAttachmentFileResult &&
      other.path == path &&
      other.byteSize == byteSize;

  @override
  int get hashCode => Object.hash(path, byteSize);

  @override
  String toString() =>
      'DesktopAttachmentFileResult(path: $path, byteSize: $byteSize)';
}

/// The desktop host's side of attachment storage.
///
/// Every method is an IPC round trip in production. The renderer never picks
/// the destination path — the host does, and reports it back — so a compromised
/// renderer cannot write outside the managed directory.
abstract interface class DesktopAttachmentBridge {
  /// Copies an existing file into managed storage without loading its bytes.
  Future<DesktopAttachmentFileResult> copyFile({
    required String attachmentId,
    required String sourcePath,
    String? extension,
  });

  Future<DesktopAttachmentFileResult> writeBase64({
    required String attachmentId,
    required String base64,
    String? extension,
  });

  Future<DesktopAttachmentFileResult> writeBytes({
    required String attachmentId,
    required Uint8List bytes,
    String? extension,
  });

  /// Whether a file was actually removed.
  Future<bool> deleteFile(String path);

  /// How many files were removed.
  Future<int> garbageCollect(List<String> referencedIds);

  Future<String> readFileBase64(String path);

  Future<String> resolvePreviewUrl(AttachmentMetadata attachment);

  Future<void> releasePreviewUrl(String url);
}

/// Stores attachment bytes through the desktop host process.
final class DesktopAttachmentStore implements PaseoAttachmentStore {
  DesktopAttachmentStore(
    this._bridge, {
    String Function()? generateId,
    DateTime Function()? clock,
  }) : _generateId = generateId ?? generateAttachmentId,
       _clock = clock ?? DateTime.now;

  final DesktopAttachmentBridge _bridge;
  final String Function() _generateId;
  final DateTime Function() _clock;

  @override
  AttachmentStorageType get storageType => AttachmentStorageType.desktopFile;

  @override
  bool get supportsPreviewUrlRelease => true;

  @override
  Future<AttachmentMetadata> save(SaveAttachmentInput input) async {
    final id = input.id ?? _generateId();
    final fileName = input.fileName;
    final source = input.source;

    if (source is FileUriAttachmentSource) {
      final sourcePath = fileUriToPath(source.uri);
      // The only branch that recovers a name from the source: a dropped file
      // arrives with a real one on disk, and losing it would show the user a
      // pill labelled with an opaque id.
      final resolvedName = fileName ?? _inferFileNameFromPath(sourcePath);
      // Deliberately ignores the extension's implied type: the host is copying
      // opaque bytes, and the caller's claim (or the JPEG fallback) is what the
      // agent will be told.
      final mimeType = normalizeMimeType(input.mimeType);
      final result = await _bridge.copyFile(
        attachmentId: id,
        sourcePath: sourcePath,
        extension: attachmentFileExtension(
          mimeType: mimeType,
          fileName: resolvedName,
          sourcePath: sourcePath,
        ),
      );
      return _toDesktopMetadata(
        id: id,
        mimeType: mimeType,
        result: result,
        fileName: resolvedName,
      );
    }

    if (source is DataUrlAttachmentSource) {
      final parsed = parseDataUrl(source.dataUrl);
      return await _saveFromBase64(
        id: id,
        base64: parsed.base64,
        mimeType: normalizeMimeType(input.mimeType ?? parsed.mimeType),
        fileName: fileName,
      );
    }

    if (source is BytesAttachmentSource) {
      final mimeType = normalizeMimeType(input.mimeType);
      final result = await _bridge.writeBytes(
        attachmentId: id,
        bytes: source.bytes,
        extension: attachmentFileExtension(
          mimeType: mimeType,
          fileName: fileName,
        ),
      );
      return _toDesktopMetadata(
        id: id,
        mimeType: mimeType,
        result: result,
        fileName: fileName,
      );
    }

    final blob = (source as BlobAttachmentSource).blob;
    return await _saveFromBase64(
      id: id,
      base64: await attachmentBytesToBase64(blob.bytes),
      mimeType: normalizeMimeType(input.mimeType ?? blob.type),
      fileName: fileName,
    );
  }

  @override
  Future<String> encodeBase64(AttachmentMetadata attachment) async {
    _assertDesktopAttachment(attachment);
    return await _bridge.readFileBase64(attachment.storageKey);
  }

  @override
  Future<String> resolvePreviewUrl(AttachmentMetadata attachment) async {
    _assertDesktopAttachment(attachment);
    return await _bridge.resolvePreviewUrl(attachment);
  }

  @override
  Future<void> releasePreviewUrl({
    required AttachmentMetadata attachment,
    required String url,
  }) async {
    _assertDesktopAttachment(attachment);
    await _bridge.releasePreviewUrl(url);
  }

  @override
  Future<void> delete(AttachmentMetadata attachment) async {
    _assertDesktopAttachment(attachment);
    await _bridge.deleteFile(attachment.storageKey);
  }

  @override
  Future<void> garbageCollect(Set<String> referencedIds) async {
    // Unlike the per-attachment methods this takes no metadata, so there is
    // nothing to assert: the host decides what is collectable.
    await _bridge.garbageCollect(referencedIds.toList());
  }

  Future<AttachmentMetadata> _saveFromBase64({
    required String id,
    required String base64,
    required String mimeType,
    required String? fileName,
  }) async {
    final result = await _bridge.writeBase64(
      attachmentId: id,
      base64: base64,
      extension: attachmentFileExtension(
        mimeType: mimeType,
        fileName: fileName,
      ),
    );
    return _toDesktopMetadata(
      id: id,
      mimeType: mimeType,
      result: result,
      fileName: fileName,
    );
  }

  AttachmentMetadata _toDesktopMetadata({
    required String id,
    required String mimeType,
    required DesktopAttachmentFileResult result,
    required String? fileName,
  }) => AttachmentMetadata(
    id: id,
    mimeType: mimeType,
    storageType: AttachmentStorageType.desktopFile,
    storageKey: result.path,
    fileName: fileName,
    byteSize: result.byteSize,
    createdAt: _clock().millisecondsSinceEpoch,
  );

  /// A `web-indexeddb` key would be meaningless to the desktop host, and a
  /// `native-file` path belongs to another device entirely — both mean the
  /// metadata travelled here from a store that is not ours.
  void _assertDesktopAttachment(AttachmentMetadata attachment) {
    if (attachment.storageType != AttachmentStorageType.desktopFile) {
      throw StateError(
        "Unsupported desktop attachment storage type "
        "'${attachment.storageType.wireName}'.",
      );
    }
  }
}

/// The last segment of [path], or `null` when there is nothing after the final
/// separator.
///
/// Deliberately not `getFileNameFromPath` from the rules module: that helper
/// trims and strips trailing separators, so `/a/b/` yields `b`. Upstream's
/// desktop store does neither, so a trailing separator yields `null` and the
/// attachment stays unnamed — which is the right answer for a path that names a
/// directory rather than a file.
String? _inferFileNameFromPath(String path) {
  final lastPart = path.replaceAll(r'\', '/').split('/').last;
  return lastPart.isNotEmpty ? lastPart : null;
}

// ---------------------------------------------------------------------------
// desktop/attachments/desktop-preview-url.ts
// ---------------------------------------------------------------------------

/// Reads a managed desktop file as base64.
abstract interface class DesktopFileReader {
  Future<String> readFileBase64(String storageKey);
}

/// Invokes a named command on the desktop host.
///
/// Deviation: upstream imports `invokeDesktopCommand` directly. Injecting it
/// keeps the path-normalisation rule below testable without an IPC channel.
typedef DesktopCommandInvoker =
    Future<String> Function(String command, Map<String, Object?> arguments);

/// A [DesktopFileReader] backed by the host's `read_file_base64` command.
///
/// Accepts either a path or a `file://` URI because attachment metadata and
/// drag payloads disagree about which they carry; the host only understands
/// paths.
DesktopFileReader createDesktopFileReader(DesktopCommandInvoker invoke) =>
    _CommandDesktopFileReader(invoke);

final class _CommandDesktopFileReader implements DesktopFileReader {
  const _CommandDesktopFileReader(this._invoke);

  final DesktopCommandInvoker _invoke;

  @override
  Future<String> readFileBase64(String storageKey) => _invoke(
    'read_file_base64',
    <String, Object?>{'path': fileUriToPath(storageKey)},
  );
}

/// Turns stored desktop files into URLs the UI can render, and takes them back.
///
/// Object URLs are preferred over data URLs because a data URL of a multi-
/// megabyte screenshot has to be re-parsed by the renderer on every layout;
/// the data URL is only a fallback for hosts that cannot mint object URLs at
/// all.
final class DesktopPreviewUrlResolver {
  DesktopPreviewUrlResolver({required this.reader, required this.objectUrls});

  final DesktopFileReader reader;
  final AttachmentObjectUrlMinter objectUrls;

  /// Only URLs this resolver minted are tracked, so [release] can refuse to
  /// revoke a URL that belongs to somebody else — revoking another owner's
  /// object URL would blank out an image still on screen.
  final Set<String> _tracked = <String>{};

  Future<String> resolve(AttachmentMetadata attachment) async {
    final base64 = await reader.readFileBase64(attachment.storageKey);
    final url = objectUrls.tryCreate(
      mimeType: attachment.mimeType,
      bytes: decodeAttachmentBase64(base64),
    );
    if (url == null) {
      // Untracked on purpose: a data URL holds its own bytes and there is
      // nothing for `release` to hand back.
      return 'data:${attachment.mimeType};base64,$base64';
    }
    _tracked.add(url);
    return url;
  }

  /// Revoking the same URL twice is a no-op after the first call, since the
  /// second release would otherwise revoke a URL that has since been re-minted
  /// under the same string by the host.
  Future<void> release(String url) async {
    if (!_tracked.remove(url)) return;
    objectUrls.revoke(url);
  }
}
