import 'package:agent_protocol/agent_protocol.dart';

final class ProviderDiscoveredModelsCache {
  const ProviderDiscoveredModelsCache({
    required this.serverId,
    required this.provider,
    required this.models,
  });

  final String serverId;
  final String provider;
  final List<ProviderModelDefinition> models;
}

final class ProviderDiscoveredModelsResult {
  const ProviderDiscoveredModelsResult({
    required this.models,
    required this.cache,
  });

  final List<ProviderModelDefinition> models;
  final ProviderDiscoveredModelsCache? cache;
}

ProviderDiscoveredModelsResult resolveProviderDiscoveredModels({
  required String serverId,
  required String provider,
  required List<ProviderModelDefinition>? currentModels,
  required bool providerSnapshotRefreshing,
  required ProviderDiscoveredModelsCache? previousCache,
}) {
  if (currentModels != null && currentModels.isNotEmpty) {
    final cache = ProviderDiscoveredModelsCache(
      serverId: serverId,
      provider: provider,
      models: currentModels,
    );
    return ProviderDiscoveredModelsResult(models: currentModels, cache: cache);
  }

  if (providerSnapshotRefreshing &&
      previousCache?.serverId == serverId &&
      previousCache?.provider == provider) {
    return ProviderDiscoveredModelsResult(
      models: previousCache!.models,
      cache: previousCache,
    );
  }

  return ProviderDiscoveredModelsResult(models: const [], cache: previousCache);
}
