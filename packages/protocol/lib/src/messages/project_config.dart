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

sealed class ProjectConfigRpcError {
  const ProjectConfigRpcError();

  String get code;
  Map<String, Object?> toJson();

  factory ProjectConfigRpcError.fromJson(Map<String, Object?> json) {
    return switch (json['code']) {
      'project_not_found' => const ProjectConfigProjectNotFound(),
      'invalid_project_config' => const ProjectConfigInvalid(),
      'stale_project_config' =>
        json.containsKey('currentRevision')
            ? ProjectConfigStale(
                currentRevision: json['currentRevision'] == null
                    ? null
                    : ProjectConfigRevision.fromJson(
                        _requiredMap(json, 'currentRevision'),
                      ),
              )
            : throw const FormatException(
                'currentRevision is required for stale_project_config',
              ),
      'write_failed' => const ProjectConfigWriteFailed(),
      final code => throw FormatException(
        'Unknown project config error code: $code',
      ),
    };
  }
}

final class ProjectConfigProjectNotFound extends ProjectConfigRpcError {
  const ProjectConfigProjectNotFound();

  @override
  String get code => 'project_not_found';

  @override
  Map<String, Object?> toJson() => {'code': code};
}

final class ProjectConfigInvalid extends ProjectConfigRpcError {
  const ProjectConfigInvalid();

  @override
  String get code => 'invalid_project_config';

  @override
  Map<String, Object?> toJson() => {'code': code};
}

final class ProjectConfigStale extends ProjectConfigRpcError {
  const ProjectConfigStale({required this.currentRevision});

  final ProjectConfigRevision? currentRevision;

  @override
  String get code => 'stale_project_config';

  @override
  Map<String, Object?> toJson() => {
    'code': code,
    'currentRevision': currentRevision?.toJson(),
  };
}

final class ProjectConfigWriteFailed extends ProjectConfigRpcError {
  const ProjectConfigWriteFailed();

  @override
  String get code => 'write_failed';

  @override
  Map<String, Object?> toJson() => {'code': code};
}

final class ReadProjectConfigRequest {
  const ReadProjectConfigRequest({
    required this.requestId,
    required this.repoRoot,
  });
  static const type = 'read_project_config_request';

  final String requestId;
  final String repoRoot;

  factory ReadProjectConfigRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final requestId = json['requestId'];
    final repoRoot = json['repoRoot'];
    if (requestId is! String || repoRoot is! String) {
      throw const FormatException('Invalid read project config request');
    }
    return ReadProjectConfigRequest(requestId: requestId, repoRoot: repoRoot);
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'repoRoot': repoRoot,
  };
}

final class WriteProjectConfigRequest {
  const WriteProjectConfigRequest({
    required this.requestId,
    required this.repoRoot,
    required this.config,
    required this.expectedRevision,
  });
  static const type = 'write_project_config_request';

  final String requestId;
  final String repoRoot;
  final Map<String, Object?> config;
  final ProjectConfigRevision? expectedRevision;

  factory WriteProjectConfigRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final requestId = json['requestId'];
    final repoRoot = json['repoRoot'];
    final config = json['config'];
    final expectedRevision = json['expectedRevision'];
    if (requestId is! String ||
        repoRoot is! String ||
        config is! Map<String, Object?> ||
        !json.containsKey('expectedRevision') ||
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
              Map<String, Object?>.from(expectedRevision as Map),
            ),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'repoRoot': repoRoot,
    'config': config,
    'expectedRevision': expectedRevision?.toJson(),
  };
}

sealed class ReadProjectConfigResponse {
  const ReadProjectConfigResponse({
    required this.requestId,
    required this.repoRoot,
  });

  static const type = 'read_project_config_response';

  final String requestId;
  final String repoRoot;
  bool get ok;
  Map<String, Object?> toJson();

  factory ReadProjectConfigResponse.fromJson(Map<String, Object?> json) {
    final payload = _responsePayload(json, type);
    final requestId = _requiredString(payload, 'requestId');
    final repoRoot = _requiredString(payload, 'repoRoot');
    return switch (payload['ok']) {
      true =>
        payload.containsKey('config') && payload.containsKey('revision')
            ? ReadProjectConfigSuccess(
                requestId: requestId,
                repoRoot: repoRoot,
                config: payload['config'] == null
                    ? null
                    : validateProjectConfigRaw(_requiredMap(payload, 'config')),
                revision: payload['revision'] == null
                    ? null
                    : ProjectConfigRevision.fromJson(
                        _requiredMap(payload, 'revision'),
                      ),
              )
            : throw const FormatException(
                'Read project config success fields are required',
              ),
      false => ReadProjectConfigFailure(
        requestId: requestId,
        repoRoot: repoRoot,
        error: ProjectConfigRpcError.fromJson(_requiredMap(payload, 'error')),
      ),
      _ => throw const FormatException(
        'Invalid read project config response discriminator',
      ),
    };
  }
}

final class ReadProjectConfigSuccess extends ReadProjectConfigResponse {
  const ReadProjectConfigSuccess({
    required super.requestId,
    required super.repoRoot,
    required this.config,
    required this.revision,
  });

  final Map<String, Object?>? config;
  final ProjectConfigRevision? revision;

  @override
  bool get ok => true;

  @override
  Map<String, Object?> toJson() => {
    'type': ReadProjectConfigResponse.type,
    'payload': {
      'requestId': requestId,
      'repoRoot': repoRoot,
      'ok': true,
      'config': config,
      'revision': revision?.toJson(),
    },
  };
}

final class ReadProjectConfigFailure extends ReadProjectConfigResponse {
  const ReadProjectConfigFailure({
    required super.requestId,
    required super.repoRoot,
    required this.error,
  });

  final ProjectConfigRpcError error;

  @override
  bool get ok => false;

  @override
  Map<String, Object?> toJson() => {
    'type': ReadProjectConfigResponse.type,
    'payload': {
      'requestId': requestId,
      'repoRoot': repoRoot,
      'ok': false,
      'error': error.toJson(),
    },
  };
}

sealed class WriteProjectConfigResponse {
  const WriteProjectConfigResponse({
    required this.requestId,
    required this.repoRoot,
  });

  static const type = 'write_project_config_response';

  final String requestId;
  final String repoRoot;
  bool get ok;
  Map<String, Object?> toJson();

  factory WriteProjectConfigResponse.fromJson(Map<String, Object?> json) {
    final payload = _responsePayload(json, type);
    final requestId = _requiredString(payload, 'requestId');
    final repoRoot = _requiredString(payload, 'repoRoot');
    return switch (payload['ok']) {
      true => WriteProjectConfigSuccess(
        requestId: requestId,
        repoRoot: repoRoot,
        config: validateProjectConfigRaw(_requiredMap(payload, 'config')),
        revision: ProjectConfigRevision.fromJson(
          _requiredMap(payload, 'revision'),
        ),
      ),
      false => WriteProjectConfigFailure(
        requestId: requestId,
        repoRoot: repoRoot,
        error: ProjectConfigRpcError.fromJson(_requiredMap(payload, 'error')),
      ),
      _ => throw const FormatException(
        'Invalid write project config response discriminator',
      ),
    };
  }
}

final class WriteProjectConfigSuccess extends WriteProjectConfigResponse {
  const WriteProjectConfigSuccess({
    required super.requestId,
    required super.repoRoot,
    required this.config,
    required this.revision,
  });

  final Map<String, Object?> config;
  final ProjectConfigRevision revision;

  @override
  bool get ok => true;

  @override
  Map<String, Object?> toJson() => {
    'type': WriteProjectConfigResponse.type,
    'payload': {
      'requestId': requestId,
      'repoRoot': repoRoot,
      'ok': true,
      'config': config,
      'revision': revision.toJson(),
    },
  };
}

final class WriteProjectConfigFailure extends WriteProjectConfigResponse {
  const WriteProjectConfigFailure({
    required super.requestId,
    required super.repoRoot,
    required this.error,
  });

  final ProjectConfigRpcError error;

  @override
  bool get ok => false;

  @override
  Map<String, Object?> toJson() => {
    'type': WriteProjectConfigResponse.type,
    'payload': {
      'requestId': requestId,
      'repoRoot': repoRoot,
      'ok': false,
      'error': error.toJson(),
    },
  };
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

void _expectType(Map<String, Object?> json, String type) {
  if (json['type'] != type) throw FormatException('Expected $type');
}

Map<String, Object?> _responsePayload(Map<String, Object?> json, String type) {
  _expectType(json, type);
  return _requiredMap(json, 'payload');
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return Map<String, Object?>.from(value);
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}
