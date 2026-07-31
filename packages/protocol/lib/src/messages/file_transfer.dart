final class FileDownloadTokenRequest {
  const FileDownloadTokenRequest({
    required this.cwd,
    required this.path,
    required this.requestId,
  });
  final String cwd;
  final String path;
  final String requestId;

  static const type = 'file_download_token_request';

  factory FileDownloadTokenRequest.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected file_download_token_request');
    }
    return FileDownloadTokenRequest(
      cwd: _requiredString(json, 'cwd'),
      path: _requiredString(json, 'path'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    'path': path,
    'requestId': requestId,
  };
}

final class FileDownloadTokenResponse {
  const FileDownloadTokenResponse({
    required this.cwd,
    required this.path,
    required this.token,
    required this.fileName,
    required this.mimeType,
    required this.size,
    required this.error,
    required this.requestId,
  });

  static const type = 'file_download_token_response';

  final String cwd;
  final String path;
  final String? token;
  final String? fileName;
  final String? mimeType;
  final num? size;
  final String? error;
  final String requestId;

  factory FileDownloadTokenResponse.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('Expected file_download_token_response');
    }
    final rawPayload = json['payload'];
    if (rawPayload is! Map) {
      throw const FormatException('payload must be an object');
    }
    final payload = Map<String, Object?>.from(rawPayload);
    final rawSize = payload['size'];
    if (rawSize != null && rawSize is! num) {
      throw const FormatException('size must be a number or null');
    }
    return FileDownloadTokenResponse(
      cwd: _requiredString(payload, 'cwd'),
      path: _requiredString(payload, 'path'),
      token: _optionalString(payload, 'token'),
      fileName: _optionalString(payload, 'fileName'),
      mimeType: _optionalString(payload, 'mimeType'),
      size: rawSize as num?,
      error: _optionalString(payload, 'error'),
      requestId: _requiredString(payload, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'cwd': cwd,
      'path': path,
      'token': token,
      'fileName': fileName,
      'mimeType': mimeType,
      'size': size,
      'error': error,
      'requestId': requestId,
    },
  };
}

final class FileUploadRequest {
  const FileUploadRequest({
    required this.fileName,
    required this.mimeType,
    required this.size,
    required this.modifiedAt,
    required this.requestId,
  });
  final String fileName;
  final String mimeType;
  final int size;
  final String modifiedAt;
  final String requestId;
}

final class UploadedFileAttachment {
  const UploadedFileAttachment({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.size,
    required this.path,
  });
  final String id;
  final String fileName;
  final String mimeType;
  final int size;
  final String path;

  Map<String, Object?> toJson() => {
    'type': 'uploaded_file',
    'id': id,
    'fileName': fileName,
    'mimeType': mimeType,
    'size': size,
    'path': path,
  };
}

String _requiredString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}

String? _optionalString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}
