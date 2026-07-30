/// Paseo 0.2.0-compatible project and workspace wire messages.
library;

enum WorkspaceProjectKind {
  git,
  nonGit,
  directory;

  static WorkspaceProjectKind fromWire(Object? value) => switch (value) {
    'git' => git,
    'non_git' => nonGit,
    'directory' => directory,
    _ => throw FormatException('Unknown projectKind: $value'),
  };

  String get wireName => switch (this) {
    git => 'git',
    nonGit => 'non_git',
    directory => 'directory',
  };
}

enum WorkspaceKind {
  directory,
  localCheckout,
  checkout,
  worktree;

  static WorkspaceKind fromWire(Object? value) => switch (value) {
    'directory' => directory,
    'local_checkout' => localCheckout,
    'checkout' => checkout,
    'worktree' => worktree,
    _ => throw FormatException('Unknown workspaceKind: $value'),
  };

  String get wireName => switch (this) {
    directory => 'directory',
    localCheckout => 'local_checkout',
    checkout => 'checkout',
    worktree => 'worktree',
  };
}

enum WorkspaceStateBucket {
  needsInput,
  failed,
  running,
  attention,
  done;

  static WorkspaceStateBucket fromWire(Object? value) => switch (value) {
    'needs_input' => needsInput,
    'failed' => failed,
    'running' => running,
    'attention' => attention,
    'done' => done,
    _ => throw FormatException('Unknown workspace status: $value'),
  };

  String get wireName => switch (this) {
    needsInput => 'needs_input',
    failed => 'failed',
    running => 'running',
    attention => 'attention',
    done => 'done',
  };
}

enum WorkspaceScriptType {
  script,
  service;

  static WorkspaceScriptType fromWire(Object? value) => switch (value) {
    null || 'service' => service,
    'script' => script,
    _ => throw FormatException('Unknown workspace script type: $value'),
  };
}

enum WorkspaceScriptLifecycle {
  running,
  stopped;

  static WorkspaceScriptLifecycle fromWire(Object? value) =>
      _enumByName(values, value, 'workspace script lifecycle');
}

enum WorkspaceScriptHealth {
  healthy,
  unhealthy;

  static WorkspaceScriptHealth fromWire(Object? value) =>
      _enumByName(values, value, 'workspace script health');
}

final class WorkspaceScript {
  const WorkspaceScript({
    required this.scriptName,
    required this.type,
    required this.hostname,
    required this.port,
    required this.lifecycle,
    required this.health,
    this.localProxyUrl,
    this.publicProxyUrl,
    this.proxyUrl,
    this.exitCode,
    this.terminalId,
  });

  final String scriptName;
  final WorkspaceScriptType type;
  final String hostname;
  final int? port;
  final String? localProxyUrl;
  final String? publicProxyUrl;
  final String? proxyUrl;
  final WorkspaceScriptLifecycle lifecycle;
  final WorkspaceScriptHealth? health;
  final num? exitCode;
  final String? terminalId;

  factory WorkspaceScript.fromJson(Map<String, Object?> json) =>
      WorkspaceScript(
        scriptName: _requiredString(json, 'scriptName'),
        type: WorkspaceScriptType.fromWire(json['type']),
        hostname: _requiredString(json, 'hostname'),
        port: _nullablePositiveInt(json, 'port'),
        localProxyUrl: _nullableString(json, 'localProxyUrl'),
        publicProxyUrl: _nullableString(json, 'publicProxyUrl'),
        proxyUrl: _nullableString(json, 'proxyUrl'),
        lifecycle: WorkspaceScriptLifecycle.fromWire(json['lifecycle']),
        health: json['health'] == null
            ? null
            : WorkspaceScriptHealth.fromWire(json['health']),
        exitCode: _nullableNum(json, 'exitCode'),
        terminalId: _nullableString(json, 'terminalId'),
      );

  Map<String, Object?> toJson() => {
    'scriptName': scriptName,
    'type': type.name,
    'hostname': hostname,
    'port': port,
    if (localProxyUrl != null) 'localProxyUrl': localProxyUrl,
    if (publicProxyUrl != null) 'publicProxyUrl': publicProxyUrl,
    'proxyUrl': proxyUrl,
    'lifecycle': lifecycle.name,
    'health': health?.name,
    'exitCode': exitCode,
    'terminalId': terminalId,
  };
}

final class WorkspaceDiffStat {
  const WorkspaceDiffStat({required this.additions, required this.deletions});

  final num additions;
  final num deletions;

  factory WorkspaceDiffStat.fromJson(Map<String, Object?> json) =>
      WorkspaceDiffStat(
        additions: _requiredNum(json, 'additions'),
        deletions: _requiredNum(json, 'deletions'),
      );

  Map<String, Object?> toJson() => {
    'additions': additions,
    'deletions': deletions,
  };
}

final class WorkspaceAheadBehind {
  const WorkspaceAheadBehind({required this.ahead, required this.behind});

  final num ahead;
  final num behind;

  factory WorkspaceAheadBehind.fromJson(Map<String, Object?> json) =>
      WorkspaceAheadBehind(
        ahead: _requiredNum(json, 'ahead'),
        behind: _requiredNum(json, 'behind'),
      );

  Map<String, Object?> toJson() => {'ahead': ahead, 'behind': behind};
}

final class WorkspaceGitRuntime {
  const WorkspaceGitRuntime({
    this.currentBranch,
    this.remoteUrl,
    this.isPaseoOwnedWorktree,
    this.isDirty,
    this.aheadBehind,
    this.aheadOfOrigin,
    this.behindOfOrigin,
  });

  final String? currentBranch;
  final String? remoteUrl;
  final bool? isPaseoOwnedWorktree;
  final bool? isDirty;
  final WorkspaceAheadBehind? aheadBehind;
  final num? aheadOfOrigin;
  final num? behindOfOrigin;

  factory WorkspaceGitRuntime.fromJson(Map<String, Object?> json) =>
      WorkspaceGitRuntime(
        currentBranch: _nullableString(json, 'currentBranch'),
        remoteUrl: _nullableString(json, 'remoteUrl'),
        isPaseoOwnedWorktree: _nullableBool(json, 'isPaseoOwnedWorktree'),
        isDirty: _nullableBool(json, 'isDirty'),
        aheadBehind: json['aheadBehind'] == null
            ? null
            : WorkspaceAheadBehind.fromJson(_requiredMap(json, 'aheadBehind')),
        aheadOfOrigin: _nullableNum(json, 'aheadOfOrigin'),
        behindOfOrigin: _nullableNum(json, 'behindOfOrigin'),
      );

  Map<String, Object?> toJson() => {
    if (currentBranch != null) 'currentBranch': currentBranch,
    if (remoteUrl != null) 'remoteUrl': remoteUrl,
    if (isPaseoOwnedWorktree != null)
      'isPaseoOwnedWorktree': isPaseoOwnedWorktree,
    if (isDirty != null) 'isDirty': isDirty,
    if (aheadBehind != null) 'aheadBehind': aheadBehind!.toJson(),
    if (aheadOfOrigin != null) 'aheadOfOrigin': aheadOfOrigin,
    if (behindOfOrigin != null) 'behindOfOrigin': behindOfOrigin,
  };
}

final class WorkspaceProjectDescriptor {
  const WorkspaceProjectDescriptor({
    required this.projectId,
    required this.projectDisplayName,
    required this.projectRootPath,
    required this.projectKind,
    this.projectCustomName,
  });

  final String projectId;
  final String projectDisplayName;
  final String? projectCustomName;
  final String projectRootPath;
  final WorkspaceProjectKind projectKind;

  factory WorkspaceProjectDescriptor.fromJson(Map<String, Object?> json) =>
      WorkspaceProjectDescriptor(
        projectId: _requiredString(json, 'projectId'),
        projectDisplayName: _requiredString(json, 'projectDisplayName'),
        projectCustomName: _nullableString(json, 'projectCustomName'),
        projectRootPath: _requiredString(json, 'projectRootPath'),
        projectKind: WorkspaceProjectKind.fromWire(json['projectKind']),
      );

  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'projectDisplayName': projectDisplayName,
    if (projectCustomName != null) 'projectCustomName': projectCustomName,
    'projectRootPath': projectRootPath,
    'projectKind': projectKind.wireName,
  };
}

final class WorkspaceDescriptor {
  const WorkspaceDescriptor({
    required this.id,
    required this.projectId,
    required this.projectDisplayName,
    required this.projectRootPath,
    required this.workspaceDirectory,
    required this.projectKind,
    required this.workspaceKind,
    required this.name,
    required this.status,
    required this.activityAt,
    this.projectCustomName,
    this.title,
    this.pinnedAt,
    this.archivingAt,
    this.statusEnteredAt,
    this.diffStat,
    this.scripts = const [],
    this.gitRuntime,
    this.githubRuntime,
    this.forge,
    this.project,
  });

  final String id;
  final String projectId;
  final String projectDisplayName;
  final String? projectCustomName;
  final String projectRootPath;
  final String workspaceDirectory;
  final WorkspaceProjectKind projectKind;
  final WorkspaceKind workspaceKind;
  final String name;
  final String? title;
  final String? pinnedAt;
  final String? archivingAt;
  final WorkspaceStateBucket status;
  final String? statusEnteredAt;
  final String? activityAt;
  final WorkspaceDiffStat? diffStat;
  final List<WorkspaceScript> scripts;
  final WorkspaceGitRuntime? gitRuntime;
  final Map<String, Object?>? githubRuntime;
  final String? forge;
  final Map<String, Object?>? project;

  factory WorkspaceDescriptor.fromJson(Map<String, Object?> json) {
    final root = _requiredString(json, 'projectRootPath');
    return WorkspaceDescriptor(
      id: _requiredString(json, 'id'),
      projectId: _requiredString(json, 'projectId'),
      projectDisplayName: _requiredString(json, 'projectDisplayName'),
      projectCustomName: _nullableString(json, 'projectCustomName'),
      projectRootPath: root,
      workspaceDirectory: _nullableString(json, 'workspaceDirectory') ?? root,
      projectKind: WorkspaceProjectKind.fromWire(json['projectKind']),
      workspaceKind: WorkspaceKind.fromWire(json['workspaceKind']),
      name: _requiredString(json, 'name'),
      title: _nullableString(json, 'title'),
      pinnedAt: _nullableString(json, 'pinnedAt'),
      archivingAt: _nullableString(json, 'archivingAt'),
      status: WorkspaceStateBucket.fromWire(json['status']),
      statusEnteredAt: _nullableString(json, 'statusEnteredAt'),
      activityAt: _nullableString(json, 'activityAt'),
      diffStat: json['diffStat'] == null
          ? null
          : WorkspaceDiffStat.fromJson(_requiredMap(json, 'diffStat')),
      scripts: _mapList(json, 'scripts', WorkspaceScript.fromJson),
      gitRuntime: json['gitRuntime'] == null
          ? null
          : WorkspaceGitRuntime.fromJson(_requiredMap(json, 'gitRuntime')),
      githubRuntime: _nullableMap(json, 'githubRuntime'),
      forge: _nullableString(json, 'forge'),
      project: _nullableMap(json, 'project'),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'projectId': projectId,
    'projectDisplayName': projectDisplayName,
    if (projectCustomName != null) 'projectCustomName': projectCustomName,
    'projectRootPath': projectRootPath,
    'workspaceDirectory': workspaceDirectory,
    'projectKind': projectKind.wireName,
    'workspaceKind': workspaceKind.wireName,
    'name': name,
    'title': title,
    'pinnedAt': pinnedAt,
    'archivingAt': archivingAt,
    'status': status.wireName,
    'statusEnteredAt': statusEnteredAt,
    'activityAt': activityAt,
    if (diffStat != null) 'diffStat': diffStat!.toJson(),
    'scripts': scripts.map((script) => script.toJson()).toList(),
    'gitRuntime': gitRuntime?.toJson(),
    if (githubRuntime != null) 'githubRuntime': githubRuntime,
    if (forge != null) 'forge': forge,
    if (project != null) 'project': project,
  };
}

enum WorkspaceSortKey { statusPriority, activityAt, name, projectId }

enum SortDirection { asc, desc }

final class WorkspaceSort {
  const WorkspaceSort({required this.key, required this.direction});

  final WorkspaceSortKey key;
  final SortDirection direction;

  factory WorkspaceSort.fromJson(Map<String, Object?> json) => WorkspaceSort(
    key: switch (json['key']) {
      'status_priority' => WorkspaceSortKey.statusPriority,
      'activity_at' => WorkspaceSortKey.activityAt,
      'name' => WorkspaceSortKey.name,
      'project_id' => WorkspaceSortKey.projectId,
      final value => throw FormatException(
        'Unknown workspace sort key: $value',
      ),
    },
    direction: SortDirection.values.byName(_requiredString(json, 'direction')),
  );

  Map<String, Object?> toJson() => {
    'key': switch (key) {
      WorkspaceSortKey.statusPriority => 'status_priority',
      WorkspaceSortKey.activityAt => 'activity_at',
      WorkspaceSortKey.name => 'name',
      WorkspaceSortKey.projectId => 'project_id',
    },
    'direction': direction.name,
  };
}

final class FetchWorkspacesRequest {
  const FetchWorkspacesRequest({
    required this.requestId,
    this.query,
    this.projectId,
    this.idPrefix,
    this.sort = const [],
    this.limit,
    this.cursor,
    this.subscriptionId,
    this.hasSubscription = false,
  });

  final String requestId;
  final String? query;
  final String? projectId;
  final String? idPrefix;
  final List<WorkspaceSort> sort;
  final int? limit;
  final String? cursor;
  final String? subscriptionId;
  final bool hasSubscription;

  factory FetchWorkspacesRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'fetch_workspaces_request');
    final filter = _nullableMap(json, 'filter');
    final page = _nullableMap(json, 'page');
    final subscribe = _nullableMap(json, 'subscribe');
    final limit = page == null ? null : _requiredInt(page, 'limit');
    if (limit != null && (limit < 1 || limit > 200)) {
      throw const FormatException('page.limit must be between 1 and 200');
    }
    final cursor = page == null ? null : _nullableString(page, 'cursor');
    if (cursor != null && cursor.isEmpty) {
      throw const FormatException('page.cursor must not be empty');
    }
    return FetchWorkspacesRequest(
      requestId: _requiredString(json, 'requestId'),
      query: filter == null ? null : _nullableString(filter, 'query'),
      projectId: filter == null ? null : _nullableString(filter, 'projectId'),
      idPrefix: filter == null ? null : _nullableString(filter, 'idPrefix'),
      sort: _mapList(json, 'sort', WorkspaceSort.fromJson),
      limit: limit,
      cursor: cursor,
      subscriptionId: subscribe == null
          ? null
          : _nullableString(subscribe, 'subscriptionId'),
      hasSubscription: subscribe != null,
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'fetch_workspaces_request',
    'requestId': requestId,
    if (query != null || projectId != null || idPrefix != null)
      'filter': {
        if (query != null) 'query': query,
        if (projectId != null) 'projectId': projectId,
        if (idPrefix != null) 'idPrefix': idPrefix,
      },
    if (sort.isNotEmpty) 'sort': sort.map((entry) => entry.toJson()).toList(),
    if (limit != null || cursor != null)
      'page': {'limit': limit ?? 200, if (cursor != null) 'cursor': cursor},
    if (hasSubscription)
      'subscribe': {
        if (subscriptionId != null) 'subscriptionId': subscriptionId,
      },
  };
}

final class WorkspacePageInfo {
  const WorkspacePageInfo({
    required this.nextCursor,
    required this.prevCursor,
    required this.hasMore,
  });

  final String? nextCursor;
  final String? prevCursor;
  final bool hasMore;

  factory WorkspacePageInfo.fromJson(Map<String, Object?> json) =>
      WorkspacePageInfo(
        nextCursor: _requiredNullableString(json, 'nextCursor'),
        prevCursor: _requiredNullableString(json, 'prevCursor'),
        hasMore: _requiredBool(json, 'hasMore'),
      );

  Map<String, Object?> toJson() => {
    'nextCursor': nextCursor,
    'prevCursor': prevCursor,
    'hasMore': hasMore,
  };
}

final class FetchWorkspacesResponse {
  const FetchWorkspacesResponse({
    required this.requestId,
    required this.entries,
    required this.pageInfo,
    this.subscriptionId,
    this.emptyProjects = const [],
  });

  final String requestId;
  final String? subscriptionId;
  final List<WorkspaceDescriptor> entries;
  final List<WorkspaceProjectDescriptor> emptyProjects;
  final WorkspacePageInfo pageInfo;

  factory FetchWorkspacesResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'fetch_workspaces_response');
    final payload = _requiredMap(json, 'payload');
    return FetchWorkspacesResponse(
      requestId: _requiredString(payload, 'requestId'),
      subscriptionId: _nullableString(payload, 'subscriptionId'),
      entries: _requiredMapList(
        payload,
        'entries',
        WorkspaceDescriptor.fromJson,
      ),
      emptyProjects: _mapList(
        payload,
        'emptyProjects',
        WorkspaceProjectDescriptor.fromJson,
      ),
      pageInfo: WorkspacePageInfo.fromJson(_requiredMap(payload, 'pageInfo')),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'fetch_workspaces_response',
    'payload': {
      'requestId': requestId,
      if (subscriptionId != null) 'subscriptionId': subscriptionId,
      'entries': entries.map((entry) => entry.toJson()).toList(),
      'emptyProjects': emptyProjects
          .map((project) => project.toJson())
          .toList(),
      'pageInfo': pageInfo.toJson(),
    },
  };
}

sealed class WorkspaceCreateSource {
  const WorkspaceCreateSource();

  factory WorkspaceCreateSource.fromJson(Map<String, Object?> json) =>
      switch (json['kind']) {
        'directory' => DirectoryWorkspaceCreateSource.fromJson(json),
        'worktree' => WorktreeWorkspaceCreateSource.fromJson(json),
        final value => throw FormatException(
          'Unknown workspace create source: $value',
        ),
      };

  Map<String, Object?> toJson();
}

final class DirectoryWorkspaceCreateSource extends WorkspaceCreateSource {
  const DirectoryWorkspaceCreateSource({required this.path, this.projectId});

  final String path;
  final String? projectId;

  factory DirectoryWorkspaceCreateSource.fromJson(Map<String, Object?> json) =>
      DirectoryWorkspaceCreateSource(
        path: _requiredString(json, 'path'),
        projectId: _nullableString(json, 'projectId'),
      );

  @override
  Map<String, Object?> toJson() => {
    'kind': 'directory',
    'path': path,
    if (projectId != null) 'projectId': projectId,
  };
}

enum WorktreeCreateAction { branchOff, checkout }

final class WorktreeWorkspaceCreateSource extends WorkspaceCreateSource {
  const WorktreeWorkspaceCreateSource({
    this.cwd,
    this.projectId,
    this.action,
    this.refName,
    this.baseBranch,
    this.branchName,
    this.checkoutSource,
    this.githubPrNumber,
    this.worktreeSlug,
  });

  final String? cwd;
  final String? projectId;
  final WorktreeCreateAction? action;
  final String? refName;
  final String? baseBranch;
  final String? branchName;
  final Map<String, Object?>? checkoutSource;
  final int? githubPrNumber;
  final String? worktreeSlug;

  factory WorktreeWorkspaceCreateSource.fromJson(Map<String, Object?> json) {
    final action = switch (json['action']) {
      null => null,
      'branch-off' => WorktreeCreateAction.branchOff,
      'checkout' => WorktreeCreateAction.checkout,
      final value => throw FormatException(
        'Unknown worktree create action: $value',
      ),
    };
    final refName = _nullableString(json, 'refName');
    final branchName = _nullableString(json, 'branchName');
    if (refName != null && refName.isEmpty) {
      throw const FormatException('refName must not be empty');
    }
    if (branchName != null && branchName.isEmpty) {
      throw const FormatException('branchName must not be empty');
    }
    return WorktreeWorkspaceCreateSource(
      cwd: _nullableString(json, 'cwd'),
      projectId: _nullableString(json, 'projectId'),
      action: action,
      refName: refName,
      baseBranch: _nullableString(json, 'baseBranch'),
      branchName: branchName,
      checkoutSource: _nullableMap(json, 'checkoutSource'),
      githubPrNumber: _nullablePositiveInt(json, 'githubPrNumber'),
      worktreeSlug: _nullableString(json, 'worktreeSlug'),
    );
  }

  @override
  Map<String, Object?> toJson() => {
    'kind': 'worktree',
    if (cwd != null) 'cwd': cwd,
    if (projectId != null) 'projectId': projectId,
    if (action != null)
      'action': action == WorktreeCreateAction.branchOff
          ? 'branch-off'
          : 'checkout',
    if (refName != null) 'refName': refName,
    if (baseBranch != null) 'baseBranch': baseBranch,
    if (branchName != null) 'branchName': branchName,
    if (checkoutSource != null) 'checkoutSource': checkoutSource,
    if (githubPrNumber != null) 'githubPrNumber': githubPrNumber,
    if (worktreeSlug != null) 'worktreeSlug': worktreeSlug,
  };
}

final class WorkspaceCreateRequest {
  const WorkspaceCreateRequest({
    required this.requestId,
    required this.source,
    this.title,
    this.firstAgentContext,
  });

  final String requestId;
  final String? title;
  final Map<String, Object?>? firstAgentContext;
  final WorkspaceCreateSource source;

  factory WorkspaceCreateRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'workspace.create.request');
    return WorkspaceCreateRequest(
      requestId: _requiredString(json, 'requestId'),
      title: _nullableString(json, 'title'),
      firstAgentContext: _nullableMap(json, 'firstAgentContext'),
      source: WorkspaceCreateSource.fromJson(_requiredMap(json, 'source')),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'workspace.create.request',
    'requestId': requestId,
    if (title != null) 'title': title,
    if (firstAgentContext != null) 'firstAgentContext': firstAgentContext,
    'source': source.toJson(),
  };
}

final class WorkspaceCreateResponse {
  const WorkspaceCreateResponse({
    required this.requestId,
    required this.workspace,
    required this.setupTerminalId,
    required this.error,
    this.errorCode,
  });

  final String requestId;
  final WorkspaceDescriptor? workspace;
  final String? setupTerminalId;
  final String? error;
  final String? errorCode;

  factory WorkspaceCreateResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'workspace.create.response');
    final payload = _requiredMap(json, 'payload');
    return WorkspaceCreateResponse(
      requestId: _requiredString(payload, 'requestId'),
      workspace: payload['workspace'] == null
          ? null
          : WorkspaceDescriptor.fromJson(_requiredMap(payload, 'workspace')),
      setupTerminalId: _nullableString(payload, 'setupTerminalId'),
      error: _nullableString(payload, 'error'),
      errorCode: _nullableString(payload, 'errorCode'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'workspace.create.response',
    'payload': {
      'workspace': workspace?.toJson(),
      'setupTerminalId': setupTerminalId,
      'error': error,
      if (errorCode != null) 'errorCode': errorCode,
      'requestId': requestId,
    },
  };
}

final class ArchiveWorkspaceRequest {
  const ArchiveWorkspaceRequest({
    required this.workspaceId,
    required this.requestId,
  });

  final String workspaceId;
  final String requestId;

  factory ArchiveWorkspaceRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'archive_workspace_request');
    return ArchiveWorkspaceRequest(
      workspaceId: _requiredString(json, 'workspaceId'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'archive_workspace_request',
    'workspaceId': workspaceId,
    'requestId': requestId,
  };
}

final class ArchiveWorkspaceResponse {
  const ArchiveWorkspaceResponse({
    required this.requestId,
    required this.workspaceId,
    required this.archivedAt,
    required this.error,
  });

  final String requestId;
  final String workspaceId;
  final String? archivedAt;
  final String? error;

  factory ArchiveWorkspaceResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'archive_workspace_response');
    final payload = _requiredMap(json, 'payload');
    return ArchiveWorkspaceResponse(
      requestId: _requiredString(payload, 'requestId'),
      workspaceId: _requiredString(payload, 'workspaceId'),
      archivedAt: _requiredNullableString(payload, 'archivedAt'),
      error: _requiredNullableString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'archive_workspace_response',
    'payload': {
      'requestId': requestId,
      'workspaceId': workspaceId,
      'archivedAt': archivedAt,
      'error': error,
    },
  };
}

sealed class WorkspaceUpdate {
  const WorkspaceUpdate();

  factory WorkspaceUpdate.fromJson(Map<String, Object?> json) {
    _expectType(json, 'workspace_update');
    final payload = _requiredMap(json, 'payload');
    return switch (payload['kind']) {
      'upsert' => WorkspaceUpsertUpdate(
        WorkspaceDescriptor.fromJson(_requiredMap(payload, 'workspace')),
      ),
      'remove' => WorkspaceRemoveUpdate(
        id: _requiredString(payload, 'id'),
        emptyProject: payload['emptyProject'] == null
            ? null
            : WorkspaceProjectDescriptor.fromJson(
                _requiredMap(payload, 'emptyProject'),
              ),
        removedProjectId: _nullableString(payload, 'removedProjectId'),
      ),
      final value => throw FormatException('Unknown workspace update: $value'),
    };
  }

  Map<String, Object?> toJson();
}

final class WorkspaceUpsertUpdate extends WorkspaceUpdate {
  const WorkspaceUpsertUpdate(this.workspace);

  final WorkspaceDescriptor workspace;

  @override
  Map<String, Object?> toJson() => {
    'type': 'workspace_update',
    'payload': {'kind': 'upsert', 'workspace': workspace.toJson()},
  };
}

final class WorkspaceRemoveUpdate extends WorkspaceUpdate {
  const WorkspaceRemoveUpdate({
    required this.id,
    this.emptyProject,
    this.removedProjectId,
  });

  final String id;
  final WorkspaceProjectDescriptor? emptyProject;
  final String? removedProjectId;

  @override
  Map<String, Object?> toJson() => {
    'type': 'workspace_update',
    'payload': {
      'kind': 'remove',
      'id': id,
      if (emptyProject != null) 'emptyProject': emptyProject!.toJson(),
      if (removedProjectId != null) 'removedProjectId': removedProjectId,
    },
  };
}

sealed class ProjectUpdate {
  const ProjectUpdate();

  factory ProjectUpdate.fromJson(Map<String, Object?> json) {
    _expectType(json, 'project.update');
    final payload = _requiredMap(json, 'payload');
    return switch (payload['kind']) {
      'upsert' => ProjectUpsertUpdate(
        WorkspaceProjectDescriptor.fromJson(_requiredMap(payload, 'project')),
      ),
      'remove' => ProjectRemoveUpdate(_requiredString(payload, 'projectId')),
      final value => throw FormatException('Unknown project update: $value'),
    };
  }

  Map<String, Object?> toJson();
}

final class ProjectUpsertUpdate extends ProjectUpdate {
  const ProjectUpsertUpdate(this.project);

  final WorkspaceProjectDescriptor project;

  @override
  Map<String, Object?> toJson() => {
    'type': 'project.update',
    'payload': {'kind': 'upsert', 'project': project.toJson()},
  };
}

final class ProjectRemoveUpdate extends ProjectUpdate {
  const ProjectRemoveUpdate(this.projectId);

  final String projectId;

  @override
  Map<String, Object?> toJson() => {
    'type': 'project.update',
    'payload': {'kind': 'remove', 'projectId': projectId},
  };
}

final class ProjectAddRequest {
  const ProjectAddRequest({required this.cwd, required this.requestId});

  static const type = 'project.add.request';

  final String cwd;
  final String requestId;

  factory ProjectAddRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return ProjectAddRequest(
      cwd: _requiredString(json, 'cwd'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'cwd': cwd,
    'requestId': requestId,
  };
}

final class ProjectAddResponse {
  const ProjectAddResponse({
    required this.requestId,
    required this.project,
    required this.error,
    this.errorCode,
  });

  static const type = 'project.add.response';

  final String requestId;
  final WorkspaceProjectDescriptor? project;
  final String? error;
  final String? errorCode;

  factory ProjectAddResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final payload = _requiredMap(json, 'payload');
    return ProjectAddResponse(
      requestId: _requiredString(payload, 'requestId'),
      project: payload['project'] == null
          ? null
          : WorkspaceProjectDescriptor.fromJson(
              _requiredMap(payload, 'project'),
            ),
      error: _nullableString(payload, 'error'),
      errorCode: _nullableString(payload, 'errorCode'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'project': project?.toJson(),
      'error': error,
      if (errorCode != null) 'errorCode': errorCode,
    },
  };
}

final class ProjectRenameRequest {
  const ProjectRenameRequest({
    required this.projectId,
    required this.customName,
    required this.requestId,
  });

  final String projectId;
  final String? customName;
  final String requestId;

  factory ProjectRenameRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'project.rename.request');
    return ProjectRenameRequest(
      projectId: _requiredString(json, 'projectId'),
      customName: _nullableString(json, 'customName'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'project.rename.request',
    'projectId': projectId,
    'customName': customName,
    'requestId': requestId,
  };
}

final class ProjectRenameResponse {
  const ProjectRenameResponse({
    required this.requestId,
    required this.projectId,
    required this.accepted,
    required this.customName,
    required this.error,
  });

  final String requestId;
  final String projectId;
  final bool accepted;
  final String? customName;
  final String? error;

  factory ProjectRenameResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'project.rename.response');
    final payload = _requiredMap(json, 'payload');
    return ProjectRenameResponse(
      requestId: _requiredString(payload, 'requestId'),
      projectId: _requiredString(payload, 'projectId'),
      accepted: _requiredBool(payload, 'accepted'),
      customName: _nullableString(payload, 'customName'),
      error: _nullableString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'project.rename.response',
    'payload': {
      'requestId': requestId,
      'projectId': projectId,
      'accepted': accepted,
      'customName': customName,
      'error': error,
    },
  };
}

final class ProjectRemoveRequest {
  const ProjectRemoveRequest({
    required this.projectId,
    required this.requestId,
  });

  final String projectId;
  final String requestId;

  factory ProjectRemoveRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'project.remove.request');
    return ProjectRemoveRequest(
      projectId: _requiredString(json, 'projectId'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'project.remove.request',
    'projectId': projectId,
    'requestId': requestId,
  };
}

final class ProjectRemoveResponse {
  const ProjectRemoveResponse({
    required this.requestId,
    required this.projectId,
    required this.accepted,
    required this.removedWorkspaceIds,
    required this.error,
  });

  final String requestId;
  final String projectId;
  final bool accepted;
  final List<String> removedWorkspaceIds;
  final String? error;

  factory ProjectRemoveResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'project.remove.response');
    final payload = _requiredMap(json, 'payload');
    final removed = payload['removedWorkspaceIds'];
    if (removed != null && removed is! List) {
      throw const FormatException('removedWorkspaceIds must be an array');
    }
    return ProjectRemoveResponse(
      requestId: _requiredString(payload, 'requestId'),
      projectId: _requiredString(payload, 'projectId'),
      accepted: _requiredBool(payload, 'accepted'),
      removedWorkspaceIds: List.unmodifiable(
        (removed as List? ?? const []).map((value) {
          if (value is! String) {
            throw const FormatException(
              'removedWorkspaceIds entries must be strings',
            );
          }
          return value;
        }),
      ),
      error: _nullableString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'project.remove.response',
    'payload': {
      'requestId': requestId,
      'projectId': projectId,
      'accepted': accepted,
      'removedWorkspaceIds': removedWorkspaceIds,
      'error': error,
    },
  };
}

final class WorkspaceTitleSetRequest {
  const WorkspaceTitleSetRequest({
    required this.workspaceId,
    required this.title,
    required this.requestId,
  });

  final String workspaceId;
  final String? title;
  final String requestId;

  factory WorkspaceTitleSetRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'workspace.title.set.request');
    return WorkspaceTitleSetRequest(
      workspaceId: _requiredString(json, 'workspaceId'),
      title: _nullableString(json, 'title'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'workspace.title.set.request',
    'workspaceId': workspaceId,
    'title': title,
    'requestId': requestId,
  };
}

final class WorkspaceTitleSetResponse {
  const WorkspaceTitleSetResponse({
    required this.requestId,
    required this.workspaceId,
    required this.accepted,
    required this.title,
    required this.error,
  });

  final String requestId;
  final String workspaceId;
  final bool accepted;
  final String? title;
  final String? error;

  factory WorkspaceTitleSetResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'workspace.title.set.response');
    final payload = _requiredMap(json, 'payload');
    return WorkspaceTitleSetResponse(
      requestId: _requiredString(payload, 'requestId'),
      workspaceId: _requiredString(payload, 'workspaceId'),
      accepted: _requiredBool(payload, 'accepted'),
      title: _nullableString(payload, 'title'),
      error: _nullableString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'workspace.title.set.response',
    'payload': {
      'requestId': requestId,
      'workspaceId': workspaceId,
      'accepted': accepted,
      'title': title,
      'error': error,
    },
  };
}

final class WorkspacePinSetRequest {
  const WorkspacePinSetRequest({
    required this.workspaceId,
    required this.pinned,
    required this.requestId,
  });

  final String workspaceId;
  final bool pinned;
  final String requestId;

  factory WorkspacePinSetRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'workspace.pin.set.request');
    return WorkspacePinSetRequest(
      workspaceId: _requiredString(json, 'workspaceId'),
      pinned: _requiredBool(json, 'pinned'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'workspace.pin.set.request',
    'workspaceId': workspaceId,
    'pinned': pinned,
    'requestId': requestId,
  };
}

final class WorkspacePinSetResponse {
  const WorkspacePinSetResponse({
    required this.requestId,
    required this.workspaceId,
    required this.accepted,
    required this.pinnedAt,
    required this.error,
  });

  final String requestId;
  final String workspaceId;
  final bool accepted;
  final String? pinnedAt;
  final String? error;

  factory WorkspacePinSetResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'workspace.pin.set.response');
    final payload = _requiredMap(json, 'payload');
    return WorkspacePinSetResponse(
      requestId: _requiredString(payload, 'requestId'),
      workspaceId: _requiredString(payload, 'workspaceId'),
      accepted: _requiredBool(payload, 'accepted'),
      pinnedAt: _nullableString(payload, 'pinnedAt'),
      error: _nullableString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'workspace.pin.set.response',
    'payload': {
      'requestId': requestId,
      'workspaceId': workspaceId,
      'accepted': accepted,
      'pinnedAt': pinnedAt,
      'error': error,
    },
  };
}

final class WorkspaceRecoveryInspectRequest {
  const WorkspaceRecoveryInspectRequest({
    required this.workspaceId,
    required this.requestId,
  });

  final String workspaceId;
  final String requestId;

  factory WorkspaceRecoveryInspectRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'workspace.recovery.inspect.request');
    return WorkspaceRecoveryInspectRequest(
      workspaceId: _requiredString(json, 'workspaceId'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'workspace.recovery.inspect.request',
    'workspaceId': workspaceId,
    'requestId': requestId,
  };
}

sealed class WorkspaceRecoveryState {
  const WorkspaceRecoveryState();

  factory WorkspaceRecoveryState.fromJson(Map<String, Object?> json) =>
      switch (json['kind']) {
        'recoverable' => RecoverableWorkspaceState.fromJson(json),
        'unavailable' => UnavailableWorkspaceState.fromJson(json),
        final value => throw FormatException(
          'Unknown workspace recovery state: $value',
        ),
      };

  String get workspaceId;
  Map<String, Object?> toJson();
}

final class RecoverableWorkspaceState extends WorkspaceRecoveryState {
  const RecoverableWorkspaceState({
    required this.workspaceId,
    required this.workspaceName,
    required this.action,
    required this.branch,
  });

  @override
  final String workspaceId;
  final String workspaceName;
  final String action;
  final String? branch;

  factory RecoverableWorkspaceState.fromJson(Map<String, Object?> json) =>
      RecoverableWorkspaceState(
        workspaceId: _requiredString(json, 'workspaceId'),
        workspaceName: _requiredString(json, 'workspaceName'),
        action: _requiredString(json, 'action'),
        branch: _nullableString(json, 'branch'),
      );

  @override
  Map<String, Object?> toJson() => {
    'kind': 'recoverable',
    'workspaceId': workspaceId,
    'workspaceName': workspaceName,
    'action': action,
    'branch': branch,
  };
}

final class UnavailableWorkspaceState extends WorkspaceRecoveryState {
  const UnavailableWorkspaceState({
    required this.workspaceId,
    required this.reason,
    required this.message,
  });

  @override
  final String workspaceId;
  final String reason;
  final String message;

  factory UnavailableWorkspaceState.fromJson(Map<String, Object?> json) =>
      UnavailableWorkspaceState(
        workspaceId: _requiredString(json, 'workspaceId'),
        reason: _requiredString(json, 'reason'),
        message: _requiredString(json, 'message'),
      );

  @override
  Map<String, Object?> toJson() => {
    'kind': 'unavailable',
    'workspaceId': workspaceId,
    'reason': reason,
    'message': message,
  };
}

final class WorkspaceRecoveryInspectResponse {
  const WorkspaceRecoveryInspectResponse({
    required this.requestId,
    required this.state,
  });

  final String requestId;
  final WorkspaceRecoveryState state;

  factory WorkspaceRecoveryInspectResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'workspace.recovery.inspect.response');
    final payload = _requiredMap(json, 'payload');
    return WorkspaceRecoveryInspectResponse(
      requestId: _requiredString(payload, 'requestId'),
      state: WorkspaceRecoveryState.fromJson(_requiredMap(payload, 'state')),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'workspace.recovery.inspect.response',
    'payload': {'requestId': requestId, 'state': state.toJson()},
  };
}

final class WorkspaceRecoveryRestoreRequest {
  const WorkspaceRecoveryRestoreRequest({
    required this.workspaceId,
    required this.requestId,
  });

  final String workspaceId;
  final String requestId;

  factory WorkspaceRecoveryRestoreRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, 'workspace.recovery.restore.request');
    return WorkspaceRecoveryRestoreRequest(
      workspaceId: _requiredString(json, 'workspaceId'),
      requestId: _requiredString(json, 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'workspace.recovery.restore.request',
    'workspaceId': workspaceId,
    'requestId': requestId,
  };
}

final class WorkspaceRecoveryRestoreResponse {
  const WorkspaceRecoveryRestoreResponse({
    required this.requestId,
    required this.workspaceId,
    required this.accepted,
    required this.error,
  });

  final String requestId;
  final String workspaceId;
  final bool accepted;
  final String? error;

  factory WorkspaceRecoveryRestoreResponse.fromJson(Map<String, Object?> json) {
    _expectType(json, 'workspace.recovery.restore.response');
    final payload = _requiredMap(json, 'payload');
    return WorkspaceRecoveryRestoreResponse(
      requestId: _requiredString(payload, 'requestId'),
      workspaceId: _requiredString(payload, 'workspaceId'),
      accepted: _requiredBool(payload, 'accepted'),
      error: _nullableString(payload, 'error'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'workspace.recovery.restore.response',
    'payload': {
      'requestId': requestId,
      'workspaceId': workspaceId,
      'accepted': accepted,
      'error': error,
    },
  };
}

T _enumByName<T extends Enum>(List<T> values, Object? value, String label) {
  if (value is String) {
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
  }
  throw FormatException('Unknown $label: $value');
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

String? _nullableString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string or null');
  return value;
}

String? _requiredNullableString(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) {
    throw FormatException('$key is required');
  }
  return _nullableString(json, key);
}

num _requiredNum(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num) throw FormatException('$key must be a number');
  return value;
}

num? _nullableNum(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! num) throw FormatException('$key must be a number or null');
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || value.toInt() != value) {
    throw FormatException('$key must be an integer');
  }
  return value.toInt();
}

int? _nullablePositiveInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! num || value.toInt() != value || value <= 0) {
    throw FormatException('$key must be a positive integer or null');
  }
  return value.toInt();
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('$key must be a boolean');
  return value;
}

bool? _nullableBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! bool) throw FormatException('$key must be a boolean or null');
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
  if (value is! Map) throw FormatException('$key must be an object or null');
  return Map.unmodifiable(value.cast<String, Object?>());
}

List<T> _mapList<T>(
  Map<String, Object?> json,
  String key,
  T Function(Map<String, Object?>) decode,
) {
  final value = json[key];
  if (value == null) return const [];
  if (value is! List) throw FormatException('$key must be an array');
  return List.unmodifiable(
    value.map((entry) {
      if (entry is! Map) throw FormatException('$key entries must be objects');
      return decode(entry.cast<String, Object?>());
    }),
  );
}

List<T> _requiredMapList<T>(
  Map<String, Object?> json,
  String key,
  T Function(Map<String, Object?>) decode,
) {
  final value = json[key];
  if (value is! List) throw FormatException('$key must be an array');
  return List.unmodifiable(
    value.map((entry) {
      if (entry is! Map) throw FormatException('$key entries must be objects');
      return decode(entry.cast<String, Object?>());
    }),
  );
}
