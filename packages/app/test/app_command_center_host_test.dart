import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/keyboard/shortcut_engine.dart';
import 'package:coding_agent_app/keyboard/shortcut_focus_scope.dart';
import 'package:coding_agent_app/state/agents_provider.dart';
import 'package:coding_agent_app/state/appearance_provider.dart';
import 'package:coding_agent_app/state/app_sidebar_visibility_provider.dart';
import 'package:coding_agent_app/state/command_center_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/keyboard_shortcut_overrides_provider.dart';
import 'package:coding_agent_app/state/sidebar_pins_provider.dart';
import 'package:coding_agent_app/state/worktree_tabs_provider.dart';
import 'package:coding_agent_app/widgets/app_command_center_host.dart';
import 'package:coding_agent_app/widgets/composer.dart';
import 'package:coding_agent_app/widgets/draft_session_composer.dart';
import 'package:coding_agent_app/widgets/workspace_explorer.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/legacy_agent_list_fetch_mixin.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDaemonClient extends DaemonClient with LegacyAgentListFetchMixin {
  _FakeDaemonClient({
    this.providers = const [],
    this.agents = const [],
    this.snapshotEntries = const [],
  }) : super(uri: Uri.parse('ws://fake')) {
    if (snapshotEntries.isNotEmpty) {
      serverInfo = const ServerInfoStatus(
        serverId: 'local',
        hostname: 'fake',
        version: '0.2.0',
        desktopManaged: false,
        features: {'providersSnapshot': true},
      );
    }
  }

  final List<ProviderInfo> providers;
  final List<AgentSummary> agents;
  final List<ProviderSnapshotEntry> snapshotEntries;
  final List<Map<String, Object?>> sessionMessages = [];
  final List<(String, Map<String, Object?>)> requests = [];

  @override
  Stream<RpcEvent> get events => const Stream.empty();

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Stream<DaemonConnectionState> get connectionState =>
      Stream.value(DaemonConnectionState.connected);

  @override
  Future<GetProvidersSnapshotResponse> fetchProvidersSnapshot({
    String? cwd,
    Duration timeout = const Duration(seconds: 30),
  }) async => GetProvidersSnapshotResponse(
    entries: snapshotEntries,
    generatedAt: 'now',
    requestId: 'snapshot',
  );

  @override
  Future<ListCommandsResponse> listCommands({
    required String agentId,
    ListCommandsDraftConfig? draftConfig,
    Duration timeout = const Duration(seconds: 30),
  }) async => ListCommandsResponse(
    agentId: agentId,
    commands: const [],
    requestId: 'commands',
  );

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    requests.add((type, payload));
    return switch (type) {
      MessageTypes.agentListRequest => {
        'agents': agents.map((agent) => agent.toJson()).toList(),
      },
      MessageTypes.providerListRequest => {
        'providers': providers.map((provider) => provider.toJson()).toList(),
      },
      MessageTypes.projectListRequest => const {'projects': []},
      _ => const {},
    };
  }

  @override
  Future<Map<String, Object?>> requestSessionMessage(
    Map<String, Object?> message, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    sessionMessages.add(message);
    final responseType = switch (message['type']) {
      'set_agent_mode_request' => 'set_agent_mode_response',
      'set_agent_model_request' => 'set_agent_model_response',
      'set_agent_thinking_request' => 'set_agent_thinking_response',
      'set_agent_feature_request' => 'set_agent_feature_response',
      _ => null,
    };
    if (responseType != null) {
      return {
        'type': responseType,
        'payload': {
          'requestId': message['requestId'],
          'agentId': message['agentId'],
          'accepted': true,
          'error': null,
        },
      };
    }
    return const {};
  }
}

Future<(ProviderContainer, _FakeDaemonClient)> _pumpHost(
  WidgetTester tester, {
  _FakeDaemonClient? client,
  Widget child = const SizedBox.expand(child: Text('content')),
  Map<String, String> shortcutOverrides = const {},
  void Function(GoRouter router)? onRouter,
}) async {
  SharedPreferences.setMockInitialValues({
    if (shortcutOverrides.isNotEmpty)
      KeyboardShortcutOverridesNotifier.storageKey: jsonEncode(
        shortcutOverrides,
      ),
  });
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SizedBox()),
      GoRoute(path: '/new-workspace', builder: (_, _) => const SizedBox()),
      GoRoute(path: '/settings/general', builder: (_, _) => const SizedBox()),
    ],
  );
  onRouter?.call(router);
  addTearDown(router.dispose);
  final fakeClient = client ?? _FakeDaemonClient();
  final container = ProviderContainer(
    overrides: [
      daemonClientProvider.overrideWithValue(fakeClient),
      providerListProvider.overrideWith((ref) async => fakeClient.providers),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(
        home: AppCommandCenterHost(router: router, child: child),
      ),
    ),
  );
  for (var index = 0; index < 6; index++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  return (container, fakeClient);
}

Future<void> _sendShortcut(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  PhysicalKeyboardKey? physicalKey,
  bool control = false,
  bool alt = false,
  bool shift = false,
}) async {
  if (control) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  }
  if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyDownEvent(key, physicalKey: physicalKey);
  await tester.pump();
  await tester.sendKeyUpEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  if (control) {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }
  await tester.pump();
}

void main() {
  testWidgets('Ctrl+Alt+T cycles themes in Paseo order', (tester) async {
    final (container, _) = await _pumpHost(tester);
    expect(container.read(appearanceProvider), AppThemeName.dark);

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyT,
      physicalKey: PhysicalKeyboardKey.keyT,
      control: true,
      alt: true,
    );

    expect(container.read(appearanceProvider), AppThemeName.zinc);
  });

  testWidgets('Ctrl+K toggles the command center and exposes root actions', (
    tester,
  ) async {
    await _pumpHost(tester);
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.keyK,
      physicalKey: PhysicalKeyboardKey.keyK,
    );
    // sendKeyDownEvent cannot add a modifier after the key; issue the exact
    // platform chord through the modifier key state.
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    expect(find.byKey(const ValueKey('command-center-search')), findsOneWidget);
    expect(find.text('Add project'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('command-center-search')), findsNothing);
  });

  testWidgets('root contributions unregister with their owning host', (
    tester,
  ) async {
    final (container, _) = await _pumpHost(tester);
    expect(
      container
          .read(commandCenterRegistryProvider)
          .contributions
          .map((item) => item.id),
      ['root:new-agent', 'root:home', 'root:settings'],
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(
      container.read(commandCenterRegistryProvider).contributions,
      isEmpty,
    );
  });

  testWidgets('persisted override replaces the default command-center chord', (
    tester,
  ) async {
    await _pumpHost(
      tester,
      shortcutOverrides: const {
        'command-center-toggle-ctrl-k-non-mac': 'Ctrl+J',
      },
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.keyK,
      physicalKey: PhysicalKeyboardKey.keyK,
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('command-center-search')), findsNothing);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);

    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.keyJ,
      physicalKey: PhysicalKeyboardKey.keyJ,
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('command-center-search')), findsOneWidget);
    expect(find.text('Ctrl+J'), findsOneWidget);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  testWidgets('question mark opens shortcuts only outside editable focus', (
    tester,
  ) async {
    await _pumpHost(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.slash,
      physicalKey: PhysicalKeyboardKey.slash,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('keyboard-shortcuts-search')),
      findsOneWidget,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  });

  testWidgets('question mark is ignored inside an editable text field', (
    tester,
  ) async {
    await _pumpHost(
      tester,
      child: const Center(child: TextBox(autofocus: true)),
    );
    await tester.pump();
    await tester.tap(find.byType(TextBox));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.slash,
      physicalKey: PhysicalKeyboardKey.slash,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('keyboard-shortcuts-search')),
      findsNothing,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  });

  testWidgets('modal barrier dismisses the active overlay', (tester) async {
    await _pumpHost(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.slash,
      physicalKey: PhysicalKeyboardKey.slash,
    );
    await tester.pump();
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('keyboard-shortcuts-search')),
      findsNothing,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  });

  testWidgets('query exposes and applies models for the active agent', (
    tester,
  ) async {
    const agent = AgentSummary(
      agentId: 'agent-1',
      title: 'Active agent',
      cwd: '/work/active',
      provider: 'openai',
      model: 'gpt-one',
      mode: AgentMode.normal,
      runState: AgentRunState.idle,
      createdAtMs: 1,
    );
    final client = _FakeDaemonClient(
      agents: const [agent],
      providers: const [
        ProviderInfo(
          id: ProviderId.openai,
          displayName: 'OpenAI',
          configured: true,
          models: [
            ProviderModel(id: 'gpt-one', displayName: 'GPT One'),
            ProviderModel(id: 'gpt-two', displayName: 'GPT Two'),
          ],
        ),
      ],
    );
    final (container, _) = await _pumpHost(tester, client: client);
    await container.read(agentsProvider.notifier).refresh();
    container.read(selectedWorktreeProvider.notifier).select('/work/active');
    container
        .read(worktreeTabsProvider('/work/active').notifier)
        .focusAgent(agent.agentId);
    await container.read(providerListProvider.future);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.enterText(
      find.byKey(const ValueKey('command-center-search')),
      'gpt one',
    );
    await tester.pump();
    await tester.tap(find.text('GPT One'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(client.sessionMessages, isEmpty);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.enterText(
      find.byKey(const ValueKey('command-center-search')),
      'gpt two',
    );
    await tester.pump();

    expect(find.text('GPT Two'), findsOneWidget);
    await tester.tap(find.text('GPT Two'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(client.sessionMessages, hasLength(1));
    expect(client.sessionMessages.single, containsPair('modelId', 'gpt-two'));
    expect(
      client.sessionMessages.single,
      containsPair('type', 'set_agent_model_request'),
    );

    container
        .read(worktreeTabsProvider('/work/active').notifier)
        .addTab(WorktreeTabKind.draft);
    await tester.pump();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.enterText(
      find.byKey(const ValueKey('command-center-search')),
      'gpt two',
    );
    await tester.pump();
    expect(find.text('GPT Two'), findsNothing);
  });

  testWidgets('query exposes every provider model for the focused draft', (
    tester,
  ) async {
    final client = _FakeDaemonClient(
      snapshotEntries: const [
        ProviderSnapshotEntry(
          provider: 'claude',
          label: 'Claude',
          status: ProviderCatalogStatus.ready,
          models: [
            ProviderModelDefinition(
              provider: 'claude',
              id: 'sonnet',
              label: 'Sonnet',
              isDefault: true,
            ),
          ],
        ),
        ProviderSnapshotEntry(
          provider: 'codex',
          label: 'Codex',
          status: ProviderCatalogStatus.ready,
          models: [
            ProviderModelDefinition(
              provider: 'codex',
              id: 'gpt-two',
              label: 'GPT Two',
              isDefault: true,
            ),
          ],
        ),
      ],
    );
    await _pumpHost(
      tester,
      client: client,
      child: const DraftSessionComposer(
        worktreePath: '/work/draft',
        tabId: 'draft-1',
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.enterText(
      find.byKey(const ValueKey('command-center-search')),
      'gpt two',
    );
    await tester.pump();

    expect(find.text('GPT Two'), findsOneWidget);
    await tester.tap(find.text('GPT Two'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.byKey(const ValueKey('command-center-search')), findsNothing);
    expect(find.text('GPT Two'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('draft-provider-selector')),
        matching: find.text('Codex'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('workspace shortcuts create and navigate tabs', (tester) async {
    final (container, _) = await _pumpHost(tester);
    const path = '/work/active';
    container.read(selectedWorktreeProvider.notifier).select(path);
    final initial = container.read(worktreeTabsProvider(path)).layout;
    expect(initial.tabs, hasLength(1));

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyT,
      physicalKey: PhysicalKeyboardKey.keyT,
      control: true,
    );
    var layout = container.read(worktreeTabsProvider(path)).layout;
    expect(layout.tabs, hasLength(2));
    expect(layout.tabs.last.kind, WorktreeTabKind.draft);

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyT,
      physicalKey: PhysicalKeyboardKey.keyT,
      control: true,
      shift: true,
    );
    layout = container.read(worktreeTabsProvider(path)).layout;
    expect(layout.tabs, hasLength(3));
    expect(layout.tabs.last.kind, WorktreeTabKind.terminal);

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.digit2,
      physicalKey: PhysicalKeyboardKey.digit2,
      alt: true,
    );
    layout = container.read(worktreeTabsProvider(path)).layout;
    expect(layout.activeTabId, layout.tabs[1].tabId);

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.bracketRight,
      physicalKey: PhysicalKeyboardKey.bracketRight,
      alt: true,
      shift: true,
    );
    layout = container.read(worktreeTabsProvider(path)).layout;
    expect(layout.activeTabId, layout.tabs[2].tabId);
  });

  testWidgets('sidebar shortcuts toggle left and workspace explorer panels', (
    tester,
  ) async {
    final (container, _) = await _pumpHost(tester);
    const path = '/work/active';
    container.read(selectedWorktreeProvider.notifier).select(path);
    expect(container.read(appSidebarVisibilityProvider), isTrue);
    expect(container.read(workspaceExplorerVisibilityProvider(path)), isTrue);

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyB,
      physicalKey: PhysicalKeyboardKey.keyB,
      control: true,
    );
    expect(container.read(appSidebarVisibilityProvider), isFalse);

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyE,
      physicalKey: PhysicalKeyboardKey.keyE,
      control: true,
    );
    expect(container.read(workspaceExplorerVisibilityProvider(path)), isFalse);

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyE,
      physicalKey: PhysicalKeyboardKey.keyE,
      control: true,
    );
    expect(container.read(workspaceExplorerVisibilityProvider(path)), isTrue);

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.period,
      physicalKey: PhysicalKeyboardKey.period,
      control: true,
    );
    expect(container.read(appSidebarVisibilityProvider), isFalse);
    expect(container.read(workspaceExplorerVisibilityProvider(path)), isFalse);

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.period,
      physicalKey: PhysicalKeyboardKey.period,
      control: true,
    );
    expect(container.read(appSidebarVisibilityProvider), isTrue);
    expect(container.read(workspaceExplorerVisibilityProvider(path)), isTrue);
  });

  testWidgets('message-input focus scope routes focus and mode shortcuts', (
    tester,
  ) async {
    const agent = AgentSummary(
      agentId: 'agent-1',
      title: 'Active agent',
      cwd: '/work/active',
      provider: 'openai',
      model: 'gpt-one',
      mode: AgentMode.normal,
      runState: AgentRunState.idle,
      createdAtMs: 1,
    );
    final client = _FakeDaemonClient(agents: const [agent]);
    final (container, _) = await _pumpHost(
      tester,
      client: client,
      child: const Composer(agentId: 'agent-1'),
    );
    await container.read(agentsProvider.notifier).refresh();

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyL,
      physicalKey: PhysicalKeyboardKey.keyL,
      control: true,
    );
    final focusContext = FocusManager.instance.primaryFocus!.context!;
    expect(
      ShortcutFocusScope.maybeOf(focusContext),
      KeyboardFocusScope.messageInput,
    );

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.tab,
      physicalKey: PhysicalKeyboardKey.tab,
      shift: true,
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(client.sessionMessages.single['type'], 'set_agent_mode_request');
    expect(client.sessionMessages.single['modeId'], AgentMode.fullAccess.name);
  });

  testWidgets('workspace navigation, pin, interrupt, and routes are live', (
    tester,
  ) async {
    const agent = AgentSummary(
      agentId: 'agent-1',
      title: 'Active agent',
      cwd: '/work/active',
      provider: 'openai',
      model: 'gpt-one',
      mode: AgentMode.normal,
      runState: AgentRunState.running,
      createdAtMs: 1,
    );
    final client = _FakeDaemonClient(agents: const [agent]);
    late GoRouter router;
    final (container, _) = await _pumpHost(
      tester,
      client: client,
      onRouter: (value) => router = value,
    );
    await container.read(agentsProvider.notifier).refresh();

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.digit1,
      physicalKey: PhysicalKeyboardKey.digit1,
      control: true,
    );
    expect(container.read(selectedWorktreeProvider), agent.cwd);

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.arrowRight,
      physicalKey: PhysicalKeyboardKey.arrowRight,
      control: true,
    );
    expect(container.read(selectedWorktreeProvider), agent.cwd);

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyP,
      physicalKey: PhysicalKeyboardKey.keyP,
      control: true,
      shift: true,
    );
    expect(container.read(sidebarPinsProvider), contains(agent.cwd));

    container
        .read(worktreeTabsProvider(agent.cwd).notifier)
        .focusAgent(agent.agentId);
    await _sendShortcut(
      tester,
      LogicalKeyboardKey.escape,
      physicalKey: PhysicalKeyboardKey.escape,
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      client.requests.where(
        (call) => call.$1 == MessageTypes.agentInterruptRequest,
      ),
      hasLength(1),
    );

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.keyO,
      physicalKey: PhysicalKeyboardKey.keyO,
      control: true,
    );
    expect(router.routeInformationProvider.value.uri.path, '/new-workspace');

    await _sendShortcut(
      tester,
      LogicalKeyboardKey.comma,
      physicalKey: PhysicalKeyboardKey.comma,
      control: true,
    );
    expect(router.routeInformationProvider.value.uri.path, '/settings/general');
  });
}
