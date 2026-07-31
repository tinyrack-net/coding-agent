/// Ports of Paseo 0.2.0's frozen attachment rules — the pure, dependency-free
/// decisions the composer and the image picker ask before any byte is read:
///
/// - `attachments/file-types.ts` — which files count as *images* the agent can
///   see natively versus opaque blobs it can only be handed as a file. SVG is
///   deliberately on the file side of that line.
/// - `attachments/utils.ts` — the string plumbing around attachment payloads:
///   data URLs, cache keys, file names, and the path <-> `file://` round trip
///   that has to survive Windows drive letters and UNC shares.
/// - `attachments/workspace-attachment-utils.ts` — which composer pills came
///   from the *workspace* (review, browser element, chat history, pull-request
///   context) rather than from the user, since only the latter belong to the
///   user's persisted draft.
/// - `hooks/picked-image-normalizer.ts` — whether a natively picked photo can
///   be attached as-is or has to be re-encoded to PNG first.
///
/// Reuse notes: `resolveRasterImageMimeType` and `rasterImageMimeTypeByExtension`
/// were already ported in `composer/composer_image_attachments.dart` and are
/// re-exported here rather than redeclared, so there is exactly one raster-image
/// MIME table in the app. `isAbsolutePath` comes from `core/path.dart`, and
/// `workspaceAttachmentToSubmitAttachment` already exists as
/// `WorkspaceContextAttachment.toAgentAttachment()` in
/// `state/workspace_attachments_provider.dart`.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../composer/composer_image_attachments.dart';
import '../core/path.dart';

export '../composer/composer_image_attachments.dart'
    show rasterImageMimeTypeByExtension, resolveRasterImageMimeType;

// ---------------------------------------------------------------------------
// file-types.ts
// ---------------------------------------------------------------------------

/// What an attachment is reported as when nothing better is known.
///
/// Paseo intentionally does not maintain a MIME table for non-image files: the
/// agent receives them as opaque bytes, so guessing `text/markdown` would only
/// add a way to be wrong.
const String genericFileMimeType = 'application/octet-stream';

/// The extensions (no leading dot) the native image picker offers.
///
/// Derived from the shared raster table so the picker can never drift from
/// what the composer will actually accept. SVG is absent on purpose — it is a
/// document, not a raster image, and models cannot consume it as one.
final List<String> rasterImageFileExtensions = List.unmodifiable([
  for (final extension in rasterImageMimeTypeByExtension.keys)
    extension.substring(1),
]);

/// The lowercased extension of [path], including the leading dot, or `''`.
///
/// Fragments and query strings are stripped first because attachment paths
/// double as preview URLs (`.../screenshot.png?cache=1`), and a cache-buster
/// must not turn an image into an unknown file type.
String getFileExtension(String path) {
  final normalizedPath = path.split('#').first.split('?').first;
  final extensionIndex = normalizedPath.lastIndexOf('.');
  if (extensionIndex < 0) return '';
  return normalizedPath.substring(extensionIndex).toLowerCase();
}

/// The short uppercase badge shown on a file pill (`PDF`, `ZIP`), or `null`
/// when the file has no extension to badge with.
String? getFileTypeLabel(String path) {
  final extension = getFileExtension(path);
  final label = extension.isEmpty ? '' : extension.substring(1);
  return label.isEmpty ? null : label.toUpperCase();
}

/// The MIME type to send for [path]: a real raster type when the agent can
/// look at the file, and [genericFileMimeType] for everything else.
String getMimeTypeFromPath(String path) =>
    getRasterImageMimeTypeFromPath(path) ?? genericFileMimeType;

/// The raster image MIME type implied by [path]'s extension, or `null` when
/// the extension is unknown or absent.
String? getRasterImageMimeTypeFromPath(String path) =>
    rasterImageMimeTypeByExtension[getFileExtension(path)];

/// Whether [path] names a file the agent can view as an image.
bool isRasterImagePath(String path) =>
    getRasterImageMimeTypeFromPath(path) != null;

/// Whether [mimeType] is a raster image type, tolerating media-type parameters
/// (`image/png; charset=binary`) and the non-standard `image/jpg` spelling.
bool isRasterImageMimeType(String? mimeType) =>
    resolveRasterImageMimeType(mimeType: mimeType) != null;

/// Whether a picked/dropped file is a raster image.
///
/// Upstream takes `Pick<File, "name" | "type">`; there is no `File` in Dart, so
/// the two fields it reads are passed directly. A browser reports an unknown
/// type as `""`, which is why [type] defaults to the empty string rather than
/// `null` — both fall back to the file name either way.
bool isRasterImageFile({required String name, String type = ''}) =>
    resolveRasterImageMimeType(mimeType: type, path: name) != null;

// ---------------------------------------------------------------------------
// utils.ts
// ---------------------------------------------------------------------------

const String _idAlphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

/// A fresh composer-attachment id.
///
/// Shape is frozen (`att_msg_<epochMillis>_<9 base36 chars>`) because ids leak
/// into draft storage keys, so a stored draft written by one build has to stay
/// addressable by the next. [now] and [random] are injectable purely so tests
/// can pin the string.
///
/// Deviation: upstream builds the suffix with
/// `Math.random().toString(36).substring(2, 11)`, which yields *fewer* than
/// nine characters for the rare small random value whose base-36 expansion is
/// short. This port always emits nine, since nothing reads the length back.
String generateAttachmentId({DateTime? now, Random? random}) {
  final clock = now ?? DateTime.now();
  final rng = random ?? Random();
  final suffix = String.fromCharCodes([
    for (var index = 0; index < 9; index += 1)
      _idAlphabet.codeUnitAt(rng.nextInt(_idAlphabet.length)),
  ]);
  return 'att_msg_${clock.millisecondsSinceEpoch}_$suffix';
}

/// The MIME type to record for an attachment whose own metadata is missing.
///
/// JPEG is the fallback rather than [genericFileMimeType] because this only
/// runs on paths that already established the payload is an image (camera
/// captures, pasted screenshots, data URLs), and a wrong-but-renderable type
/// beats an unrenderable one.
String normalizeMimeType(String? input) {
  if (input == null || input.isEmpty) return 'image/jpeg';
  final trimmed = input.trim();
  return trimmed.isNotEmpty ? trimmed : 'image/jpeg';
}

/// The MIME type and base64 payload carried by a `data:` URL.
final class AttachmentDataUrl {
  const AttachmentDataUrl({required this.mimeType, required this.base64});

  final String mimeType;
  final String base64;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is AttachmentDataUrl &&
      other.mimeType == mimeType &&
      other.base64 == base64;

  @override
  int get hashCode => Object.hash(mimeType, base64);

  @override
  String toString() =>
      'AttachmentDataUrl(mimeType: $mimeType, base64Length: ${base64.length})';
}

/// An image `data:` URL plus the compact key used to cache its decoded form.
final class AttachmentImageDataUrl extends AttachmentDataUrl {
  const AttachmentImageDataUrl({
    required super.mimeType,
    required super.base64,
    required this.cacheKey,
  });

  /// A short, collision-resistant stand-in for the whole payload.
  ///
  /// Image caches are keyed by source string; using the data URL itself would
  /// park a megabyte of base64 in a map key for every preview on screen.
  final String cacheKey;

  @override
  bool operator ==(Object other) =>
      other is AttachmentImageDataUrl &&
      other.mimeType == mimeType &&
      other.base64 == this.base64 &&
      other.cacheKey == cacheKey;

  @override
  int get hashCode => Object.hash(mimeType, this.base64, cacheKey);

  @override
  String toString() =>
      'AttachmentImageDataUrl(mimeType: $mimeType, '
      'base64Length: ${this.base64.length}, cacheKey: $cacheKey)';
}

// `i` matches upstream's flag; only the literal `data:` prefix is affected.
final RegExp _dataUrlPattern = RegExp(
  r'^data:([^,]*),([\s\S]+)$',
  caseSensitive: false,
);
final RegExp _whitespacePattern = RegExp(r'\s');

/// Splits a base64 `data:` URL into its MIME type and payload.
///
/// Throws a [FormatException] rather than returning null: every caller that
/// reaches here has already decided the string *is* an attachment payload, so a
/// malformed one is a bug worth surfacing, not a value to skip.
///
/// Deviation: upstream throws `Error`; Dart has no equivalent generic error
/// with a message field that reads well, so [FormatException] carries the
/// identical message strings.
AttachmentDataUrl parseDataUrl(String dataUrl) {
  final match = _dataUrlPattern.firstMatch(dataUrl.trim());
  if (match == null) {
    throw const FormatException('Malformed data URL for attachment.');
  }
  final metadata = match.group(1) ?? '';
  // Whitespace is stripped because data URLs pasted from HTML or wrapped by an
  // editor arrive with newlines inside the payload.
  final base64 = (match.group(2) ?? '').replaceAll(_whitespacePattern, '');
  final parts = [for (final part in metadata.split(';')) part.trim()];
  final isBase64 = parts.skip(1).any((part) => part.toLowerCase() == 'base64');
  if (!isBase64) {
    throw const FormatException('Attachment data URL is not base64 encoded.');
  }
  if (base64.isEmpty) {
    throw const FormatException(
      'Attachment data URL is missing base64 payload.',
    );
  }
  return AttachmentDataUrl(
    mimeType: normalizeMimeType(parts.first),
    base64: base64,
  );
}

/// 32-bit multiply with wraparound, matching JavaScript's `Math.imul`.
///
/// Split into 16-bit halves so the intermediate products stay inside the 53-bit
/// integer range a `dart2js` build actually has.
int _imul32(int a, int b) {
  final aHigh = (a >>> 16) & 0xFFFF;
  final aLow = a & 0xFFFF;
  final bHigh = (b >>> 16) & 0xFFFF;
  final bLow = b & 0xFFFF;
  return (aLow * bLow + (((aHigh * bLow + aLow * bHigh) & 0xFFFF) << 16)) &
      0xFFFFFFFF;
}

/// FNV-1a over UTF-16 code units, rendered base36.
///
/// Not a security hash — it exists to keep cache keys and preview ids short and
/// stable, and the exact digits are frozen so keys survive a rebuild.
String _hashString(String value) {
  var hash = 2166136261;
  for (var index = 0; index < value.length; index += 1) {
    hash = (hash ^ value.codeUnitAt(index)) & 0xFFFFFFFF;
    hash = _imul32(hash, 16777619);
  }
  return hash.toRadixString(36);
}

/// Parses [uri] as a raster image data URL, or returns `null` when it is not
/// one.
///
/// Null rather than throwing: this runs on arbitrary image sources coming out
/// of markdown and tool output, where "not a data URL" is the common case.
/// SVG data URLs return null too, keeping them on the file side of the
/// image/file line drawn by [isRasterImageMimeType].
AttachmentImageDataUrl? parseImageDataUrl(String uri) {
  if (!uri.trim().toLowerCase().startsWith('data:image/')) return null;

  final AttachmentDataUrl parsed;
  try {
    parsed = parseDataUrl(uri);
  } on FormatException {
    return null;
  }
  if (!isRasterImageMimeType(parsed.mimeType)) return null;

  final payload = parsed.base64;
  // Head + tail + length is enough to separate distinct images without walking
  // the whole payload on every cache lookup.
  final head = payload.substring(0, min(64, payload.length));
  final tail = payload.substring(max(0, payload.length - 64));
  final fingerprint =
      '${parsed.mimeType}\u0000${payload.length}\u0000$head\u0000$tail';
  return AttachmentImageDataUrl(
    mimeType: parsed.mimeType,
    base64: payload,
    cacheKey:
        'data-image:${parsed.mimeType}:${payload.length}:'
        '${_hashString(fingerprint)}',
  );
}

/// The cache key for an image source: compact for data URLs, the source itself
/// for ordinary paths and URLs.
String createImageSourceCacheKey(String source) =>
    parseImageDataUrl(source)?.cacheKey ?? source;

final RegExp _trailingSlashesPattern = RegExp(r'/+$');

/// The last path segment of [path], or `null` when there is nothing nameable.
///
/// Backslashes are folded to forward slashes first so a Windows path yields the
/// same name as its POSIX twin, and trailing separators are dropped so a
/// directory-looking path still names its leaf.
String? getFileNameFromPath(String? path) {
  final trimmed = path?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;

  final normalized = trimmed
      .replaceAll(r'\', '/')
      .replaceFirst(_trailingSlashesPattern, '');
  final fileName = normalized.split('/').last.trim();
  return fileName.isEmpty ? null : fileName;
}

/// Renders a number the way JavaScript's `String(n)` would.
///
/// Non-finite and absent values become `''` (upstream's `Number.isFinite`
/// guard), and an integral double loses its `.0` so a size of `1024.0` keys the
/// same preview as an `int` `1024`.
String _finiteNumberToString(num? value) {
  if (value == null || !value.isFinite) return '';
  if (value is double && value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  return value.toString();
}

/// A stable id for an attachment that only exists as a preview.
///
/// Preview attachments have no store record to take an id from, so identity is
/// derived from the metadata a preview *does* know. Keeping it deterministic is
/// what stops a re-render from re-adding the same pill.
String createPreviewAttachmentId({
  required String mimeType,
  String? path,
  num? size,
  String? modifiedAt,
  num? contentLength,
}) {
  final normalizedPath = path?.trim() ?? '';
  final normalizedSize = _finiteNumberToString(size);
  final normalizedModifiedAt = modifiedAt?.trim() ?? '';
  final normalizedContentLength = _finiteNumberToString(contentLength);
  final hash = _hashString(
    '$mimeType\u0000$normalizedPath\u0000$normalizedSize'
    '\u0000$normalizedModifiedAt\u0000$normalizedContentLength',
  );
  final label = normalizedSize.isNotEmpty
      ? normalizedSize
      : (normalizedContentLength.isNotEmpty
            ? normalizedContentLength
            : 'unknown');
  return 'preview_${label}_$hash';
}

/// Base64-encodes attachment bytes for the wire.
///
/// Deviation: upstream reads a `Blob` through `FileReader` and slices the
/// base64 out of the resulting data URL. Dart has neither type, so this takes
/// the bytes directly. The one observable behaviour that survives is the empty
/// case: an empty blob produces a data URL with no payload, which upstream
/// rejects, so empty bytes throw here with the same message instead of
/// returning `''`.
Future<String> attachmentBytesToBase64(Uint8List bytes) async {
  if (bytes.isEmpty) {
    throw StateError(
      'Attachment FileReader result did not contain base64 payload.',
    );
  }
  return base64Encode(bytes);
}

/// Converts a local path to a `file://` URI, leaving anything that is not an
/// absolute local path untouched.
///
/// Relative paths pass through unchanged rather than being resolved: this runs
/// on strings harvested from agent output, where a relative path is far more
/// likely to be prose than a file the app should point at.
String pathToFileUri(String path) {
  if (path.startsWith('file://')) return path;
  if (!isAbsolutePath(path)) return path;
  if (path.startsWith('/')) return 'file://$path';
  // UNC share: \\server\share -> file://server/share, where the host component
  // of the URI is the SMB server.
  if (path.startsWith(r'\\')) return 'file:${path.replaceAll(r'\', '/')}';
  return 'file:///${path.replaceAll(r'\', '/')}';
}

String _decodeFilePathSource(String source) {
  try {
    return Uri.decodeComponent(source);
  } on ArgumentError {
    // A lone `%` is a literal in a plain path but malformed as an escape.
    // Upstream swallows the same `URIError` and keeps the raw text.
    return source;
  } on FormatException {
    return source;
  }
}

final RegExp _windowsDrivePrefixPattern = RegExp(r'^[A-Za-z]:[\\/]');
final RegExp _leadingSlashDrivePattern = RegExp(r'^/([A-Za-z]:[\\/])');
final RegExp _markdownEncodedDrivePattern = RegExp(
  r'^[A-Za-z]:(?:%5[Cc]|%2[Ff])',
);

/// Windows paths are normalised to forward slashes so one spelling reaches the
/// daemon regardless of whether the path came from a URI or from the OS.
String _normalizeWindowsDrivePath(String path) =>
    _windowsDrivePrefixPattern.hasMatch(path)
    ? path.replaceAll(r'\', '/')
    : path;

/// The inverse of [pathToFileUri].
///
/// A `file://` URI with a non-empty host is a UNC share and comes back with
/// backslashes, because that is the only spelling Windows APIs accept for one.
String fileUriToPath(String uri) {
  if (!uri.startsWith('file://')) return uri;
  final fileSource = uri.substring('file://'.length);
  final decodedPath = _decodeFilePathSource(fileSource);
  if (!fileSource.startsWith('/')) {
    return '\\\\${decodedPath.replaceAll('/', r'\')}';
  }
  return _normalizeWindowsDrivePath(
    decodedPath.replaceFirstMapped(
      _leadingSlashDrivePattern,
      (match) => match.group(1)!,
    ),
  );
}

/// Resolves whatever a local-file reference looks like in the wild to a path.
///
/// Only two shapes are decoded: a real `file://` URI, and a Windows drive path
/// whose separators a markdown renderer percent-escaped. Everything else is
/// left byte-for-byte, so `/tmp/a%20b.png` keeps its literal `%20` — on POSIX
/// that is a legal file name and decoding it would point at the wrong file.
String localFileSourceToPath(String source) {
  var path = source;
  if (source.startsWith('file://')) {
    path = fileUriToPath(source);
  } else if (_markdownEncodedDrivePattern.hasMatch(source)) {
    path = _decodeFilePathSource(source);
  }
  return _normalizeWindowsDrivePath(path);
}

/// The extension of a bare file name, including the dot and *preserving case*.
///
/// Distinct from [getFileExtension] on purpose: this feeds "save as" dialogs
/// and download names, where lowercasing a user's `Report.PDF` would be a
/// visible change. A dotfile (`.env`) and a trailing dot (`archive.`) both
/// yield `''` — neither has an extension to speak of.
String getFileExtensionFromName(String? fileName) {
  if (fileName == null || fileName.isEmpty) return '';
  final index = fileName.lastIndexOf('.');
  if (index <= 0 || index == fileName.length - 1) return '';
  return fileName.substring(index);
}

// ---------------------------------------------------------------------------
// workspace-attachment-utils.ts
// ---------------------------------------------------------------------------

/// The composer attachment kinds that carry pull-request context.
///
/// Both spellings are live: `forge.*` is the current, provider-neutral naming
/// and `github.*` is the pre-forge one, still produced by older daemons whose
/// payloads a current app has to keep understanding.
const Set<String> pullRequestContextAttachmentKinds = {
  'forge.change_request_comment',
  'forge.change_request_review',
  'forge.change_request_check',
  'github.pull_request_comment',
  'github.pull_request_review',
  'github.pull_request_check',
};

/// The composer attachment kinds the *workspace* contributes rather than the
/// user.
const Set<String> workspaceAttachmentKinds = {
  'review',
  'browser_element',
  'chat_history',
  ...pullRequestContextAttachmentKinds,
};

/// Whether [kind] is a pull-request context pill.
///
/// Upstream is a type guard over `ComposerAttachment | undefined`; the app
/// models composer attachments with a string `kind`
/// (`WorkspaceContextAttachment.kind`), so the discriminant is passed directly
/// and a missing attachment is `null`.
bool isPullRequestContextAttachmentKind(String? kind) =>
    kind != null && pullRequestContextAttachmentKinds.contains(kind);

/// Whether [kind] is any workspace-contributed pill.
bool isWorkspaceAttachmentKind(String? kind) =>
    kind != null && workspaceAttachmentKinds.contains(kind);

/// Keeps only the attachments the user themselves added.
///
/// Workspace pills are re-derived from live state on every render, so persisting
/// or resubmitting them would resurrect context the user already dismissed.
/// [kindOf] reads the discriminant so a caller can pass its own attachment type
/// without this module depending on it.
List<T> userAttachmentsOnly<T>(
  Iterable<T> attachments, {
  required String Function(T attachment) kindOf,
}) => List.unmodifiable([
  for (final attachment in attachments)
    if (!isWorkspaceAttachmentKind(kindOf(attachment))) attachment,
]);

// ---------------------------------------------------------------------------
// hooks/picked-image-normalizer.ts
// ---------------------------------------------------------------------------

/// Where the bytes of a picked image live.
sealed class PickedImageSource {
  const PickedImageSource();
}

/// A file the OS picker handed back by URI; bytes are read later, on demand.
final class FileUriPickedImageSource extends PickedImageSource {
  const FileUriPickedImageSource(this.uri);

  final String uri;

  @override
  bool operator ==(Object other) =>
      other is FileUriPickedImageSource && other.uri == uri;

  @override
  int get hashCode => uri.hashCode;

  @override
  String toString() => 'FileUriPickedImageSource($uri)';
}

/// In-memory bytes.
///
/// Deviation: upstream's variant holds a web `Blob`. Dart's equivalent for an
/// already-materialised payload is the byte list itself.
final class BytesPickedImageSource extends PickedImageSource {
  const BytesPickedImageSource(this.bytes);

  final Uint8List bytes;

  @override
  bool operator ==(Object other) =>
      other is BytesPickedImageSource &&
      other.bytes.length == bytes.length &&
      _sameBytes(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  static bool _sameBytes(Uint8List a, Uint8List b) {
    for (var index = 0; index < a.length; index += 1) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  @override
  String toString() => 'BytesPickedImageSource(${bytes.length} bytes)';
}

/// One image, normalised to a format the agent can actually receive.
final class PickedImageAttachmentInput {
  const PickedImageAttachmentInput({
    required this.source,
    required this.mimeType,
    this.fileName,
  });

  final PickedImageSource source;
  final String mimeType;

  /// `null` when the picker gave no name — the attachment store then falls back
  /// to its own id rather than inventing one here.
  final String? fileName;

  @override
  bool operator ==(Object other) =>
      other is PickedImageAttachmentInput &&
      other.source == source &&
      other.mimeType == mimeType &&
      other.fileName == fileName;

  @override
  int get hashCode => Object.hash(source, mimeType, fileName);

  @override
  String toString() =>
      'PickedImageAttachmentInput(source: $source, mimeType: $mimeType, '
      'fileName: $fileName)';
}

/// What a native image picker reports about one selected asset.
///
/// Deviation: upstream's `ExpoImagePickerAssetLike` also carries an optional
/// web `File`; the normalizer never reads it, so it is omitted here.
final class PickedImageAsset {
  const PickedImageAsset({required this.uri, this.mimeType, this.fileName});

  final String uri;
  final String? mimeType;
  final String? fileName;
}

/// Re-encodes the image at [uri] as PNG and returns the new URI.
///
/// Injected rather than imported so this rule stays testable without the
/// platform image manipulator.
typedef ExportPickedImageAsPng = Future<String> Function(String uri);

enum _SupportedPickedImageFormat {
  jpeg('image/jpeg', 'jpg'),
  png('image/png', 'png');

  const _SupportedPickedImageFormat(this.mimeType, this.extension);

  final String mimeType;
  final String extension;
}

final RegExp _pickedExtensionPattern = RegExp(
  r'\.([a-z0-9]+)(?:[?#].*)?$',
  caseSensitive: false,
);

String? _extensionFromPath(String? path) {
  if (path == null) return null;
  return _pickedExtensionPattern.firstMatch(path)?.group(1)?.toLowerCase();
}

_SupportedPickedImageFormat? _formatForExtension(String? extension) =>
    switch (extension) {
      'jpg' || 'jpeg' => _SupportedPickedImageFormat.jpeg,
      'png' => _SupportedPickedImageFormat.png,
      _ => null,
    };

_SupportedPickedImageFormat? _formatForMimeType(String? mimeType) =>
    switch (mimeType?.toLowerCase()) {
      'image/jpeg' || 'image/jpg' => _SupportedPickedImageFormat.jpeg,
      'image/png' => _SupportedPickedImageFormat.png,
      _ => null,
    };

_SupportedPickedImageFormat? _supportedFormatFor(PickedImageAsset asset) {
  final uriExtension = _extensionFromPath(asset.uri);
  final uriFormat = _formatForExtension(uriExtension);
  // A URI that names an unsupported container (HEIC, WebP) is decisive even
  // when the picker also claims `image/png`: iOS reports the *display* type,
  // not the on-disk one, so trusting it would ship an undecodable file.
  if (uriExtension != null && uriFormat == null) return null;

  return _formatForMimeType(asset.mimeType) ??
      _formatForExtension(_extensionFromPath(asset.fileName)) ??
      uriFormat;
}

final RegExp _fileNameExtensionPattern = RegExp(r'\.[^./\\]+$');

String? _replaceFileExtension(String? fileName, String extension) {
  if (fileName == null || fileName.isEmpty) return null;
  return '${fileName.replaceFirst(_fileNameExtensionPattern, '')}.$extension';
}

/// Normalises picked images to JPEG or PNG, converting anything else.
///
/// Only these two formats survive the trip to every agent provider, so a HEIC
/// or WebP pick is re-encoded here rather than failing at send time. The
/// reported file name is rewritten to match the format actually sent, so the
/// pill never claims `.heic` for PNG bytes.
Future<List<PickedImageAttachmentInput>> normalizePickedImageAssetsWith(
  Iterable<PickedImageAsset> assets,
  ExportPickedImageAsPng exportAsPng,
) async {
  return Future.wait([
    for (final asset in assets) _normalizePickedImageAsset(asset, exportAsPng),
  ]);
}

Future<PickedImageAttachmentInput> _normalizePickedImageAsset(
  PickedImageAsset asset,
  ExportPickedImageAsPng exportAsPng,
) async {
  final supportedFormat = _supportedFormatFor(asset);
  if (supportedFormat != null) {
    return PickedImageAttachmentInput(
      source: FileUriPickedImageSource(asset.uri),
      mimeType: supportedFormat.mimeType,
      fileName: _replaceFileExtension(
        asset.fileName,
        supportedFormat.extension,
      ),
    );
  }

  final convertedUri = await exportAsPng(asset.uri);
  return PickedImageAttachmentInput(
    source: FileUriPickedImageSource(convertedUri),
    mimeType: _SupportedPickedImageFormat.png.mimeType,
    fileName: _replaceFileExtension(
      asset.fileName,
      _SupportedPickedImageFormat.png.extension,
    ),
  );
}
