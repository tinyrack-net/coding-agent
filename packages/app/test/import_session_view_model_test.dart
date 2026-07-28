import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/import_sessions/import_session_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

const _claude = ProviderSnapshotEntry(
  provider: 'claude',
  status: ProviderCatalogStatus.ready,
  label: 'Claude',
);
const _codex = ProviderSnapshotEntry(
  provider: 'codex',
  status: ProviderCatalogStatus.ready,
  enabled: false,
  label: 'Codex',
);

RecentProviderSessionDescriptor _session(
  String provider,
  String handle,
  String activity, {
  String? title,
  String? first,
  String? last,
}) => RecentProviderSessionDescriptor(
  providerId: provider,
  providerLabel: provider,
  providerHandleId: handle,
  cwd: '/repo',
  title: title,
  firstPromptPreview: first,
  lastPromptPreview: last,
  lastActivityAt: activity,
);

void main() {
  test('matches host upgrade and provider snapshot compatibility gates', () {
    expect(
      requiresImportSessionsHostUpgrade(
        supportsSnapshot: false,
        workspaceId: null,
        supportsWorkspaceTarget: false,
      ),
      isTrue,
    );
    expect(
      requiresImportSessionsHostUpgrade(
        supportsSnapshot: true,
        workspaceId: 'workspace-1',
        supportsWorkspaceTarget: false,
      ),
      isTrue,
    );
    expect(
      requiresImportSessionsHostUpgrade(
        supportsSnapshot: true,
        workspaceId: 'workspace-1',
        supportsWorkspaceTarget: true,
      ),
      isFalse,
    );
    expect(resolveImportSessionProviders(false, const []), isNull);
    expect(resolveImportSessionProviders(true, null), isNull);
    expect(resolveImportSessionProviders(true, const [_claude, _codex]), [
      'claude',
    ]);
    expect(buildImportProviderLabelMap(const [_claude, _codex]), {
      'claude': 'Claude',
      'codex': 'Codex',
    });
  });

  test('aggregates, deduplicates, sorts, and totals provider queries', () {
    final newer = _session('claude', 'same', '2026-07-28T02:00:00Z');
    final older = _session('codex', 'older', '2026-07-28T01:00:00Z');
    final queries = [
      ImportSessionsQueryResult(
        data: FetchRecentProviderSessionsResponse(
          requestId: '1',
          entries: [older, newer],
          filteredAlreadyImportedCount: 2,
        ),
      ),
      ImportSessionsQueryResult(
        data: FetchRecentProviderSessionsResponse(
          requestId: '2',
          entries: [newer],
          filteredAlreadyImportedCount: 3,
        ),
      ),
    ];
    expect(
      aggregateImportSessionEntries(
        queries,
      ).map((entry) => entry.providerHandleId),
      ['same', 'older'],
    );
    expect(sumAlreadyImportedSessions(queries), 5);
  });

  test('collects provider-owned error labels in query order', () {
    expect(
      collectErroredImportProviderLabels(
        providers: const ['claude', 'codex'],
        queries: const [
          ImportSessionsQueryResult(isError: true),
          ImportSessionsQueryResult(),
        ],
        providerLabels: const {'claude': 'Claude Code'},
      ),
      ['Claude Code'],
    );
    expect(
      collectErroredImportProviderLabels(
        providers: null,
        queries: const [],
        providerLabels: const {},
      ),
      isEmpty,
    );
  });

  test('uses the frozen title and prompt fallback order', () {
    expect(
      importSessionTitle(
        _session(
          'claude',
          '1',
          '2026-07-28T00:00:00Z',
          title: ' Title ',
          first: ' First ',
        ),
      ),
      'Title',
    );
    final promptFallback = _session(
      'claude',
      '2',
      '2026-07-28T00:00:00Z',
      first: ' First ',
    );
    expect(importSessionTitle(promptFallback), 'First');
    expect(importSessionPromptPreview(promptFallback), 'First');
    expect(
      importSessionPromptPreview(
        _session(
          'claude',
          '3',
          '2026-07-28T00:00:00Z',
          first: 'First',
          last: ' Last ',
        ),
      ),
      'Last',
    );
    final empty = _session('claude', '4', '2026-07-28T00:00:00Z');
    expect(importSessionTitle(empty), 'Untitled session');
    expect(importSessionPromptPreview(empty), 'No prompt preview');
  });

  test('computes each frozen empty-state branch', () {
    ImportSessionsEmptyState state({
      bool loading = false,
      bool errored = false,
      bool querying = true,
      bool settled = true,
      String provider = allImportSessionProviders,
      int aggregate = 0,
      int visible = 0,
      int imported = 0,
    }) => computeImportSessionsEmptyState(
      isLoadingSessions: loading,
      allQueriesErrored: errored,
      isQueryingProviders: querying,
      allQueriesSettled: settled,
      selectedProvider: provider,
      aggregatedCount: aggregate,
      visibleCount: visible,
      totalAlreadyImportedCount: imported,
      providerLabels: const {'codex': 'Codex'},
    );

    expect(state(loading: true).show, isFalse);
    expect(state(errored: true).show, isFalse);
    expect(state(querying: false).show, isFalse);
    expect(state(settled: false).show, isFalse);
    expect(state(visible: 1).show, isFalse);
    expect(
      state(provider: 'codex', aggregate: 1).title,
      'No recent Codex sessions to import.',
    );
    expect(
      state(imported: 1).title,
      'All recent sessions are already imported.',
    );
    expect(state().title, 'No recent sessions to import.');
  });
}
