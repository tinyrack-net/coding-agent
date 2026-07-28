/// Per-agent append-only timeline with upsert-by-id semantics and delta
/// coalescing.
///
/// - `epoch` starts at 1 and is bumped when the timeline is rebuilt (resume);
///   clients holding a stale epoch must refetch from scratch.
/// - `seq` is monotonic within an epoch. Upserting an existing item id
///   re-emits the item under a new (higher) seq, so `fetch(afterSeq)` catch-up
///   always yields the latest version of every item.
/// - Streaming text deltas are coalesced: at most one flush per item per
///   [coalesceWindow] (leading edge immediate, trailing edge on timer), and an
///   immediate flush when the item completes via [upsert].
library;

import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';

typedef TimelineItemCallback =
    void Function(String agentId, int epoch, int seq, TimelineItem item);

final class TimelineRow {
  const TimelineRow({
    required this.seq,
    required this.timestamp,
    required this.item,
  });

  final int seq;
  final String timestamp;
  final TimelineItem item;

  factory TimelineRow.fromJson(Map<String, Object?> json) {
    final seq = json['seq'];
    final timestamp = json['timestamp'];
    final item = json['item'];
    if (seq is! num || seq.toInt() != seq || seq.toInt() < 0) {
      throw const FormatException('timeline row seq must be nonnegative');
    }
    if (timestamp is! String || item is! Map) {
      throw const FormatException('invalid persisted timeline row');
    }
    return TimelineRow(
      seq: seq.toInt(),
      timestamp: timestamp,
      item: LegacyTimelineCodec.decode(item.cast<String, Object?>()),
    );
  }

  Map<String, Object?> toJson() => {
    'seq': seq,
    'timestamp': timestamp,
    'item': LegacyTimelineCodec.encode(item),
  };
}

class TimelineStore {
  TimelineStore({
    required this.agentId,
    this.onItem,
    int epoch = 1,
    List<TimelineItem> items = const [],
    List<TimelineRow> rows = const [],
    int? lastSeq,
    this.coalesceWindow = const Duration(milliseconds: 80),
  }) : _epoch = epoch {
    if (rows.isNotEmpty) {
      for (final row in rows) {
        _canonicalRows.add(row);
        if (row.seq > _lastSeq) _lastSeq = row.seq;
      }
      final latestRowById = <String, TimelineRow>{
        for (final row in rows) row.item.id: row,
      };
      if (items.isNotEmpty) {
        for (final item in items) {
          final source = latestRowById[item.id];
          final entry = TimelineRow(
            seq: source?.seq ?? ++_lastSeq,
            timestamp:
                source?.timestamp ?? DateTime.now().toUtc().toIso8601String(),
            item: item,
          );
          _entries.add(entry);
          _byId[item.id] = entry;
        }
        _entries.sort((left, right) => left.seq.compareTo(right.seq));
      } else {
        for (final row in rows) {
          final previous = _byId[row.item.id];
          final merged = TimelineRow(
            seq: row.seq,
            timestamp: row.timestamp,
            item: _mergeCanonicalDelta(previous?.item, row.item),
          );
          if (previous != null) _entries.remove(previous);
          _entries.add(merged);
          _byId[row.item.id] = merged;
        }
      }
    } else {
      for (final item in items) {
        final row = TimelineRow(
          seq: ++_lastSeq,
          timestamp: DateTime.now().toUtc().toIso8601String(),
          item: item,
        );
        _canonicalRows.add(row);
        _entries.add(row);
        _byId[item.id] = row;
      }
    }
    if (lastSeq != null && lastSeq > _lastSeq) _lastSeq = lastSeq;
  }

  final String agentId;
  final Duration coalesceWindow;
  TimelineItemCallback? onItem;

  int _epoch;
  int _lastSeq = 0;

  final List<TimelineRow> _canonicalRows = [];
  final List<TimelineRow> _entries = [];
  final Map<String, TimelineRow> _byId = {};
  final Map<String, TimelineItem> _pending = {};
  final Map<String, Timer> _timers = {};

  int get epoch => _epoch;
  int get lastSeq => _lastSeq;

  /// Latest version of every item, in seq order.
  List<TimelineItem> snapshot() => [for (final e in _entries) e.item];

  /// Canonical rows with their current sequence identity.
  ///
  /// Paseo's v2 timeline window contract exposes sequence cursors; the legacy
  /// fetch response intentionally projects only the items.
  List<TimelineRow> snapshotRows() => List.unmodifiable(_canonicalRows);

  TimelineFetchResponse fetch({int afterSeq = 0}) => TimelineFetchResponse(
    epoch: _epoch,
    lastSeq: _lastSeq,
    items: [
      for (final e in _entries)
        if (e.seq > afterSeq) e.item,
    ],
  );

  /// Immediate upsert: assigns the next seq, replaces any previous version of
  /// the same item id, cancels pending coalesced state for it, and notifies
  /// [onItem].
  void upsert(TimelineItem item) {
    _timers.remove(item.id)?.cancel();
    _pending.remove(item.id);
    _commit(item);
  }

  /// Coalesced upsert for high-frequency updates (streaming text). Flushes
  /// immediately if the item has no open coalesce window, otherwise buffers
  /// the latest version and flushes when the window elapses.
  void upsertCoalesced(TimelineItem item) {
    if (_timers.containsKey(item.id)) {
      _pending[item.id] = item;
      return;
    }
    _commit(item);
    _startTimer(item.id);
  }

  /// Bump the epoch and rebuild the timeline from [items] (resume-rebuild).
  void rebuild(List<TimelineItem> items) {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _pending.clear();
    _canonicalRows.clear();
    _entries.clear();
    _byId.clear();
    _epoch += 1;
    _lastSeq = 0;
    for (final item in items) {
      _commit(item);
    }
  }

  /// Wipe every item and bump the epoch so stale-epoch clients refetch and
  /// see an empty timeline. Used by `AgentManager.clearConversations` to
  /// implement the user-facing "reset conversation" action.
  void clear() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _pending.clear();
    _canonicalRows.clear();
    _entries.clear();
    _byId.clear();
    _epoch += 1;
    _lastSeq = 0;
  }

  /// Flush any buffered coalesced updates and cancel timers.
  void flushAll() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    final pending = List<TimelineItem>.from(_pending.values);
    _pending.clear();
    for (final item in pending) {
      _commit(item);
    }
  }

  void dispose() => flushAll();

  void _startTimer(String itemId) {
    _timers[itemId] = Timer(coalesceWindow, () {
      _timers.remove(itemId);
      final pending = _pending.remove(itemId);
      if (pending != null) {
        _commit(pending);
        _startTimer(itemId);
      }
    });
  }

  void _commit(TimelineItem item) {
    final previous = _byId[item.id];
    if (previous != null) _entries.remove(previous);
    final canonicalItem = _canonicalDelta(previous?.item, item);
    final entry = TimelineRow(
      seq: ++_lastSeq,
      timestamp: DateTime.now().toUtc().toIso8601String(),
      item: item,
    );
    _canonicalRows.add(
      TimelineRow(
        seq: entry.seq,
        timestamp: entry.timestamp,
        item: canonicalItem,
      ),
    );
    _entries.add(entry);
    _byId[item.id] = entry;
    onItem?.call(agentId, _epoch, entry.seq, item);
  }
}

TimelineItem _canonicalDelta(TimelineItem? previous, TimelineItem current) {
  if (previous case AssistantMessageItem(
    text: final previousText,
  ) when current is AssistantMessageItem) {
    return AssistantMessageItem(
      id: current.id,
      text: current.text.startsWith(previousText)
          ? current.text.substring(previousText.length)
          : current.text,
      complete: current.complete,
    );
  }
  if (previous case ReasoningItem(
    text: final previousText,
  ) when current is ReasoningItem) {
    return ReasoningItem(
      id: current.id,
      text: current.text.startsWith(previousText)
          ? current.text.substring(previousText.length)
          : current.text,
      complete: current.complete,
    );
  }
  return current;
}

TimelineItem _mergeCanonicalDelta(
  TimelineItem? previous,
  TimelineItem current,
) {
  if (previous case AssistantMessageItem(
    text: final previousText,
  ) when current is AssistantMessageItem) {
    return AssistantMessageItem(
      id: current.id,
      text: '$previousText${current.text}',
      complete: current.complete,
    );
  }
  if (previous case ReasoningItem(
    text: final previousText,
  ) when current is ReasoningItem) {
    return ReasoningItem(
      id: current.id,
      text: '$previousText${current.text}',
      complete: current.complete,
    );
  }
  return current;
}
