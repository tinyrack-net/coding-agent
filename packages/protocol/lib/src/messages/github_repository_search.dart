/// Frozen Paseo 0.2.0 GitHub repository search wire contract.
library;

enum GithubRepositoryVisibility { public, private, internal }

final class GithubRepository {
  const GithubRepository({
    required this.id,
    required this.name,
    required this.nameWithOwner,
    required this.description,
    required this.visibility,
    required this.updatedAt,
    required this.cloneUrl,
  });

  final String id;
  final String name;
  final String nameWithOwner;
  final String? description;
  final GithubRepositoryVisibility visibility;
  final String updatedAt;
  final String cloneUrl;

  factory GithubRepository.fromJson(Map<String, Object?> json) {
    final id = _nonEmptyString(json, 'id');
    final name = _nonEmptyString(json, 'name');
    final nameWithOwner = _trimmedString(json, 'nameWithOwner');
    final cloneUrl = _trimmedString(json, 'cloneUrl');
    if (nameWithOwner.length < 3 || cloneUrl.length < 3) {
      throw const FormatException(
        'nameWithOwner and cloneUrl must contain at least 3 characters',
      );
    }
    return GithubRepository(
      id: id,
      name: name,
      nameWithOwner: nameWithOwner,
      description: _nullableString(json, 'description'),
      visibility: GithubRepositoryVisibility.values.byName(
        _string(json, 'visibility'),
      ),
      updatedAt: _string(json, 'updatedAt'),
      cloneUrl: cloneUrl,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'nameWithOwner': nameWithOwner,
    'description': description,
    'visibility': visibility.name,
    'updatedAt': updatedAt,
    'cloneUrl': cloneUrl,
  };
}

final class WorkspaceGithubSearchRepositoriesRequest {
  const WorkspaceGithubSearchRepositoriesRequest({
    required this.query,
    required this.requestId,
    this.limit,
  });

  static const type = 'workspace.github.search_repositories.request';

  final String query;
  final int? limit;
  final String requestId;

  factory WorkspaceGithubSearchRepositoriesRequest.fromJson(
    Map<String, Object?> json,
  ) {
    _expectType(json, type);
    final limit = json['limit'];
    if (limit != null &&
        (limit is! num ||
            limit.toInt() != limit ||
            limit.toInt() < 1 ||
            limit.toInt() > 50)) {
      throw const FormatException('limit must be an integer from 1 to 50');
    }
    return WorkspaceGithubSearchRepositoriesRequest(
      query: _string(json, 'query'),
      limit: limit == null ? null : (limit as num).toInt(),
      requestId: _string(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'query': query,
    if (limit != null) 'limit': limit,
    'requestId': requestId,
  };
}

enum WorkspaceGithubSearchStatus {
  success,
  unavailable,
  unauthenticated,
  error,
}

final class WorkspaceGithubSearchRepositoriesResponse {
  const WorkspaceGithubSearchRepositoriesResponse({
    required this.status,
    required this.requestId,
    required this.repositories,
    required this.available,
    required this.error,
    this.reason,
  });

  static const type = 'workspace.github.search_repositories.response';

  final WorkspaceGithubSearchStatus status;
  final String requestId;
  final List<GithubRepository> repositories;
  final bool available;
  final String? error;
  final String? reason;

  factory WorkspaceGithubSearchRepositoriesResponse.fromJson(
    Map<String, Object?> json,
  ) {
    _expectType(json, type);
    final payload = _map(json, 'payload');
    final status = WorkspaceGithubSearchStatus.values.byName(
      _string(payload, 'status'),
    );
    final repositories = payload['repositories'];
    if (repositories is! List) {
      throw const FormatException('repositories must be an array');
    }
    final available = payload['available'];
    if (available is! bool) {
      throw const FormatException('available must be a boolean');
    }
    final error = _nullableString(payload, 'error');
    final reason = _nullableString(payload, 'reason');
    switch (status) {
      case WorkspaceGithubSearchStatus.success:
        if (!available || error != null || reason != null) {
          throw const FormatException('Invalid success search response');
        }
        break;
      case WorkspaceGithubSearchStatus.unavailable:
        if (available || error == null || reason != 'gh_missing') {
          throw const FormatException('Invalid unavailable search response');
        }
        break;
      case WorkspaceGithubSearchStatus.unauthenticated:
        if (available || error == null || reason != null) {
          throw const FormatException(
            'Invalid unauthenticated search response',
          );
        }
        break;
      case WorkspaceGithubSearchStatus.error:
        if (!available || error == null || reason != null) {
          throw const FormatException('Invalid error search response');
        }
        break;
    }
    return WorkspaceGithubSearchRepositoriesResponse(
      status: status,
      requestId: _string(payload, 'requestId'),
      repositories: List.unmodifiable(
        repositories.map(
          (item) => item is Map
              ? GithubRepository.fromJson(Map<String, Object?>.from(item))
              : throw const FormatException(
                  'repository entries must be objects',
                ),
        ),
      ),
      available: available,
      error: error,
      reason: reason,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'status': status.name,
      'requestId': requestId,
      'repositories': repositories.map((repo) => repo.toJson()).toList(),
      if (reason != null) 'reason': reason,
      'available': available,
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

String _nonEmptyString(Map<String, Object?> json, String key) {
  final value = _string(json, key).trim();
  if (value.isEmpty) throw FormatException('$key must not be empty');
  return value;
}

String _trimmedString(Map<String, Object?> json, String key) =>
    _nonEmptyString(json, key);

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
