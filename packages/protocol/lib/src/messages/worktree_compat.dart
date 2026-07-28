/// Paseo 0.2.0 compatibility messages for the legacy worktree CLI.
library;

final class PaseoWorktreeDescriptor {
  const PaseoWorktreeDescriptor({
    required this.worktreePath,
    required this.createdAt,
    this.branchName,
    this.head,
  });

  final String worktreePath;
  final String createdAt;
  final String? branchName;
  final String? head;

  factory PaseoWorktreeDescriptor.fromJson(Map<String, Object?> json) =>
      PaseoWorktreeDescriptor(
        worktreePath: _requiredString(json, 'worktreePath'),
        createdAt: _requiredString(json, 'createdAt'),
        branchName: _nullableString(json, 'branchName'),
        head: _nullableString(json, 'head'),
      );

  Map<String, Object?> toJson() => {
    'worktreePath': worktreePath,
    'createdAt': createdAt,
    'branchName': branchName,
    'head': head,
  };
}

final class PaseoWorktreeListRequest {
  const PaseoWorktreeListRequest({
    required this.requestId,
    this.cwd,
    this.repoRoot,
  });

  static const type = 'paseo_worktree_list_request';
  final String requestId;
  final String? cwd;
  final String? repoRoot;

  factory PaseoWorktreeListRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return PaseoWorktreeListRequest(
      requestId: _requiredString(json, 'requestId'),
      cwd: _nullableString(json, 'cwd'),
      repoRoot: _nullableString(json, 'repoRoot'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    if (cwd != null) 'cwd': cwd,
    if (repoRoot != null) 'repoRoot': repoRoot,
  };
}

final class PaseoWorktreeListResponse {
  const PaseoWorktreeListResponse({
    required this.requestId,
    required this.worktrees,
    required this.error,
  });

  static const type = 'paseo_worktree_list_response';
  final String requestId;
  final List<PaseoWorktreeDescriptor> worktrees;
  final Map<String, Object?>? error;

  factory PaseoWorktreeListResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredMap(json, 'payload');
    return PaseoWorktreeListResponse(
      requestId: _requiredString(payload, 'requestId'),
      worktrees: _mapList(
        payload,
        'worktrees',
        PaseoWorktreeDescriptor.fromJson,
      ),
      error: _nullableMap(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'worktrees': worktrees.map((entry) => entry.toJson()).toList(),
      'error': error,
      'requestId': requestId,
    },
  };
}

final class CreatePaseoWorktreeRequest {
  const CreatePaseoWorktreeRequest({
    required this.requestId,
    required this.cwd,
    this.projectId,
    this.worktreeSlug,
    this.firstAgentContext,
    this.refName,
    this.action,
    this.checkoutSource,
    this.githubPrNumber,
  });

  static const type = 'create_paseo_worktree_request';
  final String requestId;
  final String cwd;
  final String? projectId;
  final String? worktreeSlug;
  final Map<String, Object?>? firstAgentContext;
  final String? refName;
  final String? action;
  final Map<String, Object?>? checkoutSource;
  final int? githubPrNumber;

  factory CreatePaseoWorktreeRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final action = _nullableString(json, 'action');
    if (action != null && action != 'branch-off' && action != 'checkout') {
      throw FormatException('Unknown worktree action: $action');
    }
    return CreatePaseoWorktreeRequest(
      requestId: _requiredString(json, 'requestId'),
      cwd: _requiredString(json, 'cwd'),
      projectId: _nullableString(json, 'projectId'),
      worktreeSlug: _nullableString(json, 'worktreeSlug'),
      firstAgentContext: _nullableMap(json, 'firstAgentContext'),
      refName: _nullableString(json, 'refName'),
      action: action,
      checkoutSource: _nullableMap(json, 'checkoutSource'),
      githubPrNumber: _nullablePositiveInt(json, 'githubPrNumber'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'cwd': cwd,
    if (projectId != null) 'projectId': projectId,
    if (worktreeSlug != null) 'worktreeSlug': worktreeSlug,
    if (firstAgentContext != null) 'firstAgentContext': firstAgentContext,
    if (refName != null) 'refName': refName,
    if (action != null) 'action': action,
    if (checkoutSource != null) 'checkoutSource': checkoutSource,
    if (githubPrNumber != null) 'githubPrNumber': githubPrNumber,
  };
}

final class CreatePaseoWorktreeResponse {
  const CreatePaseoWorktreeResponse({
    required this.requestId,
    required this.workspace,
    required this.error,
    required this.setupTerminalId,
    this.errorCode,
  });

  static const type = 'create_paseo_worktree_response';
  final String requestId;
  final Map<String, Object?>? workspace;
  final String? error;
  final String? errorCode;
  final String? setupTerminalId;

  factory CreatePaseoWorktreeResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredMap(json, 'payload');
    return CreatePaseoWorktreeResponse(
      requestId: _requiredString(payload, 'requestId'),
      workspace: _nullableMap(payload, 'workspace'),
      error: _nullableString(payload, 'error'),
      errorCode: _nullableString(payload, 'errorCode'),
      setupTerminalId: _nullableString(payload, 'setupTerminalId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'workspace': workspace,
      'error': error,
      if (errorCode != null) 'errorCode': errorCode,
      'setupTerminalId': setupTerminalId,
      'requestId': requestId,
    },
  };
}

final class PaseoWorktreeArchiveRequest {
  const PaseoWorktreeArchiveRequest({
    required this.requestId,
    this.worktreePath,
    this.repoRoot,
    this.branchName,
    this.workspaceId,
    this.scope,
  });

  static const type = 'paseo_worktree_archive_request';
  final String requestId;
  final String? worktreePath;
  final String? repoRoot;
  final String? branchName;
  final String? workspaceId;
  final String? scope;

  factory PaseoWorktreeArchiveRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final scope = _nullableString(json, 'scope');
    if (scope != null && scope != 'workspace' && scope != 'worktree') {
      throw FormatException('Unknown worktree archive scope: $scope');
    }
    return PaseoWorktreeArchiveRequest(
      requestId: _requiredString(json, 'requestId'),
      worktreePath: _nullableString(json, 'worktreePath'),
      repoRoot: _nullableString(json, 'repoRoot'),
      branchName: _nullableString(json, 'branchName'),
      workspaceId: _nullableString(json, 'workspaceId'),
      scope: scope,
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    if (worktreePath != null) 'worktreePath': worktreePath,
    if (repoRoot != null) 'repoRoot': repoRoot,
    if (branchName != null) 'branchName': branchName,
    if (workspaceId != null) 'workspaceId': workspaceId,
    if (scope != null) 'scope': scope,
  };
}

final class PaseoWorktreeArchiveResponse {
  const PaseoWorktreeArchiveResponse({
    required this.requestId,
    required this.success,
    required this.removedAgents,
    required this.error,
  });

  static const type = 'paseo_worktree_archive_response';
  final String requestId;
  final bool success;
  final List<String> removedAgents;
  final Map<String, Object?>? error;

  factory PaseoWorktreeArchiveResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredMap(json, 'payload');
    final removed = payload['removedAgents'];
    return PaseoWorktreeArchiveResponse(
      requestId: _requiredString(payload, 'requestId'),
      success: _requiredBool(payload, 'success'),
      removedAgents: removed == null
          ? const []
          : (removed as List).map((entry) => entry as String).toList(),
      error: _nullableMap(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'success': success,
      if (removedAgents.isNotEmpty) 'removedAgents': removedAgents,
      'error': error,
      'requestId': requestId,
    },
  };
}

void _expectType(Map<String, Object?> json, String type) {
  if (json['type'] != type) {
    throw FormatException('Expected message type $type');
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a non-empty string');
  }
  return value;
}

String? _nullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

int? _nullablePositiveInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! int || value <= 0) {
    throw FormatException('$key must be a positive integer');
  }
  return value;
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

Map<String, Object?> _requiredMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('$key must be an object');
  return value.cast<String, Object?>();
}

Map<String, Object?>? _nullableMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! Map) throw FormatException('$key must be an object');
  return value.cast<String, Object?>();
}

List<T> _mapList<T>(
  Map<String, Object?> json,
  String key,
  T Function(Map<String, Object?> value) decode,
) {
  final value = json[key];
  if (value is! List) throw FormatException('$key must be a list');
  return [
    for (final entry in value)
      if (entry is Map)
        decode(entry.cast<String, Object?>())
      else
        throw FormatException('$key entries must be objects'),
  ];
}
