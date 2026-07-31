/// Ports of two Paseo 0.2.0 modules that both hang off the same TanStack Query
/// cache and both own *persisted* truth the rest of the app reads:
///
/// - `hooks/use-archive-agent.ts` — archiving an agent is an optimistic
///   mutation: the row must vanish from every cached list the instant the user
///   clicks, and every one of those caches must come back byte-identical if the
///   daemon rejects the call. All of that lives in cache-shaped helpers rather
///   than in the React hook, which is why it ports at all.
/// - `hooks/use-settings/storage.ts` — the app settings document: one JSON blob
///   under `@paseo:app-settings`, a legacy blob to migrate from, and a
///   validator that decides which persisted values the current build still
///   honours.
///
/// Both are ported against injected seams. Nothing here reads the wall clock,
/// touches `SharedPreferences`, or knows what a widget is: the caller supplies
/// a [PaseoQueryCache], a [KeyValueStorage], an [ArchivableAgentStore], a
/// [DesktopSettingsBridge] and a `DateTime Function()`.
///
/// ## Reuse
///
/// The settings document's field types are *not* redeclared here where this
/// repo already ships them, because a second copy would be free to drift:
///
/// - `language` reuses [AppLanguage]/[parseAppLanguage] from
///   `lib/i18n/locales.dart` — the same parser `lib/state/language_provider.dart`
///   persists under `settings.language`, so an unshipped locale falls back to
///   `system` in exactly one place.
/// - `theme` reuses [AppThemeName] from `lib/state/appearance_provider.dart`,
///   whose members are exactly upstream's `ThemeName | "auto"`.
/// - `workspaceTitleSource` reuses [WorkspaceTitleSource] from
///   `lib/core/paseo_session_rules.dart`, which declared it locally while this
///   module was unported.
/// - `toolCallDetailLevel` reuses [ToolCallDetailLevel] from
///   `lib/tool_calls/detail_level/tool_call_projection.dart`.
///
/// ## Storage seam (deliberate, unreconciled)
///
/// Upstream keeps all fourteen client settings in ONE JSON blob. This repo
/// currently persists a subset as individual `SharedPreferences` keys —
/// `appearance.theme`, `settings.language`, `appearance.monoFontFamily`,
/// `appearance.codeFontSize`, `appearance.tool_call_detail_level` (+ legacy
/// `appearance.compact_tool_calls`). Those providers are untouched by this
/// port; reconciling the two representations is a separate change.
library;

import 'dart:convert';

import '../core/paseo_session_rules.dart' show WorkspaceTitleSource;
import '../i18n/locales.dart' show AppLanguage, parseAppLanguage;
import '../state/appearance_provider.dart' show AppThemeName;
import '../tool_calls/detail_level/tool_call_projection.dart'
    show ToolCallDetailLevel;

export '../core/paseo_session_rules.dart' show WorkspaceTitleSource;
export '../i18n/locales.dart' show AppLanguage;
export '../state/appearance_provider.dart' show AppThemeName;
export '../tool_calls/detail_level/tool_call_projection.dart'
    show ToolCallDetailLevel;

// ---------------------------------------------------------------------------
// TanStack Query cache stand-in
// ---------------------------------------------------------------------------

/// A TanStack Query cache key: the array upstream passes as `queryKey`.
///
/// Modelled as a value type so it can key a Dart [Map]. Upstream relies on
/// react-query's stable hash of the array; [hash] reproduces that with
/// [jsonEncode], which gives the same "structurally equal keys collide"
/// behaviour without pulling in a hashing dependency.
final class QueryKey {
  QueryKey(List<Object?> segments)
    : segments = List<Object?>.unmodifiable(segments);

  final List<Object?> segments;

  /// The stable string react-query would hash this key to.
  String get hash => jsonEncode(segments);

  /// Whether this key is matched by a *partial* filter key, which is how
  /// `invalidateQueries({ queryKey })` and `setQueriesData({ queryKey })`
  /// select queries: a filter is a prefix of the keys it matches.
  bool matchesPrefix(QueryKey prefix) {
    if (prefix.segments.length > segments.length) return false;
    for (var index = 0; index < prefix.segments.length; index += 1) {
      if (segments[index] != prefix.segments[index]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) => other is QueryKey && other.hash == hash;

  @override
  int get hashCode => hash.hashCode;

  @override
  String toString() => 'QueryKey($hash)';
}

/// One cached query as [PaseoQueryCache.getQueriesData] hands it back, standing
/// in for react-query's `[QueryKey, TData]` tuple.
final class KeyedQueryData {
  const KeyedQueryData({required this.key, required this.data});

  final QueryKey key;
  final Object? data;
}

final class _QueryCacheEntry {
  _QueryCacheEntry({required this.key, required this.data});

  final QueryKey key;
  Object? data;
  bool isInvalidated = false;
}

/// The slice of `QueryClient` these two modules actually use.
///
/// Ported as a concrete in-memory cache rather than an interface because the
/// *semantics* are the thing being ported, not the storage: in particular
/// react-query's rule that an updater returning `undefined` is a no-op, which
/// is what lets upstream write `setQueryData(key, (current) => transform(current))`
/// against keys that may not be cached at all and rely on absent staying absent.
///
/// Dart has no `undefined`, so `null` stands in for it. The observable
/// consequence is that a query genuinely holding JSON `null` cannot be
/// distinguished from an absent one — a distinction neither ported module makes.
final class PaseoQueryCache {
  final Map<String, _QueryCacheEntry> _entries = <String, _QueryCacheEntry>{};

  /// Every cached key, in insertion order — react-query's iteration order.
  Iterable<QueryKey> get keys =>
      _entries.values.map((entry) => entry.key).toList(growable: false);

  /// Whether a query exists at all, which upstream reads as
  /// `getQueryState(key) !== undefined`.
  bool hasQuery(QueryKey key) => _entries.containsKey(key.hash);

  /// `queryClient.getQueryData(key)`.
  Object? getQueryData(QueryKey key) => _entries[key.hash]?.data;

  /// `queryClient.getQueryState(key)?.isInvalidated` — null when the query has
  /// never been cached, matching the optional chain upstream's suite asserts on.
  bool? isQueryInvalidated(QueryKey key) => _entries[key.hash]?.isInvalidated;

  /// `queryClient.setQueryData(key, value)`.
  ///
  /// A null [value] is react-query's `undefined`: the cache is left exactly as
  /// it was, rather than the entry being created or cleared.
  void setQueryData(QueryKey key, Object? value) {
    if (value == null) return;
    final existing = _entries[key.hash];
    if (existing == null) {
      _entries[key.hash] = _QueryCacheEntry(key: key, data: value);
      return;
    }
    existing.data = value;
  }

  /// `queryClient.setQueryData(key, updater)` — the functional form. The
  /// updater sees null for an uncached query, exactly as upstream's `current`
  /// parameter sees `undefined`.
  void updateQueryData(
    QueryKey key,
    Object? Function(Object? current) updater,
  ) {
    setQueryData(key, updater(getQueryData(key)));
  }

  /// `queryClient.getQueriesData({ queryKey })` — every query whose key starts
  /// with [prefix].
  List<KeyedQueryData> getQueriesData(QueryKey prefix) => [
    for (final entry in _entries.values)
      if (entry.key.matchesPrefix(prefix))
        KeyedQueryData(key: entry.key, data: entry.data),
  ];

  /// `queryClient.setQueriesData({ queryKey }, updater)`.
  void setQueriesData(
    QueryKey prefix,
    Object? Function(Object? current) updater,
  ) {
    for (final match in getQueriesData(prefix)) {
      updateQueryData(match.key, updater);
    }
  }

  /// `queryClient.invalidateQueries({ queryKey })`.
  ///
  /// Only the invalidation flag is modelled. Upstream also triggers a refetch
  /// of active queries, which has no meaning without a mounted React tree; the
  /// flag is the part its suite observes.
  void invalidateQueries(QueryKey prefix) {
    for (final entry in _entries.values) {
      if (entry.key.matchesPrefix(prefix)) entry.isInvalidated = true;
    }
  }

  /// `queryClient.removeQueries({ queryKey, exact })`.
  void removeQueries(QueryKey key, {bool exact = true}) {
    if (exact) {
      _entries.remove(key.hash);
      return;
    }
    _entries.removeWhere((_, entry) => entry.key.matchesPrefix(key));
  }
}

// ---------------------------------------------------------------------------
// agent-history-query-key.ts
// ---------------------------------------------------------------------------

/// `["agentHistory", serverId]` — one server's archive history.
///
/// [serverId] is nullable because upstream's builder is called before a server
/// is selected, and `["agentHistory", null]` is a real (empty) cache slot.
QueryKey agentHistoryQueryKey(String? serverId) =>
    QueryKey(['agentHistory', serverId]);

/// The prefix every cross-server history query hangs off, so one
/// `invalidateQueries` reaches all of them regardless of which servers each was
/// built for.
QueryKey allAgentHistoryQueryRootKey() => QueryKey(const ['allAgentHistory']);

/// `["allAgentHistory", ...sortedServerIds]`.
///
/// Sorted so that two callers asking for the same set of servers in different
/// orders share one cache entry. Upstream sorts a *copy*; this does too, so the
/// caller's list is never mutated.
QueryKey allAgentHistoryQueryKey(List<String> serverIds) => QueryKey([
  'allAgentHistory',
  ...[...serverIds]..sort(),
]);

/// `["sidebarAgentsList", serverId]`.
QueryKey sidebarAgentsListQueryKey(String serverId) =>
    QueryKey(['sidebarAgentsList', serverId]);

/// `["allAgents", serverId]`.
QueryKey allAgentsQueryKey(String serverId) =>
    QueryKey(['allAgents', serverId]);

// ---------------------------------------------------------------------------
// use-archive-agent.ts
// ---------------------------------------------------------------------------

/// The cache slot the pending-archive map lives in.
///
/// Pending state is kept in the query cache rather than in component state so
/// that a sidebar row and a detail header spinner agree without either owning
/// the other — that shared-cache trick is the whole reason this is a query key
/// and not a `useState`.
final QueryKey archiveAgentPendingQueryKey = QueryKey(const [
  'archive-agent-pending',
]);

const Set<String> _emptyPendingArchiveAgentIds = <String>{};

/// Which agent, on which server, an archive helper is talking about.
final class ArchiveAgentInput {
  const ArchiveAgentInput({required this.serverId, required this.agentId});

  final String serverId;
  final String agentId;

  @override
  bool operator ==(Object other) =>
      other is ArchiveAgentInput &&
      other.serverId == serverId &&
      other.agentId == agentId;

  @override
  int get hashCode => Object.hash(serverId, agentId);

  @override
  String toString() =>
      'ArchiveAgentInput(serverId: $serverId, agentId: $agentId)';
}

/// The composite cache key for one in-flight archive, or `""` when either half
/// is blank.
///
/// The empty string is upstream's sentinel for "not addressable", and every
/// caller checks it before touching the cache — blank ids must never collide
/// into a single `":"` bucket that would make two unrelated agents look like
/// one another's pending state.
String toArchiveKey(ArchiveAgentInput input) {
  final serverId = input.serverId.trim();
  final agentId = input.agentId.trim();
  if (serverId.isEmpty || agentId.isEmpty) return '';
  return '$serverId:$agentId';
}

/// The pending-archive map as currently cached, defaulting to empty.
///
/// Upstream's `Record<string, true>` only ever holds `true`; deleting is how a
/// key becomes false. Ported as `Map<String, bool>` because Dart cannot express
/// a literal-true value type, and read through [isAgentArchiving] so a
/// hand-written `false` still reads as not-archiving.
Map<String, bool> readPendingState(PaseoQueryCache cache) {
  final stored = cache.getQueryData(archiveAgentPendingQueryKey);
  if (stored is! Map) return <String, bool>{};
  return <String, bool>{
    for (final entry in stored.entries)
      if (entry.key is String && entry.value is bool)
        entry.key as String: entry.value as bool,
  };
}

/// The agent ids currently being archived on one server.
///
/// Returns a shared empty set when there is nothing pending so that a caller
/// comparing identity across rebuilds sees no change — upstream's reason for
/// `EMPTY_PENDING_ARCHIVE_AGENT_IDS` — and preserves the map's key order
/// otherwise.
Set<String> selectPendingArchiveAgentIds(
  Map<String, bool> pendingState,
  String serverId,
) {
  final normalizedServerId = serverId.trim();
  if (normalizedServerId.isEmpty) return _emptyPendingArchiveAgentIds;

  final prefix = '$normalizedServerId:';
  List<String>? agentIds;
  for (final key in pendingState.keys) {
    if (!key.startsWith(prefix)) continue;
    final agentId = key.substring(prefix.length);
    if (agentId.isEmpty) continue;
    (agentIds ??= <String>[]).add(agentId);
  }

  if (agentIds == null || agentIds.isEmpty) {
    return _emptyPendingArchiveAgentIds;
  }
  return <String>{...agentIds};
}

/// Marks one agent as archiving, or clears the mark.
///
/// Writes a *new* map only when the value actually changes, so subscribers do
/// not rebuild on a redundant set. A blank id is dropped silently rather than
/// poisoning the map with a `":"`-shaped key.
void setAgentArchiving({
  required PaseoQueryCache cache,
  required String serverId,
  required String agentId,
  required bool isArchiving,
}) {
  final key = toArchiveKey(
    ArchiveAgentInput(serverId: serverId, agentId: agentId),
  );
  if (key.isEmpty) return;

  cache.updateQueryData(archiveAgentPendingQueryKey, (current) {
    // The cached map is reused *by identity* when nothing changes, which is
    // what upstream relies on to avoid notifying subscribers about a no-op.
    final state = current is Map ? current : const <String, Object?>{};
    if (isArchiving) {
      if (state[key] == true) return state;
      return <String, Object?>{..._asStringKeyedMap(state), key: true};
    }

    if (state[key] != true) return state;

    return <String, Object?>{..._asStringKeyedMap(state)}..remove(key);
  });
}

/// Whether an archive request is currently in flight for this agent.
bool isAgentArchiving({
  required PaseoQueryCache cache,
  required String serverId,
  required String agentId,
}) {
  final key = toArchiveKey(
    ArchiveAgentInput(serverId: serverId, agentId: agentId),
  );
  if (key.isEmpty) return false;
  return readPendingState(cache)[key] ?? false;
}

/// Clears the pending mark, whatever the outcome of the request was.
void clearArchiveAgentPending({
  required PaseoQueryCache cache,
  required String serverId,
  required String agentId,
}) {
  setAgentArchiving(
    cache: cache,
    serverId: serverId,
    agentId: agentId,
    isArchiving: false,
  );
}

/// Drops one agent from a cached `{ entries: [{ agent: { id } }] }` payload.
///
/// Returns the payload *unchanged and identical* when nothing matched, which is
/// how upstream keeps react-query from notifying subscribers about a no-op. All
/// sibling keys (`pageInfo`, cursors) survive the rewrite.
///
/// Typed against `Object?` rather than a ported payload class because the cache
/// is `unknown` upstream too: a payload that is not an object, or whose
/// `entries` is not a list, passes straight through instead of throwing.
Object? removeAgentFromListPayload(Object? payload, String agentId) {
  if (payload is! Map) return payload;
  final entries = payload['entries'];
  if (entries is! List || agentId.isEmpty) return payload;

  final filtered = [
    for (final entry in entries)
      if (_listEntryAgentId(entry) != agentId) entry,
  ];
  if (filtered.length == entries.length) return payload;

  return <String, Object?>{..._asStringKeyedMap(payload), 'entries': filtered};
}

String? _listEntryAgentId(Object? entry) {
  if (entry is! Map) return null;
  final agent = entry['agent'];
  if (agent is! Map) return null;
  final id = agent['id'];
  return id is String ? id : null;
}

Map<String, Object?> _asStringKeyedMap(Map<Object?, Object?> value) => {
  for (final entry in value.entries)
    if (entry.key is String) entry.key! as String: entry.value,
};

/// Removes an archived agent from both cached agent lists at once.
///
/// Sidebar and "all agents" are separate cache slots fed by separate queries;
/// archiving has to reach both or the row lingers in whichever view the user is
/// not looking at.
void removeAgentFromCachedLists(
  PaseoQueryCache cache,
  ArchiveAgentInput input,
) {
  final agentId = input.agentId.trim();
  if (agentId.isEmpty) return;

  cache.updateQueryData(
    sidebarAgentsListQueryKey(input.serverId),
    (current) => removeAgentFromListPayload(current, agentId),
  );
  cache.updateQueryData(
    allAgentsQueryKey(input.serverId),
    (current) => removeAgentFromListPayload(current, agentId),
  );
}

/// Stamps `archivedAt` onto one agent inside a cached infinite-query payload.
///
/// The history view *keeps* archived agents — it is the archive — so unlike the
/// lists this rewrites in place rather than filtering. An entry that carries a
/// `serverId` must match; one that omits it is assumed to belong to the server
/// being addressed, which is what lets the single-server history payload (whose
/// rows have no `serverId`) share this function with the cross-server one.
///
/// An unparseable [archivedAt] leaves the payload untouched rather than writing
/// an invalid date into the cache.
Object? markAgentArchivedInHistoryPayload(
  Object? payload, {
  required String serverId,
  required String agentId,
  required String archivedAt,
}) {
  if (payload is! Map) return payload;
  final pages = payload['pages'];
  if (pages is! List || agentId.isEmpty) return payload;

  final parsedArchivedAt = DateTime.tryParse(archivedAt);
  if (parsedArchivedAt == null) return payload;

  var changed = false;
  final nextPages = [
    for (final page in pages)
      _markAgentArchivedInHistoryPage(
        page,
        serverId: serverId,
        agentId: agentId,
        archivedAt: parsedArchivedAt,
        onChanged: () => changed = true,
      ),
  ];

  if (!changed) return payload;
  return <String, Object?>{..._asStringKeyedMap(payload), 'pages': nextPages};
}

Object? _markAgentArchivedInHistoryPage(
  Object? page, {
  required String serverId,
  required String agentId,
  required DateTime archivedAt,
  required void Function() onChanged,
}) {
  // DEVIATION: upstream types `page` as an object and would throw a TypeError
  // on `page.agents` if a page were null. A non-object page is returned
  // unchanged here instead — the cache is only ever written by the query
  // itself, so the throw is unreachable rather than meaningful.
  if (page is! Map) return page;
  final agents = page['agents'];
  if (agents is! List) return page;

  var pageChanged = false;
  final nextAgents = <Object?>[];
  for (final agent in agents) {
    if (agent is Map &&
        _shouldArchiveHistoryAgent(
          agent,
          serverId: serverId,
          agentId: agentId,
        )) {
      pageChanged = true;
      onChanged();
      nextAgents.add(<String, Object?>{
        ..._asStringKeyedMap(agent),
        'archivedAt': archivedAt,
      });
      continue;
    }
    nextAgents.add(agent);
  }

  if (!pageChanged) return page;
  return <String, Object?>{..._asStringKeyedMap(page), 'agents': nextAgents};
}

bool _shouldArchiveHistoryAgent(
  Object? agent, {
  required String serverId,
  required String agentId,
}) {
  if (agent is! Map) return false;
  if (agent['id'] != agentId) return false;
  final agentServerId = agent['serverId'];
  // `!= null` is upstream's nullish check: an entry with no serverId at all
  // (the single-server payload shape) is not filtered out by it.
  if (agentServerId != null && agentServerId != serverId) return false;
  return true;
}

/// Applies [markAgentArchivedInHistoryPayload] to the single-server history and
/// to every cross-server history currently cached.
void markAgentArchivedInHistoryCache(
  PaseoQueryCache cache, {
  required String serverId,
  required String agentId,
  required String archivedAt,
}) {
  cache.updateQueryData(
    agentHistoryQueryKey(serverId),
    (current) => markAgentArchivedInHistoryPayload(
      current,
      serverId: serverId,
      agentId: agentId,
      archivedAt: archivedAt,
    ),
  );
  cache.setQueriesData(
    allAgentHistoryQueryRootKey(),
    (current) => markAgentArchivedInHistoryPayload(
      current,
      serverId: serverId,
      agentId: agentId,
      archivedAt: archivedAt,
    ),
  );
}

/// One agent the daemon reported as archived, as the close/archive response
/// carries it.
final class ArchivedAgentCloseResult {
  const ArchivedAgentCloseResult({
    required this.agentId,
    required this.archivedAt,
  });

  final String agentId;

  /// ISO-8601 as the daemon sent it; parsed, never re-formatted.
  final String archivedAt;

  @override
  bool operator ==(Object other) =>
      other is ArchivedAgentCloseResult &&
      other.agentId == agentId &&
      other.archivedAt == archivedAt;

  @override
  int get hashCode => Object.hash(agentId, archivedAt);

  @override
  String toString() =>
      'ArchivedAgentCloseResult(agentId: $agentId, archivedAt: $archivedAt)';
}

/// One agent as the session store holds it.
///
/// Upstream spreads the store's `Agent` interface (`{ ...existing, archivedAt }`)
/// and that interface is not ported, so the record is kept opaque: only
/// `archivedAt` is interpreted, every other field rides along untouched. The
/// class uses *identity* equality on purpose — upstream's rollback compares
/// `current === input.agent`, and a value-equal-but-different snapshot must
/// still count as a change.
final class ArchivableAgent {
  ArchivableAgent(Map<String, Object?> fields)
    : fields = Map<String, Object?>.unmodifiable(fields);

  final Map<String, Object?> fields;

  DateTime? get archivedAt {
    final value = fields['archivedAt'];
    return value is DateTime ? value : null;
  }

  ArchivableAgent copyWithArchivedAt(DateTime archivedAt) =>
      ArchivableAgent({...fields, 'archivedAt': archivedAt});

  @override
  String toString() => 'ArchivableAgent($fields)';
}

/// The session store's agent map, as the archive path needs it.
///
/// Upstream reaches for the `useSessionStore` singleton; injecting it keeps
/// this file free of global state and lets the suite drive rollback exactly.
abstract interface class ArchivableAgentStore {
  /// The agents for a server, or null when there is no session for it —
  /// upstream's `sessions[serverId]?.agents`.
  Map<String, ArchivableAgent>? agentsFor(String serverId);

  /// `setAgents(serverId, updater)`. An updater that returns the map it was
  /// given signals "nothing changed"; implementations should treat that as a
  /// no-op the way zustand's referential check does.
  void setAgents(
    String serverId,
    Map<String, ArchivableAgent> Function(Map<String, ArchivableAgent> previous)
    update,
  );
}

/// The agent as the store currently holds it, or null.
///
/// Captured *before* the optimistic write so [restoreAgentSnapshot] can put
/// exactly that object back — including the case where the agent was not in the
/// store at all, which must roll back to "absent" rather than to a default.
ArchivableAgent? getStoredAgentSnapshot(
  ArchivableAgentStore store,
  ArchiveAgentInput input,
) => store.agentsFor(input.serverId)?[input.agentId];

/// Puts a captured [agent] back, or removes the entry when the snapshot was null.
void restoreAgentSnapshot(
  ArchivableAgentStore store, {
  required String serverId,
  required String agentId,
  required ArchivableAgent? agent,
}) {
  store.setAgents(serverId, (previous) {
    final hasAgent = previous.containsKey(agentId);
    if (agent == null) {
      if (!hasAgent) return previous;
      return <String, ArchivableAgent>{...previous}..remove(agentId);
    }

    // Identity, not value: the same object back means nothing to do.
    if (identical(previous[agentId], agent)) return previous;

    return <String, ArchivableAgent>{...previous, agentId: agent};
  });
}

/// Stamps `archivedAt` onto the stored agent.
///
/// Skips the write when the timestamp is unparseable, when the agent is gone,
/// or when the stored timestamp already matches to the millisecond — the last
/// is what stops the optimistic write and the server's confirmation from
/// producing two rebuilds for one archive.
void markAgentArchivedInStore(
  ArchivableAgentStore store, {
  required String serverId,
  required String agentId,
  required String archivedAt,
}) {
  final parsedArchivedAt = DateTime.tryParse(archivedAt);
  if (parsedArchivedAt == null) return;

  store.setAgents(serverId, (previous) {
    final existing = previous[agentId];
    if (existing == null) return previous;
    final existingArchivedAt = existing.archivedAt;
    if (existingArchivedAt != null &&
        existingArchivedAt.millisecondsSinceEpoch ==
            parsedArchivedAt.millisecondsSinceEpoch) {
      return previous;
    }
    return <String, ArchivableAgent>{
      ...previous,
      agentId: existing.copyWithArchivedAt(parsedArchivedAt),
    };
  });
}

/// Everything the optimistic archive has to be able to undo.
final class ArchivedAgentListCacheSnapshot {
  const ArchivedAgentListCacheSnapshot({
    required this.sidebarAgentsList,
    required this.allAgents,
    required this.agentHistory,
    required this.allAgentHistory,
  });

  final Object? sidebarAgentsList;
  final Object? allAgents;
  final Object? agentHistory;
  final List<KeyedQueryData> allAgentHistory;
}

/// Captures every cache slot the archive is about to rewrite.
///
/// The cross-server histories are captured by enumeration rather than by a
/// fixed key because their keys embed whichever server set the caller asked
/// for, and a rollback has to restore all of them.
ArchivedAgentListCacheSnapshot captureArchivedAgentListCacheSnapshot(
  PaseoQueryCache cache,
  String serverId,
) => ArchivedAgentListCacheSnapshot(
  sidebarAgentsList: cache.getQueryData(sidebarAgentsListQueryKey(serverId)),
  allAgents: cache.getQueryData(allAgentsQueryKey(serverId)),
  agentHistory: cache.getQueryData(agentHistoryQueryKey(serverId)),
  allAgentHistory: cache.getQueriesData(allAgentHistoryQueryRootKey()),
);

/// Restores a captured snapshot, *removing* slots that were empty when captured
/// instead of writing null into them — otherwise a failed archive would leave
/// behind a cached empty payload that the query would then trust.
void restoreArchivedAgentListCacheSnapshot(
  PaseoQueryCache cache,
  String serverId,
  ArchivedAgentListCacheSnapshot snapshot,
) {
  _restoreCachedQuerySnapshot(
    cache,
    sidebarAgentsListQueryKey(serverId),
    snapshot.sidebarAgentsList,
  );
  _restoreCachedQuerySnapshot(
    cache,
    allAgentsQueryKey(serverId),
    snapshot.allAgents,
  );
  _restoreCachedQuerySnapshot(
    cache,
    agentHistoryQueryKey(serverId),
    snapshot.agentHistory,
  );
  for (final entry in snapshot.allAgentHistory) {
    _restoreCachedQuerySnapshot(cache, entry.key, entry.data);
  }
}

void _restoreCachedQuerySnapshot(
  PaseoQueryCache cache,
  QueryKey key,
  Object? snapshot,
) {
  if (snapshot == null) {
    cache.removeQueries(key);
    return;
  }
  cache.setQueryData(key, snapshot);
}

/// Applies a batch of archive results to the session store and every cache that
/// shows agents.
///
/// [invalidateQueries] defaults to true — the normal path, where the server has
/// spoken and a refetch should follow. The optimistic path passes false so the
/// local rewrite is not immediately raced by a refetch that has not yet learned
/// about the archive.
///
/// Returns early on an empty batch so that "nothing archived" never triggers
/// four invalidations.
void applyArchivedAgentCloseResults({
  required PaseoQueryCache cache,
  required ArchivableAgentStore store,
  required String serverId,
  required List<ArchivedAgentCloseResult> results,
  bool invalidateQueries = true,
}) {
  if (results.isEmpty) return;

  for (final result in results) {
    markAgentArchivedInStore(
      store,
      serverId: serverId,
      agentId: result.agentId,
      archivedAt: result.archivedAt,
    );
    removeAgentFromCachedLists(
      cache,
      ArchiveAgentInput(serverId: serverId, agentId: result.agentId),
    );
    markAgentArchivedInHistoryCache(
      cache,
      serverId: serverId,
      agentId: result.agentId,
      archivedAt: result.archivedAt,
    );
  }

  if (invalidateQueries) {
    cache.invalidateQueries(sidebarAgentsListQueryKey(serverId));
    cache.invalidateQueries(allAgentsQueryKey(serverId));
    cache.invalidateQueries(agentHistoryQueryKey(serverId));
    cache.invalidateQueries(allAgentHistoryQueryRootKey());
  }
}

/// The daemon call the archive mutation makes.
///
/// Upstream pulls the client off the session store inside `mutationFn` and
/// throws a translated error when there is none; the two halves are split here
/// so the "no client" branch stays testable without a fake transport.
abstract interface class ArchiveAgentGateway {
  /// Whether a connected daemon client exists for this server.
  bool hasClient(String serverId);

  /// `client.archiveAgent(agentId)`, resolving to the server's ISO-8601
  /// `archivedAt`.
  Future<String> archiveAgent({
    required String serverId,
    required String agentId,
  });
}

/// Thrown in place of upstream's `new Error(t("common.errors.daemonClientUnavailable"))`.
///
/// Carries the already-translated message rather than the key, because the
/// controller is not the layer that owns translation lookup.
final class ArchiveAgentUnavailableException implements Exception {
  const ArchiveAgentUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// `useArchiveAgent`, minus React.
///
/// The hook's value is its *ordering* — snapshot, optimistic write, request,
/// confirm-or-roll-back, then always clear pending and invalidate — so that is
/// what is ported. The mutation lifecycle maps directly: `onMutate` and
/// `onSettled` run unconditionally, `onSuccess` and `onError` are exclusive,
/// and the caller still sees the failure because `mutateAsync` rejects.
final class ArchiveAgentController {
  ArchiveAgentController({
    required this.cache,
    required this.store,
    required this.gateway,
    required this.now,
    required this.daemonClientUnavailableMessage,
  });

  final PaseoQueryCache cache;
  final ArchivableAgentStore store;
  final ArchiveAgentGateway gateway;

  /// Injected clock. Upstream calls `new Date()` inside `onMutate`; the
  /// optimistic timestamp has to be reproducible for the suite.
  final DateTime Function() now;

  /// The translated `common.errors.daemonClientUnavailable` string.
  final String daemonClientUnavailableMessage;

  /// Whether this agent is mid-archive, read straight from the shared cache.
  bool isArchivingAgent(ArchiveAgentInput input) {
    final key = toArchiveKey(input);
    if (key.isEmpty) return false;
    return readPendingState(cache)[key] ?? false;
  }

  /// The agents on one server that are mid-archive.
  Set<String> pendingArchiveAgentIds(String serverId) =>
      selectPendingArchiveAgentIds(readPendingState(cache), serverId);

  /// Archives an agent optimistically, rolling every cache back if the daemon
  /// refuses. Rethrows whatever the gateway threw, after the rollback.
  Future<void> archiveAgent(ArchiveAgentInput input) async {
    final agentSnapshot = getStoredAgentSnapshot(store, input);
    final listSnapshot = captureArchivedAgentListCacheSnapshot(
      cache,
      input.serverId,
    );
    final optimisticArchivedAt = toJsIsoString(now());

    applyArchivedAgentCloseResults(
      cache: cache,
      store: store,
      serverId: input.serverId,
      results: [
        ArchivedAgentCloseResult(
          agentId: input.agentId,
          archivedAt: optimisticArchivedAt,
        ),
      ],
      invalidateQueries: false,
    );
    setAgentArchiving(
      cache: cache,
      serverId: input.serverId,
      agentId: input.agentId,
      isArchiving: true,
    );

    try {
      if (!gateway.hasClient(input.serverId)) {
        throw ArchiveAgentUnavailableException(daemonClientUnavailableMessage);
      }
      final archivedAt = await gateway.archiveAgent(
        serverId: input.serverId,
        agentId: input.agentId,
      );
      markAgentArchivedInStore(
        store,
        serverId: input.serverId,
        agentId: input.agentId,
        archivedAt: archivedAt,
      );
    } catch (_) {
      restoreAgentSnapshot(
        store,
        serverId: input.serverId,
        agentId: input.agentId,
        agent: agentSnapshot,
      );
      restoreArchivedAgentListCacheSnapshot(
        cache,
        input.serverId,
        listSnapshot,
      );
      rethrow;
    } finally {
      clearArchiveAgentPending(
        cache: cache,
        serverId: input.serverId,
        agentId: input.agentId,
      );
      cache.invalidateQueries(sidebarAgentsListQueryKey(input.serverId));
      cache.invalidateQueries(allAgentsQueryKey(input.serverId));
      cache.invalidateQueries(agentHistoryQueryKey(input.serverId));
      cache.invalidateQueries(allAgentHistoryQueryRootKey());
    }
  }
}

/// `Date.prototype.toISOString()`.
///
/// Dart's `toIso8601String` emits microseconds when it has them; JavaScript's
/// `Date` has no sub-millisecond precision at all, so the value is truncated to
/// milliseconds first. That keeps timestamps this app writes byte-identical to
/// the ones a Paseo client writes, which matters because they end up compared
/// as strings on the wire.
String toJsIsoString(DateTime value) => DateTime.fromMillisecondsSinceEpoch(
  value.toUtc().millisecondsSinceEpoch,
  isUtc: true,
).toIso8601String();

// ---------------------------------------------------------------------------
// use-settings/storage.ts
// ---------------------------------------------------------------------------

/// Where the settings document lives.
const String appSettingsStorageKey = '@paseo:app-settings';

/// The pre-v0.1 blob, read once and rewritten into [appSettingsStorageKey].
const String legacySettingsStorageKey = '@paseo:settings';

/// The cache slot the settings document is mirrored into, so that a save can
/// merge onto what the UI is already showing without a storage round-trip.
final QueryKey appSettingsQueryKey = QueryKey(const ['app-settings']);

/// What pressing Enter does while the agent is busy.
enum SendBehavior { interrupt, queue }

/// Which build stream desktop updates come from.
enum ReleaseChannel { stable, beta }

/// What happens when the user taps a URL a service produced.
enum ServiceUrlBehavior {
  ask('ask'),
  inApp('in-app'),
  external('external');

  const ServiceUrlBehavior(this.wireValue);

  /// The persisted string, which is not always the Dart member name.
  final String wireValue;

  static ServiceUrlBehavior? fromWire(String value) {
    for (final behavior in values) {
      if (behavior.wireValue == value) return behavior;
    }
    return null;
  }
}

/// The syntax highlighting palettes this build ships.
///
/// Ported from `@getpaseo/highlight`'s `SYNTAX_THEME_IDS`, which this repo does
/// not have a Dart equivalent of yet. The ids are the frozen persisted strings.
enum SyntaxThemeId {
  github('github'),
  catppuccin('catppuccin'),
  dracula('dracula'),
  tokyoNight('tokyo-night'),
  one('one'),
  nord('nord'),
  gruvbox('gruvbox'),
  solarized('solarized');

  const SyntaxThemeId(this.wireValue);

  final String wireValue;

  static SyntaxThemeId? fromWire(String value) {
    for (final theme in values) {
      if (theme.wireValue == value) return theme;
    }
    return null;
  }
}

/// Terminal scrollback default and bounds, in lines.
const int defaultTerminalScrollbackLines = 10000;
const int minTerminalScrollbackLines = 0;
const int maxTerminalScrollbackLines = 1000000;

/// UI font size default and bounds, in logical pixels.
const int defaultUiFontSize = 16;
const int minUiFontSize = 11;
const int maxUiFontSize = 24;

/// Code font size default and bounds. The maximum is 22 because a 1.5 line
/// height on 22px still fits the rows the diff viewer lays out.
const int defaultCodeFontSize = 12;
const int minCodeFontSize = 9;
const int maxCodeFontSize = 22;

/// Longest font-family stack that will be honoured, so a corrupted preference
/// cannot inflate every style computation.
const int maxFontFamilyLength = 200;

/// The settings every client shares, regardless of platform.
///
/// Every field is non-nullable with a default: a missing or invalid persisted
/// value falls back rather than leaving a hole, which is what lets the UI read
/// settings without null checks anywhere.
final class AppSettings {
  const AppSettings({
    required this.theme,
    required this.language,
    required this.sendBehavior,
    required this.serviceUrlBehavior,
    required this.terminalScrollbackLines,
    required this.uiFontFamily,
    required this.monoFontFamily,
    required this.uiFontSize,
    required this.codeFontSize,
    required this.syntaxTheme,
    required this.workspaceTitleSource,
    required this.autoExpandReasoning,
    required this.toolCallDetailLevel,
    required this.vimKeybindings,
  });

  final AppThemeName theme;
  final AppLanguage language;
  final SendBehavior sendBehavior;
  final ServiceUrlBehavior serviceUrlBehavior;
  final int terminalScrollbackLines;

  /// `""` means "use the platform's default UI stack" — a real value, not a
  /// missing one, which is why [sanitizeFontFamily] returns it rather than null.
  final String uiFontFamily;

  /// `""` means "use the platform's default monospace stack".
  final String monoFontFamily;

  final int uiFontSize;
  final int codeFontSize;
  final SyntaxThemeId syntaxTheme;
  final WorkspaceTitleSource workspaceTitleSource;
  final bool autoExpandReasoning;
  final ToolCallDetailLevel toolCallDetailLevel;
  final bool vimKeybindings;

  /// The persisted shape.
  ///
  /// Key order is load-bearing: upstream persists `JSON.stringify` of an object
  /// built by spreading the defaults, so the serialized bytes follow the
  /// declaration order of [defaultClientSettings]. This map reproduces that
  /// order exactly, which keeps a document written by this app byte-identical
  /// to one written by Paseo.
  Map<String, Object?> toJson() => <String, Object?>{
    'theme': theme.name,
    'language': language.code,
    'sendBehavior': sendBehavior.name,
    'serviceUrlBehavior': serviceUrlBehavior.wireValue,
    'terminalScrollbackLines': terminalScrollbackLines,
    'uiFontFamily': uiFontFamily,
    'monoFontFamily': monoFontFamily,
    'uiFontSize': uiFontSize,
    'codeFontSize': codeFontSize,
    'syntaxTheme': syntaxTheme.wireValue,
    'workspaceTitleSource': workspaceTitleSource.name,
    'autoExpandReasoning': autoExpandReasoning,
    'toolCallDetailLevel': toolCallDetailLevel.name,
    'vimKeybindings': vimKeybindings,
  };

  AppSettings copyWith({
    AppThemeName? theme,
    AppLanguage? language,
    SendBehavior? sendBehavior,
    ServiceUrlBehavior? serviceUrlBehavior,
    int? terminalScrollbackLines,
    String? uiFontFamily,
    String? monoFontFamily,
    int? uiFontSize,
    int? codeFontSize,
    SyntaxThemeId? syntaxTheme,
    WorkspaceTitleSource? workspaceTitleSource,
    bool? autoExpandReasoning,
    ToolCallDetailLevel? toolCallDetailLevel,
    bool? vimKeybindings,
  }) => AppSettings(
    theme: theme ?? this.theme,
    language: language ?? this.language,
    sendBehavior: sendBehavior ?? this.sendBehavior,
    serviceUrlBehavior: serviceUrlBehavior ?? this.serviceUrlBehavior,
    terminalScrollbackLines:
        terminalScrollbackLines ?? this.terminalScrollbackLines,
    uiFontFamily: uiFontFamily ?? this.uiFontFamily,
    monoFontFamily: monoFontFamily ?? this.monoFontFamily,
    uiFontSize: uiFontSize ?? this.uiFontSize,
    codeFontSize: codeFontSize ?? this.codeFontSize,
    syntaxTheme: syntaxTheme ?? this.syntaxTheme,
    workspaceTitleSource: workspaceTitleSource ?? this.workspaceTitleSource,
    autoExpandReasoning: autoExpandReasoning ?? this.autoExpandReasoning,
    toolCallDetailLevel: toolCallDetailLevel ?? this.toolCallDetailLevel,
    vimKeybindings: vimKeybindings ?? this.vimKeybindings,
  );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.theme == theme &&
      other.language == language &&
      other.sendBehavior == sendBehavior &&
      other.serviceUrlBehavior == serviceUrlBehavior &&
      other.terminalScrollbackLines == terminalScrollbackLines &&
      other.uiFontFamily == uiFontFamily &&
      other.monoFontFamily == monoFontFamily &&
      other.uiFontSize == uiFontSize &&
      other.codeFontSize == codeFontSize &&
      other.syntaxTheme == syntaxTheme &&
      other.workspaceTitleSource == workspaceTitleSource &&
      other.autoExpandReasoning == autoExpandReasoning &&
      other.toolCallDetailLevel == toolCallDetailLevel &&
      other.vimKeybindings == vimKeybindings;

  @override
  int get hashCode => Object.hashAll(toJson().values);

  @override
  String toString() => 'AppSettings(${jsonEncode(toJson())})';
}

/// [AppSettings] plus the two fields only the desktop shell can answer for.
///
/// DEVIATION: upstream writes `interface Settings extends AppSettings`. Ported
/// as composition so there is exactly one [AppSettings] value type — inheriting
/// would give two classes whose `==` disagree about what a settings document is.
final class Settings {
  const Settings({
    required this.app,
    required this.manageBuiltInDaemon,
    required this.releaseChannel,
  });

  final AppSettings app;

  /// Whether this client starts and supervises its own daemon.
  final bool manageBuiltInDaemon;

  final ReleaseChannel releaseChannel;

  Settings copyWith({
    AppSettings? app,
    bool? manageBuiltInDaemon,
    ReleaseChannel? releaseChannel,
  }) => Settings(
    app: app ?? this.app,
    manageBuiltInDaemon: manageBuiltInDaemon ?? this.manageBuiltInDaemon,
    releaseChannel: releaseChannel ?? this.releaseChannel,
  );

  @override
  bool operator ==(Object other) =>
      other is Settings &&
      other.app == app &&
      other.manageBuiltInDaemon == manageBuiltInDaemon &&
      other.releaseChannel == releaseChannel;

  @override
  int get hashCode => Object.hash(app, manageBuiltInDaemon, releaseChannel);

  @override
  String toString() =>
      'Settings(app: $app, manageBuiltInDaemon: $manageBuiltInDaemon, '
      'releaseChannel: ${releaseChannel.name})';
}

/// The frozen client defaults, in the order they are persisted.
final AppSettings defaultClientSettings = AppSettings(
  theme: AppThemeName.auto,
  language: AppLanguage.system,
  sendBehavior: SendBehavior.interrupt,
  serviceUrlBehavior: ServiceUrlBehavior.ask,
  terminalScrollbackLines: defaultTerminalScrollbackLines,
  uiFontFamily: '',
  monoFontFamily: '',
  uiFontSize: defaultUiFontSize,
  codeFontSize: defaultCodeFontSize,
  syntaxTheme: SyntaxThemeId.one,
  workspaceTitleSource: WorkspaceTitleSource.title,
  autoExpandReasoning: false,
  toolCallDetailLevel: ToolCallDetailLevel.detailed,
  vimKeybindings: false,
);

/// The full defaults, including the desktop-owned fields.
final Settings defaultAppSettings = Settings(
  app: defaultClientSettings,
  manageBuiltInDaemon: true,
  releaseChannel: ReleaseChannel.stable,
);

/// A partial update, as `saveAppSettings({ updates })` takes.
///
/// DEVIATION: `Partial<AppSettings>` cannot be expressed in Dart, so every
/// field is nullable and null means "leave alone". No [AppSettings] field is
/// itself nullable, so nothing is lost — there is no update that means "set
/// this back to null".
final class AppSettingsUpdate {
  const AppSettingsUpdate({
    this.theme,
    this.language,
    this.sendBehavior,
    this.serviceUrlBehavior,
    this.terminalScrollbackLines,
    this.uiFontFamily,
    this.monoFontFamily,
    this.uiFontSize,
    this.codeFontSize,
    this.syntaxTheme,
    this.workspaceTitleSource,
    this.autoExpandReasoning,
    this.toolCallDetailLevel,
    this.vimKeybindings,
  });

  final AppThemeName? theme;
  final AppLanguage? language;
  final SendBehavior? sendBehavior;
  final ServiceUrlBehavior? serviceUrlBehavior;
  final int? terminalScrollbackLines;
  final String? uiFontFamily;
  final String? monoFontFamily;
  final int? uiFontSize;
  final int? codeFontSize;
  final SyntaxThemeId? syntaxTheme;
  final WorkspaceTitleSource? workspaceTitleSource;
  final bool? autoExpandReasoning;
  final ToolCallDetailLevel? toolCallDetailLevel;
  final bool? vimKeybindings;

  /// `{ ...current, ...updates }`.
  ///
  /// The update is applied verbatim — upstream does not re-validate here, so a
  /// caller that writes an out-of-range font size gets exactly that value until
  /// the next load normalizes it.
  AppSettings applyTo(AppSettings current) => current.copyWith(
    theme: theme,
    language: language,
    sendBehavior: sendBehavior,
    serviceUrlBehavior: serviceUrlBehavior,
    terminalScrollbackLines: terminalScrollbackLines,
    uiFontFamily: uiFontFamily,
    monoFontFamily: monoFontFamily,
    uiFontSize: uiFontSize,
    codeFontSize: codeFontSize,
    syntaxTheme: syntaxTheme,
    workspaceTitleSource: workspaceTitleSource,
    autoExpandReasoning: autoExpandReasoning,
    toolCallDetailLevel: toolCallDetailLevel,
    vimKeybindings: vimKeybindings,
  );
}

/// The async string store the settings document lives in.
///
/// Kept as a two-method port rather than taking `SharedPreferences` directly so
/// the load/migrate logic can be driven from an in-memory map in tests.
abstract interface class KeyValueStorage {
  Future<String?> getItem(String key);
  Future<void> setItem(String key, String value);
}

/// The daemon-management fields only the desktop shell owns.
final class DesktopDaemonSettings {
  const DesktopDaemonSettings({
    required this.manageBuiltInDaemon,
    required this.keepRunningAfterQuit,
  });

  final bool manageBuiltInDaemon;
  final bool keepRunningAfterQuit;

  @override
  bool operator ==(Object other) =>
      other is DesktopDaemonSettings &&
      other.manageBuiltInDaemon == manageBuiltInDaemon &&
      other.keepRunningAfterQuit == keepRunningAfterQuit;

  @override
  int get hashCode => Object.hash(manageBuiltInDaemon, keepRunningAfterQuit);
}

/// Upstream's `DesktopSettings`, the main-process-owned document.
///
/// Deliberately *not* this repo's `lib/state/desktop_settings_provider.dart`
/// `DesktopSettings`: that one is a different document (auto-start at login,
/// keep-running-after-quit) with no `releaseChannel` or `manageBuiltInDaemon`.
/// Naming it [DesktopOwnedSettings] keeps the two from being confused.
final class DesktopOwnedSettings {
  const DesktopOwnedSettings({
    required this.releaseChannel,
    required this.daemon,
  });

  final ReleaseChannel releaseChannel;
  final DesktopDaemonSettings daemon;

  @override
  bool operator ==(Object other) =>
      other is DesktopOwnedSettings &&
      other.releaseChannel == releaseChannel &&
      other.daemon == daemon;

  @override
  int get hashCode => Object.hash(releaseChannel, daemon);
}

/// Fields found in the renderer's blob that belong to the desktop shell and
/// have to be handed over once.
///
/// Both fields are nullable and independently optional: a blob that carries
/// only one of them still produces a migration for that one.
final class LegacyDesktopSettingsMigration {
  const LegacyDesktopSettingsMigration({
    this.manageBuiltInDaemon,
    this.releaseChannel,
  });

  final bool? manageBuiltInDaemon;
  final ReleaseChannel? releaseChannel;

  bool get isEmpty => manageBuiltInDaemon == null && releaseChannel == null;

  @override
  bool operator ==(Object other) =>
      other is LegacyDesktopSettingsMigration &&
      other.manageBuiltInDaemon == manageBuiltInDaemon &&
      other.releaseChannel == releaseChannel;

  @override
  int get hashCode => Object.hash(manageBuiltInDaemon, releaseChannel);

  @override
  String toString() =>
      'LegacyDesktopSettingsMigration(manageBuiltInDaemon: '
      '$manageBuiltInDaemon, releaseChannel: ${releaseChannel?.name})';
}

/// The desktop shell, as the settings loader sees it.
abstract interface class DesktopSettingsBridge {
  /// Whether there is a desktop shell at all. Everything below is only reached
  /// when this is true.
  bool isDesktopShell();

  Future<DesktopOwnedSettings> loadDesktopSettings();

  Future<void> migrateLegacyDesktopSettings(
    LegacyDesktopSettingsMigration input,
  );
}

/// Everything the settings loader needs injected.
final class SettingsDeps {
  const SettingsDeps({
    required this.storage,
    required this.desktop,
    this.onLoadError,
  });

  final KeyValueStorage storage;
  final DesktopSettingsBridge desktop;

  /// Port of upstream's `console.error("[AppSettings] Failed to load settings:")`.
  ///
  /// The error is still rethrown either way; this exists so a host can log it
  /// without this module choosing a logging framework.
  final void Function(Object error, StackTrace stackTrace)? onLoadError;
}

/// Merges [updates] into the current document and persists it.
///
/// Reads the *cache* first and only falls back to storage on a miss, so the
/// common case (user toggles a setting on a screen that already loaded
/// settings) is one write and no read. Whatever it starts from is normalized
/// before merging, which is how a stale cached blob written by an older build
/// gets cleaned up on the next save.
Future<void> saveAppSettings({
  required PaseoQueryCache cache,
  required AppSettingsUpdate updates,
  required SettingsDeps deps,
}) async {
  final cached = cache.getQueryData(appSettingsQueryKey);
  final storedCurrent = cached ?? await loadAppSettingsFromStorage(deps);
  final current = normalizeAppSettings(storedCurrent);
  final next = updates.applyTo(current);
  cache.setQueryData(appSettingsQueryKey, next);
  await deps.storage.setItem(appSettingsStorageKey, jsonEncode(next.toJson()));
}

/// Loads the settings document, migrating and seeding as needed.
///
/// Three cases, in order: the current blob exists and is normalized; only the
/// legacy blob exists, so the fields still recognised are lifted out of it and
/// the result is written forward; nothing exists, so the defaults are written
/// so that later reads take the fast path.
///
/// A parse failure is reported through [SettingsDeps.onLoadError] and rethrown —
/// upstream deliberately does not swallow it, because silently resetting a
/// user's settings is worse than failing loudly.
Future<AppSettings> loadAppSettingsFromStorage(SettingsDeps deps) async {
  try {
    final stored = await deps.storage.getItem(appSettingsStorageKey);
    // `if (stored)` in upstream: an empty string is falsy in JS and falls
    // through to the legacy blob rather than being parsed.
    if (stored != null && stored.isNotEmpty) {
      return normalizeAppSettings(jsonDecode(stored));
    }

    final legacyStored = await deps.storage.getItem(legacySettingsStorageKey);
    if (legacyStored != null && legacyStored.isNotEmpty) {
      final next = _applyLegacyAppSettings(jsonDecode(legacyStored));
      await deps.storage.setItem(
        appSettingsStorageKey,
        jsonEncode(next.toJson()),
      );
      return next;
    }

    await deps.storage.setItem(
      appSettingsStorageKey,
      jsonEncode(defaultClientSettings.toJson()),
    );
    return defaultClientSettings;
  } catch (error, stackTrace) {
    deps.onLoadError?.call(error, stackTrace);
    rethrow;
  }
}

/// Loads the effective settings, including the desktop-owned fields.
///
/// Off desktop the two desktop fields are pinned to their defaults *even if the
/// stored blob contains them* — a renderer that once wrote `releaseChannel`
/// must not keep steering a build stream it does not control.
///
/// The legacy read happens before [loadAppSettingsFromStorage] because that
/// call rewrites the blob, and the migration needs the pre-rewrite bytes.
Future<Settings> loadSettingsFromStorage(SettingsDeps deps) async {
  final isDesktop = deps.desktop.isDesktopShell();
  final legacyDesktopSettings = isDesktop
      ? await loadLegacyDesktopSettingsFromStorage(deps.storage)
      : null;
  final appSettings = await loadAppSettingsFromStorage(deps);

  if (!isDesktop) {
    return Settings(
      app: appSettings,
      manageBuiltInDaemon: defaultAppSettings.manageBuiltInDaemon,
      releaseChannel: defaultAppSettings.releaseChannel,
    );
  }

  if (legacyDesktopSettings != null) {
    await deps.desktop.migrateLegacyDesktopSettings(legacyDesktopSettings);
  }

  final desktopSettings = await deps.desktop.loadDesktopSettings();
  return Settings(
    app: appSettings,
    manageBuiltInDaemon: desktopSettings.daemon.manageBuiltInDaemon,
    releaseChannel: desktopSettings.releaseChannel,
  );
}

/// Turns anything at all into a valid settings document.
///
/// Non-objects (and arrays, which are objects in JS) yield the plain defaults;
/// otherwise each field is validated on its own so that one corrupt value never
/// costs the user the other thirteen.
AppSettings normalizeAppSettings(Object? value) {
  // An already-typed value round-trips unchanged; upstream has no such case
  // because its cache is untyped, but Dart callers do cache the typed object.
  if (value is AppSettings) return value;
  // JS arrays are objects, so upstream excludes them explicitly; in Dart a
  // List is simply not a Map and the `is Map` test already rejects it.
  final stored = value is Map
      ? _asStringKeyedMap(value)
      : const <String, Object?>{};
  return _pickAppSettings(stored);
}

AppSettings _pickAppSettings(Map<String, Object?> stored) {
  var result = defaultClientSettings;

  final theme = stored['theme'];
  if (theme is String) {
    for (final candidate in AppThemeName.values) {
      if (candidate.name == theme) {
        result = result.copyWith(theme: candidate);
        break;
      }
    }
  }

  final language = parseAppLanguage(stored['language']);
  if (language != null) result = result.copyWith(language: language);

  final sendBehavior = stored['sendBehavior'];
  if (sendBehavior == 'interrupt') {
    result = result.copyWith(sendBehavior: SendBehavior.interrupt);
  } else if (sendBehavior == 'queue') {
    result = result.copyWith(sendBehavior: SendBehavior.queue);
  }

  final serviceUrlBehavior = stored['serviceUrlBehavior'];
  if (serviceUrlBehavior is String) {
    final parsed = ServiceUrlBehavior.fromWire(serviceUrlBehavior);
    if (parsed != null) result = result.copyWith(serviceUrlBehavior: parsed);
  }

  final terminalScrollbackLines = parseTerminalScrollbackLines(
    stored['terminalScrollbackLines'],
  );
  if (terminalScrollbackLines != null) {
    result = result.copyWith(terminalScrollbackLines: terminalScrollbackLines);
  }

  final uiFontFamily = sanitizeFontFamily(stored['uiFontFamily']);
  if (uiFontFamily != null) {
    result = result.copyWith(uiFontFamily: uiFontFamily);
  }

  final monoFontFamily = sanitizeFontFamily(stored['monoFontFamily']);
  if (monoFontFamily != null) {
    result = result.copyWith(monoFontFamily: monoFontFamily);
  }

  final uiFontSize = parseClampedFontSize(
    stored['uiFontSize'],
    min: minUiFontSize,
    max: maxUiFontSize,
  );
  if (uiFontSize != null) result = result.copyWith(uiFontSize: uiFontSize);

  final codeFontSize = parseClampedFontSize(
    stored['codeFontSize'],
    min: minCodeFontSize,
    max: maxCodeFontSize,
  );
  if (codeFontSize != null) {
    result = result.copyWith(codeFontSize: codeFontSize);
  }

  final syntaxTheme = stored['syntaxTheme'];
  if (syntaxTheme is String) {
    final parsed = SyntaxThemeId.fromWire(syntaxTheme);
    if (parsed != null) result = result.copyWith(syntaxTheme: parsed);
  }

  final vimKeybindings = stored['vimKeybindings'];
  if (vimKeybindings is bool) {
    result = result.copyWith(vimKeybindings: vimKeybindings);
  }

  final workspaceTitleSource = stored['workspaceTitleSource'];
  if (workspaceTitleSource is String) {
    for (final candidate in WorkspaceTitleSource.values) {
      if (candidate.name == workspaceTitleSource) {
        result = result.copyWith(workspaceTitleSource: candidate);
        break;
      }
    }
  }

  final autoExpandReasoning = stored['autoExpandReasoning'];
  if (autoExpandReasoning is bool) {
    result = result.copyWith(autoExpandReasoning: autoExpandReasoning);
  }

  final toolCallDetailLevel = parseStoredToolCallDetailLevel(stored);
  if (toolCallDetailLevel != null) {
    result = result.copyWith(toolCallDetailLevel: toolCallDetailLevel);
  }

  return result;
}

/// Resolves the tool-call detail level out of a stored blob, or null when the
/// blob says nothing about it and the default should stand.
///
/// Two compatibility rules, both deliberate and both dated upstream:
/// - an explicit but unrecognised value maps to `overview`, not to the
///   `detailed` default, so the removed `"concise"` level (dropped in v0.1.107)
///   lands on the closest surviving level rather than flipping users to the
///   most verbose one;
/// - `compactToolCalls` (migrated in v0.1.105) is honoured only when there is
///   no `toolCallDetailLevel` at all.
///
/// DEVIATION: upstream distinguishes "key absent" from "key present and
/// undefined" via `!== undefined`. Dart JSON cannot represent the latter, so
/// this uses `containsKey`: a persisted `"toolCallDetailLevel": null` is treated
/// as present-and-unrecognised and maps to `overview`, matching what
/// `JSON.stringify` of an explicit null would produce upstream.
ToolCallDetailLevel? parseStoredToolCallDetailLevel(
  Map<String, Object?> stored,
) {
  if (stored.containsKey('toolCallDetailLevel')) {
    final value = stored['toolCallDetailLevel'];
    if (value is String) {
      for (final candidate in ToolCallDetailLevel.values) {
        if (candidate.name == value) return candidate;
      }
    }
    return ToolCallDetailLevel.overview;
  }
  final compactToolCalls = stored['compactToolCalls'];
  if (compactToolCalls is bool) {
    return compactToolCalls
        ? ToolCallDetailLevel.overview
        : ToolCallDetailLevel.detailed;
  }
  return null;
}

/// The legacy blob carries far more than the current one, but only `theme` is
/// still meaningful, and only its three original values — the extra themes
/// shipped after the legacy format was retired, so a legacy blob cannot
/// legitimately name one.
///
/// DEVIATION: upstream reads `legacy.theme` off the parse result unguarded, so
/// a stored literal `"null"` would throw a TypeError there. A non-object legacy
/// blob yields the plain defaults here instead — the same outcome upstream
/// reaches for every other non-object, without the one accidental throw.
AppSettings _applyLegacyAppSettings(Object? legacy) {
  if (legacy is! Map) return defaultClientSettings;
  final theme = legacy['theme'];
  if (theme == 'dark') {
    return defaultClientSettings.copyWith(theme: AppThemeName.dark);
  }
  if (theme == 'light') {
    return defaultClientSettings.copyWith(theme: AppThemeName.light);
  }
  if (theme == 'auto') {
    return defaultClientSettings.copyWith(theme: AppThemeName.auto);
  }
  return defaultClientSettings;
}

/// Reads a scrollback preference, clamping it into range.
///
/// Accepts numbers and numeric strings (a text field hands back a string), and
/// truncates toward negative infinity before clamping so `-10` reaches the
/// minimum rather than rounding to `-0`. Returns null — meaning "leave the
/// default" — only when the value is not a number at all.
int? parseTerminalScrollbackLines(Object? value) {
  final numericValue = _toJsNumber(value);
  if (numericValue == null || !numericValue.isFinite) return null;
  return numericValue
      .floor()
      .clamp(minTerminalScrollbackLines, maxTerminalScrollbackLines)
      .toInt();
}

/// Reads a font size preference, clamping it into [min]..[max].
///
/// Same accept-and-clamp contract as [parseTerminalScrollbackLines]; the bounds
/// are parameters because the UI and code font sizes have different safe ranges.
int? parseClampedFontSize(Object? value, {required int min, required int max}) {
  final numericValue = _toJsNumber(value);
  if (numericValue == null || !numericValue.isFinite) return null;
  return numericValue.floor().clamp(min, max).toInt();
}

/// JavaScript's `typeof value === "number" ? value : Number(trimmedString)`,
/// returning null where upstream would produce `NaN` from a non-numeric type.
///
/// DEVIATION: `Number()` accepts a few literal forms Dart's [num.tryParse] does
/// not (hex/octal/binary prefixes, a bare `Infinity`, a trailing `.`), so those
/// are handled explicitly. Anything still unparseable is null, which lands on
/// the same `!Number.isFinite` branch upstream takes.
double? _toJsNumber(Object? value) {
  // `typeof true === "boolean"`, so booleans are not numbers — and Dart's
  // `is num` already excludes them.
  if (value is num) return value.toDouble();
  if (value is! String) return null;
  if (value.trim().isEmpty) return null;

  var text = value.trim();
  var sign = 1.0;
  if (text.startsWith('+')) {
    text = text.substring(1);
  } else if (text.startsWith('-')) {
    sign = -1.0;
    text = text.substring(1);
  }
  if (text == 'Infinity') return sign * double.infinity;

  final lower = text.toLowerCase();
  if (lower.startsWith('0x') ||
      lower.startsWith('0o') ||
      lower.startsWith('0b')) {
    // `Number("-0x10")` is NaN in JS: a sign is not allowed on a radix
    // literal, so a signed one falls through to null here too.
    if (sign < 0) return null;
    final radix = lower.startsWith('0x')
        ? 16
        : lower.startsWith('0o')
        ? 8
        : 2;
    final parsed = int.tryParse(text.substring(2), radix: radix);
    return parsed?.toDouble();
  }

  // `Number("5.")` is 5; Dart needs the digit spelled out.
  final normalized = text.endsWith('.') ? '${text}0' : text;
  final parsed = num.tryParse(normalized);
  return parsed == null ? null : sign * parsed.toDouble();
}

/// Validates a persisted font-family stack.
///
/// Returns the trimmed stack, `""` for "use the platform default", or null when
/// the value must be ignored. Rejections are not cosmetic: `;{}<>` would let a
/// stored preference escape the CSS `font-family` declaration on web, control
/// characters would corrupt it, and an absurdly long stack would be recomputed
/// on every style pass. Quotes and commas are legitimate in a stack and stay.
String? sanitizeFontFamily(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.length > maxFontFamilyLength) return null;
  if (RegExp(r'[;{}<>]').hasMatch(trimmed)) return null;
  // Surrogate halves are all >= 0xD800, so scanning code units is equivalent to
  // upstream's per-code-point `charCodeAt(0) <= 0x1f`.
  if (trimmed.codeUnits.any((unit) => unit <= 0x1f)) return null;
  return trimmed;
}

/// Lifts the desktop-owned fields out of whichever renderer blob still has them.
///
/// Returns null when there is nothing to hand over, so the caller can skip the
/// migration entirely rather than sending an empty one. Parse failures are not
/// caught here — upstream lets them reach the caller's own error handling.
Future<LegacyDesktopSettingsMigration?> loadLegacyDesktopSettingsFromStorage(
  KeyValueStorage storage,
) async {
  final stored = await _loadRendererSettingsPayload(storage);
  if (stored == null) return null;

  final manageBuiltInDaemon = stored['manageBuiltInDaemon'];
  final releaseChannel = stored['releaseChannel'];

  final migration = LegacyDesktopSettingsMigration(
    manageBuiltInDaemon: manageBuiltInDaemon is bool
        ? manageBuiltInDaemon
        : null,
    releaseChannel: releaseChannel == 'stable'
        ? ReleaseChannel.stable
        : releaseChannel == 'beta'
        ? ReleaseChannel.beta
        : null,
  );

  return migration.isEmpty ? null : migration;
}

Future<Map<String, Object?>?> _loadRendererSettingsPayload(
  KeyValueStorage storage,
) async {
  final current = await storage.getItem(appSettingsStorageKey);
  if (current != null && current.isNotEmpty) {
    final decoded = jsonDecode(current);
    return decoded is Map ? _asStringKeyedMap(decoded) : null;
  }

  final legacy = await storage.getItem(legacySettingsStorageKey);
  if (legacy == null || legacy.isEmpty) return null;
  final decoded = jsonDecode(legacy);
  return decoded is Map ? _asStringKeyedMap(decoded) : null;
}
