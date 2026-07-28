import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';

const providerSubagentTimelinePageSize = 40;

final class ProviderSubagentTimelineState {
  const ProviderSubagentTimelineState({
    this.epoch = '',
    this.rows = const [],
    this.loading = false,
    this.hasOlder = false,
    this.hasNewer = false,
    this.gap = false,
  });

  final String epoch;
  final List<ProviderSubagentTimelineRow> rows;
  final bool loading;
  final bool hasOlder;
  final bool hasNewer;
  final bool gap;

  int get lastSeq => rows.isEmpty ? 0 : rows.last.seq;

  /// The wire replica retains canonical revisions. Paseo's stream projection
  /// shows the newest revision of a stable item only once.
  List<ProviderSubagentTimelineRow> get projectedRows {
    final result = <ProviderSubagentTimelineRow>[];
    final indexById = <String, int>{};
    for (final row in rows) {
      final index = indexById[row.item.id];
      if (index == null) {
        indexById[row.item.id] = result.length;
        result.add(row);
      } else {
        result[index] = row;
      }
    }
    return result;
  }
}

final class ProviderSubagentsState {
  const ProviderSubagentsState({
    this.descriptors = const {},
    this.timelines = const {},
    this.hiddenFromTrack = const {},
    this.loading = true,
  });

  final Map<String, ProviderSubagentDescriptor> descriptors;
  final Map<String, ProviderSubagentTimelineState> timelines;
  final Set<String> hiddenFromTrack;
  final bool loading;

  List<ProviderSubagentDescriptor> get visibleDescriptors => [
    for (final descriptor in descriptors.values)
      if (!hiddenFromTrack.contains(descriptor.id)) descriptor,
  ]..sort((left, right) => left.createdAt.compareTo(right.createdAt));
}

final class ProviderSubagentsNotifier extends Notifier<ProviderSubagentsState> {
  ProviderSubagentsNotifier(this.parentAgentId);

  final String parentAgentId;
  final Set<String> _recovering = {};

  @override
  ProviderSubagentsState build() {
    final client = ref.watch(daemonClientProvider);
    final events = client.events.listen(_onEvent);
    final connection = client.connectionState.listen((state) {
      if (state == DaemonConnectionState.connected) unawaited(refresh());
    });
    ref.onDispose(() {
      events.cancel();
      connection.cancel();
    });
    if (client.currentState == DaemonConnectionState.connected) {
      Future.microtask(refresh);
    }
    return const ProviderSubagentsState();
  }

  Future<void> refresh() async {
    try {
      final response = await ref.read(daemonClientProvider).request(
        MessageTypes.providerSubagentListRequest,
        {'parentAgentId': parentAgentId},
      );
      if (!ref.mounted) return;
      final descriptors = <String, ProviderSubagentDescriptor>{
        for (final value in (response['subagents'] as List? ?? const []))
          if (value is Map)
            ProviderSubagentDescriptor.fromJson(
              value.cast<String, Object?>(),
            ).id: ProviderSubagentDescriptor.fromJson(
              value.cast<String, Object?>(),
            ),
      };
      final hiddenFromTrack = Set<String>.of(state.hiddenFromTrack);
      for (final descriptor in descriptors.values) {
        if (descriptor.status == ProviderSubagentStatus.running) {
          hiddenFromTrack.remove(descriptor.id);
        }
      }
      state = ProviderSubagentsState(
        descriptors: descriptors,
        timelines: {
          for (final entry in state.timelines.entries)
            if (descriptors.containsKey(entry.key)) entry.key: entry.value,
        },
        hiddenFromTrack: hiddenFromTrack,
        loading: false,
      );
    } on Object {
      if (ref.mounted) {
        state = ProviderSubagentsState(
          descriptors: state.descriptors,
          timelines: state.timelines,
          hiddenFromTrack: state.hiddenFromTrack,
          loading: false,
        );
      }
    }
  }

  Future<void> loadTimeline(String subagentId) async {
    final current = state.timelines[subagentId];
    state = ProviderSubagentsState(
      descriptors: state.descriptors,
      timelines: {
        ...state.timelines,
        subagentId: ProviderSubagentTimelineState(
          epoch: current?.epoch ?? '',
          rows: current?.rows ?? const [],
          loading: true,
          hasOlder: current?.hasOlder ?? false,
          hasNewer: current?.hasNewer ?? false,
          gap: current?.gap ?? false,
        ),
      },
      hiddenFromTrack: state.hiddenFromTrack,
      loading: state.loading,
    );
    try {
      final response = await ref
          .read(daemonClientProvider)
          .request(MessageTypes.providerSubagentTimelineRequest, {
            'parentAgentId': parentAgentId,
            'subagentId': subagentId,
            'direction': ProviderSubagentTimelineDirection.tail.name,
            'limit': providerSubagentTimelinePageSize,
          });
      if (!ref.mounted) return;
      _applyTimelinePage(
        subagentId,
        ProviderSubagentTimelineResponse.fromJson(response),
      );
    } on Object {
      if (!ref.mounted) return;
      state = ProviderSubagentsState(
        descriptors: state.descriptors,
        timelines: {
          ...state.timelines,
          subagentId: ProviderSubagentTimelineState(
            epoch: current?.epoch ?? '',
            rows: current?.rows ?? const [],
            hasOlder: current?.hasOlder ?? false,
            hasNewer: current?.hasNewer ?? false,
            gap: current?.gap ?? false,
          ),
        },
        hiddenFromTrack: state.hiddenFromTrack,
        loading: state.loading,
      );
    }
  }

  Future<void> loadOlder(String subagentId) async {
    final current = state.timelines[subagentId];
    if (current == null ||
        current.loading ||
        !current.hasOlder ||
        current.epoch.isEmpty ||
        current.rows.isEmpty) {
      return;
    }
    _replaceTimeline(
      subagentId,
      ProviderSubagentTimelineState(
        epoch: current.epoch,
        rows: current.rows,
        loading: true,
        hasOlder: current.hasOlder,
        hasNewer: current.hasNewer,
        gap: current.gap,
      ),
    );
    try {
      final response = await ref
          .read(daemonClientProvider)
          .request(MessageTypes.providerSubagentTimelineRequest, {
            'parentAgentId': parentAgentId,
            'subagentId': subagentId,
            'direction': ProviderSubagentTimelineDirection.before.name,
            'cursor': ProviderSubagentTimelineCursor(
              epoch: current.epoch,
              seq: current.rows.first.seq,
            ).toJson(),
            'limit': providerSubagentTimelinePageSize,
          });
      if (!ref.mounted) return;
      _applyTimelinePage(
        subagentId,
        ProviderSubagentTimelineResponse.fromJson(response),
      );
    } on Object {
      if (!ref.mounted) return;
      _replaceTimeline(
        subagentId,
        ProviderSubagentTimelineState(
          epoch: current.epoch,
          rows: current.rows,
          hasOlder: current.hasOlder,
          hasNewer: current.hasNewer,
          gap: current.gap,
        ),
      );
    }
  }

  void _replaceTimeline(
    String subagentId,
    ProviderSubagentTimelineState timeline,
  ) {
    state = ProviderSubagentsState(
      descriptors: state.descriptors,
      timelines: {...state.timelines, subagentId: timeline},
      hiddenFromTrack: state.hiddenFromTrack,
      loading: state.loading,
    );
  }

  void _applyTimelinePage(
    String subagentId,
    ProviderSubagentTimelineResponse response,
  ) {
    if (response.error != null) {
      throw StateError(response.error!);
    }
    final existing = state.timelines[subagentId];
    final fetched = {for (final row in response.rows) row.seq: row};
    final Map<int, ProviderSubagentTimelineRow> merged;
    if (response.reset ||
        existing == null ||
        existing.epoch != response.epoch) {
      merged = fetched;
    } else if (response.direction == ProviderSubagentTimelineDirection.tail) {
      merged = fetched;
      var nextSeq = response.rows.isEmpty
          ? response.window.maxSeq + 1
          : response.rows.last.seq + 1;
      for (final row in existing.rows) {
        if (row.seq < nextSeq) continue;
        if (row.seq != nextSeq) break;
        merged[row.seq] = row;
        nextSeq += 1;
      }
    } else {
      merged = {for (final row in existing.rows) row.seq: row, ...fetched};
    }
    final rows = merged.values.toList()
      ..sort((left, right) => left.seq.compareTo(right.seq));
    _replaceTimeline(
      subagentId,
      ProviderSubagentTimelineState(
        epoch: response.epoch,
        rows: rows,
        hasOlder: response.hasOlder,
        hasNewer: response.hasNewer,
      ),
    );
  }

  void _scheduleRecovery(String subagentId, {int? afterSeq}) {
    if (_recovering.contains(subagentId)) return;
    _recovering.add(subagentId);
    Future.microtask(() async {
      try {
        final current = state.timelines[subagentId];
        final useAfter =
            afterSeq != null && current != null && current.epoch.isNotEmpty;
        final response = await ref
            .read(daemonClientProvider)
            .request(MessageTypes.providerSubagentTimelineRequest, {
              'parentAgentId': parentAgentId,
              'subagentId': subagentId,
              'direction': useAfter
                  ? ProviderSubagentTimelineDirection.after.name
                  : ProviderSubagentTimelineDirection.tail.name,
              if (useAfter)
                'cursor': ProviderSubagentTimelineCursor(
                  epoch: current.epoch,
                  seq: afterSeq,
                ).toJson(),
              'limit': useAfter ? 0 : providerSubagentTimelinePageSize,
            });
        if (!ref.mounted) return;
        _applyTimelinePage(
          subagentId,
          ProviderSubagentTimelineResponse.fromJson(response),
        );
      } on Object {
        // A later event or an explicit panel refresh retries recovery.
      } finally {
        _recovering.remove(subagentId);
      }
    });
  }

  void _onEvent(RpcEvent event) {
    if (event.type != MessageTypes.providerSubagentUpdateEvent) return;
    final ProviderSubagentUpdate update;
    try {
      update = ProviderSubagentUpdate.fromJson(event.payload);
    } on Object {
      return;
    }
    switch (update) {
      case ProviderSubagentUpsert(:final subagent):
        if (subagent.parentAgentId != parentAgentId) return;
        final hiddenFromTrack = Set<String>.of(state.hiddenFromTrack);
        if (subagent.status == ProviderSubagentStatus.running) {
          hiddenFromTrack.remove(subagent.id);
        }
        state = ProviderSubagentsState(
          descriptors: {...state.descriptors, subagent.id: subagent},
          timelines: state.timelines,
          hiddenFromTrack: hiddenFromTrack,
          loading: false,
        );
      case ProviderSubagentTimelineUpdate(
        :final parentAgentId,
        :final subagentId,
        :final item,
        :final timestamp,
        :final seq,
        :final epoch,
      ):
        if (parentAgentId != this.parentAgentId) return;
        final current = state.timelines[subagentId];
        if (current != null &&
            current.epoch.isNotEmpty &&
            current.epoch != epoch) {
          _replaceTimeline(
            subagentId,
            ProviderSubagentTimelineState(
              epoch: current.epoch,
              rows: current.rows,
              hasOlder: current.hasOlder,
              hasNewer: current.hasNewer,
              gap: true,
            ),
          );
          _scheduleRecovery(subagentId);
          return;
        }
        final rows = List<ProviderSubagentTimelineRow>.of(
          current?.rows ?? const <ProviderSubagentTimelineRow>[],
        );
        final previousLastSeq = current?.lastSeq ?? 0;
        final row = ProviderSubagentTimelineRow(
          item: item,
          timestamp: timestamp,
          seq: seq,
        );
        final index = rows.indexWhere((existing) => existing.seq == seq);
        if (index < 0) {
          rows.add(row);
          rows.sort((a, b) => a.seq.compareTo(b.seq));
        } else {
          rows[index] = row;
        }
        final hasGap = seq > previousLastSeq + 1;
        _replaceTimeline(
          subagentId,
          ProviderSubagentTimelineState(
            epoch: epoch,
            rows: rows,
            hasOlder: current?.hasOlder ?? false,
            hasNewer: current?.hasNewer ?? false,
            gap: hasGap,
          ),
        );
        if (hasGap) {
          _scheduleRecovery(
            subagentId,
            afterSeq: previousLastSeq == 0 ? null : previousLastSeq,
          );
        }
      case ProviderSubagentRemove(:final parentAgentId, :final subagentId):
        if (parentAgentId != this.parentAgentId) return;
        state = ProviderSubagentsState(
          descriptors: Map.of(state.descriptors)..remove(subagentId),
          timelines: Map.of(state.timelines)..remove(subagentId),
          hiddenFromTrack: state.hiddenFromTrack,
          loading: state.loading,
        );
    }
  }

  void hideFinished() {
    final hidden = Set<String>.of(state.hiddenFromTrack);
    for (final descriptor in state.descriptors.values) {
      if (descriptor.status != ProviderSubagentStatus.running) {
        hidden.add(descriptor.id);
      }
    }
    state = ProviderSubagentsState(
      descriptors: state.descriptors,
      timelines: state.timelines,
      hiddenFromTrack: hidden,
      loading: state.loading,
    );
  }
}

final providerSubagentsProvider =
    NotifierProvider.family<
      ProviderSubagentsNotifier,
      ProviderSubagentsState,
      String
    >(ProviderSubagentsNotifier.new);
