import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';
import '../providers/draft_provider_features.dart';

final class DraftProviderFeaturesState {
  const DraftProviderFeaturesState({
    this.features = const [],
    this.isLoading = false,
    this.isFetching = false,
    this.error,
  });

  final List<AgentFeature> features;
  final bool isLoading;
  final bool isFetching;
  final Object? error;

  DraftProviderFeaturesState copyWith({
    List<AgentFeature>? features,
    bool? isLoading,
    bool? isFetching,
    Object? error = _absent,
  }) => DraftProviderFeaturesState(
    features: features ?? this.features,
    isLoading: isLoading ?? this.isLoading,
    isFetching: isFetching ?? this.isFetching,
    error: identical(error, _absent) ? this.error : error,
  );
}

const _absent = Object();

final class DraftProviderFeaturesNotifier
    extends Notifier<DraftProviderFeaturesState> {
  DraftProviderFeaturesNotifier(this.scope);

  final DraftProviderFeaturesScope scope;
  Future<void>? _operation;
  DateTime? _fetchedAt;

  bool get _canFetch =>
      scope.enabled &&
      scope.serverId.isNotEmpty &&
      scope.draftConfig.provider.isNotEmpty &&
      scope.draftConfig.cwd.trim().isNotEmpty &&
      scope.client.currentState == DaemonConnectionState.connected;

  @override
  DraftProviderFeaturesState build() {
    final subscription = scope.client.connectionState.listen((connection) {
      if (connection == DaemonConnectionState.connected) {
        unawaited(fetch(force: true));
      }
    });
    ref.onDispose(() => unawaited(subscription.cancel()));
    if (_canFetch) Future<void>.microtask(fetch);
    return DraftProviderFeaturesState(isLoading: _canFetch);
  }

  Future<void> fetch({bool force = false}) async {
    if (!_canFetch || (!force && !_isStale)) return;
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
    return fetchedAt == null ||
        DateTime.now().difference(fetchedAt) >= const Duration(minutes: 5);
  }

  Future<void> _fetch() async {
    state = state.copyWith(
      isLoading: state.features.isEmpty,
      isFetching: true,
      error: null,
    );
    try {
      final response = await scope.client.listProviderFeatures(
        draftConfig: scope.draftConfig,
      );
      if (!ref.mounted) return;
      if (response.error case final error?) throw StateError(error);
      _fetchedAt = DateTime.now();
      state = DraftProviderFeaturesState(
        features: List.unmodifiable(response.features ?? const []),
      );
    } catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(isLoading: false, isFetching: false, error: error);
    }
  }
}

final draftProviderFeaturesProvider =
    NotifierProvider.family<
      DraftProviderFeaturesNotifier,
      DraftProviderFeaturesState,
      DraftProviderFeaturesScope
    >(DraftProviderFeaturesNotifier.new);
