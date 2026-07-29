/// Frozen Paseo 0.2.0 GitHub project clone wire contract.
library;

import 'workspace_v2.dart';

enum ProjectGithubCloneProtocol { https, ssh }

final class ProjectGithubCloneRequest {
  const ProjectGithubCloneRequest({
    required this.requestId,
    required this.repo,
    required this.targetDirectory,
    this.cloneProtocol,
  });

  static const type = 'project.github.clone.request';

  final String requestId;
  final String repo;
  final String targetDirectory;
  final ProjectGithubCloneProtocol? cloneProtocol;

  factory ProjectGithubCloneRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final repo = _trimmedString(json, 'repo');
    if (repo.length < 3) {
      throw const FormatException('repo must contain at least 3 characters');
    }
    return ProjectGithubCloneRequest(
      requestId: _string(json, 'requestId'),
      repo: repo,
      targetDirectory: _trimmedString(json, 'targetDirectory'),
      cloneProtocol: json['cloneProtocol'] == null
          ? null
          : ProjectGithubCloneProtocol.values.byName(
              _string(json, 'cloneProtocol'),
            ),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'repo': repo,
    if (cloneProtocol != null) 'cloneProtocol': cloneProtocol!.name,
    'targetDirectory': targetDirectory,
    'requestId': requestId,
  };
}

final class ProjectGithubCloneResponse {
  const ProjectGithubCloneResponse({
    required this.requestId,
    required this.repo,
    required this.checkoutPath,
    required this.project,
    required this.error,
  });

  static const type = 'project.github.clone.response';

  final String requestId;
  final String repo;
  final String? checkoutPath;
  final WorkspaceProjectDescriptor? project;
  final String? error;

  factory ProjectGithubCloneResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _map(json, 'payload');
    final repo = _trimmedString(payload, 'repo');
    if (repo.length < 3) {
      throw const FormatException('repo must contain at least 3 characters');
    }
    return ProjectGithubCloneResponse(
      requestId: _string(payload, 'requestId'),
      repo: repo,
      checkoutPath: _nullableString(payload, 'checkoutPath'),
      project: payload['project'] == null
          ? null
          : WorkspaceProjectDescriptor.fromJson(_map(payload, 'project')),
      error: _nullableString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'repo': repo,
      'checkoutPath': checkoutPath,
      'project': project?.toJson(),
      'error': error,
    },
  };
}

void _expectType(Map<String, Object?> json, String type) {
  if (json['type'] != type) throw FormatException('Expected $type');
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String _trimmedString(Map<String, Object?> json, String key) {
  final value = _string(json, key).trim();
  if (value.isEmpty) throw FormatException('$key must not be empty');
  return value;
}

String? _nullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string or null');
  return value;
}

Map<String, Object?> _map(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}
