import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';

import '../core/daemon_client.dart';
import 'providers_snapshot.dart';

const agentCommandsQueryRoot = 'agentCommands';

final class AgentCommandsScope {
  AgentCommandsScope({
    required this.client,
    required this.serverId,
    required this.agentId,
    this.draftConfig,
    this.enabled = true,
  }) : _draftIdentity = draftConfig == null
           ? null
           : _canonicalJson({
               ...draftConfig.toJson(),
               'cwd': normalizeProvidersSnapshotCwd(draftConfig.cwd) ?? '',
             });

  final DaemonClient client;
  final String serverId;
  final String agentId;
  final ListCommandsDraftConfig? draftConfig;
  final bool enabled;
  final String? _draftIdentity;

  bool get isDraft => draftConfig != null;

  List<Object?> get queryRoot => [agentCommandsQueryRoot, serverId];

  List<Object?> get queryKey {
    final draft = draftConfig;
    if (draft == null) {
      return [agentCommandsQueryRoot, serverId, 'session', agentId];
    }
    return [
      agentCommandsQueryRoot,
      serverId,
      'draft',
      draft.provider,
      'cwd',
      normalizeProvidersSnapshotCwd(draft.cwd) ?? '',
      'mode',
      draft.modeId,
      'model',
      draft.model,
      'thinking',
      draft.thinkingOptionId,
      'features',
      draft.featureValues,
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is AgentCommandsScope &&
      identical(other.client, client) &&
      other.serverId == serverId &&
      (draftConfig != null || other.draftConfig != null
          ? other.draftConfig != null && draftConfig != null
          : other.agentId == agentId) &&
      other.enabled == enabled &&
      other._draftIdentity == _draftIdentity;

  @override
  int get hashCode => Object.hash(
    identityHashCode(client),
    serverId,
    draftConfig == null ? agentId : null,
    enabled,
    _draftIdentity,
  );
}

String _canonicalJson(Object? value) => jsonEncode(_canonicalValue(value));

Object? _canonicalValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => '$key').toList()..sort();
    return {for (final key in keys) key: _canonicalValue(value[key])};
  }
  if (value is List) return value.map(_canonicalValue).toList();
  return value;
}
