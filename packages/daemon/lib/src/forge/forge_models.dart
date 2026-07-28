import 'package:agent_protocol/agent_protocol.dart';

enum ForgeAuthState {
  authenticated,
  unauthenticated,
  cliMissing,
  noRemote,
  error;

  String get wireName => switch (this) {
    authenticated => 'authenticated',
    unauthenticated => 'unauthenticated',
    cliMissing => 'cli_missing',
    noRemote => 'no_remote',
    error => 'error',
  };
}

enum ForgeCheckStatus {
  success,
  failure,
  pending,
  skipped,
  cancelled;

  String get wireName => name;
}

enum ForgeChecksStatus {
  none,
  pending,
  success,
  failure;

  String get wireName => name;
}

enum ForgeReviewDecision {
  approved,
  changesRequested,
  pending;

  String get wireName => switch (this) {
    approved => 'approved',
    changesRequested => 'changes_requested',
    pending => 'pending',
  };
}

enum ForgeMergeable {
  mergeable,
  conflicting,
  unknown;

  String get wireName => name.toUpperCase();
}

final class ForgeSearchResult {
  const ForgeSearchResult({required this.items, required this.authState});

  final List<ForgeSearchItem> items;
  final ForgeAuthState authState;

  bool get featuresEnabled => authState == ForgeAuthState.authenticated;

  factory ForgeSearchResult.unavailable(ForgeAuthState authState) {
    if (authState == ForgeAuthState.authenticated) {
      throw ArgumentError.value(authState, 'authState');
    }
    return ForgeSearchResult(items: const [], authState: authState);
  }
}

final class ForgePullRequestCreateResult {
  const ForgePullRequestCreateResult({required this.url, required this.number});

  final String url;
  final int number;
}

final class ForgePullRequestTimeline {
  const ForgePullRequestTimeline({
    required this.prNumber,
    required this.items,
    required this.truncated,
    required this.error,
  });

  final int prNumber;
  final List<PullRequestTimelineItem> items;
  final bool truncated;
  final PullRequestTimelineError? error;
}

final class ForgeCheck {
  const ForgeCheck({
    required this.name,
    required this.status,
    required this.url,
    this.workflow,
    this.duration,
  });

  final String name;
  final ForgeCheckStatus status;
  final String? url;
  final String? workflow;
  final String? duration;

  Map<String, Object?> toJson() => {
    'name': name,
    'status': status.wireName,
    'url': url,
    if (workflow != null) 'workflow': workflow,
    if (duration != null) 'duration': duration,
  };
}

final class ForgePullRequestStatus {
  const ForgePullRequestStatus({
    required this.url,
    required this.title,
    required this.state,
    required this.baseRefName,
    required this.headRefName,
    required this.isMerged,
    required this.mergeable,
    required this.checks,
    required this.checksStatus,
    required this.reviewDecision,
    this.number,
    this.repoOwner,
    this.repoName,
    this.projectPath,
    this.isDraft,
    this.forgeSpecific,
  });

  final int? number;
  final String? repoOwner;
  final String? repoName;
  final String? projectPath;
  final String url;
  final String title;
  final String state;
  final String baseRefName;
  final String headRefName;
  final bool isMerged;
  final bool? isDraft;
  final ForgeMergeable mergeable;
  final List<ForgeCheck> checks;
  final ForgeChecksStatus checksStatus;
  final ForgeReviewDecision? reviewDecision;
  final Map<String, Object?>? forgeSpecific;

  Map<String, Object?> toJson() => {
    if (number != null) 'number': number,
    if (repoOwner != null) 'repoOwner': repoOwner,
    if (repoName != null) 'repoName': repoName,
    if (projectPath != null) 'projectPath': projectPath,
    'url': url,
    'title': title,
    'state': state,
    'baseRefName': baseRefName,
    'headRefName': headRefName,
    'isMerged': isMerged,
    if (isDraft != null) 'isDraft': isDraft,
    'mergeable': mergeable.wireName,
    'checks': checks.map((check) => check.toJson()).toList(),
    'checksStatus': checksStatus.wireName,
    'reviewDecision': reviewDecision?.wireName,
    if (forgeSpecific != null) 'forgeSpecific': forgeSpecific,
  };
}

final class WorkspaceForgeSnapshot {
  const WorkspaceForgeSnapshot({
    required this.featuresEnabled,
    required this.authState,
    required this.pullRequest,
    required this.error,
    required this.refreshedAt,
    this.forge,
  });

  final bool featuresEnabled;
  final ForgeAuthState authState;
  final String? forge;
  final ForgePullRequestStatus? pullRequest;
  final String? error;
  final String refreshedAt;

  factory WorkspaceForgeSnapshot.unavailable(
    ForgeAuthState authState, {
    String? forge,
    String? error,
    DateTime? now,
  }) => WorkspaceForgeSnapshot(
    featuresEnabled: false,
    authState: authState,
    forge: forge,
    pullRequest: null,
    error: error,
    refreshedAt: (now ?? DateTime.now()).toUtc().toIso8601String(),
  );

  Map<String, Object?> toGithubRuntimeJson() => {
    'featuresEnabled': featuresEnabled,
    'pullRequest': pullRequest?.toJson(),
    'error': error == null ? null : {'message': error},
    'refreshedAt': refreshedAt,
  };
}

ForgeChecksStatus computeForgeChecksStatus(Iterable<ForgeCheck> checks) {
  final values = checks.toList(growable: false);
  if (values.isEmpty) return ForgeChecksStatus.none;
  if (values.any((check) => check.status == ForgeCheckStatus.failure)) {
    return ForgeChecksStatus.failure;
  }
  if (values.any((check) => check.status == ForgeCheckStatus.pending)) {
    return ForgeChecksStatus.pending;
  }
  return ForgeChecksStatus.success;
}
