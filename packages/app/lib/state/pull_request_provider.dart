import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';
import 'gitlab_pipeline_query.dart';

const _uuid = Uuid();

final class PullRequestPaneData {
  const PullRequestPaneData({
    this.status,
    this.timeline = const [],
    this.timelineTruncated = false,
    this.pipelineCacheRevision = 0,
    this.statusError,
    this.timelineError,
  });

  final CheckoutPrStatus? status;
  final List<PullRequestTimelineItem> timeline;
  final bool timelineTruncated;
  final int pipelineCacheRevision;
  final String? statusError;
  final String? timelineError;

  bool get hasPullRequest => status != null;
}

class PullRequestPaneNotifier extends AsyncNotifier<PullRequestPaneData> {
  PullRequestPaneNotifier(this.cwd);

  final String cwd;
  final _gitlabPipelineCache = GitlabPipelineQueryCache();
  var _pipelineCacheRevision = 0;

  @override
  Future<PullRequestPaneData> build() async {
    final client = ref.watch(daemonClientProvider);
    ref.watch(connectionStateProvider);
    if (client.currentState != DaemonConnectionState.connected) {
      return const PullRequestPaneData();
    }
    return _load(client);
  }

  Future<PullRequestPaneData> _load(DaemonClient client) async {
    final statusRequest = CheckoutPrStatusRequest(
      cwd: cwd,
      requestId: _uuid.v4(),
    );
    final statusResponse = CheckoutPrStatusResponse.fromJson(
      await client.requestSessionMessage(statusRequest.toJson()),
    );
    final status = statusResponse.status;
    if (status == null) {
      return PullRequestPaneData(
        pipelineCacheRevision: _pipelineCacheRevision,
        statusError: statusResponse.error?.message,
      );
    }
    final number = status.number;
    final owner = status.repoOwner;
    final name = status.repoName;
    if (number == null || owner == null || name == null) {
      return PullRequestPaneData(
        status: status,
        pipelineCacheRevision: _pipelineCacheRevision,
      );
    }

    try {
      final timelineRequest = PullRequestTimelineRequest(
        cwd: cwd,
        prNumber: number,
        repoOwner: owner,
        repoName: name,
        requestId: _uuid.v4(),
      );
      final timelineResponse = PullRequestTimelineResponse.fromJson(
        await client.requestSessionMessage(timelineRequest.toJson()),
      );
      return PullRequestPaneData(
        status: status,
        timeline: timelineResponse.items,
        timelineTruncated: timelineResponse.truncated,
        pipelineCacheRevision: _pipelineCacheRevision,
        timelineError: timelineResponse.error?.message,
      );
    } catch (error) {
      return PullRequestPaneData(
        status: status,
        pipelineCacheRevision: _pipelineCacheRevision,
        timelineError: '$error',
      );
    }
  }

  Future<void> refresh() async {
    final client = ref.read(daemonClientProvider);
    _gitlabPipelineCache.invalidate(serverId: _serverId(client), cwd: cwd);
    _pipelineCacheRevision += 1;
    if (!state.hasValue) state = const AsyncLoading<PullRequestPaneData>();
    state = await AsyncValue.guard(() => _load(client));
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
