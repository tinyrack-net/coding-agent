import 'package:agent_protocol/agent_protocol.dart';

const pullRequestAvatarColors = <String>[
  '#8b5cf6',
  '#f97316',
  '#0ea5e9',
  '#10b981',
  '#ef4444',
  '#eab308',
  '#ec4899',
  '#6366f1',
];

enum PullRequestChangeState { open, draft, merged, closed }

final class PullRequestRepoIdentity {
  const PullRequestRepoIdentity({
    required this.prNumber,
    required this.repoOwner,
    required this.repoName,
  });

  final num? prNumber;
  final String? repoOwner;
  final String? repoName;
}

PullRequestRepoIdentity extractPullRequestRepoIdentity(
  CheckoutPrStatus? status,
) => PullRequestRepoIdentity(
  prNumber: status?.number,
  repoOwner: _nonEmpty(status?.repoOwner),
  repoName: _nonEmpty(status?.repoName),
);

String? _nonEmpty(String? value) =>
    value != null && value.isNotEmpty ? value : null;

bool shouldFetchPullRequestTimeline({
  required bool hasClient,
  required bool isConnected,
  required bool timelineEnabled,
  required bool githubFeaturesEnabled,
  required String cwd,
  required PullRequestRepoIdentity identity,
  required bool timelineUnsupported,
}) =>
    hasClient &&
    isConnected &&
    timelineEnabled &&
    githubFeaturesEnabled &&
    cwd.isNotEmpty &&
    identity.prNumber != null &&
    identity.repoOwner != null &&
    identity.repoName != null &&
    !timelineUnsupported;

String pullRequestTimelineUnsupportedKey({
  required String serverId,
  required String cwd,
  required num prNumber,
}) => '$serverId\u0000$cwd\u0000$prNumber';

final class PullRequestTimelineUnsupportedRegistry {
  final Set<String> _keys = {};

  bool has(String key) => _keys.contains(key);

  void add(String key) => _keys.add(key);
}

String derivePullRequestAvatarColor(String login) {
  var hash = 0;
  for (final rune in login.toLowerCase().runes) {
    final firstUtf16CodeUnit = rune <= 0xffff
        ? rune
        : 0xd800 + ((rune - 0x10000) >> 10);
    hash = (hash * 31 + firstUtf16CodeUnit) & 0xffffffff;
  }
  return pullRequestAvatarColors[hash % pullRequestAvatarColors.length];
}

String formatPullRequestAge(num createdAt, {DateTime? now}) {
  final milliseconds = createdAt < 100000000000 ? createdAt * 1000 : createdAt;
  final then = DateTime.fromMillisecondsSinceEpoch(
    milliseconds.round(),
    isUtc: true,
  );
  final difference = (now ?? DateTime.now().toUtc()).toUtc().difference(then);
  if (difference.isNegative || difference.inMinutes < 1) return 'just now';
  if (difference.inHours < 1) return '${difference.inMinutes}m ago';
  if (difference.inDays < 1) return '${difference.inHours}h ago';
  if (difference.inDays < 30) return '${difference.inDays}d ago';
  if (difference.inDays < 365) {
    return '${(difference.inDays / 30).floor()}mo ago';
  }
  return '${(difference.inDays / 365).floor()}y ago';
}

bool isVisiblePullRequestActivity(PullRequestTimelineItem activity) {
  return switch (activity) {
    PullRequestTimelineComment(body: final body) => body.trim().isNotEmpty,
    PullRequestTimelineReview(
      body: final body,
      reviewState: PullRequestTimelineReviewState.commented,
    ) =>
      body.trim().isNotEmpty,
    PullRequestTimelineReview() => true,
  };
}

List<PullRequestTimelineItem> normalizePullRequestTimeline({
  required num statusNumber,
  required num? timelineNumber,
  required List<PullRequestTimelineItem> items,
}) {
  if (timelineNumber != statusNumber) return const [];
  return items.where(isVisiblePullRequestActivity).toList(growable: false);
}

num? resolvePullRequestNumber(CheckoutPrStatus status) {
  if (status.number != null) return status.number;
  final uri = Uri.tryParse(status.url);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  final match = RegExp(r'/pull/(\d+)(?:/|$)').firstMatch(uri.path);
  return match == null ? null : int.tryParse(match.group(1)!);
}

CheckoutPrStatus? normalizePullRequestStatus(CheckoutPrStatus status) {
  final number = resolvePullRequestNumber(status);
  if (number == null) return null;
  if (number == status.number) return status;
  return CheckoutPrStatus(
    forge: status.forge,
    projectPath: status.projectPath,
    number: number,
    url: status.url,
    title: status.title,
    state: status.state,
    baseRefName: status.baseRefName,
    headRefName: status.headRefName,
    isMerged: status.isMerged,
    isDraft: status.isDraft,
    mergeable: status.mergeable,
    checks: status.checks,
    checksStatus: status.checksStatus,
    reviewDecision: status.reviewDecision,
    repoOwner: status.repoOwner,
    repoName: status.repoName,
    github: status.github,
    forgeSpecific: status.forgeSpecific,
  );
}

PullRequestChangeState derivePullRequestState(CheckoutPrStatus status) {
  final state = status.state.toLowerCase();
  if (status.isMerged || state == 'merged') {
    return PullRequestChangeState.merged;
  }
  if (state != 'open') return PullRequestChangeState.closed;
  if (status.isDraft) return PullRequestChangeState.draft;
  return PullRequestChangeState.open;
}

String pullRequestStateLabel(PullRequestChangeState state) => switch (state) {
  PullRequestChangeState.draft => 'Draft',
  PullRequestChangeState.merged => 'Merged',
  PullRequestChangeState.closed => 'Closed',
  PullRequestChangeState.open => 'Open',
};

String normalizePullRequestReviewDecision(String? reviewDecision) {
  final normalized = reviewDecision?.toLowerCase();
  return normalized == 'approved' || normalized == 'changes_requested'
      ? normalized!
      : 'pending';
}

String pullRequestActivityVerb(PullRequestTimelineItem item) => switch (item) {
  PullRequestTimelineComment() => 'Commented',
  PullRequestTimelineReview(
    reviewState: PullRequestTimelineReviewState.approved,
  ) =>
    'Approved',
  PullRequestTimelineReview(
    reviewState: PullRequestTimelineReviewState.changesRequested,
  ) =>
    'Requested changes',
  PullRequestTimelineReview() => 'Reviewed',
};
