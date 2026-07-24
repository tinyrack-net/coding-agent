/// Pure parser turning `git diff` unified output into structured [DiffFile]s.
library;

import 'package:agent_protocol/agent_protocol.dart';

/// Parses the output of `git diff --no-color` (any number of files) into
/// structured [DiffFile] records with per-line old/new numbers.
List<DiffFile> parseUnifiedDiff(String diffOutput) {
  final lines = diffOutput.split('\n');
  final files = <DiffFile>[];
  _FileBuilder? current;

  void finish() {
    if (current != null) {
      files.add(current!.build());
      current = null;
    }
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];

    if (line.startsWith('diff --git ')) {
      finish();
      current = _FileBuilder();
      final paths = _parseDiffGitPaths(line);
      current!.gitOldPath = paths.$1;
      current!.gitNewPath = paths.$2;
      i++;
      continue;
    }

    final file = current;
    if (file == null) {
      i++; // Preamble noise (shouldn't normally happen).
      continue;
    }

    if (line.startsWith('@@ ')) {
      final hunk = _parseHunkHeader(line);
      if (hunk == null) {
        i++;
        continue;
      }
      var oldNo = hunk.oldStart;
      var newNo = hunk.newStart;
      final hunkLines = <DiffLine>[];
      i++;
      while (i < lines.length) {
        final l = lines[i];
        if (l.startsWith('diff --git ') || l.startsWith('@@ ')) break;
        if (l.startsWith('\\')) {
          // "\ No newline at end of file" — metadata, not content.
          i++;
          continue;
        }
        if (l.startsWith('+')) {
          hunkLines.add(DiffLine(
            type: DiffLineType.add,
            text: l.substring(1),
            newLineNo: newNo++,
          ));
          file.additions++;
        } else if (l.startsWith('-')) {
          hunkLines.add(DiffLine(
            type: DiffLineType.del,
            text: l.substring(1),
            oldLineNo: oldNo++,
          ));
          file.deletions++;
        } else if (l.startsWith(' ')) {
          hunkLines.add(DiffLine(
            type: DiffLineType.context,
            text: l.substring(1),
            oldLineNo: oldNo++,
            newLineNo: newNo++,
          ));
        } else if (l.isEmpty) {
          // Either a truly empty context line (rare; git emits ' ') or the
          // trailing newline of the whole output. Treat as end-of-hunk only
          // when we've consumed the declared counts.
          if (oldNo - hunk.oldStart >= hunk.oldCount &&
              newNo - hunk.newStart >= hunk.newCount) {
            break;
          }
          hunkLines.add(DiffLine(
            type: DiffLineType.context,
            text: '',
            oldLineNo: oldNo++,
            newLineNo: newNo++,
          ));
        } else {
          break; // Unknown line — end of hunk.
        }
        i++;
      }
      file.hunks.add(DiffHunk(header: line, lines: hunkLines));
      continue;
    }

    if (line.startsWith('new file mode')) {
      file.isNew = true;
    } else if (line.startsWith('deleted file mode')) {
      file.isDeleted = true;
    } else if (line.startsWith('rename from ')) {
      file.renameFrom = _unquotePath(line.substring('rename from '.length));
    } else if (line.startsWith('rename to ')) {
      file.renameTo = _unquotePath(line.substring('rename to '.length));
    } else if (line.startsWith('copy from ')) {
      file.renameFrom = _unquotePath(line.substring('copy from '.length));
    } else if (line.startsWith('copy to ')) {
      file.renameTo = _unquotePath(line.substring('copy to '.length));
    } else if (line.startsWith('Binary files ') && line.endsWith(' differ')) {
      file.binary = true;
    } else if (line.startsWith('GIT binary patch')) {
      file.binary = true;
    } else if (line.startsWith('--- ')) {
      final path = _stripPrefix(_unquotePath(line.substring(4)));
      if (path != null) file.minusPath = path;
    } else if (line.startsWith('+++ ')) {
      final path = _stripPrefix(_unquotePath(line.substring(4)));
      if (path != null) file.plusPath = path;
    }
    // similarity index / index / mode lines carry nothing we need.
    i++;
  }
  finish();
  return files;
}

final class _HunkRange {
  const _HunkRange(this.oldStart, this.oldCount, this.newStart, this.newCount);
  final int oldStart;
  final int oldCount;
  final int newStart;
  final int newCount;
}

final _hunkRe = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@');

_HunkRange? _parseHunkHeader(String line) {
  final m = _hunkRe.firstMatch(line);
  if (m == null) return null;
  return _HunkRange(
    int.parse(m.group(1)!),
    m.group(2) == null ? 1 : int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    m.group(4) == null ? 1 : int.parse(m.group(4)!),
  );
}

/// Strips the `a/` or `b/` prefix; returns null for `/dev/null`.
String? _stripPrefix(String path) {
  if (path == '/dev/null') return null;
  if (path.startsWith('a/') || path.startsWith('b/')) {
    return path.substring(2);
  }
  return path;
}

/// Decodes a C-style quoted git path (`"a b\\c"`). With
/// `core.quotepath=false` quoting only occurs for control chars/quotes.
String _unquotePath(String raw) {
  var s = raw.trim();
  if (s.length < 2 || !s.startsWith('"') || !s.endsWith('"')) return s;
  s = s.substring(1, s.length - 1);
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c != r'\' || i + 1 >= s.length) {
      out.write(c);
      i++;
      continue;
    }
    final n = s[i + 1];
    switch (n) {
      case 'n':
        out.write('\n');
        i += 2;
      case 't':
        out.write('\t');
        i += 2;
      case 'r':
        out.write('\r');
        i += 2;
      case '"':
        out.write('"');
        i += 2;
      case r'\':
        out.write(r'\');
        i += 2;
      default:
        // Octal escape \NNN
        final m = RegExp(r'^\\([0-7]{1,3})').firstMatch(s.substring(i));
        if (m != null) {
          out.writeCharCode(int.parse(m.group(1)!, radix: 8));
          i += 1 + m.group(1)!.length;
        } else {
          out.write(n);
          i += 2;
        }
    }
  }
  return out.toString();
}

/// Best-effort extraction of (oldPath, newPath) from a `diff --git a/x b/y`
/// line. Only used as a fallback when no `---`/`+++`/rename headers exist
/// (e.g. binary files, mode-only changes).
(String?, String?) _parseDiffGitPaths(String line) {
  var rest = line.substring('diff --git '.length).trim();
  if (rest.startsWith('"')) {
    // Quoted paths: "a/x" "b/y"
    final m = RegExp(r'^("(?:[^"\\]|\\.)*")\s+("(?:[^"\\]|\\.)*")$')
        .firstMatch(rest);
    if (m != null) {
      return (
        _stripPrefix(_unquotePath(m.group(1)!)),
        _stripPrefix(_unquotePath(m.group(2)!)),
      );
    }
    return (null, null);
  }
  // Unquoted: split at the last occurrence of ' b/' — ambiguous only for
  // pathological names containing that substring.
  final idx = rest.lastIndexOf(' b/');
  if (idx < 0) return (null, null);
  final oldRaw = rest.substring(0, idx);
  final newRaw = rest.substring(idx + 1);
  return (_stripPrefix(oldRaw), _stripPrefix(newRaw));
}

final class _FileBuilder {
  String? gitOldPath;
  String? gitNewPath;
  String? minusPath;
  String? plusPath;
  String? renameFrom;
  String? renameTo;
  bool isNew = false;
  bool isDeleted = false;
  bool binary = false;
  int additions = 0;
  int deletions = 0;
  final List<DiffHunk> hunks = [];

  DiffFile build() {
    final DiffFileStatus status;
    if (renameFrom != null && renameTo != null) {
      status = DiffFileStatus.renamed;
    } else if (isNew) {
      status = DiffFileStatus.added;
    } else if (isDeleted) {
      status = DiffFileStatus.deleted;
    } else {
      status = DiffFileStatus.modified;
    }

    final String path;
    String? oldPath;
    switch (status) {
      case DiffFileStatus.renamed:
        path = renameTo!;
        oldPath = renameFrom;
      case DiffFileStatus.deleted:
        path = minusPath ?? gitOldPath ?? gitNewPath ?? '';
      case DiffFileStatus.added:
      case DiffFileStatus.modified:
        path = plusPath ?? minusPath ?? gitNewPath ?? gitOldPath ?? '';
    }

    return DiffFile(
      path: path,
      status: status,
      oldPath: oldPath,
      binary: binary,
      additions: additions,
      deletions: deletions,
      hunks: List.unmodifiable(hunks),
    );
  }
}
