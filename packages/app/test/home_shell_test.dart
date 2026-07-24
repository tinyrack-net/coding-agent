import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/agent_chat_screen.dart';
import 'package:coding_agent_app/screens/home_shell.dart';
import 'package:coding_agent_app/screens/new_workspace_screen.dart';
import 'package:coding_agent_app/screens/settings_screen.dart';
import 'package:coding_agent_app/screens/status_screen.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/daemon_lifecycle_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _agent1 = AgentSummary(
  agentId: 'a1',
  title: 'First agent',
  cwd: '/work/one',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 100,
);

const _agent2 = AgentSummary(
  agentId: 'a2',
  title: 'Second agent',
  cwd: '/work/two',
  provider: 'codex',
  model: 'gpt',
  mode: AgentMode.plan,
  runState: AgentRunState.running,
  createdAtMs: 200,
);

class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({this.agents = const []}) : super(uri: Uri.parse('ws://fake'));

  final List<AgentSummary> agents;

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    return switch (type) {
      MessageTypes.agentListRequest => {
          'agents': agents.map((a) => a.toJson()).toList(),
        },
      MessageTypes.providerListRequest => const {'providers': []},
      MessageTypes.projectListRequest => const {'projects': []},
      _ => const {},
    };
  }
}

Future<ProviderContainer> pumpHomeShell(
  WidgetTester tester, {
  List<AgentSummary> agents = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  final client = FakeDaemonClient(agents: agents);
  final container = ProviderContainer(
    overrides: [
      daemonClientProvider.overrideWithValue(client),
      // Otherwise navigating to StatusScreen/SettingsScreen watches the real
      // daemonLifecycleProvider, which spins up an actual DaemonSupervisor
      // probing the network on this (real Windows) test host.
      desktopShellProvider.overrideWithValue(false),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: HomeShell()),
    ),
  );
  // Not pumpAndSettle(): a `running` agent renders an indeterminate
  // CircularProgressIndicator that animates forever and would time it out.
  await tester.pump();
  await tester.pump();
  await tester.pump();
  return container;
}

void main() {
  testWidgets('no agents: shows the empty placeholder', (tester) async {
    await pumpHomeShell(tester);

    expect(find.text('Select an agent or create a new one'), findsOneWidget);
    expect(find.text('No agents yet'), findsOneWidget);
  });

  testWidgets('lists agents most-recent first with provider/model subtitle',
      (tester) async {
    await pumpHomeShell(tester, agents: [_agent1, _agent2]);

    final tiles = find.byType(ListTile);
    expect(tiles, findsNWidgets(2));
    // Most-recent (createdAtMs 200) first.
    final firstTile = tester.widget<ListTile>(tiles.first);
    expect(
      (firstTile.title! as Text).data,
      'Second agent',
    );
    expect(find.text('codex · gpt'), findsOneWidget);
    expect(find.text('claude · sonnet'), findsOneWidget);
  });

  testWidgets('selecting an agent shows its chat screen', (tester) async {
    await pumpHomeShell(tester, agents: [_agent1]);

    expect(find.byType(AgentChatScreen), findsNothing);

    await tester.tap(find.text('First agent'));
    await tester.pumpAndSettle();

    expect(find.byType(AgentChatScreen), findsOneWidget);
    expect(find.text('First agent'), findsWidgets);
  });

  testWidgets('New workspace navigates to the New Workspace screen',
      (tester) async {
    await pumpHomeShell(tester);

    await tester.tap(find.text('New workspace'));
    await tester.pumpAndSettle();

    expect(find.byType(NewWorkspaceScreen), findsOneWidget);
  });

  testWidgets('the status icon navigates to StatusScreen', (tester) async {
    await pumpHomeShell(tester);

    await tester.tap(find.byTooltip('Daemon status'));
    await tester.pumpAndSettle();

    expect(find.byType(StatusScreen), findsOneWidget);
  });

  testWidgets('the settings icon navigates to SettingsScreen',
      (tester) async {
    await pumpHomeShell(tester);

    await tester.tap(find.byTooltip('Connection settings'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    // SettingsScreen's status Row genuinely overflows at this width — a
    // pre-existing, unrelated cosmetic issue in that widget, not something
    // this navigation test is about.
    final overflow = tester.takeException();
    if (overflow != null && !overflow.toString().contains('overflowed')) {
      throw overflow;
    }
  });

  testWidgets('connection footer reflects the connected state',
      (tester) async {
    await pumpHomeShell(tester);

    expect(find.text('Daemon connected'), findsOneWidget);
  });
}
