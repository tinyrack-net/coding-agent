import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/runtime/paseo_replica_sync.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Shared fakes
// ---------------------------------------------------------------------------

final class _Scheduled {
  _Scheduled(this.task, this.delay);

  final void Function() task;
  final Duration delay;
}

final class _FakeScheduler implements ReplicaSyncScheduler {
  final List<_Scheduled> entries = [];

  @override
  CancelScheduledTask schedule(void Function() task, Duration delay) {
    final entry = _Scheduled(task, delay);
    entries.add(entry);
    return () => entries.remove(entry);
  }

  List<_Scheduled> withDelay(Duration delay) =>
      entries.where((entry) => entry.delay == delay).toList();

  void runFirst(Duration delay) {
    final index = entries.indexWhere((entry) => entry.delay == delay);
    expect(index, greaterThanOrEqualTo(0));
    entries.removeAt(index).task();
  }
}

/// Yields to the event loop enough times for every pending microtask chain in
/// these modules to settle. Dart resumes an `await` one microtask later than
/// the equivalent JS `await`, so upstream assertions that follow a `respond()`
/// with no `await` need an explicit drain here.
Future<void> _settle([int ticks = 8]) async {
  for (var index = 0; index < ticks; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

// ---------------------------------------------------------------------------
// ViewedTimelineSync world (port of the TS test harness)
// ---------------------------------------------------------------------------

final class _MembershipRequest {
  _MembershipRequest(this.agentIds, this._completer);

  final List<String> agentIds;
  final Completer<void> _completer;

  void succeed() => _completer.complete();

  void fail(String message) => _completer.completeError(StateError(message));
}

final class _TimelineFetch {
  _TimelineFetch(this.agentId, this.request, this._completer);

  final String agentId;
  final ProjectedTimelineForwardFetchPlan request;
  final Completer<TimelinePageResult> _completer;

  void respond({required bool hasNewer, int seq = 1}) => _completer.complete(
    TimelinePageResult(
      hasNewer: hasNewer,
      endCursor: AgentTimelineCursor(epoch: 'epoch-$agentId', seq: seq),
    ),
  );

  void respondWithoutCursor({required bool hasNewer}) => _completer.complete(
    TimelinePageResult(hasNewer: hasNewer, endCursor: null),
  );

  void fail(String message) => _completer.completeError(StateError(message));
}

final class _TimelineWorld implements ViewedTimelineSyncPorts {
  _TimelineWorld({TimelineDeliveryMode mode = TimelineDeliveryMode.selective})
    : initialDeliveryMode = mode {
    sync = ViewedTimelineSync(this);
  }

  @override
  final TimelineDeliveryMode initialDeliveryMode;

  late final ViewedTimelineSync sync;

  final List<String> errors = [];
  final List<_Scheduled> scheduled = [];

  final List<_MembershipRequest> _memberships = [];
  final List<Completer<_MembershipRequest>> _membershipWaiters = [];
  final List<_TimelineFetch> _fetches = [];
  final List<({String agentId, Completer<_TimelineFetch> completer})>
  _fetchWaiters = [];
  final Map<String, AgentTimelineCursorRange> _cursors = {};
  final Set<String> _authoritativeHistory = {};
  final List<Completer<String>> _errorWaiters = [];
  final List<Completer<void Function()>> _retryWaiters = [];

  @override
  Future<void> setSubscription(List<String> agentIds) {
    final completer = Completer<void>();
    _memberships.add(_MembershipRequest(List.of(agentIds), completer));
    _releaseMembershipWaiter();
    return completer.future;
  }

  @override
  AgentTimelineCursorRange? readCursor(String agentId) => _cursors[agentId];

  @override
  bool hasAuthoritativeHistory(String agentId) =>
      _authoritativeHistory.contains(agentId);

  @override
  Future<TimelinePageResult> fetchPage(
    String agentId,
    ProjectedTimelineForwardFetchPlan request,
  ) {
    final completer = Completer<TimelinePageResult>();
    _fetches.add(_TimelineFetch(agentId, request, completer));
    _releaseFetchWaiters();
    return completer.future;
  }

  @override
  void reportError(Object error) {
    errors.add(error is StateError ? error.message : error.toString());
    if (_errorWaiters.isNotEmpty) {
      _errorWaiters.removeAt(0).complete(errors.last);
    }
  }

  @override
  CancelScheduledTask schedule(void Function() task, Duration delay) {
    final entry = _Scheduled(task, delay);
    scheduled.add(entry);
    if (_retryWaiters.isNotEmpty && delay == viewedTimelineRetryDelay) {
      scheduled.remove(entry);
      _retryWaiters.removeAt(0).complete(task);
    }
    return () => scheduled.remove(entry);
  }

  void setCursor(String agentId, int endSeq) {
    _cursors[agentId] = AgentTimelineCursorRange(
      epoch: 'epoch-$agentId',
      startSeq: 1,
      endSeq: endSeq,
    );
    _authoritativeHistory.add(agentId);
  }

  void setLiveCursor(String agentId, int endSeq) {
    _cursors[agentId] = AgentTimelineCursorRange(
      epoch: 'epoch-$agentId',
      startSeq: 1,
      endSeq: endSeq,
    );
  }

  Future<_MembershipRequest> nextMembership() {
    if (_memberships.isNotEmpty) {
      return Future.value(_memberships.removeAt(0));
    }
    final completer = Completer<_MembershipRequest>();
    _membershipWaiters.add(completer);
    return completer.future;
  }

  Future<_TimelineFetch> nextFetch(String agentId) {
    final index = _fetches.indexWhere((fetch) => fetch.agentId == agentId);
    if (index >= 0) return Future.value(_fetches.removeAt(index));
    final completer = Completer<_TimelineFetch>();
    _fetchWaiters.add((agentId: agentId, completer: completer));
    return completer.future;
  }

  Future<String> nextError() {
    if (errors.isNotEmpty) return Future.value(errors.last);
    final completer = Completer<String>();
    _errorWaiters.add(completer);
    return completer.future;
  }

  Future<void Function()> nextRetry() {
    final index = scheduled.indexWhere(
      (entry) => entry.delay == viewedTimelineRetryDelay,
    );
    if (index >= 0) return Future.value(scheduled.removeAt(index).task);
    final completer = Completer<void Function()>();
    _retryWaiters.add(completer);
    return completer.future;
  }

  void runUnsubscribeGrace() {
    final index = scheduled.indexWhere(
      (entry) => entry.delay == viewedTimelineUnsubscribeGrace,
    );
    expect(index, greaterThanOrEqualTo(0));
    scheduled.removeAt(index).task();
  }

  void expectNoPendingMembership() => expect(_memberships, isEmpty);

  void expectNoPendingFetch() => expect(_fetches, isEmpty);

  void expectNoPendingUnsubscribe() => expect(
    scheduled.where((entry) => entry.delay == viewedTimelineUnsubscribeGrace),
    isEmpty,
  );

  Future<void> waitForStatus(
    String agentId,
    ViewedTimelineStatus expected,
  ) async {
    for (var index = 0; index < 200; index += 1) {
      if (sync.getAgentTimelineStatus(agentId) == expected) return;
      await Future<void>.delayed(Duration.zero);
    }
    expect(sync.getAgentTimelineStatus(agentId), expected);
  }

  void _releaseMembershipWaiter() {
    if (_membershipWaiters.isEmpty || _memberships.isEmpty) return;
    _membershipWaiters.removeAt(0).complete(_memberships.removeAt(0));
  }

  void _releaseFetchWaiters() {
    for (
      var waiterIndex = _fetchWaiters.length - 1;
      waiterIndex >= 0;
      waiterIndex -= 1
    ) {
      final waiter = _fetchWaiters[waiterIndex];
      final index = _fetches.indexWhere(
        (fetch) => fetch.agentId == waiter.agentId,
      );
      if (index < 0) continue;
      _fetchWaiters.removeAt(waiterIndex);
      waiter.completer.complete(_fetches.removeAt(index));
    }
  }
}

// ---------------------------------------------------------------------------
// ReplicaCache fakes and builders
// ---------------------------------------------------------------------------

final class _MemoryStorage implements ReplicaCacheStorage {
  final Map<String, String> values = {};
  final List<String> writes = [];
  Object? getFailure;
  Object? setFailure;

  @override
  Future<String?> getItem(String key) async {
    final failure = getFailure;
    if (failure != null) throw failure;
    return values[key];
  }

  @override
  Future<void> setItem(String key, String value) async {
    final failure = setFailure;
    if (failure != null) {
      setFailure = null;
      throw failure;
    }
    writes.add(value);
    values[key] = value;
  }

  String? get payload => values[replicaCacheStorageKey];
}

final class _FakeSessionSource implements ReplicaCacheSessionSource {
  final Map<String, ReplicaCacheSession> sessions = {};
  final Set<void Function()> listeners = {};

  @override
  ReplicaCacheSession? readSession(String serverId) => sessions[serverId];

  @override
  CancelScheduledTask subscribe(void Function() listener) {
    listeners.add(listener);
    return () => listeners.remove(listener);
  }

  void emit() {
    for (final listener in listeners.toList(growable: false)) {
      listener();
    }
  }
}

final class _RecordingSink implements ReplicaCacheSessionSink {
  final Map<String, CachedHostReplica> restored = {};

  @override
  void restoreSessionReplica(String serverId, CachedHostReplica replica) {
    restored[serverId] = replica;
  }
}

AgentSummary buildAgent(
  String id, {
  String? workspaceId = 'workspace-1',
  String cwd = '/repo/paseo',
}) => AgentSummary(
  agentId: id,
  title: 'Agent $id',
  cwd: cwd,
  provider: 'codex',
  model: '',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: 1763452800000,
  updatedAt: '2026-07-18T08:01:00.000Z',
  workspaceId: workspaceId,
  lastUserMessageAt: '2026-07-18T08:01:00.000Z',
);

WorkspaceDescriptor buildWorkspace({
  String id = 'workspace-1',
  String projectId = 'project-1',
  String directory = '/repo/paseo',
}) => WorkspaceDescriptor(
  id: id,
  projectId: projectId,
  projectDisplayName: 'Paseo',
  projectRootPath: directory,
  workspaceDirectory: directory,
  projectKind: WorkspaceProjectKind.git,
  workspaceKind: WorkspaceKind.localCheckout,
  name: 'main',
  status: WorkspaceStateBucket.running,
  statusEnteredAt: '2026-07-18T08:00:00.000Z',
  activityAt: '2026-07-18T09:00:00.000Z',
);

TimelineItem buildMessage(String id, String text) =>
    AssistantMessageItem(id: id, text: text, complete: true);

ReplicaCacheSession buildSession({
  String focusedAgentId = 'agent-1',
  Map<String, AgentSummary>? agents,
  Map<String, WorkspaceDescriptor>? workspaces,
  Map<String, List<TimelineItem>>? agentStreamTail,
  Map<String, AgentTimelineCursorRange>? agentTimelineCursor,
  Map<String, bool>? agentTimelineHasOlder,
}) => ReplicaCacheSession(
  focusedAgentId: focusedAgentId,
  agents: agents ?? {'agent-1': buildAgent('agent-1')},
  workspaces: workspaces ?? {'workspace-1': buildWorkspace()},
  agentStreamTail:
      agentStreamTail ??
      {
        'agent-1': [buildMessage('message-1', 'Cached')],
      },
  agentTimelineCursor:
      agentTimelineCursor ??
      const {
        'agent-1': AgentTimelineCursorRange(
          epoch: 'epoch-1',
          startSeq: 1,
          endSeq: 12,
        ),
      },
  agentTimelineHasOlder: agentTimelineHasOlder ?? const {'agent-1': true},
);

ReplicaCacheSession buildHostSession(String serverId, String text) {
  final agentId = 'agent-$serverId';
  final workspaceId = 'workspace-$serverId';
  final directory = '/repo/$serverId';
  return ReplicaCacheSession(
    focusedAgentId: agentId,
    agents: {
      agentId: buildAgent(agentId, workspaceId: workspaceId, cwd: directory),
    },
    workspaces: {
      workspaceId: buildWorkspace(
        id: workspaceId,
        projectId: 'project-$serverId',
        directory: directory,
      ),
    },
    agentStreamTail: {
      agentId: [buildMessage('message-$serverId', text)],
    },
    agentTimelineCursor: const {},
    agentTimelineHasOlder: const {},
  );
}

({
  ReplicaCache cache,
  _MemoryStorage storage,
  _FakeSessionSource source,
  _RecordingSink sink,
  _FakeScheduler scheduler,
})
_buildCache({
  _MemoryStorage? storage,
  _FakeSessionSource? source,
  _RecordingSink? sink,
  _FakeScheduler? scheduler,
  int? maxBytes,
}) {
  final resolvedStorage = storage ?? _MemoryStorage();
  final resolvedSource = source ?? _FakeSessionSource();
  final resolvedSink = sink ?? _RecordingSink();
  final resolvedScheduler = scheduler ?? _FakeScheduler();
  return (
    cache: ReplicaCache(
      storage: resolvedStorage,
      source: resolvedSource,
      sink: resolvedSink,
      scheduler: resolvedScheduler,
      maxBytes: maxBytes,
    ),
    storage: resolvedStorage,
    source: resolvedSource,
    sink: resolvedSink,
    scheduler: resolvedScheduler,
  );
}

const String serverId = 'cached-host';

void main() {
  // -------------------------------------------------------------------------
  group('forward fetch plans', () {
    test('a tail plan carries the frozen page size and projection', () {
      final plan = planTimelineTailFetch();
      expect(plan.direction, AgentTimelineDirection.tail);
      expect(plan.cursor, isNull);
      expect(plan.limit, agentTimelineFetchPageSize);
      expect(plan.limit, 40);
      expect(plan.projection, AgentTimelineProjection.projected);
    });

    test('an after plan anchors on its cursor', () {
      final plan = planTimelineCatchUpAfter(
        const AgentTimelineCursor(epoch: 'epoch-1', seq: 12),
      );
      expect(plan.direction, AgentTimelineDirection.after);
      expect(plan.cursor, const AgentTimelineCursor(epoch: 'epoch-1', seq: 12));
      expect(plan.limit, agentTimelineFetchPageSize);
    });

    test(
      'plans compare by value so an identical gap request is recognised',
      () {
        expect(planTimelineTailFetch(), planTimelineTailFetch());
        expect(
          planTimelineCatchUpAfter(
            const AgentTimelineCursor(epoch: 'e', seq: 3),
          ),
          planTimelineCatchUpAfter(
            const AgentTimelineCursor(epoch: 'e', seq: 3),
          ),
        );
        expect(
          planTimelineCatchUpAfter(
                const AgentTimelineCursor(epoch: 'e', seq: 3),
              ) ==
              planTimelineCatchUpAfter(
                const AgentTimelineCursor(epoch: 'e', seq: 4),
              ),
          isFalse,
        );
        expect(
          planTimelineTailFetch() ==
              planTimelineCatchUpAfter(
                const AgentTimelineCursor(epoch: 'e', seq: 3),
              ),
          isFalse,
        );
        expect(
          planTimelineTailFetch().hashCode,
          planTimelineTailFetch().hashCode,
        );
      },
    );

    test('initial sync tails unless the held history is authoritative', () {
      const cursor = AgentTimelineCursorRange(
        epoch: 'epoch-1',
        startSeq: 1,
        endSeq: 9,
      );
      expect(
        planInitialAgentTimelineSync(
          cursor: cursor,
          hasAuthoritativeHistory: false,
        ),
        planTimelineTailFetch(),
      );
      expect(
        planInitialAgentTimelineSync(
          cursor: null,
          hasAuthoritativeHistory: true,
        ),
        planTimelineTailFetch(),
      );
      expect(
        planInitialAgentTimelineSync(
          cursor: cursor,
          hasAuthoritativeHistory: true,
        ),
        planTimelineCatchUpAfter(
          const AgentTimelineCursor(epoch: 'epoch-1', seq: 9),
        ),
      );
    });

    test(
      'resume sync anchors on the cursor end, tailing when there is none',
      () {
        expect(planResumeTimelineSync(cursor: null), planTimelineTailFetch());
        expect(
          planResumeTimelineSync(
            cursor: const AgentTimelineCursorRange(
              epoch: 'epoch-1',
              startSeq: 4,
              endSeq: 21,
            ),
          ),
          planTimelineCatchUpAfter(
            const AgentTimelineCursor(epoch: 'epoch-1', seq: 21),
          ),
        );
      },
    );

    test('a plan adapts to the existing protocol fetch request', () {
      final request = planTimelineCatchUpAfter(
        const AgentTimelineCursor(epoch: 'epoch-1', seq: 7),
      ).toRequest(agentId: 'agent-a', requestId: 'req-1').toJson();
      expect(request['agentId'], 'agent-a');
      expect(request['requestId'], 'req-1');
      expect(request['direction'], 'after');
      expect(request['cursor'], {'epoch': 'epoch-1', 'seq': 7});
      expect(request['limit'], 40);
      expect(request['projection'], 'projected');
    });
  });

  // -------------------------------------------------------------------------
  group('ViewedTimelineSync', () {
    test('keeps hidden agents subscribed for thirty seconds', () {
      expect(viewedTimelineUnsubscribeGrace.inMilliseconds, 30000);
      expect(viewedTimelineRetryDelay.inMilliseconds, 1000);
    });

    test('uses a tail fetch when a live cursor is not authoritative', () async {
      final world = _TimelineWorld();
      world.setLiveCursor('agent-a', 9);
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      (await world.nextMembership()).succeed();

      final fetch = await world.nextFetch('agent-a');
      expect(fetch.request, planTimelineTailFetch());
      fetch.respond(hasNewer: false);
      await _settle();
    });

    test('resumes after the cursor when history is authoritative', () async {
      final world = _TimelineWorld();
      world.setCursor('agent-a', 9);
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      (await world.nextMembership()).succeed();

      final fetch = await world.nextFetch('agent-a');
      expect(
        fetch.request,
        planTimelineCatchUpAfter(
          const AgentTimelineCursor(epoch: 'epoch-agent-a', seq: 9),
        ),
      );
      fetch.respond(hasNewer: false);
      await _settle();
    });

    test(
      'unchanged visible-set publication does not cancel paged catch-up',
      () async {
        final world = _TimelineWorld();
        world.sync.setConnected(true);
        world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
        expect(
          world.sync.getAgentTimelineStatus('agent-a'),
          ViewedTimelineStatus.pending,
        );
        (await world.nextMembership()).succeed();
        final firstPage = await world.nextFetch('agent-a');

        world.sync.replaceVisibleAgentIds('workspace', ['agent-a', 'agent-a']);
        firstPage.respond(hasNewer: true, seq: 5);
        final secondPage = await world.nextFetch('agent-a');
        expect(
          world.sync.getAgentTimelineStatus('agent-a'),
          ViewedTimelineStatus.pending,
        );
        secondPage.respond(hasNewer: false);

        await world.waitForStatus('agent-a', ViewedTimelineStatus.ready);

        expect(
          secondPage.request,
          planTimelineCatchUpAfter(
            const AgentTimelineCursor(epoch: 'epoch-agent-a', seq: 5),
          ),
        );
        world.expectNoPendingMembership();
      },
    );

    test('all acknowledged agents begin catch-up independently', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-b', 'agent-a']);
      final membership = await world.nextMembership();
      membership.succeed();

      final fetches = await Future.wait([
        world.nextFetch('agent-a'),
        world.nextFetch('agent-b'),
      ]);
      for (final fetch in fetches) {
        fetch.respond(hasNewer: false);
      }
      await _settle();

      expect(membership.agentIds, ['agent-a', 'agent-b']);
    });

    test(
      'membership changes during acknowledgement never catch up the stale set',
      () async {
        final world = _TimelineWorld();
        world.sync.setConnected(true);
        world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
        final staleMembership = await world.nextMembership();

        world.sync.replaceVisibleAgentIds('workspace', ['agent-b']);
        world.runUnsubscribeGrace();
        staleMembership.succeed();
        final currentMembership = await world.nextMembership();
        currentMembership.succeed();
        final agentB = await world.nextFetch('agent-b');
        agentB.respond(hasNewer: false);
        await _settle();

        expect(staleMembership.agentIds, ['agent-a']);
        expect(currentMembership.agentIds, ['agent-b']);
        world.expectNoPendingFetch();
      },
    );

    test('removing one agent during paging cancels only that agent', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a', 'agent-b']);
      (await world.nextMembership()).succeed();
      final initial = await Future.wait([
        world.nextFetch('agent-a'),
        world.nextFetch('agent-b'),
      ]);

      world.sync.replaceVisibleAgentIds('workspace', ['agent-b']);
      world.runUnsubscribeGrace();
      final replacement = await world.nextMembership();
      initial[0].respond(hasNewer: true, seq: 4);
      initial[1].respond(hasNewer: true, seq: 7);
      final agentBNext = await world.nextFetch('agent-b');
      replacement.succeed();
      agentBNext.respond(hasNewer: false);
      await _settle();

      expect(replacement.agentIds, ['agent-b']);
      world.expectNoPendingFetch();
    });

    test('disconnect cancels paging and reconnect restores membership before '
        'fresh catch-up', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      (await world.nextMembership()).succeed();
      final stalePage = await world.nextFetch('agent-a');

      world.sync.setConnected(false);
      expect(
        world.sync.getAgentTimelineStatus('agent-a'),
        ViewedTimelineStatus.pending,
      );
      stalePage.respond(hasNewer: true, seq: 8);
      world.sync.setConnected(true);
      final restoredMembership = await world.nextMembership();
      restoredMembership.succeed();
      final restoredPage = await world.nextFetch('agent-a');
      restoredPage.respond(hasNewer: false);

      await world.waitForStatus('agent-a', ViewedTimelineStatus.ready);

      expect(restoredMembership.agentIds, ['agent-a']);
      world.expectNoPendingFetch();
    });

    test(
      'overlapping sources deduplicate membership and source removal preserves '
      'remaining views',
      () async {
        final world = _TimelineWorld();
        world.sync.replaceVisibleAgentIds('left-route', ['agent-a']);
        world.sync.replaceVisibleAgentIds('right-route', [
          'agent-a',
          'agent-b',
        ]);
        world.sync.setConnected(true);
        final combined = await world.nextMembership();
        combined.succeed();
        final fetches = await Future.wait([
          world.nextFetch('agent-a'),
          world.nextFetch('agent-b'),
        ]);
        for (final fetch in fetches) {
          fetch.respond(hasNewer: false);
        }
        await _settle();

        world.sync.replaceVisibleAgentIds('left-route', []);
        world.expectNoPendingMembership();
        world.expectNoPendingUnsubscribe();
        world.sync.replaceVisibleAgentIds('right-route', ['agent-b']);
        world.runUnsubscribeGrace();
        final remaining = await world.nextMembership();
        remaining.succeed();
        await _settle();

        expect(combined.agentIds, ['agent-a', 'agent-b']);
        expect(remaining.agentIds, ['agent-b']);
      },
    );

    test(
      'a failed catch-up reports once and retries through the explicit retry '
      'policy',
      () async {
        final world = _TimelineWorld();
        world.sync.setConnected(true);
        world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
        (await world.nextMembership()).succeed();
        final failed = await world.nextFetch('agent-a');
        failed.fail('timeline unavailable');
        final error = await world.nextError();
        final retryCatchUp = await world.nextRetry();
        expect(
          world.sync.getAgentTimelineStatus('agent-a'),
          ViewedTimelineStatus.error,
        );

        retryCatchUp();
        final retry = await world.nextFetch('agent-a');
        expect(
          world.sync.getAgentTimelineStatus('agent-a'),
          ViewedTimelineStatus.error,
        );
        retry.respond(hasNewer: false);
        await world.waitForStatus('agent-a', ViewedTimelineStatus.ready);

        expect(error, 'timeline unavailable');
        expect(retry.request.direction, AgentTimelineDirection.tail);
        expect(world.errors, ['timeline unavailable']);
        world.expectNoPendingMembership();
      },
    );

    test('gap recovery supersedes completed catch-up and pages through the '
        'current tail', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      (await world.nextMembership()).succeed();
      (await world.nextFetch('agent-a')).respond(hasNewer: false);
      await _settle();

      world.sync.recoverGap(
        'agent-a',
        const AgentTimelineCursorRange(
          epoch: 'epoch-agent-a',
          startSeq: 1,
          endSeq: 10,
        ),
      );
      final gapPage = await world.nextFetch('agent-a');
      gapPage.respond(hasNewer: true, seq: 15);
      final finalPage = await world.nextFetch('agent-a');
      finalPage.respond(hasNewer: false);
      await _settle();

      expect(
        gapPage.request,
        planTimelineCatchUpAfter(
          const AgentTimelineCursor(epoch: 'epoch-agent-a', seq: 10),
        ),
      );
      expect(
        finalPage.request,
        planTimelineCatchUpAfter(
          const AgentTimelineCursor(epoch: 'epoch-agent-a', seq: 15),
        ),
      );
    });

    test(
      'repeated recovery for the same running gap reuses the in-flight fetch',
      () async {
        final world = _TimelineWorld();
        world.sync.setConnected(true);
        world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
        (await world.nextMembership()).succeed();
        (await world.nextFetch('agent-a')).respond(hasNewer: false);
        await _settle();

        const cursor = AgentTimelineCursorRange(
          epoch: 'epoch-agent-a',
          startSeq: 1,
          endSeq: 10,
        );
        world.sync.recoverGap('agent-a', cursor);
        final gapPage = await world.nextFetch('agent-a');
        world.sync.recoverGap('agent-a', cursor);

        world.expectNoPendingFetch();
        gapPage.respond(hasNewer: false);
        await _settle();
      },
    );

    test('a differing gap cursor supersedes the running fetch', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      (await world.nextMembership()).succeed();
      (await world.nextFetch('agent-a')).respond(hasNewer: false);
      await _settle();

      world.sync.recoverGap(
        'agent-a',
        const AgentTimelineCursorRange(
          epoch: 'epoch-agent-a',
          startSeq: 1,
          endSeq: 10,
        ),
      );
      final first = await world.nextFetch('agent-a');
      world.sync.recoverGap(
        'agent-a',
        const AgentTimelineCursorRange(
          epoch: 'epoch-agent-a',
          startSeq: 1,
          endSeq: 11,
        ),
      );
      final second = await world.nextFetch('agent-a');

      expect(
        second.request,
        planTimelineCatchUpAfter(
          const AgentTimelineCursor(epoch: 'epoch-agent-a', seq: 11),
        ),
      );
      // The superseded fetch resolving must not revive the abandoned
      // generation.
      first.respond(hasNewer: true, seq: 99);
      second.respond(hasNewer: false);
      await world.waitForStatus('agent-a', ViewedTimelineStatus.ready);
      world.expectNoPendingFetch();
    });

    test('membership failure autonomously retries without another visibility '
        'declaration', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      final failed = await world.nextMembership();
      failed.fail('subscription unavailable');
      final error = await world.nextError();
      final retryMembership = await world.nextRetry();
      expect(
        world.sync.getAgentTimelineStatus('agent-a'),
        ViewedTimelineStatus.error,
      );

      retryMembership();
      final retry = await world.nextMembership();
      retry.succeed();
      final catchUp = await world.nextFetch('agent-a');
      expect(
        world.sync.getAgentTimelineStatus('agent-a'),
        ViewedTimelineStatus.error,
      );
      catchUp.respond(hasNewer: false);
      await world.waitForStatus('agent-a', ViewedTimelineStatus.ready);

      expect(error, 'subscription unavailable');
      expect(failed.agentIds, ['agent-a']);
      expect(retry.agentIds, ['agent-a']);
    });

    test('background waits for grace before unsubscribing and catches up on '
        'return', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      (await world.nextMembership()).succeed();
      (await world.nextFetch('agent-a')).respond(hasNewer: false);
      await _settle();

      world.sync.setActive(false);
      world.expectNoPendingMembership();
      world.runUnsubscribeGrace();
      final background = await world.nextMembership();
      background.succeed();
      world.sync.setActive(true);
      final foreground = await world.nextMembership();
      foreground.succeed();
      (await world.nextFetch('agent-a')).respond(hasNewer: false);
      await _settle();

      expect(background.agentIds, isEmpty);
      expect(foreground.agentIds, ['agent-a']);
    });

    test('foregrounding within grace preserves the live membership', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      (await world.nextMembership()).succeed();
      (await world.nextFetch('agent-a')).respond(hasNewer: false);
      await _settle();

      world.sync.setActive(false);
      world.expectNoPendingMembership();
      world.sync.setActive(true);
      await _settle();

      world.expectNoPendingUnsubscribe();
      world.expectNoPendingMembership();
      world.expectNoPendingFetch();
    });

    test(
      'stale membership retry cannot overwrite a newer effective set',
      () async {
        final world = _TimelineWorld();
        world.sync.setConnected(true);
        world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
        final failed = await world.nextMembership();
        failed.fail('subscription unavailable');
        final staleRetry = await world.nextRetry();

        world.sync.replaceVisibleAgentIds('workspace', ['agent-b']);
        world.runUnsubscribeGrace();

        // Harness-timing deviation, not a behavioural one. Resolving a Dart
        // `Completer` costs one more microtask hop than resolving a JS promise,
        // so by the time the test resumes from `nextRetry` the reconcile loop has
        // already gone idle where upstream's was still in flight. The idle loop
        // publishes the grace-window union as its own request — the very same
        // publication upstream asserts in "a new visible agent subscribes
        // immediately while the previous agent lingers". Drain it, then assert
        // the invariant this test exists for: the stale retry is inert and the
        // membership still converges on the newer set.
        final union = await world.nextMembership();
        staleRetry();
        union.succeed();
        final current = await world.nextMembership();
        current.succeed();
        (await world.nextFetch('agent-b')).respond(hasNewer: false);
        await _settle();

        expect(union.agentIds, ['agent-a', 'agent-b']);
        expect(current.agentIds, ['agent-b']);
        expect(world.errors, ['subscription unavailable']);
        world.expectNoPendingMembership();
        world.expectNoPendingFetch();
      },
    );

    test('membership retry cannot run while disconnected', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      final failed = await world.nextMembership();
      failed.fail('subscription unavailable');
      final disconnectedRetry = await world.nextRetry();

      world.sync.setConnected(false);
      disconnectedRetry();
      await _settle();
      world.expectNoPendingMembership();
      world.sync.setConnected(true);
      final restored = await world.nextMembership();
      restored.succeed();
      (await world.nextFetch('agent-a')).respond(hasNewer: false);
      await _settle();

      expect(restored.agentIds, ['agent-a']);
    });

    test(
      'quickly returning to an agent cancels its pending unsubscribe without '
      'another catch-up',
      () async {
        final world = _TimelineWorld();
        world.sync.setConnected(true);
        world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
        (await world.nextMembership()).succeed();
        (await world.nextFetch('agent-a')).respond(hasNewer: false);

        await world.waitForStatus('agent-a', ViewedTimelineStatus.ready);

        world.sync.replaceVisibleAgentIds('workspace', []);
        world.expectNoPendingMembership();
        world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);

        expect(
          world.sync.getAgentTimelineStatus('agent-a'),
          ViewedTimelineStatus.ready,
        );

        await _settle();
        world.expectNoPendingUnsubscribe();
        world.expectNoPendingMembership();
        world.expectNoPendingFetch();
      },
    );

    test('unsubscribe grace expiry removes the agent exactly once', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      (await world.nextMembership()).succeed();
      (await world.nextFetch('agent-a')).respond(hasNewer: false);
      await world.waitForStatus('agent-a', ViewedTimelineStatus.ready);

      final readinessChanges = <ViewedTimelineStatus>[];
      world.sync.subscribe(() {
        readinessChanges.add(world.sync.getAgentTimelineStatus('agent-a'));
      });

      world.sync.replaceVisibleAgentIds('workspace', []);
      world.runUnsubscribeGrace();
      final unsubscribe = await world.nextMembership();
      unsubscribe.succeed();
      await _settle();

      expect(unsubscribe.agentIds, isEmpty);
      expect(readinessChanges.last, ViewedTimelineStatus.pending);
      world.expectNoPendingUnsubscribe();
      world.expectNoPendingMembership();
    });

    test('a new visible agent subscribes immediately while the previous agent '
        'lingers', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      (await world.nextMembership()).succeed();
      (await world.nextFetch('agent-a')).respond(hasNewer: false);
      await _settle();

      world.sync.replaceVisibleAgentIds('workspace', ['agent-b']);
      final expandedMembership = await world.nextMembership();
      expandedMembership.succeed();
      (await world.nextFetch('agent-b')).respond(hasNewer: false);
      await _settle();

      expect(expandedMembership.agentIds, ['agent-a', 'agent-b']);
      world.runUnsubscribeGrace();
      final settledMembership = await world.nextMembership();
      settledMembership.succeed();
      await _settle();
      expect(settledMembership.agentIds, ['agent-b']);
    });

    test(
      'backgrounding preserves an existing unsubscribe grace period',
      () async {
        final world = _TimelineWorld();
        world.sync.setConnected(true);
        world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
        (await world.nextMembership()).succeed();
        (await world.nextFetch('agent-a')).respond(hasNewer: false);
        await _settle();

        world.sync.replaceVisibleAgentIds('workspace', []);
        world.sync.setActive(false);
        world.expectNoPendingMembership();
        world.runUnsubscribeGrace();
        final unsubscribe = await world.nextMembership();
        unsubscribe.succeed();
        await _settle();

        expect(unsubscribe.agentIds, isEmpty);
        world.expectNoPendingMembership();
      },
    );

    test(
      'disconnecting cancels pending unsubscribe grace without publishing on '
      'the closed socket',
      () async {
        final world = _TimelineWorld();
        world.sync.setConnected(true);
        world.sync.replaceVisibleAgentIds('workspace', ['agent-a', 'agent-b']);
        (await world.nextMembership()).succeed();
        final fetches = await Future.wait([
          world.nextFetch('agent-a'),
          world.nextFetch('agent-b'),
        ]);
        for (final fetch in fetches) {
          fetch.respond(hasNewer: false);
        }
        await world.waitForStatus('agent-a', ViewedTimelineStatus.ready);

        world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
        final agentAStatuses = <ViewedTimelineStatus>[];
        world.sync.subscribe(() {
          agentAStatuses.add(world.sync.getAgentTimelineStatus('agent-a'));
        });
        world.sync.setConnected(false);
        await _settle();

        expect(agentAStatuses, [ViewedTimelineStatus.pending]);
        world.expectNoPendingUnsubscribe();
        world.expectNoPendingMembership();
      },
    );

    test('disposing cancels pending unsubscribe grace', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      (await world.nextMembership()).succeed();
      (await world.nextFetch('agent-a')).respond(hasNewer: false);
      await _settle();

      world.sync.replaceVisibleAgentIds('workspace', []);
      world.sync.dispose();
      await _settle();

      world.expectNoPendingUnsubscribe();
      world.expectNoPendingMembership();
    });

    test('legacy delivery skips subscription RPCs while retaining visibility '
        'catch-up and gap recovery', () async {
      final world = _TimelineWorld();
      world.sync.setDeliveryMode(TimelineDeliveryMode.legacy);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      world.sync.setConnected(true);

      world.expectNoPendingMembership();
      (await world.nextFetch('agent-a')).respond(hasNewer: false);
      await _settle();

      world.sync.recoverGap(
        'agent-a',
        const AgentTimelineCursorRange(
          epoch: 'epoch-agent-a',
          startSeq: 1,
          endSeq: 10,
        ),
      );
      final recovery = await world.nextFetch('agent-a');
      recovery.respond(hasNewer: false);
      await _settle();

      expect(
        recovery.request,
        planTimelineCatchUpAfter(
          const AgentTimelineCursor(epoch: 'epoch-agent-a', seq: 10),
        ),
      );
      world.expectNoPendingMembership();
    });

    test('switching from legacy to selective delivery publishes membership and '
        'catches up once', () async {
      final world = _TimelineWorld();
      world.sync.setDeliveryMode(TimelineDeliveryMode.legacy);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      world.sync.setConnected(true);
      (await world.nextFetch('agent-a')).respond(hasNewer: false);
      await world.waitForStatus('agent-a', ViewedTimelineStatus.ready);

      world.sync.setDeliveryMode(TimelineDeliveryMode.selective);
      expect(
        world.sync.getAgentTimelineStatus('agent-a'),
        ViewedTimelineStatus.pending,
      );
      final membership = await world.nextMembership();
      membership.succeed();
      (await world.nextFetch('agent-a')).respond(hasNewer: false);

      await world.waitForStatus('agent-a', ViewedTimelineStatus.ready);

      expect(membership.agentIds, ['agent-a']);
      world.expectNoPendingMembership();
      world.expectNoPendingFetch();
    });

    // -- edge cases the upstream suite leaves unpinned ----------------------

    test('visible ids are deduplicated, blank-filtered and sorted', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', [
        'agent-b',
        '',
        'agent-a',
        'agent-b',
      ]);
      final membership = await world.nextMembership();
      expect(membership.agentIds, ['agent-a', 'agent-b']);
      membership.succeed();
      final fetches = await Future.wait([
        world.nextFetch('agent-a'),
        world.nextFetch('agent-b'),
      ]);
      for (final fetch in fetches) {
        fetch.respond(hasNewer: false);
      }
      await _settle();
      expect(
        world.sync.getAgentTimelineStatus(''),
        ViewedTimelineStatus.pending,
      );
    });

    test('a source declaring only blanks is removed entirely', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['']);
      await _settle();
      world.expectNoPendingMembership();
      world.expectNoPendingFetch();
    });

    test('an undeclared agent reads as pending, never ready', () {
      final world = _TimelineWorld();
      expect(
        world.sync.getAgentTimelineStatus('agent-zulu'),
        ViewedTimelineStatus.pending,
      );
    });

    test('gap recovery for an undeclared agent is a no-op', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.recoverGap(
        'agent-ghost',
        const AgentTimelineCursorRange(
          epoch: 'epoch-1',
          startSeq: 1,
          endSeq: 3,
        ),
      );
      await _settle();
      world.expectNoPendingFetch();
      world.expectNoPendingMembership();
    });

    test(
      'a gap discovered before acknowledgement is replayed once subscribed',
      () async {
        final world = _TimelineWorld();
        world.sync.setConnected(true);
        world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
        final membership = await world.nextMembership();
        // The agent is desired but not yet acknowledged, so the gap parks.
        world.sync.recoverGap(
          'agent-a',
          const AgentTimelineCursorRange(
            epoch: 'epoch-agent-a',
            startSeq: 1,
            endSeq: 42,
          ),
        );
        world.expectNoPendingFetch();
        membership.succeed();

        final fetch = await world.nextFetch('agent-a');
        expect(
          fetch.request,
          planTimelineCatchUpAfter(
            const AgentTimelineCursor(epoch: 'epoch-agent-a', seq: 42),
          ),
        );
        fetch.respond(hasNewer: false);
        await world.waitForStatus('agent-a', ViewedTimelineStatus.ready);
      },
    );

    test('a page claiming newer data without an end cursor is reported, not '
        'silently completed', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      (await world.nextMembership()).succeed();
      (await world.nextFetch('agent-a')).respondWithoutCursor(hasNewer: true);

      final error = await world.nextError();
      expect(error, contains('hasNewer without an end cursor'));
      await world.waitForStatus('agent-a', ViewedTimelineStatus.error);
      expect(await world.nextRetry(), isNotNull);
    });

    test('repeating the current connected state is a no-op', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      (await world.nextMembership()).succeed();
      (await world.nextFetch('agent-a')).respond(hasNewer: false);
      await world.waitForStatus('agent-a', ViewedTimelineStatus.ready);

      world.sync.setConnected(true);
      world.sync.setActive(true);
      world.sync.setDeliveryMode(TimelineDeliveryMode.selective);
      await _settle();

      expect(
        world.sync.getAgentTimelineStatus('agent-a'),
        ViewedTimelineStatus.ready,
      );
      world.expectNoPendingMembership();
      world.expectNoPendingFetch();
    });

    test('dispose makes every later port callback inert', () async {
      final world = _TimelineWorld();
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      (await world.nextMembership()).succeed();
      final inFlight = await world.nextFetch('agent-a');

      var notified = 0;
      world.sync.subscribe(() => notified += 1);
      world.sync.dispose();
      expect(notified, 1);

      inFlight.respond(hasNewer: true, seq: 5);
      await _settle();

      world.expectNoPendingFetch();
      expect(
        world.sync.getAgentTimelineStatus('agent-a'),
        ViewedTimelineStatus.pending,
      );
      // Listeners were dropped by dispose, so nothing else fires.
      world.sync.replaceVisibleAgentIds('workspace', ['agent-b']);
      await _settle();
      expect(notified, 1);
    });

    test('an unsubscribed listener stops receiving notifications', () async {
      final world = _TimelineWorld();
      var notified = 0;
      final unsubscribe = world.sync.subscribe(() => notified += 1);
      world.sync.setConnected(true);
      world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
      expect(notified, greaterThan(0));
      final before = notified;
      unsubscribe();
      world.sync.replaceVisibleAgentIds('workspace', ['agent-b']);
      expect(notified, before);
      await _settle();
    });

    test(
      'legacy delivery acknowledges nothing while the socket is closed',
      () async {
        final world = _TimelineWorld();
        world.sync.setDeliveryMode(TimelineDeliveryMode.legacy);
        world.sync.replaceVisibleAgentIds('workspace', ['agent-a']);
        await _settle();
        world.expectNoPendingFetch();
        expect(
          world.sync.getAgentTimelineStatus('agent-a'),
          ViewedTimelineStatus.pending,
        );

        world.sync.setConnected(true);
        (await world.nextFetch('agent-a')).respond(hasNewer: false);
        await world.waitForStatus('agent-a', ViewedTimelineStatus.ready);
        world.expectNoPendingMembership();
      },
    );
  });

  // -------------------------------------------------------------------------
  group('ReplicaCache', () {
    test(
      'restores a displayable stale replica without claiming remote hydration',
      () async {
        final storage = _MemoryStorage();
        final writer = _buildCache(storage: storage);
        writer.cache.setHosts([serverId]);
        writer.source.sessions[serverId] = buildSession();
        await writer.cache.flush();

        final reader = _buildCache(storage: storage);
        reader.cache.setHosts([serverId]);
        await reader.cache.restore();

        final replica = reader.sink.restored[serverId];
        expect(replica, isNotNull);
        expect(replica!.agents.keys, ['agent-1']);
        expect(replica.workspaces.keys, ['workspace-1']);
        expect(replica.emptyProjects, isEmpty);
        expect(replica.agents['agent-1']!.title, 'Agent agent-1');
        expect(
          replica.agents['agent-1']!.updatedAt,
          '2026-07-18T08:01:00.000Z',
        );
        expect(
          replica.workspaces['workspace-1']!.statusEnteredAt,
          '2026-07-18T08:00:00.000Z',
        );
        expect(replica.timeline!.agentId, 'agent-1');
        expect(replica.timeline!.items.single.id, 'message-1');
        expect(
          (replica.timeline!.items.single as AssistantMessageItem).text,
          'Cached',
        );
        expect(replica.timeline!.cursor!.epoch, 'epoch-1');
        expect(replica.timeline!.cursor!.startSeq, 1);
        expect(replica.timeline!.cursor!.endSeq, 12);
        expect(replica.timeline!.hasOlder, isTrue);
      },
    );

    test('a persisted workspace loses its activity timestamp', () async {
      final storage = _MemoryStorage();
      final writer = _buildCache(storage: storage);
      writer.cache.setHosts([serverId]);
      writer.source.sessions[serverId] = buildSession();
      await writer.cache.flush();

      final reader = _buildCache(storage: storage);
      reader.cache.setHosts([serverId]);
      await reader.cache.restore();

      expect(
        reader.sink.restored[serverId]!.workspaces['workspace-1']!.activityAt,
        isNull,
      );
    });

    test(
      'persists only the focused agent view with a short timeline tail',
      () async {
        final storage = _MemoryStorage();
        final writer = _buildCache(storage: storage);
        writer.cache.setHosts([serverId]);

        final secondTimeline = [
          for (var index = 0; index < 60; index += 1)
            buildMessage('message-$index', 'Second $index'),
        ];
        writer.source.sessions[serverId] = buildSession(
          focusedAgentId: 'agent-2',
          agents: {
            'agent-1': buildAgent('agent-1'),
            'agent-2': buildAgent(
              'agent-2',
              workspaceId: 'workspace-2',
              cwd: '/repo/other',
            ),
          },
          workspaces: {
            'workspace-1': buildWorkspace(),
            'workspace-2': buildWorkspace(
              id: 'workspace-2',
              projectId: 'project-2',
              directory: '/repo/other',
            ),
          },
          agentStreamTail: {
            'agent-1': [buildMessage('message-1', 'First')],
            'agent-2': secondTimeline,
          },
          agentTimelineCursor: const {},
          agentTimelineHasOlder: const {},
        );
        await writer.cache.flush();

        final reader = _buildCache(storage: storage);
        reader.cache.setHosts([serverId]);
        await reader.cache.restore();

        final replica = reader.sink.restored[serverId]!;
        expect(replica.agents.keys, ['agent-2']);
        expect(replica.workspaces.keys, ['workspace-2']);
        expect(replica.emptyProjects, isEmpty);
        expect(replica.timeline!.agentId, 'agent-2');
        expect(replica.timeline!.items.length, 50);
        expect(replica.timeline!.items.first.id, 'message-10');
        expect(replica.timeline!.items.last.id, 'message-59');
        expect(replica.timeline!.cursor, isNull);
        expect(replica.timeline!.hasOlder, isFalse);
      },
    );

    test('the focused workspace falls back to the one at the agent working '
        'directory', () async {
      final storage = _MemoryStorage();
      final writer = _buildCache(storage: storage);
      writer.cache.setHosts([serverId]);
      writer.source.sessions[serverId] = buildSession(
        agents: {
          'agent-1': buildAgent('agent-1', workspaceId: 'workspace-missing'),
        },
        workspaces: {'workspace-1': buildWorkspace()},
      );
      await writer.cache.flush();

      final reader = _buildCache(storage: storage);
      reader.cache.setHosts([serverId]);
      await reader.cache.restore();

      expect(reader.sink.restored[serverId]!.workspaces.keys, ['workspace-1']);
    });

    test('a focused agent with no workspace persists none', () async {
      final storage = _MemoryStorage();
      final writer = _buildCache(storage: storage);
      writer.cache.setHosts([serverId]);
      writer.source.sessions[serverId] = buildSession(
        agents: {
          'agent-1': buildAgent(
            'agent-1',
            workspaceId: null,
            cwd: '/somewhere/else',
          ),
        },
      );
      await writer.cache.flush();

      final reader = _buildCache(storage: storage);
      reader.cache.setHosts([serverId]);
      await reader.cache.restore();

      expect(reader.sink.restored[serverId]!.workspaces, isEmpty);
      expect(reader.sink.restored[serverId]!.agents.keys, ['agent-1']);
    });

    test('a session with no focused agent persists an empty host', () async {
      final storage = _MemoryStorage();
      final writer = _buildCache(storage: storage);
      writer.cache.setHosts([serverId]);
      writer.source.sessions[serverId] = buildSession(focusedAgentId: '');
      await writer.cache.flush();

      final reader = _buildCache(storage: storage);
      reader.cache.setHosts([serverId]);
      await reader.cache.restore();

      final replica = reader.sink.restored[serverId]!;
      expect(replica.agents, isEmpty);
      expect(replica.workspaces, isEmpty);
      expect(replica.timeline, isNull);
    });

    test(
      'evicts the least recently written host when the cache exceeds its byte '
      'budget',
      () async {
        const hostIds = ['host-a', 'host-b', 'host-c'];

        // Derive the budget from the Dart encoding rather than copying the TS
        // test's literal byte count: the payloads differ in shape, but the
        // eviction rule under test does not.
        final probe = _buildCache(maxBytes: 1 << 24);
        probe.cache.setHosts(hostIds);
        probe.source.sessions['host-a'] = buildHostSession(
          'host-a',
          'A' * 1201,
        );
        probe.source.sessions['host-b'] = buildHostSession(
          'host-b',
          'B' * 1200,
        );
        probe.source.sessions['host-c'] = buildHostSession(
          'host-c',
          'C' * 1200,
        );
        await probe.cache.flush();
        final threeHostBytes = utf8.encode(probe.storage.payload!).length;

        final storage = _MemoryStorage();
        final writer = _buildCache(
          storage: storage,
          maxBytes: threeHostBytes - 1,
        );
        writer.cache.setHosts(hostIds.sublist(0, 2));
        writer.source.sessions['host-a'] = buildHostSession(
          'host-a',
          'A' * 1200,
        );
        writer.source.sessions['host-b'] = buildHostSession(
          'host-b',
          'B' * 1200,
        );
        await writer.cache.flush();

        // Rewriting host-a moves it to the newest slot, leaving host-b oldest.
        writer.source.sessions['host-a'] = buildHostSession(
          'host-a',
          'A' * 1201,
        );
        await writer.cache.flush();

        writer.cache.setHosts(hostIds);
        writer.source.sessions['host-c'] = buildHostSession(
          'host-c',
          'C' * 1200,
        );
        await writer.cache.flush();

        final reader = _buildCache(
          storage: storage,
          maxBytes: threeHostBytes - 1,
        );
        reader.cache.setHosts(hostIds);
        await reader.cache.restore();

        expect(reader.sink.restored.keys.toList()..sort(), [
          'host-a',
          'host-c',
        ]);
      },
    );

    test('a byte budget below the empty envelope still terminates', () async {
      final storage = _MemoryStorage();
      final writer = _buildCache(storage: storage, maxBytes: 0);
      writer.cache.setHosts([serverId]);
      writer.source.sessions[serverId] = buildSession(
        agentStreamTail: {
          'agent-1': [buildMessage('message-1', 'X' * 4096)],
        },
      );
      await writer.cache.flush();

      expect(storage.payload, jsonEncode({'version': 1, 'hosts': const []}));
    });

    test('drops malformed or unknown cache versions', () async {
      final storage = _MemoryStorage()
        ..values[replicaCacheStorageKey] = jsonEncode({
          'version': 999,
          'hosts': const [],
        });
      final reader = _buildCache(storage: storage);
      reader.cache.setHosts([serverId]);

      await reader.cache.restore();

      expect(reader.sink.restored, isEmpty);
    });

    test('drops an unparseable payload without throwing', () async {
      final storage = _MemoryStorage()
        ..values[replicaCacheStorageKey] = 'not json {';
      final reader = _buildCache(storage: storage);
      reader.cache.setHosts([serverId]);

      await reader.cache.restore();

      expect(reader.sink.restored, isEmpty);
    });

    test('drops a payload whose root is not an object', () async {
      final storage = _MemoryStorage()
        ..values[replicaCacheStorageKey] = jsonEncode(const [1, 2, 3]);
      final reader = _buildCache(storage: storage);
      reader.cache.setHosts([serverId]);

      await reader.cache.restore();

      expect(reader.sink.restored, isEmpty);
    });

    test('an unreadable storage restores nothing without throwing', () async {
      final storage = _MemoryStorage()..getFailure = StateError('no disk');
      final reader = _buildCache(storage: storage);
      reader.cache.setHosts([serverId]);

      await reader.cache.restore();

      expect(reader.sink.restored, isEmpty);
    });

    test('an absent or empty payload restores nothing', () async {
      final empty = _buildCache();
      empty.cache.setHosts([serverId]);
      await empty.cache.restore();
      expect(empty.sink.restored, isEmpty);

      final blank = _buildCache(
        storage: _MemoryStorage()..values[replicaCacheStorageKey] = '',
      );
      blank.cache.setHosts([serverId]);
      await blank.cache.restore();
      expect(blank.sink.restored, isEmpty);
    });

    test('one malformed host invalidates every host in the cache', () async {
      final storage = _MemoryStorage();
      final writer = _buildCache(storage: storage);
      writer.cache.setHosts([serverId, 'other-host']);
      writer.source.sessions[serverId] = buildSession();
      writer.source.sessions['other-host'] = buildHostSession(
        'other-host',
        'ok',
      );
      await writer.cache.flush();

      final decoded = jsonDecode(storage.payload!) as Map<String, Object?>;
      final hosts = decoded['hosts']! as List<Object?>;
      // Strip the required agentId from the second host's only agent.
      ((((hosts[1]! as Map<String, Object?>)['agents']! as List<Object?>)[0]
              as Map<String, Object?>))
          .remove('agentId');
      storage.values[replicaCacheStorageKey] = jsonEncode(decoded);

      final reader = _buildCache(storage: storage);
      reader.cache.setHosts([serverId, 'other-host']);
      await reader.cache.restore();

      expect(reader.sink.restored, isEmpty);
    });

    test(
      'one unrenderable timeline item drops the tail but keeps the host',
      () async {
        final storage = _MemoryStorage();
        final writer = _buildCache(storage: storage);
        writer.cache.setHosts([serverId]);
        writer.source.sessions[serverId] = buildSession();
        await writer.cache.flush();

        final decoded = jsonDecode(storage.payload!) as Map<String, Object?>;
        final host =
            (decoded['hosts']! as List<Object?>)[0] as Map<String, Object?>;
        (host['timeline']! as Map<String, Object?>)['items'] = [
          {'id': 'message-1', 'kind': 'not_a_real_kind'},
        ];
        storage.values[replicaCacheStorageKey] = jsonEncode(decoded);

        final reader = _buildCache(storage: storage);
        reader.cache.setHosts([serverId]);
        await reader.cache.restore();

        final replica = reader.sink.restored[serverId]!;
        expect(replica.timeline, isNull);
        expect(replica.agents.keys, ['agent-1']);
      },
    );

    test('a timeline item without a string id drops the tail', () async {
      final storage = _MemoryStorage();
      final writer = _buildCache(storage: storage);
      writer.cache.setHosts([serverId]);
      writer.source.sessions[serverId] = buildSession();
      await writer.cache.flush();

      final decoded = jsonDecode(storage.payload!) as Map<String, Object?>;
      final host =
          (decoded['hosts']! as List<Object?>)[0] as Map<String, Object?>;
      (host['timeline']! as Map<String, Object?>)['items'] = [
        {'kind': 'assistant_message', 'text': 'no id'},
      ];
      storage.values[replicaCacheStorageKey] = jsonEncode(decoded);

      final reader = _buildCache(storage: storage);
      reader.cache.setHosts([serverId]);
      await reader.cache.restore();

      expect(reader.sink.restored[serverId]!.timeline, isNull);
    });

    test('a negative cursor sequence invalidates the whole cache', () async {
      final storage = _MemoryStorage();
      final writer = _buildCache(storage: storage);
      writer.cache.setHosts([serverId]);
      writer.source.sessions[serverId] = buildSession();
      await writer.cache.flush();

      final decoded = jsonDecode(storage.payload!) as Map<String, Object?>;
      final host =
          (decoded['hosts']! as List<Object?>)[0] as Map<String, Object?>;
      ((host['timeline']! as Map<String, Object?>)['cursor']!
              as Map<String, Object?>)['startSeq'] =
          -1;
      storage.values[replicaCacheStorageKey] = jsonEncode(decoded);

      final reader = _buildCache(storage: storage);
      reader.cache.setHosts([serverId]);
      await reader.cache.restore();

      expect(reader.sink.restored, isEmpty);
    });

    test(
      'a stored host for an inactive server is skipped and pruned',
      () async {
        final storage = _MemoryStorage();
        final writer = _buildCache(storage: storage);
        writer.cache.setHosts([serverId, 'gone-host']);
        writer.source.sessions[serverId] = buildSession();
        writer.source.sessions['gone-host'] = buildHostSession(
          'gone-host',
          'stale',
        );
        await writer.cache.flush();
        expect(storage.payload, contains('gone-host'));

        final reader = _buildCache(storage: storage);
        reader.cache.setHosts([serverId]);
        await reader.cache.restore();
        expect(reader.sink.restored.keys, [serverId]);

        await reader.cache.flush();
        expect(storage.payload, isNot(contains('gone-host')));
      },
    );

    test('dropping a host drops what was stored for it', () async {
      final storage = _MemoryStorage();
      final writer = _buildCache(storage: storage);
      writer.cache.setHosts([serverId, 'second-host']);
      writer.source.sessions[serverId] = buildSession();
      writer.source.sessions['second-host'] = buildHostSession(
        'second-host',
        'second',
      );
      await writer.cache.flush();

      writer.cache.setHosts([serverId]);
      await writer.cache.flush();

      expect(storage.payload, isNot(contains('second-host')));
      expect(storage.payload, contains(serverId));
    });

    test('reconciling a server id carries its cache across', () async {
      final storage = _MemoryStorage();
      final writer = _buildCache(storage: storage);
      writer.cache.setHosts(['provisional']);
      writer.source.sessions['provisional'] = buildHostSession(
        'provisional',
        'carried',
      );
      await writer.cache.flush();

      writer.cache.reconcileServerId('provisional', 'paired');
      // The captured session must move too, or the same session would be
      // re-captured under the new id and clobber the carried entry.
      writer.source.sessions['paired'] = writer.source.sessions.remove(
        'provisional',
      )!;
      await writer.cache.flush();

      final reader = _buildCache(storage: storage);
      reader.cache.setHosts(['paired']);
      await reader.cache.restore();

      expect(reader.sink.restored.keys, ['paired']);
      expect(reader.sink.restored['paired']!.agents.keys, [
        'agent-provisional',
      ]);
    });

    test('reconciling schedules a write through the injected scheduler', () {
      final scheduler = _FakeScheduler();
      final writer = _buildCache(scheduler: scheduler);
      writer.cache.setHosts(['provisional']);

      writer.cache.reconcileServerId('provisional', 'paired');

      expect(scheduler.withDelay(replicaCachePersistDelay).length, 1);
    });

    test('source changes debounce into a single scheduled write', () async {
      final scheduler = _FakeScheduler();
      final storage = _MemoryStorage();
      final writer = _buildCache(storage: storage, scheduler: scheduler);
      writer.cache.setHosts([serverId]);
      writer.cache.start();
      writer.cache.start();

      writer.source.sessions[serverId] = buildSession();
      writer.source.emit();
      writer.source.emit();
      writer.source.emit();

      expect(scheduler.withDelay(replicaCachePersistDelay).length, 1);
      expect(storage.writes, isEmpty);

      scheduler.runFirst(replicaCachePersistDelay);
      await _settle();

      expect(storage.writes.length, 1);
      expect(storage.payload, contains('agent-1'));
    });

    test('stopping releases the subscription and the pending write', () async {
      final scheduler = _FakeScheduler();
      final storage = _MemoryStorage();
      final writer = _buildCache(storage: storage, scheduler: scheduler);
      writer.cache.setHosts([serverId]);
      writer.cache.start();
      writer.source.sessions[serverId] = buildSession();
      writer.source.emit();
      expect(scheduler.entries, hasLength(1));

      writer.cache.stop();
      expect(scheduler.entries, isEmpty);
      expect(writer.source.listeners, isEmpty);

      writer.source.emit();
      expect(scheduler.entries, isEmpty);
      expect(storage.writes, isEmpty);
    });

    test(
      'a failed write does not propagate and does not block the next',
      () async {
        final storage = _MemoryStorage()..setFailure = StateError('disk full');
        final writer = _buildCache(storage: storage);
        writer.cache.setHosts([serverId]);
        writer.source.sessions[serverId] = buildSession();

        await writer.cache.flush();
        expect(storage.payload, isNull);

        // A new session instance is required: an identical one is skipped.
        writer.source.sessions[serverId] = buildSession();
        await writer.cache.flush();
        expect(storage.payload, contains('agent-1'));
      },
    );

    test('an unchanged session instance is not recaptured', () async {
      final storage = _MemoryStorage();
      final writer = _buildCache(storage: storage);
      writer.cache.setHosts([serverId, 'second-host']);
      final stable = buildSession();
      writer.source.sessions[serverId] = stable;
      writer.source.sessions['second-host'] = buildHostSession(
        'second-host',
        'second',
      );
      await writer.cache.flush();

      final firstOrder =
          (jsonDecode(storage.payload!) as Map<String, Object?>)['hosts']!
              as List<Object?>;
      expect(
        firstOrder
            .map((host) => (host! as Map<String, Object?>)['serverId'])
            .toList(),
        [serverId, 'second-host'],
      );

      // Only the second host changes, so the first keeps its LRU position.
      writer.source.sessions['second-host'] = buildHostSession(
        'second-host',
        'second again',
      );
      await writer.cache.flush();

      final secondOrder =
          (jsonDecode(storage.payload!) as Map<String, Object?>)['hosts']!
              as List<Object?>;
      expect(
        secondOrder
            .map((host) => (host! as Map<String, Object?>)['serverId'])
            .toList(),
        [serverId, 'second-host'],
      );
      expect(storage.payload, contains('second again'));
    });

    test('restoring twice is stable and keeps the payload valid', () async {
      final storage = _MemoryStorage();
      final writer = _buildCache(storage: storage);
      writer.cache.setHosts([serverId]);
      writer.source.sessions[serverId] = buildSession();
      await writer.cache.flush();
      final original = storage.payload;

      final reader = _buildCache(storage: storage);
      reader.cache.setHosts([serverId]);
      await reader.cache.restore();
      await reader.cache.flush();

      expect(storage.payload, original);
      expect(reader.sink.restored.keys, [serverId]);
    });
  });
}
