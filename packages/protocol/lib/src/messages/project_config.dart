final class ProjectConfigRevision {
  const ProjectConfigRevision({required this.mtimeMs, required this.size});
  final num mtimeMs;
  final num size;

  factory ProjectConfigRevision.fromJson(Map<String, Object?> json) {
    final mtimeMs = json['mtimeMs'];
    final size = json['size'];
    if (mtimeMs is! num || size is! num) {
      throw const FormatException('Invalid project config revision');
    }
    return ProjectConfigRevision(mtimeMs: mtimeMs, size: size);
  }

  Map<String, Object?> toJson() => {'mtimeMs': mtimeMs, 'size': size};
}

final class ReadProjectConfigRequest {
  const ReadProjectConfigRequest({
    required this.requestId,
    required this.repoRoot,
  });
  final String requestId;
  final String repoRoot;

  factory ReadProjectConfigRequest.fromJson(Map<String, Object?> json) {
    final requestId = json['requestId'];
    final repoRoot = json['repoRoot'];
    if (requestId is! String || repoRoot is! String) {
      throw const FormatException('Invalid read project config request');
    }
    return ReadProjectConfigRequest(requestId: requestId, repoRoot: repoRoot);
  }
}

final class WriteProjectConfigRequest {
  const WriteProjectConfigRequest({
    required this.requestId,
    required this.repoRoot,
    required this.config,
    required this.expectedRevision,
  });
  final String requestId;
  final String repoRoot;
  final Map<String, Object?> config;
  final ProjectConfigRevision? expectedRevision;

  factory WriteProjectConfigRequest.fromJson(Map<String, Object?> json) {
    final requestId = json['requestId'];
    final repoRoot = json['repoRoot'];
    final config = json['config'];
    final expectedRevision = json['expectedRevision'];
    if (requestId is! String ||
        repoRoot is! String ||
        config is! Map<String, Object?> ||
        (expectedRevision != null &&
            expectedRevision is! Map<String, Object?>)) {
      throw const FormatException('Invalid write project config request');
    }
    return WriteProjectConfigRequest(
      requestId: requestId,
      repoRoot: repoRoot,
      config: validateProjectConfigRaw(config),
      expectedRevision: expectedRevision == null
          ? null
          : ProjectConfigRevision.fromJson(
              expectedRevision as Map<String, Object?>,
            ),
    );
  }
}

Map<String, Object?> validateProjectConfigRaw(Map<String, Object?> config) {
  final result = Map<String, Object?>.from(config);
  final worktree = config['worktree'];
  if (worktree != null) {
    if (worktree is! Map<String, Object?>) {
      throw const FormatException('Invalid worktree project config');
    }
    final normalized = Map<String, Object?>.from(worktree);
    for (final key in ['setup', 'teardown']) {
      final value = normalized[key];
      if (value != null &&
          value is! String &&
          !(value is List && value.every((item) => item is String))) {
        throw FormatException('Invalid worktree $key commands');
      }
    }
    final servicePorts = normalized['servicePorts'];
    if (servicePorts != null) {
      if (servicePorts is! Map<String, Object?> ||
          servicePorts.keys.any(
            (key) => key != 'range' && key != 'portScript',
          )) {
        throw const FormatException('Invalid servicePorts config');
      }
      final range = servicePorts['range'];
      final script = servicePorts['portScript'];
      if (range == null && script == null) {
        throw const FormatException('Expected range or portScript');
      }
      if (range != null && range is! String ||
          script != null && script is! String) {
        throw const FormatException('Invalid servicePorts values');
      }
      final normalizedPorts = <String, Object?>{};
      if (range is String) {
        final trimmed = range.trim();
        final match = RegExp(r'^(\d{1,5})-(\d{1,5})$').firstMatch(trimmed);
        if (match == null) throw const FormatException('Invalid port range');
        final start = int.parse(match.group(1)!);
        final end = int.parse(match.group(2)!);
        if (start < 1 || end > 65535 || start > end) {
          throw const FormatException('Invalid port range');
        }
        normalizedPorts['range'] = trimmed;
      }
      if (script is String) {
        final trimmed = script.trim();
        if (trimmed.isEmpty) {
          throw const FormatException('Invalid port script');
        }
        normalizedPorts['portScript'] = trimmed;
      }
      normalized['servicePorts'] = normalizedPorts;
    }
    result['worktree'] = normalized;
  }
  final scripts = config['scripts'];
  if (scripts != null) {
    if (scripts is! Map<String, Object?> ||
        scripts.values.any((value) => value is! Map<String, Object?>)) {
      throw const FormatException('Invalid scripts project config');
    }
  }
  final metadata = config['metadataGeneration'];
  if (metadata != null) {
    if (metadata is! Map<String, Object?>) {
      result['metadataGeneration'] = <String, Object?>{};
    } else {
      final normalized = Map<String, Object?>.from(metadata);
      for (final key in [
        'title',
        'branchName',
        'commitMessage',
        'pullRequest',
      ]) {
        final entry = normalized[key];
        if (entry == null) continue;
        if (entry is! Map<String, Object?> ||
            (entry['instructions'] != null &&
                entry['instructions'] is! String)) {
          normalized[key] = <String, Object?>{};
        }
      }
      result['metadataGeneration'] = normalized;
    }
  }
  return result;
}
