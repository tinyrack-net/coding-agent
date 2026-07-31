/// Frozen Paseo 0.2.0 workspace identity primitives.
///
/// This is the Dart port of four upstream modules that all answer the same
/// family of question — "which project/workspace does this path or record
/// belong to?" — and that upstream keeps deliberately separate from workspace
/// *ownership*:
///
/// * `server/workspace-git-metadata.ts` — project slugs derived from a GitHub
///   remote (or the directory basename) and the DNS-safe service slug.
/// * `server/resolve-workspace-id-for-path.ts` — the external path -> workspace
///   adapter used only at boundaries where a client hands the daemon a bare
///   worktree path with no id.
/// * `server/workspace-bootstrap-dedupe.ts` — the pure decision of whether a
///   workspace update buffered during the bootstrap window still carries new
///   information once the snapshot has been delivered.
/// * `server/migrations/backfill-workspace-id.migration.ts` — the one-time
///   legacy backfill that stamps `workspaceId` onto agent records written
///   before the daemon started stamping it at create time.
///
/// None of these take a clock: every timestamp they compare is read off a
/// persisted record, so there is deliberately no `DateTime.now()` anywhere in
/// this file and no clock to inject.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:agent_protocol/agent_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../agent/agent_store.dart';
import 'workspace_registry.dart';

// ---------------------------------------------------------------------------
// Shared path normalization
// ---------------------------------------------------------------------------

/// Normalizes a path the way this repo's [areEquivalentPaths] does, but keeps
/// the normalized string so callers can also do prefix work with it.
///
/// Upstream uses Node's `path.resolve`, which makes a path absolute and
/// normalizes separators but never changes case. This repo already established
/// (in `workspace_registry.dart`) that Windows path identity is case-folded,
/// and every other workspace lookup in the daemon obeys that law. Case folding
/// is a no-op on the POSIX platforms upstream targets, so the *observable*
/// behavior is identical there; on Windows this is a deliberate deviation that
/// makes `C:\Repo` and `c:\repo` the same workspace, matching the rest of the
/// daemon rather than upstream's byte comparison.
String _pathKey(String value) {
  var normalized = p.normalize(p.absolute(value));
  if (Platform.isWindows) normalized = normalized.toLowerCase();
  return normalized;
}

/// The user's home directory, used to stop `~` from owning every descendant.
///
/// Upstream calls `os.homedir()`. Dart has no direct equivalent, so this
/// mirrors the resolution the rest of the daemon already uses
/// (`USERPROFILE` before `HOME`, since Windows sets only the former). Exposed
/// so callers — and tests — can inject a home directory instead of depending
/// on the ambient environment.
String defaultUserHomeDirectory() =>
    Platform.environment['USERPROFILE'] ??
    Platform.environment['HOME'] ??
    Directory.current.path;

// ---------------------------------------------------------------------------
// workspace-git-metadata.ts
// ---------------------------------------------------------------------------

/// The `owner/name` GitHub identity behind [remoteUrl], or `null`.
///
/// Thin wrapper over the already-ported [parseGitHubRemoteUrl] in
/// `agent_protocol`; it exists so callers that only want the repo string do not
/// have to know about [GitHubRemoteIdentity].
String? parseGitHubRepoFromRemote(String remoteUrl) =>
    parseGitHubRemoteUrl(remoteUrl)?.repo;

/// Just the repository name (the part after `owner/`) of a GitHub remote.
///
/// Deliberately drops the owner: Paseo's project slugs are named after the
/// repository alone, which is why two owners' `claude-code` forks collide on
/// the same slug. That collision is load-bearing upstream, not an oversight —
/// [deriveProjectServiceSlug] is the function that re-adds identity.
String? parseGitHubRepoNameFromRemote(String remoteUrl) {
  final githubRepo = parseGitHubRepoFromRemote(remoteUrl);
  // Upstream guards with `if (!githubRepo)`, which in JS also rejects the empty
  // string. `parseGitHubRemoteIdentity` filters empty path segments so an empty
  // repo is unreachable, but the emptiness check is reproduced for parity.
  if (githubRepo == null || githubRepo.isEmpty) return null;

  // Upstream is `githubRepo.split("/").pop() || null`: `pop()` on a non-empty
  // array cannot be `undefined`, and the `|| null` only fires for an empty
  // trailing segment, which the identity parser already excludes.
  final repoName = githubRepo.split('/').last;
  return repoName.isEmpty ? null : repoName;
}

/// The kebab-case project slug for a checkout at [cwd].
///
/// Prefers the GitHub repository name from [remoteUrl] so that a project keeps
/// a stable slug even when its directory is renamed, and falls back to the
/// directory basename for non-GitHub remotes, missing remotes and plain
/// directories. Slugs that collapse to nothing (for example a purely non-ASCII
/// directory name) become `untitled` rather than an empty label, because the
/// slug is used to build hostnames.
///
/// Deviation: upstream's `remoteUrl ? ... : null` relies on JS truthiness, so
/// an *empty-string* remote is treated as "no remote". Dart has no truthiness,
/// so the emptiness test is spelled out — passing `''` behaves exactly like
/// passing `null`, which is what the upstream "empty remote" test pins.
String deriveProjectSlug(String cwd, [String? remoteUrl]) {
  final githubRepoName = (remoteUrl != null && remoteUrl.isNotEmpty)
      ? parseGitHubRepoNameFromRemote(remoteUrl)
      : null;
  final sourceName = githubRepoName ?? p.basename(cwd);
  final slug = slugify(sourceName);
  // Upstream is `slugify(sourceName) || "untitled"`.
  return slug.isEmpty ? 'untitled' : slug;
}

/// The project slug used for per-project service hostnames.
///
/// [deriveProjectSlug] alone is not unique — two projects whose directories are
/// both named `app` produce the same slug — so an 8 hex-character SHA-256
/// digest of the project id is appended. The digest is of the *id*, not the
/// path, so the service slug survives moving the project on disk.
///
/// Note that this intentionally never consults a git remote: a service slug is
/// keyed to the checkout on disk, so it always uses the basename of
/// [rootPath].
String deriveProjectServiceSlug({
  required String projectId,
  required String rootPath,
}) {
  final identity = sha256
      .convert(utf8.encode(projectId))
      .toString()
      .substring(0, 8);
  return '${deriveProjectSlug(rootPath)}-$identity';
}

// ---------------------------------------------------------------------------
// resolve-workspace-id-for-path.ts
// ---------------------------------------------------------------------------

/// Resolves a raw filesystem path to a single workspace id.
///
/// This is an *external path -> workspace adapter, not ownership*. It is only
/// correct at the boundary where a client hands the daemon a bare worktree path
/// with no id (archive-by-path from an old client or the CLI, auto-archive
/// after merge, the MCP `archive_worktree` tool). It must never be used to
/// attribute agent status or to place agents under a workspace: those are keyed
/// by `workspaceId`, and git facts derive from a workspace's own cwd.
///
/// Resolution order:
/// 1. An exact directory match wins — including an *archived* workspace, so
///    archive-by-path stays idempotent against already-archived records.
/// 2. Otherwise the deepest enclosing *live* workspace directory wins.
/// 3. The home directory is never allowed to enclose a descendant, or every
///    path under `~` would resolve to a workspace the user did not mean.
/// 4. `null` when nothing encloses the path.
///
/// [workspaces] is iterated in order and ties are broken by that order: when
/// several workspaces share the exact same cwd the first one wins, and when
/// several enclosing workspaces are equally deep the first one wins (upstream
/// compares with a strict `>` against the best length so far). Upstream's own
/// test only asserts that *some* sharing workspace is returned; this port keeps
/// the stronger first-wins guarantee that the implementation actually has.
///
/// [homeDirectory] overrides the ambient home directory; leave it unset outside
/// tests.
String? resolveWorkspaceIdForPath(
  String cwd,
  Iterable<PersistedWorkspaceRecord> workspaces, {
  String? homeDirectory,
}) {
  final workspaceRecords = workspaces.toList(growable: false);
  final resolvedCwd = _pathKey(cwd);

  for (final workspace in workspaceRecords) {
    // Reuses the registry's path-equivalence law rather than re-deriving it.
    if (areEquivalentPaths(workspace.cwd, cwd)) {
      return workspace.workspaceId;
    }
  }

  final userHome = _pathKey(homeDirectory ?? defaultUserHomeDirectory());
  var bestMatchLength = 0;
  PersistedWorkspaceRecord? bestMatch;
  for (final workspace in workspaceRecords) {
    if (workspace.archivedAt != null) continue;
    final workspaceCwd = _pathKey(workspace.cwd);
    if (workspaceCwd == userHome) continue;
    // The trailing separator is what stops `/workspace/project` from claiming
    // the sibling `/workspace/project-two`. A normalized path only already ends
    // in a separator when it is a filesystem root (`/` or `C:\`).
    final prefix = workspaceCwd.endsWith(p.separator)
        ? workspaceCwd
        : '$workspaceCwd${p.separator}';
    if (!resolvedCwd.startsWith(prefix)) continue;
    if (workspaceCwd.length > bestMatchLength) {
      bestMatchLength = workspaceCwd.length;
      bestMatch = workspace;
    }
  }

  return bestMatch?.workspaceId;
}

// ---------------------------------------------------------------------------
// workspace-bootstrap-dedupe.ts
// ---------------------------------------------------------------------------

const Object _absent = Object();

/// The three fields the bootstrap flush compares between the snapshot a client
/// just received and an update that was buffered while it was in flight.
///
/// Modelled as a plain value class rather than an enum-backed status because
/// upstream compares the status as an opaque string; the dedupe decision must
/// stay correct for any status the workspace layer invents.
final class BootstrapUpdateSnapshot {
  const BootstrapUpdateSnapshot({
    required this.status,
    required this.statusEnteredAt,
    required this.activityAtMs,
  });

  /// Opaque workspace status label (`done`, `needs_input`, ...).
  final String status;

  /// ISO-8601 instant the workspace entered [status], or `null` when unknown.
  final String? statusEnteredAt;

  /// Last activity as epoch milliseconds, or `null` when there was none.
  final int? activityAtMs;

  /// Sentinel-based copy so `null` can be written explicitly, mirroring the
  /// TypeScript object-spread overrides the upstream suite relies on.
  BootstrapUpdateSnapshot copyWith({
    String? status,
    Object? statusEnteredAt = _absent,
    Object? activityAtMs = _absent,
  }) => BootstrapUpdateSnapshot(
    status: status ?? this.status,
    statusEnteredAt: identical(statusEnteredAt, _absent)
        ? this.statusEnteredAt
        : statusEnteredAt as String?,
    activityAtMs: identical(activityAtMs, _absent)
        ? this.activityAtMs
        : activityAtMs as int?,
  );
}

/// Whether a workspace update buffered during the bootstrap window still says
/// something the client did not already learn from `fetch_workspaces_response`.
///
/// Emits when ANY of the following holds:
/// * there is no [snapshot] at all (first-time subscription);
/// * the status changed;
/// * `statusEnteredAt` changed, including either direction of the
///   `null` <-> value transition that the unmask case produces;
/// * the update's activity is strictly newer than the snapshot's;
/// * the snapshot had no activity and the update does.
///
/// Drops otherwise. In particular the both-`null` activity case falls through
/// to drop, and an update that *lost* activity relative to the snapshot is also
/// dropped — there is genuinely no new information in either.
bool shouldEmitPendingBootstrapUpdate({
  required BootstrapUpdateSnapshot? snapshot,
  required BootstrapUpdateSnapshot update,
}) {
  if (snapshot == null) return true;
  if (snapshot.status != update.status) return true;
  if (snapshot.statusEnteredAt != update.statusEnteredAt) return true;

  // Status pair is unchanged. The only remaining signal is activity.
  if (update.activityAtMs == null) return false;
  if (snapshot.activityAtMs == null) return true;
  return update.activityAtMs! > snapshot.activityAtMs!;
}

// ---------------------------------------------------------------------------
// migrations/backfill-workspace-id.migration.ts
// ---------------------------------------------------------------------------

/// Picks the workspace that owned [cwd] for a legacy, unstamped agent record.
///
/// COMPAT(workspaceIdBackfill): together with
/// [backfillWorkspaceIdForLegacyAgents] this is the ONLY place that maps a cwd
/// to a workspace id for ownership purposes. Every other code path treats a
/// record's `workspaceId` as authoritative. Delete both once the supported
/// floor is past the release that always stamps `workspaceId` at create time.
///
/// Differences from [resolveWorkspaceIdForPath], all intentional upstream:
/// * ties are broken by *age* (oldest `createdAt` wins), not iteration order,
///   because a legacy record predates the newer duplicate workspaces;
/// * archived workspaces are opted in with [includeArchived] rather than being
///   allowed for exact matches only — a live record must never be adopted by an
///   archived workspace, while an archived record may be, so History and
///   restore retain legacy ownership;
/// * the enclosing test accepts the exact path as well as a prefixed one.
///
/// [homeDirectory] overrides the ambient home directory; leave it unset outside
/// tests.
String? resolveLegacyWorkspaceOwner(
  String cwd,
  Iterable<PersistedWorkspaceRecord> workspaces, {
  bool includeArchived = false,
  String? homeDirectory,
}) {
  final normalizedCwd = _pathKey(cwd);
  final userHome = _pathKey(homeDirectory ?? defaultUserHomeDirectory());
  final candidateWorkspaces = workspaces
      .where((workspace) => includeArchived || workspace.archivedAt == null)
      .toList(growable: false);

  final exactMatches = candidateWorkspaces
      .where((workspace) => _pathKey(workspace.cwd) == normalizedCwd)
      .toList(growable: false);
  if (exactMatches.isNotEmpty)
    return _oldestWorkspace(exactMatches).workspaceId;

  final prefixMatches = candidateWorkspaces
      .where((workspace) {
        final workspaceCwd = _pathKey(workspace.cwd);
        if (workspaceCwd == userHome) return false;
        // Upstream appends the separator unconditionally here (unlike
        // resolve-workspace-id-for-path.ts, which checks `endsWith` first), so a
        // filesystem-root workspace builds the prefix `//` (or `C:\\`) and never
        // matches a descendant. The `normalizedCwd == workspaceCwd` disjunct is
        // dead by this point — exact matches already returned — but is kept so the
        // two implementations stay diffable against upstream.
        return normalizedCwd == workspaceCwd ||
            normalizedCwd.startsWith('$workspaceCwd${p.separator}');
      })
      .toList(growable: false);
  if (prefixMatches.isEmpty) return null;

  final deepestPrefixLength = prefixMatches
      .map((workspace) => _pathKey(workspace.cwd).length)
      .reduce(math.max);
  return _oldestWorkspace(
    prefixMatches
        .where(
          (workspace) => _pathKey(workspace.cwd).length == deepestPrefixLength,
        )
        .toList(growable: false),
  ).workspaceId;
}

/// Lowest `createdAt` wins; ties keep the earliest in iteration order because
/// upstream's reduce only replaces on a strict `<`.
PersistedWorkspaceRecord _oldestWorkspace(
  List<PersistedWorkspaceRecord> workspaces,
) => workspaces.reduce(
  (oldest, candidate) =>
      candidate.createdAt.compareTo(oldest.createdAt) < 0 ? candidate : oldest,
);

/// Stamps `workspaceId` onto every legacy agent record that lacks one.
///
/// Runs once at startup, before any runtime code reads `workspaceId`, so the
/// rest of the daemon can assume the field is populated for records that have
/// a resolvable owner. Records with no resolvable owner are left alone — they
/// stay unowned rather than being attributed to an arbitrary workspace.
///
/// Returns the number of records rewritten.
///
/// Deviations from upstream, forced by this repo's storage shape:
/// * upstream's `AgentStorage.list()/upsert()` become [AgentStore.loadAll] and
///   [AgentStore.save]; the write is a full atomic rewrite of the record with a
///   new summary, which is the only mutation path [AgentStore] offers.
/// * upstream skips a record with `if (record.workspaceId)`, JS truthiness that
///   also treats `""` as unstamped. Reproduced explicitly with an emptiness
///   check so a blank id is backfilled rather than silently kept.
/// * upstream keys "is archived" off `record.archivedAt != null`. This repo
///   carries both a persisted `archived` flag and `summary.archivedAt`, kept in
///   sync by the agent manager, so either signal counts.
/// * upstream logs through pino; this takes the daemon's `void Function(String)`
///   log callback convention and stays silent when nothing was migrated.
Future<int> backfillWorkspaceIdForLegacyAgents({
  required AgentStore agentStore,
  required FileBackedWorkspaceRegistry workspaceRegistry,
  void Function(String message)? log,
  String? homeDirectory,
}) async {
  final workspaceRecords = await workspaceRegistry.list();
  final records = await agentStore.loadAll();
  var migrated = 0;

  for (final record in records) {
    final existing = record.summary.workspaceId;
    if (existing != null && existing.isNotEmpty) continue;

    final workspaceId = resolveLegacyWorkspaceOwner(
      record.summary.cwd,
      workspaceRecords,
      includeArchived: record.archived || record.summary.archivedAt != null,
      homeDirectory: homeDirectory,
    );
    if (workspaceId == null) continue;

    await agentStore.save(_withWorkspaceId(record, workspaceId));
    migrated += 1;
  }

  if (migrated > 0) {
    log?.call('Backfilled workspaceId for $migrated legacy agent records');
  }
  return migrated;
}

/// Rebuilds a persisted agent with a stamped `workspaceId`, preserving every
/// other field. [PersistedAgent] has no `copyWith`, and adding one would mean
/// editing shared storage code, so the record is reconstructed here.
PersistedAgent _withWorkspaceId(PersistedAgent record, String workspaceId) =>
    PersistedAgent(
      summary: record.summary.copyWith(workspaceId: workspaceId),
      archived: record.archived,
      epoch: record.epoch,
      lastSeq: record.lastSeq,
      items: record.items,
      rows: record.rows,
      internal: record.internal,
      mcpServers: record.mcpServers,
      environment: record.environment,
    );
