import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';

final class GithubCommandResult {
  const GithubCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

typedef GithubCommandRunner =
    Future<GithubCommandResult> Function(
      List<String> arguments, {
      required String cwd,
    });

final class WorkspaceGithubRepositorySearchService {
  WorkspaceGithubRepositorySearchService({
    GithubCommandRunner? runner,
    Map<String, String>? environment,
  }) : _runner = runner ?? runGithubCommand,
       _environment = environment ?? Platform.environment;

  final GithubCommandRunner _runner;
  final Map<String, String> _environment;

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    if (message['type'] != WorkspaceGithubSearchRepositoriesRequest.type) {
      return null;
    }
    final request = WorkspaceGithubSearchRepositoriesRequest.fromJson(message);
    try {
      final repositories = await search(
        query: request.query,
        limit: request.limit ?? 20,
      );
      return WorkspaceGithubSearchRepositoriesResponse(
        status: WorkspaceGithubSearchStatus.success,
        requestId: request.requestId,
        repositories: repositories,
        available: true,
        error: null,
      ).toJson();
    } on ProcessException catch (error) {
      return WorkspaceGithubSearchRepositoriesResponse(
        status: WorkspaceGithubSearchStatus.unavailable,
        requestId: request.requestId,
        repositories: const [],
        reason: 'gh_missing',
        available: false,
        error:
            'GitHub CLI (gh) is not installed or not in PATH: '
            '${error.message}',
      ).toJson();
    } on GithubSearchException catch (error) {
      final unauthenticated = _isAuthenticationError(error.message);
      return WorkspaceGithubSearchRepositoriesResponse(
        status: unauthenticated
            ? WorkspaceGithubSearchStatus.unauthenticated
            : WorkspaceGithubSearchStatus.error,
        requestId: request.requestId,
        repositories: const [],
        available: !unauthenticated,
        error: unauthenticated
            ? 'GitHub CLI authentication failed'
            : error.message,
      ).toJson();
    } on Object catch (error) {
      return WorkspaceGithubSearchRepositoriesResponse(
        status: WorkspaceGithubSearchStatus.error,
        requestId: request.requestId,
        repositories: const [],
        available: true,
        error: 'Failed to search GitHub repositories: $error',
      ).toJson();
    }
  }

  Future<List<GithubRepository>> search({
    required String query,
    required int limit,
  }) async {
    final trimmed = query.trim();
    final cwd =
        _environment['USERPROFILE'] ??
        _environment['HOME'] ??
        Directory.current.path;
    final result = await _runner(
      trimmed.isEmpty
          ? [
              'repo',
              'list',
              '--json',
              'id,name,nameWithOwner,description,visibility,updatedAt,sshUrl,url',
              '--limit',
              '$limit',
            ]
          : [
              'search',
              'repos',
              trimmed,
              '--json',
              'id,name,fullName,description,visibility,updatedAt,url',
              '--sort',
              'updated',
              '--order',
              'desc',
              '--limit',
              '$limit',
            ],
      cwd: cwd,
    );
    if (result.exitCode != 0) {
      throw GithubSearchException(
        result.stderr.trim().isEmpty
            ? 'GitHub repository search failed'
            : result.stderr.trim(),
      );
    }
    final cloneProtocol = await _configuredCloneProtocol(cwd);
    final decoded = jsonDecode(result.stdout);
    if (decoded is! List) {
      throw const FormatException('GitHub repository output must be an array');
    }
    return List.unmodifiable(
      decoded.map(
        (value) => _parseRepository(
          value,
          searchResult: trimmed.isNotEmpty,
          cloneProtocol: cloneProtocol,
        ),
      ),
    );
  }

  Future<ProjectGithubCloneProtocol> _configuredCloneProtocol(
    String cwd,
  ) async {
    try {
      final result = await _runner([
        'config',
        'get',
        'git_protocol',
        '--host',
        'github.com',
      ], cwd: cwd);
      return result.exitCode == 0 && result.stdout.trim() == 'ssh'
          ? ProjectGithubCloneProtocol.ssh
          : ProjectGithubCloneProtocol.https;
    } on Object {
      return ProjectGithubCloneProtocol.https;
    }
  }
}

final class GithubSearchException implements Exception {
  const GithubSearchException(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<GithubCommandResult> runGithubCommand(
  List<String> arguments, {
  required String cwd,
}) async {
  final result = await Process.run(
    'gh',
    arguments,
    workingDirectory: cwd,
    runInShell: false,
  );
  return GithubCommandResult(
    exitCode: result.exitCode,
    stdout: '${result.stdout}',
    stderr: '${result.stderr}',
  );
}

GithubRepository _parseRepository(
  Object? value, {
  required bool searchResult,
  required ProjectGithubCloneProtocol cloneProtocol,
}) {
  if (value is! Map) {
    throw const FormatException('GitHub repository entry must be an object');
  }
  final json = Map<String, Object?>.from(value);
  final name = _requiredText(json, 'name');
  final nameWithOwner = _requiredText(
    json,
    searchResult ? 'fullName' : 'nameWithOwner',
  );
  final url = _requiredText(json, 'url');
  final cloneUrl = cloneProtocol == ProjectGithubCloneProtocol.ssh
      ? (searchResult
            ? 'git@github.com:$nameWithOwner.git'
            : _optionalText(json, 'sshUrl') ??
                  'git@github.com:$nameWithOwner.git')
      : url;
  final visibility = _requiredText(json, 'visibility').toLowerCase();
  return GithubRepository(
    id: '${json['id']}'.trim(),
    name: name,
    nameWithOwner: nameWithOwner,
    description: _optionalText(json, 'description'),
    visibility: GithubRepositoryVisibility.values.byName(visibility),
    updatedAt: _requiredText(json, 'updatedAt'),
    cloneUrl: cloneUrl,
  );
}

String _requiredText(Map<String, Object?> json, String key) {
  final value = '${json[key] ?? ''}'.trim();
  if (value.isEmpty) throw FormatException('$key must not be empty');
  return value;
}

String? _optionalText(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

bool _isAuthenticationError(String message) {
  final lower = message.toLowerCase();
  return lower.contains('authentication') ||
      lower.contains('not logged') ||
      lower.contains('gh auth login') ||
      lower.contains('http 401');
}
