/// Port of the two Paseo 0.2.0 modules that keep a client-side replica useful
/// when the daemon is *not* currently feeding it:
///
/// - `runtime/replica-cache/index.ts` — persists a small, displayable slice of
///   each host's replica so a cold launch paints the last screen the user saw
///   instead of an empty shell. Only the focused agent's view is kept, bounded
///   by a byte budget with least-recently-written hosts evicted first, so the
///   cache can never grow into a liability.
/// - `timeline/viewed-timeline-sync.ts` — reconciles *which* agents the daemon
///   should be streaming timelines for against what is actually on screen, and
///   drives each newly subscribed agent forward to the live tail. Subscription
///   membership and per-agent catch-up are separate concerns that must not
///   corrupt each other when the socket flaps mid-flight, which is why almost
///   every step here is generation-guarded.
///
/// Both modules are deliberately free of Riverpod, `DateTime.now()`, and real
/// timers: every effect they need is a port, so the frozen ordering rules can
/// be exercised without a widget tree or a wall clock.
///
/// Architectural note for this repo: the daemon projects whole timeline items
/// keyed by id rather than the client reducing deltas, so the upstream
/// `StreamItem` union and its structural runtime validation are replaced by the
/// protocol's sealed [TimelineItem]. Everything else about the cache — the
/// version gate, the whole-cache-invalidating strict decode, the tail cap, the
/// LRU byte budget — is reproduced as-is.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart';

// ---------------------------------------------------------------------------
// Shared scheduling seam
// ---------------------------------------------------------------------------

/// Cancels a task previously handed to [ReplicaSyncScheduler.schedule].
///
/// Calling it after the task already ran must be a no-op, matching upstream's
/// `clearTimeout` on an expired handle.
typedef CancelScheduledTask = void Function();

/// The one deferral seam both modules use.
///
/// Upstream calls `setTimeout` directly. Nothing in this file may start a real
/// [Timer], because every ordering rule below (retry-after-failure, the
/// unsubscribe grace window, the persist debounce) is only testable when the
/// caller decides when time passes.
abstract interface class ReplicaSyncScheduler {
  /// Runs [task] after [delay] and returns a handle that cancels it.
  CancelScheduledTask schedule(void Function() task, Duration delay);
}

// ---------------------------------------------------------------------------
// timeline-sync-plan.ts (the forward-fetch subset viewed-timeline-sync needs)
// ---------------------------------------------------------------------------

/// A timeline fetch that can only move *forward* toward the live tail.
///
/// Upstream models this as the TS union
/// `ProjectedTimelineTailFetchPlan | ProjectedTimelineAfterFetchPlan`; a sealed
/// hierarchy is the Dart analogue. `before` pages are excluded by construction
/// because catch-up must never walk backwards — that is history loading, a
/// different job owned by `TimelineNotifier.loadOlder`.
///
/// The plan is a value: [ViewedTimelineSync] compares an in-flight plan against
/// a newly requested one to decide whether a gap recovery may reuse the fetch
/// already running, so [operator ==] is load-bearing rather than cosmetic.
sealed class ProjectedTimelineForwardFetchPlan {
  const ProjectedTimelineForwardFetchPlan({
    required this.limit,
    required this.projection,
  });

  /// Page size. Defaults to the frozen [agentTimelineFetchPageSize] (40).
  final int limit;

  /// Always [AgentTimelineProjection.projected] in practice; kept as a field so
  /// the plan can be handed straight to the daemon client.
  final AgentTimelineProjection projection;

  /// The wire direction this plan requests.
  AgentTimelineDirection get direction;

  /// The anchor for an `after` plan; `null` for a tail plan.
  AgentTimelineCursor? get cursor;

  /// Adapts the plan to the existing protocol request so callers wire straight
  /// into `DaemonClient.fetchAgentTimeline` without a parallel request type.
  FetchAgentTimelineRequest toRequest({
    required String agentId,
    required String requestId,
  }) => FetchAgentTimelineRequest(
    agentId: agentId,
    requestId: requestId,
    direction: direction,
    cursor: cursor,
    limit: limit,
    projection: projection,
  );
}

/// Fetch the newest page, used when the replica has nothing trustworthy to
/// resume from.
final class ProjectedTimelineTailFetchPlan
    extends ProjectedTimelineForwardFetchPlan {
  const ProjectedTimelineTailFetchPlan({
    super.limit = agentTimelineFetchPageSize,
    super.projection = AgentTimelineProjection.projected,
  });

  @override
  AgentTimelineDirection get direction => AgentTimelineDirection.tail;

  @override
  AgentTimelineCursor? get cursor => null;

  @override
  bool operator ==(Object other) =>
      other is ProjectedTimelineTailFetchPlan &&
      other.limit == limit &&
      other.projection == projection;

  @override
  int get hashCode =>
      Object.hash(AgentTimelineDirection.tail, limit, projection);

  @override
  String toString() =>
      'ProjectedTimelineTailFetchPlan(limit: $limit, projection: ${projection.name})';
}

/// Fetch everything strictly after [cursor], used to walk from what the replica
/// already holds up to the live tail.
final class ProjectedTimelineAfterFetchPlan
    extends ProjectedTimelineForwardFetchPlan {
  const ProjectedTimelineAfterFetchPlan({
    required this.cursor,
    super.limit = agentTimelineFetchPageSize,
    super.projection = AgentTimelineProjection.projected,
  });

  @override
  final AgentTimelineCursor cursor;

  @override
  AgentTimelineDirection get direction => AgentTimelineDirection.after;

  @override
  bool operator ==(Object other) =>
      other is ProjectedTimelineAfterFetchPlan &&
      other.cursor == cursor &&
      other.limit == limit &&
      other.projection == projection;

  @override
  int get hashCode =>
      Object.hash(AgentTimelineDirection.after, cursor, limit, projection);

  @override
  String toString() =>
      'ProjectedTimelineAfterFetchPlan(cursor: ${cursor.epoch}#${cursor.seq}, '
      'limit: $limit, projection: ${projection.name})';
}

/// The newest page.
ProjectedTimelineTailFetchPlan planTimelineTailFetch() =>
    const ProjectedTimelineTailFetchPlan();

/// Everything after [cursor].
ProjectedTimelineAfterFetchPlan planTimelineCatchUpAfter(
  AgentTimelineCursor cursor,
) => ProjectedTimelineAfterFetchPlan(cursor: cursor);

/// The first fetch for an agent the client has not synced this session.
///
/// A cursor alone is not enough to resume from: it may have been reconstructed
/// from live events that arrived without any authoritative page behind them, in
/// which case there is a hole below it and only a tail fetch is safe.
ProjectedTimelineForwardFetchPlan planInitialAgentTimelineSync({
  required AgentTimelineCursorRange? cursor,
  required bool hasAuthoritativeHistory,
}) {
  if (hasAuthoritativeHistory && cursor != null) {
    return planTimelineCatchUpAfter(
      AgentTimelineCursor(epoch: cursor.epoch, seq: cursor.endSeq),
    );
  }
  return planTimelineTailFetch();
}

/// The fetch for an agent whose history is already authoritative: resume from
/// the end of what is held, or tail if nothing is held at all.
ProjectedTimelineForwardFetchPlan planResumeTimelineSync({
  required AgentTimelineCursorRange? cursor,
}) {
  if (cursor != null) {
    return planTimelineCatchUpAfter(
      AgentTimelineCursor(epoch: cursor.epoch, seq: cursor.endSeq),
    );
  }
  return planTimelineTailFetch();
}

// ---------------------------------------------------------------------------
// viewed-timeline-sync.ts
// ---------------------------------------------------------------------------

/// How the daemon delivers timelines for this connection.
///
/// `legacy` daemons push every agent unconditionally, so declaring membership
/// is pointless and the subscription RPC is skipped entirely; `selective`
/// daemons only push what the client asked for.
enum TimelineDeliveryMode { legacy, selective }

/// What a view should render for one agent's timeline freshness.
enum ViewedTimelineStatus { ready, pending, error }

/// How far behind the live tail one fetched page left the replica.
final class TimelinePageResult {
  const TimelinePageResult({required this.hasNewer, required this.endCursor});

  /// Whether the daemon holds sequences newer than this page.
  final bool hasNewer;

  /// The last cursor in this page, used as the anchor for the next `after`
  /// page. A page that claims [hasNewer] without one is a protocol violation
  /// and is reported as an error rather than silently ending catch-up.
  final AgentTimelineCursor? endCursor;
}

/// Everything [ViewedTimelineSync] needs from the outside world.
///
/// Upstream passes a plain object literal; an interface keeps the same shape
/// while letting tests supply a fake without any framework. It extends
/// [ReplicaSyncScheduler] rather than declaring a second `schedule` so both
/// modules in this file share exactly one deferral contract.
abstract interface class ViewedTimelineSyncPorts
    implements ReplicaSyncScheduler {
  /// The mode in force when the sync is constructed.
  TimelineDeliveryMode get initialDeliveryMode;

  /// Declares the complete set of agents the daemon should stream. Called with
  /// the whole set, never a delta, so a dropped call cannot desynchronize.
  Future<void> setSubscription(List<String> agentIds);

  /// The replica's current cursor for [agentId], or `null` if it holds nothing.
  AgentTimelineCursorRange? readCursor(String agentId);

  /// Whether [agentId]'s held history came from real pages rather than from
  /// live events alone. See [planInitialAgentTimelineSync].
  bool hasAuthoritativeHistory(String agentId);

  /// Fetches and applies one page. The returned [TimelinePageResult] is the
  /// only thing this module inspects; applying the entries is the port's job.
  Future<TimelinePageResult> fetchPage(
    String agentId,
    ProjectedTimelineForwardFetchPlan request,
  );

  /// Surfaces a failure. Called at most once per failed attempt so a retry
  /// storm cannot spam the user.
  void reportError(Object error);
}

/// How long to wait before retrying a failed subscription or catch-up.
const Duration viewedTimelineRetryDelay = Duration(seconds: 1);

/// How long an agent that just left the screen stays subscribed.
///
/// Flipping between two agents is the common case, and re-subscribing costs a
/// round trip plus a full catch-up; holding the subscription for half a minute
/// makes the round trip disappear for anyone who comes straight back.
const Duration viewedTimelineUnsubscribeGrace = Duration(seconds: 30);

enum _CatchUpStatus { running, complete, error }

final class _CatchUpState {
  const _CatchUpState({
    required this.generation,
    required this.status,
    this.request,
    this.cancelRetry,
  });

  final int generation;
  final _CatchUpStatus status;
  final ProjectedTimelineForwardFetchPlan? request;
  final CancelScheduledTask? cancelRetry;
}

/// Whether two catch-up requests target the same work.
///
/// Upstream compares `direction` first and treats two `tail` plans as the same
/// request without looking further, because a tail fetch has no anchor to
/// differ on. Reproduced exactly, including the `false` for a missing side.
bool _isSameCatchUpRequest(
  ProjectedTimelineForwardFetchPlan? left,
  ProjectedTimelineForwardFetchPlan? right,
) {
  if (left == null || right == null || left.direction != right.direction) {
    return false;
  }
  if (left is! ProjectedTimelineAfterFetchPlan ||
      right is! ProjectedTimelineAfterFetchPlan) {
    return true;
  }
  return left.cursor.epoch == right.cursor.epoch &&
      left.cursor.seq == right.cursor.seq;
}

/// Whether a new catch-up request should be dropped in favour of the one
/// already tracked for that agent.
///
/// A superseding request (a gap recovery) only defers to an *identical* running
/// fetch; an ordinary request also defers to a completed one, which is what
/// stops a re-publication of an unchanged visible set from re-fetching.
bool _shouldKeepCurrentCatchUp({
  required _CatchUpState? current,
  required ProjectedTimelineForwardFetchPlan? request,
  required bool supersede,
}) {
  if (current == null) return false;
  if (supersede) {
    return current.status == _CatchUpStatus.running &&
        _isSameCatchUpRequest(current.request, request);
  }
  return current.status == _CatchUpStatus.running ||
      current.status == _CatchUpStatus.complete;
}

/// Deduplicates, drops blanks, and sorts.
///
/// Upstream is `[...new Set(ids)].filter(Boolean).sort()`. `filter(Boolean)`
/// drops the empty string (the only falsy string), so the Dart equivalent is
/// `isNotEmpty`; `null` cannot occur here because the list is typed. JS's
/// default `Array.prototype.sort` compares UTF-16 code units, which is exactly
/// what Dart's `String.compareTo` does, so the resulting order is identical.
List<String> _normalizeAgentIds(Iterable<String> agentIds) =>
    agentIds.toSet().where((agentId) => agentId.isNotEmpty).toList()..sort();

bool _sameAgentIds(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// Keeps the daemon's timeline subscription equal to what is on screen, and
/// each subscribed agent's replica caught up to the live tail.
///
/// Upstream returns a closure object from `createViewedTimelineSync`; a class
/// is the Dart analogue and exposes the same surface. Construction does not
/// start any work: nothing happens until a view declares visibility and the
/// socket reports itself connected.
class ViewedTimelineSync {
  /// Creates a sync in the background-safe initial state: active (a mounted app
  /// is in the foreground), disconnected, and with no declared visibility.
  ViewedTimelineSync(ViewedTimelineSyncPorts ports)
    : _ports = ports,
      _deliveryMode = ports.initialDeliveryMode;

  final ViewedTimelineSyncPorts _ports;

  /// Visible agents per declaring view. Keeping sources separate is what lets a
  /// split screen remove one pane without disturbing the other's subscription.
  final Map<String, List<String>> _sources = {};
  final Map<String, _CatchUpState> _catchUps = {};
  final Map<String, int> _catchUpGenerations = {};
  final Map<String, ProjectedTimelineForwardFetchPlan> _pendingGaps = {};
  final Map<String, CancelScheduledTask> _lingeringRemovals = {};
  final Set<String> _visibilityCatchUpPending = {};
  final Set<String> _visibilityCatchUpErrors = {};
  final Set<void Function()> _listeners = {};

  bool _active = true;
  bool _connected = false;
  TimelineDeliveryMode _deliveryMode;
  bool _disposed = false;
  List<String> _desired = const [];
  List<String> _acknowledged = const [];
  int _membershipGeneration = 0;
  bool _reconciling = false;
  bool _reconcileRequested = false;
  bool _membershipNeedsRetry = false;
  CancelScheduledTask? _cancelMembershipRetry;

  List<String> _visibleAgentIds() => _active
      ? _normalizeAgentIds(_sources.values.expand((agentIds) => agentIds))
      : const [];

  List<String> _effectiveAgentIds() =>
      _normalizeAgentIds([..._visibleAgentIds(), ..._lingeringRemovals.keys]);

  bool _isAcknowledged(String agentId) => _acknowledged.contains(agentId);

  bool _isDesired(String agentId) => _desired.contains(agentId);

  /// Notifies listeners over a snapshot.
  ///
  /// JS iterates the live `Set`, which tolerates a listener unsubscribing
  /// itself mid-notification. Dart forbids mutation during iteration, so a
  /// snapshot is taken and entries removed in the meantime are skipped — the
  /// same observable outcome. A listener *added* mid-notification is not called
  /// until the next notification, which JS would have called; no caller depends
  /// on that, and re-entrant subscription during a notification is not a
  /// pattern this module supports.
  void _notifyListeners() {
    for (final listener in _listeners.toList(growable: false)) {
      if (!_listeners.contains(listener)) continue;
      listener();
    }
  }

  void _setVisibilityCatchUpReady(String agentId) {
    final wasPending = _visibilityCatchUpPending.remove(agentId);
    final hadError = _visibilityCatchUpErrors.remove(agentId);
    if (wasPending || hadError) _notifyListeners();
  }

  /// Moves agents from pending to error. An agent that was not pending is left
  /// alone, so a failure cannot invent an error for an agent nobody is waiting
  /// on.
  void _setVisibilityCatchUpError(List<String> agentIds) {
    var changed = false;
    for (final agentId in agentIds) {
      if (!_visibilityCatchUpPending.remove(agentId)) continue;
      _visibilityCatchUpErrors.add(agentId);
      changed = true;
    }
    if (changed) _notifyListeners();
  }

  /// Invalidates any in-flight or scheduled catch-up for [agentId].
  ///
  /// Bumping the generation is what makes an already-awaited fetch return
  /// without applying anything when it finally resolves.
  void _cancelCatchUp(String agentId) {
    _catchUpGenerations[agentId] = (_catchUpGenerations[agentId] ?? 0) + 1;
    _catchUps[agentId]?.cancelRetry?.call();
    _catchUps.remove(agentId);
    _pendingGaps.remove(agentId);
  }

  bool _catchUpAbandoned(String agentId, int generation) =>
      _disposed ||
      !_connected ||
      !_isDesired(agentId) ||
      !_isAcknowledged(agentId) ||
      _catchUps[agentId]?.generation != generation;

  /// Pages forward until the daemon reports nothing newer.
  ///
  /// The guard runs both before the fetch and after it resolves: the socket can
  /// close, the agent can scroll off screen, or a newer generation can start
  /// while the request is in flight, and in every one of those cases this page
  /// must be dropped rather than advance a replica nobody is watching.
  Future<void> _fetchUntilCurrent(
    String agentId,
    int generation,
    ProjectedTimelineForwardFetchPlan request,
  ) async {
    if (_catchUpAbandoned(agentId, generation)) return;

    try {
      final page = await _ports.fetchPage(agentId, request);
      if (_catchUpAbandoned(agentId, generation)) return;
      final endCursor = page.endCursor;
      if (page.hasNewer && endCursor != null) {
        await _fetchUntilCurrent(
          agentId,
          generation,
          planTimelineCatchUpAfter(endCursor),
        );
        return;
      }
      if (page.hasNewer) {
        // Thrown inside the try so it takes the same retry path as a transport
        // failure, exactly as upstream does.
        throw StateError(
          'Timeline page for $agentId hasNewer without an end cursor',
        );
      }
      _catchUps[agentId] = _CatchUpState(
        generation: generation,
        status: _CatchUpStatus.complete,
      );
      _setVisibilityCatchUpReady(agentId);
    } catch (error) {
      if (_catchUps[agentId]?.generation != generation) return;
      final cancelRetry = _ports.schedule(() {
        final current = _catchUps[agentId];
        if (current?.generation != generation ||
            current!.status != _CatchUpStatus.error) {
          return;
        }
        _startCatchUp(agentId);
      }, viewedTimelineRetryDelay);
      _catchUps[agentId] = _CatchUpState(
        generation: generation,
        status: _CatchUpStatus.error,
        cancelRetry: cancelRetry,
      );
      _setVisibilityCatchUpError([agentId]);
      _ports.reportError(error);
    }
  }

  /// Starts (or refuses to restart) catch-up for one agent.
  ///
  /// When the agent is not yet subscribed the [request] is parked in
  /// `_pendingGaps` rather than dropped, so a gap discovered while offline is
  /// still recovered once the subscription is acknowledged.
  void _startCatchUp(
    String agentId, {
    ProjectedTimelineForwardFetchPlan? request,
    bool supersede = false,
  }) {
    if (!_connected || !_isDesired(agentId) || !_isAcknowledged(agentId)) {
      if (request != null) _pendingGaps[agentId] = request;
      return;
    }
    final current = _catchUps[agentId];
    if (_shouldKeepCurrentCatchUp(
      current: current,
      request: request,
      supersede: supersede,
    )) {
      return;
    }
    current?.cancelRetry?.call();
    final generation = (_catchUpGenerations[agentId] ?? 0) + 1;
    _catchUpGenerations[agentId] = generation;
    _catchUps[agentId] = _CatchUpState(
      generation: generation,
      status: _CatchUpStatus.running,
      request: request,
    );
    _pendingGaps.remove(agentId);
    final cursor = _ports.readCursor(agentId);
    final nextRequest =
        request ??
        (_ports.hasAuthoritativeHistory(agentId)
            ? planResumeTimelineSync(cursor: cursor)
            : planInitialAgentTimelineSync(
                cursor: cursor,
                hasAuthoritativeHistory: false,
              ));
    unawaited(_fetchUntilCurrent(agentId, generation, nextRequest));
  }

  void _startAcknowledgedCatchUps() {
    for (final agentId in _acknowledged) {
      final gap = _pendingGaps[agentId];
      _startCatchUp(agentId, request: gap, supersede: gap != null);
    }
  }

  /// Publishes the currently desired set and, on success, starts catch-ups.
  ///
  /// Recursion at the end is deliberate: `desired` can change while the RPC is
  /// in flight, and the loop only exits once the acknowledged set equals the
  /// desired one, so the daemon is never left holding a stale membership.
  Future<void> _reconcileLatestMembership() async {
    if (_disposed ||
        !_connected ||
        _deliveryMode != TimelineDeliveryMode.selective) {
      return;
    }
    final generation = _membershipGeneration;
    final requested = _desired;
    if (!_membershipNeedsRetry && _sameAgentIds(requested, _acknowledged)) {
      return;
    }
    _membershipNeedsRetry = false;
    try {
      await _ports.setSubscription(requested);
    } catch (error) {
      _membershipNeedsRetry = true;
      _setVisibilityCatchUpError(requested);
      _cancelMembershipRetry?.call();
      _cancelMembershipRetry = _ports.schedule(() {
        _cancelMembershipRetry = null;
        if (_disposed ||
            !_connected ||
            _membershipGeneration != generation ||
            !_sameAgentIds(_desired, requested)) {
          return;
        }
        unawaited(_reconcileMembership());
      }, viewedTimelineRetryDelay);
      _ports.reportError(error);
      return;
    }
    _cancelMembershipRetry?.call();
    _cancelMembershipRetry = null;
    if (_disposed ||
        !_connected ||
        _deliveryMode != TimelineDeliveryMode.selective) {
      return;
    }
    _acknowledged = requested;
    if (generation != _membershipGeneration) {
      await _reconcileLatestMembership();
      return;
    }
    _startAcknowledgedCatchUps();
    if (!_sameAgentIds(_desired, _acknowledged)) {
      await _reconcileLatestMembership();
    }
  }

  /// Serializes membership reconciliation to one in-flight run.
  ///
  /// A second request while one is running only sets a flag; the `finally`
  /// block re-enters afterwards. Without this, two overlapping `setSubscription`
  /// calls could land out of order and leave the daemon on the older set.
  Future<void> _reconcileMembership() async {
    if (_reconciling) {
      _reconcileRequested = true;
      return;
    }
    if (_disposed || !_connected) return;
    _reconciling = true;
    try {
      await _reconcileLatestMembership();
    } finally {
      _reconciling = false;
      if (_reconcileRequested &&
          !_disposed &&
          _connected &&
          _deliveryMode == TimelineDeliveryMode.selective) {
        _reconcileRequested = false;
        unawaited(_reconcileMembership());
      } else if (!_disposed &&
          _connected &&
          _deliveryMode == TimelineDeliveryMode.selective &&
          !_membershipNeedsRetry &&
          !_sameAgentIds(_desired, _acknowledged)) {
        unawaited(_reconcileMembership());
      }
    }
  }

  void _retryFailedCatchUps() {
    for (final agentId in _acknowledged) {
      if (_catchUps[agentId]?.status == _CatchUpStatus.error) {
        _startCatchUp(agentId);
      }
    }
  }

  /// Adopts [nextDesired] as the membership to publish.
  ///
  /// An unchanged set is not a no-op: it is the hook that retries a failed
  /// subscription and a failed catch-up without requiring the view to declare
  /// visibility again.
  void _commitDesiredMembership(
    List<String> nextDesired, {
    bool resetCatchUpStatus = false,
  }) {
    var statusChanged = false;
    if (resetCatchUpStatus) {
      for (final agentId in nextDesired) {
        if (_visibilityCatchUpPending.add(agentId)) statusChanged = true;
        if (_visibilityCatchUpErrors.remove(agentId)) statusChanged = true;
      }
    }
    if (_sameAgentIds(nextDesired, _desired)) {
      if (statusChanged) _notifyListeners();
      if (_deliveryMode == TimelineDeliveryMode.selective &&
          _membershipNeedsRetry) {
        unawaited(_reconcileMembership());
      }
      _retryFailedCatchUps();
      return;
    }

    for (final agentId in _desired) {
      if (!nextDesired.contains(agentId)) {
        _cancelCatchUp(agentId);
        _visibilityCatchUpPending.remove(agentId);
        _visibilityCatchUpErrors.remove(agentId);
      }
    }
    for (final agentId in nextDesired) {
      if (!_desired.contains(agentId)) {
        _visibilityCatchUpPending.add(agentId);
        _visibilityCatchUpErrors.remove(agentId);
      }
    }
    _cancelMembershipRetry?.call();
    _cancelMembershipRetry = null;
    _desired = nextDesired;
    _membershipGeneration += 1;
    _notifyListeners();
    if (_deliveryMode == TimelineDeliveryMode.legacy) {
      _acknowledged = _connected ? _desired : const [];
      if (_connected) _startAcknowledgedCatchUps();
      return;
    }
    unawaited(_reconcileMembership());
  }

  void _clearLingeringRemovals() {
    for (final cancel in _lingeringRemovals.values.toList(growable: false)) {
      cancel();
    }
    _lingeringRemovals.clear();
  }

  /// Recomputes membership from the declared sources.
  ///
  /// When [allowGrace] is set and the connection can actually carry a
  /// subscription, an agent that just disappeared is held for
  /// [viewedTimelineUnsubscribeGrace] instead of being dropped immediately.
  /// Anything else — a disconnect, a delivery-mode switch — clears the grace
  /// window outright, because holding a subscription on a socket that cannot
  /// deliver is pure lag.
  void _publishVisibleMembership(bool allowGrace) {
    final visible = _visibleAgentIds();
    for (final agentId in visible) {
      _lingeringRemovals.remove(agentId)?.call();
    }

    if (allowGrace &&
        _connected &&
        _deliveryMode == TimelineDeliveryMode.selective) {
      for (final agentId in _desired) {
        if (visible.contains(agentId) ||
            _lingeringRemovals.containsKey(agentId)) {
          continue;
        }
        final cancel = _ports.schedule(() {
          _lingeringRemovals.remove(agentId);
          _commitDesiredMembership(_effectiveAgentIds());
        }, viewedTimelineUnsubscribeGrace);
        _lingeringRemovals[agentId] = cancel;
      }
    } else {
      _clearLingeringRemovals();
    }

    _commitDesiredMembership(_effectiveAgentIds());
  }

  // -- public surface -------------------------------------------------------

  /// Registers [listener] for status changes and returns its unsubscriber.
  void Function() subscribe(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// The freshness a view should render for [agentId].
  ///
  /// An agent nobody declared visible reads as `pending` rather than `ready`,
  /// so a view that renders before its own visibility declaration lands never
  /// shows a stale replica as current.
  ViewedTimelineStatus getAgentTimelineStatus(String agentId) {
    if (_visibilityCatchUpErrors.contains(agentId)) {
      return ViewedTimelineStatus.error;
    }
    if (!_isDesired(agentId) || _visibilityCatchUpPending.contains(agentId)) {
      return ViewedTimelineStatus.pending;
    }
    return ViewedTimelineStatus.ready;
  }

  /// Declares the complete set of agents [sourceId] currently shows.
  ///
  /// An empty list removes the source entirely rather than recording an empty
  /// entry, so an unmounted view leaves no trace in the union.
  void replaceVisibleAgentIds(String sourceId, List<String> agentIds) {
    final normalized = _normalizeAgentIds(agentIds);
    if (normalized.isEmpty) {
      _sources.remove(sourceId);
    } else {
      _sources[sourceId] = normalized;
    }
    _publishVisibleMembership(true);
  }

  /// Reports whether the app is in the foreground.
  ///
  /// Backgrounding empties the visible set but still goes through the grace
  /// window, so a quick app switch does not cost a resubscribe.
  void setActive(bool nextActive) {
    if (_active == nextActive) return;
    _active = nextActive;
    _publishVisibleMembership(true);
  }

  /// Reports socket state.
  ///
  /// Disconnecting resets every agent to pending *before* clearing the
  /// acknowledged set, so views immediately stop claiming their timelines are
  /// current; reconnecting bumps the generation so nothing from the old socket
  /// can complete against the new one.
  void setConnected(bool nextConnected) {
    if (_connected == nextConnected) return;
    _connected = nextConnected;
    if (!_connected) {
      _clearLingeringRemovals();
      _commitDesiredMembership(_visibleAgentIds(), resetCatchUpStatus: true);
      _cancelMembershipRetry?.call();
      _cancelMembershipRetry = null;
      _acknowledged = const [];
      _membershipGeneration += 1;
      for (final agentId in _desired) {
        _cancelCatchUp(agentId);
      }
      return;
    }
    _membershipGeneration += 1;
    if (_deliveryMode == TimelineDeliveryMode.legacy) {
      _acknowledged = _desired;
      _startAcknowledgedCatchUps();
    } else {
      unawaited(_reconcileMembership());
    }
  }

  /// Switches delivery mode, discarding all membership and catch-up state.
  ///
  /// The two modes disagree about what "acknowledged" means, so nothing carries
  /// over: every visible agent goes back to pending and re-syncs from scratch.
  void setDeliveryMode(TimelineDeliveryMode nextMode) {
    if (_deliveryMode == nextMode) return;
    _deliveryMode = nextMode;
    _clearLingeringRemovals();
    _cancelMembershipRetry?.call();
    _cancelMembershipRetry = null;
    _membershipNeedsRetry = false;
    _membershipGeneration += 1;
    for (final agentId in _desired) {
      _cancelCatchUp(agentId);
    }
    _desired = _visibleAgentIds();
    _visibilityCatchUpPending.clear();
    _visibilityCatchUpErrors.clear();
    _visibilityCatchUpPending.addAll(_desired);
    _acknowledged = _deliveryMode == TimelineDeliveryMode.legacy && _connected
        ? _desired
        : const [];
    _notifyListeners();
    if (_deliveryMode == TimelineDeliveryMode.selective && _connected) {
      unawaited(_reconcileMembership());
    } else if (_connected) {
      _startAcknowledgedCatchUps();
    }
  }

  /// Recovers a detected sequence gap for [agentId] by re-paging from [cursor].
  ///
  /// Ignored for an agent nobody is showing: there is no replica worth
  /// repairing, and repairing it would resurrect a subscription the user
  /// already navigated away from.
  void recoverGap(String agentId, AgentTimelineCursorRange cursor) {
    if (!_isDesired(agentId)) return;
    _startCatchUp(
      agentId,
      request: planTimelineCatchUpAfter(
        AgentTimelineCursor(epoch: cursor.epoch, seq: cursor.endSeq),
      ),
      supersede: true,
    );
  }

  /// Tears everything down. Idempotent, and every later callback is a no-op
  /// because `_disposed` is checked at each async resumption point.
  void dispose() {
    _disposed = true;
    _clearLingeringRemovals();
    _cancelMembershipRetry?.call();
    _cancelMembershipRetry = null;
    _sources.clear();
    _membershipGeneration += 1;
    for (final agentId in _desired) {
      _cancelCatchUp(agentId);
    }
    _desired = const [];
    _acknowledged = const [];
    _visibilityCatchUpPending.clear();
    _visibilityCatchUpErrors.clear();
    _notifyListeners();
    _listeners.clear();
  }
}

// ---------------------------------------------------------------------------
// runtime/replica-cache/index.ts
// ---------------------------------------------------------------------------

/// The single key the whole cache lives under.
const String replicaCacheStorageKey = '@paseo:replica-cache';

/// Bumped whenever the stored shape changes. A payload written by any other
/// version is discarded wholesale rather than migrated — the cache is a
/// disposable convenience, so a migration bug would cost more than a cold
/// start ever could.
const int replicaCacheVersion = 1;

/// How long a change waits before it is written, so a burst of store updates
/// costs one write instead of dozens.
const Duration replicaCachePersistDelay = Duration(milliseconds: 750);

/// How many timeline items are kept for the focused agent. Enough to fill the
/// first screen; the rest is refetched.
const int replicaCacheMaxTimelineItems = 50;

/// Default byte ceiling for the entire serialized cache.
const int replicaCacheMaxBytes = 1024 * 1024;

/// Where the cache persists. One key, string in and string out.
///
/// Both methods may fail; [ReplicaCache] treats every failure as "no cache"
/// rather than propagating, because a broken cache must never break launch.
abstract interface class ReplicaCacheStorage {
  Future<String?> getItem(String key);
  Future<void> setItem(String key, String value);
}

/// The live slice of one host's replica that the cache reads.
///
/// This is a *view*, not the store: [ReplicaCache] compares successive reads by
/// identity to skip re-serializing an unchanged host, so a source must return
/// the identical instance while nothing has changed and a fresh instance when
/// something has. That is what upstream gets for free from zustand's immutable
/// state objects.
final class ReplicaCacheSession {
  const ReplicaCacheSession({
    required this.focusedAgentId,
    required this.agents,
    required this.workspaces,
    required this.agentStreamTail,
    required this.agentTimelineCursor,
    required this.agentTimelineHasOlder,
  });

  /// The agent currently on screen; only this one is persisted.
  final String? focusedAgentId;
  final Map<String, AgentSummary> agents;
  final Map<String, WorkspaceDescriptor> workspaces;
  final Map<String, List<TimelineItem>> agentStreamTail;
  final Map<String, AgentTimelineCursorRange> agentTimelineCursor;
  final Map<String, bool> agentTimelineHasOlder;
}

/// Reads live sessions and reports when any of them changed.
abstract interface class ReplicaCacheSessionSource {
  /// The current session for [serverId], or `null` if there is none.
  ReplicaCacheSession? readSession(String serverId);

  /// Registers [listener] for "something changed"; returns its unsubscriber.
  /// Upstream is `useSessionStore.subscribe`.
  CancelScheduledTask subscribe(void Function() listener);
}

/// Receives a restored replica.
///
/// Upstream calls `restoreSessionReplica`, which deliberately does *not* mark
/// the session as remotely hydrated: the data is displayable but stale, and the
/// app must still do a real fetch.
abstract interface class ReplicaCacheSessionSink {
  void restoreSessionReplica(String serverId, CachedHostReplica replica);
}

/// The persisted timeline tail for one agent.
final class CachedTimelineReplica {
  const CachedTimelineReplica({
    required this.agentId,
    required this.items,
    required this.cursor,
    required this.hasOlder,
  });

  final String agentId;
  final List<TimelineItem> items;
  final AgentTimelineCursorRange? cursor;
  final bool hasOlder;
}

/// One host's restored replica.
final class CachedHostReplica {
  const CachedHostReplica({
    required this.agents,
    required this.workspaces,
    required this.emptyProjects,
    required this.timeline,
  });

  final Map<String, AgentSummary> agents;
  final Map<String, WorkspaceDescriptor> workspaces;
  final Map<String, WorkspaceProjectDescriptor> emptyProjects;

  /// `null` when nothing was stored, and also when what was stored failed to
  /// decode — a corrupt tail drops the timeline but keeps the rest of the host.
  final CachedTimelineReplica? timeline;
}

/// Raw persisted timeline. Items stay as decoded JSON until restore, mirroring
/// upstream's `z.unknown()`: the item shape is validated late and leniently, so
/// one bad item costs the timeline rather than the whole cache.
final class _StoredTimeline {
  const _StoredTimeline({
    required this.agentId,
    required this.items,
    required this.cursor,
    required this.hasOlder,
  });

  final String agentId;
  final List<Object?> items;
  final AgentTimelineCursorRange? cursor;
  final bool hasOlder;

  Map<String, Object?> toJson() => {
    'agentId': agentId,
    'items': items,
    'cursor': cursor == null
        ? null
        : {
            'epoch': cursor!.epoch,
            'startSeq': cursor!.startSeq,
            'endSeq': cursor!.endSeq,
          },
    'hasOlder': hasOlder,
  };

  static _StoredTimeline fromJson(Map<String, Object?> json) {
    final rawCursor = json['cursor'];
    return _StoredTimeline(
      agentId: json['agentId']! as String,
      items: json['items'] as List<Object?>? ?? const [],
      cursor: rawCursor == null
          ? null
          : AgentTimelineCursorRange(
              epoch: (rawCursor as Map<String, Object?>)['epoch']! as String,
              startSeq: _nonNegativeInt(rawCursor['startSeq']),
              endSeq: _nonNegativeInt(rawCursor['endSeq']),
            ),
      hasOlder: json['hasOlder']! as bool,
    );
  }
}

/// Upstream's cursor schema is `z.number().int().nonnegative()`; anything else
/// fails the parse and therefore invalidates the entire cache.
int _nonNegativeInt(Object? value) {
  if (value is! int || value < 0) {
    throw FormatException('Expected a non-negative int, got: $value');
  }
  return value;
}

final class _StoredHost {
  const _StoredHost({
    required this.serverId,
    required this.agents,
    required this.workspaces,
    required this.emptyProjects,
    required this.timeline,
  });

  final String serverId;
  final List<AgentSummary> agents;
  final List<WorkspaceDescriptor> workspaces;
  final List<WorkspaceProjectDescriptor> emptyProjects;
  final _StoredTimeline? timeline;

  _StoredHost withServerId(String nextServerId) => _StoredHost(
    serverId: nextServerId,
    agents: agents,
    workspaces: workspaces,
    emptyProjects: emptyProjects,
    timeline: timeline,
  );

  Map<String, Object?> toJson() => {
    'serverId': serverId,
    'agents': agents.map((agent) => agent.toJson()).toList(growable: false),
    'workspaces': workspaces
        .map((workspace) => workspace.toJson())
        .toList(growable: false),
    'emptyProjects': emptyProjects
        .map((project) => project.toJson())
        .toList(growable: false),
    'timeline': timeline?.toJson(),
  };

  static _StoredHost fromJson(Map<String, Object?> json) {
    final timeline = json['timeline'];
    return _StoredHost(
      serverId: json['serverId']! as String,
      agents: _decodeList(json['agents'], AgentSummary.fromJson),
      workspaces: _decodeList(json['workspaces'], WorkspaceDescriptor.fromJson),
      emptyProjects: _decodeList(
        json['emptyProjects'],
        WorkspaceProjectDescriptor.fromJson,
      ),
      timeline: timeline == null
          ? null
          : _StoredTimeline.fromJson(timeline as Map<String, Object?>),
    );
  }
}

List<T> _decodeList<T>(
  Object? value,
  T Function(Map<String, Object?> json) decode,
) => (value! as List<Object?>)
    .map((entry) => decode(entry! as Map<String, Object?>))
    .toList(growable: false);

/// Whether one persisted timeline item is something this client can render.
///
/// Upstream hand-validates the `StreamItem` union field by field. Here the
/// protocol codec does the decoding, so the check is: it must be an object with
/// a string `id`, and the codec must recognise its `kind`. The recognition test
/// is that the decoded item reports the same `kind` it was given — an unknown
/// kind falls back to an error item and therefore reports a different one,
/// which upstream also treats as invalid.
TimelineItem? _decodeStreamItem(Object? value) {
  if (value is! Map<String, Object?>) return null;
  if (value['id'] is! String) return null;
  final kind = value['kind'];
  if (kind is! String) return null;
  final TimelineItem item;
  try {
    item = TimelineItem.fromJson(value);
  } on Object {
    return null;
  }
  return item.kind == kind ? item : null;
}

CachedTimelineReplica? _deserializeTimeline(_StoredTimeline? stored) {
  if (stored == null) return null;
  final items = <TimelineItem>[];
  for (final raw in stored.items) {
    final item = _decodeStreamItem(raw);
    // One unrenderable item invalidates the whole tail: a partially decoded
    // timeline would show holes, which is worse than showing nothing.
    if (item == null) return null;
    items.add(item);
  }
  return CachedTimelineReplica(
    agentId: stored.agentId,
    items: List<TimelineItem>.unmodifiable(items),
    cursor: stored.cursor,
    hasOlder: stored.hasOlder,
  );
}

CachedHostReplica _deserializeHost(_StoredHost stored) => CachedHostReplica(
  agents: {for (final agent in stored.agents) agent.agentId: agent},
  workspaces: {
    for (final workspace in stored.workspaces) workspace.id: workspace,
  },
  emptyProjects: {
    for (final project in stored.emptyProjects) project.projectId: project,
  },
  timeline: _deserializeTimeline(stored.timeline),
);

/// Drops the workspace's activity timestamp before persisting.
///
/// Upstream writes `activityAt: null` into the stored descriptor: a cached
/// "active 3 minutes ago" would still read as 3 minutes ago after a week
/// offline, so the field is better absent than wrong. [WorkspaceDescriptor] has
/// no `copyWith`, so the round trip through JSON is how the field is cleared.
WorkspaceDescriptor _withoutWorkspaceActivity(WorkspaceDescriptor workspace) =>
    WorkspaceDescriptor.fromJson(workspace.toJson()..['activityAt'] = null);

/// Persists a displayable slice of each host's replica across launches.
///
/// The cache is intentionally tiny: for every host it keeps only the focused
/// agent, that agent's workspace, and the last
/// [replicaCacheMaxTimelineItems] timeline items. It is a paint-fast aid, never
/// a source of truth — restored data is handed to the sink in a way that leaves
/// the session still needing a real fetch.
class ReplicaCache {
  /// [maxBytes] overrides the default ceiling. It is raised to the size of an
  /// empty payload if a caller passes something smaller, because a budget below
  /// the fixed envelope would make eviction unable to ever satisfy it.
  factory ReplicaCache({
    required ReplicaCacheStorage storage,
    required ReplicaCacheSessionSource source,
    required ReplicaCacheSessionSink sink,
    required ReplicaSyncScheduler scheduler,
    int? maxBytes,
  }) => ReplicaCache._(storage, source, sink, scheduler, maxBytes);

  ReplicaCache._(
    this._storage,
    this._source,
    this._sink,
    this._scheduler,
    int? maxBytes,
  ) {
    final emptyPayloadBytes = utf8
        .encode(
          jsonEncode({
            'version': replicaCacheVersion,
            'hosts': const <Object?>[],
          }),
        )
        .length;
    _maxBytes = math.max(maxBytes ?? replicaCacheMaxBytes, emptyPayloadBytes);
  }

  final ReplicaCacheStorage _storage;
  final ReplicaCacheSessionSource _source;
  final ReplicaCacheSessionSink _sink;
  final ReplicaSyncScheduler _scheduler;

  late final int _maxBytes;

  final Set<String> _activeServerIds = <String>{};

  /// Insertion-ordered, and re-inserted on every capture, which is what makes
  /// the first key the least recently written host. Dart's default `Map` is a
  /// `LinkedHashMap`, so it matches JS `Map` iteration order exactly.
  final Map<String, _StoredHost> _storedHosts = {};

  final Map<String, String> _lastFocusedAgentIds = {};
  final Map<String, ReplicaCacheSession> _capturedSessions = {};

  bool _needsPersist = false;
  CancelScheduledTask? _unsubscribe;
  CancelScheduledTask? _cancelPersist;
  Future<void> _writeQueue = Future<void>.value();

  /// Declares which hosts are connected.
  ///
  /// Anything stored for a host that is no longer configured is dropped
  /// immediately, so removing a host also removes its cached contents rather
  /// than leaving them to resurface later.
  void setHosts(Iterable<String> serverIds) {
    final next = serverIds.toSet();
    _activeServerIds
      ..clear()
      ..addAll(next);
    var removedStoredHost = false;
    // Snapshot the keys: JS Map iterators tolerate deleting the current entry,
    // Dart's do not.
    for (final serverId in _storedHosts.keys.toList(growable: false)) {
      if (!next.contains(serverId)) {
        _storedHosts.remove(serverId);
        removedStoredHost = true;
      }
    }
    for (final serverId in _lastFocusedAgentIds.keys.toList(growable: false)) {
      if (!next.contains(serverId)) _lastFocusedAgentIds.remove(serverId);
    }
    for (final serverId in _capturedSessions.keys.toList(growable: false)) {
      if (!next.contains(serverId)) _capturedSessions.remove(serverId);
    }
    if (removedStoredHost) _needsPersist = true;
    if (_unsubscribe != null && _needsPersist) _schedulePersist();
  }

  /// Loads the cache and pushes what survives into the sink.
  ///
  /// Every failure mode — unreadable storage, unparseable JSON, a wrong
  /// version, a malformed host — ends in "restore nothing" without throwing.
  /// Call [setHosts] first: a stored host that is not active is skipped *and*
  /// marks the cache dirty, so it is pruned by the next write.
  Future<void> restore() async {
    final String? raw;
    try {
      raw = await _storage.getItem(replicaCacheStorageKey);
    } on Object {
      return;
    }
    if (raw == null || raw.isEmpty) return;
    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on Object {
      return;
    }
    final List<_StoredHost> hosts;
    try {
      hosts = _decodeCache(parsed);
    } on Object {
      return;
    }
    for (final host in hosts) {
      if (!_activeServerIds.contains(host.serverId)) {
        _needsPersist = true;
        continue;
      }
      _storedHosts[host.serverId] = host;
      final timeline = host.timeline;
      if (timeline != null) {
        _lastFocusedAgentIds[host.serverId] = timeline.agentId;
      }
    }
    if (_buildBoundedPayload().evicted) _needsPersist = true;
    for (final host in _storedHosts.values.toList(growable: false)) {
      _sink.restoreSessionReplica(host.serverId, _deserializeHost(host));
      final session = _source.readSession(host.serverId);
      if (session != null) _capturedSessions[host.serverId] = session;
    }
  }

  /// Strict, all-or-nothing decode, matching upstream's single `safeParse` over
  /// the whole document: one malformed host discards every host.
  List<_StoredHost> _decodeCache(Object? parsed) {
    if (parsed is! Map<String, Object?>) {
      throw const FormatException('Replica cache root is not an object');
    }
    if (parsed['version'] != replicaCacheVersion) {
      throw FormatException('Unsupported cache version: ${parsed['version']}');
    }
    final hosts = parsed['hosts'];
    if (hosts is! List<Object?>) {
      throw const FormatException('Replica cache hosts is not a list');
    }
    return hosts
        .map((host) => _StoredHost.fromJson(host! as Map<String, Object?>))
        .toList(growable: false);
  }

  /// Begins watching the source. Idempotent.
  ///
  /// The focused agent is recorded on every change even when nothing else is
  /// written yet, so a flush that happens after the user navigates away still
  /// persists the view they actually had.
  void start() {
    if (_unsubscribe != null) return;
    _unsubscribe = _source.subscribe(() {
      if (_activeServerIds.isEmpty) return;
      for (final serverId in _activeServerIds) {
        final focusedAgentId = _source.readSession(serverId)?.focusedAgentId;
        // JS tests truthiness here, so the empty string is not a focus.
        if (focusedAgentId != null && focusedAgentId.isNotEmpty) {
          _lastFocusedAgentIds[serverId] = focusedAgentId;
        }
      }
      _schedulePersist();
    });
    if (_needsPersist) _schedulePersist();
  }

  /// Stops watching and cancels any debounced write.
  ///
  /// Not in upstream, which lets the browser tear down the subscription at
  /// unload. Dart needs an explicit release so a cache created per test or per
  /// window does not outlive its source.
  void stop() {
    _unsubscribe?.call();
    _unsubscribe = null;
    _cancelPersist?.call();
    _cancelPersist = null;
  }

  /// Re-keys everything held for [oldServerId] under [newServerId].
  ///
  /// A host that was reached by one identity and then resolves to another (a
  /// LAN address becoming a paired id) must keep its cache instead of appearing
  /// as a brand new, empty host.
  void reconcileServerId(String oldServerId, String newServerId) {
    final stored = _storedHosts.remove(oldServerId);
    if (stored != null) {
      _storedHosts[newServerId] = stored.withServerId(newServerId);
    }
    final focusedAgentId = _lastFocusedAgentIds.remove(oldServerId);
    if (focusedAgentId != null) {
      _lastFocusedAgentIds[newServerId] = focusedAgentId;
    }
    final capturedSession = _capturedSessions.remove(oldServerId);
    if (capturedSession != null) {
      _capturedSessions[newServerId] = capturedSession;
    }
    if (_activeServerIds.remove(oldServerId)) {
      _activeServerIds.add(newServerId);
    }
    _needsPersist = true;
    _schedulePersist();
  }

  /// Captures the current sessions and writes immediately.
  ///
  /// Writes are queued rather than concurrent so two flushes cannot interleave
  /// and leave a torn payload, and a failed write never propagates — the caller
  /// is usually a lifecycle hook that must not fail.
  Future<void> flush() async {
    _cancelPersist?.call();
    _cancelPersist = null;
    _captureSessions();
    final payload = _buildBoundedPayload().payload;
    _needsPersist = false;
    final write = _write(_writeQueue, payload);
    _writeQueue = write;
    try {
      await write;
    } on Object {
      // Swallowed: the next flush's queue-drain re-observes it as handled.
    }
  }

  Future<void> _write(Future<void> previous, String payload) async {
    try {
      await previous;
    } on Object {
      // A failed earlier write must not block this one.
    }
    await _storage.setItem(replicaCacheStorageKey, payload);
  }

  /// Rebuilds the stored form for every active host whose session changed.
  ///
  /// Only the focused agent survives. Its workspace is found by id, falling
  /// back to whichever workspace sits at the agent's working directory, which
  /// is how an agent started outside a workspace still restores with useful
  /// context.
  void _captureSessions() {
    for (final serverId in _activeServerIds) {
      final session = _source.readSession(serverId);
      if (session == null) continue;
      // Identity, not equality: upstream skips when zustand handed back the
      // exact same immutable state object.
      if (identical(_capturedSessions[serverId], session)) continue;
      _capturedSessions[serverId] = session;
      final sessionFocusedAgentId = session.focusedAgentId;
      if (sessionFocusedAgentId != null && sessionFocusedAgentId.isNotEmpty) {
        _lastFocusedAgentIds[serverId] = sessionFocusedAgentId;
      }
      final focusedAgentId = _lastFocusedAgentIds[serverId];
      final focusedAgent = focusedAgentId == null
          ? null
          : session.agents[focusedAgentId];
      WorkspaceDescriptor? focusedWorkspace;
      if (focusedAgent != null) {
        final workspaceId = focusedAgent.workspaceId;
        focusedWorkspace = workspaceId == null
            ? null
            : session.workspaces[workspaceId];
        if (focusedWorkspace == null) {
          for (final workspace in session.workspaces.values) {
            if (workspace.workspaceDirectory == focusedAgent.cwd) {
              focusedWorkspace = workspace;
              break;
            }
          }
        }
      }
      final items = focusedAgentId == null
          ? null
          : session.agentStreamTail[focusedAgentId];
      final timeline = focusedAgent != null && items != null
          ? _StoredTimeline(
              agentId: focusedAgent.agentId,
              items: _encodeTail(items),
              cursor: session.agentTimelineCursor[focusedAgent.agentId],
              hasOlder:
                  session.agentTimelineHasOlder[focusedAgent.agentId] ?? false,
            )
          : null;
      final stored = _StoredHost(
        serverId: serverId,
        agents: focusedAgent == null
            ? const []
            : List<AgentSummary>.unmodifiable([focusedAgent]),
        workspaces: focusedWorkspace == null
            ? const []
            : List<WorkspaceDescriptor>.unmodifiable([
                _withoutWorkspaceActivity(focusedWorkspace),
              ]),
        // Never persisted: an empty project is cheap to rediscover and its
        // absence cannot make the restored screen look wrong.
        emptyProjects: const [],
        timeline: timeline,
      );
      // Delete-then-insert moves the host to the end of the LRU order.
      _storedHosts
        ..remove(serverId)
        ..[serverId] = stored;
    }
  }

  /// Keeps only the newest [replicaCacheMaxTimelineItems] items.
  ///
  /// Upstream additionally wraps every `Date` in a `__paseoDate` tag because
  /// its stream items carry live `Date` objects that `JSON.stringify` would
  /// flatten to strings. The protocol's [TimelineItem.toJson] already emits
  /// JSON-native values, so no tagging layer is needed and none is reproduced.
  List<Object?> _encodeTail(List<TimelineItem> items) {
    final start = items.length <= replicaCacheMaxTimelineItems
        ? 0
        : items.length - replicaCacheMaxTimelineItems;
    return [
      for (var index = start; index < items.length; index += 1)
        items[index].toJson(),
    ];
  }

  /// Serializes, evicting least-recently-written hosts until it fits.
  ({String payload, bool evicted}) _buildBoundedPayload() {
    var evicted = false;
    var payload = _serialize();
    while (utf8.encode(payload).length > _maxBytes && _storedHosts.isNotEmpty) {
      _storedHosts.remove(_storedHosts.keys.first);
      evicted = true;
      payload = _serialize();
    }
    return (payload: payload, evicted: evicted);
  }

  String _serialize() => jsonEncode({
    'version': replicaCacheVersion,
    'hosts': _storedHosts.values
        .map((host) => host.toJson())
        .toList(growable: false),
  });

  /// Debounces a write. A pending timer is left alone rather than restarted, so
  /// a continuous stream of changes still writes every
  /// [replicaCachePersistDelay] instead of never.
  void _schedulePersist() {
    if (_cancelPersist != null) return;
    _cancelPersist = _scheduler.schedule(() {
      _cancelPersist = null;
      unawaited(flush());
    }, replicaCachePersistDelay);
  }
}
