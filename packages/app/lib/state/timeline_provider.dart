import 'dart:async';
import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachments/attachment_store.dart';
import '../core/daemon_client.dart';
import '../timeline/session_stream_acceptance.dart';
import 'daemon_providers.dart';
import 'host_registry_provider.dart';

final class OptimisticUserMessage {
  OptimisticUserMessage({
    required this.id,
    required this.text,
    required this.timestamp,
    required List<AttachmentMetadata> images,
    required List<AgentAttachment> attachments,
  }) : images = List.unmodifiable(images),
       attachments = List.unmodifiable(attachments);

  final String id;
  final String text;
  final int timestamp;
  final List<AttachmentMetadata> images;
  final List<AgentAttachment> attachments;
}

/// A position in an agent's timeline. Mirrors Paseo's `TimelinePosition`,
/// the cursor a fork request uses to identify where to branch from.
final class StreamTimelinePosition {
  const StreamTimelinePosition({required this.epoch, required this.seq});

  final String epoch;
  final int seq;

  @override
  bool operator ==(Object other) =>
      other is StreamTimelinePosition &&
      other.epoch == epoch &&
      other.seq == seq;

  @override
  int get hashCode => Object.hash(epoch, seq);

  @override
  String toString() => 'StreamTimelinePosition(epoch: $epoch, seq: $seq)';
}

final class TimelineDisplayItem {
  const TimelineDisplayItem({
    required this.item,
    this.userMessage,
    this.timestamp,
    this.optimistic = false,
    this.blockGroupId,
    this.messageId,
    this.timelineCursor,
  });

  final TimelineItem item;
  final OptimisticUserMessage? userMessage;

  /// When the item was last written. Populated from the daemon's page/stream
  /// timestamp (or the optimistic message's local timestamp) and drives
  /// Paseo's turn-timing derivation; `null` only for items synthesized
  /// outside the timeline replica (e.g. subagent tool-call overlays).
  final DateTime? timestamp;

  /// Mirrors Paseo's `StreamItem.optimistic`: `true` only for a user message
  /// that is still a local, unconfirmed echo (not yet reconciled with a
  /// canonical daemon item). A reconciled item keeps its [userMessage]
  /// presentation for rendering but is no longer optimistic.
  final bool optimistic;

  /// Groups the consecutive assistant rows that were split out of one
  /// assistant message, so stream spacing can compact the seams between
  /// them. Upstream sets it while splitting long streaming markdown into
  /// separately-mountable blocks; the daemon-projected timeline upserts a
  /// whole assistant message by id instead, so this stays null in
  /// production and exists for the spacing contract.
  final String? blockGroupId;

  /// The provider-side message id for an assistant message, when the
  /// provider exposes one. Used as a fork boundary when no timeline cursor
  /// is available.
  final String? messageId;

  /// The timeline position an assistant message was written at. Preferred
  /// over [messageId] as a fork boundary when the host supports cursors.
  final StreamTimelinePosition? timelineCursor;
}

enum TimelineCatchUpPhase { idle, syncing, error }

/// Paseo keeps the authoritative tail page separate from the active stream
/// head. This lets older pages prepend without disturbing live item identity.
class TimelineState {
  const TimelineState({
    this.tailItems = const [],
    this.headItems = const [],
    this.pendingTailUserMessages = const [],
    this.pendingHeadUserMessages = const [],
    this.userMessagePresentations = const {},
    this.itemTimestamps = const {},
    this.epoch,
    this.cursor,
    this.hasOlder = false,
    this.loading = true,
    this.loadingOlder = false,
    this.catchUpPhase = TimelineCatchUpPhase.idle,
    this.error,
    this.syncError,
  });

  final List<TimelineItem> tailItems;
  final List<TimelineItem> headItems;
  final List<OptimisticUserMessage> pendingTailUserMessages;
  final List<OptimisticUserMessage> pendingHeadUserMessages;
  final Map<String, OptimisticUserMessage> userMessagePresentations;

  /// Last-known-write timestamp per canonical timeline item id. Mirrors
  /// Paseo's `StreamItem.timestamp`, which `turn-time.ts` derives turn
  /// duration from.
  final Map<String, DateTime> itemTimestamps;
  final String? epoch;
  final AgentTimelineCursorRange? cursor;
  final bool hasOlder;
  final bool loading;
  final bool loadingOlder;
  final TimelineCatchUpPhase catchUpPhase;
  final String? error;
  final String? syncError;

  List<TimelineItem> get items => [...tailItems, ...headItems];
  List<OptimisticUserMessage> get pendingUserMessages => [
    ...pendingTailUserMessages,
    ...pendingHeadUserMessages,
  ];
  int get lastSeq => cursor?.endSeq ?? 0;

  List<TimelineDisplayItem> get displayItems => [
    ...tailDisplayItems,
    ...headDisplayItems,
  ];

  List<TimelineDisplayItem> get tailDisplayItems => [
    ..._displayCanonical(tailItems, userMessagePresentations, itemTimestamps),
    ..._displayPending(pendingTailUserMessages),
  ];

  List<TimelineDisplayItem> get headDisplayItems => [
    ..._displayCanonical(headItems, userMessagePresentations, itemTimestamps),
    ..._displayPending(pendingHeadUserMessages),
  ];

  Set<String> get attachmentIds => {
    for (final message in pendingUserMessages)
      for (final image in message.images) image.id,
    for (final message in userMessagePresentations.values)
      for (final image in message.images) image.id,
  };

  TimelineState copyWith({
    List<TimelineItem>? tailItems,
    List<TimelineItem>? headItems,
    List<OptimisticUserMessage>? pendingTailUserMessages,
    List<OptimisticUserMessage>? pendingHeadUserMessages,
    Map<String, OptimisticUserMessage>? userMessagePresentations,
    Map<String, DateTime>? itemTimestamps,
    String? epoch,
    bool clearEpoch = false,
    AgentTimelineCursorRange? cursor,
    bool clearCursor = false,
    bool? hasOlder,
    bool? loading,
    bool? loadingOlder,
    TimelineCatchUpPhase? catchUpPhase,
    String? error,
    bool clearError = false,
    String? syncError,
    bool clearSyncError = false,
  }) => TimelineState(
    tailItems: tailItems ?? this.tailItems,
    headItems: headItems ?? this.headItems,
    pendingTailUserMessages:
        pendingTailUserMessages ?? this.pendingTailUserMessages,
    pendingHeadUserMessages:
        pendingHeadUserMessages ?? this.pendingHeadUserMessages,
    userMessagePresentations:
        userMessagePresentations ?? this.userMessagePresentations,
    itemTimestamps: itemTimestamps ?? this.itemTimestamps,
    epoch: clearEpoch ? null : (epoch ?? this.epoch),
    cursor: clearCursor ? null : (cursor ?? this.cursor),
    hasOlder: hasOlder ?? this.hasOlder,
    loading: loading ?? this.loading,
    loadingOlder: loadingOlder ?? this.loadingOlder,
    catchUpPhase: catchUpPhase ?? this.catchUpPhase,
    error: clearError ? null : (error ?? this.error),
    syncError: clearSyncError ? null : (syncError ?? this.syncError),
  );
}

List<TimelineDisplayItem> _displayCanonical(
  List<TimelineItem> items,
  Map<String, OptimisticUserMessage> presentations,
  Map<String, DateTime> timestamps,
) => [
  for (final item in items)
    TimelineDisplayItem(
      item: item,
      userMessage: item is UserMessageItem ? presentations[item.id] : null,
      timestamp: timestamps[item.id],
    ),
];

List<TimelineDisplayItem> _displayPending(
  List<OptimisticUserMessage> messages,
) => [
  for (final message in messages)
    TimelineDisplayItem(
      item: UserMessageItem(
        id: message.id,
        text: message.text,
        attachments: message.attachments,
      ),
      userMessage: message,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        message.timestamp,
        isUtc: true,
      ),
      optimistic: true,
    ),
];

enum _TimelineSegment { tail, head }

final class TimelineReplicaKey {
  const TimelineReplicaKey({required this.serverId, required this.agentId});

  final String serverId;
  final String agentId;

  @override
  bool operator ==(Object other) =>
      other is TimelineReplicaKey &&
      other.serverId == serverId &&
      other.agentId == agentId;

  @override
  int get hashCode => Object.hash(serverId, agentId);
}

class TimelineReplicaStoreNotifier
    extends Notifier<Map<TimelineReplicaKey, TimelineState>> {
  @override
  Map<TimelineReplicaKey, TimelineState> build() => const {};

  TimelineState? read(TimelineReplicaKey key) => state[key];

  void write(TimelineReplicaKey key, TimelineState value) {
    state = Map.unmodifiable({...state, key: value});
  }

  void clearServer(String serverId) {
    state = Map.unmodifiable({
      for (final entry in state.entries)
        if (entry.key.serverId != serverId) entry.key: entry.value,
    });
  }
}

final timelineReplicaStoreProvider =
    NotifierProvider<
      TimelineReplicaStoreNotifier,
      Map<TimelineReplicaKey, TimelineState>
    >(TimelineReplicaStoreNotifier.new);

/// Removes retained session replicas when their registered host disappears.
/// The app root watches this alongside the concurrent host runtime manager.
final timelineReplicaLifecycleProvider = Provider<void>((ref) {
  ref.listen(hostRegistryProvider, (previous, next) {
    if (previous == null) return;
    final currentServerIds = {for (final host in next.hosts) host.serverId};
    final store = ref.read(timelineReplicaStoreProvider.notifier);
    for (final host in previous.hosts) {
      if (!currentServerIds.contains(host.serverId)) {
        store.clearServer(host.serverId);
      }
    }
  });
});

/// Per-agent Paseo timeline window. Initial and recovery requests load a
/// projected tail; live gaps catch up through `after`; history uses `before`.
class TimelineNotifier extends Notifier<TimelineState> {
  TimelineNotifier(this.agentId);

  final String agentId;
  bool _fetching = false;
  bool _refetchQueued = false;
  bool _refetchQueuedFull = false;
  String _serverId = 'legacy';
  int _generation = 0;

  TimelineReplicaKey get _replicaKey =>
      TimelineReplicaKey(serverId: _serverId, agentId: agentId);

  @override
  TimelineState build() {
    _generation++;
    _fetching = false;
    _refetchQueued = false;
    _refetchQueuedFull = false;
    _serverId = ref.watch(activeHostProvider)?.serverId ?? 'legacy';
    final client = ref.watch(daemonClientProvider);
    final eventSub = client.events.listen(_onEvent);
    final nativeEventSub = client.agentStreamEvents.listen(_onAgentStream);
    final connSub = client.connectionState.listen((connection) {
      if (connection == DaemonConnectionState.connected) _fetch();
    });
    ref.onDispose(() {
      eventSub.cancel();
      nativeEventSub.cancel();
      connSub.cancel();
    });
    if (client.currentState == DaemonConnectionState.connected) {
      Future.microtask(_fetch);
    }
    return ref.read(timelineReplicaStoreProvider.notifier).read(_replicaKey) ??
        const TimelineState();
  }

  void _onEvent(RpcEvent event) {
    if (event.type != MessageTypes.agentStreamEvent) return;
    final AgentStreamPayload payload;
    try {
      payload = AgentStreamPayload.fromJson(event.payload);
    } catch (_) {
      return;
    }
    _onAgentStream(payload);
  }

  void _onAgentStream(AgentStreamPayload payload) {
    if (payload.agentId != agentId) return;
    final eventEpoch = payload.epoch.toString();
    final knownEpoch = state.epoch;
    final decision = classifySessionTimelineSeq(
      // Only a replica with no established epoch is uninitialized. An empty
      // authoritative page establishes the epoch without a cursor range, and
      // that still counts as "known, holding nothing" (endSeq 0) rather than
      // uninitialized.
      cursor: knownEpoch == null
          ? null
          : state.cursor ??
                AgentTimelineCursorRange(
                  epoch: knownEpoch,
                  startSeq: 0,
                  endSeq: 0,
                ),
      epoch: eventEpoch,
      seq: payload.seq,
    );
    switch (decision) {
      case SessionTimelineSeqDecision.init:
        _startLiveEpoch(payload, eventEpoch);
        // The in-flight cold fetch may belong to an older epoch. Always
        // queue an authoritative request for the epoch this event
        // established.
        _fetch(full: true);
      case SessionTimelineSeqDecision.dropEpoch:
        // Paseo accepts seq 1 as the first event of a replacement epoch,
        // which keeps a freshly-created conversation live while its
        // authoritative tail fetch is still in flight.
        if (payload.seq == 1) _startLiveEpoch(payload, eventEpoch);
        _fetch(full: true);
      case SessionTimelineSeqDecision.dropStale:
        return;
      case SessionTimelineSeqDecision.gap:
        _fetch();
      case SessionTimelineSeqDecision.accept:
        _applyLiveUpsert(
          _mergeResolvedPermission(payload.item),
          math.max(state.lastSeq, payload.seq),
          _payloadTimestamp(payload),
        );
    }
  }

  void _startLiveEpoch(AgentStreamPayload payload, String eventEpoch) {
    _publish(
      TimelineState(
        pendingTailUserMessages: state.pendingTailUserMessages,
        pendingHeadUserMessages: state.pendingHeadUserMessages,
        epoch: eventEpoch,
        cursor: AgentTimelineCursorRange(
          epoch: eventEpoch,
          startSeq: payload.seq,
          endSeq: payload.seq,
        ),
        loading: false,
        catchUpPhase: TimelineCatchUpPhase.syncing,
      ),
    );
    _applyLiveUpsert(payload.item, payload.seq, _payloadTimestamp(payload));
  }

  DateTime _payloadTimestamp(AgentStreamPayload payload) {
    final raw = payload.timestamp;
    if (raw != null) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed;
    }
    return DateTime.now().toUtc();
  }

  TimelineItem _mergeResolvedPermission(TimelineItem item) {
    if (item case PermissionItem(
      :final id,
      :final permissionId,
      :final status,
      toolName: '',
    )) {
      final existing = state.items
          .whereType<PermissionItem>()
          .where((candidate) => candidate.id == id)
          .firstOrNull;
      if (existing != null) {
        return PermissionItem(
          id: id,
          permissionId: permissionId,
          toolName: existing.toolName,
          status: status,
          detail: existing.detail,
        );
      }
    }
    return item;
  }

  void _applyLiveUpsert(TimelineItem item, int endSeq, DateTime timestamp) {
    final pendingTail = List<OptimisticUserMessage>.of(
      state.pendingTailUserMessages,
    );
    final pendingHead = List<OptimisticUserMessage>.of(
      state.pendingHeadUserMessages,
    );
    final presentations = Map<String, OptimisticUserMessage>.of(
      state.userMessagePresentations,
    );
    final itemTimestamps = Map<String, DateTime>.of(state.itemTimestamps)
      ..[item.id] = timestamp;
    final matchedSegment = _reconcileUserMessage(
      item,
      pendingTail,
      pendingHead,
      presentations,
      matchFirstOptimistic: true,
    );
    final tail = List<TimelineItem>.of(state.tailItems);
    final head = List<TimelineItem>.of(state.headItems);
    final existingSegment = _replaceExisting(item, tail, head);
    if (existingSegment == null) {
      final target = matchedSegment ?? _TimelineSegment.head;
      (target == _TimelineSegment.head ? head : tail).add(item);
    }
    final cursor = state.cursor;
    _publish(
      state.copyWith(
        tailItems: List.unmodifiable(tail),
        headItems: List.unmodifiable(head),
        pendingTailUserMessages: List.unmodifiable(pendingTail),
        pendingHeadUserMessages: List.unmodifiable(pendingHead),
        userMessagePresentations: Map.unmodifiable(presentations),
        itemTimestamps: Map.unmodifiable(itemTimestamps),
        cursor: cursor == null
            ? AgentTimelineCursorRange(
                epoch: state.epoch!,
                startSeq: endSeq,
                endSeq: endSeq,
              )
            : AgentTimelineCursorRange(
                epoch: cursor.epoch,
                startSeq: cursor.startSeq,
                endSeq: math.max(cursor.endSeq, endSeq),
              ),
        loading: false,
      ),
    );
  }

  bool appendOptimisticUserMessage(OptimisticUserMessage message) {
    if (state.items.any((item) => item.id == message.id) ||
        state.pendingUserMessages.any((item) => item.id == message.id)) {
      return false;
    }
    final useHead =
        state.headItems.isNotEmpty || state.pendingHeadUserMessages.isNotEmpty;
    _publish(
      useHead
          ? state.copyWith(
              pendingHeadUserMessages: List.unmodifiable([
                ...state.pendingHeadUserMessages,
                message,
              ]),
            )
          : state.copyWith(
              pendingTailUserMessages: List.unmodifiable([
                ...state.pendingTailUserMessages,
                message,
              ]),
            ),
    );
    return true;
  }

  bool handoffCreatedUserMessage(OptimisticUserMessage message) {
    final firstUser = state.items.whereType<UserMessageItem>().firstOrNull;
    if (firstUser == null) return appendOptimisticUserMessage(message);
    if (state.userMessagePresentations.containsKey(firstUser.id)) return false;
    _publish(
      state.copyWith(
        pendingTailUserMessages: List.unmodifiable([
          for (final current in state.pendingTailUserMessages)
            if (current.id != message.id) current,
        ]),
        pendingHeadUserMessages: List.unmodifiable([
          for (final current in state.pendingHeadUserMessages)
            if (current.id != message.id) current,
        ]),
        userMessagePresentations: Map.unmodifiable({
          ...state.userMessagePresentations,
          firstUser.id: message,
        }),
      ),
    );
    return true;
  }

  bool removeOptimisticUserMessage(String messageId) {
    final tail = [
      for (final message in state.pendingTailUserMessages)
        if (message.id != messageId) message,
    ];
    final head = [
      for (final message in state.pendingHeadUserMessages)
        if (message.id != messageId) message,
    ];
    if (tail.length == state.pendingTailUserMessages.length &&
        head.length == state.pendingHeadUserMessages.length) {
      return false;
    }
    _publish(
      state.copyWith(
        pendingTailUserMessages: List.unmodifiable(tail),
        pendingHeadUserMessages: List.unmodifiable(head),
      ),
    );
    return true;
  }

  void clearOptimisticUserMessages() {
    if (state.pendingUserMessages.isEmpty) return;
    _publish(
      state.copyWith(
        pendingTailUserMessages: const [],
        pendingHeadUserMessages: const [],
      ),
    );
  }

  Future<bool> loadOlder() async {
    final generation = _generation;
    final cursor = state.cursor;
    if (cursor == null || !state.hasOlder || state.loadingOlder) return false;
    _publish(state.copyWith(loadingOlder: true, clearError: true));
    try {
      final page = await ref
          .read(daemonClientProvider)
          .fetchAgentTimeline(
            agentId: agentId,
            direction: AgentTimelineDirection.before,
            cursor: cursor.start,
          );
      if (!ref.mounted || generation != _generation) return false;
      if (page.reset || page.epoch != state.epoch) {
        _applyTailPage(page);
      } else {
        _applyBeforePage(page);
      }
      return true;
    } catch (error) {
      if (!ref.mounted || generation != _generation) return false;
      _publish(state.copyWith(error: error.toString()));
      return false;
    } finally {
      if (ref.mounted && generation == _generation) {
        _publish(state.copyWith(loadingOlder: false));
      }
    }
  }

  /// Re-runs the authoritative tail sync after an initial or catch-up failure.
  ///
  /// Paseo keeps an already rendered timeline visible while retrying, but a
  /// cold open returns to its blocking loading state until the first
  /// authoritative page arrives.
  Future<void> retry() async {
    final isColdOpen = state.epoch == null;
    _publish(state.copyWith(loading: isColdOpen, clearError: true));
    await _fetch(full: true);
  }

  Future<void> _fetch({bool full = false}) async {
    final generation = _generation;
    final requestEpoch = state.epoch;
    if (_fetching) {
      _refetchQueued = true;
      _refetchQueuedFull = _refetchQueuedFull || full;
      return;
    }
    _fetching = true;
    final isCatchUp = state.epoch != null;
    if (isCatchUp) {
      _publish(state.copyWith(catchUpPhase: TimelineCatchUpPhase.syncing));
    }
    try {
      final client = ref.read(daemonClientProvider);
      final cursor = full ? null : state.cursor;
      if (cursor == null) {
        final page = await client.fetchAgentTimeline(agentId: agentId);
        if (!ref.mounted || generation != _generation) return;
        if (_isSupersededFetchPage(requestEpoch, page)) return;
        _applyTailPage(page);
      } else {
        var afterCursor = cursor.end;
        while (true) {
          final page = await client.fetchAgentTimeline(
            agentId: agentId,
            direction: AgentTimelineDirection.after,
            cursor: afterCursor,
          );
          if (!ref.mounted || generation != _generation) return;
          if (_isSupersededFetchPage(requestEpoch, page)) return;
          if (page.reset || page.epoch != state.epoch) {
            _applyTailPage(page);
            break;
          }
          _applyAfterPage(page);
          final end = page.endCursor;
          if (!page.hasNewer || end == null || end.seq <= afterCursor.seq) {
            break;
          }
          afterCursor = end;
        }
        _publish(
          state.copyWith(
            catchUpPhase: TimelineCatchUpPhase.idle,
            clearError: true,
            clearSyncError: true,
          ),
        );
      }
    } catch (error) {
      if (!ref.mounted || generation != _generation) return;
      if (isCatchUp) {
        _publish(
          state.copyWith(
            loading: false,
            catchUpPhase: TimelineCatchUpPhase.error,
            syncError: error.toString(),
          ),
        );
      } else {
        _publish(state.copyWith(loading: false, error: error.toString()));
      }
    } finally {
      if (ref.mounted && generation == _generation) {
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

  bool _isSupersededFetchPage(String? requestEpoch, AgentTimelinePage page) {
    final currentEpoch = state.epoch;
    return currentEpoch != requestEpoch &&
        currentEpoch != null &&
        page.epoch != currentEpoch;
  }

  void _applyTailPage(AgentTimelinePage page) {
    final pendingTail = List<OptimisticUserMessage>.of(
      state.pendingTailUserMessages,
    );
    final pendingHead = List<OptimisticUserMessage>.of(
      state.pendingHeadUserMessages,
    );
    final presentations = Map<String, OptimisticUserMessage>.of(
      state.userMessagePresentations,
    );
    final pageCursor = page.cursorRange;
    final currentCursor = state.cursor;
    final retainsLiveHead =
        !page.reset &&
        state.epoch == page.epoch &&
        currentCursor != null &&
        (pageCursor == null || currentCursor.endSeq > pageCursor.endSeq);
    final head = retainsLiveHead
        ? List<TimelineItem>.of(state.headItems)
        : const <TimelineItem>[];
    final headIds = head.map((item) => item.id).toSet();
    // A tail response can have been captured before a later live update for
    // the same item id. The live head owns that newer version until a tail
    // reaches its cursor; never regress completed/error state to the stale
    // projected copy.
    final items = [
      for (final entry in page.entries)
        if (!headIds.contains(entry.item.id)) entry.item,
    ];
    for (final item in items) {
      _reconcileUserMessage(item, pendingTail, pendingHead, presentations);
    }
    for (final item in head) {
      _reconcileUserMessage(item, pendingTail, pendingHead, presentations);
    }
    final pageIds = items.map((item) => item.id).toSet();
    final liveIds = {...pageIds, for (final item in head) item.id};
    final entryTimestamps = {
      for (final entry in page.entries) entry.item.id: entry.timestamp,
    };
    final itemTimestamps = <String, DateTime>{
      for (final item in items)
        item.id: _parseEntryTimestamp(entryTimestamps[item.id]!),
      for (final item in head) item.id: ?state.itemTimestamps[item.id],
    };
    final cursor = pageCursor == null
        ? (retainsLiveHead ? currentCursor : null)
        : AgentTimelineCursorRange(
            epoch: pageCursor.epoch,
            startSeq: pageCursor.startSeq,
            endSeq: retainsLiveHead
                ? math.max(pageCursor.endSeq, currentCursor.endSeq)
                : pageCursor.endSeq,
          );
    _publish(
      TimelineState(
        tailItems: List.unmodifiable(items),
        headItems: List.unmodifiable(head),
        pendingTailUserMessages: List.unmodifiable(pendingTail),
        pendingHeadUserMessages: List.unmodifiable(pendingHead),
        userMessagePresentations: Map.unmodifiable({
          for (final entry in presentations.entries)
            if (liveIds.contains(entry.key)) entry.key: entry.value,
        }),
        itemTimestamps: Map.unmodifiable(itemTimestamps),
        epoch: page.epoch,
        cursor: cursor,
        hasOlder: page.hasOlder,
        loading: false,
        catchUpPhase: TimelineCatchUpPhase.idle,
        error: null,
        syncError: null,
      ),
    );
  }

  void _applyAfterPage(AgentTimelinePage page) {
    // Never apply a forward page that is stale, from another epoch, or that
    // starts past the end of what the replica holds (which would leave a
    // hole). A gap cursor means catch up first instead.
    final acceptance = acceptIncrementalTimelineUnits(
      page: page,
      currentCursor: state.cursor,
    );
    if (!acceptance.accepted) {
      // Leave the cursor untouched so the next catch-up re-requests from the
      // same position. Re-fetching from here instead would risk ping-ponging
      // against a host that keeps answering with the same gapped window.
      return;
    }
    final pendingTail = List<OptimisticUserMessage>.of(
      state.pendingTailUserMessages,
    );
    final pendingHead = List<OptimisticUserMessage>.of(
      state.pendingHeadUserMessages,
    );
    final presentations = Map<String, OptimisticUserMessage>.of(
      state.userMessagePresentations,
    );
    final tail = List<TimelineItem>.of(state.tailItems);
    final head = List<TimelineItem>.of(state.headItems);
    final itemTimestamps = Map<String, DateTime>.of(state.itemTimestamps);
    for (final entry in page.entries) {
      final item = entry.item;
      final matched = _reconcileUserMessage(
        item,
        pendingTail,
        pendingHead,
        presentations,
      );
      if (_replaceExisting(item, tail, head) == null) {
        (matched == _TimelineSegment.tail ? tail : head).add(item);
      }
      itemTimestamps[item.id] = _parseEntryTimestamp(entry.timestamp);
    }
    _publish(
      state.copyWith(
        tailItems: List.unmodifiable(tail),
        headItems: List.unmodifiable(head),
        pendingTailUserMessages: List.unmodifiable(pendingTail),
        pendingHeadUserMessages: List.unmodifiable(pendingHead),
        userMessagePresentations: Map.unmodifiable(presentations),
        itemTimestamps: Map.unmodifiable(itemTimestamps),
        cursor:
            acceptance.cursor ?? _combineCursor(state.cursor, page.cursorRange),
        hasOlder: state.hasOlder || page.hasOlder,
        loading: false,
      ),
    );
  }

  void _applyBeforePage(AgentTimelinePage page) {
    // An older page must sit strictly below what the replica already holds;
    // anything overlapping or newer would duplicate or reorder history.
    final acceptance = acceptOlderTimelineUnits(
      page: page,
      currentCursor: state.cursor,
    );
    if (!acceptance.accepted) {
      _publish(state.copyWith(hasOlder: page.hasOlder, clearError: true));
      return;
    }
    final presentations = Map<String, OptimisticUserMessage>.of(
      state.userMessagePresentations,
    );
    final pendingTail = List<OptimisticUserMessage>.of(
      state.pendingTailUserMessages,
    );
    final pendingHead = List<OptimisticUserMessage>.of(
      state.pendingHeadUserMessages,
    );
    final tail = List<TimelineItem>.of(state.tailItems);
    final head = List<TimelineItem>.of(state.headItems);
    final older = <TimelineItem>[];
    final itemTimestamps = Map<String, DateTime>.of(state.itemTimestamps);
    for (final entry in page.entries) {
      final item = entry.item;
      _reconcileUserMessage(item, pendingTail, pendingHead, presentations);
      if (_replaceExisting(item, tail, head) == null) older.add(item);
      itemTimestamps[item.id] = _parseEntryTimestamp(entry.timestamp);
    }
    final pageCursor = page.cursorRange;
    final currentCursor = state.cursor;
    final cursor = pageCursor == null
        ? currentCursor
        : AgentTimelineCursorRange(
            epoch: pageCursor.epoch,
            startSeq: pageCursor.startSeq,
            endSeq: currentCursor?.endSeq ?? pageCursor.endSeq,
          );
    _publish(
      state.copyWith(
        tailItems: List.unmodifiable([...older, ...tail]),
        headItems: List.unmodifiable(head),
        pendingTailUserMessages: List.unmodifiable(pendingTail),
        pendingHeadUserMessages: List.unmodifiable(pendingHead),
        userMessagePresentations: Map.unmodifiable(presentations),
        itemTimestamps: Map.unmodifiable(itemTimestamps),
        cursor: cursor,
        hasOlder: page.hasOlder,
        loading: false,
        clearError: true,
      ),
    );
  }

  DateTime _parseEntryTimestamp(String raw) =>
      DateTime.tryParse(raw) ?? DateTime.now().toUtc();

  _TimelineSegment? _replaceExisting(
    TimelineItem item,
    List<TimelineItem> tail,
    List<TimelineItem> head,
  ) {
    final tailIndex = tail.indexWhere((current) => current.id == item.id);
    if (tailIndex >= 0) {
      tail[tailIndex] = item;
      return _TimelineSegment.tail;
    }
    final headIndex = head.indexWhere((current) => current.id == item.id);
    if (headIndex >= 0) {
      head[headIndex] = item;
      return _TimelineSegment.head;
    }
    return null;
  }

  _TimelineSegment? _reconcileUserMessage(
    TimelineItem item,
    List<OptimisticUserMessage> pendingTail,
    List<OptimisticUserMessage> pendingHead,
    Map<String, OptimisticUserMessage> presentations, {
    bool matchFirstOptimistic = false,
  }) {
    if (item is! UserMessageItem) return null;
    final matchId = item.clientMessageId?.isNotEmpty == true
        ? item.clientMessageId!
        : item.id;
    var index = pendingTail.indexWhere((message) => message.id == matchId);
    if (index >= 0) {
      presentations[item.id] = pendingTail.removeAt(index);
      return _TimelineSegment.tail;
    }
    index = pendingHead.indexWhere((message) => message.id == matchId);
    if (index >= 0) {
      presentations[item.id] = pendingHead.removeAt(index);
      return _TimelineSegment.head;
    }
    if (!matchFirstOptimistic) return null;
    if (pendingTail.isNotEmpty) {
      presentations[item.id] = pendingTail.removeAt(0);
      return _TimelineSegment.tail;
    }
    if (pendingHead.isNotEmpty) {
      presentations[item.id] = pendingHead.removeAt(0);
      return _TimelineSegment.head;
    }
    return null;
  }

  AgentTimelineCursorRange? _combineCursor(
    AgentTimelineCursorRange? current,
    AgentTimelineCursorRange? page,
  ) {
    if (current == null) return page;
    if (page == null) return current;
    return AgentTimelineCursorRange(
      epoch: page.epoch,
      startSeq: math.min(current.startSeq, page.startSeq),
      endSeq: math.max(current.endSeq, page.endSeq),
    );
  }

  void _publish(TimelineState next) {
    state = next;
    ref.read(timelineReplicaStoreProvider.notifier).write(_replicaKey, next);
    ref
        .read(timelineAttachmentOwnersProvider.notifier)
        .replaceAgent('${_serverId}_$agentId', next.attachmentIds);
  }
}

final timelineProvider =
    NotifierProvider.family<TimelineNotifier, TimelineState, String>(
      TimelineNotifier.new,
    );

final timelineCountProvider = Provider.family<int, String>(
  (ref, agentId) =>
      ref.watch(timelineProvider(agentId).select((s) => s.displayItems.length)),
);

class TimelineAttachmentOwnersNotifier
    extends Notifier<Map<String, Set<String>>> {
  @override
  Map<String, Set<String>> build() => const {};

  void replaceAgent(String agentId, Set<String> attachmentIds) {
    final next = Map<String, Set<String>>.of(state);
    if (attachmentIds.isEmpty) {
      next.remove(agentId);
    } else {
      next[agentId] = Set.unmodifiable(attachmentIds);
    }
    state = Map.unmodifiable(next);
  }

  Set<String> attachmentIds() => {for (final ids in state.values) ...ids};
}

final timelineAttachmentOwnersProvider =
    NotifierProvider<
      TimelineAttachmentOwnersNotifier,
      Map<String, Set<String>>
    >(TimelineAttachmentOwnersNotifier.new);
