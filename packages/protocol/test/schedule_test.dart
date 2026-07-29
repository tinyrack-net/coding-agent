import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

const _agentId = '11111111-1111-4111-8111-111111111111';

void main() {
  group('cron expression parser', () {
    test('matches structurally valid expressions', () {
      final cron = parseCronExpression('*/5 9-17 * 1,6 1-5');
      expect(cron.minute.matches(10), isTrue);
      expect(cron.minute.matches(11), isFalse);
      expect(cron.hour.matches(12), isTrue);
      expect(cron.hour.matches(18), isFalse);
      expect(cron.month.matches(6), isTrue);
      expect(cron.dayOfWeek.matches(0), isFalse);
    });

    test('reports frozen server-facing invalid expression copy', () {
      expect(
        validateCronExpression('* * *'),
        'Cron expressions must have 5 fields',
      );
      expect(
        validateCronExpression('*/5/2 * * * *'),
        'Invalid cron minute step',
      );
      expect(validateCronExpression('60 * * * *'), 'Invalid cron minute value');
      expect(validateCronExpression('* 24 * * *'), 'Invalid cron hour value');
      expect(
        validateCronExpression('* * 31-1 * *'),
        'Invalid cron day-of-month range',
      );
      expect(validateCronExpression('* * * */0 *'), 'Invalid cron month step');
      expect(
        validateCronExpression('* * * * mon'),
        'Invalid cron day-of-week value',
      );
    });
  });

  test('rolling intervals convert only when five-field cron is exact', () {
    expect(everyMsToFiveFieldCron(60000), '*/1 * * * *');
    expect(everyMsToFiveFieldCron(15 * 60000), '*/15 * * * *');
    expect(everyMsToFiveFieldCron(60 * 60000), '0 * * * *');
    expect(everyMsToFiveFieldCron(6 * 60 * 60000), '0 */6 * * *');
    expect(everyMsToFiveFieldCron(24 * 60 * 60000), '0 0 * * *');
    for (final value in [30000, 7 * 60000, 5 * 60 * 60000, 48 * 60 * 60000]) {
      expect(everyMsToFiveFieldCron(value), isNull);
    }
  });

  test('create request round-trips new-agent run options', () {
    final request = ScheduleCreateRequest.fromJson({
      'type': 'schedule/create',
      'requestId': 'request-1',
      'prompt': 'Run the task',
      'cadence': {'type': 'every', 'everyMs': 60000},
      'target': {
        'type': 'new-agent',
        'config': {
          'provider': 'claude',
          'cwd': '/tmp/project',
          'thinkingOptionId': 'think-hard',
          'archiveOnFinish': false,
          'isolation': 'worktree',
        },
      },
    });

    expect(request.toJson(), {
      'type': 'schedule/create',
      'requestId': 'request-1',
      'prompt': 'Run the task',
      'cadence': {'type': 'every', 'everyMs': 60000},
      'target': {
        'type': 'new-agent',
        'config': {
          'provider': 'claude',
          'cwd': '/tmp/project',
          'thinkingOptionId': 'think-hard',
          'archiveOnFinish': false,
          'isolation': 'worktree',
        },
      },
    });
  });

  test(
    'wire parsing preserves untrimmed prompts and explicit nullable title',
    () {
      final request = ScheduleCreateRequest.fromJson({
        'type': 'schedule/create',
        'requestId': 'request-2',
        'prompt': '  preserve this prompt  ',
        'cadence': {'type': 'every', 'everyMs': 60000},
        'target': {
          'type': 'new-agent',
          'config': {'provider': ' codex ', 'cwd': ' C:/repo ', 'title': null},
        },
      });

      expect(request.prompt, '  preserve this prompt  ');
      expect(request.toJson()['prompt'], '  preserve this prompt  ');
      final target = request.toJson()['target']! as Map<String, Object?>;
      final config = target['config']! as Map<String, Object?>;
      expect(config, containsPair('provider', ' codex '));
      expect(config, containsPair('cwd', 'C:/repo'));
      expect(config, containsPair('title', null));
    },
  );

  test(
    'stored schedule accepts opaque date strings like the frozen schema',
    () {
      final schedule = StoredSchedule.fromJson({
        'id': 'opaque',
        'name': null,
        'prompt': ' ',
        'cadence': {'type': 'every', 'everyMs': 1},
        'target': {'type': 'agent', 'agentId': _agentId},
        'status': 'active',
        'createdAt': 'not-an-iso-date',
        'updatedAt': '',
        'nextRunAt': null,
        'lastRunAt': null,
        'pausedAt': null,
        'expiresAt': 'opaque-expiry',
        'maxRuns': null,
        'runs': const [],
      });

      expect(schedule.summary.prompt, ' ');
      expect(schedule.summary.createdAt, 'not-an-iso-date');
      expect(schedule.summary.expiresAt, 'opaque-expiry');
    },
  );

  test('stored schedule and run preserve the frozen wire shape', () {
    final schedule = StoredSchedule.fromJson({
      'id': 'deadbeef',
      'name': 'Daily review',
      'prompt': 'Review main',
      'cadence': {
        'type': 'cron',
        'expression': '0 9 * * 1-5',
        'timezone': 'Asia/Seoul',
      },
      'target': {'type': 'agent', 'agentId': _agentId},
      'status': 'active',
      'createdAt': '2026-07-27T00:00:00.000Z',
      'updatedAt': '2026-07-27T00:01:00.000Z',
      'nextRunAt': '2026-07-28T00:00:00.000Z',
      'lastRunAt': null,
      'pausedAt': null,
      'expiresAt': null,
      'maxRuns': 5,
      'runs': [
        {
          'id': 'run-1',
          'scheduledFor': '2026-07-27T00:00:00.000Z',
          'startedAt': '2026-07-27T00:00:00.000Z',
          'endedAt': '2026-07-27T00:01:00.000Z',
          'status': 'succeeded',
          'agentId': _agentId,
          'workspaceId': 'ws-1',
          'output': 'done',
          'error': null,
        },
      ],
    });

    expect(schedule.toJson()['runs'], hasLength(1));
    expect(schedule.summary.status, ScheduleStatus.active);
    expect(schedule.runs.single.status, ScheduleRunStatus.succeeded);
    expect(schedule.toJson()['target'], {'type': 'agent', 'agentId': _agentId});
  });

  test('schedule request boundaries reject invalid values', () {
    expect(
      () => ScheduleCreateRequest.fromJson({
        'type': 'schedule/create',
        'requestId': 'r',
        'prompt': '',
        'cadence': {'type': 'every', 'everyMs': 0},
        'target': {'type': 'agent', 'agentId': 'bad'},
      }),
      throwsFormatException,
    );
    expect(
      () => ScheduleIdRequest.fromJson({
        'type': 'schedule/unknown',
        'requestId': 'r',
        'scheduleId': 's',
      }),
      throwsFormatException,
    );
  });

  test('schedule contract covers every lifecycle and update variant', () {
    expect(
      ['active', 'paused', 'completed'].map(ScheduleStatus.fromWire),
      ScheduleStatus.values,
    );
    expect(
      ['running', 'succeeded', 'failed'].map(ScheduleRunStatus.fromWire),
      ScheduleRunStatus.values,
    );
    expect(() => ScheduleStatus.fromWire('future'), throwsFormatException);
    expect(() => ScheduleRunStatus.fromWire('future'), throwsFormatException);
    expect(
      ScheduleCadence.fromJson({'type': 'every', 'everyMs': 10}).toJson(),
      {'type': 'every', 'everyMs': 10},
    );
    expect(
      ScheduleCadence.fromJson({
        'type': 'cron',
        'expression': ' 0 9 * * * ',
        'timezone': ' Asia/Seoul ',
      }).toJson(),
      {'type': 'cron', 'expression': '0 9 * * *', 'timezone': 'Asia/Seoul'},
    );
    expect(
      () => ScheduleCadence.fromJson({'type': 'future'}),
      throwsFormatException,
    );

    final config = ScheduleNewAgentConfig.fromJson({
      'provider': ' codex ',
      'cwd': ' C:/repo ',
      'modeId': ' auto ',
      'model': ' gpt-5.4 ',
      'thinkingOptionId': ' high ',
      'archiveOnFinish': false,
      'isolation': 'worktree',
      'title': ' Nightly ',
      'approvalPolicy': ' never ',
      'sandboxMode': ' workspace-write ',
      'networkAccess': true,
      'webSearch': false,
      'featureValues': {'fast': true},
      'extra': {
        'codex': {'reasoning': 'high'},
      },
      'systemPrompt': '',
      'mcpServers': {
        'local': {'command': 'server'},
      },
    });
    expect(config.toJson(), {
      'provider': ' codex ',
      'cwd': 'C:/repo',
      'modeId': 'auto',
      'model': 'gpt-5.4',
      'thinkingOptionId': 'high',
      'archiveOnFinish': false,
      'isolation': 'worktree',
      'title': 'Nightly',
      'approvalPolicy': 'never',
      'sandboxMode': 'workspace-write',
      'networkAccess': true,
      'webSearch': false,
      'featureValues': {'fast': true},
      'extra': {
        'codex': {'reasoning': 'high'},
      },
      'systemPrompt': '',
      'mcpServers': {
        'local': {'command': 'server'},
      },
    });
    expect(
      () => ScheduleNewAgentConfig.fromJson({
        'provider': 'codex',
        'cwd': 'C:/repo',
        'isolation': 'container',
      }),
      throwsFormatException,
    );

    final self = ScheduleTarget.fromJson({
      'type': 'self',
      'agentId': _agentId,
    }, allowSelf: true);
    expect(self.toJson(), {'type': 'self', 'agentId': _agentId});
    expect(
      ScheduleTarget.fromJson({'type': 'agent', 'agentId': _agentId}).toJson(),
      {'type': 'agent', 'agentId': _agentId},
    );
    expect(
      () => ScheduleTarget.fromJson({'type': 'self', 'agentId': _agentId}),
      throwsFormatException,
    );

    const run = ScheduleRun(
      id: 'run',
      scheduledFor: 'scheduled',
      startedAt: 'started',
      endedAt: null,
      status: ScheduleRunStatus.running,
      agentId: null,
      workspaceId: null,
      output: null,
      error: null,
    );
    final completedRun = run.copyWith(
      endedAt: 'ended',
      status: ScheduleRunStatus.succeeded,
      agentId: _agentId,
      workspaceId: 'workspace',
      output: 'done',
      error: 'none',
    );
    expect(completedRun.toJson(), {
      'id': 'run',
      'scheduledFor': 'scheduled',
      'startedAt': 'started',
      'endedAt': 'ended',
      'status': 'succeeded',
      'agentId': _agentId,
      'workspaceId': 'workspace',
      'output': 'done',
      'error': 'none',
    });
    expect(
      completedRun
          .copyWith(
            endedAt: null,
            agentId: null,
            workspaceId: null,
            output: null,
            error: null,
          )
          .toJson(),
      isNot(contains('workspaceId')),
    );

    final summary = ScheduleSummary(
      id: 'schedule',
      name: 'name',
      prompt: 'prompt',
      cadence: const EveryScheduleCadence(everyMs: 1),
      target: const AgentScheduleTarget(agentId: _agentId),
      status: ScheduleStatus.active,
      createdAt: 'created',
      updatedAt: 'updated',
      nextRunAt: 'next',
      lastRunAt: 'last',
      pausedAt: 'paused',
      expiresAt: 'expires',
      maxRuns: 2,
    );
    final copied = summary.copyWith(
      name: null,
      prompt: 'new prompt',
      cadence: const CronScheduleCadence(expression: '* * * * *'),
      target: const SelfScheduleTarget(agentId: _agentId),
      status: ScheduleStatus.paused,
      updatedAt: 'new updated',
      nextRunAt: null,
      lastRunAt: null,
      pausedAt: null,
      expiresAt: null,
      maxRuns: null,
    );
    expect(copied.name, isNull);
    expect(copied.status, ScheduleStatus.paused);
    expect(copied.nextRunAt, isNull);
    expect(
      StoredSchedule(
        summary: summary,
        runs: const [run],
      ).copyWith(summary: copied, runs: const []).runs,
      isEmpty,
    );

    for (final type in ScheduleIdRequest.supportedTypes) {
      final request = ScheduleIdRequest.fromJson({
        'type': type,
        'requestId': 'request',
        'scheduleId': 'schedule',
      });
      expect(request.toJson()['type'], type);
    }
    expect(
      ScheduleListRequest.fromJson({
        'type': 'schedule/list',
        'requestId': 'list',
      }).toJson(),
      {'type': 'schedule/list', 'requestId': 'list'},
    );

    final update = ScheduleUpdateRequest.fromJson({
      'type': 'schedule/update',
      'requestId': 'update',
      'scheduleId': 'schedule',
      'name': null,
      'prompt': 'next',
      'cadence': {'type': 'every', 'everyMs': 5},
      'newAgentConfig': {
        'provider': ' codex ',
        'cwd': ' C:/next ',
        'model': null,
        'modeId': ' auto ',
        'thinkingOptionId': ' high ',
        'archiveOnFinish': true,
        'isolation': 'local',
      },
      'maxRuns': null,
      'expiresAt': null,
      'ignored': true,
    });
    expect(update.toJson(), isNot(contains('ignored')));
    expect(update.toJson()['name'], isNull);
    expect(update.toJson()['newAgentConfig'], {
      'provider': 'codex',
      'cwd': 'C:/next',
      'model': null,
      'modeId': 'auto',
      'thinkingOptionId': 'high',
      'archiveOnFinish': true,
      'isolation': 'local',
    });
    expect(
      scheduleResponse(
        requestType: 'schedule/list',
        requestId: 'request',
        payload: const {'schedules': []},
      ),
      {
        'type': 'schedule/list/response',
        'payload': {'requestId': 'request', 'schedules': []},
      },
    );
  });

  test('schedule schemas enforce frozen optional and nullable boundaries', () {
    expect(
      () => ScheduleCadence.fromJson({
        'type': 'cron',
        'expression': '* * * * *',
        'timezone': null,
      }),
      throwsFormatException,
    );

    const optionalConfigFields = [
      'modeId',
      'model',
      'thinkingOptionId',
      'archiveOnFinish',
      'isolation',
      'approvalPolicy',
      'sandboxMode',
      'networkAccess',
      'webSearch',
      'featureValues',
      'extra',
      'systemPrompt',
      'mcpServers',
    ];
    for (final field in optionalConfigFields) {
      expect(
        () => ScheduleNewAgentConfig.fromJson({
          'provider': 'codex',
          'cwd': 'C:/repo',
          field: null,
        }),
        throwsFormatException,
        reason: '$field is optional but not nullable',
      );
    }
    expect(
      ScheduleNewAgentConfig.fromJson({
        'provider': '',
        'cwd': 'C:/repo',
        'extra': {
          'codex': {'reasoning': 'high'},
          'unknown': {'removed': true},
        },
      }).toJson(),
      {
        'provider': '',
        'cwd': 'C:/repo',
        'extra': {
          'codex': {'reasoning': 'high'},
        },
      },
    );

    for (final field in ['name', 'maxRuns', 'expiresAt', 'runOnCreate']) {
      expect(
        () => ScheduleCreateRequest.fromJson({
          'type': 'schedule/create',
          'requestId': 'request',
          'prompt': 'prompt',
          'cadence': {'type': 'every', 'everyMs': 1},
          'target': {'type': 'agent', 'agentId': _agentId},
          field: null,
        }),
        throwsFormatException,
        reason: '$field is optional but not nullable',
      );
    }
    expect(
      () => ScheduleUpdateRequest.fromJson({
        'type': 'schedule/update',
        'requestId': 'request',
        'scheduleId': 'schedule',
        'newAgentConfig': {'archiveOnFinish': null},
      }),
      throwsFormatException,
    );
    for (final field in ['prompt', 'cadence', 'newAgentConfig']) {
      expect(
        () => ScheduleUpdateRequest.fromJson({
          'type': 'schedule/update',
          'requestId': 'request',
          'scheduleId': 'schedule',
          field: null,
        }),
        throwsFormatException,
        reason: '$field is optional but not nullable',
      );
    }

    final summary = _summaryJson();
    for (final field in [
      'name',
      'nextRunAt',
      'lastRunAt',
      'pausedAt',
      'expiresAt',
      'maxRuns',
    ]) {
      expect(
        () => ScheduleSummary.fromJson({...summary}..remove(field)),
        throwsFormatException,
        reason: '$field is required and nullable',
      );
    }
    final run = _runJson();
    for (final field in ['endedAt', 'agentId', 'output', 'error']) {
      expect(
        () => ScheduleRun.fromJson({...run}..remove(field)),
        throwsFormatException,
        reason: '$field is required and nullable',
      );
    }
    expect(
      ScheduleRun.fromJson(run).toJson(),
      containsPair('workspaceId', null),
    );
    expect(
      ScheduleRun.fromJson({...run}..remove('workspaceId')).toJson(),
      isNot(contains('workspaceId')),
    );
  });

  test(
    'every frozen schedule response has a typed strict payload contract',
    () {
      final summary = _summaryJson();
      final stored = {
        ...summary,
        'runs': [_runJson()],
      };
      final run = _runJson();
      final responses = <Map<String, Object?>>[
        _responseJson('create', schedule: summary),
        {
          'type': 'schedule/list/response',
          'payload': {
            'requestId': 'list',
            'schedules': [summary],
            'error': null,
          },
        },
        _responseJson('inspect', schedule: stored),
        {
          'type': 'schedule/logs/response',
          'payload': {
            'requestId': 'logs',
            'runs': [run],
            'error': null,
          },
        },
        _responseJson('pause', schedule: summary),
        _responseJson('resume', schedule: null, error: 'not found'),
        {
          'type': 'schedule/delete/response',
          'payload': {
            'requestId': 'delete',
            'scheduleId': 'schedule',
            'error': null,
          },
        },
        _responseJson('run-once', schedule: stored),
        _responseJson('update', schedule: null, error: 'failed'),
      ];

      for (final responseJson in responses) {
        final response = ScheduleRpcResponse.fromJson(responseJson);
        expect(
          response.toJson(),
          responseJson,
          reason: responseJson['type']! as String,
        );
      }
      expect(
        ScheduleRpcResponse.fromJson(responses.first),
        isA<ScheduleCreateResponse>(),
      );
      expect(
        ScheduleRpcResponse.fromJson(responses.last),
        isA<ScheduleUpdateResponse>(),
      );
      for (final responseJson in responses) {
        final malformed = Map<String, Object?>.from(responseJson);
        malformed['payload'] = Map<String, Object?>.from(
          responseJson['payload']! as Map,
        )..remove('error');
        expect(
          () => ScheduleRpcResponse.fromJson(malformed),
          throwsFormatException,
          reason: '${responseJson['type']} requires payload.error',
        );
      }
      expect(
        () => ScheduleRpcResponse.fromJson({
          'type': 'schedule/future/response',
          'payload': const {},
        }),
        throwsFormatException,
      );
    },
  );
}

Map<String, Object?> _summaryJson() => {
  'id': 'schedule',
  'name': null,
  'prompt': 'prompt',
  'cadence': {'type': 'every', 'everyMs': 60000},
  'target': {'type': 'agent', 'agentId': _agentId},
  'status': 'active',
  'createdAt': 'created',
  'updatedAt': 'updated',
  'nextRunAt': null,
  'lastRunAt': null,
  'pausedAt': null,
  'expiresAt': null,
  'maxRuns': null,
};

Map<String, Object?> _runJson() => {
  'id': 'run',
  'scheduledFor': 'scheduled',
  'startedAt': 'started',
  'endedAt': null,
  'status': 'running',
  'agentId': null,
  'workspaceId': null,
  'output': null,
  'error': null,
};

Map<String, Object?> _responseJson(
  String operation, {
  required Object? schedule,
  String? error,
}) => {
  'type': 'schedule/$operation/response',
  'payload': {'requestId': operation, 'schedule': schedule, 'error': error},
};
