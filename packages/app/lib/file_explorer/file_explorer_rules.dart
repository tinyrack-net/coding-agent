/// Port of Paseo 0.2.0's `file-explorer/visibility.ts`,
/// `file-explorer/read-result.ts` and `components/file-pane-enabled.ts`.
///
/// Three pure decisions the file explorer makes, collected here because they
/// are the only stateless rules in that feature and are all exercised by the
/// same widgets:
///
/// * **Which entries are visible.** Dot-prefixed names are hidden unless the
///   user opted into hidden files, and a path is "hidden" when *any* segment
///   is dot-prefixed — so `src/.cache/output.json` is hidden even though its
///   own file name is not. `.` and `..` are relative-path navigation, not
///   hidden entries, so they are exempt.
/// * **How a raw daemon file read becomes a displayable file.** Only `text`
///   reads carry decoded content; the leading UTF-8 BOM is stripped for
///   display but recorded, so a later write can restore the file's original
///   bytes instead of silently dropping the BOM.
/// * **Whether the file pane should read right now.** Gating the read on
///   visibility makes a revisited tab refetch rather than show the frozen
///   first-load snapshot.
library;

import 'dart:convert';
import 'dart:typed_data';

/// What a directory listing entry is. Port of TS `ExplorerEntryKind`.
enum ExplorerEntryKind {
  file('file'),
  directory('directory');

  const ExplorerEntryKind(this.wireValue);

  /// The string the daemon wire protocol uses for this kind.
  final String wireValue;
}

/// How the daemon classified a file it read. Port of TS `ExplorerFileKind`.
enum ExplorerFileKind {
  text('text'),
  image('image'),
  binary('binary');

  const ExplorerFileKind(this.wireValue);

  /// The string the daemon wire protocol uses for this kind.
  final String wireValue;
}

/// How [ExplorerFile.content] is encoded. Port of TS `ExplorerEncoding`.
///
/// [base64] exists in the upstream union for stored explorer state but is
/// never produced by [explorerFileFromReadResult]: a non-text read keeps its
/// bytes elsewhere and reports [none].
enum ExplorerEncoding {
  utf8('utf-8'),
  base64('base64'),
  none('none');

  const ExplorerEncoding(this.wireValue);

  /// The string the daemon wire protocol uses for this encoding.
  final String wireValue;
}

/// One entry in a directory listing. Port of TS `ExplorerEntry`.
final class ExplorerEntry {
  const ExplorerEntry({
    required this.name,
    required this.path,
    required this.kind,
    required this.size,
    required this.modifiedAt,
  });

  /// The entry's own name, with no directory part.
  final String name;

  /// The entry's path relative to the workspace root.
  final String path;

  final ExplorerEntryKind kind;

  final int size;

  /// ISO-8601 timestamp, carried through verbatim from the daemon rather than
  /// parsed: the explorer only ever displays or re-sends it.
  final String modifiedAt;

  @override
  bool operator ==(Object other) =>
      other is ExplorerEntry &&
      other.name == name &&
      other.path == path &&
      other.kind == kind &&
      other.size == size &&
      other.modifiedAt == modifiedAt;

  @override
  int get hashCode => Object.hash(name, path, kind, size, modifiedAt);

  @override
  String toString() =>
      'ExplorerEntry(name: $name, path: $path, kind: $kind, size: $size, '
      'modifiedAt: $modifiedAt)';
}

/// A file prepared for display in the explorer. Port of TS `ExplorerFile`.
final class ExplorerFile {
  const ExplorerFile({
    required this.path,
    required this.kind,
    required this.encoding,
    required this.content,
    required this.hasBom,
    required this.mimeType,
    required this.size,
    required this.modifiedAt,
  });

  final String path;

  final ExplorerFileKind kind;

  final ExplorerEncoding encoding;

  /// Decoded text, or `null` for non-text reads (upstream leaves the field
  /// `undefined` in that case).
  final String? content;

  /// Whether the source bytes started with a UTF-8 BOM. Decoding removes the
  /// BOM, so this bit is retained to let file writes restore it.
  final bool hasBom;

  final String? mimeType;

  final int size;

  /// ISO-8601 timestamp, carried through verbatim from the daemon.
  final String modifiedAt;

  @override
  bool operator ==(Object other) =>
      other is ExplorerFile &&
      other.path == path &&
      other.kind == kind &&
      other.encoding == encoding &&
      other.content == content &&
      other.hasBom == hasBom &&
      other.mimeType == mimeType &&
      other.size == size &&
      other.modifiedAt == modifiedAt;

  @override
  int get hashCode => Object.hash(
    path,
    kind,
    encoding,
    content,
    hasBom,
    mimeType,
    size,
    modifiedAt,
  );

  @override
  String toString() =>
      'ExplorerFile(path: $path, kind: $kind, encoding: $encoding, '
      'content: $content, hasBom: $hasBom, mimeType: $mimeType, size: $size, '
      'modifiedAt: $modifiedAt)';
}

/// A raw file read as returned by the daemon client. Port of the TS
/// `FileReadResult` interface from `client/internal/daemon-client`.
final class FileReadResult {
  const FileReadResult({
    required this.bytes,
    required this.mime,
    required this.size,
    required this.path,
    required this.kind,
    required this.modifiedAt,
    this.revision,
  });

  final Uint8List bytes;

  final String mime;

  final int size;

  final String path;

  final ExplorerFileKind kind;

  /// ISO-8601 timestamp, carried through verbatim from the daemon.
  final String modifiedAt;

  final String? revision;
}

/// Whether [path] lives at or under a dot-prefixed segment.
///
/// Segments are split on `/` because explorer paths are always workspace
/// relative and POSIX separated, regardless of host platform. `.` and `..`
/// are relative-navigation segments, not hidden names, so they never make a
/// path hidden.
bool isHiddenExplorerPath(String path) {
  return path
      .split('/')
      .any(
        (segment) =>
            segment != '.' && segment != '..' && segment.startsWith('.'),
      );
}

/// Drops dot-prefixed entries unless the user turned hidden files on.
///
/// Only the entry's own [ExplorerEntry.name] is checked, not its full path:
/// listings are already scoped to one directory, so an entry inside a hidden
/// directory the user explicitly navigated into stays visible.
List<ExplorerEntry> filterVisibleExplorerEntries(
  List<ExplorerEntry> entries, {
  required bool showHiddenFiles,
}) {
  if (showHiddenFiles) {
    return entries;
  }
  return entries.where((entry) => !entry.name.startsWith('.')).toList();
}

/// Converts a daemon file read into the explorer's display model.
///
/// Only `text` reads get decoded content and a `utf-8` encoding; image and
/// binary reads report `none` and leave [ExplorerFile.content] null, keeping
/// their bytes with the caller.
ExplorerFile explorerFileFromReadResult(FileReadResult file) {
  final isText = file.kind == ExplorerFileKind.text;
  return ExplorerFile(
    path: file.path,
    kind: file.kind,
    encoding: isText ? ExplorerEncoding.utf8 : ExplorerEncoding.none,
    content: isText ? _decodeUtf8(file.bytes) : null,
    hasBom: isText && _hasUtf8Bom(file.bytes),
    mimeType: file.mime,
    size: file.size,
    modifiedAt: file.modifiedAt,
  );
}

/// Whether [input] should be read right now.
///
/// The read is gated on visibility so a revisited tab refetches instead of
/// showing the frozen first-load snapshot: the pane re-runs its read on the
/// disabled -> enabled transition. Read only when there is something to read
/// AND the pane can actually show it — the tab is the active one (not a
/// mounted-but-offscreen tab) and the whole app is in the foreground.
bool isFileQueryEnabled({
  required bool hasReadTarget,
  required bool isTabActive,
  required bool isAppVisible,
}) {
  return hasReadTarget && isTabActive && isAppVisible;
}

/// Mirrors the browser `TextDecoder("utf-8")` upstream relies on, which Dart's
/// [utf8] codec does not match on its own: `TextDecoder` strips one leading
/// BOM and substitutes U+FFFD for malformed bytes instead of throwing.
String _decodeUtf8(Uint8List bytes) {
  final body = _hasUtf8Bom(bytes) ? bytes.sublist(3) : bytes;
  return utf8.decode(body, allowMalformed: true);
}

/// Only a BOM at offset 0 counts; a U+FEFF elsewhere in the file is ordinary
/// content and must not be reported as a BOM.
bool _hasUtf8Bom(Uint8List bytes) {
  return bytes.length >= 3 &&
      bytes[0] == 0xef &&
      bytes[1] == 0xbb &&
      bytes[2] == 0xbf;
}
