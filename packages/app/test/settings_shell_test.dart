import 'package:coding_agent_app/screens/settings_shell.dart';
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets(
    'host settings navigation exposes Paseo information architecture',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/settings/general',
        routes: [
          GoRoute(
            path: '/settings/:section',
            builder: (context, state) => SettingsShell(
              child: Text('${state.pathParameters['section']} page'),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(FluentApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(find.text('Host'), findsOneWidget);
      expect(find.text('Connections'), findsOneWidget);
      expect(find.text('Agents'), findsOneWidget);
      expect(find.text('Workspaces'), findsOneWidget);
      expect(find.text('Terminals'), findsOneWidget);
      expect(find.text('Projects'), findsOneWidget);
      expect(find.text('Keyboard shortcuts'), findsOneWidget);
      expect(find.text('Diagnostics'), findsOneWidget);
      expect(find.text('general page'), findsOneWidget);

      await tester.tap(find.text('Agents'));
      await tester.pumpAndSettle();
      expect(find.text('agents page'), findsOneWidget);

      await tester.tap(find.text('Workspaces'));
      await tester.pumpAndSettle();
      expect(find.text('workspaces page'), findsOneWidget);

      await tester.tap(find.text('Terminals'));
      await tester.pumpAndSettle();
      expect(find.text('terminals page'), findsOneWidget);

      await tester.tap(find.text('Projects'));
      await tester.pumpAndSettle();
      expect(find.text('projects page'), findsOneWidget);

      await tester.tap(find.text('Keyboard shortcuts'));
      await tester.pumpAndSettle();
      expect(find.text('keyboard page'), findsOneWidget);

      await tester.tap(find.text('Diagnostics'));
      await tester.pumpAndSettle();
      expect(find.text('diagnostics page'), findsOneWidget);
    },
  );

  testWidgets('host routes expose host-specific sections and host picker', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/settings/hosts/server-a/connections',
      routes: [
        GoRoute(
          path: '/settings/hosts/:serverId/:hostSection',
          builder: (context, state) => SettingsShell(
            child: Text('${state.pathParameters['serverId']} page'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [hostRegistryProvider.overrideWith(_TwoHostsRegistry.new)],
        child: FluentApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Local'), findsWidgets);
    expect(find.text('Remote'), findsOneWidget);
    expect(find.text('Providers'), findsOneWidget);
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('server-a page'), findsOneWidget);

    await tester.tap(find.text('Remote'));
    await tester.pumpAndSettle();
    expect(find.text('server-b page'), findsOneWidget);
  });

  testWidgets(
    'settings resolves a connected remote host when local daemon is stopped',
    (tester) async {
      final router = GoRouter(
        initialLocation: '/settings/general',
        routes: [
          GoRoute(
            path: '/settings/:section',
            builder: (context, state) => SettingsShell(
              child: Consumer(
                builder: (context, ref, child) => Text(
                  'Active host: '
                  '${ref.watch(activeHostProvider)?.label ?? 'none'}',
                ),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            hostRegistryProvider.overrideWith(
              _RemoteWithStoppedLocalRegistry.new,
            ),
          ],
          child: FluentApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Active host: Remote connected'), findsOneWidget);
      expect(find.text('Host not found'), findsNothing);
    },
  );
}

class _TwoHostsRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [_host('server-a', 'Local'), _host('server-b', 'Remote')],
    activeServerId: 'server-a',
    loaded: true,
  );
}

class _RemoteWithStoppedLocalRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => HostRegistryState(
    hosts: [_host('server-remote', 'Remote connected')],
    activeServerId: 'server-local-stopped',
    loaded: true,
  );
}

HostProfile _host(String serverId, String label) {
  final direct = DirectTcpHostConnection(
    id: 'direct:$serverId.example:6868',
    endpoint: '$serverId.example:6868',
  );
  return HostProfile(
    serverId: serverId,
    label: label,
    connections: [direct],
    preferredConnectionId: direct.id,
    createdAt: '2026-07-26T00:00:00.000Z',
    updatedAt: '2026-07-26T00:00:00.000Z',
  );
}
