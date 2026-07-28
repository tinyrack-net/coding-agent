import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import '../../agent/create_agent_mode.dart';
import 'acp_catalog.dart';
import 'executable_resolver.dart';
import 'provider_manifest.dart';

typedef ProviderCommandResolver =
    Future<String?> Function(PaseoProviderDefinition definition);
typedef ProviderConfigResolver = MutableDaemonConfig Function();
typedef ProviderCatalogProbe =
    Future<AcpProviderCatalog?> Function(
      PaseoProviderDefinition definition,
      String cwd,
    );

final class _CatalogLoad {
  const _CatalogLoad({required this.fingerprint, required this.result});

  final String fingerprint;
  final Future<AcpProviderCatalog?> result;
}

final class PaseoProviderCatalogRegistry {
  PaseoProviderCatalogRegistry({
    ExecutableResolver? executableResolver,
    ProviderCommandResolver? commandResolver,
    List<PaseoProviderDefinition>? definitions,
    ProviderConfigResolver? configResolver,
    ProviderCatalogProbe? catalogProbe,
    DateTime Function()? now,
  }) : _resolver = executableResolver ?? ExecutableResolver(),
       _commandResolver = commandResolver,
       _baseDefinitions = definitions ?? PaseoProviderManifest.definitions,
       _configResolver = configResolver,
       _catalogProbe = catalogProbe,
       _now = now ?? DateTime.now;

  final ExecutableResolver _resolver;
  final ProviderCommandResolver? _commandResolver;
  final ProviderConfigResolver? _configResolver;
  final ProviderCatalogProbe? _catalogProbe;
  final DateTime Function() _now;
  final List<PaseoProviderDefinition> _baseDefinitions;
  final Map<String, _CatalogLoad> _catalogLoads = {};

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
    bool force = false,
  }) async {
    final filter = providers == null ? null : providers.toSet();
    final selected = [
      for (final definition in definitions)
        if (filter == null || filter.contains(definition.id)) definition,
    ];
    final probeCwd = _resolveProbeCwd(cwd);
    return Future.wait(
      selected.map(
        (definition) => _snapshotEntry(definition, cwd: probeCwd, force: force),
      ),
    );
  }

  Future<String?> resolveCreateAgentMode(AgentCreateModeRequest request) async {
    final providerDefinition = definition(request.targetProvider);
    List<String>? availableModes;
    String? targetUnattendedMode;
    if (providerDefinition != null) {
      final entries = await snapshot(
        providers: [request.targetProvider],
        cwd: request.cwd,
      );
      final entry = entries.firstOrNull;
      if (entry?.status == ProviderCatalogStatus.ready) {
        availableModes = [
          for (final mode in entry?.modes ?? const <ProviderMode>[]) mode.id,
        ];
      }
      for (final mode in providerDefinition.modes) {
        if (mode.isUnattended) {
          targetUnattendedMode = mode.mode.id;
          break;
        }
      }
    }
    return resolveAndValidateCreateAgentMode(
      requestedMode: request.requestedMode,
      targetProvider: request.targetProvider,
      parent: request.parent,
      unattended: request.unattended,
      availableModes: availableModes,
      targetUnattendedMode: targetUnattendedMode,
    );
  }

  bool isCreateAgentModeUnattended({
    required String provider,
    required String? modeId,
  }) {
    final modes = {
      for (final mode
          in definition(provider)?.modes ??
              const <PaseoProviderModeDefinition>[])
        mode.mode.id: mode.isUnattended,
    };
    return isDefaultAgentCreateConfigUnattended(
      modeId: modeId,
      unattendedModes: modes,
    );
  }

  AgentCreateModeParent createAgentModeParent(AgentSummary parent) =>
      AgentCreateModeParent(
        provider: parent.provider,
        modeId: parent.currentModeId,
        isUnattended: isCreateAgentModeUnattended(
          provider: parent.provider,
          modeId: parent.currentModeId,
        ),
      );

  Future<ProviderSnapshotEntry> _snapshotEntry(
    PaseoProviderDefinition definition, {
    required String cwd,
    required bool force,
  }) async {
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
      final catalog = available
          ? await _probeCatalog(definition, cwd: cwd, force: force)
          : null;
      return _entry(
        definition,
        available
            ? ProviderCatalogStatus.ready
            : ProviderCatalogStatus.unavailable,
        fetchedAt,
        models: catalog?.models,
        modes: catalog?.modes,
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
    List<ProviderModelDefinition>? models,
    List<ProviderMode>? modes,
  }) => ProviderSnapshotEntry(
    provider: definition.id,
    status: status,
    enabled: enabled,
    error: error,
    models: status == ProviderCatalogStatus.ready ? (models ?? const []) : null,
    modes: status == ProviderCatalogStatus.ready
        ? (modes ?? [for (final entry in definition.modes) entry.mode])
        : null,
    fetchedAt: fetchedAt,
    label: definition.label,
    description: definition.description,
    defaultModeId: definition.defaultModeId,
    source: definition.source,
  );

  Future<AcpProviderCatalog?> _probeCatalog(
    PaseoProviderDefinition definition, {
    required String cwd,
    required bool force,
  }) {
    final probe = _catalogProbe;
    if (probe == null) return Future.value();
    final key = '${definition.id}\u0000$cwd';
    final fingerprint = _definitionFingerprint(definition);
    final existing = _catalogLoads[key];
    if (!force && existing?.fingerprint == fingerprint) {
      return existing!.result;
    }
    final result = probe(definition, cwd);
    _catalogLoads[key] = _CatalogLoad(fingerprint: fingerprint, result: result);
    return result;
  }
}

String _resolveProbeCwd(String? cwd) {
  final trimmed = cwd?.trim();
  if (trimmed?.isNotEmpty == true) return p.normalize(p.absolute(trimmed!));
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  return p.normalize(
    p.absolute(home?.isNotEmpty == true ? home! : Directory.current.path),
  );
}

String _definitionFingerprint(PaseoProviderDefinition definition) =>
    jsonEncode({
      'command': [definition.command, ...definition.commandArgs],
      'environment': Map.fromEntries(
        definition.environment.entries.toList()
          ..sort((left, right) => left.key.compareTo(right.key)),
      ),
      'params': definition.providerParams,
      'modes': [for (final mode in definition.modes) mode.mode.toJson()],
    });

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
