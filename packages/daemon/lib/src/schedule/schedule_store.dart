import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

typedef ScheduleUpdater =
    FutureOr<StoredSchedule> Function(StoredSchedule schedule);

final class ScheduleStore {
  ScheduleStore(this.directory, {Random? random})
    : _random = random ?? Random.secure();

  final String directory;
  final Random _random;
  final Map<String, Future<void>> _mutations = {};

  String _filePath(String id) => p.join(directory, '$id.json');

  Future<List<StoredSchedule>> list() async {
    final dir = Directory(directory);
    await dir.create(recursive: true);
    final schedules = <StoredSchedule>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final decoded = jsonDecode(await entity.readAsString());
      schedules.add(StoredSchedule.fromJson(decoded));
    }
    schedules.sort(
      (left, right) =>
          left.summary.createdAt.compareTo(right.summary.createdAt),
    );
    return schedules;
  }

  Future<StoredSchedule?> get(String id) async {
    final file = File(_filePath(id));
    if (!await file.exists()) return null;
    return StoredSchedule.fromJson(jsonDecode(await file.readAsString()));
  }

  Future<StoredSchedule> create(StoredSchedule schedule) async {
    final id = schedule.summary.id.isEmpty
        ? _generateId()
        : schedule.summary.id;
    final created = schedule.summary.id == id
        ? schedule
        : schedule.copyWith(summary: _withId(schedule.summary, id));
    await _write(created);
    return created;
  }

  Future<StoredSchedule?> update(String id, ScheduleUpdater updater) =>
      _serialize(id, () async {
        final current = await get(id);
        if (current == null) return null;
        final next = await updater(current);
        if (next.summary.id != id) {
          throw StateError('Schedule update cannot change id: $id');
        }
        if (identical(next, current)) return current;
        final validated = StoredSchedule.fromJson(next.toJson());
        await _write(validated);
        return validated;
      });

  Future<void> delete(String id) => _serialize(id, () async {
    final file = File(_filePath(id));
    if (await file.exists()) await file.delete();
  });

  Future<T> _serialize<T>(String id, Future<T> Function() mutation) async {
    final previous = _mutations[id];
    final barrier = Completer<void>();
    final next = barrier.future;
    _mutations[id] = next;
    if (previous != null) {
      try {
        await previous;
      } on Object {
        // A failed mutation must not poison the queue.
      }
    }
    try {
      return await mutation();
    } finally {
      barrier.complete();
      if (identical(_mutations[id], next)) {
        _mutations.remove(id);
      }
    }
  }

  Future<void> _write(StoredSchedule schedule) async {
    final file = File(_filePath(schedule.summary.id));
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(schedule.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  String _generateId() {
    final bytes = List<int>.generate(4, (_) => _random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}

ScheduleSummary _withId(ScheduleSummary source, String id) => ScheduleSummary(
  id: id,
  name: source.name,
  prompt: source.prompt,
  cadence: source.cadence,
  target: source.target,
  status: source.status,
  createdAt: source.createdAt,
  updatedAt: source.updatedAt,
  nextRunAt: source.nextRunAt,
  lastRunAt: source.lastRunAt,
  pausedAt: source.pausedAt,
  expiresAt: source.expiresAt,
  maxRuns: source.maxRuns,
);
