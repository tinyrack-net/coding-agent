import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/host_connections_settings_screen.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows active connection state and removes a connection', (
    tester,
  ) async {
    final profile = _profile();
    final client = DaemonClient(uri: Uri.parse('ws://localhost:6868'));
    addTearDown(client.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(() => _SeededRegistry(profile)),
          daemonClientProvider.overrideWithValue(client),
          connectionStateProvider.overrideWith(
            (ref) => Stream.value(DaemonConnectionState.connected),
          ),
        ],
        child: FluentApp(
          home: HostConnectionsSettingsScreen(serverId: profile.serverId),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Connections'), findsOneWidget);
    expect(find.text('Workstation'), findsOneWidget);
    expect(find.text('ws://localhost:6868'), findsOneWidget);
    expect(find.text('Relay · relay.example:443'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);

    await tester.tap(find.widgetWithText(Button, 'Remove').first);
    await tester.pumpAndSettle();
    expect(find.text('Remove connection?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.text('ws://localhost:6868'), findsNothing);
    expect(find.text('Relay · relay.example:443'), findsOneWidget);
  });

  testWidgets('shows a stable unknown-host state', (tester) async {
    final client = DaemonClient(uri: Uri.parse('ws://localhost:6868'));
    addTearDown(client.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostRegistryProvider.overrideWith(() => _SeededRegistry(_profile())),
          daemonClientProvider.overrideWithValue(client),
          connectionStateProvider.overrideWith((ref) => const Stream.empty()),
        ],
        child: const FluentApp(
          home: HostConnectionsSettingsScreen(serverId: 'missing'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Host not found'), findsOneWidget);
  });
}

class _SeededRegistry extends HostRegistryNotifier {
  _SeededRegistry(this.profile);

  final HostProfile profile;

  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [profile],
    activeServerId: profile.serverId,
    loaded: true,
  );
}

HostProfile _profile() {
  const direct = DirectTcpHostConnection(
    id: 'direct:localhost:6868',
    endpoint: 'localhost:6868',
  );
  const relay = RelayHostConnection(
    id: 'relay:wss:relay.example:443',
    relayEndpoint: 'relay.example:443',
    useTls: true,
    daemonPublicKeyB64: 'key',
  );
  return const HostProfile(
    serverId: 'server-a',
    label: 'Workstation',
    connections: [direct, relay],
    preferredConnectionId: 'direct:localhost:6868',
    createdAt: '2026-07-26T00:00:00.000Z',
    updatedAt: '2026-07-26T00:00:00.000Z',
  );
}
