import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';
import 'host_registry_provider.dart';

final schedulesProvider =
    AsyncNotifierProvider<SchedulesNotifier, List<ScheduleSummary>>(
      SchedulesNotifier.new,
    );

class SchedulesNotifier extends AsyncNotifier<List<ScheduleSummary>> {
  static const _uuid = Uuid();

  DaemonClient get _client => ref.read(daemonClientProvider);

  @override
  Future<List<ScheduleSummary>> build() async {
    final connection = await ref.watch(connectionStateProvider.future);
    if (connection != DaemonConnectionState.connected) return const [];
    return _fetch();
  }

  Future<List<ScheduleSummary>> _fetch() async {
    final response = await _client.requestSessionMessage(
      ScheduleListRequest(requestId: _uuid.v4()).toJson(),
    );
    final payload = _payload(response);
    _throwError(payload);
    final values = payload['schedules'];
    if (values is! List) throw StateError('Invalid schedule list response');
    return [for (final value in values) ScheduleSummary.fromJson(value)]
      ..sort((left, right) => right.createdAt.compareTo(left.createdAt));
  }

  Future<void> reload() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }

  Future<ScheduleSummary> create({
    required String prompt,
    required String? name,
    required ScheduleCadence cadence,
    required ScheduleTarget target,
    int? maxRuns,
    String? expiresAt,
    bool runOnCreate = false,
  }) async {
    final response = await _client.requestSessionMessage(
      ScheduleCreateRequest(
        requestId: _uuid.v4(),
        prompt: prompt,
        name: name,
        cadence: cadence,
        target: target,
        maxRuns: maxRuns,
        expiresAt: expiresAt,
        runOnCreate: runOnCreate,
      ).toJson(),
    );
    final schedule = _schedule(response);
    _upsert(schedule);
    return schedule;
  }

  Future<ScheduleSummary> updateSchedule(
    String scheduleId,
    Map<String, Object?> changes,
  ) async {
    final response = await _client.requestSessionMessage(
      ScheduleUpdateRequest(
        requestId: _uuid.v4(),
        scheduleId: scheduleId,
        changes: changes,
      ).toJson(),
    );
    final schedule = _schedule(response);
    _upsert(schedule);
    return schedule;
  }

  Future<ScheduleSummary> pause(String scheduleId) =>
      _idMutation(ScheduleIdRequest.pauseType, scheduleId);

  Future<ScheduleSummary> resume(String scheduleId) =>
      _idMutation(ScheduleIdRequest.resumeType, scheduleId);

  Future<ScheduleSummary> runOnce(String scheduleId) =>
      _idMutation(ScheduleIdRequest.runOnceType, scheduleId);

  Future<void> delete(String scheduleId) async {
    final response = await _client.requestSessionMessage(
      ScheduleIdRequest(
        type: ScheduleIdRequest.deleteType,
        requestId: _uuid.v4(),
        scheduleId: scheduleId,
      ).toJson(),
    );
    final payload = _payload(response);
    _throwError(payload);
    state = AsyncData([
      for (final schedule in state.value ?? const <ScheduleSummary>[])
        if (schedule.id != scheduleId) schedule,
    ]);
  }

  Future<ScheduleSummary> _idMutation(String type, String scheduleId) async {
    final response = await _client.requestSessionMessage(
      ScheduleIdRequest(
        type: type,
        requestId: _uuid.v4(),
        scheduleId: scheduleId,
      ).toJson(),
    );
    final schedule = _schedule(response);
    _upsert(schedule);
    return schedule;
  }

  ScheduleSummary _schedule(Map<String, Object?> response) {
    final payload = _payload(response);
    _throwError(payload);
    final value = payload['schedule'];
    if (value == null) throw StateError('Schedule not found');
    return ScheduleSummary.fromJson(value);
  }

  void _upsert(ScheduleSummary schedule) {
    final schedules = [
      schedule,
      for (final existing in state.value ?? const <ScheduleSummary>[])
        if (existing.id != schedule.id) existing,
    ]..sort((left, right) => right.createdAt.compareTo(left.createdAt));
    state = AsyncData(schedules);
  }
}

Map<String, Object?> _payload(Map<String, Object?> response) {
  final payload = response['payload'];
  if (payload is! Map) throw StateError('Invalid schedule response');
  return Map<String, Object?>.from(payload);
}

void _throwError(Map<String, Object?> payload) {
  if (payload['error'] case final String error when error.isNotEmpty) {
    throw StateError(error);
  }
}

const allScheduleHostsFailedMessage = 'No connected hosts could load schedules';

final class AggregatedSchedule {
  const AggregatedSchedule({
    required this.serverId,
    required this.serverName,
    required this.schedule,
  });

  final String serverId;
  final String serverName;
  final ScheduleSummary schedule;
}

final class ScheduleHostError {
  const ScheduleHostError({
    required this.serverId,
    required this.serverName,
    required this.message,
  });

  final String serverId;
  final String serverName;
  final String message;
}

final class AggregatedSchedulesState {
  const AggregatedSchedulesState({
    this.schedules = const [],
    this.hostErrors = const [],
    this.connecting = false,
  });

  final List<AggregatedSchedule> schedules;
  final List<ScheduleHostError> hostErrors;
  final bool connecting;
}

final class ScheduleHost {
  const ScheduleHost({
    required this.serverId,
    required this.serverName,
    required this.client,
  });

  final String serverId;
  final String serverName;
  final DaemonClient client;
}

final aggregatedSchedulesProvider =
    AsyncNotifierProvider<
      AggregatedSchedulesNotifier,
      AggregatedSchedulesState
    >(AggregatedSchedulesNotifier.new);

class AggregatedSchedulesNotifier
    extends AsyncNotifier<AggregatedSchedulesState> {
  List<ScheduleHost> _hosts = const [];
  bool _connecting = false;

  @override
  Future<AggregatedSchedulesState> build() async {
    final profiles = ref.watch(hostRegistryProvider).hosts;
    final clients = ref.watch(hostRuntimeClientsProvider);
    final hosts = <ScheduleHost>[];
    var connecting = false;
    for (final profile in profiles) {
      final client = clients[profile.serverId];
      if (client == null) continue;
      ref.watch(hostConnectionStateProvider(profile.serverId));
      switch (client.currentState) {
        case DaemonConnectionState.connected:
          hosts.add(
            ScheduleHost(
              serverId: profile.serverId,
              serverName: profile.label,
              client: client,
            ),
          );
        case DaemonConnectionState.connecting:
          connecting = true;
        case DaemonConnectionState.disconnected:
        case DaemonConnectionState.versionMismatch:
          break;
      }
    }
    _hosts = List.unmodifiable(hosts);
    _connecting = connecting;
    return fetchSchedulesBatch(_hosts, connecting: connecting);
  }

  Future<void> reload() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => fetchSchedulesBatch(_hosts, connecting: _connecting),
    );
  }

  Future<ScheduleSummary> create(
    String serverId, {
    required String prompt,
    required String? name,
    required ScheduleCadence cadence,
    required ScheduleTarget target,
    int? maxRuns,
    String? expiresAt,
    bool runOnCreate = false,
  }) async {
    final schedule = await _requestSchedule(
      serverId,
      ScheduleCreateRequest(
        requestId: SchedulesNotifier._uuid.v4(),
        prompt: prompt,
        name: name,
        cadence: cadence,
        target: target,
        maxRuns: maxRuns,
        expiresAt: expiresAt,
        runOnCreate: runOnCreate,
      ).toJson(),
    );
    await _refreshPreservingData();
    return schedule;
  }

  Future<ScheduleSummary> updateSchedule(
    String serverId,
    String scheduleId,
    Map<String, Object?> changes,
  ) async {
    final schedule = await _requestSchedule(
      serverId,
      ScheduleUpdateRequest(
        requestId: SchedulesNotifier._uuid.v4(),
        scheduleId: scheduleId,
        changes: changes,
      ).toJson(),
    );
    await _refreshPreservingData();
    return schedule;
  }

  Future<ScheduleSummary> pause(String serverId, String scheduleId) =>
      _optimisticStatusMutation(
        serverId,
        scheduleId,
        ScheduleStatus.paused,
        ScheduleIdRequest.pauseType,
      );

  Future<ScheduleSummary> resume(String serverId, String scheduleId) =>
      _optimisticStatusMutation(
        serverId,
        scheduleId,
        ScheduleStatus.active,
        ScheduleIdRequest.resumeType,
      );

  Future<ScheduleSummary> runOnce(String serverId, String scheduleId) async {
    final schedule = await _requestSchedule(
      serverId,
      ScheduleIdRequest(
        type: ScheduleIdRequest.runOnceType,
        requestId: SchedulesNotifier._uuid.v4(),
        scheduleId: scheduleId,
      ).toJson(),
    );
    await _refreshPreservingData();
    return schedule;
  }

  Future<void> delete(String serverId, String scheduleId) async {
    final snapshot = state.value;
    if (snapshot == null) return;
    state = AsyncData(
      AggregatedSchedulesState(
        schedules: List.unmodifiable([
          for (final entry in snapshot.schedules)
            if (entry.serverId != serverId || entry.schedule.id != scheduleId)
              entry,
        ]),
        hostErrors: snapshot.hostErrors,
        connecting: snapshot.connecting,
      ),
    );
    try {
      final response = await _clientFor(serverId).requestSessionMessage(
        ScheduleIdRequest(
          type: ScheduleIdRequest.deleteType,
          requestId: SchedulesNotifier._uuid.v4(),
          scheduleId: scheduleId,
        ).toJson(),
      );
      _throwError(_payload(response));
    } on Object {
      state = AsyncData(snapshot);
      rethrow;
    } finally {
      await _refreshPreservingData();
    }
  }

  Future<ScheduleSummary> _optimisticStatusMutation(
    String serverId,
    String scheduleId,
    ScheduleStatus status,
    String type,
  ) async {
    final snapshot = state.value;
    if (snapshot == null) throw StateError('Schedules are not loaded');
    state = AsyncData(
      AggregatedSchedulesState(
        schedules: List.unmodifiable([
          for (final entry in snapshot.schedules)
            if (entry.serverId == serverId && entry.schedule.id == scheduleId)
              AggregatedSchedule(
                serverId: entry.serverId,
                serverName: entry.serverName,
                schedule: entry.schedule.copyWith(status: status),
              )
            else
              entry,
        ]),
        hostErrors: snapshot.hostErrors,
        connecting: snapshot.connecting,
      ),
    );
    try {
      return await _requestSchedule(
        serverId,
        ScheduleIdRequest(
          type: type,
          requestId: SchedulesNotifier._uuid.v4(),
          scheduleId: scheduleId,
        ).toJson(),
      );
    } on Object {
      state = AsyncData(snapshot);
      rethrow;
    } finally {
      await _refreshPreservingData();
    }
  }

  DaemonClient _clientFor(String serverId) {
    for (final host in _hosts) {
      if (host.serverId == serverId) return host.client;
    }
    throw StateError('Host is not connected: $serverId');
  }

  Future<ScheduleSummary> _requestSchedule(
    String serverId,
    Map<String, Object?> message,
  ) async {
    final response = await _clientFor(serverId).requestSessionMessage(message);
    final payload = _payload(response);
    _throwError(payload);
    final value = payload['schedule'];
    if (value == null) throw StateError('Schedule not found');
    return ScheduleSummary.fromJson(value);
  }

  Future<void> _refreshPreservingData() async {
    final current = state.value;
    try {
      state = AsyncData(
        await fetchSchedulesBatch(_hosts, connecting: _connecting),
      );
    } on Object {
      if (current != null) state = AsyncData(current);
    }
  }
}

Future<AggregatedSchedulesState> fetchSchedulesBatch(
  List<ScheduleHost> hosts, {
  bool connecting = false,
}) async {
  final results = await Future.wait([
    for (final host in hosts)
      _fetchHostSchedules(host).then<_ScheduleHostResult>(
        (schedules) => _ScheduleHostResult.success(host, schedules),
        onError: (Object error) => _ScheduleHostResult.failure(host, error),
      ),
  ]);
  final successful = results.where((result) => result.error == null).toList();
  if (hosts.isNotEmpty && successful.isEmpty) {
    throw StateError(allScheduleHostsFailedMessage);
  }
  final schedules = <AggregatedSchedule>[
    for (final result in successful)
      for (final schedule in result.schedules!)
        AggregatedSchedule(
          serverId: result.host.serverId,
          serverName: result.host.serverName,
          schedule: schedule,
        ),
  ]..sort(_compareAggregatedSchedules);
  final errors = <ScheduleHostError>[
    for (final result in results)
      if (result.error case final error?)
        ScheduleHostError(
          serverId: result.host.serverId,
          serverName: result.host.serverName,
          message: error.toString(),
        ),
  ];
  return AggregatedSchedulesState(
    schedules: List.unmodifiable(schedules),
    hostErrors: List.unmodifiable(errors),
    connecting: connecting,
  );
}

final class _ScheduleHostResult {
  const _ScheduleHostResult.success(this.host, this.schedules) : error = null;
  const _ScheduleHostResult.failure(this.host, this.error) : schedules = null;

  final ScheduleHost host;
  final List<ScheduleSummary>? schedules;
  final Object? error;
}

Future<List<ScheduleSummary>> _fetchHostSchedules(ScheduleHost host) async {
  final response = await host.client.requestSessionMessage(
    ScheduleListRequest(requestId: SchedulesNotifier._uuid.v4()).toJson(),
  );
  final payload = _payload(response);
  _throwError(payload);
  final values = payload['schedules'];
  if (values is! List) throw StateError('Invalid schedule list response');
  return [for (final value in values) ScheduleSummary.fromJson(value)];
}

int _compareAggregatedSchedules(
  AggregatedSchedule left,
  AggregatedSchedule right,
) {
  final created = right.schedule.createdAt.compareTo(left.schedule.createdAt);
  if (created != 0) return created;
  final host = left.serverId.compareTo(right.serverId);
  if (host != 0) return host;
  return left.schedule.id.compareTo(right.schedule.id);
}
