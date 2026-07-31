/// Port of Paseo 0.2.0's six *workspace path and identity* utilities. They live
/// in one library because they all answer the same family of question — "which
/// string names this workspace, this directory, this project, or this running
/// service?" — and because four of the six are built on the fifth
/// (`workspace-identity.ts`).
///
/// * `utils/workspace-identity.ts` — the canonical spelling rules. An *opaque
///   id* is only trimmed (it is a daemon-assigned handle and any other
///   rewriting would break equality); a *path* is additionally separator- and
///   trailing-slash-normalized so `C:\repo\app\` and `C:/repo/app` are the same
///   directory. These two rules must never be confused, which is why they are
///   separate public functions rather than one "normalize" helper.
/// * `utils/workspace-directory.ts` — the path rule plus a "must exist" wrapper
///   for the many call sites that cannot proceed without a directory.
/// * `utils/explorer-paths.ts` — joins a workspace-relative explorer entry onto
///   its workspace root, preserving whichever separator flavour the root uses.
/// * `utils/project-placement.ts` — the fallback project identity synthesized
///   when the daemon sent no placement (old daemons, or a bare cwd).
/// * `utils/workspace-archive-navigation.ts` — where to send the user after the
///   workspace they were looking at got archived.
/// * `utils/workspace-script-links.ts` — the ordered set of URLs a running
///   workspace service can be reached at, and which one to offer first.
///
/// Reused rather than redeclared: [isAbsolutePath] from `core/path.dart`,
/// [buildHostRootRoute]/[buildNewWorkspaceRoute] from `core/host_routes.dart`,
/// [deriveProjectKey]/[deriveProjectName] from `workspace/paseo_agent_grouping.dart`,
/// [isLoopbackHost] from `core/daemon_client.dart`, and [parseHostPort],
/// [WorkspaceDescriptor] and [WorkspaceScript] from `package:agent_protocol`.
///
/// [normalizeWorkspaceOpaqueId] and [normalizeWorkspacePath] are the intended
/// public home for the private `_normalizeWorkspacePath`/`_trimNonEmpty` copies
/// that `core/paseo_session_projection.dart` and `workspace/paseo_agent_grouping.dart`
/// each carry; this library may not edit those files, so collapsing them is a
/// follow-up.
library;

import 'package:agent_protocol/agent_protocol.dart'
    show
        WorkspaceDescriptor,
        WorkspaceScript,
        WorkspaceScriptLifecycle,
        WorkspaceScriptType,
        parseHostPort;
import 'package:coding_agent_app/core/daemon_client.dart' show isLoopbackHost;
import 'package:coding_agent_app/core/host_routes.dart'
    show NewWorkspaceRouteOptions, buildHostRootRoute, buildNewWorkspaceRoute;
import 'package:coding_agent_app/core/path.dart' show isAbsolutePath;
import 'package:coding_agent_app/workspace/paseo_agent_grouping.dart'
    show deriveProjectKey, deriveProjectName;

// ===========================================================================
// utils/workspace-identity.ts
// ===========================================================================

/// Upstream `trimNonEmpty`: a value that is only whitespace is indistinguishable
/// from a missing one, because both mean "no usable identity".
///
/// Upstream also guards `typeof value !== "string"` to survive untyped callers;
/// Dart's type system makes that branch unreachable, so only the null case
/// remains.
String? _trimNonEmpty(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Canonicalizes a *daemon-assigned* workspace id.
///
/// Deliberately trim-only. A workspace id is opaque: it may look like a path
/// (older daemons used the checkout directory as the id) but it is compared by
/// exact equality against ids the daemon sent, so rewriting separators or
/// trailing slashes would silently stop matching. [normalizeWorkspacePath] is
/// the function for values that really are paths.
String? normalizeWorkspaceOpaqueId(String? value) => _trimNonEmpty(value);

/// Canonicalizes a filesystem path so two spellings of one directory compare
/// equal: backslashes become forward slashes and trailing slashes are dropped.
///
/// The bare root `/` is special-cased because stripping its only slash would
/// leave the empty string, which would then be indistinguishable from "no
/// path". For the same reason a value that is *all* slashes (`///`) collapses
/// to `/` rather than to nothing.
String? normalizeWorkspacePath(String? value) {
  final trimmed = _trimNonEmpty(value);
  if (trimmed == null) return null;
  final withUnixSeparators = trimmed.replaceAll(r'\', '/');
  if (withUnixSeparators == '/') return withUnixSeparators;
  // Upstream's `/\/+$/` has no `g` flag, but `+$` is anchored so a single
  // replacement already consumes every trailing slash; `replaceFirst` is the
  // exact analogue.
  final withoutTrailingSlash = withUnixSeparators.replaceFirst(
    RegExp(r'/+$'),
    '',
  );
  return withoutTrailingSlash.isEmpty ? '/' : withoutTrailingSlash;
}

/// Canonicalizes the workspace id taken from a route parameter.
///
/// Routes carry opaque ids, so this is [normalizeWorkspaceOpaqueId] — a route
/// id that looks like `C:\tmp\repo\` keeps its backslashes and its trailing
/// slash, because that is what the daemon called the workspace.
String? resolveWorkspaceRouteId({required String? routeWorkspaceId}) =>
    normalizeWorkspaceOpaqueId(routeWorkspaceId);

/// Finds the key under which [workspaceId] is stored in [workspaces], or null.
///
/// Two lookups, in order: the id used verbatim as a key (the common case, since
/// stores key by id), then a scan comparing each descriptor's own normalized
/// id. The scan exists because a store may key by something else — a
/// `serverId:workspaceId` composite, say — while the descriptor still knows its
/// real id.
///
/// Matching is by *opaque id only*: a workspace directory that names the same
/// folder as the id does not match. Accepting directories here would let a
/// path-shaped id silently resolve to an unrelated workspace.
///
/// Iteration order follows the map's own order, which for Dart's default
/// `LinkedHashMap` is insertion order — the same order upstream's `Map` iterates
/// in, so the first match is the same one.
String? resolveWorkspaceMapKeyByIdentity({
  required Map<String, WorkspaceDescriptor>? workspaces,
  required String? workspaceId,
}) {
  final normalizedWorkspaceId = normalizeWorkspaceOpaqueId(workspaceId);
  if (normalizedWorkspaceId == null) return null;

  if (workspaces == null) return null;

  if (workspaces.containsKey(normalizedWorkspaceId)) {
    return normalizedWorkspaceId;
  }

  for (final entry in workspaces.entries) {
    if (normalizeWorkspaceOpaqueId(entry.value.id) == normalizedWorkspaceId) {
      return entry.key;
    }
  }

  return null;
}

// ===========================================================================
// utils/workspace-directory.ts
// ===========================================================================

/// The canonical directory for a workspace, or null when there is none.
///
/// A thin named wrapper over [normalizeWorkspacePath]. It exists upstream so
/// that call sites read as "resolve the workspace's directory" rather than as a
/// string operation, and so the pair below can share one rule.
String? resolveWorkspaceDirectory({required String? workspaceDirectory}) =>
    normalizeWorkspacePath(workspaceDirectory);

/// The canonical directory for a workspace, throwing when there is none.
///
/// Used by the many operations (spawn an agent, open a terminal, read a file)
/// that are meaningless without a directory: failing loudly beats passing an
/// empty string down to the daemon.
///
/// [workspaceId] only enriches the message. Upstream tests it for JS
/// truthiness, so an *empty* id produces the generic message rather than
/// `... for workspace `; that is reproduced here with an explicit emptiness
/// check.
///
/// Throws [StateError], the repo's analogue of upstream's bare `Error`, with
/// upstream's exact message text.
String requireWorkspaceDirectory({
  String? workspaceId,
  required String? workspaceDirectory,
}) {
  final directory = resolveWorkspaceDirectory(
    workspaceDirectory: workspaceDirectory,
  );
  if (directory == null) {
    throw StateError(
      workspaceId != null && workspaceId.isNotEmpty
          ? 'Workspace directory is missing for workspace $workspaceId'
          : 'Workspace directory is missing.',
    );
  }
  return directory;
}

// ===========================================================================
// utils/explorer-paths.ts
// ===========================================================================

/// Joins a file-explorer entry path onto its workspace root.
///
/// The explorer speaks workspace-relative paths, but every action taken on an
/// entry (open, reveal, drag out) needs the absolute path the daemon's
/// filesystem uses. The separator is inferred from the root rather than from
/// the host platform, because the root came from the *daemon*, which may run a
/// different OS than the client rendering the tree.
///
/// Degenerate inputs fall back rather than throw, so a half-loaded explorer
/// still produces something addressable:
///
/// * a blank root yields the entry path alone;
/// * a blank or `.` entry path yields the root (`.` is how the daemon names the
///   explorer's own root row);
/// * an already-absolute entry path passes through untouched;
/// * an entry path that is nothing but separators yields the root.
///
/// Note that a root of `/` is *blank* after its trailing separator is stripped,
/// so joining against the Unix root returns the bare entry path.
String buildAbsoluteExplorerPath({
  required String workspaceRoot,
  required String entryPath,
}) {
  final normalizedWorkspaceRoot = workspaceRoot.trim().replaceFirst(
    RegExp(r'[\\/]+$'),
    '',
  );
  final normalizedEntryPath = entryPath.trim();

  if (normalizedWorkspaceRoot.isEmpty) {
    return normalizedEntryPath;
  }

  if (normalizedEntryPath.isEmpty || normalizedEntryPath == '.') {
    return normalizedWorkspaceRoot;
  }

  if (isAbsolutePath(normalizedEntryPath)) {
    return normalizedEntryPath;
  }

  final separator = normalizedWorkspaceRoot.contains(r'\') ? r'\' : '/';
  final segments = normalizedEntryPath
      .split(RegExp(r'[\\/]+'))
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  if (segments.isEmpty) {
    return normalizedWorkspaceRoot;
  }

  return '$normalizedWorkspaceRoot$separator${segments.join(separator)}';
}

// ===========================================================================
// utils/project-placement.ts
// ===========================================================================

/// What a placement knows about the checkout an agent is running in.
///
/// Upstream is a three-member zod union discriminated by `isGit` and
/// `isPaseoOwnedWorktree`; the repo style for a TS union is a sealed hierarchy,
/// so the discriminants become the subtype rather than boolean fields that can
/// disagree with each other.
sealed class ProjectCheckoutLite {
  const ProjectCheckoutLite({required this.cwd});

  /// The directory the agent runs in.
  final String cwd;

  /// Whether [cwd] is inside a git repository.
  bool get isGit;

  /// Whether the worktree at [cwd] is one Paseo created and owns.
  bool get isPaseoOwnedWorktree;

  /// The branch checked out at [cwd], when git and detached-HEAD-free.
  String? get currentBranch;

  /// The `origin`-ish remote URL, when there is one.
  String? get remoteUrl;

  /// The root of the worktree containing [cwd].
  String? get worktreeRoot;

  /// The primary repository a worktree was cut from.
  String? get mainRepoRoot;
}

/// A checkout that is not a git repository at all.
///
/// Upstream pins every git-only field to `null` in the schema, so they are
/// constants here rather than constructor parameters — there is no way to build
/// a non-git checkout that claims a branch.
final class NotGitProjectCheckout extends ProjectCheckoutLite {
  const NotGitProjectCheckout({required super.cwd});

  @override
  bool get isGit => false;

  @override
  bool get isPaseoOwnedWorktree => false;

  @override
  String? get currentBranch => null;

  @override
  String? get remoteUrl => null;

  /// Always null. Upstream's transform pins this to `null` for the non-git
  /// member even when the payload omitted it, unlike the two git members, which
  /// default it to `cwd`.
  @override
  String? get worktreeRoot => null;

  @override
  String? get mainRepoRoot => null;
}

/// A git checkout that Paseo did not create: a plain clone, or a worktree the
/// user made themselves.
final class GitProjectCheckout extends ProjectCheckoutLite {
  GitProjectCheckout({
    required super.cwd,
    required this.currentBranch,
    required this.remoteUrl,
    String? worktreeRoot,
    this.mainRepoRoot,
    // Upstream's transform is `worktreeRoot ?? cwd`, applied at parse time.
  }) : worktreeRoot = worktreeRoot ?? cwd;

  @override
  bool get isGit => true;

  @override
  bool get isPaseoOwnedWorktree => false;

  @override
  final String? currentBranch;

  @override
  final String? remoteUrl;

  @override
  final String worktreeRoot;

  @override
  final String? mainRepoRoot;
}

/// A git worktree Paseo created for a workspace.
///
/// [mainRepoRoot] is non-null here and only here: a Paseo-owned worktree always
/// knows the repository it was cut from, which is what lets sibling workspaces
/// group together.
final class PaseoWorktreeProjectCheckout extends ProjectCheckoutLite {
  PaseoWorktreeProjectCheckout({
    required super.cwd,
    required this.currentBranch,
    required this.remoteUrl,
    required this.mainRepoRoot,
    String? worktreeRoot,
  }) : worktreeRoot = worktreeRoot ?? cwd;

  @override
  bool get isGit => true;

  @override
  bool get isPaseoOwnedWorktree => true;

  @override
  final String? currentBranch;

  @override
  final String? remoteUrl;

  @override
  final String worktreeRoot;

  @override
  final String mainRepoRoot;
}

/// Which project (and optionally which named workspace) an agent belongs to.
///
/// Port of upstream's `ProjectPlacementPayload`. The daemon normally computes
/// this — it is the side that can run `git` — and the client only synthesizes
/// one when the payload is absent.
final class ProjectPlacement {
  const ProjectPlacement({
    required this.projectKey,
    required this.projectName,
    required this.workspaceName,
    required this.checkout,
  });

  /// The grouping key. Either a remote-derived key or a directory path.
  final String projectKey;

  /// The short label derived from [projectKey].
  final String projectName;

  /// The workspace within the project, when the agent belongs to a named one.
  final String? workspaceName;

  final ProjectCheckoutLite checkout;
}

/// Builds the placement to use when the daemon sent none, from a cwd alone.
///
/// It reports `isGit: false` unconditionally — not because the directory is
/// known to be outside a repository, but because the client cannot run `git`
/// and refuses to guess. The one inference it *does* make is
/// [deriveProjectKey]'s: a path inside `.paseo/worktrees/` is attributed to the
/// repository above it, so a fallback placement still groups a worktree with
/// its siblings.
///
/// A blank cwd becomes `.`, so the derived key is never the empty string.
ProjectPlacement deriveProjectPlacementFromCwd(String cwd) {
  final normalizedCwd = _normalizeWorkingDirectory(cwd);
  final projectKey = deriveProjectKey(normalizedCwd);

  return ProjectPlacement(
    projectKey: projectKey,
    projectName: deriveProjectName(projectKey),
    workspaceName: null,
    checkout: NotGitProjectCheckout(cwd: normalizedCwd),
  );
}

/// Upstream `normalizeWorkingDirectory`.
String _normalizeWorkingDirectory(String cwd) {
  final trimmed = cwd.trim();
  return trimmed.isEmpty ? '.' : trimmed;
}

/// The daemon's placement when it sent one, else the cwd-derived fallback.
///
/// Returns the *same instance* it was given when one is present, so callers can
/// keep using identity to detect "nothing changed".
ProjectPlacement resolveProjectPlacement({
  required ProjectPlacement? projectPlacement,
  required String cwd,
}) => projectPlacement ?? deriveProjectPlacementFromCwd(cwd);

// ===========================================================================
// utils/workspace-archive-navigation.ts
// ===========================================================================

/// Where to navigate once the workspace being viewed has been archived.
///
/// The destination is the *new workspace* screen pre-filled with the archived
/// workspace's project, not a sibling workspace: archiving is usually "I am done
/// with this branch, start the next one", and silently landing the user in an
/// unrelated workspace loses that intent. When the project cannot be identified
/// the fallback is the host root.
///
/// The lookup compares descriptor ids verbatim against the *trimmed* archived
/// id, matching upstream — descriptor ids arrive already-normalized from the
/// store, so no second normalization is applied to them here.
///
/// [WorkspaceDescriptor.projectRootPath] is preferred over
/// [WorkspaceDescriptor.workspaceDirectory] because the new workspace should be
/// cut from the repository, not from the archived worktree. Upstream's `||`
/// makes an *empty* root fall through to the directory, so emptiness is tested
/// rather than nullness (the Dart fields are non-nullable strings).
String buildWorkspaceArchiveRedirectRoute({
  required String serverId,
  required String archivedWorkspaceId,
  required Iterable<WorkspaceDescriptor> workspaces,
}) {
  final normalizedArchivedWorkspaceId = resolveWorkspaceRouteId(
    routeWorkspaceId: archivedWorkspaceId,
  );
  if (normalizedArchivedWorkspaceId == null) {
    return buildHostRootRoute(serverId);
  }

  WorkspaceDescriptor? archivedWorkspace;
  for (final workspace in workspaces) {
    if (workspace.id == normalizedArchivedWorkspaceId) {
      archivedWorkspace = workspace;
      break;
    }
  }
  if (archivedWorkspace == null) {
    return buildHostRootRoute(serverId);
  }

  final sourceDirectory = archivedWorkspace.projectRootPath.isNotEmpty
      ? archivedWorkspace.projectRootPath
      : archivedWorkspace.workspaceDirectory;
  if (sourceDirectory.isEmpty) {
    return buildHostRootRoute(serverId);
  }

  return buildNewWorkspaceRoute(
    NewWorkspaceRouteOptions(
      serverId: serverId,
      sourceDirectory: sourceDirectory,
      displayName: archivedWorkspace.projectDisplayName,
      projectId: archivedWorkspace.projectId,
    ),
  );
}

// ===========================================================================
// utils/workspace-script-links.ts
// ===========================================================================

/// The transport the client is currently using to reach a daemon.
///
/// Port of upstream's `ActiveConnection` union from `runtime/host-runtime.ts`.
/// Only the TCP member carries information this library uses — it is the one
/// case where the daemon's host is also reachable from the client — but the
/// whole union is modelled so a `switch` over it stays exhaustive.
///
/// Distinct from `package:agent_protocol`'s [HostConnection], which is the
/// *stored configuration* for a connection (with an id, credentials, and TLS
/// settings). This is the runtime "what are we connected over right now"
/// snapshot, and it is what upstream's script-link rule is given.
sealed class ActiveConnection {
  const ActiveConnection({required this.endpoint, required this.display});

  /// The address the transport dialled, in whatever form that transport uses.
  final String endpoint;

  /// The short label the UI shows for this connection.
  final String display;
}

/// A direct TCP connection to a daemon at a `host:port` endpoint.
final class DirectTcpActiveConnection extends ActiveConnection {
  const DirectTcpActiveConnection({
    required super.endpoint,
    required super.display,
  });
}

/// A direct connection over a Unix domain socket.
final class DirectSocketActiveConnection extends ActiveConnection {
  const DirectSocketActiveConnection({required super.endpoint})
    : super(display: 'socket');
}

/// A direct connection over a Windows named pipe.
final class DirectPipeActiveConnection extends ActiveConnection {
  const DirectPipeActiveConnection({required super.endpoint})
    : super(display: 'pipe');
}

/// A connection brokered by the relay.
final class RelayActiveConnection extends ActiveConnection {
  const RelayActiveConnection({required super.endpoint})
    : super(display: 'relay');
}

/// How a workspace service URL reaches the service.
///
/// The order of the members is the preference order used by
/// [resolveWorkspaceScriptLink]: a URL that works from anywhere beats one that
/// only works on the daemon's own machine, which beats a raw host and port.
enum WorkspaceScriptLinkKind {
  /// A reverse proxy the operator configured, reachable from the public
  /// internet.
  public,

  /// Paseo's own local proxy, on a memorable `*.localhost` name.
  paseo,

  /// The service's own host and port, with no proxy in front of it.
  direct,
}

/// One way to open a running workspace service.
final class WorkspaceScriptLinkTarget {
  const WorkspaceScriptLinkTarget({
    required this.kind,
    required this.label,
    required this.url,
  });

  final WorkspaceScriptLinkKind kind;

  /// [url] with any leading `http://` or `https://` removed, because the scheme
  /// is noise in a link chip.
  final String label;

  final String url;

  @override
  bool operator ==(Object other) =>
      other is WorkspaceScriptLinkTarget &&
      other.kind == kind &&
      other.label == label &&
      other.url == url;

  @override
  int get hashCode => Object.hash(kind, label, url);

  @override
  String toString() =>
      'WorkspaceScriptLinkTarget(kind: $kind, label: $label, url: $url)';
}

/// Every way to open a workspace service, plus the one to offer by default.
final class ResolvedWorkspaceScriptLink {
  const ResolvedWorkspaceScriptLink({
    required this.primary,
    required this.targets,
  });

  /// The first of [targets], or null when there are none. Kept as its own field
  /// rather than computed by callers so "what does clicking the row do" has a
  /// single answer.
  final WorkspaceScriptLinkTarget? primary;

  /// The targets, most-reachable first, deduplicated by URL.
  final List<WorkspaceScriptLinkTarget> targets;

  @override
  bool operator ==(Object other) {
    if (other is! ResolvedWorkspaceScriptLink) return false;
    if (other.primary != primary) return false;
    if (other.targets.length != targets.length) return false;
    for (var index = 0; index < targets.length; index += 1) {
      if (other.targets[index] != targets[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(primary, Object.hashAll(targets));

  @override
  String toString() =>
      'ResolvedWorkspaceScriptLink(primary: $primary, targets: $targets)';
}

/// The hostname a JavaScript `new URL(url)` would report, or null where that
/// constructor would have thrown.
///
/// Two deliberate adjustments make Dart's lenient [Uri] behave like the
/// WHATWG parser upstream relies on:
///
/// * `Uri.parse` accepts scheme-less input (`"not a url"`, `"//host/path"`)
///   that `new URL` rejects, so a missing scheme is reported as a failure.
/// * `Uri.host` strips the brackets from an IPv6 authority while
///   `URL.hostname` keeps them, so they are re-added. This is observable:
///   `http://[::1]:3000` must *not* be classified as loopback, because the
///   bracketed form never equals the bare `::1` upstream compares against.
///
/// A scheme that WHATWG requires a non-empty host for, so `new URL` throws
/// without one. `file` is special too but is allowed an empty host, and every
/// non-special scheme (`mailto:`, `data:`, …) simply reports an empty hostname.
///
/// Known divergence: `new URL("http:///path")` collapses the empty authority
/// and reports the hostname `path`, whereas the rule below reports a failure.
/// The rule is kept because it makes the far more likely `"http://"` — which
/// `new URL` also rejects — correct, and because failure is the conservative
/// answer for [_isLocalOnlyUrl].
bool _requiresHost(String scheme) =>
    const {'http', 'https', 'ws', 'wss', 'ftp'}.contains(scheme);

String? _urlHostname(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return null;
  final host = uri.host;
  if (host.isEmpty && _requiresHost(uri.scheme)) return null;
  // `Uri` already lower-cases a registered name; the explicit fold matches
  // upstream's `.toLowerCase()` for the bracketed-IPv6 and percent-escaped
  // shapes it leaves alone.
  return host.contains(':') ? '[$host]'.toLowerCase() : host.toLowerCase();
}

/// Whether [url] can only be opened on the machine the daemon runs on.
///
/// `null`, blank and unparseable URLs count as local-only: this classifies a
/// legacy daemon's single `proxyUrl` field, and mislabelling an unknown URL as
/// *public* would advertise a link that leaks nothing but fails for everyone.
bool _isLocalOnlyUrl(String? url) {
  if (url == null || url.isEmpty) return true;
  final hostname = _urlHostname(url);
  if (hostname == null) return true;
  return _isLoopbackHostname(hostname) || hostname.endsWith('.localhost');
}

/// Upstream's `isLoopbackHost`, which trims and lower-cases before comparing.
///
/// Delegates to `core/daemon_client.dart`'s [isLoopbackHost] for the comparison
/// itself; that one takes an already-canonical host, so the normalization
/// upstream performs inline is applied here first.
bool _isLoopbackHostname(String host) =>
    isLoopbackHost(host.trim().toLowerCase());

/// Upstream `stripUrlProtocol`: drop a leading `http://` or `https://` only.
String _stripUrlProtocol(String url) =>
    url.replaceFirst(RegExp(r'^https?://'), '');

/// The service's own address, bypassing every proxy.
///
/// Only a direct TCP connection can tell us a host that is meaningful from the
/// client: over a socket, a pipe, or the relay we know the daemon is reachable
/// but not at what address, so `localhost` is assumed — correct when the daemon
/// is on this machine, and a harmless dead link otherwise.
///
/// A loopback daemon endpoint is rewritten to the literal `localhost` (nicer to
/// read than `127.0.0.1`), and an IPv6 host is re-bracketed so the result is a
/// valid URL authority.
String? _buildDirectServiceUrl(ActiveConnection? activeConnection, int? port) {
  if (port == null) return null;
  if (activeConnection is! DirectTcpActiveConnection) {
    return 'http://localhost:$port';
  }
  try {
    final parts = parseHostPort(activeConnection.endpoint);
    var base = parts.host;
    if (_isLoopbackHostname(parts.host)) {
      base = 'localhost';
    } else if (parts.isIpv6) {
      base = '[${parts.host}]';
    }
    return 'http://$base:$port';
  } on FormatException {
    // Upstream catches *any* throw from `parseHostPort`; the Dart port of that
    // function only ever raises `FormatException`.
    return 'http://localhost:$port';
  }
}

/// Upstream `addTarget`: append unless the URL is absent or already present.
void _addTarget(
  List<WorkspaceScriptLinkTarget> targets,
  WorkspaceScriptLinkKind kind,
  String? url,
) {
  if (url == null || url.isEmpty) return;
  if (targets.any((target) => target.url == url)) return;
  targets.add(
    WorkspaceScriptLinkTarget(
      kind: kind,
      label: _stripUrlProtocol(url),
      url: url,
    ),
  );
}

/// Every URL a workspace script can currently be opened at, best first.
///
/// Only a *service* that is *running* has links; a plain script produces no
/// URL, and a stopped service's proxies no longer answer, so both yield an
/// empty result rather than a dead link.
///
/// The ordering is public proxy, then Paseo's local proxy, then the direct
/// host and port — most-reachable to least. Duplicates are dropped by URL, so
/// a daemon that reports the same address twice contributes one chip.
ResolvedWorkspaceScriptLink resolveWorkspaceScriptLink({
  required WorkspaceScript script,
  required ActiveConnection? activeConnection,
}) {
  if (script.type != WorkspaceScriptType.service ||
      script.lifecycle != WorkspaceScriptLifecycle.running) {
    return const ResolvedWorkspaceScriptLink(primary: null, targets: []);
  }

  // COMPAT(workspaceScriptSplitUrls): added in v0.2.0, remove after 2027-01-21.
  // Old daemons only send proxyUrl, so classify it by reachability.
  final localProxyUrl =
      script.localProxyUrl ??
      (_isLocalOnlyUrl(script.proxyUrl) ? script.proxyUrl : null);
  final publicProxyUrl =
      script.publicProxyUrl ??
      (!_isLocalOnlyUrl(script.proxyUrl) ? script.proxyUrl : null);

  final targets = <WorkspaceScriptLinkTarget>[];
  _addTarget(targets, WorkspaceScriptLinkKind.public, publicProxyUrl);
  _addTarget(targets, WorkspaceScriptLinkKind.paseo, localProxyUrl);
  _addTarget(
    targets,
    WorkspaceScriptLinkKind.direct,
    _buildDirectServiceUrl(activeConnection, script.port),
  );

  return ResolvedWorkspaceScriptLink(
    primary: targets.isEmpty ? null : targets.first,
    targets: targets,
  );
}
