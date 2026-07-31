/// Port of Paseo 0.2.0's `git/policy.ts` — the single place that decides
/// *which* git action a workspace offers, in what order, whether it is
/// clickable, and what to say when it is not.
///
/// Everything else in the git UI (the split button, the action menu, the
/// mutation hooks) reads this module's answer rather than re-deriving it, which
/// is why the whole thing is a pure function of one input record: given the same
/// git/forge facts you always get the same buttons, and the policy can be
/// exercised without a widget tree, a socket, or a clock.
///
/// The shape of the answer is deliberately narrow:
///
///  - [GitActions.primary] is the one call-to-action promoted onto the button
///    itself. [_GitActionsBuilder._primaryActionId] is a strict precedence
///    ladder, not a score: the first rung that matches wins, so "you have
///    uncommitted changes" always outranks "your PR is mergeable".
///  - [GitActions.secondary] is the dropdown, in frozen order: the three remote
///    sync actions, then (only off the base branch) the feature-branch actions,
///    then archive.
///  - [GitActions.menu] is always empty. Upstream still returns the field
///    because its consumers destructure it; it is kept so a later upstream
///    revision that repopulates it is a one-line diff here.
///
/// ## What is reused rather than re-declared
///
///  - [ForgeMergeCapability] and the whole per-forge derivation of it come from
///    `core/forge_logic.dart`. This module only *reads* the neutral capability;
///    it never looks at GitHub/GitLab/Gitea facts directly, exactly as upstream
///    splits `policy.ts` from `merge-capability.ts`.
///  - [CheckoutPrMergeMethod] is the protocol enum from `package:agent_protocol`.
///  - The copy is read through `i18n/translations.dart`, the same translator
///    `git/paseo_pr_rules.dart` uses.
///
/// ## Deviations from the TypeScript, and why
///
///  - Upstream reads the i18next singleton at call time. Dart has no such
///    singleton, so the copy is injected as [GitActionsLabels] and defaults to
///    [defaultGitActionsLabels] (the frozen English strings). Because the labels
///    are resolved *during* [buildGitActions], a host that rebuilds its actions
///    on a language change gets the new language, matching upstream.
///  - `unavailableMessage?: string` becomes a nullable field: TypeScript's
///    `undefined` and Dart's `null` are the same "nothing to say here" signal,
///    and upstream never distinguishes absent from explicitly-undefined.
///  - `Record<GitActionId, GitActionRuntimeState>` becomes a plain [Map]. The
///    TypeScript type forces every id to be present; Dart cannot, so
///    [BuildGitActionsInput.runtimeFor] throws on a missing id rather than
///    silently substituting a default — the same crash upstream would take on
///    `input.runtime[id].disabled`.
///  - `Array.prototype.filter`/`map` preserve order in both languages and this
///    module never sorts, so no stability tiebreak is needed anywhere.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../core/forge_logic.dart';
import '../i18n/locales.dart';
import '../i18n/translations.dart';

// ---------------------------------------------------------------------------
// Identifiers and small wire enums
// ---------------------------------------------------------------------------

/// Every action the git policy can produce.
///
/// [wireName] is the kebab-case id upstream uses as the union member; it is the
/// value hosts key telemetry, test expectations and per-action runtime state
/// on, so it stays stable independently of the Dart enum name.
enum GitActionId {
  commit('commit'),
  pull('pull'),
  push('push'),
  pullAndPush('pull-and-push'),
  pr('pr'),
  mergePrSquash('merge-pr-squash'),
  mergePrMerge('merge-pr-merge'),
  mergePrRebase('merge-pr-rebase'),
  enablePrAutoMergeSquash('enable-pr-auto-merge-squash'),
  enablePrAutoMergeMerge('enable-pr-auto-merge-merge'),
  enablePrAutoMergeRebase('enable-pr-auto-merge-rebase'),
  disablePrAutoMerge('disable-pr-auto-merge'),
  mergeBranch('merge-branch'),
  mergeFromBase('merge-from-base'),
  archiveWorkspace('archive-workspace');

  const GitActionId(this.wireName);

  /// The frozen upstream id string.
  final String wireName;
}

/// Upstream's `ActionStatus` (`components/ui/dropdown-menu`): where a triggered
/// action currently is in its mutation lifecycle.
///
/// Declared here rather than imported because the dropdown component is a view
/// concern outside this cluster, and the policy only ever passes the value
/// through from [GitActionRuntimeState] to [GitAction] — it never branches on
/// it. Naming it `GitActionStatus` keeps the git-scoped meaning obvious next to
/// the app's other, unrelated status enums.
enum GitActionStatus { idle, pending, success }

/// The two change-request states the policy is willing to reason about.
///
/// A forge can report far more (`merged`, `locked`, vendor-specific values);
/// [narrowPullRequestState] collapses everything else to null precisely so that
/// downstream rules never have to guess what an unfamiliar state means.
enum PullRequestState { open, closed }

/// Upstream's `PullRequestMergeable` protocol union.
///
/// The Dart protocol keeps `CheckoutPrStatus.mergeable` as a normalized
/// `String` rather than an enum, so this is declared locally; [fromWire]
/// reproduces the wire schema's `.catch("UNKNOWN")` so an unrecognized value
/// reads as "we don't know", never as "conflicting".
enum PullRequestMergeable {
  mergeable('MERGEABLE'),
  conflicting('CONFLICTING'),
  unknown('UNKNOWN');

  const PullRequestMergeable(this.wireName);

  final String wireName;

  static PullRequestMergeable fromWire(Object? value) => switch (value) {
    'MERGEABLE' => mergeable,
    'CONFLICTING' => conflicting,
    _ => unknown,
  };
}

/// The user's stored preference for how a finished branch ships.
enum ShipDefault { merge, pr }

/// Narrows a forge's raw change-request state string to the closed set the
/// policy understands, or null when it is anything else.
///
/// Deliberately *not* a `fromWire` on [PullRequestState]: the null return is
/// load-bearing policy ("treat this like there is no usable state") rather than
/// a parse failure, and upstream exports it as a standalone helper that callers
/// apply at the daemon boundary.
PullRequestState? narrowPullRequestState(String? state) {
  if (state == 'open') return PullRequestState.open;
  if (state == 'closed') return PullRequestState.closed;
  return null;
}

// ---------------------------------------------------------------------------
// Copy
// ---------------------------------------------------------------------------

/// Resolves one `workspace.git.actions.*` key, interpolating `{{name}}`
/// placeholders from [args].
typedef GitActionsTranslator =
    String Function(String key, Map<String, Object?>? args);

/// The copy [buildGitActions] reads, injected so the policy stays pure and
/// locale-independent.
///
/// This is a thin key-based wrapper rather than ~50 named fields on purpose:
/// the keys stay written out at the same call sites upstream writes them, so a
/// future upstream copy change is a literal one-line diff here instead of a
/// rename across two files.
final class GitActionsLabels {
  const GitActionsLabels(this._translate);

  /// Binds the labels to a live translator. The `workspace.git.actions.` prefix
  /// is applied here so call sites read like their upstream counterparts.
  factory GitActionsLabels.fromTranslations(Translations translations) =>
      GitActionsLabels(
        (key, args) => translations.t('workspace.git.actions.$key', args: args),
      );

  final GitActionsTranslator _translate;

  /// Resolves [key] relative to `workspace.git.actions`.
  String t(String key, [Map<String, Object?>? args]) => _translate(key, args);
}

/// The frozen English `workspace.git.actions` subtree this module reads.
///
/// Mirrors `assets/i18n/en.json`; kept as literals so the policy is usable (and
/// testable) without the asset bundle, exactly as
/// `defaultWorktreeArchiveWarningLabels` is in `paseo_pr_rules.dart`. Only the
/// keys `policy.ts` actually reads are vendored — toasts, the archive-warning
/// subtree and the `_mr` context variants belong to other modules.
const Map<String, Object?> _frozenEnglishGitActions = {
  'workspace': {
    'git': {
      'actions': {
        'commit': {
          'label': 'Commit',
          'pending': 'Committing...',
          'success': 'Committed',
        },
        'pull': {'label': 'Pull', 'pending': 'Pulling...', 'success': 'Pulled'},
        'push': {'label': 'Push', 'pending': 'Pushing...', 'success': 'Pushed'},
        'pullAndPush': {
          'label': 'Pull and push',
          'pending': 'Pulling and pushing...',
          'success': 'Pulled and pushed',
        },
        'viewPr': 'View PR',
        'createPr': {
          'label': 'Create PR',
          'pending': 'Creating PR...',
          'success': 'PR Created',
        },
        'mergeBranch': {
          'label': 'Merge locally',
          'pending': 'Merging...',
          'success': 'Merged',
        },
        'mergeFromBase': {
          'label': 'Update from {{baseRef}}',
          'pending': 'Updating...',
          'success': 'Updated',
        },
        'archive': {
          'label': 'Archive workspace',
          'pending': 'Archiving...',
          'success': 'Archived',
        },
        'mergePr': {
          'squash': 'Merge PR (squash)',
          'merge': 'Merge PR (merge)',
          'rebase': 'Merge PR (rebase)',
          'pending': 'Merging PR...',
          'success': 'PR merged',
        },
        'autoMerge': {
          'enableSquash': 'Auto merge (squash)',
          'enableMerge': 'Auto merge (merge)',
          'enableRebase': 'Auto merge (rebase)',
          'enabled': 'Auto-merge enabled',
          'enabling': 'Enabling auto-merge...',
          'disabling': 'Disabling auto-merge...',
          'disabled': 'Auto-merge disabled',
        },
        'unavailable': {
          'viewPrNoForge':
              "View {{noun}} isn't available right now because {{brand}} isn't connected",
          'pullNoRemote':
              "Pull isn't available here because this branch is not connected to a remote yet",
          'pullDirty':
              "Pull isn't available while you have local changes so commit or stash them first",
          'pullUpToDate':
              "Pull isn't available because this branch is already up to date",
          'pushNoRemote':
              "Push isn't available here because this branch is not connected to a remote yet",
          'pushBehind':
              "Push isn't available yet because there are newer changes to bring in first",
          'pushNothing':
              "Push isn't available because there is nothing new to send",
          'pullAndPushNoRemote':
              "Pull and push isn't available here because this branch is not connected to a remote yet",
          'pullAndPushDirty':
              "Pull and push isn't available while you have local changes so commit or stash them first",
          'pullAndPushNoIncoming':
              "Pull and push isn't available because there are no incoming changes to pull first",
          'pullAndPushInSync':
              "Pull and push isn't available because this branch is already in sync",
          'pullAndPushNothingToPush':
              "Pull and push isn't available because there is nothing new to send after pulling",
          'createPrNoForge':
              "Create {{noun}} isn't available right now because {{brand}} isn't connected",
          'createPrNoCommits':
              "Create PR isn't available because this branch doesn't have any new commits yet",
          'mergeNoBase':
              "Merge isn't available because we couldn't determine the base branch",
          'mergeDirty':
              "Merge isn't available while you have local changes so commit or stash them first",
          'mergeNothing':
              "Merge isn't available because this branch doesn't have anything new to merge yet",
          'updateNoBase':
              "Update isn't available because we couldn't determine the base branch",
          'updateDirty':
              "Update isn't available while you have local changes so commit or stash them first",
          'updateCurrent':
              "Update isn't available because this branch is already up to date with {{baseRef}}",
          'mergePrNoForge':
              "Merge {{noun}} isn't available right now because {{brand}} isn't connected",
          'mergePrMissing':
              "Merge PR isn't available because there isn't a pull request yet",
          'mergePrDraft':
              "Merge PR isn't available because the pull request is still a draft",
          'mergePrMerged':
              "Merge PR isn't available because the pull request is already merged",
          'mergePrClosed':
              "Merge PR isn't available because the pull request is closed",
          'mergePrConflicts':
              "Merge PR isn't available because the pull request has conflicts",
          'mergePrQueue':
              "Merge PR isn't available here because this repository uses a merge queue",
          'mergePrNotReady':
              "Merge {{noun}} isn't available until {{brand}} reports the {{noun}} is ready to merge",
          'autoMergeCannotDisable':
              "Auto-merge is enabled, but this account can't disable it",
        },
      },
    },
  },
};

/// The English copy [buildGitActions] falls back to when no translator is
/// supplied.
final GitActionsLabels defaultGitActionsLabels =
    GitActionsLabels.fromTranslations(
      Translations.fromTables(
        TranslationTable.fromJson(SupportedLocale.en, _frozenEnglishGitActions),
      ),
    );

// ---------------------------------------------------------------------------
// Value types
// ---------------------------------------------------------------------------

/// One rendered action: everything a button or menu row needs, and nothing
/// about how it is drawn.
final class GitAction {
  const GitAction({
    required this.id,
    required this.label,
    required this.pendingLabel,
    required this.successLabel,
    required this.disabled,
    required this.status,
    required this.startsGroup,
    required this.handler,
    this.unavailableMessage,
    this.icon,
  });

  final GitActionId id;

  /// Idle label. [pendingLabel] and [successLabel] are the same string for the
  /// "View PR" action, which is a navigation, not a mutation.
  final String label;
  final String pendingLabel;
  final String successLabel;

  final bool disabled;
  final GitActionStatus status;

  /// Why the action cannot be used right now, or null when there is nothing to
  /// explain.
  ///
  /// Independent of [disabled] on purpose: most actions stay *clickable* while
  /// unavailable so the host can surface this sentence on press instead of
  /// presenting a dead control the user cannot interrogate. It is suppressed
  /// entirely while the runtime reports [GitActionRuntimeState.disabled],
  /// because in that state the reason is "a mutation is already running", not
  /// anything about the repository.
  final String? unavailableMessage;

  /// The host's icon element, passed straight through from the runtime state.
  ///
  /// Typed `Object?` (upstream: `ReactElement`) so this module never imports
  /// the widget layer; the policy only forwards it and never inspects it.
  final Object? icon;

  /// When true, a menu separator should be rendered before this item.
  final bool startsGroup;

  final void Function() handler;

  @override
  String toString() => 'GitAction(${id.wireName}, "$label")';
}

/// The policy's whole answer: one promoted action, the dropdown, and an
/// always-empty menu slot.
final class GitActions {
  const GitActions({
    required this.primary,
    required this.secondary,
    required this.menu,
  });

  final GitAction? primary;
  final List<GitAction> secondary;

  /// Always empty in Paseo 0.2.0. See the library doc for why it survives.
  final List<GitAction> menu;
}

/// The host-owned half of an action: whether a mutation is in flight, what icon
/// to draw, and what to run on press.
///
/// Split out from [GitAction] because it is the only part the policy cannot
/// derive — it belongs to the mutation layer, and injecting it is what keeps
/// [buildGitActions] pure.
final class GitActionRuntimeState {
  const GitActionRuntimeState({
    required this.handler,
    this.disabled = false,
    this.status = GitActionStatus.idle,
    this.icon,
  });

  /// True while the host has this action blocked (typically its own mutation is
  /// running). Distinct from a policy-level "not available": see
  /// [GitAction.unavailableMessage].
  final bool disabled;

  final GitActionStatus status;
  final Object? icon;
  final void Function() handler;
}

/// Builds a full runtime map with every id idle and enabled.
///
/// Upstream's `Record<GitActionId, …>` makes exhaustiveness a compile error;
/// Dart cannot, so this helper is the practical equivalent for hosts and tests:
/// start from a complete map, then override only the ids that are mid-mutation.
Map<GitActionId, GitActionRuntimeState> idleGitActionRuntime({
  required void Function() handler,
  Map<GitActionId, GitActionRuntimeState> overrides = const {},
}) => {
  for (final id in GitActionId.values)
    id: overrides[id] ?? GitActionRuntimeState(handler: handler),
};

/// Every fact the policy needs. Deliberately flat and fully required: a caller
/// that has not decided what to pass for one of these has not decided what the
/// buttons mean either.
final class BuildGitActionsInput {
  const BuildGitActionsInput({
    required this.isGit,
    required this.githubFeaturesEnabled,
    required this.forgeBrandLabel,
    required this.forgeChangeRequestNoun,
    required this.githubAutoMergeActionsEnabled,
    required this.hasPullRequest,
    required this.pullRequestUrl,
    required this.pullRequestState,
    required this.pullRequestIsDraft,
    required this.pullRequestIsMerged,
    required this.pullRequestMergeable,
    required this.mergeCapability,
    required this.hasRemote,
    required this.isPaseoOwnedWorktree,
    required this.isOnBaseBranch,
    required this.hasUncommittedChanges,
    required this.baseRefAvailable,
    required this.baseRefLabel,
    required this.aheadCount,
    required this.behindBaseCount,
    required this.aheadOfOrigin,
    required this.behindOfOrigin,
    required this.shouldPromoteArchive,
    required this.shipDefault,
    required this.runtime,
  });

  /// False for a plain directory workspace, which gets no git actions at all.
  final bool isGit;

  /// Whether the forge integration is connected and usable. Gates every
  /// change-request action; when false the PR action degrades to a disabled
  /// "Create/View" with a "not connected" explanation.
  final bool githubFeaturesEnabled;

  /// Forge brand label (e.g. "GitHub", "GitLab") for forge-neutral copy.
  final String forgeBrandLabel;

  /// Short change-request noun (e.g. "PR", "MR") for forge-neutral copy.
  final String forgeChangeRequestNoun;

  /// The daemon's auto-merge feature gate. Independent of
  /// [githubFeaturesEnabled] so an older daemon simply never offers auto-merge
  /// rather than offering an RPC it cannot serve.
  final bool githubAutoMergeActionsEnabled;

  final bool hasPullRequest;

  /// Null when the change request exists but its URL is unknown, which is
  /// treated as "no usable PR" everywhere it matters — a "View PR" the host
  /// cannot open would be a dead end.
  final String? pullRequestUrl;

  final PullRequestState? pullRequestState;
  final bool pullRequestIsDraft;
  final bool pullRequestIsMerged;
  final PullRequestMergeable pullRequestMergeable;

  /// The neutral, forge-derived merge capability, or null when the forge
  /// supplied no merge facts. Null is not "cannot merge": it switches the
  /// policy onto the conservative raw-git fallback in
  /// [_GitActionsBuilder._canMergePr].
  final ForgeMergeCapability? mergeCapability;

  final bool hasRemote;

  /// Whether Paseo created this checkout as a worktree it owns. Unlocks both
  /// the first-push path (no upstream yet) and archive as a fallback CTA.
  final bool isPaseoOwnedWorktree;

  final bool isOnBaseBranch;
  final bool hasUncommittedChanges;
  final bool baseRefAvailable;

  /// Display name of the base branch, interpolated into the update copy.
  final String baseRefLabel;

  /// Commits this branch has that the base branch does not.
  final int aheadCount;

  /// Commits the base branch has that this branch does not.
  final int behindBaseCount;

  /// Commits ahead of / behind the tracked upstream, or null when there is no
  /// upstream to compare against (never pushed, or the remote branch was
  /// pruned). Null and 0 mean different things here — see
  /// [_GitActionsBuilder._hasPushableCommits].
  final int? aheadOfOrigin;
  final int? behindOfOrigin;

  /// Host-level signal that this workspace is finished and archiving should be
  /// promoted. Outranks every other primary candidate, including commit.
  final bool shouldPromoteArchive;

  final ShipDefault shipDefault;

  /// Per-action host state. Must contain an entry for every [GitActionId].
  final Map<GitActionId, GitActionRuntimeState> runtime;

  /// The runtime state for [id].
  ///
  /// Throws when the map is incomplete, which is the closest Dart analogue of
  /// upstream's exhaustive `Record` type: a missing id is a wiring bug, and
  /// silently substituting an enabled no-op would render a button that does
  /// nothing.
  GitActionRuntimeState runtimeFor(GitActionId id) {
    final state = runtime[id];
    if (state == null) {
      throw ArgumentError.value(
        id,
        'id',
        'BuildGitActionsInput.runtime is missing an entry',
      );
    }
    return state;
  }
}

// ---------------------------------------------------------------------------
// Action models
// ---------------------------------------------------------------------------

/// Which family a change-request action belongs to: the status/navigation
/// action, a direct merge, or an auto-merge toggle.
enum _PullRequestActionRole { status, direct, auto }

/// A merge-method-parameterized action (one per [CheckoutPrMergeMethod]).
///
/// The two lists built from this type are the module's frozen ordering: squash
/// first (and starting its own separator group), then merge, then rebase. That
/// order is also the tie-break when the forge reports no preferred method.
final class _PullRequestMergeMethodActionModel {
  const _PullRequestMergeMethodActionModel({
    required this.id,
    required this.method,
    required this.startsGroup,
  });

  final GitActionId id;
  final CheckoutPrMergeMethod method;
  final bool startsGroup;
}

const List<_PullRequestMergeMethodActionModel>
_pullRequestDirectMergeActionModels = [
  _PullRequestMergeMethodActionModel(
    id: GitActionId.mergePrSquash,
    method: CheckoutPrMergeMethod.squash,
    startsGroup: true,
  ),
  _PullRequestMergeMethodActionModel(
    id: GitActionId.mergePrMerge,
    method: CheckoutPrMergeMethod.merge,
    startsGroup: false,
  ),
  _PullRequestMergeMethodActionModel(
    id: GitActionId.mergePrRebase,
    method: CheckoutPrMergeMethod.rebase,
    startsGroup: false,
  ),
];

const List<_PullRequestMergeMethodActionModel>
_pullRequestAutoMergeEnableActionModels = [
  _PullRequestMergeMethodActionModel(
    id: GitActionId.enablePrAutoMergeSquash,
    method: CheckoutPrMergeMethod.squash,
    startsGroup: true,
  ),
  _PullRequestMergeMethodActionModel(
    id: GitActionId.enablePrAutoMergeMerge,
    method: CheckoutPrMergeMethod.merge,
    startsGroup: false,
  ),
  _PullRequestMergeMethodActionModel(
    id: GitActionId.enablePrAutoMergeRebase,
    method: CheckoutPrMergeMethod.rebase,
    startsGroup: false,
  ),
];

final class _PullRequestActionModel {
  const _PullRequestActionModel({
    required this.id,
    required this.role,
    required this.build,
  });

  final GitActionId id;
  final _PullRequestActionRole role;
  final GitAction Function(_GitActionsBuilder builder) build;
}

/// The frozen order of every change-request action. Both the dropdown order and
/// the "which methods may I offer" filters read this single list.
final List<_PullRequestActionModel> _pullRequestActionModels = [
  _PullRequestActionModel(
    id: GitActionId.pr,
    role: _PullRequestActionRole.status,
    build: (builder) => builder._buildPrAction(),
  ),
  for (final model in _pullRequestDirectMergeActionModels)
    _PullRequestActionModel(
      id: model.id,
      role: _PullRequestActionRole.direct,
      build: (builder) => builder._buildDirectPullRequestMergeAction(model),
    ),
  for (final model in _pullRequestAutoMergeEnableActionModels)
    _PullRequestActionModel(
      id: model.id,
      role: _PullRequestActionRole.auto,
      build: (builder) => builder._buildEnablePullRequestAutoMergeAction(model),
    ),
  _PullRequestActionModel(
    id: GitActionId.disablePrAutoMerge,
    role: _PullRequestActionRole.auto,
    build: (builder) => builder._buildDisablePullRequestAutoMergeAction(),
  ),
];

/// The three remote sync actions, always offered (though usually with an
/// explanation) regardless of which branch you are on.
const List<GitActionId> _remoteActionIds = [
  GitActionId.pull,
  GitActionId.push,
  GitActionId.pullAndPush,
];

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Decides which git actions a workspace offers.
///
/// [labels] defaults to the frozen English copy; pass
/// `GitActionsLabels.fromTranslations(...)` to follow the active language.
GitActions buildGitActions(
  BuildGitActionsInput input, {
  GitActionsLabels? labels,
}) => _GitActionsBuilder(input, labels ?? defaultGitActionsLabels).build();

/// Holds the input and copy so the ported helpers keep upstream's names and
/// read as free functions over one implicit argument.
final class _GitActionsBuilder {
  _GitActionsBuilder(this.input, this.labels);

  final BuildGitActionsInput input;
  final GitActionsLabels labels;

  String _t(String key, [Map<String, Object?>? args]) => labels.t(key, args);

  GitActions build() {
    if (!input.isGit) {
      return const GitActions(primary: null, secondary: [], menu: []);
    }

    final allActions = <GitActionId, GitAction>{};

    final commitRuntime = input.runtimeFor(GitActionId.commit);
    allActions[GitActionId.commit] = GitAction(
      id: GitActionId.commit,
      label: _t('commit.label'),
      pendingLabel: _t('commit.pending'),
      successLabel: _t('commit.success'),
      disabled: commitRuntime.disabled,
      status: commitRuntime.status,
      icon: commitRuntime.icon,
      startsGroup: false,
      handler: commitRuntime.handler,
    );

    final pullRuntime = input.runtimeFor(GitActionId.pull);
    allActions[GitActionId.pull] = GitAction(
      id: GitActionId.pull,
      label: _t('pull.label'),
      pendingLabel: _t('pull.pending'),
      successLabel: _t('pull.success'),
      disabled: pullRuntime.disabled,
      status: pullRuntime.status,
      unavailableMessage: pullRuntime.disabled ? null : _pullUnavailable(),
      icon: pullRuntime.icon,
      startsGroup: false,
      handler: pullRuntime.handler,
    );

    final pushRuntime = input.runtimeFor(GitActionId.push);
    allActions[GitActionId.push] = GitAction(
      id: GitActionId.push,
      label: _t('push.label'),
      pendingLabel: _t('push.pending'),
      successLabel: _t('push.success'),
      disabled: pushRuntime.disabled,
      status: pushRuntime.status,
      unavailableMessage: pushRuntime.disabled ? null : _pushUnavailable(),
      icon: pushRuntime.icon,
      startsGroup: false,
      handler: pushRuntime.handler,
    );

    final pullAndPushRuntime = input.runtimeFor(GitActionId.pullAndPush);
    allActions[GitActionId.pullAndPush] = GitAction(
      id: GitActionId.pullAndPush,
      label: _t('pullAndPush.label'),
      pendingLabel: _t('pullAndPush.pending'),
      successLabel: _t('pullAndPush.success'),
      disabled: pullAndPushRuntime.disabled,
      status: pullAndPushRuntime.status,
      unavailableMessage: pullAndPushRuntime.disabled
          ? null
          : _pullAndPushUnavailable(),
      icon: pullAndPushRuntime.icon,
      startsGroup: false,
      handler: pullAndPushRuntime.handler,
    );

    for (final model in _pullRequestActionModels) {
      allActions[model.id] = model.build(this);
    }

    final mergeBranchRuntime = input.runtimeFor(GitActionId.mergeBranch);
    allActions[GitActionId.mergeBranch] = GitAction(
      id: GitActionId.mergeBranch,
      label: _t('mergeBranch.label'),
      pendingLabel: _t('mergeBranch.pending'),
      successLabel: _t('mergeBranch.success'),
      disabled: mergeBranchRuntime.disabled,
      status: mergeBranchRuntime.status,
      unavailableMessage: mergeBranchRuntime.disabled
          ? null
          : _mergeBranchUnavailable(),
      icon: mergeBranchRuntime.icon,
      startsGroup: false,
      handler: mergeBranchRuntime.handler,
    );

    final mergeFromBaseRuntime = input.runtimeFor(GitActionId.mergeFromBase);
    allActions[GitActionId.mergeFromBase] = GitAction(
      id: GitActionId.mergeFromBase,
      label: _t('mergeFromBase.label', {'baseRef': input.baseRefLabel}),
      pendingLabel: _t('mergeFromBase.pending'),
      successLabel: _t('mergeFromBase.success'),
      disabled: mergeFromBaseRuntime.disabled,
      status: mergeFromBaseRuntime.status,
      unavailableMessage: mergeFromBaseRuntime.disabled
          ? null
          : _mergeFromBaseUnavailable(),
      icon: mergeFromBaseRuntime.icon,
      startsGroup: true,
      handler: mergeFromBaseRuntime.handler,
    );

    final archiveRuntime = input.runtimeFor(GitActionId.archiveWorkspace);
    allActions[GitActionId.archiveWorkspace] = GitAction(
      id: GitActionId.archiveWorkspace,
      label: _t('archive.label'),
      pendingLabel: _t('archive.pending'),
      successLabel: _t('archive.success'),
      disabled: archiveRuntime.disabled,
      status: archiveRuntime.status,
      icon: archiveRuntime.icon,
      startsGroup: true,
      handler: archiveRuntime.handler,
    );

    final primaryActionId = _primaryActionId();
    final primary = primaryActionId == null
        ? null
        : allActions[primaryActionId];

    final secondaryIds = <GitActionId>[
      ..._remoteActionIds,
      if (!input.isOnBaseBranch) ..._featureActionIds(),
      GitActionId.archiveWorkspace,
    ];

    return GitActions(
      primary: primary,
      // Archive is dropped from the dropdown only when it was promoted, so it
      // is never offered twice; every other promoted action deliberately stays
      // listed as well.
      secondary: secondaryIds
          .where(
            (id) =>
                id != GitActionId.archiveWorkspace ||
                primaryActionId != GitActionId.archiveWorkspace,
          )
          .map((id) => allActions[id]!)
          .toList(growable: false),
      menu: const [],
    );
  }

  // -------------------------------------------------------------------------
  // Primary selection
  // -------------------------------------------------------------------------

  /// The strict precedence ladder for the promoted action. First match wins.
  GitActionId? _primaryActionId() {
    if (input.shouldPromoteArchive) {
      return GitActionId.archiveWorkspace;
    }
    if (input.hasUncommittedChanges) {
      return GitActionId.commit;
    }
    if (_canPull()) {
      return GitActionId.pull;
    }
    if (_canPush()) {
      return GitActionId.push;
    }
    if (_canMergePr()) {
      return _defaultDirectPullRequestMergeActionId();
    }
    if (_canEnablePrAutoMerge()) {
      return _defaultEnablePullRequestAutoMergeActionId();
    }
    if (_hasEnabledPrAutoMerge()) {
      return GitActionId.pr;
    }
    if (input.shipDefault == ShipDefault.pr &&
        _canUsePullRequestActionAsShipDefault()) {
      return GitActionId.pr;
    }
    if (!input.isOnBaseBranch && input.aheadCount > 0) {
      return GitActionId.mergeBranch;
    }
    if (!input.isOnBaseBranch && _canMergeFromBase()) {
      return GitActionId.mergeFromBase;
    }
    if (input.githubFeaturesEnabled &&
        input.hasPullRequest &&
        input.pullRequestUrl != null) {
      return GitActionId.pr;
    }

    // Only Paseo-owned worktrees get Archive as a fallback primary action.
    // Regular Git checkouts should not show the destructive archive CTA by
    // default.
    if (input.isPaseoOwnedWorktree) {
      return GitActionId.archiveWorkspace;
    }

    return null;
  }

  /// The change-request actions worth showing, in frozen model order.
  ///
  /// [roles] is kept from upstream even though the only call site passes all
  /// three: it documents that the ordering and the role grouping are separate
  /// concerns, and it is the seam a future "auto-merge only" menu would use.
  List<GitActionId> _pullRequestActionIds(List<_PullRequestActionRole> roles) =>
      _pullRequestActionModels
          .where((model) => roles.contains(model.role))
          .where((model) => _shouldShowPullRequestAction(model.id))
          .map((model) => model.id)
          .toList(growable: false);

  List<GitActionId> _featureActionIds() => [
    GitActionId.mergeFromBase,
    GitActionId.mergeBranch,
    ..._pullRequestActionIds(const [
      _PullRequestActionRole.status,
      _PullRequestActionRole.direct,
      _PullRequestActionRole.auto,
    ]),
  ];

  /// Squash is the last-resort default because it is the method most repos
  /// allow; the fallback is unreachable through [_primaryActionId], which only
  /// asks once at least one method is allowed.
  GitActionId _defaultDirectPullRequestMergeActionId() =>
      _preferredDirectPullRequestMergeActionModel()?.id ??
      _pullRequestDirectMergeActionModels.first.id;

  GitActionId _defaultEnablePullRequestAutoMergeActionId() =>
      _preferredEnablePullRequestAutoMergeActionModel()?.id ??
      _pullRequestAutoMergeEnableActionModels.first.id;

  // -------------------------------------------------------------------------
  // Action builders
  // -------------------------------------------------------------------------

  /// The change-request action doubles as navigation once a PR exists, so its
  /// label, pending and success strings collapse to the same "View PR".
  ///
  /// A PR with no URL falls through to the Create branch: a "View" the host
  /// cannot open is worse than offering to create one.
  GitAction _buildPrAction() {
    final runtime = input.runtimeFor(GitActionId.pr);

    if (input.hasPullRequest && input.pullRequestUrl != null) {
      return GitAction(
        id: GitActionId.pr,
        label: _t('viewPr'),
        pendingLabel: _t('viewPr'),
        successLabel: _t('viewPr'),
        disabled: runtime.disabled,
        status: runtime.status,
        unavailableMessage: runtime.disabled || input.githubFeaturesEnabled
            ? null
            : _t('unavailable.viewPrNoForge', {
                'brand': input.forgeBrandLabel,
                'noun': input.forgeChangeRequestNoun,
              }),
        icon: runtime.icon,
        startsGroup: false,
        handler: runtime.handler,
      );
    }

    return GitAction(
      id: GitActionId.pr,
      label: _t('createPr.label'),
      pendingLabel: _t('createPr.pending'),
      successLabel: _t('createPr.success'),
      disabled: runtime.disabled,
      status: runtime.status,
      unavailableMessage: runtime.disabled ? null : _createPrUnavailable(),
      icon: runtime.icon,
      startsGroup: false,
      handler: runtime.handler,
    );
  }

  /// Direct merge actions are the only ones whose `disabled` combines the
  /// runtime with the policy: they are built for every method so the map is
  /// complete, but only surfaced when [_canMergePr] agrees.
  GitAction _buildDirectPullRequestMergeAction(
    _PullRequestMergeMethodActionModel model,
  ) {
    final runtime = input.runtimeFor(model.id);
    final unavailableMessage = _mergePrUnavailable();
    return GitAction(
      id: model.id,
      label: _directPullRequestMergeActionLabel(model.id),
      pendingLabel: _t('mergePr.pending'),
      successLabel: _t('mergePr.success'),
      disabled: runtime.disabled || !_canMergePr(),
      status: runtime.status,
      unavailableMessage: runtime.disabled ? null : unavailableMessage,
      icon: runtime.icon,
      startsGroup: model.startsGroup,
      handler: runtime.handler,
    );
  }

  /// Enabling auto-merge carries no unavailable copy at all: the action is
  /// either offered (because the forge says the viewer may enable it) or hidden
  /// outright, so there is never a half-state to explain.
  GitAction _buildEnablePullRequestAutoMergeAction(
    _PullRequestMergeMethodActionModel model,
  ) {
    final runtime = input.runtimeFor(model.id);
    return GitAction(
      id: model.id,
      label: _enablePullRequestAutoMergeActionLabel(model.id),
      pendingLabel: _t('autoMerge.enabling'),
      successLabel: _t('autoMerge.enabled'),
      disabled: runtime.disabled,
      status: runtime.status,
      icon: runtime.icon,
      startsGroup: model.startsGroup,
      handler: runtime.handler,
    );
  }

  /// Labelled with the *state* ("Auto-merge enabled") rather than the verb,
  /// because the row exists mainly to report that auto-merge is on; pressing it
  /// is the secondary affordance, and is disabled for viewers who lack the
  /// permission.
  GitAction _buildDisablePullRequestAutoMergeAction() {
    final runtime = input.runtimeFor(GitActionId.disablePrAutoMerge);
    final canDisable = input.mergeCapability?.canDisableAutoMerge == true;
    return GitAction(
      id: GitActionId.disablePrAutoMerge,
      label: _t('autoMerge.enabled'),
      pendingLabel: _t('autoMerge.disabling'),
      successLabel: _t('autoMerge.disabled'),
      disabled: runtime.disabled || !canDisable,
      status: runtime.status,
      unavailableMessage: runtime.disabled
          ? null
          : (canDisable ? null : _t('unavailable.autoMergeCannotDisable')),
      icon: runtime.icon,
      startsGroup: true,
      handler: runtime.handler,
    );
  }

  String _directPullRequestMergeActionLabel(GitActionId id) => switch (id) {
    GitActionId.mergePrSquash => _t('mergePr.squash'),
    GitActionId.mergePrMerge => _t('mergePr.merge'),
    GitActionId.mergePrRebase => _t('mergePr.rebase'),
    // Upstream's switch is exhaustive over a three-member union; Dart needs a
    // default arm, and reaching it means a model list and this switch drifted.
    _ => throw ArgumentError.value(id, 'id', 'not a direct merge action'),
  };

  String _enablePullRequestAutoMergeActionLabel(GitActionId id) => switch (id) {
    GitActionId.enablePrAutoMergeSquash => _t('autoMerge.enableSquash'),
    GitActionId.enablePrAutoMergeMerge => _t('autoMerge.enableMerge'),
    GitActionId.enablePrAutoMergeRebase => _t('autoMerge.enableRebase'),
    _ => throw ArgumentError.value(id, 'id', 'not an enable-auto-merge action'),
  };

  // -------------------------------------------------------------------------
  // Capability predicates
  // -------------------------------------------------------------------------

  /// Pulling requires a clean tree: a merge into dirty state is the classic way
  /// to lose work, so a dirty checkout is steered to commit first.
  bool _canPull() =>
      input.hasRemote &&
      !input.hasUncommittedChanges &&
      (input.behindOfOrigin ?? 0) > 0;

  /// Pushing while behind is refused outright rather than offered and failed:
  /// the user is sent to pull first.
  bool _canPush() =>
      input.hasRemote &&
      _hasPushableCommits() &&
      (input.behindOfOrigin ?? 0) == 0;

  bool _hasPushableCommits() {
    if ((input.aheadOfOrigin ?? 0) > 0) {
      return true;
    }
    // No-upstream Paseo worktrees are first-pushable: the daemon push sets
    // upstream with `git push -u`. Do not fold this into aheadOfOrigin; null
    // also covers deleted/pruned upstream branches.
    return input.isPaseoOwnedWorktree &&
        input.aheadOfOrigin == null &&
        input.aheadCount > 0;
  }

  bool _canMergeFromBase() =>
      !input.isOnBaseBranch &&
      input.baseRefAvailable &&
      !input.hasUncommittedChanges &&
      input.behindBaseCount > 0;

  /// Whether "PR" is a meaningful promotion for a user whose ship default is
  /// PR: an existing PR needs a URL to open, and a branch with no commits has
  /// nothing to open a PR for.
  bool _canUsePullRequestActionAsShipDefault() {
    if (input.isOnBaseBranch || !input.githubFeaturesEnabled) {
      return false;
    }
    if (input.hasPullRequest) {
      return input.pullRequestUrl != null;
    }
    return input.aheadCount > 0;
  }

  /// Whether a direct merge may be promoted and offered.
  ///
  /// Two regimes: with forge merge facts the forge's own readiness is trusted
  /// (so a locally-behind branch can still merge); without them the policy
  /// falls back to raw git and demands a branch that is exactly in sync with
  /// both origin and base, because it has no way to know the forge would accept
  /// the merge.
  bool _canMergePr() {
    final capability = input.mergeCapability;
    final canMergeFromPullRequestStatus =
        input.githubFeaturesEnabled &&
        input.hasPullRequest &&
        input.pullRequestState == PullRequestState.open &&
        !input.pullRequestIsDraft &&
        !input.pullRequestIsMerged &&
        input.pullRequestMergeable != PullRequestMergeable.conflicting &&
        input.aheadCount > 0 &&
        !input.hasUncommittedChanges;

    if (!canMergeFromPullRequestStatus) {
      return false;
    }

    if (capability == null) {
      return input.pullRequestMergeable == PullRequestMergeable.mergeable &&
          input.behindOfOrigin == 0 &&
          input.aheadOfOrigin == 0 &&
          !_canMergeFromBase();
    }

    return capability.directMergeReady &&
        !capability.autoMergeEnabled &&
        !capability.mergeBlockedByQueue &&
        _allowedDirectPullRequestMergeActionModels().isNotEmpty;
  }

  /// Auto-merge needs forge facts — there is no raw-git fallback, because
  /// nothing local can tell you whether the forge will merge later.
  bool _canEnablePrAutoMerge() {
    final capability = input.mergeCapability;
    return input.githubFeaturesEnabled &&
        input.githubAutoMergeActionsEnabled &&
        input.hasPullRequest &&
        input.pullRequestState == PullRequestState.open &&
        !input.pullRequestIsDraft &&
        !input.pullRequestIsMerged &&
        input.pullRequestMergeable != PullRequestMergeable.conflicting &&
        capability != null &&
        !capability.autoMergeEnabled &&
        capability.canEnableAutoMerge &&
        !capability.mergeBlockedByQueue &&
        _allowedAutoMergeEnableActionModels().isNotEmpty;
  }

  /// Note this ignores [BuildGitActionsInput.githubAutoMergeActionsEnabled]:
  /// once auto-merge is on, the PR action is promoted so the user can go look
  /// at it even on a daemon that cannot toggle it.
  bool _hasEnabledPrAutoMerge() =>
      input.githubFeaturesEnabled &&
      input.hasPullRequest &&
      input.pullRequestUrl != null &&
      input.mergeCapability?.autoMergeEnabled == true;

  // -------------------------------------------------------------------------
  // Unavailable copy
  // -------------------------------------------------------------------------

  String? _pullUnavailable() {
    if (!input.hasRemote) {
      return _t('unavailable.pullNoRemote');
    }
    if (input.hasUncommittedChanges) {
      return _t('unavailable.pullDirty');
    }
    // No upstream reads as "not connected to a remote yet", which is the
    // actionable phrasing even when the repo does have a remote configured.
    if (input.behindOfOrigin == null) {
      return _t('unavailable.pullNoRemote');
    }
    if (input.behindOfOrigin == 0) {
      return _t('unavailable.pullUpToDate');
    }
    return null;
  }

  String? _pushUnavailable() {
    if (!input.hasRemote) {
      return _t('unavailable.pushNoRemote');
    }
    if ((input.behindOfOrigin ?? 0) > 0) {
      return _t('unavailable.pushBehind');
    }
    if (!_hasPushableCommits()) {
      return _t('unavailable.pushNothing');
    }
    return null;
  }

  String? _pullAndPushUnavailable() {
    if (!input.hasRemote) {
      return _t('unavailable.pullAndPushNoRemote');
    }
    if (input.hasUncommittedChanges) {
      return _t('unavailable.pullAndPushDirty');
    }
    if (input.behindOfOrigin == null) {
      return _t('unavailable.pullAndPushNoIncoming');
    }
    if (input.behindOfOrigin == 0 && input.aheadOfOrigin == 0) {
      return _t('unavailable.pullAndPushInSync');
    }
    if (input.behindOfOrigin == 0) {
      return _t('unavailable.pullAndPushNoIncoming');
    }
    if ((input.aheadOfOrigin ?? 0) == 0) {
      return _t('unavailable.pullAndPushNothingToPush');
    }
    return null;
  }

  String? _createPrUnavailable() {
    if (!input.githubFeaturesEnabled) {
      return _t('unavailable.createPrNoForge', {
        'brand': input.forgeBrandLabel,
        'noun': input.forgeChangeRequestNoun,
      });
    }
    if (input.aheadCount == 0) {
      return _t('unavailable.createPrNoCommits');
    }
    return null;
  }

  String? _mergeBranchUnavailable() {
    if (!input.baseRefAvailable) {
      return _t('unavailable.mergeNoBase');
    }
    if (input.hasUncommittedChanges) {
      return _t('unavailable.mergeDirty');
    }
    if (input.aheadCount == 0) {
      return _t('unavailable.mergeNothing');
    }
    return null;
  }

  String? _mergeFromBaseUnavailable() {
    if (!input.baseRefAvailable) {
      return _t('unavailable.updateNoBase');
    }
    if (input.hasUncommittedChanges) {
      return _t('unavailable.updateDirty');
    }
    if (input.behindBaseCount == 0) {
      return _t('unavailable.updateCurrent', {'baseRef': input.baseRefLabel});
    }
    return null;
  }

  /// Why a direct PR merge is unavailable.
  ///
  /// Ported for completeness, but currently unobservable through
  /// [buildGitActions]: a direct-merge action is only ever *shown* when
  /// [_canMergePr] is true, and every condition that makes this return a
  /// sentence also makes [_canMergePr] false. It is kept faithful (rather than
  /// deleted) because it is the copy an upstream revision would surface the
  /// moment those actions are shown disabled instead of hidden.
  String? _mergePrUnavailable() {
    if (!input.githubFeaturesEnabled) {
      return _t('unavailable.mergePrNoForge', {
        'brand': input.forgeBrandLabel,
        'noun': input.forgeChangeRequestNoun,
      });
    }
    if (!input.hasPullRequest) {
      return _t('unavailable.mergePrMissing');
    }
    if (input.pullRequestIsDraft) {
      return _t('unavailable.mergePrDraft');
    }
    if (input.pullRequestIsMerged) {
      return _t('unavailable.mergePrMerged');
    }
    if (input.pullRequestState == PullRequestState.closed) {
      return _t('unavailable.mergePrClosed');
    }
    if (input.pullRequestMergeable == PullRequestMergeable.conflicting) {
      return _t('unavailable.mergePrConflicts');
    }
    final capability = input.mergeCapability;
    if (capability == null) {
      return null;
    }
    if (capability.mergeBlockedByQueue) {
      return _t('unavailable.mergePrQueue');
    }
    if (!capability.directMergeReady) {
      return _t('unavailable.mergePrNotReady', {
        'brand': input.forgeBrandLabel,
        'noun': input.forgeChangeRequestNoun,
      });
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Visibility and merge-method allowlists
  // -------------------------------------------------------------------------

  /// The status action is always shown; every other change-request action is
  /// hidden unless it is actually usable, so the dropdown never fills with
  /// dead rows.
  bool _shouldShowPullRequestAction(GitActionId id) {
    if (id == GitActionId.pr) {
      return true;
    }
    if (id == GitActionId.disablePrAutoMerge) {
      return input.githubAutoMergeActionsEnabled &&
          input.mergeCapability?.autoMergeEnabled == true;
    }
    if (_isDirectPullRequestMergeActionId(id)) {
      return _canMergePr() &&
          _allowedDirectPullRequestMergeActionIds().contains(id);
    }
    if (_isEnablePullRequestAutoMergeActionId(id)) {
      return _canEnablePrAutoMerge() &&
          _allowedAutoMergeEnableActionIds().contains(id);
    }
    return false;
  }

  bool _isDirectPullRequestMergeActionId(GitActionId id) =>
      _pullRequestDirectMergeActionModels.any((model) => model.id == id);

  bool _isEnablePullRequestAutoMergeActionId(GitActionId id) =>
      _pullRequestAutoMergeEnableActionModels.any((model) => model.id == id);

  List<GitActionId> _allowedDirectPullRequestMergeActionIds() =>
      _allowedDirectPullRequestMergeActionModels()
          .map((model) => model.id)
          .toList(growable: false);

  List<GitActionId> _allowedAutoMergeEnableActionIds() =>
      _allowedAutoMergeEnableActionModels()
          .map((model) => model.id)
          .toList(growable: false);

  List<_PullRequestMergeMethodActionModel>
  _allowedDirectPullRequestMergeActionModels() =>
      _pullRequestDirectMergeActionModels
          .where((model) => _isPullRequestMergeMethodAllowed(model.method))
          .toList(growable: false);

  List<_PullRequestMergeMethodActionModel>
  _allowedAutoMergeEnableActionModels() =>
      _pullRequestAutoMergeEnableActionModels
          .where((model) => _isPullRequestMergeMethodAllowed(model.method))
          .toList(growable: false);

  /// The forge's preferred method when it is allowed, otherwise the first
  /// allowed method in frozen order, otherwise nothing.
  _PullRequestMergeMethodActionModel?
  _preferredDirectPullRequestMergeActionModel() =>
      _preferredModel(_allowedDirectPullRequestMergeActionModels());

  _PullRequestMergeMethodActionModel?
  _preferredEnablePullRequestAutoMergeActionModel() =>
      _preferredModel(_allowedAutoMergeEnableActionModels());

  _PullRequestMergeMethodActionModel? _preferredModel(
    List<_PullRequestMergeMethodActionModel> allowed,
  ) {
    final preferred = input.mergeCapability?.preferredMethod;
    for (final model in allowed) {
      if (model.method.name == preferred) {
        return model;
      }
    }
    return allowed.isEmpty ? null : allowed.first;
  }

  /// A null capability means "the forge told us nothing", which is treated as
  /// permissive: every method stays on offer rather than silently vanishing
  /// against an older daemon.
  ///
  /// [ForgeMergeCapability.allowedMethods] is a `List<String>` of wire names,
  /// so the comparison goes through [CheckoutPrMergeMethod.name] — the enum's
  /// Dart names are exactly the wire values.
  bool _isPullRequestMergeMethodAllowed(CheckoutPrMergeMethod method) {
    final capability = input.mergeCapability;
    if (capability == null) {
      return true;
    }
    return capability.allowedMethods.contains(method.name);
  }
}
