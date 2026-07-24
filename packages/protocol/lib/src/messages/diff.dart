/// Structured diff messages: the daemon parses `git diff` output and ships
/// structured hunks so clients never parse unified diffs themselves.
library;

enum DiffFileStatus { added, modified, deleted, renamed }

enum DiffLineType { context, add, del }

final class DiffLine {
  const DiffLine({
    required this.type,
    required this.text,
    this.oldLineNo,
    this.newLineNo,
  });

  final DiffLineType type;
  final String text;
  final int? oldLineNo;
  final int? newLineNo;

  static DiffLine fromJson(Map<String, Object?> json) => DiffLine(
        type: DiffLineType.values.byName((json['type'] as String?) ?? 'context'),
        text: (json['text'] as String?) ?? '',
        oldLineNo: (json['oldLineNo'] as num?)?.toInt(),
        newLineNo: (json['newLineNo'] as num?)?.toInt(),
      );

  Map<String, Object?> toJson() => {
        'type': type.name,
        'text': text,
        if (oldLineNo != null) 'oldLineNo': oldLineNo,
        if (newLineNo != null) 'newLineNo': newLineNo,
      };
}

final class DiffHunk {
  const DiffHunk({required this.header, required this.lines});

  final String header;
  final List<DiffLine> lines;

  static DiffHunk fromJson(Map<String, Object?> json) => DiffHunk(
        header: (json['header'] as String?) ?? '',
        lines: ((json['lines'] as List?) ?? const [])
            .cast<Map<String, Object?>>()
            .map(DiffLine.fromJson)
            .toList(),
      );

  Map<String, Object?> toJson() => {
        'header': header,
        'lines': lines.map((l) => l.toJson()).toList(),
      };
}

final class DiffFile {
  const DiffFile({
    required this.path,
    required this.status,
    this.oldPath,
    this.binary = false,
    this.additions = 0,
    this.deletions = 0,
    this.hunks = const [],
  });

  final String path;
  final DiffFileStatus status;
  final String? oldPath;
  final bool binary;
  final int additions;
  final int deletions;
  final List<DiffHunk> hunks;

  static DiffFile fromJson(Map<String, Object?> json) => DiffFile(
        path: json['path'] as String,
        status: DiffFileStatus.values
            .byName((json['status'] as String?) ?? 'modified'),
        oldPath: json['oldPath'] as String?,
        binary: (json['binary'] as bool?) ?? false,
        additions: (json['additions'] as num?)?.toInt() ?? 0,
        deletions: (json['deletions'] as num?)?.toInt() ?? 0,
        hunks: ((json['hunks'] as List?) ?? const [])
            .cast<Map<String, Object?>>()
            .map(DiffHunk.fromJson)
            .toList(),
      );

  Map<String, Object?> toJson() => {
        'path': path,
        'status': status.name,
        if (oldPath != null) 'oldPath': oldPath,
        'binary': binary,
        'additions': additions,
        'deletions': deletions,
        'hunks': hunks.map((h) => h.toJson()).toList(),
      };
}

/// Response of `diff.get.request` (payload: `{cwd, baseRef?}`).
/// Without baseRef: working tree vs HEAD, untracked files included as added.
final class DiffResponse {
  const DiffResponse({required this.files});

  final List<DiffFile> files;

  static DiffResponse fromJson(Map<String, Object?> json) => DiffResponse(
        files: ((json['files'] as List?) ?? const [])
            .cast<Map<String, Object?>>()
            .map(DiffFile.fromJson)
            .toList(),
      );

  Map<String, Object?> toJson() =>
      {'files': files.map((f) => f.toJson()).toList()};
}
