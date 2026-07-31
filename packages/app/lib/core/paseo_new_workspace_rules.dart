/// Ports of the four frozen decision modules that sit behind Paseo 0.2.0's
/// "new workspace" screen. They live together because each one answers a
/// question the screen asks *before* it can talk to a daemon, and none of them
/// touches React state:
///
/// - `screens/new-workspace-empty.ts` — is this submission blank, and if the
///   user hit send on a blank composer, how do we create the bare workspace?
/// - `screens/new-workspace-fork-context.ts` — when a draft is forked into a
///   fresh worktree, which directory does its cwd land in, and which of the
///   carried-over attachments may influence the workspace's generated name.
/// - `screens/new-workspace-picker-item.ts` — turning the branch/PR picker's
///   selection into the worktree-creation fields the daemon expects.
/// - `screens/new-workspace-initial-context.ts` — which host the screen opens
///   on, and when a later recomputation is allowed to move it.
///
/// Everything here is deliberately store-free and daemon-free: the screen
/// supplies the observed state, these rules return the decision.
library;

import 'package:agent_protocol/agent_protocol.dart';

import '../widgets/host_status_dot.dart' show HostRuntimeConnectionStatus;

// ---------------------------------------------------------------------------
// new-workspace-empty.ts
// ---------------------------------------------------------------------------

/// The subset of upstream's `MessagePayload` (`composer/types.ts`) that the
/// empty-submission rules read.
///
/// Upstream types `attachments` as `ComposerAttachment[]`; that union is not
/// ported, and only its *length* is ever inspected here, so attachments stay
/// opaque — matching the existing `shouldAllowEmptyDraftText` in
/// `composer/workspace_draft_submission.dart`.
final class NewWorkspaceMessagePayload {
  const NewWorkspaceMessagePayload({
    required this.text,
    required this.cwd,
    this.attachments = const [],
  });

  final String text;
  final String cwd;
  final List<Object?> attachments;
}

/// Whether hitting send should create a bare workspace rather than an agent.
///
/// Whitespace-only text counts as blank, but a single attachment does not —
/// an image with no prompt is still something the user meant to send to an
/// agent.
bool isEmptyWorkspaceSubmission(NewWorkspaceMessagePayload payload) =>
    payload.text.trim().isEmpty && payload.attachments.isEmpty;

/// The arguments [runCreateEmptyWorkspace] hands to its `ensureWorkspace`
/// callback. Modelled as a value type (rather than four positional arguments)
/// so a caller's recorder can assert the exact call the way upstream's
/// `expect(ensureWorkspace).toHaveBeenCalledWith({...})` does.
final class EnsureWorkspaceInput {
  const EnsureWorkspaceInput({
    required this.cwd,
    required this.prompt,
    required this.attachments,
    required this.withInitialAgent,
  });

  final String cwd;
  final String prompt;
  final List<AgentAttachment> attachments;
  final bool withInitialAgent;

  @override
  bool operator ==(Object other) =>
      other is EnsureWorkspaceInput &&
      other.cwd == cwd &&
      other.prompt == prompt &&
      other.withInitialAgent == withInitialAgent &&
      _sameAttachments(other.attachments, attachments);

  @override
  int get hashCode =>
      Object.hash(cwd, prompt, withInitialAgent, attachments.length);

  static bool _sameAttachments(
    List<AgentAttachment> left,
    List<AgentAttachment> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!identical(left[index], right[index])) return false;
    }
    return true;
  }
}

/// Creates the workspace for a blank submission, then routes to it.
///
/// The prompt and attachments are dropped on purpose: the user asked for an
/// empty workspace, so no initial agent is spawned even though the draft may
/// still carry a cwd. Only [NewWorkspaceMessagePayload.cwd] survives.
///
/// DEVIATION: upstream's `ensureWorkspace` resolves to a normalized
/// `WorkspaceDescriptor` and the caller reads nothing but `.id`. Requiring a
/// fully-populated `WorkspaceDescriptor` here would burden every caller and
/// test with a dozen irrelevant fields, so the callback resolves to the
/// workspace id directly.
Future<void> runCreateEmptyWorkspace({
  required NewWorkspaceMessagePayload payload,
  required Future<String> Function(EnsureWorkspaceInput input) ensureWorkspace,
  required String serverId,
  required void Function(String serverId, String workspaceId) navigate,
}) async {
  final workspaceId = await ensureWorkspace(
    EnsureWorkspaceInput(
      cwd: payload.cwd,
      prompt: '',
      attachments: const [],
      withInitialAgent: false,
    ),
  );
  navigate(serverId, workspaceId);
}

// ---------------------------------------------------------------------------
// new-workspace-fork-context.ts
// ---------------------------------------------------------------------------

/// Matches a drive-letter prefix on an already-normalized (forward-slash) path.
final _likelyWindowsPath = RegExp(r'^[a-zA-Z]:/');

bool _isLikelyWindowsPath(String path) => _likelyWindowsPath.hasMatch(path);

final _trailingSlashes = RegExp(r'/+$');
final _trailingSeparators = RegExp(r'[\\/]+$');

/// Whether an attachment is the forked conversation's full transcript.
///
/// The daemon-side builder (`daemon/src/agent/fork_context.dart`) emits this as
/// a `text` attachment; upstream tags it `contextKind: "chat_history"` and that
/// tag is the only thing distinguishing it from a user-authored text snippet.
bool _isChatHistoryTextAttachment(AgentAttachment attachment) =>
    attachment is TextAgentAttachment &&
    attachment.contextKind == 'chat_history';

/// The attachments allowed to influence the new workspace's generated name.
///
/// A forked draft carries the entire prior conversation, which would drown out
/// the far more specific context (a PR, a review comment) the user actually
/// forked *for*. Dropping it keeps the generated name about the new work.
///
/// DEVIATION: upstream discriminates on `attachment.type === "text"`; this
/// repo's `AgentAttachment` union is narrower (`text` | `review`) than
/// upstream's, so the check is a type test. Every non-text attachment kind is
/// passed through either way.
List<AgentAttachment> getWorkspaceNamingAttachments(
  List<AgentAttachment> attachments,
) => [
  for (final attachment in attachments)
    if (!_isChatHistoryTextAttachment(attachment)) attachment,
];

/// Rebases a draft's working directory from the source checkout onto the new
/// worktree, preserving how deep into the repo the user was.
///
/// Forking from `repo/packages/app` should land in `worktree/packages/app`, not
/// at the worktree root — the draft's subdirectory is usually the whole point
/// of where the user was working. Anything that cannot be expressed as a
/// subpath of [sourceDirectory] (a different repo, a missing source, an empty
/// cwd) falls back to the worktree root rather than guessing.
///
/// Comparison is case-insensitive only when either side looks like a Windows
/// path, so POSIX paths that differ only in case stay distinct. The separator
/// of the result follows [workspaceDirectory]: backslashes are kept only when
/// it uses backslashes exclusively.
String remapDraftCwdToWorkspace({
  required String cwd,
  required String workspaceDirectory,
  String? sourceDirectory,
}) {
  final trimmedCwd = cwd.trim();
  final trimmedSource = sourceDirectory?.trim();
  final trimmedWorkspace = workspaceDirectory.trim();
  // Upstream's `!cwd || !sourceDirectory` is a falsy check, so an empty string
  // is rejected exactly like a missing value.
  if (trimmedCwd.isEmpty || trimmedSource == null || trimmedSource.isEmpty) {
    return trimmedWorkspace;
  }

  final normalizedCwd = trimmedCwd
      .replaceAll(r'\', '/')
      .replaceFirst(_trailingSlashes, '');
  final normalizedSource = trimmedSource
      .replaceAll(r'\', '/')
      .replaceFirst(_trailingSlashes, '');
  final compareCaseInsensitively =
      _isLikelyWindowsPath(normalizedCwd) ||
      _isLikelyWindowsPath(normalizedSource);
  final comparableCwd = compareCaseInsensitively
      ? normalizedCwd.toLowerCase()
      : normalizedCwd;
  final comparableSource = compareCaseInsensitively
      ? normalizedSource.toLowerCase()
      : normalizedSource;
  if (comparableCwd == comparableSource) {
    return trimmedWorkspace;
  }

  // Sliced from the case-preserving path even though the prefix test is
  // case-folded, so the surviving subpath keeps the user's original casing.
  final relativePath = comparableCwd.startsWith('$comparableSource/')
      ? normalizedCwd.substring(normalizedSource.length + 1)
      : '';
  if (relativePath.isEmpty) {
    return trimmedWorkspace;
  }

  final separator =
      trimmedWorkspace.contains(r'\') && !trimmedWorkspace.contains('/')
      ? r'\'
      : '/';
  return [
    trimmedWorkspace.replaceFirst(_trailingSeparators, ''),
    ...relativePath.split('/'),
  ].where((segment) => segment.isNotEmpty).join(separator);
}

// ---------------------------------------------------------------------------
// new-workspace-picker-item.ts
// ---------------------------------------------------------------------------

/// A row the branch/change-request picker can have selected.
sealed class PickerItem {
  const PickerItem();
}

/// A local or remote branch to branch off of.
final class BranchPickerItem extends PickerItem {
  const BranchPickerItem(this.name);

  final String name;
}

/// A forge change request (GitHub PR, GitLab MR, ...) to check out.
///
/// Upstream tags this variant `"github-pr"` for historical reasons even though
/// it carries any forge's change request; the name here follows the forge-
/// neutral naming already used by `composer/checkout_link_selection.dart`.
final class ChangeRequestPickerItem extends PickerItem {
  const ChangeRequestPickerItem(this.item);

  final ForgeSearchItem item;
}

/// The worktree-creation fields a picker selection contributes.
///
/// Upstream is a `Pick<CreatePaseoWorktreeInput, ...>` of exactly these four
/// keys, and the *absence* of a key is meaningful on the wire — see
/// [toJson], which reproduces upstream's conditional-spread object shape.
final class PickerCheckoutRequest {
  const PickerCheckoutRequest({
    required this.action,
    this.refName,
    this.checkoutSource,
    this.githubPrNumber,
  });

  final GitSetupAction action;
  final String? refName;
  final ChangeRequestCheckoutSource? checkoutSource;

  /// COMPAT(githubPrNumber): added upstream in v0.1.106, removable after
  /// 2026-12-28 once the daemon floor parses `checkoutSource`. Sent only for
  /// GitHub so non-GitHub forges never see a field that means "PR number".
  final int? githubPrNumber;

  /// The request as the daemon receives it. Optional fields are omitted rather
  /// than sent as null, which is the observable difference upstream encodes
  /// with `...(x ? { x } : {})`.
  Map<String, Object?> toJson() => {
    'action': switch (action) {
      GitSetupAction.branchOff => 'branch-off',
      GitSetupAction.checkout => 'checkout',
    },
    if (refName != null) 'refName': refName,
    if (checkoutSource != null) 'checkoutSource': checkoutSource!.toJson(),
    if (githubPrNumber != null) 'githubPrNumber': githubPrNumber,
  };

  @override
  bool operator ==(Object other) =>
      other is PickerCheckoutRequest &&
      other.action == action &&
      other.refName == refName &&
      other.githubPrNumber == githubPrNumber &&
      other.checkoutSource?.number == checkoutSource?.number &&
      other.checkoutSource?.forge == checkoutSource?.forge &&
      other.checkoutSource?.projectPath == checkoutSource?.projectPath;

  @override
  int get hashCode => Object.hash(
    action,
    refName,
    githubPrNumber,
    checkoutSource?.number,
    checkoutSource?.forge,
    checkoutSource?.projectPath,
  );
}

/// Converts the picker's selection into worktree-creation fields, or null when
/// nothing is selected and the caller should send no checkout intent at all.
///
/// A branch row branches off; a change-request row checks the change request
/// out. The head ref is only sent when the forge actually reported one — a
/// blank or whitespace-only `headRefName` means "let the daemon resolve it"
/// rather than "check out the empty ref".
///
/// DEVIATION: upstream returns `undefined` for no selection. Dart has no
/// undefined/null split, so callers get null; the observable contract ("omit
/// these fields entirely") is unchanged.
PickerCheckoutRequest? pickerItemToCheckoutRequest(PickerItem? item) {
  switch (item) {
    case null:
      return null;
    case BranchPickerItem(:final name):
      return PickerCheckoutRequest(
        action: GitSetupAction.branchOff,
        refName: name,
      );
    case ChangeRequestPickerItem(:final item):
      final headRefName = item.headRefName?.trim();
      // `?? "github"` is nullish, not falsy: an explicitly empty forge stays
      // empty and therefore does not qualify for the legacy PR-number field.
      final forge = item.forge ?? 'github';
      final projectPath = item.projectPath;
      return PickerCheckoutRequest(
        action: GitSetupAction.checkout,
        refName: headRefName != null && headRefName.isNotEmpty
            ? headRefName
            : null,
        checkoutSource: ChangeRequestCheckoutSource(
          forge: forge,
          number: item.number,
          projectPath: projectPath != null && projectPath.isNotEmpty
              ? projectPath
              : null,
        ),
        githubPrNumber: forge == 'github' ? item.number : null,
      );
  }
}

// ---------------------------------------------------------------------------
// new-workspace-initial-context.ts
// ---------------------------------------------------------------------------

/// One host that has a given project checked out.
///
/// The subset of upstream's `WorkspaceStructureHostPlacement` these rules read;
/// `iconWorkingDir` is presentation-only and never consulted here.
final class NewWorkspaceProjectHost {
  const NewWorkspaceProjectHost({
    required this.serverId,
    required this.canCreateWorktree,
  });

  final String serverId;

  /// False for non-git projects, which can only host one workspace per
  /// directory unless the host opts into workspace multiplicity.
  final bool canCreateWorktree;
}

/// A project as the host picker sees it.
///
/// The subset of upstream's `HostProjectListItem` (`projects/
/// host-project-model.ts`, not yet ported) that host resolution reads:
/// [projectKey] identifies the project across hosts, [hosts] says where it
/// lives.
final class NewWorkspaceHostProject {
  const NewWorkspaceHostProject({
    required this.projectKey,
    required this.hosts,
  });

  final String projectKey;
  final List<NewWorkspaceProjectHost> hosts;
}

/// Everything host resolution observes about the world.
final class NewWorkspaceInitialServerInput {
  const NewWorkspaceInitialServerInput({
    required this.allServerIds,
    required this.projects,
    this.routeServerId,
    this.lastActiveProject,
    this.hostConnectionStatusByServerId = const {},
    this.workspaceMultiplicityByServerId = const {},
  });

  /// In display order — several fallbacks resolve to "the first one".
  final List<String> allServerIds;

  /// The host the current route names, if the user arrived via a host-scoped
  /// link. Honoured verbatim, even when that host is offline.
  final String? routeServerId;

  /// The project the user last worked in, possibly not yet rehydrated into
  /// [projects].
  final NewWorkspaceHostProject? lastActiveProject;

  final List<NewWorkspaceHostProject> projects;

  /// Absent entries mean "not yet known", which is treated as reachable-but-
  /// not-online rather than offline.
  final Map<String, HostRuntimeConnectionStatus> hostConnectionStatusByServerId;

  /// Hosts that allow more than one workspace per directory, which makes even
  /// non-git projects selectable there.
  final Map<String, bool> workspaceMultiplicityByServerId;
}

/// Trims and validates a server id against the known set.
///
/// Upstream's `normalized && ... ? normalized : null` is a falsy test, so a
/// whitespace-only id collapses to empty and is rejected like a missing one.
String? _knownServerId(Set<String> serverIds, String? serverId) {
  final normalized = serverId?.trim() ?? '';
  return normalized.isNotEmpty && serverIds.contains(normalized)
      ? normalized
      : null;
}

bool _supportsAllProjects(
  Map<String, bool> workspaceMultiplicityByServerId,
  String serverId,
) => workspaceMultiplicityByServerId[serverId] == true;

/// Upstream `canCreateWorkspaceForHostProject` from `projects/
/// host-project-model.ts`. Kept private because that module belongs to a
/// different port and should own the public name when it lands.
bool _canCreateWorkspaceForHostProject({
  required NewWorkspaceHostProject project,
  required String serverId,
  required bool allowAllProjects,
}) {
  for (final host in project.hosts) {
    if (host.serverId == serverId) {
      return allowAllProjects || host.canCreateWorktree;
    }
  }
  return false;
}

/// Prefers the hydrated copy of [candidate] that actually lists [serverId], so
/// a remembered project stub does not veto a host it was simply never told
/// about. Falls back to the stub when no hydrated copy exists.
NewWorkspaceHostProject _getProjectForServer({
  required NewWorkspaceHostProject candidate,
  required List<NewWorkspaceHostProject> projects,
  required String serverId,
}) {
  for (final project in projects) {
    if (project.projectKey == candidate.projectKey &&
        project.hosts.any((host) => host.serverId == serverId)) {
      return project;
    }
  }
  return candidate;
}

bool _canUseProjectForServer({
  required NewWorkspaceHostProject project,
  required List<NewWorkspaceHostProject> projects,
  required String serverId,
  required Map<String, bool> workspaceMultiplicityByServerId,
}) => _canCreateWorkspaceForHostProject(
  project: _getProjectForServer(
    candidate: project,
    projects: projects,
    serverId: serverId,
  ),
  serverId: serverId,
  allowAllProjects: _supportsAllProjects(
    workspaceMultiplicityByServerId,
    serverId,
  ),
);

/// The first known host the remembered project can actually be created on.
String? _findLastActiveProjectServerId(
  NewWorkspaceInitialServerInput input,
  Set<String> serverIds,
) {
  final lastActiveProject = input.lastActiveProject;
  if (lastActiveProject == null) return null;

  for (final host in lastActiveProject.hosts) {
    if (!serverIds.contains(host.serverId)) continue;
    if (_canUseProjectForServer(
      project: lastActiveProject,
      projects: input.projects,
      serverId: host.serverId,
      workspaceMultiplicityByServerId: input.workspaceMultiplicityByServerId,
    )) {
      return host.serverId;
    }
  }

  return null;
}

bool _hasSelectableProject(
  NewWorkspaceInitialServerInput input,
  String serverId,
) => input.projects.any(
  (project) => _canUseProjectForServer(
    project: project,
    projects: input.projects,
    serverId: serverId,
    workspaceMultiplicityByServerId: input.workspaceMultiplicityByServerId,
  ),
);

bool _isOnline(NewWorkspaceInitialServerInput input, String serverId) =>
    input.hostConnectionStatusByServerId[serverId] ==
    HostRuntimeConnectionStatus.online;

/// Only `offline` and `error` are *known* to be unusable. `idle`, `connecting`
/// and a missing status all still might come up, so they stay candidates.
bool _isKnownUnreachable(
  NewWorkspaceInitialServerInput input,
  String serverId,
) {
  final status = input.hostConnectionStatusByServerId[serverId];
  return status == HostRuntimeConnectionStatus.offline ||
      status == HostRuntimeConnectionStatus.error;
}

String _firstOrEmpty(List<String> serverIds) =>
    serverIds.isEmpty ? '' : serverIds.first;

/// Which host the new-workspace screen should open on.
///
/// The ordering encodes a preference for hosts the user can act on *right now*
/// over hosts they used most recently: an explicit route wins outright, then
/// the remembered project if it is online, then online hosts that have
/// something to select, then any online host, and only then hosts that are
/// merely not-known-to-be-broken. The last resort is the first configured host,
/// which keeps the screen on a host rather than an empty selection.
///
/// Returns the empty string when there are no hosts at all, mirroring
/// upstream's `?? ""` terminator.
String resolveNewWorkspaceInitialServerId(
  NewWorkspaceInitialServerInput input,
) {
  final serverIds = input.allServerIds.toSet();
  final routeServerId = _knownServerId(serverIds, input.routeServerId);
  if (routeServerId != null) {
    return routeServerId;
  }

  final onlineServerIds = [
    for (final serverId in input.allServerIds)
      if (_isOnline(input, serverId)) serverId,
  ];
  final onlineServerIdsWithProjects = [
    for (final serverId in onlineServerIds)
      if (_hasSelectableProject(input, serverId)) serverId,
  ];
  final serverIdsWithProjects = [
    for (final serverId in input.allServerIds)
      if (_hasSelectableProject(input, serverId)) serverId,
  ];

  final lastActiveProjectServerId = _findLastActiveProjectServerId(
    input,
    serverIds,
  );
  if (lastActiveProjectServerId != null &&
      _isOnline(input, lastActiveProjectServerId)) {
    return lastActiveProjectServerId;
  }

  if (onlineServerIdsWithProjects.isNotEmpty) {
    return onlineServerIdsWithProjects.first;
  }
  // Upstream tests `length === 1` before `length > 0`; both branches return the
  // same value, so the sole-online case is kept only as documentation of intent.
  if (onlineServerIds.isNotEmpty) {
    return onlineServerIds.first;
  }

  final reachableServerIdsWithProjects = [
    for (final serverId in serverIdsWithProjects)
      if (!_isKnownUnreachable(input, serverId)) serverId,
  ];
  if (reachableServerIdsWithProjects.length == 1) {
    return reachableServerIdsWithProjects.first;
  }

  if (lastActiveProjectServerId != null) {
    return lastActiveProjectServerId;
  }

  if (serverIdsWithProjects.length == 1) {
    return serverIdsWithProjects.first;
  }

  return _firstOrEmpty(input.allServerIds);
}

/// Whether an automatically-selected host should move to [nextServerId] when
/// [resolveNewWorkspaceInitialServerId] recomputes to a new default.
///
/// The screen recomputes its default as hosts connect and projects hydrate, but
/// yanking the selection out from under someone mid-draft is worse than showing
/// a slightly stale host. So the current host is kept unless the move is a
/// clear improvement: the current host is dead and the new one is not, the new
/// one is what the route or the remembered project asked for, or the current
/// host simply has nothing the user could pick.
///
/// [currentServerId] being unknown or absent means nothing is being preserved,
/// so the new default is taken as-is.
String resolveNewWorkspaceAutomaticServerId(
  NewWorkspaceInitialServerInput input, {
  required String? currentServerId,
  required String? nextServerId,
}) {
  final serverIds = input.allServerIds.toSet();
  final current = _knownServerId(serverIds, currentServerId);
  final next =
      _knownServerId(serverIds, nextServerId) ??
      _firstOrEmpty(input.allServerIds);
  if (current == null || current == next) {
    return next;
  }

  if (_isOnline(input, next) && !_isOnline(input, current)) {
    return next;
  }

  if (_knownServerId(serverIds, input.routeServerId) == next) {
    return next;
  }

  final lastActiveProjectServerId = _findLastActiveProjectServerId(
    input,
    serverIds,
  );
  final hasOnlineServer = input.allServerIds.any(
    (serverId) => _isOnline(input, serverId),
  );
  if (lastActiveProjectServerId == next &&
      (_isOnline(input, next) || !hasOnlineServer)) {
    return next;
  }

  final currentHasProject = _hasSelectableProject(input, current);
  final nextHasProject = _hasSelectableProject(input, next);
  if (_isKnownUnreachable(input, current) &&
      nextHasProject &&
      !_isKnownUnreachable(input, next)) {
    return next;
  }
  if (!currentHasProject &&
      nextHasProject &&
      (!_isOnline(input, current) || _isOnline(input, next))) {
    return next;
  }

  return current;
}
