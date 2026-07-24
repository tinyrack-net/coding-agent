import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/settings_screen.dart';
import 'package:coding_agent_app/state/connection_settings_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({
    DaemonConnectionState state = DaemonConnectionState.connected,
    this.rejectedHelloOverride,
  })  : _state = state,
        super(uri: Uri.parse('ws://fake'));

  final DaemonConnectionState _state;
  final ServerHello? rejectedHelloOverride;

  /// Per-request-type scriptable response; defaults to an empty payload.
  Map<String, Object?> Function(String type, Map<String, Object?> payload)?
      onRequest;

  @override
  ServerHello? get rejectedHello => rejectedHelloOverride;

  @override
  DaemonConnectionState get currentState => _state;

  @override
  Stream<DaemonConnectionState> get connectionState => Stream.value(_state);

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async =>
      onRequest?.call(type, payload) ?? const {};
}

Future<ProviderContainer> pumpSettingsScreen(
  WidgetTester tester,
  FakeDaemonClient client,
) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);
  // Tall enough that the AI Providers cards + Desktop section both land
  // within the ListView's viewport/cache extent without needing a scroll.
  await tester.binding.setSurfaceSize(const Size(800, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('shows the current connection and the daemon uri',
      (tester) async {
    await pumpSettingsScreen(tester, FakeDaemonClient());

    expect(find.text('Connected — ws://127.0.0.1:6868'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Host'), findsOneWidget);
  });

  testWidgets('validation: empty host is rejected', (tester) async {
    await pumpSettingsScreen(tester, FakeDaemonClient());

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Host').first,
      '',
    );
    await tester.tap(find.text('Save & Reconnect'));
    await tester.pump();

    expect(find.text('Host is required'), findsOneWidget);
    expect(find.text('Settings saved. Reconnecting…'), findsNothing);
  });

  testWidgets('validation: out-of-range port is rejected', (tester) async {
    await pumpSettingsScreen(tester, FakeDaemonClient());

    final portField = find.ancestor(
      of: find.text('Port'),
      matching: find.byType(TextFormField),
    );
    await tester.enterText(portField, '99999');
    await tester.tap(find.text('Save & Reconnect'));
    await tester.pump();

    expect(find.text('Enter a port between 1 and 65535'), findsOneWidget);
  });

  testWidgets('valid input saves settings and shows a confirmation snackbar',
      (tester) async {
    final container = await pumpSettingsScreen(tester, FakeDaemonClient());

    final hostField = find.ancestor(
      of: find.text('Host'),
      matching: find.byType(TextFormField),
    );
    final portField = find.ancestor(
      of: find.text('Port'),
      matching: find.byType(TextFormField),
    );
    await tester.enterText(hostField, '10.0.0.5');
    await tester.enterText(portField, '7000');
    await tester.tap(find.text('Save & Reconnect'));
    await tester.pump();

    expect(find.text('Settings saved. Reconnecting…'), findsOneWidget);
    final settings = container.read(connectionSettingsProvider);
    expect(settings.host, '10.0.0.5');
    expect(settings.port, 7000);
  });

  testWidgets('version mismatch shows the guidance card', (tester) async {
    await pumpSettingsScreen(
      tester,
      FakeDaemonClient(
        state: DaemonConnectionState.versionMismatch,
        rejectedHelloOverride: const ServerHello(
          daemonVersion: '9.0.0',
          protocolVersion: 1,
        ),
      ),
    );

    expect(find.textContaining('Version mismatch'), findsOneWidget);
    expect(find.textContaining('원격 데몬 v9.0.0'), findsOneWidget);
  });

  testWidgets('desktop section: toggling keep-running persists the setting',
      (tester) async {
    await pumpSettingsScreen(tester, FakeDaemonClient());

    // This test host is Windows, so the desktop settings section renders.
    expect(find.text('Keep daemon running after quit'), findsOneWidget);
    final keepRunningSwitch = find.widgetWithText(
      SwitchListTile,
      'Keep daemon running after quit',
    );
    final before = tester.widget<SwitchListTile>(keepRunningSwitch).value;
    expect(before, isTrue);

    await tester.tap(keepRunningSwitch);
    await tester.pump();

    final after = tester.widget<SwitchListTile>(keepRunningSwitch).value;
    expect(after, isFalse);
  });

  group('AI Providers section', () {
    testWidgets('shows all three providers with a configured indicator',
        (tester) async {
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.providerListRequest) {
            return {
              'providers': [
                const ProviderInfo(
                  id: ProviderId.openai,
                  displayName: 'Codex',
                  configured: true,
                ).toJson(),
              ],
            };
          }
          return const {};
        };
      await pumpSettingsScreen(tester, client);

      expect(find.text('AI Providers'), findsOneWidget);
      expect(find.text('Codex'), findsOneWidget);
      expect(find.text('DeepSeek'), findsOneWidget);
      expect(find.text('OpenRouter'), findsOneWidget);
      // Only the configured provider (Codex) shows a Remove button.
      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets('saving an API key sends provider.credential.set.request',
        (tester) async {
      final calls = <(String, Map<String, Object?>)>[];
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          calls.add((type, payload));
          return const {};
        };
      await pumpSettingsScreen(tester, client);

      final deepseekKeyField = find.ancestor(
        of: find.text('DeepSeek'),
        matching: find.byType(Card),
      );
      await tester.enterText(
        find.descendant(of: deepseekKeyField, matching: find.byType(TextField)),
        'sk-deepseek-test',
      );
      await tester.tap(
        find.descendant(of: deepseekKeyField, matching: find.text('Save')),
      );
      await tester.pumpAndSettle();

      final saveCall = calls.singleWhere(
        (c) => c.$1 == MessageTypes.providerCredentialSetRequest,
      );
      expect(saveCall.$2['providerId'], 'deepseek');
      expect(saveCall.$2['apiKey'], 'sk-deepseek-test');
    });

    testWidgets('testing a connection shows the result', (tester) async {
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.providerCredentialTestRequest) {
            return {'ok': false, 'error': 'invalid key'};
          }
          return const {};
        };
      await pumpSettingsScreen(tester, client);

      final openaiCard = find.ancestor(
        of: find.text('Codex'),
        matching: find.byType(Card),
      );
      await tester.tap(
        find.descendant(of: openaiCard, matching: find.text('Test Connection')),
      );
      await tester.pumpAndSettle();

      expect(find.text('invalid key'), findsOneWidget);
    });

    testWidgets('removing a configured key sends provider.credential.clear',
        (tester) async {
      final calls = <(String, Map<String, Object?>)>[];
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          calls.add((type, payload));
          if (type == MessageTypes.providerListRequest) {
            return {
              'providers': [
                const ProviderInfo(
                  id: ProviderId.openrouter,
                  displayName: 'OpenRouter',
                  configured: true,
                ).toJson(),
              ],
            };
          }
          return const {};
        };
      await pumpSettingsScreen(tester, client);

      final openrouterCard = find.ancestor(
        of: find.text('OpenRouter'),
        matching: find.byType(Card),
      );
      await tester.tap(
        find.descendant(of: openrouterCard, matching: find.text('Remove')),
      );
      await tester.pumpAndSettle();

      final clearCall = calls.singleWhere(
        (c) => c.$1 == MessageTypes.providerCredentialClearRequest,
      );
      expect(clearCall.$2['providerId'], 'openrouter');
    });
  });

  group('Reset all data section', () {
    // The section's button and the confirmation dialog share the same
    // "Reset all data" label, so locate the section button via the
    // description text that's unique to the reset card.
    Finder sectionResetButton() => find.descendant(
          of: find.ancestor(
            of: find.textContaining('agent timelines'),
            matching: find.byType(Card),
          ),
          matching: find.byType(FilledButton),
        );

    testWidgets('shows the destructive card with a confirmation dialog',
        (tester) async {
      await pumpSettingsScreen(tester, FakeDaemonClient());

      // The reset card describes the action and offers a button.
      expect(find.textContaining('Reset all data'), findsWidgets);
      expect(find.textContaining('agent timelines'), findsOneWidget);
    });

    testWidgets('cancel leaves app state untouched', (tester) async {
      // pumpSettingsScreen wipes mock prefs, so seed non-default values
      // through the notifier instead.
      final calls = <(String, Map<String, Object?>)>[];
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          calls.add((type, payload));
          if (type == MessageTypes.providerListRequest) {
            return {
              'providers': [
                const ProviderInfo(
                  id: ProviderId.openai,
                  displayName: 'Codex',
                  configured: true,
                ).toJson(),
              ],
            };
          }
          return const {};
        };
      final container = await pumpSettingsScreen(tester, client);
      await container.read(connectionSettingsProvider.notifier).save(
            host: '10.9.9.9',
            port: 7777,
            token: 'keep-me',
          );

      await tester.tap(sectionResetButton());
      await tester.pumpAndSettle();

      // Dialog is showing.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Reset all data?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // No clear RPC was sent, settings still point at the seeded host.
      expect(
        calls.where(
          (c) => c.$1 == MessageTypes.providerCredentialClearRequest,
        ),
        isEmpty,
      );
      expect(container.read(connectionSettingsProvider).host, '10.9.9.9');
      expect(container.read(connectionSettingsProvider).port, 7777);
      expect(container.read(connectionSettingsProvider).token, 'keep-me');
    });

    testWidgets(
        'confirming resets local settings and clears every configured key',
        (tester) async {
      final calls = <(String, Map<String, Object?>)>[];
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          calls.add((type, payload));
          if (type == MessageTypes.providerListRequest) {
            return {
              'providers': [
                const ProviderInfo(
                  id: ProviderId.openai,
                  displayName: 'Codex',
                  configured: true,
                ).toJson(),
                const ProviderInfo(
                  id: ProviderId.deepseek,
                  displayName: 'DeepSeek',
                  configured: false,
                ).toJson(),
                const ProviderInfo(
                  id: ProviderId.openrouter,
                  displayName: 'OpenRouter',
                  configured: true,
                ).toJson(),
              ],
            };
          }
          if (type == MessageTypes.agentConversationClearRequest) {
            return {'cleared': 2};
          }
          if (type == MessageTypes.agentListRequest) {
            // Return two agents so the snackbar count matches the response.
            return {
              'agents': [
                const AgentSummary(
                  agentId: 'a1',
                  title: 'A',
                  cwd: 'C:/r',
                  provider: 'openai',
                  model: 'm',
                  mode: AgentMode.normal,
                  runState: AgentRunState.idle,
                  createdAtMs: 1,
                ).toJson(),
                const AgentSummary(
                  agentId: 'a2',
                  title: 'B',
                  cwd: 'C:/r',
                  provider: 'openai',
                  model: 'm',
                  mode: AgentMode.normal,
                  runState: AgentRunState.idle,
                  createdAtMs: 2,
                ).toJson(),
              ],
            };
          }
          return const {};
        };
      final container = await pumpSettingsScreen(tester, client);
      await container.read(connectionSettingsProvider.notifier).save(
            host: '10.9.9.9',
            port: 7777,
            token: 'keep-me',
          );

      await tester.tap(sectionResetButton());
      await tester.pumpAndSettle();

      // Confirm inside the dialog (the only FilledButton there).
      final confirmButton = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      );
      expect(confirmButton, findsOneWidget);
      await tester.tap(confirmButton);
      await tester.pumpAndSettle();

      // Local settings snap back to defaults.
      expect(container.read(connectionSettingsProvider),
          const ConnectionSettings());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('daemon.host'), isFalse);
      expect(prefs.containsKey('daemon.port'), isFalse);
      expect(prefs.containsKey('daemon.token'), isFalse);

      // A clear RPC was sent for each CONFIGURED provider, not for the
      // unconfigured DeepSeek entry.
      final clearCalls = calls
          .where((c) => c.$1 == MessageTypes.providerCredentialClearRequest)
          .toList();
      final clearedIds = clearCalls
          .map((c) => c.$2['providerId'])
          .toSet();
      expect(clearedIds, {'openai', 'openrouter'});

      // The agent.conversation.clear RPC was sent with an empty payload
      // (means "wipe every agent").
      final convCalls = calls
          .where((c) => c.$1 == MessageTypes.agentConversationClearRequest)
          .toList();
      expect(convCalls, hasLength(1));
      expect(convCalls.single.$2, isEmpty);

      // The success snackbar reports the cleared conversation count.
      expect(
        find.text('All data has been reset (2 conversations wiped).'),
        findsOneWidget,
      );
    });

    testWidgets(
        'conversation-clear failure surfaces in the snackbar but the local '
        'reset still completes', (tester) async {
      final calls = <(String, Map<String, Object?>)>[];
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          calls.add((type, payload));
          if (type == MessageTypes.providerListRequest) {
            return const {'providers': []};
          }
          if (type == MessageTypes.agentConversationClearRequest) {
            throw StateError('daemon offline');
          }
          return const {};
        };
      final container = await pumpSettingsScreen(tester, client);
      await container.read(connectionSettingsProvider.notifier).save(
            host: '10.9.9.9',
            port: 7777,
          );

      await tester.tap(sectionResetButton());
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      await tester.pumpAndSettle();

      // Local settings still reset.
      expect(
          container.read(connectionSettingsProvider), const ConnectionSettings());
      // The snackbar mentions the conversation failure.
      expect(
        find.textContaining('Some daemon-side items could not be cleared'),
        findsOneWidget,
      );
      expect(find.textContaining('conversations: Bad state: daemon offline'),
          findsOneWidget);
      // The RPC was attempted.
      expect(
        calls.where(
          (c) => c.$1 == MessageTypes.agentConversationClearRequest,
        ),
        hasLength(1),
      );
    });
  });
}
