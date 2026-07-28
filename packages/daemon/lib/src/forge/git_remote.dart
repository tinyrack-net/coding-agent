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

GitRemoteLocation? parseGitRemoteLocation(String remoteUrl) {
  final trimmed = remoteUrl.trim();
  if (trimmed.isEmpty) return null;
  final scp = RegExp(r'^[^@]+@([^:]+):(.+)$').firstMatch(trimmed);
  if (scp != null) {
    final host = normalizeGitRemoteHost(scp.group(1)!);
    final path = _normalizeRemotePath(scp.group(2)!);
    return _validHost(host) && path != null
        ? GitRemoteLocation(transport: 'scp', host: host, path: path)
        : null;
  }

  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      !const {'http', 'https', 'ssh'}.contains(uri.scheme.toLowerCase())) {
    return null;
  }
  final host = normalizeGitRemoteHost(uri.host);
  String path;
  try {
    path = Uri.decodeComponent(uri.path);
  } on FormatException {
    return null;
  }
  final normalizedPath = _normalizeRemotePath(path);
  if (!_validHost(host) || normalizedPath == null) return null;
  return GitRemoteLocation(
    transport: uri.scheme.toLowerCase(),
    host: host,
    path: normalizedPath,
  );
}

String normalizeGitRemoteHost(String host) =>
    host.trim().replaceFirst(RegExp(r'\.+$'), '').toLowerCase();

String? forgeForKnownHost(String host) =>
    switch (normalizeGitRemoteHost(host)) {
      'github.com' => 'github',
      'gitlab.com' => 'gitlab',
      'gitea.com' => 'gitea',
      'codeberg.org' => 'codeberg',
      _ => null,
    };

String? _normalizeRemotePath(String value) {
  var path = value.trim().replaceAll(RegExp(r'^/+|/+$'), '');
  if (path.endsWith('.git')) path = path.substring(0, path.length - 4);
  return path.isEmpty ? null : path;
}

bool _validHost(String host) =>
    RegExp(r'^[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$').hasMatch(host);
