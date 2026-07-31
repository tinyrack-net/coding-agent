// Port of the upstream suite for `data/push-router.ts`, plus the edge cases it
// leaves unpinned.
//
// Upstream pins seven behaviors: provider/daemon-config routing and detachment,
// checkout-diff subscribe + write, no-retry after a failed subscribe, terminal
// subscribe + workspace filtering, reconnect re-subscription, routing after a
// metadata-less observer overwrites `meta`, and the per-server invalidation
// scope. Everything else here is unpinned upstream and pins behavior this port
// had to make a decision about: route-metadata validation (which rejects and
// which coerces), JavaScript truthiness on optional string fields, the
// observer-count and `enabled` gates, subscription replacement when a route's
// compare changes, the cache-event filter, unmount teardown, multi-router
// coexistence on one daemon, and the injected clock.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/data/paseo_push_router.dart';
import 'package:coding_agent_app/git/paseo_git_queries.dart'
    show checkoutDiffQueryKey;
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const String serverId = 'server-1';
const String otherServerId = 'server-2';
const String cwd = '/repo';
const String workspaceId = 'workspace-a';

/// A fixed instant, so the synthesized `terminals-changed-<ms>` request id is
/// an assertable constant rather than whatever the wall clock said.
final DateTime fixedNow = DateTime.utc(2026, 1, 1, 12);
DateTime testClock() => fixedNow;
final String fixedNowRequestId =
    'terminals-changed-${fixedNow.millisecondsSinceEpoch}';

/// Mirrors upstream's `daemonConfig` fixture.
const MutableDaemonConfig daemonConfig = MutableDaemonConfig(
  injectMcpIntoAgents: true,
  browserToolsEnabled: false,
  autoArchiveAfterMerge: false,
  enableTerminalAgentHooks: false,
  appendSystemPrompt: '',
);

/// The compare parameters used by every checkout-diff case, matching upstream.
const CheckoutDiffCompare baseCompare = CheckoutDiffCompare(
  mode: CheckoutDiffMode.base,
  baseRef: 'main',
  ignoreWhitespace: true,
);

/// [CheckoutDiffCompare] has no value equality, so recorded calls carry this
/// record instead of the object.
typedef ComparePlan = ({
  CheckoutDiffMode mode,
  String? baseRef,
  bool ignoreWhitespace,
});

ComparePlan planOf(CheckoutDiffCompare compare) => (
  mode: compare.mode,
  baseRef: compare.baseRef,
  ignoreWhitespace: compare.ignoreWhitespace,
);

const ComparePlan baseComparePlan = (
  mode: CheckoutDiffMode.base,
  baseRef: 'main',
  ignoreWhitespace: true,
);

typedef SubscribeCheckoutDiffCall = ({
  String cwd,
  ComparePlan compare,
  String subscriptionId,
  String? requestId,
});

typedef TerminalSubscriptionCall = ({String cwd, String? workspaceId});

/// Upstream builds subscription ids as `checkoutDiff:${JSON.stringify(key)}`;
/// the exact spelling is opaque to the router, so a readable join stands in.
String subscriptionIdFor(PushQueryKey queryKey) =>
    'checkoutDiff:${queryKey.join('|')}';

PaseoTerminalInfo terminal(
  String id, {
  required String name,
  String? workspaceId,
  TerminalActivity? activity,
  String terminalCwd = cwd,
}) => PaseoTerminalInfo(
  id: id,
  name: name,
  cwd: terminalCwd,
  workspaceId: workspaceId,
  activity: activity,
);

CheckoutDiffFile diffFile(String path) => CheckoutDiffFile(
  path: path,
  isNew: false,
  isDeleted: false,
  additions: 1,
  deletions: 0,
  hunks: const [],
);

ProvidersSnapshotUpdate providerUpdate(String generatedAt, {String? cwd}) =>
    ProvidersSnapshotUpdate(
      cwd: cwd,
      entries: const [
        ProviderSnapshotEntry(
          provider: 'codex',
          status: ProviderCatalogStatus.ready,
          models: [],
        ),
      ],
      generatedAt: generatedAt,
    );

// ---------------------------------------------------------------------------
// Fake client
// ---------------------------------------------------------------------------

/// The Dart analogue of upstream's `createFakeClient`.
///
/// Handlers are stored per message kind and dropped by the callback each
/// registration returns, so an unmounted router genuinely stops receiving —
/// which is what the detachment case asserts.
final class FakePushClient implements ServerDataPushClient {
  FakePushClient({this.rejectCheckoutDiffSubscribe = false});

  final bool rejectCheckoutDiffSubscribe;

  final List<void Function(ProvidersSnapshotUpdate)> _providersHandlers = [];
  final List<void Function(PaseoStatusPush)> _statusHandlers = [];
  final List<void Function(CheckoutDiffUpdate)> _diffUpdateHandlers = [];
  final List<void Function(SubscribeCheckoutDiffResponse)>
  _diffResponseHandlers = [];
  final List<void Function(TerminalsChanged)> _terminalsHandlers = [];

  final List<SubscribeCheckoutDiffCall> subscribeCheckoutDiffCalls = [];
  final List<String> unsubscribeCheckoutDiffCalls = [];
  final List<TerminalSubscriptionCall> subscribeTerminalCalls = [];
  final List<TerminalSubscriptionCall> unsubscribeTerminalCalls = [];

  /// When set, [unsubscribeCheckoutDiff] throws after recording, standing in
  /// for a socket that closed underneath the router.
  bool throwOnUnsubscribeCheckoutDiff = false;

  void Function() _register<T>(List<T> handlers, T handler) {
    handlers.add(handler);
    return () => handlers.remove(handler);
  }

  @override
  void Function() onProvidersSnapshotUpdate(
    void Function(ProvidersSnapshotUpdate message) handler,
  ) => _register(_providersHandlers, handler);

  @override
  void Function() onStatus(void Function(PaseoStatusPush message) handler) =>
      _register(_statusHandlers, handler);

  @override
  void Function() onCheckoutDiffUpdate(
    void Function(CheckoutDiffUpdate message) handler,
  ) => _register(_diffUpdateHandlers, handler);

  @override
  void Function() onSubscribeCheckoutDiffResponse(
    void Function(SubscribeCheckoutDiffResponse message) handler,
  ) => _register(_diffResponseHandlers, handler);

  @override
  void Function() onTerminalsChanged(
    void Function(TerminalsChanged message) handler,
  ) => _register(_terminalsHandlers, handler);

  @override
  Future<SubscribeCheckoutDiffResponse> subscribeCheckoutDiff(
    String cwd,
    CheckoutDiffCompare compare, {
    required String subscriptionId,
    String? requestId,
  }) async {
    subscribeCheckoutDiffCalls.add((
      cwd: cwd,
      compare: planOf(compare),
      subscriptionId: subscriptionId,
      requestId: requestId,
    ));
    if (rejectCheckoutDiffSubscribe) {
      throw StateError('subscribe failed');
    }
    return SubscribeCheckoutDiffResponse(
      payload: CheckoutDiffPayload(
        subscriptionId: subscriptionId,
        cwd: cwd,
        files: const [],
        error: null,
      ),
      requestId: requestId ?? 'subscribe-checkout-diff',
    );
  }

  @override
  void unsubscribeCheckoutDiff(String subscriptionId) {
    unsubscribeCheckoutDiffCalls.add(subscriptionId);
    if (throwOnUnsubscribeCheckoutDiff) {
      throw StateError('socket already closed');
    }
  }

  @override
  void subscribeTerminals({required String cwd, String? workspaceId}) =>
      subscribeTerminalCalls.add((cwd: cwd, workspaceId: workspaceId));

  @override
  void unsubscribeTerminals({required String cwd, String? workspaceId}) =>
      unsubscribeTerminalCalls.add((cwd: cwd, workspaceId: workspaceId));

  void emitProviders(ProvidersSnapshotUpdate message) {
    for (final handler in _providersHandlers.toList()) {
      handler(message);
    }
  }

  void emitStatus(Map<String, Object?> payload) {
    for (final handler in _statusHandlers.toList()) {
      handler(PaseoStatusPush(payload));
    }
  }

  void emitDiffUpdate(CheckoutDiffUpdate message) {
    for (final handler in _diffUpdateHandlers.toList()) {
      handler(message);
    }
  }

  void emitDiffResponse(SubscribeCheckoutDiffResponse message) {
    for (final handler in _diffResponseHandlers.toList()) {
      handler(message);
    }
  }

  void emitTerminalsChanged(TerminalsChanged message) {
    for (final handler in _terminalsHandlers.toList()) {
      handler(message);
    }
  }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

final class Harness {
  Harness({bool rejectCheckoutDiffSubscribe = false})
    : client = FakePushClient(
        rejectCheckoutDiffSubscribe: rejectCheckoutDiffSubscribe,
      );

  final PushQueryCache cache = PushQueryCache();
  final FakePushClient client;
  final List<CheckoutDiffSubscribeFailure> subscribeFailures = [];
  final List<void Function()> _teardown = [];

  void Function() mount({String id = serverId}) {
    final dispose = mountServerDataPushRouter(
      ServerDataPushRouterOptions(
        client: client,
        queryClient: cache,
        serverId: id,
        clock: testClock,
        onSubscribeCheckoutDiffError: subscribeFailures.add,
      ),
    );
    _teardown.add(dispose);
    return dispose;
  }

  /// Builds an observer and attaches it, registering the detach for teardown so
  /// no case can leak an observer into the module-global repair registry.
  ({PushQueryObserver observer, void Function() detach}) observe(
    PushQueryKey queryKey, {
    Map<String, Object?>? meta,
  }) {
    final observer = PushQueryObserver(cache, queryKey: queryKey, meta: meta);
    final detach = observer.subscribe();
    _teardown.add(detach);
    return (observer: observer, detach: detach);
  }

  void disposeAll() {
    for (final dispose in _teardown.reversed.toList()) {
      dispose();
    }
    _teardown.clear();
  }
}

/// Lets the microtasks a fire-and-forget subscribe schedules run.
Future<void> settle() async {
  await Future<void>.value();
  await Future<void>.value();
  await Future<void>.value();
}

CheckoutDiffCachePayload diffPayloadAt(
  PushQueryCache cache,
  PushQueryKey key,
) => cache.getQueryData(key)! as CheckoutDiffCachePayload;

ListTerminalsCachePayload terminalsPayloadAt(
  PushQueryCache cache,
  PushQueryKey key,
) => cache.getQueryData(key)! as ListTerminalsCachePayload;

void main() {
  // -------------------------------------------------------------------------
  // Upstream suite
  // -------------------------------------------------------------------------

  group('server data push router (upstream suite)', () {
    test(
      'routes provider snapshot and daemon config payloads until detached',
      () {
        final harness = Harness();
        final unmount = harness.mount();

        harness.client.emitProviders(
          providerUpdate('2026-01-01T00:00:00.000Z'),
        );
        harness.client.emitStatus({
          'status': 'daemon_config_changed',
          'config': daemonConfig.toJson(),
        });

        final snapshot =
            harness.cache.getQueryData(providersSnapshotQueryKey(serverId))!
                as GetProvidersSnapshotResponse;
        expect(snapshot.entries.single.provider, 'codex');
        expect(snapshot.entries.single.status, ProviderCatalogStatus.ready);
        expect(snapshot.entries.single.enabled, isTrue);
        expect(snapshot.generatedAt, '2026-01-01T00:00:00.000Z');
        expect(snapshot.requestId, 'providers_snapshot_update');

        final config =
            harness.cache.getQueryData(daemonConfigQueryKey(serverId))!
                as MutableDaemonConfig;
        expect(config.injectMcpIntoAgents, isTrue);
        expect(config.browserToolsEnabled, isFalse);
        expect(config.appendSystemPrompt, '');

        unmount();
        harness.client.emitProviders(
          providerUpdate('2026-01-01T00:00:01.000Z'),
        );

        final afterDetach =
            harness.cache.getQueryData(providersSnapshotQueryKey(serverId))!
                as GetProvidersSnapshotResponse;
        expect(afterDetach.generatedAt, '2026-01-01T00:00:00.000Z');

        harness.disposeAll();
      },
    );

    test(
      'subscribes active checkout diff queries and writes matching diff events',
      () {
        final harness = Harness();
        final queryKey = checkoutDiffQueryKey(
          serverId,
          cwd,
          CheckoutDiffMode.base,
          'main',
          true,
        );
        final subscriptionId = subscriptionIdFor(queryKey);
        final query = harness.observe(
          queryKey,
          meta: checkoutDiffPushRoute(
            enabled: true,
            serverId: serverId,
            subscriptionId: subscriptionId,
            cwd: cwd,
            compare: baseCompare,
          ),
        );
        harness.mount();

        expect(harness.client.subscribeCheckoutDiffCalls, [
          (
            cwd: cwd,
            compare: baseComparePlan,
            subscriptionId: subscriptionId,
            requestId: 'push-router:$serverId:$subscriptionId',
          ),
        ]);

        harness.client.emitDiffResponse(
          SubscribeCheckoutDiffResponse(
            payload: CheckoutDiffPayload(
              subscriptionId: subscriptionId,
              cwd: cwd,
              files: const [],
              error: null,
            ),
            requestId: 'diff-1',
          ),
        );

        final response = diffPayloadAt(harness.cache, queryKey);
        expect(response.cwd, cwd);
        expect(response.files, isEmpty);
        expect(response.error, isNull);
        expect(response.requestId, 'diff-1');

        harness.client.emitDiffUpdate(
          CheckoutDiffUpdate(
            CheckoutDiffPayload(
              subscriptionId: subscriptionId,
              cwd: cwd,
              files: const [],
              error: null,
            ),
          ),
        );

        expect(
          diffPayloadAt(harness.cache, queryKey).requestId,
          'subscription:$subscriptionId',
        );

        query.detach();

        expect(harness.client.unsubscribeCheckoutDiffCalls, [subscriptionId]);

        harness.disposeAll();
      },
    );

    test(
      'does not retry failed subscriptions on unrelated cache events',
      () async {
        final harness = Harness(rejectCheckoutDiffSubscribe: true);
        final queryKey = checkoutDiffQueryKey(
          serverId,
          cwd,
          CheckoutDiffMode.base,
          'main',
          true,
        );
        harness.observe(
          queryKey,
          meta: checkoutDiffPushRoute(
            enabled: true,
            serverId: serverId,
            subscriptionId: subscriptionIdFor(queryKey),
            cwd: cwd,
            compare: baseCompare,
          ),
        );
        harness.mount();

        expect(harness.client.subscribeCheckoutDiffCalls, hasLength(1));

        await settle();

        harness.cache.setQueryData(['unrelated'], 'value');

        expect(harness.client.subscribeCheckoutDiffCalls, hasLength(1));
        expect(harness.subscribeFailures, hasLength(1));
        expect(harness.subscribeFailures.single.cwd, cwd);
        expect(harness.subscribeFailures.single.serverId, serverId);

        harness.disposeAll();
      },
    );

    test(
      'subscribes active terminal queries and filters terminal pushes by workspace',
      () {
        final harness = Harness();
        final queryKey = terminalsQueryKey(serverId, cwd, workspaceId);
        final query = harness.observe(
          queryKey,
          meta: workspaceTerminalsPushRoute(
            enabled: true,
            serverId: serverId,
            cwd: cwd,
            workspaceId: workspaceId,
          ),
        );
        harness.mount();

        expect(harness.client.subscribeTerminalCalls, [
          (cwd: cwd, workspaceId: workspaceId),
        ]);

        harness.client.emitTerminalsChanged(
          TerminalsChanged(
            cwd: cwd,
            terminals: [
              terminal('terminal-a', name: 'Main', workspaceId: workspaceId),
              terminal(
                'terminal-b',
                name: 'Sibling',
                workspaceId: 'workspace-b',
              ),
            ],
          ),
        );

        final payload = terminalsPayloadAt(harness.cache, queryKey);
        expect(payload.cwd, cwd);
        expect(payload.terminals.map((entry) => entry.id), ['terminal-a']);
        expect(payload.requestId, startsWith('terminals-changed-'));

        query.detach();

        expect(harness.client.unsubscribeTerminalCalls, [
          (cwd: cwd, workspaceId: workspaceId),
        ]);

        harness.disposeAll();
      },
    );

    test('re-sends active push subscriptions after reconnect', () {
      final harness = Harness();
      final checkoutDiffKey = checkoutDiffQueryKey(
        serverId,
        cwd,
        CheckoutDiffMode.base,
        'main',
        true,
      );
      final checkoutDiffSubscriptionId = subscriptionIdFor(checkoutDiffKey);
      final terminalKey = terminalsQueryKey(serverId, cwd, workspaceId);
      harness.observe(
        checkoutDiffKey,
        meta: checkoutDiffPushRoute(
          enabled: true,
          serverId: serverId,
          subscriptionId: checkoutDiffSubscriptionId,
          cwd: cwd,
          compare: baseCompare,
        ),
      );
      harness.observe(
        terminalKey,
        meta: workspaceTerminalsPushRoute(
          enabled: true,
          serverId: serverId,
          cwd: cwd,
          workspaceId: workspaceId,
        ),
      );
      harness.mount();

      // Metadata-less observers on the same keys: constructing them clears
      // `meta`, which is exactly the state the reconnect repair has to survive.
      harness.observe(checkoutDiffKey);
      harness.observe(terminalKey);

      invalidateServerDataQueriesAfterReconnect(
        queryClient: harness.cache,
        serverId: serverId,
      );

      expect(harness.client.subscribeCheckoutDiffCalls, [
        (
          cwd: cwd,
          compare: baseComparePlan,
          subscriptionId: checkoutDiffSubscriptionId,
          requestId: 'push-router:$serverId:$checkoutDiffSubscriptionId',
        ),
        (
          cwd: cwd,
          compare: baseComparePlan,
          subscriptionId: checkoutDiffSubscriptionId,
          requestId: 'push-router:$serverId:$checkoutDiffSubscriptionId',
        ),
      ]);
      expect(harness.client.subscribeTerminalCalls, [
        (cwd: cwd, workspaceId: workspaceId),
        (cwd: cwd, workspaceId: workspaceId),
      ]);

      harness.client.emitTerminalsChanged(
        TerminalsChanged(
          cwd: cwd,
          terminals: [
            terminal('terminal-a', name: 'Main', workspaceId: workspaceId),
            terminal('terminal-b', name: 'Sibling', workspaceId: 'workspace-b'),
          ],
        ),
      );

      final payload = terminalsPayloadAt(harness.cache, terminalKey);
      expect(payload.terminals.map((entry) => entry.id), ['terminal-a']);
      expect(payload.requestId, fixedNowRequestId);

      harness.disposeAll();
    });

    test(
      'routes terminal pushes after another observer attaches without push metadata',
      () {
        final harness = Harness();
        final queryKey = terminalsQueryKey(serverId, cwd, workspaceId);
        harness.observe(
          queryKey,
          meta: workspaceTerminalsPushRoute(
            enabled: true,
            serverId: serverId,
            cwd: cwd,
            workspaceId: workspaceId,
          ),
        );
        harness.mount();
        expect(harness.client.subscribeTerminalCalls, [
          (cwd: cwd, workspaceId: workspaceId),
        ]);

        harness.observe(queryKey);

        harness.client.emitTerminalsChanged(
          TerminalsChanged(
            cwd: cwd,
            terminals: [
              terminal(
                'terminal-a',
                name: 'Main',
                workspaceId: workspaceId,
                activity: const TerminalActivity(
                  state: TerminalActivityState.idle,
                  attentionReason: TerminalActivityAttentionReason.needsInput,
                  changedAt: 1,
                ),
              ),
            ],
          ),
        );

        final payload = terminalsPayloadAt(harness.cache, queryKey);
        expect(payload.terminals, hasLength(1));
        expect(payload.terminals.single.id, 'terminal-a');
        expect(
          payload.terminals.single.activity?.attentionReason,
          TerminalActivityAttentionReason.needsInput,
        );
        expect(payload.terminals.single.activity?.changedAt, 1);
        expect(payload.requestId, startsWith('terminals-changed-'));
        expect(harness.client.unsubscribeTerminalCalls, isEmpty);

        harness.disposeAll();
      },
    );

    test('invalidates only the reconnect-repair scopes for one server', () {
      final cache = PushQueryCache();
      final providerKey = providersSnapshotQueryKey(serverId);
      final configKey = daemonConfigQueryKey(serverId);
      final diffKey = checkoutDiffQueryKey(
        serverId,
        cwd,
        CheckoutDiffMode.uncommitted,
        null,
        false,
      );
      final terminalKey = terminalsQueryKey(serverId, cwd, workspaceId);
      final otherProviderKey = providersSnapshotQueryKey(otherServerId);

      cache.setQueryData(providerKey, 'p');
      cache.setQueryData(configKey, 'c');
      cache.setQueryData(diffKey, 'd');
      cache.setQueryData(terminalKey, 't');
      cache.setQueryData(otherProviderKey, 'other');

      invalidateServerDataQueriesAfterReconnect(
        queryClient: cache,
        serverId: serverId,
      );

      expect(cache.getQuery(providerKey)!.isInvalidated, isTrue);
      expect(cache.getQuery(configKey)!.isInvalidated, isTrue);
      expect(cache.getQuery(diffKey)!.isInvalidated, isTrue);
      expect(cache.getQuery(terminalKey)!.isInvalidated, isTrue);
      expect(cache.getQuery(otherProviderKey)!.isInvalidated, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Query keys
  // -------------------------------------------------------------------------

  group('query keys', () {
    test(
      'providers-snapshot keys separate the home scope from a cwd scope',
      () {
        expect(providersSnapshotQueryKey(serverId), [
          'providersSnapshot',
          serverId,
          'home',
        ]);
        expect(providersSnapshotQueryKey(serverId, '/repo/'), [
          'providersSnapshot',
          serverId,
          'cwd',
          '/repo',
        ]);
        // A blank cwd normalizes away entirely and lands on the home scope.
        expect(
          providersSnapshotQueryKey(serverId, '   '),
          providersSnapshotQueryKey(serverId),
        );
      },
    );

    test(
      'the providers-snapshot root is a prefix of every scope beneath it',
      () {
        final cache = PushQueryCache();
        cache.setQueryData(providersSnapshotQueryKey(serverId), 'home');
        cache.setQueryData(
          providersSnapshotQueryKey(serverId, '/repo'),
          'repo',
        );
        cache.invalidateQueries(
          queryKey: providersSnapshotQueryRootKey(serverId),
        );
        expect(
          cache.getAll().where((query) => query.isInvalidated),
          hasLength(2),
        );
      },
    );

    test('a workspace-less terminals key still has four slots', () {
      expect(terminalsQueryKey(serverId, cwd), [
        'terminals',
        serverId,
        cwd,
        null,
      ]);
    });

    test('the daemon-config key keeps its hyphenated namespace', () {
      expect(daemonConfigQueryKey(serverId), ['daemon-config', serverId]);
    });

    test('the agent-commands root is the namespace a snapshot push sweeps', () {
      expect(agentCommandsQueryRootKey(serverId), ['agentCommands', serverId]);
    });
  });

  // -------------------------------------------------------------------------
  // Cache substrate
  // -------------------------------------------------------------------------

  group('push query cache', () {
    test('hashes keys structurally, not by identity', () {
      final cache = PushQueryCache();
      cache.setQueryData(['a', 1, true], 'value');
      expect(cache.getQueryData(['a', 1, true]), 'value');
    });

    test('does not conflate a string with the scalar that prints alike', () {
      final cache = PushQueryCache();
      cache.setQueryData(['k', true], 'boolean');
      cache.setQueryData(['k', 'true'], 'string');
      cache.setQueryData(['k', 1], 'number');
      cache.setQueryData(['k', '1'], 'numeric string');
      expect(cache.getQueryData(['k', true]), 'boolean');
      expect(cache.getQueryData(['k', 'true']), 'string');
      expect(cache.getQueryData(['k', 1]), 'number');
      expect(cache.getQueryData(['k', '1']), 'numeric string');
    });

    test('caches a key on first write and reports insertion order', () {
      final cache = PushQueryCache();
      cache.setQueryData(['second'], 2);
      cache.setQueryData(['first'], 1);
      expect(cache.getAll().map((query) => query.queryKey.first), [
        'second',
        'first',
      ]);
    });

    test('an updater sees null on a cold key and the value afterwards', () {
      final cache = PushQueryCache();
      final seen = <Object?>[];
      cache.setQueryDataWith(['k'], (current) {
        seen.add(current);
        return 1;
      });
      cache.setQueryDataWith(['k'], (current) {
        seen.add(current);
        return 2;
      });
      expect(seen, [null, 1]);
      expect(cache.getQueryData(['k']), 2);
    });

    test('distinguishes a cached null from a key that was never written', () {
      final cache = PushQueryCache();
      cache.setQueryData(['written'], null);
      expect(cache.getQuery(['written'])!.hasData, isTrue);
      expect(cache.getQuery(['never']), isNull);
    });

    test('key invalidation matches by prefix, and exact when asked', () {
      final cache = PushQueryCache();
      cache.setQueryData(['root', serverId, 'leaf'], 'deep');
      cache.setQueryData(['root', otherServerId], 'other');
      cache.invalidateQueries(queryKey: ['root', serverId]);
      expect(cache.getQuery(['root', serverId, 'leaf'])!.isInvalidated, isTrue);
      expect(cache.getQuery(['root', otherServerId])!.isInvalidated, isFalse);

      final exactCache = PushQueryCache();
      exactCache.setQueryData(['root', serverId, 'leaf'], 'deep');
      exactCache.invalidateQueries(queryKey: ['root', serverId], exact: true);
      expect(
        exactCache.getQuery(['root', serverId, 'leaf'])!.isInvalidated,
        isFalse,
      );
    });

    test('a key filter and a predicate must both match', () {
      final cache = PushQueryCache();
      cache.setQueryData(['root', 'a'], 1);
      cache.setQueryData(['root', 'b'], 2);
      cache.invalidateQueries(
        queryKey: ['root'],
        predicate: (query) => query.queryKey[1] == 'b',
      );
      expect(cache.getQuery(['root', 'a'])!.isInvalidated, isFalse);
      expect(cache.getQuery(['root', 'b'])!.isInvalidated, isTrue);
    });

    test('emits added then updated for a cold write, and removed on drop', () {
      final cache = PushQueryCache();
      final events = <PushQueryCacheEventType>[];
      final stop = cache.subscribe((event) => events.add(event.type));
      cache.setQueryData(['k'], 1);
      cache.setQueryData(['k'], 2);
      cache.remove(['k']);
      cache.remove(['k']);
      stop();
      cache.setQueryData(['k'], 3);
      expect(events, [
        PushQueryCacheEventType.added,
        PushQueryCacheEventType.updated,
        PushQueryCacheEventType.updated,
        PushQueryCacheEventType.removed,
      ]);
    });

    test('an observer raises the count only while subscribed', () {
      final cache = PushQueryCache();
      final observer = PushQueryObserver(cache, queryKey: ['k']);
      expect(cache.getQuery(['k'])!.getObserversCount(), 0);
      final detach = observer.subscribe();
      expect(cache.getQuery(['k'])!.getObserversCount(), 1);
      detach();
      detach();
      expect(cache.getQuery(['k'])!.getObserversCount(), 0);
    });

    test('subscribing twice without detaching is an error', () {
      final cache = PushQueryCache();
      final observer = PushQueryObserver(cache, queryKey: ['k']);
      addTearDown(observer.subscribe());
      expect(observer.subscribe, throwsStateError);
    });

    test('a later observer overwrites the metadata of an earlier one', () {
      final cache = PushQueryCache();
      final first = PushQueryObserver(
        cache,
        queryKey: ['k'],
        meta: const {'serverData': <String, Object?>{}},
      );
      expect(first.query.meta, isNotNull);
      PushQueryObserver(cache, queryKey: ['k']);
      expect(first.query.meta, isNull);
    });

    test('setMeta signals only while the observer is attached', () {
      final cache = PushQueryCache();
      final events = <PushQueryCacheEventType>[];
      final observer = PushQueryObserver(cache, queryKey: ['k']);
      final stop = cache.subscribe((event) => events.add(event.type));
      observer.setMeta(const {'a': 1});
      expect(events, isEmpty);
      final detach = observer.subscribe();
      observer.setMeta(const {'a': 2});
      expect(events, [
        PushQueryCacheEventType.observerAdded,
        PushQueryCacheEventType.observerOptionsUpdated,
      ]);
      detach();
      stop();
    });
  });

  // -------------------------------------------------------------------------
  // Route metadata
  // -------------------------------------------------------------------------

  group('route metadata', () {
    /// Mounts a router with one attached query carrying [meta] and reports what
    /// the router decided to subscribe to.
    Harness subscribeWith(Map<String, Object?> meta, {PushQueryKey? queryKey}) {
      final harness = Harness();
      harness.observe(
        queryKey ??
            checkoutDiffQueryKey(
              serverId,
              cwd,
              CheckoutDiffMode.base,
              'main',
              true,
            ),
        meta: meta,
      );
      harness.mount();
      addTearDown(harness.disposeAll);
      return harness;
    }

    test('a well-formed checkout-diff route subscribes', () {
      final harness = subscribeWith(
        checkoutDiffPushRoute(
          enabled: true,
          serverId: serverId,
          subscriptionId: 'sub',
          cwd: cwd,
          compare: baseCompare,
        ),
      );
      expect(harness.client.subscribeCheckoutDiffCalls, hasLength(1));
    });

    test('a disabled route is ignored', () {
      final harness = subscribeWith(
        checkoutDiffPushRoute(
          enabled: false,
          serverId: serverId,
          subscriptionId: 'sub',
          cwd: cwd,
          compare: baseCompare,
        ),
      );
      expect(harness.client.subscribeCheckoutDiffCalls, isEmpty);
    });

    test("a route naming another daemon is not this router's business", () {
      final harness = subscribeWith(
        checkoutDiffPushRoute(
          enabled: true,
          serverId: otherServerId,
          subscriptionId: 'sub',
          cwd: cwd,
          compare: baseCompare,
        ),
      );
      expect(harness.client.subscribeCheckoutDiffCalls, isEmpty);
    });

    test('a query with no observers is not subscribed', () {
      final harness = Harness();
      final queryKey = checkoutDiffQueryKey(
        serverId,
        cwd,
        CheckoutDiffMode.base,
        'main',
        true,
      );
      // Constructed but never subscribed: the entry exists with metadata, but
      // nobody is looking at it.
      PushQueryObserver(
        harness.cache,
        queryKey: queryKey,
        meta: checkoutDiffPushRoute(
          enabled: true,
          serverId: serverId,
          subscriptionId: 'sub',
          cwd: cwd,
          compare: baseCompare,
        ),
      );
      harness.mount();
      expect(harness.client.subscribeCheckoutDiffCalls, isEmpty);
      harness.disposeAll();
    });

    test('malformed route metadata is rejected rather than half-read', () {
      final rejected = <String, Map<String, Object?>>{
        'non-boolean enabled': {
          'domain': 'checkoutDiff',
          'enabled': 'yes',
          'serverId': serverId,
          'cwd': cwd,
          'subscriptionId': 'sub',
          'compare': {'mode': 'base'},
        },
        'non-string serverId': {
          'domain': 'checkoutDiff',
          'enabled': true,
          'serverId': 1,
          'cwd': cwd,
          'subscriptionId': 'sub',
          'compare': {'mode': 'base'},
        },
        'non-string cwd': {
          'domain': 'checkoutDiff',
          'enabled': true,
          'serverId': serverId,
          'cwd': null,
          'subscriptionId': 'sub',
          'compare': {'mode': 'base'},
        },
        'unknown domain': {
          'domain': 'somethingElse',
          'enabled': true,
          'serverId': serverId,
          'cwd': cwd,
        },
        'missing subscriptionId': {
          'domain': 'checkoutDiff',
          'enabled': true,
          'serverId': serverId,
          'cwd': cwd,
          'compare': {'mode': 'base'},
        },
        'missing compare': {
          'domain': 'checkoutDiff',
          'enabled': true,
          'serverId': serverId,
          'cwd': cwd,
          'subscriptionId': 'sub',
        },
        'unknown compare mode': {
          'domain': 'checkoutDiff',
          'enabled': true,
          'serverId': serverId,
          'cwd': cwd,
          'subscriptionId': 'sub',
          'compare': {'mode': 'staged'},
        },
        'explicitly null baseRef': {
          'domain': 'checkoutDiff',
          'enabled': true,
          'serverId': serverId,
          'cwd': cwd,
          'subscriptionId': 'sub',
          'compare': {'mode': 'base', 'baseRef': null},
        },
        'non-boolean ignoreWhitespace': {
          'domain': 'checkoutDiff',
          'enabled': true,
          'serverId': serverId,
          'cwd': cwd,
          'subscriptionId': 'sub',
          'compare': {'mode': 'base', 'ignoreWhitespace': 'yes'},
        },
      };

      for (final entry in rejected.entries) {
        final harness = subscribeWith({'serverData': entry.value});
        expect(
          harness.client.subscribeCheckoutDiffCalls,
          isEmpty,
          reason: entry.key,
        );
      }
    });

    test('metadata that is not a serverData object carries no route', () {
      for (final meta in <Map<String, Object?>>[
        <String, Object?>{},
        {'serverData': null},
        {'serverData': 'checkoutDiff'},
      ]) {
        final harness = subscribeWith(meta);
        expect(harness.client.subscribeCheckoutDiffCalls, isEmpty);
      }
    });

    test('an omitted compare baseRef is accepted; a null one is not', () {
      final accepted = subscribeWith({
        'serverData': {
          'domain': 'checkoutDiff',
          'enabled': true,
          'serverId': serverId,
          'cwd': cwd,
          'subscriptionId': 'sub',
          'compare': {'mode': 'uncommitted'},
        },
      });
      expect(accepted.client.subscribeCheckoutDiffCalls.single.compare, (
        mode: CheckoutDiffMode.uncommitted,
        baseRef: null,
        ignoreWhitespace: false,
      ));
    });

    test(
      'an empty compare baseRef is dropped, as JavaScript truthiness does',
      () {
        final harness = subscribeWith(
          checkoutDiffPushRoute(
            enabled: true,
            serverId: serverId,
            subscriptionId: 'sub',
            cwd: cwd,
            compare: const CheckoutDiffCompare(
              mode: CheckoutDiffMode.base,
              baseRef: '',
            ),
          ),
        );
        expect(
          harness.client.subscribeCheckoutDiffCalls.single.compare.baseRef,
          isNull,
        );
      },
    );

    test('an uncommitted compare keeps a baseRef the caller supplied', () {
      // The protocol's `normalized()` would strip it; the router deliberately
      // does not normalize, because the kept value participates in route
      // equality.
      final harness = subscribeWith(
        checkoutDiffPushRoute(
          enabled: true,
          serverId: serverId,
          subscriptionId: 'sub',
          cwd: cwd,
          compare: const CheckoutDiffCompare(
            mode: CheckoutDiffMode.uncommitted,
            baseRef: 'main',
          ),
        ),
      );
      expect(harness.client.subscribeCheckoutDiffCalls.single.compare, (
        mode: CheckoutDiffMode.uncommitted,
        baseRef: 'main',
        ignoreWhitespace: false,
      ));
    });

    test('an empty workspace id is the same route as none at all', () {
      final route = workspaceTerminalsPushRoute(
        enabled: true,
        serverId: serverId,
        cwd: cwd,
        workspaceId: '',
      );
      expect((route['serverData']! as Map).containsKey('workspaceId'), isFalse);

      final harness = Harness();
      harness.observe(terminalsQueryKey(serverId, cwd), meta: route);
      harness.mount();
      expect(harness.client.subscribeTerminalCalls, [
        (cwd: cwd, workspaceId: null),
      ]);
      harness.disposeAll();
    });

    test('an explicitly null workspace id in metadata rejects the route', () {
      final harness = Harness();
      harness.observe(
        terminalsQueryKey(serverId, cwd),
        meta: const {
          'serverData': <String, Object?>{
            'domain': 'workspaceTerminals',
            'enabled': true,
            'serverId': serverId,
            'cwd': cwd,
            'workspaceId': null,
          },
        },
      );
      harness.mount();
      expect(harness.client.subscribeTerminalCalls, isEmpty);
      harness.disposeAll();
    });
  });

  // -------------------------------------------------------------------------
  // Reconciliation
  // -------------------------------------------------------------------------

  group('subscription reconciliation', () {
    test(
      'changing a route replaces the feed under the same subscription id',
      () {
        final harness = Harness();
        final queryKey = checkoutDiffQueryKey(
          serverId,
          cwd,
          CheckoutDiffMode.base,
          'main',
          true,
        );
        final query = harness.observe(
          queryKey,
          meta: checkoutDiffPushRoute(
            enabled: true,
            serverId: serverId,
            subscriptionId: 'sub',
            cwd: cwd,
            compare: baseCompare,
          ),
        );
        harness.mount();
        expect(harness.client.subscribeCheckoutDiffCalls, hasLength(1));

        query.observer.setMeta(
          checkoutDiffPushRoute(
            enabled: true,
            serverId: serverId,
            subscriptionId: 'sub',
            cwd: cwd,
            compare: const CheckoutDiffCompare(
              mode: CheckoutDiffMode.base,
              baseRef: 'develop',
              ignoreWhitespace: true,
            ),
          ),
        );

        expect(harness.client.unsubscribeCheckoutDiffCalls, ['sub']);
        expect(harness.client.subscribeCheckoutDiffCalls, hasLength(2));
        expect(
          harness.client.subscribeCheckoutDiffCalls.last.compare.baseRef,
          'develop',
        );

        harness.disposeAll();
      },
    );

    test('an unchanged route is left alone across reconciliations', () {
      final harness = Harness();
      final queryKey = terminalsQueryKey(serverId, cwd, workspaceId);
      final route = workspaceTerminalsPushRoute(
        enabled: true,
        serverId: serverId,
        cwd: cwd,
        workspaceId: workspaceId,
      );
      final query = harness.observe(queryKey, meta: route);
      harness.mount();
      query.observer.setMeta(route);
      query.observer.setMeta(route);
      expect(harness.client.subscribeTerminalCalls, hasLength(1));
      expect(harness.client.unsubscribeTerminalCalls, isEmpty);
      harness.disposeAll();
    });

    test('changing a terminal route re-keys the feed', () {
      final harness = Harness();
      final queryKey = terminalsQueryKey(serverId, cwd, workspaceId);
      final query = harness.observe(
        queryKey,
        meta: workspaceTerminalsPushRoute(
          enabled: true,
          serverId: serverId,
          cwd: cwd,
          workspaceId: workspaceId,
        ),
      );
      harness.mount();
      query.observer.setMeta(
        workspaceTerminalsPushRoute(
          enabled: true,
          serverId: serverId,
          cwd: cwd,
          workspaceId: 'workspace-b',
        ),
      );
      expect(harness.client.subscribeTerminalCalls, [
        (cwd: cwd, workspaceId: workspaceId),
        (cwd: cwd, workspaceId: 'workspace-b'),
      ]);
      expect(harness.client.unsubscribeTerminalCalls, [
        (cwd: cwd, workspaceId: workspaceId),
      ]);
      harness.disposeAll();
    });

    test('dropping the query from the cache closes its feed', () {
      final harness = Harness();
      final queryKey = terminalsQueryKey(serverId, cwd, workspaceId);
      harness.observe(
        queryKey,
        meta: workspaceTerminalsPushRoute(
          enabled: true,
          serverId: serverId,
          cwd: cwd,
          workspaceId: workspaceId,
        ),
      );
      harness.mount();
      harness.cache.remove(queryKey);
      expect(harness.client.unsubscribeTerminalCalls, [
        (cwd: cwd, workspaceId: workspaceId),
      ]);
      harness.disposeAll();
    });

    test('a cache write on a routed key does not re-reconcile', () {
      final harness = Harness();
      final queryKey = terminalsQueryKey(serverId, cwd, workspaceId);
      harness.observe(
        queryKey,
        meta: workspaceTerminalsPushRoute(
          enabled: true,
          serverId: serverId,
          cwd: cwd,
          workspaceId: workspaceId,
        ),
      );
      harness.mount();
      harness.cache.setQueryData(queryKey, 'anything');
      expect(harness.client.subscribeTerminalCalls, hasLength(1));
      harness.disposeAll();
    });

    test('two queries wanting one subscription open it once', () {
      final harness = Harness();
      final meta = checkoutDiffPushRoute(
        enabled: true,
        serverId: serverId,
        subscriptionId: 'shared',
        cwd: cwd,
        compare: baseCompare,
      );
      harness.observe([
        'checkoutDiff',
        serverId,
        cwd,
        'base',
        'main',
        true,
      ], meta: meta);
      harness.observe(['some-other-consumer', serverId], meta: meta);
      harness.mount();
      expect(harness.client.subscribeCheckoutDiffCalls, hasLength(1));
      harness.disposeAll();
    });

    test('a rejected subscribe withdraws the active record', () async {
      final harness = Harness(rejectCheckoutDiffSubscribe: true);
      final queryKey = checkoutDiffQueryKey(
        serverId,
        cwd,
        CheckoutDiffMode.base,
        'main',
        true,
      );
      harness.observe(
        queryKey,
        meta: checkoutDiffPushRoute(
          enabled: true,
          serverId: serverId,
          subscriptionId: 'sub',
          cwd: cwd,
          compare: baseCompare,
        ),
      );
      final unmount = harness.mount();
      await settle();
      // Withdrawn, so unmount has nothing to close.
      unmount();
      expect(harness.client.unsubscribeCheckoutDiffCalls, isEmpty);
      harness.disposeAll();
    });
  });

  // -------------------------------------------------------------------------
  // Push application
  // -------------------------------------------------------------------------

  group('push application', () {
    test(
      'a snapshot push writes the scope it names and sweeps agent commands',
      () {
        final harness = Harness();
        harness.cache.setQueryData([
          ...agentCommandsQueryRootKey(serverId),
          'session',
          'agent-1',
        ], 'commands');
        harness.cache.setQueryData([
          ...agentCommandsQueryRootKey(otherServerId),
          'session',
          'agent-2',
        ], 'other commands');
        harness.mount();

        harness.client.emitProviders(
          providerUpdate('2026-02-02T00:00:00.000Z', cwd: '/repo/'),
        );

        final scoped =
            harness.cache.getQueryData(
                  providersSnapshotQueryKey(serverId, '/repo'),
                )!
                as GetProvidersSnapshotResponse;
        expect(scoped.generatedAt, '2026-02-02T00:00:00.000Z');
        expect(
          harness.cache.getQueryData(providersSnapshotQueryKey(serverId)),
          isNull,
        );
        expect(
          harness.cache.getQuery([
            ...agentCommandsQueryRootKey(serverId),
            'session',
            'agent-1',
          ])!.isInvalidated,
          isTrue,
        );
        expect(
          harness.cache.getQuery([
            ...agentCommandsQueryRootKey(otherServerId),
            'session',
            'agent-2',
          ])!.isInvalidated,
          isFalse,
        );

        harness.disposeAll();
      },
    );

    test('applyProvidersSnapshotUpdate works without a mounted router', () {
      final cache = PushQueryCache();
      applyProvidersSnapshotUpdate(
        serverId: serverId,
        queryClient: cache,
        message: providerUpdate('2026-03-03T00:00:00.000Z'),
      );
      expect(
        (cache.getQueryData(providersSnapshotQueryKey(serverId))!
                as GetProvidersSnapshotResponse)
            .requestId,
        'providers_snapshot_update',
      );
    });

    test('a status push that is not a config change is ignored', () {
      final harness = Harness();
      harness.mount();
      harness.client.emitStatus({'status': 'pong'});
      harness.client.emitStatus({'status': 'daemon_config_changed'});
      harness.client.emitStatus({
        'status': 'daemon_config_changed',
        'config': 'not an object',
      });
      expect(
        harness.cache.getQueryData(daemonConfigQueryKey(serverId)),
        isNull,
      );
      harness.disposeAll();
    });

    test('a config that cannot be parsed leaves the cache untouched', () {
      // Deviation from upstream, which caches the unvalidated object; a typed
      // cache cannot, so the malformed push is dropped instead.
      final harness = Harness();
      harness.mount();
      harness.client.emitStatus({
        'status': 'daemon_config_changed',
        'config': <String, Object?>{'mcp': 'not an object'},
      });
      expect(
        harness.cache.getQueryData(daemonConfigQueryKey(serverId)),
        isNull,
      );
      harness.disposeAll();
    });

    test('checkout diff files are ordered by path, stably', () {
      final harness = Harness();
      final queryKey = checkoutDiffQueryKey(
        serverId,
        cwd,
        CheckoutDiffMode.base,
        'main',
        true,
      );
      harness.observe(
        queryKey,
        meta: checkoutDiffPushRoute(
          enabled: true,
          serverId: serverId,
          subscriptionId: 'sub',
          cwd: cwd,
          compare: baseCompare,
        ),
      );
      harness.mount();

      harness.client.emitDiffUpdate(
        CheckoutDiffUpdate(
          CheckoutDiffPayload(
            subscriptionId: 'sub',
            cwd: cwd,
            files: [diffFile('z.dart'), diffFile('a.dart'), diffFile('m.dart')],
            error: null,
          ),
        ),
      );

      expect(
        diffPayloadAt(harness.cache, queryKey).files.map((file) => file.path),
        ['a.dart', 'm.dart', 'z.dart'],
      );
      harness.disposeAll();
    });

    test('a diff push for an unknown subscription writes nothing', () {
      final harness = Harness();
      final queryKey = checkoutDiffQueryKey(
        serverId,
        cwd,
        CheckoutDiffMode.base,
        'main',
        true,
      );
      harness.observe(
        queryKey,
        meta: checkoutDiffPushRoute(
          enabled: true,
          serverId: serverId,
          subscriptionId: 'sub',
          cwd: cwd,
          compare: baseCompare,
        ),
      );
      harness.mount();

      harness.client.emitDiffUpdate(
        CheckoutDiffUpdate(
          CheckoutDiffPayload(
            subscriptionId: 'a-different-subscription',
            cwd: cwd,
            files: const [],
            error: null,
          ),
        ),
      );

      expect(harness.cache.getQueryData(queryKey), isNull);
      harness.disposeAll();
    });

    test('a diff push carries the checkout error through', () {
      final harness = Harness();
      final queryKey = checkoutDiffQueryKey(
        serverId,
        cwd,
        CheckoutDiffMode.base,
        'main',
        true,
      );
      harness.observe(
        queryKey,
        meta: checkoutDiffPushRoute(
          enabled: true,
          serverId: serverId,
          subscriptionId: 'sub',
          cwd: cwd,
          compare: baseCompare,
        ),
      );
      harness.mount();

      harness.client.emitDiffUpdate(
        CheckoutDiffUpdate(
          CheckoutDiffPayload(
            subscriptionId: 'sub',
            cwd: cwd,
            files: const [],
            error: const CheckoutError(
              code: CheckoutErrorCode.unknown,
              message: 'boom',
            ),
          ),
        ),
      );

      expect(diffPayloadAt(harness.cache, queryKey).error?.message, 'boom');
      harness.disposeAll();
    });

    test('a diff push still routes after the metadata is overwritten', () {
      // Upstream only pins this fallback for terminals; the checkout-diff half
      // of it is exercised here.
      final harness = Harness();
      final queryKey = checkoutDiffQueryKey(
        serverId,
        cwd,
        CheckoutDiffMode.base,
        'main',
        true,
      );
      harness.observe(
        queryKey,
        meta: checkoutDiffPushRoute(
          enabled: true,
          serverId: serverId,
          subscriptionId: 'sub',
          cwd: cwd,
          compare: baseCompare,
        ),
      );
      harness.mount();
      harness.observe(queryKey);

      harness.client.emitDiffUpdate(
        CheckoutDiffUpdate(
          CheckoutDiffPayload(
            subscriptionId: 'sub',
            cwd: cwd,
            files: const [],
            error: null,
          ),
        ),
      );

      expect(
        diffPayloadAt(harness.cache, queryKey).requestId,
        'subscription:sub',
      );
      expect(harness.client.unsubscribeCheckoutDiffCalls, isEmpty);
      harness.disposeAll();
    });

    test('a terminals push preserves the request id already cached', () {
      final harness = Harness();
      final queryKey = terminalsQueryKey(serverId, cwd, workspaceId);
      harness.observe(
        queryKey,
        meta: workspaceTerminalsPushRoute(
          enabled: true,
          serverId: serverId,
          cwd: cwd,
          workspaceId: workspaceId,
        ),
      );
      harness.mount();
      harness.cache.setQueryData(
        queryKey,
        const ListTerminalsCachePayload(
          cwd: cwd,
          terminals: [],
          requestId: 'list-1',
        ),
      );

      harness.client.emitTerminalsChanged(
        TerminalsChanged(
          cwd: cwd,
          terminals: [
            terminal('terminal-a', name: 'Main', workspaceId: workspaceId),
          ],
        ),
      );

      expect(terminalsPayloadAt(harness.cache, queryKey).requestId, 'list-1');
      harness.disposeAll();
    });

    test(
      'a terminals push synthesizes its request id from the injected clock',
      () {
        final harness = Harness();
        final queryKey = terminalsQueryKey(serverId, cwd, workspaceId);
        harness.observe(
          queryKey,
          meta: workspaceTerminalsPushRoute(
            enabled: true,
            serverId: serverId,
            cwd: cwd,
            workspaceId: workspaceId,
          ),
        );
        harness.mount();
        harness.client.emitTerminalsChanged(
          const TerminalsChanged(cwd: cwd, terminals: []),
        );
        expect(
          terminalsPayloadAt(harness.cache, queryKey).requestId,
          fixedNowRequestId,
        );
        harness.disposeAll();
      },
    );

    test('a terminals push for another cwd is ignored', () {
      final harness = Harness();
      final queryKey = terminalsQueryKey(serverId, cwd, workspaceId);
      harness.observe(
        queryKey,
        meta: workspaceTerminalsPushRoute(
          enabled: true,
          serverId: serverId,
          cwd: cwd,
          workspaceId: workspaceId,
        ),
      );
      harness.mount();
      harness.client.emitTerminalsChanged(
        TerminalsChanged(
          cwd: '/elsewhere',
          terminals: [
            terminal(
              'terminal-a',
              name: 'Main',
              workspaceId: workspaceId,
              terminalCwd: '/elsewhere',
            ),
          ],
        ),
      );
      expect(harness.cache.getQueryData(queryKey), isNull);
      harness.disposeAll();
    });

    test('a workspace-less route receives only workspace-less terminals', () {
      final harness = Harness();
      final queryKey = terminalsQueryKey(serverId, cwd);
      harness.observe(
        queryKey,
        meta: workspaceTerminalsPushRoute(
          enabled: true,
          serverId: serverId,
          cwd: cwd,
        ),
      );
      harness.mount();
      harness.client.emitTerminalsChanged(
        TerminalsChanged(
          cwd: cwd,
          terminals: [
            terminal('loose', name: 'Loose'),
            terminal('owned', name: 'Owned', workspaceId: workspaceId),
          ],
        ),
      );
      expect(
        terminalsPayloadAt(harness.cache, queryKey).terminals.map((t) => t.id),
        ['loose'],
      );
      harness.disposeAll();
    });
  });

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  group('router lifecycle', () {
    test('unmount closes every feed it opened, once', () {
      final harness = Harness();
      final diffKey = checkoutDiffQueryKey(
        serverId,
        cwd,
        CheckoutDiffMode.base,
        'main',
        true,
      );
      harness.observe(
        diffKey,
        meta: checkoutDiffPushRoute(
          enabled: true,
          serverId: serverId,
          subscriptionId: 'sub',
          cwd: cwd,
          compare: baseCompare,
        ),
      );
      harness.observe(
        terminalsQueryKey(serverId, cwd, workspaceId),
        meta: workspaceTerminalsPushRoute(
          enabled: true,
          serverId: serverId,
          cwd: cwd,
          workspaceId: workspaceId,
        ),
      );
      final unmount = harness.mount();

      unmount();
      unmount();

      expect(harness.client.unsubscribeCheckoutDiffCalls, ['sub']);
      expect(harness.client.unsubscribeTerminalCalls, [
        (cwd: cwd, workspaceId: workspaceId),
      ]);
      harness.disposeAll();
    });

    test('unmount survives a client that throws while closing a diff feed', () {
      final harness = Harness();
      harness.client.throwOnUnsubscribeCheckoutDiff = true;
      harness.observe(
        checkoutDiffQueryKey(
          serverId,
          cwd,
          CheckoutDiffMode.base,
          'main',
          true,
        ),
        meta: checkoutDiffPushRoute(
          enabled: true,
          serverId: serverId,
          subscriptionId: 'sub',
          cwd: cwd,
          compare: baseCompare,
        ),
      );
      final unmount = harness.mount();
      expect(unmount, returnsNormally);
      harness.disposeAll();
    });

    test('an unmounted router stops reconciling and stops writing', () {
      final harness = Harness();
      final queryKey = terminalsQueryKey(serverId, cwd, workspaceId);
      final route = workspaceTerminalsPushRoute(
        enabled: true,
        serverId: serverId,
        cwd: cwd,
        workspaceId: workspaceId,
      );
      final unmount = harness.mount();
      unmount();

      harness.observe(queryKey, meta: route);
      harness.client.emitTerminalsChanged(
        const TerminalsChanged(cwd: cwd, terminals: []),
      );

      expect(harness.client.subscribeTerminalCalls, isEmpty);
      expect(harness.cache.getQueryData(queryKey), isNull);
      harness.disposeAll();
    });

    test('a reconnect with nothing mounted still invalidates', () {
      final cache = PushQueryCache();
      cache.setQueryData(daemonConfigQueryKey(serverId), 'c');
      expect(
        () => invalidateServerDataQueriesAfterReconnect(
          queryClient: cache,
          serverId: serverId,
        ),
        returnsNormally,
      );
      expect(
        cache.getQuery(daemonConfigQueryKey(serverId))!.isInvalidated,
        isTrue,
      );
    });

    test('a reconnect on another daemon leaves this router alone', () {
      final harness = Harness();
      harness.observe(
        terminalsQueryKey(serverId, cwd, workspaceId),
        meta: workspaceTerminalsPushRoute(
          enabled: true,
          serverId: serverId,
          cwd: cwd,
          workspaceId: workspaceId,
        ),
      );
      harness.mount();
      invalidateServerDataQueriesAfterReconnect(
        queryClient: harness.cache,
        serverId: otherServerId,
      );
      expect(harness.client.subscribeTerminalCalls, hasLength(1));
      harness.disposeAll();
    });

    test('two routers on one daemon each keep their own reconnect repair', () {
      final harness = Harness();
      harness.observe(
        terminalsQueryKey(serverId, cwd, workspaceId),
        meta: workspaceTerminalsPushRoute(
          enabled: true,
          serverId: serverId,
          cwd: cwd,
          workspaceId: workspaceId,
        ),
      );
      final first = harness.mount();
      harness.mount();
      expect(harness.client.subscribeTerminalCalls, hasLength(2));

      first();
      invalidateServerDataQueriesAfterReconnect(
        queryClient: harness.cache,
        serverId: serverId,
      );
      // The surviving router re-subscribes; the unmounted one does not.
      expect(harness.client.subscribeTerminalCalls, hasLength(3));

      harness.disposeAll();
    });

    test('the reconnect repair order is stable', () {
      expect(reconnectRepairDomains, [
        'providersSnapshot',
        'daemonConfig',
        'checkoutDiff',
        'workspaceTerminals',
      ]);
    });
  });

  // -------------------------------------------------------------------------
  // terminals_changed wire shape
  // -------------------------------------------------------------------------

  group('terminals_changed', () {
    test('fills each entry cwd from the payload the wire omits it for', () {
      final message = TerminalsChanged.fromJson({
        'type': 'terminals_changed',
        'payload': {
          'cwd': cwd,
          'terminals': [
            {'id': 'a', 'name': 'Main', 'workspaceId': workspaceId},
          ],
        },
      });
      expect(message.cwd, cwd);
      expect(message.terminals.single.cwd, cwd);
      expect(message.terminals.single.workspaceId, workspaceId);
    });

    test('round-trips back to the omit-cwd wire shape', () {
      final json = TerminalsChanged(
        cwd: cwd,
        terminals: [terminal('a', name: 'Main', workspaceId: workspaceId)],
      ).toJson();
      final payload = json['payload']! as Map<String, Object?>;
      final entries = payload['terminals']! as List<Object?>;
      expect(payload['cwd'], cwd);
      expect((entries.single as Map).containsKey('cwd'), isFalse);
    });

    test('rejects malformed payloads', () {
      expect(
        () => TerminalsChanged.fromJson({'type': 'something_else'}),
        throwsFormatException,
      );
      expect(
        () => TerminalsChanged.fromJson({'type': 'terminals_changed'}),
        throwsFormatException,
      );
      expect(
        () => TerminalsChanged.fromJson({
          'type': 'terminals_changed',
          'payload': {'terminals': <Object?>[]},
        }),
        throwsFormatException,
      );
      expect(
        () => TerminalsChanged.fromJson({
          'type': 'terminals_changed',
          'payload': {'cwd': cwd, 'terminals': 'not a list'},
        }),
        throwsFormatException,
      );
      expect(
        () => TerminalsChanged.fromJson({
          'type': 'terminals_changed',
          'payload': {
            'cwd': cwd,
            'terminals': ['not an object'],
          },
        }),
        throwsFormatException,
      );
    });
  });
}
