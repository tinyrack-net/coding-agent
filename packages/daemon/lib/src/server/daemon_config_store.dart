import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

typedef DaemonConfigFieldListener = void Function(bool value);
typedef DaemonConfigListener = void Function(MutableDaemonConfig config);

final class DaemonConfigStore {
  DaemonConfigStore({
    required String home,
    MutableDaemonConfig? initial,
    bool enableTerminalAgentHooks = false,
  }) : _home = p.normalize(p.absolute(home)),
       _current =
           initial ??
           MutableDaemonConfig(
             injectMcpIntoAgents: false,
             enableTerminalAgentHooks: enableTerminalAgentHooks,
           );

  factory DaemonConfigStore.load({
    required String home,
    bool? enableTerminalAgentHooks,
  }) {
    final normalizedHome = p.normalize(p.absolute(home));
    final file = File(p.join(normalizedHome, 'config.json'));
    final persisted = file.existsSync()
        ? _readObject(file.readAsStringSync(), 'config.json')
        : <String, Object?>{'version': 1};
    final daemon = _object(persisted['daemon']);
    final agents = _object(persisted['agents']);
    final mcp = _object(daemon['mcp']);
    final browserTools = _object(daemon['browserTools']);
    final metadataGeneration = _object(agents['metadataGeneration']);
    final config = MutableDaemonConfig.fromJson({
      'mcp': {'injectIntoAgents': mcp['injectIntoAgents'] == true},
      'browserTools': {'enabled': browserTools['enabled'] == true},
      'providers': _normalizeProviderOverrides(_object(agents['providers'])),
      'metadataGeneration': {
        'providers': metadataGeneration['providers'] ?? const <Object?>[],
      },
      'autoArchiveAfterMerge': daemon['autoArchiveAfterMerge'] == true,
      'enableTerminalAgentHooks':
          enableTerminalAgentHooks ??
          (daemon['enableTerminalAgentHooks'] == true),
      'appendSystemPrompt': daemon['appendSystemPrompt'] is String
          ? daemon['appendSystemPrompt']
          : '',
      if (daemon['terminalProfiles'] != null)
        'terminalProfiles': daemon['terminalProfiles'],
    });
    return DaemonConfigStore(home: normalizedHome, initial: config);
  }

  final String _home;
  MutableDaemonConfig _current;
  final Set<DaemonConfigFieldListener> _terminalHookListeners = {};
  final Set<DaemonConfigListener> _changeListeners = {};

  bool get enableTerminalAgentHooks => _current.enableTerminalAgentHooks;
  MutableDaemonConfig get config => _current;

  bool setEnableTerminalAgentHooks(bool value) =>
      patch(MutableDaemonConfigPatch(enableTerminalAgentHooks: value));

  bool patch(MutableDaemonConfigPatch patch) {
    final patchJson = patch.toJson();
    final removeProviders = _stringList(
      patchJson.remove('removeProviders'),
      'removeProviders',
    ).toSet();
    final merged = _deepMerge(_current.toJson(), patchJson);
    final providers = _object(merged['providers'])
      ..removeWhere((id, _) => removeProviders.contains(id));
    merged['providers'] = providers;
    final metadata = _object(merged['metadataGeneration']);
    final metadataProviders = metadata['providers'];
    if (metadataProviders is List && removeProviders.isNotEmpty) {
      metadata['providers'] = [
        for (final entry in metadataProviders)
          if (entry is Map &&
              !removeProviders.contains(entry['provider'] as Object?))
            entry,
      ];
      merged['metadataGeneration'] = metadata;
    }
    final next = MutableDaemonConfig.fromJson(merged);
    final configChanged = !_sameConfig(_current, next);
    if (!configChanged && removeProviders.isEmpty) return false;

    _persist(next, removeProviders);
    if (!configChanged) return false;
    final previous = _current;
    _current = next;
    if (previous.enableTerminalAgentHooks != next.enableTerminalAgentHooks) {
      for (final listener in _terminalHookListeners.toList(growable: false)) {
        listener(next.enableTerminalAgentHooks);
      }
    }
    for (final listener in _changeListeners.toList(growable: false)) {
      listener(next);
    }
    return true;
  }

  void Function() onChange(DaemonConfigListener listener) {
    _changeListeners.add(listener);
    return () => _changeListeners.remove(listener);
  }

  void Function() onEnableTerminalAgentHooksChanged(
    DaemonConfigFieldListener listener,
  ) {
    _terminalHookListeners.add(listener);
    return () => _terminalHookListeners.remove(listener);
  }

  void _persist(MutableDaemonConfig config, Set<String> removeProviders) {
    final file = File(p.join(_home, 'config.json'));
    final root = file.existsSync()
        ? _readObject(file.readAsStringSync(), 'config.json')
        : <String, Object?>{'version': 1};
    final daemon = _object(root['daemon']);
    final agents = _object(root['agents']);
    final persistedProviders = _normalizeProviderOverrides(
      _object(agents['providers']),
    );
    for (final id in removeProviders) {
      persistedProviders.remove(id);
    }
    for (final entry in config.providers.entries) {
      persistedProviders[entry.key] = {
        ..._object(persistedProviders[entry.key]),
        ..._stripProviderOverride(entry.value.toJson()),
      };
    }
    final persistedAgents = <String, Object?>{...agents}
      ..remove('providers')
      ..remove('metadataGeneration');
    final metadataProviders = config.metadataGenerationProviders
        .map(_stripMetadataGenerationProvider)
        .toList();
    final shouldPersistMetadataGeneration =
        metadataProviders.isNotEmpty || agents['metadataGeneration'] != null;
    final nextAgents = <String, Object?>{
      ...persistedAgents,
      if (persistedProviders.isNotEmpty) 'providers': persistedProviders,
      if (shouldPersistMetadataGeneration)
        'metadataGeneration': {'providers': metadataProviders},
    };
    final rootWithoutAgents = <String, Object?>{...root}..remove('agents');
    final next = {
      ...rootWithoutAgents,
      'version': root['version'] ?? 1,
      'daemon': {
        ...daemon,
        'mcp': {
          ..._object(daemon['mcp']),
          'injectIntoAgents': config.injectMcpIntoAgents,
        },
        'browserTools': {
          ..._object(daemon['browserTools']),
          'enabled': config.browserToolsEnabled,
        },
        'autoArchiveAfterMerge': config.autoArchiveAfterMerge,
        'enableTerminalAgentHooks': config.enableTerminalAgentHooks,
        'appendSystemPrompt': config.appendSystemPrompt,
        if (config.terminalProfiles != null)
          'terminalProfiles': config.terminalProfiles!
              .map((profile) => profile.toJson())
              .toList(),
      },
      if (nextAgents.isNotEmpty) 'agents': nextAgents,
    };
    _writePrivateFileAtomic(
      file,
      '${const JsonEncoder.withIndent('  ').convert(next)}\n',
    );
  }
}

Map<String, Object?> _deepMerge(
  Map<String, Object?> current,
  Map<String, Object?> patch,
) {
  final result = <String, Object?>{...current};
  for (final entry in patch.entries) {
    final previous = result[entry.key];
    final value = entry.value;
    result[entry.key] = previous is Map && value is Map
        ? _deepMerge(
            Map<String, Object?>.from(previous),
            Map<String, Object?>.from(value),
          )
        : value;
  }
  return result;
}

bool _sameConfig(MutableDaemonConfig left, MutableDaemonConfig right) =>
    jsonEncode(left.toJson()) == jsonEncode(right.toJson());

List<String> _stringList(Object? value, String field) {
  if (value == null) return const [];
  if (value is! List || value.any((entry) => entry is! String)) {
    throw FormatException('$field must be an array of strings');
  }
  return value.cast<String>();
}

Map<String, Object?> _readObject(String raw, String label) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw FormatException('$label must contain a JSON object');
  }
  return Map<String, Object?>.from(decoded);
}

Map<String, Object?> _object(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : <String, Object?>{};

Map<String, Object?> _normalizeProviderOverrides(
  Map<String, Object?> providers,
) => {
  for (final entry in providers.entries)
    entry.key: _stripProviderOverride(
      _requiredObject(entry.value, 'provider ${entry.key}'),
    ),
};

const _providerStringFields = {'extends', 'label', 'description'};

Map<String, Object?> _stripProviderOverride(Map<String, Object?> source) {
  final result = <String, Object?>{};
  for (final field in _providerStringFields) {
    final value = source[field];
    if (value == null) continue;
    if (value is! String) {
      throw FormatException('provider $field must be a string');
    }
    result[field] = value;
  }
  if (source['command'] case final value?) {
    result['command'] = _nonEmptyStringList(value, 'provider command');
  }
  if (source['env'] case final value?) {
    final env = _requiredObject(value, 'provider env');
    if (env.values.any((entry) => entry is! String)) {
      throw const FormatException('provider env values must be strings');
    }
    result['env'] = env;
  }
  if (source['params'] case final value?) {
    if (value is! Map) {
      throw const FormatException('provider params must be an object');
    }
    result['params'] = Map<String, Object?>.from(value);
  }
  for (final field in const ['models', 'additionalModels']) {
    if (source[field] case final value?) {
      if (value is! List) {
        throw FormatException('provider $field must be an array');
      }
      result[field] = value
          .map(
            (model) =>
                _stripProviderModel(_requiredObject(model, 'provider model')),
          )
          .toList();
    }
  }
  if (source['disallowedTools'] case final value?) {
    result['disallowedTools'] = _stringList(value, 'provider disallowedTools');
  }
  if (source['enabled'] case final value?) {
    if (value is! bool) {
      throw const FormatException('provider enabled must be a boolean');
    }
    result['enabled'] = value;
  }
  if (source['order'] case final value?) {
    if (value is! num) {
      throw const FormatException('provider order must be a number');
    }
    result['order'] = value;
  }
  return result;
}

Map<String, Object?> _stripProviderModel(Map<String, Object?> source) {
  final id = source['id'];
  final label = source['label'];
  if (id is! String || id.isEmpty || label is! String || label.isEmpty) {
    throw const FormatException(
      'provider model id and label must be non-empty strings',
    );
  }
  final result = <String, Object?>{'id': id, 'label': label};
  if (source['description'] case final value?) {
    if (value is! String) {
      throw const FormatException(
        'provider model description must be a string',
      );
    }
    result['description'] = value;
  }
  if (source['isDefault'] case final value?) {
    if (value is! bool) {
      throw const FormatException('provider model isDefault must be a boolean');
    }
    result['isDefault'] = value;
  }
  if (source['thinkingOptions'] case final value?) {
    if (value is! List) {
      throw const FormatException(
        'provider model thinkingOptions must be an array',
      );
    }
    result['thinkingOptions'] = value
        .map(
          (option) => _stripThinkingOption(
            _requiredObject(option, 'provider thinking option'),
          ),
        )
        .toList();
  }
  return result;
}

Map<String, Object?> _stripThinkingOption(Map<String, Object?> source) {
  final id = source['id'];
  final label = source['label'];
  if (id is! String || label is! String) {
    throw const FormatException(
      'provider thinking option id and label must be strings',
    );
  }
  final result = <String, Object?>{'id': id, 'label': label};
  if (source['description'] case final value?) {
    if (value is! String) {
      throw const FormatException(
        'provider thinking option description must be a string',
      );
    }
    result['description'] = value;
  }
  if (source['isDefault'] case final value?) {
    if (value is! bool) {
      throw const FormatException(
        'provider thinking option isDefault must be a boolean',
      );
    }
    result['isDefault'] = value;
  }
  return result;
}

List<String> _nonEmptyStringList(Object? value, String field) {
  final values = _stringList(value, field);
  if (values.isEmpty || values.any((entry) => entry.isEmpty)) {
    throw FormatException('$field must contain non-empty strings');
  }
  return values;
}

Map<String, Object?> _stripMetadataGenerationProvider(
  MutableStructuredGenerationProvider provider,
) => {
  'provider': provider.provider,
  if (provider.model != null) 'model': provider.model,
  if (provider.thinkingOptionId != null)
    'thinkingOptionId': provider.thinkingOptionId,
};

Map<String, Object?> _requiredObject(Object? value, String field) {
  if (value is! Map) throw FormatException('$field must be an object');
  return Map<String, Object?>.from(value);
}

void _writePrivateFileAtomic(File file, String contents) {
  file.parent.createSync(recursive: true);
  final temporary = File('${file.path}.tmp-$pid');
  temporary.writeAsStringSync(contents, flush: true);
  // coverage:ignore-start
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['600', temporary.path]);
  }
  // coverage:ignore-end
  if (file.existsSync()) file.deleteSync();
  temporary.renameSync(file.path);
}
