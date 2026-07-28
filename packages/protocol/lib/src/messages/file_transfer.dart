final class FileDownloadTokenRequest {
  const FileDownloadTokenRequest({
    required this.cwd,
    required this.path,
    required this.requestId,
  });
  final String cwd;
  final String path;
  final String requestId;
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
