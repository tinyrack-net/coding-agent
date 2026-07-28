/// File read/write/edit tools, sandboxed to the agent's working directory.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'tool_exception.dart';

/// Resolves [rawPath] against [cwd], rejecting anything that escapes it
/// (`..` traversal, absolute paths outside cwd, symlinks notwithstanding —
/// mirrors the containment check in `GitService`).
String resolveSandboxedPath(String cwd, String rawPath) {
  final normalizedCwd = p.normalize(p.absolute(cwd));
  final candidate = p.isAbsolute(rawPath)
      ? rawPath
      : p.join(normalizedCwd, rawPath);
  final normalizedCandidate = p.normalize(p.absolute(candidate));
  final rel = p.relative(normalizedCandidate, from: normalizedCwd);
  if (rel == '..' || rel.startsWith('..${p.separator}')) {
    throw ToolExecutionException(
      'path "$rawPath" escapes the working directory',
    );
  }
  return normalizedCandidate;
}

Future<String> readFile(String cwd, String path) async {
  final resolved = resolveSandboxedPath(cwd, path);
  final file = File(resolved);
  if (!file.existsSync()) {
    throw ToolExecutionException('file not found: $path');
  }
  return file.readAsString();
}

Future<void> writeFile(String cwd, String path, String content) async {
  final resolved = resolveSandboxedPath(cwd, path);
  final file = File(resolved);
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

/// Replaces the sole occurrence of [oldString] with [newString] in [path].
/// Throws if the file doesn't exist, [oldString] isn't found, or it isn't
/// unique (ambiguous edits are rejected rather than guessed at).
Future<void> editFile(
  String cwd,
  String path,
  String oldString,
  String newString,
) async {
  final resolved = resolveSandboxedPath(cwd, path);
  final file = File(resolved);
  if (!file.existsSync()) {
    throw ToolExecutionException('file not found: $path');
  }
  final original = await file.readAsString();
  final occurrences = original.split(oldString).length - 1;
  if (occurrences == 0) {
    throw ToolExecutionException('old_string not found in $path');
  }
  if (occurrences > 1) {
    throw ToolExecutionException(
      'old_string is not unique in $path ($occurrences matches)',
    );
  }
  await file.writeAsString(original.replaceFirst(oldString, newString));
}

/// A minimal +/- line diff for display — not a full unified diff (no hunk
/// headers/context), which the `timeline_item_tile` renderer doesn't require.
String simpleDiff(String oldString, String newString) {
  final buffer = StringBuffer();
  for (final line in oldString.split('\n')) {
    buffer.writeln('-$line');
  }
  for (final line in newString.split('\n')) {
    buffer.writeln('+$line');
  }
  return buffer.toString().trimRight();
}
