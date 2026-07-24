import 'dart:async';
import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';

/// Immutable timeline snapshot for one agent.
class TimelineState {
  const TimelineState({
    this.items = const [],
    this.epoch = -1,
    this.lastSeq = 0,
    this.loading = true,
  });

  final List<TimelineItem> items;

  /// -1 means "no successful fetch yet".
  final int epoch;
  final int lastSeq;
  final bool loading;

  TimelineState copyWith({
    List<TimelineItem>? items,
    int? epoch,
    int? lastSeq,
    bool? loading,
  }) =>
      TimelineState(
        items: items ?? this.items,
        epoch: epoch ?? this.epoch,
        lastSeq: lastSeq ?? this.lastSeq,
        loading: loading ?? this.loading,
      );
}

/// Per-agent timeline: ordered items with upsert-by-id, fed by `agent.stream`
/// events and `agent.timeline.fetch` for initial load / catch-up.
class TimelineNotifier extends Notifier<TimelineState> {
  TimelineNotifier(this.agentId);

  /// Family argument: the agent this timeline belongs to.
  final String agentId;

  /// itemId -> index into [TimelineState.items].
  final Map<String, int> _index = {};
  bool _fetching = false;
  bool _refetchQueued = false;
  bool _refetchQueuedFull = false;

  @override
  TimelineState build() {
    _index.clear();
    _fetching = false;
    _refetchQueued = false;
    _refetchQueuedFull = false;
    final client = ref.watch(daemonClientProvider);
    final eventSub = client.events.listen(_onEvent);
    final connSub = client.connectionState.listen((s) {
      if (s == DaemonConnectionState.connected) _fetch();
    });
    ref.onDispose(() {
      eventSub.cancel();
      connSub.cancel();
    });
    if (client.currentState == DaemonConnectionState.connected) {
      Future.microtask(_fetch);
    }
    return const TimelineState();
  }

  void _onEvent(RpcEvent event) {
    if (event.type != MessageTypes.agentStreamEvent) return;
    final AgentStreamPayload payload;
    try {
      payload = AgentStreamPayload.fromJson(event.payload);
    } catch (_) {
      return;
    }
    if (payload.agentId != agentId) return;
    if (state.epoch < 0) {
      // No baseline yet; the initial fetch will pick everything up.
      _fetch();
      return;
    }
    if (payload.epoch != state.epoch) {
      _fetch(full: true);
      return;
    }
    if (payload.seq > state.lastSeq + 1) {
      // Gap detected: catch up from what we have.
      _fetch();
      return;
    }
    _applyUpsert(payload.item, math.max(state.lastSeq, payload.seq));
  }

  void _applyUpsert(TimelineItem item, int lastSeq) {
    final existing = _index[item.id];
    final List<TimelineItem> items;
    if (existing != null) {
      items = List.of(state.items);
      items[existing] = item;
    } else {
      items = List.of(state.items)..add(item);
      _index[item.id] = items.length - 1;
    }
    state = state.copyWith(items: items, lastSeq: lastSeq, loading: false);
  }

  Future<void> _fetch({bool full = false}) async {
    if (_fetching) {
      _refetchQueued = true;
      _refetchQueuedFull = _refetchQueuedFull || full;
      return;
    }
    _fetching = true;
    try {
      final client = ref.read(daemonClientProvider);
      final incremental = !full && state.epoch >= 0;
      final res =
          await client.request(MessageTypes.agentTimelineFetchRequest, {
        'agentId': agentId,
        if (incremental) 'epoch': state.epoch,
        if (incremental) 'afterSeq': state.lastSeq,
      });
      final fetched = TimelineFetchResponse.fromJson(res);
      if (incremental && fetched.epoch == state.epoch) {
        var next = state;
        for (final item in fetched.items) {
          final existing = _index[item.id];
          final List<TimelineItem> items;
          if (existing != null) {
            items = List.of(next.items);
            items[existing] = item;
          } else {
            items = List.of(next.items)..add(item);
            _index[item.id] = items.length - 1;
          }
          next = next.copyWith(items: items);
        }
        state = next.copyWith(
          lastSeq: math.max(state.lastSeq, fetched.lastSeq),
          loading: false,
        );
      } else {
        // Full snapshot (initial load or epoch change).
        _index.clear();
        for (var i = 0; i < fetched.items.length; i++) {
          _index[fetched.items[i].id] = i;
        }
        state = TimelineState(
          items: List.unmodifiable(fetched.items),
          epoch: fetched.epoch,
          lastSeq: fetched.lastSeq,
          loading: false,
        );
      }
    } catch (_) {
      // Disconnected or daemon error; reconnect handler will refetch.
    } finally {
      _fetching = false;
      if (_refetchQueued) {
        _refetchQueued = false;
        final queuedFull = _refetchQueuedFull;
        _refetchQueuedFull = false;
        unawaited(_fetch(full: queuedFull));
      }
    }
  }
}

final timelineProvider =
    NotifierProvider.family<TimelineNotifier, TimelineState, String>(
  TimelineNotifier.new,
);

/// Number of items in an agent's timeline (cheap to watch from list builders).
final timelineCountProvider = Provider.family<int, String>(
  (ref, agentId) =>
      ref.watch(timelineProvider(agentId).select((s) => s.items.length)),
);
