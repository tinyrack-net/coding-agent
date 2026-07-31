/// Port of Paseo 0.2.0's frozen `data/push-router.ts` — the one place that
/// turns a daemon's *unsolicited* messages into cache writes, and that keeps the
/// daemon's per-subscription push feeds in sync with what the UI is actually
/// looking at.
///
/// The module answers three separate questions, and it is worth keeping them
/// apart because they fail in different ways:
///
///  1. **Which push feeds should be open right now?** Every query that wants
///     server-pushed data tags itself with a route (see [checkoutDiffPushRoute]
///     and [workspaceTerminalsPushRoute]). The router watches the query cache,
///     derives the *desired* set of subscriptions from the queries that
///     currently have observers, and diffs it against the *active* set —
///     subscribing what appeared, unsubscribing what left or changed. This is
///     why a diff pane that scrolls out of existence stops costing the daemon
///     anything, without any screen having to remember to tear down.
///  2. **Where does an arriving push get written?** A push names a subscription
///     or a cwd, not a cache key, so the router walks the cache to find the
///     entries that subscription feeds and writes each one.
///  3. **What must be repaired after a reconnect?** A new socket has none of the
///     old session's subscriptions, and every cached value predates the gap. So
///     [invalidateServerDataQueriesAfterReconnect] both invalidates the
///     server-scoped caches and re-sends every active subscription.
///
/// ## Why this file carries a query cache
///
/// Upstream is written against TanStack Query: `QueryClient`, `QueryCache`,
/// `QueryObserver`, `query.meta`, `getObserversCount()`, `setQueryData`,
/// `invalidateQueries`. None of that is *incidental* here — the router's entire
/// subscription-reconciliation contract is expressed in terms of it. This repo
/// runs on Riverpod, which has no cache to walk and no per-entry observer count,
/// so porting the router without a cache would leave nothing to port.
///
/// [PushQueryCache] is therefore included: the minimum slice of TanStack's cache
/// whose *observable* behavior the router depends on. It is deliberately not a
/// general-purpose cache — there is no fetching, no staleness, no retry, no
/// garbage collection — only the pieces the router reads and writes. See its own
/// doc comment for the semantics that are reproduced on purpose.
///
/// ## What is reused
///
///  - `package:agent_protocol` supplies every wire shape: [CheckoutDiffUpdate],
///    [SubscribeCheckoutDiffResponse], [CheckoutDiffPayload], [CheckoutDiffFile],
///    [CheckoutDiffCompare]/[CheckoutDiffMode], [CheckoutError],
///    [ProvidersSnapshotUpdate], [GetProvidersSnapshotResponse],
///    [MutableDaemonConfig] and [PaseoTerminalInfo].
///  - `core/diff_order.dart` supplies [orderCheckoutDiffFiles], upstream's
///    `git/diff-order.ts`.
///  - `git/paseo_git_queries.dart` supplies [CheckoutQueryKey], the query-key
///    representation this repo already settled on, and `checkoutDiffQueryKey`,
///    which builds the keys this router matches.
///  - `providers/providers_snapshot.dart` and `providers/agent_commands.dart`
///    supply the query-root constants and `normalizeProvidersSnapshotCwd`, so
///    the keys built here are the same keys the rest of the app builds.
///
/// ## Where this overlaps the app's existing push dispatch
///
/// The running app already dispatches three of these five pushes, but per
/// consumer rather than centrally: `state/providers_snapshot_provider.dart`
/// listens to `DaemonClient.providersSnapshotUpdates`,
/// `state/daemon_config_provider.dart` to `daemonConfigChanges`, and
/// `state/working_diff_provider.dart` to `checkoutDiffUpdates` while owning its
/// own subscribe/unsubscribe lifecycle. `terminals_changed` is not dispatched
/// anywhere yet. Adopting this router means those providers become cache
/// readers instead of socket listeners; until then the two paths coexist and
/// this module is the frozen reference, not the live wiring.
library;

import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';

import '../core/diff_order.dart';
import '../git/paseo_git_queries.dart' show CheckoutQueryKey;
import '../providers/agent_commands.dart' show agentCommandsQueryRoot;
import '../providers/providers_snapshot.dart'
    show normalizeProvidersSnapshotCwd, providersSnapshotQueryRoot;

// ---------------------------------------------------------------------------
// Query keys
// ---------------------------------------------------------------------------

/// A cache key: a heterogeneous, order-significant tuple compared structurally.
///
/// An alias of [CheckoutQueryKey] rather than a new type, because the keys this
/// router matches are built by `git/paseo_git_queries.dart`; giving them two
/// names but one representation keeps the reuse visible at every call site.
typedef PushQueryKey = CheckoutQueryKey;

/// Root key for every providers-snapshot scope on one daemon.
///
/// Upstream names this `providersSnapshotQueryRoot`; that name is already taken
/// in this repo by the `String` namespace constant in
/// `providers/providers_snapshot.dart`, which this function reuses, so the
/// key-building form gets the `Key` suffix.
PushQueryKey providersSnapshotQueryRootKey(String? serverId) => [
  providersSnapshotQueryRoot,
  serverId,
];

/// Key for one providers-snapshot scope.
///
/// The cwd is normalized through the same [normalizeProvidersSnapshotCwd] the
/// rest of the app uses, so a push naming `/repo/` and a fetch naming `/repo`
/// land on one entry. A cwd that normalizes away entirely is the *home* scope,
/// which is a different key rather than a null-valued one.
PushQueryKey providersSnapshotQueryKey(String? serverId, [String? cwd]) {
  final normalizedCwd = normalizeProvidersSnapshotCwd(cwd);
  return normalizedCwd != null
      ? [providersSnapshotQueryRoot, serverId, 'cwd', normalizedCwd]
      : [providersSnapshotQueryRoot, serverId, 'home'];
}

/// Root key for every agent-commands scope on one daemon.
///
/// A providers snapshot changes which slash commands exist, so the root is
/// invalidated wholesale whenever a snapshot push lands.
PushQueryKey agentCommandsQueryRootKey(String serverId) => [
  agentCommandsQueryRoot,
  serverId,
];

/// Key for one daemon's mutable config.
///
/// Upstream's `data/daemon-config.ts` is a two-line module outside this cluster
/// and has no Dart counterpart yet; the key is reproduced here verbatim
/// (`daemon-config`, hyphenated, unlike its camelCase neighbours) because
/// changing it would silently split the cache.
PushQueryKey daemonConfigQueryKey(String? serverId) => [
  'daemon-config',
  serverId,
];

/// Key for one workspace's terminal list.
///
/// Deliberately *not* the repo's `buildTerminalsQueryKey` from
/// `terminal/workspace_terminal_state.dart`: that one returns a Dart record,
/// which cannot be indexed positionally. The router reads slots 2 and 3 of this
/// key to recover a cwd and workspace id for a query whose push metadata was
/// overwritten (see [_getActiveTerminalRouteForQueryKey]), so the list shape is
/// load-bearing. Reconciling the two is a follow-up: the record form would have
/// to grow an ordered projection.
///
/// [workspaceId] is stored as an explicit null rather than omitted, matching
/// upstream's `workspaceId ?? null`, so a workspace-less key still has arity 4.
PushQueryKey terminalsQueryKey(
  String serverId,
  String? workspaceDirectory, [
  String? workspaceId,
]) => ['terminals', serverId, workspaceDirectory, workspaceId];

// ---------------------------------------------------------------------------
// Query cache substrate
// ---------------------------------------------------------------------------

/// The cache lifecycle events the router listens for.
///
/// The full TanStack vocabulary is reproduced, including the three the router
/// ignores, because [_canEventChangeDesiredSubscriptions] is a *filter* and a
/// filter is only meaningful if the things it filters out can actually occur.
/// `updated` in particular must exist: every push write emits one, and a router
/// that reconciled on it would re-enter reconciliation from inside its own
/// cache write.
enum PushQueryCacheEventType {
  /// A key was cached for the first time.
  added,

  /// A key was dropped from the cache.
  removed,

  /// A cached value changed.
  updated,

  /// An observer attached to a query.
  observerAdded,

  /// An observer detached from a query.
  observerRemoved,

  /// An attached observer's options — including its push metadata — changed.
  observerOptionsUpdated,

  /// An attached observer recomputed its result. Never affects subscriptions.
  observerResultsUpdated,
}

/// One cache lifecycle event.
final class PushQueryCacheEvent {
  const PushQueryCacheEvent({required this.type, required this.query});

  final PushQueryCacheEventType type;
  final PushQuery query;
}

/// One cache entry.
///
/// Mirrors the slice of TanStack's `Query` the router touches: the key, the
/// metadata its observers last supplied, the cached value, how many observers
/// are attached, and whether it has been invalidated.
final class PushQuery {
  PushQuery._(this.queryKey);

  /// The key this entry is filed under. Immutable: rebuilding a key with the
  /// same arguments addresses this same entry.
  final PushQueryKey queryKey;

  /// The metadata of the observer that most recently set options on this query.
  ///
  /// Last-writer-wins, exactly as TanStack's `Query.setOptions` behaves — which
  /// is why an observer attaching *without* push metadata erases the route of
  /// the observer that had one. That is not a bug to route around; it is the
  /// condition the active-subscription fallback exists to survive, and the
  /// upstream suite pins it.
  ///
  /// Kept as a raw map rather than a typed route so that [_readServerDataRoute]
  /// genuinely validates it, the way upstream validates `query.meta` typed as
  /// `Record<string, unknown>`.
  Map<String, Object?>? meta;

  Object? _data;
  bool _hasData = false;

  /// Whether an invalidation swept this entry. Set by
  /// [PushQueryCache.invalidateQueries]; never cleared here, because nothing in
  /// this module refetches.
  bool isInvalidated = false;

  int _observersCount = 0;

  /// The cached value, or null when nothing has been written.
  Object? get data => _data;

  /// Whether anything has been written, distinguishing "cached null" from
  /// "never written".
  bool get hasData => _hasData;

  /// How many observers are currently attached.
  ///
  /// A method, not a getter, to keep the call sites reading like upstream's
  /// `query.getObserversCount()` — the single test that decides whether a route
  /// is live.
  int getObserversCount() => _observersCount;
}

/// A live view onto one cache entry.
///
/// The Dart stand-in for TanStack's `QueryObserver`, reduced to what makes a
/// query *observed*. Constructing one builds (or re-options) the entry;
/// [subscribe] is what actually raises its observer count, and the returned
/// callback lowers it. The split matters: upstream constructs observers that are
/// never subscribed, and those must not keep a push subscription alive.
final class PushQueryObserver {
  /// Builds — or re-options — the entry for [queryKey] and records [meta] on it.
  ///
  /// Note the side effect on construction: attaching a second observer with no
  /// metadata clears the first observer's route immediately, before anyone
  /// subscribes. That is TanStack's behavior and the router is built to absorb
  /// it.
  PushQueryObserver(
    this._cache, {
    required PushQueryKey queryKey,
    Map<String, Object?>? meta,
  }) : _queryKey = List<Object?>.unmodifiable(queryKey) {
    _query = _cache.build(_queryKey, meta: meta);
  }

  final PushQueryCache _cache;
  final PushQueryKey _queryKey;
  late final PushQuery _query;
  bool _subscribed = false;

  /// The entry this observer watches.
  PushQuery get query => _query;

  /// Attaches, and returns the detach callback.
  ///
  /// Detaching twice is a no-op rather than an error, so a caller that both
  /// detaches explicitly and unwinds a scope cannot drive the observer count
  /// negative.
  void Function() subscribe() {
    if (_subscribed) {
      throw StateError('PushQueryObserver is already subscribed');
    }
    _subscribed = true;
    _query._observersCount += 1;
    _cache._notify(PushQueryCacheEventType.observerAdded, _query);
    var released = false;
    return () {
      if (released) return;
      released = true;
      _subscribed = false;
      _query._observersCount -= 1;
      _cache._notify(PushQueryCacheEventType.observerRemoved, _query);
    };
  }

  /// Replaces this observer's metadata, as upstream's
  /// `observer.setOptions({meta})` does.
  ///
  /// Only emits `observerOptionsUpdated` while attached: an unattached
  /// observer's options cannot change any subscription, so signalling would
  /// force a pointless reconciliation.
  void setMeta(Map<String, Object?>? meta) {
    _cache.build(_queryKey, meta: meta);
    if (_subscribed) {
      _cache._notify(PushQueryCacheEventType.observerOptionsUpdated, _query);
    }
  }
}

/// The query cache the router reconciles against.
///
/// Reproduces exactly the TanStack semantics the router's behavior depends on:
///
///  - **Insertion-ordered iteration.** `getAll()` yields entries in the order
///    they were first cached. The router writes a push to *every* matching
///    entry, so order is only observable when two entries match — but the
///    upstream suite's fake data and the desired-subscription maps both inherit
///    JS `Map` insertion order, so it is preserved rather than left to chance.
///  - **Structural key hashing.** Keys are looked up by a deterministic
///    serialization, so a rebuilt key hits the same entry. The serialization is
///    type-tagged, so the string `"true"` and the boolean `true` do not collide
///    the way a naive `toString` would.
///  - **`setQueryData` creates.** Writing to an unknown key caches it, emitting
///    `added` then `updated` — which is precisely why the upstream suite can
///    prove that an unrelated `setQueryData` does not retry a failed
///    subscription.
///  - **Prefix invalidation.** `invalidateQueries({queryKey})` matches
///    *partially* — the filter key must be a prefix of the cached key — because
///    that is how one root key sweeps every scope beneath it.
///
/// Everything else about TanStack is out of scope: no fetching, no staleness, no
/// retries, no garbage collection, no refetch-on-invalidate.
final class PushQueryCache {
  final Map<String, PushQuery> _queries = <String, PushQuery>{};
  final List<void Function(PushQueryCacheEvent)> _listeners =
      <void Function(PushQueryCacheEvent)>[];

  /// Every cached entry, in insertion order.
  List<PushQuery> getAll() => _queries.values.toList(growable: false);

  /// The entry for [queryKey], or null when nothing is cached under it.
  ///
  /// Upstream's `getQueryState(key)` is reached through this: the state fields
  /// the suite reads (`isInvalidated`) live on [PushQuery] directly.
  PushQuery? getQuery(PushQueryKey queryKey) =>
      _queries[_hashQueryKey(queryKey)];

  /// The cached value for [queryKey], or null when nothing is cached.
  Object? getQueryData(PushQueryKey queryKey) => getQuery(queryKey)?.data;

  /// Listens for lifecycle events; returns the unsubscribe callback.
  ///
  /// Listeners are snapshotted before dispatch so a listener that mutates the
  /// cache — which the router does, every time it reconciles — cannot corrupt
  /// the iteration.
  void Function() subscribe(void Function(PushQueryCacheEvent) listener) {
    _listeners.add(listener);
    var released = false;
    return () {
      if (released) return;
      released = true;
      _listeners.remove(listener);
    };
  }

  /// Returns the entry for [queryKey], creating it if absent, and records
  /// [meta] on it.
  ///
  /// Last-writer-wins on [meta] — including a null [meta], which *clears* the
  /// route. See [PushQuery.meta].
  PushQuery build(PushQueryKey queryKey, {Map<String, Object?>? meta}) {
    final hash = _hashQueryKey(queryKey);
    final existing = _queries[hash];
    if (existing != null) {
      existing.meta = meta;
      return existing;
    }
    final query = PushQuery._(List<Object?>.unmodifiable(queryKey))
      ..meta = meta;
    _queries[hash] = query;
    _notify(PushQueryCacheEventType.added, query);
    return query;
  }

  /// Writes [data] under [queryKey], caching the key if it is new.
  void setQueryData(PushQueryKey queryKey, Object? data) =>
      setQueryDataWith(queryKey, (_) => data);

  /// Writes the result of [updater] under [queryKey].
  ///
  /// [updater] receives the current value, or null when nothing is cached —
  /// upstream's `(current) => …` updater signature, whose `current` is
  /// `undefined` on a cold key. This is how a terminals push preserves the
  /// request id of the fetch that populated the entry.
  void setQueryDataWith(
    PushQueryKey queryKey,
    Object? Function(Object? current) updater,
  ) {
    final query = build(
      queryKey,
      meta: _queries[_hashQueryKey(queryKey)]?.meta,
    );
    query
      .._data = updater(query._data)
      .._hasData = true;
    _notify(PushQueryCacheEventType.updated, query);
  }

  /// Drops [queryKey] from the cache.
  ///
  /// Not used by the router itself, but `removed` is one of the events that can
  /// change the desired subscription set, so the cache has to be able to
  /// produce it.
  void remove(PushQueryKey queryKey) {
    final removed = _queries.remove(_hashQueryKey(queryKey));
    if (removed == null) return;
    _notify(PushQueryCacheEventType.removed, removed);
  }

  /// Marks every matching entry invalidated.
  ///
  /// [queryKey] matches by prefix (upstream's default, `exact: false`);
  /// [predicate] matches by arbitrary test. Passing both requires both to
  /// match, as TanStack's filters compose. Passing neither matches everything.
  void invalidateQueries({
    PushQueryKey? queryKey,
    bool Function(PushQuery query)? predicate,
    bool exact = false,
  }) {
    for (final query in _queries.values.toList(growable: false)) {
      if (queryKey != null &&
          !(exact
              ? _queryKeysEqual(query.queryKey, queryKey)
              : _isQueryKeyPrefix(queryKey, query.queryKey))) {
        continue;
      }
      if (predicate != null && !predicate(query)) continue;
      query.isInvalidated = true;
    }
  }

  void _notify(PushQueryCacheEventType type, PushQuery query) {
    final event = PushQueryCacheEvent(type: type, query: query);
    for (final listener in _listeners.toList(growable: false)) {
      listener(event);
    }
  }
}

// ---------------------------------------------------------------------------
// Push messages
// ---------------------------------------------------------------------------

/// A `status` push, carried as its raw payload.
///
/// Upstream's `status` message is a wide discriminated union and the router
/// cares about exactly one member of it. Handing the router the *raw* payload
/// keeps [_isDaemonConfigChangedPayload] a real guard with real behavior —
/// which matters, because in production this router would sit behind a socket
/// that emits every status message, not just config changes.
///
/// Note the overlap: `DaemonClient.daemonConfigChanges` already applies the
/// equivalent filter before publishing [DaemonConfigChangedStatus], so wiring
/// this router to that stream would make the guard redundant. Wiring it to the
/// raw `status` frames would not.
final class PaseoStatusPush {
  const PaseoStatusPush(this.payload);

  final Map<String, Object?> payload;
}

/// A `terminals_changed` push: the full terminal list for one cwd.
///
/// Declared here only because `package:agent_protocol` has no message for it
/// yet — the daemon sends it, but nothing in this app consumes it. It belongs in
/// `packages/protocol/lib/src/messages/terminal_v2.dart` next to
/// [PaseoTerminalInfo]; it is local for now so this port does not modify a file
/// another agent may be editing.
///
/// Each entry reuses the protocol's [PaseoTerminalInfo]. The wire omits `cwd`
/// from the entries because the payload's own [cwd] covers all of them, so
/// [fromJson] fills each entry's cwd from the payload — a strictly informational
/// enrichment, since the router only ever reads `workspaceId` off an entry and
/// writes the entry through unchanged.
final class TerminalsChanged {
  const TerminalsChanged({required this.cwd, required this.terminals});

  static const String type = 'terminals_changed';

  final String cwd;
  final List<PaseoTerminalInfo> terminals;

  factory TerminalsChanged.fromJson(Map<String, Object?> json) {
    if (json['type'] != type) {
      throw const FormatException('expected message type terminals_changed');
    }
    final payload = json['payload'];
    if (payload is! Map) {
      throw const FormatException('terminals_changed payload is required');
    }
    final values = payload.cast<String, Object?>();
    final cwd = values['cwd'];
    if (cwd is! String) {
      throw const FormatException('terminals_changed cwd must be a string');
    }
    final terminals = values['terminals'];
    if (terminals is! List) {
      throw const FormatException('terminals_changed terminals must be a list');
    }
    return TerminalsChanged(
      cwd: cwd,
      terminals: terminals
          .map((entry) {
            if (entry is! Map) {
              throw const FormatException('terminals entries must be objects');
            }
            final values = entry.cast<String, Object?>();
            return PaseoTerminalInfo.fromJson({'cwd': cwd, ...values});
          })
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'payload': {
      'cwd': cwd,
      'terminals': terminals
          .map((terminal) {
            final json = terminal.toJson()..remove('cwd');
            return json;
          })
          .toList(growable: false),
    },
  };
}

// ---------------------------------------------------------------------------
// Cache payloads
// ---------------------------------------------------------------------------

/// What a checkout-diff query holds.
///
/// Upstream types this `Omit<SubscribeCheckoutDiffResponsePayload,
/// "subscriptionId">`: the subscription id is how the push was *routed*, so
/// storing it in the routed-to entry would be redundant, and a `requestId` takes
/// its place so the reader can tell a subscribe response from a live update.
///
/// The protocol's [CheckoutDiffPayload] is the wire shape and cannot stand in —
/// it has the subscriptionId and no requestId. The element types
/// ([CheckoutDiffFile], [CheckoutError]) are reused unchanged.
final class CheckoutDiffCachePayload {
  const CheckoutDiffCachePayload({
    required this.cwd,
    required this.files,
    required this.error,
    required this.requestId,
  });

  final String cwd;
  final List<CheckoutDiffFile> files;
  final CheckoutError? error;

  /// `subscription:<id>` for a live update, or the daemon's own request id for
  /// the initial subscribe response.
  final String requestId;
}

/// What a terminals query holds.
///
/// Deliberately *not* the repo's `ListTerminalsPayload` from
/// `terminal/workspace_terminal_state.dart`: that one stores
/// `TerminalListEntry`, which keeps only `id`, `name` and `title`. The router
/// filters pushes by `workspaceId` and writes entries through whole, so an
/// entry type that drops `workspaceId` and `activity` cannot carry a push.
/// Reconciling the two means widening `TerminalListEntry` — see the module doc.
final class ListTerminalsCachePayload {
  const ListTerminalsCachePayload({
    required this.cwd,
    required this.terminals,
    required this.requestId,
  });

  /// Optional upstream (`cwd?: string`), because a list fetched without a
  /// workspace filter has no single cwd. A push always names one.
  final String? cwd;

  final List<PaseoTerminalInfo> terminals;

  /// Carried over from whatever populated the entry, so a push does not erase
  /// the identity of the fetch it is updating.
  final String requestId;
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

/// A query's declaration that it is fed by a daemon push feed.
///
/// Upstream's `CheckoutDiffRoute | WorkspaceTerminalsRoute` discriminated union
/// becomes a sealed hierarchy, so the domain checks the router performs are
/// exhaustiveness-checked instead of string-compared.
sealed class ServerDataRoute {
  const ServerDataRoute({
    required this.enabled,
    required this.serverId,
    required this.cwd,
  });

  /// Whether the consumer currently wants this feed. A disabled route is
  /// ignored entirely, exactly as if the query carried no metadata.
  final bool enabled;

  final String serverId;
  final String cwd;
}

/// A query fed by a checkout-diff subscription.
final class CheckoutDiffRoute extends ServerDataRoute {
  const CheckoutDiffRoute({
    required super.enabled,
    required super.serverId,
    required super.cwd,
    required this.subscriptionId,
    required this.compare,
  });

  /// The daemon-side subscription this query is the sink for. Chosen by the
  /// consumer, so two queries that want the same diff share one feed.
  final String subscriptionId;

  /// Reuses the protocol's [CheckoutDiffCompare].
  ///
  /// Deviation: upstream's local `CheckoutDiffCompare` has
  /// `ignoreWhitespace?: boolean`, so it distinguishes *absent* from `false`,
  /// and [_areCheckoutDiffRoutesEqual] would call those two routes unequal and
  /// resubscribe. The protocol's field is a non-nullable `bool` defaulting to
  /// `false`, collapsing the two. The only observable consequence is the one
  /// that is removed: a resubscribe that upstream performs when a route changes
  /// from "unspecified" to "explicitly false", which requests the identical diff.
  /// Everywhere the value is actually *used* upstream tests it with `=== true`.
  final CheckoutDiffCompare compare;
}

/// A query fed by a workspace's terminal-list push feed.
final class WorkspaceTerminalsRoute extends ServerDataRoute {
  const WorkspaceTerminalsRoute({
    required super.enabled,
    required super.serverId,
    required super.cwd,
    this.workspaceId,
  });

  /// Null means "the terminals of this cwd that belong to no workspace" — not
  /// "any workspace". Pushes are filtered by exact equality, so a null route
  /// matches only null-workspace terminals.
  final String? workspaceId;
}

/// Builds the metadata a checkout-diff query tags itself with.
///
/// Returned as a raw map, not a [CheckoutDiffRoute], because that is what a
/// query's `meta` is: untyped data that survived a trip through a cache and must
/// be re-validated on the way out (see [_readServerDataRoute]).
///
/// `baseRef` is emitted only when non-null, because the reader distinguishes
/// *absent* (fine, means no base ref) from *null* (rejects the whole route) —
/// upstream's `baseRef !== undefined && typeof baseRef !== "string"`.
Map<String, Object?> checkoutDiffPushRoute({
  required bool enabled,
  required String serverId,
  required String subscriptionId,
  required String cwd,
  required CheckoutDiffCompare compare,
}) => {
  'serverData': <String, Object?>{
    'domain': 'checkoutDiff',
    'enabled': enabled,
    'serverId': serverId,
    'subscriptionId': subscriptionId,
    'cwd': cwd,
    'compare': <String, Object?>{
      'mode': compare.mode.name,
      if (compare.baseRef != null) 'baseRef': compare.baseRef,
      'ignoreWhitespace': compare.ignoreWhitespace,
    },
  },
};

/// Builds the metadata a terminals query tags itself with.
///
/// An empty [workspaceId] is dropped rather than stored, reproducing upstream's
/// `...(input.workspaceId ? {workspaceId} : {})` — JavaScript truthiness, where
/// `""` is falsy. So a route built with `workspaceId: ""` matches exactly the
/// terminals a route built with no workspace id would.
Map<String, Object?> workspaceTerminalsPushRoute({
  required bool enabled,
  required String serverId,
  required String cwd,
  String? workspaceId,
}) => {
  'serverData': <String, Object?>{
    'domain': 'workspaceTerminals',
    'enabled': enabled,
    'serverId': serverId,
    'cwd': cwd,
    if (workspaceId != null && workspaceId.isNotEmpty)
      'workspaceId': workspaceId,
  },
};

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// One subscribe-checkout-diff failure, as reported to
/// [ServerDataPushRouterOptions.onSubscribeCheckoutDiffError].
final class CheckoutDiffSubscribeFailure {
  const CheckoutDiffSubscribeFailure({
    required this.serverId,
    required this.cwd,
    required this.error,
  });

  final String serverId;
  final String cwd;
  final Object error;
}

/// The slice of a daemon connection this router drives.
///
/// Deviation: upstream declares a single generic `on<TType>(type, handler)` that
/// narrows the message type from the string literal. Dart has no structural
/// discriminated unions, so the five instantiations become five named
/// registrations. Each returns its own unsubscribe callback, as upstream's does.
///
/// The message types are the protocol's own, except where the protocol has none
/// yet ([PaseoStatusPush], [TerminalsChanged]).
abstract interface class ServerDataPushClient {
  /// Registers a `providers_snapshot_update` handler.
  void Function() onProvidersSnapshotUpdate(
    void Function(ProvidersSnapshotUpdate message) handler,
  );

  /// Registers a `status` handler. Every status message is delivered; the
  /// router filters.
  void Function() onStatus(void Function(PaseoStatusPush message) handler);

  /// Registers a `checkout_diff_update` handler.
  void Function() onCheckoutDiffUpdate(
    void Function(CheckoutDiffUpdate message) handler,
  );

  /// Registers a `subscribe_checkout_diff_response` handler.
  void Function() onSubscribeCheckoutDiffResponse(
    void Function(SubscribeCheckoutDiffResponse message) handler,
  );

  /// Registers a `terminals_changed` handler.
  void Function() onTerminalsChanged(
    void Function(TerminalsChanged message) handler,
  );

  /// Opens a checkout-diff feed. The returned response is the initial snapshot;
  /// the router discards it, because the daemon also delivers it as a
  /// `subscribe_checkout_diff_response` push, which is what actually writes the
  /// cache.
  Future<SubscribeCheckoutDiffResponse> subscribeCheckoutDiff(
    String cwd,
    CheckoutDiffCompare compare, {
    required String subscriptionId,
    String? requestId,
  });

  /// Closes a checkout-diff feed. May throw; the router treats a throw as
  /// "already gone".
  void unsubscribeCheckoutDiff(String subscriptionId);

  /// Opens a terminal-list feed.
  void subscribeTerminals({required String cwd, String? workspaceId});

  /// Closes a terminal-list feed.
  void unsubscribeTerminals({required String cwd, String? workspaceId});
}

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

/// Applies a providers-snapshot push to the cache.
///
/// Exported separately from the router because a snapshot push is
/// self-addressing — it names its own cwd — so it needs no subscription
/// bookkeeping and callers outside the router can apply one directly.
///
/// The write is unconditional: a push is newer than anything cached by
/// definition, so there is no generation check. The `requestId` is the literal
/// `providers_snapshot_update`, which is how a reader tells a pushed snapshot
/// from a fetched one.
///
/// Agent commands are invalidated wholesale for the daemon afterwards, because a
/// provider gaining or losing readiness changes which slash commands exist, and
/// the snapshot push carries no hint about which scopes were affected.
///
/// Upstream opens with a `message.type !== "providers_snapshot_update"` guard;
/// it is unreachable here, since the parameter type carries the discriminant.
void applyProvidersSnapshotUpdate({
  required String serverId,
  required PushQueryCache queryClient,
  required ProvidersSnapshotUpdate message,
}) {
  queryClient.setQueryData(
    providersSnapshotQueryKey(serverId, message.cwd),
    GetProvidersSnapshotResponse(
      entries: message.entries,
      generatedAt: message.generatedAt,
      requestId: 'providers_snapshot_update',
    ),
  );
  queryClient.invalidateQueries(queryKey: agentCommandsQueryRootKey(serverId));
}

/// One "what does a reconnect make stale?" rule.
final class _ReconnectRepairPolicy {
  const _ReconnectRepairPolicy({
    required this.domain,
    required this.invalidate,
  });

  final String domain;
  final void Function(PushQueryCache queryClient, String serverId) invalidate;
}

/// Everything a reconnect invalidates, in upstream's order.
///
/// Two of the four sweep by *key prefix* and two by *predicate*, and the
/// asymmetry is load-bearing: providers-snapshot and daemon-config keys share a
/// stable prefix, while checkout-diff and terminals keys carry mode/baseRef and
/// workspace-id tails that a prefix cannot reach.
const List<_ReconnectRepairPolicy> _reconnectRepairPolicies =
    <_ReconnectRepairPolicy>[
      _ReconnectRepairPolicy(
        domain: 'providersSnapshot',
        invalidate: _invalidateProvidersSnapshot,
      ),
      _ReconnectRepairPolicy(
        domain: 'daemonConfig',
        invalidate: _invalidateDaemonConfig,
      ),
      _ReconnectRepairPolicy(
        domain: 'checkoutDiff',
        invalidate: _invalidateCheckoutDiff,
      ),
      _ReconnectRepairPolicy(
        domain: 'workspaceTerminals',
        invalidate: _invalidateWorkspaceTerminals,
      ),
    ];

void _invalidateProvidersSnapshot(
  PushQueryCache queryClient,
  String serverId,
) => queryClient.invalidateQueries(
  queryKey: providersSnapshotQueryRootKey(serverId),
);

void _invalidateDaemonConfig(PushQueryCache queryClient, String serverId) =>
    queryClient.invalidateQueries(queryKey: daemonConfigQueryKey(serverId));

void _invalidateCheckoutDiff(PushQueryCache queryClient, String serverId) =>
    queryClient.invalidateQueries(
      predicate: (query) =>
          _isQueryForServer(query.queryKey, 'checkoutDiff', serverId),
    );

void _invalidateWorkspaceTerminals(
  PushQueryCache queryClient,
  String serverId,
) => queryClient.invalidateQueries(
  predicate: (query) =>
      _isQueryForServer(query.queryKey, 'terminals', serverId),
);

/// Every mounted router's reconnect repair, keyed by daemon.
///
/// Module-global, exactly as upstream's
/// `reconnectSubscriptionRepairsByServerId` is, because the reconnect is noticed
/// by the transport layer — which holds no reference to any router — while the
/// repair belongs to the router. A `Set` of closures gives each mount a distinct
/// identity to register and remove, so two routers on one daemon coexist and
/// neither's unmount cancels the other's repair.
final Map<String, Set<void Function()>>
_reconnectSubscriptionRepairsByServerId = <String, Set<void Function()>>{};

/// Repairs everything a dropped-and-restored connection invalidated.
///
/// Two distinct jobs, and both are necessary:
///
///  - **Invalidate.** Every server-scoped cache entry predates the gap, so it is
///    marked stale. Only [serverId]'s entries: a multi-daemon app must not
///    refetch a healthy daemon's data because a different one blinked.
///  - **Re-subscribe.** A new socket carries none of the old session's
///    subscriptions. Each mounted router forgets what it thought was active,
///    then re-derives it — so the daemon is told about every feed again, from
///    scratch.
///
/// Safe to call when nothing is mounted: the invalidations still apply and there
/// is simply no repair to run.
void invalidateServerDataQueriesAfterReconnect({
  required PushQueryCache queryClient,
  required String serverId,
}) {
  for (final policy in _reconnectRepairPolicies) {
    policy.invalidate(queryClient, serverId);
  }
  // Snapshotted: a repair reconciles, which can unmount nothing here but is
  // free to mutate the cache, and upstream's `for…of` over a live JS Set has
  // the same tolerance.
  for (final repairSubscriptions in <void Function()>[
    ...?_reconnectSubscriptionRepairsByServerId[serverId],
  ]) {
    repairSubscriptions();
  }
}

/// The domains a reconnect repairs, in order. Exposed for assertions; the
/// policies themselves are private because their bodies are the behavior.
List<String> get reconnectRepairDomains => _reconnectRepairPolicies
    .map((policy) => policy.domain)
    .toList(growable: false);

/// Everything [mountServerDataPushRouter] needs.
final class ServerDataPushRouterOptions {
  const ServerDataPushRouterOptions({
    required this.client,
    required this.queryClient,
    required this.serverId,
    required this.clock,
    this.onSubscribeCheckoutDiffError,
  });

  final ServerDataPushClient client;
  final PushQueryCache queryClient;
  final String serverId;

  /// Wall clock, injected.
  ///
  /// Read in exactly one place: the synthetic request id a terminals push
  /// invents when it lands on an entry no fetch ever populated. Upstream calls
  /// `Date.now()` inline; this module never calls [DateTime.now] itself, so the
  /// id is deterministic under test.
  final DateTime Function() clock;

  /// Called when opening a checkout-diff feed fails.
  ///
  /// Upstream writes to `console.error`. A callback rather than a print keeps
  /// the failure observable — and keeps a Flutter app from logging to stdout
  /// from a data-layer module. Null means "swallow", which is what the upstream
  /// suite effectively asserts: a failed subscribe is dropped from the active
  /// set and never retried.
  final void Function(CheckoutDiffSubscribeFailure failure)?
  onSubscribeCheckoutDiffError;
}

/// Attaches the router to a daemon connection. Returns the detach callback.
///
/// While attached, the router:
///  - keeps the daemon's checkout-diff and terminal feeds matched to the queries
///    that currently have observers,
///  - writes every arriving push into the cache entries it feeds,
///  - and registers a reconnect repair under [ServerDataPushRouterOptions.serverId].
///
/// Detaching is total: it deregisters the repair, drops every push handler,
/// closes every feed this router opened, and makes any in-flight reconciliation
/// a no-op. A detached router cannot write to the cache, which is what lets a
/// screen tear down without racing a push already in flight.
///
/// Calling the returned callback twice closes the feeds once — the active maps
/// are cleared on the first call.
void Function() mountServerDataPushRouter(ServerDataPushRouterOptions options) {
  final client = options.client;
  final queryClient = options.queryClient;
  final serverId = options.serverId;
  final activeCheckoutDiffSubscriptions = <String, CheckoutDiffRoute>{};
  final activeTerminalSubscriptions = <String, WorkspaceTerminalsRoute>{};
  var disposed = false;

  void reconcileSubscriptions([
    _ActiveServerDataSubscriptions? fallbackActive,
  ]) {
    if (disposed) return;

    final active =
        fallbackActive ??
        _ActiveServerDataSubscriptions(
          checkoutDiff: activeCheckoutDiffSubscriptions,
          workspaceTerminals: activeTerminalSubscriptions,
        );

    final desiredCheckoutDiffSubscriptions = <String, CheckoutDiffRoute>{};
    final desiredTerminalSubscriptions = <String, WorkspaceTerminalsRoute>{};
    for (final query in queryClient.getAll()) {
      final route = _getActiveServerDataRoute(query, serverId, active);
      if (route == null) continue;
      if (route is CheckoutDiffRoute) {
        desiredCheckoutDiffSubscriptions[route.subscriptionId] = route;
        continue;
      }
      if (route is WorkspaceTerminalsRoute) {
        desiredTerminalSubscriptions[_workspaceTerminalSubscriptionKey(route)] =
            route;
      }
    }

    _reconcileCheckoutDiffSubscriptions(
      active: activeCheckoutDiffSubscriptions,
      client: client,
      desired: desiredCheckoutDiffSubscriptions,
      serverId: serverId,
      onError: options.onSubscribeCheckoutDiffError,
    );
    _reconcileTerminalSubscriptions(
      active: activeTerminalSubscriptions,
      client: client,
      desired: desiredTerminalSubscriptions,
    );
  }

  void resetSubscriptionsAfterReconnect() {
    // The pre-reconnect active maps become the *fallback* the reconciliation
    // reads routes from: a query whose push metadata was overwritten by a
    // metadata-less observer has no other record of what it was subscribed to,
    // and losing it here would silently drop the feed for the rest of the
    // session.
    final fallbackActive = _ActiveServerDataSubscriptions(
      checkoutDiff: Map<String, CheckoutDiffRoute>.from(
        activeCheckoutDiffSubscriptions,
      ),
      workspaceTerminals: Map<String, WorkspaceTerminalsRoute>.from(
        activeTerminalSubscriptions,
      ),
    );
    activeCheckoutDiffSubscriptions.clear();
    activeTerminalSubscriptions.clear();
    reconcileSubscriptions(fallbackActive);
  }

  final unsubscribeQueryCache = queryClient.subscribe((event) {
    if (!_shouldReconcileSubscriptionsForCacheEvent(
      event,
      serverId,
      _ActiveServerDataSubscriptions(
        checkoutDiff: activeCheckoutDiffSubscriptions,
        workspaceTerminals: activeTerminalSubscriptions,
      ),
    )) {
      return;
    }
    reconcileSubscriptions();
  });
  final unsubscribeProviders = client.onProvidersSnapshotUpdate(
    (message) => applyProvidersSnapshotUpdate(
      queryClient: queryClient,
      serverId: serverId,
      message: message,
    ),
  );
  final unsubscribeDaemonConfig = client.onStatus(
    (message) => _applyDaemonConfigStatus(
      queryClient: queryClient,
      serverId: serverId,
      message: message,
    ),
  );
  final unsubscribeCheckoutDiffUpdate = client.onCheckoutDiffUpdate(
    (message) => _applyCheckoutDiffUpdate(
      activeCheckoutDiffSubscriptions: activeCheckoutDiffSubscriptions,
      queryClient: queryClient,
      serverId: serverId,
      message: message,
    ),
  );
  final unsubscribeCheckoutDiffResponse = client
      .onSubscribeCheckoutDiffResponse(
        (message) => _applyCheckoutDiffSubscribeResponse(
          activeCheckoutDiffSubscriptions: activeCheckoutDiffSubscriptions,
          queryClient: queryClient,
          serverId: serverId,
          message: message,
        ),
      );
  final unsubscribeTerminalsChanged = client.onTerminalsChanged(
    (message) => _applyTerminalsChanged(
      activeCheckoutDiffSubscriptions: activeCheckoutDiffSubscriptions,
      activeTerminalSubscriptions: activeTerminalSubscriptions,
      queryClient: queryClient,
      serverId: serverId,
      message: message,
      clock: options.clock,
    ),
  );
  final reconnectSubscriptionRepairs = _reconnectSubscriptionRepairsByServerId
      .putIfAbsent(serverId, () => <void Function()>{});
  reconnectSubscriptionRepairs.add(resetSubscriptionsAfterReconnect);

  reconcileSubscriptions();

  return () {
    disposed = true;
    reconnectSubscriptionRepairs.remove(resetSubscriptionsAfterReconnect);
    if (reconnectSubscriptionRepairs.isEmpty) {
      _reconnectSubscriptionRepairsByServerId.remove(serverId);
    }
    unsubscribeQueryCache();
    unsubscribeProviders();
    unsubscribeDaemonConfig();
    unsubscribeCheckoutDiffUpdate();
    unsubscribeCheckoutDiffResponse();
    unsubscribeTerminalsChanged();
    for (final subscriptionId in activeCheckoutDiffSubscriptions.keys.toList(
      growable: false,
    )) {
      _unsubscribeCheckoutDiff(client, subscriptionId);
    }
    activeCheckoutDiffSubscriptions.clear();
    for (final route in activeTerminalSubscriptions.values.toList(
      growable: false,
    )) {
      client.unsubscribeTerminals(
        cwd: route.cwd,
        workspaceId: route.workspaceId,
      );
    }
    activeTerminalSubscriptions.clear();
  };
}

// ---------------------------------------------------------------------------
// Reconciliation
// ---------------------------------------------------------------------------

/// The two active-subscription maps, passed together because a route lookup may
/// have to try both.
final class _ActiveServerDataSubscriptions {
  const _ActiveServerDataSubscriptions({
    required this.checkoutDiff,
    required this.workspaceTerminals,
  });

  final Map<String, CheckoutDiffRoute> checkoutDiff;
  final Map<String, WorkspaceTerminalsRoute> workspaceTerminals;
}

/// Diffs active against desired checkout-diff feeds.
///
/// Teardown runs first and in full, so a route whose *compare* changed is closed
/// before the replacement opens — the daemon keys feeds by subscription id, and
/// opening first would leave the old and new feeds fighting over one id.
///
/// A subscription is recorded as active *before* the request resolves, so a
/// second reconciliation arriving mid-flight does not open a duplicate. If the
/// request then fails, the record is withdrawn — but only if it still describes
/// the same route, since a reconciliation in the meantime may already have
/// replaced it. There is deliberately no retry: the next cache event that
/// changes the desired set will subscribe again, and a tight retry loop against
/// a daemon that is rejecting subscriptions helps nobody.
void _reconcileCheckoutDiffSubscriptions({
  required Map<String, CheckoutDiffRoute> active,
  required ServerDataPushClient client,
  required Map<String, CheckoutDiffRoute> desired,
  required String serverId,
  required void Function(CheckoutDiffSubscribeFailure failure)? onError,
}) {
  for (final entry in active.entries.toList(growable: false)) {
    final desiredRoute = desired[entry.key];
    if (desiredRoute != null &&
        _areCheckoutDiffRoutesEqual(entry.value, desiredRoute)) {
      continue;
    }
    _unsubscribeCheckoutDiff(client, entry.key);
    active.remove(entry.key);
  }

  for (final entry in desired.entries.toList(growable: false)) {
    final subscriptionId = entry.key;
    final desiredRoute = entry.value;
    if (active.containsKey(subscriptionId)) continue;
    active[subscriptionId] = desiredRoute;
    // Fire-and-forget, exactly as upstream's `void ….catch(…)`: the initial
    // snapshot arrives as a push, so nothing here awaits the response. Only the
    // failure path does any work.
    unawaited(
      client
          .subscribeCheckoutDiff(
            desiredRoute.cwd,
            desiredRoute.compare,
            subscriptionId: subscriptionId,
            requestId: 'push-router:$serverId:$subscriptionId',
          )
          .then<void>(
            (_) {},
            onError: (Object error) {
              if (_areCheckoutDiffRoutesEqual(
                active[subscriptionId],
                desiredRoute,
              )) {
                active.remove(subscriptionId);
              }
              onError?.call(
                CheckoutDiffSubscribeFailure(
                  serverId: serverId,
                  cwd: desiredRoute.cwd,
                  error: error,
                ),
              );
            },
          ),
    );
  }
}

/// Diffs active against desired terminal feeds.
///
/// Unlike checkout diff, subscribing is fire-and-forget: the daemon acknowledges
/// with a `terminals_changed` push rather than a response, so there is no
/// failure to unwind.
void _reconcileTerminalSubscriptions({
  required Map<String, WorkspaceTerminalsRoute> active,
  required ServerDataPushClient client,
  required Map<String, WorkspaceTerminalsRoute> desired,
}) {
  for (final entry in active.entries.toList(growable: false)) {
    final desiredRoute = desired[entry.key];
    if (desiredRoute != null &&
        _areWorkspaceTerminalsRoutesEqual(entry.value, desiredRoute)) {
      continue;
    }
    client.unsubscribeTerminals(
      cwd: entry.value.cwd,
      workspaceId: entry.value.workspaceId,
    );
    active.remove(entry.key);
  }

  for (final entry in desired.entries.toList(growable: false)) {
    if (active.containsKey(entry.key)) continue;
    active[entry.key] = entry.value;
    client.subscribeTerminals(
      cwd: entry.value.cwd,
      workspaceId: entry.value.workspaceId,
    );
  }
}

// ---------------------------------------------------------------------------
// Push application
// ---------------------------------------------------------------------------

/// Writes a `daemon_config_changed` status into the daemon-config entry.
///
/// Every other status message is ignored. Note the write is unconditional and
/// unkeyed by request: a config push *is* the new config, so there is nothing to
/// merge.
///
/// Deviation: upstream's guard is `payload.status === "daemon_config_changed" &&
/// isRecord(payload.config)`, and it then caches the config object *unvalidated*.
/// The Dart cache is typed, so the config is parsed with
/// [MutableDaemonConfig.fromJson]; a payload that passes upstream's `isRecord`
/// but is not a valid config is dropped here rather than cached in a form no
/// reader could use. That is the closest observable equivalent — upstream would
/// cache it and every reader would then mis-read it.
void _applyDaemonConfigStatus({
  required PushQueryCache queryClient,
  required String serverId,
  required PaseoStatusPush message,
}) {
  final payload = message.payload;
  if (!_isDaemonConfigChangedPayload(payload)) return;
  final MutableDaemonConfig config;
  try {
    config = MutableDaemonConfig.fromJson(
      (payload['config']! as Map).cast<String, Object?>(),
    );
  } on FormatException {
    return;
  }
  queryClient.setQueryData(daemonConfigQueryKey(serverId), config);
}

/// Writes a live checkout-diff push into every entry its subscription feeds.
///
/// The request id is synthesized as `subscription:<id>` so a reader can tell
/// this apart from the initial subscribe response, which carries the daemon's
/// own request id.
void _applyCheckoutDiffUpdate({
  required Map<String, CheckoutDiffRoute> activeCheckoutDiffSubscriptions,
  required PushQueryCache queryClient,
  required String serverId,
  required CheckoutDiffUpdate message,
}) => _setCheckoutDiffPayload(
  activeCheckoutDiffSubscriptions: activeCheckoutDiffSubscriptions,
  queryClient: queryClient,
  serverId: serverId,
  subscriptionId: message.payload.subscriptionId,
  payload: CheckoutDiffCachePayload(
    cwd: message.payload.cwd,
    files: orderCheckoutDiffFiles(message.payload.files),
    error: message.payload.error,
    requestId: 'subscription:${message.payload.subscriptionId}',
  ),
);

/// Writes the initial snapshot of a checkout-diff feed.
///
/// Identical to [_applyCheckoutDiffUpdate] except that the daemon's request id
/// is preserved, which is how the consumer that asked for the subscription
/// recognizes its own answer.
void _applyCheckoutDiffSubscribeResponse({
  required Map<String, CheckoutDiffRoute> activeCheckoutDiffSubscriptions,
  required PushQueryCache queryClient,
  required String serverId,
  required SubscribeCheckoutDiffResponse message,
}) => _setCheckoutDiffPayload(
  activeCheckoutDiffSubscriptions: activeCheckoutDiffSubscriptions,
  queryClient: queryClient,
  serverId: serverId,
  subscriptionId: message.payload.subscriptionId,
  payload: CheckoutDiffCachePayload(
    cwd: message.payload.cwd,
    files: orderCheckoutDiffFiles(message.payload.files),
    error: message.payload.error,
    requestId: message.requestId,
  ),
);

/// Writes [payload] into every cached entry fed by [subscriptionId].
///
/// Note what is *not* checked here, deliberately matching upstream: neither the
/// observer count nor the route's `enabled` flag. A push that arrives for a
/// subscription the daemon still believes is open is written even if the last
/// observer just detached — the alternative is a cache entry that silently
/// diverges from the daemon until it is evicted.
///
/// The route is recovered from the query's own metadata first, and only then
/// from the active-subscription map — the fallback that keeps routing working
/// after a metadata-less observer overwrote `meta`.
void _setCheckoutDiffPayload({
  required Map<String, CheckoutDiffRoute> activeCheckoutDiffSubscriptions,
  required PushQueryCache queryClient,
  required String serverId,
  required String subscriptionId,
  required CheckoutDiffCachePayload payload,
}) {
  for (final query in queryClient.getAll()) {
    final route =
        _getServerDataRoute(query) ??
        _getActiveCheckoutDiffRouteForQueryKey(
          active: activeCheckoutDiffSubscriptions,
          queryKey: query.queryKey,
          serverId: serverId,
        );
    if (route is! CheckoutDiffRoute ||
        route.serverId != serverId ||
        route.subscriptionId != subscriptionId) {
      continue;
    }
    queryClient.setQueryData(query.queryKey, payload);
  }
}

/// Writes a terminal-list push into every matching entry.
///
/// A push carries *every* terminal under a cwd, across all workspaces, so each
/// entry receives only the terminals belonging to its own route's workspace.
/// Matching is exact, including null-to-null: a workspace-less route gets the
/// workspace-less terminals, not all of them.
///
/// The request id is carried over from whatever populated the entry. Only when
/// nothing did is one synthesized from the clock — an entry fed purely by pushes
/// still needs an id, and stamping it with the arrival time is the only
/// information available.
void _applyTerminalsChanged({
  required Map<String, CheckoutDiffRoute> activeCheckoutDiffSubscriptions,
  required Map<String, WorkspaceTerminalsRoute> activeTerminalSubscriptions,
  required PushQueryCache queryClient,
  required String serverId,
  required TerminalsChanged message,
  required DateTime Function() clock,
}) {
  for (final query in queryClient.getAll()) {
    final route = _getActiveServerDataRoute(
      query,
      serverId,
      _ActiveServerDataSubscriptions(
        checkoutDiff: activeCheckoutDiffSubscriptions,
        workspaceTerminals: activeTerminalSubscriptions,
      ),
    );
    if (route is! WorkspaceTerminalsRoute || route.cwd != message.cwd) {
      continue;
    }

    final matchingTerminals = message.terminals
        .where((terminal) => terminal.workspaceId == route.workspaceId)
        .toList(growable: false);

    queryClient.setQueryDataWith(query.queryKey, (current) {
      final existing = current is ListTerminalsCachePayload ? current : null;
      return ListTerminalsCachePayload(
        cwd: message.cwd,
        terminals: matchingTerminals,
        requestId:
            existing?.requestId ??
            'terminals-changed-${clock().millisecondsSinceEpoch}',
      );
    });
  }
}

// ---------------------------------------------------------------------------
// Route resolution
// ---------------------------------------------------------------------------

/// The route a query is *currently* fed by, or null when it is not fed at all.
///
/// Three gates, in order:
///  1. No observers means nobody is looking, so the feed is not wanted — this is
///     what makes a subscription's lifetime follow the UI's.
///  2. Declared metadata wins, but only if it is enabled and names this daemon.
///     A route naming another daemon is not "no route": it is *this* daemon's
///     answer of "not mine".
///  3. Otherwise fall back to the active subscriptions, which is the only record
///     left when a metadata-less observer overwrote the query's `meta`.
ServerDataRoute? _getActiveServerDataRoute(
  PushQuery query,
  String serverId,
  _ActiveServerDataSubscriptions active,
) {
  if (query.getObserversCount() == 0) return null;
  final route = _getServerDataRoute(query);
  if (route != null) {
    return route.enabled && route.serverId == serverId ? route : null;
  }
  return _getActiveRouteForQueryKey(
    active: active,
    queryKey: query.queryKey,
    serverId: serverId,
  );
}

/// Recovers a route for [queryKey] from the active subscriptions.
///
/// Terminals are tried first, matching upstream's `??` order. The two key
/// namespaces are disjoint, so the order cannot change the answer — it is
/// preserved because relying on that disjointness silently would be fragile.
ServerDataRoute? _getActiveRouteForQueryKey({
  required _ActiveServerDataSubscriptions active,
  required PushQueryKey queryKey,
  required String serverId,
}) =>
    _getActiveTerminalRouteForQueryKey(
      active: active.workspaceTerminals,
      queryKey: queryKey,
      serverId: serverId,
    ) ??
    _getActiveCheckoutDiffRouteForQueryKey(
      active: active.checkoutDiff,
      queryKey: queryKey,
      serverId: serverId,
    );

/// Recovers a terminals route by reading the cwd and workspace id straight out
/// of the key.
///
/// A non-string cwd — including the null a workspace-less terminals key carries
/// in slot 2 — disqualifies the key: without a cwd there is no subscription to
/// match. A workspace id may be absent or null (both mean "no workspace") but
/// not some other type.
WorkspaceTerminalsRoute? _getActiveTerminalRouteForQueryKey({
  required Map<String, WorkspaceTerminalsRoute> active,
  required PushQueryKey queryKey,
  required String serverId,
}) {
  if (!_isQueryForServer(queryKey, 'terminals', serverId)) return null;
  final cwd = queryKey.length > 2 ? queryKey[2] : null;
  final workspaceId = queryKey.length > 3 ? queryKey[3] : null;
  if (cwd is! String || (workspaceId != null && workspaceId is! String)) {
    return null;
  }
  return active['$cwd\u0000${workspaceId ?? ''}'];
}

/// Recovers a checkout-diff route by finding the active subscription whose
/// compare parameters the key spells out.
///
/// A linear scan rather than a lookup: the key encodes the *parameters*, not the
/// subscription id, and the id is chosen by the consumer, so it cannot be
/// derived from the key.
CheckoutDiffRoute? _getActiveCheckoutDiffRouteForQueryKey({
  required Map<String, CheckoutDiffRoute> active,
  required PushQueryKey queryKey,
  required String serverId,
}) {
  if (!_isQueryForServer(queryKey, 'checkoutDiff', serverId)) return null;
  for (final route in active.values) {
    if (_isCheckoutDiffQueryKeyForRoute(queryKey, route)) return route;
  }
  return null;
}

/// Whether [event] can have changed which subscriptions are wanted.
///
/// Two filters, and both are needed. The event *type* filter keeps a cache write
/// from re-entering reconciliation — every push writes, and every write emits
/// `updated`. The route filter keeps an unrelated daemon's queries, and plain
/// application queries, from costing a full cache walk on every change.
bool _shouldReconcileSubscriptionsForCacheEvent(
  PushQueryCacheEvent event,
  String serverId,
  _ActiveServerDataSubscriptions active,
) {
  if (!_canEventChangeDesiredSubscriptions(event.type)) return false;
  final route = _getServerDataRoute(event.query);
  if (route?.serverId == serverId) return true;
  return _getActiveRouteForQueryKey(
        active: active,
        queryKey: event.query.queryKey,
        serverId: serverId,
      ) !=
      null;
}

/// The event types that can change the desired subscription set.
///
/// `updated` and `observerResultsUpdated` are excluded on purpose: a value
/// changing cannot change *whether* a feed is wanted, and reconciling on them
/// would make every push trigger a full cache walk.
bool _canEventChangeDesiredSubscriptions(PushQueryCacheEventType type) =>
    type == PushQueryCacheEventType.added ||
    type == PushQueryCacheEventType.removed ||
    type == PushQueryCacheEventType.observerAdded ||
    type == PushQueryCacheEventType.observerRemoved ||
    type == PushQueryCacheEventType.observerOptionsUpdated;

/// Reads a query's declared route, or null when it declares none.
ServerDataRoute? _getServerDataRoute(PushQuery query) {
  final meta = query.meta;
  if (meta == null) return null;
  final serverData = meta['serverData'];
  if (serverData is! Map) return null;
  return _readServerDataRoute(serverData.cast<String, Object?>());
}

/// Validates one `serverData` metadata object into a route.
///
/// Every field is re-checked because metadata is untyped by construction, and a
/// half-valid route is worse than none: it would open a feed nothing can consume.
/// An unknown `domain` yields null rather than throwing, so a query tagged by a
/// newer build of the app is ignored instead of crashing this one.
///
/// Deviation: Dart has one `null` where JavaScript has `null` and `undefined`.
/// Upstream's optional fields reject an explicit `null` (`baseRef !== undefined
/// && typeof baseRef !== "string"`) but accept absence, so absence is modelled
/// as a missing map key and `null` as a present null — and a present null is
/// rejected, exactly as upstream rejects it.
ServerDataRoute? _readServerDataRoute(Map<String, Object?> value) {
  final domain = value['domain'];
  final enabled = value['enabled'];
  final serverId = value['serverId'];
  final cwd = value['cwd'];
  if (enabled is! bool || serverId is! String || cwd is! String) return null;

  if (domain == 'checkoutDiff') {
    final subscriptionId = value['subscriptionId'];
    final compare = _readCheckoutDiffCompare(value['compare']);
    if (subscriptionId is! String || compare == null) return null;
    return CheckoutDiffRoute(
      enabled: enabled,
      serverId: serverId,
      cwd: cwd,
      subscriptionId: subscriptionId,
      compare: compare,
    );
  }

  if (domain == 'workspaceTerminals') {
    final workspaceId = value['workspaceId'];
    if (value.containsKey('workspaceId') && workspaceId is! String) return null;
    return WorkspaceTerminalsRoute(
      enabled: enabled,
      serverId: serverId,
      cwd: cwd,
      // JavaScript truthiness: `""` is dropped, so an empty workspace id is the
      // same route as no workspace id.
      workspaceId: workspaceId is String && workspaceId.isNotEmpty
          ? workspaceId
          : null,
    );
  }

  return null;
}

/// Validates the compare parameters out of route metadata.
///
/// An unrecognized mode rejects the whole route rather than defaulting: a diff
/// against the wrong base is worse than no diff. The result is a protocol
/// [CheckoutDiffCompare], constructed directly rather than through
/// `normalized()`, because normalization would drop a `baseRef` on an
/// `uncommitted` compare and upstream keeps it — and the kept value participates
/// in route equality.
CheckoutDiffCompare? _readCheckoutDiffCompare(Object? value) {
  if (value is! Map) return null;
  final compare = value.cast<String, Object?>();
  final mode = compare['mode'];
  final baseRef = compare['baseRef'];
  final ignoreWhitespace = compare['ignoreWhitespace'];
  if (mode != 'uncommitted' && mode != 'base') return null;
  if (compare.containsKey('baseRef') && baseRef is! String) return null;
  if (compare.containsKey('ignoreWhitespace') && ignoreWhitespace is! bool) {
    return null;
  }
  return CheckoutDiffCompare(
    mode: mode == 'base' ? CheckoutDiffMode.base : CheckoutDiffMode.uncommitted,
    // JavaScript truthiness again: an empty baseRef is dropped.
    baseRef: baseRef is String && baseRef.isNotEmpty ? baseRef : null,
    ignoreWhitespace: ignoreWhitespace == true,
  );
}

/// Whether two checkout-diff routes describe the same feed.
///
/// A null [left] is never equal, which is how a withdrawn subscription is told
/// apart from an unchanged one. The subscription id alone is not enough: the
/// consumer may reuse an id for different compare parameters, and that has to
/// close and reopen the feed.
bool _areCheckoutDiffRoutesEqual(
  CheckoutDiffRoute? left,
  CheckoutDiffRoute right,
) =>
    left != null &&
    left.serverId == right.serverId &&
    left.subscriptionId == right.subscriptionId &&
    left.cwd == right.cwd &&
    left.compare.mode == right.compare.mode &&
    left.compare.baseRef == right.compare.baseRef &&
    left.compare.ignoreWhitespace == right.compare.ignoreWhitespace;

/// Whether [queryKey] is the cache key of [route]'s diff.
///
/// Mirrors `checkoutDiffQueryKey` slot for slot, including its two
/// normalizations: a missing base ref is the empty string, and ignore-whitespace
/// is compared as a strict boolean.
bool _isCheckoutDiffQueryKeyForRoute(
  PushQueryKey queryKey,
  CheckoutDiffRoute route,
) =>
    queryKey.length >= 6 &&
    queryKey[0] == 'checkoutDiff' &&
    queryKey[1] == route.serverId &&
    queryKey[2] == route.cwd &&
    queryKey[3] == route.compare.mode.name &&
    queryKey[4] == (route.compare.baseRef ?? '') &&
    queryKey[5] == (route.compare.ignoreWhitespace == true);

/// Whether two terminals routes describe the same feed.
bool _areWorkspaceTerminalsRoutesEqual(
  WorkspaceTerminalsRoute left,
  WorkspaceTerminalsRoute right,
) =>
    left.serverId == right.serverId &&
    left.cwd == right.cwd &&
    left.workspaceId == right.workspaceId;

/// The active-map key for a terminals route.
///
/// A NUL separator, because a path and a workspace id are both arbitrary
/// strings and any printable separator could occur inside one: with a `:`, the
/// pair (`a`, `b:c`) and the pair (`a:b`, `c`) collapse to one key, so two
/// unrelated workspaces would share a single subscription.
String _workspaceTerminalSubscriptionKey(WorkspaceTerminalsRoute route) =>
    '${route.cwd}\u0000${route.workspaceId ?? ''}';

/// Closes a checkout-diff feed, tolerating a throw.
///
/// Disconnect cleanup can race with explicit subscription teardown: the socket
/// may already be gone by the time the router gets around to closing feeds, and
/// that is not a failure — the daemon has dropped the session anyway.
void _unsubscribeCheckoutDiff(
  ServerDataPushClient client,
  String subscriptionId,
) {
  try {
    client.unsubscribeCheckoutDiff(subscriptionId);
  } catch (_) {
    // Intentionally swallowed; see above.
  }
}

/// Whether [queryKey] is a [kind] key belonging to [serverId].
bool _isQueryForServer(PushQueryKey queryKey, String kind, String serverId) =>
    queryKey.length >= 2 && queryKey[0] == kind && queryKey[1] == serverId;

/// Whether a status payload is the daemon-config one.
///
/// The `config` presence check is upstream's `isRecord(payload.config)`: a
/// `daemon_config_changed` status without a config object is malformed and is
/// ignored rather than caching nothing over something.
bool _isDaemonConfigChangedPayload(Map<String, Object?> payload) =>
    payload['status'] == 'daemon_config_changed' && payload['config'] is Map;

// ---------------------------------------------------------------------------
// Query key hashing
// ---------------------------------------------------------------------------

/// A deterministic, type-tagged serialization of a query key.
///
/// TanStack's `hashKey` is a JSON stringify with sorted object keys; this is the
/// same idea with the types kept, so `"true"` and `true` — or `"1"` and `1` —
/// cannot land in the same cache entry. Object keys are sorted so two maps built
/// in different orders hash alike.
String _hashQueryKey(PushQueryKey queryKey) {
  final buffer = StringBuffer();
  _writeQueryKeyPart(buffer, queryKey);
  return buffer.toString();
}

void _writeQueryKeyPart(StringBuffer out, Object? value) {
  if (value is List) {
    out.write('[');
    for (final item in value) {
      _writeQueryKeyPart(out, item);
      out.write(',');
    }
    out.write(']');
    return;
  }
  if (value is Map) {
    final keys = value.keys.map((key) => '$key').toList()..sort();
    out.write('{');
    for (final key in keys) {
      out
        ..write(key)
        ..write(':');
      _writeQueryKeyPart(out, value[key]);
      out.write(',');
    }
    out.write('}');
    return;
  }
  out
    ..write(value.runtimeType)
    ..write('(')
    ..write(value)
    ..write(')');
}

/// Structural equality for one key element, recursing into lists and maps the
/// way TanStack's deep comparison does.
bool _queryKeyPartsEqual(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_queryKeyPartsEqual(left[index], right[index])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key)) return false;
      if (!_queryKeyPartsEqual(entry.value, right[entry.key])) return false;
    }
    return true;
  }
  return left == right;
}

bool _queryKeysEqual(PushQueryKey left, PushQueryKey right) =>
    left.length == right.length && _isQueryKeyPrefix(right, left);

/// Whether [prefix] is a prefix of [queryKey], element by element. TanStack's
/// default (`exact: false`) key filter.
bool _isQueryKeyPrefix(PushQueryKey prefix, PushQueryKey queryKey) {
  if (queryKey.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (!_queryKeyPartsEqual(queryKey[index], prefix[index])) return false;
  }
  return true;
}
