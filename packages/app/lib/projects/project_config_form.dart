/// Lossless projection between a raw Paseo project config and its editable UI
/// draft.
///
/// The settings screen intentionally edits only a small public surface. All
/// unknown fields are retained so opening and saving a config created by a
/// newer daemon cannot discard data.
enum LifecycleOriginalKind { string, array, missing }

const metadataPromptKeys = <String>[
  'branchName',
  'commitMessage',
  'pullRequest',
];

final class ProjectScriptDraft {
  ProjectScriptDraft({
    required this.id,
    required this.name,
    required this.commandText,
    required this.commandOriginalKind,
    required this.type,
    required this.portText,
    required this.rawEntry,
  });

  final String id;
  String name;
  String commandText;
  final LifecycleOriginalKind commandOriginalKind;
  String type;
  String portText;
  final Map<String, Object?> rawEntry;
}

final class ProjectConfigDraft {
  ProjectConfigDraft({
    required this.setupText,
    required this.setupOriginalKind,
    required this.teardownText,
    required this.teardownOriginalKind,
    required this.scripts,
    required this.metadataPrompts,
    required this.metadataGenerationBase,
  });

  String setupText;
  final LifecycleOriginalKind setupOriginalKind;
  String teardownText;
  final LifecycleOriginalKind teardownOriginalKind;
  List<ProjectScriptDraft> scripts;
  final Map<String, String> metadataPrompts;
  final Map<String, Object?>? metadataGenerationBase;
}

typedef _LifecycleProjection = ({String text, LifecycleOriginalKind kind});

int _scriptDraftIdCounter = 0;

ProjectConfigDraft configToDraft(Map<String, Object?>? config) {
  final worktree = _mapOrEmpty(config?['worktree']);
  final setup = _projectLifecycle(worktree['setup']);
  final teardown = _projectLifecycle(worktree['teardown']);
  final scripts = <ProjectScriptDraft>[];

  for (final entry in _mapOrEmpty(config?['scripts']).entries) {
    final rawEntry = _mapOrEmpty(entry.value);
    final command = _projectLifecycle(rawEntry['command']);
    scripts.add(
      ProjectScriptDraft(
        id: _nextScriptDraftId(),
        name: entry.key,
        commandText: command.text,
        commandOriginalKind: command.kind,
        type: rawEntry['type'] is String ? rawEntry['type']! as String : '',
        portText: switch (rawEntry['port']) {
          final num value when value.isFinite => _numberText(value),
          final String value => value,
          _ => '',
        },
        rawEntry: Map<String, Object?>.from(rawEntry),
      ),
    );
  }

  final metadata = _nullableMap(config?['metadataGeneration']);
  final metadataPrompts = <String, String>{
    for (final key in metadataPromptKeys) key: '',
  };
  for (final key in metadataPromptKeys) {
    final instructions = _nullableMap(metadata?[key])?['instructions'];
    if (instructions is String) metadataPrompts[key] = instructions;
  }

  return ProjectConfigDraft(
    setupText: setup.text,
    setupOriginalKind: setup.kind,
    teardownText: teardown.text,
    teardownOriginalKind: teardown.kind,
    scripts: scripts,
    metadataPrompts: metadataPrompts,
    metadataGenerationBase: metadata == null
        ? null
        : Map<String, Object?>.from(metadata),
  );
}

Map<String, Object?> applyDraftToConfig({
  required ProjectConfigDraft draft,
  required Map<String, Object?>? base,
}) {
  final baseConfig = base ?? const <String, Object?>{};
  final nextWorktree = Map<String, Object?>.from(
    _mapOrEmpty(baseConfig['worktree']),
  );

  _replaceOptional(
    nextWorktree,
    'setup',
    _lifecycleFromText(draft.setupText, draft.setupOriginalKind),
  );
  _replaceOptional(
    nextWorktree,
    'teardown',
    _lifecycleFromText(draft.teardownText, draft.teardownOriginalKind),
  );

  final nextScripts = <String, Object?>{};
  for (final row in draft.scripts) {
    final name = row.name.trim();
    if (name.isEmpty) continue;
    final nextEntry = Map<String, Object?>.from(row.rawEntry);
    _replaceOptional(
      nextEntry,
      'command',
      _lifecycleFromText(row.commandText, row.commandOriginalKind),
    );
    _replaceOptional(
      nextEntry,
      'type',
      row.type.trim().isEmpty ? null : row.type.trim(),
    );
    _replaceOptional(nextEntry, 'port', _parseScriptPort(row.portText));
    nextScripts[name] = nextEntry;
  }

  final nextMetadata = Map<String, Object?>.from(
    draft.metadataGenerationBase ?? const <String, Object?>{},
  );
  for (final key in metadataPromptKeys) {
    final text = draft.metadataPrompts[key] ?? '';
    final baseEntry = _nullableMap(draft.metadataGenerationBase?[key]);
    if (text.trim().isEmpty) {
      if (baseEntry == null) {
        nextMetadata.remove(key);
        continue;
      }
      final nextEntry = Map<String, Object?>.from(baseEntry)
        ..remove('instructions');
      if (nextEntry.isEmpty) {
        nextMetadata.remove(key);
      } else {
        nextMetadata[key] = nextEntry;
      }
    } else {
      nextMetadata[key] = <String, Object?>{
        ...?baseEntry,
        'instructions': text,
      };
    }
  }

  final result = Map<String, Object?>.from(baseConfig);
  _replaceOptional(
    result,
    'worktree',
    nextWorktree.isEmpty ? null : nextWorktree,
  );
  _replaceOptional(result, 'scripts', nextScripts.isEmpty ? null : nextScripts);
  _replaceOptional(
    result,
    'metadataGeneration',
    nextMetadata.isEmpty ? null : nextMetadata,
  );
  return result;
}

_LifecycleProjection _projectLifecycle(Object? value) {
  if (value is String) {
    return (text: value, kind: LifecycleOriginalKind.string);
  }
  if (value is List) {
    return (
      text: value.whereType<String>().join('\n'),
      kind: LifecycleOriginalKind.array,
    );
  }
  return (text: '', kind: LifecycleOriginalKind.missing);
}

Object? _lifecycleFromText(String text, LifecycleOriginalKind kind) {
  final lines = text
      .split('\n')
      .where((line) => line.trim().isNotEmpty)
      .toList(growable: false);
  if (lines.isEmpty) return null;
  return switch (kind) {
    LifecycleOriginalKind.string => lines.join('\n'),
    LifecycleOriginalKind.array => lines,
    LifecycleOriginalKind.missing => lines.length == 1 ? lines.single : lines,
  };
}

Object? _parseScriptPort(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (RegExp(r'^[0-9]+$').hasMatch(trimmed)) {
    final parsed = int.tryParse(trimmed);
    if (parsed != null) return parsed;
  }
  return trimmed;
}

String _numberText(num value) =>
    value == value.truncateToDouble() ? value.toInt().toString() : '$value';

String _nextScriptDraftId() => 'script-draft-${++_scriptDraftIdCounter}';

Map<String, Object?> _mapOrEmpty(Object? value) =>
    _nullableMap(value) ?? const <String, Object?>{};

Map<String, Object?>? _nullableMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry('$key', value));
  }
  return null;
}

void _replaceOptional(Map<String, Object?> map, String key, Object? value) {
  if (value == null) {
    map.remove(key);
  } else {
    map[key] = value;
  }
}
