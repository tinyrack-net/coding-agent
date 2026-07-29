/// Frozen Paseo 0.2.0 Git remote parsing and classification.
library;

final class GitRemoteLocation {
  const GitRemoteLocation({
    required this.transport,
    required this.host,
    required this.path,
  });

  final String transport;
  final String host;
  final String path;

  String? get owner {
    final segments = path.split('/');
    return segments.length > 1
        ? segments.sublist(0, segments.length - 1).join('/')
        : null;
  }

  String? get repo => path.split('/').lastOrNull;
}

final class GitHubRemoteIdentity {
  const GitHubRemoteIdentity({
    required this.owner,
    required this.name,
    required this.repo,
  });

  final String owner;
  final String name;
  final String repo;
}

bool isCompleteGitRemote(String repo) => parseGitRemoteLocation(repo) != null;

GitRemoteLocation? parseGitRemoteLocation(String remoteUrl) {
  final trimmed = remoteUrl.trim();
  if (trimmed.isEmpty) return null;

  final scpLike = RegExp(r'^[^@]+@([^:]+):(.+)$').firstMatch(trimmed);
  if (scpLike != null) {
    final host = normalizeGitRemoteHost(scpLike.group(1) ?? '');
    final path = _normalizeRemotePath(scpLike.group(2) ?? '');
    if (!_isValidRemoteHost(host) || path == null) return null;
    return GitRemoteLocation(transport: 'scp', host: host, path: path);
  }

  if (RegExp(r'%(?![0-9A-Fa-f]{2})').hasMatch(trimmed)) return null;
  final parsed = Uri.tryParse(trimmed);
  if (parsed == null ||
      !const {'https', 'http', 'ssh'}.contains(parsed.scheme.toLowerCase())) {
    return null;
  }
  final host = normalizeGitRemoteHost(parsed.host);
  String path;
  try {
    path = Uri.decodeComponent(parsed.path);
  } on FormatException {
    return null;
  }
  final normalizedPath = _normalizeRemotePath(path);
  if (!_isValidRemoteHost(host) || normalizedPath == null) return null;
  return GitRemoteLocation(
    transport: parsed.scheme.toLowerCase(),
    host: host,
    path: normalizedPath,
  );
}

GitHubRemoteIdentity? parseGitHubRemoteUrl(String remoteUrl) {
  final location = parseGitRemoteLocation(remoteUrl);
  if (location == null || !isGitHubHost(location.host)) return null;
  return parseGitHubRemoteIdentity(location.path);
}

GitHubRemoteIdentity? parseGitHubRemoteIdentity(String path) {
  final segments = path.split('/').where((value) => value.isNotEmpty).toList();
  if (segments.length != 2) return null;
  return GitHubRemoteIdentity(
    owner: segments[0],
    name: segments[1],
    repo: '${segments[0]}/${segments[1]}',
  );
}

bool isGitHubHost(String host) =>
    const {'github.com'}.contains(normalizeGitRemoteHost(host));

String normalizeGitRemoteHost(String host) =>
    host.trim().replaceFirst(RegExp(r'\.+$'), '').toLowerCase();

String? _normalizeRemotePath(String value) {
  var path = value.trim().replaceAll(RegExp(r'^/+|/+$'), '');
  if (path.endsWith('.git')) path = path.substring(0, path.length - 4);
  return path.isEmpty ? null : path;
}

bool _isValidRemoteHost(String host) =>
    RegExp(r'^[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$').hasMatch(host);
