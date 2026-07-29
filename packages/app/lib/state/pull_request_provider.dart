import 'package:agent_protocol/agent_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/daemon_client.dart';
import 'daemon_providers.dart';

const _uuid = Uuid();

final class PullRequestPaneData {
  const PullRequestPaneData({
    this.status,
    this.timeline = const [],
    this.timelineTruncated = false,
    this.statusError,
    this.timelineError,
  });

  final CheckoutPrStatus? status;
  final List<PullRequestTimelineItem> timeline;
  final bool timelineTruncated;
  final String? statusError;
  final String? timelineError;

  bool get hasPullRequest => status != null;
}

class PullRequestPaneNotifier extends AsyncNotifier<PullRequestPaneData> {
  PullRequestPaneNotifier(this.cwd);

  final String cwd;

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
      return PullRequestPaneData(statusError: statusResponse.error?.message);
    }
    final number = status.number;
    final owner = status.repoOwner;
    final name = status.repoName;
    if (number == null || owner == null || name == null) {
      return PullRequestPaneData(status: status);
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
        timelineError: timelineResponse.error?.message,
      );
    } catch (error) {
      return PullRequestPaneData(status: status, timelineError: '$error');
    }
  }

  Future<void> refresh() async {
    final client = ref.read(daemonClientProvider);
    state = const AsyncLoading<PullRequestPaneData>();
    state = await AsyncValue.guard(() => _load(client));
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
    num pipelineId,
  ) async {
    if (!pipelineId.isFinite ||
        pipelineId <= 0 ||
        pipelineId.toInt() != pipelineId) {
      throw ArgumentError.value(
        pipelineId,
        'pipelineId',
        'must be a positive integer',
      );
    }
    final request = CheckoutForgeGetCheckDetailsRequest(
      type: CheckoutForgeGetCheckDetailsRequest.modernType,
      cwd: cwd,
      checkRunId: pipelineId.toInt(),
      changeRequestNumber: status.number?.toInt(),
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
  }
}

final pullRequestPaneProvider =
    AsyncNotifierProvider.family<
      PullRequestPaneNotifier,
      PullRequestPaneData,
      String
    >(PullRequestPaneNotifier.new);
