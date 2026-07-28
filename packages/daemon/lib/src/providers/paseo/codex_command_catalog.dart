import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

Future<List<AgentSlashCommand>> listCodexCommands({
  required String cwd,
  required Future<Object?> Function(String method, Object? params) request,
  Map<String, String>? environment,
}) async {
  final commands = <String, AgentSlashCommand>{
    'compact': const AgentSlashCommand(
      name: 'compact',
      description:
          'Summarize conversation to prevent hitting the context limit',
      argumentHint: '',
    ),
  };

  final appServerSkills = await _listAppServerSkills(cwd, request);
  final skills = appServerSkills.isEmpty
      ? await _listFileSkills(cwd, environment ?? Platform.environment)
      : appServerSkills;
  for (final command in skills) {
    commands.putIfAbsent(command.name, () => command);
  }
  for (final command in await _listCustomPrompts(
    environment ?? Platform.environment,
  )) {
    commands.putIfAbsent(command.name, () => command);
  }
  final result = commands.values.toList()
    ..sort((left, right) => left.name.compareTo(right.name));
  return List.unmodifiable(result);
}

Future<List<AgentSlashCommand>> _listAppServerSkills(
  String cwd,
  Future<Object?> Function(String method, Object? params) request,
) async {
  try {
    final response = _record(
      await request('skills/list', {
        'cwd': [cwd],
      }),
    );
    final data = response?['data'];
    if (data is! List) return const [];
    final byName = <String, AgentSlashCommand>{};
    for (final groupValue in data) {
      final group = _record(groupValue);
      final skills = group?['skills'];
      if (skills is! List) continue;
      for (final value in skills) {
        final skill = _record(value);
        final name = skill?['name'];
        final path = skill?['path'];
        if (name is! String || name.isEmpty || path is! String) continue;
        final description =
            _nonEmpty(skill?['description']) ??
            _nonEmpty(skill?['shortDescription']) ??
            _nonEmpty(skill?['short_description']) ??
            'Skill';
        byName.putIfAbsent(
          name,
          () => AgentSlashCommand(
            name: name,
            description: description,
            argumentHint: '',
            kind: AgentSlashCommandKind.skill,
          ),
        );
      }
    }
    return byName.values.toList();
  } on Object {
    return const [];
  }
}

Future<List<AgentSlashCommand>> _listCustomPrompts(
  Map<String, String> environment,
) async {
  final directory = Directory(p.join(_codexHome(environment), 'prompts'));
  List<FileSystemEntity> entries;
  try {
    entries = await directory.list(followLinks: false).toList();
  } on FileSystemException {
    return const [];
  }
  final result = <AgentSlashCommand>[];
  for (final entry in entries) {
    if (entry is! File || p.extension(entry.path) != '.md') continue;
    final name = p.basenameWithoutExtension(entry.path);
    if (name.isEmpty) continue;
    try {
      final metadata = _frontMatter(await entry.readAsString());
      result.add(
        AgentSlashCommand(
          name: 'prompts:$name',
          description: metadata['description'] ?? 'Custom prompt',
          argumentHint:
              metadata['argument-hint'] ?? metadata['argument_hint'] ?? '',
        ),
      );
    } on FileSystemException {
      // A single unreadable prompt does not hide the remaining catalog.
    }
  }
  result.sort((left, right) => left.name.compareTo(right.name));
  return result;
}

Future<List<AgentSlashCommand>> _listFileSkills(
  String cwd,
  Map<String, String> environment,
) async {
  final candidates = <String>[
    p.join(cwd, '.codex', 'skills'),
    p.join(_codexHome(environment), 'skills'),
  ];
  final repoRoot = await _findRepoRoot(cwd);
  if (repoRoot != null) {
    candidates.insert(1, p.join(p.dirname(cwd), '.codex', 'skills'));
    candidates.insert(2, p.join(repoRoot, '.codex', 'skills'));
  }
  final byName = <String, AgentSlashCommand>{};
  for (final candidate in candidates) {
    final directory = Directory(candidate);
    List<FileSystemEntity> entries;
    try {
      entries = await directory.list(followLinks: false).toList();
    } on FileSystemException {
      continue;
    }
    for (final entry in entries) {
      if (entry is! Directory && entry is! Link) continue;
      final file = File(p.join(entry.path, 'SKILL.md'));
      try {
        final metadata = _frontMatter(await file.readAsString());
        final name = metadata['name'];
        final description = metadata['description'];
        if (name == null || description == null) continue;
        byName.putIfAbsent(
          name,
          () => AgentSlashCommand(
            name: name,
            description: description,
            argumentHint: '',
            kind: AgentSlashCommandKind.skill,
          ),
        );
      } on FileSystemException {
        continue;
      }
    }
  }
  final result = byName.values.toList()
    ..sort((left, right) => left.name.compareTo(right.name));
  return result;
}

Future<String?> _findRepoRoot(String cwd) async {
  var current = Directory(cwd).absolute.path;
  while (true) {
    if (await FileSystemEntity.type(p.join(current, '.git')) !=
        FileSystemEntityType.notFound) {
      return current;
    }
    final parent = p.dirname(current);
    if (parent == current) return null;
    current = parent;
  }
}

String _codexHome(Map<String, String> environment) =>
    environment['CODEX_HOME'] ??
    p.join(
      environment['HOME'] ??
          environment['USERPROFILE'] ??
          Directory.current.path,
      '.codex',
    );

Map<String, String> _frontMatter(String content) {
  final lines = content.split(RegExp(r'\r?\n'));
  if (lines.isEmpty || lines.first.trim() != '---') return const {};
  final result = <String, String>{};
  for (var index = 1; index < lines.length; index++) {
    final line = lines[index].trim();
    if (line == '---') break;
    if (line.isEmpty || line.startsWith('#')) continue;
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    final key = line.substring(0, separator).trim();
    var value = line.substring(separator + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    if (key.isNotEmpty && value.isNotEmpty) result[key] = value;
  }
  return result;
}

Map<String, Object?>? _record(Object? value) {
  if (value is! Map) return null;
  return Map<String, Object?>.from(value);
}

String? _nonEmpty(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;
