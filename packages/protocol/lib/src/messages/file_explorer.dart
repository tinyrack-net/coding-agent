enum FileExplorerMode { list, file }

sealed class FileVersion {
  const FileVersion({required this.cwd, required this.path});

  final String cwd;
  final String path;

  factory FileVersion.fromJson(Map<String, Object?> json) {
    final cwd = json['cwd'];
    final path = json['path'];
    if (cwd is! String || path is! String) {
      throw const FormatException('Invalid file version');
    }
    return switch (json['status']) {
      'ready' => ReadyFileVersion.fromJson(json),
      'missing' => MissingFileVersion(cwd: cwd, path: path),
      'error' => ErrorFileVersion.fromJson(json),
      _ => throw const FormatException('Invalid file version status'),
    };
  }

  Map<String, Object?> toJson();
}

final class ReadyFileVersion extends FileVersion {
  const ReadyFileVersion({
    required super.cwd,
    required super.path,
    required this.size,
    required this.modifiedAt,
    this.revision,
  });

  final int size;
  final String modifiedAt;
  final String? revision;

  factory ReadyFileVersion.fromJson(Map<String, Object?> json) {
    final cwd = json['cwd'];
    final path = json['path'];
    final size = json['size'];
    final modifiedAt = json['modifiedAt'];
    final revision = json['revision'];
    if (cwd is! String ||
        path is! String ||
        size is! num ||
        size < 0 ||
        modifiedAt is! String ||
        (revision != null && revision is! String)) {
      throw const FormatException('Invalid ready file version');
    }
    return ReadyFileVersion(
      cwd: cwd,
      path: path,
      size: size.toInt(),
      modifiedAt: modifiedAt,
      revision: revision as String?,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'status': 'ready',
    'cwd': cwd,
    'path': path,
    'size': size,
    'modifiedAt': modifiedAt,
    if (revision != null) 'revision': revision,
  };
}

final class MissingFileVersion extends FileVersion {
  const MissingFileVersion({required super.cwd, required super.path});

  @override
  Map<String, Object?> toJson() => {
    'status': 'missing',
    'cwd': cwd,
    'path': path,
  };
}

final class ErrorFileVersion extends FileVersion {
  const ErrorFileVersion({
    required super.cwd,
    required super.path,
    required this.error,
  });

  final String error;

  factory ErrorFileVersion.fromJson(Map<String, Object?> json) {
    final cwd = json['cwd'];
    final path = json['path'];
    final error = json['error'];
    if (cwd is! String || path is! String || error is! String) {
      throw const FormatException('Invalid error file version');
    }
    return ErrorFileVersion(cwd: cwd, path: path, error: error);
  }

  @override
  Map<String, Object?> toJson() => {
    'status': 'error',
    'cwd': cwd,
    'path': path,
    'error': error,
  };
}

sealed class FileWriteResult {
  const FileWriteResult();

  factory FileWriteResult.fromJson(Map<String, Object?> json) =>
      switch (json['status']) {
        'written' => WrittenFileResult.fromJson(json),
        'conflict' => ConflictFileResult.fromJson(json),
        'error' => FileWriteError.fromJson(json),
        _ => throw const FormatException('Invalid file write result'),
      };

  Map<String, Object?> toJson();
}

final class WrittenFileResult extends FileWriteResult {
  const WrittenFileResult({
    required this.modifiedAt,
    required this.size,
    this.revision,
  });

  final String modifiedAt;
  final int size;
  final String? revision;

  factory WrittenFileResult.fromJson(Map<String, Object?> json) {
    final modifiedAt = json['modifiedAt'];
    final size = json['size'];
    final revision = json['revision'];
    if (modifiedAt is! String ||
        size is! num ||
        size < 0 ||
        (revision != null && revision is! String)) {
      throw const FormatException('Invalid written file result');
    }
    return WrittenFileResult(
      modifiedAt: modifiedAt,
      size: size.toInt(),
      revision: revision as String?,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'status': 'written',
    'modifiedAt': modifiedAt,
    'size': size,
    if (revision != null) 'revision': revision,
  };
}

final class ConflictFileResult extends FileWriteResult {
  const ConflictFileResult(this.version);

  final FileVersion version;

  factory ConflictFileResult.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    if (version is! Map) {
      throw const FormatException('Invalid conflict file result');
    }
    return ConflictFileResult(
      FileVersion.fromJson(Map<String, Object?>.from(version)),
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'status': 'conflict',
    'version': version.toJson(),
  };
}

final class FileWriteError extends FileWriteResult {
  const FileWriteError(this.error);

  final String error;

  factory FileWriteError.fromJson(Map<String, Object?> json) {
    final error = json['error'];
    if (error is! String) {
      throw const FormatException('Invalid file write error');
    }
    return FileWriteError(error);
  }

  @override
  Map<String, Object?> toJson() => {'status': 'error', 'error': error};
}

final class FileExplorerRequest {
  const FileExplorerRequest({
    required this.cwd,
    required this.mode,
    required this.requestId,
    this.path = '.',
    this.acceptBinary = false,
  });

  final String cwd;
  final String path;
  final FileExplorerMode mode;
  final String requestId;
  final bool acceptBinary;

  factory FileExplorerRequest.fromJson(Map<String, Object?> json) {
    final cwd = json['cwd'];
    final path = json['path'] ?? '.';
    final mode = json['mode'];
    final requestId = json['requestId'];
    final acceptBinary = json['acceptBinary'] ?? false;
    if (cwd is! String ||
        path is! String ||
        mode is! String ||
        requestId is! String ||
        acceptBinary is! bool) {
      throw const FormatException('Invalid file explorer request');
    }
    return FileExplorerRequest(
      cwd: cwd,
      path: path,
      mode: switch (mode) {
        'list' => FileExplorerMode.list,
        'file' => FileExplorerMode.file,
        _ => throw const FormatException('Invalid file explorer mode'),
      },
      requestId: requestId,
      acceptBinary: acceptBinary,
    );
  }
}

final class FileSubscribeRequest {
  const FileSubscribeRequest({
    required this.cwd,
    required this.path,
    required this.subscriptionId,
    required this.requestId,
  });

  final String cwd;
  final String path;
  final String subscriptionId;
  final String requestId;

  factory FileSubscribeRequest.fromJson(Map<String, Object?> json) {
    final cwd = json['cwd'];
    final path = json['path'];
    final subscriptionId = json['subscriptionId'];
    final requestId = json['requestId'];
    if (cwd is! String ||
        path is! String ||
        subscriptionId is! String ||
        requestId is! String) {
      throw const FormatException('Invalid file subscribe request');
    }
    return FileSubscribeRequest(
      cwd: cwd,
      path: path,
      subscriptionId: subscriptionId,
      requestId: requestId,
    );
  }
}

final class FileUnsubscribeRequest {
  const FileUnsubscribeRequest({
    required this.subscriptionId,
    required this.requestId,
  });

  final String subscriptionId;
  final String requestId;

  factory FileUnsubscribeRequest.fromJson(Map<String, Object?> json) {
    final subscriptionId = json['subscriptionId'];
    final requestId = json['requestId'];
    if (subscriptionId is! String || requestId is! String) {
      throw const FormatException('Invalid file unsubscribe request');
    }
    return FileUnsubscribeRequest(
      subscriptionId: subscriptionId,
      requestId: requestId,
    );
  }
}

final class FileWriteRequest {
  const FileWriteRequest({
    required this.cwd,
    required this.path,
    required this.content,
    required this.expectedModifiedAt,
    required this.requestId,
    this.expectedRevision,
  });

  final String cwd;
  final String path;
  final String content;
  final String expectedModifiedAt;
  final String? expectedRevision;
  final String requestId;

  factory FileWriteRequest.fromJson(Map<String, Object?> json) {
    final cwd = json['cwd'];
    final path = json['path'];
    final content = json['content'];
    final expectedModifiedAt = json['expectedModifiedAt'];
    final expectedRevision = json['expectedRevision'];
    final requestId = json['requestId'];
    if (cwd is! String ||
        path is! String ||
        content is! String ||
        expectedModifiedAt is! String ||
        (expectedRevision != null && expectedRevision is! String) ||
        requestId is! String) {
      throw const FormatException('Invalid file write request');
    }
    return FileWriteRequest(
      cwd: cwd,
      path: path,
      content: content,
      expectedModifiedAt: expectedModifiedAt,
      expectedRevision: expectedRevision as String?,
      requestId: requestId,
    );
  }
}

final class ProjectIconRequest {
  const ProjectIconRequest({required this.cwd, required this.requestId});

  final String cwd;
  final String requestId;

  factory ProjectIconRequest.fromJson(Map<String, Object?> json) {
    final cwd = json['cwd'];
    final requestId = json['requestId'];
    if (cwd is! String || requestId is! String) {
      throw const FormatException('Invalid project icon request');
    }
    return ProjectIconRequest(cwd: cwd, requestId: requestId);
  }
}
