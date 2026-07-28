import 'workspace_file_open.dart';

final class WorkspaceDraftTabSetup {
  const WorkspaceDraftTabSetup({
    required this.provider,
    required this.cwd,
    required this.modeId,
    required this.model,
    required this.thinkingOptionId,
    required this.featureValues,
  });

  final String provider;
  final String cwd;
  final String? modeId;
  final String? model;
  final String? thinkingOptionId;
  final Map<String, Object?> featureValues;

  Map<String, Object?> toJson() => {
    'provider': provider,
    'cwd': cwd,
    'modeId': modeId,
    'model': model,
    'thinkingOptionId': thinkingOptionId,
    'featureValues': featureValues,
  };

  @override
  bool operator ==(Object other) =>
      other is WorkspaceDraftTabSetup &&
      other.provider == provider &&
      other.cwd == cwd &&
      other.modeId == modeId &&
      other.model == model &&
      other.thinkingOptionId == thinkingOptionId &&
      _mapsShallowEqual(other.featureValues, featureValues);

  @override
  int get hashCode => Object.hash(
    provider,
    cwd,
    modeId,
    model,
    thinkingOptionId,
    _featureValuesHash(featureValues),
  );
}

sealed class WorkspaceTabTarget {
  const WorkspaceTabTarget();

  String get kind;

  Map<String, Object?> toJson();

  static WorkspaceTabTarget? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = value.cast<Object?, Object?>();
    final kind = json['kind'];
    if (kind is! String) return null;
    return switch (kind) {
      'draft' => WorkspaceDraftTabTarget(
        draftId: _stringOrEmpty(json['draftId']),
        setup: normalizeWorkspaceDraftTabSetup(json['setup']),
      ),
      'agent' => WorkspaceAgentTabTarget(
        agentId: _stringOrEmpty(json['agentId']),
      ),
      'provider_subagent' => WorkspaceProviderSubagentTabTarget(
        parentAgentId: _stringOrEmpty(json['parentAgentId']),
        subagentId: _stringOrEmpty(json['subagentId']),
      ),
      'terminal' => WorkspaceTerminalTabTarget(
        terminalId: _stringOrEmpty(json['terminalId']),
      ),
      'browser' => WorkspaceBrowserTabTarget(
        browserId: _stringOrEmpty(json['browserId']),
      ),
      'file' => WorkspaceFileTabTarget(
        path: _stringOrEmpty(json['path']),
        lineStart: _finiteIntegerOrNull(json['lineStart']),
        lineEnd: _finiteIntegerOrNull(json['lineEnd']),
      ),
      'working_diff' => WorkspaceWorkingDiffTabTarget(
        focusPath: json['focusPath'] is String
            ? json['focusPath'] as String
            : null,
        focusRequestId: _finiteIntegerOrNull(json['focusRequestId']),
      ),
      'setup' => WorkspaceSetupTabTarget(
        workspaceId: _stringOrEmpty(json['workspaceId']),
      ),
      'commit_diff' => WorkspaceCommitDiffTabTarget(
        sha: _stringOrEmpty(json['sha']),
      ),
      _ => null,
    };
  }
}

final class WorkspaceDraftTabTarget extends WorkspaceTabTarget {
  const WorkspaceDraftTabTarget({required this.draftId, this.setup});

  final String draftId;
  final WorkspaceDraftTabSetup? setup;

  @override
  String get kind => 'draft';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'draftId': draftId,
    if (setup != null) 'setup': setup!.toJson(),
  };
}

final class WorkspaceAgentTabTarget extends WorkspaceTabTarget {
  const WorkspaceAgentTabTarget({required this.agentId});

  final String agentId;

  @override
  String get kind => 'agent';

  @override
  Map<String, Object?> toJson() => {'kind': kind, 'agentId': agentId};
}

final class WorkspaceProviderSubagentTabTarget extends WorkspaceTabTarget {
  const WorkspaceProviderSubagentTabTarget({
    required this.parentAgentId,
    required this.subagentId,
  });

  final String parentAgentId;
  final String subagentId;

  @override
  String get kind => 'provider_subagent';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'parentAgentId': parentAgentId,
    'subagentId': subagentId,
  };
}

final class WorkspaceTerminalTabTarget extends WorkspaceTabTarget {
  const WorkspaceTerminalTabTarget({required this.terminalId});

  final String terminalId;

  @override
  String get kind => 'terminal';

  @override
  Map<String, Object?> toJson() => {'kind': kind, 'terminalId': terminalId};
}

final class WorkspaceBrowserTabTarget extends WorkspaceTabTarget {
  const WorkspaceBrowserTabTarget({required this.browserId});

  final String browserId;

  @override
  String get kind => 'browser';

  @override
  Map<String, Object?> toJson() => {'kind': kind, 'browserId': browserId};
}

final class WorkspaceFileTabTarget extends WorkspaceTabTarget {
  const WorkspaceFileTabTarget({
    required this.path,
    this.lineStart,
    this.lineEnd,
  });

  final String path;
  final int? lineStart;
  final int? lineEnd;

  @override
  String get kind => 'file';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    'path': path,
    if (lineStart != null) 'lineStart': lineStart,
    if (lineEnd != null) 'lineEnd': lineEnd,
  };
}

final class WorkspaceWorkingDiffTabTarget extends WorkspaceTabTarget {
  const WorkspaceWorkingDiffTabTarget({this.focusPath, this.focusRequestId});

  final String? focusPath;
  final int? focusRequestId;

  @override
  String get kind => 'working_diff';

  @override
  Map<String, Object?> toJson() => {
    'kind': kind,
    if (focusPath != null) 'focusPath': focusPath,
    if (focusRequestId != null) 'focusRequestId': focusRequestId,
  };
}

final class WorkspaceSetupTabTarget extends WorkspaceTabTarget {
  const WorkspaceSetupTabTarget({required this.workspaceId});

  final String workspaceId;

  @override
  String get kind => 'setup';

  @override
  Map<String, Object?> toJson() => {'kind': kind, 'workspaceId': workspaceId};
}

final class WorkspaceCommitDiffTabTarget extends WorkspaceTabTarget {
  const WorkspaceCommitDiffTabTarget({required this.sha});

  final String sha;

  @override
  String get kind => 'commit_diff';

  @override
  Map<String, Object?> toJson() => {'kind': kind, 'sha': sha};
}

final class WorkspaceTab {
  const WorkspaceTab({
    required this.tabId,
    required this.target,
    required this.createdAt,
  });

  final String tabId;
  final WorkspaceTabTarget target;
  final int createdAt;

  Map<String, Object?> toJson() => {
    'tabId': tabId,
    'target': target.toJson(),
    'createdAt': createdAt,
  };

  static WorkspaceTab? fromJson(Object? value) {
    if (value is! Map) return null;
    final json = value.cast<Object?, Object?>();
    final tabId = _trimNonEmpty(json['tabId']);
    final target = WorkspaceTabTarget.fromJson(json['target']);
    final createdAt = json['createdAt'];
    if (tabId == null || target == null || createdAt is! num) return null;
    final normalizedTarget = normalizeWorkspaceTabTarget(target);
    if (normalizedTarget == null) return null;
    return WorkspaceTab(
      tabId: tabId,
      target: normalizedTarget,
      createdAt: createdAt.toInt(),
    );
  }
}

String? buildWorkspaceTabPersistenceKey({
  required String serverId,
  required String workspaceId,
}) {
  final normalizedServerId = serverId.trim();
  final normalizedWorkspaceId = workspaceId.trim();
  if (normalizedServerId.isEmpty || normalizedWorkspaceId.isEmpty) return null;
  return '$normalizedServerId:$normalizedWorkspaceId';
}

WorkspaceDraftTabSetup? normalizeWorkspaceDraftTabSetup(Object? value) {
  if (value is! Map) return null;
  final record = value.cast<Object?, Object?>();
  final provider = _trimNonEmpty(record['provider']);
  final cwd = _trimNonEmpty(record['cwd']);
  if (provider == null || cwd == null) return null;
  final rawFeatures = record['featureValues'];
  return WorkspaceDraftTabSetup(
    provider: provider,
    cwd: cwd,
    modeId: _trimOptionalString(record['modeId']),
    model: _trimOptionalString(record['model']),
    thinkingOptionId: _trimOptionalString(record['thinkingOptionId']),
    featureValues: _stringObjectMap(rawFeatures) ?? const {},
  );
}

WorkspaceTabTarget? normalizeWorkspaceTabTarget(WorkspaceTabTarget? value) {
  return switch (value) {
    null => null,
    WorkspaceDraftTabTarget() => switch (_trimNonEmpty(value.draftId)) {
      final draftId? => WorkspaceDraftTabTarget(
        draftId: draftId,
        setup: value.setup == null
            ? null
            : normalizeWorkspaceDraftTabSetup(value.setup!.toJson()),
      ),
      null => null,
    },
    WorkspaceAgentTabTarget() => switch (_trimNonEmpty(value.agentId)) {
      final agentId? => WorkspaceAgentTabTarget(agentId: agentId),
      null => null,
    },
    WorkspaceProviderSubagentTabTarget() => switch ((
      _trimNonEmpty(value.parentAgentId),
      _trimNonEmpty(value.subagentId),
    )) {
      (final parentAgentId?, final subagentId?) =>
        WorkspaceProviderSubagentTabTarget(
          parentAgentId: parentAgentId,
          subagentId: subagentId,
        ),
      _ => null,
    },
    WorkspaceTerminalTabTarget() => switch (_trimNonEmpty(value.terminalId)) {
      final terminalId? => WorkspaceTerminalTabTarget(terminalId: terminalId),
      null => null,
    },
    WorkspaceBrowserTabTarget() => switch (_trimNonEmpty(value.browserId)) {
      final browserId? => WorkspaceBrowserTabTarget(browserId: browserId),
      null => null,
    },
    WorkspaceFileTabTarget() => switch (normalizeWorkspaceFileLocation(
      WorkspaceFileLocation(
        path: value.path,
        lineStart: value.lineStart,
        lineEnd: value.lineEnd,
      ),
    )) {
      final location? => WorkspaceFileTabTarget(
        path: location.path,
        lineStart: location.lineStart,
        lineEnd: location.lineEnd,
      ),
      null => null,
    },
    WorkspaceWorkingDiffTabTarget() => WorkspaceWorkingDiffTabTarget(
      focusPath: _trimNonEmpty(value.focusPath)?.replaceAll(r'\', '/'),
      focusRequestId: _normalizePositiveInteger(value.focusRequestId),
    ),
    WorkspaceSetupTabTarget() => switch (_trimNonEmpty(value.workspaceId)) {
      final workspaceId? => WorkspaceSetupTabTarget(workspaceId: workspaceId),
      null => null,
    },
    WorkspaceCommitDiffTabTarget() => switch (_trimNonEmpty(value.sha)) {
      final sha? => WorkspaceCommitDiffTabTarget(sha: sha),
      null => null,
    },
  };
}

bool workspaceTabTargetsEqual(
  WorkspaceTabTarget left,
  WorkspaceTabTarget right,
) {
  if (left.kind != right.kind) return false;
  return switch ((left, right)) {
    (WorkspaceDraftTabTarget l, WorkspaceDraftTabTarget r) =>
      l.draftId == r.draftId && l.setup == r.setup,
    (WorkspaceAgentTabTarget l, WorkspaceAgentTabTarget r) =>
      l.agentId == r.agentId,
    (
      WorkspaceProviderSubagentTabTarget l,
      WorkspaceProviderSubagentTabTarget r,
    ) =>
      l.parentAgentId == r.parentAgentId && l.subagentId == r.subagentId,
    (WorkspaceTerminalTabTarget l, WorkspaceTerminalTabTarget r) =>
      l.terminalId == r.terminalId,
    (WorkspaceBrowserTabTarget l, WorkspaceBrowserTabTarget r) =>
      l.browserId == r.browserId,
    (WorkspaceFileTabTarget l, WorkspaceFileTabTarget r) =>
      normalizeWorkspaceFileLocation(
            WorkspaceFileLocation(
              path: l.path,
              lineStart: l.lineStart,
              lineEnd: l.lineEnd,
            ),
          ) ==
          normalizeWorkspaceFileLocation(
            WorkspaceFileLocation(
              path: r.path,
              lineStart: r.lineStart,
              lineEnd: r.lineEnd,
            ),
          ),
    (WorkspaceWorkingDiffTabTarget l, WorkspaceWorkingDiffTabTarget r) =>
      l.focusPath == r.focusPath && l.focusRequestId == r.focusRequestId,
    (WorkspaceSetupTabTarget l, WorkspaceSetupTabTarget r) =>
      l.workspaceId == r.workspaceId,
    (WorkspaceCommitDiffTabTarget l, WorkspaceCommitDiffTabTarget r) =>
      l.sha == r.sha,
    _ => false,
  };
}

String buildDeterministicWorkspaceTabId(WorkspaceTabTarget target) =>
    switch (target) {
      WorkspaceDraftTabTarget() => target.draftId,
      WorkspaceAgentTabTarget() => 'agent_${target.agentId}',
      WorkspaceProviderSubagentTabTarget() =>
        'provider_subagent_${target.parentAgentId.length}_'
            '${target.parentAgentId}_${target.subagentId.length}_'
            '${target.subagentId}',
      WorkspaceTerminalTabTarget() => 'terminal_${target.terminalId}',
      WorkspaceBrowserTabTarget() => 'browser_${target.browserId}',
      WorkspaceFileTabTarget() => 'file_${target.path}',
      WorkspaceWorkingDiffTabTarget() => 'working_diff',
      WorkspaceSetupTabTarget() => 'setup_${target.workspaceId}',
      WorkspaceCommitDiffTabTarget() => 'commit_diff_${target.sha}',
    };

String? _trimNonEmpty(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _trimOptionalString(Object? value) =>
    value == null ? null : _trimNonEmpty(value);

int? _normalizePositiveInteger(int? value) =>
    value != null && value > 0 ? value : null;

String _stringOrEmpty(Object? value) => value is String ? value : '';

int? _finiteIntegerOrNull(Object? value) =>
    value is num && value.isFinite ? value.floor() : null;

Map<String, Object?>? _stringObjectMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

bool _mapsShallowEqual(Map<String, Object?> left, Map<String, Object?> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (!right.containsKey(entry.key) || right[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

int _featureValuesHash(Map<String, Object?> values) {
  final keys = values.keys.toList()..sort();
  return Object.hashAll(keys.map((key) => Object.hash(key, values[key])));
}
