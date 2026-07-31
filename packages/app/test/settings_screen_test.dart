import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/i18n/locales.dart';
import 'package:coding_agent_app/screens/settings_screen.dart';
import 'package:coding_agent_app/state/language_provider.dart';
import 'package:coding_agent_app/state/connection_settings_provider.dart';
import 'package:coding_agent_app/state/code_appearance_provider.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/state/host_registry_provider.dart';
import 'package:coding_agent_app/state/tool_call_detail_level_provider.dart';
import 'package:coding_agent_app/tool_calls/detail_level/tool_call_projection.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/legacy_agent_list_fetch_mixin.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeDaemonClient extends DaemonClient with LegacyAgentListFetchMixin {
  FakeDaemonClient({
    this._state = DaemonConnectionState.connected,
    this.rejectedHelloOverride,
  }) : super(uri: Uri.parse('ws://fake'));

  final DaemonConnectionState _state;
  final ServerHello? rejectedHelloOverride;

  /// Per-request-type scriptable response; defaults to an empty payload.
  Map<String, Object?> Function(String type, Map<String, Object?> payload)?
  onRequest;
  MutableDaemonConfig daemonConfig = const MutableDaemonConfig(
    injectMcpIntoAgents: false,
  );
  Object? configLoadError;
  Future<void> Function(MutableDaemonConfigPatch patch)? onConfigPatch;
  String diagnostic = 'Tinyrack daemon diagnostic';
  Object? diagnosticError;
  int diagnosticRequests = 0;

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
  }) async => onRequest?.call(type, payload) ?? const {};

  @override
  Future<MutableDaemonConfig> getDaemonConfig({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (configLoadError != null) throw configLoadError!;
    return daemonConfig;
  }

  @override
  Future<MutableDaemonConfig> patchDaemonConfig(
    MutableDaemonConfigPatch patch, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await onConfigPatch?.call(patch);
    daemonConfig = MutableDaemonConfig.fromJson(
      _deepMerge(daemonConfig.toJson(), patch.toJson()),
    );
    return daemonConfig;
  }

  @override
  Future<String> getDiagnostics({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    diagnosticRequests += 1;
    if (diagnosticError != null) throw diagnosticError!;
    return diagnostic;
  }
}

Map<String, Object?> _deepMerge(
  Map<String, Object?> current,
  Map<String, Object?> patch,
) {
  final next = <String, Object?>{...current};
  for (final entry in patch.entries) {
    final previous = next[entry.key];
    next[entry.key] = previous is Map && entry.value is Map
        ? _deepMerge(
            Map<String, Object?>.from(previous),
            Map<String, Object?>.from(entry.value as Map),
          )
        : entry.value;
  }
  return next;
}

Future<ProviderContainer> pumpSettingsScreen(
  WidgetTester tester,
  FakeDaemonClient client, {
  String section = 'general',
  bool withDiagnosticHost = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      daemonClientProvider.overrideWithValue(client),
      if (withDiagnosticHost)
        hostRegistryProvider.overrideWith(_DiagnosticHostRegistry.new),
    ],
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

Finder _labeledTextBox(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(InfoLabel)),
  matching: find.byType(TextBox),
);

Finder _toggleFor(String title) => find.descendant(
  of: find.ancestor(of: find.text(title), matching: find.byType(Card)),
  matching: find.byType(ToggleSwitch),
);

void main() {
  testWidgets('appearance settings persist the tool-call detail level', (
    tester,
  ) async {
    final container = await pumpSettingsScreen(
      tester,
      FakeDaemonClient(),
      section: 'appearance',
    );

    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Tool call detail'), findsOneWidget);
    expect(find.text('Code font size'), findsOneWidget);
    expect(find.text('12 px'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('appearance-mono-font-family')),
      findsOneWidget,
    );
    expect(find.text('Detailed'), findsOneWidget);

    await tester.tap(find.text('12 px'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('18 px').last);
    await tester.enterText(
      find.byKey(const ValueKey('appearance-mono-font-family')),
      'Cascadia Code',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(container.read(codeAppearanceProvider).codeFontSize, 18);
    expect(
      container.read(codeAppearanceProvider).monoFontFamily,
      'Cascadia Code',
    );

    await tester.tap(find.text('Detailed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Overview').last);
    await tester.pumpAndSettle();

    expect(
      container.read(toolCallDetailLevelProvider),
      ToolCallDetailLevel.overview,
    );
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(ToolCallDetailLevelNotifier.preferenceKey),
      'overview',
    );
  });

  testWidgets('appearance settings pick and persist the app language', (
    tester,
  ) async {
    final container = await pumpSettingsScreen(
      tester,
      FakeDaemonClient(),
      section: 'appearance',
    );

    // The test platform reports en-US, so "System" resolves to English and
    // every option is labelled in English alongside its native name.
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('App language'), findsOneWidget);
    expect(container.read(resolvedLocaleProvider), SupportedLocale.en);
    expect(find.text('System'), findsOneWidget);

    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();
    expect(find.text('日本語 - Japanese'), findsWidgets);
    await tester.tap(find.text('日本語 - Japanese').last);
    await tester.pumpAndSettle();

    expect(
      container.read(appLanguageProvider),
      AppLanguage.of(SupportedLocale.ja),
    );
    expect(container.read(resolvedLocaleProvider), SupportedLocale.ja);
    expect(
      (await SharedPreferences.getInstance()).getString('settings.language'),
      'ja',
    );

    // The trigger re-labels itself in the newly active locale, collapsing to
    // the single native name because Japanese named in Japanese is the same
    // string twice.
    expect(find.text('日本語'), findsOneWidget);

    // Reopening names every other language in Japanese too.
    await tester.tap(find.text('日本語'));
    await tester.pumpAndSettle();
    expect(find.text('English - 英語'), findsWidgets);
    expect(find.text('العربية - アラビア語'), findsWidgets);
  });

  testWidgets('keyboard section exposes shortcut rebinding', (tester) async {
    await pumpSettingsScreen(tester, FakeDaemonClient(), section: 'keyboard');

    expect(
      find.byKey(const ValueKey('keyboard-shortcuts-settings')),
      findsOneWidget,
    );
    expect(find.text('Keyboard shortcuts'), findsOneWidget);
    expect(find.text('Customize keyboard shortcuts.'), findsNothing);
    expect(find.textContaining('Customize keyboard shortcuts'), findsOneWidget);
  });

  testWidgets('diagnostics collects, refreshes, and reports daemon failures', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..serverInfo = const ServerInfoStatus(
        serverId: 'server-1',
        hostname: 'workstation',
        version: '0.2.0',
        desktopManaged: true,
        features: {'daemonDiagnostics': true},
      );
    await pumpSettingsScreen(
      tester,
      client,
      section: 'diagnostics',
      withDiagnosticHost: true,
    );

    expect(find.byKey(const Key('app-diagnostics-page')), findsOneWidget);
    expect(find.textContaining('Tinyrack app diagnostics'), findsOneWidget);
    expect(find.textContaining('Host: Local'), findsOneWidget);
    expect(find.textContaining('Tinyrack daemon diagnostic'), findsOneWidget);
    expect(client.diagnosticRequests, 1);

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.tap(find.byKey(const Key('copy-diagnostic')));
    await tester.pumpAndSettle();
    expect(find.text('Diagnostic copied.'), findsOneWidget);

    client.diagnosticError = StateError('diagnostic unavailable');
    await tester.tap(find.byKey(const Key('refresh-diagnostic')));
    await tester.pumpAndSettle();

    expect(client.diagnosticRequests, 2);
    expect(find.textContaining('Some diagnostics failed'), findsOneWidget);
    expect(find.textContaining('diagnostic unavailable'), findsWidgets);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('diagnostics explains an unavailable daemon capability', (
    tester,
  ) async {
    final client = FakeDaemonClient(state: DaemonConnectionState.disconnected);
    await pumpSettingsScreen(tester, client, section: 'diagnostics');

    expect(
      find.textContaining('unsupported or host is not connected'),
      findsOneWidget,
    );
    expect(client.diagnosticRequests, 0);
  });

  testWidgets('shows the current connection and the daemon uri', (
    tester,
  ) async {
    await pumpSettingsScreen(tester, FakeDaemonClient());

    expect(find.text('Connected — ws://127.0.0.1:6868'), findsOneWidget);
    expect(_labeledField('Host'), findsOneWidget);
    expect(find.text('Enable terminal agent hooks'), findsNothing);
  });

  testWidgets('terminal hook setting loads and patches daemon config', (
    tester,
  ) async {
    final patches = <MutableDaemonConfigPatch>[];
    final client = FakeDaemonClient()
      ..daemonConfig = const MutableDaemonConfig(
        injectMcpIntoAgents: false,
        enableTerminalAgentHooks: true,
      )
      ..onConfigPatch = (patch) async => patches.add(patch);
    await pumpSettingsScreen(tester, client, section: 'terminals');

    final toggle = _toggleFor('Enable terminal agent hooks');
    expect(tester.widget<ToggleSwitch>(toggle).checked, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(patches, hasLength(1));
    expect(patches.single.enableTerminalAgentHooks, isFalse);
    expect(tester.widget<ToggleSwitch>(toggle).checked, isFalse);
  });

  testWidgets('terminal hook mutation failure preserves state and reports it', (
    tester,
  ) async {
    final client = FakeDaemonClient()
      ..onConfigPatch = (_) async => throw StateError('write failed');
    await pumpSettingsScreen(tester, client, section: 'terminals');

    final toggle = _toggleFor('Enable terminal agent hooks');
    await tester.tap(toggle);
    await tester.pump(const Duration(milliseconds: 150));

    expect(
      find.textContaining('Unable to update terminal agent hooks'),
      findsOneWidget,
    );
    expect(tester.widget<ToggleSwitch>(toggle).checked, isFalse);
    await tester.pump(const Duration(seconds: 5));
  });

  group('Host parity settings', () {
    testWidgets('agents page patches MCP and browser tools', (tester) async {
      final patches = <MutableDaemonConfigPatch>[];
      final client = FakeDaemonClient()
        ..onConfigPatch = (patch) async => patches.add(patch);
      await pumpSettingsScreen(tester, client, section: 'agents');

      expect(find.text('Enable Tinyrack tools'), findsOneWidget);
      expect(find.text('Browser tools'), findsOneWidget);
      expect(find.text('System prompt'), findsOneWidget);

      await tester.tap(_toggleFor('Enable Tinyrack tools'));
      await tester.pumpAndSettle();
      await tester.tap(_toggleFor('Browser tools'));
      await tester.pumpAndSettle();

      expect(patches, hasLength(2));
      expect(patches[0].injectMcpIntoAgents, isTrue);
      expect(patches[1].browserToolsEnabled, isTrue);
      expect(
        tester
            .widget<ToggleSwitch>(_toggleFor('Enable Tinyrack tools'))
            .checked,
        isTrue,
      );
      expect(
        tester.widget<ToggleSwitch>(_toggleFor('Browser tools')).checked,
        isTrue,
      );
    });

    testWidgets('browser mutation reports its error and preserves state', (
      tester,
    ) async {
      final client = FakeDaemonClient()
        ..onConfigPatch = (_) async => throw StateError('policy denied');
      await pumpSettingsScreen(tester, client, section: 'agents');

      await tester.tap(_toggleFor('Browser tools'));
      await tester.pumpAndSettle();

      expect(find.textContaining('policy denied'), findsOneWidget);
      expect(
        tester.widget<ToggleSwitch>(_toggleFor('Browser tools')).checked,
        isFalse,
      );
    });

    testWidgets('host config load failure shows the error state', (
      tester,
    ) async {
      final client = FakeDaemonClient()
        ..configLoadError = StateError('config unavailable');
      await pumpSettingsScreen(tester, client, section: 'agents');

      expect(find.text('Unable to load host settings'), findsOneWidget);
      expect(find.textContaining('config unavailable'), findsOneWidget);
    });

    testWidgets('browser mutation disables the switch and shows progress', (
      tester,
    ) async {
      final pending = Completer<void>();
      final client = FakeDaemonClient()..onConfigPatch = (_) => pending.future;
      await pumpSettingsScreen(tester, client, section: 'agents');

      await tester.tap(_toggleFor('Browser tools'));
      await tester.pump();

      expect(find.text('Updating browser tools…'), findsOneWidget);
      expect(
        tester.widget<ToggleSwitch>(_toggleFor('Browser tools')).onChanged,
        isNull,
      );

      pending.complete();
      await tester.pumpAndSettle();
      expect(find.text('Updating browser tools…'), findsNothing);
    });

    testWidgets('system prompt sheet resets and saves the draft', (
      tester,
    ) async {
      final patches = <MutableDaemonConfigPatch>[];
      final client = FakeDaemonClient()
        ..daemonConfig = const MutableDaemonConfig(
          injectMcpIntoAgents: false,
          appendSystemPrompt: 'Existing',
        )
        ..onConfigPatch = (patch) async => patches.add(patch);
      await pumpSettingsScreen(tester, client, section: 'agents');

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Append system prompt'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('host-append-system-prompt-card')),
        findsOneWidget,
      );
      final keyedInput = find.byKey(
        const ValueKey('host-append-system-prompt-input'),
      );
      expect(keyedInput, findsOneWidget);
      expect(tester.getSize(keyedInput).height, 96);
      final input = find.byType(TextBox);
      expect(tester.widget<TextBox>(input).controller!.text, 'Existing');

      await tester.enterText(input, 'Draft');
      await tester.pump();
      await tester.tap(find.text('Reset'));
      await tester.pump();
      expect(tester.widget<TextBox>(input).controller!.text, 'Existing');

      await tester.enterText(input, 'Always keep replies concise.');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(patches.single.appendSystemPrompt, 'Always keep replies concise.');
      expect(find.text('Append system prompt'), findsNothing);
    });

    testWidgets('system prompt save failure stays open with an error', (
      tester,
    ) async {
      final client = FakeDaemonClient()
        ..onConfigPatch = (_) async => throw StateError('prompt rejected');
      await pumpSettingsScreen(tester, client, section: 'agents');

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextBox), 'New prompt');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('prompt rejected'), findsOneWidget);
      expect(find.text('Append system prompt'), findsOneWidget);
    });

    testWidgets('workspaces page patches merge auto-archive', (tester) async {
      final patches = <MutableDaemonConfigPatch>[];
      final client = FakeDaemonClient()
        ..onConfigPatch = (patch) async => patches.add(patch);
      await pumpSettingsScreen(tester, client, section: 'workspaces');

      await tester.tap(_toggleFor('Archive merged PR workspaces'));
      await tester.pumpAndSettle();

      expect(patches.single.autoArchiveAfterMerge, isTrue);
      expect(
        tester
            .widget<ToggleSwitch>(_toggleFor('Archive merged PR workspaces'))
            .checked,
        isTrue,
      );
    });

    testWidgets('terminal profiles add, edit, reorder, and remove', (
      tester,
    ) async {
      final patches = <MutableDaemonConfigPatch>[];
      final client = FakeDaemonClient()
        ..onConfigPatch = (patch) async => patches.add(patch);
      await pumpSettingsScreen(tester, client, section: 'terminals');

      expect(find.text('Claude Code'), findsOneWidget);
      expect(find.text('Codex'), findsOneWidget);
      expect(find.text('OpenCode'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('Terminal profiles'),
            matching: find.byType(Row),
          ),
          matching: find.byIcon(FluentIcons.add),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(_labeledTextBox('Name'), 'Custom Agent');
      await tester.enterText(_labeledTextBox('Command'), 'custom-agent');
      await tester.enterText(_labeledTextBox('Arguments'), '--mode fast');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Custom Agent'), findsOneWidget);
      expect(patches.last.terminalProfiles, hasLength(4));
      expect(patches.last.terminalProfiles!.last.args, ['--mode', 'fast']);

      final customRow = find.ancestor(
        of: find.text('Custom Agent'),
        matching: find.byType(Row),
      );
      await tester.tap(
        find.descendant(of: customRow, matching: find.byIcon(FluentIcons.edit)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(_labeledTextBox('Name'), 'Custom Agent 2');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Custom Agent 2'), findsOneWidget);

      final codexRow = find.ancestor(
        of: find.text('Codex'),
        matching: find.byType(Row),
      );
      await tester.tap(
        find.descendant(of: codexRow, matching: find.byIcon(FluentIcons.down)),
      );
      await tester.pumpAndSettle();
      expect(patches.last.terminalProfiles!.map((profile) => profile.id), [
        'claude',
        'opencode',
        'codex',
        isNot(anyOf('claude', 'codex', 'opencode')),
      ]);

      final customRowAfterMove = find.ancestor(
        of: find.text('Custom Agent 2'),
        matching: find.byType(Row),
      );
      await tester.tap(
        find.descendant(
          of: customRowAfterMove,
          matching: find.byIcon(FluentIcons.delete),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Remove profile?'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      expect(find.text('Custom Agent 2'), findsNothing);
      expect(patches.last.terminalProfiles, hasLength(3));
    });

    testWidgets(
      'terminal profile editor validates required fields and cancels',
      (tester) async {
        await pumpSettingsScreen(
          tester,
          FakeDaemonClient(),
          section: 'terminals',
        );
        await tester.tap(
          find.descendant(
            of: find.ancestor(
              of: find.text('Terminal profiles'),
              matching: find.byType(Row),
            ),
            matching: find.byIcon(FluentIcons.add),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Save'));
        await tester.pump();
        expect(find.text('Name is required'), findsOneWidget);
        expect(find.text('Command is required'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Add terminal profile'), findsNothing);
      },
    );

    testWidgets('disconnected host pages show their exact unavailable states', (
      tester,
    ) async {
      await pumpSettingsScreen(
        tester,
        FakeDaemonClient(state: DaemonConnectionState.disconnected),
        section: 'agents',
      );
      expect(
        find.text('Connect to this host to manage agents'),
        findsOneWidget,
      );
    });
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
    testWidgets('shows all three providers with a configured indicator', (
      tester,
    ) async {
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
      await pumpSettingsScreen(tester, client, section: 'providers');

      expect(find.text('AI Providers'), findsOneWidget);
      expect(find.text('Codex'), findsOneWidget);
      expect(find.text('DeepSeek'), findsOneWidget);
      expect(find.text('OpenRouter'), findsOneWidget);
      // Only the configured provider (Codex) shows a Remove button.
      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets('saving an API key sends provider.credential.set.request', (
      tester,
    ) async {
      final calls = <(String, Map<String, Object?>)>[];
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          calls.add((type, payload));
          return const {};
        };
      await pumpSettingsScreen(tester, client, section: 'providers');

      final deepseekKeyField = find.ancestor(
        of: find.text('DeepSeek'),
        matching: find.byType(Card),
      );
      await tester.enterText(
        find.descendant(of: deepseekKeyField, matching: find.byType(TextBox)),
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
      // Let AppToast's auto-dismiss timer fire so no Timer remains pending.
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('testing a connection shows the result', (tester) async {
      final client = FakeDaemonClient()
        ..onRequest = (type, payload) {
          if (type == MessageTypes.providerCredentialTestRequest) {
            return {'ok': false, 'error': 'invalid key'};
          }
          return const {};
        };
      await pumpSettingsScreen(tester, client, section: 'providers');

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

    testWidgets('removing a configured key sends provider.credential.clear', (
      tester,
    ) async {
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
      await pumpSettingsScreen(tester, client, section: 'providers');

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
                  id: ProviderId.openai,
                  displayName: 'Codex',
                  configured: true,
                ).toJson(),
              ],
            };
          }
          return const {};
        };
      final container = await pumpSettingsScreen(
        tester,
        client,
        section: 'reset',
      );
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

      // No clear RPC was sent, settings still point at the seeded host.
      expect(
        calls.where((c) => c.$1 == MessageTypes.providerCredentialClearRequest),
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
        final container = await pumpSettingsScreen(
          tester,
          client,
          section: 'reset',
        );
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

        // A clear RPC was sent for each CONFIGURED provider, not for the
        // unconfigured DeepSeek entry.
        final clearCalls = calls
            .where((c) => c.$1 == MessageTypes.providerCredentialClearRequest)
            .toList();
        final clearedIds = clearCalls.map((c) => c.$2['providerId']).toSet();
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
        final container = await pumpSettingsScreen(
          tester,
          client,
          section: 'reset',
        );
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

class _DiagnosticHostRegistry extends HostRegistryNotifier {
  @override
  HostRegistryState build() => const HostRegistryState(
    hosts: [
      HostProfile(
        serverId: 'server-1',
        label: 'Local',
        connections: [
          DirectTcpHostConnection(
            id: 'direct:127.0.0.1:6868',
            endpoint: '127.0.0.1:6868',
            password: 'secret',
          ),
        ],
        preferredConnectionId: 'direct:127.0.0.1:6868',
        createdAt: '2026-07-27T00:00:00.000Z',
        updatedAt: '2026-07-27T00:00:00.000Z',
      ),
    ],
    activeServerId: 'server-1',
    loaded: true,
  );
}
