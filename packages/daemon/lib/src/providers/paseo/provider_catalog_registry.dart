import 'package:agent_protocol/agent_protocol.dart';

import 'executable_resolver.dart';
import 'provider_manifest.dart';

typedef ProviderCommandResolver =
    Future<String?> Function(PaseoProviderDefinition definition);

final class PaseoProviderCatalogRegistry {
  PaseoProviderCatalogRegistry({
    ExecutableResolver? executableResolver,
    ProviderCommandResolver? commandResolver,
    List<PaseoProviderDefinition>? definitions,
    DateTime Function()? now,
  }) : _resolver = executableResolver ?? ExecutableResolver(),
       _commandResolver = commandResolver,
       definitions = definitions ?? PaseoProviderManifest.definitions,
       _now = now ?? DateTime.now;

  final ExecutableResolver _resolver;
  final ProviderCommandResolver? _commandResolver;
  final DateTime Function() _now;
  final List<PaseoProviderDefinition> definitions;

  PaseoProviderDefinition? definition(String provider) {
    for (final definition in definitions) {
      if (definition.id == provider) return definition;
    }
    return null;
  }

  Future<String?> resolveCommand(PaseoProviderDefinition definition) {
    final override = _commandResolver;
    if (override != null) return override(definition);
    if (definition.id == 'codex') return _resolver.findCodex();
    return _resolver.find(definition.command);
  }

  Future<ProviderAvailabilityV2> availability(
    PaseoProviderDefinition definition,
  ) async {
    if (!definition.enabledByDefault) {
      return ProviderAvailabilityV2(provider: definition.id, available: false);
    }
    try {
      return ProviderAvailabilityV2(
        provider: definition.id,
        available: await resolveCommand(definition) != null,
      );
    } catch (error) {
      return ProviderAvailabilityV2(
        provider: definition.id,
        available: false,
        error: error.toString(),
      );
    }
  }

  Future<List<ProviderAvailabilityV2>> listAvailability() =>
      Future.wait(definitions.map(availability));

  Future<List<ProviderSnapshotEntry>> snapshot({
    Iterable<String>? providers,
    String? cwd,
  }) async {
    final filter = providers == null ? null : providers.toSet();
    final selected = [
      for (final definition in definitions)
        if (filter == null || filter.contains(definition.id)) definition,
    ];
    return Future.wait(selected.map(_snapshotEntry));
  }

  Future<ProviderSnapshotEntry> _snapshotEntry(
    PaseoProviderDefinition definition,
  ) async {
    final fetchedAt = _now().toUtc().toIso8601String();
    if (!definition.enabledByDefault) {
      return _entry(
        definition,
        ProviderCatalogStatus.unavailable,
        fetchedAt,
        enabled: false,
      );
    }
    try {
      final available = await resolveCommand(definition) != null;
      return _entry(
        definition,
        available
            ? ProviderCatalogStatus.ready
            : ProviderCatalogStatus.unavailable,
        fetchedAt,
      );
    } catch (error) {
      return _entry(
        definition,
        ProviderCatalogStatus.error,
        fetchedAt,
        error: error.toString(),
      );
    }
  }

  ProviderSnapshotEntry _entry(
    PaseoProviderDefinition definition,
    ProviderCatalogStatus status,
    String fetchedAt, {
    bool enabled = true,
    String? error,
  }) => ProviderSnapshotEntry(
    provider: definition.id,
    status: status,
    enabled: enabled,
    source: 'builtin',
    error: error,
    models: status == ProviderCatalogStatus.ready ? const [] : null,
    modes: status == ProviderCatalogStatus.ready
        ? [for (final entry in definition.modes) entry.mode]
        : null,
    fetchedAt: fetchedAt,
    label: definition.label,
    description: definition.description,
    defaultModeId: definition.defaultModeId,
  );
}
