import 'dart:async';
import 'dart:io';

import 'package:agent_daemon/src/schedule/schedule_service.dart';
import 'package:agent_daemon/src/schedule/schedule_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

const _agentId = '11111111-1111-4111-8111-111111111111';

ScheduleCreateRequest _request({
  ScheduleCadence cadence = const EveryScheduleCadence(everyMs: 60000),
  ScheduleTarget target = const AgentScheduleTarget(agentId: _agentId),
  int? maxRuns,
  bool? runOnCreate,
}) => ScheduleCreateRequest(
  requestId: 'request-1',
  name: ' Build ',
  prompt: ' Run tests ',
  cadence: cadence,
  target: target,
  maxRuns: maxRuns,
  runOnCreate: runOnCreate,
);

void main() {
  late Directory temp;
  late DateTime now;
  late List<StoredSchedule> executions;
  late ScheduleService service;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('schedule_service_test_');
    now = DateTime.utc(2026, 1, 1, 12);
    executions = [];
    service = ScheduleService(
      home: temp.path,
      now: () => now,
      runner: (schedule, runId) async {
        executions.add(schedule);
        return const ScheduleExecutionResult(agentId: _agentId, output: 'done');
      },
    );
  });

  tearDown(() {
    service.stop();
    temp.deleteSync(recursive: true);
  });

  test(
    'create trims fields and preserves Paseo run-on-create defaults',
    () async {
      final rolling = await service.create(_request());
      expect(rolling.summary.name, 'Build');
      expect(rolling.summary.prompt, 'Run tests');
      expect(rolling.summary.nextRunAt, now.toIso8601String());

      final cron = await service.create(
        _request(cadence: const CronScheduleCadence(expression: '15 * * * *')),
      );
      expect(
        cron.summary.nextRunAt,
        DateTime.utc(2026, 1, 1, 12, 15).toIso8601String(),
      );
      expect(await service.list(), hasLength(2));
    },
  );

  test('tick records a successful run and completes at maxRuns', () async {
    final created = await service.create(_request(maxRuns: 1));
    await service.tick();

    final finished = await service.inspect(created.summary.id);
    expect(executions, hasLength(1));
    expect(finished.summary.status, ScheduleStatus.completed);
    expect(finished.summary.nextRunAt, isNull);
    expect(finished.runs.single.status, ScheduleRunStatus.succeeded);
    expect(finished.runs.single.output, 'done');
    expect(finished.runs.single.agentId, _agentId);
  });

  test('pause, resume, update, logs, and delete preserve lifecycle', () async {
    final created = await service.create(_request(runOnCreate: false));
    final paused = await service.pause(created.summary.id);
    expect(paused.summary.status, ScheduleStatus.paused);
    expect(paused.summary.nextRunAt, isNull);
    expect(paused.summary.pausedAt, now.toIso8601String());

    now = now.add(const Duration(minutes: 10));
    final resumed = await service.resume(created.summary.id);
    expect(resumed.summary.status, ScheduleStatus.active);
    expect(resumed.summary.pausedAt, isNull);

    final updated = await service.update(
      ScheduleUpdateRequest.fromJson({
        'type': 'schedule/update',
        'requestId': 'update-1',
        'scheduleId': created.summary.id,
        'name': null,
        'prompt': 'New prompt',
        'cadence': {
          'type': 'cron',
          'expression': '0 9 * * *',
          'timezone': 'Asia/Seoul',
        },
        'maxRuns': 2,
      }),
    );
    expect(updated.summary.name, isNull);
    expect(updated.summary.prompt, 'New prompt');
    expect(updated.summary.maxRuns, 2);
    expect(updated.summary.cadence, isA<CronScheduleCadence>());
    expect(await service.logs(created.summary.id), isEmpty);

    await service.delete(created.summary.id);
    await expectLater(service.inspect(created.summary.id), throwsStateError);
  });

  test(
    'manual run does not advance cadence and target-gone completes',
    () async {
      final created = await service.create(_request(runOnCreate: false));
      final scheduled = created.summary.nextRunAt;
      final manual = await service.runOnce(created.summary.id);
      expect(manual.summary.nextRunAt, scheduled);
      expect(manual.runs.single.status, ScheduleRunStatus.succeeded);

      final goneService = ScheduleService(
        home: '${temp.path}/gone',
        now: () => now,
        runner: (_, __) async => throw ScheduleTargetGoneError('agent gone'),
      );
      final gone = await goneService.create(_request(maxRuns: 5));
      await goneService.tick();
      final failed = await goneService.inspect(gone.summary.id);
      expect(failed.summary.status, ScheduleStatus.completed);
      expect(failed.runs.single.status, ScheduleRunStatus.failed);
      goneService.stop();
    },
  );

  test('workspace identity survives a failed scheduled run', () async {
    late ScheduleService recordingService;
    recordingService = ScheduleService(
      home: '${temp.path}/workspace-record',
      now: () => now,
      runner: (schedule, runId) async {
        await recordingService.recordRunWorkspace(
          scheduleId: schedule.summary.id,
          runId: runId,
          workspaceId: 'wks_run',
          agentId: _agentId,
        );
        throw StateError('provider failed');
      },
    );
    final created = await recordingService.create(
      _request(runOnCreate: false),
    );
    final result = await recordingService.runOnce(created.summary.id);

    expect(result.runs.single.status, ScheduleRunStatus.failed);
    expect(result.runs.single.workspaceId, 'wks_run');
    expect(result.runs.single.agentId, _agentId);
    recordingService.stop();
  });

  test('agent archive completes every matching schedule', () async {
    final first = await service.create(_request(runOnCreate: false));
    final second = await service.create(_request(runOnCreate: false));
    expect(await service.listActiveAgentTargetIds(), {_agentId});

    expect(await service.completeForAgent(_agentId), 2);
    expect(
      (await service.inspect(first.summary.id)).summary.status,
      ScheduleStatus.completed,
    );
    expect(
      (await service.inspect(second.summary.id)).summary.status,
      ScheduleStatus.completed,
    );
    expect(await service.listActiveAgentTargetIds(), isEmpty);
    expect(await service.completeForAgent(_agentId), 0);
  });

  test('RPC handler emits exact response families and stable errors', () async {
    final create = await service.handle(_request().toJson());
    expect(create!['type'], 'schedule/create/response');
    final createPayload = create['payload']! as Map<String, Object?>;
    final schedule = ScheduleSummary.fromJson(createPayload['schedule']);

    final list = await service.handle(
      const ScheduleListRequest(requestId: 'list-1').toJson(),
    );
    expect(list!['type'], 'schedule/list/response');
    expect(
      ((list['payload']! as Map<String, Object?>)['schedules']! as List),
      hasLength(1),
    );

    final missing = await service.handle(
      ScheduleIdRequest(
        type: ScheduleIdRequest.inspectType,
        requestId: 'inspect-1',
        scheduleId: 'missing',
      ).toJson(),
    );
    expect(missing!['type'], 'schedule/inspect/response');
    expect((missing['payload']! as Map<String, Object?>)['schedule'], isNull);
    expect(
      (missing['payload']! as Map<String, Object?>)['error'],
      'Schedule not found: missing',
    );

    final deleted = await service.handle(
      ScheduleIdRequest(
        type: ScheduleIdRequest.deleteType,
        requestId: 'delete-1',
        scheduleId: schedule.id,
      ).toJson(),
    );
    expect((deleted!['payload']! as Map)['scheduleId'], schedule.id);
  });

  test('RPC handler covers update, inspect, logs, lifecycle, and run now', () async {
    final created = await service.create(_request(runOnCreate: false));
    final id = created.summary.id;

    final update = await service.handle({
      'type': 'schedule/update',
      'requestId': 'update',
      'scheduleId': id,
      'expiresAt': '2026-01-02T12:00:00.000Z',
    });
    expect(update!['type'], 'schedule/update/response');
    expect((update['payload']! as Map)['error'], isNull);

    for (final requestType in [
      ScheduleIdRequest.inspectType,
      ScheduleIdRequest.logsType,
      ScheduleIdRequest.pauseType,
      ScheduleIdRequest.resumeType,
      ScheduleIdRequest.runOnceType,
    ]) {
      final response = await service.handle(
        ScheduleIdRequest(
          type: requestType,
          requestId: requestType,
          scheduleId: id,
        ).toJson(),
      );
      expect(response!['type'], '$requestType/response');
      expect((response['payload']! as Map)['error'], isNull);
    }

    final malformedDelete = await service.handle({
      'type': ScheduleIdRequest.deleteType,
      'requestId': 'bad-delete',
      'scheduleId': 42,
    });
    expect((malformedDelete!['payload']! as Map)['scheduleId'], '');
    expect((malformedDelete['payload']! as Map)['error'], isNotNull);
  });

  test('new-agent updates preserve timezone and patch runtime config', () async {
    final created = await service.create(
      _request(
        runOnCreate: false,
        cadence: const CronScheduleCadence(
          expression: '0 9 * * *',
          timezone: 'Asia/Seoul',
        ),
        target: NewAgentScheduleTarget(
          config: ScheduleNewAgentConfig(
            provider: ' codex ',
            cwd: ' ${temp.path} ',
            model: 'old',
            modeId: 'default',
            thinkingOptionId: 'medium',
            archiveOnFinish: true,
            isolation: 'local',
            title: 'Title',
            hasTitle: true,
            approvalPolicy: 'on-request',
            sandboxMode: 'workspace-write',
            networkAccess: true,
            webSearch: false,
            featureValues: const {'feature': true},
            extra: const {'extra': true},
            systemPrompt: 'system',
            mcpServers: const {'server': <String, Object?>{}},
          ),
        ),
      ),
    );

    final updated = await service.update(
      ScheduleUpdateRequest.fromJson({
        'type': ScheduleUpdateRequest.type,
        'requestId': 'patch',
        'scheduleId': created.summary.id,
        'cadence': {'type': 'cron', 'expression': '30 10 * * *'},
        'expiresAt': '2026-02-01T00:00:00.000Z',
        'newAgentConfig': {
          'provider': ' claude-code ',
          'cwd': ' ${temp.path}/next ',
          'model': 'new',
          'modeId': 'plan',
          'thinkingOptionId': 'high',
          'archiveOnFinish': false,
          'isolation': 'worktree',
        },
      }),
    );
    final cadence = updated.summary.cadence as CronScheduleCadence;
    final config =
        (updated.summary.target as NewAgentScheduleTarget).config;
    expect(cadence.timezone, 'Asia/Seoul');
    expect(config.provider, 'claude-code');
    expect(config.cwd, '${temp.path}/next');
    expect(config.model, 'new');
    expect(config.modeId, 'plan');
    expect(config.thinkingOptionId, 'high');
    expect(config.archiveOnFinish, isFalse);
    expect(config.isolation, 'worktree');
    expect(config.title, 'Title');
    expect(config.approvalPolicy, 'on-request');
    expect(config.sandboxMode, 'workspace-write');
    expect(config.networkAccess, isTrue);
    expect(config.webSearch, isFalse);
    expect(config.featureValues, {'feature': true});
    expect(config.extra, {'extra': true});
    expect(config.systemPrompt, 'system');
    expect(config.mcpServers, {'server': <String, Object?>{}});

    await expectLater(
      service.update(
        ScheduleUpdateRequest.fromJson({
          'type': ScheduleUpdateRequest.type,
          'requestId': 'wrong-target',
          'scheduleId': (await service.create(_request())).summary.id,
          'newAgentConfig': {'provider': 'codex'},
        }),
      ),
      throwsStateError,
    );
  });

  test('missing, completed, running, and expired guards are stable', () async {
    await expectLater(
      service.recordRunWorkspace(
        scheduleId: 'missing',
        runId: 'run',
        workspaceId: 'workspace',
        agentId: null,
      ),
      throwsStateError,
    );
    await expectLater(service.pause('missing'), throwsStateError);
    await expectLater(service.resume('missing'), throwsStateError);
    await expectLater(
      service.update(
        ScheduleUpdateRequest.fromJson({
          'type': ScheduleUpdateRequest.type,
          'requestId': 'missing',
          'scheduleId': 'missing',
          'prompt': 'updated',
        }),
      ),
      throwsStateError,
    );

    final completed = await service.create(_request(maxRuns: 1));
    await service.tick();
    await expectLater(service.pause(completed.summary.id), throwsStateError);
    await expectLater(service.resume(completed.summary.id), throwsStateError);
    await expectLater(service.runOnce(completed.summary.id), throwsStateError);

    final gate = Completer<void>();
    final started = Completer<void>();
    final runningService = ScheduleService(
      home: '${temp.path}/running',
      now: () => now,
      runner: (_, __) async {
        started.complete();
        await gate.future;
        return const ScheduleExecutionResult(agentId: null, output: null);
      },
    );
    final running = await runningService.create(
      _request(runOnCreate: false),
    );
    final firstRun = runningService.runOnce(running.summary.id);
    await started.future;
    await expectLater(
      runningService.runOnce(running.summary.id),
      throwsStateError,
    );
    gate.complete();
    await firstRun;
    runningService.stop();

    final expiring = await service.create(_request(runOnCreate: false));
    await service.update(
      ScheduleUpdateRequest.fromJson({
        'type': ScheduleUpdateRequest.type,
        'requestId': 'expires',
        'scheduleId': expiring.summary.id,
        'expiresAt': now.subtract(const Duration(seconds: 1)).toIso8601String(),
      }),
    );
    await service.tick();
    expect(
      (await service.inspect(expiring.summary.id)).summary.status,
      ScheduleStatus.completed,
    );
  });

  test(
    'startup recovers interrupted runs and advances stale cadence',
    () async {
      final store = ScheduleStore('${temp.path}/recover/schedules');
      final stale = StoredSchedule(
        summary: ScheduleSummary(
          id: '',
          name: 'Recover',
          prompt: 'resume',
          cadence: const EveryScheduleCadence(everyMs: 60000),
          target: const AgentScheduleTarget(agentId: _agentId),
          status: ScheduleStatus.active,
          createdAt: '2026-01-01T11:00:00.000Z',
          updatedAt: '2026-01-01T11:00:00.000Z',
          nextRunAt: '2026-01-01T11:01:00.000Z',
          lastRunAt: null,
          pausedAt: null,
          expiresAt: null,
          maxRuns: null,
        ),
        runs: const [
          ScheduleRun(
            id: 'run',
            scheduledFor: '2026-01-01T11:00:00.000Z',
            startedAt: '2026-01-01T11:00:00.000Z',
            endedAt: null,
            status: ScheduleRunStatus.running,
            agentId: null,
            workspaceId: null,
            output: null,
            error: null,
          ),
        ],
      );
      final persisted = await store.create(stale);
      final recovering = ScheduleService(
        home: '${temp.path}/recover',
        store: store,
        now: () => now,
        runner: (_, __) async =>
            const ScheduleExecutionResult(agentId: null, output: null),
      );
      await recovering.start();
      final recovered = await recovering.inspect(persisted.summary.id);
      expect(recovered.runs.single.status, ScheduleRunStatus.failed);
      expect(
        recovered.runs.single.error,
        'Daemon restarted before the scheduled run completed',
      );
      expect(DateTime.parse(recovered.summary.nextRunAt!).isAfter(now), isTrue);
      recovering.stop();
    },
  );

  test('startup archives interrupted new-agent run workspaces', () async {
    final store = ScheduleStore('${temp.path}/recover-workspace/schedules');
    final persisted = await store.create(
      StoredSchedule(
        summary: ScheduleSummary(
          id: '',
          name: null,
          prompt: 'resume',
          cadence: const EveryScheduleCadence(everyMs: 60000),
          target: NewAgentScheduleTarget(
            config: ScheduleNewAgentConfig(
              provider: 'codex',
              cwd: temp.path,
              archiveOnFinish: true,
            ),
          ),
          status: ScheduleStatus.active,
          createdAt: '2026-01-01T11:00:00.000Z',
          updatedAt: '2026-01-01T11:00:00.000Z',
          nextRunAt: '2026-01-01T13:00:00.000Z',
          lastRunAt: null,
          pausedAt: null,
          expiresAt: null,
          maxRuns: null,
        ),
        runs: const [
          ScheduleRun(
            id: 'run',
            scheduledFor: '2026-01-01T11:00:00.000Z',
            startedAt: '2026-01-01T11:00:00.000Z',
            endedAt: null,
            status: ScheduleRunStatus.running,
            agentId: _agentId,
            workspaceId: 'wks_interrupted',
            output: null,
            error: null,
          ),
        ],
      ),
    );
    final archived = <String>[];
    final recovering = ScheduleService(
      home: '${temp.path}/recover-workspace',
      store: store,
      now: () => now,
      archiveWorkspace: (id) async => archived.add(id),
      runner: (_, __) async =>
          const ScheduleExecutionResult(agentId: null, output: null),
    );

    await recovering.start();
    expect(archived, ['wks_interrupted']);
    expect(
      (await recovering.inspect(persisted.summary.id)).runs.single.status,
      ScheduleRunStatus.failed,
    );
    recovering.stop();
  });

  test('startup completes orphaned existing-agent schedules', () async {
    final orphanService = ScheduleService(
      home: '${temp.path}/orphan',
      now: () => now,
      targetAgentExists: (_) => false,
      runner: (_, __) async =>
          const ScheduleExecutionResult(agentId: null, output: null),
    );
    final created = await orphanService.create(
      _request(runOnCreate: false),
    );

    await orphanService.start();
    expect(
      (await orphanService.inspect(created.summary.id)).summary.status,
      ScheduleStatus.completed,
    );
    orphanService.stop();
  });
}
