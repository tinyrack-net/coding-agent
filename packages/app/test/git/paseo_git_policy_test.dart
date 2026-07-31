// Port of the upstream suite for `git/policy.ts`, plus the edge cases it leaves
// unpinned: the whole primary-action precedence ladder (upstream only samples
// it), every arm of all six "unavailable" message helpers, the null-tracking
// (`aheadOfOrigin == null`) branches, the archive-dedup rule, runtime
// pass-through (disabled/status/icon/handler identity), the merge-method
// allowlist fallbacks, `narrowPullRequestState` (exported but never tested
// upstream), and the vendored-English-copy-vs-shipped-asset drift guard.
//
// Every expectation about built actions was pinned by executing the frozen
// TypeScript under Node against the same scenarios, not by reading the source.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/forge_logic.dart';
import 'package:coding_agent_app/git/paseo_git_policy.dart';
import 'package:coding_agent_app/i18n/locales.dart';
import 'package:coding_agent_app/i18n/translations.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// Sentinel that lets an optional named parameter distinguish "not passed"
/// (use the default) from "passed null" — which matters for `aheadOfOrigin` /
/// `behindOfOrigin`, where null and 0 take different branches.
const Object _unset = Object();

/// Mirrors the upstream `githubStatus` fixture: a complete GitHub merge-facts
/// envelope with the fields a test cares about overridden.
Map<String, Object?> githubStatus({
  Object? mergeStateStatus = 'CLEAN',
  Map<String, Object?>? autoMergeRequest,
  bool viewerCanEnableAutoMerge = false,
  bool viewerCanDisableAutoMerge = false,
  bool viewerCanMergeAsAdmin = false,
  bool viewerCanUpdateBranch = false,
  Map<String, Object?>? repository,
  bool isMergeQueueEnabled = false,
  bool isInMergeQueue = false,
}) => {
  'forge': 'github',
  'mergeStateStatus': mergeStateStatus,
  'autoMergeRequest': autoMergeRequest,
  'viewerCanEnableAutoMerge': viewerCanEnableAutoMerge,
  'viewerCanDisableAutoMerge': viewerCanDisableAutoMerge,
  'viewerCanMergeAsAdmin': viewerCanMergeAsAdmin,
  'viewerCanUpdateBranch': viewerCanUpdateBranch,
  'repository':
      repository ??
      const {
        'autoMergeAllowed': true,
        'mergeCommitAllowed': true,
        'squashMergeAllowed': true,
        'rebaseMergeAllowed': true,
        'viewerDefaultMergeMethod': 'SQUASH',
      },
  'isMergeQueueEnabled': isMergeQueueEnabled,
  'isInMergeQueue': isInMergeQueue,
};

/// Repository merge policy with only the named methods allowed.
Map<String, Object?> repositoryPolicy({
  bool autoMergeAllowed = true,
  bool mergeCommitAllowed = true,
  bool squashMergeAllowed = true,
  bool rebaseMergeAllowed = true,
  String? viewerDefaultMergeMethod = 'SQUASH',
}) => {
  'autoMergeAllowed': autoMergeAllowed,
  'mergeCommitAllowed': mergeCommitAllowed,
  'squashMergeAllowed': squashMergeAllowed,
  'rebaseMergeAllowed': rebaseMergeAllowed,
  'viewerDefaultMergeMethod': viewerDefaultMergeMethod,
};

/// Mirrors the upstream `createInput` helper. `pullRequestGithub` is handed to
/// the real forge derivation so the capability under test is the one production
/// would compute, not a hand-built stub.
BuildGitActionsInput createInput({
  bool isGit = true,
  bool githubFeaturesEnabled = true,
  String forgeBrandLabel = 'GitHub',
  String forgeChangeRequestNoun = 'PR',
  bool githubAutoMergeActionsEnabled = true,
  bool hasPullRequest = false,
  String? pullRequestUrl,
  PullRequestState? pullRequestState,
  bool pullRequestIsDraft = false,
  bool pullRequestIsMerged = false,
  PullRequestMergeable pullRequestMergeable = PullRequestMergeable.unknown,
  Object? pullRequestGithub,
  bool hasRemote = false,
  bool isPaseoOwnedWorktree = false,
  bool isOnBaseBranch = true,
  bool hasUncommittedChanges = false,
  bool baseRefAvailable = true,
  String baseRefLabel = 'main',
  int aheadCount = 0,
  int behindBaseCount = 0,
  Object? aheadOfOrigin = _unset,
  Object? behindOfOrigin = _unset,
  bool shouldPromoteArchive = false,
  ShipDefault shipDefault = ShipDefault.pr,
  Map<GitActionId, GitActionRuntimeState> runtimeOverrides = const {},
  void Function()? handler,
}) => BuildGitActionsInput(
  isGit: isGit,
  githubFeaturesEnabled: githubFeaturesEnabled,
  forgeBrandLabel: forgeBrandLabel,
  forgeChangeRequestNoun: forgeChangeRequestNoun,
  githubAutoMergeActionsEnabled: githubAutoMergeActionsEnabled,
  hasPullRequest: hasPullRequest,
  pullRequestUrl: pullRequestUrl,
  pullRequestState: pullRequestState,
  pullRequestIsDraft: pullRequestIsDraft,
  pullRequestIsMerged: pullRequestIsMerged,
  pullRequestMergeable: pullRequestMergeable,
  mergeCapability: deriveForgeMergeCapability(pullRequestGithub),
  hasRemote: hasRemote,
  isPaseoOwnedWorktree: isPaseoOwnedWorktree,
  isOnBaseBranch: isOnBaseBranch,
  hasUncommittedChanges: hasUncommittedChanges,
  baseRefAvailable: baseRefAvailable,
  baseRefLabel: baseRefLabel,
  aheadCount: aheadCount,
  behindBaseCount: behindBaseCount,
  aheadOfOrigin: identical(aheadOfOrigin, _unset) ? 0 : aheadOfOrigin as int?,
  behindOfOrigin: identical(behindOfOrigin, _unset)
      ? 0
      : behindOfOrigin as int?,
  shouldPromoteArchive: shouldPromoteArchive,
  shipDefault: shipDefault,
  runtime: idleGitActionRuntime(
    handler: handler ?? () {},
    overrides: runtimeOverrides,
  ),
);

/// The open, mergeable pull request most merge scenarios start from.
BuildGitActionsInput openPrInput({
  int aheadCount = 2,
  Object? pullRequestGithub,
  bool githubFeaturesEnabled = true,
  bool githubAutoMergeActionsEnabled = true,
  bool pullRequestIsDraft = false,
  bool pullRequestIsMerged = false,
  PullRequestState? pullRequestState = PullRequestState.open,
  PullRequestMergeable pullRequestMergeable = PullRequestMergeable.mergeable,
  String? pullRequestUrl = 'https://example.com/pr/456',
  bool hasUncommittedChanges = false,
  bool isPaseoOwnedWorktree = false,
  int behindBaseCount = 0,
  Object? aheadOfOrigin = _unset,
  Object? behindOfOrigin = _unset,
  ShipDefault shipDefault = ShipDefault.pr,
  Map<GitActionId, GitActionRuntimeState> runtimeOverrides = const {},
}) => createInput(
  hasRemote: true,
  isOnBaseBranch: false,
  aheadCount: aheadCount,
  behindBaseCount: behindBaseCount,
  aheadOfOrigin: aheadOfOrigin,
  behindOfOrigin: behindOfOrigin,
  hasPullRequest: true,
  pullRequestUrl: pullRequestUrl,
  pullRequestState: pullRequestState,
  pullRequestIsDraft: pullRequestIsDraft,
  pullRequestIsMerged: pullRequestIsMerged,
  pullRequestMergeable: pullRequestMergeable,
  pullRequestGithub: pullRequestGithub,
  githubFeaturesEnabled: githubFeaturesEnabled,
  githubAutoMergeActionsEnabled: githubAutoMergeActionsEnabled,
  hasUncommittedChanges: hasUncommittedChanges,
  isPaseoOwnedWorktree: isPaseoOwnedWorktree,
  shipDefault: shipDefault,
  runtimeOverrides: runtimeOverrides,
);

// ---------------------------------------------------------------------------
// Assertion helpers
// ---------------------------------------------------------------------------

/// The frozen wire ids, which is how upstream's expectations are written.
List<String> idsOf(List<GitAction> actions) =>
    actions.map((action) => action.id.wireName).toList(growable: false);

GitAction? findAction(List<GitAction> actions, GitActionId id) {
  for (final action in actions) {
    if (action.id == id) return action;
  }
  return null;
}

/// Every policy-owned field of an action, as a record so comparisons are
/// structural and failures print the whole row.
typedef ActionRow = ({
  String id,
  String label,
  String pendingLabel,
  String successLabel,
  bool disabled,
  GitActionStatus status,
  String? unavailableMessage,
  bool startsGroup,
});

ActionRow rowOf(GitAction action) => (
  id: action.id.wireName,
  label: action.label,
  pendingLabel: action.pendingLabel,
  successLabel: action.successLabel,
  disabled: action.disabled,
  status: action.status,
  unavailableMessage: action.unavailableMessage,
  startsGroup: action.startsGroup,
);

const List<String> mergePrActionIds = [
  'merge-pr-squash',
  'merge-pr-merge',
  'merge-pr-rebase',
];

/// Every `workspace.git.actions.*` key `paseo_git_policy.dart` reads. Doubles
/// as the checklist for the vendored-copy drift guard below.
const List<String> policyCopyKeys = [
  'commit.label',
  'commit.pending',
  'commit.success',
  'pull.label',
  'pull.pending',
  'pull.success',
  'push.label',
  'push.pending',
  'push.success',
  'pullAndPush.label',
  'pullAndPush.pending',
  'pullAndPush.success',
  'viewPr',
  'createPr.label',
  'createPr.pending',
  'createPr.success',
  'mergeBranch.label',
  'mergeBranch.pending',
  'mergeBranch.success',
  'mergeFromBase.label',
  'mergeFromBase.pending',
  'mergeFromBase.success',
  'archive.label',
  'archive.pending',
  'archive.success',
  'mergePr.squash',
  'mergePr.merge',
  'mergePr.rebase',
  'mergePr.pending',
  'mergePr.success',
  'autoMerge.enableSquash',
  'autoMerge.enableMerge',
  'autoMerge.enableRebase',
  'autoMerge.enabled',
  'autoMerge.enabling',
  'autoMerge.disabling',
  'autoMerge.disabled',
  'unavailable.viewPrNoForge',
  'unavailable.pullNoRemote',
  'unavailable.pullDirty',
  'unavailable.pullUpToDate',
  'unavailable.pushNoRemote',
  'unavailable.pushBehind',
  'unavailable.pushNothing',
  'unavailable.pullAndPushNoRemote',
  'unavailable.pullAndPushDirty',
  'unavailable.pullAndPushNoIncoming',
  'unavailable.pullAndPushInSync',
  'unavailable.pullAndPushNothingToPush',
  'unavailable.createPrNoForge',
  'unavailable.createPrNoCommits',
  'unavailable.mergeNoBase',
  'unavailable.mergeDirty',
  'unavailable.mergeNothing',
  'unavailable.updateNoBase',
  'unavailable.updateDirty',
  'unavailable.updateCurrent',
  'unavailable.mergePrNoForge',
  'unavailable.mergePrMissing',
  'unavailable.mergePrDraft',
  'unavailable.mergePrMerged',
  'unavailable.mergePrClosed',
  'unavailable.mergePrConflicts',
  'unavailable.mergePrQueue',
  'unavailable.mergePrNotReady',
  'unavailable.autoMergeCannotDisable',
];

void main() {
  // -------------------------------------------------------------------------
  // narrowPullRequestState — exported upstream but never exercised there
  // -------------------------------------------------------------------------
  group('narrowPullRequestState', () {
    test('keeps the two states the policy understands', () {
      expect(narrowPullRequestState('open'), PullRequestState.open);
      expect(narrowPullRequestState('closed'), PullRequestState.closed);
    });

    test('drops every other forge state rather than guessing', () {
      expect(narrowPullRequestState('merged'), isNull);
      expect(narrowPullRequestState('locked'), isNull);
      expect(narrowPullRequestState(''), isNull);
    });

    test('is case sensitive, matching the raw wire comparison', () {
      expect(narrowPullRequestState('OPEN'), isNull);
      expect(narrowPullRequestState('Closed'), isNull);
    });

    test('maps a missing state to null', () {
      expect(narrowPullRequestState(null), isNull);
    });
  });

  group('PullRequestMergeable.fromWire', () {
    test('reads the three known wire values', () {
      expect(
        PullRequestMergeable.fromWire('MERGEABLE'),
        PullRequestMergeable.mergeable,
      );
      expect(
        PullRequestMergeable.fromWire('CONFLICTING'),
        PullRequestMergeable.conflicting,
      );
      expect(
        PullRequestMergeable.fromWire('UNKNOWN'),
        PullRequestMergeable.unknown,
      );
    });

    test('falls back to unknown, never to conflicting', () {
      expect(
        PullRequestMergeable.fromWire('mergeable'),
        PullRequestMergeable.unknown,
      );
      expect(PullRequestMergeable.fromWire(null), PullRequestMergeable.unknown);
      expect(PullRequestMergeable.fromWire(42), PullRequestMergeable.unknown);
    });
  });

  // -------------------------------------------------------------------------
  // Upstream suite
  // -------------------------------------------------------------------------
  group('buildGitActions (upstream suite)', () {
    test('shows only remote sync actions on the base branch', () {
      final actions = buildGitActions(createInput(hasRemote: true));

      expect(actions.primary, isNull);
      expect(idsOf(actions.secondary), [
        'pull',
        'push',
        'pull-and-push',
        'archive-workspace',
      ]);
    });

    test('prioritizes pull when the branch is behind origin', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, behindOfOrigin: 2),
      );

      expect(actions.primary!.id, GitActionId.pull);
      expect(actions.primary!.label, 'Pull');
    });

    test('keeps push clickable with a clearer message when diverged', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, aheadOfOrigin: 1, behindOfOrigin: 1),
      );
      final push = findAction(actions.secondary, GitActionId.push)!;

      expect(push.disabled, isFalse);
      expect(
        push.unavailableMessage,
        "Push isn't available yet because there are newer changes to bring in first",
      );
    });

    test('keeps push available for a no-upstream Paseo worktree', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          isPaseoOwnedWorktree: true,
          isOnBaseBranch: false,
          aheadCount: 1,
          aheadOfOrigin: null,
          behindOfOrigin: null,
        ),
      );
      final push = findAction(actions.secondary, GitActionId.push)!;

      expect(push.disabled, isFalse);
      expect(push.unavailableMessage, isNull);
      expect(actions.primary!.id, GitActionId.push);
    });

    test('prioritizes push over PR merge when local commits are unpushed', () {
      final actions = buildGitActions(
        openPrInput(aheadOfOrigin: 2, pullRequestGithub: githubStatus()),
      );

      expect(actions.primary!.id, GitActionId.push);
      expect(actions.primary!.label, 'Push');
    });

    test('shows update-from-base only on feature branches behind the base', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, isOnBaseBranch: false, behindBaseCount: 3),
      );
      final update = findAction(actions.secondary, GitActionId.mergeFromBase)!;

      expect(update.label, 'Update from main');
      expect(update.disabled, isFalse);
      expect(update.unavailableMessage, isNull);
    });

    test('uses a clear sentence when pull is unavailable', () {
      final actions = buildGitActions(createInput(hasRemote: true));
      final pull = findAction(actions.secondary, GitActionId.pull)!;

      expect(pull.disabled, isFalse);
      expect(
        pull.unavailableMessage,
        "Pull isn't available because this branch is already up to date",
      );
    });

    test('keeps update-from-base off the base branch entirely', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, behindOfOrigin: 2),
      );

      expect(findAction(actions.secondary, GitActionId.mergeFromBase), isNull);
    });

    test('keeps feature branch actions available off the base branch', () {
      final actions = buildGitActions(
        openPrInput(behindBaseCount: 1, pullRequestGithub: githubStatus()),
      );

      expect(idsOf(actions.secondary), [
        'pull',
        'push',
        'pull-and-push',
        'merge-from-base',
        'merge-branch',
        'pr',
        'merge-pr-squash',
        'merge-pr-merge',
        'merge-pr-rebase',
        'archive-workspace',
      ]);
      expect(findAction(actions.secondary, GitActionId.pr)!.label, 'View PR');
    });

    test('enables pull-and-push with both incoming and outgoing commits', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, aheadOfOrigin: 2, behindOfOrigin: 3),
      );
      final action = findAction(actions.secondary, GitActionId.pullAndPush)!;

      expect(action.label, 'Pull and push');
      expect(action.disabled, isFalse);
      expect(action.unavailableMessage, isNull);
    });

    test('keeps pull-and-push unavailable with only outgoing commits', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, aheadOfOrigin: 2, behindOfOrigin: 0),
      );
      final action = findAction(actions.secondary, GitActionId.pullAndPush)!;

      expect(action.label, 'Pull and push');
      expect(action.unavailableMessage, isA<String>());
    });

    test('keeps pull-and-push unavailable with only incoming commits', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, aheadOfOrigin: 0, behindOfOrigin: 2),
      );
      final action = findAction(actions.secondary, GitActionId.pullAndPush)!;

      expect(action.label, 'Pull and push');
      expect(action.unavailableMessage, isA<String>());
    });

    test('explains pull-and-push when the branch is in sync', () {
      final actions = buildGitActions(createInput(hasRemote: true));
      final action = findAction(actions.secondary, GitActionId.pullAndPush)!;

      expect(action.disabled, isFalse);
      expect(
        action.unavailableMessage,
        "Pull and push isn't available because this branch is already in sync",
      );
    });

    test('explains pull-and-push when there is nothing to pull first', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, aheadOfOrigin: 1, behindOfOrigin: 0),
      );

      expect(
        findAction(
          actions.secondary,
          GitActionId.pullAndPush,
        )!.unavailableMessage,
        "Pull and push isn't available because there are no incoming changes to pull first",
      );
    });

    test('explains pull-and-push when there is nothing to push after', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, aheadOfOrigin: 0, behindOfOrigin: 1),
      );

      expect(
        findAction(
          actions.secondary,
          GitActionId.pullAndPush,
        )!.unavailableMessage,
        "Pull and push isn't available because there is nothing new to send after pulling",
      );
    });

    test('explains pull-and-push when there are uncommitted changes', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          hasUncommittedChanges: true,
          aheadOfOrigin: 1,
        ),
      );

      expect(
        findAction(
          actions.secondary,
          GitActionId.pullAndPush,
        )!.unavailableMessage,
        "Pull and push isn't available while you have local changes so commit or stash them first",
      );
    });

    test('hides Git actions for a non-Git workspace', () {
      final actions = buildGitActions(createInput(isGit: false));

      expect(actions.primary, isNull);
      expect(actions.secondary, isEmpty);
      expect(actions.menu, isEmpty);
    });

    test('offers archive workspace for Git checkouts and worktrees', () {
      final localCheckout = buildGitActions(
        createInput(hasUncommittedChanges: true),
      );
      final worktree = buildGitActions(
        createInput(hasUncommittedChanges: true, isPaseoOwnedWorktree: true),
      );

      expect(
        findAction(localCheckout.secondary, GitActionId.archiveWorkspace),
        isNotNull,
      );
      expect(
        findAction(worktree.secondary, GitActionId.archiveWorkspace),
        isNotNull,
      );
    });

    test('does not promote archive for an idle regular Git checkout', () {
      final actions = buildGitActions(createInput());

      expect(actions.primary, isNull);
      expect(
        findAction(actions.secondary, GitActionId.archiveWorkspace),
        isNotNull,
      );
    });

    test('still promotes archive for an idle Paseo-owned worktree', () {
      final actions = buildGitActions(createInput(isPaseoOwnedWorktree: true));

      expect(actions.primary!.id, GitActionId.archiveWorkspace);
      expect(actions.primary!.label, 'Archive workspace');
    });

    test('promotes squash-and-merge when an open PR is mergeable', () {
      final actions = buildGitActions(
        openPrInput(pullRequestGithub: githubStatus()),
      );

      expect(actions.primary!.id, GitActionId.mergePrSquash);
      expect(actions.primary!.label, 'Merge PR (squash)');
    });

    test('uses GitHub merge state, not mergeable, for direct readiness', () {
      final actions = buildGitActions(
        openPrInput(
          pullRequestMergeable: PullRequestMergeable.unknown,
          pullRequestGithub: githubStatus(mergeStateStatus: 'CLEAN'),
        ),
      );

      expect(actions.primary!.id, GitActionId.mergePrSquash);
      expect(actions.primary!.label, 'Merge PR (squash)');
    });

    test('offers direct PR merge even if the local branch is behind', () {
      final actions = buildGitActions(
        openPrInput(
          behindBaseCount: 3,
          aheadOfOrigin: 0,
          behindOfOrigin: 2,
          pullRequestGithub: githubStatus(mergeStateStatus: 'CLEAN'),
        ),
      );

      for (final id in [
        GitActionId.mergePrSquash,
        GitActionId.mergePrMerge,
        GitActionId.mergePrRebase,
      ]) {
        final action = findAction(actions.secondary, id)!;
        expect(action.disabled, isFalse, reason: id.wireName);
        expect(action.unavailableMessage, isNull, reason: id.wireName);
      }
      // Pull still outranks the merge, because the local checkout is behind.
      expect(actions.primary!.id, GitActionId.pull);
    });

    test('promotes ready PR merge over update-from-base', () {
      final actions = buildGitActions(
        openPrInput(
          behindBaseCount: 3,
          pullRequestGithub: githubStatus(mergeStateStatus: 'CLEAN'),
        ),
      );

      expect(actions.primary!.id, GitActionId.mergePrSquash);
    });

    test('promotes push over Create PR when local commits are unpushed', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          isOnBaseBranch: false,
          aheadCount: 2,
          aheadOfOrigin: 2,
          behindBaseCount: 3,
        ),
      );

      expect(actions.primary!.id, GitActionId.push);
      expect(actions.primary!.label, 'Push');
    });

    test('uses the forge change-request noun in no-forge copy', () {
      final createActions = buildGitActions(
        createInput(
          githubFeaturesEnabled: false,
          forgeBrandLabel: 'GitLab',
          forgeChangeRequestNoun: 'MR',
          hasRemote: true,
          isOnBaseBranch: false,
          aheadCount: 1,
        ),
      );
      final viewActions = buildGitActions(
        createInput(
          githubFeaturesEnabled: false,
          forgeBrandLabel: 'GitLab',
          forgeChangeRequestNoun: 'MR',
          hasRemote: true,
          isOnBaseBranch: false,
          hasPullRequest: true,
          pullRequestUrl: 'https://gitlab.com/example/repo/-/merge_requests/1',
        ),
      );

      expect(
        findAction(createActions.secondary, GitActionId.pr)!.unavailableMessage,
        "Create MR isn't available right now because GitLab isn't connected",
      );
      expect(
        findAction(viewActions.secondary, GitActionId.pr)!.unavailableMessage,
        "View MR isn't available right now because GitLab isn't connected",
      );
      // The forge is disconnected, so nothing is promoted at all.
      expect(viewActions.primary, isNull);
    });

    test('uses local merge when merge is the stored ship default', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          isOnBaseBranch: false,
          aheadCount: 2,
          behindBaseCount: 3,
          shipDefault: ShipDefault.merge,
        ),
      );

      expect(actions.primary!.id, GitActionId.mergeBranch);
      expect(actions.primary!.label, 'Merge locally');
    });

    test('promotes ready PR merge over local merge', () {
      final actions = buildGitActions(
        openPrInput(pullRequestGithub: githubStatus()),
      );

      expect(actions.primary!.id, GitActionId.mergePrSquash);
      expect(findAction(actions.secondary, GitActionId.mergeBranch), isNotNull);
    });

    test('keeps the merge-pr actions in the feature branch menu', () {
      final actions = buildGitActions(
        openPrInput(pullRequestGithub: githubStatus()),
      );

      expect(idsOf(actions.secondary), [
        'pull',
        'push',
        'pull-and-push',
        'merge-from-base',
        'merge-branch',
        'pr',
        'merge-pr-squash',
        'merge-pr-merge',
        'merge-pr-rebase',
        'archive-workspace',
      ]);
    });

    test('keeps the visible PR action model stable on feature branches', () {
      final actions = buildGitActions(
        openPrInput(pullRequestGithub: githubStatus()),
      );
      final rows = actions.secondary
          .where(
            (action) =>
                action.id == GitActionId.pr ||
                mergePrActionIds.contains(action.id.wireName),
          )
          .map(rowOf)
          .toList(growable: false);

      expect(rows, [
        (
          id: 'pr',
          label: 'View PR',
          pendingLabel: 'View PR',
          successLabel: 'View PR',
          disabled: false,
          status: GitActionStatus.idle,
          unavailableMessage: null,
          startsGroup: false,
        ),
        (
          id: 'merge-pr-squash',
          label: 'Merge PR (squash)',
          pendingLabel: 'Merging PR...',
          successLabel: 'PR merged',
          disabled: false,
          status: GitActionStatus.idle,
          unavailableMessage: null,
          startsGroup: true,
        ),
        (
          id: 'merge-pr-merge',
          label: 'Merge PR (merge)',
          pendingLabel: 'Merging PR...',
          successLabel: 'PR merged',
          disabled: false,
          status: GitActionStatus.idle,
          unavailableMessage: null,
          startsGroup: false,
        ),
        (
          id: 'merge-pr-rebase',
          label: 'Merge PR (rebase)',
          pendingLabel: 'Merging PR...',
          successLabel: 'PR merged',
          disabled: false,
          status: GitActionStatus.idle,
          unavailableMessage: null,
          startsGroup: false,
        ),
      ]);
    });

    test('uses Merge locally for the local merge action', () {
      final actions = buildGitActions(
        createInput(isOnBaseBranch: false, aheadCount: 2),
      );

      expect(
        findAction(actions.secondary, GitActionId.mergeBranch)!.label,
        'Merge locally',
      );
      // Ship-default "pr" still wins the promotion even with no remote.
      expect(actions.primary!.id, GitActionId.pr);
      expect(actions.primary!.label, 'Create PR');
    });

    for (final entry in <(String, BuildGitActionsInput)>[
      (
        'draft',
        openPrInput(
          pullRequestIsDraft: true,
          pullRequestGithub: githubStatus(),
        ),
      ),
      (
        'merged',
        openPrInput(
          pullRequestIsMerged: true,
          pullRequestGithub: githubStatus(),
        ),
      ),
      (
        'closed',
        openPrInput(
          pullRequestState: PullRequestState.closed,
          pullRequestGithub: githubStatus(),
        ),
      ),
      (
        'conflicting',
        openPrInput(
          pullRequestMergeable: PullRequestMergeable.conflicting,
          pullRequestGithub: githubStatus(),
        ),
      ),
    ]) {
      test(
        'does not offer direct merge actions when the PR is ${entry.$1}',
        () {
          final actions = buildGitActions(entry.$2);

          expect(
            actions.secondary
                .where(
                  (action) => mergePrActionIds.contains(action.id.wireName),
                )
                .toList(),
            isEmpty,
          );
          final pr = findAction(actions.secondary, GitActionId.pr)!;
          expect(pr.label, 'View PR');
          expect(actions.primary!.id, GitActionId.pr);
        },
      );
    }

    test('preserves legacy direct merge when payloads have no forge facts', () {
      final oldDaemonStatus = CheckoutPrStatus.fromJson(const {
        'number': 456,
        'url': 'https://example.com/pr/456',
        'title': 'Legacy payload',
        'state': 'open',
        'baseRefName': 'main',
        'headRefName': 'feature',
        'isMerged': false,
        'mergeable': 'MERGEABLE',
      });

      expect(oldDaemonStatus.forgeSpecific, isNull);
      expect(oldDaemonStatus.isDraft, isFalse);

      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          isOnBaseBranch: false,
          aheadCount: 2,
          hasPullRequest: true,
          pullRequestUrl: oldDaemonStatus.url,
          pullRequestState: narrowPullRequestState(oldDaemonStatus.state),
          pullRequestIsDraft: oldDaemonStatus.isDraft,
          pullRequestIsMerged: oldDaemonStatus.isMerged,
          pullRequestMergeable: PullRequestMergeable.fromWire(
            oldDaemonStatus.mergeable,
          ),
          pullRequestGithub: oldDaemonStatus.forgeSpecific,
        ),
      );

      expect(actions.primary!.id, GitActionId.mergePrSquash);
      expect(actions.primary!.label, 'Merge PR (squash)');
      expect(idsOf(actions.secondary), [
        'pull',
        'push',
        'pull-and-push',
        'merge-from-base',
        'merge-branch',
        'pr',
        'merge-pr-squash',
        'merge-pr-merge',
        'merge-pr-rebase',
        'archive-workspace',
      ]);
    });

    test("requires GitHub's direct-merge allowlist before promoting", () {
      final actions = buildGitActions(
        openPrInput(
          pullRequestUrl: 'https://example.com/pr/993',
          pullRequestGithub: githubStatus(
            mergeStateStatus: 'BLOCKED',
            viewerCanEnableAutoMerge: true,
            repository: repositoryPolicy(
              mergeCommitAllowed: false,
              rebaseMergeAllowed: false,
            ),
          ),
        ),
      );

      expect(actions.primary!.id, GitActionId.enablePrAutoMergeSquash);
      expect(actions.primary!.label, 'Auto merge (squash)');
      expect(idsOf(actions.secondary), [
        'pull',
        'push',
        'pull-and-push',
        'merge-from-base',
        'merge-branch',
        'pr',
        'enable-pr-auto-merge-squash',
        'archive-workspace',
      ]);
    });

    for (final entry in const <(String, GitActionId, String)>[
      ('SQUASH', GitActionId.enablePrAutoMergeSquash, 'Auto merge (squash)'),
      ('MERGE', GitActionId.enablePrAutoMergeMerge, 'Auto merge (merge)'),
      ('REBASE', GitActionId.enablePrAutoMergeRebase, 'Auto merge (rebase)'),
    ]) {
      test('labels the ${entry.$1} auto-merge action with its method', () {
        final actions = buildGitActions(
          openPrInput(
            pullRequestUrl: 'https://example.com/pr/993',
            pullRequestGithub: githubStatus(
              mergeStateStatus: 'BLOCKED',
              viewerCanEnableAutoMerge: true,
              repository: repositoryPolicy(viewerDefaultMergeMethod: entry.$1),
            ),
          ),
        );

        expect(actions.primary!.id, entry.$2);
        expect(actions.primary!.label, entry.$3);
        // All three remain offered; only the promotion follows the default.
        expect(idsOf(actions.secondary), [
          'pull',
          'push',
          'pull-and-push',
          'merge-from-base',
          'merge-branch',
          'pr',
          'enable-pr-auto-merge-squash',
          'enable-pr-auto-merge-merge',
          'enable-pr-auto-merge-rebase',
          'archive-workspace',
        ]);
      });
    }

    test('does not offer auto-merge when the daemon feature gate is off', () {
      final actions = buildGitActions(
        openPrInput(
          pullRequestUrl: 'https://example.com/pr/993',
          githubAutoMergeActionsEnabled: false,
          pullRequestGithub: githubStatus(
            mergeStateStatus: 'BLOCKED',
            viewerCanEnableAutoMerge: true,
          ),
        ),
      );

      expect(actions.primary!.id, GitActionId.pr);
      expect(actions.primary!.label, 'View PR');
      expect(
        actions.secondary.any(
          (action) => action.id.wireName.startsWith('enable-pr-auto-merge'),
        ),
        isFalse,
      );
    });

    test('shows existing auto-merge as state and disables it when able', () {
      final actions = buildGitActions(
        openPrInput(
          pullRequestGithub: githubStatus(
            autoMergeRequest: const {
              'enabledAt': '2026-05-13T12:00:00Z',
              'mergeMethod': 'SQUASH',
              'enabledBy': 'octocat',
            },
            viewerCanDisableAutoMerge: true,
          ),
        ),
      );

      expect(actions.primary!.id, GitActionId.pr);
      expect(actions.primary!.label, 'View PR');

      final disable = findAction(
        actions.secondary,
        GitActionId.disablePrAutoMerge,
      )!;
      expect(disable.label, 'Auto-merge enabled');
      expect(disable.pendingLabel, 'Disabling auto-merge...');
      expect(disable.successLabel, 'Auto-merge disabled');
      expect(disable.disabled, isFalse);
      expect(disable.unavailableMessage, isNull);
      expect(disable.startsGroup, isTrue);
      expect(
        actions.secondary.any(
          (action) => mergePrActionIds.contains(action.id.wireName),
        ),
        isFalse,
      );
    });

    test('respects repository merge method policy for direct merges', () {
      final actions = buildGitActions(
        openPrInput(
          pullRequestGithub: githubStatus(
            repository: repositoryPolicy(
              squashMergeAllowed: false,
              rebaseMergeAllowed: false,
            ),
          ),
        ),
      );

      expect(actions.primary!.id, GitActionId.mergePrMerge);
      expect(actions.primary!.label, 'Merge PR (merge)');
      expect(idsOf(actions.secondary), [
        'pull',
        'push',
        'pull-and-push',
        'merge-from-base',
        'merge-branch',
        'pr',
        'merge-pr-merge',
        'archive-workspace',
      ]);
    });

    test('does not treat merge queue repositories as direct mergeable', () {
      final actions = buildGitActions(
        openPrInput(
          pullRequestGithub: githubStatus(
            mergeStateStatus: 'CLEAN',
            isMergeQueueEnabled: true,
          ),
        ),
      );

      expect(actions.primary!.id, GitActionId.pr);
      expect(actions.primary!.label, 'View PR');
      expect(
        actions.secondary.any(
          (action) => mergePrActionIds.contains(action.id.wireName),
        ),
        isFalse,
      );
    });

    test('groups merge-pr actions behind their own separator', () {
      final actions = buildGitActions(
        openPrInput(
          pullRequestGithub: githubStatus(),
          isPaseoOwnedWorktree: true,
        ),
      );

      expect(idsOf(actions.secondary.where((a) => a.startsGroup).toList()), [
        'merge-from-base',
        'merge-pr-squash',
        'archive-workspace',
      ]);
      expect(idsOf(actions.secondary.where((a) => !a.startsGroup).toList()), [
        'pull',
        'push',
        'pull-and-push',
        'merge-branch',
        'pr',
        'merge-pr-merge',
        'merge-pr-rebase',
      ]);
    });
  });

  // -------------------------------------------------------------------------
  // Primary precedence ladder (upstream only samples a few rungs)
  // -------------------------------------------------------------------------
  group('primary action precedence', () {
    test('archive promotion outranks uncommitted changes', () {
      final actions = buildGitActions(
        createInput(
          shouldPromoteArchive: true,
          hasUncommittedChanges: true,
          hasRemote: true,
        ),
      );

      expect(actions.primary!.id, GitActionId.archiveWorkspace);
    });

    test('a promoted archive is removed from the dropdown', () {
      final actions = buildGitActions(
        createInput(
          shouldPromoteArchive: true,
          hasUncommittedChanges: true,
          hasRemote: true,
        ),
      );

      expect(idsOf(actions.secondary), ['pull', 'push', 'pull-and-push']);
    });

    test('a promoted archive is removed on feature branches too', () {
      final actions = buildGitActions(
        createInput(
          shouldPromoteArchive: true,
          isOnBaseBranch: false,
          hasRemote: true,
          aheadCount: 2,
        ),
      );

      expect(idsOf(actions.secondary), [
        'pull',
        'push',
        'pull-and-push',
        'merge-from-base',
        'merge-branch',
        'pr',
      ]);
    });

    test('every other promoted action stays listed in the dropdown', () {
      final actions = buildGitActions(
        openPrInput(pullRequestGithub: githubStatus()),
      );

      expect(actions.primary!.id, GitActionId.mergePrSquash);
      expect(
        findAction(actions.secondary, GitActionId.mergePrSquash),
        same(actions.primary),
      );
    });

    test('uncommitted changes outrank pull', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          hasUncommittedChanges: true,
          behindOfOrigin: 3,
        ),
      );

      expect(actions.primary!.id, GitActionId.commit);
      expect(actions.primary!.label, 'Commit');
      expect(actions.primary!.pendingLabel, 'Committing...');
      expect(actions.primary!.successLabel, 'Committed');
      // Commit never carries an unavailable message.
      expect(actions.primary!.unavailableMessage, isNull);
    });

    test('pull outranks a mergeable PR when the checkout is behind', () {
      final actions = buildGitActions(
        openPrInput(
          behindOfOrigin: 2,
          aheadOfOrigin: 0,
          behindBaseCount: 3,
          pullRequestGithub: githubStatus(),
        ),
      );

      expect(actions.primary!.id, GitActionId.pull);
    });

    test('an enabled auto-merge promotes the PR action', () {
      final actions = buildGitActions(
        openPrInput(
          pullRequestGithub: githubStatus(
            autoMergeRequest: const {
              'enabledAt': null,
              'mergeMethod': null,
              'enabledBy': null,
            },
            viewerCanDisableAutoMerge: true,
          ),
        ),
      );

      expect(actions.primary!.id, GitActionId.pr);
    });

    test('an enabled auto-merge promotes the PR even with the gate off', () {
      final actions = buildGitActions(
        openPrInput(
          githubAutoMergeActionsEnabled: false,
          pullRequestGithub: githubStatus(
            autoMergeRequest: const {
              'enabledAt': null,
              'mergeMethod': null,
              'enabledBy': null,
            },
            viewerCanDisableAutoMerge: true,
          ),
        ),
      );

      expect(actions.primary!.id, GitActionId.pr);
      // ...but the disable row is gated away.
      expect(
        findAction(actions.secondary, GitActionId.disablePrAutoMerge),
        isNull,
      );
    });

    test('ship-default pr falls through when the PR has no URL', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          isOnBaseBranch: false,
          aheadCount: 2,
          hasPullRequest: true,
          pullRequestUrl: null,
          pullRequestState: PullRequestState.open,
        ),
      );

      expect(actions.primary!.id, GitActionId.mergeBranch);
      expect(actions.primary!.label, 'Merge locally');
    });

    test('ship-default pr falls through when the branch has no commits', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, isOnBaseBranch: false, aheadCount: 0),
      );

      expect(actions.primary, isNull);
    });

    test('merge-from-base is promoted when nothing is ahead', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          isOnBaseBranch: false,
          aheadCount: 0,
          behindBaseCount: 4,
        ),
      );

      expect(actions.primary!.id, GitActionId.mergeFromBase);
      expect(actions.primary!.label, 'Update from main');
    });

    test('an existing PR is the last resort before the archive fallback', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          isOnBaseBranch: true,
          hasPullRequest: true,
          pullRequestUrl: 'https://example.com/pr/7',
          pullRequestState: PullRequestState.open,
        ),
      );

      expect(actions.primary!.id, GitActionId.pr);
      expect(actions.primary!.label, 'View PR');
      // On the base branch the PR action is promoted but never listed.
      expect(idsOf(actions.secondary), [
        'pull',
        'push',
        'pull-and-push',
        'archive-workspace',
      ]);
    });

    test('a plain checkout with nothing to do promotes nothing', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, isPaseoOwnedWorktree: false),
      );

      expect(actions.primary, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Push / pull tracking edge cases (null upstream)
  // -------------------------------------------------------------------------
  group('upstream tracking', () {
    test('a non-worktree with no upstream cannot push', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          isOnBaseBranch: false,
          aheadCount: 3,
          aheadOfOrigin: null,
          behindOfOrigin: null,
        ),
      );
      final push = findAction(actions.secondary, GitActionId.push)!;

      expect(
        push.unavailableMessage,
        "Push isn't available because there is nothing new to send",
      );
      expect(actions.primary!.id, GitActionId.pr);
    });

    test('a worktree with no upstream and no commits cannot push', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          isPaseoOwnedWorktree: true,
          isOnBaseBranch: false,
          aheadCount: 0,
          aheadOfOrigin: null,
          behindOfOrigin: null,
        ),
      );

      expect(
        findAction(actions.secondary, GitActionId.push)!.unavailableMessage,
        "Push isn't available because there is nothing new to send",
      );
      expect(actions.primary!.id, GitActionId.archiveWorkspace);
    });

    test('a null behind count still reads as "no remote" for pull', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, aheadOfOrigin: 1, behindOfOrigin: null),
      );

      expect(
        findAction(actions.secondary, GitActionId.pull)!.unavailableMessage,
        "Pull isn't available here because this branch is not connected to a remote yet",
      );
      // ...while push, which only guards on `behind > 0`, is available.
      expect(actions.primary!.id, GitActionId.push);
    });

    test('a null behind count blocks pull-and-push as "no incoming"', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, aheadOfOrigin: 1, behindOfOrigin: null),
      );

      expect(
        findAction(
          actions.secondary,
          GitActionId.pullAndPush,
        )!.unavailableMessage,
        "Pull and push isn't available because there are no incoming changes to pull first",
      );
    });

    test('a null ahead count with incoming commits blocks the push half', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, aheadOfOrigin: null, behindOfOrigin: 2),
      );

      expect(
        findAction(
          actions.secondary,
          GitActionId.pullAndPush,
        )!.unavailableMessage,
        "Pull and push isn't available because there is nothing new to send after pulling",
      );
      expect(actions.primary!.id, GitActionId.pull);
    });
  });

  // -------------------------------------------------------------------------
  // Unavailable copy — every arm
  // -------------------------------------------------------------------------
  group('unavailable copy', () {
    test('no remote explains all three sync actions', () {
      final actions = buildGitActions(createInput(hasRemote: false));

      expect(
        findAction(actions.secondary, GitActionId.pull)!.unavailableMessage,
        "Pull isn't available here because this branch is not connected to a remote yet",
      );
      expect(
        findAction(actions.secondary, GitActionId.push)!.unavailableMessage,
        "Push isn't available here because this branch is not connected to a remote yet",
      );
      expect(
        findAction(
          actions.secondary,
          GitActionId.pullAndPush,
        )!.unavailableMessage,
        "Pull and push isn't available here because this branch is not connected to a remote yet",
      );
    });

    test('a dirty tree explains pull and pull-and-push, but not push', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          hasUncommittedChanges: true,
          behindOfOrigin: 2,
          aheadOfOrigin: 1,
        ),
      );

      expect(
        findAction(actions.secondary, GitActionId.pull)!.unavailableMessage,
        "Pull isn't available while you have local changes so commit or stash them first",
      );
      expect(
        findAction(
          actions.secondary,
          GitActionId.pullAndPush,
        )!.unavailableMessage,
        "Pull and push isn't available while you have local changes so commit or stash them first",
      );
      // Push does not care about the working tree, only about being behind.
      expect(
        findAction(actions.secondary, GitActionId.push)!.unavailableMessage,
        "Push isn't available yet because there are newer changes to bring in first",
      );
    });

    test('an unavailable base ref explains merge and update', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          isOnBaseBranch: false,
          baseRefAvailable: false,
          behindBaseCount: 4,
          aheadCount: 1,
        ),
      );

      expect(
        findAction(
          actions.secondary,
          GitActionId.mergeFromBase,
        )!.unavailableMessage,
        "Update isn't available because we couldn't determine the base branch",
      );
      expect(
        findAction(
          actions.secondary,
          GitActionId.mergeBranch,
        )!.unavailableMessage,
        "Merge isn't available because we couldn't determine the base branch",
      );
    });

    test('a dirty tree explains merge and update before their counts', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          isOnBaseBranch: false,
          hasUncommittedChanges: true,
          behindBaseCount: 4,
          aheadCount: 4,
        ),
      );

      expect(
        findAction(
          actions.secondary,
          GitActionId.mergeFromBase,
        )!.unavailableMessage,
        "Update isn't available while you have local changes so commit or stash them first",
      );
      expect(
        findAction(
          actions.secondary,
          GitActionId.mergeBranch,
        )!.unavailableMessage,
        "Merge isn't available while you have local changes so commit or stash them first",
      );
    });

    test('an up-to-date branch names the base ref in the update copy', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          isOnBaseBranch: false,
          baseRefLabel: 'develop',
          behindBaseCount: 0,
        ),
      );

      expect(
        findAction(actions.secondary, GitActionId.mergeFromBase)!.label,
        'Update from develop',
      );
      expect(
        findAction(
          actions.secondary,
          GitActionId.mergeFromBase,
        )!.unavailableMessage,
        "Update isn't available because this branch is already up to date with develop",
      );
    });

    test('a branch with no commits explains merge and create-PR', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, isOnBaseBranch: false, aheadCount: 0),
      );

      expect(
        findAction(
          actions.secondary,
          GitActionId.mergeBranch,
        )!.unavailableMessage,
        "Merge isn't available because this branch doesn't have anything new to merge yet",
      );
      expect(
        findAction(actions.secondary, GitActionId.pr)!.unavailableMessage,
        "Create PR isn't available because this branch doesn't have any new commits yet",
      );
    });

    test('a disconnected forge outranks the no-commits create-PR copy', () {
      final actions = buildGitActions(
        createInput(
          githubFeaturesEnabled: false,
          hasRemote: true,
          isOnBaseBranch: false,
          aheadCount: 0,
        ),
      );

      expect(
        findAction(actions.secondary, GitActionId.pr)!.unavailableMessage,
        "Create PR isn't available right now because GitHub isn't connected",
      );
    });

    test('a connected forge leaves the view-PR action unexplained', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          isOnBaseBranch: false,
          hasPullRequest: true,
          pullRequestUrl: 'https://example.com/pr/1',
        ),
      );

      expect(
        findAction(actions.secondary, GitActionId.pr)!.unavailableMessage,
        isNull,
      );
    });

    test('archive and commit never carry an unavailable message', () {
      final actions = buildGitActions(
        createInput(hasRemote: false, hasUncommittedChanges: true),
      );

      expect(actions.primary!.id, GitActionId.commit);
      expect(actions.primary!.unavailableMessage, isNull);
      expect(
        findAction(
          actions.secondary,
          GitActionId.archiveWorkspace,
        )!.unavailableMessage,
        isNull,
      );
    });

    test('an auto-merge the viewer cannot disable is explained', () {
      final actions = buildGitActions(
        openPrInput(
          pullRequestGithub: githubStatus(
            autoMergeRequest: const {
              'enabledAt': '2026-05-13T12:00:00Z',
              'mergeMethod': 'SQUASH',
              'enabledBy': 'octocat',
            },
          ),
        ),
      );
      final disable = findAction(
        actions.secondary,
        GitActionId.disablePrAutoMerge,
      )!;

      expect(disable.disabled, isTrue);
      expect(
        disable.unavailableMessage,
        "Auto-merge is enabled, but this account can't disable it",
      );
    });
  });

  // -------------------------------------------------------------------------
  // Merge capability edges
  // -------------------------------------------------------------------------
  group('merge capability', () {
    test('HAS_HOOKS counts as direct-merge ready', () {
      final actions = buildGitActions(
        openPrInput(
          pullRequestGithub: githubStatus(mergeStateStatus: 'HAS_HOOKS'),
        ),
      );

      expect(actions.primary!.id, GitActionId.mergePrSquash);
    });

    test('a repository allowing no merge method offers none', () {
      final actions = buildGitActions(
        openPrInput(
          pullRequestGithub: githubStatus(
            repository: repositoryPolicy(
              mergeCommitAllowed: false,
              squashMergeAllowed: false,
              rebaseMergeAllowed: false,
            ),
          ),
        ),
      );

      expect(actions.primary!.id, GitActionId.pr);
      expect(
        actions.secondary.any(
          (action) => mergePrActionIds.contains(action.id.wireName),
        ),
        isFalse,
      );
    });

    test('a disallowed preferred method falls back to the first allowed', () {
      final actions = buildGitActions(
        openPrInput(
          pullRequestGithub: githubStatus(
            repository: repositoryPolicy(squashMergeAllowed: false),
          ),
        ),
      );

      expect(actions.primary!.id, GitActionId.mergePrMerge);
      expect(idsOf(actions.secondary), [
        'pull',
        'push',
        'pull-and-push',
        'merge-from-base',
        'merge-branch',
        'pr',
        'merge-pr-merge',
        'merge-pr-rebase',
        'archive-workspace',
      ]);
    });

    test('a PR already in the merge queue is not direct-mergeable', () {
      final actions = buildGitActions(
        openPrInput(pullRequestGithub: githubStatus(isInMergeQueue: true)),
      );

      expect(actions.primary!.id, GitActionId.pr);
      expect(
        actions.secondary.any(
          (action) => mergePrActionIds.contains(action.id.wireName),
        ),
        isFalse,
      );
    });

    test('BLOCKED without permission offers neither merge nor auto-merge', () {
      final actions = buildGitActions(
        openPrInput(
          pullRequestGithub: githubStatus(mergeStateStatus: 'BLOCKED'),
        ),
      );

      expect(actions.primary!.id, GitActionId.pr);
      expect(idsOf(actions.secondary), [
        'pull',
        'push',
        'pull-and-push',
        'merge-from-base',
        'merge-branch',
        'pr',
        'archive-workspace',
      ]);
    });

    test('uncommitted changes block direct merge outright', () {
      final actions = buildGitActions(
        openPrInput(
          hasUncommittedChanges: true,
          pullRequestGithub: githubStatus(),
        ),
      );

      expect(actions.primary!.id, GitActionId.commit);
      expect(
        actions.secondary.any(
          (action) => mergePrActionIds.contains(action.id.wireName),
        ),
        isFalse,
      );
    });

    test('a null capability demands an exactly in-sync branch', () {
      final inSync = buildGitActions(openPrInput());
      final behindBase = buildGitActions(openPrInput(behindBaseCount: 2));

      expect(inSync.primary!.id, GitActionId.mergePrSquash);
      // behindBaseCount > 0 makes canMergeFromBase true, which the raw-git
      // fallback treats as "not safe to merge yet".
      expect(behindBase.primary!.id, GitActionId.pr);
      expect(
        behindBase.secondary.any(
          (action) => mergePrActionIds.contains(action.id.wireName),
        ),
        isFalse,
      );
    });

    test('a null capability requires an explicitly MERGEABLE PR', () {
      final actions = buildGitActions(
        openPrInput(pullRequestMergeable: PullRequestMergeable.unknown),
      );

      expect(actions.primary!.id, GitActionId.pr);
    });

    test('a null capability rejects an unknown upstream position', () {
      final actions = buildGitActions(openPrInput(aheadOfOrigin: null));

      // aheadOfOrigin === 0 is a strict check upstream, so null fails it; push
      // is not possible either (non-worktree), so the PR action is promoted.
      expect(actions.primary!.id, GitActionId.pr);
    });

    test('a null capability leaves every merge method on offer', () {
      final actions = buildGitActions(openPrInput());

      expect(idsOf(actions.secondary), [
        'pull',
        'push',
        'pull-and-push',
        'merge-from-base',
        'merge-branch',
        'pr',
        'merge-pr-squash',
        'merge-pr-merge',
        'merge-pr-rebase',
        'archive-workspace',
      ]);
    });

    test('a disconnected forge hides every change-request merge action', () {
      final actions = buildGitActions(
        openPrInput(
          githubFeaturesEnabled: false,
          pullRequestGithub: githubStatus(),
        ),
      );

      expect(idsOf(actions.secondary), [
        'pull',
        'push',
        'pull-and-push',
        'merge-from-base',
        'merge-branch',
        'pr',
        'archive-workspace',
      ]);
    });
  });

  // -------------------------------------------------------------------------
  // Runtime pass-through
  // -------------------------------------------------------------------------
  group('runtime state', () {
    test('a disabled runtime suppresses the unavailable message', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          runtimeOverrides: {
            GitActionId.pull: GitActionRuntimeState(
              handler: () {},
              disabled: true,
              status: GitActionStatus.pending,
            ),
          },
        ),
      );
      final pull = findAction(actions.secondary, GitActionId.pull)!;

      expect(pull.disabled, isTrue);
      expect(pull.status, GitActionStatus.pending);
      expect(pull.unavailableMessage, isNull);
    });

    test('a disabled runtime suppresses every action message', () {
      final disabled = GitActionRuntimeState(handler: () {}, disabled: true);
      final actions = buildGitActions(
        openPrInput(
          pullRequestGithub: githubStatus(),
          runtimeOverrides: {for (final id in GitActionId.values) id: disabled},
        ),
      );

      for (final action in actions.secondary) {
        expect(action.disabled, isTrue, reason: action.id.wireName);
        expect(action.unavailableMessage, isNull, reason: action.id.wireName);
      }
    });

    test('status is carried through per action', () {
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          runtimeOverrides: {
            GitActionId.push: GitActionRuntimeState(
              handler: () {},
              status: GitActionStatus.success,
            ),
          },
        ),
      );

      expect(
        findAction(actions.secondary, GitActionId.push)!.status,
        GitActionStatus.success,
      );
      expect(
        findAction(actions.secondary, GitActionId.pull)!.status,
        GitActionStatus.idle,
      );
    });

    test('the icon is passed through untouched', () {
      const icon = Object();
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          runtimeOverrides: {
            GitActionId.pull: GitActionRuntimeState(handler: () {}, icon: icon),
          },
        ),
      );

      expect(findAction(actions.secondary, GitActionId.pull)!.icon, same(icon));
      expect(findAction(actions.secondary, GitActionId.push)!.icon, isNull);
    });

    test('each action keeps its own handler', () {
      final fired = <String>[];
      final actions = buildGitActions(
        createInput(
          hasRemote: true,
          runtimeOverrides: {
            for (final id in GitActionId.values)
              id: GitActionRuntimeState(handler: () => fired.add(id.wireName)),
          },
        ),
      );

      for (final action in actions.secondary) {
        action.handler();
      }

      expect(fired, ['pull', 'push', 'pull-and-push', 'archive-workspace']);
    });

    test('a policy-disabled action still keeps a runtime status', () {
      final actions = buildGitActions(
        openPrInput(
          pullRequestGithub: githubStatus(
            autoMergeRequest: const {
              'enabledAt': null,
              'mergeMethod': null,
              'enabledBy': null,
            },
          ),
          runtimeOverrides: {
            GitActionId.disablePrAutoMerge: GitActionRuntimeState(
              handler: () {},
              status: GitActionStatus.pending,
            ),
          },
        ),
      );
      final disable = findAction(
        actions.secondary,
        GitActionId.disablePrAutoMerge,
      )!;

      expect(disable.disabled, isTrue);
      expect(disable.status, GitActionStatus.pending);
    });

    test('an incomplete runtime map is a wiring error, not a silent no-op', () {
      final input = BuildGitActionsInput(
        isGit: true,
        githubFeaturesEnabled: true,
        forgeBrandLabel: 'GitHub',
        forgeChangeRequestNoun: 'PR',
        githubAutoMergeActionsEnabled: true,
        hasPullRequest: false,
        pullRequestUrl: null,
        pullRequestState: null,
        pullRequestIsDraft: false,
        pullRequestIsMerged: false,
        pullRequestMergeable: PullRequestMergeable.unknown,
        mergeCapability: null,
        hasRemote: false,
        isPaseoOwnedWorktree: false,
        isOnBaseBranch: true,
        hasUncommittedChanges: false,
        baseRefAvailable: true,
        baseRefLabel: 'main',
        aheadCount: 0,
        behindBaseCount: 0,
        aheadOfOrigin: 0,
        behindOfOrigin: 0,
        shouldPromoteArchive: false,
        shipDefault: ShipDefault.pr,
        runtime: const {},
      );

      expect(() => buildGitActions(input), throwsArgumentError);
    });

    test('idleGitActionRuntime covers every id and honours overrides', () {
      final custom = GitActionRuntimeState(handler: () {}, disabled: true);
      final runtime = idleGitActionRuntime(
        handler: () {},
        overrides: {GitActionId.commit: custom},
      );

      expect(runtime.length, GitActionId.values.length);
      expect(runtime[GitActionId.commit], same(custom));
      expect(runtime[GitActionId.pull]!.disabled, isFalse);
      expect(runtime[GitActionId.pull]!.status, GitActionStatus.idle);
    });
  });

  // -------------------------------------------------------------------------
  // Copy binding
  // -------------------------------------------------------------------------
  group('copy', () {
    test('the vendored English copy matches the shipped asset', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final asset = GitActionsLabels.fromTranslations(
        await Translations.load(SupportedLocale.en),
      );

      for (final key in policyCopyKeys) {
        expect(
          defaultGitActionsLabels.t(key),
          asset.t(key),
          reason: 'workspace.git.actions.$key drifted from assets/i18n/en.json',
        );
      }
    });

    test(
      'uses the active language for labels and unavailable messages',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        final labels = GitActionsLabels.fromTranslations(
          await Translations.load(SupportedLocale.zhCN),
        );
        final actions = buildGitActions(
          createInput(
            hasRemote: true,
            behindOfOrigin: 1,
            isOnBaseBranch: false,
            aheadCount: 0,
          ),
          labels: labels,
        );

        expect(actions.primary!.id, GitActionId.pull);
        expect(actions.primary!.label, 'Pull');
        expect(actions.primary!.pendingLabel, '正在 pull...');
        expect(actions.primary!.successLabel, '已 pull');

        final pr = findAction(actions.secondary, GitActionId.pr)!;
        expect(pr.label, '创建 PR');
        expect(pr.unavailableMessage, '无法创建 PR，因为此分支还没有新的 commit');
      },
    );

    test('interpolates the base ref into the translated update copy', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final labels = GitActionsLabels.fromTranslations(
        await Translations.load(SupportedLocale.zhCN),
      );
      final actions = buildGitActions(
        createInput(hasRemote: true, isOnBaseBranch: false),
        labels: labels,
      );
      final update = findAction(actions.secondary, GitActionId.mergeFromBase)!;

      expect(update.label, '从 main 更新');
      expect(update.unavailableMessage, '无法更新，因为此分支已与 main 保持最新');
    });

    test('translates the change-request labels too', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final labels = GitActionsLabels.fromTranslations(
        await Translations.load(SupportedLocale.zhCN),
      );
      final actions = buildGitActions(
        openPrInput(pullRequestGithub: githubStatus()),
        labels: labels,
      );

      expect(actions.primary!.label, 'Merge PR (squash)');
      expect(actions.primary!.pendingLabel, '正在 merge PR...');
      expect(actions.primary!.successLabel, 'PR 已 merge');
      expect(findAction(actions.secondary, GitActionId.pr)!.label, '查看 PR');
    });

    test('falls back to English for a key the locale is missing', () {
      final labels = GitActionsLabels.fromTranslations(
        Translations.fromTables(
          TranslationTable.fromJson(SupportedLocale.zhCN, const {
            'workspace': {
              'git': {
                'actions': {
                  'pull': {'label': '拉取'},
                },
              },
            },
          }),
          TranslationTable.fromJson(SupportedLocale.en, const {
            'workspace': {
              'git': {
                'actions': {
                  'pull': {'pending': 'Pulling...', 'success': 'Pulled'},
                },
              },
            },
          }),
        ),
      );
      final actions = buildGitActions(
        createInput(hasRemote: true, behindOfOrigin: 1),
        labels: labels,
      );

      expect(actions.primary!.label, '拉取');
      expect(actions.primary!.pendingLabel, 'Pulling...');
    });

    test('a missing key surfaces as the key, never as a blank label', () {
      final labels = GitActionsLabels.fromTranslations(
        Translations.fromTables(
          TranslationTable.fromJson(SupportedLocale.en, const {}),
        ),
      );
      final actions = buildGitActions(
        createInput(hasRemote: true, behindOfOrigin: 1),
        labels: labels,
      );

      expect(actions.primary!.label, 'workspace.git.actions.pull.label');
    });
  });

  // -------------------------------------------------------------------------
  // Structural guarantees
  // -------------------------------------------------------------------------
  group('structure', () {
    test('the menu slot is always empty', () {
      for (final actions in [
        buildGitActions(createInput()),
        buildGitActions(createInput(isGit: false)),
        buildGitActions(openPrInput(pullRequestGithub: githubStatus())),
      ]) {
        expect(actions.menu, isEmpty);
      }
    });

    test('every action id has a stable wire name', () {
      expect(GitActionId.values.map((id) => id.wireName).toList(), [
        'commit',
        'pull',
        'push',
        'pull-and-push',
        'pr',
        'merge-pr-squash',
        'merge-pr-merge',
        'merge-pr-rebase',
        'enable-pr-auto-merge-squash',
        'enable-pr-auto-merge-merge',
        'enable-pr-auto-merge-rebase',
        'disable-pr-auto-merge',
        'merge-branch',
        'merge-from-base',
        'archive-workspace',
      ]);
    });

    test('commit is never listed in the dropdown', () {
      final actions = buildGitActions(
        openPrInput(
          hasUncommittedChanges: true,
          pullRequestGithub: githubStatus(),
        ),
      );

      expect(actions.primary!.id, GitActionId.commit);
      expect(findAction(actions.secondary, GitActionId.commit), isNull);
    });

    test('the separator groups are stable on a plain feature branch', () {
      final actions = buildGitActions(
        createInput(hasRemote: true, isOnBaseBranch: false, aheadCount: 1),
      );

      expect(idsOf(actions.secondary.where((a) => a.startsGroup).toList()), [
        'merge-from-base',
        'archive-workspace',
      ]);
    });
  });
}
