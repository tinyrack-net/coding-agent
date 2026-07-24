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

typedef TimelineItemCallback = void Function(
  String agentId,
  int epoch,
  int seq,
  TimelineItem item,
);

class TimelineStore {
  TimelineStore({
    required this.agentId,
    this.onItem,
    int epoch = 1,
    List<TimelineItem> items = const [],
    this.coalesceWindow = const Duration(milliseconds: 80),
  }) : _epoch = epoch {
    for (final item in items) {
      final entry = (seq: ++_lastSeq, item: item);
      _entries.add(entry);
      _byId[item.id] = entry;
    }
  }

  final String agentId;
  final Duration coalesceWindow;
  TimelineItemCallback? onItem;

  int _epoch;
  int _lastSeq = 0;

  final List<({int seq, TimelineItem item})> _entries = [];
  final Map<String, ({int seq, TimelineItem item})> _byId = {};
  final Map<String, TimelineItem> _pending = {};
  final Map<String, Timer> _timers = {};

  int get epoch => _epoch;
  int get lastSeq => _lastSeq;

  /// Latest version of every item, in seq order.
  List<TimelineItem> snapshot() => [for (final e in _entries) e.item];

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
    _entries.clear();
    _byId.clear();
    _epoch += 1;
    _lastSeq = 0;
    for (final item in items) {
      _commit(item);
    }
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
    final entry = (seq: ++_lastSeq, item: item);
    _entries.add(entry);
    _byId[item.id] = entry;
    onItem?.call(agentId, _epoch, entry.seq, item);
  }
}
