import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/schedules_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads and mutates schedules through native session messages', () async {
    final client = _FakeDaemonClient();
    final container = ProviderContainer(
      overrides: [
        daemonClientProvider.overrideWithValue(client),
        connectionStateProvider.overrideWithValue(
          const AsyncData(DaemonConnectionState.connected),
        ),
      ],
    );
    addTearDown(container.dispose);

    final loaded = await container.read(schedulesProvider.future);
    expect(loaded.single.id, 'deadbeef');
    expect(client.types, ['schedule/list']);

    await container.read(schedulesProvider.notifier).pause('deadbeef');
    expect(
      container.read(schedulesProvider).value!.single.status,
      ScheduleStatus.paused,
    );
    expect(client.types.last, 'schedule/pause');

    await container.read(schedulesProvider.notifier).delete('deadbeef');
    expect(container.read(schedulesProvider).value, isEmpty);
    expect(client.types.last, 'schedule/delete');

    await container.read(schedulesProvider.notifier).reload();
    await container.read(schedulesProvider.future);
    final notifier = container.read(schedulesProvider.notifier);
    await notifier.create(
      prompt: 'new',
      name: null,
      cadence: const CronScheduleCadence(expression: '0 9 * * *'),
      target: const NewAgentScheduleTarget(
        config: ScheduleNewAgentConfig(provider: 'codex', cwd: 'C:/repo'),
      ),
    );
    await notifier.updateSchedule('deadbeef', const {'prompt': 'updated'});
    await notifier.resume('deadbeef');
    await notifier.runOnce('deadbeef');
    expect(
      client.types,
      containsAll([
        'schedule/create',
        'schedule/update',
        'schedule/resume',
        'schedule/run-once',
      ]),
    );
  });

  test('surfaces schedule payload errors', () async {
    final client = _FakeDaemonClient()..error = 'load failed';
    final container = ProviderContainer(
      overrides: [
        daemonClientProvider.overrideWithValue(client),
        connectionStateProvider.overrideWithValue(
          const AsyncData(DaemonConnectionState.connected),
        ),
      ],
    );
    addTearDown(container.dispose);

    await expectLater(
      container.read(schedulesProvider.future),
      throwsStateError,
    );
  });
}

final class _FakeDaemonClient extends DaemonClient {
  _FakeDaemonClient() : super(uri: Uri.parse('ws://127.0.0.1:6868/ws'));

  final types = <String>[];
  String? error;

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final type = message['type']! as String;
    types.add(type);
    if (error != null) {
      return {
        'type': '$type/response',
        'payload': {'requestId': message['requestId'], 'error': error},
      };
    }
    final requestId = message['requestId'];
    if (type == 'schedule/list') {
      return {
        'type': 'schedule/list/response',
        'payload': {
          'requestId': requestId,
          'schedules': [_summary()],
          'error': null,
        },
      };
    }
    if (type == 'schedule/delete') {
      return {
        'type': 'schedule/delete/response',
        'payload': {
          'requestId': requestId,
          'scheduleId': message['scheduleId'],
          'error': null,
        },
      };
    }
    return {
      'type': '$type/response',
      'payload': {
        'requestId': requestId,
        'schedule': _summary(
          status: type == 'schedule/pause' ? 'paused' : 'active',
        ),
        'error': null,
      },
    };
  }
}

Map<String, Object?> _summary({String status = 'active'}) => {
  'id': 'deadbeef',
  'name': 'Review',
  'prompt': 'Review the branch',
  'cadence': {'type': 'cron', 'expression': '*/5 * * * *'},
  'target': {
    'type': 'new-agent',
    'config': {'provider': 'codex', 'cwd': 'C:/repo'},
  },
  'status': status,
  'createdAt': '2026-07-27T00:00:00.000Z',
  'updatedAt': '2026-07-27T00:00:00.000Z',
  'nextRunAt': '2026-07-27T00:05:00.000Z',
  'lastRunAt': null,
  'pausedAt': status == 'paused' ? '2026-07-27T00:01:00.000Z' : null,
  'expiresAt': null,
  'maxRuns': null,
};
