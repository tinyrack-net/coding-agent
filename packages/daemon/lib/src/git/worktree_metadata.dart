import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

final class WorktreeMetadata {
  const WorktreeMetadata({
    required this.version,
    required this.baseRefName,
    this.changeRequestLookupTarget,
    this.firstAgentBranchAutoName,
    this.worktreePort,
  });

  final int version;
  final String baseRefName;
  final Map<String, Object?>? changeRequestLookupTarget;
  final Map<String, Object?>? firstAgentBranchAutoName;
  final int? worktreePort;

  factory WorktreeMetadata.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    if (version != 1 && version != 2) {
      throw const FormatException('Invalid worktree metadata version');
    }
    final baseRefName = _nonEmptyString(json['baseRefName'], 'baseRefName');
    final changeRequest = _changeRequest(json['changeRequestLookupTarget']);
    final firstAgent = version == 2
        ? _firstAgentBranchAutoName(json['firstAgentBranchAutoName'])
        : null;
    int? worktreePort;
    if (version == 2 && json['runtime'] != null) {
      final runtime = _object(json['runtime'], 'runtime');
      worktreePort = _positiveInt(runtime['worktreePort'], 'worktreePort');
    }
    return WorktreeMetadata(
      version: version as int,
      baseRefName: baseRefName,
      changeRequestLookupTarget: changeRequest,
      firstAgentBranchAutoName: firstAgent,
      worktreePort: worktreePort,
    );
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'baseRefName': baseRefName,
    if (changeRequestLookupTarget != null)
      'changeRequestLookupTarget': changeRequestLookupTarget,
    if (version == 2 && firstAgentBranchAutoName != null)
      'firstAgentBranchAutoName': firstAgentBranchAutoName,
    if (version == 2 && worktreePort != null)
      'runtime': {'worktreePort': worktreePort},
  };
}

String worktreeMetadataPath(String worktreeRoot) => p.join(
  _gitDirectoryForWorktreeRoot(worktreeRoot),
  'paseo',
  'worktree.json',
);

String normalizeWorktreeBaseRefName(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError('Base branch is required');
  }
  return trimmed.startsWith('origin/')
      ? trimmed.substring('origin/'.length)
      : trimmed;
}

void writeWorktreeBaseMetadata(
  String worktreeRoot, {
  required String baseRefName,
  Map<String, Object?>? changeRequestLookupTarget,
}) {
  final normalized = normalizeWorktreeBaseRefName(baseRefName);
  if (normalized == 'HEAD') {
    throw ArgumentError('Base branch cannot be HEAD');
  }
  if (normalized.contains('..') ||
      normalized.contains('@{') ||
      !RegExp(r'^[0-9A-Za-z._/-]+$').hasMatch(normalized)) {
    throw ArgumentError('Invalid base branch: $normalized');
  }
  final target = changeRequestLookupTarget == null
      ? null
      : _changeRequest(changeRequestLookupTarget);
  _writeMetadata(
    worktreeRoot,
    WorktreeMetadata(
      version: 1,
      baseRefName: normalized,
      changeRequestLookupTarget: target,
    ),
  );
}

void writeWorktreeRuntimeMetadata(
  String worktreeRoot, {
  required int worktreePort,
}) {
  if (worktreePort <= 0) {
    throw ArgumentError('Invalid worktree runtime port: $worktreePort');
  }
  final current = readWorktreeMetadata(worktreeRoot);
  if (current == null) {
    throw StateError(
      'Cannot persist worktree runtime metadata: missing base metadata',
    );
  }
  _writeMetadata(
    worktreeRoot,
    WorktreeMetadata(
      version: 2,
      baseRefName: current.baseRefName,
      changeRequestLookupTarget: current.changeRequestLookupTarget,
      firstAgentBranchAutoName: current.firstAgentBranchAutoName,
      worktreePort: worktreePort,
    ),
  );
}

WorktreeMetadata? readWorktreeMetadata(String worktreeRoot) {
  final file = File(worktreeMetadataPath(worktreeRoot));
  if (!file.existsSync()) return null;
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('Worktree metadata must be an object');
  }
  return WorktreeMetadata.fromJson(decoded);
}

int? readWorktreeRuntimePort(String worktreeRoot) =>
    readWorktreeMetadata(worktreeRoot)?.worktreePort;

String _gitDirectoryForWorktreeRoot(String worktreeRoot) {
  final gitPath = p.join(worktreeRoot, '.git');
  final type = FileSystemEntity.typeSync(gitPath);
  if (type == FileSystemEntityType.notFound) {
    throw StateError('Not a git repository: $worktreeRoot');
  }
  if (type == FileSystemEntityType.file) {
    final match = RegExp(
      r'^gitdir:\s*(.+)$',
      multiLine: true,
    ).firstMatch(File(gitPath).readAsStringSync());
    final raw = match?.group(1)?.trim();
    if (raw != null && raw.isNotEmpty) {
      return p.normalize(p.isAbsolute(raw) ? raw : p.join(worktreeRoot, raw));
    }
  }
  return gitPath;
}

void _writeMetadata(String worktreeRoot, WorktreeMetadata metadata) {
  final path = worktreeMetadataPath(worktreeRoot);
  Directory(p.dirname(path)).createSync(recursive: true);
  final temporary = File(
    '$path.${pid}.${DateTime.now().millisecondsSinceEpoch}.tmp',
  );
  temporary.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(metadata.toJson())}\n',
    flush: true,
  );
  try {
    temporary.renameSync(path);
  } finally {
    if (temporary.existsSync()) {
      temporary.deleteSync();
    }
  }
}

Map<String, Object?> _object(Object? value, String field) {
  if (value is! Map) throw FormatException('$field must be an object');
  return value.map((key, value) {
    if (key is! String) throw FormatException('$field keys must be strings');
    return MapEntry(key, value);
  });
}

String _nonEmptyString(Object? value, String field) {
  if (value is! String || value.isEmpty) {
    throw FormatException('$field must be a non-empty string');
  }
  return value;
}

int _positiveInt(Object? value, String field) {
  if (value is! int || value <= 0) {
    throw FormatException('$field must be a positive integer');
  }
  return value;
}

Map<String, Object?>? _changeRequest(Object? value) {
  if (value == null) return null;
  final input = _object(value, 'changeRequestLookupTarget');
  final result = <String, Object?>{
    'headRef': _nonEmptyString(input['headRef'], 'headRef'),
  };
  if (input['headRepositoryOwner'] != null) {
    result['headRepositoryOwner'] = _nonEmptyString(
      input['headRepositoryOwner'],
      'headRepositoryOwner',
    );
  }
  if (input['changeRequestNumber'] != null) {
    result['changeRequestNumber'] = _positiveInt(
      input['changeRequestNumber'],
      'changeRequestNumber',
    );
  }
  return Map.unmodifiable(result);
}

Map<String, Object?>? _firstAgentBranchAutoName(Object? value) {
  if (value == null) return null;
  final input = _object(value, 'firstAgentBranchAutoName');
  final status = input['status'];
  if (status != 'pending' && status != 'attempted') {
    throw const FormatException('Invalid first agent branch auto-name status');
  }
  final result = <String, Object?>{
    'status': status,
    'placeholderBranchName': _nonEmptyString(
      input['placeholderBranchName'],
      'placeholderBranchName',
    ),
  };
  if (status == 'attempted') {
    result['attemptedAt'] = _nonEmptyString(
      input['attemptedAt'],
      'attemptedAt',
    );
  }
  return Map.unmodifiable(result);
}
