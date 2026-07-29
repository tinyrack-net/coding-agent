import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/state/schedule_row_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.parse('2026-07-29T12:00:00.000Z');

  test('title and product copy follow the frozen fallback order', () {
    expect(
      resolveScheduleTitle(
        _schedule(name: ' Named ', prompt: 'Prompt', configTitle: 'Config'),
      ),
      'Named',
    );
    expect(
      resolveScheduleTitle(
        _schedule(name: ' ', prompt: 'Prompt', configTitle: ' Config '),
      ),
      'Config',
    );
    expect(
      resolveScheduleTitle(
        _schedule(name: null, prompt: '\n  First line  \nSecond'),
      ),
      'First line',
    );
    expect(
      resolveScheduleTitle(_schedule(name: null, prompt: '  ')),
      'Untitled schedule',
    );

    final heartbeat = _schedule(
      name: null,
      prompt: '  ',
      target: const AgentScheduleTarget(
        agentId: '11111111-1111-4111-8111-111111111111',
      ),
    );
    expect(scheduleProductName(heartbeat), 'Heartbeat');
    expect(resolveScheduleTitle(heartbeat), 'Untitled heartbeat');
  });

  test('cadence labels match frozen rolling and cron descriptions', () {
    expect(
      formatScheduleCadence(
        const EveryScheduleCadence(everyMs: Duration.millisecondsPerMinute),
      ),
      'Every 1 minute',
    );
    expect(
      formatScheduleCadence(
        const EveryScheduleCadence(everyMs: 3 * Duration.millisecondsPerHour),
      ),
      'Every 3 hours',
    );
    expect(
      formatScheduleCadence(
        const CronScheduleCadence(
          expression: '30 8 * * 1-5',
          timezone: 'Asia/Seoul',
        ),
      ),
      'Weekdays at 08:30 Asia/Seoul',
    );
    expect(
      formatScheduleCadence(
        const CronScheduleCadence(expression: '*/5 * * * *'),
      ),
      '*/5 * * * *',
    );
  });

  test('relative history and next-run copy use frozen boundaries', () {
    expect(
      formatScheduleTimeAgo('2026-07-29T11:59:55.000Z', now: now),
      'just now',
    );
    expect(
      formatScheduleTimeAgo('2026-07-29T11:59:30.000Z', now: now),
      '30s ago',
    );
    expect(
      formatScheduleTimeAgo('2026-07-29T09:00:00.000Z', now: now),
      '3h ago',
    );
    expect(
      formatScheduleTimeAgo('2026-07-20T12:00:00.000Z', now: now),
      'Jul 20',
    );
    expect(formatScheduleNextRun('2026-07-29T12:00:30.000Z', now: now), 'soon');
    expect(
      formatScheduleNextRun('2026-07-29T15:00:00.000Z', now: now),
      'in 3h',
    );
  });

  test('meta reads identity, history, then active future', () {
    final schedule = _schedule(
      name: 'Daily check',
      prompt: 'Prompt',
      createdAt: '2026-07-29T10:00:00.000Z',
      lastRunAt: '2026-07-29T11:30:00.000Z',
      nextRunAt: '2026-07-29T15:00:00.000Z',
    );
    expect(
      buildScheduleRowMeta(
        schedule,
        active: true,
        serverName: 'Remote',
        singleHost: false,
        now: now,
      ),
      'Remote · Every hour · Created 2h ago · Last run 30m ago · Next run in 3h',
    );
    expect(
      buildScheduleRowMeta(
        schedule,
        active: false,
        serverName: 'Remote',
        singleHost: true,
        now: now,
      ),
      'Every hour · Created 2h ago · Last run 30m ago',
    );
  });
}

ScheduleSummary _schedule({
  required String? name,
  required String prompt,
  String? configTitle,
  ScheduleTarget? target,
  String createdAt = '2026-07-29T10:00:00.000Z',
  String? lastRunAt,
  String? nextRunAt,
}) => ScheduleSummary(
  id: 'schedule',
  name: name,
  prompt: prompt,
  cadence: const CronScheduleCadence(expression: '0 * * * *'),
  target:
      target ??
      NewAgentScheduleTarget(
        config: ScheduleNewAgentConfig(
          provider: 'codex',
          cwd: r'C:\repo',
          title: configTitle,
        ),
      ),
  status: ScheduleStatus.active,
  createdAt: createdAt,
  updatedAt: createdAt,
  nextRunAt: nextRunAt,
  lastRunAt: lastRunAt,
  pausedAt: null,
  expiresAt: null,
  maxRuns: null,
);
