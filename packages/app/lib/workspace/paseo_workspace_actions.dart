/// Port of six frozen Paseo 0.2.0 modules that each answer "what should this
/// user-initiated workspace action actually *do*". They live in one library
/// because every one of them is a small, store-free decision procedure that the
/// screen or controller above it feeds observed state into, and because none of
/// them is large enough to justify a file of its own:
///
/// - `workspace/workspace-archive.ts` — hide a workspace row the instant the
///   user archives it, and put it back if the daemon says no.
/// - `workspace/open-target-planner.ts` — the "Open in…" menu: which desktop
///   editors and which forge web URL a workspace (and its active file) can be
///   opened at right now.
/// - `screens/workspace/workspace-bulk-close.ts` — classifying a tab strip for
///   "close all", the confirmation copy that describes the damage, and the
///   close itself.
/// - `screens/new-workspace-picker-state.ts` — the branch/change-request
///   picker's selection reducer and the one PR attachment it owns.
/// - `screens/new-workspace/project-selection.ts` — which project the
///   new-workspace screen has selected as hosts connect and projects hydrate.
/// - `screens/settings/appearance/apply-appearance.ts` — pushing the user's
///   font and syntax-theme choices onto every registered theme.
///
/// ## What this library deliberately does *not* re-implement
///
/// - [WorkspaceArchiveTarget] is already in `workspace/paseo_workspace_pins.dart`
///   (upstream declares the same interface twice, in `workspace-archive.ts` and
///   in `project-workspace-archive.ts`); it is imported and re-exported here so
///   `selectProjectWorkspacesToArchive` can feed
///   [archiveWorkspacesOptimistically] without a conversion.
/// - The pending-archive registry (upstream `contexts/session-workspace-upserts.ts`)
///   is already in `core/paseo_session_projection.dart`; [markWorkspaceArchivePending]
///   and [clearWorkspaceArchivePending] are called directly, so the optimistic
///   hide and the upsert suppression can never disagree.
/// - Workspace id/key identity (upstream `utils/workspace-identity.ts`) is
///   already in `workspace/paseo_workspace_paths.dart`;
///   [resolveWorkspaceMapKeyByIdentity] is reused for the snapshot lookup.
/// - Active-file path resolution (upstream `workspace/file-open.ts`) is already
///   in `workspace/workspace_file_open.dart`; [resolveWorkspaceFilePaths],
///   [WorkspaceFileLocation] and [ResolvedWorkspaceFilePaths] are reused as-is.
/// - Forge identity, presentation and web-URL grammar (upstream `git/forge.ts`)
///   are already in `core/forge.dart` + `core/forge_url.dart`;
///   [forgeFromRemoteUrl] and [getForgePresentation] are reused, which is what
///   makes the blob/tree URLs byte-identical to upstream's.
/// - Tab targets and target equality (upstream `workspace-tabs/model.ts`) are
///   already in `workspace/workspace_tab_model.dart`; [WorkspaceTab],
///   [WorkspaceTabTarget] and [workspaceTabTargetsEqual] are reused instead of a
///   local `WorkspaceTabDescriptor`.
/// - The picker's row union (upstream `screens/new-workspace-picker-item.ts`) is
///   already in `core/paseo_new_workspace_rules.dart`; [PickerItem],
///   [BranchPickerItem] and [ChangeRequestPickerItem] are reused.
/// - The project row (upstream `projects/host-project-model.ts`) is already in
///   `core/paseo_app_misc.dart`; [HostProjectListItem] is reused.
/// - The theme key set is already in `state/appearance_provider.dart`;
///   [AppThemeName] is reused rather than a second copy of the six keys, and
///   `core/theme.dart` keeps owning what those keys *look* like.
/// - The syntax-theme id set is already in `hooks/paseo_agent_settings_rules.dart`;
///   [SyntaxThemeId] is reused.
///
/// ## Injected capabilities
///
/// Upstream reaches for module-level singletons — a Zustand store, an i18next
/// instance, `UnistylesRuntime`, `@getpaseo/highlight`. None of those exist here,
/// and reaching for a Riverpod container from a pure rule would make these
/// untestable, so each is a constructor/parameter injection with a documented
/// default where a sensible one exists.
library;

import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart' show WorkspaceDescriptor;

import '../core/forge.dart' show forgeFromRemoteUrl, getForgePresentation;
import '../core/forge_url.dart' show ForgeBlobUrlInput, ForgeBranchTreeUrlInput;
import '../core/paseo_app_misc.dart' show HostProjectListItem;
import '../core/paseo_new_workspace_rules.dart'
    show BranchPickerItem, ChangeRequestPickerItem, PickerItem;
import '../core/paseo_session_projection.dart'
    show clearWorkspaceArchivePending, markWorkspaceArchivePending;
import '../hooks/paseo_agent_settings_rules.dart' show SyntaxThemeId;
import '../state/appearance_provider.dart' show AppThemeName;
import 'paseo_workspace_paths.dart' show resolveWorkspaceMapKeyByIdentity;
import 'paseo_workspace_pins.dart' show WorkspaceArchiveTarget;
import 'workspace_file_open.dart'
    show
        ResolvedWorkspaceFilePaths,
        WorkspaceFileLocation,
        resolveWorkspaceFilePaths;
import 'workspace_tab_model.dart'
    show
        WorkspaceAgentTabTarget,
        WorkspaceTab,
        WorkspaceTabTarget,
        WorkspaceTerminalTabTarget,
        workspaceTabTargetsEqual;

export '../core/paseo_new_workspace_rules.dart'
    show BranchPickerItem, ChangeRequestPickerItem, PickerItem;
export 'paseo_workspace_pins.dart' show WorkspaceArchiveTarget;

// ===========================================================================
// workspace/workspace-archive.ts
// ===========================================================================

/// The daemon's answer to an archive request.
///
/// Upstream types the client method as returning the whole
/// `archive_workspace_response` payload and reads exactly one field off it, so
/// only that field is modelled: a non-empty [error] means the archive did not
/// happen. Upstream's `if (payload.error)` is a truthiness test, so an *empty*
/// error string counts as success — [archiveWorkspaceOptimistically] reproduces
/// that rather than treating `""` as a failure with a blank message.
final class WorkspaceArchiveResult {
  const WorkspaceArchiveResult({this.error});

  final String? error;
}

/// The single daemon call the archive flow is allowed to make.
///
/// Upstream declares the same one-method structural interface so the flow can
/// be driven by a stub; Dart has no structural typing, so this is a nominal
/// interface the real `DaemonClient` is adapted onto.
abstract interface class WorkspaceArchiveClient {
  Future<WorkspaceArchiveResult> archiveWorkspace(String workspaceId);
}

/// The three session-store operations the optimistic hide needs.
///
/// Upstream calls `useSessionStore.getState()` directly — a module-global
/// Zustand store. This repo keeps session state in Riverpod, which a pure rule
/// must not reach into, so the store is injected. The read returns the raw map
/// (rather than a single descriptor) because the snapshot lookup goes through
/// [resolveWorkspaceMapKeyByIdentity], which needs to see every key.
abstract interface class WorkspaceArchiveSessionStore {
  /// The workspaces known for [serverId], or null when the session is unknown.
  /// Iteration order is load-bearing — see [resolveWorkspaceMapKeyByIdentity].
  Map<String, WorkspaceDescriptor>? workspacesFor(String serverId);

  void removeWorkspace(String serverId, String workspaceId);

  void mergeWorkspaces(String serverId, List<WorkspaceDescriptor> workspaces);
}

/// One workspace whose archive did not go through.
///
/// [error] is `Object` rather than a typed exception because upstream types it
/// `unknown`: it carries whatever the daemon call threw, which may be a
/// transport error, a `StateError` built from the payload's message, or the
/// host-disconnected error this module synthesizes.
final class WorkspaceArchiveFailure {
  const WorkspaceArchiveFailure({
    required this.serverId,
    required this.workspaceId,
    required this.error,
  });

  final String serverId;
  final String workspaceId;
  final Object error;

  @override
  String toString() =>
      'WorkspaceArchiveFailure(serverId: $serverId, '
      'workspaceId: $workspaceId, error: $error)';
}

/// The frozen English copy for `sidebar.workspace.toasts.hostDisconnected`.
///
/// Upstream binds `i18n.t(...)` at call time against the i18next singleton;
/// this repo loads [Translations] asynchronously and hands them down, so the
/// string is a parameter with the English text as its default. Mirrors the same
/// pattern already used by `git/paseo_git_queries.dart`.
const String defaultWorkspaceArchiveHostDisconnectedMessage =
    'Host is not connected';

/// Removes the workspace from the store and remembers what was there.
///
/// The pending mark is set *before* the removal so that an upsert racing the
/// removal is already being suppressed by the time the row disappears;
/// reversing the two would let the daemon resurrect the row between them.
WorkspaceDescriptor? _hideWorkspaceOptimistically(
  WorkspaceArchiveTarget workspace,
  WorkspaceArchiveSessionStore store,
) {
  final workspaces = store.workspacesFor(workspace.serverId);
  final workspaceKey = resolveWorkspaceMapKeyByIdentity(
    workspaces: workspaces,
    workspaceId: workspace.workspaceId,
  );
  final snapshot = workspaceKey == null ? null : workspaces?[workspaceKey];
  markWorkspaceArchivePending(
    serverId: workspace.serverId,
    workspaceId: workspace.workspaceId,
  );
  store.removeWorkspace(workspace.serverId, workspace.workspaceId);
  return snapshot;
}

/// Puts a failed archive's row back, exactly as it was.
///
/// The pending mark is cleared unconditionally, even when there was no snapshot
/// to restore: the archive is no longer in flight either way, and leaving the
/// mark set would silently swallow every future upsert for that workspace.
void _restoreOptimisticallyHiddenWorkspace({
  required String serverId,
  required String workspaceId,
  required WorkspaceDescriptor? snapshot,
  required WorkspaceArchiveSessionStore store,
}) {
  clearWorkspaceArchivePending(serverId: serverId, workspaceId: workspaceId);
  if (snapshot != null) {
    store.mergeWorkspaces(serverId, [snapshot]);
  }
}

/// Archives one workspace, hiding its row immediately and restoring it on
/// failure.
///
/// The hide happens *synchronously*, before the first suspension point, so the
/// row is gone by the time this returns its future — that is the whole point of
/// the optimism, and callers rely on it when archiving a batch.
///
/// Rethrows whatever went wrong after restoring, so a single-workspace caller
/// can surface a toast.
Future<void> archiveWorkspaceOptimistically({
  required WorkspaceArchiveClient client,
  required WorkspaceArchiveTarget workspace,
  required WorkspaceArchiveSessionStore store,
}) async {
  final snapshot = _hideWorkspaceOptimistically(workspace, store);

  try {
    final payload = await client.archiveWorkspace(workspace.workspaceId);
    final error = payload.error;
    // Upstream's `if (payload.error)` is truthy, not a null check.
    if (error != null && error.isNotEmpty) {
      // `StateError` is this repo's stand-in for upstream's bare `Error`.
      throw StateError(error);
    }
  } catch (_) {
    _restoreOptimisticallyHiddenWorkspace(
      serverId: workspace.serverId,
      workspaceId: workspace.workspaceId,
      snapshot: snapshot,
      store: store,
    );
    rethrow;
  }
}

/// Archives every workspace concurrently and reports only the ones that failed.
///
/// Concurrency is the point: `Promise.allSettled` upstream, [Future.wait] here.
/// Every workspace's optimistic hide runs synchronously in list order before
/// any daemon call resolves, so the whole selection disappears at once rather
/// than row by row.
///
/// A workspace whose host has no client fails *without* being hidden — there is
/// nothing to restore, and hiding a row whose archive was never attempted would
/// be a lie.
///
/// Failures come back in input order. Successes are simply absent; the returned
/// list is empty when everything worked.
///
/// DEVIATION: upstream throws object literals and filters the settled results
/// through an `isWorkspaceArchiveFailure` type guard, because a `Promise` can
/// reject with anything. Here each unit returns `null` or a
/// [WorkspaceArchiveFailure] and never throws, which is the same observable
/// contract with the unrepresentable case removed by the type system.
Future<List<WorkspaceArchiveFailure>> archiveWorkspacesOptimistically({
  required WorkspaceArchiveClient? Function(String serverId) getClient,
  required List<WorkspaceArchiveTarget> workspaces,
  required WorkspaceArchiveSessionStore store,
  String hostDisconnectedMessage =
      defaultWorkspaceArchiveHostDisconnectedMessage,
}) async {
  Future<WorkspaceArchiveFailure?> archiveOne(
    WorkspaceArchiveTarget workspace,
  ) async {
    final client = getClient(workspace.serverId);
    if (client == null) {
      return WorkspaceArchiveFailure(
        serverId: workspace.serverId,
        workspaceId: workspace.workspaceId,
        error: StateError(hostDisconnectedMessage),
      );
    }

    try {
      await archiveWorkspaceOptimistically(
        client: client,
        workspace: workspace,
        store: store,
      );
      return null;
    } catch (error) {
      return WorkspaceArchiveFailure(
        serverId: workspace.serverId,
        workspaceId: workspace.workspaceId,
        error: error,
      );
    }
  }

  // Built eagerly so every optimistic hide runs before the first `await`,
  // matching `input.workspaces.map(async ...)` upstream.
  final pending = <Future<WorkspaceArchiveFailure?>>[
    for (final workspace in workspaces) archiveOne(workspace),
  ];
  final results = await Future.wait(pending);
  return [for (final result in results) ?result];
}

// ===========================================================================
// workspace/open-target-planner.ts
// ===========================================================================

/// Whether a desktop target opens files or reveals them.
///
/// Purely descriptive — the planner never branches on it, because a
/// file-manager and an editor are handed the same `{workspacePath, filePath}`
/// and it is the desktop bridge that decides what "open" means.
enum DesktopOpenTargetKind { editor, fileManager }

/// The two built-in glyph names a desktop target can ask for.
enum DesktopOpenTargetSymbol { folder, terminal }

/// A desktop target's menu icon: either a real app icon the host extracted, or
/// one of two built-in glyphs.
sealed class DesktopOpenTargetIcon {
  const DesktopOpenTargetIcon();
}

/// An app icon the desktop host handed over as a `data:` URL.
final class ImageDesktopOpenTargetIcon extends DesktopOpenTargetIcon {
  const ImageDesktopOpenTargetIcon(this.dataUrl);

  final String dataUrl;

  @override
  bool operator ==(Object other) =>
      other is ImageDesktopOpenTargetIcon && other.dataUrl == dataUrl;

  @override
  int get hashCode => dataUrl.hashCode;

  @override
  String toString() => 'ImageDesktopOpenTargetIcon($dataUrl)';
}

/// A built-in glyph, used when no app icon is available.
final class SymbolDesktopOpenTargetIcon extends DesktopOpenTargetIcon {
  const SymbolDesktopOpenTargetIcon(this.name);

  final DesktopOpenTargetSymbol name;

  @override
  bool operator ==(Object other) =>
      other is SymbolDesktopOpenTargetIcon && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'SymbolDesktopOpenTargetIcon(${name.name})';
}

/// One installed editor or file manager the desktop bridge reported.
///
/// [id] is an opaque string, not an enum: the bridge also reports user-defined
/// script targets such as `script:open-in-nvim`, and the planner passes them
/// through untouched.
final class DesktopOpenTarget {
  const DesktopOpenTarget({
    required this.id,
    required this.label,
    required this.kind,
    required this.icon,
  });

  final String id;
  final String label;
  final DesktopOpenTargetKind kind;
  final DesktopOpenTargetIcon icon;
}

/// The arguments handed to the desktop bridge's `openTarget`.
///
/// Optional fields are *omitted* on the wire rather than sent as null, which is
/// what upstream's conditional spread encodes; [toJson] reproduces that shape.
final class OpenDesktopTargetInput {
  const OpenDesktopTargetInput({
    required this.editorId,
    required this.workspacePath,
    this.filePath,
    this.line,
    this.column,
  });

  final String editorId;
  final String workspacePath;
  final String? filePath;
  final int? line;
  final int? column;

  Map<String, Object?> toJson() => {
    'editorId': editorId,
    'workspacePath': workspacePath,
    if (filePath != null) 'filePath': filePath,
    if (line != null) 'line': line,
    if (column != null) 'column': column,
  };

  @override
  bool operator ==(Object other) =>
      other is OpenDesktopTargetInput &&
      other.editorId == editorId &&
      other.workspacePath == workspacePath &&
      other.filePath == filePath &&
      other.line == line &&
      other.column == column;

  @override
  int get hashCode =>
      Object.hash(editorId, workspacePath, filePath, line, column);

  @override
  String toString() => 'OpenDesktopTargetInput(${toJson()})';
}

/// One entry in the "Open in…" menu.
sealed class PlannedWorkspaceOpenTarget {
  const PlannedWorkspaceOpenTarget();

  /// Upstream's `source` discriminant, kept as a string so a caller that
  /// serializes the plan produces the same payload.
  String get source;

  /// Stable identity within the menu — the desktop target id, or the forge id.
  String get id;

  String get label;
}

/// A desktop app (editor, file manager, or user script) the workspace can be
/// opened in.
final class PlannedDesktopOpenTarget extends PlannedWorkspaceOpenTarget {
  const PlannedDesktopOpenTarget({
    required this.id,
    required this.label,
    required this.editorId,
    required this.icon,
    required this.openInput,
  });

  @override
  String get source => 'desktop';

  @override
  final String id;

  @override
  final String label;

  /// Always equal to [id]. Upstream carries both because the bridge's argument
  /// is named `editorId` while the menu's key is named `id`; keeping the
  /// duplication makes the port diffable against the frozen source.
  final String editorId;

  final DesktopOpenTargetIcon icon;
  final OpenDesktopTargetInput openInput;

  @override
  bool operator ==(Object other) =>
      other is PlannedDesktopOpenTarget &&
      other.id == id &&
      other.label == label &&
      other.editorId == editorId &&
      other.icon == icon &&
      other.openInput == openInput;

  @override
  int get hashCode => Object.hash(id, label, editorId, icon, openInput);

  @override
  String toString() =>
      'PlannedDesktopOpenTarget(id: $id, label: $label, icon: $icon, '
      'openInput: $openInput)';
}

/// The forge web page (blob view, or branch tree) backing this checkout.
final class PlannedForgeOpenTarget extends PlannedWorkspaceOpenTarget {
  const PlannedForgeOpenTarget({
    required this.forge,
    required this.label,
    required this.url,
  });

  @override
  String get source => 'forge';

  /// The forge id. An open string, per `core/forge.dart`, because the daemon
  /// may report a forge this build does not know.
  final String forge;

  /// Always equal to [forge] — upstream types `id: Forge` for this member.
  @override
  String get id => forge;

  @override
  final String label;

  final String url;

  @override
  bool operator ==(Object other) =>
      other is PlannedForgeOpenTarget &&
      other.forge == forge &&
      other.label == label &&
      other.url == url;

  @override
  int get hashCode => Object.hash(forge, label, url);

  @override
  String toString() =>
      'PlannedForgeOpenTarget(forge: $forge, label: $label, url: $url)';
}

/// What the planner needs to know about the workspace's git checkout.
final class CheckoutStatusForOpenTarget {
  const CheckoutStatusForOpenTarget({
    required this.isGit,
    this.remoteUrl,
    this.currentBranch,
  });

  final bool isGit;
  final String? remoteUrl;
  final String? currentBranch;
}

/// A pre-resolved active file, supplied instead of letting the planner resolve
/// one.
///
/// DEVIATION: upstream distinguishes three states on one field —
/// `undefined` ("not supplied, resolve it yourself"), `null` ("supplied, and
/// there is deliberately no resolved file"), and a value. Dart has a single
/// null, so the two absent-ish states are split across the box and its
/// contents: a null [PlanWorkspaceOpenTargetsInput.resolvedActiveFile] is
/// upstream's `undefined`, and `ResolvedActiveFileOverride(null)` is upstream's
/// explicit `null`. The distinction is observable — the first derives a file
/// from `activeFile`, the second suppresses it.
final class ResolvedActiveFileOverride {
  const ResolvedActiveFileOverride(this.value);

  final ResolvedWorkspaceFilePaths? value;
}

/// Everything the "Open in…" menu observes about the world.
final class PlanWorkspaceOpenTargetsInput {
  const PlanWorkspaceOpenTargetsInput({
    required this.workspaceDirectory,
    required this.canUseDesktopBridge,
    required this.isLocalExecution,
    this.activeFile,
    this.resolvedActiveFile,
    this.desktopTargets = const [],
    this.checkoutStatus,
    this.forge,
  });

  final String workspaceDirectory;

  /// The file the user is looking at, if any. Its line range becomes the forge
  /// URL's anchor and the editor's cursor position.
  final WorkspaceFileLocation? activeFile;

  final ResolvedActiveFileOverride? resolvedActiveFile;

  final List<DesktopOpenTarget> desktopTargets;

  /// False in a plain browser: there is no desktop host to ask.
  final bool canUseDesktopBridge;

  /// False when the daemon runs on another machine — its paths mean nothing to
  /// a local editor.
  final bool isLocalExecution;

  final CheckoutStatusForOpenTarget? checkoutStatus;

  /// The caller's already-resolved forge id. Wins over inference from the
  /// remote URL; null means "infer it".
  final String? forge;
}

ResolvedWorkspaceFilePaths? _resolveActiveFileForOpenTargets(
  PlanWorkspaceOpenTargetsInput input,
) {
  final override = input.resolvedActiveFile;
  if (override != null) {
    return override.value;
  }
  final activeFile = input.activeFile;
  return activeFile != null
      ? resolveWorkspaceFilePaths(
          path: activeFile.path,
          workspaceRoot: input.workspaceDirectory,
        )
      : null;
}

/// Desktop targets are all-or-nothing: without a bridge, or against a remote
/// daemon, none of them can act on the workspace's paths.
List<PlannedDesktopOpenTarget> _planDesktopOpenTargets(
  PlanWorkspaceOpenTargetsInput input,
  ResolvedWorkspaceFilePaths? resolvedFile,
) {
  if (!input.canUseDesktopBridge || !input.isLocalExecution) {
    return const [];
  }

  return [
    for (final target in input.desktopTargets)
      PlannedDesktopOpenTarget(
        id: target.id,
        label: target.label,
        editorId: target.id,
        icon: target.icon,
        openInput: resolvedFile == null
            ? OpenDesktopTargetInput(
                editorId: target.id,
                workspacePath: input.workspaceDirectory,
              )
            : OpenDesktopTargetInput(
                editorId: target.id,
                workspacePath: input.workspaceDirectory,
                filePath: resolvedFile.absolutePath,
                // Upstream spreads `...(activeFile?.lineStart ? { line } : {})`,
                // a truthiness test: a `lineStart` of 0 omits the key just like a
                // missing one does.
                line:
                    input.activeFile?.lineStart != null &&
                        input.activeFile!.lineStart != 0
                    ? input.activeFile!.lineStart
                    : null,
              ),
      ),
  ];
}

/// A blob URL when a file inside the repo is open, a branch tree URL otherwise.
///
/// A forge with no web-URL grammar returns null from both builders, which is
/// what makes [_planForgeOpenTarget] drop the entry instead of offering a link
/// that goes nowhere.
String? _buildForgeWebUrl(
  String forge, {
  required String? remoteUrl,
  required String? branch,
  required String? path,
  int? lineStart,
  int? lineEnd,
}) {
  final presentation = getForgePresentation(forge);
  if (path != null && path.isNotEmpty) {
    return presentation.buildBlobUrl?.call(
      ForgeBlobUrlInput(
        remoteUrl: remoteUrl,
        branch: branch,
        path: path,
        lineStart: lineStart,
        lineEnd: lineEnd,
      ),
    );
  }
  return presentation.buildBranchTreeUrl?.call(
    ForgeBranchTreeUrlInput(remoteUrl: remoteUrl, branch: branch),
  );
}

PlannedForgeOpenTarget? _planForgeOpenTarget(
  PlanWorkspaceOpenTargetsInput input,
  ResolvedWorkspaceFilePaths? resolvedFile,
) {
  final checkoutStatus = input.checkoutStatus;
  if (checkoutStatus == null || !checkoutStatus.isGit) {
    return null;
  }
  // `??` upstream, so an explicitly-passed forge wins even over a remote URL
  // that would infer a different one...
  final forge = input.forge ?? forgeFromRemoteUrl(checkoutStatus.remoteUrl);
  // ...but the following `if (!forge)` is a truthiness test, so an explicitly
  // *empty* forge id is rejected rather than normalized to `github`.
  if (forge == null || forge.isEmpty) {
    return null;
  }
  final url = _buildForgeWebUrl(
    forge,
    remoteUrl: checkoutStatus.remoteUrl,
    branch: checkoutStatus.currentBranch,
    path: resolvedFile?.relativePath,
    lineStart: input.activeFile?.lineStart,
    lineEnd: input.activeFile?.lineEnd,
  );
  if (url == null || url.isEmpty) {
    return null;
  }
  return PlannedForgeOpenTarget(
    forge: forge,
    label: getForgePresentation(forge).brandLabel,
    url: url,
  );
}

/// The "Open in…" menu, desktop apps first and the forge link last.
///
/// The two halves are independent on purpose: a remote workspace still offers
/// its GitHub link, and a workspace with no remote still offers its editors.
/// The forge entry is appended rather than interleaved so it is always the last
/// row no matter how many editors are installed.
List<PlannedWorkspaceOpenTarget> planWorkspaceOpenTargets(
  PlanWorkspaceOpenTargetsInput input,
) {
  final resolvedFile = _resolveActiveFileForOpenTargets(input);
  final desktopTargets = _planDesktopOpenTargets(input, resolvedFile);
  final forgeTarget = _planForgeOpenTarget(input, resolvedFile);
  return [...desktopTargets, ?forgeTarget];
}

// ===========================================================================
// screens/workspace/workspace-bulk-close.ts
// ===========================================================================

/// An agent tab queued for bulk close. Archiving the agent and closing the tab
/// are separate steps, so both ids are carried.
final class BulkCloseAgentTab {
  const BulkCloseAgentTab({required this.tabId, required this.agentId});

  final String tabId;
  final String agentId;

  @override
  bool operator ==(Object other) =>
      other is BulkCloseAgentTab &&
      other.tabId == tabId &&
      other.agentId == agentId;

  @override
  int get hashCode => Object.hash(tabId, agentId);

  @override
  String toString() => 'BulkCloseAgentTab(tabId: $tabId, agentId: $agentId)';
}

/// A terminal tab queued for bulk close.
final class BulkCloseTerminalTab {
  const BulkCloseTerminalTab({required this.tabId, required this.terminalId});

  final String tabId;
  final String terminalId;

  @override
  bool operator ==(Object other) =>
      other is BulkCloseTerminalTab &&
      other.tabId == tabId &&
      other.terminalId == terminalId;

  @override
  int get hashCode => Object.hash(tabId, terminalId);

  @override
  String toString() =>
      'BulkCloseTerminalTab(tabId: $tabId, terminalId: $terminalId)';
}

/// Any other tab — a file, a diff, a browser, a draft. Closing one destroys
/// nothing on the daemon, so the whole target is kept only to hand back to the
/// cleanup callback.
final class BulkCloseOtherTab {
  const BulkCloseOtherTab({required this.tabId, required this.target});

  final String tabId;
  final WorkspaceTabTarget target;

  @override
  bool operator ==(Object other) =>
      other is BulkCloseOtherTab &&
      other.tabId == tabId &&
      workspaceTabTargetsEqual(other.target, target);

  @override
  int get hashCode => Object.hash(tabId, target.kind);

  @override
  String toString() =>
      'BulkCloseOtherTab(tabId: $tabId, target: ${target.toJson()})';
}

/// A tab strip split by how destructive closing each tab is.
///
/// The three-way split exists because agents and terminals need a daemon RPC
/// before their tabs go away, while everything else is purely client-side.
final class BulkClosableTabGroups {
  const BulkClosableTabGroups({
    required this.agentTabs,
    required this.terminalTabs,
    required this.otherTabs,
  });

  final List<BulkCloseAgentTab> agentTabs;
  final List<BulkCloseTerminalTab> terminalTabs;
  final List<BulkCloseOtherTab> otherTabs;

  @override
  bool operator ==(Object other) =>
      other is BulkClosableTabGroups &&
      _listEquals(other.agentTabs, agentTabs) &&
      _listEquals(other.terminalTabs, terminalTabs) &&
      _listEquals(other.otherTabs, otherTabs);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(agentTabs),
    Object.hashAll(terminalTabs),
    Object.hashAll(otherTabs),
  );

  @override
  String toString() =>
      'BulkClosableTabGroups(agentTabs: $agentTabs, '
      'terminalTabs: $terminalTabs, otherTabs: $otherTabs)';
}

bool _listEquals<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// Every sentence the bulk-close confirmation can be built from, injected so
/// the rule stays locale-independent.
///
/// Seven separate builders rather than one composed sentence because the copy
/// is not compositional: only the variants that include terminals carry the
/// "running process will be stopped" warning, and only the variants that
/// include agents say "archive" rather than "close".
final class BulkCloseConfirmationLabels {
  const BulkCloseConfirmationLabels({
    required this.all,
    required this.agentsAndTerminals,
    required this.terminalsAndTabs,
    required this.agentsAndTabs,
    required this.terminals,
    required this.tabs,
    required this.agents,
  });

  final String Function({
    required int agents,
    required int terminals,
    required int tabs,
  })
  all;
  final String Function({required int agents, required int terminals})
  agentsAndTerminals;
  final String Function({required int terminals, required int tabs})
  terminalsAndTabs;
  final String Function({required int agents, required int tabs}) agentsAndTabs;
  final String Function({required int terminals}) terminals;
  final String Function({required int tabs}) tabs;
  final String Function({required int agents}) agents;
}

/// The frozen English copy, verbatim from upstream's
/// `DEFAULT_BULK_CLOSE_CONFIRMATION_LABELS`.
final BulkCloseConfirmationLabels defaultBulkCloseConfirmationLabels =
    BulkCloseConfirmationLabels(
      all: ({required agents, required terminals, required tabs}) =>
          'This will archive $agents agent(s), close $terminals terminal(s), '
          'and close $tabs tab(s). Any running process in a closed terminal '
          'will be stopped immediately.',
      agentsAndTerminals: ({required agents, required terminals}) =>
          'This will archive $agents agent(s) and close $terminals '
          'terminal(s). Any running process in a closed terminal will be '
          'stopped immediately.',
      terminalsAndTabs: ({required terminals, required tabs}) =>
          'This will close $terminals terminal(s) and close $tabs tab(s). '
          'Any running process in a closed terminal will be stopped '
          'immediately.',
      agentsAndTabs: ({required agents, required tabs}) =>
          'This will archive $agents agent(s) and close $tabs tab(s).',
      terminals: ({required terminals}) =>
          'This will close $terminals terminal(s). Any running process in a '
          'closed terminal will be stopped immediately.',
      tabs: ({required tabs}) => 'This will close $tabs tab(s).',
      agents: ({required agents}) => 'This will archive $agents agent(s).',
    );

/// The arguments handed to the caller's per-tab cleanup.
final class CloseWorkspaceTabWithCleanupInput {
  const CloseWorkspaceTabWithCleanupInput({required this.tabId, this.target});

  final String tabId;

  /// Null only for callers that pass none; the bulk close always supplies one.
  final WorkspaceTabTarget? target;

  @override
  bool operator ==(Object other) {
    if (other is! CloseWorkspaceTabWithCleanupInput) return false;
    if (other.tabId != tabId) return false;
    final otherTarget = other.target;
    final selfTarget = target;
    if (otherTarget == null || selfTarget == null) {
      return otherTarget == null && selfTarget == null;
    }
    return workspaceTabTargetsEqual(otherTarget, selfTarget);
  }

  @override
  int get hashCode => Object.hash(tabId, target?.kind);

  @override
  String toString() =>
      'CloseWorkspaceTabWithCleanupInput(tabId: $tabId, '
      'target: ${target?.toJson()})';
}

/// The daemon call that archives agents and kills terminals in one round trip.
///
/// Upstream types the parameter as `Pick<DaemonClient, "closeItems">` and
/// discards the response; this narrows it to the one method and to `void`,
/// because reading the per-item results would change the fire-and-forget
/// semantics the flow depends on.
abstract interface class BulkCloseItemsClient {
  Future<void> closeItems({
    required List<String> agentIds,
    required List<String> terminalIds,
  });
}

/// Runs one tab's close animation/bookkeeping around [action].
typedef BulkCloseTab =
    Future<void> Function(String tabId, Future<void> Function() action);

/// Removes a tab from the strip and releases whatever it held open.
typedef CloseWorkspaceTabWithCleanup =
    void Function(CloseWorkspaceTabWithCleanupInput input);

/// Structured logging sink. Injected because upstream reaches for a module-level
/// logger; the payload is a map so the message and its fields stay separable.
typedef BulkCloseWarn =
    void Function(String message, Map<String, Object?> payload);

/// Splits a tab strip into the three bulk-close groups, preserving strip order
/// within each group.
///
/// Order matters downstream: the confirmation counts are read off these lists,
/// and [closeBulkWorkspaceTabs] closes agents, then terminals, then everything
/// else, so a stable per-group order is what makes the close deterministic.
BulkClosableTabGroups classifyBulkClosableTabs(List<WorkspaceTab> tabs) {
  final agentTabs = <BulkCloseAgentTab>[];
  final terminalTabs = <BulkCloseTerminalTab>[];
  final otherTabs = <BulkCloseOtherTab>[];

  for (final tab in tabs) {
    final target = tab.target;
    if (target is WorkspaceAgentTabTarget) {
      agentTabs.add(
        BulkCloseAgentTab(tabId: tab.tabId, agentId: target.agentId),
      );
      continue;
    }
    if (target is WorkspaceTerminalTabTarget) {
      terminalTabs.add(
        BulkCloseTerminalTab(tabId: tab.tabId, terminalId: target.terminalId),
      );
      continue;
    }
    otherTabs.add(BulkCloseOtherTab(tabId: tab.tabId, target: target));
  }

  return BulkClosableTabGroups(
    agentTabs: agentTabs,
    terminalTabs: terminalTabs,
    otherTabs: otherTabs,
  );
}

/// The sentence shown before a bulk close.
///
/// The branch order is upstream's and is *not* symmetric: `agents + terminals`
/// is tested before `terminals + tabs`, so an agents+terminals+no-tabs strip
/// never falls through to the terminals+tabs copy. The final fallback is the
/// agents-only sentence, which is also what an entirely empty group set
/// produces — "This will archive 0 agent(s)." Callers are expected not to
/// prompt for an empty selection.
String buildBulkCloseConfirmationMessage(
  BulkClosableTabGroups input, {
  BulkCloseConfirmationLabels? labels,
}) {
  final resolved = labels ?? defaultBulkCloseConfirmationLabels;
  final agentCount = input.agentTabs.length;
  final terminalCount = input.terminalTabs.length;
  final otherCount = input.otherTabs.length;

  if (agentCount > 0 && terminalCount > 0 && otherCount > 0) {
    return resolved.all(
      agents: agentCount,
      terminals: terminalCount,
      tabs: otherCount,
    );
  }
  if (agentCount > 0 && terminalCount > 0) {
    return resolved.agentsAndTerminals(
      agents: agentCount,
      terminals: terminalCount,
    );
  }
  if (terminalCount > 0 && otherCount > 0) {
    return resolved.terminalsAndTabs(
      terminals: terminalCount,
      tabs: otherCount,
    );
  }
  if (agentCount > 0 && otherCount > 0) {
    return resolved.agentsAndTabs(agents: agentCount, tabs: otherCount);
  }
  if (terminalCount > 0) {
    return resolved.terminals(terminals: terminalCount);
  }
  if (otherCount > 0) {
    return resolved.tabs(tabs: otherCount);
  }
  return resolved.agents(agents: agentCount);
}

/// The frozen English copy for `common.errors.daemonClientUnavailable`.
const String defaultBulkCloseDaemonClientUnavailableMessage =
    'Daemon client unavailable';

/// Closes every classified tab, firing one `closeItems` RPC for the destructive
/// ones.
///
/// Deliberately fire-and-forget in two places, both upstream's design:
///
/// * the RPC is *not* awaited, so the tab strip empties at once instead of
///   waiting on the network — a failed archive is reported through [warn], not
///   by leaving tabs on screen;
/// * each [closeTab] call is likewise not awaited, so N tabs close in parallel
///   rather than in a chain of animations.
///
/// The returned future therefore completes once the loops have *started* every
/// close, not once they have finished. Every [closeTab] call runs synchronously
/// up to its own first suspension, so the tab ids are handed over in group
/// order (agents, terminals, others) regardless of how each close resolves.
///
/// When there are destructive tabs but no [client], nothing is archived and the
/// tabs still close — the alternative is leaving the user with a strip they
/// cannot clear because their daemon dropped.
Future<void> closeBulkWorkspaceTabs({
  required BulkCloseItemsClient? client,
  required BulkClosableTabGroups groups,
  required BulkCloseTab closeTab,
  required CloseWorkspaceTabWithCleanup closeWorkspaceTabWithCleanup,
  required String logLabel,
  BulkCloseWarn? warn,
  String daemonClientUnavailableMessage =
      defaultBulkCloseDaemonClientUnavailableMessage,
}) async {
  final hasDestructiveTabs =
      groups.agentTabs.isNotEmpty || groups.terminalTabs.isNotEmpty;

  if (hasDestructiveTabs && client != null) {
    unawaited(
      client
          .closeItems(
            agentIds: [for (final tab in groups.agentTabs) tab.agentId],
            terminalIds: [
              for (final tab in groups.terminalTabs) tab.terminalId,
            ],
          )
          .catchError((Object error) {
            warn?.call(
              '[WorkspaceScreen] Failed to bulk close tabs $logLabel',
              {'error': error},
            );
          }),
    );
  } else if (hasDestructiveTabs) {
    warn?.call('[WorkspaceScreen] Failed to bulk close tabs $logLabel', {
      'error': StateError(daemonClientUnavailableMessage),
    });
  }

  for (final tab in groups.agentTabs) {
    unawaited(
      closeTab(tab.tabId, () async {
        closeWorkspaceTabWithCleanup(
          CloseWorkspaceTabWithCleanupInput(
            tabId: tab.tabId,
            target: WorkspaceAgentTabTarget(agentId: tab.agentId),
          ),
        );
      }),
    );
  }

  for (final tab in groups.terminalTabs) {
    unawaited(
      closeTab(tab.tabId, () async {
        closeWorkspaceTabWithCleanup(
          CloseWorkspaceTabWithCleanupInput(
            tabId: tab.tabId,
            target: WorkspaceTerminalTabTarget(terminalId: tab.terminalId),
          ),
        );
      }),
    );
  }

  for (final tab in groups.otherTabs) {
    unawaited(
      closeTab(tab.tabId, () async {
        closeWorkspaceTabWithCleanup(
          CloseWorkspaceTabWithCleanupInput(
            tabId: tab.tabId,
            target: tab.target,
          ),
        );
      }),
    );
  }
}

// ===========================================================================
// screens/new-workspace-picker-state.ts
// ===========================================================================

/// The owner tag stamped on the one PR attachment the picker manages.
///
/// Ownership lives on the attachment rather than in component state because
/// drafts outlive the picker: a user who closes and reopens the screen must
/// still be able to tell "the picker put this here" from "I attached this".
const String newWorkspacePickerAttachmentOwner = 'new-workspace-picker';

/// A composer attachment the *user* owns, as far as these rules are concerned.
///
/// DEVIATION: upstream's `UserComposerAttachment` is an eight-member structural
/// union (images, files, workspace files, issues, change requests, …). These
/// rules read exactly three things from it — is it a change-request attachment,
/// is it the picker's own, and what number does it carry — so only the two PR
/// members are modelled concretely and every other kind is carried opaquely by
/// [OtherUserComposerAttachment]. Nothing observable is lost: non-PR
/// attachments are only ever passed through unchanged.
sealed class UserComposerAttachment {
  const UserComposerAttachment();

  /// The wire discriminant, so a caller can round-trip the attachment.
  String get kind;
}

/// The forge-neutral change-request attachment.
final class ForgeChangeRequestComposerAttachment
    extends UserComposerAttachment {
  const ForgeChangeRequestComposerAttachment(this.item);

  final ForgeSearchItemLike item;

  @override
  String get kind => 'forge_change_request';

  @override
  bool operator ==(Object other) =>
      other is ForgeChangeRequestComposerAttachment && other.item == item;

  @override
  int get hashCode => Object.hash(kind, item);

  @override
  String toString() => 'ForgeChangeRequestComposerAttachment($item)';
}

/// The legacy GitHub-specific PR attachment.
///
/// COMPAT(githubAttachmentKinds): still emitted upstream in v0.2.0 and still
/// the kind the picker writes, so [owner] lives here rather than on the
/// forge-neutral member.
final class GithubPrComposerAttachment extends UserComposerAttachment {
  const GithubPrComposerAttachment(this.item, {this.owner});

  final ForgeSearchItemLike item;

  /// [newWorkspacePickerAttachmentOwner] when the picker added it; null when
  /// the user did.
  final String? owner;

  @override
  String get kind => 'github_pr';

  @override
  bool operator ==(Object other) =>
      other is GithubPrComposerAttachment &&
      other.item == item &&
      other.owner == owner;

  @override
  int get hashCode => Object.hash(kind, item, owner);

  @override
  String toString() => 'GithubPrComposerAttachment($item, owner: $owner)';
}

/// Any attachment kind these rules do not inspect.
final class OtherUserComposerAttachment extends UserComposerAttachment {
  const OtherUserComposerAttachment(this.kind, {this.payload});

  @override
  final String kind;

  /// Opaque, carried only so a round-trip through these rules is lossless.
  final Object? payload;

  @override
  bool operator ==(Object other) =>
      other is OtherUserComposerAttachment &&
      other.kind == kind &&
      other.payload == payload;

  @override
  int get hashCode => Object.hash(kind, payload);

  @override
  String toString() => 'OtherUserComposerAttachment($kind)';
}

/// The one field of a forge search item these attachment rules compare on.
///
/// DEVIATION: upstream compares `attachment.item.number` against the selected
/// PR's `number`. `package:agent_protocol`'s `ForgeSearchItem` has no value
/// equality, so a bare identity comparison would make "already attached" depend
/// on object identity rather than PR number. This tiny value type restores the
/// upstream comparison; [ForgeSearchItemLike.of] adapts a real wire item.
final class ForgeSearchItemLike {
  const ForgeSearchItemLike({required this.number, this.item});

  /// Adapts any object that knows its change-request number.
  factory ForgeSearchItemLike.of(int number, [Object? item]) =>
      ForgeSearchItemLike(number: number, item: item);

  final int number;

  /// The full wire item, carried through untouched.
  final Object? item;

  @override
  bool operator ==(Object other) =>
      other is ForgeSearchItemLike &&
      other.number == number &&
      identical(other.item, item);

  @override
  int get hashCode => Object.hash(number, identityHashCode(item));

  @override
  String toString() => 'ForgeSearchItemLike(number: $number)';
}

/// What the picker currently has selected, and whether a PR that shows up on
/// its own is allowed to steal that selection.
final class PickerSelectionState {
  const PickerSelectionState({
    required this.selectedItem,
    required this.allowAutoPrSelection,
  });

  final PickerItem? selectedItem;

  /// True only between "the composer text mentions a PR" and the moment that
  /// PR's row actually arrives. This one-shot window is what keeps the picker
  /// from re-selecting the PR every time the row list refreshes.
  final bool allowAutoPrSelection;

  @override
  bool operator ==(Object other) =>
      other is PickerSelectionState &&
      identical(other.selectedItem, selectedItem) &&
      other.allowAutoPrSelection == allowAutoPrSelection;

  @override
  int get hashCode =>
      Object.hash(identityHashCode(selectedItem), allowAutoPrSelection);

  @override
  String toString() =>
      'PickerSelectionState(selectedItem: $selectedItem, '
      'allowAutoPrSelection: $allowAutoPrSelection)';
}

/// Something that happened to the picker.
sealed class PickerSelectionEvent {
  const PickerSelectionEvent();
}

/// The composer text was found to mention a change request; its row has not
/// arrived yet.
final class PrDetectedPickerEvent extends PickerSelectionEvent {
  const PrDetectedPickerEvent();
}

/// A change-request row arrived in the list.
final class PrAddedPickerEvent extends PickerSelectionEvent {
  const PrAddedPickerEvent(this.item);

  final ChangeRequestPickerItem item;
}

/// The user clicked a row.
final class PickerSelectedPickerEvent extends PickerSelectionEvent {
  const PickerSelectedPickerEvent(this.item);

  final PickerItem item;
}

/// The host or project the picker searches within changed.
final class TargetChangedPickerEvent extends PickerSelectionEvent {
  const TargetChangedPickerEvent();
}

/// Nothing selected, and no pending auto-selection.
const PickerSelectionState initialPickerSelectionState = PickerSelectionState(
  selectedItem: null,
  allowAutoPrSelection: false,
);

/// Folds a picker event into the selection state.
///
/// The rule that makes this a reducer rather than two setters: a PR may only
/// auto-select itself in the narrow window opened by
/// [PrDetectedPickerEvent] and closed by the *first* thing that consumes it.
/// So a second PR in the same edit does not displace the first, an explicit
/// click always wins, and a PR arriving with no detection behind it (an
/// attachment that was already on the draft) never changes the checkout.
PickerSelectionState reducePickerSelection(
  PickerSelectionState state,
  PickerSelectionEvent event,
) => switch (event) {
  PrDetectedPickerEvent() => PickerSelectionState(
    selectedItem: state.selectedItem,
    allowAutoPrSelection: true,
  ),
  PrAddedPickerEvent(:final item) =>
    state.allowAutoPrSelection
        ? PickerSelectionState(selectedItem: item, allowAutoPrSelection: false)
        : state,
  PickerSelectedPickerEvent(:final item) => PickerSelectionState(
    selectedItem: item,
    allowAutoPrSelection: false,
  ),
  TargetChangedPickerEvent() => initialPickerSelectionState,
};

bool _isPrAttachment(UserComposerAttachment attachment) =>
    attachment is ForgeChangeRequestComposerAttachment ||
    attachment is GithubPrComposerAttachment;

int? _prAttachmentNumber(UserComposerAttachment attachment) =>
    switch (attachment) {
      ForgeChangeRequestComposerAttachment(:final item) => item.number,
      GithubPrComposerAttachment(:final item) => item.number,
      OtherUserComposerAttachment() => null,
    };

bool _isPickerOwnedPrAttachment(UserComposerAttachment attachment) =>
    attachment is GithubPrComposerAttachment &&
    attachment.owner == newWorkspacePickerAttachmentOwner;

/// Rewrites the attachment list so it reflects the picker's current selection.
///
/// Exactly one attachment is under the picker's control: the previous
/// picker-owned PR is always dropped first, and a newly selected change request
/// is appended — but only if the user has not already attached that same PR by
/// hand, under either the legacy or the forge-neutral kind. Duplicating it
/// would send the same change request to the agent twice and leave the user
/// with two pills they cannot tell apart.
///
/// A null [item] (or any non-change-request row) therefore means "just remove
/// mine", which is how a persisted picker selection is cleared without touching
/// anything the user added.
List<UserComposerAttachment> syncPickerPrAttachment({
  required List<UserComposerAttachment> attachments,
  required PickerItem? item,
}) {
  final nextAttachments = <UserComposerAttachment>[
    for (final attachment in attachments)
      if (!_isPickerOwnedPrAttachment(attachment)) attachment,
  ];

  if (item is ChangeRequestPickerItem) {
    final selectedPr = item.item;
    final hasExistingPrAttachment = nextAttachments.any(
      (attachment) =>
          _isPrAttachment(attachment) &&
          _prAttachmentNumber(attachment) == selectedPr.number,
    );
    if (!hasExistingPrAttachment) {
      return [
        ...nextAttachments,
        GithubPrComposerAttachment(
          ForgeSearchItemLike.of(selectedPr.number, selectedPr),
          owner: newWorkspacePickerAttachmentOwner,
        ),
      ];
    }
  }

  return nextAttachments;
}

/// Drops *every* change-request attachment when the picker's target changes.
///
/// Not just the picker's own: a PR belongs to one repository, so once the user
/// switches host or project every attached PR is about a repo they are no
/// longer creating a workspace in. Issues and files survive because they are
/// not repo-scoped in the same way.
///
/// Returns the *same list instance* when the target did not actually change, so
/// a caller comparing by identity can skip the state write entirely.
List<UserComposerAttachment> clearPickerPrAttachmentForTargetChange({
  required List<UserComposerAttachment> attachments,
  required String currentTargetId,
  required String nextTargetId,
}) {
  if (currentTargetId == nextTargetId) {
    return attachments;
  }
  return [
    for (final attachment in attachments)
      if (!_isPrAttachment(attachment)) attachment,
  ];
}

// ===========================================================================
// screens/new-workspace/project-selection.ts
// ===========================================================================

/// Who chose the project: the screen's own default, or the user.
///
/// The distinction drives everything below — an automatic choice may be
/// silently improved as data arrives, a manual one may not.
enum ProjectSelectionSource { initial, manual }

/// Where an automatic choice came from. Null (an absent value) means there was
/// no initial project at all.
enum InitialProjectSelectionSource {
  /// The route named this project.
  route,

  /// The user's last active project.
  lastActive,

  /// Neither — just the first selectable project.
  fallback,
}

/// The new-workspace screen's project selection.
///
/// [contextKey] is stored *on* the selection so a selection made under one set
/// of assumptions (this host, this route, these capabilities) can be detected
/// as stale when those assumptions change.
final class ProjectSelection {
  const ProjectSelection({
    required this.contextKey,
    required this.projectKey,
    required this.project,
    required this.source,
  });

  final String contextKey;
  final String? projectKey;

  /// The last known snapshot of the selected project. Kept alongside
  /// [projectKey] so a project that briefly disappears from the list — during a
  /// pending archive, say — can still be rendered.
  final HostProjectListItem? project;

  final ProjectSelectionSource source;

  @override
  bool operator ==(Object other) =>
      other is ProjectSelection &&
      other.contextKey == contextKey &&
      other.projectKey == projectKey &&
      other.project == project &&
      other.source == source;

  @override
  int get hashCode => Object.hash(contextKey, projectKey, project, source);

  @override
  String toString() =>
      'ProjectSelection(contextKey: $contextKey, projectKey: $projectKey, '
      'project: $project, source: ${source.name})';
}

/// Everything project reconciliation observes about the world.
final class ProjectSelectionContext {
  const ProjectSelectionContext({
    required this.contextKey,
    required this.manualContextKey,
    required this.initialProject,
    required this.initialProjectSource,
    required this.projects,
    required this.routeProject,
    required this.lastActiveProject,
    required this.shouldPreserveMissingProject,
  });

  /// Identity of the *automatic* selection's assumptions, including whether the
  /// host allows non-worktree projects.
  final String contextKey;

  /// Identity of a *manual* selection's assumptions. Deliberately coarser than
  /// [contextKey] — it omits the project-scope segment — so a capability change
  /// does not throw away a choice the user made by hand.
  final String manualContextKey;

  final HostProjectListItem? initialProject;
  final InitialProjectSelectionSource? initialProjectSource;

  /// The selectable projects, in display order. "First" here is a real
  /// fallback, so the order is load-bearing.
  final List<HostProjectListItem> projects;

  final HostProjectListItem? routeProject;
  final HostProjectListItem? lastActiveProject;

  /// Whether a project missing from [projects] should still be shown — true
  /// while its archive is in flight, so the row does not flicker away and back.
  final bool Function(HostProjectListItem project) shouldPreserveMissingProject;
}

/// The key identifying an automatic selection's assumptions.
///
/// The project-scope segment is part of the key because a host that gains
/// "all projects" capability can offer a *better* default than the git-only
/// one that was picked before, and that is a change worth resetting for.
String createProjectSelectionContextKey({
  required String selectedServerId,
  required String? routeProjectKey,
  required bool allowAllProjects,
}) {
  final projectScope = allowAllProjects ? 'all-projects' : 'worktree-projects';
  return '$selectedServerId:$projectScope:${routeProjectKey ?? ''}';
}

/// The key identifying a manual selection's assumptions.
///
/// Host and route only. A capability change must not discard a project the user
/// deliberately picked, so the scope segment is absent here on purpose.
String createManualProjectSelectionContextKey({
  required String selectedServerId,
  required String? routeProjectKey,
}) => '$selectedServerId:${routeProjectKey ?? ''}';

/// The screen's default selection for a context.
ProjectSelection createProjectSelection(ProjectSelectionContext context) =>
    ProjectSelection(
      contextKey: context.contextKey,
      projectKey: context.initialProject?.projectKey,
      project: context.initialProject,
      source: ProjectSelectionSource.initial,
    );

/// Classifies where an automatic choice came from.
///
/// The route is checked before the remembered project so that a deep link into
/// a project the user also happens to have used last is reported as `route` —
/// only a `lastActive` default may later be superseded, and a routed one must
/// not be.
InitialProjectSelectionSource? resolveInitialProjectSelectionSource({
  required HostProjectListItem? initialProject,
  required HostProjectListItem? routeProject,
  required HostProjectListItem? lastActiveProject,
}) {
  if (initialProject == null) {
    return null;
  }
  if (routeProject?.projectKey == initialProject.projectKey) {
    return InitialProjectSelectionSource.route;
  }
  if (lastActiveProject?.projectKey == initialProject.projectKey) {
    return InitialProjectSelectionSource.lastActive;
  }
  return InitialProjectSelectionSource.fallback;
}

/// Upstream's `selection.projectKey?.trim() ?? "" || null` — a blank key is
/// indistinguishable from no key.
String? _resolveProjectSelectionKey(ProjectSelection selection) {
  final projectKey = selection.projectKey?.trim() ?? '';
  return projectKey.isEmpty ? null : projectKey;
}

/// The route or remembered project matching [projectKey], if either does.
///
/// Only consulted for *automatic* selections: it is how a default survives the
/// window before `projects` has hydrated, and applying it to a manual selection
/// would resurrect a project the user did not pick.
HostProjectListItem? _resolveSelectedProjectFromInitialInputs(
  String projectKey,
  ProjectSelectionContext context,
) {
  final routeProject = context.routeProject;
  if (routeProject != null && routeProject.projectKey == projectKey) {
    return routeProject;
  }
  final lastActiveProject = context.lastActiveProject;
  if (lastActiveProject != null && lastActiveProject.projectKey == projectKey) {
    return lastActiveProject;
  }
  return null;
}

/// Points the selection at the freshest snapshot of the same project.
///
/// DEVIATION: upstream's guard is `selection.project === project` — reference
/// identity, so an equal-but-distinct snapshot still produces a new selection
/// object (and a React re-render). [HostProjectListItem] has value equality in
/// this repo, so [identical] is used to keep the upstream behavior rather than
/// silently strengthening the bail-out.
ProjectSelection _refreshSelectionProject(
  ProjectSelection selection,
  HostProjectListItem project,
) {
  if (selection.projectKey == project.projectKey &&
      identical(selection.project, project)) {
    return selection;
  }
  return ProjectSelection(
    contextKey: selection.contextKey,
    projectKey: project.projectKey,
    project: project,
    source: selection.source,
  );
}

/// Whether an automatic choice should step aside for a freshly hydrated
/// remembered project.
///
/// Only when the new default came from `lastActive`: the remembered project
/// arriving late is the one case where the screen genuinely knows better than
/// the choice it already made. A `route` or `fallback` default is left alone.
bool _shouldResetInitialFallbackSelection(
  ProjectSelection selection,
  ProjectSelectionContext context,
) {
  final initialProject = context.initialProject;
  if (selection.source != ProjectSelectionSource.initial ||
      initialProject == null ||
      context.initialProjectSource !=
          InitialProjectSelectionSource.lastActive) {
    return false;
  }

  return selection.projectKey != initialProject.projectKey;
}

/// The project a selection currently resolves to, or null when it resolves to
/// nothing and the caller should fall back.
///
/// Four cascading answers, most authoritative first: a project that is actually
/// selectable; the stored snapshot when the caller says a missing project is
/// only *temporarily* missing; and — for automatic selections only — the route
/// or remembered project it was derived from.
HostProjectListItem? resolveProjectSelection(
  ProjectSelection selection,
  ProjectSelectionContext context,
) {
  final projectKey = _resolveProjectSelectionKey(selection);
  if (projectKey == null) {
    return null;
  }

  for (final project in context.projects) {
    if (project.projectKey == projectKey) {
      return project;
    }
  }

  final storedProject = selection.project;
  if (storedProject != null &&
      storedProject.projectKey == projectKey &&
      context.shouldPreserveMissingProject(storedProject)) {
    return storedProject;
  }

  if (selection.source != ProjectSelectionSource.manual) {
    return _resolveSelectedProjectFromInitialInputs(projectKey, context);
  }

  return null;
}

/// Brings a selection up to date with a newly observed context.
///
/// Three outcomes, in order: the context's assumptions changed, so start over;
/// the remembered project just hydrated and beats an automatic default, so
/// start over; otherwise keep the selection, refreshed onto the newest snapshot
/// of the same project. A selection that no longer resolves to anything also
/// starts over.
///
/// A manual selection is compared against [ProjectSelectionContext.manualContextKey]
/// rather than [ProjectSelectionContext.contextKey], which is what lets a
/// user's explicit pick survive a host capability change.
ProjectSelection reconcileProjectSelection(
  ProjectSelection current,
  ProjectSelectionContext context,
) {
  final initialSelection = createProjectSelection(context);
  final currentContextKey = current.source == ProjectSelectionSource.manual
      ? context.manualContextKey
      : context.contextKey;
  if (current.contextKey != currentContextKey) {
    return initialSelection;
  }

  if (_shouldResetInitialFallbackSelection(current, context)) {
    return initialSelection;
  }

  final resolvedProject = resolveProjectSelection(current, context);
  if (resolvedProject != null) {
    return _refreshSelectionProject(current, resolvedProject);
  }

  return initialSelection;
}

// ===========================================================================
// screens/settings/appearance/apply-appearance.ts
// ===========================================================================

/// Which polarity a theme is authored in, for resolving a syntax palette.
enum AppearanceColorScheme { light, dark }

/// The registered theme keys [applyAppearance] patches, in upstream's order.
///
/// [AppThemeName.auto] is absent because it is not a theme — it is the
/// instruction to follow the OS, and resolves to `light` or `dark`, both of
/// which *are* patched. Patching all six regardless of which one is active is
/// deliberate: the active theme can change and adaptive mode can flip
/// light/dark, so this keeps ordering against any `setTheme` call irrelevant.
const List<AppThemeName> appearancePatchableThemeKeys = [
  AppThemeName.light,
  AppThemeName.dark,
  AppThemeName.zinc,
  AppThemeName.midnight,
  AppThemeName.claude,
  AppThemeName.ghostty,
];

/// The polarity of a theme key. Every key but [AppThemeName.light] is dark.
///
/// [AppThemeName.auto] answers [AppearanceColorScheme.dark], matching
/// `core/theme.dart`'s own default resolution for an unknown platform
/// brightness; it is never passed here by [applyAppearance].
AppearanceColorScheme appearanceColorSchemeForThemeKey(AppThemeName key) =>
    key == AppThemeName.light
    ? AppearanceColorScheme.light
    : AppearanceColorScheme.dark;

/// The two font stacks a theme carries.
final class AppearanceFontFamilies {
  const AppearanceFontFamilies({required this.ui, required this.mono});

  final String ui;
  final String mono;

  @override
  bool operator ==(Object other) =>
      other is AppearanceFontFamilies && other.ui == ui && other.mono == mono;

  @override
  int get hashCode => Object.hash(ui, mono);

  @override
  String toString() => 'AppearanceFontFamilies(ui: $ui, mono: $mono)';
}

/// A theme's font-size ramp.
///
/// DEVIATION: upstream's keys are `xs sm base lg xl 2xl 3xl 4xl code`. Dart
/// identifiers cannot start with a digit, so the three numeric steps are
/// spelled [xl2], [xl3], [xl4]; nothing else is renamed.
final class AppearanceFontSizeRamp {
  const AppearanceFontSizeRamp({
    required this.xs,
    required this.code,
    required this.sm,
    required this.base,
    required this.lg,
    required this.xl,
    required this.xl2,
    required this.xl3,
    required this.xl4,
  });

  final num xs;

  /// The mono/diff size. On a separate semantic axis from the UI ramp, so it is
  /// set absolutely and never scaled.
  final num code;

  final num sm;
  final num base;
  final num lg;
  final num xl;
  final num xl2;
  final num xl3;
  final num xl4;

  @override
  bool operator ==(Object other) =>
      other is AppearanceFontSizeRamp &&
      other.xs == xs &&
      other.code == code &&
      other.sm == sm &&
      other.base == base &&
      other.lg == lg &&
      other.xl == xl &&
      other.xl2 == xl2 &&
      other.xl3 == xl3 &&
      other.xl4 == xl4;

  @override
  int get hashCode => Object.hash(xs, code, sm, base, lg, xl, xl2, xl3, xl4);

  @override
  String toString() =>
      'AppearanceFontSizeRamp(xs: $xs, sm: $sm, base: $base, lg: $lg, '
      'xl: $xl, xl2: $xl2, xl3: $xl3, xl4: $xl4, code: $code)';
}

/// Upstream's authored `FONT_SIZE` ramp — the reference every scaled ramp is
/// derived from.
const AppearanceFontSizeRamp paseoFontSizeRamp = AppearanceFontSizeRamp(
  xs: 12,
  code: 12,
  sm: 14,
  base: 16,
  lg: 18,
  xl: 20,
  xl2: 22,
  xl3: 26,
  xl4: 34,
);

/// Upstream's authored `LINE_HEIGHT.diff`.
const int paseoDiffLineHeight = 22;

/// The UI font size the [paseoFontSizeRamp] is authored at — scale factor 1.0.
const int paseoBaseUiFontSizeReference = 16;

/// Upstream's `DEFAULT_UI_FONT_STACK` on native (RN's `Platform.select` default
/// branch). See [paseoDefaultUiFontStackWeb] / [paseoDefaultUiFontStackIos] for
/// the other two branches — `Platform.select` has no Dart analogue in a pure
/// library, so the branch is a parameter of [applyAppearance] instead.
const String paseoDefaultUiFontStack = 'normal';

/// Upstream's `DEFAULT_MONO_FONT_STACK` on native.
const String paseoDefaultMonoFontStack = 'monospace';

/// Upstream's `DEFAULT_UI_FONT_STACK` on iOS.
const String paseoDefaultUiFontStackIos = 'system-ui';

/// Upstream's `DEFAULT_MONO_FONT_STACK` on iOS.
const String paseoDefaultMonoFontStackIos = 'ui-monospace';

/// Upstream's `DEFAULT_UI_FONT_STACK` on web.
const String paseoDefaultUiFontStackWeb =
    "system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, "
    'Helvetica, Arial, sans-serif';

/// Upstream's `DEFAULT_MONO_FONT_STACK` on web.
const String paseoDefaultMonoFontStackWeb =
    "SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', "
    "'Courier New', monospace";

/// The user's appearance choices, already clamped by the settings screen.
final class AppearanceInput {
  const AppearanceInput({
    required this.uiFontFamily,
    required this.monoFontFamily,
    required this.uiFontSize,
    required this.codeFontSize,
    required this.syntaxTheme,
  });

  /// Blank (or whitespace-only) means "use the default stack".
  final String uiFontFamily;

  /// Blank (or whitespace-only) means "use the default stack".
  final String monoFontFamily;

  final num uiFontSize;
  final num codeFontSize;
  final SyntaxThemeId syntaxTheme;
}

/// The parts of a registered theme the appearance updater reads and replaces.
///
/// Modelled as one type for both the input and the output of the updater
/// because `UnistylesRuntime.updateTheme` *replaces* the stored theme rather
/// than merging into it — an omitted key would be dropped, which is why
/// [lineHeight] and [colors] are carried through as maps and only their
/// `diff` / `syntax` entries are overwritten.
final class AppearanceThemeSnapshot {
  const AppearanceThemeSnapshot({
    required this.colorScheme,
    required this.fontFamily,
    required this.fontSize,
    required this.lineHeight,
    required this.colors,
  });

  /// The theme's own polarity, which is what a syntax palette is resolved
  /// against — a named palette ignores it, but `github` (and every other
  /// dual-mode palette) does not.
  final AppearanceColorScheme colorScheme;

  final AppearanceFontFamilies fontFamily;
  final AppearanceFontSizeRamp fontSize;

  /// `diff` plus whatever else the theme carries.
  final Map<String, num> lineHeight;

  /// `syntax` plus every other color the theme carries — `foreground` and the
  /// rest are passed through untouched, because plain text is owned by the
  /// theme, not by the syntax palette.
  final Map<String, Object?> colors;

  @override
  String toString() =>
      'AppearanceThemeSnapshot(colorScheme: ${colorScheme.name}, '
      'fontFamily: $fontFamily, fontSize: $fontSize, '
      'lineHeight: $lineHeight, colors: $colors)';
}

/// The updater handed to [AppearanceThemeUpdate].
typedef AppearanceThemeUpdater =
    AppearanceThemeSnapshot Function(AppearanceThemeSnapshot theme);

/// Replaces one registered theme with the result of applying [AppearanceThemeUpdater]
/// to its current value.
///
/// Injected because upstream calls `UnistylesRuntime.updateTheme`, a
/// react-native-unistyles global that has no Dart counterpart.
typedef AppearanceThemeUpdate =
    void Function(AppThemeName key, AppearanceThemeUpdater updater);

/// Resolves a syntax palette for a theme id and polarity.
///
/// Injected because `@getpaseo/highlight`'s `resolveSyntaxColors` has no Dart
/// port yet. The palette is an opaque token->color map here; this module only
/// stores it.
typedef SyntaxColorsResolver =
    Map<String, String> Function(
      SyntaxThemeId theme,
      AppearanceColorScheme colorScheme,
    );

/// Builds the font-size ramp from the canonical [paseoFontSizeRamp], scaled by
/// `uiSize / 16` so the type hierarchy survives at non-default sizes.
///
/// Deriving from the *authored* ramp — never from the live, possibly
/// already-scaled theme — is what makes [applyAppearance] idempotent: repeated
/// applies never compound, and changing only the code size leaves the UI ramp
/// at its authored values.
///
/// DEVIATION (unobservable in practice): JavaScript's `Math.round` breaks ties
/// toward `+Infinity` while Dart's [num.round] breaks them away from zero. The
/// two agree for every non-negative input, and a font size is never negative.
AppearanceFontSizeRamp _scaleFontSize(num uiSize, num codeSize) {
  final r = uiSize / paseoBaseUiFontSizeReference;
  return AppearanceFontSizeRamp(
    xs: (paseoFontSizeRamp.xs * r).round(),
    sm: (paseoFontSizeRamp.sm * r).round(),
    base: (paseoFontSizeRamp.base * r).round(),
    lg: (paseoFontSizeRamp.lg * r).round(),
    xl: (paseoFontSizeRamp.xl * r).round(),
    xl2: (paseoFontSizeRamp.xl2 * r).round(),
    xl3: (paseoFontSizeRamp.xl3 * r).round(),
    xl4: (paseoFontSizeRamp.xl4 * r).round(),
    code: codeSize, // absolute, NOT scaled
  );
}

/// Patches every registered theme with the user's appearance choices.
///
/// All six keys are patched, in [appearancePatchableThemeKeys] order, even
/// though only one is active: the active key can change at any time and
/// adaptive mode can flip light/dark, so patching everything makes ordering
/// against theme selection irrelevant.
///
/// [applyRootUiFont] is upstream's web-only escape hatch — RN-web stamps a
/// default font on every text element, so the UI font cannot be delivered
/// through the theme alone. It is optional here because on Flutter there is
/// nothing to stamp.
///
/// DEVIATION: upstream's updater body is duplicated across a
/// `colorScheme === "light"` branch and an else branch. That is purely a
/// TypeScript narrowing workaround — spreading the theme union would widen
/// `colorScheme` and satisfy neither member — and the two branches are
/// character-identical. Dart needs no such split, so there is one branch.
void applyAppearance(
  AppearanceInput input, {
  required AppearanceThemeUpdate updateTheme,
  required SyntaxColorsResolver resolveSyntaxColors,
  void Function(String uiFontFamily)? applyRootUiFont,
  String uiFontStackFallback = paseoDefaultUiFontStack,
  String monoFontStackFallback = paseoDefaultMonoFontStack,
}) {
  // Upstream's `x.trim() || DEFAULT` — a whitespace-only family is no family.
  final trimmedUi = input.uiFontFamily.trim();
  final ui = trimmedUi.isEmpty ? uiFontStackFallback : trimmedUi;
  final trimmedMono = input.monoFontFamily.trim();
  final mono = trimmedMono.isEmpty ? monoFontStackFallback : trimmedMono;
  // Coupled to the code size, not the UI size: the diff viewer lays out mono
  // rows, so a bigger code font needs taller rows and a bigger UI font does not.
  final diffLineHeight = (input.codeFontSize * 1.5).round();

  for (final key in appearancePatchableThemeKeys) {
    updateTheme(key, (theme) {
      return AppearanceThemeSnapshot(
        colorScheme: theme.colorScheme,
        fontFamily: AppearanceFontFamilies(ui: ui, mono: mono),
        fontSize: _scaleFontSize(input.uiFontSize, input.codeFontSize),
        lineHeight: {...theme.lineHeight, 'diff': diffLineHeight},
        colors: {
          ...theme.colors,
          'syntax': resolveSyntaxColors(input.syntaxTheme, theme.colorScheme),
        },
      );
    });
  }

  applyRootUiFont?.call(ui);
}
