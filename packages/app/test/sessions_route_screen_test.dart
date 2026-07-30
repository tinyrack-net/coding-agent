import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/app_router.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/sessions_screen.dart';
import 'package:coding_agent_app/state/agent_history_provider.dart';
import 'package:coding_agent_app/state/daemon_lifecycle_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('global Sessions waits for host registry hydration', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final registry = _RouteRegistry();
    final client = _RouteDaemonClient();
    final router = buildAppRouter(initialLocation: '/sessions');
    addTearDown(client.dispose);
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(() => registry),
          agentHistoryProvider.overrideWith(_EmptyHistory.new),
          daemonClientProvider.overrideWithValue(client),
          connectionStateProvider.overrideWith(
            (ref) => Stream.value(DaemonConnectionState.connected),
          ),
          desktopShellProvider.overrideWithValue(false),
        ],
        child: FluentApp.router(routerConfig: router),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('sessions-route-loading')),
      findsOneWidget,
    );
    expect(find.byType(SessionsScreen), findsNothing);

    registry.complete(activeServerId: 'server-a');
    await tester.pump();
    await tester.pump();

    expect(find.byType(SessionsScreen), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/sessions');
  });

  testWidgets(
    'legacy host Sessions deep link waits, then canonically replaces route',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final registry = _RouteRegistry();
      final client = _RouteDaemonClient();
      final router = buildAppRouter(
        initialLocation: 'coding-agent://h/server-a/sessions',
      );
      addTearDown(client.dispose);
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            hostRegistryProvider.overrideWith(() => registry),
            agentHistoryProvider.overrideWith(_EmptyHistory.new),
            daemonClientProvider.overrideWithValue(client),
            connectionStateProvider.overrideWith(
              (ref) => Stream.value(DaemonConnectionState.connected),
            ),
            desktopShellProvider.overrideWithValue(false),
          ],
          child: FluentApp.router(routerConfig: router),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('host-sessions-route-loading')),
        findsOneWidget,
      );
      expect(
        router.routeInformationProvider.value.uri.path,
        '/h/server-a/sessions',
      );

      registry.complete(activeServerId: 'server-b');
      await tester.pump();
      await tester.pump();

      expect(router.routeInformationProvider.value.uri.path, '/sessions');
      expect(router.canPop(), isFalse);
      expect(registry.selectHostCalls, isEmpty);
      expect(registry.state.activeServerId, 'server-b');
      expect(find.byType(SessionsScreen), findsOneWidget);
    },
  );

  testWidgets('unknown legacy host Sessions route falls back after hydration', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final registry = _RouteRegistry();
    final client = _RouteDaemonClient();
    final router = buildAppRouter(initialLocation: '/h/removed/sessions');
    addTearDown(client.dispose);
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(() => registry),
          agentHistoryProvider.overrideWith(_EmptyHistory.new),
          daemonClientProvider.overrideWithValue(client),
          connectionStateProvider.overrideWith(
            (ref) => Stream.value(DaemonConnectionState.connected),
          ),
          desktopShellProvider.overrideWithValue(false),
        ],
        child: FluentApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    registry.complete(activeServerId: 'server-a');
    await tester.pump();
    await tester.pump();

    expect(router.routeInformationProvider.value.uri.path, '/open-project');
    expect(router.canPop(), isFalse);
  });
}

final class _EmptyHistory extends AgentHistoryNotifier {
  @override
  Future<AgentHistoryState> build() async => const AgentHistoryState();
}

final class _RouteRegistry extends HostRegistryNotifier {
  final selectHostCalls = <String>[];

  @override
  HostRegistryState build() => const HostRegistryState();

  void complete({required String activeServerId}) {
    state = HostRegistryState(
      hosts: const [
        HostProfile(
          serverId: 'server-a',
          label: 'Host A',
          connections: [
            DirectTcpHostConnection(
              id: 'direct:a.example:6868',
              endpoint: 'a.example:6868',
            ),
          ],
          preferredConnectionId: 'direct:a.example:6868',
          createdAt: '2026-07-30T00:00:00.000Z',
          updatedAt: '2026-07-30T00:00:00.000Z',
        ),
        HostProfile(
          serverId: 'server-b',
          label: 'Host B',
          connections: [
            DirectTcpHostConnection(
              id: 'direct:b.example:6868',
              endpoint: 'b.example:6868',
            ),
          ],
          preferredConnectionId: 'direct:b.example:6868',
          createdAt: '2026-07-30T00:00:00.000Z',
          updatedAt: '2026-07-30T00:00:00.000Z',
        ),
      ],
      activeServerId: activeServerId,
      loaded: true,
    );
  }

  @override
  Future<void> selectHost(String serverId) async {
    selectHostCalls.add(serverId);
    await super.selectHost(serverId);
  }
}

final class _RouteDaemonClient extends DaemonClient {
  _RouteDaemonClient() : super(uri: Uri.parse('ws://fake'));

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async => switch (type) {
    MessageTypes.agentListRequest => const {'agents': []},
    MessageTypes.providerListRequest => const {'providers': []},
    MessageTypes.projectListRequest => const {'projects': []},
    _ => const {},
  };
}
