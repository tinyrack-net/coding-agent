import 'package:agent_protocol/agent_protocol.dart';

import 'executable_resolver.dart';
import 'provider_manifest.dart';

typedef ProviderCommandResolver =
    Future<String?> Function(PaseoProviderDefinition definition);
typedef ProviderConfigResolver = MutableDaemonConfig Function();

final class PaseoProviderCatalogRegistry {
  PaseoProviderCatalogRegistry({
    ExecutableResolver? executableResolver,
    ProviderCommandResolver? commandResolver,
    List<PaseoProviderDefinition>? definitions,
    ProviderConfigResolver? configResolver,
    DateTime Function()? now,
  }) : _resolver = executableResolver ?? ExecutableResolver(),
       _commandResolver = commandResolver,
       _baseDefinitions = definitions ?? PaseoProviderManifest.definitions,
       _configResolver = configResolver,
       _now = now ?? DateTime.now;

  final ExecutableResolver _resolver;
  final ProviderCommandResolver? _commandResolver;
  final ProviderConfigResolver? _configResolver;
  final DateTime Function() _now;
  final List<PaseoProviderDefinition> _baseDefinitions;

  List<PaseoProviderDefinition> get definitions {
    final config = _configResolver?.call();
    if (config == null) return _baseDefinitions;
    final overrides = config.providers;
    final resolved = <PaseoProviderDefinition>[
      for (final definition in _baseDefinitions)
        _applyOverride(definition, overrides[definition.id]),
    ];
    final builtinIds = {
      for (final definition in _baseDefinitions) definition.id,
    };
    for (final entry in overrides.entries) {
      if (builtinIds.contains(entry.key)) continue;
      resolved.add(_customDefinition(entry.key, entry.value));
    }
    return List.unmodifiable(resolved);
  }

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
    error: error,
    models: status == ProviderCatalogStatus.ready ? const [] : null,
    modes: status == ProviderCatalogStatus.ready
        ? [for (final entry in definition.modes) entry.mode]
        : null,
    fetchedAt: fetchedAt,
    label: definition.label,
    description: definition.description,
    defaultModeId: definition.defaultModeId,
    source: definition.source,
  );
}

PaseoProviderDefinition _applyOverride(
  PaseoProviderDefinition definition,
  MutableDaemonProviderConfig? override,
) {
  if (override == null) return definition;
  final command = _command(override.extra['command']);
  return PaseoProviderDefinition(
    id: definition.id,
    label: _string(override.extra['label']) ?? definition.label,
    description:
        _string(override.extra['description']) ?? definition.description,
    command: command?.first ?? definition.command,
    commandArgs: command == null
        ? definition.commandArgs
        : command.skip(1).toList(growable: false),
    environment: _stringMap(override.extra['env']) ?? definition.environment,
    providerParams:
        _objectMap(override.extra['params']) ?? definition.providerParams,
    enabledByDefault: override.enabled ?? definition.enabledByDefault,
    defaultModeId: definition.defaultModeId,
    modes: definition.modes,
    capabilities: definition.capabilities,
    source: definition.source,
  );
}

PaseoProviderDefinition _customDefinition(
  String id,
  MutableDaemonProviderConfig config,
) {
  final extendsId = _string(config.extra['extends']);
  if (extendsId != 'acp') {
    throw StateError("Custom provider '$id' requires extends: acp");
  }
  final command = _command(config.extra['command']);
  if (command == null) {
    throw StateError("ACP provider '$id' requires a command");
  }
  final providerParams = _objectMap(config.extra['params']) ?? const {};
  final supportsMcpServers = providerParams['supportsMcpServers'];
  return PaseoProviderDefinition(
    id: id,
    label: _string(config.extra['label']) ?? id,
    description: _string(config.extra['description']) ?? 'Custom ACP provider',
    command: command.first,
    commandArgs: command.skip(1).toList(growable: false),
    environment: _stringMap(config.extra['env']) ?? const {},
    providerParams: providerParams,
    enabledByDefault: config.enabled ?? true,
    defaultModeId: null,
    modes: const [],
    capabilities: {
      ...paseoAcpCapabilities,
      if (supportsMcpServers is bool) 'supportsMcpServers': supportsMcpServers,
    },
    source: 'custom',
  );
}

String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

List<String>? _command(Object? value) {
  if (value is! List ||
      value.isEmpty ||
      value.any((entry) => entry is! String || entry.isEmpty)) {
    return null;
  }
  return value.cast<String>();
}

Map<String, String>? _stringMap(Object? value) {
  if (value is! Map ||
      value.keys.any((key) => key is! String) ||
      value.values.any((entry) => entry is! String)) {
    return null;
  }
  return Map.unmodifiable(value.cast<String, String>());
}

Map<String, Object?>? _objectMap(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) return null;
  return Map.unmodifiable(value.cast<String, Object?>());
}
