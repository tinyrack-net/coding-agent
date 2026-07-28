import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/host_settings_route_screen.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('activates the route host before rendering its connections', (
    tester,
  ) async {
    final client = DaemonClient(uri: Uri.parse('ws://a.example:6868'));
    addTearDown(client.dispose);
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_RouteRegistry.new),
          daemonClientProvider.overrideWithValue(client),
          connectionStateProvider.overrideWith((ref) => const Stream.empty()),
        ],
        child: Builder(
          builder: (context) {
            container = ProviderScope.containerOf(context);
            return const FluentApp(
              home: HostSettingsRouteScreen(
                serverId: 'server-a',
                section: 'connections',
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(container.read(hostRegistryProvider).activeServerId, 'server-a');
    expect(find.text('Connections'), findsOneWidget);
    expect(find.text('Host A'), findsOneWidget);
  });

  testWidgets('rejects unknown host route ids', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [hostRegistryProvider.overrideWith(_RouteRegistry.new)],
        child: const FluentApp(
          home: HostSettingsRouteScreen(
            serverId: 'missing',
            section: 'connections',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Host not found'), findsOneWidget);
  });

  testWidgets('shows registry loading state', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [hostRegistryProvider.overrideWith(_LoadingRegistry.new)],
        child: const FluentApp(
          home: HostSettingsRouteScreen(
            serverId: 'server-a',
            section: 'connections',
          ),
        ),
      ),
    );
    expect(find.byType(ProgressRing), findsOneWidget);
  });

  testWidgets('reacts to a changed route host', (tester) async {
    final client = DaemonClient(uri: Uri.parse('ws://a.example:6868'));
    addTearDown(client.dispose);
    var serverId = 'server-a';
    late StateSetter update;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_RouteRegistry.new),
          daemonClientProvider.overrideWithValue(client),
          connectionStateProvider.overrideWith((ref) => const Stream.empty()),
        ],
        child: FluentApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return HostSettingsRouteScreen(
                serverId: serverId,
                section: 'connections',
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    update(() => serverId = 'server-b');
    await tester.pumpAndSettle();
    expect(find.text('Host B'), findsOneWidget);
  });

  testWidgets('routes host providers to the Paseo ACP catalog', (tester) async {
    final client = DaemonClient(uri: Uri.parse('ws://a.example:6868'));
    addTearDown(client.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(_RouteRegistry.new),
          daemonClientProvider.overrideWithValue(client),
          connectionStateProvider.overrideWith((ref) => const Stream.empty()),
        ],
        child: const FluentApp(
          home: HostSettingsRouteScreen(
            serverId: 'server-a',
            section: 'providers',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Add provider'), findsOneWidget);
    expect(find.text('Agoragentic'), findsOneWidget);
    expect(
      find.text('This host does not support provider discovery.'),
      findsOneWidget,
    );
    expect(find.text('AI Providers'), findsNothing);
  });
}

class _RouteRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [_host('server-a', 'Host A'), _host('server-b', 'Host B')],
    activeServerId: 'server-b',
    loaded: true,
  );
}

class _LoadingRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => const HostRegistryState();
}

HostProfile _host(String id, String label) {
  final connection = DirectTcpHostConnection(
    id: 'direct:$id.example:6868',
    endpoint: '$id.example:6868',
  );
  return HostProfile(
    serverId: id,
    label: label,
    connections: [connection],
    preferredConnectionId: connection.id,
    createdAt: '2026-07-26T00:00:00.000Z',
    updatedAt: '2026-07-26T00:00:00.000Z',
  );
}
