import 'forge.dart';

final class ForgeBlobUrlInput {
  const ForgeBlobUrlInput({
    required this.remoteUrl,
    required this.branch,
    required this.path,
    this.lineStart,
    this.lineEnd,
  });

  final String? remoteUrl;
  final String? branch;
  final String? path;
  final int? lineStart;
  final int? lineEnd;
}

final class ForgeBranchTreeUrlInput {
  const ForgeBranchTreeUrlInput({
    required this.remoteUrl,
    required this.branch,
  });

  final String? remoteUrl;
  final String? branch;
}

final class _ForgeUrlGrammar {
  const _ForgeUrlGrammar({
    required this.treeInfix,
    required this.blobInfix,
    required this.lineAnchor,
  });

  final String treeInfix;
  final String blobInfix;
  final String Function(int start, int? end) lineAnchor;
}

final class GitRemoteLocation {
  const GitRemoteLocation({required this.host, required this.path});

  final String host;
  final String path;
}

final class _ForgeWebLocation {
  const _ForgeWebLocation({required this.host, required this.repo});

  final String host;
  final String repo;
}

final _scpRemotePattern = RegExp(r'^[^@]+@([^:]+):(.+)$');
final _validHostPattern = RegExp(r'^[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?$');

final _forgeUrlGrammars = <String, _ForgeUrlGrammar>{
  'github': _ForgeUrlGrammar(
    treeInfix: '/tree/',
    blobInfix: '/blob/',
    lineAnchor: _githubLineAnchor,
  ),
  'gitlab': _ForgeUrlGrammar(
    treeInfix: '/-/tree/',
    blobInfix: '/-/blob/',
    lineAnchor: _gitLabLineAnchor,
  ),
  for (final id in ['gitea', 'forgejo', 'codeberg'])
    id: _ForgeUrlGrammar(
      treeInfix: '/src/branch/',
      blobInfix: '/src/branch/',
      lineAnchor: _githubLineAnchor,
    ),
};

bool hasForgeWebUrls(String forge) => _forgeUrlGrammars.containsKey(forge);

String? buildForgeBranchTreeUrl(String forge, ForgeBranchTreeUrlInput input) {
  final grammar = _forgeUrlGrammars[forge];
  final location = _resolveForgeWebLocation(forge, input.remoteUrl);
  final branch = input.branch?.trim();
  if (grammar == null ||
      location == null ||
      branch == null ||
      branch.isEmpty ||
      branch == 'HEAD') {
    return null;
  }
  return 'https://${location.host}/${location.repo}'
      '${grammar.treeInfix}${_encodeSegments(branch)}';
}

String? buildForgeBlobUrl(String forge, ForgeBlobUrlInput input) {
  final grammar = _forgeUrlGrammars[forge];
  final location = _resolveForgeWebLocation(forge, input.remoteUrl);
  final branch = input.branch?.trim();
  final path = _normalizeBlobPath(input.path);
  if (grammar == null ||
      location == null ||
      branch == null ||
      branch.isEmpty ||
      branch == 'HEAD' ||
      path == null) {
    return null;
  }
  var url =
      'https://${location.host}/${location.repo}${grammar.blobInfix}'
      '${_encodeSegments(branch)}/${_encodeSegments(path)}';
  final lineStart = input.lineStart;
  if (lineStart != null && lineStart > 0) {
    url += grammar.lineAnchor(lineStart, input.lineEnd);
  }
  return url;
}

_ForgeWebLocation? _resolveForgeWebLocation(String forge, String? remoteUrl) {
  if (remoteUrl == null || remoteUrl.isEmpty) return null;
  final location = parseGitRemoteLocation(remoteUrl);
  if (location == null || !_isValidRepoPath(location.path)) return null;
  final cloudHosts = getForgeDefinition(forge)?.cloudHosts ?? const [];
  final normalizedCloudHosts = cloudHosts.map(normalizeGitRemoteHost).toList();
  final host = normalizedCloudHosts.contains(location.host)
      ? normalizedCloudHosts.first
      : location.host;
  return _ForgeWebLocation(host: host, repo: location.path);
}

GitRemoteLocation? parseGitRemoteLocation(String remoteUrl) {
  final trimmed = remoteUrl.trim();
  if (trimmed.isEmpty) return null;
  final scpMatch = _scpRemotePattern.firstMatch(trimmed);
  if (scpMatch != null) {
    final host = normalizeGitRemoteHost(scpMatch.group(1) ?? '');
    final path = _normalizeRemotePath(scpMatch.group(2) ?? '');
    if (!_validHostPattern.hasMatch(host) || path == null) return null;
    return GitRemoteLocation(host: host, path: path);
  }

  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      !const {'https', 'http', 'ssh'}.contains(uri.scheme.toLowerCase())) {
    return null;
  }
  final host = normalizeGitRemoteHost(uri.host);
  String decodedPath;
  try {
    decodedPath = Uri.decodeComponent(uri.path);
  } on FormatException {
    return null;
  }
  final path = _normalizeRemotePath(decodedPath);
  if (!_validHostPattern.hasMatch(host) || path == null) return null;
  return GitRemoteLocation(host: host, path: path);
}

String normalizeGitRemoteHost(String host) =>
    host.trim().replaceFirst(RegExp(r'\.+$'), '').toLowerCase();

String? _normalizeRemotePath(String path) {
  var normalized = path.trim().replaceAll(RegExp(r'^/+|/+$'), '');
  if (normalized.endsWith('.git')) {
    normalized = normalized.substring(0, normalized.length - 4);
  }
  return normalized.isEmpty ? null : normalized;
}

bool _isValidRepoPath(String path) {
  final segments = path.split('/').where((segment) => segment.isNotEmpty);
  return segments.isNotEmpty && !segments.contains('..');
}

String? _normalizeBlobPath(String? path) {
  final trimmed = path
      ?.trim()
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'^/+'), '');
  if (trimmed == null || trimmed.isEmpty) return null;
  final segments = <String>[];
  for (final segment in trimmed.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isEmpty) return null;
      segments.removeLast();
    } else {
      segments.add(segment);
    }
  }
  return segments.isEmpty ? null : segments.join('/');
}

String _encodeSegments(String value) =>
    value.split('/').map(Uri.encodeComponent).join('/');

String _githubLineAnchor(int start, int? end) =>
    end != null && end > start ? '#L$start-L$end' : '#L$start';

String _gitLabLineAnchor(int start, int? end) =>
    end != null && end > start ? '#L$start-$end' : '#L$start';
