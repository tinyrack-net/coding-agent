/// Disk persistence for registered projects.
///
/// Layout: `<dataDir>/projects.json` holding `{projects: [ProjectInfo]}`.
/// Writes are atomic (tmp file + rename), matching agent_store.dart.
library;

import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

class ProjectStore {
  ProjectStore({String? dataDir}) : dataDir = dataDir ?? defaultDataDir();

  final String dataDir;

  List<ProjectInfo>? _cache;

  static String defaultDataDir() {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    return p.join(home, '.tinyrack-agent');
  }

  String get _filePath => p.join(dataDir, 'projects.json');

  /// All registered projects, in insertion order.
  Future<List<ProjectInfo>> list() async {
    _cache ??= await _load();
    return List.unmodifiable(_cache!);
  }

  /// Adds (or updates, keyed by normalized path) a project and persists.
  Future<ProjectInfo> add(ProjectInfo project) async {
    _cache ??= await _load();
    final normalized = ProjectInfo(
      path: p.normalize(project.path),
      name: project.name,
      isGitRepo: project.isGitRepo,
    );
    final idx =
        _cache!.indexWhere((existing) => p.equals(existing.path, normalized.path));
    if (idx >= 0) {
      _cache![idx] = normalized;
    } else {
      _cache!.add(normalized);
    }
    await _save();
    return normalized;
  }

  Future<List<ProjectInfo>> _load() async {
    final file = File(_filePath);
    if (!file.existsSync()) return [];
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      return ((json['projects'] as List?) ?? const [])
          .cast<Map<String, Object?>>()
          .map(ProjectInfo.fromJson)
          .toList();
    } catch (_) {
      // Corrupt store: start fresh rather than failing every request.
      return [];
    }
  }

  /// Atomic write (tmp + rename).
  Future<void> _save() async {
    final file = File(_filePath);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'projects': [for (final project in _cache ?? const <ProjectInfo>[]) project.toJson()],
      }),
      flush: true,
    );
    if (file.existsSync()) {
      try {
        await file.delete();
      } catch (_) {}
    }
    await tmp.rename(file.path);
  }
}
