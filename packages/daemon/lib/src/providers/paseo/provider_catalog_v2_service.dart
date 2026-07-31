import 'package:agent_protocol/agent_protocol.dart';

import 'provider_catalog_registry.dart';
import 'provider_manifest.dart';

typedef ProviderDraftFeatureResolver =
    Future<List<AgentFeature>> Function(ListCommandsDraftConfig config);

final class ProviderCatalogV2Service {
  ProviderCatalogV2Service({
    required this.registry,
    ProviderDraftFeatureResolver? featureResolver,
    DateTime Function()? now,
    void Function(ProvidersSnapshotUpdate update)? onSnapshotChanged,
    bool nonBlockingSnapshotReads = false,
  }) : _now = now ?? DateTime.now,
       _featureResolver =
           featureResolver ??
           ((config) async => paseoProviderDraftFeatures(config)),
       _onSnapshotChanged = onSnapshotChanged,
       _nonBlockingSnapshotReads = nonBlockingSnapshotReads;

  final PaseoProviderCatalogRegistry registry;
  final DateTime Function() _now;
  final ProviderDraftFeatureResolver _featureResolver;
  final void Function(ProvidersSnapshotUpdate update)? _onSnapshotChanged;
  final bool _nonBlockingSnapshotReads;

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    return switch (message['type']) {
      'list_available_providers_request' => _listAvailable(
        ListAvailableProvidersRequest.fromJson(message),
      ),
      'list_provider_models_request' => _listModels(
        ListProviderModelsRequest.fromJson(message),
      ),
      'list_provider_modes_request' => _listModes(
        ListProviderModesRequest.fromJson(message),
      ),
      'list_provider_features_request' => _listFeatures(
        ListProviderFeaturesRequest.fromJson(message),
      ),
      'get_providers_snapshot_request' => _getSnapshot(
        GetProvidersSnapshotRequest.fromJson(message),
      ),
      'refresh_providers_snapshot_request' => _refresh(
        RefreshProvidersSnapshotRequest.fromJson(message),
      ),
      'provider_diagnostic_request' => _diagnostic(
        ProviderDiagnosticRequest.fromJson(message),
      ),
      _ => null,
    };
  }

  Future<Map<String, Object?>> _listAvailable(
    ListAvailableProvidersRequest request,
  ) async {
    try {
      return ListAvailableProvidersResponse(
        requestId: request.requestId,
        providers: await registry.listAvailability(),
        fetchedAt: _timestamp(),
      ).toJson();
    } catch (error) {
      return ListAvailableProvidersResponse(
        requestId: request.requestId,
        providers: const [],
        fetchedAt: _timestamp(),
        error: error.toString(),
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _listModels(
    ListProviderModelsRequest request,
  ) async {
    final fetchedAt = _timestamp();
    final definition = registry.definition(request.provider);
    if (definition == null) {
      return ListProviderModelsResponse(
        provider: request.provider,
        requestId: request.requestId,
        fetchedAt: fetchedAt,
        error: 'Unknown provider: ${request.provider}',
      ).toJson();
    }
    if (!definition.enabledByDefault) {
      return ListProviderModelsResponse(
        provider: request.provider,
        requestId: request.requestId,
        fetchedAt: fetchedAt,
        error: 'Provider ${request.provider} is disabled',
      ).toJson();
    }
    final entry = (await registry.snapshot(
      providers: [request.provider],
    )).single;
    if (entry.status == ProviderCatalogStatus.ready) {
      return ListProviderModelsResponse(
        provider: request.provider,
        requestId: request.requestId,
        fetchedAt: entry.fetchedAt ?? fetchedAt,
        models: entry.models ?? const [],
      ).toJson();
    }
    return ListProviderModelsResponse(
      provider: request.provider,
      requestId: request.requestId,
      fetchedAt: fetchedAt,
      error: entry.status == ProviderCatalogStatus.error
          ? (entry.error ?? 'Failed to list models for ${request.provider}')
          : 'Provider ${request.provider} is not available',
    ).toJson();
  }

  Future<Map<String, Object?>> _listModes(
    ListProviderModesRequest request,
  ) async {
    final fetchedAt = _timestamp();
    final definition = registry.definition(request.provider);
    if (definition == null) {
      return ListProviderModesResponse(
        provider: request.provider,
        requestId: request.requestId,
        fetchedAt: fetchedAt,
        error: 'Unknown provider: ${request.provider}',
      ).toJson();
    }
    if (!definition.enabledByDefault) {
      return ListProviderModesResponse(
        provider: request.provider,
        requestId: request.requestId,
        fetchedAt: fetchedAt,
        error: 'Provider ${request.provider} is disabled',
      ).toJson();
    }
    final entry = (await registry.snapshot(
      providers: [request.provider],
    )).single;
    if (entry.status == ProviderCatalogStatus.ready) {
      return ListProviderModesResponse(
        provider: request.provider,
        requestId: request.requestId,
        fetchedAt: entry.fetchedAt ?? fetchedAt,
        modes: entry.modes ?? const [],
      ).toJson();
    }
    return ListProviderModesResponse(
      provider: request.provider,
      requestId: request.requestId,
      fetchedAt: fetchedAt,
      error: entry.status == ProviderCatalogStatus.error
          ? (entry.error ?? 'Failed to list modes for ${request.provider}')
          : 'Provider ${request.provider} is not available',
    ).toJson();
  }

  Future<Map<String, Object?>> _listFeatures(
    ListProviderFeaturesRequest request,
  ) async {
    final config = request.draftConfig;
    final fetchedAt = _timestamp();
    try {
      final definition = registry.definition(config.provider);
      if (definition == null) {
        throw StateError('Unknown provider: ${config.provider}');
      }
      if (!definition.enabledByDefault) {
        throw StateError('Provider ${config.provider} is disabled');
      }
      if (config.model == null || config.model!.trim().isEmpty) {
        return ListProviderFeaturesResponse(
          provider: config.provider,
          features: const [],
          fetchedAt: fetchedAt,
          requestId: request.requestId,
        ).toJson();
      }
      final availability = await registry.availability(definition);
      if (!availability.available) {
        throw StateError(
          "Provider '${config.provider}' is not available. "
          'Please ensure the CLI is installed.',
        );
      }
      return ListProviderFeaturesResponse(
        provider: config.provider,
        features: await _featureResolver(config),
        fetchedAt: fetchedAt,
        requestId: request.requestId,
      ).toJson();
    } catch (error) {
      return ListProviderFeaturesResponse(
        provider: config.provider,
        error: error.toString(),
        fetchedAt: fetchedAt,
        requestId: request.requestId,
      ).toJson();
    }
  }

  Future<Map<String, Object?>> _getSnapshot(
    GetProvidersSnapshotRequest request,
  ) async => GetProvidersSnapshotResponse(
    entries: await registry.snapshot(
      cwd: request.cwd,
      wait: !_nonBlockingSnapshotReads,
      emitUpdates: _nonBlockingSnapshotReads,
    ),
    generatedAt: _timestamp(),
    requestId: request.requestId,
  ).toJson();

  Future<Map<String, Object?>> _refresh(
    RefreshProvidersSnapshotRequest request,
  ) async {
    await registry.snapshot(
      providers: request.providers,
      cwd: request.cwd,
      force: true,
    );
    final entries = await registry.snapshot(cwd: request.cwd);
    _onSnapshotChanged?.call(
      ProvidersSnapshotUpdate(
        cwd: request.cwd,
        entries: entries,
        generatedAt: _timestamp(),
      ),
    );
    return RefreshProvidersSnapshotResponse(
      requestId: request.requestId,
      acknowledged: true,
    ).toJson();
  }

  Future<Map<String, Object?>> _diagnostic(
    ProviderDiagnosticRequest request,
  ) async {
    try {
      return ProviderDiagnosticResponse(
        provider: request.provider,
        diagnostic: await registry.diagnostic(request.provider),
        requestId: request.requestId,
      ).toJson();
    } catch (error) {
      return {
        'type': 'rpc_error',
        'payload': {
          'requestId': request.requestId,
          'requestType': ProviderDiagnosticRequest.type,
          'error': 'Failed to get provider diagnostic: $error',
          'code': 'provider_diagnostic_failed',
        },
      };
    }
  }

  String _timestamp() => _now().toUtc().toIso8601String();
}
