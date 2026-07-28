final class AgentCreateModeParent {
  const AgentCreateModeParent({
    required this.provider,
    required this.modeId,
    required this.isUnattended,
  });

  final String provider;
  final String? modeId;
  final bool isUnattended;
}

final class AgentCreateModeRequest {
  const AgentCreateModeRequest({
    required this.cwd,
    required this.targetProvider,
    required this.requestedMode,
    required this.parent,
    required this.unattended,
  });

  final String cwd;
  final String targetProvider;
  final String? requestedMode;
  final AgentCreateModeParent? parent;
  final bool unattended;
}

final class AgentCreateConfigRequest {
  const AgentCreateConfigRequest({
    required this.cwd,
    required this.targetProvider,
    required this.requestedMode,
    required this.featureValues,
    required this.parent,
    required this.unattended,
  });

  final String cwd;
  final String targetProvider;
  final String? requestedMode;
  final Map<String, Object?> featureValues;
  final AgentCreateModeParent? parent;
  final bool unattended;
}

final class ResolvedAgentCreateConfig {
  const ResolvedAgentCreateConfig({
    required this.modeId,
    required this.featureValues,
  });

  final String? modeId;
  final Map<String, Object?> featureValues;
}

typedef AgentCreateModeResolver =
    Future<String?> Function(AgentCreateModeRequest request);

String? resolveAndValidateCreateAgentMode({
  required String? requestedMode,
  required String targetProvider,
  required AgentCreateModeParent? parent,
  required bool unattended,
  required List<String>? availableModes,
  String? targetUnattendedMode,
}) {
  if (requestedMode != null) {
    if (availableModes != null && !availableModes.contains(requestedMode)) {
      throw StateError(
        "Invalid mode '$requestedMode' for provider '$targetProvider'. "
        'Available modes: ${_listModes(availableModes)}',
      );
    }
    return requestedMode;
  }

  if (parent == null) {
    if (unattended && targetUnattendedMode != null) {
      return targetUnattendedMode;
    }
    return null;
  }

  if (parent.provider == targetProvider) {
    return parent.modeId;
  }

  if ((unattended || parent.isUnattended) && targetUnattendedMode != null) {
    return targetUnattendedMode;
  }

  if (availableModes?.isEmpty == true) {
    return null;
  }

  throw StateError(
    "cannot inherit mode '${parent.modeId ?? '<none>'}' from caller "
    "(provider '${parent.provider}') for new agent "
    "(provider '$targetProvider'). Pass an explicit mode. "
    "Available modes for '$targetProvider': ${_listModes(availableModes)}",
  );
}

bool isDefaultAgentCreateConfigUnattended({
  required String? modeId,
  required Map<String, bool> unattendedModes,
}) {
  if (modeId == null) return false;
  return unattendedModes[modeId] == true;
}

String _listModes(List<String>? modes) {
  if (modes == null) return 'unknown';
  return modes.isEmpty ? '(none)' : modes.join(', ');
}
