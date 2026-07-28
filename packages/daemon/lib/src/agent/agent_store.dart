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
  });

  final AgentSummary summary;
  final bool archived;
  final int epoch;
  final int lastSeq;
  final List<TimelineItem> items;
  final List<TimelineRow> rows;
  final bool internal;

  static PersistedAgent fromJson(Map<String, Object?> json) => PersistedAgent(
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
  );

  Map<String, Object?> toJson() => {
    'summary': summary.toJson(),
    'archived': archived,
    'epoch': epoch,
    'lastSeq': lastSeq,
    'items': items.map((i) => i.toJson()).toList(),
    if (rows.isNotEmpty) 'rows': rows.map((row) => row.toJson()).toList(),
    if (internal) 'internal': true,
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

  static String defaultDataDir() {
    final home =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    return p.join(home, '.tinyrack-agent');
  }

  String _fileFor(PersistedAgent record) => p.join(
    dataDir,
    'agents',
    sanitizeCwd(record.summary.cwd),
    '${record.summary.agentId}.json',
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
  Future<void> save(PersistedAgent record) async {
    final file = File(_fileFor(record));
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(record.toJson()), flush: true);
    if (file.existsSync()) {
      try {
        await file.delete();
      } catch (_) {}
    }
    await tmp.rename(file.path);
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
  }
}
