import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/providers/provider_command_templates.dart';
import 'package:coding_agent_app/providers/agent_commands.dart';
import 'package:coding_agent_app/providers/providers_snapshot.dart';
import 'package:coding_agent_app/state/agent_commands_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/providers_snapshot_provider.dart';
import 'package:coding_agent_app/state/providers_snapshot_lifecycle_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _ready = ProviderSnapshotEntry(
  provider: 'codex',
  status: ProviderCatalogStatus.ready,
  label: 'Codex',
);

final class _SnapshotClient extends DaemonClient {
  _SnapshotClient({this.supported = true})
    : super(uri: Uri.parse('ws://fake')) {
    serverInfo = ServerInfoStatus(
      serverId: 'server-1',
      hostname: 'fake',
      version: '0.2.0',
      desktopManaged: false,
      features: {'providersSnapshot': supported},
    );
  }

  final bool supported;
  final updates = StreamController<ProvidersSnapshotUpdate>.broadcast();
  final connections = StreamController<DaemonConnectionState>.broadcast();
  List<ProviderSnapshotEntry> entries = const [_ready];
  Object? fetchError;
  Object? refreshError;
  int fetchCalls = 0;
  int refreshCalls = 0;
  String? lastCwd;
  List<String>? lastProviders;
  int commandCalls = 0;
  DaemonConnectionState current = DaemonConnectionState.connected;

  @override
  DaemonConnectionState get currentState => current;

  @override
  Stream<ProvidersSnapshotUpdate> get providersSnapshotUpdates =>
      updates.stream;

  @override
  Stream<DaemonConnectionState> get connectionState => connections.stream;

  @override
  Future<GetProvidersSnapshotResponse> fetchProvidersSnapshot({
    String? cwd,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    fetchCalls++;
    lastCwd = cwd;
    if (fetchError case final error?) throw error;
    return GetProvidersSnapshotResponse(
      entries: entries,
      generatedAt: 'generated-$fetchCalls',
      requestId: 'fetch-$fetchCalls',
    );
  }

  @override
  Future<RefreshProvidersSnapshotResponse> refreshProvidersSnapshot({
    String? cwd,
    List<String>? providers,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    refreshCalls++;
    lastCwd = cwd;
    lastProviders = providers;
    if (refreshError case final error?) throw error;
    return RefreshProvidersSnapshotResponse(
      requestId: 'refresh-$refreshCalls',
      acknowledged: true,
    );
  }

  @override
  Future<ListCommandsResponse> listCommands({
    required String agentId,
    ListCommandsDraftConfig? draftConfig,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    commandCalls++;
    return ListCommandsResponse(
      agentId: agentId,
      commands: const [],
      requestId: 'commands-$commandCalls',
    );
  }

  @override
  void dispose() {
    updates.close();
    connections.close();
    super.dispose();
  }
}

void main() {
  test('normalizes cwd and builds frozen query identities', () {
    final client = _SnapshotClient();
    addTearDown(client.dispose);
    final home = ProvidersSnapshotScope(
      client: client,
      serverId: 'server-1',
      cwd: ' ',
    );
    final cwd = ProvidersSnapshotScope(
      client: client,
      serverId: 'server-1',
      cwd: r' C:\repo\\ ',
    );

    expect(home.cwd, isNull);
    expect(home.isHomeScope, isTrue);
    expect(cwd.isHomeScope, isFalse);
    expect(home.queryRoot, ['providersSnapshot', 'server-1']);
    expect(home.queryKey, ['providersSnapshot', 'server-1', 'home']);
    expect(cwd.cwd, 'C:/repo');
    expect(cwd.queryKey, ['providersSnapshot', 'server-1', 'cwd', 'C:/repo']);
    expect(normalizeProvidersSnapshotCwd('/'), '/');
    expect(normalizeProvidersSnapshotCwd('///'), '/');
    expect(
      cwd,
      ProvidersSnapshotScope(
        client: client,
        serverId: 'server-1',
        cwd: 'C:/repo/',
      ),
    );
  });

  test('selector refetch decision follows selected loading entry', () {
    expect(
      selectorOpenRefetchDecision(entries: null),
      SelectorOpenRefetchDecision.refetchStale,
    );
    expect(
      selectorOpenRefetchDecision(
        entries: const [
          ProviderSnapshotStatus(provider: 'codex', loading: true),
        ],
        selectedProvider: 'codex',
      ),
      SelectorOpenRefetchDecision.refetchAlways,
    );
    expect(
      selectorOpenRefetchDecision(
        entries: const [
          ProviderSnapshotStatus(provider: 'codex', loading: false),
        ],
        selectedProvider: 'codex',
      ),
      SelectorOpenRefetchDecision.refetchStale,
    );
    expect(
      selectorOpenRefetchDecision(
        entries: const [
          ProviderSnapshotStatus(provider: 'claude', loading: false),
        ],
        selectedProvider: 'codex',
      ),
      SelectorOpenRefetchDecision.refetchAlways,
    );
  });

  test('loads, refreshes, applies scoped pushes, and reconnects', () async {
    final client = _SnapshotClient();
    addTearDown(client.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final scope = ProvidersSnapshotScope(
      client: client,
      serverId: 'server-1',
      cwd: 'C:\\repo\\',
    );
    final provider = providersSnapshotProvider(scope);
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    final notifier = container.read(provider.notifier);

    await notifier.ensureLoaded();
    expect(container.read(provider).entries, const [_ready]);
    expect(client.lastCwd, 'C:/repo');
    expect(client.fetchCalls, 1);
    await notifier.ensureLoaded();
    expect(client.fetchCalls, 1);

    notifier.refetchIfStale('claude');
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(client.fetchCalls, 2);

    client.entries = const [
      ProviderSnapshotEntry(
        provider: 'claude',
        status: ProviderCatalogStatus.ready,
      ),
    ];
    await notifier.refresh(const ['claude']);
    expect(client.refreshCalls, 1);
    expect(client.lastProviders, ['claude']);
    expect(container.read(provider).entries!.single.provider, 'claude');

    client.updates.add(
      const ProvidersSnapshotUpdate(
        cwd: '/other',
        entries: [],
        generatedAt: 'ignored',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(container.read(provider).entries, isNotEmpty);

    client.updates.add(
      const ProvidersSnapshotUpdate(
        cwd: 'C:/repo/',
        entries: [_ready],
        generatedAt: 'pushed',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(container.read(provider).generatedAt, 'pushed');

    client.connections.add(DaemonConnectionState.connected);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(client.fetchCalls, 4);
  });

  test('reports errors and gates unsupported hosts', () async {
    final failing = _SnapshotClient()..fetchError = StateError('offline');
    addTearDown(failing.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final scope = ProvidersSnapshotScope(client: failing, serverId: 'server-1');
    final provider = providersSnapshotProvider(scope);
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    await container.read(provider.notifier).ensureLoaded();
    expect(container.read(provider).error, contains('offline'));

    final unsupported = _SnapshotClient(supported: false);
    addTearDown(unsupported.dispose);
    final unsupportedScope = ProvidersSnapshotScope(
      client: unsupported,
      serverId: 'server-1',
    );
    final unsupportedProvider = providersSnapshotProvider(unsupportedScope);
    expect(container.read(unsupportedProvider).supportsSnapshot, isFalse);
    await container.read(unsupportedProvider.notifier).refresh();
    expect(unsupported.fetchCalls, 0);
    expect(unsupported.refreshCalls, 0);

    failing.fetchError = null;
    failing.refreshError = StateError('refresh offline');
    await container.read(provider.notifier).refresh();
    expect(container.read(provider).error, contains('refresh offline'));
    expect(container.read(provider).isRefreshing, isFalse);
  });

  test('gates disabled scopes and invalidates dependent replicas', () async {
    final client = _SnapshotClient();
    addTearDown(client.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final disabled = providersSnapshotProvider(
      ProvidersSnapshotScope(
        client: client,
        serverId: 'server-1',
        enabled: false,
      ),
    );
    final disabledSubscription = container.listen(disabled, (_, _) {});
    addTearDown(disabledSubscription.close);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(disabled).supportsSnapshot, isTrue);
    expect(client.fetchCalls, 0);

    final commands = agentCommandsProvider(
      AgentCommandsScope(
        client: client,
        serverId: 'server-1',
        agentId: 'agent-1',
      ),
    );
    final commandSubscription = container.listen(commands, (_, _) {});
    addTearDown(commandSubscription.close);
    await container.read(commands.notifier).ensureLoaded();
    expect(client.commandCalls, 1);

    final home = providersSnapshotProvider(
      ProvidersSnapshotScope(client: client, serverId: 'server-1'),
    );
    final cwd = providersSnapshotProvider(
      ProvidersSnapshotScope(
        client: client,
        serverId: 'server-1',
        cwd: 'C:/repo',
      ),
    );
    final homeSubscription = container.listen(home, (_, _) {});
    final cwdSubscription = container.listen(cwd, (_, _) {});
    addTearDown(homeSubscription.close);
    addTearDown(cwdSubscription.close);
    await container.read(home.notifier).ensureLoaded();
    await container.read(cwd.notifier).ensureLoaded();
    final beforeRefresh = client.fetchCalls;

    await container.read(home.notifier).refresh();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(client.fetchCalls, greaterThanOrEqualTo(beforeRefresh + 3));
    expect(client.commandCalls, greaterThanOrEqualTo(2));

    final beforePush = client.commandCalls;
    client.updates.add(
      const ProvidersSnapshotUpdate(entries: [_ready], generatedAt: 'push'),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(client.commandCalls, greaterThan(beforePush));
  });

  test('prefetches the connected home scope once per host runtime', () async {
    final client = _SnapshotClient();
    addTearDown(client.dispose);
    final container = ProviderContainer(
      overrides: [
        hostRuntimeClientsProvider.overrideWithValue({'server-1': client}),
      ],
    );
    addTearDown(container.dispose);

    container.read(providersSnapshotReplicaLifecycleProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(client.fetchCalls, 1);
    final state = container.read(
      providersSnapshotProvider(
        ProvidersSnapshotScope(client: client, serverId: 'server-1'),
      ),
    );
    expect(state.entries, const [_ready]);
  });

  test('waits for a connected host before loading', () async {
    final client = _SnapshotClient()
      ..current = DaemonConnectionState.disconnected;
    addTearDown(client.dispose);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final provider = providersSnapshotProvider(
      ProvidersSnapshotScope(client: client, serverId: 'server-1'),
    );
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);

    await container.read(provider.notifier).ensureLoaded();
    expect(client.fetchCalls, 0);
    expect(container.read(provider).isLoading, isFalse);

    client.current = DaemonConnectionState.connected;
    client.connections.add(DaemonConnectionState.connected);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(client.fetchCalls, 1);
  });

  test('builds frozen provider-native resume commands', () {
    expect(
      buildProviderResumeCommand(provider: 'codex', sessionId: 'thread-1'),
      'codex resume thread-1',
    );
    expect(
      buildProviderResumeCommand(provider: 'claude', sessionId: 'session-1'),
      'claude --resume session-1',
    );
    expect(
      buildProviderResumeCommand(provider: 'pi', sessionId: 'p'),
      'pi --session p',
    );
    expect(
      buildProviderResumeCommand(provider: 'omp', sessionId: 'o'),
      'omp --session o',
    );
    expect(
      buildProviderResumeCommand(provider: 'opencode', sessionId: 'x'),
      'opencode --session x',
    );
    expect(
      buildProviderResumeCommand(provider: 'custom', sessionId: 'x'),
      isNull,
    );
  });
}
