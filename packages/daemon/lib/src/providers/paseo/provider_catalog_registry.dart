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
typedef ProviderModeCatalogResolver =
    Future<({List<ProviderMode> modes, String? defaultModeId})?> Function(
      PaseoProviderDefinition definition,
      String cwd,
    );

/// Emitted after a provider finishes loading an asynchronous snapshot.
///
/// The callback mirrors Paseo's `ProviderSnapshotManager` change event.  The
/// global snapshot is represented by a null cwd; workspace snapshots contain
/// the normalized absolute cwd used for the probe.
typedef ProviderSnapshotChangeListener =
    void Function(String? cwd, List<ProviderSnapshotEntry> entries);

final class _CatalogLoad {
  const _CatalogLoad({required this.fingerprint, required this.result});

  final String fingerprint;
  final Future<AcpProviderCatalog?> result;
}

final class _ProviderLoad {
  _ProviderLoad({required this.generation});

  final int generation;
  late final Future<void> result;
}

final class PaseoProviderCatalogRegistry {
  PaseoProviderCatalogRegistry({
    ExecutableResolver? executableResolver,
    ProviderCommandResolver? commandResolver,
    List<PaseoProviderDefinition>? definitions,
    Iterable<String> runtimeProviderIds = const [],
    ProviderConfigResolver? configResolver,
    ProviderCatalogProbe? catalogProbe,
    ProviderModeCatalogResolver? modeCatalogResolver,
    DateTime Function()? now,
    ProviderSnapshotChangeListener? onSnapshotChanged,
  }) : _resolver = executableResolver ?? ExecutableResolver(),
       _commandResolver = commandResolver,
       _baseDefinitions = definitions ?? PaseoProviderManifest.definitions,
       _runtimeProviderIds = Set.unmodifiable(
         runtimeProviderIds
             .map((provider) => provider.trim())
             .where((provider) => provider.isNotEmpty),
       ),
       _configResolver = configResolver,
       _catalogProbe = catalogProbe,
       _modeCatalogResolver = modeCatalogResolver,
       _now = now ?? DateTime.now,
       _onSnapshotChanged = onSnapshotChanged;

  final ExecutableResolver _resolver;
  final ProviderCommandResolver? _commandResolver;
  final ProviderConfigResolver? _configResolver;
  final ProviderCatalogProbe? _catalogProbe;
  final ProviderModeCatalogResolver? _modeCatalogResolver;
  final DateTime Function() _now;
  final ProviderSnapshotChangeListener? _onSnapshotChanged;
  final List<PaseoProviderDefinition> _baseDefinitions;
  final Set<String> _runtimeProviderIds;
  final Map<String, _CatalogLoad> _catalogLoads = {};
  final Map<String, Map<String, ProviderSnapshotEntry>> _snapshots = {};
  final Map<String, Map<String, _ProviderLoad>> _providerLoads = {};
  String? _definitionsFingerprint;
  int _generation = 0;

  List<PaseoProviderDefinition> get definitions {
    final config = _configResolver?.call();
    final overrides = config?.providers ?? const {};
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
    final resolvedIds = {for (final definition in resolved) definition.id};
    for (final provider in _runtimeProviderIds) {
      if (resolvedIds.add(provider)) {
        resolved.add(_runtimeDefinition(provider));
      }
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
    if (_runtimeProviderIds.contains(definition.id)) {
      return Future.value('runtime:${definition.id}');
    }
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
    bool wait = true,
    bool emitUpdates = false,
  }) async {
    final currentDefinitions = definitions;
    _syncDefinitionGeneration(currentDefinitions);
    final filter = providers == null ? null : providers.toSet();
    final selected = [
      for (final definition in currentDefinitions)
        if (filter == null || filter.contains(definition.id)) definition,
    ];
    final snapshotKey = _snapshotKey(cwd);
    final snapshot = _ensureSnapshot(snapshotKey, currentDefinitions);
    final probeCwd = _resolveProbeCwd(cwd);
    final loads = <Future<void>>[];
    for (final definition in selected) {
      loads.add(
        _loadProvider(
          snapshotKey: snapshotKey,
          wireCwd: cwd,
          probeCwd: probeCwd,
          definition: definition,
          force: force,
          emitUpdates: emitUpdates,
        ),
      );
    }
    if (wait && loads.isNotEmpty) {
      await Future.wait(loads);
    }
    final entries = [
      for (final definition in selected)
        if (snapshot[definition.id] case final entry?) _cloneEntry(entry),
    ];
    return entries;
  }

  Future<String> diagnostic(String provider) async {
    final providerDefinition = definition(provider);
    if (providerDefinition == null) {
      return _formatProviderDiagnostic(provider, [
        ('Error', 'Provider $provider is not configured'),
      ]);
    }
    final entry = (await snapshot(providers: [provider], force: true)).single;
    final modelCount = entry.status == ProviderCatalogStatus.ready
        ? '${entry.models?.length ?? 0}'
        : '—';
    return '${_formatProviderDiagnostic(providerDefinition.label, const [('Diagnostic', 'No diagnostic available')])}\n'
        '  Models: $modelCount\n'
        '  Status: ${_formatProviderStatus(entry)}';
  }

  Future<String?> resolveCreateAgentMode(AgentCreateModeRequest request) async {
    final resolved = await resolveCreateAgentConfig(
      AgentCreateConfigRequest(
        cwd: request.cwd,
        targetProvider: request.targetProvider,
        requestedMode: request.requestedMode,
        featureValues: const {},
        parent: request.parent,
        unattended: request.unattended,
      ),
    );
    return resolved.modeId;
  }

  Future<ResolvedAgentCreateConfig> resolveCreateAgentConfig(
    AgentCreateConfigRequest request,
  ) async {
    final providerDefinition = definition(request.targetProvider);
    List<String>? availableModes;
    String? targetUnattendedMode;
    if (providerDefinition != null) {
      final entry = await _requireReadyProvider(
        providerDefinition,
        cwd: request.cwd,
      );
      final hasKnownModeCatalog =
          !_runtimeProviderIds.contains(providerDefinition.id) ||
          providerDefinition.modes.isNotEmpty;
      if (hasKnownModeCatalog) {
        availableModes = [
          for (final mode in entry.modes ?? const <ProviderMode>[]) mode.id,
        ];
      }
      for (final mode in providerDefinition.modes) {
        if (mode.isUnattended) {
          targetUnattendedMode = mode.mode.id;
          break;
        }
      }
    }
    return _resolveProviderCreateAgentConfig(
      request,
      availableModes: availableModes,
      targetUnattendedMode: targetUnattendedMode,
    );
  }

  Future<ProviderSnapshotEntry> _requireReadyProvider(
    PaseoProviderDefinition definition, {
    required String cwd,
  }) async {
    final entry = (await snapshot(providers: [definition.id], cwd: cwd)).single;
    if (!entry.enabled) {
      throw StateError("Provider '${entry.provider}' is disabled");
    }
    return switch (entry.status) {
      ProviderCatalogStatus.ready => entry,
      ProviderCatalogStatus.error => throw StateError(
        entry.error ?? "Failed to load provider '${entry.provider}'",
      ),
      ProviderCatalogStatus.unavailable || ProviderCatalogStatus.loading =>
        throw StateError("Provider '${entry.provider}' is not available"),
    };
  }

  ResolvedAgentCreateConfig _resolveProviderCreateAgentConfig(
    AgentCreateConfigRequest request, {
    required List<String>? availableModes,
    required String? targetUnattendedMode,
  }) {
    if (request.targetProvider == 'opencode') {
      return _resolveOpenCodeCreateAgentConfig(
        request,
        availableModes: availableModes,
      );
    }
    return ResolvedAgentCreateConfig(
      modeId: resolveAndValidateCreateAgentMode(
        requestedMode: request.requestedMode,
        targetProvider: request.targetProvider,
        parent: request.parent,
        unattended: request.unattended,
        availableModes: availableModes,
        targetUnattendedMode: targetUnattendedMode,
      ),
      featureValues: Map.unmodifiable(request.featureValues),
    );
  }

  ResolvedAgentCreateConfig _resolveOpenCodeCreateAgentConfig(
    AgentCreateConfigRequest request, {
    required List<String>? availableModes,
  }) {
    const legacyFullAccessMode = 'full-access';
    const buildMode = 'build';
    const autoAcceptFeature = 'auto_accept';
    final legacyFullAccess = request.requestedMode == legacyFullAccessMode;
    final unattended =
        request.unattended || request.parent?.isUnattended == true;
    final inheritsUnattended = request.requestedMode == null && unattended;
    final inheritedMode =
        inheritsUnattended && request.parent?.provider == request.targetProvider
        ? request.parent?.modeId
        : null;
    final requestedMode = legacyFullAccess
        ? buildMode
        : request.requestedMode ?? inheritedMode;
    final featureValues = <String, Object?>{...request.featureValues};
    if (legacyFullAccess ||
        (unattended && !featureValues.containsKey(autoAcceptFeature))) {
      featureValues[autoAcceptFeature] = true;
    }
    if (inheritsUnattended && requestedMode == null) {
      return ResolvedAgentCreateConfig(
        modeId: null,
        featureValues: Map.unmodifiable(featureValues),
      );
    }
    return ResolvedAgentCreateConfig(
      modeId: resolveAndValidateCreateAgentMode(
        requestedMode: requestedMode,
        targetProvider: request.targetProvider,
        parent: request.parent,
        unattended: unattended,
        availableModes: availableModes,
        targetUnattendedMode: null,
      ),
      featureValues: Map.unmodifiable(featureValues),
    );
  }

  bool isCreateAgentConfigUnattended({
    required String provider,
    required String? modeId,
    required Map<String, Object?> featureValues,
  }) {
    if (provider == 'opencode' && featureValues['auto_accept'] == true) {
      return true;
    }
    return isCreateAgentModeUnattended(provider: provider, modeId: modeId);
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
        isUnattended: isCreateAgentConfigUnattended(
          provider: parent.provider,
          modeId: parent.currentModeId,
          featureValues: parent.featureValues,
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
      final modeResolver = _modeCatalogResolver;
      final modeCatalogFuture = modeResolver == null
          ? Future<({List<ProviderMode> modes, String? defaultModeId})?>.value()
          : modeResolver(definition, cwd);
      final results = available
          ? await Future.wait<Object?>([
              _probeCatalog(definition, cwd: cwd, force: force),
              modeCatalogFuture,
            ])
          : const <Object?>[null, null];
      final catalog = results[0] as AcpProviderCatalog?;
      final modeCatalog =
          results[1] as ({List<ProviderMode> modes, String? defaultModeId})?;
      return _entry(
        definition,
        available
            ? ProviderCatalogStatus.ready
            : ProviderCatalogStatus.unavailable,
        fetchedAt,
        models: catalog?.models,
        modes: catalog?.modes ?? modeCatalog?.modes,
        defaultModeId: catalog?.defaultModeId ?? modeCatalog?.defaultModeId,
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

  Future<void> _loadProvider({
    required String snapshotKey,
    required String? wireCwd,
    required String probeCwd,
    required PaseoProviderDefinition definition,
    required bool force,
    required bool emitUpdates,
  }) {
    final loads = _providerLoads.putIfAbsent(snapshotKey, () => {});
    final existing = loads[definition.id];
    if (!force && existing != null) return existing.result;

    final snapshot = _snapshots.putIfAbsent(snapshotKey, () => {});
    final existingEntry = snapshot[definition.id];
    if (!force &&
        existing == null &&
        existingEntry != null &&
        existingEntry.status != ProviderCatalogStatus.loading) {
      return Future<void>.value();
    }
    if (force ||
        snapshot[definition.id]?.status == ProviderCatalogStatus.loading) {
      snapshot[definition.id] = _loadingEntry(definition);
    }
    final load = _ProviderLoad(generation: _generation);
    loads[definition.id] = load;
    load.result = Future<void>(() async {
      try {
        final entry = await _snapshotEntry(
          definition,
          cwd: probeCwd,
          force: force,
        );
        if (!_isCurrentLoad(snapshotKey, definition.id, load)) return;
        snapshot[definition.id] = entry;
        if (emitUpdates) _emitSnapshotChanged(wireCwd, snapshot);
      } catch (error) {
        if (!_isCurrentLoad(snapshotKey, definition.id, load)) return;
        snapshot[definition.id] = _errorEntry(definition, error);
        if (emitUpdates) _emitSnapshotChanged(wireCwd, snapshot);
      } finally {
        if (_isCurrentLoad(snapshotKey, definition.id, load)) {
          loads.remove(definition.id);
          if (loads.isEmpty) _providerLoads.remove(snapshotKey);
        }
      }
    });
    return load.result;
  }

  ProviderSnapshotEntry _loadingEntry(PaseoProviderDefinition definition) =>
      ProviderSnapshotEntry(
        provider: definition.id,
        status: ProviderCatalogStatus.loading,
        enabled: definition.enabledByDefault,
        source: definition.source,
        label: definition.label,
        description: definition.description,
        defaultModeId: definition.defaultModeId,
      );

  ProviderSnapshotEntry _errorEntry(
    PaseoProviderDefinition definition,
    Object error,
  ) => ProviderSnapshotEntry(
    provider: definition.id,
    status: ProviderCatalogStatus.error,
    enabled: definition.enabledByDefault,
    source: definition.source,
    error: error.toString(),
    label: definition.label,
    description: definition.description,
    defaultModeId: definition.defaultModeId,
  );

  bool _isCurrentLoad(
    String snapshotKey,
    String provider,
    _ProviderLoad load,
  ) =>
      _generation == load.generation &&
      _providerLoads[snapshotKey]?[provider] == load;

  Map<String, ProviderSnapshotEntry> _ensureSnapshot(
    String snapshotKey,
    List<PaseoProviderDefinition> currentDefinitions,
  ) {
    final existing = _snapshots[snapshotKey];
    if (existing == null) {
      final created = <String, ProviderSnapshotEntry>{
        for (final definition in currentDefinitions)
          definition.id: _loadingEntry(definition),
      };
      _snapshots[snapshotKey] = created;
      return created;
    }
    final known = {for (final definition in currentDefinitions) definition.id};
    existing.removeWhere((provider, _) => !known.contains(provider));
    for (final definition in currentDefinitions) {
      final current = existing[definition.id];
      if (current == null) {
        existing[definition.id] = _loadingEntry(definition);
      } else if (!definition.enabledByDefault &&
          current.status != ProviderCatalogStatus.unavailable) {
        existing[definition.id] = _snapshotEntryMetadata(
          definition,
          ProviderCatalogStatus.unavailable,
          enabled: false,
        );
      }
    }
    return existing;
  }

  ProviderSnapshotEntry _snapshotEntryMetadata(
    PaseoProviderDefinition definition,
    ProviderCatalogStatus status, {
    bool? enabled,
    String? error,
  }) => ProviderSnapshotEntry(
    provider: definition.id,
    status: status,
    enabled: enabled ?? definition.enabledByDefault,
    source: definition.source,
    error: error,
    label: definition.label,
    description: definition.description,
    defaultModeId: definition.defaultModeId,
  );

  void _syncDefinitionGeneration(
    List<PaseoProviderDefinition> currentDefinitions,
  ) {
    final fingerprint = jsonEncode([
      for (final definition in currentDefinitions)
        [definition.id, _definitionFingerprint(definition)],
    ]);
    if (fingerprint == _definitionsFingerprint) return;
    _definitionsFingerprint = fingerprint;
    _generation++;
    // Existing in-flight loads must not publish results against a changed
    // provider registry.  Their identity check observes the new generation.
    _providerLoads.clear();
    for (final snapshot in _snapshots.values) {
      final known = {
        for (final definition in currentDefinitions) definition.id,
      };
      snapshot.removeWhere((provider, _) => !known.contains(provider));
      for (final definition in currentDefinitions) {
        snapshot[definition.id] = definition.enabledByDefault
            ? _loadingEntry(definition)
            : _snapshotEntryMetadata(
                definition,
                ProviderCatalogStatus.unavailable,
                enabled: false,
              );
      }
    }
  }

  String _snapshotKey(String? cwd) {
    final trimmed = cwd?.trim();
    return trimmed == null || trimmed.isEmpty
        ? r'__paseo_global_provider_snapshot__'
        : _resolveProbeCwd(trimmed);
  }

  void _emitSnapshotChanged(
    String? wireCwd,
    Map<String, ProviderSnapshotEntry> snapshot,
  ) {
    _onSnapshotChanged?.call(wireCwd, [
      for (final entry in snapshot.values) _cloneEntry(entry),
    ]);
  }

  ProviderSnapshotEntry _cloneEntry(ProviderSnapshotEntry entry) =>
      ProviderSnapshotEntry(
        provider: entry.provider,
        status: entry.status,
        enabled: entry.enabled,
        source: entry.source,
        error: entry.error,
        models: entry.models == null
            ? null
            : [for (final model in entry.models!) _cloneModel(model)],
        modes: entry.modes == null
            ? null
            : [for (final mode in entry.modes!) _cloneMode(mode)],
        fetchedAt: entry.fetchedAt,
        label: entry.label,
        description: entry.description,
        defaultModeId: entry.defaultModeId,
      );

  ProviderModelDefinition _cloneModel(
    ProviderModelDefinition model,
  ) => ProviderModelDefinition(
    provider: model.provider,
    id: model.id,
    label: model.label,
    description: model.description,
    isDefault: model.isDefault,
    metadata: model.metadata == null ? null : Map.of(model.metadata!),
    contextWindowMaxTokens: model.contextWindowMaxTokens,
    thinkingOptions: model.thinkingOptions == null
        ? null
        : [for (final option in model.thinkingOptions!) _cloneOption(option)],
    defaultThinkingOptionId: model.defaultThinkingOptionId,
  );

  ProviderSelectOption _cloneOption(ProviderSelectOption option) =>
      ProviderSelectOption(
        id: option.id,
        label: option.label,
        description: option.description,
        isDefault: option.isDefault,
        metadata: option.metadata == null ? null : Map.of(option.metadata!),
      );

  ProviderMode _cloneMode(ProviderMode mode) => ProviderMode(
    id: mode.id,
    label: mode.label,
    description: mode.description,
    icon: mode.icon,
    colorTier: mode.colorTier,
  );

  ProviderSnapshotEntry _entry(
    PaseoProviderDefinition definition,
    ProviderCatalogStatus status,
    String fetchedAt, {
    bool enabled = true,
    String? error,
    List<ProviderModelDefinition>? models,
    List<ProviderMode>? modes,
    String? defaultModeId,
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
    defaultModeId: defaultModeId ?? definition.defaultModeId,
    source: definition.source,
  );

  Future<AcpProviderCatalog?> _probeCatalog(
    PaseoProviderDefinition definition, {
    required String cwd,
    required bool force,
  }) {
    if (_runtimeProviderIds.contains(definition.id)) return Future.value();
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

String _formatProviderDiagnostic(
  String providerName,
  List<(String, String)> entries,
) => [
  providerName,
  for (final entry in entries) '  ${entry.$1}: ${entry.$2}',
].join('\n');

String _formatProviderStatus(ProviderSnapshotEntry entry) =>
    switch (entry.status) {
      ProviderCatalogStatus.ready => 'Ready',
      ProviderCatalogStatus.error => 'Error: ${entry.error ?? 'Unknown error'}',
      ProviderCatalogStatus.unavailable => 'Unavailable',
      ProviderCatalogStatus.loading => 'Loading',
    };

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
    voice: definition.voice,
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

PaseoProviderDefinition _runtimeDefinition(String id) =>
    PaseoProviderDefinition(
      id: id,
      label: id,
      description: 'Runtime-injected provider',
      command: id,
      defaultModeId: null,
      modes: const [],
      source: 'custom',
    );

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
