import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../providers/providers_snapshot.dart';
import 'agent_commands_provider.dart';

final class ProvidersSnapshotState {
  const ProvidersSnapshotState({
    this.entries,
    this.generatedAt,
    this.isLoading = false,
    this.isFetching = false,
    this.isRefreshing = false,
    this.error,
    required this.supportsSnapshot,
  });

  final List<ProviderSnapshotEntry>? entries;
  final String? generatedAt;
  final bool isLoading;
  final bool isFetching;
  final bool isRefreshing;
  final String? error;
  final bool supportsSnapshot;

  ProvidersSnapshotState copyWith({
    List<ProviderSnapshotEntry>? entries,
    String? generatedAt,
    bool? isLoading,
    bool? isFetching,
    bool? isRefreshing,
    Object? error = _absent,
  }) => ProvidersSnapshotState(
    entries: entries ?? this.entries,
    generatedAt: generatedAt ?? this.generatedAt,
    isLoading: isLoading ?? this.isLoading,
    isFetching: isFetching ?? this.isFetching,
    isRefreshing: isRefreshing ?? this.isRefreshing,
    error: identical(error, _absent) ? this.error : error as String?,
    supportsSnapshot: supportsSnapshot,
  );
}

const _absent = Object();
final _notifiersByServer = <String, Set<ProvidersSnapshotNotifier>>{};

void invalidateProvidersSnapshotRoot(String serverId) {
  for (final notifier in [...?_notifiersByServer[serverId]]) {
    notifier.invalidate();
  }
}

final class ProvidersSnapshotNotifier extends Notifier<ProvidersSnapshotState> {
  ProvidersSnapshotNotifier(this.scope);

  final ProvidersSnapshotScope scope;
  int _generation = 0;
  Future<void>? _fetchOperation;

  bool get _canFetch =>
      state.supportsSnapshot &&
      scope.enabled &&
      scope.serverId?.isNotEmpty == true &&
      scope.client.currentState == DaemonConnectionState.connected;

  @override
  ProvidersSnapshotState build() {
    final supported =
        scope.client.serverInfo?.features['providersSnapshot'] == true;
    if (!supported) {
      return const ProvidersSnapshotState(supportsSnapshot: false);
    }
    final serverId = scope.serverId;
    final registered = serverId == null
        ? null
        : _notifiersByServer.putIfAbsent(serverId, () => {});
    registered?.add(this);
    final updateSubscription = scope.client.providersSnapshotUpdates.listen(
      _applyUpdate,
    );
    final connectionSubscription = scope.client.connectionState.listen((
      connection,
    ) {
      if (connection == DaemonConnectionState.connected) {
        unawaited(fetch());
      }
    });
    ref.onDispose(() {
      registered?.remove(this);
      if (registered?.isEmpty == true) _notifiersByServer.remove(serverId);
      unawaited(updateSubscription.cancel());
      unawaited(connectionSubscription.cancel());
    });
    final shouldLoad =
        scope.enabled &&
        scope.serverId?.isNotEmpty == true &&
        scope.client.currentState == DaemonConnectionState.connected;
    if (shouldLoad) Future<void>.microtask(fetch);
    return ProvidersSnapshotState(
      isLoading: shouldLoad,
      supportsSnapshot: true,
    );
  }

  Future<void> fetch() async {
    if (!_canFetch) return;
    final existing = _fetchOperation;
    if (existing != null) return existing;
    final operation = _fetch();
    _fetchOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_fetchOperation, operation)) _fetchOperation = null;
    }
  }

  Future<void> ensureLoaded() =>
      state.entries == null ? fetch() : Future<void>.value();

  Future<void> _fetch() async {
    final generation = ++_generation;
    state = state.copyWith(
      isLoading: state.entries == null,
      isFetching: true,
      error: null,
    );
    try {
      final response = await scope.client.fetchProvidersSnapshot(
        cwd: scope.cwd,
      );
      if (!ref.mounted || generation != _generation) return;
      state = state.copyWith(
        entries: List.unmodifiable(response.entries),
        generatedAt: response.generatedAt,
        isLoading: false,
        isFetching: false,
        error: null,
      );
    } catch (error) {
      if (!ref.mounted || generation != _generation) return;
      state = state.copyWith(
        isLoading: false,
        isFetching: false,
        error: '$error',
      );
    }
  }

  Future<void> refresh([List<String>? providers]) async {
    if (!state.supportsSnapshot ||
        scope.serverId?.isNotEmpty != true ||
        state.isRefreshing) {
      return;
    }
    state = state.copyWith(isRefreshing: true, error: null);
    try {
      await scope.client.refreshProvidersSnapshot(
        cwd: scope.cwd,
        providers: providers,
      );
      await fetch();
      invalidateAgentCommandsForServer(scope.serverId!);
      if (scope.isHomeScope) {
        invalidateProvidersSnapshotRoot(scope.serverId!);
      }
    } catch (error) {
      if (ref.mounted) state = state.copyWith(error: '$error');
    } finally {
      if (ref.mounted) state = state.copyWith(isRefreshing: false);
    }
  }

  void refetchIfStale([String? selectedProvider]) {
    final decision = selectorOpenRefetchDecision(
      entries: [
        for (final entry in state.entries ?? const <ProviderSnapshotEntry>[])
          ProviderSnapshotStatus(
            provider: entry.provider,
            loading: entry.status == ProviderCatalogStatus.loading,
          ),
      ],
      selectedProvider: selectedProvider,
    );
    if (decision == SelectorOpenRefetchDecision.refetchAlways &&
        !state.isFetching) {
      unawaited(fetch());
    }
  }

  void invalidate() {
    if (_canFetch) unawaited(fetch());
  }

  void _applyUpdate(ProvidersSnapshotUpdate update) {
    if (normalizeProvidersSnapshotCwd(update.cwd) != scope.cwd) return;
    _generation++;
    state = state.copyWith(
      entries: List.unmodifiable(update.entries),
      generatedAt: update.generatedAt,
      isLoading: false,
      isFetching: false,
      error: null,
    );
    final serverId = scope.serverId;
    if (serverId != null) invalidateAgentCommandsForServer(serverId);
  }
}

final providersSnapshotProvider =
    NotifierProvider.family<
      ProvidersSnapshotNotifier,
      ProvidersSnapshotState,
      ProvidersSnapshotScope
    >(ProvidersSnapshotNotifier.new);
