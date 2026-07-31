/// Ports of Paseo 0.2.0's smallest standalone decision helpers, kept
/// together because each is a single frozen rule with no home of its own:
///
/// - `screens/workspace/workspace-draft-pane-focus.ts`
/// - `components/file-pane-render-mode.ts`
/// - `utils/status-loader.ts`
/// - `utils/latency.ts`
/// - `utils/extract-agent-model.ts`
/// - `utils/project-display-name.ts`
/// - `utils/desktop-badge-state.ts`
/// - `components/message-compaction-label.ts`
library;

import '../composer/composer_input_labels.dart';

/// A workspace draft composer takes focus with its pane, but never while a
/// submit is in flight — stealing focus mid-submit would fight the user.
bool shouldAutoFocusWorkspaceDraftComposer({
  required bool isPaneFocused,
  required bool isSubmitting,
}) => isPaneFocused && !isSubmitting;

/// Markdown files open in the rendered view rather than the code editor.
bool isRenderedMarkdownFile(String filePath) {
  final normalized = filePath.trim().toLowerCase();
  return normalized.endsWith('.md') || normalized.endsWith('.markdown');
}

/// The status buckets a workspace row can be in.
enum StatusLoaderBucket { needsInput, failed, running, attention, done }

/// Only a running workspace shows the synced spinner; every other bucket is
/// a settled state with its own glyph.
bool shouldRenderSyncedStatusLoader(StatusLoaderBucket? bucket) =>
    bucket == StatusLoaderBucket.running;

/// Formats a latency for display: sub-millisecond in microseconds, under a
/// second in whole milliseconds, and above that in seconds with at most one
/// decimal.
String formatLatency(num latencyMs) {
  if (latencyMs < 1) return '${(latencyMs * 1000).round()}µs';
  if (latencyMs < 1000) return '${latencyMs.round()}ms';

  final seconds = latencyMs / 1000;
  final roundedSeconds = (seconds * 10).round() / 10;
  return roundedSeconds == roundedSeconds.truncate()
      ? '${roundedSeconds.truncate()}s'
      : '${roundedSeconds.toStringAsFixed(1)}s';
}

/// The model an agent is actually running, preferring what the runtime
/// reports over what was configured, and treating blank as absent.
String? extractAgentModel({String? runtimeModel, String? configuredModel}) {
  final runtime = runtimeModel?.trim();
  if (runtime != null && runtime.isNotEmpty) return runtime;
  final configured = configuredModel?.trim();
  if (configured != null && configured.isNotEmpty) return configured;
  return null;
}

const _githubRemotePrefix = 'remote:github.com/';

/// Turns a project id into something readable: a GitHub remote keeps its
/// owner/repo, and a path keeps its last segment.
String projectDisplayNameFromProjectId(String projectId) {
  if (projectId.startsWith(_githubRemotePrefix)) {
    final remainder = projectId.substring(_githubRemotePrefix.length);
    return remainder.isEmpty ? projectId : remainder;
  }

  final segments = projectId
      .split(RegExp(r'[\\/]'))
      .where((segment) => segment.isNotEmpty)
      .toList();
  return segments.isEmpty ? projectId : segments.last;
}

/// The label a project's placeholder icon shows — the repo name rather than
/// the whole owner/repo pair.
String projectIconPlaceholderLabelFromDisplayName(String displayName) {
  final trimmed = displayName.trim();
  if (trimmed.isEmpty) return '';

  final segments = trimmed
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList();
  return segments.isEmpty ? trimmed : segments.last;
}

/// The workspace statuses that count toward the desktop badge.
enum DesktopBadgeWorkspaceStatus {
  attention,
  needsInput,
  failed,
  running,
  done,
}

/// A workspace is badge-worthy only when it is waiting on the user.
bool isWorkspaceActionableForDesktopBadge(DesktopBadgeWorkspaceStatus status) =>
    status == DesktopBadgeWorkspaceStatus.attention ||
    status == DesktopBadgeWorkspaceStatus.needsInput ||
    status == DesktopBadgeWorkspaceStatus.failed;

/// The dock badge count, or null when there is nothing to badge (rather
/// than a zero, which would render an empty badge).
int? deriveMacDockBadgeCountFromWorkspaceStatuses(
  List<DesktopBadgeWorkspaceStatus> statuses,
) {
  final actionableCount = statuses
      .where(isWorkspaceActionableForDesktopBadge)
      .length;
  return actionableCount > 0 ? actionableCount : null;
}

enum CompactionMarkerStatus { loading, completed }

enum CompactionMarkerTrigger { auto, manual }

/// The label on a compaction marker. Takes the translator because the app
/// has no localization layer yet (`i18n/*` is tracked separately).
String getCompactionMarkerLabel({
  required CompactionMarkerStatus status,
  required ComposerTranslator t,
  CompactionMarkerTrigger? trigger,
  num? preTokens,
  String Function(int thousands)? withTokens,
}) {
  if (status == CompactionMarkerStatus.loading) {
    return t('message.compaction.loading');
  }
  if (trigger == CompactionMarkerTrigger.auto) {
    return t('message.compaction.auto');
  }
  if (trigger == CompactionMarkerTrigger.manual) {
    return t('message.compaction.manual');
  }
  if (preTokens != null && preTokens != 0) {
    final thousands = (preTokens / 1000).round();
    return withTokens?.call(thousands) ?? t('message.compaction.withTokens');
  }
  return t('message.compaction.completed');
}
