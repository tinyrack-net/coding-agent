/// Port of Paseo 0.2.0's four frozen change-request / worktree-archive rules.
/// They live together because each is a small, dependency-light decision that a
/// widget or controller asks a single question of, and all four sit on the
/// boundary between the daemon's wire payloads and the git UI:
///
/// - `git/pr-hint.ts` — given a checkout's change-request status, what compact
///   badge should a workspace row render (number, state, brand mark)?
/// - `git/pr-status.ts` — how does a `checkout_pr_status_response` become a
///   payload whose auth state feature code can `switch` on, including for
///   daemons predating the `authState` field?
/// - `git/branch-switcher-operations.ts` — binds the branch switcher's git
///   calls to one workspace directory so a workspace *id* can never be passed
///   where a *cwd* is expected.
/// - `git/worktree-archive-warning.ts` — which risks make archiving a worktree
///   workspace destructive enough to warrant a confirmation, and what copy
///   explains them.
///
/// Forge normalization and auth-state parsing are *not* re-implemented here;
/// they were already ported in `core/forge.dart` and are reused.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../core/forge.dart';
import '../i18n/translations.dart';

// ---------------------------------------------------------------------------
// pr-hint.ts
// ---------------------------------------------------------------------------

/// The three states a [PrHint] badge can render.
///
/// Upstream's `"open" | "merged" | "closed"` is genuinely closed — it is
/// *computed* in [selectPrHintFromStatus] rather than taken from the wire — so
/// it becomes an enum. Contrast [PrHint.checksStatus] / [PrHint.reviewDecision]
/// below, which upstream merely casts and therefore stay strings.
enum PrHintState { open, merged, closed }

/// The upstream `"none" | "pending" | "success" | "failure"` check roll-up.
enum PrChecksStatus {
  none('none'),
  pending('pending'),
  success('success'),
  failure('failure');

  const PrChecksStatus(this.wireName);

  final String wireName;
}

/// The upstream `"approved" | "changes_requested" | "pending"` review verdict.
enum PrReviewDecision {
  approved('approved'),
  changesRequested('changes_requested'),
  pending('pending');

  const PrReviewDecision(this.wireName);

  final String wireName;
}

/// Typed reading of a raw [PrHint.checksStatus], or null when the daemon sent
/// a value this client does not know. Separate from the field so an unknown
/// value still survives on the hint, matching upstream's unchecked cast.
PrChecksStatus? parsePrChecksStatus(String? raw) {
  for (final value in PrChecksStatus.values) {
    if (value.wireName == raw) return value;
  }
  return null;
}

/// Typed reading of a raw [PrHint.reviewDecision]. See [parsePrChecksStatus]
/// for why this is a lookup rather than the field's own type.
PrReviewDecision? parsePrReviewDecision(String? raw) {
  for (final value in PrReviewDecision.values) {
    if (value.wireName == raw) return value;
  }
  return null;
}

/// The compact change-request summary a workspace row renders.
final class PrHint {
  const PrHint({
    required this.url,
    required this.number,
    required this.state,
    required this.forge,
    this.checks,
    this.checksStatus,
    this.reviewDecision,
  });

  final String url;

  /// The change-request number.
  ///
  /// Typed `num`, not `int`, to reproduce upstream exactly: JavaScript's
  /// `Number.parseInt` yields an imprecise double once the digit run exceeds
  /// 2^53, and the `Number.isFinite` guard upstream only rejects the digit runs
  /// long enough to overflow to `Infinity`. A Dart `int` would either throw or
  /// silently disagree on those inputs. See [_parseChangeRequestNumber].
  final num number;

  final PrHintState state;

  /// Forge backing this change request, so badges render the right brand mark.
  /// An open string (any id the daemon reports), per `core/forge.dart`.
  final String forge;

  final List<CheckoutPrCheck>? checks;

  /// Raw wire value. Upstream casts the daemon's string to its union without
  /// validating, so a value from a newer daemon reaches the UI verbatim; making
  /// this a [PrChecksStatus] would silently drop it. Read it through
  /// [parsePrChecksStatus] when you need to branch on it.
  final String? checksStatus;

  /// Raw wire value, for the same reason as [checksStatus]. Read it through
  /// [parsePrReviewDecision].
  final String? reviewDecision;
}

/// The shape [selectPrHintFromStatus] reads out of a change-request status.
///
/// Upstream declares a structural `PrStatusLike` so the selector accepts both
/// the wire status and hand-built test fixtures. Dart has no structural typing,
/// so this is a nominal carrier with [PrStatusLike.fromCheckoutPrStatus] for
/// the real wire object.
final class PrStatusLike {
  const PrStatusLike({
    required this.url,
    required this.state,
    required this.isMerged,
    this.checks,
    this.checksStatus,
    this.reviewDecision,
    this.forge,
  });

  /// Adapts the daemon's `checkout_pr_status_response` status onto the shape
  /// the selector reads.
  factory PrStatusLike.fromCheckoutPrStatus(CheckoutPrStatus status) =>
      PrStatusLike(
        url: status.url,
        state: status.state,
        isMerged: status.isMerged,
        checks: status.checks,
        checksStatus: status.checksStatus,
        reviewDecision: status.reviewDecision,
        forge: status.forge,
      );

  final String url;
  final String state;
  final bool isMerged;
  final List<CheckoutPrCheck>? checks;
  final String? checksStatus;
  final String? reviewDecision;
  final String? forge;
}

/// GitHub uses `/pull/N`, Gitea/Forgejo `/pulls/N`, GitLab `/-/merge_requests/N`.
/// Matching all three is what lets a non-GitHub change-request summary still
/// produce a hint (and therefore a brand mark).
final RegExp _changeRequestNumberPattern = RegExp(
  r'/(?:pull|pulls|merge_requests)/(\d+)(?:/|$)',
);

/// Extracts the change-request number from a forge URL, or null when the URL is
/// unparseable or carries no recognizable number.
///
/// Deviations from upstream's `new URL(url).pathname`:
///  - `Uri.tryParse` is far more permissive than the WHATWG URL parser, which
///    throws on anything lacking a scheme. The explicit [Uri.hasScheme] check
///    restores the "must be absolute" precondition, so a bare `"/pull/42"` is
///    rejected here exactly as it is upstream.
///  - The number is parsed as `int` first and only falls back to `double` for
///    digit runs that overflow 64 bits, which reproduces JavaScript's single
///    `Number` type: exact below 2^53, lossy above it, `Infinity` (rejected by
///    the finite check) far above it.
num? _parseChangeRequestNumber(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) {
    return null;
  }

  final match = _changeRequestNumberPattern.firstMatch(uri.path);
  if (match == null) {
    return null;
  }

  final digits = match.group(1)!;
  final number = int.tryParse(digits) ?? double.tryParse(digits);
  if (number == null || !number.isFinite) {
    return null;
  }
  return number;
}

/// Derives the workspace-row badge from a change-request status, or null when
/// there is nothing worth badging.
///
/// [forge] is the caller's already-resolved forge id and wins over the status's
/// own; it falls back to the status only when null, so an explicitly empty
/// string still normalizes to `github` (upstream uses `??`, not `||`, here).
/// A status with an empty URL is treated as absent, matching upstream's
/// truthiness check on `status?.url`.
PrHint? selectPrHintFromStatus(PrStatusLike? status, {String? forge}) {
  if (status == null || status.url.isEmpty) {
    return null;
  }

  final number = _parseChangeRequestNumber(status.url);
  if (number == null) {
    return null;
  }

  final PrHintState state;
  if (status.isMerged || status.state == 'merged') {
    state = PrHintState.merged;
  } else if (status.state == 'open') {
    state = PrHintState.open;
  } else {
    state = PrHintState.closed;
  }

  return PrHint(
    url: status.url,
    number: number,
    state: state,
    forge: normalizeForge(forge ?? status.forge),
    checks: status.checks,
    checksStatus: status.checksStatus,
    reviewDecision: status.reviewDecision,
  );
}

// ---------------------------------------------------------------------------
// pr-status.ts
// ---------------------------------------------------------------------------

/// A `checkout_pr_status_response` payload whose auth state feature code can
/// actually branch on.
///
/// The wire field is deliberately untyped (`z.unknown()`) so a newer daemon can
/// introduce states without breaking older clients; this type is the boundary
/// where that unknown becomes a closed [ForgeAuthState].
final class CheckoutPrStatusPayload {
  const CheckoutPrStatusPayload({
    required this.cwd,
    required this.status,
    required this.githubFeaturesEnabled,
    required this.authState,
    required this.forge,
    required this.error,
    required this.requestId,
  });

  final String cwd;
  final CheckoutPrStatus? status;

  /// The legacy boolean. Kept on the payload because it is still the only
  /// signal old daemons send, and [authState] is derived from it for those.
  final bool githubFeaturesEnabled;

  final ForgeAuthState authState;

  /// Already defaulted to `github` by the wire schema for daemons that predate
  /// the field, so this is non-null by the time it reaches feature code.
  final String forge;

  final CheckoutError? error;
  final String requestId;
}

/// Resolves the payload's auth state, falling back to the legacy feature flag.
///
/// Takes the whole response rather than a separate payload object because the
/// Dart `CheckoutPrStatusResponse` already flattens `payload` onto itself;
/// upstream's `Omit<..., "authState"> & { authState }` spread has no Dart
/// analogue, so the fields are re-stated explicitly.
CheckoutPrStatusPayload normalizeCheckoutPrStatusPayload(
  CheckoutPrStatusResponse payload,
) {
  return CheckoutPrStatusPayload(
    cwd: payload.cwd,
    status: payload.status,
    githubFeaturesEnabled: payload.githubFeaturesEnabled,
    // COMPAT(forgeAuthState): added in v0.1.106, remove after 2026-12-27 once
    // all supported daemons send authState.
    //
    // An *unknown* wire state deliberately falls through to the legacy flag
    // rather than being surfaced: feature code must never see a state it cannot
    // handle.
    authState:
        parseForgeAuthState(payload.authState) ??
        (payload.githubFeaturesEnabled
            ? ForgeAuthState.authenticated
            : ForgeAuthState.unauthenticated),
    forge: payload.forge,
    error: payload.error,
    requestId: payload.requestId,
  );
}

// ---------------------------------------------------------------------------
// branch-switcher-operations.ts
// ---------------------------------------------------------------------------

/// Whether a switched-to branch was already local or had to come from a remote.
enum CheckoutSwitchBranchSource { local, remote }

/// Result of a `checkout_switch_branch_response`.
///
/// Declared here rather than imported because the Dart protocol package has no
/// `checkout_switch_branch` message yet; the fields mirror the frozen upstream
/// schema so this can be deleted in favour of the generated type later.
final class CheckoutSwitchBranchResult {
  const CheckoutSwitchBranchResult({
    required this.cwd,
    required this.success,
    required this.branch,
    required this.error,
    required this.requestId,
    this.source,
  });

  final String cwd;
  final bool success;
  final String branch;
  final CheckoutError? error;
  final String requestId;
  final CheckoutSwitchBranchSource? source;
}

/// The slice of the daemon client the branch switcher needs.
///
/// Upstream types the parameter as the whole `DaemonClient`; narrowing it to an
/// interface is what makes [BranchSwitcherOperations] testable without a socket
/// and documents the five calls the switcher is allowed to make. The concrete
/// `DaemonClient` in this repo satisfies four of these and lacks
/// `checkoutSwitchBranch`, so production wiring goes through a thin adapter.
abstract interface class BranchSwitcherGitClient {
  Future<BranchSuggestionsResponse> getBranchSuggestions({
    required String cwd,
    int? limit,
  });

  Future<StashListResponse> stashList({required String cwd, bool? paseoOnly});

  Future<StashSaveResponse> stashSave({required String cwd, String? branch});

  Future<StashPopResponse> stashPop({
    required String cwd,
    required int stashIndex,
  });

  Future<CheckoutSwitchBranchResult> checkoutSwitchBranch({
    required String cwd,
    required String branch,
  });
}

/// Binds the branch switcher's git operations to a single workspace directory,
/// so a workspace id can never be passed where a cwd is expected. The directory
/// is set once at construction; callers choose the operation, never the
/// directory.
///
/// Upstream returns an object literal of closures over `cwd`; a final class is
/// the Dart equivalent. The guarantee is carried by the *method signatures* —
/// none of them accepts a directory — rather than by hiding [cwd], which stays
/// readable because callers routinely need it for logging and cache keys.
final class BranchSwitcherOperations {
  const BranchSwitcherOperations({required this.client, required this.cwd});

  final BranchSwitcherGitClient client;
  final String cwd;

  Future<BranchSuggestionsResponse> getBranchSuggestions({
    required int limit,
  }) => client.getBranchSuggestions(cwd: cwd, limit: limit);

  /// Only Paseo's own stashes: the switcher offers to restore work it stashed,
  /// never a stash the user made by hand.
  Future<StashListResponse> listPaseoStashes() =>
      client.stashList(cwd: cwd, paseoOnly: true);

  Future<StashSaveResponse> saveStash({String? branch}) =>
      client.stashSave(cwd: cwd, branch: branch);

  Future<StashPopResponse> popStash({required int stashIndex}) =>
      client.stashPop(cwd: cwd, stashIndex: stashIndex);

  Future<CheckoutSwitchBranchResult> switchBranch({required String branch}) =>
      client.checkoutSwitchBranch(cwd: cwd, branch: branch);
}

// ---------------------------------------------------------------------------
// worktree-archive-warning.ts
// ---------------------------------------------------------------------------

/// Added/deleted line counts for a workspace's working tree.
final class WorktreeArchiveDiffStat {
  const WorktreeArchiveDiffStat({
    required this.additions,
    required this.deletions,
  });

  final int additions;
  final int deletions;

  @override
  bool operator ==(Object other) =>
      other is WorktreeArchiveDiffStat &&
      other.additions == additions &&
      other.deletions == deletions;

  @override
  int get hashCode => Object.hash(additions, deletions);

  @override
  String toString() =>
      'WorktreeArchiveDiffStat(additions: $additions, deletions: $deletions)';
}

/// What could be lost by archiving a worktree-backed workspace.
///
/// [isDirty] is deliberately tri-state: `true`/`false` are the daemon's answer,
/// and null means "the daemon did not say", which is what lets [diffStat] stand
/// in for it. Upstream's `boolean | null | undefined` collapses to `bool?` here
/// because both absent forms take the same branch.
final class WorktreeArchiveRisk {
  const WorktreeArchiveRisk({this.isDirty, this.aheadOfOrigin, this.diffStat});

  final bool? isDirty;
  final int? aheadOfOrigin;
  final WorktreeArchiveDiffStat? diffStat;

  @override
  bool operator ==(Object other) =>
      other is WorktreeArchiveRisk &&
      other.isDirty == isDirty &&
      other.aheadOfOrigin == aheadOfOrigin &&
      other.diffStat == diffStat;

  @override
  int get hashCode => Object.hash(isDirty, aheadOfOrigin, diffStat);

  @override
  String toString() =>
      'WorktreeArchiveRisk(isDirty: $isDirty, aheadOfOrigin: $aheadOfOrigin, '
      'diffStat: $diffStat)';
}

/// A [WorktreeArchiveRisk] plus the workspace name the confirmation title
/// needs. Upstream extends the risk interface; composition is used here so the
/// risk type stays a plain value object.
final class WorktreeArchiveConfirmationInput {
  const WorktreeArchiveConfirmationInput({
    required this.workspaceName,
    required this.risk,
  });

  final String workspaceName;
  final WorktreeArchiveRisk risk;
}

/// Every string the archive warning can render, injected so the rules stay pure
/// and locale-independent.
final class WorktreeArchiveWarningLabels {
  const WorktreeArchiveWarningLabels({
    required this.title,
    required this.confirm,
    required this.cancel,
    required this.uncommittedChanges,
    required this.uncommittedChangesWithDiff,
    required this.addedLine,
    required this.deletedLine,
    required this.unpushedCommit,
  });

  /// Builds the labels from a live translator.
  ///
  /// This is the true analogue of upstream's
  /// `DEFAULT_WORKTREE_ARCHIVE_WARNING_LABELS`, which binds to the i18next
  /// singleton at module load. Dart has no such singleton — [Translations] is
  /// loaded asynchronously and handed down — so the binding is an explicit
  /// factory, and [defaultWorktreeArchiveWarningLabels] covers callers with no
  /// translator in hand.
  factory WorktreeArchiveWarningLabels.fromTranslations(
    Translations translations,
  ) {
    String t(String key, [Map<String, Object?>? args]) =>
        translations.t('workspace.git.actions.archiveWarning.$key', args: args);

    return WorktreeArchiveWarningLabels(
      title: (workspaceName) => t('title', {'workspaceName': workspaceName}),
      confirm: t('confirm'),
      cancel: t('cancel'),
      uncommittedChanges: t('uncommittedChanges'),
      uncommittedChangesWithDiff: (diffStat) =>
          t('uncommittedChangesWithDiff', {'diffStat': diffStat}),
      // i18next selects the plural form by key suffix; the exact-1 test is
      // upstream's, reproduced rather than delegated to a plural engine.
      addedLine: (count) =>
          t(count == 1 ? 'addedLine' : 'addedLines', {'count': count}),
      deletedLine: (count) =>
          t(count == 1 ? 'deletedLine' : 'deletedLines', {'count': count}),
      unpushedCommit: (count) => t(
        count == 1 ? 'unpushedCommit' : 'unpushedCommits',
        {'count': count},
      ),
    );
  }

  final String Function(String workspaceName) title;
  final String confirm;
  final String cancel;
  final String uncommittedChanges;
  final String Function(String diffStat) uncommittedChangesWithDiff;
  final String Function(int count) addedLine;
  final String Function(int count) deletedLine;
  final String Function(int count) unpushedCommit;
}

/// The frozen English copy, used when no translator is available.
///
/// Mirrors `assets/i18n/en.json` under
/// `workspace.git.actions.archiveWarning`; kept as literals so these rules are
/// usable (and testable) without the asset bundle.
final WorktreeArchiveWarningLabels defaultWorktreeArchiveWarningLabels =
    WorktreeArchiveWarningLabels(
      title: (workspaceName) => 'Archive "$workspaceName"?',
      confirm: 'Archive',
      cancel: 'Cancel',
      uncommittedChanges: 'Uncommitted changes',
      uncommittedChangesWithDiff: (diffStat) =>
          'Uncommitted changes ($diffStat)',
      addedLine: (count) => count == 1 ? '1 added line' : '$count added lines',
      deletedLine: (count) =>
          count == 1 ? '1 deleted line' : '$count deleted lines',
      unpushedCommit: (count) =>
          count == 1 ? '1 unpushed commit' : '$count unpushed commits',
    );

/// Maps the archive-workspace wire fields onto the shared risk shape, so the
/// archive flow and the worktree flow reason about danger identically.
WorktreeArchiveRisk toWorktreeArchiveRisk({
  bool? archiveHasUncommittedChanges,
  int? archiveUnpushedCommitCount,
  WorktreeArchiveDiffStat? diffStat,
}) => WorktreeArchiveRisk(
  isDirty: archiveHasUncommittedChanges,
  aheadOfOrigin: archiveUnpushedCommitCount,
  diffStat: diffStat,
);

/// `"12 added lines, 1 deleted line"`, or null when there is nothing to say —
/// a zero-on-both-sides diff stat reads as no diff stat at all, so the caller
/// falls back to the undecorated "Uncommitted changes".
String? _formatDiffStat(
  WorktreeArchiveDiffStat? diffStat,
  WorktreeArchiveWarningLabels labels,
) {
  if (diffStat == null) {
    return null;
  }

  final parts = <String>[];
  if (diffStat.additions > 0) {
    parts.add(labels.addedLine(diffStat.additions));
  }
  if (diffStat.deletions > 0) {
    parts.add(labels.deletedLine(diffStat.deletions));
  }

  return parts.isNotEmpty ? parts.join(', ') : null;
}

/// One line per thing archiving would put at risk; empty means archiving is
/// safe and no confirmation is warranted.
///
/// A null [WorktreeArchiveRisk.isDirty] is treated as dirty only when the diff
/// stat shows real changes: an older daemon that reports line counts but no
/// dirty flag still gets a warning, while a daemon that reports neither stays
/// silent rather than crying wolf.
List<String> buildWorktreeArchiveRiskReasons(
  WorktreeArchiveRisk input, {
  WorktreeArchiveWarningLabels? labels,
}) {
  final resolved = labels ?? defaultWorktreeArchiveWarningLabels;
  final reasons = <String>[];
  final diffStat = input.diffStat;
  final hasDiffStatChanges = diffStat != null
      ? diffStat.additions > 0 || diffStat.deletions > 0
      : false;
  final hasUncommittedChanges =
      input.isDirty == true || (input.isDirty == null && hasDiffStatChanges);

  if (hasUncommittedChanges) {
    final diffStatLabel = _formatDiffStat(diffStat, resolved);
    reasons.add(
      diffStatLabel != null
          ? resolved.uncommittedChangesWithDiff(diffStatLabel)
          : resolved.uncommittedChanges,
    );
  }

  if ((input.aheadOfOrigin ?? 0) > 0) {
    reasons.add(resolved.unpushedCommit(input.aheadOfOrigin ?? 0));
  }

  return reasons;
}

/// The confirmation body, or null when archiving is safe. Null is the signal
/// to skip the dialog entirely, not to show an empty one.
String? buildWorktreeArchiveConfirmationMessage(
  WorktreeArchiveConfirmationInput input, {
  WorktreeArchiveWarningLabels? labels,
}) {
  final reasons = buildWorktreeArchiveRiskReasons(input.risk, labels: labels);
  if (reasons.isEmpty) {
    return null;
  }

  return reasons.join('\n');
}

/// Everything a host needs to render the archive confirmation.
final class WorktreeArchiveConfirmRequest {
  const WorktreeArchiveConfirmRequest({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.destructive,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;
}

/// Shows the confirmation and reports the user's answer.
///
/// Upstream calls a module-level `confirmDialog` that reaches for React Native's
/// `Alert` or the desktop host; injecting it keeps this rule free of any widget
/// tree and testable without pumping a dialog.
typedef WorktreeArchiveConfirmPrompt =
    Future<bool> Function(WorktreeArchiveConfirmRequest request);

/// Asks before archiving a workspace whose worktree still holds work, and
/// returns true when archiving may proceed.
///
/// A risk-free archive resolves true *without* prompting — silence is consent
/// here because there is nothing to lose.
Future<bool> confirmRiskyWorktreeArchive(
  WorktreeArchiveConfirmationInput input, {
  required WorktreeArchiveConfirmPrompt prompt,
  WorktreeArchiveWarningLabels? labels,
}) async {
  final resolved = labels ?? defaultWorktreeArchiveWarningLabels;
  final message = buildWorktreeArchiveConfirmationMessage(
    input,
    labels: resolved,
  );
  // Upstream's `if (!message)` also short-circuits on the empty string; that
  // branch is unreachable because every reason is non-empty, so a null check is
  // equivalent.
  if (message == null) {
    return true;
  }

  return await prompt(
    WorktreeArchiveConfirmRequest(
      title: resolved.title(input.workspaceName),
      message: message,
      confirmLabel: resolved.confirm,
      cancelLabel: resolved.cancel,
      destructive: true,
    ),
  );
}
