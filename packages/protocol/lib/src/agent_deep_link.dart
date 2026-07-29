/// Frozen Paseo 0.2.0 agent deep-link contract with Tinyrack branding.
library;

final class AgentDeepLinkTarget {
  const AgentDeepLinkTarget({required this.serverId, required this.agentId});

  final String serverId;
  final String agentId;

  @override
  bool operator ==(Object other) =>
      other is AgentDeepLinkTarget &&
      other.serverId == serverId &&
      other.agentId == agentId;

  @override
  int get hashCode => Object.hash(serverId, agentId);
}

String buildAgentDeepLinkRoute(AgentDeepLinkTarget target) {
  final normalized = _normalizeTarget(target);
  return '/h/${Uri.encodeComponent(normalized.serverId)}/agent/'
      '${Uri.encodeComponent(normalized.agentId)}';
}

String buildAgentDeepLink(AgentDeepLinkTarget target) =>
    'coding-agent:/${buildAgentDeepLinkRoute(target)}';

AgentDeepLinkTarget? parseAgentDeepLink(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      uri.scheme.toLowerCase() != 'coding-agent' ||
      uri.host != 'h' ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final segments = uri.pathSegments;
  if (segments.length != 3 || segments[1] != 'agent') return null;
  final serverId = _trimNonEmpty(segments[0]);
  final agentId = _trimNonEmpty(segments[2]);
  if (serverId == null || agentId == null) return null;
  return AgentDeepLinkTarget(serverId: serverId, agentId: agentId);
}

AgentDeepLinkTarget _normalizeTarget(AgentDeepLinkTarget target) {
  final serverId = _trimNonEmpty(target.serverId);
  final agentId = _trimNonEmpty(target.agentId);
  if (serverId == null || agentId == null) {
    throw ArgumentError('Agent deep links require a server ID and agent ID.');
  }
  return AgentDeepLinkTarget(serverId: serverId, agentId: agentId);
}

String? _trimNonEmpty(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
