import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';

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

final class HostAgentRoute {
  const HostAgentRoute({required this.serverId, required this.agentId});

  final String serverId;
  final String agentId;
}

final class NewWorkspaceRouteOptions {
  const NewWorkspaceRouteOptions({
    this.serverId,
    this.sourceDirectory,
    this.displayName,
    this.projectId,
    this.draftId,
  });

  final String? serverId;
  final String? sourceDirectory;
  final String? displayName;
  final String? projectId;
  final String? draftId;
}

enum SettingsSectionSlug {
  general,
  appearance,
  editor,
  shortcuts,
  integrations,
  permissions,
  diagnostics,
  about,
}

enum HostSectionSlug {
  connections,
  agents,
  workspaces,
  providers,
  usage,
  terminals,
  host,
}

const settingsSectionSlugs = SettingsSectionSlug.values;
const hostSectionSlugs = HostSectionSlug.values;

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

HostWorkspaceRoute? parseHostWorkspaceRouteFromPathname(String pathname) {
  final uri = Uri.tryParse(pathname);
  return uri == null ? null : parseHostWorkspaceRouteFromUri(uri);
}

HostAgentRoute? parseHostAgentRouteFromUri(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.length < 4 || segments[0] != 'h' || segments[2] != 'agent') {
    return null;
  }
  final serverId = _trimNonEmpty(segments[1]);
  final agentId = _trimNonEmpty(segments[3]);
  if (serverId == null || agentId == null) return null;
  return HostAgentRoute(serverId: serverId, agentId: agentId);
}

HostAgentRoute? parseHostAgentRouteFromPathname(String pathname) {
  final uri = Uri.tryParse(pathname);
  return uri == null ? null : parseHostAgentRouteFromUri(uri);
}

WorkspaceOpenIntent? parseHostWorkspaceOpenIntentFromUri(Uri uri) =>
    parseWorkspaceOpenIntent(uri.queryParameters['open']);

WorkspaceOpenIntent? parseHostWorkspaceOpenIntentFromPathname(String pathname) {
  final uri = Uri.tryParse(pathname);
  return uri == null ? null : parseHostWorkspaceOpenIntentFromUri(uri);
}

String? parseServerIdFromUri(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.length < 2 || segments.first != 'h') return null;
  return _trimNonEmpty(segments[1]);
}

String? parseServerIdFromPathname(String pathname) {
  final uri = Uri.tryParse(pathname);
  return uri == null ? null : parseServerIdFromUri(uri);
}

String stripHostWorkspaceRouteEchoSearch(String route) {
  final uri = Uri.tryParse(route);
  if (uri == null) return route;
  final selection = parseHostWorkspaceRouteFromUri(uri);
  if (selection == null || !uri.hasQuery) return route;

  final retained = <MapEntry<String, String>>[];
  var didStrip = false;
  for (final entry in uri.queryParametersAll.entries) {
    for (final value in entry.value) {
      final shouldStrip = switch (entry.key) {
        'serverId' => _trimNonEmpty(value) == selection.serverId,
        'workspaceId' =>
          decodeWorkspaceIdFromPathSegment(value) == selection.workspaceId,
        'pop' => value == 'true',
        _ => false,
      };
      if (shouldStrip) {
        didStrip = true;
      } else {
        retained.add(MapEntry(entry.key, value));
      }
    }
  }
  if (!didStrip) return route;

  final query = retained
      .map(
        (entry) =>
            '${Uri.encodeQueryComponent(entry.key)}='
            '${Uri.encodeQueryComponent(entry.value)}',
      )
      .join('&');
  return Uri(
    path: uri.path,
    query: query.isEmpty ? null : query,
    fragment: uri.hasFragment ? uri.fragment : null,
  ).toString();
}

String buildHostWorkspaceRoute(String serverId, String workspaceId) {
  final host = _trimNonEmpty(serverId);
  final workspace = _trimNonEmpty(workspaceId);
  if (host == null || workspace == null) return '/';
  final encodedWorkspace = encodeWorkspaceIdForPathSegment(workspace);
  return '/h/${Uri.encodeComponent(host)}/workspace/'
      '${Uri.encodeComponent(encodedWorkspace)}';
}

String buildHostAgentRoute(String serverId, String agentId) {
  try {
    return buildAgentDeepLinkRoute(
      AgentDeepLinkTarget(serverId: serverId, agentId: agentId),
    );
  } on ArgumentError {
    return '/';
  }
}

String buildHostAgentDetailRoute(
  String serverId,
  String agentId, {
  String? workspaceId,
}) {
  final workspace = _trimNonEmpty(workspaceId);
  final agent = _trimNonEmpty(agentId);
  if (agent == null) return '/';
  if (workspace != null) {
    return buildHostWorkspaceOpenRoute(serverId, workspace, 'agent:$agent');
  }
  return buildHostAgentRoute(serverId, agent);
}

String buildHostWorkspaceOpenRoute(
  String serverId,
  String workspaceId,
  String openIntent,
) {
  final base = buildHostWorkspaceRoute(serverId, workspaceId);
  final intent = _trimNonEmpty(openIntent);
  if (base == '/' || intent == null) return base;
  return '$base?open=${Uri.encodeComponent(intent)}';
}

String buildHostRootRoute(String serverId) {
  final normalized = _trimNonEmpty(serverId);
  return normalized == null ? '/' : '/h/${Uri.encodeComponent(normalized)}';
}

String buildHostOpenProjectRoute(String serverId) {
  final base = buildHostRootRoute(serverId);
  return base == '/' ? base : '$base/open-project';
}

String buildHostSessionsRoute(String serverId) {
  final base = buildHostRootRoute(serverId);
  return base == '/' ? base : '$base/sessions';
}

String buildSessionsRoute() => '/sessions';

String buildSchedulesRoute() => '/schedules';

String buildOpenProjectRoute() => '/open-project';

String buildNewWorkspaceRoute([
  NewWorkspaceRouteOptions options = const NewWorkspaceRouteOptions(),
]) {
  final query = <String, String>{};
  final serverId = _trimNonEmpty(options.serverId);
  if (serverId != null) query['serverId'] = serverId;
  if (options.sourceDirectory case final String sourceDirectory
      when sourceDirectory.isNotEmpty) {
    query['dir'] = sourceDirectory;
  }
  if (options.displayName case final String displayName
      when displayName.isNotEmpty) {
    query['name'] = displayName;
  }
  if (options.projectId case final String projectId when projectId.isNotEmpty) {
    query['projectId'] = projectId;
  }
  if (options.draftId case final String draftId when draftId.isNotEmpty) {
    query['draftId'] = draftId;
  }
  return query.isEmpty
      ? '/new'
      : Uri(path: '/new', queryParameters: query).toString();
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

bool isSettingsSectionSlug(String value) =>
    settingsSectionSlugs.any((section) => section.name == value);

bool isHostSectionSlug(String value) =>
    hostSectionSlugs.any((section) => section.name == value);

HostSectionSlug? normalizeHostSectionSlug(String value) {
  for (final section in hostSectionSlugs) {
    if (section.name == value) return section;
  }
  return switch (value) {
    'orchestration' => HostSectionSlug.agents,
    'daemon' => HostSectionSlug.host,
    _ => null,
  };
}

String buildSettingsRoute() => '/settings';

String buildSettingsSectionRoute(SettingsSectionSlug section) =>
    '/settings/${section.name}';

/// Returns the canonical settings URL for a raw route segment.
///
/// Paseo keeps unknown app sections on the general view, while retaining a
/// small set of pre-0.2 aliases so old desktop shortcuts do not strand users.
String? canonicalSettingsSectionPath(String rawSection) {
  final section = rawSection.trim();
  if (section.isEmpty) {
    return buildSettingsSectionRoute(SettingsSectionSlug.general);
  }
  if (isSettingsSectionSlug(section)) {
    return null;
  }
  return switch (section) {
    'keyboard' => buildSettingsSectionRoute(SettingsSectionSlug.shortcuts),
    // These sections existed in the Flutter MVP. Keep their routes usable
    // until their content is migrated to the corresponding Paseo section.
    'desktop' ||
    'reset' ||
    'projects' ||
    'agents' ||
    'workspaces' ||
    'providers' ||
    'terminals' => null,
    _ => buildSettingsSectionRoute(SettingsSectionSlug.general),
  };
}

/// Returns a host settings URL only when [rawSection] is not already
/// canonical. A null result means the current URL is canonical or the host
/// id is invalid and should be handled by the leaf screen.
String? canonicalHostSettingsSectionPath(String serverId, String rawSection) {
  final normalizedServer = _trimNonEmpty(serverId);
  if (normalizedServer == null) return null;
  final normalized = normalizeHostSectionSlug(rawSection.trim());
  if (normalized == null) {
    return buildSettingsHostSectionRoute(
      normalizedServer,
      HostSectionSlug.connections,
    );
  }
  if (normalized.name == rawSection.trim()) return null;
  return buildSettingsHostSectionRoute(normalizedServer, normalized);
}

String buildSettingsAddHostRoute([Object intentId = '1']) =>
    '/settings/general?addHost=${Uri.encodeComponent('$intentId')}';

String buildSettingsHostRoute(String serverId) {
  final normalized = _trimNonEmpty(serverId);
  if (normalized == null) {
    throw ArgumentError.value(serverId, 'serverId', 'must be non-empty');
  }
  return '/settings/hosts/${Uri.encodeComponent(normalized)}';
}

String buildSettingsHostSectionRoute(
  String serverId,
  HostSectionSlug section,
) => '${buildSettingsHostRoute(serverId)}/${section.name}';

String buildProjectsSettingsRoute() => '/settings/projects';

String buildProjectSettingsRoute(String projectKey) {
  final normalized = _trimNonEmpty(projectKey);
  if (normalized == null) {
    throw ArgumentError.value(projectKey, 'projectKey', 'must be non-empty');
  }
  return '/settings/projects/${Uri.encodeComponent(normalized)}';
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

/// Whether the remembered workspace selection is known to still exist.
///
/// [WorkspaceSelectionStatus.unknown] is not a synonym for missing: until the
/// catalog has hydrated the app cannot tell a deleted workspace from one it
/// has simply not loaded yet, and redirecting on that guess would bounce the
/// user off a workspace that is about to appear.
enum WorkspaceSelectionStatus { unknown, exists, missing }

WorkspaceSelectionStatus resolveWorkspaceSelectionStatus({
  required bool hasHydratedWorkspaces,
  required bool workspaceExists,
}) {
  if (workspaceExists) return WorkspaceSelectionStatus.exists;
  return hasHydratedWorkspaces
      ? WorkspaceSelectionStatus.missing
      : WorkspaceSelectionStatus.unknown;
}

/// Where `/h/:serverId` lands: back on the remembered workspace unless that
/// workspace is known to be gone, otherwise the project picker.
String resolveHostIndexRoute({
  required String serverId,
  required HostWorkspaceRoute? workspaceSelection,
  required WorkspaceSelectionStatus workspaceSelectionStatus,
}) {
  if (workspaceSelection?.serverId == serverId &&
      workspaceSelectionStatus != WorkspaceSelectionStatus.missing) {
    return buildHostWorkspaceRoute(serverId, workspaceSelection!.workspaceId);
  }
  return buildOpenProjectRoute();
}
