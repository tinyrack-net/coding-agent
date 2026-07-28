/// Paseo 0.2.0 workspace setup progress and cached-status wire contract.
library;

enum WorkspaceSetupStatus {
  running,
  completed,
  failed;

  static WorkspaceSetupStatus fromWire(Object? value) {
    if (value is String) {
      for (final status in values) {
        if (status.name == value) return status;
      }
    }
    throw FormatException('Unknown workspace setup status: $value');
  }
}

enum WorkspaceSetupCommandStatus {
  running,
  completed,
  failed;

  static WorkspaceSetupCommandStatus fromWire(Object? value) {
    if (value is String) {
      for (final status in values) {
        if (status.name == value) return status;
      }
    }
    throw FormatException('Unknown workspace setup command status: $value');
  }
}

final class WorkspaceSetupCommand {
  const WorkspaceSetupCommand({
    required this.index,
    required this.command,
    required this.cwd,
    required this.status,
    required this.exitCode,
    this.log = '',
    this.durationMs,
  });

  final int index;
  final String command;
  final String cwd;
  final String log;
  final WorkspaceSetupCommandStatus status;
  final num? exitCode;
  final num? durationMs;

  factory WorkspaceSetupCommand.fromJson(Map<String, Object?> json) {
    final index = _requiredInt(json, 'index');
    if (index <= 0) {
      throw const FormatException('index must be a positive integer');
    }
    final durationMs = _nullableNum(json, 'durationMs');
    if (durationMs != null && durationMs < 0) {
      throw const FormatException('durationMs must be nonnegative');
    }
    return WorkspaceSetupCommand(
      index: index,
      command: _requiredString(json, 'command'),
      cwd: _requiredString(json, 'cwd'),
      log: _optionalString(json, 'log') ?? '',
      status: WorkspaceSetupCommandStatus.fromWire(json['status']),
      exitCode: _nullableNum(json, 'exitCode'),
      durationMs: durationMs,
    );
  }

  Map<String, Object?> toJson() => {
    'index': index,
    'command': command,
    'cwd': cwd,
    'log': log,
    'status': status.name,
    'exitCode': exitCode,
    if (durationMs != null) 'durationMs': durationMs,
  };
}

final class WorkspaceSetupDetail {
  const WorkspaceSetupDetail({
    required this.worktreePath,
    required this.branchName,
    required this.log,
    required this.commands,
    this.truncated,
  });

  final String worktreePath;
  final String branchName;
  final String log;
  final List<WorkspaceSetupCommand> commands;
  final bool? truncated;

  factory WorkspaceSetupDetail.fromJson(Map<String, Object?> json) {
    if (json['type'] != 'worktree_setup') {
      throw const FormatException(
        'workspace setup detail type must be worktree_setup',
      );
    }
    final rawCommands = json['commands'];
    if (rawCommands is! List) {
      throw const FormatException('commands must be an array');
    }
    return WorkspaceSetupDetail(
      worktreePath: _requiredString(json, 'worktreePath'),
      branchName: _requiredString(json, 'branchName'),
      log: _requiredString(json, 'log'),
      commands: List.unmodifiable(
        rawCommands.map((entry) {
          if (entry is! Map) {
            throw const FormatException('commands entries must be objects');
          }
          return WorkspaceSetupCommand.fromJson(entry.cast<String, Object?>());
        }),
      ),
      truncated: _optionalBool(json, 'truncated'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'worktree_setup',
    'worktreePath': worktreePath,
    'branchName': branchName,
    'log': log,
    'commands': commands.map((command) => command.toJson()).toList(),
    if (truncated != null) 'truncated': truncated,
  };
}

final class WorkspaceSetupSnapshot {
  const WorkspaceSetupSnapshot({
    required this.status,
    required this.detail,
    required this.error,
  });

  final WorkspaceSetupStatus status;
  final WorkspaceSetupDetail detail;
  final String? error;

  factory WorkspaceSetupSnapshot.fromJson(Map<String, Object?> json) =>
      WorkspaceSetupSnapshot(
        status: WorkspaceSetupStatus.fromWire(json['status']),
        detail: WorkspaceSetupDetail.fromJson(_requiredMap(json, 'detail')),
        error: _nullableString(json, 'error'),
      );

  Map<String, Object?> toJson() => {
    'status': status.name,
    'detail': detail.toJson(),
    'error': error,
  };
}

final class WorkspaceSetupStatusRequest {
  const WorkspaceSetupStatusRequest({
    required this.workspaceId,
    required this.requestId,
  });

  static const type = 'workspace_setup_status_request';

  final String workspaceId;
  final String requestId;

  factory WorkspaceSetupStatusRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return WorkspaceSetupStatusRequest(
      workspaceId: _requiredString(json, 'workspaceId'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'workspaceId': workspaceId,
    'requestId': requestId,
  };
}

final class WorkspaceSetupProgress {
  const WorkspaceSetupProgress({
    required this.workspaceId,
    required this.snapshot,
  });

  static const type = 'workspace_setup_progress';

  final String workspaceId;
  final WorkspaceSetupSnapshot snapshot;

  factory WorkspaceSetupProgress.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredMap(json, 'payload');
    return WorkspaceSetupProgress(
      workspaceId: _requiredString(payload, 'workspaceId'),
      snapshot: WorkspaceSetupSnapshot.fromJson(payload),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {'workspaceId': workspaceId, ...snapshot.toJson()},
  };
}

final class WorkspaceSetupStatusResponse {
  const WorkspaceSetupStatusResponse({
    required this.requestId,
    required this.workspaceId,
    required this.snapshot,
  });

  static const type = 'workspace_setup_status_response';

  final String requestId;
  final String workspaceId;
  final WorkspaceSetupSnapshot? snapshot;

  factory WorkspaceSetupStatusResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredMap(json, 'payload');
    final snapshotValue = payload['snapshot'];
    if (snapshotValue != null && snapshotValue is! Map) {
      throw const FormatException('snapshot must be an object or null');
    }
    final snapshot = snapshotValue == null
        ? null
        : Map<String, Object?>.from(snapshotValue as Map);
    return WorkspaceSetupStatusResponse(
      requestId: _requiredString(payload, 'requestId'),
      workspaceId: _requiredString(payload, 'workspaceId'),
      snapshot: snapshot == null
          ? null
          : WorkspaceSetupSnapshot.fromJson(snapshot),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'workspaceId': workspaceId,
      'snapshot': snapshot?.toJson(),
    },
  };
}

void _expectType(Map<String, Object?> json, String expected) {
  if (json['type'] != expected) {
    throw FormatException('Expected $expected message');
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String? _nullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string or null');
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || value.toInt() != value) {
    throw FormatException('$key must be an integer');
  }
  return value.toInt();
}

num? _nullableNum(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! num) throw FormatException('$key must be a number or null');
  return value;
}

bool? _optionalBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return value.cast<String, Object?>();
}
