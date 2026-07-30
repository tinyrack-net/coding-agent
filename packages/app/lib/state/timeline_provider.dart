import 'dart:async';
import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../attachments/attachment_store.dart';
import '../core/daemon_client.dart';
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

final class TimelineDisplayItem {
  const TimelineDisplayItem({required this.item, this.userMessage});

  final TimelineItem item;
  final OptimisticUserMessage? userMessage;
}

/// Paseo keeps the authoritative tail page separate from the active stream
/// head. This lets older pages prepend without disturbing live item identity.
class TimelineState {
  const TimelineState({
    this.tailItems = const [],
    this.headItems = const [],
    this.pendingTailUserMessages = const [],
    this.pendingHeadUserMessages = const [],
    this.userMessagePresentations = const {},
    this.epoch,
    this.cursor,
    this.hasOlder = false,
    this.loading = true,
    this.loadingOlder = false,
    this.error,
  });

  final List<TimelineItem> tailItems;
  final List<TimelineItem> headItems;
  final List<OptimisticUserMessage> pendingTailUserMessages;
  final List<OptimisticUserMessage> pendingHeadUserMessages;
  final Map<String, OptimisticUserMessage> userMessagePresentations;
  final String? epoch;
  final AgentTimelineCursorRange? cursor;
  final bool hasOlder;
  final bool loading;
  final bool loadingOlder;
  final String? error;

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
    ..._displayCanonical(tailItems, userMessagePresentations),
    ..._displayPending(pendingTailUserMessages),
  ];

  List<TimelineDisplayItem> get headDisplayItems => [
    ..._displayCanonical(headItems, userMessagePresentations),
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
    String? epoch,
    bool clearEpoch = false,
    AgentTimelineCursorRange? cursor,
    bool clearCursor = false,
    bool? hasOlder,
    bool? loading,
    bool? loadingOlder,
    String? error,
    bool clearError = false,
  }) => TimelineState(
    tailItems: tailItems ?? this.tailItems,
    headItems: headItems ?? this.headItems,
    pendingTailUserMessages:
        pendingTailUserMessages ?? this.pendingTailUserMessages,
    pendingHeadUserMessages:
        pendingHeadUserMessages ?? this.pendingHeadUserMessages,
    userMessagePresentations:
        userMessagePresentations ?? this.userMessagePresentations,
    epoch: clearEpoch ? null : (epoch ?? this.epoch),
    cursor: clearCursor ? null : (cursor ?? this.cursor),
    hasOlder: hasOlder ?? this.hasOlder,
    loading: loading ?? this.loading,
    loadingOlder: loadingOlder ?? this.loadingOlder,
    error: clearError ? null : (error ?? this.error),
  );
}

List<TimelineDisplayItem> _displayCanonical(
  List<TimelineItem> items,
  Map<String, OptimisticUserMessage> presentations,
) => [
  for (final item in items)
    TimelineDisplayItem(
      item: item,
      userMessage: item is UserMessageItem ? presentations[item.id] : null,
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
    if (state.epoch == null) {
      _fetch();
      return;
    }
    if (eventEpoch != state.epoch) {
      _fetch(full: true);
      return;
    }
    if (payload.seq > state.lastSeq + 1) {
      _fetch();
      return;
    }
    _applyLiveUpsert(
      _mergeResolvedPermission(payload.item),
      math.max(state.lastSeq, payload.seq),
    );
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

  void _applyLiveUpsert(TimelineItem item, int endSeq) {
    final pendingTail = List<OptimisticUserMessage>.of(
      state.pendingTailUserMessages,
    );
    final pendingHead = List<OptimisticUserMessage>.of(
      state.pendingHeadUserMessages,
    );
    final presentations = Map<String, OptimisticUserMessage>.of(
      state.userMessagePresentations,
    );
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
        clearError: true,
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
    if (_fetching) {
      _refetchQueued = true;
      _refetchQueuedFull = _refetchQueuedFull || full;
      return;
    }
    _fetching = true;
    try {
      final client = ref.read(daemonClientProvider);
      final cursor = full ? null : state.cursor;
      if (cursor == null) {
        final page = await client.fetchAgentTimeline(agentId: agentId);
        if (!ref.mounted || generation != _generation) return;
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
      }
    } catch (error) {
      if (!ref.mounted || generation != _generation) return;
      _publish(state.copyWith(loading: false, error: error.toString()));
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
    final items = [for (final entry in page.entries) entry.item];
    for (final item in items) {
      _reconcileUserMessage(item, pendingTail, pendingHead, presentations);
    }
    final liveIds = items.map((item) => item.id).toSet();
    _publish(
      TimelineState(
        tailItems: List.unmodifiable(items),
        pendingTailUserMessages: List.unmodifiable(pendingTail),
        pendingHeadUserMessages: List.unmodifiable(pendingHead),
        userMessagePresentations: Map.unmodifiable({
          for (final entry in presentations.entries)
            if (liveIds.contains(entry.key)) entry.key: entry.value,
        }),
        epoch: page.epoch,
        cursor: page.cursorRange,
        hasOlder: page.hasOlder,
        loading: false,
        error: null,
      ),
    );
  }

  void _applyAfterPage(AgentTimelinePage page) {
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
    }
    _publish(
      state.copyWith(
        tailItems: List.unmodifiable(tail),
        headItems: List.unmodifiable(head),
        pendingTailUserMessages: List.unmodifiable(pendingTail),
        pendingHeadUserMessages: List.unmodifiable(pendingHead),
        userMessagePresentations: Map.unmodifiable(presentations),
        cursor: _combineCursor(state.cursor, page.cursorRange),
        hasOlder: state.hasOlder || page.hasOlder,
        loading: false,
        clearError: true,
      ),
    );
  }

  void _applyBeforePage(AgentTimelinePage page) {
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
    for (final entry in page.entries) {
      final item = entry.item;
      _reconcileUserMessage(item, pendingTail, pendingHead, presentations);
      if (_replaceExisting(item, tail, head) == null) older.add(item);
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
        cursor: cursor,
        hasOlder: page.hasOlder,
        loading: false,
        clearError: true,
      ),
    );
  }

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
