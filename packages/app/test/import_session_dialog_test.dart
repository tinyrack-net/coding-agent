import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/daemon_client.dart';
import 'package:coding_agent_app/import_sessions/import_session_dialog.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _agent = AgentSummary(
  agentId: 'imported-1',
  title: 'Imported agent',
  cwd: '/repo',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1,
  workspaceId: 'workspace-1',
);

const _claude = ProviderSnapshotEntry(
  provider: 'claude',
  status: ProviderCatalogStatus.ready,
  label: 'Claude',
);
const _codex = ProviderSnapshotEntry(
  provider: 'codex',
  status: ProviderCatalogStatus.ready,
  label: 'Codex',
);

RecentProviderSessionDescriptor _session({
  String provider = 'claude',
  String handle = 'session-1',
  String cwd = '/repo',
  String? title = 'Fix the tests',
}) => RecentProviderSessionDescriptor(
  providerId: provider,
  providerLabel: provider,
  providerHandleId: handle,
  cwd: cwd,
  title: title,
  firstPromptPreview: 'First prompt',
  lastPromptPreview: 'Latest prompt',
  lastActivityAt: DateTime.now()
      .toUtc()
      .subtract(const Duration(minutes: 2))
      .toIso8601String(),
);

FetchRecentProviderSessionsResponse _response(
  List<RecentProviderSessionDescriptor> entries, {
  int? imported,
}) => FetchRecentProviderSessionsResponse(
  requestId: 'request',
  entries: entries,
  filteredAlreadyImportedCount: imported,
);

final class _FakeClient extends DaemonClient {
  _FakeClient() : super(uri: Uri.parse('ws://fake')) {
    serverInfo = const ServerInfoStatus(
      serverId: 'fake',
      hostname: 'fake',
      version: '0.2.0',
      desktopManaged: false,
      features: {
        'providersSnapshot': true,
        'importSessionWorkspaceTarget': true,
      },
    );
  }

  List<ProviderSnapshotEntry> snapshot = const [_claude];
  FetchRecentProviderSessionsResponse sessions = _response(const []);
  ImportAgentStatusResponse imported = const ImportAgentStatusResponse(
    requestId: 'request',
    status: 'agent_resumed',
    agentId: 'imported-1',
    agent: _agent,
  );

  @override
  DaemonConnectionState get currentState => DaemonConnectionState.connected;

  @override
  Future<GetProvidersSnapshotResponse> fetchProvidersSnapshot({
    String? cwd,
    Duration timeout = const Duration(seconds: 30),
  }) async => GetProvidersSnapshotResponse(
    entries: snapshot,
    generatedAt: DateTime.now().toUtc().toIso8601String(),
    requestId: 'snapshot',
  );

  @override
  Future<FetchRecentProviderSessionsResponse> fetchRecentProviderSessions({
    String? cwd,
    List<String>? providers,
    String? since,
    int? limit,
    Duration timeout = const Duration(seconds: 30),
  }) async => sessions;

  @override
  Future<ImportAgentStatusResponse> importProviderSession({
    required String providerId,
    required String providerHandleId,
    required String cwd,
    String? workspaceId,
    Map<String, String>? labels,
    Duration timeout = const Duration(seconds: 60),
  }) async => imported;
}

Future<void> _pump(
  WidgetTester tester, {
  DaemonClient? client,
  String? cwd = '/repo',
  String? workspaceId = 'workspace-1',
  bool supportsSnapshot = true,
  bool supportsWorkspaceTarget = true,
  ImportSessionSnapshotLoader? snapshotLoader,
  ImportSessionProviderLoader? providerLoader,
  ImportSessionImporter? importer,
  void Function(AgentSummary)? onImported,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: FluentApp(
        home: ImportSessionDialog(
          client: client,
          cwd: cwd,
          workspaceId: workspaceId,
          supportsSnapshot: supportsSnapshot,
          supportsWorkspaceTarget: supportsWorkspaceTarget,
          snapshotLoader: snapshotLoader,
          providerLoader: providerLoader,
          importer: importer,
          onImported: onImported,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows disconnected and host-upgrade gates', (tester) async {
    await _pump(tester);
    expect(find.text('Connect to a host to import sessions'), findsOneWidget);

    await _pump(tester, client: _FakeClient(), supportsWorkspaceTarget: false);
    expect(find.text('Update the host to import sessions.'), findsOneWidget);
  });

  testWidgets('loads each provider and reports partial failures', (
    tester,
  ) async {
    final calls = <String>[];
    await _pump(
      tester,
      client: _FakeClient(),
      snapshotLoader: () async => const [_claude, _codex],
      providerLoader: (provider) async {
        calls.add(provider);
        if (provider == 'codex') throw StateError('offline');
        return _response([_session()]);
      },
    );

    expect(calls, unorderedEquals(['claude', 'codex']));
    expect(
      find.byKey(const ValueKey('import-session-filter-trigger')),
      findsOneWidget,
    );
    expect(find.text('Fix the tests'), findsOneWidget);
    expect(find.text('Latest prompt'), findsOneWidget);
    expect(find.text('Could not load sessions from: Codex'), findsOneWidget);
  });

  testWidgets('shows already-imported empty state and refreshes', (
    tester,
  ) async {
    var loads = 0;
    await _pump(
      tester,
      client: _FakeClient(),
      snapshotLoader: () async => const [_claude],
      providerLoader: (_) async {
        loads++;
        return _response(const [], imported: 2);
      },
    );

    expect(
      find.text('All recent sessions are already imported.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('import-session-refresh')));
    await tester.pumpAndSettle();
    expect(loads, 2);
  });

  testWidgets('filters aggregated rows by provider', (tester) async {
    await _pump(
      tester,
      client: _FakeClient(),
      snapshotLoader: () async => const [_claude, _codex],
      providerLoader: (provider) async => _response([
        _session(
          provider: provider,
          handle: '$provider-session',
          title: '$provider title',
        ),
      ]),
    );

    tester
        .widget<ComboBox<String>>(
          find.byKey(const ValueKey('import-session-filter-trigger')),
        )
        .onChanged!('codex');
    await tester.pump();
    expect(find.text('claude title'), findsNothing);
    expect(find.text('codex title'), findsOneWidget);
  });

  testWidgets('uses the daemon client paths for discovery and import', (
    tester,
  ) async {
    final client = _FakeClient()..sessions = _response([_session()]);
    await _pump(
      tester,
      client: client,
      supportsSnapshot: true,
      supportsWorkspaceTarget: true,
    );
    await tester.tap(
      find.byKey(const ValueKey('import-session-session-claude-session-1')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('import-session-sheet')), findsNothing);
  });

  testWidgets('closes from the sheet action', (tester) async {
    await _pump(tester, client: _FakeClient());
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('import-session-sheet')), findsNothing);
  });

  testWidgets('reloads when scope changes and renders compact dated rows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var snapshotLoads = 0;
    Future<List<ProviderSnapshotEntry>> snapshotLoader() async {
      snapshotLoads++;
      return const [_claude];
    }

    Future<FetchRecentProviderSessionsResponse> providerLoader(_) async =>
        _response([
          for (final pair in const [
            ('hours', Duration(hours: 2)),
            ('days', Duration(days: 2)),
            ('months', Duration(days: 60)),
          ])
            RecentProviderSessionDescriptor(
              providerId: 'claude',
              providerLabel: 'Claude',
              providerHandleId: pair.$1,
              cwd: '/repo/${pair.$1}',
              title: pair.$1,
              firstPromptPreview: 'prompt',
              lastPromptPreview: 'prompt',
              lastActivityAt: DateTime.now()
                  .toUtc()
                  .subtract(pair.$2)
                  .toIso8601String(),
            ),
        ]);

    await tester.pumpWidget(
      ProviderScope(
        child: FluentApp(
          home: ImportSessionDialog(
            client: _FakeClient(),
            supportsSnapshot: true,
            supportsWorkspaceTarget: true,
            snapshotLoader: snapshotLoader,
            providerLoader: providerLoader,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2h ago'), findsOneWidget);
    expect(find.text('2d ago'), findsOneWidget);
    expect(find.text('2mo ago'), findsOneWidget);
    expect(find.text('/repo/months'), findsOneWidget);

    await tester.pumpWidget(
      ProviderScope(
        child: FluentApp(
          home: ImportSessionDialog(
            client: _FakeClient(),
            cwd: '/different',
            supportsSnapshot: true,
            supportsWorkspaceTarget: true,
            snapshotLoader: snapshotLoader,
            providerLoader: providerLoader,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(snapshotLoads, 2);
  });

  testWidgets('shows the no-compatible-provider state', (tester) async {
    await _pump(
      tester,
      client: _FakeClient(),
      snapshotLoader: () async => const [],
    );
    expect(find.text('No compatible providers are available.'), findsOneWidget);
  });

  testWidgets('shows progress while the provider snapshot is pending', (
    tester,
  ) async {
    final snapshot = Completer<List<ProviderSnapshotEntry>>();
    await tester.pumpWidget(
      ProviderScope(
        child: FluentApp(
          home: ImportSessionDialog(
            client: _FakeClient(),
            supportsSnapshot: true,
            supportsWorkspaceTarget: true,
            snapshotLoader: () => snapshot.future,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Loading recent sessions…'), findsOneWidget);
    expect(find.byType(ProgressRing), findsWidgets);
    snapshot.complete(const []);
    await tester.pumpAndSettle();
  });

  testWidgets('reports snapshot and all-provider loading failures', (
    tester,
  ) async {
    await _pump(
      tester,
      client: _FakeClient(),
      snapshotLoader: () async => throw StateError('snapshot failed'),
    );
    expect(find.text('Could not load recent sessions.'), findsOneWidget);

    await _pump(
      tester,
      client: _FakeClient(),
      snapshotLoader: () async => const [_claude, _codex],
      providerLoader: (_) async => throw StateError('provider failed'),
    );
    expect(find.text('Could not load recent sessions.'), findsOneWidget);
  });

  testWidgets('imports a row, returns the agent, and closes', (tester) async {
    AgentSummary? imported;
    await _pump(
      tester,
      client: _FakeClient(),
      snapshotLoader: () async => const [_claude],
      providerLoader: (_) async => _response([_session()]),
      importer: (_) async => const ImportAgentStatusResponse(
        requestId: 'request',
        status: 'agent_resumed',
        agentId: 'imported-1',
        agent: _agent,
      ),
      onImported: (agent) => imported = agent,
    );

    await tester.tap(
      find.byKey(const ValueKey('import-session-session-claude-session-1')),
    );
    await tester.pumpAndSettle();
    expect(imported, _agent);
    expect(find.byKey(const ValueKey('import-session-sheet')), findsNothing);
  });

  testWidgets('reports an import error and keeps the sheet open', (
    tester,
  ) async {
    await _pump(
      tester,
      client: _FakeClient(),
      snapshotLoader: () async => const [_claude],
      providerLoader: (_) async => _response([_session()]),
      importer: (_) async => throw StateError('failed'),
    );
    await tester.tap(
      find.byKey(const ValueKey('import-session-session-claude-session-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not import selected session.'), findsOneWidget);
  });
}
