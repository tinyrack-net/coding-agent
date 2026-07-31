// Ports of the upstream suites for Paseo 0.2.0's attachment byte stores —
// `attachments/local-file-attachment-store.test.ts`,
// `attachments/web/indexeddb-attachment-store.test.ts`,
// `desktop/attachments/desktop-attachment-store.test.ts` and
// `desktop/attachments/desktop-preview-url.test.ts` — plus the edge cases those
// suites leave unpinned: absent cache directories, extension fallbacks, mime
// inference precedence, missing records, connection lifecycle, and the
// storage-type guards.
//
// The fakes below stand in for the platform primitives each backend injects.
// `_FakeAttachmentFileSystem` mirrors upstream's `createTestAttachmentFileSystem`
// (directories tracked without a trailing slash, `listDirectory` returning entry
// names) so the ported expectations stay byte-comparable.
import 'dart:convert';
import 'dart:typed_data';

import 'package:coding_agent_app/attachments/paseo_attachment_stores.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

String _stripTrailingSlash(String uri) =>
    uri.endsWith('/') ? uri.substring(0, uri.length - 1) : uri;

final class _FakeAttachmentFileSystem implements AttachmentFileSystem {
  _FakeAttachmentFileSystem({this.cacheDirectory = 'file:///cache/'});

  @override
  final String? cacheDirectory;

  final Map<String, Uint8List> files = {};
  final Set<String> directories = {};
  final List<String> madeDirectories = [];
  final List<String> deletedUris = [];
  final List<bool> deleteIdempotency = [];
  final List<({String from, String to})> copies = [];

  /// When false, `getInfo` reports files as missing even after a write — the
  /// shape of a host that cannot stat what it just created.
  bool reportsFileInfo = true;

  @override
  Future<AttachmentFileInfo> getInfo(String uri) async {
    if (directories.contains(uri) ||
        directories.contains(_stripTrailingSlash(uri))) {
      return const AttachmentFileFound(isDirectory: true);
    }
    final bytes = files[uri];
    if (bytes != null && reportsFileInfo) {
      return AttachmentFileFound(isDirectory: false, size: bytes.length);
    }
    return const AttachmentFileMissing();
  }

  @override
  Future<void> makeDirectory(String uri, {required bool intermediates}) async {
    madeDirectories.add(uri);
    directories.add(_stripTrailingSlash(uri));
  }

  @override
  Future<void> writeBytes(String uri, Uint8List bytes) async {
    files[uri] = bytes;
  }

  @override
  Future<void> copy({required String from, required String to}) async {
    copies.add((from: from, to: to));
    final bytes = files[from];
    if (bytes == null) {
      throw StateError('copy: source does not exist: $from');
    }
    files[to] = bytes;
  }

  @override
  Future<String> readAsBase64(String uri) async {
    final bytes = files[uri];
    if (bytes == null) {
      throw StateError('readAsBase64: file does not exist: $uri');
    }
    return base64Encode(bytes);
  }

  @override
  Future<void> delete(String uri, {required bool idempotent}) async {
    deletedUris.add(uri);
    deleteIdempotency.add(idempotent);
    if (files.remove(uri) == null && !idempotent) {
      throw StateError('delete: file does not exist: $uri');
    }
  }

  @override
  Future<List<String>> listDirectory(String uri) async {
    final prefix = uri.endsWith('/') ? uri : '$uri/';
    return [
      for (final path in files.keys)
        if (path.startsWith(prefix)) path.substring(prefix.length),
    ];
  }
}

final class _MintedUrl {
  const _MintedUrl({
    required this.url,
    required this.mimeType,
    required this.base64,
  });

  final String url;
  final String mimeType;
  final String base64;

  @override
  bool operator ==(Object other) =>
      other is _MintedUrl &&
      other.url == url &&
      other.mimeType == mimeType &&
      other.base64 == base64;

  @override
  int get hashCode => Object.hash(url, mimeType, base64);

  @override
  String toString() =>
      '_MintedUrl(url: $url, mimeType: $mimeType, base64: $base64)';
}

final class _FakeObjectUrls implements AttachmentObjectUrlMinter {
  _FakeObjectUrls({this.supportsCreate = true});

  final bool supportsCreate;
  final List<_MintedUrl> minted = [];
  final List<String> revoked = [];
  int _nextId = 1;

  @override
  String? tryCreate({required String mimeType, required Uint8List bytes}) {
    if (!supportsCreate) return null;
    final url = 'blob:fake-${_nextId++}';
    // Recorded as base64 so the assertions stay identical to upstream's, where
    // the minter took the base64 payload rather than the decoded bytes.
    minted.add(
      _MintedUrl(url: url, mimeType: mimeType, base64: base64Encode(bytes)),
    );
    return url;
  }

  @override
  void revoke(String url) => revoked.add(url);
}

final class _FakeBlobSession implements AttachmentBlobSession {
  _FakeBlobSession(this._database);

  final _FakeBlobDatabase _database;
  bool closed = false;

  @override
  Future<void> put(StoredAttachmentBlob record) async {
    final error = _database.putError;
    if (error != null) throw error;
    _database.records[record.id] = record;
  }

  @override
  Future<StoredAttachmentBlob?> get(String id) async => _database.records[id];

  @override
  Future<void> delete(String id) async {
    _database.deletedKeys.add(id);
    _database.records.remove(id);
  }

  @override
  Future<List<String>> keys() async => _database.records.keys.toList();

  @override
  Future<void> close() async {
    closed = true;
    _database.closeCount += 1;
  }
}

final class _FakeBlobDatabase implements AttachmentBlobDatabase {
  final Map<String, StoredAttachmentBlob> records = {};
  final List<String> deletedKeys = [];
  final List<_FakeBlobSession> sessions = [];
  int openCount = 0;
  int closeCount = 0;
  Object? putError;

  @override
  Future<AttachmentBlobSession> open() async {
    openCount += 1;
    final session = _FakeBlobSession(this);
    sessions.add(session);
    return session;
  }
}

sealed class _FakeDesktopWrite {
  const _FakeDesktopWrite();
}

final class _FakeCopyWrite extends _FakeDesktopWrite {
  const _FakeCopyWrite(this.sourcePath);

  final String sourcePath;

  @override
  bool operator ==(Object other) =>
      other is _FakeCopyWrite && other.sourcePath == sourcePath;

  @override
  int get hashCode => sourcePath.hashCode;

  @override
  String toString() => '_FakeCopyWrite($sourcePath)';
}

final class _FakeBase64Write extends _FakeDesktopWrite {
  const _FakeBase64Write(this.base64);

  final String base64;

  @override
  bool operator ==(Object other) =>
      other is _FakeBase64Write && other.base64 == base64;

  @override
  int get hashCode => base64.hashCode;

  @override
  String toString() => '_FakeBase64Write($base64)';
}

final class _FakeBytesWrite extends _FakeDesktopWrite {
  const _FakeBytesWrite(this.bytes);

  final Uint8List bytes;

  @override
  bool operator ==(Object other) =>
      other is _FakeBytesWrite &&
      other.bytes.length == bytes.length &&
      base64Encode(other.bytes) == base64Encode(bytes);

  @override
  int get hashCode => base64Encode(bytes).hashCode;

  @override
  String toString() => '_FakeBytesWrite(${bytes.length} bytes)';
}

final class _FakeDesktopEntry {
  const _FakeDesktopEntry({
    required this.attachmentId,
    required this.path,
    required this.byteSize,
    required this.extension,
    required this.source,
  });

  final String attachmentId;
  final String path;
  final int byteSize;
  final String? extension;
  final _FakeDesktopWrite source;

  @override
  bool operator ==(Object other) =>
      other is _FakeDesktopEntry &&
      other.attachmentId == attachmentId &&
      other.path == path &&
      other.byteSize == byteSize &&
      other.extension == extension &&
      other.source == source;

  @override
  int get hashCode =>
      Object.hash(attachmentId, path, byteSize, extension, source);

  @override
  String toString() =>
      '_FakeDesktopEntry(attachmentId: $attachmentId, path: $path, '
      'byteSize: $byteSize, extension: $extension, source: $source)';
}

final class _FakeDesktopBridge implements DesktopAttachmentBridge {
  final List<_FakeDesktopEntry> savedEntries = [];
  final List<String> deletedPaths = [];
  final List<List<String>> garbageCollections = [];
  final List<String> readBase64Calls = [];
  final List<AttachmentMetadata> resolvedPreviewUrls = [];
  final List<String> releasedPreviewUrls = [];

  String _buildPath(String attachmentId, String? extension) =>
      '/managed/$attachmentId${extension ?? ''}';

  DesktopAttachmentFileResult _record(_FakeDesktopEntry entry) {
    savedEntries.add(entry);
    return DesktopAttachmentFileResult(
      path: entry.path,
      byteSize: entry.byteSize,
    );
  }

  @override
  Future<DesktopAttachmentFileResult> copyFile({
    required String attachmentId,
    required String sourcePath,
    String? extension,
  }) async => _record(
    _FakeDesktopEntry(
      attachmentId: attachmentId,
      path: _buildPath(attachmentId, extension),
      byteSize: 4,
      extension: extension,
      source: _FakeCopyWrite(sourcePath),
    ),
  );

  @override
  Future<DesktopAttachmentFileResult> writeBase64({
    required String attachmentId,
    required String base64,
    String? extension,
  }) async => _record(
    _FakeDesktopEntry(
      attachmentId: attachmentId,
      path: _buildPath(attachmentId, extension),
      byteSize: 4,
      extension: extension,
      source: _FakeBase64Write(base64),
    ),
  );

  @override
  Future<DesktopAttachmentFileResult> writeBytes({
    required String attachmentId,
    required Uint8List bytes,
    String? extension,
  }) async => _record(
    _FakeDesktopEntry(
      attachmentId: attachmentId,
      path: _buildPath(attachmentId, extension),
      byteSize: bytes.length,
      extension: extension,
      source: _FakeBytesWrite(bytes),
    ),
  );

  @override
  Future<bool> deleteFile(String path) async {
    deletedPaths.add(path);
    return true;
  }

  @override
  Future<int> garbageCollect(List<String> referencedIds) async {
    garbageCollections.add(referencedIds);
    return 0;
  }

  @override
  Future<String> readFileBase64(String path) async {
    readBase64Calls.add(path);
    return 'AAECAw==';
  }

  @override
  Future<String> resolvePreviewUrl(AttachmentMetadata attachment) async {
    resolvedPreviewUrls.add(attachment);
    return 'blob:test';
  }

  @override
  Future<void> releasePreviewUrl(String url) async {
    releasedPreviewUrls.add(url);
  }
}

final class _FakeDesktopReader implements DesktopFileReader {
  _FakeDesktopReader(this._files);

  final Map<String, String> _files;
  final List<String> reads = [];

  @override
  Future<String> readFileBase64(String storageKey) async {
    reads.add(storageKey);
    final base64 = _files[storageKey];
    if (base64 == null) {
      throw StateError(
        '_FakeDesktopReader: no file registered for $storageKey',
      );
    }
    return base64;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const String _baseDirectoryName = 'preview-assets';
const String _base = 'file:///cache/$_baseDirectoryName/';

LocalFileAttachmentStore _localStore(
  _FakeAttachmentFileSystem fileSystem, {
  AttachmentStorageType storageType = AttachmentStorageType.nativeFile,
  ResolveAttachmentPreviewUrl? resolvePreviewUrl,
  ReleaseAttachmentPreviewUrl? releasePreviewUrl,
  String Function()? generateId,
  DateTime Function()? clock,
}) => LocalFileAttachmentStore(
  storageType: storageType,
  baseDirectoryName: _baseDirectoryName,
  fileSystem: fileSystem,
  resolvePreviewUrlWith:
      resolvePreviewUrl ??
      (attachment) async => 'file://${attachment.storageKey}',
  releasePreviewUrlWith: releasePreviewUrl,
  generateId: generateId,
  clock: clock,
);

AttachmentMetadata _desktopAttachment({
  String id = 'att-1',
  String mimeType = 'image/png',
  String storageKey = '/tmp/att-1.png',
  AttachmentStorageType storageType = AttachmentStorageType.desktopFile,
}) => AttachmentMetadata(
  id: id,
  mimeType: mimeType,
  storageType: storageType,
  storageKey: storageKey,
  fileName: null,
  byteSize: null,
  createdAt: 0,
);

final Uint8List _fourBytes = Uint8List.fromList([0, 1, 2, 3]);

void main() {
  group('local file attachment store', () {
    test('writes raw byte sources directly to the managed file path', () async {
      final fileSystem = _FakeAttachmentFileSystem();
      final store = _localStore(fileSystem);

      final attachment = await store.save(
        SaveAttachmentInput(
          id: 'preview_8_test',
          mimeType: 'image/png',
          fileName: 'result.png',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );

      expect(attachment.id, 'preview_8_test');
      expect(attachment.mimeType, 'image/png');
      expect(attachment.storageType, AttachmentStorageType.nativeFile);
      expect(attachment.storageKey, '/cache/preview-assets/preview_8_test.png');
      expect(attachment.fileName, 'result.png');
      expect(attachment.byteSize, 4);
      expect(
        fileSystem.files['file:///cache/preview-assets/preview_8_test.png'],
        _fourBytes,
      );
      expect(
        fileSystem.directories.contains('file:///cache/preview-assets'),
        isTrue,
      );
    });

    test('refuses to save when the host has no cache directory', () async {
      final store = _localStore(
        _FakeAttachmentFileSystem(cacheDirectory: null),
      );

      await expectLater(
        store.save(
          SaveAttachmentInput(source: BytesAttachmentSource(_fourBytes)),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Attachment file-system cacheDirectory is unavailable.',
          ),
        ),
      );
    });

    test('treats an empty cache directory as no cache directory', () async {
      final store = _localStore(_FakeAttachmentFileSystem(cacheDirectory: ''));

      await expectLater(
        store.save(
          SaveAttachmentInput(source: BytesAttachmentSource(_fourBytes)),
        ),
        throwsStateError,
      );
      // The same falsiness silences garbage collection rather than throwing.
      await store.garbageCollect({'att_1'});
    });

    test('decodes data URL sources and takes their mime type', () async {
      final fileSystem = _FakeAttachmentFileSystem();
      final store = _localStore(fileSystem);

      final attachment = await store.save(
        const SaveAttachmentInput(
          id: 'att_data',
          source: DataUrlAttachmentSource('data:image/gif;base64,AAECAw=='),
        ),
      );

      expect(attachment.mimeType, 'image/gif');
      expect(attachment.storageKey, '/cache/preview-assets/att_data.gif');
      expect(fileSystem.files['${_base}att_data.gif'], _fourBytes);
    });

    test('lets an explicit mime type win over the data URL\'s own', () async {
      final fileSystem = _FakeAttachmentFileSystem();
      final store = _localStore(fileSystem);

      final attachment = await store.save(
        const SaveAttachmentInput(
          id: 'att_override',
          mimeType: 'image/webp',
          source: DataUrlAttachmentSource('data:image/png;base64,AAECAw=='),
        ),
      );

      expect(attachment.mimeType, 'image/webp');
      expect(attachment.storageKey, '/cache/preview-assets/att_override.webp');
    });

    test(
      'rejects a malformed data URL even when a mime type is given',
      () async {
        final store = _localStore(_FakeAttachmentFileSystem());

        await expectLater(
          store.save(
            const SaveAttachmentInput(
              id: 'att_bad',
              mimeType: 'image/png',
              source: DataUrlAttachmentSource('data:image/png,not-base64'),
            ),
          ),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('takes the mime type from a blob source, JPEG when untyped', () async {
      final fileSystem = _FakeAttachmentFileSystem();
      final store = _localStore(fileSystem);

      final typed = await store.save(
        SaveAttachmentInput(
          id: 'att_typed',
          source: BlobAttachmentSource(
            AttachmentBlob(bytes: _fourBytes, type: 'image/bmp'),
          ),
        ),
      );
      final untyped = await store.save(
        SaveAttachmentInput(
          id: 'att_untyped',
          source: BlobAttachmentSource(
            AttachmentBlob(bytes: _fourBytes, type: ''),
          ),
        ),
      );

      expect(typed.mimeType, 'image/bmp');
      expect(typed.storageKey, '/cache/preview-assets/att_typed.bmp');
      expect(untyped.mimeType, 'image/jpeg');
      expect(untyped.storageKey, '/cache/preview-assets/att_untyped.jpg');
    });

    test('copies file URI sources into the managed directory', () async {
      final fileSystem = _FakeAttachmentFileSystem();
      fileSystem.files['file:///Users/test/Desktop/image.png'] = _fourBytes;
      final store = _localStore(fileSystem);

      final attachment = await store.save(
        const SaveAttachmentInput(
          id: 'att_copy',
          mimeType: 'image/png',
          source: FileUriAttachmentSource('/Users/test/Desktop/image.png'),
        ),
      );

      expect(fileSystem.copies, [
        (
          from: 'file:///Users/test/Desktop/image.png',
          to: '${_base}att_copy.png',
        ),
      ]);
      expect(fileSystem.files['${_base}att_copy.png'], _fourBytes);
      expect(attachment.byteSize, 4);
    });

    test(
      'skips the copy when the source already is the managed file',
      () async {
        final fileSystem = _FakeAttachmentFileSystem();
        final store = _localStore(fileSystem);

        final attachment = await store.save(
          const SaveAttachmentInput(
            id: 'att_same',
            mimeType: 'image/png',
            source: FileUriAttachmentSource(
              'file:///cache/preview-assets/att_same.png',
            ),
          ),
        );

        expect(fileSystem.copies, isEmpty);
        expect(attachment.storageKey, '/cache/preview-assets/att_same.png');
      },
    );

    test('names the file from the mime table when the name has none', () async {
      final fileSystem = _FakeAttachmentFileSystem();
      final store = _localStore(fileSystem);

      final noExtension = await store.save(
        SaveAttachmentInput(
          id: 'att_a',
          mimeType: 'image/png',
          fileName: 'result',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );
      final dotfile = await store.save(
        SaveAttachmentInput(
          id: 'att_b',
          mimeType: 'image/svg+xml',
          fileName: '.env',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );
      final unknownType = await store.save(
        SaveAttachmentInput(
          id: 'att_c',
          mimeType: 'application/zip',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );
      final namedExtension = await store.save(
        SaveAttachmentInput(
          id: 'att_d',
          mimeType: 'image/png',
          fileName: 'archive.tar.gz',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );

      expect(noExtension.storageKey, '/cache/preview-assets/att_a.png');
      expect(dotfile.storageKey, '/cache/preview-assets/att_b.svg');
      expect(unknownType.storageKey, '/cache/preview-assets/att_c.img');
      expect(namedExtension.storageKey, '/cache/preview-assets/att_d.gz');
    });

    test(
      'reports a null byte size when the host cannot stat the file',
      () async {
        final fileSystem = _FakeAttachmentFileSystem()..reportsFileInfo = false;
        final store = _localStore(fileSystem);

        final attachment = await store.save(
          SaveAttachmentInput(
            id: 'att_unstattable',
            mimeType: 'image/png',
            source: BytesAttachmentSource(_fourBytes),
          ),
        );

        expect(attachment.byteSize, isNull);
        expect(fileSystem.files['${_base}att_unstattable.png'], _fourBytes);
      },
    );

    test(
      'mints an id and stamps createdAt when the caller supplies neither',
      () async {
        final fileSystem = _FakeAttachmentFileSystem();
        final store = _localStore(
          fileSystem,
          generateId: () => 'att_generated',
          clock: () => DateTime.fromMillisecondsSinceEpoch(1234),
        );

        final attachment = await store.save(
          SaveAttachmentInput(
            mimeType: 'image/png',
            source: BytesAttachmentSource(_fourBytes),
          ),
        );

        expect(attachment.id, 'att_generated');
        expect(attachment.createdAt, 1234);
        expect(attachment.fileName, isNull);
      },
    );

    test(
      'reuses an existing managed directory instead of recreating it',
      () async {
        final fileSystem = _FakeAttachmentFileSystem();
        fileSystem.directories.add('file:///cache/preview-assets');
        final store = _localStore(fileSystem);

        await store.save(
          SaveAttachmentInput(
            id: 'att_1',
            mimeType: 'image/png',
            source: BytesAttachmentSource(_fourBytes),
          ),
        );

        expect(fileSystem.madeDirectories, isEmpty);
      },
    );

    test('reads stored bytes back through the file URI', () async {
      final fileSystem = _FakeAttachmentFileSystem();
      final store = _localStore(fileSystem);
      final attachment = await store.save(
        SaveAttachmentInput(
          id: 'att_read',
          mimeType: 'image/png',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );

      expect(await store.encodeBase64(attachment), 'AAECAw==');
    });

    test('deletes idempotently', () async {
      final fileSystem = _FakeAttachmentFileSystem();
      final store = _localStore(fileSystem);
      final attachment = await store.save(
        SaveAttachmentInput(
          id: 'att_gone',
          mimeType: 'image/png',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );

      await store.delete(attachment);
      // A second delete of the same, now-absent file must still not throw.
      await store.delete(attachment);

      expect(fileSystem.deletedUris, [
        '${_base}att_gone.png',
        '${_base}att_gone.png',
      ]);
      expect(fileSystem.deleteIdempotency, [true, true]);
      expect(fileSystem.files.containsKey('${_base}att_gone.png'), isFalse);
    });

    test('delegates preview URL resolution and release', () async {
      final released = <String>[];
      final fileSystem = _FakeAttachmentFileSystem();
      final store = _localStore(
        fileSystem,
        resolvePreviewUrl: (attachment) async => 'custom:${attachment.id}',
        releasePreviewUrl: ({required attachment, required url}) async =>
            released.add('${attachment.id}:$url'),
      );
      final attachment = await store.save(
        SaveAttachmentInput(
          id: 'att_preview',
          mimeType: 'image/png',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );

      expect(store.supportsPreviewUrlRelease, isTrue);
      expect(await store.resolvePreviewUrl(attachment), 'custom:att_preview');
      await store.releasePreviewUrl(attachment: attachment, url: 'blob:x');
      expect(released, ['att_preview:blob:x']);
    });

    test('releasing is a silent no-op when no release hook is given', () async {
      final store = _localStore(_FakeAttachmentFileSystem());

      expect(store.supportsPreviewUrlRelease, isFalse);
      await store.releasePreviewUrl(
        attachment: _desktopAttachment(),
        url: 'blob:x',
      );
    });

    test('garbage collects unreferenced managed files only', () async {
      final fileSystem = _FakeAttachmentFileSystem();
      fileSystem.files['${_base}att_keep.png'] = _fourBytes;
      fileSystem.files['${_base}att_drop.png'] = _fourBytes;
      fileSystem.files['${_base}att_multi.tar.gz'] = _fourBytes;
      fileSystem.files['$_base.hidden'] = _fourBytes;
      final store = _localStore(fileSystem);

      await store.garbageCollect({'att_keep', 'att_multi'});

      expect(fileSystem.deletedUris, ['${_base}att_drop.png']);
      expect(
        fileSystem.files.keys,
        containsAll(<String>[
          '${_base}att_keep.png',
          '${_base}att_multi.tar.gz',
          '$_base.hidden',
        ]),
      );
      // Collection also guarantees the managed directory exists.
      expect(fileSystem.directories, contains('file:///cache/preview-assets'));
    });

    test('collects nothing when everything is still referenced', () async {
      final fileSystem = _FakeAttachmentFileSystem();
      fileSystem.files['${_base}att_a.png'] = _fourBytes;
      final store = _localStore(fileSystem);

      await store.garbageCollect({'att_a'});

      expect(fileSystem.deletedUris, isEmpty);
    });

    test('rejects a web-indexeddb storage type', () {
      expect(
        () => LocalFileAttachmentStore(
          storageType: AttachmentStorageType.webIndexedDb,
          baseDirectoryName: _baseDirectoryName,
          fileSystem: _FakeAttachmentFileSystem(),
          resolvePreviewUrlWith: (attachment) async => 'x',
        ),
        throwsArgumentError,
      );
    });

    test('stamps desktop-file metadata when built for desktop', () async {
      final store = _localStore(
        _FakeAttachmentFileSystem(),
        storageType: AttachmentStorageType.desktopFile,
      );

      final attachment = await store.save(
        SaveAttachmentInput(
          id: 'att_desktop',
          mimeType: 'image/png',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );

      expect(store.storageType, AttachmentStorageType.desktopFile);
      expect(attachment.storageType, AttachmentStorageType.desktopFile);
    });
  });

  group('indexeddb attachment store', () {
    test('stores raw byte sources as a Blob', () async {
      final database = _FakeBlobDatabase();
      final store = IndexedDbAttachmentStore(
        database: database,
        objectUrls: _FakeObjectUrls(),
      );

      final attachment = await store.save(
        SaveAttachmentInput(
          id: 'att_bytes',
          mimeType: 'image/png',
          fileName: 'image.png',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );

      final record = database.records['att_bytes']!;
      expect(record.id, 'att_bytes');
      expect(record.blob, AttachmentBlob(bytes: _fourBytes, type: 'image/png'));
      expect(record.createdAt, isA<int>());
      expect(record.fileName, 'image.png');

      expect(attachment.id, 'att_bytes');
      expect(attachment.mimeType, 'image/png');
      expect(attachment.storageType, AttachmentStorageType.webIndexedDb);
      expect(attachment.storageKey, 'att_bytes');
      expect(attachment.fileName, 'image.png');
      expect(attachment.byteSize, 4);
    });

    test('falls back to JPEG for untyped raw bytes', () async {
      final database = _FakeBlobDatabase();
      final store = IndexedDbAttachmentStore(
        database: database,
        objectUrls: _FakeObjectUrls(),
      );

      final attachment = await store.save(
        SaveAttachmentInput(
          id: 'att_untyped',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );

      expect(attachment.mimeType, 'image/jpeg');
      expect(database.records['att_untyped']!.blob.type, 'image/jpeg');
    });

    test('keeps a blob source as-is and retypes it on override', () async {
      final database = _FakeBlobDatabase();
      final store = IndexedDbAttachmentStore(
        database: database,
        objectUrls: _FakeObjectUrls(),
      );
      final blob = AttachmentBlob(bytes: _fourBytes, type: 'image/gif');

      final kept = await store.save(
        SaveAttachmentInput(id: 'att_kept', source: BlobAttachmentSource(blob)),
      );
      final retyped = await store.save(
        SaveAttachmentInput(
          id: 'att_retyped',
          mimeType: 'image/webp',
          source: BlobAttachmentSource(blob),
        ),
      );

      expect(kept.mimeType, 'image/gif');
      expect(identical(database.records['att_kept']!.blob, blob), isTrue);
      expect(retyped.mimeType, 'image/webp');
      expect(database.records['att_retyped']!.blob.type, 'image/webp');
      expect(database.records['att_retyped']!.blob.bytes, _fourBytes);
    });

    test(
      'stores data URL sources decoded, with the URL\'s mime type',
      () async {
        final database = _FakeBlobDatabase();
        final store = IndexedDbAttachmentStore(
          database: database,
          objectUrls: _FakeObjectUrls(),
        );

        final attachment = await store.save(
          const SaveAttachmentInput(
            id: 'att_data',
            source: DataUrlAttachmentSource('data:image/gif;base64,AAECAw=='),
          ),
        );

        expect(attachment.mimeType, 'image/gif');
        expect(attachment.byteSize, 4);
        expect(
          database.records['att_data']!.blob,
          AttachmentBlob(bytes: _fourBytes, type: 'image/gif'),
        );
      },
    );

    test('reads file URI sources through the injected fetcher', () async {
      final database = _FakeBlobDatabase();
      final fetched = <String>[];
      final store = IndexedDbAttachmentStore(
        database: database,
        objectUrls: _FakeObjectUrls(),
        fetchUri: (uri) async {
          fetched.add(uri);
          return AttachmentBlob(bytes: _fourBytes, type: 'image/tiff');
        },
      );

      final attachment = await store.save(
        const SaveAttachmentInput(
          id: 'att_uri',
          source: FileUriAttachmentSource('blob:https://app/abc'),
        ),
      );

      expect(fetched, ['blob:https://app/abc']);
      expect(attachment.mimeType, 'image/tiff');
      expect(database.records['att_uri']!.blob.bytes, _fourBytes);
    });

    test('rejects file URI sources when no fetcher is configured', () async {
      final store = IndexedDbAttachmentStore(
        database: _FakeBlobDatabase(),
        objectUrls: _FakeObjectUrls(),
      );

      await expectLater(
        store.save(
          const SaveAttachmentInput(
            source: FileUriAttachmentSource('blob:https://app/abc'),
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('mints an id and stamps createdAt from the clock', () async {
      final database = _FakeBlobDatabase();
      final store = IndexedDbAttachmentStore(
        database: database,
        objectUrls: _FakeObjectUrls(),
        generateId: () => 'att_generated',
        clock: () => DateTime.fromMillisecondsSinceEpoch(4321),
      );

      final attachment = await store.save(
        SaveAttachmentInput(source: BytesAttachmentSource(_fourBytes)),
      );

      expect(attachment.id, 'att_generated');
      expect(attachment.storageKey, 'att_generated');
      expect(attachment.createdAt, 4321);
      expect(database.records['att_generated']!.createdAt, 4321);
      expect(database.records['att_generated']!.fileName, isNull);
    });

    test('encodes stored bytes as base64', () async {
      final database = _FakeBlobDatabase();
      final store = IndexedDbAttachmentStore(
        database: database,
        objectUrls: _FakeObjectUrls(),
      );
      final attachment = await store.save(
        SaveAttachmentInput(
          id: 'att_read',
          mimeType: 'image/png',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );

      expect(await store.encodeBase64(attachment), 'AAECAw==');
    });

    test('throws when the requested record is missing', () async {
      final store = IndexedDbAttachmentStore(
        database: _FakeBlobDatabase(),
        objectUrls: _FakeObjectUrls(),
      );

      await expectLater(
        store.encodeBase64(
          _desktopAttachment(
            id: 'att_ghost',
            storageKey: 'att_ghost',
            storageType: AttachmentStorageType.webIndexedDb,
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Attachment att_ghost was not found in IndexedDB.',
          ),
        ),
      );
    });

    test('mints preview URLs and revokes them unconditionally', () async {
      final database = _FakeBlobDatabase();
      final objectUrls = _FakeObjectUrls();
      final store = IndexedDbAttachmentStore(
        database: database,
        objectUrls: objectUrls,
      );
      final attachment = await store.save(
        SaveAttachmentInput(
          id: 'att_preview',
          mimeType: 'image/png',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );

      expect(store.supportsPreviewUrlRelease, isTrue);
      expect(await store.resolvePreviewUrl(attachment), 'blob:fake-1');
      expect(objectUrls.minted, [
        const _MintedUrl(
          url: 'blob:fake-1',
          mimeType: 'image/png',
          base64: 'AAECAw==',
        ),
      ]);

      // No minted-URL ledger on this backend: even a foreign URL is revoked.
      await store.releasePreviewUrl(attachment: attachment, url: 'blob:other');
      expect(objectUrls.revoked, ['blob:other']);
    });

    test('throws when the host cannot mint object URLs', () async {
      final database = _FakeBlobDatabase();
      final store = IndexedDbAttachmentStore(
        database: database,
        objectUrls: _FakeObjectUrls(supportsCreate: false),
      );
      final attachment = await store.save(
        SaveAttachmentInput(
          id: 'att_preview',
          mimeType: 'image/png',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );

      await expectLater(
        store.resolvePreviewUrl(attachment),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Object URLs are unavailable in this runtime.',
          ),
        ),
      );
    });

    test('deletes a single record by its storage key', () async {
      final database = _FakeBlobDatabase();
      final store = IndexedDbAttachmentStore(
        database: database,
        objectUrls: _FakeObjectUrls(),
      );
      final attachment = await store.save(
        SaveAttachmentInput(
          id: 'att_gone',
          mimeType: 'image/png',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );

      await store.delete(attachment);

      expect(database.deletedKeys, ['att_gone']);
      expect(database.records, isEmpty);
    });

    test('garbage collects unreferenced records only', () async {
      final database = _FakeBlobDatabase();
      final store = IndexedDbAttachmentStore(
        database: database,
        objectUrls: _FakeObjectUrls(),
      );
      for (final id in ['att_keep', 'att_drop', 'att_also_drop']) {
        await store.save(
          SaveAttachmentInput(
            id: id,
            mimeType: 'image/png',
            source: BytesAttachmentSource(_fourBytes),
          ),
        );
      }

      await store.garbageCollect({'att_keep'});

      expect(database.deletedKeys, ['att_drop', 'att_also_drop']);
      expect(database.records.keys, ['att_keep']);
    });

    test(
      'closes the connection after every operation, failures included',
      () async {
        final database = _FakeBlobDatabase();
        final store = IndexedDbAttachmentStore(
          database: database,
          objectUrls: _FakeObjectUrls(),
        );

        await store.save(
          SaveAttachmentInput(
            id: 'att_1',
            mimeType: 'image/png',
            source: BytesAttachmentSource(_fourBytes),
          ),
        );
        await store.garbageCollect({'att_1'});
        database.putError = StateError('IndexedDB transaction request failed.');
        await expectLater(
          store.save(
            SaveAttachmentInput(
              id: 'att_2',
              mimeType: 'image/png',
              source: BytesAttachmentSource(_fourBytes),
            ),
          ),
          throwsStateError,
        );

        expect(database.openCount, 3);
        expect(database.closeCount, 3);
        expect(database.sessions.every((session) => session.closed), isTrue);
      },
    );
  });

  group('desktop attachment store', () {
    test('saves dropped file paths as desktop-file metadata', () async {
      final bridge = _FakeDesktopBridge();
      final store = DesktopAttachmentStore(bridge);

      final attachment = await store.save(
        const SaveAttachmentInput(
          id: 'att_1',
          mimeType: 'image/png',
          source: FileUriAttachmentSource(
            'file:///Users/test/Desktop/image.png',
          ),
        ),
      );

      expect(bridge.savedEntries, [
        const _FakeDesktopEntry(
          attachmentId: 'att_1',
          path: '/managed/att_1.png',
          byteSize: 4,
          extension: '.png',
          source: _FakeCopyWrite('/Users/test/Desktop/image.png'),
        ),
      ]);
      expect(attachment.storageType, AttachmentStorageType.desktopFile);
      expect(attachment.storageKey, '/managed/att_1.png');
    });

    test('saves blob/data-url sources via desktop filesystem writes', () async {
      final bridge = _FakeDesktopBridge();
      final store = DesktopAttachmentStore(bridge);

      await store.save(
        const SaveAttachmentInput(
          id: 'att_2',
          source: DataUrlAttachmentSource('data:image/png;base64,AAECAw=='),
        ),
      );

      expect(bridge.savedEntries, [
        const _FakeDesktopEntry(
          attachmentId: 'att_2',
          path: '/managed/att_2.png',
          byteSize: 4,
          extension: '.png',
          source: _FakeBase64Write('AAECAw=='),
        ),
      ]);
    });

    test('saves raw byte sources via desktop filesystem writes', () async {
      final bridge = _FakeDesktopBridge();
      final store = DesktopAttachmentStore(bridge);

      final attachment = await store.save(
        SaveAttachmentInput(
          id: 'att_bytes',
          mimeType: 'image/png',
          fileName: 'inline.png',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );

      expect(bridge.savedEntries, [
        _FakeDesktopEntry(
          attachmentId: 'att_bytes',
          path: '/managed/att_bytes.png',
          byteSize: 4,
          extension: '.png',
          source: _FakeBytesWrite(_fourBytes),
        ),
      ]);
      expect(attachment.id, 'att_bytes');
      expect(attachment.mimeType, 'image/png');
      expect(attachment.storageType, AttachmentStorageType.desktopFile);
      expect(attachment.storageKey, '/managed/att_bytes.png');
      expect(attachment.fileName, 'inline.png');
      expect(attachment.byteSize, 4);
    });

    test(
      'delegates encode/preview/delete/gc to desktop command path',
      () async {
        final bridge = _FakeDesktopBridge();
        final store = DesktopAttachmentStore(bridge);
        final attachment = _desktopAttachment(
          id: 'att_3',
          mimeType: 'image/jpeg',
          storageKey: '/managed/att_3.jpg',
        );

        await store.encodeBase64(attachment);
        await store.resolvePreviewUrl(attachment);
        await store.releasePreviewUrl(attachment: attachment, url: 'blob:test');
        await store.delete(attachment);
        await store.garbageCollect({'att_3'});

        expect(bridge.readBase64Calls, ['/managed/att_3.jpg']);
        expect(bridge.resolvedPreviewUrls, [attachment]);
        expect(bridge.releasedPreviewUrls, ['blob:test']);
        expect(bridge.deletedPaths, ['/managed/att_3.jpg']);
        expect(bridge.garbageCollections, [
          ['att_3'],
        ]);
      },
    );

    test('infers the file name and extension from the source path', () async {
      final bridge = _FakeDesktopBridge();
      final store = DesktopAttachmentStore(bridge);

      final attachment = await store.save(
        const SaveAttachmentInput(
          id: 'att_named',
          source: FileUriAttachmentSource(
            'file:///Users/test/Desktop/report.heic',
          ),
        ),
      );

      expect(attachment.fileName, 'report.heic');
      // The extension came from the inferred name, but the mime type did not:
      // an unspecified type still falls back to JPEG.
      expect(attachment.mimeType, 'image/jpeg');
      expect(bridge.savedEntries.single.extension, '.heic');
    });

    test('keeps an explicit file name over the source path', () async {
      final bridge = _FakeDesktopBridge();
      final store = DesktopAttachmentStore(bridge);

      final attachment = await store.save(
        const SaveAttachmentInput(
          id: 'att_named',
          fileName: 'renamed.webp',
          source: FileUriAttachmentSource('/Users/test/Desktop/original.heic'),
        ),
      );

      expect(attachment.fileName, 'renamed.webp');
      expect(bridge.savedEntries.single.extension, '.webp');
      expect(
        bridge.savedEntries.single.source,
        const _FakeCopyWrite('/Users/test/Desktop/original.heic'),
      );
    });

    test('leaves a directory-shaped source path unnamed', () async {
      final bridge = _FakeDesktopBridge();
      final store = DesktopAttachmentStore(bridge);

      final attachment = await store.save(
        const SaveAttachmentInput(
          id: 'att_dir',
          mimeType: 'image/gif',
          source: FileUriAttachmentSource('/Users/test/Desktop/'),
        ),
      );

      expect(attachment.fileName, isNull);
      // No name and no extension on the path, so the mime table decides.
      expect(bridge.savedEntries.single.extension, '.gif');
    });

    test('falls back to .img for a payload with no nameable type', () async {
      final bridge = _FakeDesktopBridge();
      final store = DesktopAttachmentStore(bridge);

      await store.save(
        SaveAttachmentInput(
          id: 'att_opaque',
          mimeType: 'application/octet-stream',
          source: BytesAttachmentSource(_fourBytes),
        ),
      );

      expect(bridge.savedEntries.single.extension, '.img');
      expect(bridge.savedEntries.single.path, '/managed/att_opaque.img');
    });

    test('encodes blob sources to base64 before handing them over', () async {
      final bridge = _FakeDesktopBridge();
      final store = DesktopAttachmentStore(bridge);

      final attachment = await store.save(
        SaveAttachmentInput(
          id: 'att_blob',
          source: BlobAttachmentSource(
            AttachmentBlob(bytes: _fourBytes, type: 'image/bmp'),
          ),
        ),
      );

      expect(attachment.mimeType, 'image/bmp');
      expect(bridge.savedEntries, [
        const _FakeDesktopEntry(
          attachmentId: 'att_blob',
          path: '/managed/att_blob.bmp',
          byteSize: 4,
          extension: '.bmp',
          source: _FakeBase64Write('AAECAw=='),
        ),
      ]);
    });

    test('rejects an empty blob source the way FileReader does', () async {
      final store = DesktopAttachmentStore(_FakeDesktopBridge());

      await expectLater(
        store.save(
          SaveAttachmentInput(
            id: 'att_empty',
            source: BlobAttachmentSource(
              AttachmentBlob(bytes: Uint8List(0), type: 'image/png'),
            ),
          ),
        ),
        throwsStateError,
      );
    });

    test('rejects metadata that belongs to another storage backend', () async {
      final store = DesktopAttachmentStore(_FakeDesktopBridge());
      final foreign = _desktopAttachment(
        storageType: AttachmentStorageType.webIndexedDb,
      );

      final matcher = throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          "Unsupported desktop attachment storage type 'web-indexeddb'.",
        ),
      );
      await expectLater(store.encodeBase64(foreign), matcher);
      await expectLater(store.resolvePreviewUrl(foreign), matcher);
      await expectLater(
        store.releasePreviewUrl(attachment: foreign, url: 'blob:x'),
        matcher,
      );
      await expectLater(store.delete(foreign), matcher);
      // Collection carries no metadata, so it is not guarded.
      await store.garbageCollect({'att-1'});
    });

    test(
      'mints an id and stamps createdAt when the caller supplies neither',
      () async {
        final bridge = _FakeDesktopBridge();
        final store = DesktopAttachmentStore(
          bridge,
          generateId: () => 'att_generated',
          clock: () => DateTime.fromMillisecondsSinceEpoch(999),
        );

        final attachment = await store.save(
          SaveAttachmentInput(
            mimeType: 'image/png',
            source: BytesAttachmentSource(_fourBytes),
          ),
        );

        expect(attachment.id, 'att_generated');
        expect(attachment.createdAt, 999);
        expect(store.storageType, AttachmentStorageType.desktopFile);
        expect(store.supportsPreviewUrlRelease, isTrue);
      },
    );
  });

  group('desktop preview URLs', () {
    test('mints an object URL from the desktop file\'s base64 bytes', () async {
      final reader = _FakeDesktopReader({'/tmp/att-1.png': 'AAECAw=='});
      final objectUrls = _FakeObjectUrls();
      final resolver = DesktopPreviewUrlResolver(
        reader: reader,
        objectUrls: objectUrls,
      );

      final url = await resolver.resolve(_desktopAttachment());

      expect(url, 'blob:fake-1');
      expect(reader.reads, ['/tmp/att-1.png']);
      expect(objectUrls.minted, [
        const _MintedUrl(
          url: 'blob:fake-1',
          mimeType: 'image/png',
          base64: 'AAECAw==',
        ),
      ]);
    });

    test('falls back to a data URL when the host cannot mint URLs', () async {
      final reader = _FakeDesktopReader({'/tmp/att-2.jpg': 'AAECAw=='});
      final objectUrls = _FakeObjectUrls(supportsCreate: false);
      final resolver = DesktopPreviewUrlResolver(
        reader: reader,
        objectUrls: objectUrls,
      );

      final url = await resolver.resolve(
        _desktopAttachment(
          id: 'att-2',
          mimeType: 'image/jpeg',
          storageKey: '/tmp/att-2.jpg',
        ),
      );

      expect(url, 'data:image/jpeg;base64,AAECAw==');
      expect(objectUrls.revoked, isEmpty);
      // A data URL was never tracked, so releasing it revokes nothing.
      await resolver.release(url);
      expect(objectUrls.revoked, isEmpty);
    });

    test('revokes only object URLs it minted', () async {
      final reader = _FakeDesktopReader({'/tmp/att-3.jpg': 'AAECAw=='});
      final objectUrls = _FakeObjectUrls();
      final resolver = DesktopPreviewUrlResolver(
        reader: reader,
        objectUrls: objectUrls,
      );

      final url = await resolver.resolve(
        _desktopAttachment(
          id: 'att-3',
          mimeType: 'image/jpeg',
          storageKey: '/tmp/att-3.jpg',
        ),
      );
      await resolver.release(url);
      await resolver.release('blob:never-minted');

      expect(objectUrls.revoked, [url]);
    });

    test('only revokes a minted URL once across repeated releases', () async {
      final reader = _FakeDesktopReader({'/tmp/att-4.png': 'AAECAw=='});
      final objectUrls = _FakeObjectUrls();
      final resolver = DesktopPreviewUrlResolver(
        reader: reader,
        objectUrls: objectUrls,
      );

      final url = await resolver.resolve(
        _desktopAttachment(id: 'att-4', storageKey: '/tmp/att-4.png'),
      );
      await resolver.release(url);
      await resolver.release(url);

      expect(objectUrls.revoked, [url]);
    });

    test('tracks each attachment\'s URL independently', () async {
      final reader = _FakeDesktopReader({
        '/tmp/att-5.png': 'AAECAw==',
        '/tmp/att-6.png': 'BAUGBw==',
      });
      final objectUrls = _FakeObjectUrls();
      final resolver = DesktopPreviewUrlResolver(
        reader: reader,
        objectUrls: objectUrls,
      );

      final first = await resolver.resolve(
        _desktopAttachment(id: 'att-5', storageKey: '/tmp/att-5.png'),
      );
      final second = await resolver.resolve(
        _desktopAttachment(id: 'att-6', storageKey: '/tmp/att-6.png'),
      );
      await resolver.release(second);

      expect([first, second], ['blob:fake-1', 'blob:fake-2']);
      expect(objectUrls.revoked, ['blob:fake-2']);
      await resolver.release(first);
      expect(objectUrls.revoked, ['blob:fake-2', 'blob:fake-1']);
    });

    test('reads desktop files through the host command as a path', () async {
      final invocations =
          <({String command, Map<String, Object?> arguments})>[];
      final reader = createDesktopFileReader((command, arguments) async {
        invocations.add((command: command, arguments: arguments));
        return 'AAECAw==';
      });

      expect(
        await reader.readFileBase64('file:///Users/test/Desktop/image.png'),
        'AAECAw==',
      );
      await reader.readFileBase64('/already/a/path.png');

      expect(invocations.map((entry) => entry.command), [
        'read_file_base64',
        'read_file_base64',
      ]);
      expect(invocations.map((entry) => entry.arguments['path']), [
        '/Users/test/Desktop/image.png',
        '/already/a/path.png',
      ]);
    });
  });
}
