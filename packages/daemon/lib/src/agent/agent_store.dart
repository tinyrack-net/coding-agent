/// Disk persistence for agents.
///
/// Layout: `<dataDir>/agents/<sanitized-cwd>/<agentId>.json` where each file
/// holds `{summary, archived, epoch, lastSeq, items[]}`. Writes are atomic
/// (tmp file + rename) and debounced (500 ms per agent).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:path/path.dart' as p;

import 'timeline_store.dart';

final class PersistedAgent {
  const PersistedAgent({
    required this.summary,
    required this.archived,
    required this.epoch,
    required this.lastSeq,
    required this.items,
    this.rows = const [],
    this.internal = false,
    this.mcpServers = const {},
    this.environment = const {},
  });

  final AgentSummary summary;
  final bool archived;
  final int epoch;
  final int lastSeq;
  final List<TimelineItem> items;
  final List<TimelineRow> rows;
  final bool internal;
  final Map<String, Object?> mcpServers;
  final Map<String, String> environment;

  static PersistedAgent fromJson(Map<String, Object?> json) {
    final config = json['config'];
    final mcpServers = config is Map && config['mcpServers'] is Map
        ? Map<String, Object?>.unmodifiable(
            Map<String, Object?>.from(config['mcpServers']! as Map),
          )
        : const <String, Object?>{};
    final environment = config is Map && config['env'] is Map
        ? Map<String, String>.unmodifiable(
            Map<String, String>.from(config['env']! as Map),
          )
        : const <String, String>{};
    return PersistedAgent(
      summary: AgentSummary.fromJson(json['summary'] as Map<String, Object?>),
      archived: (json['archived'] as bool?) ?? false,
      epoch: (json['epoch'] as num?)?.toInt() ?? 1,
      lastSeq: (json['lastSeq'] as num?)?.toInt() ?? 0,
      items: ((json['items'] as List?) ?? const [])
          .cast<Map<String, Object?>>()
          .map(TimelineItem.fromJson)
          .toList(),
      rows: ((json['rows'] as List?) ?? const [])
          .cast<Map<String, Object?>>()
          .map(TimelineRow.fromJson)
          .toList(),
      internal: (json['internal'] as bool?) ?? false,
      mcpServers: mcpServers,
      environment: environment,
    );
  }

  Map<String, Object?> toJson() => {
    'summary': summary.toJson(),
    'archived': archived,
    'epoch': epoch,
    'lastSeq': lastSeq,
    'items': items.map((i) => i.toJson()).toList(),
    if (rows.isNotEmpty) 'rows': rows.map((row) => row.toJson()).toList(),
    if (internal) 'internal': true,
    if (mcpServers.isNotEmpty || environment.isNotEmpty)
      'config': {
        if (mcpServers.isNotEmpty) 'mcpServers': mcpServers,
        if (environment.isNotEmpty) 'env': environment,
      },
  };
}

class AgentStore {
  AgentStore({
    String? dataDir,
    this.debounce = const Duration(milliseconds: 500),
  }) : dataDir = dataDir ?? defaultDataDir();

  final String dataDir;
  final Duration debounce;

  final Map<String, Timer> _timers = {};
  final Map<String, PersistedAgent> _dirty = {};
  final Map<String, Future<void>> _writes = {};
  static int _nextTempId = 0;

  static String defaultDataDir() {
    final home =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    return p.join(home, '.tinyrack-agent');
  }

  String _fileFor(PersistedAgent record) => _fileForSummary(record.summary);

  String _fileForSummary(AgentSummary summary) => p.join(
    dataDir,
    'agents',
    sanitizeCwd(summary.cwd),
    '${summary.agentId}.json',
  );

  /// Filesystem-safe directory name for a cwd, unique per distinct cwd.
  static String sanitizeCwd(String cwd) {
    var safe = cwd.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (safe.length > 80) safe = safe.substring(safe.length - 80);
    final hash = cwd.hashCode.toUnsigned(32).toRadixString(16);
    return '${safe}_$hash';
  }

  /// Load every persisted agent (including archived ones).
  Future<List<PersistedAgent>> loadAll() async {
    final agentsDir = Directory(p.join(dataDir, 'agents'));
    if (!agentsDir.existsSync()) return const [];
    final records = <PersistedAgent>[];
    await for (final entity in agentsDir.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final json =
            jsonDecode(await entity.readAsString()) as Map<String, Object?>;
        records.add(PersistedAgent.fromJson(json));
      } catch (_) {
        // Skip corrupt files rather than failing startup.
      }
    }
    records.sort(
      (a, b) => a.summary.createdAtMs.compareTo(b.summary.createdAtMs),
    );
    return records;
  }

  /// Schedule a debounced save; the latest record per agent wins.
  void scheduleSave(PersistedAgent record) {
    final id = record.summary.agentId;
    _dirty[id] = record;
    _timers[id] ??= Timer(debounce, () {
      _timers.remove(id);
      final pending = _dirty.remove(id);
      if (pending != null) {
        unawaited(save(pending));
      }
    });
  }

  /// Immediate atomic write (tmp + rename).
  Future<void> save(PersistedAgent record) {
    final path = _fileFor(record);
    final previous = _writes[path] ?? Future<void>.value();
    late final Future<void> queued;
    queued = previous.then(
      (_) => _saveNow(path, record),
      onError: (_, __) => _saveNow(path, record),
    );
    _writes[path] = queued;
    return queued.whenComplete(() {
      if (identical(_writes[path], queued)) {
        _writes.remove(path);
      }
    });
  }

  Future<void> _saveNow(String path, PersistedAgent record) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final tempId = _nextTempId++;
    final tmp = File('${file.path}.$pid.$tempId.tmp');
    try {
      await tmp.writeAsString(jsonEncode(record.toJson()), flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tmp.rename(file.path);
    } finally {
      if (await tmp.exists()) {
        await tmp.delete();
      }
    }
  }

  /// Write out all pending debounced saves now.
  Future<void> flush() async {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    final pending = List<PersistedAgent>.from(_dirty.values);
    _dirty.clear();
    for (final record in pending) {
      await save(record);
    }
    final writes = _writes.values.toList(growable: false);
    if (writes.isNotEmpty) {
      await Future.wait(writes);
    }
  }

  /// Permanently remove one durable agent after draining its queued writes.
  Future<void> remove(AgentSummary summary) async {
    final id = summary.agentId;
    _timers.remove(id)?.cancel();
    _dirty.remove(id);
    final path = _fileForSummary(summary);
    final write = _writes[path];
    if (write != null) {
      try {
        await write;
      } on Object {
        // Deletion is the final operation; a failed predecessor must not
        // retain a stale durable snapshot.
      }
    }
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}
