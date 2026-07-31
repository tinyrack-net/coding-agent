// Ports of the upstream Paseo 0.2.0 suites for the five stores collected in
// `lib/state/paseo_ui_stores.dart`:
//
//   stores/browser-store/state.test.ts
//   stores/sidebar-collapsed-sections-store/state.test.ts
//   stores/sidebar-view-store.test.ts
//   stores/navigation-active-workspace-store/navigation.test.ts
//   stores/draft-store/migration.test.ts
//
// Every upstream case is ported, plus the edges those suites leave unpinned:
// JS truthiness vs nullishness, the exact reference-identity contracts, Set and
// Map iteration order, the `Array.sort` stability the New Workspace promotion
// leans on, persist-envelope round trips, and the validation arms that no
// upstream fixture exercises.
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/host_routes.dart';
import 'package:coding_agent_app/core/paseo_app_misc.dart'
    show MutableKeyValueStorage;
import 'package:coding_agent_app/state/paseo_ui_stores.dart';
import 'package:coding_agent_app/workspace/workspace_tab_model.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

final class _MemoryStorage implements MutableKeyValueStorage {
  _MemoryStorage([Map<String, String?>? initial]) : values = {...?initial};

  final Map<String, String?> values;
  final List<String> reads = [];

  @override
  Future<String?> getItem(String key) async {
    reads.add(key);
    return values[key];
  }

  @override
  Future<void> setItem(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> removeItem(String key) async {
    values[key] = null;
  }
}

BrowserIndexState _withRecords(List<BrowserRecord> records) =>
    BrowserIndexState(
      browsersById: {for (final record in records) record.browserId: record},
    );

BrowserRecord _record(String browserId, String? url, {int now = 0}) =>
    createBrowserRecord(browserId: browserId, initialUrl: url, now: now);

CollapsedProjectsState _emptyCollapsed() =>
    const CollapsedProjectsState.empty();

AgentSummary _agent({
  required String agentId,
  String? workspaceId,
  bool requiresAttention = false,
  AgentAttentionReason? attentionReason,
  String? attentionTimestamp,
  String? parentAgentId,
}) => AgentSummary(
  agentId: agentId,
  title: agentId,
  cwd: '/repo/workspace-a',
  provider: 'claude',
  model: 'sonnet',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 0,
  workspaceId: workspaceId,
  requiresAttention: requiresAttention,
  attentionReason: attentionReason,
  attentionTimestamp: attentionTimestamp,
  parentAgentId: parentAgentId,
);

WorkspaceDescriptor _workspace(String id) => WorkspaceDescriptor(
  id: id,
  projectId: 'project-1',
  projectDisplayName: 'Project',
  projectRootPath: '/repo',
  workspaceDirectory: '/repo/$id',
  projectKind: WorkspaceProjectKind.git,
  workspaceKind: WorkspaceKind.worktree,
  name: id,
  status: WorkspaceStateBucket.done,
  activityAt: null,
);

final class _RecordedTab {
  const _RecordedTab(this.workspaceKey, this.target);

  final String workspaceKey;
  final WorkspaceTabTarget target;
}

final class _NavigationHarness {
  _NavigationHarness({
    Map<String, WorkspaceDescriptor>? Function(String serverId)?
    getSessionWorkspaces,
    Iterable<AgentSummary> Function(String serverId)? getSessionAgents,
  }) {
    deps = NavigateToWorkspaceDeps(
      getSessionWorkspaces: getSessionWorkspaces ?? (_) => null,
      getSessionAgents: getSessionAgents ?? (_) => const <AgentSummary>[],
      openTabFocused: (workspaceKey, target) {
        openedTabs.add(_RecordedTab(workspaceKey, target));
        return target is WorkspaceAgentTabTarget ? target.agentId : null;
      },
      pinAgent: (workspaceKey, agentId) =>
          pinnedAgents.add('$workspaceKey/$agentId'),
      rememberLastWorkspace: (selection) {
        remembered.add(selection);
        lastSelection = selection;
      },
      navigateToRoute: navigations.add,
    );
  }

  late final NavigateToWorkspaceDeps deps;
  final List<String> navigations = [];
  final List<HostWorkspaceRoute> remembered = [];
  final List<_RecordedTab> openedTabs = [];
  final List<String> pinnedAgents = [];
  HostWorkspaceRoute? lastSelection;

  NavigateToLastWorkspaceDeps get lastDeps => NavigateToLastWorkspaceDeps(
    base: deps,
    getLastWorkspaceSelection: () => lastSelection,
  );
}

Matcher _isRoute(String serverId, String workspaceId) =>
    isA<HostWorkspaceRoute>()
        .having((route) => route.serverId, 'serverId', serverId)
        .having((route) => route.workspaceId, 'workspaceId', workspaceId);

Future<List<AttachmentMetadata>> _passThroughMigrateLegacyImages(
  List<PersistedDraftImage> images,
) async => [
  for (final image in images)
    if (image is PersistedAttachmentDraftImage) image.metadata,
];

DraftMigrationPorts _ports(int nowMs) => DraftMigrationPorts(
  migrateLegacyImages: _passThroughMigrateLegacyImages,
  nowMs: nowMs,
);

Map<String, Object?> _activeDraftJson(
  String text,
  int updatedAt, [
  List<Object?> attachments = const [],
]) => {
  'input': {'text': text, 'attachments': attachments},
  'lifecycle': 'active',
  'updatedAt': updatedAt,
  'version': 1,
};

Map<String, Object?> _githubIssueAttachment(int number) => {
  'kind': 'github_issue',
  'item': {
    'kind': 'issue',
    'number': number,
    'title': 'Review item $number',
    'url': 'https://example.com/issues/$number',
    'state': 'open',
    'body': null,
    'labels': <String>[],
  },
};

Map<String, Object?> _githubPrAttachment(int number) => {
  'kind': 'github_pr',
  'item': {
    'kind': 'change_request',
    'number': number,
    'title': 'Review item $number',
    'url': 'https://example.com/pulls/$number',
    'state': 'open',
    'body': null,
    'labels': <String>[],
    'baseRefName': 'main',
    'headRefName': 'feature/legacy',
  },
};

Map<String, Object?> _workspaceReviewAttachment() => {
  'kind': 'review',
  'reviewDraftKey': 'review:key',
  'commentCount': 1,
  'attachment': {
    'type': 'review',
    'mimeType': 'application/paseo-review',
    'cwd': '/repo',
    'mode': 'uncommitted',
    'baseRef': null,
    'comments': <Object?>[],
  },
};

void main() {
  // =========================================================================
  // 1. browser-store/state.ts
  // =========================================================================

  group('normalizeBrowserUrl', () {
    test('normalizes local development hosts to http by default', () {
      expect(normalizeBrowserUrl('localhost:8081'), 'http://localhost:8081');
      expect(normalizeBrowserUrl('localhost/path'), 'http://localhost/path');
      expect(
        normalizeBrowserUrl('127.0.0.1:3000/path'),
        'http://127.0.0.1:3000/path',
      );
      expect(normalizeBrowserUrl('192.168.0.8'), 'http://192.168.0.8');
      expect(normalizeBrowserUrl('[::1]:5173'), 'http://[::1]:5173');
    });

    test('normalizes public hosts to https by default', () {
      expect(normalizeBrowserUrl('example.com'), 'https://example.com');
      expect(
        normalizeBrowserUrl('//example.com/path'),
        'https://example.com/path',
      );
    });

    test('keeps explicit protocols unchanged', () {
      expect(
        normalizeBrowserUrl('http://localhost:8081'),
        'http://localhost:8081',
      );
      expect(
        normalizeBrowserUrl('https://localhost:8081'),
        'https://localhost:8081',
      );
      expect(
        normalizeBrowserUrl('file:///tmp/example.html'),
        'file:///tmp/example.html',
      );
    });

    test('falls back to a default URL when input is blank', () {
      expect(normalizeBrowserUrl(null), 'https://example.com');
      expect(normalizeBrowserUrl('   '), 'https://example.com');
      expect(normalizeBrowserUrl(''), 'https://example.com');
    });

    // Edge: upstream trims before every branch, so surrounding whitespace never
    // reaches the produced URL.
    test('trims before deciding a scheme', () {
      expect(normalizeBrowserUrl('  localhost:3000 '), 'http://localhost:3000');
      expect(normalizeBrowserUrl('  example.com '), 'https://example.com');
    });

    // Edge: the local-host pattern is anchored *and* terminated, so a host that
    // merely starts with "localhost" is treated as a public host.
    test('only treats a whole local host label as local', () {
      expect(normalizeBrowserUrl('localhost'), 'http://localhost');
      expect(normalizeBrowserUrl('localhost?q=1'), 'http://localhost?q=1');
      expect(normalizeBrowserUrl('localhost#top'), 'http://localhost#top');
      expect(
        normalizeBrowserUrl('localhostfoo.com'),
        'https://localhostfoo.com',
      );
      expect(normalizeBrowserUrl('[::1]'), 'http://[::1]');
    });

    // Edge: the dotted-quad arm is deliberately loose (`\d{1,3}` per octet with
    // no range check), so an out-of-range literal still gets the http default.
    test('does not range-check the dotted-quad arm', () {
      expect(normalizeBrowserUrl('999.999.999.999'), 'http://999.999.999.999');
      expect(normalizeBrowserUrl('1.2.3'), 'https://1.2.3');
    });

    // Edge: any RFC-shaped scheme is preserved, not just http/https/file.
    test('preserves an arbitrary explicit scheme', () {
      expect(
        normalizeBrowserUrl('chrome-extension://abc/page.html'),
        'chrome-extension://abc/page.html',
      );
      expect(normalizeBrowserUrl('mailto:a@b.test'), 'mailto:a@b.test');
    });
  });

  group('createBrowserRecord', () {
    test('normalizes the initial URL and starts with idle state', () {
      final record = createBrowserRecord(
        browserId: 'b1',
        initialUrl: 'localhost:8081',
        now: 1000,
      );

      expect(record.toJson(), {
        'browserId': 'b1',
        'url': 'http://localhost:8081',
        'title': '',
        'isLoading': false,
        'canGoBack': false,
        'canGoForward': false,
        'faviconUrl': null,
        'lastError': null,
        'createdAt': 1000,
      });
    });

    // Edge: `createdAt` comes from the caller's clock, never a wall clock read
    // inside the rule.
    test('stamps createdAt from the supplied clock reading', () {
      expect(
        createBrowserRecord(
          browserId: 'b1',
          initialUrl: null,
          now: 42,
        ).createdAt,
        42,
      );
    });
  });

  group('applyBrowserPatch', () {
    test('normalizes URL updates', () {
      final initial = _withRecords([_record('b1', 'https://a.test')]);

      final next = applyBrowserPatch(
        initial,
        'b1',
        const BrowserRecordPatch(url: 'example.com/path'),
      );

      expect(next.browsersById['b1']?.url, 'https://example.com/path');
    });

    test('returns the same state reference when nothing changes', () {
      final initial = _withRecords([_record('b1', 'https://a.test')]);

      final next = applyBrowserPatch(
        initial,
        'b1',
        const BrowserRecordPatch(url: 'https://a.test', title: ''),
      );

      expect(next, same(initial));
    });

    test('returns the same state when the browser id is unknown', () {
      final initial = _withRecords([_record('b1', 'https://a.test')]);

      expect(
        applyBrowserPatch(
          initial,
          'missing',
          const BrowserRecordPatch(title: 'x'),
        ),
        same(initial),
      );
    });

    test('returns the same state when the browser id is blank', () {
      final initial = _withRecords([_record('b1', 'https://a.test')]);

      expect(
        applyBrowserPatch(initial, '   ', const BrowserRecordPatch(title: 'x')),
        same(initial),
      );
    });

    // Edge: the id is trimmed before lookup, so a padded id still finds its
    // record.
    test('trims the browser id before looking it up', () {
      final initial = _withRecords([_record('b1', 'https://a.test')]);

      final next = applyBrowserPatch(
        initial,
        '  b1  ',
        const BrowserRecordPatch(title: 'Trimmed'),
      );

      expect(next, isNot(same(initial)));
      expect(next.browsersById['b1']?.title, 'Trimmed');
      expect(next.browsersById.keys, ['b1']);
    });

    // Edge: `patch.url ?? existing.url` is nullish, not falsy, so an empty
    // string patch is *used* and normalises to the default URL.
    test('uses an empty-string url patch rather than keeping the old url', () {
      final initial = _withRecords([_record('b1', 'https://a.test')]);

      final next = applyBrowserPatch(
        initial,
        'b1',
        const BrowserRecordPatch(url: ''),
      );

      expect(next.browsersById['b1']?.url, 'https://example.com');
    });

    // Edge: the nullable fields distinguish "absent" from "explicitly null".
    test('clears a nullable field only when the patch carries it', () {
      final initial = _withRecords([_record('b1', 'https://a.test')]);
      final withFavicon = applyBrowserPatch(
        initial,
        'b1',
        const BrowserRecordPatch(
          faviconUrl: PatchField('https://a.test/favicon.ico'),
          lastError: PatchField('boom'),
        ),
      );

      expect(withFavicon.browsersById['b1']?.faviconUrl, isNotNull);

      final untouched = applyBrowserPatch(
        withFavicon,
        'b1',
        const BrowserRecordPatch(title: 'Title'),
      );
      expect(
        untouched.browsersById['b1']?.faviconUrl,
        'https://a.test/favicon.ico',
      );
      expect(untouched.browsersById['b1']?.lastError, 'boom');

      final cleared = applyBrowserPatch(
        untouched,
        'b1',
        const BrowserRecordPatch(
          faviconUrl: PatchField(null),
          lastError: PatchField(null),
        ),
      );
      expect(cleared.browsersById['b1']?.faviconUrl, isNull);
      expect(cleared.browsersById['b1']?.lastError, isNull);
    });

    // Edge: identity and birth time are outside the patch type, so they survive
    // every update.
    test('never rewrites browserId or createdAt', () {
      final initial = _withRecords([_record('b1', 'https://a.test', now: 7)]);

      final next = applyBrowserPatch(
        initial,
        'b1',
        const BrowserRecordPatch(isLoading: true, canGoBack: true),
      );

      expect(next.browsersById['b1']?.browserId, 'b1');
      expect(next.browsersById['b1']?.createdAt, 7);
      expect(next.browsersById['b1']?.isLoading, isTrue);
      expect(next.browsersById['b1']?.canGoBack, isTrue);
    });

    // Edge: other records are untouched and keep their insertion position.
    test('leaves sibling records and key order alone', () {
      final initial = _withRecords([
        _record('b1', 'https://a.test'),
        _record('b2', 'https://b.test'),
      ]);
      final b2 = initial.browsersById['b2'];

      final next = applyBrowserPatch(
        initial,
        'b1',
        const BrowserRecordPatch(title: 'A'),
      );

      expect(next.browsersById.keys, ['b1', 'b2']);
      expect(next.browsersById['b2'], same(b2));
    });
  });

  group('removeBrowserFromIndex', () {
    test('removes the named browser', () {
      final initial = _withRecords([
        _record('b1', 'https://a.test'),
        _record('b2', 'https://b.test'),
      ]);

      final next = removeBrowserFromIndex(initial, 'b1');

      expect(next.browsersById.keys.toList(), ['b2']);
    });

    test('returns the same state when the browser id is unknown', () {
      final initial = _withRecords([_record('b1', 'https://a.test')]);

      expect(removeBrowserFromIndex(initial, 'missing'), same(initial));
    });

    test('returns the same state when the browser id is blank', () {
      final initial = _withRecords([_record('b1', 'https://a.test')]);

      expect(removeBrowserFromIndex(initial, '   '), same(initial));
    });

    // Edge: removal trims too, and does not mutate the source map.
    test('trims the id and leaves the input state untouched', () {
      final initial = _withRecords([
        _record('b1', 'https://a.test'),
        _record('b2', 'https://b.test'),
      ]);

      final next = removeBrowserFromIndex(initial, ' b2 ');

      expect(next.browsersById.keys.toList(), ['b1']);
      expect(initial.browsersById.keys.toList(), ['b1', 'b2']);
    });
  });

  group('sanitizeBrowsersForPersist', () {
    test('clears transient fields on every record', () {
      final base = _record('b1', 'https://a.test');
      final state = BrowserIndexState(
        browsersById: {
          'b1': BrowserRecord(
            browserId: base.browserId,
            url: base.url,
            title: base.title,
            isLoading: true,
            canGoBack: base.canGoBack,
            canGoForward: base.canGoForward,
            faviconUrl: base.faviconUrl,
            lastError: 'network down',
            createdAt: base.createdAt,
          ),
        },
      );

      final persisted = sanitizeBrowsersForPersist(state);

      expect(persisted.browsersById['b1']?.isLoading, isFalse);
      expect(persisted.browsersById['b1']?.lastError, isNull);
    });

    // Edge: only the two transient fields are cleared; navigation affordances
    // and the favicon survive so a restored tab renders correctly.
    test('keeps every non-transient field and the key order', () {
      final state = BrowserIndexState(
        browsersById: {
          'b1': const BrowserRecord(
            browserId: 'b1',
            url: 'https://a.test/page',
            title: 'A',
            isLoading: true,
            canGoBack: true,
            canGoForward: true,
            faviconUrl: 'https://a.test/icon.png',
            lastError: 'boom',
            createdAt: 5,
          ),
          'b2': const BrowserRecord(
            browserId: 'b2',
            url: 'https://b.test',
            title: '',
            isLoading: false,
            canGoBack: false,
            canGoForward: false,
            faviconUrl: null,
            lastError: null,
            createdAt: 6,
          ),
        },
      );

      final persisted = sanitizeBrowsersForPersist(state);

      expect(persisted.browsersById.keys.toList(), ['b1', 'b2']);
      expect(persisted.browsersById['b1']?.toJson(), {
        'browserId': 'b1',
        'url': 'https://a.test/page',
        'title': 'A',
        'isLoading': false,
        'canGoBack': true,
        'canGoForward': true,
        'faviconUrl': 'https://a.test/icon.png',
        'lastError': null,
        'createdAt': 5,
      });
      // The source state is not mutated.
      expect(state.browsersById['b1']?.isLoading, isTrue);
    });
  });

  group('BrowserIndexStore', () {
    test('creates, patches and removes browsers through storage', () async {
      final storage = _MemoryStorage();
      var counter = 0;
      final store = BrowserIndexStore(
        storage: storage,
        generateBrowserId: () => 'browser-${++counter}',
        nowMs: () => 1000 + counter,
      );

      final first = await store.createBrowser(initialUrl: 'localhost:8081');
      expect(first, 'browser-1');
      expect(store.getBrowserRecord('browser-1')?.url, 'http://localhost:8081');
      expect(store.getBrowserRecord('  browser-1  ')?.url, isNotNull);
      expect(store.getBrowserRecord('   '), isNull);

      await store.updateBrowser(
        'browser-1',
        const BrowserRecordPatch(title: 'Local', isLoading: true),
      );
      expect(store.state.browsersById['browser-1']?.title, 'Local');

      // The persisted envelope carries the sanitised state, not the live one.
      final envelope =
          jsonDecode(storage.values[browserStoreStorageName]!) as Map;
      expect(envelope['version'], 0);
      final persisted =
          ((envelope['state'] as Map)['browsersById'] as Map)['browser-1']
              as Map;
      expect(persisted['isLoading'], isFalse);
      expect(persisted['title'], 'Local');

      await store.removeBrowser('browser-1');
      expect(store.state.browsersById, isEmpty);
    });

    test('rehydrates from the persisted envelope', () async {
      final storage = _MemoryStorage({
        browserStoreStorageName: jsonEncode({
          'state': {
            'browsersById': {
              'b1': {
                'browserId': 'b1',
                'url': 'localhost:9000',
                'title': 'Local',
                'isLoading': true,
                'canGoBack': true,
                'canGoForward': false,
                'faviconUrl': null,
                'lastError': 'stale',
                'createdAt': 12,
              },
              'b2': 'not-an-object',
            },
          },
          'version': 0,
        }),
      });
      final store = BrowserIndexStore(
        storage: storage,
        generateBrowserId: () => 'unused',
        nowMs: () => 0,
      );

      await store.rehydrate();

      // The URL is re-normalised on the way in and the non-object entry is
      // dropped rather than poisoning the index.
      expect(store.state.browsersById.keys.toList(), ['b1']);
      expect(store.state.browsersById['b1']?.url, 'http://localhost:9000');
      expect(store.state.browsersById['b1']?.createdAt, 12);
      // Transient fields are restored as written; only `partialize` clears them.
      expect(store.state.browsersById['b1']?.isLoading, isTrue);
    });

    test(
      'ignores a missing key, a non-object blob and a foreign version',
      () async {
        Future<BrowserIndexStore> hydrate(Map<String, String?> values) async {
          final store = BrowserIndexStore(
            storage: _MemoryStorage(values),
            generateBrowserId: () => 'unused',
            nowMs: () => 0,
          );
          await store.rehydrate();
          return store;
        }

        expect((await hydrate({})).state.browsersById, isEmpty);
        expect(
          (await hydrate({browserStoreStorageName: 'null'})).state.browsersById,
          isEmpty,
        );
        expect(
          (await hydrate({browserStoreStorageName: '[]'})).state.browsersById,
          isEmpty,
        );
        expect(
          (await hydrate({
            browserStoreStorageName: jsonEncode({
              'state': {
                'browsersById': {
                  'b1': {'url': 'https://a.test'},
                },
              },
              'version': 99,
            }),
          })).state.browsersById,
          isEmpty,
        );
      },
    );
  });

  // =========================================================================
  // 2. sidebar-collapsed-sections-store/state.ts
  // =========================================================================

  group('sidebar collapsed projects transitions', () {
    test('tracks collapsed project keys as a Set', () {
      var state = _emptyCollapsed();

      state = setProjectCollapsed(state, 'project-a', true);
      state = toggleProjectCollapsed(state, 'project-b');
      state = toggleProjectCollapsed(state, 'project-a');
      state = toggleStatusGroupCollapsed(state, 'running');

      expect(state.collapsedProjectKeys.toList(), ['project-b']);
      expect(state.collapsedStatusGroupKeys.toList(), ['running']);
    });

    test('serializes collapsed project keys for preference storage', () {
      const state = CollapsedProjectsState(
        collapsedProjectKeys: {'project-a', 'project-b'},
        collapsedStatusGroupKeys: {'running'},
        collapsedPinned: true,
      );

      expect(serializeCollapsedProjects(state), {
        'collapsedProjectKeys': ['project-a', 'project-b'],
        'collapsedStatusGroupKeys': ['running'],
        'collapsedPinned': true,
      });
    });

    test('toggles and restores the pinned section collapse flag', () {
      final toggled = togglePinnedCollapsed(_emptyCollapsed());
      expect(toggled.collapsedPinned, isTrue);

      final restored = mergePersistedCollapsedProjects({
        'collapsedPinned': true,
      }, _emptyCollapsed());
      expect(restored.collapsedPinned, isTrue);
    });

    test('restores collapsed project keys from persisted preferences', () {
      final restored = mergePersistedCollapsedProjects({
        'collapsedProjectKeys': ['project-a', 'project-b', 42],
      }, _emptyCollapsed());

      expect(restored.collapsedProjectKeys.toList(), [
        'project-a',
        'project-b',
      ]);
      expect(restored.collapsedStatusGroupKeys, isEmpty);
    });

    test('keeps the existing state object when persisted preferences do not '
        'change collapsed keys', () {
      final currentState = _emptyCollapsed();

      expect(
        mergePersistedCollapsedProjects(null, currentState),
        same(currentState),
      );
      expect(
        mergePersistedCollapsedProjects(const {}, currentState),
        same(currentState),
      );
      expect(
        mergePersistedCollapsedProjects(const {
          'collapsedProjectKeys': <Object?>[],
        }, currentState),
        same(currentState),
      );
    });

    // Edge: the first guard is JS truthiness, so `0`/`""`/`false` short-circuit
    // where an empty array does not. Both roads reach `current`, but only
    // because the second (set-equality) guard also holds.
    test('treats falsy persisted key lists as absent', () {
      final currentState = _emptyCollapsed();

      for (final falsy in <Object?>[0, '', false, null]) {
        expect(
          mergePersistedCollapsedProjects({
            'collapsedProjectKeys': falsy,
          }, currentState),
          same(currentState),
          reason: 'falsy value $falsy should be treated as absent',
        );
      }
    });

    // Edge: a truthy-but-unusable value passes the first guard and then decodes
    // to an empty set, which is how a corrupt blob resets rather than throws.
    test('decodes a truthy non-array key list to an empty set', () {
      const current = CollapsedProjectsState(
        collapsedProjectKeys: {'project-a'},
        collapsedStatusGroupKeys: {},
        collapsedPinned: false,
      );

      final restored = mergePersistedCollapsedProjects(const {
        'collapsedProjectKeys': 'project-a',
      }, current);

      expect(restored, isNot(same(current)));
      expect(restored.collapsedProjectKeys, isEmpty);
    });

    // Edge: `collapsedPinned` is only adopted when it is a real boolean.
    test('keeps the current pinned flag when the persisted value is not a '
        'boolean', () {
      const current = CollapsedProjectsState(
        collapsedProjectKeys: {},
        collapsedStatusGroupKeys: {},
        collapsedPinned: true,
      );

      final restored = mergePersistedCollapsedProjects(const {
        'collapsedPinned': 'yes',
        'collapsedProjectKeys': ['project-a'],
      }, current);

      expect(restored.collapsedPinned, isTrue);
      expect(restored.collapsedProjectKeys.toList(), ['project-a']);
    });

    // Edge: a persisted blob that differs produces a new object; one that
    // matches (even with reordered keys) returns the current instance.
    test('returns a new state only when the decoded blob differs', () {
      const current = CollapsedProjectsState(
        collapsedProjectKeys: {'a', 'b'},
        collapsedStatusGroupKeys: {'running'},
        collapsedPinned: true,
      );

      expect(
        mergePersistedCollapsedProjects(const {
          'collapsedProjectKeys': ['b', 'a'],
          'collapsedStatusGroupKeys': ['running'],
          'collapsedPinned': true,
        }, current),
        same(current),
      );
      expect(
        mergePersistedCollapsedProjects(const {
          'collapsedProjectKeys': ['a'],
          'collapsedStatusGroupKeys': ['running'],
          'collapsedPinned': true,
        }, current),
        isNot(same(current)),
      );
    });

    // Edge: toggling a key off and back on moves it to the end of the
    // iteration order in both `Set` implementations, which is what the
    // serialized array order reflects.
    test('re-adding a key moves it to the end of the iteration order', () {
      var state = const CollapsedProjectsState(
        collapsedProjectKeys: {'a', 'b', 'c'},
        collapsedStatusGroupKeys: {},
        collapsedPinned: false,
      );

      state = toggleProjectCollapsed(state, 'a');
      state = toggleProjectCollapsed(state, 'a');

      expect(state.collapsedProjectKeys.toList(), ['b', 'c', 'a']);
    });

    // Edge: `setProjectCollapsed(false)` on an absent key is a no-op in effect,
    // but upstream still allocates, so it is never reference-equal.
    test('setProjectCollapsed always allocates a fresh state', () {
      final current = _emptyCollapsed();

      final next = setProjectCollapsed(current, 'absent', false);

      expect(next, isNot(same(current)));
      expect(next.collapsedProjectKeys, isEmpty);
    });

    // Edge: the three axes are independent — toggling one never disturbs the
    // others.
    test('keeps the three collapse axes independent', () {
      var state = _emptyCollapsed();
      state = toggleProjectCollapsed(state, 'project-a');
      state = toggleStatusGroupCollapsed(state, 'running');
      state = togglePinnedCollapsed(state);

      expect(state.collapsedProjectKeys.toList(), ['project-a']);
      expect(state.collapsedStatusGroupKeys.toList(), ['running']);
      expect(state.collapsedPinned, isTrue);

      final afterStatus = toggleStatusGroupCollapsed(state, 'running');
      expect(afterStatus.collapsedStatusGroupKeys, isEmpty);
      expect(afterStatus.collapsedProjectKeys.toList(), ['project-a']);
      expect(afterStatus.collapsedPinned, isTrue);
    });
  });

  group('SidebarCollapsedSectionsStore', () {
    test('persists every action and rehydrates through merge', () async {
      final storage = _MemoryStorage();
      final store = SidebarCollapsedSectionsStore(storage: storage);

      await store.toggleProjectCollapsed('project-a');
      await store.setProjectCollapsed('project-b', true);
      await store.toggleStatusGroupCollapsed('running');
      await store.togglePinnedCollapsed();

      expect(store.state.collapsedProjectKeys.toList(), [
        'project-a',
        'project-b',
      ]);

      final restored = SidebarCollapsedSectionsStore(storage: storage);
      await restored.rehydrate();

      expect(restored.state.collapsedProjectKeys.toList(), [
        'project-a',
        'project-b',
      ]);
      expect(restored.state.collapsedStatusGroupKeys.toList(), ['running']);
      expect(restored.state.collapsedPinned, isTrue);
    });

    test('leaves defaults in place when nothing is stored', () async {
      final store = SidebarCollapsedSectionsStore(storage: _MemoryStorage());

      await store.rehydrate();

      expect(store.state.collapsedProjectKeys, isEmpty);
      expect(store.state.collapsedStatusGroupKeys, isEmpty);
      expect(store.state.collapsedPinned, isFalse);
    });
  });

  // =========================================================================
  // 3. sidebar-view-store.ts
  // =========================================================================

  group('sidebar view store', () {
    test('toggles multiple hosts into and out of the filter', () async {
      final store = SidebarViewStore(storage: _MemoryStorage());

      await store.toggleHostFilter('host-a');
      await store.toggleHostFilter('host-b');
      expect(store.hostFilters, ['host-a', 'host-b']);

      await store.toggleHostFilter('host-a');
      expect(store.hostFilters, ['host-b']);

      await store.clearHostFilters();
      expect(store.hostFilters, isEmpty);
    });

    test('keeps host filters that still point at available hosts', () async {
      final store = SidebarViewStore(storage: _MemoryStorage());
      await store.toggleHostFilter('host-a');
      await store.toggleHostFilter('host-b');

      await store.reconcileHostFilters(['host-a', 'host-b', 'host-c']);

      expect(store.hostFilters, ['host-a', 'host-b']);
    });

    test('drops a host filter after that host is removed', () async {
      final store = SidebarViewStore(storage: _MemoryStorage());
      await store.toggleHostFilter('host-a');
      await store.toggleHostFilter('removed-host');

      await store.reconcileHostFilters(['host-a']);

      expect(store.hostFilters, ['host-a']);
    });

    test('migrates legacy per-host group modes to the new global mode', () {
      expect(
        migrateSidebarViewState({
          'groupModeByServerId': {'host-a': 'project', 'host-b': 'status'},
        }).toJson(),
        {'groupMode': 'status', 'hostFilters': <String>[]},
      );
    });

    test('migrates a pre-v2 single host filter to the multi-host list', () {
      expect(
        migrateSidebarViewState({
          'groupMode': 'status',
          'hostFilter': 'host-a',
        }).toJson(),
        {
          'groupMode': 'status',
          'hostFilters': ['host-a'],
        },
      );
    });

    test(
      'keeps current persisted sidebar view state during version migration',
      () {
        expect(
          migrateSidebarViewState({
            'groupMode': 'status',
            'hostFilters': ['host-a', 'host-b'],
          }).toJson(),
          {
            'groupMode': 'status',
            'hostFilters': ['host-a', 'host-b'],
          },
        );
      },
    );

    test(
      'falls back to the legacy storage key when the new key is empty',
      () async {
        final legacyBlob = jsonEncode({
          'state': {
            'groupModeByServerId': {'host-a': 'status'},
          },
          'version': 0,
        });
        final storage = _MemoryStorage({
          sidebarViewStorageName: null,
          legacySidebarGroupModeStorageName: legacyBlob,
        });

        final value = await createSidebarViewStorage(
          storage,
        ).getItem(sidebarViewStorageName);

        expect(value, legacyBlob);
        expect(storage.reads, [
          sidebarViewStorageName,
          legacySidebarGroupModeStorageName,
        ]);
      },
    );

    test('uses the new storage key without reading the legacy key when '
        'current state exists', () async {
      final currentBlob = jsonEncode({
        'state': {
          'groupMode': 'project',
          'hostFilters': ['host-a'],
        },
        'version': 2,
      });
      final storage = _MemoryStorage({
        sidebarViewStorageName: currentBlob,
        legacySidebarGroupModeStorageName: jsonEncode({
          'state': {
            'groupModeByServerId': {'host-b': 'status'},
          },
          'version': 0,
        }),
      });

      final value = await createSidebarViewStorage(
        storage,
      ).getItem(sidebarViewStorageName);

      expect(value, currentBlob);
      expect(storage.reads, [sidebarViewStorageName]);
    });

    // Edge: the fallback is scoped to the sidebar key; any other miss stays a
    // miss.
    test('does not apply the legacy fallback to unrelated keys', () async {
      final storage = _MemoryStorage({
        legacySidebarGroupModeStorageName: 'legacy',
      });

      final value = await createSidebarViewStorage(storage).getItem('other');

      expect(value, isNull);
      expect(storage.reads, ['other']);
    });

    // Edge: writes and removals always target the requested key, never the
    // legacy one.
    test('writes and removals bypass the legacy key', () async {
      final storage = _MemoryStorage({
        legacySidebarGroupModeStorageName: 'legacy',
      });
      final wrapped = createSidebarViewStorage(storage);

      await wrapped.setItem(sidebarViewStorageName, 'fresh');
      expect(storage.values[sidebarViewStorageName], 'fresh');
      expect(storage.values[legacySidebarGroupModeStorageName], 'legacy');

      await wrapped.removeItem(sidebarViewStorageName);
      expect(storage.values[sidebarViewStorageName], isNull);
      expect(storage.values[legacySidebarGroupModeStorageName], 'legacy');
    });

    // Edge: anything that is not a JSON object migrates to the defaults.
    test('migrates a non-object blob to the defaults', () {
      for (final blob in <Object?>[null, 'text', 7, <Object?>[]]) {
        expect(
          migrateSidebarViewState(blob).toJson(),
          {'groupMode': 'project', 'hostFilters': <String>[]},
          reason: 'blob $blob should migrate to defaults',
        );
      }
    });

    // Edge: an unknown group mode falls back to `project`, and non-string
    // entries are stripped from the filter list.
    test('sanitizes an unknown group mode and non-string host filters', () {
      expect(
        migrateSidebarViewState({
          'groupMode': 'timeline',
          'hostFilters': ['host-a', 3, null, 'host-b'],
        }).toJson(),
        {
          'groupMode': 'project',
          'hostFilters': ['host-a', 'host-b'],
        },
      );
    });

    // Edge: the legacy collapse is biased to `status` only when some host had
    // it; an all-project map collapses to `project`.
    test('collapses an all-project legacy map to project', () {
      expect(
        migrateSidebarViewState({
          'groupModeByServerId': {'host-a': 'project', 'host-b': 'project'},
        }).toJson(),
        {'groupMode': 'project', 'hostFilters': <String>[]},
      );
    });

    // Edge: a legacy map with no recognisable mode is not a legacy blob at all,
    // so the current-shape fields are read instead.
    test(
      'falls through to the current shape when the legacy map is unusable',
      () {
        expect(
          migrateSidebarViewState({
            'groupModeByServerId': {'host-a': 'nonsense'},
            'groupMode': 'status',
            'hostFilters': ['host-a'],
          }).toJson(),
          {
            'groupMode': 'status',
            'hostFilters': ['host-a'],
          },
        );
        expect(
          migrateSidebarViewState({
            'groupModeByServerId': 'not-a-map',
            'groupMode': 'status',
          }).toJson(),
          {'groupMode': 'status', 'hostFilters': <String>[]},
        );
      },
    );

    // Edge: a legacy blob predates host filtering, so any host filter alongside
    // it is deliberately discarded.
    test('discards host filters that accompany a legacy group mode', () {
      expect(
        migrateSidebarViewState({
          'groupModeByServerId': {'host-a': 'status'},
          'hostFilters': ['host-a'],
        }).toJson(),
        {'groupMode': 'status', 'hostFilters': <String>[]},
      );
    });

    // Edge: reconciling an empty (= "all hosts") filter list is a no-op and
    // never writes.
    test('reconciling an empty filter list does not write', () async {
      final storage = _MemoryStorage();
      final store = SidebarViewStore(storage: storage);

      await store.reconcileHostFilters(['host-a']);

      expect(store.hostFilters, isEmpty);
      expect(storage.values, isEmpty);
    });

    // Edge: reconciling with nothing to drop also skips the write.
    test('reconciling with nothing to drop does not rewrite storage', () async {
      final storage = _MemoryStorage();
      final store = SidebarViewStore(storage: storage);
      await store.toggleHostFilter('host-a');
      final afterToggle = storage.values[sidebarViewStorageName];

      await store.reconcileHostFilters(['host-a', 'host-b']);

      expect(storage.values[sidebarViewStorageName], afterToggle);
    });

    test(
      'rehydrates through the legacy key and re-persists under the new one',
      () async {
        final storage = _MemoryStorage({
          legacySidebarGroupModeStorageName: jsonEncode({
            'state': {
              'groupModeByServerId': {'host-a': 'status'},
            },
            'version': 0,
          }),
        });
        final store = SidebarViewStore(storage: storage);

        await store.rehydrate();
        expect(store.groupMode, SidebarGroupMode.status);
        expect(store.hostFilters, isEmpty);

        await store.setGroupMode(SidebarGroupMode.project);
        expect(jsonDecode(storage.values[sidebarViewStorageName]!), {
          'state': {'groupMode': 'project', 'hostFilters': <String>[]},
          'version': sidebarViewStoreVersion,
        });
      },
    );

    test('round-trips a v2 blob', () async {
      final storage = _MemoryStorage();
      final store = SidebarViewStore(storage: storage);
      await store.setGroupMode(SidebarGroupMode.status);
      await store.toggleHostFilter('host-a');

      final restored = SidebarViewStore(storage: storage);
      await restored.rehydrate();

      expect(restored.groupMode, SidebarGroupMode.status);
      expect(restored.hostFilters, ['host-a']);
    });
  });

  // =========================================================================
  // 4. navigation-active-workspace-store/navigation.ts
  // =========================================================================

  group('workspace navigation', () {
    test('reports when no last workspace is known', () {
      final harness = _NavigationHarness();

      expect(navigateToLastWorkspace(harness.lastDeps), isFalse);
      expect(harness.navigations, isEmpty);
    });

    test('navigates to a workspace route and remembers the selection', () {
      final harness = _NavigationHarness();

      navigateToWorkspace(
        const NavigateToWorkspaceInput(
          serverId: 'server-1',
          workspaceId: 'workspace-a',
        ),
        harness.deps,
      );

      expect(harness.navigations, ['/h/server-1/workspace/workspace-a']);
      expect(harness.remembered, [_isRoute('server-1', 'workspace-a')]);
    });

    test("focuses the attention agent's tab when a workspace has one", () {
      final harness = _NavigationHarness(
        getSessionWorkspaces: (_) => {'workspace-a': _workspace('workspace-a')},
        getSessionAgents: (_) => [
          _agent(
            agentId: 'agent-1',
            workspaceId: 'workspace-a',
            requiresAttention: true,
            attentionReason: AgentAttentionReason.permission,
          ),
        ],
      );

      navigateToWorkspace(
        const NavigateToWorkspaceInput(
          serverId: 'server-1',
          workspaceId: 'workspace-a',
        ),
        harness.deps,
      );

      expect(harness.openedTabs, hasLength(1));
      expect(harness.openedTabs.single.workspaceKey, 'server-1:workspace-a');
      expect(
        (harness.openedTabs.single.target as WorkspaceAgentTabTarget).agentId,
        'agent-1',
      );
    });

    test('keeps an explicit tab authoritative over an attention agent', () {
      final harness = _NavigationHarness(
        getSessionWorkspaces: (_) => {'workspace-a': _workspace('workspace-a')},
        getSessionAgents: (_) => [
          _agent(
            agentId: 'agent-1',
            workspaceId: 'workspace-a',
            requiresAttention: true,
            attentionReason: AgentAttentionReason.permission,
          ),
        ],
      );

      navigateToWorkspace(
        const NavigateToWorkspaceInput(
          serverId: 'server-1',
          workspaceId: 'workspace-a',
          target: WorkspaceDraftTabTarget(draftId: 'draft-1'),
        ),
        harness.deps,
      );

      expect(harness.openedTabs, hasLength(1));
      expect(harness.openedTabs.single.workspaceKey, 'server-1:workspace-a');
      expect(
        (harness.openedTabs.single.target as WorkspaceDraftTabTarget).draftId,
        'draft-1',
      );
    });

    test('defers an agent tab until a missing workspace is recovered', () {
      final harness = _NavigationHarness(
        getSessionWorkspaces: (_) => <String, WorkspaceDescriptor>{},
      );

      navigateToWorkspace(
        const NavigateToWorkspaceInput(
          serverId: 'server-1',
          workspaceId: 'workspace-a',
          target: WorkspaceAgentTabTarget(agentId: 'agent-1'),
        ),
        harness.deps,
      );

      expect(harness.openedTabs, isEmpty);
      expect(harness.navigations, [
        '/h/server-1/workspace/workspace-a?open=agent%3Aagent-1',
      ]);
    });

    test('reads the active workspace from the current route', () {
      final selection = parseActiveWorkspaceSelection(
        const RouteSelectionInput(
          pathname: '/h/server-1/workspace/workspace-a',
        ),
      );

      expect(selection, _isRoute('server-1', 'workspace-a'));
    });

    test('falls back to workspace route params during cold route mount', () {
      final selection = parseActiveWorkspaceSelection(
        const RouteSelectionInput(
          pathname: '/',
          params: WorkspaceRouteParams(
            serverId: 'server-1',
            workspaceId: 'b64_L3RtcC9wYXNlby1taXNzaW5nLXdvcmtzcGFjZQ',
          ),
        ),
      );

      expect(selection, _isRoute('server-1', '/tmp/paseo-missing-workspace'));
    });

    test('ignores stale workspace route params while an app-wide route is '
        'active', () {
      final selection = parseActiveWorkspaceSelection(
        const RouteSelectionInput(
          pathname: '/settings/general',
          params: WorkspaceRouteParams(
            serverId: 'server-1',
            workspaceId: 'workspace-a',
          ),
        ),
      );

      expect(selection, isNull);
    });

    test('navigates to the last workspace once a route observation has been '
        'remembered', () {
      final harness = _NavigationHarness();

      final observed = parseActiveWorkspaceSelection(
        const RouteSelectionInput(
          pathname: '/h/server-1/workspace/workspace-a',
        ),
      );
      expect(observed, isNotNull);
      harness.deps.rememberLastWorkspace(observed!);

      expect(navigateToLastWorkspace(harness.lastDeps), isTrue);
      expect(harness.navigations, ['/h/server-1/workspace/workspace-a']);
    });

    // Edge: expo-router hands repeated params through as arrays, so the first
    // string entry is used and everything else yields "no selection".
    test('reads array-shaped and blank route params', () {
      expect(
        parseActiveWorkspaceSelection(
          const RouteSelectionInput(
            pathname: '',
            params: WorkspaceRouteParams(
              serverId: ['  server-1 ', 'server-2'],
              workspaceId: ['workspace-a'],
            ),
          ),
        ),
        _isRoute('server-1', 'workspace-a'),
      );

      for (final params in const [
        WorkspaceRouteParams(),
        WorkspaceRouteParams(serverId: 'server-1'),
        WorkspaceRouteParams(workspaceId: 'workspace-a'),
        WorkspaceRouteParams(serverId: '   ', workspaceId: 'workspace-a'),
        WorkspaceRouteParams(serverId: 'server-1', workspaceId: '   '),
        WorkspaceRouteParams(serverId: 7, workspaceId: 'workspace-a'),
        WorkspaceRouteParams(serverId: <Object?>[], workspaceId: 'workspace-a'),
      ]) {
        expect(
          parseActiveWorkspaceSelection(
            RouteSelectionInput(pathname: '/', params: params),
          ),
          isNull,
        );
      }
    });

    // Edge: the pathname always wins, even when params disagree.
    test('prefers the pathname over the params', () {
      expect(
        parseActiveWorkspaceSelection(
          const RouteSelectionInput(
            pathname: '/h/server-1/workspace/workspace-a',
            params: WorkspaceRouteParams(
              serverId: 'other-server',
              workspaceId: 'other-workspace',
            ),
          ),
        ),
        _isRoute('server-1', 'workspace-a'),
      );
    });

    // Edge: the map may be keyed by something other than the descriptor's own
    // id, so identity resolution has to fall back to a scan.
    test('resolves a workspace filed under a different map key', () {
      expect(
        resolveWorkspaceMapKeyByIdentity(
          workspaces: {'/repo/workspace-a': _workspace('workspace-a')},
          workspaceId: '  workspace-a  ',
        ),
        '/repo/workspace-a',
      );
      expect(
        resolveWorkspaceMapKeyByIdentity(
          workspaces: {'workspace-a': _workspace('workspace-a')},
          workspaceId: 'workspace-a',
        ),
        'workspace-a',
      );
      expect(
        resolveWorkspaceMapKeyByIdentity(
          workspaces: {'workspace-a': _workspace('workspace-a')},
          workspaceId: '   ',
        ),
        isNull,
      );
      expect(
        resolveWorkspaceMapKeyByIdentity(
          workspaces: null,
          workspaceId: 'workspace-a',
        ),
        isNull,
      );
    });

    // Edge: with the workspace known, an agent target *is* opened, and `pin`
    // reaches the layout store.
    test('opens and pins an agent tab for a known workspace', () {
      final harness = _NavigationHarness(
        getSessionWorkspaces: (_) => {'workspace-a': _workspace('workspace-a')},
      );

      final route = navigateToWorkspace(
        const NavigateToWorkspaceInput(
          serverId: 'server-1',
          workspaceId: 'workspace-a',
          target: WorkspaceAgentTabTarget(agentId: 'agent-1'),
          pin: true,
        ),
        harness.deps,
      );

      expect(route, '/h/server-1/workspace/workspace-a');
      expect(harness.openedTabs, hasLength(1));
      expect(harness.pinnedAgents, ['server-1:workspace-a/agent-1']);
    });

    // Edge: a non-agent target is opened even when the workspace is unknown —
    // only agent tabs are deferred.
    test('opens a non-agent tab even when the workspace is unknown', () {
      final harness = _NavigationHarness(
        getSessionWorkspaces: (_) => <String, WorkspaceDescriptor>{},
      );

      navigateToWorkspace(
        const NavigateToWorkspaceInput(
          serverId: 'server-1',
          workspaceId: 'workspace-a',
          target: WorkspaceTerminalTabTarget(terminalId: 'term-1'),
        ),
        harness.deps,
      );

      expect(harness.openedTabs, hasLength(1));
      expect(harness.navigations, ['/h/server-1/workspace/workspace-a']);
    });

    // Edge: `prepareWorkspaceTab` swaps the placeholder draft id for a fresh
    // one so two "new draft" navigations never collide.
    test('replaces the placeholder draft id with a generated one', () {
      final harness = _NavigationHarness(
        getSessionWorkspaces: (_) => {'workspace-a': _workspace('workspace-a')},
      );

      navigateToWorkspace(
        const NavigateToWorkspaceInput(
          serverId: 'server-1',
          workspaceId: 'workspace-a',
          target: WorkspaceDraftTabTarget(draftId: 'new'),
        ),
        harness.deps,
      );

      final draftId =
          (harness.openedTabs.single.target as WorkspaceDraftTabTarget).draftId;
      expect(draftId, isNot('new'));
      expect(draftId, isNotEmpty);
    });

    // Edge: with no target and an unknown workspace, no tab is opened at all —
    // the attention scan is skipped rather than run against every agent.
    test('skips the attention scan when the workspace is unknown', () {
      final harness = _NavigationHarness(
        getSessionWorkspaces: (_) => <String, WorkspaceDescriptor>{},
        getSessionAgents: (_) => [
          _agent(
            agentId: 'agent-1',
            workspaceId: 'workspace-a',
            requiresAttention: true,
            attentionReason: AgentAttentionReason.finished,
          ),
        ],
      );

      navigateToWorkspace(
        const NavigateToWorkspaceInput(
          serverId: 'server-1',
          workspaceId: 'workspace-a',
        ),
        harness.deps,
      );

      expect(harness.openedTabs, isEmpty);
      expect(harness.navigations, ['/h/server-1/workspace/workspace-a']);
    });

    // Edge: agents belonging to other workspaces are filtered out before the
    // attention pick, and an agent with no attention leaves the tab closed.
    test('only considers agents of the resolved workspace', () {
      final harness = _NavigationHarness(
        getSessionWorkspaces: (_) => {'workspace-a': _workspace('workspace-a')},
        getSessionAgents: (_) => [
          _agent(
            agentId: 'other',
            workspaceId: 'workspace-b',
            requiresAttention: true,
            attentionReason: AgentAttentionReason.permission,
          ),
          _agent(agentId: 'calm', workspaceId: 'workspace-a'),
        ],
      );

      navigateToWorkspace(
        const NavigateToWorkspaceInput(
          serverId: 'server-1',
          workspaceId: 'workspace-a',
        ),
        harness.deps,
      );

      expect(harness.openedTabs, isEmpty);
    });

    // Edge: the remembered selection carries the *raw* workspace id the caller
    // asked for, not the resolved map key.
    test('remembers the requested workspace id, not the resolved key', () {
      final harness = _NavigationHarness(
        getSessionWorkspaces: (_) => {
          '/repo/workspace-a': _workspace('workspace-a'),
        },
      );

      navigateToWorkspace(
        const NavigateToWorkspaceInput(
          serverId: 'server-1',
          workspaceId: 'workspace-a',
        ),
        harness.deps,
      );

      expect(harness.remembered, [_isRoute('server-1', 'workspace-a')]);
    });

    // Edge: navigating to the last workspace replays it through the full
    // navigate path, so it re-remembers and re-navigates.
    test('replays the remembered selection through navigateToWorkspace', () {
      final harness = _NavigationHarness();
      harness.lastSelection = const HostWorkspaceRoute(
        serverId: 'server-1',
        workspaceId: '/tmp/scratch space',
      );

      expect(navigateToLastWorkspace(harness.lastDeps), isTrue);
      expect(harness.navigations, hasLength(1));
      expect(harness.navigations.single, startsWith('/h/server-1/workspace/'));
      expect(harness.remembered.single.workspaceId, '/tmp/scratch space');
    });
  });

  // =========================================================================
  // 5. draft-store/migration.ts
  // =========================================================================

  group('draft-store migration', () {
    test('promotes the newest legacy New Workspace draft into the singleton '
        'surface', () async {
      final forkDraft = _activeDraftJson('fork context', 1700000000003);
      final agentDraft = _activeDraftJson('agent prompt', 1700000000004);

      final migrated = await migratePersistedState({
        'drafts': {
          'new-workspace:server-a:/project/older': _activeDraftJson(
            'older new workspace prompt',
            1700000000001,
          ),
          'new-workspace:server-b:/project/newer': _activeDraftJson(
            'newer new workspace prompt',
            1700000000002,
          ),
          'new-workspace:draft:fork-1': forkDraft,
          'agent:server-a:agent-1': agentDraft,
        },
        'createModalDraft': null,
      }, _ports(1700000000005));

      expect(
        {
          for (final entry in migrated.drafts.entries)
            entry.key: entry.value.toJson(),
        },
        {
          'new-workspace': _activeDraftJson(
            'newer new workspace prompt',
            1700000000002,
          ),
          'new-workspace:draft:fork-1': forkDraft,
          'agent:server-a:agent-1': agentDraft,
        },
      );
    });

    test('drops unowned checkout PR context when promoting a scoped New '
        'Workspace draft', () async {
      final issue = _githubIssueAttachment(101);
      final migrated = await migratePersistedState({
        'drafts': {
          'new-workspace:server-a:/project/a': _activeDraftJson(
            'keep the prompt',
            2,
            [issue, _githubPrAttachment(202)],
          ),
        },
        'createModalDraft': null,
      }, _ports(3));

      expect(migrated.drafts['new-workspace']?.input.toJson(), {
        'text': 'keep the prompt',
        'attachments': [issue],
      });
    });

    test('normalizes legacy image metadata into image attachments and strips '
        'persisted preview URLs', () async {
      final migrated = await migratePersistedState({
        'drafts': {
          'agent:server:agent': {
            'input': {
              'text': 'hello',
              'images': [
                {
                  'id': 'att-1',
                  'mimeType': 'image/png',
                  'storageType': 'desktop-file',
                  'storageKey': '/tmp/att-1.png',
                  'createdAt': 1700000000000,
                  'previewUri': 'asset://should-not-persist',
                },
              ],
            },
            'lifecycle': 'active',
            'updatedAt': 1700000000001,
            'version': 1,
          },
        },
        'createModalDraft': null,
      }, _ports(1700000000002));

      expect(migrated.drafts['agent:server:agent']?.input.toJson(), {
        'text': 'hello',
        'attachments': [
          {
            'kind': 'image',
            'metadata': {
              'id': 'att-1',
              'mimeType': 'image/png',
              'storageType': 'desktop-file',
              'storageKey': '/tmp/att-1.png',
              'createdAt': 1700000000000,
            },
          },
        ],
      });
    });

    test('hydrates old persisted drafts that still include cwd', () async {
      final original = {
        'drafts': {
          'agent:server:agent': {
            'input': {
              'text': 'hello',
              'attachments': [
                {
                  'kind': 'image',
                  'metadata': {
                    'id': 'att-1',
                    'mimeType': 'image/jpeg',
                    'storageType': 'web-indexeddb',
                    'storageKey': 'att-1',
                    'createdAt': 1700000000000,
                  },
                },
              ],
              'cwd': '/repo',
            },
            'lifecycle': 'active',
            'updatedAt': 1700000000001,
            'version': 2,
          },
        },
        'createModalDraft': null,
      };

      final ports = _ports(1700000000002);
      final once = await migratePersistedState(original, ports);
      final twice = await migratePersistedState(once.toJson(), ports);

      expect(twice.toJson(), once.toJson());
      expect(twice.drafts['agent:server:agent']?.input.toJson(), {
        'text': 'hello',
        'attachments': [
          {
            'kind': 'image',
            'metadata': {
              'id': 'att-1',
              'mimeType': 'image/jpeg',
              'storageType': 'web-indexeddb',
              'storageKey': 'att-1',
              'createdAt': 1700000000000,
            },
          },
        ],
      });
    });

    test('rejects workspace review attachments from migrated draft '
        'attachments', () async {
      final migrated = await migratePersistedState({
        'drafts': {
          'agent:server:agent': {
            'input': {
              'text': 'hello',
              'attachments': [_workspaceReviewAttachment()],
            },
            'lifecycle': 'active',
            'updatedAt': 1700000000001,
            'version': 2,
          },
        },
        'createModalDraft': null,
      }, _ports(1700000000002));

      expect(migrated.drafts['agent:server:agent']?.input.attachments, isEmpty);
    });

    // Edge: ties in `updatedAt` are broken by insertion order, which V8's
    // stable sort guarantees and Dart's `List.sort` does not — the port adds an
    // explicit index tiebreak for exactly this.
    test('breaks updatedAt ties by original insertion order', () async {
      final migrated = await migratePersistedState({
        'drafts': {
          'new-workspace:server-a:/first': _activeDraftJson('first', 100),
          'new-workspace:server-b:/second': _activeDraftJson('second', 100),
          'new-workspace:server-c:/third': _activeDraftJson('third', 100),
        },
      }, _ports(1));

      expect(migrated.drafts['new-workspace']?.input.text, 'first');
      expect(migrated.drafts.keys.toList(), ['new-workspace']);
    });

    // Edge: an existing singleton draft was written by a build that already had
    // the singleton, so it always wins.
    test('never overwrites an existing singleton draft', () async {
      final migrated = await migratePersistedState({
        'drafts': {
          'new-workspace': _activeDraftJson('already global', 1),
          'new-workspace:server-a:/project': _activeDraftJson('scoped', 999),
        },
      }, _ports(1));

      expect(migrated.drafts['new-workspace']?.input.text, 'already global');
      expect(migrated.drafts.keys.toList(), ['new-workspace']);
    });

    // Edge: only *active* scoped drafts can be promoted; a finalized one is
    // dropped with the rest of its keys.
    test('promotes nothing when every legacy draft is finalized', () async {
      final migrated = await migratePersistedState({
        'drafts': {
          'new-workspace:server-a:/a': {
            'input': {'text': 'sent', 'attachments': <Object?>[]},
            'lifecycle': 'sent',
            'updatedAt': 5,
            'version': 1,
          },
          'new-workspace:server-b:/b': {
            'input': {'text': 'abandoned', 'attachments': <Object?>[]},
            'lifecycle': 'abandoned',
            'updatedAt': 6,
            'version': 1,
          },
        },
      }, _ports(1));

      expect(migrated.drafts, isEmpty);
    });

    // Edge: fork keys share the `new-workspace:` prefix but are not legacy.
    test('leaves fork draft keys untouched', () async {
      final migrated = await migratePersistedState({
        'drafts': {'new-workspace:draft:fork-1': _activeDraftJson('fork', 1)},
      }, _ports(2));

      expect(migrated.drafts.keys.toList(), ['new-workspace:draft:fork-1']);
      expect(
        isLegacyNewWorkspaceDraftKey('new-workspace:draft:fork-1'),
        isFalse,
      );
      expect(isLegacyNewWorkspaceDraftKey('new-workspace:a:/b'), isTrue);
      expect(isLegacyNewWorkspaceDraftKey('new-workspace'), isFalse);
      expect(isLegacyNewWorkspaceDraftKey('agent:server:agent'), isFalse);
    });

    // Edge: the modal draft goes through exactly the same record migration.
    test('migrates the create-modal draft', () async {
      final migrated = await migratePersistedState({
        'drafts': <String, Object?>{},
        'createModalDraft': {
          'input': {'text': 'modal', 'attachments': <Object?>[]},
          'lifecycle': 'nonsense',
          'version': 4,
        },
      }, _ports(777));

      expect(migrated.createModalDraft?.input.text, 'modal');
      // An unrecognised lifecycle falls back to `active`, and a missing
      // `updatedAt` is stamped from the injected clock.
      expect(
        migrated.createModalDraft?.lifecycle,
        ComposerDraftLifecycle.active,
      );
      expect(migrated.createModalDraft?.updatedAt, 777);
      expect(migrated.createModalDraft?.version, 4);

      final none = await migratePersistedState({
        'drafts': <String, Object?>{},
        'createModalDraft': 'not-an-object',
      }, _ports(1));
      expect(none.createModalDraft, isNull);
    });

    // Edge: a wholly absent blob, a non-object blob, and non-object draft
    // entries all migrate to something usable rather than throwing.
    test('tolerates missing and malformed input', () async {
      for (final blob in <Object?>[null, 'text', 7, <Object?>[]]) {
        final migrated = await migratePersistedState(blob, _ports(1));
        expect(migrated.drafts, isEmpty);
        expect(migrated.createModalDraft, isNull);
      }

      final migrated = await migratePersistedState({
        'drafts': {'agent:a:b': 'not-an-object', 'agent:a:c': null},
      }, _ports(1));
      expect(migrated.drafts, isEmpty);
    });

    // Edge: the pre-`input` flat record shape is still readable.
    test('reads the flat legacy record shape', () async {
      final migrated = await migratePersistedState({
        'drafts': {
          'agent:server:agent': {
            'text': 'flat',
            'attachments': <Object?>[],
            'lifecycle': 'sent',
            'updatedAt': 9,
            'version': 3,
          },
        },
      }, _ports(1));

      final record = migrated.drafts['agent:server:agent'];
      expect(record?.input.text, 'flat');
      expect(record?.lifecycle, ComposerDraftLifecycle.sent);
      expect(record?.updatedAt, 9);
      expect(record?.version, 3);
    });

    // Edge: defaults for a record that carries nothing but a lifecycle.
    test('defaults text, updatedAt and version', () async {
      final migrated = await migratePersistedState({
        'drafts': {
          'agent:server:agent': {'lifecycle': 'abandoned'},
        },
      }, _ports(4242));

      final record = migrated.drafts['agent:server:agent'];
      expect(record?.input.text, '');
      expect(record?.input.attachments, isEmpty);
      expect(record?.lifecycle, ComposerDraftLifecycle.abandoned);
      expect(record?.updatedAt, 4242);
      expect(record?.version, 1);
    });

    // Edge: legacy `{ uri }` images reach the port, and the falsy-mimeType arm
    // drops an empty string rather than persisting it.
    test('hands legacy uri images to the migration port', () async {
      final seen = <PersistedDraftImage>[];
      final ports = DraftMigrationPorts(
        migrateLegacyImages: (images) async {
          seen.addAll(images);
          return const [];
        },
        nowMs: 1,
      );

      await migratePersistedState({
        'drafts': {
          'agent:server:agent': {
            'input': {
              'text': '',
              'images': [
                {'uri': 'file:///a.png', 'mimeType': 'image/png'},
                {'uri': 'file:///b.png', 'mimeType': ''},
                {'uri': 'file:///c.png'},
                {'noUri': true},
                'not-an-object',
              ],
            },
          },
        },
      }, ports);

      expect(seen, hasLength(3));
      expect(seen.whereType<LegacyDraftImage>().map((i) => i.uri).toList(), [
        'file:///a.png',
        'file:///b.png',
        'file:///c.png',
      ]);
      expect(
        seen.whereType<LegacyDraftImage>().map((i) => i.mimeType).toList(),
        ['image/png', null, null],
      );
    });

    // Edge: migrated legacy images are appended after the canonical
    // attachments, which is what makes repeated migration stable.
    test('appends migrated legacy images after existing attachments', () async {
      final issue = _githubIssueAttachment(1);
      final migrated = await migratePersistedState({
        'drafts': {
          'agent:server:agent': {
            'input': {
              'text': 'both',
              'attachments': [issue],
              'images': [
                {
                  'id': 'att-1',
                  'mimeType': 'image/png',
                  'storageType': 'native-file',
                  'storageKey': '/tmp/a.png',
                  'createdAt': 1,
                },
              ],
            },
          },
        },
      }, _ports(1));

      final attachments =
          migrated.drafts['agent:server:agent']!.input.attachments;
      expect(attachments, hasLength(2));
      expect(attachments.first, isA<ForgeComposerAttachment>());
      expect(attachments.last, isA<ImageComposerAttachment>());
    });

    // Edge: the `file` attachment arm validates the full uploaded-file shape.
    test('validates uploaded file attachments', () async {
      Future<List<UserComposerAttachment>> attachmentsFor(
        List<Object?> attachments,
      ) async {
        final migrated = await migratePersistedState({
          'drafts': {
            'agent:a:b': {
              'input': {'text': '', 'attachments': attachments},
            },
          },
        }, _ports(1));
        return migrated.drafts['agent:a:b']!.input.attachments;
      }

      const good = {
        'kind': 'file',
        'attachment': {
          'type': 'uploaded_file',
          'id': 'f1',
          'fileName': 'a.txt',
          'mimeType': 'text/plain',
          'size': 0,
          'path': '/tmp/a.txt',
        },
      };
      expect(await attachmentsFor([good]), hasLength(1));
      expect((await attachmentsFor([good])).single.toJson(), good);

      for (final bad in <Object?>[
        {'kind': 'file'},
        {
          'kind': 'file',
          'attachment': {
            'type': 'other',
            'id': 'f1',
            'fileName': 'a',
            'mimeType': 'm',
            'size': 1,
            'path': '/p',
          },
        },
        {
          'kind': 'file',
          'attachment': {
            'type': 'uploaded_file',
            'id': 'f1',
            'fileName': 'a',
            'mimeType': 'm',
            'size': -1,
            'path': '/p',
          },
        },
        {
          'kind': 'file',
          'attachment': {
            'type': 'uploaded_file',
            'id': 'f1',
            'fileName': 'a',
            'mimeType': 'm',
            'size': 'big',
            'path': '/p',
          },
        },
      ]) {
        expect(await attachmentsFor([bad]), isEmpty, reason: '$bad');
      }
    });

    // Edge: workspace-file attachments normalise a leading `./` and validate
    // the selection, including the line-range bounds.
    test('validates and normalizes workspace file attachments', () async {
      Future<List<Map<String, Object?>>> jsonFor(
        List<Object?> attachments,
      ) async {
        final migrated = await migratePersistedState({
          'drafts': {
            'agent:a:b': {
              'input': {'text': '', 'attachments': attachments},
            },
          },
        }, _ports(1));
        return [
          for (final attachment
              in migrated.drafts['agent:a:b']!.input.attachments)
            attachment.toJson(),
        ];
      }

      expect(
        await jsonFor([
          {
            'kind': 'workspace_file',
            'path': '  ./src/example.ts ',
            'selection': {'kind': 'whole_file'},
          },
          {
            'kind': 'workspace_file',
            'path': 'src/other.ts',
            'selection': {'kind': 'line_range', 'startLine': 3, 'endLine': 9},
          },
        ]),
        [
          {
            'kind': 'workspace_file',
            'path': 'src/example.ts',
            'selection': {'kind': 'whole_file'},
          },
          {
            'kind': 'workspace_file',
            'path': 'src/other.ts',
            'selection': {'kind': 'line_range', 'startLine': 3, 'endLine': 9},
          },
        ],
      );

      // A Windows-shaped path keeps its separators: upstream only strips a
      // leading `./`.
      expect(
        (await jsonFor([
          {
            'kind': 'workspace_file',
            'path': r'src\example.ts',
            'selection': {'kind': 'whole_file'},
          },
        ])).single['path'],
        r'src\example.ts',
      );

      for (final bad in <Object?>[
        {
          'kind': 'workspace_file',
          'selection': {'kind': 'whole_file'},
        },
        {
          'kind': 'workspace_file',
          'path': '   ',
          'selection': {'kind': 'whole_file'},
        },
        {'kind': 'workspace_file', 'path': 'a.ts'},
        {'kind': 'workspace_file', 'path': 'a.ts', 'selection': 'whole_file'},
        {
          'kind': 'workspace_file',
          'path': 'a.ts',
          'selection': {'kind': 'line_range', 'startLine': 0, 'endLine': 3},
        },
        {
          'kind': 'workspace_file',
          'path': 'a.ts',
          'selection': {'kind': 'line_range', 'startLine': 5, 'endLine': 4},
        },
        {
          'kind': 'workspace_file',
          'path': 'a.ts',
          'selection': {'kind': 'line_range', 'startLine': 1.5, 'endLine': 4},
        },
        {
          'kind': 'workspace_file',
          'path': 'a.ts',
          'selection': {'kind': 'other'},
        },
      ]) {
        expect(await jsonFor([bad]), isEmpty, reason: '$bad');
      }
    });

    // Edge: image attachments require the full metadata shape; a metadata blob
    // with an unknown storage type is rejected (see the documented deviation).
    test('validates image attachment metadata', () {
      expect(
        parseAttachmentMetadata({
          'id': 'a',
          'mimeType': 'image/png',
          'storageType': 'desktop-file',
          'storageKey': '/tmp/a',
          'createdAt': 1,
          'fileName': 'a.png',
          'byteSize': 12,
        })?.fileName,
        'a.png',
      );
      expect(parseAttachmentMetadata(null), isNull);
      expect(parseAttachmentMetadata('a'), isNull);
      expect(
        parseAttachmentMetadata({
          'id': 'a',
          'mimeType': 'image/png',
          'storageType': 'ftp',
          'storageKey': '/tmp/a',
          'createdAt': 1,
        }),
        isNull,
      );
      expect(
        parseAttachmentMetadata({
          'id': 'a',
          'mimeType': 'image/png',
          'storageType': 'desktop-file',
          'storageKey': '/tmp/a',
        }),
        isNull,
      );
    });

    // Edge: the forge/GitHub item validator is the union of both upstream Zod
    // schemas — `kind` is limited to the three accepted spellings, `body` is
    // required-but-nullable, and `labels` must be all strings.
    test('validates forge search items against the schema union', () {
      Map<String, Object?> item(Map<String, Object?> overrides) => {
        'kind': 'issue',
        'number': 1,
        'title': 't',
        'url': 'u',
        'state': 'open',
        'body': null,
        'labels': <String>[],
        ...overrides,
      };

      expect(parseForgeOrGitHubSearchItem(item(const {})), isNotNull);
      expect(
        parseForgeOrGitHubSearchItem(item(const {'kind': 'pr'}))?.kind,
        ForgeSearchKind.changeRequest,
      );
      expect(
        parseForgeOrGitHubSearchItem(
          item(const {'kind': 'change_request'}),
        )?.kind,
        ForgeSearchKind.changeRequest,
      );
      expect(
        parseForgeOrGitHubSearchItem(item(const {'kind': 'github-pr'})),
        isNull,
      );
      expect(parseForgeOrGitHubSearchItem(item(const {'number': 'x'})), isNull);
      expect(
        parseForgeOrGitHubSearchItem(
          item(const {
            'labels': [1],
          }),
        ),
        isNull,
      );
      expect(parseForgeOrGitHubSearchItem(item(const {'body': 7})), isNull);
      expect(
        parseForgeOrGitHubSearchItem(const {
          'kind': 'issue',
          'number': 1,
          'title': 't',
          'url': 'u',
          'state': 'open',
          'labels': <String>[],
        }),
        isNull,
        reason: 'body is required, even though it may be null',
      );
      expect(
        parseForgeOrGitHubSearchItem(item(const {'forge': null})),
        isNull,
        reason: 'forge is optional but not nullable',
      );
      expect(
        parseForgeOrGitHubSearchItem(item(const {'baseRefName': null})),
        isNotNull,
        reason: 'baseRefName is nullable and optional',
      );
      expect(
        parseForgeOrGitHubSearchItem(item(const {'baseRefName': 3})),
        isNull,
      );
    });

    // Edge: only the picker's own owner tag survives on a `github_pr`; any
    // other owner rejects the whole attachment.
    test('accepts only the picker owner on a github_pr attachment', () {
      Map<String, Object?> pr(Map<String, Object?> extra) => {
        ..._githubPrAttachment(1),
        ...extra,
      };

      expect(
        (parseUserComposerAttachment(pr(const {})) as ForgeComposerAttachment)
            .owner,
        isNull,
      );
      expect(
        (parseUserComposerAttachment(
                  pr(const {'owner': 'new-workspace-picker'}),
                )
                as ForgeComposerAttachment)
            .owner,
        newWorkspacePickerAttachmentOwner,
      );
      expect(
        parseUserComposerAttachment(pr(const {'owner': 'someone-else'})),
        isNull,
      );
      // An owner on any other forge kind is simply not carried.
      expect(
        (parseUserComposerAttachment({
                  ..._githubIssueAttachment(1),
                  'owner': 'someone-else',
                })
                as ForgeComposerAttachment)
            .owner,
        isNull,
      );
    });

    // Edge: unknown attachment kinds — including every workspace-synthesised
    // one — are dropped rather than migrated.
    test('drops attachments of unknown kinds', () {
      for (final blob in <Object?>[
        null,
        'text',
        <Object?>[],
        const {'kind': 'browser_element'},
        const {'kind': 'chat_history'},
        const {'kind': 'github.pull_request_comment'},
        const {},
      ]) {
        expect(parseUserComposerAttachment(blob), isNull, reason: '$blob');
      }
    });

    // Edge: promotion strips *every* PR attachment, forge or GitHub flavoured,
    // while leaving issues alone.
    test('strips only PR attachments when promoting', () async {
      final issue = _githubIssueAttachment(1);
      final migrated = await migratePersistedState({
        'drafts': {
          'new-workspace:server-a:/a': _activeDraftJson('prompt', 1, [
            _githubPrAttachment(2),
            issue,
            _githubPrAttachment(3),
          ]),
        },
      }, _ports(1));

      expect(migrated.drafts['new-workspace']?.input.toJson(), {
        'text': 'prompt',
        'attachments': [issue],
      });
    });

    // Edge: promotion preserves the winning record's lifecycle metadata.
    test('promotion keeps the winning record metadata', () async {
      final migrated = await migratePersistedState({
        'drafts': {
          'new-workspace:server-a:/a': {
            'input': {'text': 'p', 'attachments': <Object?>[]},
            'lifecycle': 'active',
            'updatedAt': 55,
            'version': 9,
          },
        },
      }, _ports(1));

      expect(migrated.drafts['new-workspace']?.updatedAt, 55);
      expect(migrated.drafts['new-workspace']?.version, 9);
    });
  });

  // =========================================================================
  // Shared helpers
  // =========================================================================

  group('JS semantics helpers', () {
    test('jsTruthy matches JavaScript falsiness', () {
      for (final falsy in <Object?>[
        null,
        false,
        0,
        -0.0,
        0.0,
        '',
        double.nan,
      ]) {
        expect(jsTruthy(falsy), isFalse, reason: '$falsy');
      }
      for (final truthy in <Object?>[
        true,
        1,
        -1,
        0.5,
        'a',
        ' ',
        <Object?>[],
        <String, Object?>{},
      ]) {
        expect(jsTruthy(truthy), isTrue, reason: '$truthy');
      }
    });

    test('trimNonEmpty collapses blanks to null', () {
      expect(trimNonEmpty(null), isNull);
      expect(trimNonEmpty(''), isNull);
      expect(trimNonEmpty('   '), isNull);
      expect(trimNonEmpty(' a '), 'a');
    });

    test('asJsonObject accepts only JSON objects', () {
      expect(asJsonObject(const {'a': 1}), isNotNull);
      expect(asJsonObject(jsonDecode('{"a":1}')), isNotNull);
      expect(asJsonObject(<Object?>[]), isNull);
      expect(asJsonObject(null), isNull);
      expect(asJsonObject('a'), isNull);
    });
  });
}
