import 'package:agent_protocol/agent_protocol.dart';

enum ForgeCheckStatus {
  success('success'),
  failure('failure'),
  pending('pending'),
  skipped('skipped');

  const ForgeCheckStatus(this.wireName);

  final String wireName;
}

ForgeCheckStatus mapForgeCheckStatus(String status) => switch (status) {
  'success' => ForgeCheckStatus.success,
  'failure' => ForgeCheckStatus.failure,
  'pending' => ForgeCheckStatus.pending,
  'skipped' || 'cancelled' => ForgeCheckStatus.skipped,
  _ => ForgeCheckStatus.pending,
};

final class ForgeMergeCapability {
  const ForgeMergeCapability({
    required this.directMergeReady,
    required this.canEnableAutoMerge,
    required this.autoMergeEnabled,
    required this.canDisableAutoMerge,
    required this.mergeBlockedByQueue,
    required this.allowedMethods,
    required this.preferredMethod,
  });

  final bool directMergeReady;
  final bool canEnableAutoMerge;
  final bool autoMergeEnabled;
  final bool canDisableAutoMerge;
  final bool mergeBlockedByQueue;
  final List<String> allowedMethods;
  final String? preferredMethod;
}

final class GithubAutoMergeRequest {
  const GithubAutoMergeRequest({
    required this.enabledAt,
    required this.mergeMethod,
    required this.enabledBy,
  });

  final String? enabledAt;
  final String? mergeMethod;
  final String? enabledBy;

  static ({bool valid, GithubAutoMergeRequest? value}) parse(Object? value) {
    if (value == null) return (valid: true, value: null);
    if (value is! Map) return (valid: false, value: null);
    final enabledAt = value['enabledAt'];
    final mergeMethod = value['mergeMethod'];
    final enabledBy = value['enabledBy'];
    if (!_isNullableString(enabledAt) ||
        !_isNullableString(mergeMethod) ||
        !_isNullableString(enabledBy)) {
      return (valid: false, value: null);
    }
    return (
      valid: true,
      value: GithubAutoMergeRequest(
        enabledAt: enabledAt as String?,
        mergeMethod: mergeMethod as String?,
        enabledBy: enabledBy as String?,
      ),
    );
  }
}

final class GithubRepositoryPolicy {
  const GithubRepositoryPolicy({
    required this.autoMergeAllowed,
    required this.mergeCommitAllowed,
    required this.squashMergeAllowed,
    required this.rebaseMergeAllowed,
    required this.viewerDefaultMergeMethod,
  });

  static const empty = GithubRepositoryPolicy(
    autoMergeAllowed: false,
    mergeCommitAllowed: false,
    squashMergeAllowed: false,
    rebaseMergeAllowed: false,
    viewerDefaultMergeMethod: null,
  );

  final bool autoMergeAllowed;
  final bool mergeCommitAllowed;
  final bool squashMergeAllowed;
  final bool rebaseMergeAllowed;
  final String? viewerDefaultMergeMethod;

  static ({bool valid, GithubRepositoryPolicy value}) parse(
    Object? value, {
    required bool present,
  }) {
    if (!present) return (valid: true, value: empty);
    if (value is! Map) return (valid: false, value: empty);
    for (final field in [
      'autoMergeAllowed',
      'mergeCommitAllowed',
      'squashMergeAllowed',
      'rebaseMergeAllowed',
    ]) {
      final fieldValue = value[field];
      if (value.containsKey(field) && fieldValue is! bool) {
        return (valid: false, value: empty);
      }
    }
    final preferred = value['viewerDefaultMergeMethod'];
    if (!_isNullableString(preferred)) {
      return (valid: false, value: empty);
    }
    return (
      valid: true,
      value: GithubRepositoryPolicy(
        autoMergeAllowed: value['autoMergeAllowed'] as bool? ?? false,
        mergeCommitAllowed: value['mergeCommitAllowed'] as bool? ?? false,
        squashMergeAllowed: value['squashMergeAllowed'] as bool? ?? false,
        rebaseMergeAllowed: value['rebaseMergeAllowed'] as bool? ?? false,
        viewerDefaultMergeMethod: preferred as String?,
      ),
    );
  }
}

final class GithubMergeFacts {
  const GithubMergeFacts({
    required this.mergeStateStatus,
    required this.autoMergeRequest,
    required this.viewerCanEnableAutoMerge,
    required this.viewerCanDisableAutoMerge,
    required this.viewerCanMergeAsAdmin,
    required this.viewerCanUpdateBranch,
    required this.repository,
    required this.isMergeQueueEnabled,
    required this.isInMergeQueue,
  });

  final String? mergeStateStatus;
  final GithubAutoMergeRequest? autoMergeRequest;
  final bool viewerCanEnableAutoMerge;
  final bool viewerCanDisableAutoMerge;
  final bool viewerCanMergeAsAdmin;
  final bool viewerCanUpdateBranch;
  final GithubRepositoryPolicy repository;
  final bool isMergeQueueEnabled;
  final bool isInMergeQueue;

  static GithubMergeFacts? parse(Object? value) {
    if (value is! Map || value['forge'] != 'github') return null;
    final mergeStateStatus = value['mergeStateStatus'];
    if (!_isNullableString(mergeStateStatus)) return null;
    for (final field in [
      'viewerCanEnableAutoMerge',
      'viewerCanDisableAutoMerge',
      'viewerCanMergeAsAdmin',
      'viewerCanUpdateBranch',
      'isMergeQueueEnabled',
      'isInMergeQueue',
    ]) {
      final fieldValue = value[field];
      if (value.containsKey(field) && fieldValue is! bool) return null;
    }
    final autoMerge = GithubAutoMergeRequest.parse(value['autoMergeRequest']);
    final repository = GithubRepositoryPolicy.parse(
      value['repository'],
      present: value.containsKey('repository'),
    );
    if (!autoMerge.valid || !repository.valid) return null;
    return GithubMergeFacts(
      mergeStateStatus: mergeStateStatus as String?,
      autoMergeRequest: autoMerge.value,
      viewerCanEnableAutoMerge:
          value['viewerCanEnableAutoMerge'] as bool? ?? false,
      viewerCanDisableAutoMerge:
          value['viewerCanDisableAutoMerge'] as bool? ?? false,
      viewerCanMergeAsAdmin: value['viewerCanMergeAsAdmin'] as bool? ?? false,
      viewerCanUpdateBranch: value['viewerCanUpdateBranch'] as bool? ?? false,
      repository: repository.value,
      isMergeQueueEnabled: value['isMergeQueueEnabled'] as bool? ?? false,
      isInMergeQueue: value['isInMergeQueue'] as bool? ?? false,
    );
  }
}

ForgeMergeCapability? deriveGithubMergeCapability(Object? facts) {
  final github = GithubMergeFacts.parse(facts);
  if (github == null) return null;
  final repository = github.repository;
  return ForgeMergeCapability(
    directMergeReady: const {
      'CLEAN',
      'HAS_HOOKS',
    }.contains(github.mergeStateStatus),
    canEnableAutoMerge:
        github.mergeStateStatus == 'BLOCKED' &&
        repository.autoMergeAllowed &&
        github.viewerCanEnableAutoMerge,
    autoMergeEnabled: github.autoMergeRequest != null,
    canDisableAutoMerge: github.viewerCanDisableAutoMerge,
    mergeBlockedByQueue: github.isMergeQueueEnabled || github.isInMergeQueue,
    allowedMethods: [
      if (repository.mergeCommitAllowed) 'merge',
      if (repository.squashMergeAllowed) 'squash',
      if (repository.rebaseMergeAllowed) 'rebase',
    ],
    preferredMethod: switch (repository.viewerDefaultMergeMethod) {
      'SQUASH' => 'squash',
      'MERGE' => 'merge',
      'REBASE' => 'rebase',
      _ => null,
    },
  );
}

const _gitlabActivePipelineStatuses = {
  'created',
  'waiting_for_resource',
  'preparing',
  'pending',
  'running',
  'scheduled',
};

bool isGitlabPipelineActiveStatus(String status) =>
    _gitlabActivePipelineStatuses.contains(status);

ForgeCheckStatus mapGitlabPipelineStatus(String status) => switch (status) {
  'success' || 'passed' => ForgeCheckStatus.success,
  'failed' => ForgeCheckStatus.failure,
  'canceled' || 'cancelled' || 'skipped' => ForgeCheckStatus.skipped,
  _ => ForgeCheckStatus.pending,
};

final class GitlabMergeFacts {
  const GitlabMergeFacts({
    required this.detailedMergeStatus,
    required this.mergeStatus,
    required this.hasConflicts,
    required this.blockingDiscussionsResolved,
    required this.approvalsRequired,
    required this.approvalsGiven,
    required this.pipelineStatus,
    required this.pipelineId,
    required this.pipelineUrl,
    required this.mergeWhenPipelineSucceeds,
  });

  final String? detailedMergeStatus;
  final String? mergeStatus;
  final bool hasConflicts;
  final bool blockingDiscussionsResolved;
  final num approvalsRequired;
  final num approvalsGiven;
  final String? pipelineStatus;
  final num? pipelineId;
  final String? pipelineUrl;
  final bool mergeWhenPipelineSucceeds;

  static GitlabMergeFacts? parse(Object? value) {
    if (value is! Map || value['forge'] != 'gitlab') return null;
    for (final field in [
      'detailedMergeStatus',
      'mergeStatus',
      'pipelineStatus',
      'pipelineUrl',
    ]) {
      if (!_isNullableString(value[field])) return null;
    }
    for (final field in [
      'hasConflicts',
      'blockingDiscussionsResolved',
      'mergeWhenPipelineSucceeds',
    ]) {
      if (value.containsKey(field) && value[field] is! bool) return null;
    }
    for (final field in ['approvalsRequired', 'approvalsGiven']) {
      if (value.containsKey(field) && !_isFiniteNumber(value[field])) {
        return null;
      }
    }
    if (value['pipelineId'] != null && !_isFiniteNumber(value['pipelineId'])) {
      return null;
    }
    return GitlabMergeFacts(
      detailedMergeStatus: value['detailedMergeStatus'] as String?,
      mergeStatus: value['mergeStatus'] as String?,
      hasConflicts: value['hasConflicts'] as bool? ?? false,
      blockingDiscussionsResolved:
          value['blockingDiscussionsResolved'] as bool? ?? true,
      approvalsRequired: value['approvalsRequired'] as num? ?? 0,
      approvalsGiven: value['approvalsGiven'] as num? ?? 0,
      pipelineStatus: value['pipelineStatus'] as String?,
      pipelineId: value['pipelineId'] as num?,
      pipelineUrl: value['pipelineUrl'] as String?,
      mergeWhenPipelineSucceeds:
          value['mergeWhenPipelineSucceeds'] as bool? ?? false,
    );
  }
}

ForgeMergeCapability? deriveGitlabMergeCapability(Object? facts) {
  final gitlab = GitlabMergeFacts.parse(facts);
  if (gitlab == null) return null;
  final autoMergeEnabled = gitlab.mergeWhenPipelineSucceeds;
  final hasActivePipeline =
      gitlab.pipelineStatus != null &&
      isGitlabPipelineActiveStatus(gitlab.pipelineStatus!);
  final directMergeReady = gitlab.detailedMergeStatus != null
      ? gitlab.detailedMergeStatus == 'mergeable'
      : gitlab.mergeStatus == 'can_be_merged' && !gitlab.hasConflicts;
  return ForgeMergeCapability(
    directMergeReady: directMergeReady,
    canEnableAutoMerge: !autoMergeEnabled && hasActivePipeline,
    autoMergeEnabled: autoMergeEnabled,
    canDisableAutoMerge: autoMergeEnabled,
    mergeBlockedByQueue: false,
    allowedMethods: const ['merge', 'squash', 'rebase'],
    preferredMethod: null,
  );
}

final class GitlabPipelineSummary {
  const GitlabPipelineSummary({
    required this.id,
    required this.status,
    required this.rawStatus,
    required this.url,
  });

  final num id;
  final ForgeCheckStatus status;
  final String rawStatus;
  final String? url;
}

GitlabPipelineSummary? deriveGitlabPipelineSummary(GitlabMergeFacts facts) {
  final id = facts.pipelineId;
  if (id == null) return null;
  final rawStatus = facts.pipelineStatus ?? '';
  return GitlabPipelineSummary(
    id: id,
    status: mapGitlabPipelineStatus(rawStatus),
    rawStatus: rawStatus,
    url: facts.pipelineUrl,
  );
}

final class GitlabApprovals {
  const GitlabApprovals({required this.given, required this.required});

  final num given;
  final num required;
}

GitlabApprovals? deriveGitlabApprovals(GitlabMergeFacts facts) =>
    facts.approvalsRequired <= 0
    ? null
    : GitlabApprovals(
        given: facts.approvalsGiven,
        required: facts.approvalsRequired,
      );

final class GitlabPipelineJobCounts {
  const GitlabPipelineJobCounts({
    required this.passed,
    required this.failed,
    required this.pending,
  });

  final int passed;
  final int failed;
  final int pending;

  int get total => passed + failed + pending;
}

GitlabPipelineJobCounts countGitlabPipelineJobs(
  Iterable<CheckoutPipelineStage> stages,
) {
  var passed = 0;
  var failed = 0;
  var pending = 0;
  for (final job in stages.expand((stage) => stage.jobs)) {
    switch (mapGitlabPipelineStatus(job.status)) {
      case ForgeCheckStatus.success:
        passed += 1;
      case ForgeCheckStatus.failure:
        failed += 1;
      case ForgeCheckStatus.pending:
        pending += 1;
      case ForgeCheckStatus.skipped:
        break;
    }
  }
  return GitlabPipelineJobCounts(
    passed: passed,
    failed: failed,
    pending: pending,
  );
}

String formatGitlabPipelineDuration(num? seconds) {
  if (seconds == null || !seconds.isFinite || seconds <= 0) return '';
  final totalSeconds = seconds.floor();
  if (totalSeconds < 60) return '${totalSeconds}s';
  final totalMinutes = totalSeconds ~/ 60;
  if (totalMinutes < 60) {
    final remainingSeconds = totalSeconds % 60;
    return remainingSeconds == 0
        ? '${totalMinutes}m'
        : '${totalMinutes}m ${remainingSeconds}s';
  }
  final hours = totalMinutes ~/ 60;
  final remainingMinutes = totalMinutes % 60;
  return remainingMinutes == 0 ? '${hours}h' : '${hours}h ${remainingMinutes}m';
}

/// Neutral registry boundary with Paseo's compatibility fallback for daemons
/// that still put GitHub facts in `status.github`.
ForgeMergeCapability? deriveForgeMergeCapability(
  Object? forgeSpecific, {
  Map<String, Object?>? legacyGithubFacts,
}) {
  if (forgeSpecific == null) {
    if (legacyGithubFacts == null) return null;
    return deriveGithubMergeCapability({
      'forge': 'github',
      ...legacyGithubFacts,
    });
  }
  return deriveGithubMergeCapability(forgeSpecific) ??
      deriveGitlabMergeCapability(forgeSpecific) ??
      deriveGiteaMergeCapability(forgeSpecific);
}

final class GiteaMergeFacts {
  const GiteaMergeFacts({
    required this.mergeable,
    required this.hasMerged,
    required this.ciStatus,
  });

  final bool mergeable;
  final bool hasMerged;
  final String? ciStatus;

  static GiteaMergeFacts? parse(Object? value) {
    if (value is! Map || value['forge'] != 'gitea') return null;
    final mergeable = value['mergeable'];
    final hasMerged = value['hasMerged'];
    final ciStatus = value['ciStatus'];
    if (value.containsKey('mergeable') && mergeable is! bool) return null;
    if (value.containsKey('hasMerged') && hasMerged is! bool) return null;
    if (ciStatus != null && ciStatus is! String) return null;
    return GiteaMergeFacts(
      mergeable: mergeable as bool? ?? false,
      hasMerged: hasMerged as bool? ?? false,
      ciStatus: ciStatus as String?,
    );
  }
}

ForgeMergeCapability? deriveGiteaMergeCapability(Object? facts) {
  final gitea = GiteaMergeFacts.parse(facts);
  if (gitea == null) return null;
  return ForgeMergeCapability(
    directMergeReady: gitea.mergeable && !gitea.hasMerged,
    canEnableAutoMerge: false,
    autoMergeEnabled: false,
    canDisableAutoMerge: false,
    mergeBlockedByQueue: false,
    allowedMethods: const ['merge', 'squash', 'rebase'],
    preferredMethod: null,
  );
}

final class ForgeFallbackCheck {
  const ForgeFallbackCheck({
    required this.provider,
    required this.name,
    required this.status,
    required this.url,
  });

  final String provider;
  final String name;
  final ForgeCheckStatus status;
  final String url;

  CheckoutPrCheck toCheckoutPrCheck() =>
      CheckoutPrCheck(name: name, status: status.wireName, url: url);
}

List<ForgeFallbackCheck> getGiteaNativeFallbackChecks(
  CheckoutPrStatus status,
  String forge,
) {
  final facts = GiteaMergeFacts.parse(status.forgeSpecific);
  final ciStatus = facts?.ciStatus;
  if (ciStatus == null || ciStatus.isEmpty) return const [];
  return [
    ForgeFallbackCheck(
      provider: forge,
      name: 'CI',
      status: _mapGiteaCiStatus(ciStatus),
      url: status.url,
    ),
  ];
}

/// Matches Paseo's PR-pane data builder: usable native checks win, otherwise a
/// registered forge may synthesize aggregate checks from `forgeSpecific`.
List<CheckoutPrCheck> resolvePullRequestChecks(CheckoutPrStatus status) {
  final nativeChecks = status.checks
      .where((check) => check.url != null)
      .map(
        (check) => CheckoutPrCheck(
          name: check.name,
          status: mapForgeCheckStatus(check.status).wireName,
          url: check.url,
          workflow: check.workflow,
          duration: check.duration,
          checkRunId: check.checkRunId,
          workflowRunId: check.workflowRunId,
        ),
      )
      .toList(growable: false);
  if (nativeChecks.isNotEmpty) return nativeChecks;
  return getGiteaNativeFallbackChecks(
    status,
    status.forge,
  ).map((check) => check.toCheckoutPrCheck()).toList(growable: false);
}

ForgeCheckStatus _mapGiteaCiStatus(String status) =>
    status == 'warning' || status == 'error'
    ? ForgeCheckStatus.failure
    : mapForgeCheckStatus(status);

bool _isNullableString(Object? value) => value == null || value is String;

bool _isFiniteNumber(Object? value) => value is num && value.isFinite;
