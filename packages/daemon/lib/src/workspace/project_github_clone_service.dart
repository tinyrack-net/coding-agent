import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import 'workspace_registry.dart';

const projectGithubCloneTimeout = Duration(minutes: 5);
const projectGithubCloneMaxOutputBytes = 1024 * 1024;

typedef ProjectGithubCloneRunner =
    Future<void> Function({
      required String cloneUrl,
      required String targetPath,
      required String cwd,
      required Duration timeout,
      required int maxOutputBytes,
    });

final class NormalizedCloneRepository {
  const NormalizedCloneRepository({
    required this.name,
    required this.displayName,
    required this.cloneUrl,
  });

  final String name;
  final String displayName;
  final String cloneUrl;
}

NormalizedCloneRepository normalizeCloneRepository({
  required String repo,
  ProjectGithubCloneProtocol? cloneProtocol,
}) {
  final trimmed = repo.trim();
  if (trimmed.isEmpty) throw StateError('Repository is required');

  final remote = parseGitRemoteLocation(trimmed);
  if (remote != null) {
    final segments = remote.path
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    final name = segments.lastOrNull;
    if (name == null || !_isValidGitHubRepoSegment(name)) {
      throw StateError('Repository name contains invalid characters');
    }
    return NormalizedCloneRepository(
      name: name,
      displayName: remote.path,
      cloneUrl: trimmed,
    );
  }

  final segments = trimmed.split('/');
  if (segments.length != 2 || segments[0].isEmpty || segments[1].isEmpty) {
    throw StateError(
      'Repository must use owner/repo format or a git remote URL',
    );
  }
  final owner = segments[0];
  final rawName = segments[1];
  final name = rawName.endsWith('.git')
      ? rawName.substring(0, rawName.length - 4)
      : rawName;
  if (!_isValidGitHubRepoSegment(owner) || !_isValidGitHubRepoSegment(name)) {
    throw StateError('Repository contains invalid characters');
  }
  if (cloneProtocol == null) {
    throw StateError(
      'Clone protocol is required for owner/repo repository names',
    );
  }
  return NormalizedCloneRepository(
    name: name,
    displayName: '$owner/$name',
    cloneUrl: cloneProtocol == ProjectGithubCloneProtocol.ssh
        ? 'git@github.com:$owner/$name.git'
        : 'https://github.com/$owner/$name.git',
  );
}

final class ProjectGithubCloneService {
  ProjectGithubCloneService({
    required this.registries,
    ProjectGithubCloneRunner? runClone,
    DateTime Function()? now,
    Map<String, String>? environment,
  }) : _runClone = runClone ?? runProjectGithubGitClone,
       _now = now ?? DateTime.now,
       _environment = environment ?? Platform.environment;

  final WorkspaceRegistries registries;
  final ProjectGithubCloneRunner _runClone;
  final DateTime Function() _now;
  final Map<String, String> _environment;

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    if (message['type'] != ProjectGithubCloneRequest.type) return null;
    final request = ProjectGithubCloneRequest.fromJson(message);
    var normalizedRepo = request.repo;
    String? checkoutPath;
    try {
      final repo = normalizeCloneRepository(
        repo: request.repo,
        cloneProtocol: request.cloneProtocol,
      );
      normalizedRepo = repo.displayName;
      final targetParent = p.normalize(
        p.absolute(_expandTilde(request.targetDirectory)),
      );
      checkoutPath = p.normalize(p.join(targetParent, repo.name));
      if (!_isPathWithinRoot(targetParent, checkoutPath)) {
        throw StateError(
          'Resolved checkout path must stay inside the target directory',
        );
      }

      final parent = Directory(targetParent);
      await parent.create(recursive: true);
      if (FileSystemEntity.typeSync(checkoutPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('Checkout path already exists: $checkoutPath');
      }

      final staging = await parent.createTemp('.tinyrack-clone-');
      try {
        await _runClone(
          cloneUrl: repo.cloneUrl,
          targetPath: staging.path,
          cwd: targetParent,
          timeout: projectGithubCloneTimeout,
          maxOutputBytes: projectGithubCloneMaxOutputBytes,
        );
        await staging.rename(checkoutPath);
      } on Object {
        if (staging.existsSync()) {
          try {
            await staging.delete(recursive: true);
          } on Object {
            // Cleanup is best effort; preserve the clone failure.
          }
        }
        rethrow;
      }

      final timestamp = _now().toUtc().toIso8601String();
      final project = await registries.projects.getOrCreateActiveByRoot(
        rootPath: checkoutPath,
        kind: PersistedProjectKind.git,
        displayName: repo.name,
        timestamp: timestamp,
      );
      return ProjectGithubCloneResponse(
        requestId: request.requestId,
        repo: repo.displayName,
        checkoutPath: checkoutPath,
        project: WorkspaceProjectDescriptor(
          projectId: project.projectId,
          projectDisplayName: resolveProjectDisplayName(project),
          projectCustomName: project.customName,
          projectRootPath: project.rootPath,
          projectKind: WorkspaceProjectKind.git,
        ),
        error: null,
      ).toJson();
    } on Object catch (error) {
      return ProjectGithubCloneResponse(
        requestId: request.requestId,
        repo: normalizedRepo,
        checkoutPath: checkoutPath,
        project: null,
        error: _errorMessage(error),
      ).toJson();
    }
  }

  String _expandTilde(String value) {
    final trimmed = value.trim();
    if (trimmed != '~' &&
        !trimmed.startsWith('~/') &&
        !trimmed.startsWith(r'~\')) {
      return trimmed;
    }
    final home =
        _environment['USERPROFILE'] ??
        _environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'];
    if (home == null || home.trim().isEmpty) return trimmed;
    if (trimmed == '~') return home;
    return p.join(home, trimmed.substring(2));
  }
}

Future<void> runProjectGithubGitClone({
  required String cloneUrl,
  required String targetPath,
  required String cwd,
  required Duration timeout,
  required int maxOutputBytes,
}) async {
  final process = await Process.start(
    'git',
    ['-c', 'core.quotepath=false', 'clone', cloneUrl, targetPath],
    workingDirectory: cwd,
    runInShell: false,
    mode: ProcessStartMode.normal,
  );
  final stdout = _BoundedOutput(maxOutputBytes);
  final stderr = _BoundedOutput(2048);
  var truncated = false;
  final stdoutDone = Completer<void>();
  final stderrDone = Completer<void>();
  process.stdout.listen(
    (bytes) {
      if (stdout.add(bytes)) {
        truncated = true;
        process.kill();
      }
    },
    onDone: stdoutDone.complete,
    onError: stdoutDone.completeError,
  );
  process.stderr.listen(
    stderr.add,
    onDone: stderrDone.complete,
    onError: stderrDone.completeError,
  );

  late final int exitCode;
  try {
    exitCode = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    process.kill();
    throw TimeoutException(
      'Git command timed out after ${timeout.inMilliseconds}ms: '
      'git clone $cloneUrl $targetPath',
      timeout,
    );
  } finally {
    await Future.wait([
      stdoutDone.future.catchError((_) {}),
      stderrDone.future.catchError((_) {}),
    ]);
  }
  if (!truncated && exitCode != 0) {
    final detail = stderr.text.trim();
    throw StateError(
      'Git command failed: git clone $cloneUrl $targetPath '
      '(exit code: $exitCode, signal: none)\n'
      '${detail.isEmpty ? '(no stderr)' : detail}',
    );
  }
}

final class _BoundedOutput {
  _BoundedOutput(this.limit);

  final int limit;
  final List<int> _bytes = [];

  /// Returns true when the input crossed the configured bound.
  bool add(List<int> bytes) {
    final remaining = limit - _bytes.length;
    if (remaining <= 0) return true;
    if (bytes.length > remaining) {
      _bytes.addAll(bytes.take(remaining));
      return true;
    }
    _bytes.addAll(bytes);
    return false;
  }

  String get text => utf8.decode(_bytes, allowMalformed: true);
}

bool _isValidGitHubRepoSegment(String value) =>
    RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value);

bool _isPathWithinRoot(String rootPath, String candidatePath) {
  final root = p.normalize(p.absolute(rootPath));
  final candidate = p.normalize(p.absolute(candidatePath));
  return p.equals(root, candidate) || p.isWithin(root, candidate);
}

String _errorMessage(Object error) => switch (error) {
  StateError(message: final message) => message,
  TimeoutException(message: final message?) => message,
  FileSystemException(message: final message) => message,
  _ => '$error',
};
