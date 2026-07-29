/// Paseo 0.2 schedule wire contracts.
library;

enum ScheduleStatus {
  active,
  paused,
  completed;

  String get wireName => name;

  static ScheduleStatus fromWire(Object? value) => switch (value) {
    'active' => active,
    'paused' => paused,
    'completed' => completed,
    _ => throw FormatException('Unknown schedule status: $value'),
  };
}

enum ScheduleRunStatus {
  running,
  succeeded,
  failed;

  String get wireName => name;

  static ScheduleRunStatus fromWire(Object? value) => switch (value) {
    'running' => running,
    'succeeded' => succeeded,
    'failed' => failed,
    _ => throw FormatException('Unknown schedule run status: $value'),
  };
}

sealed class ScheduleCadence {
  const ScheduleCadence();

  String get type;
  Map<String, Object?> toJson();

  static ScheduleCadence fromJson(Object? value) {
    final json = _map(value, 'cadence');
    return switch (json['type']) {
      'every' => EveryScheduleCadence(
        everyMs: _positiveInt(json['everyMs'], 'cadence.everyMs'),
      ),
      'cron' => CronScheduleCadence(
        expression: _nonEmpty(json['expression'], 'cadence.expression'),
        timezone: _optionalNonEmptyField(json, 'timezone', 'cadence.timezone'),
      ),
      _ => throw FormatException(
        'Unknown schedule cadence type: ${json['type']}',
      ),
    };
  }
}

final class EveryScheduleCadence extends ScheduleCadence {
  const EveryScheduleCadence({required this.everyMs});

  final int everyMs;

  @override
  String get type => 'every';

  @override
  Map<String, Object?> toJson() => {'type': type, 'everyMs': everyMs};
}

final class CronScheduleCadence extends ScheduleCadence {
  const CronScheduleCadence({required this.expression, this.timezone});

  final String expression;
  final String? timezone;

  @override
  String get type => 'cron';

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'expression': expression,
    if (timezone != null) 'timezone': timezone,
  };
}

final class ScheduleNewAgentConfig {
  const ScheduleNewAgentConfig({
    required this.provider,
    required this.cwd,
    this.modeId,
    this.model,
    this.thinkingOptionId,
    this.archiveOnFinish,
    this.isolation,
    this.title,
    this.hasTitle = false,
    this.approvalPolicy,
    this.sandboxMode,
    this.networkAccess,
    this.webSearch,
    this.featureValues,
    this.extra,
    this.systemPrompt,
    this.mcpServers,
  });

  final String provider;
  final String cwd;
  final String? modeId;
  final String? model;
  final String? thinkingOptionId;
  final bool? archiveOnFinish;
  final String? isolation;
  final String? title;

  /// Distinguishes an omitted title from the explicit JSON value `null`.
  final bool hasTitle;
  final String? approvalPolicy;
  final String? sandboxMode;
  final bool? networkAccess;
  final bool? webSearch;
  final Map<String, Object?>? featureValues;
  final Map<String, Object?>? extra;
  final String? systemPrompt;
  final Map<String, Object?>? mcpServers;

  factory ScheduleNewAgentConfig.fromJson(Object? value) {
    final json = _map(value, 'target.config');
    final isolation = _optionalStringField(
      json,
      'isolation',
      'config.isolation',
    );
    if (isolation != null && isolation != 'local' && isolation != 'worktree') {
      throw FormatException('Unknown schedule isolation: $isolation');
    }
    return ScheduleNewAgentConfig(
      provider: _string(json['provider'], 'config.provider'),
      cwd: _nonEmpty(json['cwd'], 'config.cwd'),
      modeId: _optionalNonEmptyField(json, 'modeId', 'config.modeId'),
      model: _optionalNonEmptyField(json, 'model', 'config.model'),
      thinkingOptionId: _optionalNonEmptyField(
        json,
        'thinkingOptionId',
        'config.thinkingOptionId',
      ),
      archiveOnFinish: _optionalBoolField(
        json,
        'archiveOnFinish',
        'config.archiveOnFinish',
      ),
      isolation: isolation,
      title: _optionalNullableNonEmpty(json, 'title', 'config.title'),
      hasTitle: json.containsKey('title'),
      approvalPolicy: _optionalNonEmptyField(
        json,
        'approvalPolicy',
        'config.approvalPolicy',
      ),
      sandboxMode: _optionalNonEmptyField(
        json,
        'sandboxMode',
        'config.sandboxMode',
      ),
      networkAccess: _optionalBoolField(
        json,
        'networkAccess',
        'config.networkAccess',
      ),
      webSearch: _optionalBoolField(json, 'webSearch', 'config.webSearch'),
      featureValues: _optionalMapField(
        json,
        'featureValues',
        'config.featureValues',
      ),
      extra: _scheduleExtra(json),
      systemPrompt: _optionalStringField(
        json,
        'systemPrompt',
        'config.systemPrompt',
      ),
      mcpServers: _optionalMapField(json, 'mcpServers', 'config.mcpServers'),
    );
  }

  Map<String, Object?> toJson() => {
    'provider': provider,
    'cwd': cwd,
    if (modeId != null) 'modeId': modeId,
    if (model != null) 'model': model,
    if (thinkingOptionId != null) 'thinkingOptionId': thinkingOptionId,
    if (archiveOnFinish != null) 'archiveOnFinish': archiveOnFinish,
    if (isolation != null) 'isolation': isolation,
    if (hasTitle || title != null) 'title': title,
    if (approvalPolicy != null) 'approvalPolicy': approvalPolicy,
    if (sandboxMode != null) 'sandboxMode': sandboxMode,
    if (networkAccess != null) 'networkAccess': networkAccess,
    if (webSearch != null) 'webSearch': webSearch,
    if (featureValues != null) 'featureValues': featureValues,
    if (extra != null) 'extra': extra,
    if (systemPrompt != null) 'systemPrompt': systemPrompt,
    if (mcpServers != null) 'mcpServers': mcpServers,
  };
}

sealed class ScheduleTarget {
  const ScheduleTarget();

  String get type;
  Map<String, Object?> toJson();

  static ScheduleTarget fromJson(Object? value, {bool allowSelf = false}) {
    final json = _map(value, 'target');
    return switch (json['type']) {
      'agent' => AgentScheduleTarget(
        agentId: _guid(json['agentId'], 'target.agentId'),
      ),
      'self' when allowSelf => SelfScheduleTarget(
        agentId: _guid(json['agentId'], 'target.agentId'),
      ),
      'new-agent' => NewAgentScheduleTarget(
        config: ScheduleNewAgentConfig.fromJson(json['config']),
      ),
      _ => throw FormatException(
        'Unknown schedule target type: ${json['type']}',
      ),
    };
  }
}

final class AgentScheduleTarget extends ScheduleTarget {
  const AgentScheduleTarget({required this.agentId});

  final String agentId;

  @override
  String get type => 'agent';

  @override
  Map<String, Object?> toJson() => {'type': type, 'agentId': agentId};
}

final class SelfScheduleTarget extends ScheduleTarget {
  const SelfScheduleTarget({required this.agentId});

  final String agentId;

  @override
  String get type => 'self';

  @override
  Map<String, Object?> toJson() => {'type': type, 'agentId': agentId};
}

final class NewAgentScheduleTarget extends ScheduleTarget {
  const NewAgentScheduleTarget({required this.config});

  final ScheduleNewAgentConfig config;

  @override
  String get type => 'new-agent';

  @override
  Map<String, Object?> toJson() => {'type': type, 'config': config.toJson()};
}

final class ScheduleRun {
  const ScheduleRun({
    required this.id,
    required this.scheduledFor,
    required this.startedAt,
    required this.endedAt,
    required this.status,
    required this.agentId,
    required this.workspaceId,
    this.hasWorkspaceId = false,
    required this.output,
    required this.error,
  });

  final String id;
  final String scheduledFor;
  final String startedAt;
  final String? endedAt;
  final ScheduleRunStatus status;
  final String? agentId;
  final String? workspaceId;

  /// Distinguishes an omitted workspace id from explicit JSON `null`.
  final bool hasWorkspaceId;
  final String? output;
  final String? error;

  factory ScheduleRun.fromJson(Object? value) {
    final json = _map(value, 'run');
    final agentId = _requiredNullableString(json, 'agentId', 'run.agentId');
    if (agentId != null) _validateGuid(agentId, 'run.agentId');
    return ScheduleRun(
      id: _string(json['id'], 'run.id'),
      scheduledFor: _string(json['scheduledFor'], 'run.scheduledFor'),
      startedAt: _string(json['startedAt'], 'run.startedAt'),
      endedAt: _requiredNullableString(json, 'endedAt', 'run.endedAt'),
      status: ScheduleRunStatus.fromWire(json['status']),
      agentId: agentId,
      workspaceId: _optionalString(json['workspaceId'], 'run.workspaceId'),
      hasWorkspaceId: json.containsKey('workspaceId'),
      output: _requiredNullableString(json, 'output', 'run.output'),
      error: _requiredNullableString(json, 'error', 'run.error'),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'scheduledFor': scheduledFor,
    'startedAt': startedAt,
    'endedAt': endedAt,
    'status': status.wireName,
    'agentId': agentId,
    if (hasWorkspaceId || workspaceId != null) 'workspaceId': workspaceId,
    'output': output,
    'error': error,
  };

  ScheduleRun copyWith({
    Object? endedAt = _absent,
    ScheduleRunStatus? status,
    Object? agentId = _absent,
    Object? workspaceId = _absent,
    bool? hasWorkspaceId,
    Object? output = _absent,
    Object? error = _absent,
  }) => ScheduleRun(
    id: id,
    scheduledFor: scheduledFor,
    startedAt: startedAt,
    endedAt: identical(endedAt, _absent) ? this.endedAt : endedAt as String?,
    status: status ?? this.status,
    agentId: identical(agentId, _absent) ? this.agentId : agentId as String?,
    workspaceId: identical(workspaceId, _absent)
        ? this.workspaceId
        : workspaceId as String?,
    hasWorkspaceId:
        hasWorkspaceId ??
        (identical(workspaceId, _absent)
            ? this.hasWorkspaceId
            : workspaceId != null),
    output: identical(output, _absent) ? this.output : output as String?,
    error: identical(error, _absent) ? this.error : error as String?,
  );
}

final class ScheduleSummary {
  const ScheduleSummary({
    required this.id,
    required this.name,
    required this.prompt,
    required this.cadence,
    required this.target,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.nextRunAt,
    required this.lastRunAt,
    required this.pausedAt,
    required this.expiresAt,
    required this.maxRuns,
  });

  final String id;
  final String? name;
  final String prompt;
  final ScheduleCadence cadence;
  final ScheduleTarget target;
  final ScheduleStatus status;
  final String createdAt;
  final String updatedAt;
  final String? nextRunAt;
  final String? lastRunAt;
  final String? pausedAt;
  final String? expiresAt;
  final int? maxRuns;

  factory ScheduleSummary.fromJson(Object? value) {
    final json = _map(value, 'schedule');
    return ScheduleSummary(
      id: _string(json['id'], 'schedule.id'),
      name: _requiredNullableString(json, 'name', 'schedule.name'),
      prompt: _minLengthOne(json['prompt'], 'schedule.prompt'),
      cadence: ScheduleCadence.fromJson(json['cadence']),
      target: ScheduleTarget.fromJson(json['target']),
      status: ScheduleStatus.fromWire(json['status']),
      createdAt: _string(json['createdAt'], 'schedule.createdAt'),
      updatedAt: _string(json['updatedAt'], 'schedule.updatedAt'),
      nextRunAt: _requiredNullableString(
        json,
        'nextRunAt',
        'schedule.nextRunAt',
      ),
      lastRunAt: _requiredNullableString(
        json,
        'lastRunAt',
        'schedule.lastRunAt',
      ),
      pausedAt: _requiredNullableString(json, 'pausedAt', 'schedule.pausedAt'),
      expiresAt: _requiredNullableString(
        json,
        'expiresAt',
        'schedule.expiresAt',
      ),
      maxRuns: _requiredNullablePositiveInt(
        json,
        'maxRuns',
        'schedule.maxRuns',
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'prompt': prompt,
    'cadence': cadence.toJson(),
    'target': target.toJson(),
    'status': status.wireName,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'nextRunAt': nextRunAt,
    'lastRunAt': lastRunAt,
    'pausedAt': pausedAt,
    'expiresAt': expiresAt,
    'maxRuns': maxRuns,
  };

  ScheduleSummary copyWith({
    Object? name = _absent,
    String? prompt,
    ScheduleCadence? cadence,
    ScheduleTarget? target,
    ScheduleStatus? status,
    String? updatedAt,
    Object? nextRunAt = _absent,
    Object? lastRunAt = _absent,
    Object? pausedAt = _absent,
    Object? expiresAt = _absent,
    Object? maxRuns = _absent,
  }) => ScheduleSummary(
    id: id,
    name: identical(name, _absent) ? this.name : name as String?,
    prompt: prompt ?? this.prompt,
    cadence: cadence ?? this.cadence,
    target: target ?? this.target,
    status: status ?? this.status,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    nextRunAt: identical(nextRunAt, _absent)
        ? this.nextRunAt
        : nextRunAt as String?,
    lastRunAt: identical(lastRunAt, _absent)
        ? this.lastRunAt
        : lastRunAt as String?,
    pausedAt: identical(pausedAt, _absent)
        ? this.pausedAt
        : pausedAt as String?,
    expiresAt: identical(expiresAt, _absent)
        ? this.expiresAt
        : expiresAt as String?,
    maxRuns: identical(maxRuns, _absent) ? this.maxRuns : maxRuns as int?,
  );
}

final class StoredSchedule {
  const StoredSchedule({required this.summary, required this.runs});

  final ScheduleSummary summary;
  final List<ScheduleRun> runs;

  factory StoredSchedule.fromJson(Object? value) {
    final json = _map(value, 'schedule');
    return StoredSchedule(
      summary: ScheduleSummary.fromJson(json),
      runs: _list(
        json['runs'],
        'schedule.runs',
      ).map(ScheduleRun.fromJson).toList(growable: false),
    );
  }

  Map<String, Object?> toJson() => {
    ...summary.toJson(),
    'runs': runs.map((run) => run.toJson()).toList(growable: false),
  };

  StoredSchedule copyWith({
    ScheduleSummary? summary,
    List<ScheduleRun>? runs,
  }) =>
      StoredSchedule(summary: summary ?? this.summary, runs: runs ?? this.runs);
}

final class ScheduleCreateRequest {
  const ScheduleCreateRequest({
    required this.requestId,
    required this.prompt,
    required this.cadence,
    required this.target,
    this.name,
    this.maxRuns,
    this.expiresAt,
    this.runOnCreate,
  });

  static const type = 'schedule/create';
  final String requestId;
  final String prompt;
  final String? name;
  final ScheduleCadence cadence;
  final ScheduleTarget target;
  final int? maxRuns;
  final String? expiresAt;
  final bool? runOnCreate;

  factory ScheduleCreateRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return ScheduleCreateRequest(
      requestId: _string(json['requestId'], 'requestId'),
      prompt: _minLengthOne(json['prompt'], 'prompt'),
      name: _optionalStringField(json, 'name', 'name'),
      cadence: ScheduleCadence.fromJson(json['cadence']),
      target: ScheduleTarget.fromJson(json['target'], allowSelf: true),
      maxRuns: _optionalPositiveIntField(json, 'maxRuns', 'maxRuns'),
      expiresAt: _optionalStringField(json, 'expiresAt', 'expiresAt'),
      runOnCreate: _optionalBoolField(json, 'runOnCreate', 'runOnCreate'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'prompt': prompt,
    if (name != null) 'name': name,
    'cadence': cadence.toJson(),
    'target': target.toJson(),
    if (maxRuns != null) 'maxRuns': maxRuns,
    if (expiresAt != null) 'expiresAt': expiresAt,
    if (runOnCreate != null) 'runOnCreate': runOnCreate,
  };
}

final class ScheduleIdRequest {
  const ScheduleIdRequest({
    required this.type,
    required this.requestId,
    required this.scheduleId,
  });

  static const inspectType = 'schedule/inspect';
  static const logsType = 'schedule/logs';
  static const pauseType = 'schedule/pause';
  static const resumeType = 'schedule/resume';
  static const deleteType = 'schedule/delete';
  static const runOnceType = 'schedule/run-once';
  static const supportedTypes = {
    inspectType,
    logsType,
    pauseType,
    resumeType,
    deleteType,
    runOnceType,
  };

  final String type;
  final String requestId;
  final String scheduleId;

  factory ScheduleIdRequest.fromJson(Map<String, Object?> json) {
    final type = json['type'];
    if (type is! String || !supportedTypes.contains(type)) {
      throw FormatException('Unknown schedule request type: $type');
    }
    return ScheduleIdRequest(
      type: type,
      requestId: _string(json['requestId'], 'requestId'),
      scheduleId: _string(json['scheduleId'], 'scheduleId'),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'scheduleId': scheduleId,
  };
}

final class ScheduleListRequest {
  const ScheduleListRequest({required this.requestId});

  static const type = 'schedule/list';
  final String requestId;

  factory ScheduleListRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    return ScheduleListRequest(
      requestId: _string(json['requestId'], 'requestId'),
    );
  }

  Map<String, Object?> toJson() => {'type': type, 'requestId': requestId};
}

final class ScheduleUpdateRequest {
  const ScheduleUpdateRequest({
    required this.requestId,
    required this.scheduleId,
    required this.changes,
  });

  static const type = 'schedule/update';
  static const _allowedFields = {
    'name',
    'prompt',
    'cadence',
    'newAgentConfig',
    'maxRuns',
    'expiresAt',
  };

  final String requestId;
  final String scheduleId;
  final Map<String, Object?> changes;

  factory ScheduleUpdateRequest.fromJson(Map<String, Object?> json) {
    _expectType(json, type);
    final changes = <String, Object?>{};
    for (final field in _allowedFields) {
      if (json.containsKey(field)) changes[field] = json[field];
    }
    if (changes['name'] case final value?) {
      _string(value, 'name');
    }
    if (changes.containsKey('prompt')) {
      _minLengthOne(changes['prompt'], 'prompt');
    }
    if (changes.containsKey('cadence')) {
      changes['cadence'] = ScheduleCadence.fromJson(
        changes['cadence'],
      ).toJson();
    }
    if (changes['maxRuns'] case final value?) {
      _positiveInt(value, 'maxRuns');
    }
    if (changes['expiresAt'] case final value?) {
      _string(value, 'expiresAt');
    }
    if (changes.containsKey('newAgentConfig')) {
      final config = _map(changes['newAgentConfig'], 'newAgentConfig');
      const nullableStrings = {'model', 'modeId', 'thinkingOptionId'};
      const strings = {'provider', 'cwd'};
      final normalized = <String, Object?>{};
      for (final entry in config.entries) {
        if (strings.contains(entry.key)) {
          normalized[entry.key] = _nonEmpty(
            entry.value,
            'newAgentConfig.${entry.key}',
          );
        } else if (nullableStrings.contains(entry.key) && entry.value != null) {
          normalized[entry.key] = _nonEmpty(
            entry.value,
            'newAgentConfig.${entry.key}',
          );
        } else if (nullableStrings.contains(entry.key)) {
          normalized[entry.key] = null;
        } else if (entry.key == 'archiveOnFinish') {
          normalized[entry.key] = _bool(
            entry.value,
            'newAgentConfig.archiveOnFinish',
          );
        } else if (entry.key == 'isolation') {
          final isolation = _string(entry.value, 'newAgentConfig.isolation');
          if (isolation != 'local' && isolation != 'worktree') {
            throw FormatException('Unknown schedule isolation: $isolation');
          }
          normalized[entry.key] = isolation;
        }
      }
      changes['newAgentConfig'] = normalized;
    }
    return ScheduleUpdateRequest(
      requestId: _string(json['requestId'], 'requestId'),
      scheduleId: _string(json['scheduleId'], 'scheduleId'),
      changes: Map.unmodifiable(changes),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'requestId': requestId,
    'scheduleId': scheduleId,
    ...changes,
  };
}

sealed class ScheduleRpcResponse {
  const ScheduleRpcResponse();

  String get type;
  String get requestId;
  String? get error;
  Map<String, Object?> toJson();

  static ScheduleRpcResponse fromJson(
    Map<String, Object?> json,
  ) => switch (json['type']) {
    ScheduleCreateResponse.wireType => ScheduleCreateResponse.fromJson(json),
    ScheduleListResponse.wireType => ScheduleListResponse.fromJson(json),
    ScheduleInspectResponse.wireType => ScheduleInspectResponse.fromJson(json),
    ScheduleLogsResponse.wireType => ScheduleLogsResponse.fromJson(json),
    SchedulePauseResponse.wireType => SchedulePauseResponse.fromJson(json),
    ScheduleResumeResponse.wireType => ScheduleResumeResponse.fromJson(json),
    ScheduleDeleteResponse.wireType => ScheduleDeleteResponse.fromJson(json),
    ScheduleRunOnceResponse.wireType => ScheduleRunOnceResponse.fromJson(json),
    ScheduleUpdateResponse.wireType => ScheduleUpdateResponse.fromJson(json),
    final type => throw FormatException(
      'Unknown schedule response type: $type',
    ),
  };
}

abstract base class _ScheduleSummaryResponse extends ScheduleRpcResponse {
  const _ScheduleSummaryResponse({
    required this.requestId,
    required this.schedule,
    required this.error,
  });

  @override
  final String requestId;
  final ScheduleSummary? schedule;
  @override
  final String? error;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'schedule': schedule?.toJson(),
      'error': error,
    },
  };
}

final class ScheduleCreateResponse extends _ScheduleSummaryResponse {
  const ScheduleCreateResponse({
    required super.requestId,
    required super.schedule,
    required super.error,
  });

  static const wireType = 'schedule/create/response';

  factory ScheduleCreateResponse.fromJson(Map<String, Object?> json) {
    final payload = _responsePayload(json, wireType);
    final fields = _summaryResponseFields(payload);
    return ScheduleCreateResponse(
      requestId: fields.requestId,
      schedule: fields.schedule,
      error: fields.error,
    );
  }

  @override
  String get type => wireType;
}

final class SchedulePauseResponse extends _ScheduleSummaryResponse {
  const SchedulePauseResponse({
    required super.requestId,
    required super.schedule,
    required super.error,
  });

  static const wireType = 'schedule/pause/response';

  factory SchedulePauseResponse.fromJson(Map<String, Object?> json) {
    final payload = _responsePayload(json, wireType);
    final fields = _summaryResponseFields(payload);
    return SchedulePauseResponse(
      requestId: fields.requestId,
      schedule: fields.schedule,
      error: fields.error,
    );
  }

  @override
  String get type => wireType;
}

final class ScheduleResumeResponse extends _ScheduleSummaryResponse {
  const ScheduleResumeResponse({
    required super.requestId,
    required super.schedule,
    required super.error,
  });

  static const wireType = 'schedule/resume/response';

  factory ScheduleResumeResponse.fromJson(Map<String, Object?> json) {
    final payload = _responsePayload(json, wireType);
    final fields = _summaryResponseFields(payload);
    return ScheduleResumeResponse(
      requestId: fields.requestId,
      schedule: fields.schedule,
      error: fields.error,
    );
  }

  @override
  String get type => wireType;
}

abstract base class _StoredScheduleResponse extends ScheduleRpcResponse {
  const _StoredScheduleResponse({
    required this.requestId,
    required this.schedule,
    required this.error,
  });

  @override
  final String requestId;
  final StoredSchedule? schedule;
  @override
  final String? error;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'schedule': schedule?.toJson(),
      'error': error,
    },
  };
}

final class ScheduleInspectResponse extends _StoredScheduleResponse {
  const ScheduleInspectResponse({
    required super.requestId,
    required super.schedule,
    required super.error,
  });

  static const wireType = 'schedule/inspect/response';

  factory ScheduleInspectResponse.fromJson(Map<String, Object?> json) {
    final payload = _responsePayload(json, wireType);
    final fields = _storedResponseFields(payload);
    return ScheduleInspectResponse(
      requestId: fields.requestId,
      schedule: fields.schedule,
      error: fields.error,
    );
  }

  @override
  String get type => wireType;
}

final class ScheduleRunOnceResponse extends _StoredScheduleResponse {
  const ScheduleRunOnceResponse({
    required super.requestId,
    required super.schedule,
    required super.error,
  });

  static const wireType = 'schedule/run-once/response';

  factory ScheduleRunOnceResponse.fromJson(Map<String, Object?> json) {
    final payload = _responsePayload(json, wireType);
    final fields = _storedResponseFields(payload);
    return ScheduleRunOnceResponse(
      requestId: fields.requestId,
      schedule: fields.schedule,
      error: fields.error,
    );
  }

  @override
  String get type => wireType;
}

final class ScheduleUpdateResponse extends _StoredScheduleResponse {
  const ScheduleUpdateResponse({
    required super.requestId,
    required super.schedule,
    required super.error,
  });

  static const wireType = 'schedule/update/response';

  factory ScheduleUpdateResponse.fromJson(Map<String, Object?> json) {
    final payload = _responsePayload(json, wireType);
    final fields = _storedResponseFields(payload);
    return ScheduleUpdateResponse(
      requestId: fields.requestId,
      schedule: fields.schedule,
      error: fields.error,
    );
  }

  @override
  String get type => wireType;
}

final class ScheduleListResponse extends ScheduleRpcResponse {
  const ScheduleListResponse({
    required this.requestId,
    required this.schedules,
    required this.error,
  });

  static const wireType = 'schedule/list/response';
  @override
  final String requestId;
  final List<ScheduleSummary> schedules;
  @override
  final String? error;

  factory ScheduleListResponse.fromJson(Map<String, Object?> json) {
    final payload = _responsePayload(json, wireType);
    return ScheduleListResponse(
      requestId: _string(payload['requestId'], 'payload.requestId'),
      schedules: _list(
        payload['schedules'],
        'payload.schedules',
      ).map(ScheduleSummary.fromJson).toList(growable: false),
      error: _requiredNullableString(payload, 'error', 'payload.error'),
    );
  }

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'schedules': schedules
          .map((schedule) => schedule.toJson())
          .toList(growable: false),
      'error': error,
    },
  };
}

final class ScheduleLogsResponse extends ScheduleRpcResponse {
  const ScheduleLogsResponse({
    required this.requestId,
    required this.runs,
    required this.error,
  });

  static const wireType = 'schedule/logs/response';
  @override
  final String requestId;
  final List<ScheduleRun> runs;
  @override
  final String? error;

  factory ScheduleLogsResponse.fromJson(Map<String, Object?> json) {
    final payload = _responsePayload(json, wireType);
    return ScheduleLogsResponse(
      requestId: _string(payload['requestId'], 'payload.requestId'),
      runs: _list(
        payload['runs'],
        'payload.runs',
      ).map(ScheduleRun.fromJson).toList(growable: false),
      error: _requiredNullableString(payload, 'error', 'payload.error'),
    );
  }

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'runs': runs.map((run) => run.toJson()).toList(growable: false),
      'error': error,
    },
  };
}

final class ScheduleDeleteResponse extends ScheduleRpcResponse {
  const ScheduleDeleteResponse({
    required this.requestId,
    required this.scheduleId,
    required this.error,
  });

  static const wireType = 'schedule/delete/response';
  @override
  final String requestId;
  final String scheduleId;
  @override
  final String? error;

  factory ScheduleDeleteResponse.fromJson(Map<String, Object?> json) {
    final payload = _responsePayload(json, wireType);
    return ScheduleDeleteResponse(
      requestId: _string(payload['requestId'], 'payload.requestId'),
      scheduleId: _string(payload['scheduleId'], 'payload.scheduleId'),
      error: _requiredNullableString(payload, 'error', 'payload.error'),
    );
  }

  @override
  String get type => wireType;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'requestId': requestId,
      'scheduleId': scheduleId,
      'error': error,
    },
  };
}

Map<String, Object?> scheduleResponse({
  required String requestType,
  required String requestId,
  required Map<String, Object?> payload,
}) => {
  'type': '$requestType/response',
  'payload': {'requestId': requestId, ...payload},
};

Map<String, Object?> _responsePayload(Map<String, Object?> json, String type) {
  _expectType(json, type);
  return _map(json['payload'], 'payload');
}

({String requestId, ScheduleSummary? schedule, String? error})
_summaryResponseFields(Map<String, Object?> payload) => (
  requestId: _string(payload['requestId'], 'payload.requestId'),
  schedule: _requiredNullableValue(
    payload,
    'schedule',
    'payload.schedule',
    ScheduleSummary.fromJson,
  ),
  error: _requiredNullableString(payload, 'error', 'payload.error'),
);

({String requestId, StoredSchedule? schedule, String? error})
_storedResponseFields(Map<String, Object?> payload) => (
  requestId: _string(payload['requestId'], 'payload.requestId'),
  schedule: _requiredNullableValue(
    payload,
    'schedule',
    'payload.schedule',
    StoredSchedule.fromJson,
  ),
  error: _requiredNullableString(payload, 'error', 'payload.error'),
);

Map<String, Object?> _map(Object? value, String field) {
  if (value is Map) return Map<String, Object?>.from(value);
  throw FormatException('$field must be an object');
}

Map<String, Object?>? _optionalMapField(
  Map<String, Object?> json,
  String key,
  String field,
) {
  if (!json.containsKey(key)) return null;
  return _map(json[key], field);
}

Map<String, Object?>? _scheduleExtra(Map<String, Object?> json) {
  if (!json.containsKey('extra')) return null;
  final extra = _map(json['extra'], 'config.extra');
  final normalized = <String, Object?>{};
  for (final key in const ['codex', 'claude']) {
    if (extra.containsKey(key)) {
      normalized[key] = _map(extra[key], 'config.extra.$key');
    }
  }
  return normalized;
}

List<Object?> _list(Object? value, String field) {
  if (value is List) return value;
  throw FormatException('$field must be an array');
}

String _string(Object? value, String field) {
  if (value is String) return value;
  throw FormatException('$field must be a string');
}

String _nonEmpty(Object? value, String field) {
  final string = _string(value, field).trim();
  if (string.isEmpty) throw FormatException('$field must not be empty');
  return string;
}

String _minLengthOne(Object? value, String field) {
  final string = _string(value, field);
  if (string.isEmpty) throw FormatException('$field must not be empty');
  return string;
}

String? _optionalString(Object? value, String field) =>
    value == null ? null : _string(value, field);

String? _optionalStringField(
  Map<String, Object?> json,
  String key,
  String field,
) {
  if (!json.containsKey(key)) return null;
  return _string(json[key], field);
}

String? _optionalNonEmptyField(
  Map<String, Object?> json,
  String key,
  String field,
) {
  if (!json.containsKey(key)) return null;
  return _nonEmpty(json[key], field);
}

String? _optionalNullableNonEmpty(
  Map<String, Object?> json,
  String key,
  String field,
) {
  if (!json.containsKey(key) || json[key] == null) return null;
  return _nonEmpty(json[key], field);
}

bool _bool(Object? value, String field) {
  if (value is bool) return value;
  throw FormatException('$field must be a boolean');
}

bool? _optionalBoolField(Map<String, Object?> json, String key, String field) {
  if (!json.containsKey(key)) return null;
  return _bool(json[key], field);
}

int _positiveInt(Object? value, String field) {
  if (value is int && value > 0) return value;
  throw FormatException('$field must be a positive integer');
}

int? _optionalPositiveIntField(
  Map<String, Object?> json,
  String key,
  String field,
) {
  if (!json.containsKey(key)) return null;
  return _positiveInt(json[key], field);
}

String? _requiredNullableString(
  Map<String, Object?> json,
  String key,
  String field,
) {
  if (!json.containsKey(key)) {
    throw FormatException('$field is required');
  }
  return json[key] == null ? null : _string(json[key], field);
}

int? _requiredNullablePositiveInt(
  Map<String, Object?> json,
  String key,
  String field,
) {
  if (!json.containsKey(key)) {
    throw FormatException('$field is required');
  }
  return json[key] == null ? null : _positiveInt(json[key], field);
}

T? _requiredNullableValue<T>(
  Map<String, Object?> json,
  String key,
  String field,
  T Function(Object? value) decode,
) {
  if (!json.containsKey(key)) {
    throw FormatException('$field is required');
  }
  return json[key] == null ? null : decode(json[key]);
}

String _guid(Object? value, String field) {
  final result = _string(value, field);
  _validateGuid(result, field);
  return result;
}

void _validateGuid(String value, String field) {
  if (!RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  ).hasMatch(value)) {
    throw FormatException('$field must be a guid');
  }
}

void _expectType(Map<String, Object?> json, String type) {
  if (json['type'] != type) throw FormatException('Expected type $type');
}

const _absent = Object();
