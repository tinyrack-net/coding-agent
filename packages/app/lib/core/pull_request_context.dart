import 'package:agent_protocol/agent_protocol.dart';

import '../state/workspace_attachments_provider.dart';
import 'forge.dart';

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

sealed class PullRequestTimelineEntry {
  const PullRequestTimelineEntry(this.id);

  final String id;
}

final class PullRequestSingleEntry extends PullRequestTimelineEntry {
  const PullRequestSingleEntry(super.id, this.activity);

  final PullRequestTimelineItem activity;
}

final class PullRequestThreadEntry extends PullRequestTimelineEntry {
  const PullRequestThreadEntry({
    required String id,
    required this.comments,
    this.location,
    this.isResolved,
  }) : super(id);

  final List<PullRequestTimelineComment> comments;
  final PullRequestTimelineCommentLocation? location;
  final bool? isResolved;

  bool get collapsedByDefault =>
      isResolved == true || location?.isOutdated == true;
}

final class PullRequestReviewEntry extends PullRequestTimelineEntry {
  const PullRequestReviewEntry({
    required String id,
    required this.review,
    required this.threads,
  }) : super(id);

  final PullRequestTimelineReview review;
  final List<PullRequestThreadEntry> threads;
}

List<PullRequestTimelineEntry> buildPullRequestTimeline(
  List<PullRequestTimelineItem> activities,
) {
  final entries = <PullRequestTimelineEntry>[];
  final threadsById = <String, PullRequestThreadEntry>{};

  for (final activity in activities) {
    if (!isVisiblePullRequestActivity(activity)) continue;
    if (activity is! PullRequestTimelineComment) {
      entries.add(PullRequestSingleEntry(activity.id, activity));
      continue;
    }
    final threadId = activity.threadId ?? activity.location?.threadId;
    if (threadId == null || threadId.isEmpty) {
      entries.add(PullRequestSingleEntry(activity.id, activity));
      continue;
    }
    final existing = threadsById[threadId];
    if (existing != null) {
      existing.comments.add(activity);
      continue;
    }
    final thread = PullRequestThreadEntry(
      id: 'thread:$threadId',
      comments: [activity],
      location: activity.location,
      isResolved: activity.location?.isResolved ?? activity.threadIsResolved,
    );
    threadsById[threadId] = thread;
    entries.add(thread);
  }

  final reviewIds = {
    for (final entry in entries)
      if (entry case PullRequestSingleEntry(
        activity: PullRequestTimelineReview(id: final id),
      ))
        id,
  };
  final byReview = <String, List<PullRequestThreadEntry>>{};
  for (final entry in entries.whereType<PullRequestThreadEntry>()) {
    final reviewId = entry.comments.firstOrNull?.reviewId;
    if (reviewId != null && reviewIds.contains(reviewId)) {
      byReview.putIfAbsent(reviewId, () => []).add(entry);
    }
  }
  if (byReview.isEmpty) return entries;

  final nested = byReview.values.expand((threads) => threads).toSet();
  return [
    for (final entry in entries)
      if (entry is PullRequestThreadEntry && nested.contains(entry))
        ...const <PullRequestTimelineEntry>[]
      else if (entry case PullRequestSingleEntry(
        activity: PullRequestTimelineReview() && final review,
      ))
        if (byReview[review.id] case final threads?)
          PullRequestReviewEntry(id: entry.id, review: review, threads: threads)
        else
          entry
      else
        entry,
  ];
}

bool canAddPullRequestActivityToChat(PullRequestTimelineItem activity) {
  if (activity is PullRequestTimelineComment) {
    return activity.body.trim().isNotEmpty;
  }
  final review = activity as PullRequestTimelineReview;
  return review.body.trim().isNotEmpty ||
      review.reviewState == PullRequestTimelineReviewState.changesRequested;
}

WorkspaceContextAttachment? buildPullRequestActivityAttachment({
  required CheckoutPrStatus status,
  required PullRequestTimelineItem activity,
}) {
  if (!canAddPullRequestActivityToChat(activity)) return null;
  final number = status.number?.toInt();
  if (number == null) return null;
  final forge = getForgeDefinitionOrNeutral(status.forge.toLowerCase());
  final isReview = activity is PullRequestTimelineReview;
  final kind = isReview
      ? 'forge.change_request_review'
      : 'forge.change_request_comment';
  final noun = _capitalize(forge.changeRequestNoun);
  final lines = [
    '${forge.displayName} ${forge.changeRequestNoun} ${isReview ? 'review' : 'comment'}',
    '$noun: ${forge.changeRequestNumberPrefix}$number ${status.title}',
    '$noun URL: ${status.url}',
    'URL: ${activity.url}',
    'Author: ${activity.author}',
    if (activity case PullRequestTimelineReview(reviewState: final reviewState))
      'State: ${reviewState.wireName}',
    'Created: ${formatPullRequestAge(activity.createdAt)}',
    if (activity case PullRequestTimelineComment(location: final location?))
      'Location: ${formatPullRequestActivityLocation(location)}',
    if (activity.body.trim().isNotEmpty) ...['', activity.body.trim()],
  ];
  return WorkspaceContextAttachment(
    kind: kind,
    id: '$number:${activity.id}',
    title: activity.author,
    subtitle: '${forge.changeRequestNumberPrefix}$number ${status.title}',
    text: lines.join('\n'),
    url: activity.url,
  );
}

WorkspaceContextAttachment? buildPullRequestThreadAttachment({
  required CheckoutPrStatus status,
  required PullRequestThreadEntry thread,
}) {
  final number = status.number?.toInt();
  final root = thread.comments.firstOrNull;
  final comments = thread.comments
      .where((comment) => comment.body.trim().isNotEmpty)
      .toList(growable: false);
  if (number == null || comments.isEmpty || root == null) return null;
  final forge = getForgeDefinitionOrNeutral(status.forge.toLowerCase());
  final noun = _capitalize(forge.changeRequestNoun);
  final title = thread.location == null
      ? 'Discussion thread'
      : formatPullRequestThreadPath(thread.location!);
  final lines = [
    '${forge.displayName} ${forge.changeRequestNoun} review thread',
    '$noun: ${forge.changeRequestNumberPrefix}$number ${status.title}',
    '$noun URL: ${status.url}',
    'URL: ${root.url}',
    if (thread.location case final location?)
      'Location: ${formatPullRequestThreadPath(location)}',
    if (thread.location?.isResolved case final resolved?)
      'Thread state: ${resolved ? 'resolved' : 'unresolved'}',
    if (thread.location?.isOutdated == true)
      'Note: this thread is outdated (the code it refers to has changed)',
    '',
    comments
        .map(
          (comment) =>
              '${comment.author} (${formatPullRequestAge(comment.createdAt)}):\n'
              '${comment.body.trim()}',
        )
        .join('\n\n---\n\n'),
  ];
  return WorkspaceContextAttachment(
    kind: 'forge.change_request_comment',
    id: '$number:${thread.id}',
    title: title,
    subtitle: '${forge.changeRequestNumberPrefix}$number ${status.title}',
    text: lines.join('\n'),
    url: root.url,
  );
}

bool canAddPullRequestCheckLogsToChat(CheckoutPrCheck check) =>
    check.status == 'failure';

WorkspaceContextAttachment buildPullRequestCheckAttachment({
  required CheckoutPrStatus status,
  required CheckoutPrCheck check,
  CheckoutCheckDetails? details,
}) {
  final number = status.number?.toInt();
  if (number == null) {
    throw ArgumentError.value(status.number, 'status.number');
  }
  final forge = getForgeDefinitionOrNeutral(status.forge.toLowerCase());
  final noun = _capitalize(forge.changeRequestNoun);
  final lines = [
    '${forge.displayName} ${forge.changeRequestNoun} check',
    '$noun: ${forge.changeRequestNumberPrefix}$number ${status.title}',
    '$noun URL: ${status.url}',
    'Check: ${check.name}',
    'Status: ${check.status}',
    if (details?.conclusion case final conclusion? when conclusion.isNotEmpty)
      'Conclusion: $conclusion',
    'Check URL: ${check.url}',
    if ((details?.detailsUrl ?? details?.url) case final detailsUrl?
        when detailsUrl.isNotEmpty)
      'Details URL: $detailsUrl',
  ];
  _appendCheckOutput(lines, details);
  _appendCheckAnnotations(lines, details);
  _appendFailedJobs(lines, details);
  if (details?.truncated == true) {
    lines.addAll([
      '',
      'Note: Check details were truncated by ${forge.displayName}/API or local caps.',
    ]);
  }
  final checkId = check.checkRunId == null
      ? '$number:check:${check.name}'
      : '$number:check-run:${check.checkRunId!.toInt()}';
  return WorkspaceContextAttachment(
    kind: 'forge.change_request_check',
    id: checkId,
    title: check.name,
    subtitle: '${forge.changeRequestNumberPrefix}$number ${status.title}',
    text: lines.join('\n'),
    url: details?.detailsUrl ?? details?.url ?? check.url,
  );
}

void _appendCheckOutput(List<String> lines, CheckoutCheckDetails? details) {
  final output = details?.output;
  if (output?['title'] case final String title when title.isNotEmpty) {
    lines.add('Output title: $title');
  }
  if (output?['summary'] case final String summary when summary.isNotEmpty) {
    lines.add('Output summary: $summary');
  }
  if (output?['text'] case final String text when text.isNotEmpty) {
    lines.addAll(['Output text:', text]);
  }
}

void _appendCheckAnnotations(
  List<String> lines,
  CheckoutCheckDetails? details,
) {
  final annotations = details?.annotations ?? const [];
  if (annotations.isEmpty) return;
  lines.addAll(['', 'Annotations:']);
  for (final annotation in annotations) {
    final location = annotation.path == null
        ? 'unknown location'
        : '${annotation.path}${_annotationLines(annotation)}';
    final level = annotation.annotationLevel == null
        ? ''
        : ' ${annotation.annotationLevel}';
    final message = annotation.message == null ? '' : ': ${annotation.message}';
    lines.add('- $location$level$message');
  }
}

String _annotationLines(CheckoutCheckAnnotation annotation) {
  if (annotation.startLine != null && annotation.endLine != null) {
    return ':${annotation.startLine!.toInt()}-${annotation.endLine!.toInt()}';
  }
  if (annotation.startLine != null) {
    return ':${annotation.startLine!.toInt()}';
  }
  return '';
}

void _appendFailedJobs(List<String> lines, CheckoutCheckDetails? details) {
  final jobs = details?.failedJobs ?? const [];
  if (jobs.isEmpty) return;
  lines.addAll(['', 'Failed jobs:']);
  for (final job in jobs) {
    lines.add('- ${job.name}: ${job.conclusion ?? job.status ?? 'unknown'}');
    if (job.url case final url? when url.isNotEmpty) lines.add('  $url');
    if (job.logTail case final log? when log.isNotEmpty) {
      lines.addAll([
        '  ```',
        ...log.split('\n').map((line) => '  $line'),
        '  ```',
      ]);
    }
    if (job.logTruncated == true) {
      lines.add('  Log tail truncated to the latest capped lines.');
    }
  }
}

String formatPullRequestActivityLocation(
  PullRequestTimelineCommentLocation location,
) {
  final parts = [formatPullRequestThreadPath(location)];
  if (location.isResolved case final resolved?) {
    parts.add(resolved ? 'resolved' : 'unresolved');
  }
  if (location.isOutdated case final outdated?) {
    parts.add(outdated ? 'outdated' : 'current');
  }
  final threadId = location.threadId;
  if (threadId != null && threadId.length <= 24) {
    parts.add('thread $threadId');
  }
  return parts.join(' · ');
}

String formatPullRequestThreadPath(
  PullRequestTimelineCommentLocation location,
) {
  final line = location.line?.toInt();
  final start = location.startLine?.toInt();
  if (line != null && start != null) return '${location.path}:$start-$line';
  if (line != null) return '${location.path}:$line';
  return location.path;
}

String formatPullRequestAge(num createdAt) {
  final milliseconds = createdAt < 100000000000 ? createdAt * 1000 : createdAt;
  final then = DateTime.fromMillisecondsSinceEpoch(
    milliseconds.round(),
    isUtc: true,
  );
  final difference = DateTime.now().toUtc().difference(then);
  if (difference.isNegative || difference.inMinutes < 1) return 'just now';
  if (difference.inHours < 1) return '${difference.inMinutes}m ago';
  if (difference.inDays < 1) return '${difference.inHours}h ago';
  if (difference.inDays < 30) return '${difference.inDays}d ago';
  if (difference.inDays < 365) {
    return '${(difference.inDays / 30).floor()}mo ago';
  }
  return '${(difference.inDays / 365).floor()}y ago';
}

String _capitalize(String value) =>
    value.isEmpty ? value : '${value[0].toUpperCase()}${value.substring(1)}';
