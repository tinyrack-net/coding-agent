/// Frozen Paseo 0.2.0 port of the four modules that together answer "where did
/// this thing come from, and where does it live now?".
///
/// Upstream sources (read-only, `packages/server/src`):
///
/// * `utils/path.ts` — the string-only path-equivalence and containment law the
///   daemon uses to decide whether two spellings of a directory are the same
///   directory. Deliberately *not* the registry's `areEquivalentPaths`: this one
///   never touches the host filesystem to normalize, so it can compare a Windows
///   path while running on POSIX (which is exactly what the upstream suite
///   pins).
/// * `server/workspace-registry-bootstrap.ts` (plus its
///   `workspace-registry-bootstrap-legacy.ts` classifier, the three `derive*`
///   helpers it borrows from `server/workspace-registry-model.ts`, and
///   `utils/git-rev-parse-path.ts`) — the one-time migration that materializes
///   `projects.json` / `workspaces.json` out of pre-registry agent records.
/// * `tasks/task-store.ts` (plus `tasks/task-document.ts` and the two
///   `tasks/task-graph.ts` predicates it needs) — the markdown-file-backed task
///   store.
/// * `server/agent/providers/provider-image-output.ts` — turning a provider's
///   image output into assistant markdown, materializing inline base64 into a
///   private temp file when that is the only form available.
///
/// The four are grouped because the parity cluster ships them together; they
/// share only this library's path primitives.
///
/// Every wall-clock read and every random id is injected. The filesystem is
/// *not* injected: the daemon really touches the disk here, and the suite runs
/// against real temp directories, which is the established pattern in this
/// package.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../agent/agent_store.dart';
import '../services/paseo_quota_and_tasks.dart';
import '../workspace/paseo_workspace_identity.dart';
import '../workspace/workspace_registry.dart';
import 'private_files.dart';

// `isRealpathInsideRoot` is upstream `utils/path.ts`'s
// `getRealpathAwareRelativePath(...) !== null`, and this repo already ported it
// (for the self-update install-origin check). Re-exported rather than
// re-implemented so there is exactly one symlink-aware containment predicate in
// the daemon.
export 'paseo_self_update.dart' show isRealpathInsideRoot;

// ---------------------------------------------------------------------------
// utils/path.ts
// ---------------------------------------------------------------------------

/// Expands a leading `~` in [path] to the user's home directory.
///
/// Only a bare `~` or a `~/`-prefixed path is expanded; `~user` and a `~` that
/// appears anywhere but the front are returned untouched, because upstream
/// guards the rewrite with those two exact shapes.
///
/// [homeDirectory] overrides the resolved home; leave it unset outside tests.
///
/// Deviation: upstream is `process.env.HOME || os.homedir()`. Dart has no
/// `os.homedir()`, so this repo's [defaultUserHomeDirectory] (`USERPROFILE`
/// before `HOME`, then the process cwd) stands in for it while `HOME` keeps
/// upstream's first-place priority. The `||` also means an *empty* `HOME` falls
/// through to the homedir lookup, which the explicit emptiness check preserves.
String expandTilde(String path, {String? homeDirectory}) {
  String home() {
    if (homeDirectory != null) return homeDirectory;
    final envHome = Platform.environment['HOME'];
    if (envHome != null && envHome.isNotEmpty) return envHome;
    return defaultUserHomeDirectory();
  }

  if (path.startsWith('~/')) {
    // Upstream is `path.replace("~", homeDir)`, which replaces the first `~` —
    // guaranteed to be the leading one by the `startsWith` guard above.
    return '${home()}${path.substring(1)}';
  }
  if (path == '~') return home();
  return path;
}

/// Whether [left] and [right] name the same directory, comparing as strings.
///
/// Normalizes separators and dot segments, ignores trailing separators, strips
/// Windows `\\?\` namespace prefixes, and case-folds *only* when at least one
/// side is unmistakably a Windows path. It never resolves symlinks and never
/// checks whether either path exists — which is what makes it usable for
/// filtering a cwd that belongs to a different machine.
///
/// Named apart from the registry's `areEquivalentPaths` (in
/// `workspace/workspace_registry.dart`) on purpose: that one resolves against
/// the *running* process's cwd and case-folds by host platform, so the two are
/// genuinely different predicates and must not be confused. Upstream's name for
/// this function is `areEquivalentPaths`.
bool areEquivalentPathStrings(String left, String right) {
  final compareAsWindows = _shouldCompareAsWindows(left, right);
  return _normalizePathForComparison(left, compareAsWindows) ==
      _normalizePathForComparison(right, compareAsWindows);
}

/// Builds a reusable predicate that answers [areEquivalentPathStrings] against
/// a fixed [target].
///
/// The target's normalization is computed once. The Windows-ness of the
/// comparison is still re-decided per candidate: a POSIX-looking target
/// compared against a Windows-looking candidate switches the whole comparison
/// to Windows rules (and re-normalizes the target under them), exactly as
/// [areEquivalentPathStrings] would have.
bool Function(String candidate) createPathEquivalenceMatcher(String target) {
  final compareAsWindows = _looksLikeDefiniteWindowsPath(target);
  final normalizedTarget = _normalizePathForComparison(
    target,
    compareAsWindows,
  );

  return (candidate) {
    final candidateCompareAsWindows =
        compareAsWindows || _looksLikeDefiniteWindowsPath(candidate);
    final comparableTarget = candidateCompareAsWindows == compareAsWindows
        ? normalizedTarget
        : _normalizePathForComparison(target, candidateCompareAsWindows);
    return _normalizePathForComparison(candidate, candidateCompareAsWindows) ==
        comparableTarget;
  };
}

/// Like [createPathEquivalenceMatcher], but also compares symlink-resolved
/// spellings of both sides.
///
/// Every variant of the target is matched against every variant of the
/// candidate, so a path reached through a symlinked parent still compares equal
/// to the same path reached literally.
bool Function(String candidate) createRealpathAwarePathMatcher(String target) {
  final targetMatchers = _collectPathVariants(
    target,
  ).map(createPathEquivalenceMatcher).toList(growable: false);

  return (candidate) => _collectPathVariants(
    candidate,
  ).any((variant) => targetMatchers.any((matches) => matches(variant)));
}

/// Whether [candidate] is [root] itself or lives beneath it.
///
/// String-only, like [areEquivalentPathStrings]: `/opt/paseo` contains
/// `/opt/paseo/node_modules` but not the sibling `/opt/paseo-other`.
bool isPathInsideRoot(String root, String candidate) =>
    _getRelativePathInsideRoot(root, candidate) != null;

/// The suffix of [candidate] relative to [root] when it is inside [root],
/// otherwise `null`.
///
/// Symlink-aware: every literal/resolved pairing of the two paths is tried, and
/// the suffix is derived from *the same* pair that proved containment. Callers
/// that re-root an existing filesystem path must keep those two operations
/// coupled, or they will graft a suffix computed against one root onto another.
///
/// Deviation: Node's `path.relative` yields `''` when the two paths are equal
/// while Dart's yields `'.'`; the `'.'` is normalized back to `''` so callers
/// see upstream's empty-suffix contract.
String? getRealpathAwareRelativePath(String root, String candidate) {
  for (final rootVariant in _collectPathVariants(root)) {
    for (final candidateVariant in _collectPathVariants(candidate)) {
      final relativePath = _getRelativePathInsideRoot(
        rootVariant,
        candidateVariant,
      );
      if (relativePath != null) return relativePath;
    }
  }
  return null;
}

String? _getRelativePathInsideRoot(String root, String candidate) {
  final compareAsWindows = _shouldCompareAsWindows(root, candidate);
  final context = compareAsWindows ? p.windows : p.posix;
  final normalizedRoot = _normalizePathForComparison(root, compareAsWindows);
  final normalizedCandidate = _normalizePathForComparison(
    candidate,
    compareAsWindows,
  );

  final String relative;
  try {
    relative = context.relative(normalizedCandidate, from: normalizedRoot);
  } on Object {
    // Dart throws when exactly one side is relative; Node instead returns a
    // `..`-prefixed string, which is a rejection either way.
    return null;
  }

  if (relative == '.') return '';
  return relative.isEmpty ||
          (!relative.startsWith('..') && !context.isAbsolute(relative))
      ? relative
      : null;
}

/// The literal path plus any symlink-resolved spellings of it.
///
/// Deviation: Node tries both `realpathSync.native` and `realpathSync`. Dart
/// exposes one resolver reached through whichever entity type the path happens
/// to be, so both `Directory` and `File` are attempted and failures are
/// ignored — a path that does not exist simply contributes no extra variant,
/// which is upstream's fallback too.
List<String> _collectPathVariants(String value) {
  final variants = <String>{value};
  try {
    variants.add(Directory(value).resolveSymbolicLinksSync());
  } on Object {
    // Not a directory, or does not exist.
  }
  try {
    variants.add(File(value).resolveSymbolicLinksSync());
  } on Object {
    // Not a file, or does not exist.
  }
  return variants.toList(growable: false);
}

bool _shouldCompareAsWindows(String left, String right) =>
    _looksLikeDefiniteWindowsPath(left) || _looksLikeDefiniteWindowsPath(right);

final RegExp _windowsDrivePattern = RegExp(r'^[a-zA-Z]:[\\/]');
final RegExp _windowsNamespacePattern = RegExp(r'^[/\\]{2}\?[/\\]');
final RegExp _windowsUncPattern = RegExp(r'^\\{2}[^/\\]+[/\\][^/\\]+');
final RegExp _windowsNamespaceDrivePattern = RegExp(
  r'^[/\\]{2}\?[/\\]([a-zA-Z]:)[/\\](.*)$',
);
final RegExp _windowsNamespaceUncPattern = RegExp(
  r'^[/\\]{2}\?[/\\]UNC[/\\]([^/\\]+)[/\\]([^/\\]+)(?:[/\\](.*))?$',
  caseSensitive: false,
);

bool _looksLikeDefiniteWindowsPath(String value) =>
    _windowsDrivePattern.hasMatch(value) ||
    _windowsNamespacePattern.hasMatch(value) ||
    _windowsUncPattern.hasMatch(value);

String _normalizePathForComparison(String value, bool compareAsWindows) {
  final context = compareAsWindows ? p.windows : p.posix;
  final comparableValue = compareAsWindows
      ? _stripWindowsNamespacePrefix(value)
      : value;
  final platformNormalized = context.normalize(comparableValue);
  final normalized = _stripTrailingSeparators(
    platformNormalized,
    context.rootPrefix(platformNormalized),
    compareAsWindows,
  );
  return compareAsWindows ? normalized.toLowerCase() : normalized;
}

/// Rewrites `\\?\C:\x` to `C:\x` and `\\?\UNC\server\share\x` to
/// `\\server\share\x`.
///
/// Anything else keeps its namespace prefix. That is upstream's behavior, and
/// it matters here because `package:path`'s Windows context mangles a surviving
/// `\\?\` prefix differently from Node's — so the two only agree on the two
/// shapes this function knows how to unwrap.
String _stripWindowsNamespacePrefix(String value) {
  final driveMatch = _windowsNamespaceDrivePattern.firstMatch(value);
  final drivePrefix = driveMatch?.group(1);
  if (drivePrefix != null && drivePrefix.isNotEmpty) {
    return '$drivePrefix\\${driveMatch!.group(2) ?? ''}';
  }

  final uncMatch = _windowsNamespaceUncPattern.firstMatch(value);
  final uncServer = uncMatch?.group(1);
  final uncShare = uncMatch?.group(2);
  if (uncServer != null &&
      uncServer.isNotEmpty &&
      uncShare != null &&
      uncShare.isNotEmpty) {
    final uncRest = uncMatch!.group(3);
    return '\\\\$uncServer\\$uncShare${uncRest != null ? '\\$uncRest' : ''}';
  }

  return value;
}

String _stripTrailingSeparators(
  String value,
  String root,
  bool compareAsWindows,
) {
  var result = value;
  while (result.length > root.length &&
      _isSeparator(result[result.length - 1], compareAsWindows)) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

bool _isSeparator(String character, bool compareAsWindows) =>
    character == '/' || (compareAsWindows && character == r'\');

// ---------------------------------------------------------------------------
// utils/git-rev-parse-path.ts
// ---------------------------------------------------------------------------

/// The single path `git rev-parse` printed on [stdout], or `null`.
///
/// Rejects empty output, multi-line output, and anything starting with `--`,
/// because those are the shapes git uses to say "no answer" rather than to
/// report a path.
String? parseGitRevParsePath(String stdout) {
  final trimmed = stdout.trim();
  if (trimmed.isEmpty) return null;

  final lines = trimmed.split(RegExp(r'\r?\n'));
  if (lines.length != 1) return null;

  final path = lines[0].trim();
  if (path.isEmpty || path.startsWith('--')) return null;

  return path;
}

/// [parseGitRevParsePath] resolved against [cwd].
///
/// git prints a relative path for some `rev-parse` queries, so the answer is
/// only meaningful once anchored to the directory the command ran in.
String? resolveGitRevParsePath(String cwd, String stdout) {
  final parsed = parseGitRevParsePath(stdout);
  return parsed == null
      ? null
      : _resolvePath(p.join(_resolvePath(cwd), parsed));
}

/// Node's `path.resolve` for a single argument: absolute, normalized, and with
/// separators unified for the host platform.
String _resolvePath(String value) => p.normalize(p.absolute(value));

// ---------------------------------------------------------------------------
// workspace-registry-model.ts (the three derive* helpers the classifier needs)
// ---------------------------------------------------------------------------

/// The git facts about one directory that project/workspace classification
/// needs.
///
/// Port of upstream's `ProjectCheckoutLitePayload`. This package had no Dart
/// analogue — the app package's `ProjectCheckoutLite` is a sealed hierarchy
/// that lives on the far side of the wire — so the flat payload shape is
/// reproduced here, `null`able fields and all, because the classifier keys off
/// exactly those nulls.
final class ProjectCheckoutLite {
  /// Creates a checkout snapshot for [cwd].
  const ProjectCheckoutLite({
    required this.cwd,
    required this.isGit,
    this.currentBranch,
    this.remoteUrl,
    this.worktreeRoot,
    this.isPaseoOwnedWorktree = false,
    this.mainRepoRoot,
  });

  /// The directory this snapshot describes.
  final String cwd;

  /// Whether [cwd] is inside a git checkout at all.
  final bool isGit;

  /// Checked-out branch, or `null` on a detached HEAD / non-git directory.
  final String? currentBranch;

  /// `origin`'s URL, used to group sibling checkouts into one project.
  final String? remoteUrl;

  /// Root of the worktree containing [cwd].
  final String? worktreeRoot;

  /// Whether Paseo created this worktree (as opposed to the user).
  final bool isPaseoOwnedWorktree;

  /// Root of the main checkout when [cwd] is a linked worktree; `null` when
  /// [cwd] *is* the main checkout.
  final String? mainRepoRoot;

  /// This snapshot re-pointed at [cwd], mirroring upstream's
  /// `{ ...input.checkout, cwd }` spread.
  ProjectCheckoutLite withCwd(String cwd) => ProjectCheckoutLite(
    cwd: cwd,
    isGit: isGit,
    currentBranch: currentBranch,
    remoteUrl: remoteUrl,
    worktreeRoot: worktreeRoot,
    isPaseoOwnedWorktree: isPaseoOwnedWorktree,
    mainRepoRoot: mainRepoRoot,
  );
}

/// Whether a checkout becomes a git-backed project or a bare directory.
PersistedProjectKind deriveProjectKind(ProjectCheckoutLite checkout) =>
    checkout.isGit ? PersistedProjectKind.git : PersistedProjectKind.nonGit;

/// Which flavor of workspace a checkout is.
///
/// Deviation: upstream's `checkout.mainRepoRoot ? "worktree" : "local_checkout"`
/// is JS truthiness, so an **empty-string** `mainRepoRoot` reads as "no main
/// repo" and yields `local_checkout`. The emptiness check keeps that.
PersistedWorkspaceKind deriveWorkspaceKind(ProjectCheckoutLite checkout) {
  if (!checkout.isGit) return PersistedWorkspaceKind.directory;
  final mainRepoRoot = checkout.mainRepoRoot;
  return (mainRepoRoot != null && mainRepoRoot.isNotEmpty)
      ? PersistedWorkspaceKind.worktree
      : PersistedWorkspaceKind.localCheckout;
}

/// The label a workspace is first given: its branch, or its directory name.
///
/// A detached HEAD reports the literal branch `HEAD`, which would be a useless
/// label, so it falls through to the basename. The basename is computed by
/// splitting on both separators rather than with `p.basename`, because the
/// input can be a Windows path while the daemon runs on POSIX.
String deriveWorkspaceDisplayName({
  required String cwd,
  required ProjectCheckoutLite checkout,
}) {
  final branch = checkout.currentBranch?.trim();
  // Upstream's `if (branch && ...)` also rejects the empty string.
  if (branch != null && branch.isNotEmpty && branch.toUpperCase() != 'HEAD') {
    return branch;
  }

  final segments = cwd
      .replaceAll(r'\', '/')
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  // Upstream is `segments[segments.length - 1] ?? input.cwd`: an empty segment
  // list (`cwd` of `/` or `""`) falls back to the raw cwd.
  return segments.isEmpty ? cwd : segments.last;
}

// ---------------------------------------------------------------------------
// workspace-registry-bootstrap-legacy.ts
// ---------------------------------------------------------------------------

/// Everything the bootstrap needs to know about one legacy agent directory.
///
/// COMPAT(legacyRegistryBootstrap): upstream added this on 2026-07-15 and plans
/// to remove it after 2027-01-15, once every supported install has materialized
/// its registry files. It exists only so pre-registry agent records can be
/// grouped into projects and workspaces after the fact.
final class DirectoryProjectMembership {
  /// Creates a membership. Prefer [classifyDirectoryForProjectMembership].
  const DirectoryProjectMembership({
    required this.cwd,
    required this.checkout,
    required this.workspaceDirectoryKey,
    required this.workspaceKind,
    required this.workspaceDisplayName,
    required this.projectKey,
    required this.projectName,
    required this.projectRootPath,
    required this.projectKind,
  });

  /// The classified directory, resolved to an absolute normalized path.
  final String cwd;

  /// [checkout] re-pointed at [cwd].
  final ProjectCheckoutLite checkout;

  /// The identity two agent records must share to land in the same workspace.
  ///
  /// This is the *worktree root*, not the cwd, so two agents started in
  /// different subdirectories of one worktree collapse into one workspace.
  final String workspaceDirectoryKey;

  /// Flavor of the workspace that will be materialized.
  final PersistedWorkspaceKind workspaceKind;

  /// Label for the materialized workspace.
  final String workspaceDisplayName;

  /// The identity two workspaces must share to land in the same project —
  /// `remote:<host>/<path>` when a remote is known, otherwise a path.
  final String projectKey;

  /// Human-readable name derived from [projectKey].
  final String projectName;

  /// Root path recorded on the materialized project.
  final String projectRootPath;

  /// Flavor of the materialized project.
  final PersistedProjectKind projectKind;
}

/// Classifies one directory into the project and workspace it should belong to.
///
/// Pure: it derives everything from [cwd] and [checkout] and never consults the
/// registries, which is what lets the bootstrap group every legacy record
/// before it writes anything.
DirectoryProjectMembership classifyDirectoryForProjectMembership({
  required String cwd,
  required ProjectCheckoutLite checkout,
}) {
  final resolvedCwd = _resolvePath(cwd);
  final resolvedCheckout = checkout.withCwd(resolvedCwd);
  final projectKey = _deriveProjectGroupingKey(
    // `??` and not `||`: an empty-string worktree root IS used here upstream.
    cwd: resolvedCheckout.worktreeRoot ?? resolvedCwd,
    remoteUrl: resolvedCheckout.remoteUrl,
    mainRepoRoot: resolvedCheckout.mainRepoRoot,
  );

  return DirectoryProjectMembership(
    cwd: resolvedCwd,
    checkout: resolvedCheckout,
    workspaceDirectoryKey: _deriveWorkspaceDirectoryKey(
      resolvedCwd,
      resolvedCheckout,
    ),
    workspaceKind: deriveWorkspaceKind(resolvedCheckout),
    workspaceDisplayName: deriveWorkspaceDisplayName(
      cwd: resolvedCwd,
      checkout: resolvedCheckout,
    ),
    projectKey: projectKey,
    projectName: _deriveProjectGroupingName(projectKey),
    projectRootPath: _deriveProjectRootPath(resolvedCwd, resolvedCheckout),
    projectKind: deriveProjectKind(resolvedCheckout),
  );
}

String _deriveWorkspaceDirectoryKey(String cwd, ProjectCheckoutLite checkout) {
  final rawWorktreeRoot = checkout.worktreeRoot;
  // Upstream's `checkout.worktreeRoot ? ... : null` is truthiness, so an empty
  // string skips the parse entirely rather than being fed to it.
  final worktreeRoot = (rawWorktreeRoot != null && rawWorktreeRoot.isNotEmpty)
      ? parseGitRevParsePath(rawWorktreeRoot)
      : null;
  return worktreeRoot ?? _resolvePath(cwd);
}

/// `remote:<lowercased host>/<owner>/<repo>` for a recognizable remote.
///
/// Handles both scp-like (`git@host:owner/repo.git`) and URL remotes. A remote
/// whose path has no `/` is rejected, because a single segment cannot identify
/// a repository and would collapse unrelated projects together.
String? _deriveRemoteProjectKey(String? remoteUrl) {
  if (remoteUrl == null || remoteUrl.isEmpty) return null;

  final trimmed = remoteUrl.trim();
  if (trimmed.isEmpty) return null;

  String? host;
  String? remotePath;
  final scpLike = RegExp(r'^[^@]+@([^:]+):(.+)$').firstMatch(trimmed);
  if (scpLike != null) {
    host = scpLike.group(1);
    remotePath = scpLike.group(2);
  } else if (trimmed.contains('://')) {
    // Deviation: upstream constructs `new URL(trimmed)` and returns null when
    // the constructor throws. `Uri.tryParse` is the closest analogue — it
    // returns null for input the URL parser also rejects — but it is more
    // permissive about hosts, so the emptiness checks below carry the weight
    // that `parsed.hostname || null` carries upstream.
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null) return null;
    host = parsed.host.isEmpty ? null : parsed.host;
    remotePath = parsed.path.isEmpty
        ? null
        : parsed.path.replaceFirst(RegExp(r'^/+'), '');
  }

  if (host == null || host.isEmpty) return null;
  if (remotePath == null || remotePath.isEmpty) return null;

  var cleanedPath = remotePath
      .trim()
      .replaceFirst(RegExp(r'^/+'), '')
      .replaceFirst(RegExp(r'/+$'), '');
  if (cleanedPath.endsWith('.git')) {
    cleanedPath = cleanedPath.substring(0, cleanedPath.length - 4);
  }
  if (!cleanedPath.contains('/')) return null;

  return 'remote:${host.toLowerCase()}/$cleanedPath';
}

/// The remote identity when there is one, else the main repo root, else the
/// directory itself.
///
/// The remote wins so that a clone and its worktrees group together even though
/// they live at unrelated paths.
String _deriveProjectGroupingKey({
  required String cwd,
  required String? remoteUrl,
  required String? mainRepoRoot,
}) {
  final remoteKey = _deriveRemoteProjectKey(remoteUrl);
  if (remoteKey != null) return remoteKey;

  // Upstream's `mainRepoRoot || options.cwd` also falls through on `""`.
  final trimmedMainRepoRoot = mainRepoRoot?.trim();
  return (trimmedMainRepoRoot != null && trimmedMainRepoRoot.isNotEmpty)
      ? trimmedMainRepoRoot
      : cwd;
}

/// `owner/repo` for a remote key, the last path segment otherwise.
String _deriveProjectGroupingName(String projectKey) {
  const remotePrefix = 'remote:';
  if (projectKey.startsWith(remotePrefix)) {
    // Drops the host segment, then keeps the last two path segments.
    final pathSegments = projectKey
        .substring(remotePrefix.length)
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .skip(1)
        .toList(growable: false);
    if (pathSegments.length >= 2) {
      return pathSegments.sublist(pathSegments.length - 2).join('/');
    }
    if (pathSegments.length == 1) return pathSegments[0];
    return projectKey;
  }

  final segments = projectKey
      .split(RegExp(r'[\\/]'))
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  // Upstream's `segments[segments.length - 1] || projectKey`.
  return segments.isEmpty ? projectKey : segments.last;
}

/// A git worktree's project is rooted at the main checkout, not the worktree.
String _deriveProjectRootPath(String cwd, ProjectCheckoutLite checkout) {
  final mainRepoRoot = checkout.mainRepoRoot;
  return (checkout.isGit && mainRepoRoot != null && mainRepoRoot.isNotEmpty)
      ? mainRepoRoot
      : cwd;
}

// ---------------------------------------------------------------------------
// workspace-registry-bootstrap.ts
// ---------------------------------------------------------------------------

/// Asks git what it knows about [cwd].
///
/// Injected rather than taken as a `WorkspaceGitService`, because the bootstrap
/// only ever calls one method on it and the suite must be able to make that
/// call throw.
typedef WorkspaceCheckoutProbe =
    Future<ProjectCheckoutLite> Function(String cwd);

/// Structured log sink, standing in for the pino logger upstream injects.
typedef RegistryBootstrapLogger =
    void Function(String message, Map<String, Object?> fields);

/// What [bootstrapWorkspaceRegistries] did.
///
/// Deviation: upstream returns `Promise<void>` and these counts only ever reach
/// the log line. Returning them makes the outcome assertable without forcing a
/// logger on every caller.
final class RegistryBootstrapSummary {
  /// Creates a summary.
  const RegistryBootstrapSummary({
    required this.materializedProjects,
    required this.materializedWorkspaces,
    required this.skippedBecauseRegistriesExisted,
    required this.backfilledAgents,
  });

  /// Distinct projects the migration wrote.
  final int materializedProjects;

  /// Distinct workspaces the migration wrote.
  final int materializedWorkspaces;

  /// True when both registry files already existed, so nothing was
  /// materialized and only the `workspaceId` backfill ran.
  final bool skippedBecauseRegistriesExisted;

  /// Legacy agent records that gained a `workspaceId`.
  final int backfilledAgents;
}

/// Materializes `projects.json` and `workspaces.json` from pre-registry agent
/// records, then stamps `workspaceId` onto every legacy agent.
///
/// Runs once at startup. It is a no-op (beyond the backfill) as soon as *both*
/// registry files exist, which is what makes it safe to call unconditionally.
/// The asymmetric guard matters: if only the workspaces file exists, the
/// migration reruns but reuses the workspace ids already on disk, so agents
/// never lose their owner.
///
/// A legacy agent can outlive its working directory, so a record whose cwd is
/// missing — or is a file — is dropped *before* git is consulted. Reconciliation
/// treats a missing directory as absent and bootstrap must agree, or the first
/// materialized record would disagree with every later one. A git failure for a
/// directory that *does* exist is propagated: that is a real fault, not an
/// absent workspace.
///
/// [getCheckout] is the git probe, [clock] supplies the fallback timestamp,
/// [workspaceIdFactory] the generated ids, and [homeDirectory] overrides the
/// ambient home used by the backfill's ownership resolution. Leave the last
/// three unset outside tests.
Future<RegistryBootstrapSummary> bootstrapWorkspaceRegistries({
  required String paseoHome,
  required AgentStore agentStore,
  required FileBackedProjectRegistry projectRegistry,
  required FileBackedWorkspaceRegistry workspaceRegistry,
  required WorkspaceCheckoutProbe getCheckout,
  DateTime Function()? clock,
  String Function()? workspaceIdFactory,
  RegistryBootstrapLogger? log,
  String? homeDirectory,
}) async {
  final newWorkspaceId = workspaceIdFactory ?? generateWorkspaceId;
  final now = clock ?? DateTime.now;

  final existence = await Future.wait([
    projectRegistry.existsOnDisk(),
    workspaceRegistry.existsOnDisk(),
  ]);
  final projectsExists = existence[0];
  final workspacesExists = existence[1];

  await Future.wait([
    projectRegistry.initialize(),
    workspaceRegistry.initialize(),
  ]);

  Future<int> backfill() => backfillWorkspaceIdForLegacyAgents(
    agentStore: agentStore,
    workspaceRegistry: workspaceRegistry,
    homeDirectory: homeDirectory,
    log: log == null ? null : (message) => log(message, const {}),
  );

  if (projectsExists && workspacesExists) {
    return RegistryBootstrapSummary(
      materializedProjects: 0,
      materializedWorkspaces: 0,
      skippedBecauseRegistriesExisted: true,
      backfilledAgents: await backfill(),
    );
  }

  // Deviation: upstream keys this by `path.resolve(workspace.cwd)` — no case
  // folding, even on Windows. Reproduced rather than routed through the
  // registry's case-folding `areEquivalentPaths`, because changing it would
  // silently re-own workspaces during a one-shot migration.
  //
  // A later duplicate wins, matching `new Map(entries)`.
  final existingWorkspaceIdsByCwd = <String, String>{
    for (final workspace in await workspaceRegistry.list())
      _resolvePath(workspace.cwd): workspace.workspaceId,
  };

  final records = await agentStore.loadAll();
  final activeRecords = records
      .where(
        (record) =>
            !_isArchivedAgent(record) &&
            _isExistingDirectory(record.summary.cwd),
      )
      .toList(growable: false);

  final placements = await Future.wait(
    activeRecords.map((record) async {
      final normalizedCwd = _resolvePath(record.summary.cwd);
      final checkout = await getCheckout(normalizedCwd);
      final membership = classifyDirectoryForProjectMembership(
        cwd: normalizedCwd,
        checkout: checkout,
      );
      return (record: record, membership: membership);
    }),
  );

  // Insertion-ordered, like the JS `Map` upstream builds: the first record to
  // claim a directory key also fixes that workspace's membership facts.
  final recordsByDirectoryKey = <String, _DirectoryGroup>{};
  for (final placement in placements) {
    final group = recordsByDirectoryKey.putIfAbsent(
      placement.membership.workspaceDirectoryKey,
      () => _DirectoryGroup(placement.membership),
    );
    group.records.add(placement.record);
  }

  final projectRanges = <String, _IsoDateRange>{};
  final workspaceUpsertInputs = <_WorkspaceUpsertInput>[];

  for (final group in recordsByDirectoryKey.values) {
    final membership = group.membership;
    final workspaceCwd = membership.checkout.cwd;
    String? workspaceCreatedAt;
    String? workspaceUpdatedAt;
    for (final record in group.records) {
      workspaceCreatedAt = _minIsoDate(
        workspaceCreatedAt,
        _resolveAgentCreatedAt(record.summary),
      );
      workspaceUpdatedAt = _maxIsoDate(
        workspaceUpdatedAt,
        _resolveAgentUpdatedAt(record.summary),
      );
    }

    // Unreachable while a group has at least one record — kept because
    // upstream spells it out and a future empty group must not write `null`.
    final createdAt = workspaceCreatedAt ?? _isoMillis(now());
    final updatedAt = workspaceUpdatedAt ?? createdAt;

    final projectRange =
        projectRanges[membership.projectKey] ?? const _IsoDateRange(null, null);
    projectRanges[membership.projectKey] = _IsoDateRange(
      _minIsoDate(projectRange.createdAt, createdAt),
      _maxIsoDate(projectRange.updatedAt, updatedAt),
    );

    workspaceUpsertInputs.add(
      _WorkspaceUpsertInput(
        workspaceId:
            existingWorkspaceIdsByCwd[workspaceCwd] ?? newWorkspaceId(),
        membership: membership,
        workspaceCwd: workspaceCwd,
        createdAt: createdAt,
        updatedAt: updatedAt,
      ),
    );
  }

  await Future.wait([
    for (final input in workspaceUpsertInputs) ...[
      workspaceRegistry.upsert(
        createPersistedWorkspaceRecord(
          workspaceId: input.workspaceId,
          projectId: input.membership.projectKey,
          cwd: input.workspaceCwd,
          kind: input.membership.workspaceKind,
          displayName: input.membership.workspaceDisplayName,
          createdAt: input.createdAt,
          updatedAt: input.updatedAt,
        ),
      ),
      projectRegistry.upsert(
        createPersistedProjectRecord(
          projectId: input.membership.projectKey,
          rootPath: input.membership.projectRootPath,
          kind: input.membership.projectKind,
          displayName: input.membership.projectName,
          createdAt:
              projectRanges[input.membership.projectKey]?.createdAt ??
              input.createdAt,
          updatedAt:
              projectRanges[input.membership.projectKey]?.updatedAt ??
              input.updatedAt,
        ),
      ),
    ],
  ]);

  final backfilledAgents = await backfill();

  log?.call('Workspace registries bootstrapped from existing agent storage', {
    'projectsFile': p.join(paseoHome, 'projects', 'projects.json'),
    'workspacesFile': p.join(paseoHome, 'projects', 'workspaces.json'),
    'materializedProjects': projectRanges.length,
    'materializedWorkspaces': recordsByDirectoryKey.length,
  });

  return RegistryBootstrapSummary(
    materializedProjects: projectRanges.length,
    materializedWorkspaces: recordsByDirectoryKey.length,
    skippedBecauseRegistriesExisted: false,
    backfilledAgents: backfilledAgents,
  );
}

final class _DirectoryGroup {
  _DirectoryGroup(this.membership);

  final DirectoryProjectMembership membership;
  final List<PersistedAgent> records = [];
}

final class _IsoDateRange {
  const _IsoDateRange(this.createdAt, this.updatedAt);

  final String? createdAt;
  final String? updatedAt;
}

final class _WorkspaceUpsertInput {
  const _WorkspaceUpsertInput({
    required this.workspaceId,
    required this.membership,
    required this.workspaceCwd,
    required this.createdAt,
    required this.updatedAt,
  });

  final String workspaceId;
  final DirectoryProjectMembership membership;
  final String workspaceCwd;
  final String createdAt;
  final String updatedAt;
}

/// Deviation: upstream keys "archived" off `record.archivedAt != null`. This
/// repo carries both a persisted `archived` flag and `summary.archivedAt`, kept
/// in sync by the agent manager, so either signal counts — the same rule
/// `backfillWorkspaceIdForLegacyAgents` already uses.
bool _isArchivedAgent(PersistedAgent record) =>
    record.archived || record.summary.archivedAt != null;

/// A missing path and a path that is a file both read as "no directory".
///
/// `FileSystemEntity.typeSync` reports `notFound` instead of throwing, which is
/// the same observable answer as upstream's `try { statSync(...) } catch`.
bool _isExistingDirectory(String cwd) {
  try {
    return FileSystemEntity.typeSync(cwd) == FileSystemEntityType.directory;
  } on Object {
    return false;
  }
}

/// Upstream `record.createdAt || record.updatedAt || new Date(0).toISOString()`.
///
/// Deviation: this repo stores creation as a non-nullable `createdAtMs`, so the
/// two fallbacks are unreachable. They are kept spelled out so the chain stays
/// diffable against upstream.
String _resolveAgentCreatedAt(AgentSummary summary) {
  final createdAt = _isoMillis(
    DateTime.fromMillisecondsSinceEpoch(summary.createdAtMs, isUtc: true),
  );
  if (createdAt.isNotEmpty) return createdAt;
  final updatedAt = summary.updatedAt;
  if (updatedAt != null && updatedAt.isNotEmpty) return updatedAt;
  return _epochIso;
}

/// Upstream
/// `record.lastActivityAt || record.updatedAt || record.createdAt || epoch0`.
///
/// Deviation: this repo's [AgentSummary] has no `lastActivityAt` — activity is
/// tracked on the live agent, not on the persisted summary — so the chain
/// starts at `updatedAt`. For a legacy record that never moved after creation
/// the two agree; for one that did, the workspace's `updatedAt` is derived from
/// the last *persisted* update instead of the last observed activity.
String _resolveAgentUpdatedAt(AgentSummary summary) {
  final updatedAt = summary.updatedAt;
  if (updatedAt != null && updatedAt.isNotEmpty) return updatedAt;
  final createdAt = _isoMillis(
    DateTime.fromMillisecondsSinceEpoch(summary.createdAtMs, isUtc: true),
  );
  if (createdAt.isNotEmpty) return createdAt;
  return _epochIso;
}

const String _epochIso = '1970-01-01T00:00:00.000Z';

/// Upstream `Date.parse(left) <= Date.parse(right) ? left : right`, guarded by
/// `if (!left) return right`.
///
/// Deviation: `Date.parse` yields `NaN` for an unparseable instant and every
/// comparison against `NaN` is false, so upstream silently prefers `right`.
/// [DateTime.tryParse] returning `null` reproduces exactly that.
String? _minIsoDate(String? left, String? right) {
  if (left == null || left.isEmpty) return right;
  if (right == null || right.isEmpty) return left;
  final parsedLeft = DateTime.tryParse(left);
  final parsedRight = DateTime.tryParse(right);
  if (parsedLeft == null || parsedRight == null) return right;
  return !parsedLeft.isAfter(parsedRight) ? left : right;
}

/// Mirror of [_minIsoDate] for the newest instant.
String? _maxIsoDate(String? left, String? right) {
  if (left == null || left.isEmpty) return right;
  if (right == null || right.isEmpty) return left;
  final parsedLeft = DateTime.tryParse(left);
  final parsedRight = DateTime.tryParse(right);
  if (parsedLeft == null || parsedRight == null) return right;
  return !parsedLeft.isBefore(parsedRight) ? left : right;
}

/// `new Date().toISOString()`: UTC with exactly three fractional digits.
///
/// Dart's [DateTime.toIso8601String] emits six digits when the instant carries
/// microseconds, which would break byte-comparison against timestamps written
/// by upstream, so the instant is truncated to milliseconds first.
String _isoMillis(DateTime instant) => DateTime.fromMillisecondsSinceEpoch(
  instant.millisecondsSinceEpoch,
  isUtc: true,
).toIso8601String();

// ---------------------------------------------------------------------------
// tasks/task-graph.ts (the two predicates task-store.ts needs)
// ---------------------------------------------------------------------------

/// Whether [task] can be picked up right now.
///
/// Open, every dependency done, and every child done. The child rule is what
/// makes a parent task behave like an epic: it only becomes ready once the work
/// under it is finished.
///
/// Note this is the *unscoped* child check, unlike
/// [isTaskExecutableInOrder] — `getReady` reports what the user could actually
/// start, and a child outside the requested scope is still real work.
bool isReadyTask(TaskGraph graph, Task task) =>
    task.status == TaskStatus.open &&
    _areTaskDepsDone(graph, task, graph.doneTaskIds) &&
    _areTaskChildrenDone(graph, task.id, graph.doneTaskIds);

/// Whether [task] is waiting on a dependency that is not done.
///
/// Draft and done tasks are never blocked (they are not waiting on anything),
/// and a task with no dependencies at all is never blocked — a parent held up
/// only by its children is "not ready", not "blocked".
bool isBlockedTask(TaskGraph graph, Task task) =>
    task.status != TaskStatus.draft &&
    task.status != TaskStatus.done &&
    task.deps.isNotEmpty &&
    !_areTaskDepsDone(graph, task, graph.doneTaskIds);

// Duplicated from `services/paseo_quota_and_tasks.dart`, where the same two
// helpers back `isTaskExecutableInOrder` but are library-private. They are
// four-line pure predicates over the public [TaskGraph] fields; re-deriving
// them here is cheaper than widening that library's API surface.
bool _areTaskDepsDone(TaskGraph graph, Task task, Set<String> completed) =>
    task.deps.every(
      (depId) => graph.taskMap.containsKey(depId) && completed.contains(depId),
    );

bool _areTaskChildrenDone(
  TaskGraph graph,
  String taskId,
  Set<String> completed,
) => (graph.childrenMap[taskId] ?? const <Task>[]).every(
  (child) => completed.contains(child.id),
);

// ---------------------------------------------------------------------------
// tasks/task-document.ts
// ---------------------------------------------------------------------------

/// Renders [task] as the markdown document the store persists.
///
/// The frontmatter carries the scheduling fields and the body carries the prose,
/// so a task file stays hand-editable — which is the whole reason the store is
/// file-backed rather than a database.
String serializeTaskDocument(Task task) {
  final frontmatterLines = <String>[
    '---',
    'id: ${task.id}',
    'title: ${task.title}',
    'status: ${task.status.wireValue}',
    'deps: [${task.deps.join(', ')}]',
    'created: ${task.created}',
  ];

  // Upstream guards each of these with JS truthiness, so an empty string is
  // omitted exactly like an absent value.
  final parentId = task.parentId;
  if (parentId != null && parentId.isNotEmpty) {
    frontmatterLines.add('parentId: $parentId');
  }
  final assignee = task.assignee;
  if (assignee != null && assignee.isNotEmpty) {
    frontmatterLines.add('assignee: $assignee');
  }
  // Priority is guarded with `!== undefined`, so a priority of 0 is written.
  if (task.priority != null) {
    frontmatterLines.add('priority: ${task.priority}');
  }

  frontmatterLines.add('---');

  final buffer = StringBuffer();
  if (task.body.isNotEmpty) buffer.write('${task.body}\n');

  if (task.acceptanceCriteria.isNotEmpty) {
    buffer.write('\n## Acceptance Criteria\n\n');
    for (final criterion in task.acceptanceCriteria) {
      buffer.write('- [ ] $criterion\n');
    }
  }

  if (task.notes.isNotEmpty) {
    buffer.write('\n## Notes\n');
    for (final note in task.notes) {
      buffer.write('\n**${note.timestamp}**\n\n${note.content}\n');
    }
  }

  return '${frontmatterLines.join('\n')}\n\n$buffer';
}

final RegExp _frontmatterPattern = RegExp(r'^---\n([\s\S]*?)\n---\n');
final RegExp _depsListPattern = RegExp(r'\[(.*)\]');
final RegExp _notesSectionPattern = RegExp(r'## Notes\n([\s\S]*?)$');
final RegExp _notePattern = RegExp(
  r'\*\*(\d{4}-\d{2}-\d{2}T[\d:.Z]+)\*\*\n\n([\s\S]*?)(?=\n\*\*\d{4}|$)',
);
final RegExp _criteriaSectionPattern = RegExp(
  r'## Acceptance Criteria\n\n([\s\S]*?)(?=\n## Notes|$)',
);
final RegExp _criterionPattern = RegExp(r'- \[[ x]\] (.+)$', multiLine: true);
final RegExp _firstSectionPattern = RegExp(
  r'\n## (Acceptance Criteria|Notes)\n',
);

/// Parses a task document back into a [Task].
///
/// [clock] supplies the `created` fallback for a document that lost its
/// frontmatter timestamp; leave it unset outside tests.
///
/// Throws [FormatException] when the frontmatter block is missing, and — unlike
/// upstream — also when `status` is absent or unrecognized. Upstream casts the
/// raw string straight into its union (`getValue("status") as TaskStatus`), so a
/// corrupt file yields a `Task` carrying an impossible status that then silently
/// fails every scheduling predicate. This port has a closed enum and surfaces
/// the corruption instead of laundering it.
Task parseTaskDocument(String content, {DateTime Function()? clock}) {
  final frontmatterMatch = _frontmatterPattern.firstMatch(content);
  if (frontmatterMatch == null) {
    throw const FormatException('Invalid task file: missing frontmatter');
  }

  final frontmatter = frontmatterMatch.group(1)!;
  final fileBody = content.substring(frontmatterMatch.group(0)!.length);

  String getValue(String key) =>
      RegExp(
        '^$key: (.*)\$',
        multiLine: true,
      ).firstMatch(frontmatter)?.group(1) ??
      '';

  final depsMatch = _depsListPattern.firstMatch(getValue('deps'));
  final depsInner = depsMatch?.group(1) ?? '';
  final deps = depsInner.trim().isEmpty
      ? const <String>[]
      : depsInner
            .split(',')
            .map((dep) => dep.trim())
            .where((dep) => dep.isNotEmpty)
            .toList(growable: false);

  final notes = <TaskNote>[];
  final notesSection = _notesSectionPattern.firstMatch(fileBody);
  if (notesSection != null) {
    for (final match in _notePattern.allMatches(notesSection.group(1)!)) {
      notes.add(
        TaskNote(timestamp: match.group(1)!, content: match.group(2)!.trim()),
      );
    }
  }

  final acceptanceCriteria = <String>[];
  final criteriaSection = _criteriaSectionPattern.firstMatch(fileBody);
  if (criteriaSection != null) {
    for (final match in _criterionPattern.allMatches(
      criteriaSection.group(1)!,
    )) {
      acceptanceCriteria.add(match.group(1)!.trim());
    }
  }

  var taskBody = fileBody;
  final firstSection = _firstSectionPattern.firstMatch(fileBody);
  if (firstSection != null) {
    taskBody = fileBody.substring(0, firstSection.start).trim();
  }
  taskBody = taskBody.trim();

  final assignee = getValue('assignee');
  final parentId = getValue('parentId');
  final priorityText = getValue('priority');
  final created = getValue('created');

  return Task(
    id: getValue('id'),
    title: getValue('title'),
    status: TaskStatus.fromWire(getValue('status')),
    deps: deps,
    parentId: parentId.isEmpty ? null : parentId,
    body: taskBody,
    acceptanceCriteria: acceptanceCriteria,
    notes: notes,
    created: created.isEmpty ? _isoMillis((clock ?? DateTime.now)()) : created,
    assignee: assignee.isEmpty ? null : assignee,
    priority: priorityText.isEmpty ? null : _parseIntPrefix(priorityText),
    raw: content,
  );
}

/// JavaScript's `parseInt(value, 10)`: reads an optional sign and the leading
/// run of digits, ignoring whatever trails.
///
/// Deviation spelled out because [int.tryParse] instead rejects the whole
/// string, which would turn a frontmatter line like `priority: 3 (high)` into
/// an absent priority rather than `3`. `NaN` maps to `null`, matching the
/// `Number.isNaN` hole upstream leaves open.
int? _parseIntPrefix(String value) {
  final match = RegExp(r'^\s*([+-]?\d+)').firstMatch(value);
  return match == null ? null : int.parse(match.group(1)!);
}

/// Reads a task document from disk.
///
/// Rethrows a [PathNotFoundException] for a missing file so callers can
/// distinguish "no such task" from "corrupt task", which is what
/// [FileTaskStore.get] relies on.
Future<Task> readTaskDocument(
  String filePath, {
  DateTime Function()? clock,
}) async =>
    parseTaskDocument(await File(filePath).readAsString(), clock: clock);

/// Writes a task document atomically.
///
/// Deviation: upstream calls its shared `writeFileAtomic`. This package's only
/// atomic writer ([writePrivateFileAtomic]) also chmods to 0600, which is wrong
/// for task files — they are meant to be hand-edited — so the temp-then-rename
/// dance is repeated here without the permission tightening.
Future<void> writeTaskDocument(String filePath, Task task) async {
  final file = File(filePath);
  await file.parent.create(recursive: true);
  final temporary = File(
    '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  await temporary.writeAsString(serializeTaskDocument(task), flush: true);
  await temporary.rename(file.path);
}

// ---------------------------------------------------------------------------
// tasks/task-store.ts
// ---------------------------------------------------------------------------

/// Optional fields accepted by [TaskStore.create].
final class CreateTaskOptions {
  /// Creates a set of overrides. Every field defaults to the store's default.
  const CreateTaskOptions({
    this.deps,
    this.parentId,
    this.status,
    this.body,
    this.acceptanceCriteria,
    this.assignee,
    this.priority,
  });

  /// Task ids that must be done first.
  final List<String>? deps;

  /// Parent task id.
  final String? parentId;

  /// Initial status; defaults to [TaskStatus.open].
  final TaskStatus? status;

  /// Long-form markdown body.
  final String? body;

  /// Verification checklist.
  final List<String>? acceptanceCriteria;

  /// Agent override.
  final String? assignee;

  /// Lower sorts first.
  final int? priority;
}

const Object _unsetTaskField = Object();

/// A partial update for [TaskStore.update].
///
/// Port of upstream's `Partial<Omit<Task, "id" | "created">>`. Dart cannot
/// distinguish an omitted named argument from an explicit `null`, so the three
/// nullable fields go through a sentinel: omit them to leave them alone, pass
/// `null` to clear them. `id` and `created` are absent by construction because
/// upstream's `Omit` forbids changing them.
final class TaskChanges {
  /// Creates a change set.
  const TaskChanges({
    this.title,
    this.status,
    this.deps,
    Object? parentId = _unsetTaskField,
    this.body,
    this.acceptanceCriteria,
    this.notes,
    Object? assignee = _unsetTaskField,
    Object? priority = _unsetTaskField,
    this.raw,
  }) : _parentId = parentId,
       _assignee = assignee,
       _priority = priority;

  /// New title, or `null` to leave it alone.
  final String? title;

  /// New status, or `null` to leave it alone.
  final TaskStatus? status;

  /// Replacement dependency list, or `null` to leave it alone.
  final List<String>? deps;

  /// Replacement body, or `null` to leave it alone.
  final String? body;

  /// Replacement checklist, or `null` to leave it alone.
  final List<String>? acceptanceCriteria;

  /// Replacement notes, or `null` to leave them alone.
  final List<TaskNote>? notes;

  /// Replacement raw document, or `null` to leave it alone.
  final String? raw;

  final Object? _parentId;
  final Object? _assignee;
  final Object? _priority;

  Task _applyTo(Task task) => Task(
    id: task.id,
    title: title ?? task.title,
    status: status ?? task.status,
    created: task.created,
    deps: deps ?? task.deps,
    parentId: identical(_parentId, _unsetTaskField)
        ? task.parentId
        : _parentId as String?,
    body: body ?? task.body,
    acceptanceCriteria: acceptanceCriteria ?? task.acceptanceCriteria,
    notes: notes ?? task.notes,
    assignee: identical(_assignee, _unsetTaskField)
        ? task.assignee
        : _assignee as String?,
    priority: identical(_priority, _unsetTaskField)
        ? task.priority
        : _priority as int?,
    raw: raw ?? task.raw,
  );
}

/// The task API the rest of the daemon codes against.
///
/// Extends [TaskGraphStore] (the read slice `execution-order.ts` already
/// depends on) rather than redeclaring `list`/`get`/`getDescendants`, so the
/// scheduling code and the store cannot drift apart.
abstract interface class TaskStore implements TaskGraphStore {
  /// Every dependency reachable from [id], transitively, without duplicates.
  Future<List<Task>> getDepTree(String id);

  /// The parent chain from the immediate parent up to the root.
  Future<List<Task>> getAncestors(String id);

  /// Direct children of [id], in execution order.
  Future<List<Task>> getChildren(String id);

  /// Tasks that can be started right now, optionally scoped to a subtree.
  Future<List<Task>> getReady([String? scopeId]);

  /// Tasks waiting on an unfinished dependency, optionally scoped.
  Future<List<Task>> getBlocked([String? scopeId]);

  /// Completed tasks, newest first, optionally scoped.
  Future<List<Task>> getClosed([String? scopeId]);

  /// Creates a task titled [title].
  Future<Task> create(String title, [CreateTaskOptions? options]);

  /// Applies [changes] to the task [id] and returns the updated task.
  Future<Task> update(String id, TaskChanges changes);

  /// Deletes the task [id].
  Future<void> delete(String id);

  /// Adds [depId] as a dependency of [id], ignoring duplicates.
  Future<void> addDep(String id, String depId);

  /// Removes [depId] from [id]'s dependencies, ignoring unknown ids.
  Future<void> removeDep(String id, String depId);

  /// Reparents [id] under [parentId], or detaches it when [parentId] is null.
  Future<void> setParent(String id, String? parentId);

  /// Appends a timestamped note to [id].
  Future<void> addNote(String id, String content);

  /// Moves [id] to [TaskStatus.open] from any status.
  Future<void> open(String id);

  /// Moves [id] from [TaskStatus.open] to [TaskStatus.inProgress].
  Future<void> start(String id);

  /// Moves [id] to [TaskStatus.done] from any status.
  Future<void> close(String id);

  /// Moves [id] to [TaskStatus.failed] from any status.
  Future<void> fail(String id);

  /// Appends [criterion] to [id]'s checklist.
  Future<void> addAcceptanceCriteria(String id, String criterion);
}

/// A [TaskStore] backed by one markdown file per task in a single directory.
///
/// There is no in-memory index: every query re-reads the directory. That is
/// deliberate upstream — the files are the source of truth and a human or
/// another process may have edited them between calls.
///
/// [clock] supplies `created`/note timestamps and [idFactory] the task ids;
/// leave both unset outside tests.
final class FileTaskStore implements TaskStore {
  /// Creates a store over [dir], which is created on demand.
  FileTaskStore(
    this.dir, {
    DateTime Function()? clock,
    String Function()? idFactory,
  }) : _clock = clock ?? DateTime.now,
       _idFactory = idFactory ?? _generateTaskId;

  /// Directory holding `<id>.md` documents.
  final String dir;
  final DateTime Function() _clock;
  final String Function() _idFactory;

  String _taskPath(String id) => p.join(dir, '$id.md');

  Future<void> _ensureDir() => Directory(dir).create(recursive: true);

  Future<Task?> _readTask(String id) async {
    try {
      return await readTaskDocument(_taskPath(id), clock: _clock);
    } on PathNotFoundException {
      // Upstream narrows on `error.code === "ENOENT"` and rethrows everything
      // else; a corrupt document still surfaces as a FormatException.
      return null;
    }
  }

  Future<void> _writeTask(Task task) async {
    await _ensureDir();
    await writeTaskDocument(_taskPath(task.id), task);
  }

  @override
  Future<List<Task>> list() async {
    await _ensureDir();
    final List<String> ids;
    try {
      ids = Directory(dir)
          .listSync()
          .whereType<File>()
          .map((entity) => p.basename(entity.path))
          .where((name) => name.endsWith('.md'))
          .map((name) => name.substring(0, name.length - 3))
          .toList(growable: false);
    } on PathNotFoundException {
      return const [];
    }
    final loaded = await Future.wait(ids.map(_readTask));
    final tasks = loaded.whereType<Task>().toList();
    // Oldest first, for a stable ordering callers can rely on.
    return _stableSorted(tasks, (a, b) => a.created.compareTo(b.created));
  }

  @override
  Future<Task?> get(String id) => _readTask(id);

  @override
  Future<List<Task>> getDepTree(String id) async {
    final root = await get(id);
    if (root == null) throw StateError('Task not found: $id');

    final visited = <String>{};
    final result = <Task>[];

    Future<void> traverse(String taskId) async {
      if (visited.contains(taskId)) return;
      visited.add(taskId);

      final task = await get(taskId);
      if (task == null) return;

      for (final depId in task.deps) {
        if (visited.contains(depId)) continue;
        final dep = await get(depId);
        if (dep != null) {
          result.add(dep);
          await traverse(depId);
        }
      }
    }

    await traverse(id);
    return result;
  }

  @override
  Future<List<Task>> getAncestors(String id) async {
    final task = await get(id);
    if (task == null) throw StateError('Task not found: $id');

    final ancestors = <Task>[];
    var currentId = task.parentId;
    while (currentId != null && currentId.isNotEmpty) {
      final parent = await get(currentId);
      if (parent == null) break;
      ancestors.add(parent);
      currentId = parent.parentId;
    }
    return ancestors;
  }

  @override
  Future<List<Task>> getChildren(String id) async {
    final allTasks = await list();
    return _stableSorted(
      allTasks.where((task) => task.parentId == id).toList(),
      sortByPriorityThenCreated,
    );
  }

  @override
  Future<List<Task>> getDescendants(String id) async {
    final result = <Task>[];
    Future<void> traverse(String parentId) async {
      for (final child in await getChildren(parentId)) {
        result.add(child);
        await traverse(child.id);
      }
    }

    await traverse(id);
    return result;
  }

  @override
  Future<List<Task>> getReady([String? scopeId]) async {
    final graph = await loadScopedTaskGraph(this, scopeId);
    return _stableSorted(
      graph.candidates.where((task) => isReadyTask(graph, task)).toList(),
      sortByPriorityThenCreated,
    );
  }

  @override
  Future<List<Task>> getBlocked([String? scopeId]) async {
    final graph = await loadScopedTaskGraph(this, scopeId);
    return graph.candidates
        .where((task) => isBlockedTask(graph, task))
        .toList(growable: false);
  }

  @override
  Future<List<Task>> getClosed([String? scopeId]) async {
    final graph = await loadScopedTaskGraph(this, scopeId);
    return _stableSorted(
      graph.candidates.where((task) => task.status == TaskStatus.done).toList(),
      // Newest first.
      (a, b) => b.created.compareTo(a.created),
    );
  }

  @override
  Future<Task> create(String title, [CreateTaskOptions? options]) async {
    final parentId = options?.parentId;
    if (parentId != null && parentId.isNotEmpty) {
      if (await get(parentId) == null) {
        throw StateError('Parent task not found: $parentId');
      }
    }

    final task = Task(
      id: _idFactory(),
      title: title,
      status: options?.status ?? TaskStatus.open,
      deps: options?.deps ?? const [],
      parentId: parentId,
      body: options?.body ?? '',
      acceptanceCriteria: options?.acceptanceCriteria ?? const [],
      notes: const [],
      created: _isoMillis(_clock()),
      assignee: options?.assignee,
      priority: options?.priority,
      // Filled in by the re-read below, exactly as upstream does.
      raw: '',
    );

    await _writeTask(task);
    return (await get(task.id))!;
  }

  @override
  Future<Task> update(String id, TaskChanges changes) async {
    final task = await get(id);
    if (task == null) throw StateError('Task not found: $id');

    // Upstream returns the spread object without re-reading, so the returned
    // task's `raw` is the pre-update document. Preserved deliberately.
    final updated = changes._applyTo(task);
    await _writeTask(updated);
    return updated;
  }

  @override
  Future<void> delete(String id) async {
    if (await get(id) == null) throw StateError('Task not found: $id');
    await File(_taskPath(id)).delete();
  }

  @override
  Future<void> addDep(String id, String depId) async {
    final task = await get(id);
    if (task == null) throw StateError('Task not found: $id');

    if (await get(depId) == null) {
      throw StateError('Dependency not found: $depId');
    }

    if (task.deps.contains(depId)) return;
    await _writeTask(TaskChanges(deps: [...task.deps, depId])._applyTo(task));
  }

  @override
  Future<void> removeDep(String id, String depId) async {
    final task = await get(id);
    if (task == null) throw StateError('Task not found: $id');

    await _writeTask(
      TaskChanges(
        deps: task.deps.where((dep) => dep != depId).toList(growable: false),
      )._applyTo(task),
    );
  }

  @override
  Future<void> setParent(String id, String? parentId) async {
    final task = await get(id);
    if (task == null) throw StateError('Task not found: $id');

    if (parentId != null && parentId.isNotEmpty) {
      if (await get(parentId) == null) {
        throw StateError('Parent task not found: $parentId');
      }
      // Order matters: upstream checks existence first, so asking a task to
      // parent itself reports the self-parent error rather than a missing one.
      if (parentId == id) throw StateError('Task cannot be its own parent');
      final ancestors = await _getAncestorsFrom(parentId);
      if (ancestors.any((ancestor) => ancestor.id == id)) {
        throw StateError('Cannot set parent: would create circular reference');
      }
    }

    await update(
      id,
      TaskChanges(
        parentId: (parentId != null && parentId.isNotEmpty) ? parentId : null,
      ),
    );
  }

  /// [getAncestors] but inclusive of [id] itself, used for the cycle check.
  Future<List<Task>> _getAncestorsFrom(String id) async {
    final ancestors = <Task>[];
    String? currentId = id;
    while (currentId != null && currentId.isNotEmpty) {
      final task = await get(currentId);
      if (task == null) break;
      ancestors.add(task);
      currentId = task.parentId;
    }
    return ancestors;
  }

  @override
  Future<void> addNote(String id, String content) async {
    final task = await get(id);
    if (task == null) throw StateError('Task not found: $id');

    await _writeTask(
      TaskChanges(
        notes: [
          ...task.notes,
          TaskNote(timestamp: _isoMillis(_clock()), content: content),
        ],
      )._applyTo(task),
    );
  }

  @override
  Future<void> open(String id) async {
    if (await get(id) == null) throw StateError('Task not found: $id');
    await update(id, const TaskChanges(status: TaskStatus.open));
  }

  @override
  Future<void> start(String id) async {
    final task = await get(id);
    if (task == null) throw StateError('Task not found: $id');
    if (task.status != TaskStatus.open) {
      throw StateError(
        'Cannot start task with status: ${task.status.wireValue}',
      );
    }
    await update(id, const TaskChanges(status: TaskStatus.inProgress));
  }

  @override
  Future<void> close(String id) async {
    if (await get(id) == null) throw StateError('Task not found: $id');
    await update(id, const TaskChanges(status: TaskStatus.done));
  }

  @override
  Future<void> fail(String id) async {
    if (await get(id) == null) throw StateError('Task not found: $id');
    await update(id, const TaskChanges(status: TaskStatus.failed));
  }

  @override
  Future<void> addAcceptanceCriteria(String id, String criterion) async {
    final task = await get(id);
    if (task == null) throw StateError('Task not found: $id');

    await _writeTask(
      TaskChanges(
        acceptanceCriteria: [...task.acceptanceCriteria, criterion],
      )._applyTo(task),
    );
  }
}

/// Upstream `randomBytes(4).toString("hex")`: eight lowercase hex characters.
String _generateTaskId() {
  final random = Random.secure();
  return List<int>.generate(
    4,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

/// Stable sort.
///
/// `Array.prototype.sort` has been stable since ES2019, and every comparator in
/// `task-store.ts` leans on it for ties (equal priority *and* equal `created`,
/// which happens routinely because the timestamps only carry milliseconds).
/// Dart's [List.sort] is not stable, so ties fall back to the original index.
List<T> _stableSorted<T>(List<T> items, int Function(T a, T b) compare) {
  final decorated = List<(int, T)>.generate(
    items.length,
    (index) => (index, items[index]),
  );
  decorated.sort((a, b) {
    final result = compare(a.$2, b.$2);
    return result != 0 ? result : a.$1.compareTo(b.$1);
  });
  return [for (final entry in decorated) entry.$2];
}

// ---------------------------------------------------------------------------
// server/agent/providers/provider-image-output.ts
// ---------------------------------------------------------------------------

/// An image a provider reported, in whichever form the provider chose.
///
/// All four carriers are optional and mutually redundant, because providers
/// disagree: some return a local path, some a URL, some inline base64, some a
/// `data:` URI in the `path` slot.
final class ProviderImageOutput {
  /// Creates an image output.
  const ProviderImageOutput({
    this.path,
    this.url,
    this.data,
    this.mimeType,
    this.altText,
  });

  /// Local filesystem path to the image.
  final String? path;

  /// Remote URL for the image.
  final String? url;

  /// Base64 payload, optionally already a `data:` URI.
  final String? data;

  /// MIME type of [data], when the provider bothered to say.
  final String? mimeType;

  /// Alt text; defaults to `Image` when blank.
  final String? altText;
}

/// A base64 image that has been written to a private temp file.
final class MaterializedProviderImage {
  /// Creates a handle to the written file.
  const MaterializedProviderImage({required this.path});

  /// Absolute path of the written file.
  final String path;
}

/// Renders as an id-less assistant message, matching upstream's
/// `{ type: "assistant_message", text }` union member.
///
/// Deviation: this repo's [AssistantMessageItem] requires an id and a
/// completeness flag, both of which are assigned by the timeline layer *after*
/// this function runs. Returning a bare text carrier keeps that assignment
/// where it belongs; [toTimelineItem] does the conversion at the boundary.
final class ProviderImageAssistantMessage {
  /// Creates a message carrying [text].
  const ProviderImageAssistantMessage(this.text);

  /// The assistant markdown.
  final String text;

  /// This message as a complete timeline item with the given [id].
  AssistantMessageItem toTimelineItem({required String id}) =>
      AssistantMessageItem(id: id, text: text, complete: true);
}

const String _providerImageAttachmentDir = 'paseo-attachments';
const String _providerImageAttachmentDirPrefix =
    '$_providerImageAttachmentDir-';

String? _materializedImageAttachmentDir;

/// Whether the cached attachments directory is still usable.
///
/// Deviation: upstream `lstatSync`s and then `chmodSync`s to 0700. Dart has no
/// `chmod`, so the mode is applied by shelling out on POSIX (the same escape
/// hatch `private_files.dart` uses) and skipped on Windows, where the temp
/// directory is already per-user.
bool _canReuseMaterializedImageAttachmentDir(String dir) {
  try {
    if (FileSystemEntity.typeSync(dir, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    _chmod(dir, '700');
    return true;
  } on Object {
    return false;
  }
}

void _chmod(String path, String mode) {
  // coverage:ignore-start
  if (!Platform.isWindows) Process.runSync('chmod', [mode, path]);
  // coverage:ignore-end
}

String _getMaterializedImageAttachmentDir() {
  final cached = _materializedImageAttachmentDir;
  if (cached != null && _canReuseMaterializedImageAttachmentDir(cached)) {
    return cached;
  }

  // A fresh directory per process (and per removal) keeps one agent's image
  // temp files out of another's, and makes the directory removable wholesale.
  final created = Directory.systemTemp
      .createTempSync(_providerImageAttachmentDirPrefix)
      .path;
  _chmod(created, '700');
  _materializedImageAttachmentDir = created;
  return created;
}

/// Resets the cached attachments directory. Test-only seam: the directory is
/// process-global upstream too, so a suite that removes it must be able to
/// forget it.
void resetMaterializedImageAttachmentDirForTest() {
  _materializedImageAttachmentDir = null;
}

String _getImageExtension(String mimeType) => switch (mimeType) {
  'image/jpeg' => 'jpg',
  'image/png' => 'png',
  'image/webp' => 'webp',
  'image/gif' => 'gif',
  'image/bmp' => 'bmp',
  'image/tiff' => 'tiff',
  _ => 'bin',
};

final RegExp _dataUriPattern = RegExp(r'^data:([^;]+);base64,(.*)$');

({String mimeType, String data}) _normalizeImageData(
  String mimeType,
  String data,
) {
  if (data.startsWith('data:')) {
    final match = _dataUriPattern.firstMatch(data);
    if (match != null) {
      return (mimeType: match.group(1)!, data: match.group(2)!);
    }
  }
  return (mimeType: mimeType, data: data);
}

/// Writes [data] into the private attachments directory and returns its path.
///
/// The filename is a SHA-256 of the decoded bytes, so re-materializing the same
/// image within a process reuses the existing file instead of leaking a fresh
/// one for every repeated image block or history replay.
///
/// Deviations:
/// * `Buffer.from(x, "base64")` never throws — it skips characters outside the
///   alphabet and tolerates missing padding. [base64.decode] throws on both, so
///   the payload is sanitized first; a garbage payload therefore still produces
///   a file (of whatever bytes survived) rather than an exception, which is
///   what the caller's `try/catch` upstream is written against.
/// * upstream passes `{ mode: 0o600 }` to the write itself; Dart cannot, so the
///   mode is applied immediately afterwards through [ensurePrivateFile]. There
///   is a sub-millisecond window where the file carries the default umask —
///   acceptable because the containing directory is already 0700.
MaterializedProviderImage materializeProviderImage({
  required String data,
  String? mimeType,
}) {
  final attachmentsDir = _getMaterializedImageAttachmentDir();
  final normalized = _normalizeImageData(mimeType ?? 'image/png', data);
  final bytes = _decodeBase64Lenient(normalized.data);
  final extension = _getImageExtension(normalized.mimeType);
  final hash = sha256.convert(bytes).toString();
  final file = File(p.join(attachmentsDir, '$hash.$extension'));
  file.writeAsBytesSync(bytes, flush: true);
  ensurePrivateFile(file);
  return MaterializedProviderImage(path: file.path);
}

List<int> _decodeBase64Lenient(String value) {
  final filtered = value.replaceAll(RegExp(r'[^A-Za-z0-9+/\-_]'), '');
  final canonical = filtered.replaceAll('-', '+').replaceAll('_', '/');
  // Node also ignores a trailing partial group; `base64.decode` would throw.
  final usable = canonical.substring(
    0,
    canonical.length - (canonical.length % 4 == 1 ? 1 : 0),
  );
  final padding = (4 - usable.length % 4) % 4;
  return base64.decode(usable + ('=' * padding));
}

/// Recognizes the markdown [renderProviderImageOutputAsAssistantMarkdown] emits
/// for a materialized attachment.
///
/// Matching the full `<64 hex>.<ext>` shape inside an attachments directory —
/// rather than merely a leading `![` — is what keeps user-authored image
/// markdown from being mistaken for a provider image during history replay. The
/// separator alternation still accepts doubled-backslash Windows history; new
/// Windows output uses `file://` URIs.
bool isProviderImageMarkdown(String text) =>
    _providerImageMarkdownPattern.hasMatch(text);

final RegExp _providerImageMarkdownPattern = RegExp(
  r'^!\[[^\]]*\]\([^)]*'
  '$_providerImageAttachmentDir'
  r'(?:-[^/\\)]+)?[/\\]+(?:[^/\\)]+[/\\]+)?[0-9a-f]{64}\.[a-z0-9]+\)',
);

/// Materializes an inline base64 image; injected so callers (and tests) can
/// decline to touch the filesystem.
typedef ProviderImageMaterializer =
    MaterializedProviderImage Function({
      required String data,
      String? mimeType,
    });

/// Renders [image] as assistant markdown, or `null` when there is nothing to
/// show.
///
/// Resolution order, straight from upstream:
/// 1. a non-`data:` path or URL is linked directly — no bytes are copied;
/// 2. otherwise the base64 payload (from `data`, or from a `data:` URI that
///    arrived in `path`/`url`) is handed to [materialize];
/// 3. a payload that cannot be materialized into a real file path degrades to a
///    plain apology rather than embedding a megabyte of base64 in the
///    transcript;
/// 4. no payload at all yields `null`.
///
/// [materialize] is optional: with no materializer an inline image always takes
/// branch 3, which is exactly how upstream behaves when the option is omitted.
ProviderImageAssistantMessage? renderProviderImageOutputAsAssistantMarkdown(
  ProviderImageOutput image, {
  ProviderImageMaterializer? materialize,
}) {
  final source = _nonEmptyString(image.path) ?? _nonEmptyString(image.url);
  if (source != null && !_isDataImageSource(source)) {
    final altText = _escapeMarkdownImageAlt(
      _nonEmptyString(image.altText) ?? 'Image',
    );
    return ProviderImageAssistantMessage(
      '![$altText](${_escapeMarkdownImageSource(source)})',
    );
  }

  final data =
      _nonEmptyString(image.data) ??
      ((source != null && _isDataImageSource(source)) ? source : null);
  if (data == null) return null;

  MaterializedProviderImage? materialized;
  try {
    materialized = materialize?.call(
      data: data,
      mimeType: _nonEmptyString(image.mimeType),
    );
  } on Object {
    materialized = null;
  }

  // `!materialized?.path` upstream: an empty path counts as no path.
  if (materialized == null ||
      materialized.path.isEmpty ||
      _isDataImageSource(materialized.path)) {
    return const ProviderImageAssistantMessage(
      'Image output was omitted because it was not available as a file path '
      'or URL.',
    );
  }

  final altText = _escapeMarkdownImageAlt(
    _nonEmptyString(image.altText) ?? 'Image',
  );
  return ProviderImageAssistantMessage(
    '![$altText](${_escapeMarkdownImageSource(materialized.path)})',
  );
}

String? _nonEmptyString(String? value) {
  final trimmed = value?.trim();
  return (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
}

bool _isDataImageSource(String source) =>
    source.trim().toLowerCase().startsWith('data:image/');

String _escapeMarkdownImageAlt(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll(']', r'\]');

/// Percent-encodes each path segment while leaving the separators intact.
///
/// [Uri.encodeComponent] escapes exactly the set `encodeURIComponent` does, so
/// `#`, `?` and spaces become `%23`, `%3F` and `%20` while `-_.!~*'()` survive.
String _encodeFilePath(String value) =>
    value.split('/').map(Uri.encodeComponent).join('/');

/// A `file:` URI for a Windows path, or `null` when [value] is not one.
///
/// Both `\\?\`-prefixed forms are unwrapped first, because a URI carrying the
/// literal namespace prefix is not resolvable by any viewer.
String? _windowsFileUri(String value) {
  final isWindowsNetworkPath = value.startsWith(r'\\');
  var normalizedPath = value.replaceAll(r'\', '/');
  if (RegExp(r'^//\?/UNC/', caseSensitive: false).hasMatch(normalizedPath)) {
    normalizedPath = '//${normalizedPath.substring(8)}';
  } else if (RegExp(r'^//\?/[A-Za-z]:/').hasMatch(normalizedPath)) {
    normalizedPath = normalizedPath.substring(4);
  }

  if (RegExp(r'^[A-Za-z]:/').hasMatch(normalizedPath)) {
    final drive = normalizedPath.substring(0, 2);
    return 'file:///$drive${_encodeFilePath(normalizedPath.substring(2))}';
  }
  if (isWindowsNetworkPath && normalizedPath.startsWith('//')) {
    return 'file:${_encodeFilePath(normalizedPath)}';
  }
  return null;
}

String _markdownImageSource(String value) {
  final windowsUri = _windowsFileUri(value);
  if (windowsUri != null) return windowsUri;
  if (value.startsWith('/')) return 'file://${_encodeFilePath(value)}';
  return value;
}

String _escapeMarkdownImageSource(String value) =>
    _markdownImageSource(value).replaceAll(r'\', r'\\').replaceAll(')', r'\)');
