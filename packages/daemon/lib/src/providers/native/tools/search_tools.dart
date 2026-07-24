/// grep/glob search tools, scoped to the agent's working directory.
library;

import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'fs_tools.dart';
import 'tool_exception.dart';

const _excludedDirs = {'.git', '.dart_tool', 'build', 'node_modules', '.idea'};
const _maxMatches = 200;

bool _isExcluded(String cwd, String path) =>
    p.split(p.relative(path, from: cwd)).any(_excludedDirs.contains);

Future<String> grepSearch(String cwd, String pattern, {String? path}) async {
  final root =
      Directory(path == null ? cwd : resolveSandboxedPath(cwd, path));
  if (!root.existsSync()) {
    throw ToolExecutionException('path not found: ${path ?? '.'}');
  }
  final RegExp regex;
  try {
    regex = RegExp(pattern);
  } catch (e) {
    throw ToolExecutionException('invalid regular expression: $e');
  }

  final matches = <String>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (matches.length >= _maxMatches) break;
    if (entity is! File || _isExcluded(cwd, entity.path)) continue;
    String content;
    try {
      content = await entity.readAsString();
    } catch (_) {
      continue; // binary or unreadable
    }
    final lines = content.split('\n');
    for (var i = 0; i < lines.length && matches.length < _maxMatches; i++) {
      if (regex.hasMatch(lines[i])) {
        matches.add('${p.relative(entity.path, from: cwd)}:${i + 1}: '
            '${lines[i].trim()}');
      }
    }
  }
  return matches.isEmpty ? 'no matches' : matches.join('\n');
}

Future<String> globSearch(String cwd, String pattern) async {
  final Glob glob;
  try {
    glob = Glob(pattern);
  } catch (e) {
    throw ToolExecutionException('invalid glob pattern: $e');
  }

  final root = Directory(cwd);
  final matches = <String>[];
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (matches.length >= _maxMatches) break;
    if (_isExcluded(cwd, entity.path)) continue;
    final rel = p.relative(entity.path, from: cwd).replaceAll('\\', '/');
    if (glob.matches(rel)) matches.add(rel);
  }
  return matches.isEmpty ? 'no matches' : matches.join('\n');
}
