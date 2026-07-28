import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../providers/agent_commands.dart';

final class AgentCommandsState {
  const AgentCommandsState({
    this.commands = const [],
    this.isLoading = false,
    this.isFetching = false,
    this.error,
  });

  final List<AgentSlashCommand> commands;
  final bool isLoading;
  final bool isFetching;
  final Object? error;

  bool get isError => error != null;

  AgentCommandsState copyWith({
    List<AgentSlashCommand>? commands,
    bool? isLoading,
    bool? isFetching,
    Object? error = _absent,
  }) => AgentCommandsState(
    commands: commands ?? this.commands,
    isLoading: isLoading ?? this.isLoading,
    isFetching: isFetching ?? this.isFetching,
    error: identical(error, _absent) ? this.error : error,
  );
}

const _absent = Object();
final _notifiersByServer = <String, Set<AgentCommandsNotifier>>{};

void invalidateAgentCommandsForServer(String serverId) {
  for (final notifier in [...?_notifiersByServer[serverId]]) {
    notifier.invalidate();
  }
}

final class AgentCommandsNotifier extends Notifier<AgentCommandsState> {
  AgentCommandsNotifier(this.scope);

  final AgentCommandsScope scope;
  Future<void>? _operation;
  DateTime? _fetchedAt;

  bool get _canFetch =>
      scope.enabled &&
      scope.serverId.isNotEmpty &&
      (scope.agentId.isNotEmpty || scope.draftConfig != null) &&
      scope.client.currentState == DaemonConnectionState.connected;

  @override
  AgentCommandsState build() {
    final registered = _notifiersByServer.putIfAbsent(scope.serverId, () => {});
    registered.add(this);
    final subscription = scope.client.connectionState.listen((connection) {
      if (connection == DaemonConnectionState.connected) {
        unawaited(fetch(force: true));
      }
    });
    ref.onDispose(() {
      registered.remove(this);
      if (registered.isEmpty) _notifiersByServer.remove(scope.serverId);
      unawaited(subscription.cancel());
    });
    if (_canFetch) Future<void>.microtask(fetch);
    return AgentCommandsState(isLoading: _canFetch);
  }

  Future<void> ensureLoaded() => fetch();

  void invalidate() {
    _fetchedAt = null;
    if (_canFetch) unawaited(fetch(force: true));
  }

  Future<void> fetch({bool force = false}) async {
    if (!_canFetch) return;
    if (!force && !_isStale) return;
    final existing = _operation;
    if (existing != null) return existing;
    final operation = _fetch();
    _operation = operation;
    try {
      await operation;
    } finally {
      if (identical(_operation, operation)) _operation = null;
    }
  }

  bool get _isStale {
    final fetchedAt = _fetchedAt;
    if (fetchedAt == null) return true;
    if (scope.isDraft) return false;
    return DateTime.now().difference(fetchedAt) >= const Duration(minutes: 1);
  }

  Future<void> _fetch() async {
    state = state.copyWith(
      isLoading: state.commands.isEmpty,
      isFetching: true,
      error: null,
    );
    try {
      final response = await scope.client.listCommands(
        agentId: scope.agentId,
        draftConfig: scope.draftConfig,
      );
      if (!ref.mounted) return;
      if (response.error case final error?) {
        throw StateError(error);
      }
      _fetchedAt = DateTime.now();
      state = AgentCommandsState(
        commands: List.unmodifiable(response.commands),
      );
    } catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(isLoading: false, isFetching: false, error: error);
    }
  }
}

final agentCommandsProvider =
    NotifierProvider.family<
      AgentCommandsNotifier,
      AgentCommandsState,
      AgentCommandsScope
    >(AgentCommandsNotifier.new);
