import '../terminal/terminal_profiles.dart';

final class MutableDaemonProviderModel {
  const MutableDaemonProviderModel({
    required this.id,
    required this.label,
    this.description,
    this.isDefault,
    this.extra = const {},
  });

  final String id;
  final String label;
  final String? description;
  final bool? isDefault;
  final Map<String, Object?> extra;

  factory MutableDaemonProviderModel.fromJson(Map<String, Object?> json) {
    final id = _nonEmptyString(json['id'], 'provider model id');
    final label = _nonEmptyString(json['label'], 'provider model label');
    return MutableDaemonProviderModel(
      id: id,
      label: label,
      description: _optionalString(json['description'], 'description'),
      isDefault: _optionalBool(json['isDefault'], 'isDefault'),
      extra: _extras(json, const {'id', 'label', 'description', 'isDefault'}),
    );
  }

  Map<String, Object?> toJson() => {
    ...extra,
    'id': id,
    'label': label,
    if (description != null) 'description': description,
    if (isDefault != null) 'isDefault': isDefault,
  };
}

final class MutableDaemonProviderConfig {
  const MutableDaemonProviderConfig({
    this.enabled,
    this.additionalModels,
    this.extra = const {},
  });

  final bool? enabled;
  final List<MutableDaemonProviderModel>? additionalModels;
  final Map<String, Object?> extra;

  factory MutableDaemonProviderConfig.fromJson(Map<String, Object?> json) {
    final models = json['additionalModels'];
    if (models != null && models is! List) {
      throw const FormatException('additionalModels must be an array');
    }
    return MutableDaemonProviderConfig(
      enabled: _optionalBool(json['enabled'], 'enabled'),
      additionalModels: models == null
          ? null
          : List.unmodifiable(
              (models as List).map(
                (model) => MutableDaemonProviderModel.fromJson(
                  _map(model, 'provider model'),
                ),
              ),
            ),
      extra: _extras(json, const {'enabled', 'additionalModels'}),
    );
  }

  Map<String, Object?> toJson() => {
    ...extra,
    if (enabled != null) 'enabled': enabled,
    if (additionalModels != null)
      'additionalModels': additionalModels!
          .map((model) => model.toJson())
          .toList(),
  };
}

final class MutableStructuredGenerationProvider {
  const MutableStructuredGenerationProvider({
    required this.provider,
    this.model,
    this.thinkingOptionId,
    this.extra = const {},
  });

  final String provider;
  final String? model;
  final String? thinkingOptionId;
  final Map<String, Object?> extra;

  factory MutableStructuredGenerationProvider.fromJson(
    Map<String, Object?> json,
  ) => MutableStructuredGenerationProvider(
    provider: _nonEmptyString(json['provider'], 'provider'),
    model: _optionalNonEmptyString(json['model'], 'model'),
    thinkingOptionId: _optionalNonEmptyString(
      json['thinkingOptionId'],
      'thinkingOptionId',
    ),
    extra: _extras(json, const {'provider', 'model', 'thinkingOptionId'}),
  );

  Map<String, Object?> toJson() => {
    ...extra,
    'provider': provider,
    if (model != null) 'model': model,
    if (thinkingOptionId != null) 'thinkingOptionId': thinkingOptionId,
  };
}

final class MutableDaemonConfig {
  const MutableDaemonConfig({
    required this.injectMcpIntoAgents,
    this.browserToolsEnabled = false,
    this.providers = const {},
    this.metadataGenerationProviders = const [],
    this.autoArchiveAfterMerge = false,
    this.enableTerminalAgentHooks = false,
    this.appendSystemPrompt = '',
    this.terminalProfiles,
    this.extra = const {},
    this.mcpExtra = const {},
    this.browserToolsExtra = const {},
    this.metadataGenerationExtra = const {},
  });

  final bool injectMcpIntoAgents;
  final bool browserToolsEnabled;
  final Map<String, MutableDaemonProviderConfig> providers;
  final List<MutableStructuredGenerationProvider> metadataGenerationProviders;
  final bool autoArchiveAfterMerge;
  final bool enableTerminalAgentHooks;
  final String appendSystemPrompt;
  final List<TerminalProfile>? terminalProfiles;
  final Map<String, Object?> extra;
  final Map<String, Object?> mcpExtra;
  final Map<String, Object?> browserToolsExtra;
  final Map<String, Object?> metadataGenerationExtra;

  factory MutableDaemonConfig.fromJson(Map<String, Object?> json) {
    final mcp = _map(json['mcp'], 'mcp');
    final browser = json['browserTools'] == null
        ? const <String, Object?>{}
        : _map(json['browserTools'], 'browserTools');
    final providerValues = json['providers'] == null
        ? const <String, Object?>{}
        : _map(json['providers'], 'providers');
    final metadata = json['metadataGeneration'] == null
        ? const <String, Object?>{}
        : _map(json['metadataGeneration'], 'metadataGeneration');
    final metadataProviders = metadata['providers'];
    if (metadataProviders != null && metadataProviders is! List) {
      throw const FormatException(
        'metadataGeneration.providers must be an array',
      );
    }
    final rawProfiles = json['terminalProfiles'];
    if (rawProfiles != null && rawProfiles is! List) {
      throw const FormatException('terminalProfiles must be an array');
    }
    return MutableDaemonConfig(
      injectMcpIntoAgents: _requiredBool(
        mcp['injectIntoAgents'],
        'mcp.injectIntoAgents',
      ),
      browserToolsEnabled:
          _optionalBool(browser['enabled'], 'browserTools.enabled') ?? false,
      providers: Map.unmodifiable(
        providerValues.map(
          (id, value) => MapEntry(
            id,
            MutableDaemonProviderConfig.fromJson(
              _map(value, 'provider config'),
            ),
          ),
        ),
      ),
      metadataGenerationProviders: List.unmodifiable(
        (metadataProviders as List? ?? const []).map(
          (provider) => MutableStructuredGenerationProvider.fromJson(
            _map(provider, 'metadata generation provider'),
          ),
        ),
      ),
      autoArchiveAfterMerge:
          _optionalBool(
            json['autoArchiveAfterMerge'],
            'autoArchiveAfterMerge',
          ) ??
          false,
      enableTerminalAgentHooks:
          _optionalBool(
            json['enableTerminalAgentHooks'],
            'enableTerminalAgentHooks',
          ) ??
          false,
      appendSystemPrompt:
          _optionalString(json['appendSystemPrompt'], 'appendSystemPrompt') ??
          '',
      terminalProfiles: rawProfiles == null
          ? null
          : List.unmodifiable(
              (rawProfiles as List).map(
                (profile) =>
                    TerminalProfile.fromJson(_map(profile, 'terminal profile')),
              ),
            ),
      extra: _extras(json, const {
        'mcp',
        'browserTools',
        'providers',
        'metadataGeneration',
        'autoArchiveAfterMerge',
        'enableTerminalAgentHooks',
        'appendSystemPrompt',
        'terminalProfiles',
      }),
      mcpExtra: _extras(mcp, const {'injectIntoAgents'}),
      browserToolsExtra: _extras(browser, const {'enabled'}),
      metadataGenerationExtra: _extras(metadata, const {'providers'}),
    );
  }

  Map<String, Object?> toJson() => {
    ...extra,
    'mcp': {...mcpExtra, 'injectIntoAgents': injectMcpIntoAgents},
    'browserTools': {...browserToolsExtra, 'enabled': browserToolsEnabled},
    'providers': providers.map((id, config) => MapEntry(id, config.toJson())),
    'metadataGeneration': {
      ...metadataGenerationExtra,
      'providers': metadataGenerationProviders
          .map((provider) => provider.toJson())
          .toList(),
    },
    'autoArchiveAfterMerge': autoArchiveAfterMerge,
    'enableTerminalAgentHooks': enableTerminalAgentHooks,
    'appendSystemPrompt': appendSystemPrompt,
    if (terminalProfiles != null)
      'terminalProfiles': terminalProfiles!
          .map((profile) => profile.toJson())
          .toList(),
  };
}

final class MutableDaemonConfigPatch {
  const MutableDaemonConfigPatch({
    this.injectMcpIntoAgents,
    this.browserToolsEnabled,
    this.providers,
    this.removeProviders,
    this.metadataGenerationProviders,
    this.autoArchiveAfterMerge,
    this.enableTerminalAgentHooks,
    this.appendSystemPrompt,
    this.terminalProfiles,
    this.values = const {},
  });

  final bool? injectMcpIntoAgents;
  final bool? browserToolsEnabled;
  final Map<String, MutableDaemonProviderConfig>? providers;
  final List<String>? removeProviders;
  final List<MutableStructuredGenerationProvider>? metadataGenerationProviders;
  final bool? autoArchiveAfterMerge;
  final bool? enableTerminalAgentHooks;
  final String? appendSystemPrompt;
  final List<TerminalProfile>? terminalProfiles;
  final Map<String, Object?> values;

  factory MutableDaemonConfigPatch.fromJson(Map<String, Object?> json) {
    _validateMutableDaemonConfigPatch(json);
    final mcp = json['mcp'] == null
        ? const <String, Object?>{}
        : _map(json['mcp'], 'mcp');
    final browser = json['browserTools'] == null
        ? const <String, Object?>{}
        : _map(json['browserTools'], 'browserTools');
    final providerValues = json['providers'] == null
        ? null
        : _map(json['providers'], 'providers');
    final metadata = json['metadataGeneration'] == null
        ? const <String, Object?>{}
        : _map(json['metadataGeneration'], 'metadataGeneration');
    final metadataProviders = metadata['providers'] as List?;
    final rawProfiles = json['terminalProfiles'] as List?;
    return MutableDaemonConfigPatch(
      injectMcpIntoAgents: _optionalBool(
        mcp['injectIntoAgents'],
        'mcp.injectIntoAgents',
      ),
      browserToolsEnabled: _optionalBool(
        browser['enabled'],
        'browserTools.enabled',
      ),
      providers: providerValues == null
          ? null
          : Map.unmodifiable(
              providerValues.map(
                (id, value) => MapEntry(
                  id,
                  MutableDaemonProviderConfig.fromJson(
                    _map(value, 'providers.$id'),
                  ),
                ),
              ),
            ),
      removeProviders: json['removeProviders'] == null
          ? null
          : List.unmodifiable((json['removeProviders'] as List).cast<String>()),
      metadataGenerationProviders: metadataProviders == null
          ? null
          : List.unmodifiable(
              metadataProviders.map(
                (provider) => MutableStructuredGenerationProvider.fromJson(
                  _map(provider, 'metadata generation provider'),
                ),
              ),
            ),
      autoArchiveAfterMerge: _optionalBool(
        json['autoArchiveAfterMerge'],
        'autoArchiveAfterMerge',
      ),
      enableTerminalAgentHooks: _optionalBool(
        json['enableTerminalAgentHooks'],
        'enableTerminalAgentHooks',
      ),
      appendSystemPrompt: _optionalString(
        json['appendSystemPrompt'],
        'appendSystemPrompt',
      ),
      terminalProfiles: rawProfiles == null
          ? null
          : List.unmodifiable(
              rawProfiles.map(
                (profile) =>
                    TerminalProfile.fromJson(_map(profile, 'terminal profile')),
              ),
            ),
      values: Map.unmodifiable(json),
    );
  }

  Map<String, Object?> toJson() => {
    ...values,
    if (injectMcpIntoAgents != null)
      'mcp': {
        ..._mapOrEmpty(values['mcp']),
        'injectIntoAgents': injectMcpIntoAgents,
      },
    if (browserToolsEnabled != null)
      'browserTools': {
        ..._mapOrEmpty(values['browserTools']),
        'enabled': browserToolsEnabled,
      },
    if (providers != null)
      'providers': providers!.map(
        (id, provider) => MapEntry(id, provider.toJson()),
      ),
    if (removeProviders != null) 'removeProviders': removeProviders,
    if (metadataGenerationProviders != null)
      'metadataGeneration': {
        ..._mapOrEmpty(values['metadataGeneration']),
        'providers': metadataGenerationProviders!
            .map((provider) => provider.toJson())
            .toList(),
      },
    if (autoArchiveAfterMerge != null)
      'autoArchiveAfterMerge': autoArchiveAfterMerge,
    if (enableTerminalAgentHooks != null)
      'enableTerminalAgentHooks': enableTerminalAgentHooks,
    if (appendSystemPrompt != null) 'appendSystemPrompt': appendSystemPrompt,
    if (terminalProfiles != null)
      'terminalProfiles': terminalProfiles!
          .map((profile) => profile.toJson())
          .toList(),
  };
}

final class GetDaemonConfigRequest {
  const GetDaemonConfigRequest({required this.requestId});
  final String requestId;

  factory GetDaemonConfigRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'get_daemon_config_request');
    return GetDaemonConfigRequest(
      requestId: _requiredString(json['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'get_daemon_config_request',
    'requestId': requestId,
  };
}

final class SetDaemonConfigRequest {
  const SetDaemonConfigRequest({required this.requestId, required this.config});
  final String requestId;
  final MutableDaemonConfigPatch config;

  factory SetDaemonConfigRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'set_daemon_config_request');
    return SetDaemonConfigRequest(
      requestId: _requiredString(json['requestId'], 'requestId'),
      config: MutableDaemonConfigPatch.fromJson(_map(json['config'], 'config')),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'set_daemon_config_request',
    'requestId': requestId,
    'config': config.toJson(),
  };
}

final class DaemonConfigResponse {
  const DaemonConfigResponse({
    required this.type,
    required this.requestId,
    required this.config,
  });

  final String type;
  final String requestId;
  final MutableDaemonConfig config;

  factory DaemonConfigResponse.fromJson(Map<String, Object?> json) {
    final type = json['type'];
    if (type != 'get_daemon_config_response' &&
        type != 'set_daemon_config_response') {
      throw FormatException('Unexpected daemon config response: $type');
    }
    final payload = _map(json['payload'], 'payload');
    return DaemonConfigResponse(
      type: type! as String,
      requestId: _requiredString(payload['requestId'], 'requestId'),
      config: MutableDaemonConfig.fromJson(_map(payload['config'], 'config')),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {'requestId': requestId, 'config': config.toJson()},
  };
}

final class DaemonConfigChangedStatus {
  const DaemonConfigChangedStatus({required this.config});
  final MutableDaemonConfig config;

  factory DaemonConfigChangedStatus.fromJson(Map<String, Object?> json) {
    if (json['status'] != 'daemon_config_changed') {
      throw const FormatException('Expected daemon_config_changed status');
    }
    return DaemonConfigChangedStatus(
      config: MutableDaemonConfig.fromJson(_map(json['config'], 'config')),
    );
  }

  Map<String, Object?> toJson() => {
    'status': 'daemon_config_changed',
    'config': config.toJson(),
  };
}

void _expectType(Map<String, Object?> json, String type) {
  if (json['type'] != type) throw FormatException('Expected $type');
}

Map<String, Object?> _map(Object? value, String field) {
  if (value is! Map) throw FormatException('$field must be an object');
  return Map<String, Object?>.from(value);
}

Map<String, Object?> _mapOrEmpty(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : const {};

Map<String, Object?> _extras(Map<String, Object?> json, Set<String> known) =>
    Map.unmodifiable({
      for (final entry in json.entries)
        if (!known.contains(entry.key)) entry.key: entry.value,
    });

String _requiredString(Object? value, String field) {
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}

String _nonEmptyString(Object? value, String field) {
  final string = _requiredString(value, field);
  if (string.isEmpty) throw FormatException('$field must not be empty');
  return string;
}

String? _optionalString(Object? value, String field) =>
    value == null ? null : _requiredString(value, field);

String? _optionalNonEmptyString(Object? value, String field) =>
    value == null ? null : _nonEmptyString(value, field);

bool _requiredBool(Object? value, String field) {
  if (value is! bool) throw FormatException('$field must be a boolean');
  return value;
}

bool? _optionalBool(Object? value, String field) =>
    value == null ? null : _requiredBool(value, field);

void _validateMutableDaemonConfigPatch(Map<String, Object?> json) {
  if (json['mcp'] case final value?) {
    final mcp = _map(value, 'mcp');
    _optionalBool(mcp['injectIntoAgents'], 'mcp.injectIntoAgents');
  }
  if (json['browserTools'] case final value?) {
    final browser = _map(value, 'browserTools');
    _optionalBool(browser['enabled'], 'browserTools.enabled');
  }
  if (json['providers'] case final value?) {
    final providers = _map(value, 'providers');
    for (final entry in providers.entries) {
      MutableDaemonProviderConfig.fromJson(
        _map(entry.value, 'providers.${entry.key}'),
      );
    }
  }
  if (json['removeProviders'] case final value?) {
    if (value is! List) {
      throw const FormatException('removeProviders must be an array');
    }
    for (final provider in value) {
      _nonEmptyString(provider, 'removeProviders entry');
    }
  }
  if (json['metadataGeneration'] case final value?) {
    final metadata = _map(value, 'metadataGeneration');
    if (metadata['providers'] case final providers?) {
      if (providers is! List) {
        throw const FormatException(
          'metadataGeneration.providers must be an array',
        );
      }
      for (final provider in providers) {
        MutableStructuredGenerationProvider.fromJson(
          _map(provider, 'metadata generation provider'),
        );
      }
    }
  }
  _optionalBool(json['autoArchiveAfterMerge'], 'autoArchiveAfterMerge');
  _optionalBool(json['enableTerminalAgentHooks'], 'enableTerminalAgentHooks');
  _optionalString(json['appendSystemPrompt'], 'appendSystemPrompt');
  if (json['terminalProfiles'] case final value?) {
    if (value is! List) {
      throw const FormatException('terminalProfiles must be an array');
    }
    for (final profile in value) {
      TerminalProfile.fromJson(_map(profile, 'terminal profile'));
    }
  }
}
