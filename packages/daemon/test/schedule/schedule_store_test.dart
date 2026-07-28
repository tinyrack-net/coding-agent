import 'dart:io';
import 'dart:math';

import 'package:agent_daemon/src/schedule/schedule_store.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

const _agentId = '11111111-1111-4111-8111-111111111111';

StoredSchedule _schedule(String createdAt, {String id = ''}) => StoredSchedule(
  summary: ScheduleSummary(
    id: id,
    name: 'Build',
    prompt: 'Run build',
    cadence: const EveryScheduleCadence(everyMs: 60000),
    target: const AgentScheduleTarget(agentId: _agentId),
    status: ScheduleStatus.active,
    createdAt: createdAt,
    updatedAt: createdAt,
    nextRunAt: createdAt,
    lastRunAt: null,
    pausedAt: null,
    expiresAt: null,
    maxRuns: null,
  ),
  runs: const [],
);

void main() {
  late Directory temp;
  late ScheduleStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('schedule_store_test_');
    store = ScheduleStore(temp.path, random: Random(7));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('creates eight-hex ids and persists sorted schedules', () async {
    final second = await store.create(_schedule('2026-01-02T00:00:00.000Z'));
    final first = await store.create(_schedule('2026-01-01T00:00:00.000Z'));

    expect(second.summary.id, matches(RegExp(r'^[0-9a-f]{8}$')));
    expect(first.summary.id, isNot(second.summary.id));
    expect((await store.list()).map((schedule) => schedule.summary.createdAt), [
      '2026-01-01T00:00:00.000Z',
      '2026-01-02T00:00:00.000Z',
    ]);
    expect((await store.get(first.summary.id))!.toJson(), first.toJson());
  });

  test('serializes concurrent updates and deletes idempotently', () async {
    final created = await store.create(_schedule('2026-01-01T00:00:00.000Z'));
    final updates = List.generate(
      10,
      (index) => store.update(created.summary.id, (schedule) async {
        await Future<void>.delayed(Duration(milliseconds: index % 2));
        return schedule.copyWith(
          summary: schedule.summary.copyWith(name: 'Build $index'),
        );
      }),
    );
    await Future.wait(updates);
    expect((await store.get(created.summary.id))!.summary.name, 'Build 9');

    await store.delete(created.summary.id);
    await store.delete(created.summary.id);
    expect(await store.get(created.summary.id), isNull);
  });

  test('rejects id mutation and malformed persisted data', () async {
    final created = await store.create(_schedule('2026-01-01T00:00:00.000Z'));
    await expectLater(
      store.update(
        created.summary.id,
        (_) => _schedule('2026-01-01T00:00:00.000Z', id: 'different'),
      ),
      throwsStateError,
    );
    File('${temp.path}/bad.json').writeAsStringSync('{}');
    await expectLater(store.list(), throwsFormatException);
  });
}
