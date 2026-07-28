import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../workspace/workspace_registry.dart';
import 'connection.dart';

const tinyrackProjectConfigFileName = 'tinyrack.json';
const paseoProjectConfigFileName = 'paseo.json';

final class ProjectConfigFile {
  const ProjectConfigFile();

  Future<Map<String, Object?>> read(String repoRoot) async {
    final file = await _selectedFile(repoRoot);
    if (!await file.exists()) {
      return {'ok': true, 'config': null, 'revision': null};
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('Project config must be an object');
      }
      return {
        'ok': true,
        'config': validateProjectConfigRaw(decoded),
        'revision': (await _revision(file))!.toJson(),
      };
    } catch (_) {
      return {
        'ok': false,
        'error': {'code': 'invalid_project_config'},
      };
    }
  }

  Future<Map<String, Object?>> write({
    required String repoRoot,
    required Map<String, Object?> config,
    required ProjectConfigRevision? expectedRevision,
  }) async {
    Map<String, Object?> normalized;
    try {
      normalized = validateProjectConfigRaw(config);
    } on FormatException {
      return {
        'ok': false,
        'error': {'code': 'invalid_project_config'},
      };
    }
    final file = await _selectedFile(repoRoot);
    final temporary = File(
      p.join(
        repoRoot,
        '.${p.basename(file.path)}.${pid}.${const Uuid().v4()}.tmp',
      ),
    );
    try {
      await temporary.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(normalized)}\n',
        flush: true,
      );
      final current = await _revision(file);
      if (!_sameRevision(current, expectedRevision)) {
        return {
          'ok': false,
          'error': {
            'code': 'stale_project_config',
            'currentRevision': current?.toJson(),
          },
        };
      }
      await temporary.rename(file.path);
      final revision = await _revision(file);
      if (revision == null) {
        return {
          'ok': false,
          'error': {'code': 'write_failed'},
        };
      }
      return {'ok': true, 'config': normalized, 'revision': revision.toJson()};
    } catch (_) {
      return {
        'ok': false,
        'error': {'code': 'write_failed'},
      };
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        // Best-effort cleanup, matching Paseo.
      }
    }
  }

  Future<File> _selectedFile(String repoRoot) async {
    final branded = File(p.join(repoRoot, tinyrackProjectConfigFileName));
    if (await branded.exists()) return branded;
    final compatible = File(p.join(repoRoot, paseoProjectConfigFileName));
    return await compatible.exists() ? compatible : branded;
  }
}

final class ProjectConfigService {
  const ProjectConfigService({
    required this.projects,
    this.files = const ProjectConfigFile(),
  });

  final FileBackedProjectRegistry projects;
  final ProjectConfigFile files;

  Future<Object?> handle(
    Connection connection,
    Map<String, Object?> message,
  ) async {
    switch (message['type']) {
      case 'read_project_config_request':
        final request = ReadProjectConfigRequest.fromJson(message);
        final root = await _knownRoot(request.repoRoot);
        if (root == null) {
          return _failure(
            'read_project_config_response',
            request.requestId,
            request.repoRoot,
            'project_not_found',
          );
        }
        final result = await files.read(root);
        return {
          'type': 'read_project_config_response',
          'payload': {
            'requestId': request.requestId,
            'repoRoot': root,
            ...result,
          },
        };
      case 'write_project_config_request':
        final request = WriteProjectConfigRequest.fromJson(message);
        final root = await _knownRoot(request.repoRoot);
        if (root == null) {
          return _failure(
            'write_project_config_response',
            request.requestId,
            request.repoRoot,
            'project_not_found',
          );
        }
        final result = await files.write(
          repoRoot: root,
          config: request.config,
          expectedRevision: request.expectedRevision,
        );
        return {
          'type': 'write_project_config_response',
          'payload': {
            'requestId': request.requestId,
            'repoRoot': root,
            ...result,
          },
        };
      default:
        return null;
    }
  }

  Future<String?> _knownRoot(String requested) async {
    final canonicalRequested = await _canonicalRoot(requested);
    for (final project in await projects.list()) {
      if (project.archivedAt != null) continue;
      final root = await _canonicalRoot(project.rootPath);
      if (p.equals(root, canonicalRequested)) return root;
    }
    return null;
  }
}

Future<String> _canonicalRoot(String value) async {
  final resolved = p.normalize(p.absolute(value));
  try {
    return p.normalize(await Directory(resolved).resolveSymbolicLinks());
  } on FileSystemException {
    return resolved;
  }
}

Future<ProjectConfigRevision?> _revision(File file) async {
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file) return null;
  return ProjectConfigRevision(
    mtimeMs: stat.modified.microsecondsSinceEpoch / 1000,
    size: stat.size,
  );
}

bool _sameRevision(ProjectConfigRevision? left, ProjectConfigRevision? right) {
  if (left == null || right == null) return left == null && right == null;
  return left.mtimeMs == right.mtimeMs && left.size == right.size;
}

Map<String, Object?> _failure(
  String type,
  String requestId,
  String repoRoot,
  String code,
) => {
  'type': type,
  'payload': {
    'requestId': requestId,
    'repoRoot': repoRoot,
    'ok': false,
    'error': {'code': code},
  },
};
