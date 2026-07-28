import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'schedule_cron.dart';
import 'schedule_store.dart';

final class ScheduleExecutionResult {
  const ScheduleExecutionResult({
    required this.agentId,
    required this.output,
    this.workspaceId,
  });

  final String? agentId;
  final String? workspaceId;
  final String? output;
}

typedef ScheduleRunner =
    Future<ScheduleExecutionResult> Function(
      StoredSchedule schedule,
      String runId,
    );
typedef ScheduleWorkspaceArchiver = Future<void> Function(String workspaceId);
typedef ScheduleErrorHandler = void Function(Object error, StackTrace stack);

final class ScheduleTargetGoneError extends StateError {
  ScheduleTargetGoneError(super.message);
}

final class ScheduleService {
  ScheduleService({
    required String home,
    required ScheduleRunner runner,
    ScheduleStore? store,
    DateTime Function()? now,
    Uuid? uuid,
    ScheduleWorkspaceArchiver? archiveWorkspace,
    ScheduleErrorHandler? onError,
    bool Function(String agentId)? targetAgentExists,
  }) : _store = store ?? ScheduleStore(p.join(home, 'schedules')),
       _runner = runner,
       _now = now ?? DateTime.now,
       _uuid = uuid ?? const Uuid(),
       _archiveWorkspace = archiveWorkspace,
       _onError = onError,
       _targetAgentExists = targetAgentExists;

  final ScheduleStore _store;
  final ScheduleRunner _runner;
  final DateTime Function() _now;
  final Uuid _uuid;
  final ScheduleWorkspaceArchiver? _archiveWorkspace;
  final ScheduleErrorHandler? _onError;
  final bool Function(String agentId)? _targetAgentExists;
  final Set<String> _runningScheduleIds = {};
  Timer? _tickTimer;

  Future<void> start() async {
    await _recoverInterruptedRuns();
    await _sweepOrphanedSchedules();
    _tickTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_tickSafely()),
    );
  }

  Future<void> _tickSafely() async {
    try {
      await tick();
    } on Object catch (error, stack) {
      _onError?.call(error, stack);
    }
  }

  void stop() {
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  Future<StoredSchedule> create(ScheduleCreateRequest request) async {
    return _store.create(_newSchedule(request));
  }

  Future<StoredSchedule> createOrReplace(ScheduleCreateRequest request) async {
    final name = _optionalName(request.name);
    if (name == null) return create(request);
    final candidate = _newSchedule(request);
    return _store.upsertByNameAndTarget(
      name: name,
      target: candidate.summary.target,
      create: () => candidate,
      update: (current) {
        final now = _now().toUtc();
        var cadence = candidate.summary.cadence;
        if (current.summary.cadence case CronScheduleCadence(
          timezone: final currentZone?,
        )) {
          if (cadence case CronScheduleCadence(
            expression: final expression,
            timezone: null,
          )) {
            cadence = CronScheduleCadence(
              expression: expression,
              timezone: currentZone,
            );
          }
        }
        final nextRunAt = request.runOnCreate ?? false
            ? now
            : computeNextRunAt(cadence, now);
        return current.copyWith(
          summary: current.summary.copyWith(
            name: name,
            prompt: candidate.summary.prompt,
            cadence: cadence,
            target: candidate.summary.target,
            status: ScheduleStatus.active,
            updatedAt: now.toIso8601String(),
            nextRunAt: nextRunAt.toIso8601String(),
            pausedAt: null,
            expiresAt: candidate.summary.expiresAt,
            maxRuns: candidate.summary.maxRuns,
          ),
        );
      },
    );
  }

  StoredSchedule _newSchedule(ScheduleCreateRequest request) {
    final prompt = _normalizePrompt(request.prompt);
    validateScheduleCadence(request.cadence);
    final target = switch (request.target) {
      SelfScheduleTarget(agentId: final agentId) => AgentScheduleTarget(
        agentId: agentId,
      ),
      final target => target,
    };
    final now = _now().toUtc();
    final runOnCreate =
        request.runOnCreate ?? request.cadence is EveryScheduleCadence;
    final nextRunAt = runOnCreate
        ? now
        : computeNextRunAt(request.cadence, now);
    return StoredSchedule(
      summary: ScheduleSummary(
        id: '',
        name: _optionalName(request.name),
        prompt: prompt,
        cadence: request.cadence,
        target: target,
        status: ScheduleStatus.active,
        createdAt: now.toIso8601String(),
        updatedAt: now.toIso8601String(),
        nextRunAt: nextRunAt.toIso8601String(),
        lastRunAt: null,
        pausedAt: null,
        expiresAt: request.expiresAt,
        maxRuns: request.maxRuns,
      ),
      runs: const [],
    );
  }

  Future<List<StoredSchedule>> list() => _store.list();

  Future<StoredSchedule> inspect(String id) async =>
      await _store.get(id) ?? (throw StateError('Schedule not found: $id'));

  Future<List<ScheduleRun>> logs(String id) async {
    final schedule = await inspect(id);
    return [...schedule.runs]
      ..sort((left, right) => left.startedAt.compareTo(right.startedAt));
  }

  Future<void> recordRunWorkspace({
    required String scheduleId,
    required String runId,
    required String workspaceId,
    required String? agentId,
  }) async {
    final updated = await _store.update(
      scheduleId,
      (schedule) => schedule.copyWith(
        summary: schedule.summary.copyWith(
          updatedAt: _now().toUtc().toIso8601String(),
        ),
        runs: [
          for (final run in schedule.runs)
            if (run.id == runId && run.status == ScheduleRunStatus.running)
              run.copyWith(workspaceId: workspaceId, agentId: agentId)
            else
              run,
        ],
      ),
    );
    if (updated == null) {
      throw StateError('Schedule not found: $scheduleId');
    }
  }

  Future<StoredSchedule> pause(String id) async {
    final updated = await _store.update(id, (schedule) {
      if (schedule.summary.status == ScheduleStatus.completed) {
        throw StateError('Schedule $id is already completed');
      }
      if (schedule.summary.status == ScheduleStatus.paused) return schedule;
      final now = _now().toUtc().toIso8601String();
      return schedule.copyWith(
        summary: schedule.summary.copyWith(
          status: ScheduleStatus.paused,
          nextRunAt: null,
          pausedAt: now,
          updatedAt: now,
        ),
      );
    });
    return updated ?? (throw StateError('Schedule not found: $id'));
  }

  Future<StoredSchedule> resume(String id) async {
    final updated = await _store.update(id, (schedule) {
      if (schedule.summary.status == ScheduleStatus.completed) {
        throw StateError('Schedule $id is already completed');
      }
      if (schedule.summary.status == ScheduleStatus.active) return schedule;
      final now = _now().toUtc();
      return schedule.copyWith(
        summary: schedule.summary.copyWith(
          status: ScheduleStatus.active,
          nextRunAt: computeNextRunAt(
            schedule.summary.cadence,
            now,
          ).toIso8601String(),
          pausedAt: null,
          updatedAt: now.toIso8601String(),
        ),
      );
    });
    return updated ?? (throw StateError('Schedule not found: $id'));
  }

  Future<StoredSchedule> update(ScheduleUpdateRequest request) async {
    final updated = await _store.update(request.scheduleId, (schedule) {
      final changes = request.changes;
      final now = _now().toUtc();
      var summary = schedule.summary;
      if (changes.containsKey('name')) {
        summary = summary.copyWith(
          name: _optionalName(changes['name'] as String?),
        );
      }
      if (changes['prompt'] case final String prompt) {
        summary = summary.copyWith(prompt: _normalizePrompt(prompt));
      }
      if (changes['cadence'] case final Object cadenceJson) {
        var cadence = ScheduleCadence.fromJson(cadenceJson);
        if (summary.cadence case CronScheduleCadence(
          timezone: final currentZone?,
        )) {
          if (cadence case CronScheduleCadence(
            expression: final expression,
            timezone: null,
          )) {
            cadence = CronScheduleCadence(
              expression: expression,
              timezone: currentZone,
            );
          }
        }
        validateScheduleCadence(cadence);
        summary = summary.copyWith(
          cadence: cadence,
          nextRunAt: summary.status == ScheduleStatus.active
              ? computeNextRunAt(cadence, now).toIso8601String()
              : null,
        );
      }
      if (changes.containsKey('maxRuns')) {
        summary = summary.copyWith(maxRuns: changes['maxRuns'] as int?);
      }
      if (changes.containsKey('expiresAt')) {
        summary = summary.copyWith(expiresAt: changes['expiresAt'] as String?);
      }
      if (changes['newAgentConfig'] case final Map configPatch) {
        final target = summary.target;
        if (target is! NewAgentScheduleTarget) {
          throw StateError(
            'new-agent config updates are only valid for new-agent target schedules',
          );
        }
        summary = summary.copyWith(
          target: NewAgentScheduleTarget(
            config: _patchConfig(
              target.config,
              configPatch.cast<String, Object?>(),
            ),
          ),
        );
      }
      return schedule.copyWith(
        summary: summary.copyWith(updatedAt: now.toIso8601String()),
      );
    });
    return updated ??
        (throw StateError('Schedule not found: ${request.scheduleId}'));
  }

  Future<void> delete(String id) => _store.delete(id);

  Future<Set<String>> listActiveAgentTargetIds() async => {
    for (final schedule in await _store.list())
      if (schedule.summary.status == ScheduleStatus.active)
        if (schedule.summary.target case AgentScheduleTarget(agentId: final id))
          id,
  };

  Future<int> completeForAgent(String agentId) async {
    final now = _now().toUtc();
    var completed = 0;
    for (final schedule in await _store.list()) {
      if (schedule.summary.target
          case AgentScheduleTarget(agentId: final targetId)
          when targetId == agentId &&
              schedule.summary.status != ScheduleStatus.completed) {
        await _complete(schedule.summary.id, now);
        completed++;
      }
    }
    return completed;
  }

  Future<StoredSchedule> runOnce(String id) async {
    final schedule = await inspect(id);
    if (schedule.summary.status == ScheduleStatus.completed) {
      throw StateError('Schedule $id is already completed');
    }
    if (_runningScheduleIds.contains(id)) {
      throw StateError('Schedule $id is already running');
    }
    await _runSchedule(schedule, _now().toUtc(), manual: true);
    return inspect(id);
  }

  Future<void> tick() async {
    final now = _now().toUtc();
    for (final schedule in await _store.list()) {
      final summary = schedule.summary;
      if (summary.status != ScheduleStatus.active ||
          summary.nextRunAt == null ||
          _runningScheduleIds.contains(summary.id)) {
        continue;
      }
      if (_shouldComplete(schedule, now)) {
        await _complete(summary.id, now);
        continue;
      }
      if (DateTime.parse(summary.nextRunAt!).isAfter(now)) continue;
      await _runSchedule(schedule, now);
    }
  }

  Future<Map<String, Object?>?> handle(Map<String, Object?> message) async {
    final type = message['type'];
    if (type is! String || !type.startsWith('schedule/')) return null;
    final requestId = message['requestId'];
    if (requestId is! String) {
      throw const FormatException('requestId must be a string');
    }
    try {
      switch (type) {
        case ScheduleCreateRequest.type:
          final schedule = await create(
            ScheduleCreateRequest.fromJson(message),
          );
          return scheduleResponse(
            requestType: type,
            requestId: requestId,
            payload: {'schedule': schedule.summary.toJson(), 'error': null},
          );
        case ScheduleListRequest.type:
          ScheduleListRequest.fromJson(message);
          final schedules = await list();
          return scheduleResponse(
            requestType: type,
            requestId: requestId,
            payload: {
              'schedules': schedules
                  .map((schedule) => schedule.summary.toJson())
                  .toList(growable: false),
              'error': null,
            },
          );
        case ScheduleUpdateRequest.type:
          final schedule = await update(
            ScheduleUpdateRequest.fromJson(message),
          );
          return scheduleResponse(
            requestType: type,
            requestId: requestId,
            payload: {'schedule': schedule.toJson(), 'error': null},
          );
        default:
          final request = ScheduleIdRequest.fromJson(message);
          return await _handleIdRequest(request);
      }
    } on Object catch (error) {
      return scheduleResponse(
        requestType: type,
        requestId: requestId,
        payload: _errorPayload(type, message, error),
      );
    }
  }

  Future<Map<String, Object?>> _handleIdRequest(
    ScheduleIdRequest request,
  ) async {
    final payload = switch (request.type) {
      ScheduleIdRequest.inspectType => {
        'schedule': (await inspect(request.scheduleId)).toJson(),
        'error': null,
      },
      ScheduleIdRequest.logsType => {
        'runs': (await logs(
          request.scheduleId,
        )).map((run) => run.toJson()).toList(growable: false),
        'error': null,
      },
      ScheduleIdRequest.pauseType => {
        'schedule': (await pause(request.scheduleId)).summary.toJson(),
        'error': null,
      },
      ScheduleIdRequest.resumeType => {
        'schedule': (await resume(request.scheduleId)).summary.toJson(),
        'error': null,
      },
      ScheduleIdRequest.deleteType => () {
        return <String, Object?>{
          'scheduleId': request.scheduleId,
          'error': null,
        };
      }(),
      ScheduleIdRequest.runOnceType => {
        'schedule': (await runOnce(request.scheduleId)).toJson(),
        'error': null,
      },
      _ => throw StateError('Unsupported schedule request ${request.type}'),
    };
    if (request.type == ScheduleIdRequest.deleteType) {
      await delete(request.scheduleId);
    }
    return scheduleResponse(
      requestType: request.type,
      requestId: request.requestId,
      payload: payload,
    );
  }

  Map<String, Object?> _errorPayload(
    String type,
    Map<String, Object?> message,
    Object error,
  ) {
    final text = error is FormatException
        ? error.message
        : error.toString().replaceFirst(
            RegExp(r'^(Bad state|Invalid argument): '),
            '',
          );
    return switch (type) {
      ScheduleListRequest.type => {'schedules': <Object?>[], 'error': text},
      ScheduleIdRequest.logsType => {'runs': <Object?>[], 'error': text},
      ScheduleIdRequest.deleteType => {
        'scheduleId': message['scheduleId'] is String
            ? message['scheduleId']
            : '',
        'error': text,
      },
      _ => {'schedule': null, 'error': text},
    };
  }

  Future<void> _runSchedule(
    StoredSchedule schedule,
    DateTime now, {
    bool manual = false,
  }) async {
    final id = schedule.summary.id;
    _runningScheduleIds.add(id);
    final runId = _uuid.v4();
    final running = ScheduleRun(
      id: runId,
      scheduledFor: manual
          ? now.toIso8601String()
          : schedule.summary.nextRunAt ?? now.toIso8601String(),
      startedAt: now.toIso8601String(),
      endedAt: null,
      status: ScheduleRunStatus.running,
      agentId: null,
      workspaceId: null,
      output: null,
      error: null,
    );
    final withRun = await _store.update(
      id,
      (current) => current.copyWith(runs: [...current.runs, running]),
    );
    if (withRun == null) {
      _runningScheduleIds.remove(id);
      throw StateError('Schedule not found: $id');
    }
    try {
      final result = await _runner(withRun, runId);
      await _finishRun(
        id,
        runId,
        ScheduleRunStatus.succeeded,
        agentId: result.agentId,
        workspaceId: result.workspaceId,
        output: result.output,
        manual: manual,
      );
    } on Object catch (error) {
      await _finishRun(
        id,
        runId,
        ScheduleRunStatus.failed,
        error: error.toString(),
        targetGone: error is ScheduleTargetGoneError,
        manual: manual,
      );
    } finally {
      _runningScheduleIds.remove(id);
    }
  }

  Future<void> _finishRun(
    String scheduleId,
    String runId,
    ScheduleRunStatus status, {
    String? agentId,
    String? workspaceId,
    String? output,
    String? error,
    bool targetGone = false,
    bool manual = false,
  }) async {
    await _store.update(scheduleId, (schedule) {
      final now = _now().toUtc();
      final runs = [
        for (final run in schedule.runs)
          if (run.id == runId)
            run.copyWith(
              status: status,
              endedAt: now.toIso8601String(),
              agentId: agentId ?? run.agentId,
              workspaceId: workspaceId ?? run.workspaceId,
              output: output,
              error: error,
            )
          else
            run,
      ];
      var summary = schedule.summary.copyWith(
        lastRunAt: now.toIso8601String(),
        updatedAt: now.toIso8601String(),
      );
      final updated = schedule.copyWith(summary: summary, runs: runs);
      if (targetGone || _shouldComplete(updated, now)) {
        summary = _completed(summary, now);
      } else if (!manual) {
        if (summary.status == ScheduleStatus.paused) {
          summary = summary.copyWith(nextRunAt: null);
        } else {
          var next = computeNextRunAt(
            summary.cadence,
            DateTime.parse(summary.nextRunAt ?? now.toIso8601String()),
          );
          while (!next.isAfter(now)) {
            next = computeNextRunAt(summary.cadence, next);
          }
          summary = summary.copyWith(nextRunAt: next.toIso8601String());
        }
      }
      return updated.copyWith(summary: summary);
    });
  }

  Future<void> _complete(String id, DateTime now) async {
    await _store.update(
      id,
      (schedule) =>
          schedule.copyWith(summary: _completed(schedule.summary, now)),
    );
  }

  ScheduleSummary _completed(ScheduleSummary summary, DateTime now) =>
      summary.copyWith(
        status: ScheduleStatus.completed,
        nextRunAt: null,
        pausedAt: null,
        updatedAt: now.toIso8601String(),
      );

  bool _shouldComplete(StoredSchedule schedule, DateTime now) {
    final summary = schedule.summary;
    final expiresAt = summary.expiresAt == null
        ? null
        : DateTime.tryParse(summary.expiresAt!);
    if (expiresAt != null && !expiresAt.isAfter(now)) {
      return true;
    }
    if (summary.maxRuns == null) return false;
    return schedule.runs
            .where((run) => run.status != ScheduleRunStatus.running)
            .length >=
        summary.maxRuns!;
  }

  Future<void> _recoverInterruptedRuns() async {
    final now = _now().toUtc();
    for (final schedule in await _store.list()) {
      final workspacesToArchive = <String>{};
      await _store.update(schedule.summary.id, (current) {
        var dirty = false;
        final runs = [
          for (final run in current.runs)
            if (run.status == ScheduleRunStatus.running)
              () {
                dirty = true;
                if (current.summary.target
                    case NewAgentScheduleTarget(config: final config)
                    when run.workspaceId != null &&
                        (run.agentId == null ||
                            (config.archiveOnFinish ?? true))) {
                  workspacesToArchive.add(run.workspaceId!);
                }
                return run.copyWith(
                  status: ScheduleRunStatus.failed,
                  endedAt: now.toIso8601String(),
                  error: 'Daemon restarted before the scheduled run completed',
                );
              }()
            else
              run,
        ];
        var summary = current.summary;
        if (summary.status == ScheduleStatus.active &&
            summary.nextRunAt != null &&
            !DateTime.parse(summary.nextRunAt!).isAfter(now)) {
          var next = computeNextRunAt(
            summary.cadence,
            DateTime.parse(summary.nextRunAt!),
          );
          while (!next.isAfter(now)) {
            next = computeNextRunAt(summary.cadence, next);
          }
          summary = summary.copyWith(nextRunAt: next.toIso8601String());
          dirty = true;
        }
        return dirty
            ? current.copyWith(
                summary: summary.copyWith(updatedAt: now.toIso8601String()),
                runs: runs,
              )
            : current;
      });
      for (final workspaceId in workspacesToArchive) {
        try {
          await _archiveWorkspace?.call(workspaceId);
        } on Object catch (error, stack) {
          _onError?.call(error, stack);
        }
      }
    }
  }

  Future<void> _sweepOrphanedSchedules() async {
    final exists = _targetAgentExists;
    if (exists == null) return;
    final now = _now().toUtc();
    for (final schedule in await _store.list()) {
      final target = schedule.summary.target;
      if (target is AgentScheduleTarget &&
          schedule.summary.status != ScheduleStatus.completed &&
          !exists(target.agentId)) {
        await _complete(schedule.summary.id, now);
      }
    }
  }
}

String _normalizePrompt(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) throw StateError('Schedule prompt is required');
  return trimmed;
}

String? _optionalName(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

ScheduleNewAgentConfig _patchConfig(
  ScheduleNewAgentConfig config,
  Map<String, Object?> patch,
) => ScheduleNewAgentConfig(
  provider: (patch['provider'] as String?)?.trim() ?? config.provider,
  cwd: (patch['cwd'] as String?)?.trim() ?? config.cwd,
  model: patch.containsKey('model') ? patch['model'] as String? : config.model,
  modeId: patch.containsKey('modeId')
      ? patch['modeId'] as String?
      : config.modeId,
  thinkingOptionId: patch.containsKey('thinkingOptionId')
      ? patch['thinkingOptionId'] as String?
      : config.thinkingOptionId,
  archiveOnFinish: patch['archiveOnFinish'] as bool? ?? config.archiveOnFinish,
  isolation: patch['isolation'] as String? ?? config.isolation,
  title: config.title,
  approvalPolicy: config.approvalPolicy,
  sandboxMode: config.sandboxMode,
  networkAccess: config.networkAccess,
  webSearch: config.webSearch,
  featureValues: config.featureValues,
  extra: config.extra,
  systemPrompt: config.systemPrompt,
  mcpServers: config.mcpServers,
);
