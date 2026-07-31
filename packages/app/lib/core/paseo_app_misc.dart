/// Ports of six small, frozen Paseo 0.2.0 modules that share no feature but do
/// share a shape: each is a pure decision (or a decision plus one injected
/// side-effect port) that some screen asks a question of, and none of them is
/// large enough to justify a file of its own.
///
/// - `file-explorer/preview-target.ts` — which working directory a file preview
///   should be read relative to, given a path that may be workspace-relative,
///   absolute, home-relative, or on a completely different volume.
/// - `projects/host-project-model.ts` + `projects/host-projects.ts` — the
///   project list the host/project pickers render, plus every "which project
///   should start selected" fallback the new-workspace and new-worktree flows
///   run.
/// - `hooks/use-preferred-editor.ts` — which external editor "Open in…" uses,
///   and the persisted preference behind it.
/// - `screens/settings/daemon-restart.ts` — whether the settings screen's
///   restart button goes through the desktop shell or over the daemon RPC.
/// - `utils/review-attachments.ts` — turning a forge (GitHub/GitLab/…) search
///   result into the attachment shape the agent receives, in both the current
///   and the legacy-daemon wire dialects.
/// - `workspace-service-routes/store.ts` — the per-host "which URL do I use to
///   reach a workspace script" preference, and the sanitising rehydrate that
///   protects it from a corrupted persisted blob.
///
/// Everything here is pure or takes its I/O as an injected port, so the whole
/// file runs without a widget tree, a daemon, or a desktop shell. Nothing reads
/// a clock.
///
/// ## Reuse
///
/// These ports deliberately do *not* redeclare types this repo already ships:
///
/// - [isAbsolutePath] comes from `lib/core/path.dart`, the existing port of
///   upstream `utils/path.ts` that `preview-target.ts` imports.
/// - [WorkspaceProjectKind], [WorkspaceDescriptor], [ForgeSearchItem] and
///   [AvailableEditor] come from `package:agent_protocol` — the same wire types
///   upstream's modules are typed against. In particular the editor ids
///   [resolvePreferredEditorId] chooses between are exactly the
///   `list_available_editors` reply's [AvailableEditor.id] values, which are in
///   turn the `EditorTargetDescriptor.id`s produced by the editor-target
///   registry in `lib/desktop/paseo_desktop_features.dart`; the winner is what
///   an `open_in_editor` request carries as `editorId`.
/// - [KeyValueStorage] comes from `lib/hooks/paseo_agent_settings_rules.dart`,
///   this repo's port of upstream's AsyncStorage seam.
///   [MutableKeyValueStorage] only adds the `removeItem` that upstream's
///   `StateStorage`/AsyncStorage also have and the settings port did not need.
/// - [DesktopDaemonSettings] (also from `paseo_agent_settings_rules.dart`) is
///   the desktop-owned settings document [restartDaemonFromSettings] reads
///   `manageBuiltInDaemon` out of.
/// - [DaemonStatus] comes from `package:daemon_lifecycle`, matching the choice
///   `lib/desktop/paseo_desktop_daemon_rules.dart` already made for the daemon
///   start/stop ports.
///
/// ## Not reused, and why
///
/// - `lib/core/paseo_new_workspace_rules.dart` holds a *private*
///   `_canCreateWorkspaceForHostProject` over a two-field
///   `NewWorkspaceHostProject`, with a comment reserving the public name for
///   this port. That file belongs to a different upstream module
///   (`new-workspace-initial-context.ts`) and cannot be edited here, so its
///   private copy stays; [canCreateWorkspaceForHostProject] below is the public
///   one. The two are not identical: the new-workspace rules additionally
///   require a hydrated project to *list* the server before preferring it over
///   a remembered stub, which is that module's own rule, not this one's.
/// - `AgentAttachment` in `package:agent_protocol` is a sealed hierarchy that
///   models only the `text` and `review` attachment kinds; a `forge_*` variant
///   cannot be added from outside its library. [ForgeAgentAttachment] is
///   therefore a separate hierarchy whose [ForgeAgentAttachment.toJson] emits
///   exactly the object upstream builds, so the wire bytes are unchanged.
library;

import 'dart:collection';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart'
    show
        AvailableEditor,
        ForgeSearchItem,
        ForgeSearchKind,
        WorkspaceDescriptor,
        WorkspaceProjectKind;
import 'package:daemon_lifecycle/daemon_lifecycle.dart' show DaemonStatus;

import '../hooks/paseo_agent_settings_rules.dart'
    show DesktopDaemonSettings, KeyValueStorage;
import 'path.dart' show isAbsolutePath;

// Re-exported because they appear in this library's public signatures, so a
// caller should not have to know which existing module they were reused from.
export 'package:daemon_lifecycle/daemon_lifecycle.dart' show DaemonStatus;

export '../hooks/paseo_agent_settings_rules.dart'
    show DesktopDaemonSettings, KeyValueStorage;
export 'path.dart' show isAbsolutePath;

// ---------------------------------------------------------------------------
// Shared storage seam
// ---------------------------------------------------------------------------

/// A key/value store that can also forget a key.
///
/// Upstream's two persistence seams — AsyncStorage (`use-preferred-editor.ts`)
/// and zustand's `StateStorage` (`workspace-service-routes/store.ts`) — are the
/// same three methods. This repo already models the read/write half as
/// [KeyValueStorage]; clearing a preference needs the third, so it is added
/// here rather than duplicating the interface.
abstract interface class MutableKeyValueStorage implements KeyValueStorage {
  /// Removes [key]. Removing an absent key is not an error, matching both
  /// AsyncStorage and `StateStorage`.
  Future<void> removeItem(String key);
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// file-explorer/preview-target.ts
// ---------------------------------------------------------------------------

/// Where a file preview should be read from: a working directory plus the path
/// to hand the daemon, which may itself still be absolute.
///
/// The daemon resolves reads relative to a cwd it is allowed to reach, so a
/// preview of a file outside the workspace has to widen the cwd rather than
/// escape it with `..`.
final class FilePreviewReadTarget {
  const FilePreviewReadTarget({required this.cwd, required this.path});

  /// The workspace root, the filesystem/volume root, or `~`.
  final String cwd;

  /// The path exactly as the caller asked for it, minus surrounding
  /// whitespace. Never rewritten — normalisation only ever informs the
  /// containment decision.
  final String path;

  @override
  bool operator ==(Object other) =>
      other is FilePreviewReadTarget && other.cwd == cwd && other.path == path;

  @override
  int get hashCode => Object.hash(cwd, path);

  @override
  String toString() => 'FilePreviewReadTarget(cwd: $cwd, path: $path)';
}

/// Drops trailing separators, except from a path that *is* a root.
///
/// `/` and a bare drive (`C:`, `C:/`, `C:\`) must keep their shape or the
/// prefix comparison below would compare against an empty string.
String _trimTrailingSeparators(String value) {
  if (value == '/' || RegExp(r'^[A-Za-z]:[\\/]?$').hasMatch(value)) {
    return value.replaceAll(r'\', '/');
  }
  // `replaceFirst` (not `replaceAll`) because the JS source anchors the run to
  // the end of the string, so exactly one match can ever exist.
  return value.replaceFirst(RegExp(r'[\\/]+$'), '');
}

/// Puts a path into the one spelling containment can be tested in: forward
/// slashes, no trailing separator, and an upper-cased drive letter because
/// Windows volumes are case-insensitive.
///
/// Only the *drive letter* is case-folded. The rest of the path keeps its case,
/// so this stays wrong-by-design for a case-insensitive volume — faithfully so,
/// since upstream makes the same trade.
String _normalizeForPathComparison(String value) {
  final normalized = _trimTrailingSeparators(value.replaceAll(r'\', '/'));
  if (RegExp(r'^[A-Za-z]:/').hasMatch(normalized)) {
    return '${normalized.substring(0, 1).toUpperCase()}'
        '${normalized.substring(1)}';
  }
  return normalized;
}

/// Whether [candidatePath] is [rootPath] or lives under it.
///
/// A root that normalises away to nothing (`//`, `\\\\`) can contain nothing —
/// upstream's `!candidate || !root` guard, reproduced with an emptiness test
/// because Dart has no falsy strings.
bool _isPathWithinRoot(String candidatePath, String rootPath) {
  final candidate = _normalizeForPathComparison(candidatePath);
  final root = _normalizeForPathComparison(rootPath);
  if (candidate.isEmpty || root.isEmpty) return false;
  if (root == '/') return candidate.startsWith('/');
  if (candidate == root) return true;
  return candidate.startsWith('$root/');
}

final RegExp _driveRootPattern = RegExp(r'^([A-Za-z]:)[\\/]');
final RegExp _uncRootPattern = RegExp(r'^(\\\\[^\\]+\\[^\\]+)');

/// The widest cwd that still contains [value]: `/` on POSIX, `C:/` for a drive
/// path, `\\server\share` for a UNC path.
///
/// Returns null for anything that is not one of those three shapes, which is
/// how a malformed "absolute" path ends up with no preview target at all
/// instead of a cwd that would let the daemon read from somewhere unexpected.
String? _deriveFilesystemRootFromAbsolutePath(String value) {
  if (value.startsWith('/')) return '/';

  final driveMatch = _driveRootPattern.firstMatch(value);
  if (driveMatch != null) return '${driveMatch.group(1)}/';

  final uncMatch = _uncRootPattern.firstMatch(value);
  if (uncMatch != null) return uncMatch.group(1);

  return null;
}

/// `~`, `~/…`, or `~\…` — a path the daemon resolves against the *host's* home
/// directory rather than any workspace.
bool _isHomeRelativePath(String value) =>
    value == '~' || value.startsWith('~/') || value.startsWith(r'~\');

/// Picks the cwd a file preview of [path] should be read against.
///
/// The order is deliberate and each step exists for a reason:
///
/// 1. A home-relative path is handed to the daemon as-is with `cwd: "~"`; only
///    the host knows where home is.
/// 2. A relative path is meaningless without a workspace, so it needs an
///    absolute [workspaceRoot] and is refused otherwise.
/// 3. An absolute path *inside* the workspace keeps the workspace as its cwd,
///    which is what keeps a preview scoped to the project the user is in.
/// 4. Anything else absolute falls back to its own volume root — the narrowest
///    cwd that can still reach it.
///
/// Returns null when no cwd can be justified. A blank [path] (or one that is
/// only whitespace) is always null.
FilePreviewReadTarget? resolveFilePreviewReadTarget({
  required String path,
  String? workspaceRoot,
}) {
  final previewPath = path.trim();
  if (previewPath.isEmpty) return null;

  if (_isHomeRelativePath(previewPath)) {
    return FilePreviewReadTarget(cwd: '~', path: previewPath);
  }

  // Upstream writes `input.workspaceRoot?.trim()` and then `!workspaceRoot`,
  // so a whitespace-only root is as good as an absent one.
  final trimmedRoot = workspaceRoot?.trim() ?? '';
  final hasUsableRoot = trimmedRoot.isNotEmpty && isAbsolutePath(trimmedRoot);

  if (!isAbsolutePath(previewPath)) {
    if (!hasUsableRoot) return null;
    return FilePreviewReadTarget(cwd: trimmedRoot, path: previewPath);
  }

  if (hasUsableRoot && _isPathWithinRoot(previewPath, trimmedRoot)) {
    return FilePreviewReadTarget(cwd: trimmedRoot, path: previewPath);
  }

  final filesystemRoot = _deriveFilesystemRootFromAbsolutePath(previewPath);
  if (filesystemRoot == null) return null;

  return FilePreviewReadTarget(cwd: filesystemRoot, path: previewPath);
}

// ---------------------------------------------------------------------------
// projects/host-project-model.ts + projects/host-projects.ts
// ---------------------------------------------------------------------------

/// One host that has a given project checked out, and where.
///
/// Port of upstream `WorkspaceStructureHostPlacement`.
final class WorkspaceStructureHostPlacement {
  const WorkspaceStructureHostPlacement({
    required this.serverId,
    required this.iconWorkingDir,
    required this.canCreateWorktree,
  });

  final String serverId;

  /// The directory the project icon/avatar is derived from on *this* host —
  /// the same project can sit at different paths on different machines.
  final String iconWorkingDir;

  /// Whether a new worktree can be branched here, which is false for anything
  /// that is not a git checkout.
  final bool canCreateWorktree;

  @override
  bool operator ==(Object other) =>
      other is WorkspaceStructureHostPlacement &&
      other.serverId == serverId &&
      other.iconWorkingDir == iconWorkingDir &&
      other.canCreateWorktree == canCreateWorktree;

  @override
  int get hashCode => Object.hash(serverId, iconWorkingDir, canCreateWorktree);

  @override
  String toString() =>
      'WorkspaceStructureHostPlacement(serverId: $serverId, iconWorkingDir: '
      '$iconWorkingDir, canCreateWorktree: $canCreateWorktree)';
}

/// A project as the cross-host workspace structure describes it.
///
/// Port of upstream `WorkspaceStructureProject` from
/// `projects/workspace-structure.ts`, declared here because that builder is a
/// separate (unported) module and [buildHostProjectList] is typed against it.
final class WorkspaceStructureProject {
  const WorkspaceStructureProject({
    required this.projectKey,
    required this.projectName,
    required this.projectKind,
    required this.iconWorkingDir,
    required this.hosts,
    required this.workspaceKeys,
  });

  final String projectKey;
  final String projectName;
  final WorkspaceProjectKind projectKind;
  final String iconWorkingDir;
  final List<WorkspaceStructureHostPlacement> hosts;

  /// `"<serverId>:<workspaceId>"` for every workspace of this project, across
  /// every host.
  final List<String> workspaceKeys;
}

/// A project row in the host/project pickers.
///
/// Port of upstream `HostProjectListItem`. Structurally identical to
/// [WorkspaceStructureProject] on purpose: upstream keeps two names so the
/// picker never grows a dependency on how the structure is built, and
/// [buildHostProjectList] is the (identity) bridge between them. Dart's nominal
/// typing makes that copy explicit rather than free.
final class HostProjectListItem {
  const HostProjectListItem({
    required this.projectKey,
    required this.projectName,
    required this.projectKind,
    required this.iconWorkingDir,
    required this.hosts,
    required this.workspaceKeys,
  });

  final String projectKey;
  final String projectName;
  final WorkspaceProjectKind projectKind;
  final String iconWorkingDir;
  final List<WorkspaceStructureHostPlacement> hosts;
  final List<String> workspaceKeys;

  /// Structural copy, used by the tests and by callers that need to vary one
  /// field of a fixture. Not an upstream API; upstream spreads object literals.
  HostProjectListItem copyWith({
    String? projectKey,
    String? projectName,
    WorkspaceProjectKind? projectKind,
    String? iconWorkingDir,
    List<WorkspaceStructureHostPlacement>? hosts,
    List<String>? workspaceKeys,
  }) => HostProjectListItem(
    projectKey: projectKey ?? this.projectKey,
    projectName: projectName ?? this.projectName,
    projectKind: projectKind ?? this.projectKind,
    iconWorkingDir: iconWorkingDir ?? this.iconWorkingDir,
    hosts: hosts ?? this.hosts,
    workspaceKeys: workspaceKeys ?? this.workspaceKeys,
  );

  @override
  bool operator ==(Object other) =>
      other is HostProjectListItem &&
      other.projectKey == projectKey &&
      other.projectName == projectName &&
      other.projectKind == projectKind &&
      other.iconWorkingDir == iconWorkingDir &&
      _listEquals(other.hosts, hosts) &&
      _listEquals(other.workspaceKeys, workspaceKeys);

  @override
  int get hashCode => Object.hash(
    projectKey,
    projectName,
    projectKind,
    iconWorkingDir,
    Object.hashAll(hosts),
    Object.hashAll(workspaceKeys),
  );

  @override
  String toString() =>
      'HostProjectListItem(projectKey: $projectKey, projectName: $projectName, '
      'projectKind: ${projectKind.name}, iconWorkingDir: $iconWorkingDir, '
      'hosts: $hosts, workspaceKeys: $workspaceKeys)';
}

/// What the current route knows about a project before any daemon data has
/// arrived. Port of upstream `HostProjectRouteContext`.
///
/// Every field but [serverId] is optional because a deep link may name only a
/// host.
final class HostProjectRouteContext {
  const HostProjectRouteContext({
    required this.serverId,
    this.projectId,
    this.displayName,
    this.sourceDirectory,
  });

  final String serverId;
  final String? projectId;
  final String? displayName;
  final String? sourceDirectory;
}

/// Upstream `trimOptional`: trims, then collapses the empty result to "absent".
String? _trimOptional(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

/// Only a git checkout can be branched into a new worktree.
///
/// Kept separate from "can this project be listed at all" on purpose: a
/// directory project is perfectly listable, it just cannot spawn worktrees.
bool canCreateWorktreeForProjectKind(WorkspaceProjectKind projectKind) =>
    projectKind == WorkspaceProjectKind.git;

/// Projects the pickers should show, in the order the workspace structure
/// produced them.
///
/// Ordering is load-bearing: the structure builder already sorted projects by
/// display name, and several fallbacks below mean "the first one".
List<HostProjectListItem> buildHostProjectList({
  required List<WorkspaceStructureProject> projects,
}) => [
  for (final project in projects)
    HostProjectListItem(
      projectKey: project.projectKey,
      projectName: project.projectName,
      projectKind: project.projectKind,
      iconWorkingDir: project.iconWorkingDir,
      hosts: project.hosts,
      workspaceKeys: project.workspaceKeys,
    ),
];

/// The body of upstream's `useHostProjects` hook, minus the store read and the
/// `useMemo`.
///
/// The empty-input short circuit is upstream's, and is observable only as
/// identity: an empty input yields a const empty list rather than a fresh one.
List<HostProjectListItem> selectHostProjects(
  List<WorkspaceStructureProject> projects,
) {
  if (projects.isEmpty) return const [];
  return buildHostProjectList(projects: projects);
}

/// Synthesises the project the current route names, so the picker can show a
/// selection before the daemon's project list has loaded.
///
/// Returns null unless the route carries *both* a project id and a source
/// directory — without a directory there is nothing to create a workspace in.
/// The kind is assumed to be git (and therefore worktree-capable); the real
/// kind replaces this stub the moment the project list hydrates.
HostProjectListItem? hostProjectFromRoute(HostProjectRouteContext route) {
  final projectKey = _trimOptional(route.projectId);
  final iconWorkingDir = _trimOptional(route.sourceDirectory);
  if (projectKey == null || iconWorkingDir == null) return null;
  return HostProjectListItem(
    projectKey: projectKey,
    projectName: _trimOptional(route.displayName) ?? projectKey,
    projectKind: WorkspaceProjectKind.git,
    iconWorkingDir: iconWorkingDir,
    hosts: [
      WorkspaceStructureHostPlacement(
        // Not trimmed: upstream passes the route's serverId straight through.
        serverId: route.serverId,
        iconWorkingDir: iconWorkingDir,
        canCreateWorktree: true,
      ),
    ],
    workspaceKeys: const [],
  );
}

/// Synthesises the project of the workspace the user was last in, so "new
/// workspace" can default to the project they were already working on.
///
/// Unlike [hostProjectFromRoute] this knows the real kind, so the placement's
/// worktree capability is accurate rather than assumed.
HostProjectListItem? hostProjectFromWorkspace({
  required String serverId,
  required WorkspaceDescriptor? workspace,
}) {
  if (workspace == null) return null;
  final projectKey = workspace.projectId.trim();
  final iconWorkingDir = workspace.projectRootPath.trim();
  if (projectKey.isEmpty || iconWorkingDir.isEmpty) return null;
  return HostProjectListItem(
    projectKey: projectKey,
    // Upstream writes `projectDisplayName || projectKey`, an *untrimmed* falsy
    // test: only a genuinely empty display name falls back, a whitespace-only
    // one is kept as-is.
    projectName: workspace.projectDisplayName.isEmpty
        ? projectKey
        : workspace.projectDisplayName,
    projectKind: workspace.projectKind,
    iconWorkingDir: iconWorkingDir,
    hosts: [
      WorkspaceStructureHostPlacement(
        serverId: serverId,
        iconWorkingDir: iconWorkingDir,
        canCreateWorktree: canCreateWorktreeForProjectKind(
          workspace.projectKind,
        ),
      ),
    ],
    workspaceKeys: ['$serverId:${workspace.id}'],
  );
}

bool _projectCanCreateWorktree(HostProjectListItem project) =>
    project.hosts.any((host) => host.canCreateWorktree);

/// Where [project] lives on [serverId], or null when it is not on that host.
String? getHostProjectSourceDirectory(
  HostProjectListItem project,
  String serverId,
) {
  for (final host in project.hosts) {
    if (host.serverId == serverId) return host.iconWorkingDir;
  }
  return null;
}

/// Whether a new workspace can be created for [project] on [serverId].
///
/// The project must be on that host at all. Beyond that, a host that supports
/// workspace multiplicity ([allowAllProjects]) can hold several workspaces per
/// directory and so accepts non-git projects too; a host without it can only
/// take projects that can be branched into their own worktree.
bool canCreateWorkspaceForHostProject({
  required HostProjectListItem project,
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

/// [projects] narrowed to the ones the new-workspace form may offer for
/// [serverId], in their original order.
List<HostProjectListItem> filterWorkspaceProjectsForHost({
  required List<HostProjectListItem> projects,
  required String serverId,
  required bool allowAllProjects,
}) => [
  for (final project in projects)
    if (canCreateWorkspaceForHostProject(
      project: project,
      serverId: serverId,
      allowAllProjects: allowAllProjects,
    ))
      project,
];

/// Which project the new-*workspace* form starts on.
///
/// Route first, then the last active project, then simply the first project in
/// the list. Each candidate is re-read from [projects] when a hydrated copy
/// exists, because a route/last-active stub carries an assumed host placement
/// that the real data may contradict.
///
/// The final fallback is unconditional: upstream returns `projects[0]` without
/// checking it against [serverId], so a form can legitimately open on a project
/// that cannot be created on the selected host and rely on the submit button
/// being disabled instead.
HostProjectListItem? resolveInitialWorkspaceProject({
  required HostProjectListItem? routeProject,
  required HostProjectListItem? lastActiveProject,
  required List<HostProjectListItem> projects,
  required String serverId,
  required bool allowAllProjects,
}) {
  for (final candidate in [routeProject, lastActiveProject]) {
    if (candidate == null) continue;
    var hydratedProject = candidate;
    for (final project in projects) {
      if (project.projectKey == candidate.projectKey) {
        hydratedProject = project;
        break;
      }
    }
    if (canCreateWorkspaceForHostProject(
      project: hydratedProject,
      serverId: serverId,
      allowAllProjects: allowAllProjects,
    )) {
      return hydratedProject;
    }
  }

  return projects.isEmpty ? null : projects.first;
}

/// Which project the new-*worktree* form starts on.
///
/// Deliberately host-agnostic, unlike [resolveInitialWorkspaceProject]: a
/// worktree can be branched wherever the project has a worktree-capable
/// placement, so only that capability is checked. When nothing qualifies the
/// form opens with no project rather than an unusable one.
///
/// Note the asymmetry with [resolveInitialWorkspaceProject]: the route and
/// last-active candidates are used *as given*, never re-read from [projects].
HostProjectListItem? resolveInitialWorktreeProject({
  required HostProjectListItem? routeProject,
  required HostProjectListItem? lastActiveProject,
  required List<HostProjectListItem> projects,
}) {
  if (routeProject != null && _projectCanCreateWorktree(routeProject)) {
    return routeProject;
  }
  if (lastActiveProject != null &&
      _projectCanCreateWorktree(lastActiveProject)) {
    return lastActiveProject;
  }
  for (final project in projects) {
    if (_projectCanCreateWorktree(project)) return project;
  }
  return null;
}

/// Resolves the user's explicit selection back to a project.
///
/// The route and last-active stubs are consulted after [projects] so a
/// selection made before hydration survives it — otherwise the picker would
/// blank out for as long as the project list takes to load. An empty or
/// whitespace-only key means "nothing selected".
HostProjectListItem? resolveSelectedHostProject({
  required String? selectedProjectKey,
  required List<HostProjectListItem> projects,
  required HostProjectListItem? routeProject,
  required HostProjectListItem? lastActiveProject,
}) {
  final key = selectedProjectKey?.trim() ?? '';
  if (key.isEmpty) return null;

  for (final project in projects) {
    if (project.projectKey == key) return project;
  }
  if (routeProject?.projectKey == key) return routeProject;
  if (lastActiveProject?.projectKey == key) return lastActiveProject;
  return null;
}

// ---------------------------------------------------------------------------
// hooks/use-preferred-editor.ts
// ---------------------------------------------------------------------------

/// Storage key the preferred editor is persisted under. Frozen: changing it
/// silently forgets every user's choice.
const String preferredEditorStorageKey = '@paseo:preferred-editor';

/// Upstream's `PREFERRED_EDITOR_QUERY_KEY`, kept so a host wiring this into a
/// real query cache uses the same key upstream did.
const List<String> preferredEditorQueryKey = ['preferred-editor'];

/// The stored preference as a *three*-state value.
///
/// Upstream leans on JavaScript's `undefined`/`null` split: `undefined` means
/// "the load has not finished", `null` means "loaded, nothing stored". Dart has
/// only `null`, so the distinction becomes this sealed pair — it is load
/// bearing, because [resolvePreferredEditorId] must not pick a default while
/// the real answer is still in flight.
sealed class StoredPreferredEditorId {
  const StoredPreferredEditorId();
}

/// Upstream's `undefined`: the preference has not been read yet.
final class PendingPreferredEditorId extends StoredPreferredEditorId {
  const PendingPreferredEditorId();

  @override
  bool operator ==(Object other) => other is PendingPreferredEditorId;

  @override
  int get hashCode => (PendingPreferredEditorId).hashCode;

  @override
  String toString() => 'PendingPreferredEditorId()';
}

/// The preference has been read; [editorId] is null when nothing was stored.
final class KnownPreferredEditorId extends StoredPreferredEditorId {
  const KnownPreferredEditorId(this.editorId);

  final String? editorId;

  @override
  bool operator ==(Object other) =>
      other is KnownPreferredEditorId && other.editorId == editorId;

  @override
  int get hashCode => Object.hash(KnownPreferredEditorId, editorId);

  @override
  String toString() => 'KnownPreferredEditorId($editorId)';
}

/// Reads the persisted editor id, treating blank as unset.
///
/// Upstream's `if (!stored)` also catches the empty string, and the following
/// `stored.trim() || null` catches whitespace — both collapse to "no
/// preference", so a corrupted blank value cannot pin the picker to nothing.
Future<String?> loadPreferredEditor(KeyValueStorage storage) async {
  final stored = await storage.getItem(preferredEditorStorageKey);
  if (stored == null || stored.isEmpty) return null;
  final trimmed = stored.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Which editor "Open in…" should use.
///
/// The stored choice wins whenever it is still installed — including ids this
/// build has never heard of, so a preference set by a newer build (or a
/// user-defined `script:` target) survives a downgrade. Otherwise the first
/// available target wins, which is why the registry's order is meaningful:
/// the platform's own file manager sits there as the universal fallback.
///
/// Returns null while [storedEditorId] is still [PendingPreferredEditorId] —
/// defaulting mid-load would flash the wrong editor into the UI and, worse,
/// could be written back as a real choice. Also null when nothing is
/// available at all.
///
/// A stored empty string behaves as "nothing stored" (upstream's
/// `storedEditorId &&` is a falsy test), so it falls through to the first
/// available id rather than matching an empty entry.
String? resolvePreferredEditorId(
  List<String> availableEditorIds,
  StoredPreferredEditorId storedEditorId,
) {
  switch (storedEditorId) {
    case PendingPreferredEditorId():
      return null;
    case KnownPreferredEditorId(:final editorId):
      if (editorId != null &&
          editorId.isNotEmpty &&
          availableEditorIds.any((available) => available == editorId)) {
        return editorId;
      }
      return availableEditorIds.isEmpty ? null : availableEditorIds.first;
  }
}

/// The ids of [editors] in reply order, ready for [resolvePreferredEditorId].
///
/// Exists so callers do not re-derive the mapping between the
/// `list_available_editors` reply and this module's `readonly string[]`.
List<String> availableEditorIdsOf(Iterable<AvailableEditor> editors) => [
  for (final editor in editors) editor.id,
];

/// The persisted preferred-editor preference, as upstream's `usePreferredEditor`
/// hook exposes it.
///
/// Ported as a plain controller rather than against this repo's
/// [KeyValueStorage]-backed query-cache helper on purpose: that cache maps
/// react-query's `undefined` onto Dart `null`, and this module needs to cache a
/// *real* null (`updatePreferredEditor(null)` clears the choice while leaving
/// the query resolved). Two states cannot share one representation here, so the
/// controller keeps them apart itself.
final class PreferredEditorController {
  PreferredEditorController(this.storage);

  final MutableKeyValueStorage storage;

  Future<void>? _load;
  bool _isLoading = true;
  String? _editorId;

  /// Upstream's `isPending`. True until the first read resolves — or until an
  /// update writes a value, which resolves the query the same way
  /// `setQueryData` does.
  bool get isLoading => _isLoading;

  /// Upstream's `isPending ? undefined : (data ?? null)`.
  StoredPreferredEditorId get preferredEditorId => _isLoading
      ? const PendingPreferredEditorId()
      : KnownPreferredEditorId(_editorId);

  /// Runs the read once and caches it forever.
  ///
  /// Upstream's query sets `staleTime: Infinity, gcTime: Infinity`, so the
  /// preference is read exactly once per session no matter how many components
  /// mount the hook; repeated calls here await the same future.
  ///
  /// Deviation: upstream's query, if it were to resolve *after* an
  /// [updatePreferredEditor], would overwrite the newer value. That race is not
  /// modelled — an update while the initial read is in flight keeps the update.
  Future<void> ensureLoaded() => _load ??= _runLoad();

  Future<void> _runLoad() async {
    final loaded = await loadPreferredEditor(storage);
    if (!_isLoading) return;
    _editorId = loaded;
    _isLoading = false;
  }

  /// Records [editorId] as the user's choice, or clears it when null.
  ///
  /// The in-memory value is updated *before* the write, matching upstream's
  /// `setQueryData` then `await AsyncStorage…`: the UI reflects the choice
  /// immediately and a failing write surfaces as a rejected future rather than
  /// a silent revert.
  ///
  /// An empty string is stored in memory but *removed* from storage — upstream's
  /// `if (editorId)` is a falsy test. The value therefore does not survive a
  /// restart, which is the same outcome [loadPreferredEditor] would produce for
  /// it anyway.
  Future<void> updatePreferredEditor(String? editorId) async {
    _editorId = editorId;
    _isLoading = false;
    _load ??= Future<void>.value();
    if (editorId != null && editorId.isNotEmpty) {
      await storage.setItem(preferredEditorStorageKey, editorId);
      return;
    }
    await storage.removeItem(preferredEditorStorageKey);
  }
}

// ---------------------------------------------------------------------------
// screens/settings/daemon-restart.ts
// ---------------------------------------------------------------------------

/// The two fields of the desktop shell's daemon status this decision reads.
///
/// Declared narrowly, as upstream does, rather than reusing this repo's
/// [DaemonStatus]: that type carries a `ServerHello` with `desktopManaged` but
/// no `serverId`, and the whole point of this rule is matching the settings
/// screen's host id against the desktop daemon's.
final class DesktopDaemonRestartStatus {
  const DesktopDaemonRestartStatus({
    required this.desktopManaged,
    required this.serverId,
  });

  /// Whether the desktop app started (and therefore owns) this daemon.
  final bool desktopManaged;

  /// The host id the desktop daemon is registered under.
  final String serverId;
}

/// Everything [restartDaemonFromSettings] can do to the world.
///
/// Taken as a value object of closures so the ordering rule below — which of
/// these get called, and in what order — is testable with no Electron host, no
/// settings file, and no live daemon.
final class SettingsDaemonRestartDeps {
  const SettingsDaemonRestartDeps({
    required this.getIsElectron,
    required this.getDesktopDaemonStatus,
    required this.getDesktopSettings,
    required this.restartDesktopDaemon,
    required this.restartServer,
  });

  /// Whether there is a desktop shell at all. Checked first and synchronously,
  /// so the web build never touches the desktop bridge.
  final bool Function() getIsElectron;

  final Future<DesktopDaemonRestartStatus> Function() getDesktopDaemonStatus;

  /// Reads the desktop-owned settings document. Reuses this repo's
  /// [DesktopDaemonSettings]; only `manageBuiltInDaemon` is consulted, and
  /// `keepRunningAfterQuit` is ignored by this rule.
  final Future<DesktopDaemonSettings> Function() getDesktopSettings;

  /// Restarts the built-in daemon through the desktop shell. The returned
  /// status is discarded, exactly as upstream discards it — the settings screen
  /// re-reads status separately.
  final Future<DaemonStatus> Function() restartDesktopDaemon;

  /// Asks the daemon to restart itself over its own RPC, tagging the request
  /// with a reason for the daemon's logs.
  final Future<void> Function(String reason) restartServer;
}

/// Whether [hostServerId] names the daemon this desktop app is managing.
///
/// Every check short-circuits, and the order matters: the settings document is
/// only read once the host is known to be the local desktop-managed one, so a
/// remote host's restart never fails on an unreadable local settings file.
Future<bool> _isLocalDesktopManagedDaemon(
  String hostServerId,
  SettingsDaemonRestartDeps deps,
) async {
  if (!deps.getIsElectron()) return false;

  final desktopDaemonStatus = await deps.getDesktopDaemonStatus();
  if (!desktopDaemonStatus.desktopManaged) return false;

  final normalizedHostServerId = hostServerId.trim();
  final normalizedDesktopServerId = desktopDaemonStatus.serverId.trim();

  if (normalizedHostServerId.isEmpty ||
      normalizedHostServerId != normalizedDesktopServerId) {
    return false;
  }

  final desktopSettings = await deps.getDesktopSettings();
  return desktopSettings.manageBuiltInDaemon;
}

/// Restarts the daemon behind [hostServerId] from the settings screen.
///
/// A daemon the desktop app spawned has to be restarted through the shell —
/// asking it to restart itself over RPC would kill a child process the shell
/// then has to notice and respawn. Every other host (remote, or a local daemon
/// the user started by hand) restarts itself over RPC.
///
/// Failures from the desktop path propagate rather than falling back to the RPC
/// path: a half-restarted managed daemon must surface, not be papered over by a
/// second restart attempt against a process that may no longer be there.
Future<void> restartDaemonFromSettings({
  required String hostServerId,
  required String reason,
  required SettingsDaemonRestartDeps deps,
}) async {
  if (await _isLocalDesktopManagedDaemon(hostServerId, deps)) {
    await deps.restartDesktopDaemon();
    return;
  }

  await deps.restartServer(reason);
}

// ---------------------------------------------------------------------------
// utils/review-attachments.ts
// ---------------------------------------------------------------------------

/// Default forge for an item that does not name one — every pre-forge daemon
/// only ever searched GitHub.
const String defaultForgeAttachmentForge = 'github';

/// A forge item attached to an agent prompt.
///
/// Separate from `package:agent_protocol`'s sealed `AgentAttachment` (which
/// models only `text` and `review` and cannot be extended from here). [toJson]
/// emits exactly the object upstream builds, so the wire payload is identical.
sealed class ForgeAgentAttachment {
  const ForgeAgentAttachment();

  /// The attachment's discriminator on the wire.
  String get type;

  /// The MIME type the daemon dispatches on. Paired one-to-one with [type];
  /// both are sent because older daemons keyed off one or the other.
  String get mimeType;

  /// The attachment object, with optional fields omitted rather than set to
  /// null — upstream builds them with `...(value ? { value } : {})`, and an
  /// absent key is what the daemon's schema expects.
  Map<String, Object?> toJson();
}

/// A pull/merge request in the current, forge-agnostic dialect.
final class ForgeChangeRequestAttachment extends ForgeAgentAttachment {
  const ForgeChangeRequestAttachment({
    required this.forge,
    required this.number,
    required this.title,
    required this.url,
    this.body,
    this.projectPath,
    this.baseRefName,
    this.headRefName,
  });

  @override
  String get type => 'forge_change_request';

  @override
  String get mimeType => 'application/paseo-forge-change-request';

  final String forge;
  final int number;
  final String title;
  final String url;
  final String? body;
  final String? projectPath;
  final String? baseRefName;
  final String? headRefName;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'mimeType': mimeType,
    'forge': forge,
    'number': number,
    'title': title,
    'url': url,
    if (body != null) 'body': body,
    if (projectPath != null) 'projectPath': projectPath,
    if (baseRefName != null) 'baseRefName': baseRefName,
    if (headRefName != null) 'headRefName': headRefName,
  };

  @override
  bool operator ==(Object other) =>
      other is ForgeChangeRequestAttachment &&
      other.forge == forge &&
      other.number == number &&
      other.title == title &&
      other.url == url &&
      other.body == body &&
      other.projectPath == projectPath &&
      other.baseRefName == baseRefName &&
      other.headRefName == headRefName;

  @override
  int get hashCode => Object.hash(
    forge,
    number,
    title,
    url,
    body,
    projectPath,
    baseRefName,
    headRefName,
  );

  @override
  String toString() => 'ForgeChangeRequestAttachment(${toJson()})';
}

/// An issue in the current, forge-agnostic dialect.
///
/// Carries no branch names — an issue has no refs, which is the whole reason
/// this is a separate shape from [ForgeChangeRequestAttachment].
final class ForgeIssueAttachment extends ForgeAgentAttachment {
  const ForgeIssueAttachment({
    required this.forge,
    required this.number,
    required this.title,
    required this.url,
    this.body,
    this.projectPath,
  });

  @override
  String get type => 'forge_issue';

  @override
  String get mimeType => 'application/paseo-forge-issue';

  final String forge;
  final int number;
  final String title;
  final String url;
  final String? body;
  final String? projectPath;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'mimeType': mimeType,
    'forge': forge,
    'number': number,
    'title': title,
    'url': url,
    if (body != null) 'body': body,
    if (projectPath != null) 'projectPath': projectPath,
  };

  @override
  bool operator ==(Object other) =>
      other is ForgeIssueAttachment &&
      other.forge == forge &&
      other.number == number &&
      other.title == title &&
      other.url == url &&
      other.body == body &&
      other.projectPath == projectPath;

  @override
  int get hashCode => Object.hash(forge, number, title, url, body, projectPath);

  @override
  String toString() => 'ForgeIssueAttachment(${toJson()})';
}

/// A pull request in the pre-forge dialect, for daemons too old to understand
/// `forge_change_request`.
///
/// Has no `forge` and no `projectPath`: those daemons only knew GitHub, and
/// only in the workspace's own checkout.
final class LegacyGitHubPullRequestAttachment extends ForgeAgentAttachment {
  const LegacyGitHubPullRequestAttachment({
    required this.number,
    required this.title,
    required this.url,
    this.body,
    this.baseRefName,
    this.headRefName,
  });

  @override
  String get type => 'github_pr';

  @override
  String get mimeType => 'application/github-pr';

  final int number;
  final String title;
  final String url;
  final String? body;
  final String? baseRefName;
  final String? headRefName;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'mimeType': mimeType,
    'number': number,
    'title': title,
    'url': url,
    if (body != null) 'body': body,
    if (baseRefName != null) 'baseRefName': baseRefName,
    if (headRefName != null) 'headRefName': headRefName,
  };

  @override
  bool operator ==(Object other) =>
      other is LegacyGitHubPullRequestAttachment &&
      other.number == number &&
      other.title == title &&
      other.url == url &&
      other.body == body &&
      other.baseRefName == baseRefName &&
      other.headRefName == headRefName;

  @override
  int get hashCode =>
      Object.hash(number, title, url, body, baseRefName, headRefName);

  @override
  String toString() => 'LegacyGitHubPullRequestAttachment(${toJson()})';
}

/// An issue in the pre-forge dialect.
final class LegacyGitHubIssueAttachment extends ForgeAgentAttachment {
  const LegacyGitHubIssueAttachment({
    required this.number,
    required this.title,
    required this.url,
    this.body,
  });

  @override
  String get type => 'github_issue';

  @override
  String get mimeType => 'application/github-issue';

  final int number;
  final String title;
  final String url;
  final String? body;

  @override
  Map<String, Object?> toJson() => {
    'type': type,
    'mimeType': mimeType,
    'number': number,
    'title': title,
    'url': url,
    if (body != null) 'body': body,
  };

  @override
  bool operator ==(Object other) =>
      other is LegacyGitHubIssueAttachment &&
      other.number == number &&
      other.title == title &&
      other.url == url &&
      other.body == body;

  @override
  int get hashCode => Object.hash(number, title, url, body);

  @override
  String toString() => 'LegacyGitHubIssueAttachment(${toJson()})';
}

/// Upstream spreads optional fields with `...(value ? { value } : {})`, a falsy
/// test — so an empty string is dropped exactly like a missing one.
String? _omitIfBlank(String? value) =>
    value == null || value.isEmpty ? null : value;

/// Turns the forge search result the user picked into an agent attachment.
///
/// Returns null when nothing is selected, so a caller can hand the raw
/// selection straight through without a guard of its own.
///
/// A change request keeps its base/head refs so the agent can check the branch
/// out; an issue has none. Both keep `projectPath` when the item came from a
/// project other than the workspace's own.
ForgeAgentAttachment? buildForgeAttachmentFromSearchItem(
  ForgeSearchItem? item,
) {
  if (item == null) return null;

  if (item.kind == ForgeSearchKind.changeRequest) {
    return ForgeChangeRequestAttachment(
      // `??` is nullish, not falsy: an item that explicitly reports an empty
      // forge keeps the empty string rather than defaulting to GitHub.
      forge: item.forge ?? defaultForgeAttachmentForge,
      number: item.number,
      title: item.title,
      url: item.url,
      body: _omitIfBlank(item.body),
      projectPath: _omitIfBlank(item.projectPath),
      baseRefName: _omitIfBlank(item.baseRefName),
      headRefName: _omitIfBlank(item.headRefName),
    );
  }

  return ForgeIssueAttachment(
    forge: item.forge ?? defaultForgeAttachmentForge,
    number: item.number,
    title: item.title,
    url: item.url,
    body: _omitIfBlank(item.body),
    projectPath: _omitIfBlank(item.projectPath),
  );
}

/// Upstream's `buildGitHubAttachmentFromSearchItem`, kept as an alias of
/// [buildForgeAttachmentFromSearchItem] for callers written before forges were
/// generalised. Identical function, not a copy.
const ForgeAgentAttachment? Function(ForgeSearchItem?)
buildGitHubAttachmentFromSearchItem = buildForgeAttachmentFromSearchItem;

/// The same selection in the pre-forge wire dialect, for daemons that predate
/// `forge_*` attachments.
///
/// Drops `forge` and `projectPath` entirely — an old daemon would reject the
/// unknown keys, and it could not act on a cross-project path anyway.
ForgeAgentAttachment? buildLegacyGitHubAttachmentFromSearchItem(
  ForgeSearchItem? item,
) {
  if (item == null) return null;

  if (item.kind == ForgeSearchKind.changeRequest) {
    return LegacyGitHubPullRequestAttachment(
      number: item.number,
      title: item.title,
      url: item.url,
      body: _omitIfBlank(item.body),
      baseRefName: _omitIfBlank(item.baseRefName),
      headRefName: _omitIfBlank(item.headRefName),
    );
  }

  return LegacyGitHubIssueAttachment(
    number: item.number,
    title: item.title,
    url: item.url,
    body: _omitIfBlank(item.body),
  );
}

// ---------------------------------------------------------------------------
// workspace-service-routes/store.ts
// ---------------------------------------------------------------------------

/// How a workspace script's service URL is reached.
///
/// Port of upstream's `WorkspaceScriptLinkKind` from
/// `utils/workspace-script-links.ts`. Only the union is ported here — the link
/// *builders* in that module belong to their own port; this store just needs to
/// name and validate the three choices.
enum WorkspaceScriptLinkKind {
  /// A publicly shareable tunnel URL.
  public('public'),

  /// The Paseo-hosted proxy route.
  paseo('paseo'),

  /// Straight at the host's own address and port.
  direct('direct');

  const WorkspaceScriptLinkKind(this.wireName);

  /// The exact string persisted and sent on the wire.
  final String wireName;

  /// Upstream's `isWorkspaceScriptLinkKind` type guard: anything that is not
  /// one of the three spellings is not a kind, including a valid-looking value
  /// of the wrong type.
  static WorkspaceScriptLinkKind? tryFromWire(Object? value) => switch (value) {
    'public' => public,
    'paseo' => paseo,
    'direct' => direct,
    _ => null,
  };
}

/// The zustand persist key. Frozen: changing it forgets every stored route.
const String workspaceServiceRoutePreferencesStorageName =
    'workspace-service-route-preferences';

/// The persisted schema version. A blob stamped with anything else is dropped,
/// because the store registers no migration.
const int workspaceServiceRoutePreferencesVersion = 1;

/// Keeps only the entries that are still valid route kinds, in their stored
/// order.
///
/// This is upstream's `merge`-time sanitiser and the reason a hand-edited or
/// downgraded blob cannot wedge the UI on a route this build cannot render:
/// unknown values are dropped per host, not per blob, so one bad entry does not
/// cost the user their other hosts' choices.
///
/// [value] is the *whole* persisted state object (`{ byServerId: … }`), not the
/// map itself, matching what zustand hands `merge`. Anything that is not an
/// object — including null, a list, or a primitive — yields an empty map.
Map<String, WorkspaceScriptLinkKind> sanitizeWorkspaceServiceRoutePreferences(
  Object? value,
) {
  if (value is! Map) return const {};
  final byServerId = value['byServerId'];
  if (byServerId is! Map) return const {};

  final result = <String, WorkspaceScriptLinkKind>{};
  byServerId.forEach((serverId, kind) {
    if (serverId is! String) return;
    final parsed = WorkspaceScriptLinkKind.tryFromWire(kind);
    if (parsed != null) result[serverId] = parsed;
  });
  return result;
}

/// Each host's preferred way of reaching its workspace scripts, persisted.
///
/// Port of upstream's zustand store. The persisted document is
/// `{"state":{"byServerId":{…}},"version":1}`, written on every change and
/// sanitised on the way back in by [sanitizeWorkspaceServiceRoutePreferences].
///
/// Deviations from the zustand original, both forced by Dart having no implicit
/// background task queue:
///
/// * [setPreferredRoute] returns a future. Upstream's setter is synchronous and
///   the persist middleware writes in the background; awaiting here is how a
///   caller (or a test) knows the write landed. The in-memory value is updated
///   before the write either way, so a synchronous read after a non-awaited
///   call sees the same thing upstream would.
/// * [rehydrate] must be called explicitly. Upstream hydrates on construction
///   and exposes `persist.rehydrate()` for a re-read; until it completes the
///   store reads as empty in both.
final class WorkspaceServiceRoutePreferencesStore {
  WorkspaceServiceRoutePreferencesStore(this.storage, {this.onRehydrateError});

  final KeyValueStorage storage;

  /// Port of upstream's `console.error` when a persisted blob is stamped with a
  /// version this build has no migration for. The preferences are dropped
  /// either way; this only exists so a host can log it without this module
  /// choosing a logging framework.
  final void Function(String message)? onRehydrateError;

  Map<String, WorkspaceScriptLinkKind> _byServerId =
      const <String, WorkspaceScriptLinkKind>{};

  /// The current preferences, in insertion order. Empty before [rehydrate].
  Map<String, WorkspaceScriptLinkKind> get byServerId =>
      UnmodifiableMapView(_byServerId);

  /// Reads the persisted blob and replaces the in-memory state with its
  /// sanitised contents.
  ///
  /// A missing key, a JSON `null`, a non-object blob, or a version mismatch all
  /// land on the same empty result — zustand calls `merge` with `undefined` in
  /// every one of those cases, and this store's `merge` sanitises `undefined`
  /// to `{}`.
  ///
  /// Malformed JSON is *not* swallowed: `createJSONStorage` lets `JSON.parse`
  /// throw and the hydrate promise rejects, so the [FormatException] from
  /// [jsonDecode] propagates here too.
  Future<void> rehydrate() async {
    final raw = await storage.getItem(
      workspaceServiceRoutePreferencesStorageName,
    );

    Object? persistedState;
    if (raw != null) {
      final decoded = jsonDecode(raw);
      // Upstream's `if (deserializedStorageValue)` is a falsy test; anything
      // that is not a JSON object has neither `.version` nor `.state`, so both
      // branches collapse to "no persisted state".
      if (decoded is Map) {
        final version = decoded['version'];
        if (version is num &&
            version != workspaceServiceRoutePreferencesVersion) {
          onRehydrateError?.call(
            'State loaded from storage couldn\'t be migrated since no migrate '
            'function was provided',
          );
        } else {
          persistedState = decoded['state'];
        }
      }
    }

    _byServerId = sanitizeWorkspaceServiceRoutePreferences(persistedState);
  }

  /// Records [kind] as the preferred route for [serverId] and persists.
  ///
  /// An existing host keeps its position in the map, matching the JS spread
  /// `{ ...state.byServerId, [serverId]: kind }`, so the persisted key order is
  /// stable across updates.
  Future<void> setPreferredRoute(
    String serverId,
    WorkspaceScriptLinkKind kind,
  ) async {
    _byServerId = {..._byServerId, serverId: kind};
    await _persist();
  }

  Future<void> _persist() => storage.setItem(
    workspaceServiceRoutePreferencesStorageName,
    jsonEncode({
      'state': {
        'byServerId': {
          for (final entry in _byServerId.entries)
            entry.key: entry.value.wireName,
        },
      },
      'version': workspaceServiceRoutePreferencesVersion,
    }),
  );
}
