import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/state/schedules_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'batch merges hosts concurrently and retains partial failures',
    () async {
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final release = Completer<void>();
      final first = _ScheduleClient(
        'first',
        started: firstStarted,
        release: release,
      );
      final second = _ScheduleClient(
        'second',
        started: secondStarted,
        release: release,
      );

      final pending = fetchSchedulesBatch([
        ScheduleHost(serverId: 'b', serverName: 'Beta', client: second),
        ScheduleHost(serverId: 'a', serverName: 'Alpha', client: first),
      ]);
      await Future.wait([firstStarted.future, secondStarted.future]);
      release.complete();

      final merged = await pending;
      expect(merged.schedules.map((entry) => entry.serverId), ['a', 'b']);
      expect(merged.hostErrors, isEmpty);

      second.listError = StateError('offline');
      final partial = await fetchSchedulesBatch([
        ScheduleHost(serverId: 'a', serverName: 'Alpha', client: first),
        ScheduleHost(serverId: 'b', serverName: 'Beta', client: second),
      ]);
      expect(partial.schedules.single.serverId, 'a');
      expect(partial.hostErrors.single.serverId, 'b');
      expect(partial.hostErrors.single.message, contains('offline'));
    },
  );

  test('batch reports settling state and exact all-host failure', () async {
    final settling = await fetchSchedulesBatch(const [], connecting: true);
    expect(settling.connecting, isTrue);
    expect(settling.schedules, isEmpty);

    await expectLater(
      fetchSchedulesBatch([
        ScheduleHost(
          serverId: 'a',
          serverName: 'Alpha',
          client: _ScheduleClient('first')..listError = StateError('offline'),
        ),
      ]),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allScheduleHostsFailedMessage,
        ),
      ),
    );
  });

  test('mutations route by host and expose optimistic state', () async {
    final first = _ScheduleClient('first');
    final second = _ScheduleClient('second');
    final container = _container(first, second);
    addTearDown(container.dispose);
    await container.read(aggregatedSchedulesProvider.future);

    first.mutationGate = Completer<void>();
    final pause = container
        .read(aggregatedSchedulesProvider.notifier)
        .pause('a', 'first');
    await first.mutationStarted!.future;
    expect(_entry(container, 'a').schedule.status, ScheduleStatus.paused);
    expect(_entry(container, 'b').schedule.status, ScheduleStatus.active);
    first.mutationGate!.complete();
    await pause;
    expect(first.types, contains('schedule/pause'));
    expect(second.types, isNot(contains('schedule/pause')));

    first.mutationGate = null;
    final notifier = container.read(aggregatedSchedulesProvider.notifier);
    await notifier.resume('a', 'first');
    await notifier.updateSchedule('a', 'first', const {'prompt': 'updated'});
    await notifier.runOnce('a', 'first');
    await notifier.create(
      'a',
      prompt: 'new',
      name: null,
      cadence: const CronScheduleCadence(expression: '0 9 * * *'),
      target: const NewAgentScheduleTarget(
        config: ScheduleNewAgentConfig(provider: 'codex', cwd: 'C:/repo'),
      ),
    );
    expect(
      first.types,
      containsAll([
        'schedule/resume',
        'schedule/update',
        'schedule/run-once',
        'schedule/create',
      ]),
    );
    expect(second.types, isNot(contains('schedule/create')));

    first.mutationGate = Completer<void>();
    final deletion = container
        .read(aggregatedSchedulesProvider.notifier)
        .delete('a', 'first');
    await first.mutationStarted!.future;
    expect(
      container
          .read(aggregatedSchedulesProvider)
          .requireValue
          .schedules
          .map((entry) => entry.serverId),
      ['b'],
    );
    first.mutationGate!.complete();
    await deletion;
    expect(first.types, contains('schedule/delete'));
  });

  test(
    'failed optimistic mutation rolls back without losing other hosts',
    () async {
      final first = _ScheduleClient('first')..mutationError = 'pause failed';
      final second = _ScheduleClient('second');
      final container = _container(first, second);
      addTearDown(container.dispose);
      await container.read(aggregatedSchedulesProvider.future);

      first.mutationGate = Completer<void>();
      final pause = container
          .read(aggregatedSchedulesProvider.notifier)
          .pause('a', 'first');
      await first.mutationStarted!.future;
      expect(_entry(container, 'a').schedule.status, ScheduleStatus.paused);
      first.mutationGate!.complete();
      await expectLater(pause, throwsStateError);

      final restored = container.read(aggregatedSchedulesProvider).requireValue;
      expect(restored.schedules, hasLength(2));
      expect(_entry(container, 'a').schedule.status, ScheduleStatus.active);
      expect(_entry(container, 'b').schedule.status, ScheduleStatus.active);
    },
  );
}

AggregatedSchedule _entry(ProviderContainer container, String serverId) =>
    container
        .read(aggregatedSchedulesProvider)
        .requireValue
        .schedules
        .singleWhere((entry) => entry.serverId == serverId);

ProviderContainer _container(_ScheduleClient first, _ScheduleClient second) =>
    ProviderContainer(
      overrides: [
        hostRegistryProvider.overrideWith(_ScheduleRegistry.new),
        hostRuntimeClientsProvider.overrideWithValue({'a': first, 'b': second}),
        hostConnectionStateProvider.overrideWith(
          (ref, serverId) => Stream.value(DaemonConnectionState.connected),
        ),
      ],
    );

final class _ScheduleClient extends DaemonClient {
  _ScheduleClient(this.scheduleId, {this.started, this.release})
    : super(uri: Uri.parse('ws://schedule-test'));

  final String scheduleId;
  final Completer<void>? started;
  final Completer<void>? release;
  Object? listError;
  String? mutationError;
  Completer<void>? mutationGate;
  Completer<void>? mutationStarted;
  ScheduleStatus status = ScheduleStatus.active;
  bool deleted = false;
  final List<String> types = [];

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final type = message['type']! as String;
    types.add(type);
    if (type == 'schedule/list') {
      if (started != null && !started!.isCompleted) started!.complete();
      if (release != null && !release!.isCompleted) await release!.future;
      if (listError case final error?) throw error;
      return _listResponse(message['requestId']);
    }

    mutationStarted = Completer<void>()..complete();
    final gate = mutationGate;
    if (gate != null && !gate.isCompleted) await gate.future;
    if (mutationError case final error?) {
      return {
        'type': '$type/response',
        'payload': {'requestId': message['requestId'], 'error': error},
      };
    }
    if (type == 'schedule/pause') status = ScheduleStatus.paused;
    if (type == 'schedule/resume') status = ScheduleStatus.active;
    if (type == 'schedule/delete') {
      deleted = true;
      return {
        'type': '$type/response',
        'payload': {
          'requestId': message['requestId'],
          'scheduleId': scheduleId,
          'error': null,
        },
      };
    }
    return {
      'type': '$type/response',
      'payload': {
        'requestId': message['requestId'],
        'schedule': _summary(),
        'error': null,
      },
    };
  }

  Map<String, Object?> _listResponse(Object? requestId) => {
    'type': 'schedule/list/response',
    'payload': {
      'requestId': requestId,
      'schedules': deleted ? const [] : [_summary()],
      'error': null,
    },
  };

  Map<String, Object?> _summary() => {
    'id': scheduleId,
    'name': scheduleId,
    'prompt': 'Review $scheduleId',
    'cadence': {'type': 'cron', 'expression': '*/5 * * * *'},
    'target': {
      'type': 'new-agent',
      'config': {'provider': 'codex', 'cwd': 'C:/repo'},
    },
    'status': status.wireName,
    'createdAt': '2026-07-27T00:00:00.000Z',
    'updatedAt': '2026-07-27T00:00:00.000Z',
    'nextRunAt': '2026-07-27T00:05:00.000Z',
    'lastRunAt': null,
    'pausedAt': status == ScheduleStatus.paused
        ? '2026-07-27T00:01:00.000Z'
        : null,
    'expiresAt': null,
    'maxRuns': null,
  };
}

final class _ScheduleRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [_profile('a', 'Alpha'), _profile('b', 'Beta')],
    activeServerId: 'a',
    loaded: true,
  );
}

HostProfile _profile(String serverId, String label) => HostProfile(
  serverId: serverId,
  label: label,
  connections: [
    DirectTcpHostConnection(
      id: 'direct:$serverId:6868',
      endpoint: '$serverId:6868',
    ),
  ],
  preferredConnectionId: 'direct:$serverId:6868',
  createdAt: '2026-07-27T00:00:00.000Z',
  updatedAt: '2026-07-27T00:00:00.000Z',
);
