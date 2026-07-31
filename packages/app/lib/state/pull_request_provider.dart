import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import '../core/pull_request_data.dart';
import 'daemon_providers.dart';
import 'gitlab_pipeline_query.dart';
import 'workspace_checkout_status_provider.dart';

const _uuid = Uuid();
final _unsupportedTimelineRegistry = PullRequestTimelineUnsupportedRegistry();

final class PullRequestPaneData {
  const PullRequestPaneData({
    this.status,
    this.timeline = const [],
    this.timelineTruncated = false,
    this.timelineResolved = false,
    this.activityLoading = false,
    this.isRefreshing = false,
    this.githubFeaturesEnabled = true,
    this.pipelineCacheRevision = 0,
    this.statusError,
    this.timelineError,
  });

  final CheckoutPrStatus? status;
  final List<PullRequestTimelineItem> timeline;
  final bool timelineTruncated;
  final bool timelineResolved;
  final bool activityLoading;
  final bool isRefreshing;
  final bool githubFeaturesEnabled;
  final int pipelineCacheRevision;
  final String? statusError;
  final String? timelineError;

  bool get hasPullRequest => status != null;
}

class PullRequestPaneNotifier extends AsyncNotifier<PullRequestPaneData> {
  PullRequestPaneNotifier(this.cwd);

  final String cwd;
  final _gitlabPipelineCache = GitlabPipelineQueryCache();
  final _timelineActivations = <Object>{};
  var _pipelineCacheRevision = 0;
  var _loadGeneration = 0;
  var _manualTimelineEnabled = false;

  bool get _timelineEnabled =>
      _manualTimelineEnabled || _timelineActivations.isNotEmpty;

  @override
  Future<PullRequestPaneData> build() async {
    final client = ref.watch(daemonClientProvider);
    // Select the *effective* connection state rather than the raw
    // AsyncValue. An already-connected client replays its terminal state on
    // subscribe, so watching the AsyncValue rebuilds this notifier once
    // shortly after mount (loading -> data) even though the connection never
    // changed. That reload discards a fatal error before the retry
    // affordance can be used, and double-fetches status on every mount.
    // Collapsing to the value the load actually branches on makes that
    // transition a no-op while a genuine (re)connect still rebuilds.
    final connection = ref.watch(
      connectionStateProvider.select(
        (state) => state.value ?? client.currentState,
      ),
    );
    final serverId = _serverId(client);
    ref.watch(checkoutStatusPushRouterProvider(serverId));
    final pushed = ref.watch(
      checkoutStatusPushCacheProvider.select(
        (cache) => cache[(serverId: serverId, cwd: cwd)]?.prStatus,
      ),
    );
    if (cwd.isEmpty) {
      return const PullRequestPaneData();
    }
    final generation = ++_loadGeneration;
    if (pushed != null) {
      return _projectStatusResponse(
        client,
        response: pushed,
        generation: generation,
        previous: state.value,
        fromPush: true,
      );
    }
    if (connection != DaemonConnectionState.connected) {
      return state.value ?? const PullRequestPaneData();
    }
    return _load(client, generation: generation);
  }

  Future<PullRequestPaneData> _load(
    DaemonClient client, {
    required int generation,
    PullRequestPaneData? previous,
  }) async {
    final statusRequest = CheckoutPrStatusRequest(
      cwd: cwd,
      requestId: _uuid.v4(),
    );
    final statusResponse = CheckoutPrStatusResponse.fromJson(
      await client.requestSessionMessage(statusRequest.toJson()),
    );
    return _projectStatusResponse(
      client,
      response: statusResponse,
      generation: generation,
      previous: previous,
    );
  }

  PullRequestPaneData _projectStatusResponse(
    DaemonClient client, {
    required CheckoutPrStatusResponse response,
    required int generation,
    PullRequestPaneData? previous,
    bool fromPush = false,
  }) {
    final rawStatus = response.status;
    if (rawStatus == null) {
      if (fromPush && previous?.status != null) {
        _gitlabPipelineCache.invalidate(serverId: _serverId(client), cwd: cwd);
        _pipelineCacheRevision += 1;
      }
      return PullRequestPaneData(
        githubFeaturesEnabled: response.githubFeaturesEnabled,
        pipelineCacheRevision: _pipelineCacheRevision,
        statusError: response.error?.message,
      );
    }
    final status = normalizePullRequestStatus(rawStatus);
    if (status == null) {
      return PullRequestPaneData(
        githubFeaturesEnabled: response.githubFeaturesEnabled,
        pipelineCacheRevision: _pipelineCacheRevision,
      );
    }
    final identity = extractPullRequestRepoIdentity(status);
    final unsupportedKey = pullRequestTimelineUnsupportedKey(
      serverId: _serverId(client),
      cwd: cwd,
      prNumber: identity.prNumber!,
    );
    final shouldFetch = shouldFetchPullRequestTimeline(
      hasClient: true,
      isConnected: client.currentState == DaemonConnectionState.connected,
      timelineEnabled: _timelineEnabled,
      githubFeaturesEnabled: response.githubFeaturesEnabled,
      cwd: cwd,
      identity: identity,
      timelineUnsupported: _unsupportedTimelineRegistry.has(unsupportedKey),
    );
    final statusChanged = !_samePullRequestStatus(previous?.status, status);
    if (fromPush && statusChanged) {
      _gitlabPipelineCache.invalidate(serverId: _serverId(client), cwd: cwd);
      _pipelineCacheRevision += 1;
    }
    final keepPreviousTimeline =
        !statusChanged && previous?.timelineResolved == true;
    final pending = PullRequestPaneData(
      status: status,
      timeline: keepPreviousTimeline ? previous!.timeline : const [],
      timelineTruncated: keepPreviousTimeline && previous!.timelineTruncated,
      timelineResolved: keepPreviousTimeline,
      activityLoading: shouldFetch && !keepPreviousTimeline,
      isRefreshing: false,
      githubFeaturesEnabled: response.githubFeaturesEnabled,
      pipelineCacheRevision: _pipelineCacheRevision,
      statusError: response.error?.message,
    );
    if (shouldFetch && (!fromPush || statusChanged)) {
      unawaited(
        Future<void>.delayed(
          Duration.zero,
          () => _loadTimeline(
            client,
            status: status,
            identity: identity,
            unsupportedKey: unsupportedKey,
            generation: generation,
            pending: pending,
          ),
        ),
      );
    }
    return pending;
  }

  void setTimelineEnabled(bool enabled) {
    if (_manualTimelineEnabled == enabled) return;
    _manualTimelineEnabled = enabled;
    _timelineActivationChanged(_timelineEnabled);
  }

  void setTimelineActive(Object token, bool active) {
    final changed = active
        ? _timelineActivations.add(token)
        : _timelineActivations.remove(token);
    if (!changed) return;
    _timelineActivationChanged(_timelineEnabled);
  }

  void _timelineActivationChanged(bool enabled) {
    if (!enabled) {
      _loadGeneration += 1;
      return;
    }
    final current = state.value;
    final status = current?.status;
    if (current == null ||
        status == null ||
        current.timelineResolved ||
        current.activityLoading) {
      return;
    }
    final client = ref.read(daemonClientProvider);
    final identity = extractPullRequestRepoIdentity(status);
    final number = identity.prNumber;
    if (number == null) return;
    final unsupportedKey = pullRequestTimelineUnsupportedKey(
      serverId: _serverId(client),
      cwd: cwd,
      prNumber: number,
    );
    if (!shouldFetchPullRequestTimeline(
      hasClient: true,
      isConnected: client.currentState == DaemonConnectionState.connected,
      timelineEnabled: true,
      githubFeaturesEnabled: current.githubFeaturesEnabled,
      cwd: cwd,
      identity: identity,
      timelineUnsupported: _unsupportedTimelineRegistry.has(unsupportedKey),
    )) {
      return;
    }
    final generation = ++_loadGeneration;
    final pending = PullRequestPaneData(
      status: status,
      timeline: current.timeline,
      timelineTruncated: current.timelineTruncated,
      timelineResolved: current.timelineResolved,
      activityLoading: true,
      githubFeaturesEnabled: current.githubFeaturesEnabled,
      pipelineCacheRevision: current.pipelineCacheRevision,
      statusError: current.statusError,
      timelineError: current.timelineError,
    );
    state = AsyncData(pending);
    unawaited(
      _loadTimeline(
        client,
        status: status,
        identity: identity,
        unsupportedKey: unsupportedKey,
        generation: generation,
        pending: pending,
      ),
    );
  }

  Future<void> refresh() async {
    final client = ref.read(daemonClientProvider);
    _gitlabPipelineCache.invalidate(serverId: _serverId(client), cwd: cwd);
    _pipelineCacheRevision += 1;
    final generation = ++_loadGeneration;
    final previous = state.value;
    if (previous == null) {
      state = const AsyncLoading<PullRequestPaneData>();
    } else {
      state = AsyncData(
        PullRequestPaneData(
          status: previous.status,
          timeline: previous.timeline,
          timelineTruncated: previous.timelineTruncated,
          timelineResolved: previous.timelineResolved,
          activityLoading: previous.activityLoading,
          isRefreshing: true,
          githubFeaturesEnabled: previous.githubFeaturesEnabled,
          pipelineCacheRevision: _pipelineCacheRevision,
          statusError: previous.statusError,
          timelineError: previous.timelineError,
        ),
      );
    }
    try {
      final next = await _load(
        client,
        generation: generation,
        previous: previous,
      );
      if (ref.mounted && generation == _loadGeneration) {
        state = AsyncData(next);
      }
    } catch (error, stackTrace) {
      if (!ref.mounted || generation != _loadGeneration) return;
      if (previous == null) {
        state = AsyncError(error, stackTrace);
      } else {
        state = AsyncData(
          PullRequestPaneData(
            status: previous.status,
            timeline: previous.timeline,
            timelineTruncated: previous.timelineTruncated,
            timelineResolved: previous.timelineResolved,
            githubFeaturesEnabled: previous.githubFeaturesEnabled,
            pipelineCacheRevision: _pipelineCacheRevision,
            statusError: '$error',
          ),
        );
      }
    }
  }

  Future<void> _loadTimeline(
    DaemonClient client, {
    required CheckoutPrStatus status,
    required PullRequestRepoIdentity identity,
    required String unsupportedKey,
    required int generation,
    required PullRequestPaneData pending,
  }) async {
    try {
      final timelineRequest = PullRequestTimelineRequest(
        cwd: cwd,
        prNumber: identity.prNumber!,
        repoOwner: identity.repoOwner!,
        repoName: identity.repoName!,
        requestId: _uuid.v4(),
      );
      final timelineResponse = PullRequestTimelineResponse.fromJson(
        await client.requestSessionMessage(timelineRequest.toJson()),
      );
      if (!ref.mounted || generation != _loadGeneration) return;
      final timelineMatchesStatus =
          timelineResponse.prNumber == identity.prNumber;
      state = AsyncData(
        PullRequestPaneData(
          status: status,
          timeline: normalizePullRequestTimeline(
            statusNumber: identity.prNumber!,
            timelineNumber: timelineResponse.prNumber,
            items: timelineResponse.items,
          ),
          timelineTruncated:
              timelineMatchesStatus && timelineResponse.truncated,
          timelineResolved: true,
          githubFeaturesEnabled: pending.githubFeaturesEnabled,
          pipelineCacheRevision: pending.pipelineCacheRevision,
          statusError: pending.statusError,
          timelineError: timelineMatchesStatus
              ? timelineResponse.error?.message
              : null,
        ),
      );
    } catch (error) {
      if (!ref.mounted || generation != _loadGeneration) return;
      final unsupported = isUnsupportedPullRequestTimelineError(error);
      if (unsupported) {
        _unsupportedTimelineRegistry.add(unsupportedKey);
      }
      state = AsyncData(
        PullRequestPaneData(
          status: status,
          timeline: pending.timeline,
          timelineTruncated: pending.timelineTruncated,
          timelineResolved: pending.timelineResolved,
          githubFeaturesEnabled: pending.githubFeaturesEnabled,
          pipelineCacheRevision: pending.pipelineCacheRevision,
          statusError: pending.statusError,
          timelineError: unsupported ? null : '$error',
        ),
      );
    }
  }

  Future<void> refreshCheckout() async {
    final client = ref.read(daemonClientProvider);
    final response = CheckoutRefreshResponse.fromJson(
      await client.requestSessionMessage(
        CheckoutRefreshRequest(cwd: cwd, requestId: _uuid.v4()).toJson(),
      ),
    );
    if (!response.success) {
      throw StateError(response.error?.message ?? 'Could not refresh checkout');
    }
    await refresh();
  }

  Future<CheckoutCheckDetails?> loadCheckDetails(
    CheckoutPrStatus status,
    CheckoutPrCheck check,
  ) async {
    final checkRunId = check.checkRunId?.toInt();
    final workflowRunId = check.workflowRunId?.toInt();
    if (checkRunId == null && workflowRunId == null) return null;
    final owner = status.repoOwner;
    final name = status.repoName;
    if (owner == null || name == null) return null;
    try {
      final request = CheckoutForgeGetCheckDetailsRequest(
        type: CheckoutForgeGetCheckDetailsRequest.modernType,
        cwd: cwd,
        repoOwner: owner,
        repoName: name,
        checkRunId: checkRunId,
        workflowRunId: workflowRunId,
        changeRequestNumber: status.number?.toInt(),
        requestId: _uuid.v4(),
      );
      final response = CheckoutForgeGetCheckDetailsResponse.fromJson(
        await ref
            .read(daemonClientProvider)
            .requestSessionMessage(request.toJson()),
      );
      return response.success ? response.details : null;
    } on Object {
      return null;
    }
  }

  Future<CheckoutPipeline?> loadGitlabPipeline(
    CheckoutPrStatus status,
    num pipelineId, {
    required bool live,
    bool force = false,
  }) async {
    final key = gitlabPipelineQueryKey(status, pipelineId);
    if (!force && !_gitlabPipelineCache.shouldFetch(key, live: live)) {
      return _gitlabPipelineCache.snapshot(key)!.pipeline;
    }
    return _gitlabPipelineCache.fetch(key, () async {
      final request = CheckoutForgeGetCheckDetailsRequest(
        type: CheckoutForgeGetCheckDetailsRequest.modernType,
        cwd: cwd,
        checkRunId: key.pipelineId,
        changeRequestNumber: key.changeRequestNumber,
        requestId: _uuid.v4(),
      );
      final response = CheckoutForgeGetCheckDetailsResponse.fromJson(
        await ref
            .read(daemonClientProvider)
            .requestSessionMessage(request.toJson()),
      );
      if (!response.success) {
        throw StateError(
          response.error?.message ?? 'Could not load pipeline jobs',
        );
      }
      return response.details?.pipeline;
    });
  }

  GitlabPipelineQueryKey gitlabPipelineQueryKey(
    CheckoutPrStatus status,
    num pipelineId,
  ) {
    final client = ref.read(daemonClientProvider);
    final changeRequestNumber = status.number;
    if (!pipelineId.isFinite ||
        pipelineId <= 0 ||
        pipelineId.toInt() != pipelineId) {
      throw ArgumentError.value(
        pipelineId,
        'pipelineId',
        'must be a positive integer',
      );
    }
    if (changeRequestNumber == null ||
        !changeRequestNumber.isFinite ||
        changeRequestNumber <= 0 ||
        changeRequestNumber.toInt() != changeRequestNumber) {
      throw ArgumentError.value(
        changeRequestNumber,
        'status.number',
        'must be a positive integer',
      );
    }
    return GitlabPipelineQueryKey(
      serverId: _serverId(client),
      cwd: cwd,
      pipelineId: pipelineId.toInt(),
      changeRequestNumber: changeRequestNumber.toInt(),
    );
  }

  GitlabPipelineCacheSnapshot? gitlabPipelineSnapshot(
    CheckoutPrStatus status,
    num pipelineId,
  ) =>
      _gitlabPipelineCache.snapshot(gitlabPipelineQueryKey(status, pipelineId));
}

final pullRequestPaneProvider =
    AsyncNotifierProvider.family<
      PullRequestPaneNotifier,
      PullRequestPaneData,
      String
    >(PullRequestPaneNotifier.new);

String _serverId(DaemonClient client) =>
    client.serverInfo?.serverId ?? client.uri.toString();

bool _samePullRequestStatus(
  CheckoutPrStatus? previous,
  CheckoutPrStatus next,
) =>
    previous != null &&
    jsonEncode(previous.toJson()) == jsonEncode(next.toJson());

bool isUnsupportedPullRequestTimelineError(Object error) =>
    error is DaemonRpcException && error.error.code == 'unknown_schema';
