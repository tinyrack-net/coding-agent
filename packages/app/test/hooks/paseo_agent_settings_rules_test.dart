// Ports of the upstream suites for Paseo 0.2.0's `hooks/use-archive-agent.ts`
// and `hooks/use-settings/storage.ts`, plus the edge cases those suites leave
// unpinned: blank-id sentinels, prefix collisions between server ids, identity
// preservation on no-op cache rewrites, rollback of absent cache slots, the
// JS-truthiness reads of stored strings, `Number()`'s extra literal forms,
// font-family control characters, and the exact byte order of the persisted
// settings document.
//
// Nothing here reads a real clock or a real preference store: the archive
// controller takes a `DateTime Function()` and the settings loader takes an
// in-memory `KeyValueStorage`.
import 'dart:convert';

import 'package:coding_agent_app/hooks/paseo_agent_settings_rules.dart';
// Only for `SupportedLocale`, which the port reuses but does not re-export.
import 'package:coding_agent_app/i18n/locales.dart' show SupportedLocale;
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Port of upstream `fakes.ts`'s `createInMemoryKeyValueStorage`.
final class _InMemoryKeyValueStorage implements KeyValueStorage {
  _InMemoryKeyValueStorage([Map<String, String> initial = const {}])
    : entries = {...initial};

  final Map<String, String> entries;

  @override
  Future<String?> getItem(String key) async => entries[key];

  @override
  Future<void> setItem(String key, String value) async {
    entries[key] = value;
  }
}

/// Port of upstream `fakes.ts`'s `createFakeDesktopBridge`.
final class _FakeDesktopBridge implements DesktopSettingsBridge {
  _FakeDesktopBridge({this.isDesktop = false, DesktopOwnedSettings? settings})
    : settings = settings ?? _defaultDesktopSettings;

  static const _defaultDesktopSettings = DesktopOwnedSettings(
    releaseChannel: ReleaseChannel.stable,
    daemon: DesktopDaemonSettings(
      manageBuiltInDaemon: true,
      keepRunningAfterQuit: true,
    ),
  );

  final bool isDesktop;
  final DesktopOwnedSettings settings;
  final List<LegacyDesktopSettingsMigration> migrationsApplied = [];

  @override
  bool isDesktopShell() => isDesktop;

  @override
  Future<DesktopOwnedSettings> loadDesktopSettings() async => settings;

  @override
  Future<void> migrateLegacyDesktopSettings(
    LegacyDesktopSettingsMigration input,
  ) async {
    migrationsApplied.add(input);
  }
}

final class _Deps {
  _Deps({_InMemoryKeyValueStorage? storage, _FakeDesktopBridge? desktop})
    : storage = storage ?? _InMemoryKeyValueStorage(),
      desktop = desktop ?? _FakeDesktopBridge();

  final _InMemoryKeyValueStorage storage;
  final _FakeDesktopBridge desktop;
  final List<Object> loadErrors = [];

  SettingsDeps get deps => SettingsDeps(
    storage: storage,
    desktop: desktop,
    onLoadError: (error, _) => loadErrors.add(error),
  );
}

/// Stands in for the zustand session store's agent map.
final class _InMemoryAgentStore implements ArchivableAgentStore {
  final Map<String, Map<String, ArchivableAgent>> sessions = {};

  /// How many times the updater actually produced a new map, so tests can pin
  /// upstream's "return `prev` to mean nothing changed" contract.
  int replacements = 0;

  void initializeSession(
    String serverId, [
    Map<String, ArchivableAgent>? agents,
  ]) {
    sessions[serverId] = {...?agents};
  }

  @override
  Map<String, ArchivableAgent>? agentsFor(String serverId) =>
      sessions[serverId];

  @override
  void setAgents(
    String serverId,
    Map<String, ArchivableAgent> Function(Map<String, ArchivableAgent> previous)
    update,
  ) {
    final previous = sessions[serverId];
    if (previous == null) return;
    final next = update(previous);
    if (identical(next, previous)) return;
    replacements += 1;
    sessions[serverId] = next;
  }
}

final class _FakeArchiveGateway implements ArchiveAgentGateway {
  _FakeArchiveGateway({
    this.clientAvailable = true,
    this.archivedAt = '2026-04-01T04:00:00.000Z',
    this.failure,
  });

  bool clientAvailable;
  String archivedAt;
  Object? failure;
  final List<ArchiveAgentInput> calls = [];

  @override
  bool hasClient(String serverId) => clientAvailable;

  @override
  Future<String> archiveAgent({
    required String serverId,
    required String agentId,
  }) async {
    calls.add(ArchiveAgentInput(serverId: serverId, agentId: agentId));
    final error = failure;
    if (error != null) throw error;
    return archivedAt;
  }
}

ArchivableAgent _makeAgent({DateTime? archivedAt, String title = 'Agent 1'}) =>
    ArchivableAgent({
      'serverId': 'server-a',
      'id': 'agent-1',
      'provider': 'codex',
      'status': 'running',
      'title': title,
      'archivedAt': archivedAt,
    });

Map<String, Object?> _asMap(Object? value) => value! as Map<String, Object?>;

void main() {
  // -------------------------------------------------------------------------
  // agent-history-query-key.ts + the QueryClient stand-in
  // -------------------------------------------------------------------------

  group('query keys', () {
    test('builds the frozen key shapes', () {
      expect(agentHistoryQueryKey('server-a').segments, [
        'agentHistory',
        'server-a',
      ]);
      expect(agentHistoryQueryKey(null).segments, ['agentHistory', null]);
      expect(allAgentHistoryQueryRootKey().segments, ['allAgentHistory']);
      expect(sidebarAgentsListQueryKey('server-a').segments, [
        'sidebarAgentsList',
        'server-a',
      ]);
      expect(allAgentsQueryKey('server-a').segments, ['allAgents', 'server-a']);
    });

    test('sorts cross-server history ids so callers share one cache slot', () {
      expect(allAgentHistoryQueryKey(['server-b', 'server-a']).segments, [
        'allAgentHistory',
        'server-a',
        'server-b',
      ]);
      expect(
        allAgentHistoryQueryKey(['server-b', 'server-a']),
        allAgentHistoryQueryKey(['server-a', 'server-b']),
      );
    });

    test('does not mutate the caller list while sorting', () {
      final serverIds = ['server-b', 'server-a'];
      allAgentHistoryQueryKey(serverIds);
      expect(serverIds, ['server-b', 'server-a']);
    });

    test('equal keys hash equally and unequal keys do not', () {
      expect(
        QueryKey(const ['a', 'b']).hashCode,
        QueryKey(const ['a', 'b']).hashCode,
      );
      expect(QueryKey(const ['a', 'b']), isNot(QueryKey(const ['a', 'c'])));
      expect(QueryKey(const ['a']), isNot(QueryKey(const ['a', 'b'])));
    });

    test('matches partial prefixes but never a longer filter', () {
      final key = allAgentHistoryQueryKey(['server-a', 'server-b']);
      expect(key.matchesPrefix(allAgentHistoryQueryRootKey()), isTrue);
      expect(
        key.matchesPrefix(QueryKey(const ['allAgentHistory', 'server-a'])),
        isTrue,
      );
      expect(key.matchesPrefix(QueryKey(const ['allAgents'])), isFalse);
      expect(
        allAgentHistoryQueryRootKey().matchesPrefix(key),
        isFalse,
        reason: 'a longer filter cannot match a shorter key',
      );
    });
  });

  group('PaseoQueryCache', () {
    test('reports an absent query as having no state', () {
      final cache = PaseoQueryCache();
      final key = QueryKey(const ['missing']);

      expect(cache.hasQuery(key), isFalse);
      expect(cache.getQueryData(key), isNull);
      expect(cache.isQueryInvalidated(key), isNull);
    });

    test(
      'treats a null value as react-query undefined and skips the write',
      () {
        final cache = PaseoQueryCache();
        final key = QueryKey(const ['q']);

        cache.setQueryData(key, null);
        expect(cache.hasQuery(key), isFalse);

        cache.setQueryData(key, 'value');
        cache.updateQueryData(key, (_) => null);
        expect(cache.getQueryData(key), 'value');
      },
    );

    test('hands the updater null for an uncached query', () {
      final cache = PaseoQueryCache();
      Object? seen = 'sentinel';

      cache.updateQueryData(QueryKey(const ['q']), (current) {
        seen = current;
        return 'next';
      });

      expect(seen, isNull);
      expect(cache.getQueryData(QueryKey(const ['q'])), 'next');
    });

    test('invalidates and removes by key', () {
      final cache = PaseoQueryCache();
      final root = QueryKey(const ['root']);
      final child = QueryKey(const ['root', 'a']);
      final other = QueryKey(const ['other']);
      cache.setQueryData(child, 1);
      cache.setQueryData(other, 2);

      cache.invalidateQueries(root);
      expect(cache.isQueryInvalidated(child), isTrue);
      expect(cache.isQueryInvalidated(other), isFalse);

      cache.removeQueries(child);
      expect(cache.hasQuery(child), isFalse);
      expect(cache.hasQuery(other), isTrue);

      cache.setQueryData(child, 1);
      cache.removeQueries(root, exact: false);
      expect(cache.hasQuery(child), isFalse);
      expect(cache.hasQuery(other), isTrue);
    });

    test('setQueriesData rewrites every prefix match, in insertion order', () {
      final cache = PaseoQueryCache();
      cache.setQueryData(QueryKey(const ['root', 'b']), 'b');
      cache.setQueryData(QueryKey(const ['root', 'a']), 'a');
      cache.setQueryData(QueryKey(const ['nope']), 'x');

      cache.setQueriesData(QueryKey(const ['root']), (current) => '$current!');

      expect(
        cache.getQueriesData(QueryKey(const ['root'])).map((e) => e.data),
        ['b!', 'a!'],
      );
      expect(cache.getQueryData(QueryKey(const ['nope'])), 'x');
    });
  });

  // -------------------------------------------------------------------------
  // use-archive-agent.ts
  // -------------------------------------------------------------------------

  group('toArchiveKey', () {
    test('joins the trimmed ids', () {
      expect(
        toArchiveKey(
          const ArchiveAgentInput(serverId: ' server-a ', agentId: ' agent-1 '),
        ),
        'server-a:agent-1',
      );
    });

    test('returns the empty sentinel when either id is blank', () {
      expect(
        toArchiveKey(const ArchiveAgentInput(serverId: '', agentId: 'agent-1')),
        '',
      );
      expect(
        toArchiveKey(
          const ArchiveAgentInput(serverId: 'server-a', agentId: ''),
        ),
        '',
      );
      expect(
        toArchiveKey(const ArchiveAgentInput(serverId: '   ', agentId: '   ')),
        '',
      );
    });
  });

  group('pending archive state', () {
    test('tracks pending archive state in the shared cache', () {
      final cache = PaseoQueryCache();

      expect(
        isAgentArchiving(
          cache: cache,
          serverId: 'server-a',
          agentId: 'agent-1',
        ),
        isFalse,
      );

      setAgentArchiving(
        cache: cache,
        serverId: 'server-a',
        agentId: 'agent-1',
        isArchiving: true,
      );

      expect(
        isAgentArchiving(
          cache: cache,
          serverId: 'server-a',
          agentId: 'agent-1',
        ),
        isTrue,
      );
      expect(
        isAgentArchiving(
          cache: cache,
          serverId: 'server-a',
          agentId: 'agent-2',
        ),
        isFalse,
      );

      setAgentArchiving(
        cache: cache,
        serverId: 'server-a',
        agentId: 'agent-1',
        isArchiving: false,
      );

      expect(
        isAgentArchiving(
          cache: cache,
          serverId: 'server-a',
          agentId: 'agent-1',
        ),
        isFalse,
      );
    });

    test('ignores a blank id rather than writing a ":" bucket', () {
      final cache = PaseoQueryCache();

      setAgentArchiving(
        cache: cache,
        serverId: '',
        agentId: '',
        isArchiving: true,
      );

      expect(cache.hasQuery(archiveAgentPendingQueryKey), isFalse);
      expect(
        isAgentArchiving(cache: cache, serverId: '', agentId: ''),
        isFalse,
      );
    });

    test('keeps the same map when the flag is already set', () {
      final cache = PaseoQueryCache();
      setAgentArchiving(
        cache: cache,
        serverId: 'server-a',
        agentId: 'agent-1',
        isArchiving: true,
      );
      final first = cache.getQueryData(archiveAgentPendingQueryKey);

      setAgentArchiving(
        cache: cache,
        serverId: 'server-a',
        agentId: 'agent-1',
        isArchiving: true,
      );

      expect(
        identical(cache.getQueryData(archiveAgentPendingQueryKey), first),
        isTrue,
      );
    });

    test('clearing an unset flag still seeds an empty map', () {
      final cache = PaseoQueryCache();

      clearArchiveAgentPending(
        cache: cache,
        serverId: 'server-a',
        agentId: 'agent-1',
      );

      expect(cache.hasQuery(archiveAgentPendingQueryKey), isTrue);
      expect(readPendingState(cache), isEmpty);
    });

    test('reads a missing or malformed cache slot as empty', () {
      final cache = PaseoQueryCache();
      expect(readPendingState(cache), isEmpty);

      cache.setQueryData(archiveAgentPendingQueryKey, 'not a map');
      expect(readPendingState(cache), isEmpty);

      cache.setQueryData(archiveAgentPendingQueryKey, {
        'server-a:agent-1': true,
        'server-a:agent-2': 'yes',
      });
      expect(readPendingState(cache), {'server-a:agent-1': true});
    });

    test('a hand-written false reads as not archiving', () {
      final cache = PaseoQueryCache();
      cache.setQueryData(archiveAgentPendingQueryKey, {
        'server-a:agent-1': false,
      });

      expect(
        isAgentArchiving(
          cache: cache,
          serverId: 'server-a',
          agentId: 'agent-1',
        ),
        isFalse,
      );
    });
  });

  group('selectPendingArchiveAgentIds', () {
    test('selects pending archive ids for a single server', () {
      final pendingIds = selectPendingArchiveAgentIds(const {
        'server-a:agent-1': true,
        'server-a:agent-2': true,
        'server-b:agent-3': true,
      }, 'server-a');

      expect(pendingIds.toList(), ['agent-1', 'agent-2']);
    });

    test('trims the server id before matching', () {
      expect(
        selectPendingArchiveAgentIds(const {
          'server-a:agent-1': true,
        }, '  server-a  ').toList(),
        ['agent-1'],
      );
    });

    test('does not confuse a server whose id is a prefix of another', () {
      expect(
        selectPendingArchiveAgentIds(const {
          'server-a:agent-1': true,
          'server-ab:agent-2': true,
        }, 'server-a').toList(),
        ['agent-1'],
      );
    });

    test('skips a key with an empty agent id', () {
      expect(
        selectPendingArchiveAgentIds(const {'server-a:': true}, 'server-a'),
        isEmpty,
      );
    });

    test('returns the shared empty set for a blank server or no matches', () {
      final blank = selectPendingArchiveAgentIds(const {
        'server-a:agent-1': true,
      }, '   ');
      final none = selectPendingArchiveAgentIds(const {
        'server-b:agent-1': true,
      }, 'server-a');

      expect(blank, isEmpty);
      expect(none, isEmpty);
      expect(
        identical(blank, none),
        isTrue,
        reason: 'one shared instance keeps identity-comparing callers stable',
      );
    });
  });

  group('removeAgentFromListPayload', () {
    test('removes an archived agent from cached list payloads', () {
      final payload = <String, Object?>{
        'entries': [
          {
            'agent': {'id': 'agent-1'},
          },
          {
            'agent': {'id': 'agent-2'},
          },
        ],
        'pageInfo': {'hasMore': false},
      };

      final next = _asMap(removeAgentFromListPayload(payload, 'agent-1'));

      expect(next['entries'], [
        {
          'agent': {'id': 'agent-2'},
        },
      ]);
      expect(next['pageInfo'], {'hasMore': false});
    });

    test('returns the identical payload when nothing matched', () {
      final payload = <String, Object?>{
        'entries': [
          {
            'agent': {'id': 'agent-2'},
          },
        ],
      };

      expect(
        identical(removeAgentFromListPayload(payload, 'agent-1'), payload),
        isTrue,
      );
    });

    test('passes through a null, non-object, or entry-less payload', () {
      expect(removeAgentFromListPayload(null, 'agent-1'), isNull);
      expect(removeAgentFromListPayload(42, 'agent-1'), 42);

      final noEntries = <String, Object?>{'entries': 'nope'};
      expect(
        identical(removeAgentFromListPayload(noEntries, 'agent-1'), noEntries),
        isTrue,
      );
    });

    test('ignores a blank agent id', () {
      final payload = <String, Object?>{
        'entries': [
          {
            'agent': {'id': 'agent-1'},
          },
        ],
      };

      expect(
        identical(removeAgentFromListPayload(payload, ''), payload),
        isTrue,
      );
    });

    test('keeps entries with a null entry, null agent, or missing id', () {
      final payload = <String, Object?>{
        'entries': [
          null,
          {'agent': null},
          <String, Object?>{},
          {
            'agent': {'id': 'agent-1'},
          },
        ],
      };

      final next = _asMap(removeAgentFromListPayload(payload, 'agent-1'));

      expect(next['entries'], [
        null,
        {'agent': null},
        <String, Object?>{},
      ]);
    });
  });

  group('markAgentArchivedInHistoryPayload', () {
    Object? mark(
      Object? payload, {
      String archivedAt = '2026-04-01T04:00:00.000Z',
    }) => markAgentArchivedInHistoryPayload(
      payload,
      serverId: 'server-a',
      agentId: 'agent-1',
      archivedAt: archivedAt,
    );

    test('stamps a matching agent and keeps sibling keys', () {
      final payload = <String, Object?>{
        'pages': [
          <String, Object?>{
            'agents': [
              {'id': 'agent-1', 'archivedAt': null},
              {'id': 'agent-2', 'archivedAt': null},
            ],
          },
        ],
        'pageParams': [null],
      };

      final next = _asMap(mark(payload));

      expect(next, {
        'pages': [
          {
            'agents': [
              {'id': 'agent-1', 'archivedAt': DateTime.utc(2026, 4, 1, 4)},
              {'id': 'agent-2', 'archivedAt': null},
            ],
          },
        ],
        'pageParams': [null],
      });
    });

    test('matches an entry that carries no serverId at all', () {
      final next = _asMap(
        mark(<String, Object?>{
          'pages': [
            <String, Object?>{
              'agents': [
                {'id': 'agent-1'},
              ],
            },
          ],
        }),
      );

      expect(((next['pages']! as List).first as Map)['agents'], [
        {'id': 'agent-1', 'archivedAt': DateTime.utc(2026, 4, 1, 4)},
      ]);
    });

    test('leaves an entry belonging to another server alone', () {
      final payload = <String, Object?>{
        'pages': [
          <String, Object?>{
            'agents': [
              {'id': 'agent-1', 'serverId': 'server-b', 'archivedAt': null},
            ],
          },
        ],
      };

      expect(identical(mark(payload), payload), isTrue);
    });

    test('returns the payload untouched for an unparseable timestamp', () {
      final payload = <String, Object?>{
        'pages': [
          <String, Object?>{
            'agents': [
              {'id': 'agent-1'},
            ],
          },
        ],
      };

      expect(
        identical(mark(payload, archivedAt: 'not-a-date'), payload),
        isTrue,
      );
    });

    test('passes through null, non-object, and page-less payloads', () {
      expect(mark(null), isNull);
      expect(mark('nope'), 'nope');

      final noPages = <String, Object?>{'pages': 'nope'};
      expect(identical(mark(noPages), noPages), isTrue);
    });

    test('leaves a page whose agents are missing or malformed alone', () {
      // DEVIATION: upstream would throw on a null page (`page.agents`); the
      // port returns it unchanged.
      final payload = <String, Object?>{
        'pages': [
          null,
          <String, Object?>{'agents': 'nope'},
          <String, Object?>{
            'agents': [
              {'id': 'agent-1'},
            ],
          },
        ],
      };

      final next = _asMap(mark(payload));
      final pages = next['pages']! as List;

      expect(pages[0], isNull);
      expect(pages[1], {'agents': 'nope'});
      expect((pages[2]! as Map)['agents'], [
        {'id': 'agent-1', 'archivedAt': DateTime.utc(2026, 4, 1, 4)},
      ]);
    });

    test('ignores a blank agent id', () {
      final payload = <String, Object?>{
        'pages': [
          <String, Object?>{
            'agents': [
              {'id': ''},
            ],
          },
        ],
      };

      expect(
        identical(
          markAgentArchivedInHistoryPayload(
            payload,
            serverId: 'server-a',
            agentId: '',
            archivedAt: '2026-04-01T04:00:00.000Z',
          ),
          payload,
        ),
        isTrue,
      );
    });
  });

  group('applyArchivedAgentCloseResults', () {
    late PaseoQueryCache cache;
    late _InMemoryAgentStore store;

    void seed() {
      cache = PaseoQueryCache();
      store = _InMemoryAgentStore()
        ..initializeSession('server-a', {'agent-1': _makeAgent()});
      cache.setQueryData(
        sidebarAgentsListQueryKey('server-a'),
        <String, Object?>{
          'entries': [
            {
              'agent': {'id': 'agent-1'},
            },
            {
              'agent': {'id': 'agent-2'},
            },
          ],
        },
      );
      cache.setQueryData(allAgentsQueryKey('server-a'), <String, Object?>{
        'entries': [
          {
            'agent': {'id': 'agent-1'},
          },
          {
            'agent': {'id': 'agent-2'},
          },
        ],
      });
      cache.setQueryData(agentHistoryQueryKey('server-a'), <String, Object?>{
        'pages': [
          <String, Object?>{
            'agents': [
              {'id': 'agent-1', 'archivedAt': null},
              {'id': 'agent-2', 'archivedAt': null},
            ],
          },
        ],
        'pageParams': [null],
      });
      cache.setQueryData(
        allAgentHistoryQueryKey(['server-a', 'server-b']),
        <String, Object?>{
          'pages': [
            <String, Object?>{
              'agents': [
                {'id': 'agent-1', 'serverId': 'server-a', 'archivedAt': null},
                {'id': 'agent-1', 'serverId': 'server-b', 'archivedAt': null},
              ],
            },
          ],
          'pageParams': [null],
        },
      );
    }

    test('applies close results to session state and cached lists', () {
      seed();

      applyArchivedAgentCloseResults(
        cache: cache,
        store: store,
        serverId: 'server-a',
        results: const [
          ArchivedAgentCloseResult(
            agentId: 'agent-1',
            archivedAt: '2026-04-01T04:00:00.000Z',
          ),
        ],
      );

      expect(
        store.sessions['server-a']!['agent-1']!.archivedAt,
        DateTime.utc(2026, 4, 1, 4),
      );
      expect(cache.getQueryData(sidebarAgentsListQueryKey('server-a')), {
        'entries': [
          {
            'agent': {'id': 'agent-2'},
          },
        ],
      });
      expect(cache.getQueryData(allAgentsQueryKey('server-a')), {
        'entries': [
          {
            'agent': {'id': 'agent-2'},
          },
        ],
      });
      expect(cache.getQueryData(agentHistoryQueryKey('server-a')), {
        'pages': [
          {
            'agents': [
              {'id': 'agent-1', 'archivedAt': DateTime.utc(2026, 4, 1, 4)},
              {'id': 'agent-2', 'archivedAt': null},
            ],
          },
        ],
        'pageParams': [null],
      });
      expect(
        cache.isQueryInvalidated(
          allAgentHistoryQueryKey(['server-a', 'server-b']),
        ),
        isTrue,
      );
      expect(
        cache.getQueryData(allAgentHistoryQueryKey(['server-a', 'server-b'])),
        {
          'pages': [
            {
              'agents': [
                {
                  'id': 'agent-1',
                  'serverId': 'server-a',
                  'archivedAt': DateTime.utc(2026, 4, 1, 4),
                },
                {'id': 'agent-1', 'serverId': 'server-b', 'archivedAt': null},
              ],
            },
          ],
          'pageParams': [null],
        },
      );
    });

    test('can apply close results without invalidating cached lists', () {
      seed();

      applyArchivedAgentCloseResults(
        cache: cache,
        store: store,
        serverId: 'server-a',
        results: const [
          ArchivedAgentCloseResult(
            agentId: 'agent-1',
            archivedAt: '2026-04-01T04:00:00.000Z',
          ),
        ],
        invalidateQueries: false,
      );

      expect(
        cache.isQueryInvalidated(sidebarAgentsListQueryKey('server-a')),
        isFalse,
      );
      expect(cache.isQueryInvalidated(allAgentsQueryKey('server-a')), isFalse);
      expect(
        cache.isQueryInvalidated(agentHistoryQueryKey('server-a')),
        isFalse,
      );
      expect(
        cache.isQueryInvalidated(
          allAgentHistoryQueryKey(['server-a', 'server-b']),
        ),
        isFalse,
      );
      expect(
        store.sessions['server-a']!['agent-1']!.archivedAt,
        DateTime.utc(2026, 4, 1, 4),
      );
    });

    test('does nothing at all for an empty batch', () {
      seed();

      applyArchivedAgentCloseResults(
        cache: cache,
        store: store,
        serverId: 'server-a',
        results: const [],
      );

      expect(
        cache.isQueryInvalidated(sidebarAgentsListQueryKey('server-a')),
        isFalse,
      );
      expect(store.replacements, 0);
    });

    test('applies every result in the batch', () {
      seed();

      applyArchivedAgentCloseResults(
        cache: cache,
        store: store,
        serverId: 'server-a',
        results: const [
          ArchivedAgentCloseResult(
            agentId: 'agent-1',
            archivedAt: '2026-04-01T04:00:00.000Z',
          ),
          ArchivedAgentCloseResult(
            agentId: 'agent-2',
            archivedAt: '2026-04-01T05:00:00.000Z',
          ),
        ],
      );

      expect(
        _asMap(
          cache.getQueryData(sidebarAgentsListQueryKey('server-a')),
        )['entries'],
        isEmpty,
      );
      expect(
        ((_asMap(cache.getQueryData(agentHistoryQueryKey('server-a')))['pages']!
                    as List)
                .first
            as Map)['agents'],
        [
          {'id': 'agent-1', 'archivedAt': DateTime.utc(2026, 4, 1, 4)},
          {'id': 'agent-2', 'archivedAt': DateTime.utc(2026, 4, 1, 5)},
        ],
      );
    });

    test(
      'an unparseable timestamp leaves the store alone but still delists',
      () {
        seed();

        applyArchivedAgentCloseResults(
          cache: cache,
          store: store,
          serverId: 'server-a',
          results: const [
            ArchivedAgentCloseResult(agentId: 'agent-1', archivedAt: 'nope'),
          ],
          invalidateQueries: false,
        );

        expect(store.sessions['server-a']!['agent-1']!.archivedAt, isNull);
        expect(
          _asMap(
            cache.getQueryData(sidebarAgentsListQueryKey('server-a')),
          )['entries'],
          [
            {
              'agent': {'id': 'agent-2'},
            },
          ],
        );
      },
    );
  });

  group('session store snapshots', () {
    test(
      'markAgentArchivedInStore skips a redundant same-millisecond write',
      () {
        final store = _InMemoryAgentStore()
          ..initializeSession('server-a', {
            'agent-1': _makeAgent(archivedAt: DateTime.utc(2026, 4, 1, 4)),
          });

        markAgentArchivedInStore(
          store,
          serverId: 'server-a',
          agentId: 'agent-1',
          archivedAt: '2026-04-01T04:00:00.000Z',
        );

        expect(store.replacements, 0);
      },
    );

    test('markAgentArchivedInStore skips a missing agent', () {
      final store = _InMemoryAgentStore()..initializeSession('server-a');

      markAgentArchivedInStore(
        store,
        serverId: 'server-a',
        agentId: 'agent-1',
        archivedAt: '2026-04-01T04:00:00.000Z',
      );

      expect(store.replacements, 0);
    });

    test('markAgentArchivedInStore preserves the agent\'s other fields', () {
      final store = _InMemoryAgentStore()
        ..initializeSession('server-a', {'agent-1': _makeAgent(title: 'Kept')});

      markAgentArchivedInStore(
        store,
        serverId: 'server-a',
        agentId: 'agent-1',
        archivedAt: '2026-04-01T04:00:00.000Z',
      );

      expect(store.sessions['server-a']!['agent-1']!.fields['title'], 'Kept');
      expect(store.replacements, 1);
    });

    test('getStoredAgentSnapshot is null for an unknown server or agent', () {
      final store = _InMemoryAgentStore()..initializeSession('server-a');

      expect(
        getStoredAgentSnapshot(
          store,
          const ArchiveAgentInput(serverId: 'server-b', agentId: 'agent-1'),
        ),
        isNull,
      );
      expect(
        getStoredAgentSnapshot(
          store,
          const ArchiveAgentInput(serverId: 'server-a', agentId: 'agent-1'),
        ),
        isNull,
      );
    });

    test(
      'restoreAgentSnapshot removes the agent when the snapshot was null',
      () {
        final store = _InMemoryAgentStore()
          ..initializeSession('server-a', {'agent-1': _makeAgent()});

        restoreAgentSnapshot(
          store,
          serverId: 'server-a',
          agentId: 'agent-1',
          agent: null,
        );

        expect(store.sessions['server-a'], isEmpty);
        expect(store.replacements, 1);
      },
    );

    test('restoreAgentSnapshot is a no-op when nothing needs undoing', () {
      final agent = _makeAgent();
      final store = _InMemoryAgentStore()
        ..initializeSession('server-a', {'agent-1': agent});

      restoreAgentSnapshot(
        store,
        serverId: 'server-a',
        agentId: 'agent-1',
        agent: agent,
      );
      restoreAgentSnapshot(
        store,
        serverId: 'server-a',
        agentId: 'agent-2',
        agent: null,
      );

      expect(store.replacements, 0);
    });

    test(
      'restoreAgentSnapshot puts back a value-equal but distinct object',
      () {
        final store = _InMemoryAgentStore()
          ..initializeSession('server-a', {'agent-1': _makeAgent()});
        final snapshot = _makeAgent();

        restoreAgentSnapshot(
          store,
          serverId: 'server-a',
          agentId: 'agent-1',
          agent: snapshot,
        );

        expect(
          identical(store.sessions['server-a']!['agent-1'], snapshot),
          isTrue,
        );
        expect(store.replacements, 1);
      },
    );
  });

  group('list cache snapshots', () {
    test('restores captured payloads and removes slots that were empty', () {
      final cache = PaseoQueryCache();
      cache.setQueryData(
        sidebarAgentsListQueryKey('server-a'),
        <String, Object?>{'entries': []},
      );
      cache.setQueryData(
        allAgentHistoryQueryKey(['server-a']),
        <String, Object?>{'pages': []},
      );

      final snapshot = captureArchivedAgentListCacheSnapshot(cache, 'server-a');

      cache.setQueryData(sidebarAgentsListQueryKey('server-a'), 'clobbered');
      cache.setQueryData(
        allAgentsQueryKey('server-a'),
        'created after capture',
      );
      cache.setQueryData(
        agentHistoryQueryKey('server-a'),
        'created after capture',
      );

      restoreArchivedAgentListCacheSnapshot(cache, 'server-a', snapshot);

      expect(cache.getQueryData(sidebarAgentsListQueryKey('server-a')), {
        'entries': <Object?>[],
      });
      expect(
        cache.hasQuery(allAgentsQueryKey('server-a')),
        isFalse,
        reason: 'a slot that was absent at capture must be removed, not nulled',
      );
      expect(cache.hasQuery(agentHistoryQueryKey('server-a')), isFalse);
      expect(cache.getQueryData(allAgentHistoryQueryKey(['server-a'])), {
        'pages': <Object?>[],
      });
    });

    test('captures every cross-server history slot, not a fixed key', () {
      final cache = PaseoQueryCache();
      cache.setQueryData(allAgentHistoryQueryKey(['server-a']), 1);
      cache.setQueryData(allAgentHistoryQueryKey(['server-a', 'server-b']), 2);

      final snapshot = captureArchivedAgentListCacheSnapshot(cache, 'server-a');

      expect(snapshot.allAgentHistory.map((entry) => entry.data), [1, 2]);
    });
  });

  group('toJsIsoString', () {
    test('truncates to milliseconds the way Date.toISOString does', () {
      expect(
        toJsIsoString(DateTime.utc(2026, 4, 1, 4, 0, 0, 0, 500)),
        '2026-04-01T04:00:00.000Z',
      );
      expect(
        toJsIsoString(DateTime.utc(2026, 4, 1, 4, 0, 0, 123)),
        '2026-04-01T04:00:00.123Z',
      );
    });

    test('normalizes a local time to UTC', () {
      final local = DateTime.utc(2026, 4, 1, 4).toLocal();
      expect(toJsIsoString(local), '2026-04-01T04:00:00.000Z');
    });
  });

  group('ArchiveAgentController', () {
    ({
      ArchiveAgentController controller,
      PaseoQueryCache cache,
      _InMemoryAgentStore store,
      _FakeArchiveGateway gateway,
    })
    build({_FakeArchiveGateway? gateway}) {
      final cache = PaseoQueryCache();
      final store = _InMemoryAgentStore()
        ..initializeSession('server-a', {'agent-1': _makeAgent()});
      final resolvedGateway = gateway ?? _FakeArchiveGateway();
      cache.setQueryData(
        sidebarAgentsListQueryKey('server-a'),
        <String, Object?>{
          'entries': [
            {
              'agent': {'id': 'agent-1'},
            },
          ],
        },
      );
      return (
        controller: ArchiveAgentController(
          cache: cache,
          store: store,
          gateway: resolvedGateway,
          now: () => DateTime.utc(2026, 4, 1, 3, 59, 59),
          daemonClientUnavailableMessage: 'Daemon client unavailable',
        ),
        cache: cache,
        store: store,
        gateway: resolvedGateway,
      );
    }

    test(
      'archives optimistically then confirms with the server timestamp',
      () async {
        final harness = build();

        await harness.controller.archiveAgent(
          const ArchiveAgentInput(serverId: 'server-a', agentId: 'agent-1'),
        );

        expect(harness.gateway.calls, [
          const ArchiveAgentInput(serverId: 'server-a', agentId: 'agent-1'),
        ]);
        expect(
          harness.store.sessions['server-a']!['agent-1']!.archivedAt,
          DateTime.utc(2026, 4, 1, 4),
        );
        expect(
          _asMap(
            harness.cache.getQueryData(sidebarAgentsListQueryKey('server-a')),
          )['entries'],
          isEmpty,
        );
        expect(
          harness.cache.isQueryInvalidated(
            sidebarAgentsListQueryKey('server-a'),
          ),
          isTrue,
        );
        expect(
          harness.controller.isArchivingAgent(
            const ArchiveAgentInput(serverId: 'server-a', agentId: 'agent-1'),
          ),
          isFalse,
        );
      },
    );

    test('marks the agent pending while the request is in flight', () async {
      final gateway = _FakeArchiveGateway();
      final harness = build(gateway: gateway);
      const input = ArchiveAgentInput(serverId: 'server-a', agentId: 'agent-1');

      final pending = harness.controller.archiveAgent(input);

      expect(harness.controller.isArchivingAgent(input), isTrue);
      expect(harness.controller.pendingArchiveAgentIds('server-a').toList(), [
        'agent-1',
      ]);

      await pending;

      expect(harness.controller.isArchivingAgent(input), isFalse);
      expect(harness.controller.pendingArchiveAgentIds('server-a'), isEmpty);
    });

    test('stamps the injected clock, then the server timestamp wins', () async {
      final gateway = _FakeArchiveGateway(
        archivedAt: '2026-04-01T06:30:00.000Z',
      );
      final harness = build(gateway: gateway);

      final pending = harness.controller.archiveAgent(
        const ArchiveAgentInput(serverId: 'server-a', agentId: 'agent-1'),
      );

      expect(
        harness.store.sessions['server-a']!['agent-1']!.archivedAt,
        DateTime.utc(2026, 4, 1, 3, 59, 59),
        reason: 'the optimistic stamp comes from the injected clock',
      );

      await pending;

      expect(
        harness.store.sessions['server-a']!['agent-1']!.archivedAt,
        DateTime.utc(2026, 4, 1, 6, 30),
      );
    });

    test(
      'rolls the store and every cache back when the daemon fails',
      () async {
        final gateway = _FakeArchiveGateway(failure: StateError('nope'));
        final harness = build(gateway: gateway);
        final before = harness.cache.getQueryData(
          sidebarAgentsListQueryKey('server-a'),
        );

        await expectLater(
          harness.controller.archiveAgent(
            const ArchiveAgentInput(serverId: 'server-a', agentId: 'agent-1'),
          ),
          throwsStateError,
        );

        expect(
          harness.store.sessions['server-a']!['agent-1']!.archivedAt,
          isNull,
        );
        expect(
          identical(
            harness.cache.getQueryData(sidebarAgentsListQueryKey('server-a')),
            before,
          ),
          isTrue,
        );
        expect(
          harness.controller.isArchivingAgent(
            const ArchiveAgentInput(serverId: 'server-a', agentId: 'agent-1'),
          ),
          isFalse,
        );
        expect(
          harness.cache.isQueryInvalidated(
            sidebarAgentsListQueryKey('server-a'),
          ),
          isTrue,
          reason: 'onSettled invalidates whatever the outcome was',
        );
      },
    );

    test(
      'throws the translated message when no daemon client is connected',
      () async {
        final gateway = _FakeArchiveGateway(clientAvailable: false);
        final harness = build(gateway: gateway);

        await expectLater(
          harness.controller.archiveAgent(
            const ArchiveAgentInput(serverId: 'server-a', agentId: 'agent-1'),
          ),
          throwsA(
            isA<ArchiveAgentUnavailableException>().having(
              (error) => error.message,
              'message',
              'Daemon client unavailable',
            ),
          ),
        );

        expect(gateway.calls, isEmpty);
        expect(
          harness.store.sessions['server-a']!['agent-1']!.archivedAt,
          isNull,
        );
      },
    );

    test('a blank id never reads as archiving', () {
      final harness = build();

      expect(
        harness.controller.isArchivingAgent(
          const ArchiveAgentInput(serverId: '', agentId: 'agent-1'),
        ),
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  // use-settings/storage.ts
  // -------------------------------------------------------------------------

  group('loadAppSettingsFromStorage', () {
    test('defaults theme to auto when storage is empty', () async {
      final deps = _Deps();

      final result = await loadAppSettingsFromStorage(deps.deps);

      expect(result.theme, AppThemeName.auto);
    });

    test(
      'seeds storage with the client defaults when nothing is persisted',
      () async {
        final deps = _Deps();

        final result = await loadAppSettingsFromStorage(deps.deps);

        expect(result, defaultClientSettings);
        expect(defaultClientSettings.language, AppLanguage.system);
        expect(
          deps.storage.entries[appSettingsStorageKey],
          jsonEncode(defaultClientSettings.toJson()),
        );
      },
    );

    test('persists the settings document in the frozen key order', () async {
      final deps = _Deps();

      await loadAppSettingsFromStorage(deps.deps);

      expect(
        deps.storage.entries[appSettingsStorageKey],
        '{"theme":"auto","language":"system","sendBehavior":"interrupt",'
        '"serviceUrlBehavior":"ask","terminalScrollbackLines":10000,'
        '"uiFontFamily":"","monoFontFamily":"","uiFontSize":16,'
        '"codeFontSize":12,"syntaxTheme":"one","workspaceTitleSource":"title",'
        '"autoExpandReasoning":false,"toolCallDetailLevel":"detailed",'
        '"vimKeybindings":false}',
      );
    });

    test('defaults language to system when storage is empty', () async {
      final deps = _Deps();

      expect(
        (await loadAppSettingsFromStorage(deps.deps)).language,
        AppLanguage.system,
      );
    });

    test(
      'defaults workspace title source to title when storage is empty',
      () async {
        final deps = _Deps();

        expect(
          (await loadAppSettingsFromStorage(deps.deps)).workspaceTitleSource,
          WorkspaceTitleSource.title,
        );
      },
    );

    test('loads configured terminal scrollback lines', () async {
      final deps = _Deps(
        storage: _InMemoryKeyValueStorage({
          appSettingsStorageKey: jsonEncode({'terminalScrollbackLines': 42000}),
        }),
      );

      expect(
        (await loadAppSettingsFromStorage(deps.deps)).terminalScrollbackLines,
        42000,
      );
    });

    test('loads a configured workspace title source', () async {
      final deps = _Deps(
        storage: _InMemoryKeyValueStorage({
          appSettingsStorageKey: jsonEncode({'workspaceTitleSource': 'branch'}),
        }),
      );

      expect(
        (await loadAppSettingsFromStorage(deps.deps)).workspaceTitleSource,
        WorkspaceTitleSource.branch,
      );
    });

    test('drops an unknown workspace title source back to title', () async {
      final deps = _Deps(
        storage: _InMemoryKeyValueStorage({
          appSettingsStorageKey: jsonEncode({
            'workspaceTitleSource': 'directory',
          }),
        }),
      );

      expect(
        (await loadAppSettingsFromStorage(deps.deps)).workspaceTitleSource,
        WorkspaceTitleSource.title,
      );
    });

    test('normalizes terminal scrollback lines from storage', () async {
      final deps = _Deps(
        storage: _InMemoryKeyValueStorage({
          appSettingsStorageKey: jsonEncode({
            'terminalScrollbackLines': 1000000.9,
          }),
        }),
      );

      expect(
        (await loadAppSettingsFromStorage(deps.deps)).terminalScrollbackLines,
        1000000,
      );
    });

    test(
      'migrates the legacy theme key into the new settings object',
      () async {
        final deps = _Deps(
          storage: _InMemoryKeyValueStorage({
            legacySettingsStorageKey: jsonEncode({
              'theme': 'dark',
              'manageBuiltInDaemon': false,
              'releaseChannel': 'beta',
            }),
          }),
        );

        final result = await loadAppSettingsFromStorage(deps.deps);

        expect(
          result,
          defaultClientSettings.copyWith(theme: AppThemeName.dark),
        );
        expect(
          deps.storage.entries[appSettingsStorageKey],
          jsonEncode(result.toJson()),
        );
      },
    );

    test(
      'the legacy migration honours only its three original themes',
      () async {
        Future<AppThemeName> load(Object? theme) async {
          final deps = _Deps(
            storage: _InMemoryKeyValueStorage({
              legacySettingsStorageKey: jsonEncode({'theme': theme}),
            }),
          );
          return (await loadAppSettingsFromStorage(deps.deps)).theme;
        }

        expect(await load('light'), AppThemeName.light);
        expect(await load('auto'), AppThemeName.auto);
        expect(
          await load('ghostty'),
          AppThemeName.auto,
          reason:
              'ghostty postdates the legacy format, so it cannot be trusted',
        );
        expect(await load(7), AppThemeName.auto);
      },
    );

    test('the legacy migration drops every other legacy field', () async {
      final deps = _Deps(
        storage: _InMemoryKeyValueStorage({
          legacySettingsStorageKey: jsonEncode({
            'theme': 'dark',
            'language': 'ja',
            'uiFontSize': 20,
          }),
        }),
      );

      final result = await loadAppSettingsFromStorage(deps.deps);

      expect(result.language, AppLanguage.system);
      expect(result.uiFontSize, defaultUiFontSize);
    });

    test('a non-object legacy blob falls back to the plain defaults', () async {
      final deps = _Deps(
        storage: _InMemoryKeyValueStorage({legacySettingsStorageKey: 'null'}),
      );

      expect(
        await loadAppSettingsFromStorage(deps.deps),
        defaultClientSettings,
      );
    });

    test('loads a persisted explicit language', () async {
      final deps = _Deps(
        storage: _InMemoryKeyValueStorage({
          appSettingsStorageKey: jsonEncode({'language': 'zh-CN'}),
        }),
      );

      expect(
        (await loadAppSettingsFromStorage(deps.deps)).language,
        AppLanguage.of(SupportedLocale.zhCN),
      );
    });

    test('drops an unknown persisted language back to system', () async {
      final deps = _Deps(
        storage: _InMemoryKeyValueStorage({
          appSettingsStorageKey: jsonEncode({'language': 'klingon'}),
        }),
      );

      expect(
        (await loadAppSettingsFromStorage(deps.deps)).language,
        AppLanguage.system,
      );
    });

    test(
      'an empty stored blob is falsy and falls through to the legacy key',
      () async {
        final deps = _Deps(
          storage: _InMemoryKeyValueStorage({
            appSettingsStorageKey: '',
            legacySettingsStorageKey: jsonEncode({'theme': 'light'}),
          }),
        );

        expect(
          (await loadAppSettingsFromStorage(deps.deps)).theme,
          AppThemeName.light,
        );
      },
    );

    test(
      'an empty legacy blob falls through to seeding the defaults',
      () async {
        final deps = _Deps(
          storage: _InMemoryKeyValueStorage({
            appSettingsStorageKey: '',
            legacySettingsStorageKey: '',
          }),
        );

        expect(
          await loadAppSettingsFromStorage(deps.deps),
          defaultClientSettings,
        );
        expect(
          deps.storage.entries[appSettingsStorageKey],
          jsonEncode(defaultClientSettings.toJson()),
        );
      },
    );

    test(
      'reports and rethrows a malformed blob instead of resetting it',
      () async {
        final deps = _Deps(
          storage: _InMemoryKeyValueStorage({appSettingsStorageKey: '{oops'}),
        );

        await expectLater(
          loadAppSettingsFromStorage(deps.deps),
          throwsA(isA<FormatException>()),
        );
        expect(deps.loadErrors, hasLength(1));
        expect(
          deps.storage.entries[appSettingsStorageKey],
          '{oops',
          reason: 'the corrupt document must not be silently overwritten',
        );
      },
    );
  });

  group('loadSettingsFromStorage', () {
    test(
      'defaults built-in daemon management to enabled when storage is empty',
      () async {
        final deps = _Deps();

        expect(await loadSettingsFromStorage(deps.deps), defaultAppSettings);
      },
    );

    test('defaults release channel to stable when storage is empty', () async {
      final deps = _Deps();

      expect(
        (await loadSettingsFromStorage(deps.deps)).releaseChannel,
        ReleaseChannel.stable,
      );
    });

    test(
      'ignores renderer-owned daemon management state off desktop',
      () async {
        final deps = _Deps(
          storage: _InMemoryKeyValueStorage({
            appSettingsStorageKey: jsonEncode({
              'theme': 'light',
              'manageBuiltInDaemon': false,
            }),
          }),
        );

        expect(
          await loadSettingsFromStorage(deps.deps),
          defaultAppSettings.copyWith(
            app: defaultClientSettings.copyWith(theme: AppThemeName.light),
          ),
        );
      },
    );

    test('ignores a renderer-owned release channel off desktop', () async {
      final deps = _Deps(
        storage: _InMemoryKeyValueStorage({
          appSettingsStorageKey: jsonEncode({'releaseChannel': 'beta'}),
        }),
      );

      expect(
        (await loadSettingsFromStorage(deps.deps)).releaseChannel,
        ReleaseChannel.stable,
      );
    });

    test(
      'migrates legacy desktop-owned settings before reading effective settings',
      () async {
        final desktop = _FakeDesktopBridge(
          isDesktop: true,
          settings: const DesktopOwnedSettings(
            releaseChannel: ReleaseChannel.beta,
            daemon: DesktopDaemonSettings(
              manageBuiltInDaemon: false,
              keepRunningAfterQuit: true,
            ),
          ),
        );
        final deps = _Deps(
          storage: _InMemoryKeyValueStorage({
            appSettingsStorageKey: jsonEncode({
              'theme': 'light',
              'manageBuiltInDaemon': false,
              'releaseChannel': 'beta',
            }),
          }),
          desktop: desktop,
        );

        final result = await loadSettingsFromStorage(deps.deps);

        expect(desktop.migrationsApplied, [
          const LegacyDesktopSettingsMigration(
            manageBuiltInDaemon: false,
            releaseChannel: ReleaseChannel.beta,
          ),
        ]);
        expect(
          result,
          Settings(
            app: defaultClientSettings.copyWith(theme: AppThemeName.light),
            manageBuiltInDaemon: false,
            releaseChannel: ReleaseChannel.beta,
          ),
        );
      },
    );

    test('does not call the desktop bridge off desktop', () async {
      final desktop = _FakeDesktopBridge();
      final deps = _Deps(
        storage: _InMemoryKeyValueStorage({
          appSettingsStorageKey: jsonEncode({'theme': 'light'}),
        }),
        desktop: desktop,
      );

      final result = await loadSettingsFromStorage(deps.deps);

      expect(desktop.migrationsApplied, isEmpty);
      expect(
        result,
        defaultAppSettings.copyWith(
          app: defaultClientSettings.copyWith(theme: AppThemeName.light),
        ),
      );
    });

    test(
      'skips the migration when the blob carries no desktop-owned field',
      () async {
        final desktop = _FakeDesktopBridge(isDesktop: true);
        final deps = _Deps(
          storage: _InMemoryKeyValueStorage({
            appSettingsStorageKey: jsonEncode({'theme': 'light'}),
          }),
          desktop: desktop,
        );

        final result = await loadSettingsFromStorage(deps.deps);

        expect(desktop.migrationsApplied, isEmpty);
        expect(result.manageBuiltInDaemon, isTrue);
        expect(result.releaseChannel, ReleaseChannel.stable);
      },
    );

    test(
      'migrates from the legacy blob when the current one is absent',
      () async {
        final desktop = _FakeDesktopBridge(isDesktop: true);
        final deps = _Deps(
          storage: _InMemoryKeyValueStorage({
            legacySettingsStorageKey: jsonEncode({
              'theme': 'dark',
              'manageBuiltInDaemon': true,
            }),
          }),
          desktop: desktop,
        );

        final result = await loadSettingsFromStorage(deps.deps);

        expect(desktop.migrationsApplied, [
          const LegacyDesktopSettingsMigration(manageBuiltInDaemon: true),
        ]);
        expect(result.app.theme, AppThemeName.dark);
      },
    );
  });

  group('loadLegacyDesktopSettingsFromStorage', () {
    test('returns null when neither blob exists', () async {
      expect(
        await loadLegacyDesktopSettingsFromStorage(_InMemoryKeyValueStorage()),
        isNull,
      );
    });

    test('returns null for a non-object or empty blob', () async {
      expect(
        await loadLegacyDesktopSettingsFromStorage(
          _InMemoryKeyValueStorage({appSettingsStorageKey: '5'}),
        ),
        isNull,
      );
      expect(
        await loadLegacyDesktopSettingsFromStorage(
          _InMemoryKeyValueStorage({appSettingsStorageKey: 'null'}),
        ),
        isNull,
      );
      expect(
        await loadLegacyDesktopSettingsFromStorage(
          _InMemoryKeyValueStorage({
            appSettingsStorageKey: '',
            legacySettingsStorageKey: '',
          }),
        ),
        isNull,
      );
    });

    test('ignores fields of the wrong type or an unknown channel', () async {
      expect(
        await loadLegacyDesktopSettingsFromStorage(
          _InMemoryKeyValueStorage({
            appSettingsStorageKey: jsonEncode({
              'manageBuiltInDaemon': 'yes',
              'releaseChannel': 'nightly',
            }),
          }),
        ),
        isNull,
      );
    });

    test('lifts each field independently', () async {
      expect(
        await loadLegacyDesktopSettingsFromStorage(
          _InMemoryKeyValueStorage({
            appSettingsStorageKey: jsonEncode({'releaseChannel': 'stable'}),
          }),
        ),
        const LegacyDesktopSettingsMigration(
          releaseChannel: ReleaseChannel.stable,
        ),
      );
      expect(
        await loadLegacyDesktopSettingsFromStorage(
          _InMemoryKeyValueStorage({
            appSettingsStorageKey: jsonEncode({'manageBuiltInDaemon': false}),
          }),
        ),
        const LegacyDesktopSettingsMigration(manageBuiltInDaemon: false),
      );
    });

    test('prefers the current blob over the legacy one', () async {
      expect(
        await loadLegacyDesktopSettingsFromStorage(
          _InMemoryKeyValueStorage({
            appSettingsStorageKey: jsonEncode({'releaseChannel': 'stable'}),
            legacySettingsStorageKey: jsonEncode({'releaseChannel': 'beta'}),
          }),
        ),
        const LegacyDesktopSettingsMigration(
          releaseChannel: ReleaseChannel.stable,
        ),
      );
    });
  });

  group('saveAppSettings', () {
    test(
      'saves terminal scrollback through app settings persistence',
      () async {
        final deps = _Deps(
          storage: _InMemoryKeyValueStorage({
            appSettingsStorageKey: jsonEncode(defaultClientSettings.toJson()),
          }),
        );
        final cache = PaseoQueryCache();

        await saveAppSettings(
          cache: cache,
          updates: const AppSettingsUpdate(terminalScrollbackLines: 42000),
          deps: deps.deps,
        );

        expect(
          deps.storage.entries[appSettingsStorageKey],
          jsonEncode(
            defaultClientSettings
                .copyWith(terminalScrollbackLines: 42000)
                .toJson(),
          ),
        );
      },
    );

    test('normalizes a legacy cached settings shape before saving', () async {
      final deps = _Deps();
      final cache = PaseoQueryCache();
      cache.setQueryData(appSettingsQueryKey, <String, Object?>{
        'theme': 'dark',
        'compactToolCalls': true,
      });

      await saveAppSettings(
        cache: cache,
        updates: const AppSettingsUpdate(theme: AppThemeName.light),
        deps: deps.deps,
      );

      expect(
        jsonDecode(deps.storage.entries[appSettingsStorageKey]!),
        defaultClientSettings
            .copyWith(
              theme: AppThemeName.light,
              toolCallDetailLevel: ToolCallDetailLevel.overview,
            )
            .toJson(),
      );
    });

    test('mirrors the saved document into the cache', () async {
      final deps = _Deps();
      final cache = PaseoQueryCache();

      await saveAppSettings(
        cache: cache,
        updates: const AppSettingsUpdate(vimKeybindings: true),
        deps: deps.deps,
      );

      expect(
        cache.getQueryData(appSettingsQueryKey),
        defaultClientSettings.copyWith(vimKeybindings: true),
      );
    });

    test(
      'falls back to storage on a cache miss, seeding it on the way',
      () async {
        final deps = _Deps();
        final cache = PaseoQueryCache();

        await saveAppSettings(
          cache: cache,
          updates: const AppSettingsUpdate(uiFontSize: 20),
          deps: deps.deps,
        );

        expect(
          jsonDecode(deps.storage.entries[appSettingsStorageKey]!),
          defaultClientSettings.copyWith(uiFontSize: 20).toJson(),
        );
      },
    );

    test('round-trips a typed document already in the cache', () async {
      final deps = _Deps();
      final cache = PaseoQueryCache();
      cache.setQueryData(
        appSettingsQueryKey,
        defaultClientSettings.copyWith(
          language: AppLanguage.of(SupportedLocale.ja),
        ),
      );

      await saveAppSettings(
        cache: cache,
        updates: const AppSettingsUpdate(autoExpandReasoning: true),
        deps: deps.deps,
      );

      final saved = normalizeAppSettings(
        jsonDecode(deps.storage.entries[appSettingsStorageKey]!),
      );
      expect(saved.language, AppLanguage.of(SupportedLocale.ja));
      expect(saved.autoExpandReasoning, isTrue);
    });

    test('writes an update verbatim without re-clamping it', () async {
      final deps = _Deps();
      final cache = PaseoQueryCache();

      await saveAppSettings(
        cache: cache,
        updates: const AppSettingsUpdate(uiFontSize: 999),
        deps: deps.deps,
      );

      expect(
        jsonDecode(deps.storage.entries[appSettingsStorageKey]!)['uiFontSize'],
        999,
      );
      expect(
        normalizeAppSettings(
          jsonDecode(deps.storage.entries[appSettingsStorageKey]!),
        ).uiFontSize,
        maxUiFontSize,
        reason: 'the next load is what clamps it',
      );
    });
  });

  group('normalizeAppSettings', () {
    test('falls back to the defaults for a non-object', () {
      expect(normalizeAppSettings(null), defaultClientSettings);
      expect(normalizeAppSettings('nope'), defaultClientSettings);
      expect(normalizeAppSettings(7), defaultClientSettings);
      expect(normalizeAppSettings(const <Object?>[]), defaultClientSettings);
    });

    test('returns an already-typed document unchanged', () {
      final settings = defaultClientSettings.copyWith(uiFontSize: 20);

      expect(identical(normalizeAppSettings(settings), settings), isTrue);
    });

    test('accepts every shipped theme and rejects anything else', () {
      for (final theme in AppThemeName.values) {
        expect(
          normalizeAppSettings({'theme': theme.name}).theme,
          theme,
          reason: theme.name,
        );
      }
      expect(
        normalizeAppSettings(const {'theme': 'solaris'}).theme,
        AppThemeName.auto,
      );
      expect(normalizeAppSettings(const {'theme': 3}).theme, AppThemeName.auto);
    });

    test('accepts both send behaviours and rejects anything else', () {
      expect(
        normalizeAppSettings(const {'sendBehavior': 'queue'}).sendBehavior,
        SendBehavior.queue,
      );
      expect(
        normalizeAppSettings(const {'sendBehavior': 'interrupt'}).sendBehavior,
        SendBehavior.interrupt,
      );
      expect(
        normalizeAppSettings(const {'sendBehavior': 'defer'}).sendBehavior,
        SendBehavior.interrupt,
      );
    });

    test('accepts the hyphenated in-app service url behaviour', () {
      expect(
        normalizeAppSettings(const {
          'serviceUrlBehavior': 'in-app',
        }).serviceUrlBehavior,
        ServiceUrlBehavior.inApp,
      );
      expect(
        normalizeAppSettings(const {
          'serviceUrlBehavior': 'external',
        }).serviceUrlBehavior,
        ServiceUrlBehavior.external,
      );
      expect(
        normalizeAppSettings(const {
          'serviceUrlBehavior': 'inApp',
        }).serviceUrlBehavior,
        ServiceUrlBehavior.ask,
        reason: 'the Dart member name is not the persisted string',
      );
    });

    test('reads the boolean toggles only when they really are booleans', () {
      expect(
        normalizeAppSettings(const {'vimKeybindings': true}).vimKeybindings,
        isTrue,
      );
      expect(
        normalizeAppSettings(const {'vimKeybindings': 'true'}).vimKeybindings,
        isFalse,
      );
      expect(
        normalizeAppSettings(const {
          'autoExpandReasoning': true,
        }).autoExpandReasoning,
        isTrue,
      );
      expect(
        normalizeAppSettings(const {
          'autoExpandReasoning': 1,
        }).autoExpandReasoning,
        isFalse,
      );
    });

    test('keeps unrelated stored keys out of the result', () {
      final result = normalizeAppSettings(const {
        'theme': 'dark',
        'somethingElse': 'kept upstream? no',
      });

      expect(result.toJson().containsKey('somethingElse'), isFalse);
      expect(result, defaultClientSettings.copyWith(theme: AppThemeName.dark));
    });
  });

  group('appearance settings', () {
    Future<AppSettings> load(Map<String, Object?> stored) async {
      final deps = _Deps(
        storage: _InMemoryKeyValueStorage({
          appSettingsStorageKey: jsonEncode(stored),
        }),
      );
      return loadAppSettingsFromStorage(deps.deps);
    }

    test(
      'defaults the appearance fields when an old blob omits them',
      () async {
        final result = await load({'theme': 'dark'});

        expect(result.uiFontFamily, '');
        expect(result.monoFontFamily, '');
        expect(result.uiFontSize, defaultUiFontSize);
        expect(result.codeFontSize, defaultCodeFontSize);
        expect(result.syntaxTheme, SyntaxThemeId.one);
        expect(result.toolCallDetailLevel, ToolCallDetailLevel.detailed);
      },
    );

    test(
      'migrates the enabled compact tool call preference to overview',
      () async {
        expect(
          (await load({'compactToolCalls': true})).toolCallDetailLevel,
          ToolCallDetailLevel.overview,
        );
      },
    );

    test(
      'migrates the disabled compact tool call preference to detailed',
      () async {
        expect(
          (await load({'compactToolCalls': false})).toolCallDetailLevel,
          ToolCallDetailLevel.detailed,
        );
      },
    );

    test('maps an unrecognized tool call detail level to overview', () async {
      expect(
        (await load({'toolCallDetailLevel': 'unknown'})).toolCallDetailLevel,
        ToolCallDetailLevel.overview,
      );
      expect(
        (await load({'toolCallDetailLevel': 'concise'})).toolCallDetailLevel,
        ToolCallDetailLevel.overview,
        reason: 'the removed level lands on the closest survivor',
      );
    });

    test(
      'an explicit detail level wins over the legacy compact flag',
      () async {
        expect(
          (await load({
            'toolCallDetailLevel': 'detailed',
            'compactToolCalls': true,
          })).toolCallDetailLevel,
          ToolCallDetailLevel.detailed,
        );
      },
    );

    test('a non-boolean compact flag leaves the default in place', () async {
      expect(
        (await load({'compactToolCalls': 'yes'})).toolCallDetailLevel,
        ToolCallDetailLevel.detailed,
      );
    });

    test(
      'clamps the UI font size into range and rejects non-numeric values',
      () async {
        expect((await load({'uiFontSize': 999})).uiFontSize, 24);
        expect((await load({'uiFontSize': 8})).uiFontSize, 11);
        expect(
          (await load({'uiFontSize': 'abc'})).uiFontSize,
          defaultUiFontSize,
        );
      },
    );

    test(
      'clamps the code font size into range and rejects non-numeric values',
      () async {
        expect((await load({'codeFontSize': 999})).codeFontSize, 22);
        expect((await load({'codeFontSize': 8})).codeFontSize, 9);
        expect(
          (await load({'codeFontSize': 'abc'})).codeFontSize,
          defaultCodeFontSize,
        );
      },
    );

    test('trims an accepted font family', () async {
      expect((await load({'uiFontFamily': '  Menlo  '})).uiFontFamily, 'Menlo');
    });

    test(
      'keeps an explicit empty font family as the default sentinel',
      () async {
        expect((await load({'uiFontFamily': ''})).uiFontFamily, '');
      },
    );

    test('rejects a font family containing CSS-breaking characters', () async {
      expect((await load({'uiFontFamily': 'a;b{c}'})).uiFontFamily, '');
    });

    test('rejects an over-length font family', () async {
      expect((await load({'uiFontFamily': 'a' * 201})).uiFontFamily, '');
    });

    test('normalizes the mono font family on the same rules', () async {
      expect(
        (await load({'monoFontFamily': '  JetBrains Mono  '})).monoFontFamily,
        'JetBrains Mono',
      );
      expect((await load({'monoFontFamily': 'a<b'})).monoFontFamily, '');
    });

    test('accepts a known syntax theme id', () async {
      expect(
        (await load({'syntaxTheme': 'dracula'})).syntaxTheme,
        SyntaxThemeId.dracula,
      );
      expect(
        (await load({'syntaxTheme': 'tokyo-night'})).syntaxTheme,
        SyntaxThemeId.tokyoNight,
      );
    });

    test(
      'drops a removed or unknown syntax theme id back to the default',
      () async {
        expect(
          (await load({'syntaxTheme': 'auto'})).syntaxTheme,
          SyntaxThemeId.one,
        );
        expect(
          (await load({'syntaxTheme': 'bogus'})).syntaxTheme,
          SyntaxThemeId.one,
        );
        expect(
          (await load({'syntaxTheme': 'tokyoNight'})).syntaxTheme,
          SyntaxThemeId.one,
          reason: 'the persisted id is hyphenated, not camelCase',
        );
      },
    );
  });

  group('parseTerminalScrollbackLines', () {
    test(
      'clamps negative values to the minimum and rejects non-numeric strings',
      () {
        expect(parseTerminalScrollbackLines('-10'), 0);
        expect(parseTerminalScrollbackLines('abc'), isNull);
      },
    );

    test('clamps to the maximum and truncates toward negative infinity', () {
      expect(parseTerminalScrollbackLines(2000000), maxTerminalScrollbackLines);
      expect(parseTerminalScrollbackLines(42000.9), 42000);
      expect(parseTerminalScrollbackLines(-0.5), 0);
    });

    test('rejects everything that is not a number or numeric string', () {
      expect(parseTerminalScrollbackLines(null), isNull);
      expect(parseTerminalScrollbackLines(true), isNull);
      expect(parseTerminalScrollbackLines(''), isNull);
      expect(parseTerminalScrollbackLines('   '), isNull);
      expect(parseTerminalScrollbackLines(const <Object?>[]), isNull);
      expect(parseTerminalScrollbackLines(double.nan), isNull);
      expect(parseTerminalScrollbackLines(double.infinity), isNull);
      expect(parseTerminalScrollbackLines('Infinity'), isNull);
    });
  });

  group('parseClampedFontSize', () {
    test('clamps to the bounds and rejects non-numeric strings', () {
      expect(parseClampedFontSize(999, min: 11, max: 24), 24);
      expect(parseClampedFontSize(8, min: 11, max: 24), 11);
      expect(parseClampedFontSize('15', min: 11, max: 24), 15);
      expect(parseClampedFontSize('abc', min: 11, max: 24), isNull);
    });

    test('accepts the numeric string forms JavaScript Number() does', () {
      expect(parseClampedFontSize('  15  ', min: 11, max: 24), 15);
      expect(parseClampedFontSize('1.5e1', min: 11, max: 24), 15);
      expect(parseClampedFontSize('+15', min: 11, max: 24), 15);
      expect(parseClampedFontSize('15.', min: 11, max: 24), 15);
      expect(parseClampedFontSize('0x10', min: 11, max: 24), 16);
      expect(parseClampedFontSize('0b10000', min: 11, max: 24), 16);
      expect(parseClampedFontSize('0o20', min: 11, max: 24), 16);
      expect(
        parseClampedFontSize('-0x10', min: 11, max: 24),
        isNull,
        reason: 'Number("-0x10") is NaN',
      );
      expect(parseClampedFontSize('15px', min: 11, max: 24), isNull);
    });
  });

  group('sanitizeFontFamily', () {
    test('returns null for a non-string', () {
      expect(sanitizeFontFamily(null), isNull);
      expect(sanitizeFontFamily(16), isNull);
      expect(sanitizeFontFamily(true), isNull);
    });

    test('collapses a whitespace-only value to the default sentinel', () {
      expect(sanitizeFontFamily('   '), '');
      expect(sanitizeFontFamily(''), '');
    });

    test('keeps quotes and commas, which are legitimate in a stack', () {
      expect(
        sanitizeFontFamily('"JetBrains Mono", Menlo, monospace'),
        '"JetBrains Mono", Menlo, monospace',
      );
    });

    test('rejects each CSS-breaking character on its own', () {
      for (final char in [';', '{', '}', '<', '>']) {
        expect(sanitizeFontFamily('Menlo${char}x'), isNull, reason: char);
      }
    });

    test('rejects control characters anywhere in the stack', () {
      expect(sanitizeFontFamily('Men\u0000lo'), isNull);
      expect(sanitizeFontFamily('Men\u001Flo'), isNull);
      expect(
        sanitizeFontFamily('Men\tlo'),
        isNull,
        reason: 'a tab is below 0x1f too',
      );
    });

    test('accepts non-ASCII names and astral characters', () {
      expect(sanitizeFontFamily('나눔고딕'), '나눔고딕');
      expect(sanitizeFontFamily('Font \u{1F600}'), 'Font \u{1F600}');
    });

    test('accepts a stack of exactly the maximum length', () {
      expect(
        sanitizeFontFamily('a' * maxFontFamilyLength),
        'a' * maxFontFamilyLength,
      );
      expect(sanitizeFontFamily('a' * (maxFontFamilyLength + 1)), isNull);
    });

    test('measures length after trimming', () {
      final padded = '  ${'a' * maxFontFamilyLength}  ';
      expect(sanitizeFontFamily(padded), 'a' * maxFontFamilyLength);
    });
  });

  group('parseStoredToolCallDetailLevel', () {
    test('says nothing when the blob mentions neither key', () {
      expect(parseStoredToolCallDetailLevel(const {}), isNull);
    });

    test('treats an explicit null as present and unrecognised', () {
      expect(
        parseStoredToolCallDetailLevel(const {'toolCallDetailLevel': null}),
        ToolCallDetailLevel.overview,
      );
    });

    test('resolves both shipped levels', () {
      expect(
        parseStoredToolCallDetailLevel(const {
          'toolCallDetailLevel': 'overview',
        }),
        ToolCallDetailLevel.overview,
      );
      expect(
        parseStoredToolCallDetailLevel(const {
          'toolCallDetailLevel': 'detailed',
        }),
        ToolCallDetailLevel.detailed,
      );
    });
  });

  group('defaults', () {
    test('the client defaults are the frozen ones', () {
      expect(defaultClientSettings.theme, AppThemeName.auto);
      expect(defaultClientSettings.language, AppLanguage.system);
      expect(defaultClientSettings.sendBehavior, SendBehavior.interrupt);
      expect(defaultClientSettings.serviceUrlBehavior, ServiceUrlBehavior.ask);
      expect(
        defaultClientSettings.terminalScrollbackLines,
        defaultTerminalScrollbackLines,
      );
      expect(defaultClientSettings.syntaxTheme, SyntaxThemeId.one);
      expect(
        defaultClientSettings.workspaceTitleSource,
        WorkspaceTitleSource.title,
      );
      expect(defaultClientSettings.autoExpandReasoning, isFalse);
      expect(
        defaultClientSettings.toolCallDetailLevel,
        ToolCallDetailLevel.detailed,
      );
      expect(defaultClientSettings.vimKeybindings, isFalse);
    });

    test('the full defaults add the desktop-owned fields', () {
      expect(defaultAppSettings.app, defaultClientSettings);
      expect(defaultAppSettings.manageBuiltInDaemon, isTrue);
      expect(defaultAppSettings.releaseChannel, ReleaseChannel.stable);
    });

    test('the bounds are the frozen ones', () {
      expect(
        [minTerminalScrollbackLines, maxTerminalScrollbackLines],
        [0, 1000000],
      );
      expect([minUiFontSize, defaultUiFontSize, maxUiFontSize], [11, 16, 24]);
      expect(
        [minCodeFontSize, defaultCodeFontSize, maxCodeFontSize],
        [9, 12, 22],
      );
      expect(maxFontFamilyLength, 200);
    });

    test('the storage keys are the frozen ones', () {
      expect(appSettingsStorageKey, '@paseo:app-settings');
      expect(legacySettingsStorageKey, '@paseo:settings');
      expect(appSettingsQueryKey.segments, ['app-settings']);
      expect(archiveAgentPendingQueryKey.segments, ['archive-agent-pending']);
    });

    test('AppSettings equality covers every field', () {
      final variants = <AppSettings>[
        defaultClientSettings.copyWith(theme: AppThemeName.dark),
        defaultClientSettings.copyWith(
          language: AppLanguage.of(SupportedLocale.fr),
        ),
        defaultClientSettings.copyWith(sendBehavior: SendBehavior.queue),
        defaultClientSettings.copyWith(
          serviceUrlBehavior: ServiceUrlBehavior.external,
        ),
        defaultClientSettings.copyWith(terminalScrollbackLines: 1),
        defaultClientSettings.copyWith(uiFontFamily: 'Menlo'),
        defaultClientSettings.copyWith(monoFontFamily: 'Menlo'),
        defaultClientSettings.copyWith(uiFontSize: 20),
        defaultClientSettings.copyWith(codeFontSize: 20),
        defaultClientSettings.copyWith(syntaxTheme: SyntaxThemeId.nord),
        defaultClientSettings.copyWith(
          workspaceTitleSource: WorkspaceTitleSource.branch,
        ),
        defaultClientSettings.copyWith(autoExpandReasoning: true),
        defaultClientSettings.copyWith(
          toolCallDetailLevel: ToolCallDetailLevel.overview,
        ),
        defaultClientSettings.copyWith(vimKeybindings: true),
      ];

      for (final variant in variants) {
        expect(variant, isNot(defaultClientSettings), reason: '$variant');
      }
      expect(variants, hasLength(defaultClientSettings.toJson().length));
    });
  });
}
