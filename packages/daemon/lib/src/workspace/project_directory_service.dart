import 'dart:async';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import 'workspace_registry.dart';

final _directoryCreationTails = <String, Future<void>>{};

final class ProjectDirectoryRequestException implements Exception {
  const ProjectDirectoryRequestException(
    this.code,
    this.message, {
    this.directoryPath,
  });

  final ProjectCreateDirectoryErrorCode code;
  final String message;
  final String? directoryPath;

  @override
  String toString() => message;
}

final class CreateProjectDirectoryResult {
  const CreateProjectDirectoryResult({
    required this.directoryPath,
    required this.project,
  });

  final String directoryPath;
  final PersistedProjectRecord project;
}

typedef ProjectDirectoryRegistrar =
    Future<PersistedProjectRecord> Function(String directoryPath);

abstract interface class ProjectDirectoryFileSystem {
  Future<FileSystemEntityType> type(String path);
  Future<void> create(String path);
  Future<void> remove(String path);
}

final class IoProjectDirectoryFileSystem implements ProjectDirectoryFileSystem {
  const IoProjectDirectoryFileSystem();

  @override
  Future<FileSystemEntityType> type(String path) =>
      FileSystemEntity.type(path, followLinks: true);

  @override
  Future<void> create(String path) => Directory(path).create();

  @override
  Future<void> remove(String path) => Directory(path).delete();
}

Future<CreateProjectDirectoryResult> createProjectDirectory({
  required String parentPath,
  required String name,
  required ProjectDirectoryRegistrar registerProject,
  ProjectDirectoryFileSystem fileSystem = const IoProjectDirectoryFileSystem(),
  Map<String, String>? environment,
}) async {
  validateProjectDirectoryName(name);
  final requestedParent = parentPath.trim();
  if (requestedParent.isEmpty) {
    throw const ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.parentDirectoryNotFound,
      'Parent directory is required',
    );
  }
  final parent = p.normalize(
    p.absolute(_expandTilde(requestedParent, environment)),
  );
  final directoryPath = p.normalize(p.join(parent, name));
  if (!_isPathInside(parent, directoryPath)) {
    throw const ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.invalidName,
      'Directory name must resolve inside the selected parent',
    );
  }

  try {
    if (await fileSystem.type(parent) != FileSystemEntityType.directory) {
      throw ProjectDirectoryRequestException(
        ProjectCreateDirectoryErrorCode.parentDirectoryNotFound,
        'Parent directory not found: $parent',
      );
    }
  } on ProjectDirectoryRequestException {
    rethrow;
  } on FileSystemException catch (error) {
    throw _mapParentError(error, parent);
  } on Object catch (error) {
    throw ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.filesystemError,
      'Failed to inspect parent directory: ${_errorMessage(error)}',
    );
  }

  try {
    await _createDirectoryExclusive(fileSystem, directoryPath);
  } on ProjectDirectoryRequestException {
    rethrow;
  } on FileSystemException catch (error) {
    throw _mapCreateError(error, directoryPath);
  } on Object catch (error) {
    throw ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.filesystemError,
      'Failed to create directory: ${_errorMessage(error)}',
      directoryPath: directoryPath,
    );
  }

  try {
    return CreateProjectDirectoryResult(
      directoryPath: directoryPath,
      project: await registerProject(directoryPath),
    );
  } on Object catch (registrationError) {
    try {
      await fileSystem.remove(directoryPath);
    } on Object catch (rollbackError) {
      throw ProjectDirectoryRequestException(
        ProjectCreateDirectoryErrorCode.registrationFailed,
        'Failed to register project and roll back directory: '
        '${_errorMessage(rollbackError)}',
        directoryPath: directoryPath,
      );
    }
    throw ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.registrationFailed,
      'Failed to register project: ${_errorMessage(registrationError)}',
      directoryPath: directoryPath,
    );
  }
}

Future<void> _createDirectoryExclusive(
  ProjectDirectoryFileSystem fileSystem,
  String directoryPath,
) async {
  final previous = _directoryCreationTails[directoryPath];
  final release = Completer<void>();
  _directoryCreationTails[directoryPath] = release.future;
  if (previous != null) {
    await previous;
  }
  try {
    if (await fileSystem.type(directoryPath) != FileSystemEntityType.notFound) {
      throw ProjectDirectoryRequestException(
        ProjectCreateDirectoryErrorCode.directoryExists,
        'Directory already exists: $directoryPath',
        directoryPath: directoryPath,
      );
    }
    await fileSystem.create(directoryPath);
  } finally {
    release.complete();
    if (identical(_directoryCreationTails[directoryPath], release.future)) {
      _directoryCreationTails.remove(directoryPath);
    }
  }
}

void validateProjectDirectoryName(String name) {
  if (name.trim().isEmpty) {
    throw const ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.invalidName,
      'Directory name cannot be empty',
    );
  }
  if (name != name.trim()) {
    throw const ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.invalidName,
      'Directory name cannot start or end with whitespace',
    );
  }
  if (name == '.' || name == '..') {
    throw const ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.invalidName,
      'Directory name cannot be . or ..',
    );
  }
  if (name.contains('/') || name.contains(r'\') || name.contains('\x00')) {
    throw const ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.invalidName,
      'Directory name must be a single name without path separators',
    );
  }
  if (p.isAbsolute(name) ||
      RegExp(r'^[A-Za-z]:').hasMatch(name) ||
      name.startsWith(r'\\')) {
    throw const ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.invalidName,
      'Directory name cannot be an absolute path',
    );
  }
}

ProjectDirectoryRequestException _mapParentError(
  FileSystemException error,
  String parent,
) {
  if (_isPermissionDenied(error)) {
    return ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.permissionDenied,
      'Permission denied reading parent directory: $parent',
    );
  }
  if (_isNotFound(error)) {
    return ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.parentDirectoryNotFound,
      'Parent directory not found: $parent',
    );
  }
  return ProjectDirectoryRequestException(
    ProjectCreateDirectoryErrorCode.filesystemError,
    'Failed to inspect parent directory: ${_errorMessage(error)}',
  );
}

ProjectDirectoryRequestException _mapCreateError(
  FileSystemException error,
  String directoryPath,
) {
  if (_alreadyExists(error)) {
    return ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.directoryExists,
      'Directory already exists: $directoryPath',
      directoryPath: directoryPath,
    );
  }
  if (_isNotFound(error)) {
    return ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.parentDirectoryNotFound,
      'Parent directory not found: ${p.dirname(directoryPath)}',
      directoryPath: directoryPath,
    );
  }
  if (_isPermissionDenied(error)) {
    return ProjectDirectoryRequestException(
      ProjectCreateDirectoryErrorCode.permissionDenied,
      'Permission denied creating directory: $directoryPath',
      directoryPath: directoryPath,
    );
  }
  return ProjectDirectoryRequestException(
    ProjectCreateDirectoryErrorCode.filesystemError,
    'Failed to create directory: ${_errorMessage(error)}',
    directoryPath: directoryPath,
  );
}

bool _isPathInside(String parent, String child) {
  final relative = p.relative(child, from: parent);
  return relative.isNotEmpty &&
      relative != '..' &&
      !relative.startsWith('..${p.separator}') &&
      !p.isAbsolute(relative);
}

String _expandTilde(String value, Map<String, String>? environment) {
  if (value != '~' && !value.startsWith('~/') && !value.startsWith(r'~\')) {
    return value;
  }
  final env = environment ?? Platform.environment;
  final home = env['USERPROFILE'] ?? env['HOME'];
  if (home == null || home.trim().isEmpty) return value;
  return value == '~' ? home : p.join(home, value.substring(2));
}

bool _alreadyExists(FileSystemException error) =>
    {17, 183}.contains(error.osError?.errorCode) ||
    error.message.toLowerCase().contains('exists');

bool _isNotFound(FileSystemException error) =>
    {2, 3}.contains(error.osError?.errorCode) ||
    error.message.toLowerCase().contains('not found');

bool _isPermissionDenied(FileSystemException error) =>
    {5, 13, 30}.contains(error.osError?.errorCode) ||
    error.message.toLowerCase().contains('permission') ||
    error.message.toLowerCase().contains('access is denied');

String _errorMessage(Object error) =>
    error is FileSystemException ? error.message : '$error';
