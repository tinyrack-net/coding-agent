/// Frozen Paseo 0.2.0 project-directory creation wire contract.
library;

import 'workspace_v2.dart';

enum ProjectCreateDirectoryErrorCode {
  invalidName('invalid_name'),
  parentDirectoryNotFound('parent_directory_not_found'),
  directoryExists('directory_exists'),
  permissionDenied('permission_denied'),
  registrationFailed('registration_failed'),
  filesystemError('filesystem_error');

  const ProjectCreateDirectoryErrorCode(this.wireValue);

  final String wireValue;

  static ProjectCreateDirectoryErrorCode? tryFromWire(String? value) =>
      values.where((code) => code.wireValue == value).firstOrNull;
}

final class ProjectCreateDirectoryRequest {
  const ProjectCreateDirectoryRequest({
    required this.parentPath,
    required this.name,
    required this.requestId,
  });

  static const type = 'project.create_directory.request';

  final String parentPath;
  final String name;
  final String requestId;

  factory ProjectCreateDirectoryRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return ProjectCreateDirectoryRequest(
      parentPath: _string(json, 'parentPath'),
      name: _string(json, 'name'),
      requestId: _string(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'parentPath': parentPath,
    'name': name,
    'requestId': requestId,
  };
}

final class ProjectCreateDirectoryResponse {
  const ProjectCreateDirectoryResponse({
    required this.requestId,
    required this.directoryPath,
    required this.project,
    required this.error,
    required this.errorCode,
  });

  static const type = 'project.create_directory.response';

  final String requestId;
  final String? directoryPath;
  final WorkspaceProjectDescriptor? project;
  final String? error;

  /// Open-ended on the wire so older clients tolerate newer daemon codes.
  final String? errorCode;

  factory ProjectCreateDirectoryResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _map(json, 'payload');
    return ProjectCreateDirectoryResponse(
      requestId: _string(payload, 'requestId'),
      directoryPath: _nullableString(payload, 'directoryPath'),
      project: payload['project'] == null
          ? null
          : WorkspaceProjectDescriptor.fromJson(_map(payload, 'project')),
      error: _nullableString(payload, 'error'),
      errorCode: _nullableString(payload, 'errorCode'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'directoryPath': directoryPath,
      'project': project?.toJson(),
      'error': error,
      'errorCode': errorCode,
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
