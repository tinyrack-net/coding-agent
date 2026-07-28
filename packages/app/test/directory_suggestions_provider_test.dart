import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/state/directory_suggestions_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _SuggestionsClient extends DaemonClient {
  _SuggestionsClient() : super(uri: Uri.parse('ws://fake'));

  final connections = StreamController<DaemonConnectionState>.broadcast();
  DaemonConnectionState current = DaemonConnectionState.connected;
  int calls = 0;
  String? lastQuery;
  String? lastCwd;
  int? lastLimit;
  Object? error;
  bool legacyDirectoriesOnly = false;

  @override
  DaemonConnectionState get currentState => current;

  @override
  Stream<DaemonConnectionState> get connectionState => connections.stream;

  @override
  Future<DirectorySuggestionsResponse> getDirectorySuggestions({
    required String query,
    String? cwd,
    bool? includeFiles,
    bool? includeDirectories,
    DirectorySuggestionMatchMode? matchMode,
    int? limit,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls++;
    lastQuery = query;
    lastCwd = cwd;
    lastLimit = limit;
    final failure = error;
    if (failure != null) throw failure;
    return DirectorySuggestionsResponse(
      directories: const ['src'],
      entries: legacyDirectoriesOnly
          ? const []
          : const [
              DirectorySuggestionEntry(
                path: 'src/main.dart',
                kind: DirectorySuggestionKind.file,
              ),
            ],
      requestId: 'request-$calls',
    );
  }

  @override
  void dispose() {
    connections.close();
    super.dispose();
  }
}

void main() {
  test('scope identity includes host, cwd, query, flags, and client', () {
    final client = _SuggestionsClient();
    final otherClient = _SuggestionsClient();
    addTearDown(client.dispose);
    addTearDown(otherClient.dispose);
    final scope = DirectorySuggestionsScope(
      client: client,
      serverId: 'host-scope',
      cwd: 'C:/repo',
      query: 'src',
      enabled: true,
    );
    final equal = DirectorySuggestionsScope(
      client: client,
      serverId: 'host-scope',
      cwd: 'C:/repo',
      query: 'src',
      enabled: true,
    );

    expect(scope, equal);
    expect(
      scope,
      isNot(
        DirectorySuggestionsScope(
          client: otherClient,
          serverId: 'host-scope',
          cwd: 'C:/repo',
          query: 'src',
          enabled: true,
        ),
      ),
    );
    expect(scope.cacheKey, contains('C:/repo'));
    expect(scope.queryCacheKey, contains('src'));
  });

  test('fetches, caches, reconnects, and preserves data on error', () async {
    final client = _SuggestionsClient();
    addTearDown(client.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final provider = directorySuggestionsProvider(
      DirectorySuggestionsScope(
        client: client,
        serverId: 'host-fetch',
        cwd: 'C:/repo/fetch',
        query: 'main',
        enabled: true,
      ),
    );
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    final notifier = container.read(provider.notifier);

    await notifier.fetch();
    expect(client.calls, 1);
    expect(container.read(provider).entries.single.path, 'src/main.dart');
    expect(client.lastQuery, 'main');
    expect(client.lastCwd, 'C:/repo/fetch');
    expect(client.lastLimit, 50);
    await notifier.fetch();
    expect(client.calls, 1);

    client.connections.add(DaemonConnectionState.connected);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(client.calls, 2);

    client.error = StateError('offline');
    await notifier.fetch(force: true);
    expect(container.read(provider).entries.single.path, 'src/main.dart');
    expect('${container.read(provider).error}', contains('offline'));
  });

  test(
    'maps legacy directories and gates disabled/disconnected scopes',
    () async {
      final client = _SuggestionsClient()..legacyDirectoriesOnly = true;
      addTearDown(client.dispose);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final legacy = directorySuggestionsProvider(
        DirectorySuggestionsScope(
          client: client,
          serverId: 'host-legacy',
          cwd: 'C:/repo/legacy',
          query: '',
          enabled: true,
        ),
      );
      final subscription = container.listen(legacy, (_, _) {});
      addTearDown(subscription.close);
      await container.read(legacy.notifier).fetch();
      expect(container.read(legacy).entries.single.toJson(), {
        'path': 'src',
        'kind': 'directory',
      });

      client.current = DaemonConnectionState.disconnected;
      final disconnected = directorySuggestionsProvider(
        DirectorySuggestionsScope(
          client: client,
          serverId: 'host-disconnected',
          cwd: 'C:/repo',
          query: '',
          enabled: true,
        ),
      );
      await container.read(disconnected.notifier).fetch();
      final disabled = directorySuggestionsProvider(
        DirectorySuggestionsScope(
          client: client,
          serverId: 'host-disabled',
          cwd: 'C:/repo',
          query: '',
          enabled: false,
        ),
      );
      await container.read(disabled.notifier).fetch();
      expect(client.calls, 1);
      expect(container.read(disabled).isLoading, isFalse);
    },
  );
}
