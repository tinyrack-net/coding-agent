import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';

import '../core/daemon_client.dart';
import 'providers_snapshot.dart';

const draftProviderFeaturesQueryRoot = 'providerFeatures';

final class DraftProviderFeaturesScope {
  DraftProviderFeaturesScope({
    required this.client,
    required this.serverId,
    required this.draftConfig,
    this.enabled = true,
  }) : _identity = jsonEncode(
         _canonicalValue(
           {
             ...draftConfig.toJson(),
             'cwd': normalizeProvidersSnapshotCwd(draftConfig.cwd) ?? '',
             // Paseo keys feature discovery by the selections which define the
             // feature surface, not by the current feature values.
           }..remove('featureValues'),
         ),
       );

  final DaemonClient client;
  final String serverId;
  final ListCommandsDraftConfig draftConfig;
  final bool enabled;
  final String _identity;

  List<Object?> get queryKey => [
    draftProviderFeaturesQueryRoot,
    serverId,
    draftConfig.provider,
    normalizeProvidersSnapshotCwd(draftConfig.cwd) ?? '',
    draftConfig.modeId,
    draftConfig.model,
    draftConfig.thinkingOptionId,
  ];

  @override
  bool operator ==(Object other) =>
      other is DraftProviderFeaturesScope &&
      identical(other.client, client) &&
      other.serverId == serverId &&
      other.enabled == enabled &&
      other._identity == _identity;

  @override
  int get hashCode =>
      Object.hash(identityHashCode(client), serverId, enabled, _identity);
}

Object? _canonicalValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => '$key').toList()..sort();
    return {for (final key in keys) key: _canonicalValue(value[key])};
  }
  if (value is List) return value.map(_canonicalValue).toList();
  return value;
}
