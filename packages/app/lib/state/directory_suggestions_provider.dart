import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/daemon_client.dart';

final class DirectorySuggestionsScope {
  const DirectorySuggestionsScope({
    required this.client,
    required this.serverId,
    required this.cwd,
    required this.query,
    required this.enabled,
    this.includeFiles = true,
    this.includeDirectories = true,
    this.limit = 50,
  });

  final DaemonClient client;
  final String serverId;
  final String cwd;
  final String query;
  final bool enabled;
  final bool includeFiles;
  final bool includeDirectories;
  final int limit;

  String get cacheKey =>
      '$serverId\u0000$cwd\u0000$includeFiles\u0000$includeDirectories';

  String get queryCacheKey => '$cacheKey\u0000$query\u0000$limit';

  @override
  bool operator ==(Object other) =>
      other is DirectorySuggestionsScope &&
      identical(client, other.client) &&
      serverId == other.serverId &&
      cwd == other.cwd &&
      query == other.query &&
      enabled == other.enabled &&
      includeFiles == other.includeFiles &&
      includeDirectories == other.includeDirectories &&
      limit == other.limit;

  @override
  int get hashCode => Object.hash(
    identityHashCode(client),
    serverId,
    cwd,
    query,
    enabled,
    includeFiles,
    includeDirectories,
    limit,
  );
}

final class DirectorySuggestionsState {
  const DirectorySuggestionsState({
    this.entries = const [],
    this.isLoading = false,
    this.isFetching = false,
    this.error,
  });

  final List<DirectorySuggestionEntry> entries;
  final bool isLoading;
  final bool isFetching;
  final Object? error;
}

final class _CachedSuggestions {
  const _CachedSuggestions(this.entries, this.fetchedAt);

  final List<DirectorySuggestionEntry> entries;
  final DateTime fetchedAt;
}

final _lastEntriesByScope = <String, List<DirectorySuggestionEntry>>{};
final _cacheByQuery = <String, _CachedSuggestions>{};

final class DirectorySuggestionsNotifier
    extends Notifier<DirectorySuggestionsState> {
  DirectorySuggestionsNotifier(this.scope);

  final DirectorySuggestionsScope scope;
  Future<void>? _operation;

  bool get _canFetch =>
      scope.enabled &&
      scope.serverId.isNotEmpty &&
      scope.cwd.trim().isNotEmpty &&
      scope.client.currentState == DaemonConnectionState.connected;

  @override
  DirectorySuggestionsState build() {
    final previous = _lastEntriesByScope[scope.cacheKey] ?? const [];
    final subscription = scope.client.connectionState.listen((connection) {
      if (connection == DaemonConnectionState.connected) {
        unawaited(fetch(force: true));
      }
    });
    ref.onDispose(() => unawaited(subscription.cancel()));
    if (_canFetch) Future<void>.microtask(fetch);
    return DirectorySuggestionsState(
      entries: previous,
      isLoading: _canFetch && previous.isEmpty,
    );
  }

  Future<void> fetch({bool force = false}) async {
    if (!_canFetch) return;
    final cached = _cacheByQuery[scope.queryCacheKey];
    if (!force &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) <
            const Duration(seconds: 15)) {
      state = DirectorySuggestionsState(entries: cached.entries);
      return;
    }
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

  Future<void> _fetch() async {
    state = DirectorySuggestionsState(
      entries: state.entries,
      isLoading: state.entries.isEmpty,
      isFetching: true,
    );
    try {
      final response = await scope.client.getDirectorySuggestions(
        cwd: scope.cwd,
        query: scope.query,
        includeFiles: scope.includeFiles,
        includeDirectories: scope.includeDirectories,
        limit: scope.limit,
      );
      if (!ref.mounted) return;
      if (response.error case final error?) throw StateError(error);
      final entries = List<DirectorySuggestionEntry>.unmodifiable(
        response.entries.isNotEmpty
            ? response.entries
            : [
                for (final directory in response.directories)
                  DirectorySuggestionEntry(
                    path: directory,
                    kind: DirectorySuggestionKind.directory,
                  ),
              ],
      );
      _lastEntriesByScope[scope.cacheKey] = entries;
      _cacheByQuery[scope.queryCacheKey] = _CachedSuggestions(
        entries,
        DateTime.now(),
      );
      state = DirectorySuggestionsState(entries: entries);
    } catch (error) {
      if (!ref.mounted) return;
      state = DirectorySuggestionsState(entries: state.entries, error: error);
    }
  }
}

final directorySuggestionsProvider =
    NotifierProvider.family<
      DirectorySuggestionsNotifier,
      DirectorySuggestionsState,
      DirectorySuggestionsScope
    >(DirectorySuggestionsNotifier.new);
