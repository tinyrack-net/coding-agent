import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';

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
