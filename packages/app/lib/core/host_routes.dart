import 'dart:convert';

const _base64WorkspaceIdPrefix = 'b64_';

sealed class WorkspaceOpenIntent {
  const WorkspaceOpenIntent();
}

final class AgentWorkspaceOpenIntent extends WorkspaceOpenIntent {
  const AgentWorkspaceOpenIntent(this.agentId);
  final String agentId;
}

final class TerminalWorkspaceOpenIntent extends WorkspaceOpenIntent {
  const TerminalWorkspaceOpenIntent(this.terminalId);
  final String terminalId;
}

final class FileWorkspaceOpenIntent extends WorkspaceOpenIntent {
  const FileWorkspaceOpenIntent(this.path);
  final String path;
}

final class DraftWorkspaceOpenIntent extends WorkspaceOpenIntent {
  const DraftWorkspaceOpenIntent(this.draftId);
  final String draftId;
}

final class SetupWorkspaceOpenIntent extends WorkspaceOpenIntent {
  const SetupWorkspaceOpenIntent(this.workspaceId);
  final String workspaceId;
}

final class HostWorkspaceRoute {
  const HostWorkspaceRoute({required this.serverId, required this.workspaceId});

  final String serverId;
  final String workspaceId;
}

String? _trimNonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _decodeComponent(String value) {
  try {
    return Uri.decodeComponent(value);
  } on FormatException {
    return value;
  }
}

String _toBase64UrlNoPad(String value) =>
    base64Url.encode(utf8.encode(value)).replaceFirst(RegExp(r'=+$'), '');

String? _decodeBase64UrlNoPadUtf8(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(normalized)) {
    return null;
  }
  try {
    return utf8.decode(
      base64Url.decode(base64Url.normalize(normalized)),
      allowMalformed: true,
    );
  } on FormatException {
    return null;
  }
}

String? _tryDecodeBase64UrlNoPadUtf8(String value) {
  final normalized = value.trim();
  final decoded = _decodeBase64UrlNoPadUtf8(normalized);
  if (decoded == null || decoded.isEmpty) return null;
  return _toBase64UrlNoPad(decoded) == normalized ? decoded : null;
}

bool _isLegacyPathLike(String value) =>
    value.contains('/') ||
    value.contains(r'\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);

bool _hasLegacyDecodeNoise(String value) => value.runes.any(
  (codePoint) => codePoint < 0x20 || codePoint == 0x7f || codePoint == 0xfffd,
);

String encodeWorkspaceIdForPathSegment(String workspaceId) {
  final normalized = _trimNonEmpty(workspaceId);
  if (normalized == null) return '';
  if (RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(normalized)) return normalized;
  return '$_base64WorkspaceIdPrefix${_toBase64UrlNoPad(normalized)}';
}

String? decodeWorkspaceIdFromPathSegment(String workspaceIdSegment) {
  final segment = _trimNonEmpty(workspaceIdSegment);
  if (segment == null) return null;
  final decoded = _trimNonEmpty(_decodeComponent(segment));
  if (decoded == null) return null;

  if (decoded.startsWith(_base64WorkspaceIdPrefix)) {
    final payload = decoded.substring(_base64WorkspaceIdPrefix.length);
    return _trimNonEmpty(
      _tryDecodeBase64UrlNoPadUtf8(payload) ??
          _decodeBase64UrlNoPadUtf8(payload),
    );
  }

  // COMPAT(legacyPathWorkspaceId): Paseo links before v0.1.95 encoded the
  // workspace path directly, without the b64_ marker.
  final canonical = _tryDecodeBase64UrlNoPadUtf8(decoded);
  if (canonical != null &&
      _isLegacyPathLike(canonical) &&
      !_hasLegacyDecodeNoise(canonical)) {
    return canonical.trim();
  }
  final relaxed = _decodeBase64UrlNoPadUtf8(decoded);
  if (relaxed != null &&
      _isLegacyPathLike(relaxed) &&
      !_hasLegacyDecodeNoise(relaxed)) {
    return relaxed.trim();
  }
  return decoded.trim();
}

String encodeFilePathForPathSegment(String filePath) {
  final normalized = _trimNonEmpty(filePath);
  return normalized == null ? '' : _toBase64UrlNoPad(normalized);
}

String? decodeFilePathFromPathSegment(String filePathSegment) {
  final segment = _trimNonEmpty(filePathSegment);
  if (segment == null) return null;
  final decoded = _trimNonEmpty(_decodeComponent(segment));
  return decoded == null ? null : _tryDecodeBase64UrlNoPadUtf8(decoded);
}

WorkspaceOpenIntent? parseWorkspaceOpenIntent(String? value) {
  final normalized = _trimNonEmpty(value);
  if (normalized == null) return null;
  final separator = normalized.indexOf(':');
  if (separator <= 0 || separator >= normalized.length - 1) return null;
  final kind = normalized.substring(0, separator);
  final payload = _trimNonEmpty(normalized.substring(separator + 1));
  if (payload == null) return null;
  return switch (kind) {
    'agent' => AgentWorkspaceOpenIntent(payload),
    'terminal' => TerminalWorkspaceOpenIntent(payload),
    'draft' => DraftWorkspaceOpenIntent(payload),
    'file' => switch (decodeFilePathFromPathSegment(payload)) {
      final String path => FileWorkspaceOpenIntent(path),
      null => null,
    },
    'setup' => switch (decodeWorkspaceIdFromPathSegment(payload)) {
      final String workspaceId => SetupWorkspaceOpenIntent(workspaceId),
      null => null,
    },
    _ => null,
  };
}

HostWorkspaceRoute? parseHostWorkspaceRouteFromUri(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.length != 4 ||
      segments[0] != 'h' ||
      segments[2] != 'workspace') {
    return null;
  }
  final serverId = _trimNonEmpty(segments[1]);
  final workspaceId = decodeWorkspaceIdFromPathSegment(segments[3]);
  if (serverId == null || workspaceId == null) return null;
  return HostWorkspaceRoute(serverId: serverId, workspaceId: workspaceId);
}

WorkspaceOpenIntent? parseHostWorkspaceOpenIntentFromUri(Uri uri) =>
    parseWorkspaceOpenIntent(uri.queryParameters['open']);

String buildHostWorkspaceRoute(String serverId, String workspaceId) {
  final host = _trimNonEmpty(serverId);
  final workspace = _trimNonEmpty(workspaceId);
  if (host == null || workspace == null) return '/';
  final encodedWorkspace = encodeWorkspaceIdForPathSegment(workspace);
  return '/h/${Uri.encodeComponent(host)}/workspace/'
      '${Uri.encodeComponent(encodedWorkspace)}';
}

String buildHostWorkspaceOpenRoute(
  String serverId,
  String workspaceId,
  String openIntent,
) {
  final base = buildHostWorkspaceRoute(serverId, workspaceId);
  final intent = _trimNonEmpty(openIntent);
  if (base == '/' || intent == null) return base;
  return '$base?open=${Uri.encodeQueryComponent(intent)}';
}

enum KnownHostRouteResolution { render, openProject, welcome }

KnownHostRouteResolution resolveKnownHostRoute({
  required String? routeServerId,
  required Iterable<String> serverIds,
}) {
  final routeHost = _trimNonEmpty(routeServerId);
  final hosts = serverIds.toList(growable: false);
  if (routeHost != null && hosts.contains(routeHost)) {
    return KnownHostRouteResolution.render;
  }
  return hosts.isEmpty
      ? KnownHostRouteResolution.welcome
      : KnownHostRouteResolution.openProject;
}

String buildCodingAgentDeepLink(String route) {
  final normalized = route.trim();
  if (!normalized.startsWith('/')) {
    throw ArgumentError.value(route, 'route', 'must start with /');
  }
  return 'coding-agent:/$normalized';
}

/// Converts the registered custom-scheme form
/// `coding-agent://h/:serverId/workspace/:workspaceId` back to the same route
/// used by Flutter Web and GoRouter.
String? routeFromCodingAgentDeepLink(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null || uri.scheme.toLowerCase() != 'coding-agent') return null;
  if (uri.host.isEmpty) return null;
  final path = '/${uri.host}${uri.path}';
  if (!path.startsWith('/h/')) return null;
  return Uri(
    path: path,
    query: uri.hasQuery ? uri.query : null,
    fragment: uri.hasFragment ? uri.fragment : null,
  ).toString();
}
