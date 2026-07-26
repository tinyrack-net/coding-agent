import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/screens/settings_screen.dart';
import 'package:coding_agent_app/state/connection_settings_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeDaemonClient extends DaemonClient {
  FakeDaemonClient({
    this.state = DaemonConnectionState.connected,
    this.rejectedHelloOverride,
  }) : super(uri: Uri.parse('ws://fake'));

  final DaemonConnectionState state;
  final ServerHello? rejectedHelloOverride;

  /// Per-request-type scriptable response; defaults to an empty payload.
  Map<String, Object?> Function(String type, Map<String, Object?> payload)?
  onRequest;

  @override
  ServerHello? get rejectedHello => rejectedHelloOverride;

  @override
  DaemonConnectionState get currentState => state;

  @override
  Stream<DaemonConnectionState> get connectionState => Stream.value(state);

  @override
  Future<Map<String, Object?>> request(
    String type,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async => onRequest?.call(type, payload) ?? const {};
}

Future<ProviderContainer> pumpSettingsScreen(
  WidgetTester tester,
  FakeDaemonClient client, {
  String section = 'general',
}) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [daemonClientProvider.overrideWithValue(client)],
  );
  addTearDown(container.dispose);
  await tester.binding.setSurfaceSize(const Size(800, 2200));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: FluentApp(home: SettingsScreen(section: section)),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Finds the `TextFormBox` under the `InfoLabel` with the given [label] —
/// the label text is a sibling, not a descendant, of the box (fluent_ui's
/// `InfoLabel` lays out label + child in a column), so a plain
/// `find.widgetWithText`/`find.ancestor` can't bridge them directly.
Finder _labeledField(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(InfoLabel)),
  matching: find.byType(TextFormBox),
);

void main() {
  testWidgets('an unknown section falls back to the connection settings', (
    tester,
  ) async {
    await pumpSettingsScreen(tester, FakeDaemonClient(), section: 'bogus');
    expect(find.text('Connection Settings'), findsOneWidget);
  });

  testWidgets('reports a disconnected daemon', (tester) async {
    await pumpSettingsScreen(
      tester,
      FakeDaemonClient(state: DaemonConnectionState.disconnected),
    );
    expect(
      find.text('Disconnected (retrying) — ws://127.0.0.1:6868'),
      findsOneWidget,
    );
  });

  testWidgets('shows the current connection and the daemon uri', (
    tester,
  ) async {
    await pumpSettingsScreen(tester, FakeDaemonClient());

    expect(find.text('Connected — ws://127.0.0.1:6868'), findsOneWidget);
    expect(_labeledField('Host'), findsOneWidget);
  });

  testWidgets('validation: empty host is rejected', (tester) async {
    await pumpSettingsScreen(tester, FakeDaemonClient());

    await tester.enterText(_labeledField('Host'), '');
    await tester.tap(find.text('Save & Reconnect'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Host is required'), findsOneWidget);
    expect(find.text('Settings saved. Reconnecting…'), findsNothing);
  });

  testWidgets('validation: out-of-range port is rejected', (tester) async {
    await pumpSettingsScreen(tester, FakeDaemonClient());

    await tester.enterText(_labeledField('Port'), '99999');
    await tester.tap(find.text('Save & Reconnect'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Enter a port between 1 and 65535'), findsOneWidget);
  });

  testWidgets('valid input saves settings and shows a confirmation snackbar', (
    tester,
  ) async {
    final container = await pumpSettingsScreen(tester, FakeDaemonClient());

    await tester.enterText(_labeledField('Host'), '10.0.0.5');
    await tester.enterText(_labeledField('Port'), '7000');
    await tester.tap(find.text('Save & Reconnect'));
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Settings saved. Reconnecting…'), findsOneWidget);
    final settings = container.read(connectionSettingsProvider);
    expect(settings.host, '10.0.0.5');
    expect(settings.port, 7000);
    // Let AppToast's auto-dismiss timer fire so no Timer remains pending.
    await tester.pump(const Duration(seconds: 5));
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

    testWidgets('desktop section: toggling keep-running persists the setting', (
    tester,
  ) async {
    await pumpSettingsScreen(tester, FakeDaemonClient(), section: 'desktop');

    expect(find.text('Keep daemon running after quit'), findsOneWidget);
    final keepRunningSwitch = find.byType(ToggleSwitch).at(1);
    final before = tester.widget<ToggleSwitch>(keepRunningSwitch).checked;
    expect(before, isTrue);

    await tester.tap(keepRunningSwitch);
    await tester.pump(const Duration(milliseconds: 150));

    final after = tester.widget<ToggleSwitch>(keepRunningSwitch).checked;
    expect(after, isFalse);
  });

  group('AI Providers section', () {
    /// Scripts `provider.list` with [providers] and records every request.
    (FakeDaemonClient, List<(String, Map<String, Object?>)>) listing(
      List<ProviderInfo> providers, {
      Map<String, Object?> Function(String type)? extra,
    }) {
      final calls = <(String, Map<String, Object?>)>[];
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          calls.add((type, payload));
          if (type == MessageTypes.providerListRequest) {
            return {'providers': [for (final p in providers) p.toJson()]};
          }
          return extra?.call(type) ?? const {};
        };
      return (client, calls);
    }

    const claude = ProviderInfo(
      id: 'p-claude',
      displayName: 'Claude (work)',
      kind: ProviderKind.anthropic,
      baseUrl: 'https://api.anthropic.com/v1',
      configured: true,
    );
    const unconfigured = ProviderInfo(
      id: 'p-local',
      displayName: 'Local llama',
      kind: ProviderKind.openaiCompatible,
      baseUrl: 'http://localhost:8080/v1',
      configured: false,
      unavailableReason: 'no API key configured',
    );

    testWidgets('empty list invites the user to add one', (tester) async {
      final (client, _) = listing(const []);
      await pumpSettingsScreen(tester, client, section: 'providers');

      expect(find.text('AI Providers'), findsOneWidget);
      expect(find.textContaining('No providers yet'), findsOneWidget);
      expect(find.text('Add provider'), findsOneWidget);
    });

    testWidgets('renders a row per provider with kind badge and base URL', (
      tester,
    ) async {
      final (client, _) = listing(const [claude, unconfigured]);
      await pumpSettingsScreen(tester, client, section: 'providers');

      expect(find.text('Claude (work)'), findsOneWidget);
      expect(find.text('Claude-compatible'), findsOneWidget);
      expect(find.text('https://api.anthropic.com/v1'), findsOneWidget);

      expect(find.text('Local llama'), findsOneWidget);
      expect(find.text('OpenAI-compatible'), findsOneWidget);
      expect(find.text('no API key configured'), findsOneWidget);
    });

    testWidgets('Test Connection is only offered once a key is stored', (
      tester,
    ) async {
      final (client, _) = listing(const [claude, unconfigured]);
      await pumpSettingsScreen(tester, client, section: 'providers');

      Finder testButtonIn(String name) => find.descendant(
        of: find.ancestor(of: find.text(name), matching: find.byType(Card)),
        matching: find.widgetWithText(Button, 'Test Connection'),
      );

      expect(
        tester.widget<Button>(testButtonIn('Claude (work)')).onPressed,
        isNotNull,
      );
      expect(
        tester.widget<Button>(testButtonIn('Local llama')).onPressed,
        isNull,
      );
    });

    testWidgets('testing a connection shows the failure reason', (tester) async {
      final (client, _) = listing(
        const [claude],
        extra: (type) => type == MessageTypes.providerCredentialTestRequest
            ? {'ok': false, 'error': 'invalid key'}
            : const {},
      );
      await pumpSettingsScreen(tester, client, section: 'providers');

      await tester.tap(find.text('Test Connection'));
      await tester.pumpAndSettle();

      expect(find.text('invalid key'), findsOneWidget);
    });

    testWidgets('adding a preset provider sends provider.upsert', (
      tester,
    ) async {
      final (client, calls) = listing(
        const [],
        extra: (type) => type == MessageTypes.providerUpsertRequest
            ? ProviderUpsertResponse(
                config: ProviderConfig.fromJson(claude.toConfig().toJson()),
              ).toJson()
            : const {},
      );
      await pumpSettingsScreen(tester, client, section: 'providers');

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();

      // Preset picker, then the form pre-filled from it.
      await tester.tap(find.text('Claude (Anthropic)'));
      await tester.pumpAndSettle();

      await tester.enterText(_labeledField('Name'), 'Claude (work)');
      await tester.enterText(
        find.descendant(
          of: find.ancestor(
            of: find.text('API key'),
            matching: find.byType(InfoLabel),
          ),
          matching: find.byType(TextBox),
        ),
        'sk-ant-123',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final upsert = calls.singleWhere(
        (c) => c.$1 == MessageTypes.providerUpsertRequest,
      );
      final config = upsert.$2['config'] as Map<String, Object?>;
      // Empty id means "create"; the daemon assigns the real one.
      expect(config['id'], '');
      expect(config['displayName'], 'Claude (work)');
      expect(config['kind'], 'anthropic');
      expect(config['baseUrl'], 'https://api.anthropic.com/v1');
      expect(upsert.$2['apiKey'], 'sk-ant-123');

      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('editing prefills the form and preserves the id', (
      tester,
    ) async {
      final (client, calls) = listing(
        const [claude],
        extra: (type) => type == MessageTypes.providerUpsertRequest
            ? ProviderUpsertResponse(config: claude.toConfig()).toJson()
            : const {},
      );
      await pumpSettingsScreen(tester, client, section: 'providers');

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextFormBox>(_labeledField('Name')).controller!.text,
        'Claude (work)',
      );
      // A blank key field must not clear the stored secret.
      expect(
        find.textContaining('Leave blank to keep the existing key'),
        findsOneWidget,
      );

      await tester.enterText(_labeledField('Name'), 'Claude (renamed)');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final upsert = calls.singleWhere(
        (c) => c.$1 == MessageTypes.providerUpsertRequest,
      );
      final config = upsert.$2['config'] as Map<String, Object?>;
      expect(config['id'], 'p-claude');
      expect(config['displayName'], 'Claude (renamed)');
      expect(upsert.$2.containsKey('apiKey'), isFalse);

      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('an invalid base URL blocks the save', (tester) async {
      final (client, calls) = listing(const []);
      await pumpSettingsScreen(tester, client, section: 'providers');

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom (OpenAI-compatible)'));
      await tester.pumpAndSettle();

      await tester.enterText(_labeledField('Name'), 'Broken');
      await tester.enterText(_labeledField('Base URL'), 'not-a-url');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.text('Must be an absolute http(s) URL'), findsOneWidget);
      expect(
        calls.where((c) => c.$1 == MessageTypes.providerUpsertRequest),
        isEmpty,
      );
    });

    testWidgets('deleting asks for confirmation then sends provider.delete', (
      tester,
    ) async {
      final (client, calls) = listing(const [claude]);
      await pumpSettingsScreen(tester, client, section: 'providers');

      await tester.tap(find.byIcon(FluentIcons.delete));
      await tester.pumpAndSettle();

      expect(find.text('Delete Claude (work)?'), findsOneWidget);
      // The copy must warn that live agents break.
      expect(find.textContaining('fail to start'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      final deleteCall = calls.singleWhere(
        (c) => c.$1 == MessageTypes.providerDeleteRequest,
      );
      expect(deleteCall.$2['providerId'], 'p-claude');

      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('cancelling the delete sends nothing', (tester) async {
      final (client, calls) = listing(const [claude]);
      await pumpSettingsScreen(tester, client, section: 'providers');

      await tester.tap(find.byIcon(FluentIcons.delete));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Button, 'Cancel'));
      await tester.pumpAndSettle();

      expect(
        calls.where((c) => c.$1 == MessageTypes.providerDeleteRequest),
        isEmpty,
      );
    });

    testWidgets('a failing provider.list surfaces the error', (tester) async {
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.providerListRequest) {
            throw StateError('daemon offline');
          }
          return const {};
        };
      await pumpSettingsScreen(tester, client, section: 'providers');

      expect(
        find.textContaining('Failed to load providers'),
        findsOneWidget,
      );
    });

    testWidgets('a failing test surfaces the exception inline', (tester) async {
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.providerListRequest) {
            return {'providers': [claude.toJson()]};
          }
          if (type == MessageTypes.providerCredentialTestRequest) {
            throw StateError('socket closed');
          }
          return const {};
        };
      await pumpSettingsScreen(tester, client, section: 'providers');

      await tester.tap(find.text('Test Connection'));
      await tester.pumpAndSettle();

      expect(find.textContaining('socket closed'), findsOneWidget);
    });

    testWidgets('a failing delete keeps the row and toasts', (tester) async {
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.providerListRequest) {
            return {'providers': [claude.toJson()]};
          }
          if (type == MessageTypes.providerDeleteRequest) {
            throw StateError('write failed');
          }
          return const {};
        };
      await pumpSettingsScreen(tester, client, section: 'providers');

      await tester.tap(find.byIcon(FluentIcons.delete));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Failed to delete provider'), findsOneWidget);
      expect(find.text('Claude (work)'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('a failing upsert keeps the dialog open and toasts', (
      tester,
    ) async {
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.providerListRequest) {
            return const {'providers': []};
          }
          if (type == MessageTypes.providerUpsertRequest) {
            throw StateError('baseUrl rejected');
          }
          return const {};
        };
      await pumpSettingsScreen(tester, client, section: 'providers');

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Claude (Anthropic)'));
      await tester.pumpAndSettle();
      await tester.enterText(_labeledField('Name'), 'Claude');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Failed to save provider'), findsOneWidget);
      // The form stays up so the user can correct and retry.
      expect(find.byType(ContentDialog), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
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

    testWidgets('shows the destructive card with a confirmation dialog', (
      tester,
    ) async {
      await pumpSettingsScreen(tester, FakeDaemonClient(), section: 'reset');

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
                  id: 'openai',
                  kind: ProviderKind.openaiCompatible,
                  baseUrl: 'https://api.openai.example/v1',
                  displayName: 'Codex',
                  configured: true,
                ).toJson(),
              ],
            };
          }
          return const {};
        };
      final container = await pumpSettingsScreen(tester, client, section: 'reset');
      await container
          .read(connectionSettingsProvider.notifier)
          .save(host: '10.9.9.9', port: 7777, token: 'keep-me');

      await tester.tap(sectionResetButton());
      await tester.pumpAndSettle();

      // Dialog is showing.
      expect(find.byType(ContentDialog), findsOneWidget);
      expect(find.text('Reset all data?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Nothing was deleted, settings still point at the seeded host.
      expect(
        calls.where((c) => c.$1 == MessageTypes.providerDeleteRequest),
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
                    id: 'openai',
                  kind: ProviderKind.openaiCompatible,
                  baseUrl: 'https://api.openai.example/v1',
                    displayName: 'Codex',
                    configured: true,
                  ).toJson(),
                  const ProviderInfo(
                    id: 'deepseek',
                  kind: ProviderKind.openaiCompatible,
                  baseUrl: 'https://api.deepseek.example/v1',
                    displayName: 'DeepSeek',
                    configured: false,
                  ).toJson(),
                  const ProviderInfo(
                    id: 'openrouter',
                  kind: ProviderKind.openaiCompatible,
                  baseUrl: 'https://openrouter.example/api/v1',
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
        final container = await pumpSettingsScreen(tester, client, section: 'reset');
        await container
            .read(connectionSettingsProvider.notifier)
            .save(host: '10.9.9.9', port: 7777, token: 'keep-me');

        await tester.tap(sectionResetButton());
        await tester.pumpAndSettle();

        // Confirm inside the dialog (the only FilledButton there).
        final confirmButton = find.descendant(
          of: find.byType(ContentDialog),
          matching: find.byType(FilledButton),
        );
        expect(confirmButton, findsOneWidget);
        await tester.tap(confirmButton);
        await tester.pumpAndSettle();

        // Local settings snap back to defaults.
        expect(
          container.read(connectionSettingsProvider),
          const ConnectionSettings(),
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey('daemon.host'), isFalse);
        expect(prefs.containsKey('daemon.port'), isFalse);
        expect(prefs.containsKey('daemon.token'), isFalse);

        // Every provider is DELETED, not merely un-keyed: providers are user
        // data now, so a reset that left providers.json populated wouldn't be
        // a reset. That includes the unconfigured DeepSeek entry.
        final deletedIds = calls
            .where((c) => c.$1 == MessageTypes.providerDeleteRequest)
            .map((c) => c.$2['providerId'])
            .toSet();
        expect(deletedIds, {'openai', 'deepseek', 'openrouter'});

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
        // Let AppToast's auto-dismiss timer fire so no Timer remains pending.
        await tester.pump(const Duration(seconds: 5));
      },
    );

    testWidgets(
      'conversation-clear failure surfaces in the snackbar but the local '
      'reset still completes',
      (tester) async {
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
        final container = await pumpSettingsScreen(tester, client, section: 'reset');
        await container
            .read(connectionSettingsProvider.notifier)
            .save(host: '10.9.9.9', port: 7777);

        await tester.tap(sectionResetButton());
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(ContentDialog),
            matching: find.byType(FilledButton),
          ),
        );
        await tester.pumpAndSettle();

        // Local settings still reset.
        expect(
          container.read(connectionSettingsProvider),
          const ConnectionSettings(),
        );
        // The snackbar mentions the conversation failure.
        expect(
          find.textContaining('Some daemon-side items could not be cleared'),
          findsOneWidget,
        );
        expect(
          find.textContaining('conversations: Bad state: daemon offline'),
          findsOneWidget,
        );
        // The RPC was attempted.
        expect(
          calls.where(
            (c) => c.$1 == MessageTypes.agentConversationClearRequest,
          ),
          hasLength(1),
        );
        // Let AppToast's auto-dismiss timer fire (6s duration here) so no
        // Timer remains pending.
        await tester.pump(const Duration(seconds: 7));
      },
    );
  });
}
