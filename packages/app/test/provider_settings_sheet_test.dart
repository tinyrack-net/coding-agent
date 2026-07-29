import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/core/theme.dart';
import 'package:coding_agent_app/screens/host_providers_settings_section.dart';
import 'package:coding_agent_app/state/daemon_providers.dart';
import 'package:coding_agent_app/widgets/provider_settings_sheet.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _sonnet = ProviderModelDefinition(
  provider: 'claude',
  id: 'claude-sonnet-4',
  label: 'Claude Sonnet 4',
  description: 'Balanced model',
);

const _opus = ProviderModelDefinition(
  provider: 'claude',
  id: 'claude-opus-4',
  label: 'Claude Opus 4',
  description: 'Most capable model',
);

final class _ProviderClient extends DaemonClient {
  _ProviderClient() : super(uri: Uri.parse('ws://fake')) {
    serverInfo = const ServerInfoStatus(
      serverId: 'server-a',
      hostname: 'test',
      version: '0.2.0',
      desktopManaged: true,
      features: {'providersSnapshot': true},
    );
  }

  MutableDaemonConfig config = const MutableDaemonConfig(
    injectMcpIntoAgents: false,
    providers: {
      'claude': MutableDaemonProviderConfig(
        enabled: true,
        additionalModels: [
          MutableDaemonProviderModel(id: 'custom-one', label: 'custom-one'),
        ],
      ),
    },
  );
  int refreshCalls = 0;
  int patchCalls = 0;

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Future<MutableDaemonConfig> getDaemonConfig({
    Duration timeout = const Duration(seconds: 30),
  }) async => config;

  @override
  Future<MutableDaemonConfig> patchDaemonConfig(
    MutableDaemonConfigPatch patch, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    patchCalls++;
    config = MutableDaemonConfig(
      injectMcpIntoAgents: config.injectMcpIntoAgents,
      providers: {...config.providers, ...?patch.providers},
    );
    return config;
  }

  @override
  Future<GetProvidersSnapshotResponse> fetchProvidersSnapshot({
    String? cwd,
    Duration timeout = const Duration(seconds: 30),
  }) async => const GetProvidersSnapshotResponse(
    entries: [
      ProviderSnapshotEntry(
        provider: 'claude',
        status: ProviderCatalogStatus.ready,
        label: 'Claude Code',
        source: 'builtin',
        models: [_sonnet, _opus],
        fetchedAt: '2026-07-30T02:00:00.000Z',
      ),
    ],
    generatedAt: '2026-07-30T02:00:00.000Z',
    requestId: 'snapshot',
  );

  @override
  Future<RefreshProvidersSnapshotResponse> refreshProvidersSnapshot({
    String? cwd,
    List<String>? providers,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    refreshCalls++;
    expect(providers, ['claude']);
    return const RefreshProvidersSnapshotResponse(
      requestId: 'refresh',
      acknowledged: true,
    );
  }

  @override
  Future<ProviderDiagnosticResponse> getProviderDiagnostic(
    String provider, {
    String? requestId,
    Duration timeout = const Duration(seconds: 30),
  }) async => ProviderDiagnosticResponse(
    provider: provider,
    diagnostic: 'Claude Code\n  Models: 2\n  Status: Ready',
    requestId: requestId ?? 'diagnostic',
  );
}

void main() {
  testWidgets('provider sheet uses frozen compact 65 percent snap', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 800);
    addTearDown(tester.view.reset);
    final client = _ProviderClient();
    addTearDown(client.dispose);

    await _pump(
      tester,
      client,
      const ProviderSettingsSheet(serverId: 'server-a', provider: 'claude'),
    );
    await tester.pumpAndSettle();

    final card = tester.getRect(
      find.byKey(const ValueKey('adaptive-modal-sheet-card')),
    );
    expect(card, const Rect.fromLTWH(0, 280, 500, 520));
    expect(
      tester.getRect(find.byType(ProviderSettingsFooter)).bottom,
      lessThanOrEqualTo(card.bottom),
    );
  });

  testWidgets(
    'provider sheet searches, adds, removes, refreshes, and opens diagnostics',
    (tester) async {
      final client = _ProviderClient();
      addTearDown(client.dispose);
      await _pump(
        tester,
        client,
        const ProviderSettingsSheet(serverId: 'server-a', provider: 'claude'),
      );
      await tester.pumpAndSettle();

      expect(find.text('Claude Code'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('discovered-model-claude-sonnet-4')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('custom-model-custom-one')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('provider-settings-search')),
        'opus',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('discovered-model-claude-opus-4')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('discovered-model-claude-sonnet-4')),
        findsNothing,
      );
      expect(find.text('Custom models'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('provider-settings-search')),
        '',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('add-custom-model')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('add-custom-model-sheet')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const ValueKey('custom-model-id')),
        'custom-two',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('confirm-add-custom-model')));
      await tester.pumpAndSettle();
      expect(client.patchCalls, 1);
      expect(
        find.byKey(const ValueKey('custom-model-custom-two')),
        findsOneWidget,
      );

      final removeCustom = find.byKey(
        const ValueKey('remove-custom-model-custom-one'),
      );
      await tester.ensureVisible(removeCustom);
      await tester.pumpAndSettle();
      await tester.tap(removeCustom);
      await tester.pumpAndSettle();
      expect(client.patchCalls, 2);
      expect(
        find.byKey(const ValueKey('custom-model-custom-one')),
        findsNothing,
      );

      final refreshBefore = client.refreshCalls;
      await tester.tap(find.byKey(const ValueKey('refresh-provider-models')));
      await tester.pumpAndSettle();
      expect(client.refreshCalls, refreshBefore + 1);

      await tester.tap(find.byKey(const ValueKey('open-provider-diagnostic')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('provider-diagnostic-dialog')),
        findsOneWidget,
      );
      expect(find.textContaining('Status: Ready'), findsOneWidget);
    },
  );

  testWidgets('installed provider row opens the model settings sheet', (
    tester,
  ) async {
    final client = _ProviderClient();
    addTearDown(client.dispose);
    await _pump(
      tester,
      client,
      const HostProvidersSettingsSection(serverId: 'server-a'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('installed-provider-claude')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('provider-settings-sheet')),
      findsOneWidget,
    );
    expect(find.text('Discovered'), findsOneWidget);
    expect(find.text('Custom models'), findsOneWidget);
  });

  testWidgets('add model sheet disables blank and duplicate ids', (
    tester,
  ) async {
    var additions = 0;
    await _pump(
      tester,
      null,
      AddCustomProviderModelSheet(
        existingModels: const [
          MutableDaemonProviderModel(id: 'existing', label: 'existing'),
        ],
        onAdd: (_) async => additions++,
      ),
    );

    final button = find.byKey(const ValueKey('confirm-add-custom-model'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('custom-model-id')),
      'existing',
    );
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(additions, 0);
  });

  testWidgets('model body preserves frozen loading and empty states', (
    tester,
  ) async {
    await _pump(
      tester,
      null,
      ProviderSettingsModelsBody(
        discoveredModels: const [],
        customModels: const [],
        totalDiscovered: 0,
        totalCustom: 0,
        searching: false,
        refreshing: true,
        error: null,
        deletingModelId: null,
        onDeleteCustomModel: (_) {},
        onRetry: () {},
      ),
    );
    expect(find.text('Loading models...'), findsOneWidget);
    expect(find.byType(ProgressRing), findsOneWidget);

    await _pump(
      tester,
      null,
      ProviderSettingsModelsBody(
        discoveredModels: const [],
        customModels: const [],
        totalDiscovered: 2,
        totalCustom: 1,
        searching: true,
        refreshing: false,
        error: null,
        deletingModelId: null,
        onDeleteCustomModel: (_) {},
        onRetry: () {},
      ),
    );
    expect(find.text('No models match your search'), findsOneWidget);

    await _pump(
      tester,
      null,
      ProviderSettingsModelsBody(
        discoveredModels: const [],
        customModels: const [],
        totalDiscovered: 0,
        totalCustom: 0,
        searching: false,
        refreshing: false,
        error: null,
        deletingModelId: null,
        onDeleteCustomModel: (_) {},
        onRetry: () {},
      ),
    );
    expect(find.text('No models detected'), findsOneWidget);
  });

  testWidgets('provider error state exposes retry', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      null,
      ProviderSettingsModelsBody(
        discoveredModels: const [],
        customModels: const [],
        totalDiscovered: 0,
        totalCustom: 0,
        searching: false,
        refreshing: false,
        error: 'catalog failed',
        deletingModelId: null,
        onDeleteCustomModel: (_) {},
        onRetry: () => retries++,
      ),
    );

    expect(find.text('catalog failed'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retry-provider-models')));
    await tester.pump(const Duration(milliseconds: 150));
    expect(retries, 1);
  });
}

Future<void> _pump(WidgetTester tester, DaemonClient? client, Widget home) =>
    tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (client != null) daemonClientProvider.overrideWithValue(client),
        ],
        child: FluentApp(theme: buildAppTheme(), home: home),
      ),
    );
