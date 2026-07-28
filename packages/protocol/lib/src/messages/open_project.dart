/// Paseo-compatible idempotent project/workspace opening messages.
library;

import 'workspace_v2.dart';

final class OpenProjectRequest {
  const OpenProjectRequest({required this.cwd, required this.requestId});

  static const type = 'open_project_request';
  final String cwd;
  final String requestId;

  factory OpenProjectRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type ||
        json['cwd'] is! String ||
        json['requestId'] is! String) {
      throw const FormatException('invalid open_project_request');
    }
    return OpenProjectRequest(
      cwd: json['cwd']! as String,
      requestId: json['requestId']! as String,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    'requestId': requestId,
  };
}

final class OpenProjectResponse {
  const OpenProjectResponse({
    required this.requestId,
    required this.workspace,
    required this.error,
    this.errorCode,
  });

  static const type = 'open_project_response';
  final String requestId;
  final WorkspaceDescriptor? workspace;
  final String? error;
  final String? errorCode;

  factory OpenProjectResponse.fromJson(Map<String, Object?> json) {
    if (json['type'] != type || json['payload'] is! Map) {
      throw const FormatException('invalid open_project_response');
    }
    final payload = (json['payload'] as Map).cast<String, Object?>();
    final workspace = payload['workspace'];
    final errorCode = payload['errorCode'];
    return OpenProjectResponse(
      requestId: payload['requestId']! as String,
      workspace: workspace == null
          ? null
          : WorkspaceDescriptor.fromJson(
              (workspace as Map).cast<String, Object?>(),
            ),
      error: payload['error'] as String?,
      errorCode: errorCode == 'directory_not_found'
          ? errorCode as String
          : null,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'workspace': workspace?.toJson(),
      'error': error,
      if (errorCode != null) 'errorCode': errorCode,
    },
  };
}
