/// Port of Paseo 0.2.0's two *grouping by project* modules. They live in one
/// library because they answer the same question from opposite ends: "which
/// project does this agent belong to, and what row should the UI draw for it?"
///
/// - `utils/agent-grouping.ts` — derives a project identity for an agent (from
///   its cwd, or preferably from the git remote so worktrees of one repo
///   collapse together), then splits the agent list into an *active* section
///   grouped by project and an *inactive* section grouped by recency.
/// - `workspace/legacy-daemon-workspaces.ts` — the `COMPAT(legacyWorkspaceDaemon)`
///   shim. Daemons older than v0.1.97 expose agents by cwd but have no workspace
///   registry, so the client synthesizes one workspace row per checkout
///   directory. Upstream deliberately keeps every cwd -> synthetic-workspace rule
///   in a single file so the shim is deleted by deleting the module once the
///   daemon floor rises.
///
/// Reused rather than redeclared, from `package:agent_protocol`:
/// [AgentSummary] and [AgentDirectoryEntry] (upstream's store `Agent` and
/// `FetchAgentsEntry`), [WorkspaceDescriptor], [WorkspaceProjectDescriptor],
/// [WorkspaceGitRuntime], [WorkspaceProjectKind], [WorkspaceKind],
/// [WorkspaceStateBucket], [ServerInfoStatus] (upstream's `DaemonServerInfo`),
/// [AgentDirectorySort]/[AgentDirectorySortKey]/[AgentDirectorySortDirection],
/// [AgentDirectoryPageInfo], and the two bucket rules `deriveAgentStateBucket`
/// and `getWorkspaceStateBucketPriority`.
library;

import 'package:agent_protocol/agent_protocol.dart';

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Sort that keeps equal elements in their original relative order.
///
/// JavaScript's `Array.prototype.sort` has been stable since ES2019 and both
/// modules below lean on it (agents that share a `lastActivityAt` must keep
/// their arrival order; a project's truly-active agents must stay ahead of the
/// merely-recent ones they tie with). Dart's `List.sort` makes no stability
/// promise, so the original index is folded in as a final tiebreak.
///
/// Deliberately duplicated from the identical private helper in
/// `core/paseo_session_projection.dart`: that one is library-private and this
/// port may not edit an existing file to widen it.
List<T> _stableSorted<T>(Iterable<T> items, int Function(T a, T b) compare) {
  final indexed = items.toList(growable: false).asMap().entries.toList();
  indexed.sort((a, b) {
    final result = compare(a.value, b.value);
    return result != 0 ? result : a.key.compareTo(b.key);
  });
  return [for (final entry in indexed) entry.value];
}

/// Upstream `trimNonEmpty` from `utils/workspace-identity.ts`: a value that is
/// only whitespace is indistinguishable from a missing one.
String? _trimNonEmpty(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Upstream `normalizeWorkspacePath` from `utils/workspace-identity.ts`:
/// canonicalize separators and drop trailing slashes so two spellings of the
/// same directory compare equal. The bare root is special-cased because
/// stripping its only slash would leave nothing.
///
/// Duplicated from the private copy in `core/paseo_session_projection.dart` for
/// the same reason as [_stableSorted]. When `utils/workspace-identity.ts` gets
/// its own port this and that copy should both collapse into it.
String? _normalizeWorkspacePath(String? value) {
  final trimmed = _trimNonEmpty(value);
  if (trimmed == null) return null;
  final withUnixSeparators = trimmed.replaceAll(r'\', '/');
  if (withUnixSeparators == '/') return withUnixSeparators;
  final withoutTrailingSlash = withUnixSeparators.replaceFirst(
    RegExp(r'/+$'),
    '',
  );
  return withoutTrailingSlash.isEmpty ? '/' : withoutTrailingSlash;
}

// ===========================================================================
// utils/agent-grouping.ts
// ===========================================================================

/// The marker Paseo stamps into a worktree path. Everything before it is the
/// repository the worktree was cut from.
const String _worktreeMarker = '.paseo/worktrees/';

/// The project key used to group agents that have no usable git remote.
///
/// A Paseo-owned worktree reports the parent repo path, so every worktree of one
/// checkout lands in the same group; anything else is grouped by its own cwd.
///
/// The trailing-slash strip removes exactly one slash, matching upstream's
/// non-global `/\/$/` — a path ending in `//` keeps one of them.
String deriveProjectKey(String cwd) {
  final idx = cwd.indexOf(_worktreeMarker);
  if (idx != -1) {
    return cwd.substring(0, idx).replaceFirst(RegExp(r'/$'), '');
  }
  return cwd;
}

/// A stable grouping key derived from a git remote URL, or null when the URL
/// cannot be resolved to a host *and* an owner-qualified path.
///
/// This is what makes the intended UX work: two clones (or worktrees) of the
/// same repo in unrelated directories collapse into one project group, because
/// the remote is the thing they actually share.
///
/// Waterfall: GitHub is normalized to a well-known key so SSH and HTTPS spellings
/// agree; any other host keeps its own name in the key so two forges cannot
/// collide on the same `owner/repo`.
///
/// Deliberately not routed through `package:agent_protocol`'s
/// [parseGitRemoteLocation], even though the two overlap heavily. That helper is
/// a port of a *different* upstream module (`utils/git-remote.ts`) and is
/// stricter in three observable ways: it rejects schemes outside
/// `https`/`http`/`ssh`, it validates the host against a hostname charset, and
/// it accepts single-segment paths. Upstream's rule here accepts any scheme,
/// never validates the host, and *requires* a `/` in the path. Reusing it would
/// silently change which remotes group together.
///
/// Deviation: upstream builds a `new URL(...)` and reads `hostname`, which keeps
/// the brackets on an IPv6 literal (`[::1]`). Dart's [Uri.host] strips them, so
/// an IPv6 remote yields `remote:::1/owner/repo` instead of
/// `remote:[::1]/owner/repo`. The key is only ever compared against other keys
/// produced by this same function, so grouping is unaffected; only a key that
/// leaked into a UI label would look different.
String? deriveRemoteProjectKey(String? remoteUrl) {
  // JS `!remoteUrl` also rejects the empty string, which `== null` would not.
  if (remoteUrl == null || remoteUrl.isEmpty) {
    return null;
  }

  final trimmed = remoteUrl.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  // Supported forms:
  // - git@github.com:owner/repo.git
  // - https://github.com/owner/repo(.git)
  // - ssh://git@github.com/owner/repo(.git)
  String? host;
  String? path;

  // SSH scp-like form: user@host:owner/repo(.git). Checked first, so
  // `ssh://git@github.com:22/owner/repo.git` is read as host `github.com` with
  // path `22/owner/repo` — the port number becomes a path segment. That is
  // upstream's behavior and is preserved rather than "fixed".
  final scpLike = RegExp(r'^[^@]+@([^:]+):(.+)$').firstMatch(trimmed);
  if (scpLike != null) {
    host = scpLike.group(1);
    path = scpLike.group(2);
  } else if (trimmed.contains('://')) {
    // `Uri.tryParse` returning null stands in for upstream's `try { new URL }
    // catch {}`: both leave host and path unset and fall through to the guard.
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null) {
      host = parsed.host;
      path = parsed.path.isEmpty
          ? null
          : parsed.path.replaceFirst(RegExp(r'^/'), '');
    }
  }

  // JS `!host || !path` — the empty string is falsy, so an authority-less URL
  // (`file:///a/b`, `https:///owner/repo`) and a root-only path both bail here.
  if (host == null || host.isEmpty || path == null || path.isEmpty) {
    return null;
  }

  var cleanedPath = path
      .trim()
      .replaceFirst(RegExp(r'^/+'), '')
      .replaceFirst(RegExp(r'/+$'), '');
  if (cleanedPath.endsWith('.git')) {
    cleanedPath = cleanedPath.substring(0, cleanedPath.length - 4);
  }

  // Best-effort: owner/repo is the common case. A longer path (groups/subgroups
  // /repo) is kept whole; a bare repo name is rejected because it would collide
  // across owners.
  if (!cleanedPath.contains('/')) {
    return null;
  }

  final cleanedHost = host.toLowerCase();

  // GitHub is treated as a well-known host. The formatted result is identical to
  // the generic branch below; the branch is kept because upstream keeps it, and
  // because it is the seam where GitHub-specific normalization would go.
  if (cleanedHost == 'github.com') {
    return 'remote:github.com/$cleanedPath';
  }

  return 'remote:$cleanedHost/$cleanedPath';
}

/// The `owner/repo` portion of a git remote URL, or null when the URL does not
/// resolve to an owner-qualified name.
///
/// Intentionally sloppier than [deriveRemoteProjectKey]: it never looks at the
/// host, so it is only safe for display, never for identity.
///
/// Examples:
/// - `git@github.com:anthropics/claude-code.git` -> `anthropics/claude-code`
/// - `https://github.com/anthropics/claude-code.git` -> `anthropics/claude-code`
/// - `https://github.com/anthropics/claude-code` -> `anthropics/claude-code`
String? parseRepoNameFromRemoteUrl(String? remoteUrl) {
  if (remoteUrl == null || remoteUrl.isEmpty) {
    return null;
  }

  var cleaned = remoteUrl;

  // SSH format: git@github.com:owner/repo.git
  if (cleaned.startsWith('git@')) {
    final colonIdx = cleaned.indexOf(':');
    if (colonIdx != -1) {
      cleaned = cleaned.substring(colonIdx + 1);
    }
  }
  // HTTPS format: https://github.com/owner/repo.git
  else if (cleaned.contains('://')) {
    // JS `split("://")[1]` on a triple-scheme string keeps only the second
    // chunk; `elementAtOrNull` reproduces the `undefined` for a missing index,
    // and the `isNotEmpty` guard reproduces JS's `if (urlPath)` truthiness.
    final urlPath = cleaned.split('://').elementAtOrNull(1);
    if (urlPath != null && urlPath.isNotEmpty) {
      // Remove the host (e.g. `github.com/`).
      final slashIdx = urlPath.indexOf('/');
      if (slashIdx != -1) {
        cleaned = urlPath.substring(slashIdx + 1);
      }
    }
  }

  if (cleaned.endsWith('.git')) {
    cleaned = cleaned.substring(0, cleaned.length - 4);
  }

  // Should be `owner/repo` by now.
  return cleaned.contains('/') ? cleaned : null;
}

/// Just the repo name, with the owner dropped.
///
/// Example: `git@github.com:anthropics/claude-code.git` -> `claude-code`.
String? parseRepoShortNameFromRemoteUrl(String? remoteUrl) {
  final fullName = parseRepoNameFromRemoteUrl(remoteUrl);
  // JS `!fullName` — a remote of exactly `"/"` parses to the empty string here.
  if (fullName == null || fullName.isEmpty) {
    return null;
  }
  final last = fullName.split('/').last;
  // JS `parts[parts.length - 1] || null` — a trailing slash yields "".
  return last.isEmpty ? null : last;
}

/// The short name for a project key: the repo path for a GitHub remote key,
/// otherwise the last path segment.
///
/// Falls back to the whole key whenever the extraction would produce nothing,
/// so a row always has *some* label.
String deriveProjectName(String projectKey) {
  const githubRemotePrefix = 'remote:github.com/';
  if (projectKey.startsWith(githubRemotePrefix)) {
    final rest = projectKey.substring(githubRemotePrefix.length);
    return rest.isEmpty ? projectKey : rest;
  }
  final segments = projectKey.split('/').where((value) => value.isNotEmpty);
  return segments.isEmpty ? projectKey : segments.last;
}

/// The label the UI shows for a project.
///
/// Separate from [deriveProjectName] because the two answer different questions:
/// [deriveProjectName] is the *derived* name stored on a [ProjectGroup], while
/// this one is given the already-resolved name and only overrides it when the
/// key carries better information.
///
/// - GitHub remotes show `owner/repo`.
/// - Other remotes show the remote path, falling back to the whole
///   `host/path` remainder when there is no `/` to split on.
/// - Local projects prefer [projectName], then the cwd tail.
///
/// Upstream takes a single object argument; the two fields are passed as named
/// parameters here.
String deriveProjectDisplayName({
  required String projectKey,
  required String projectName,
}) {
  const githubPrefix = 'remote:github.com/';
  if (projectKey.startsWith(githubPrefix)) {
    return projectKey.substring(githubPrefix.length);
  }

  const remotePrefix = 'remote:';
  if (projectKey.startsWith(remotePrefix)) {
    final withoutPrefix = projectKey.substring(remotePrefix.length);
    final slashIdx = withoutPrefix.indexOf('/');
    if (slashIdx >= 0) {
      final remotePath = withoutPrefix.substring(slashIdx + 1).trim();
      if (remotePath.isNotEmpty) {
        return remotePath;
      }
    }
    return withoutPrefix;
  }

  final trimmedProjectName = projectName.trim();
  if (trimmedProjectName.isNotEmpty) {
    return trimmedProjectName;
  }

  final normalized = projectKey
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  final segments = normalized.split('/').where((value) => value.isNotEmpty);
  return segments.isEmpty ? projectKey : segments.last;
}

/// The recency bucket an inactive agent is filed under.
///
/// Upstream `deriveDateGroup` returns a bare `string` drawn from a closed set
/// that a second module (`dateOrder`) then has to re-list in the right order.
/// Modelling it as an enum makes the order intrinsic — [values] *is* upstream's
/// `dateOrder`, in the same sequence — while [label] preserves the exact strings
/// upstream renders and groups by.
enum AgentDateGroup {
  recent('Recent'),
  yesterday('Yesterday'),
  thisWeek('This week'),
  thisMonth('This month'),
  older('Older');

  const AgentDateGroup(this.label);

  /// The user-visible header, byte-for-byte upstream's string.
  final String label;
}

/// Local-calendar midnight for an instant.
///
/// JavaScript's `Date.prototype.getFullYear()` and friends always read the
/// *local* calendar regardless of how the value was constructed, so a UTC
/// [DateTime] is converted first; without [DateTime.toLocal] a `DateTime.utc`
/// input would be bucketed against UTC calendar days while `now` used local
/// ones.
DateTime _startOfLocalDay(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// The recency bucket for an agent, relative to the injected [now].
///
/// Upstream reads `new Date()` inline; the clock is a parameter here so the
/// bucketing is deterministic under test.
///
/// Bucketing is by *calendar day*, not elapsed hours: an agent last active one
/// minute before midnight is "Yesterday" a minute later. That is what makes the
/// headers read the way a user expects.
///
/// A future timestamp lands in [AgentDateGroup.recent], because everything at or
/// after today's midnight is "Recent".
AgentDateGroup deriveDateGroup(
  DateTime lastActivityAt, {
  required DateTime now,
}) {
  final today = _startOfLocalDay(now);
  // Upstream subtracts exactly 24h from the epoch value rather than stepping the
  // calendar, so across a DST boundary "yesterday" is not local midnight. Dart's
  // `subtract` is likewise epoch-based, which reproduces that quirk.
  final yesterday = today.subtract(const Duration(hours: 24));
  final activityDate = _startOfLocalDay(lastActivityAt);

  if (activityDate.millisecondsSinceEpoch >= today.millisecondsSinceEpoch) {
    return AgentDateGroup.recent;
  }
  if (activityDate.millisecondsSinceEpoch >= yesterday.millisecondsSinceEpoch) {
    return AgentDateGroup.yesterday;
  }

  final diffMs =
      today.millisecondsSinceEpoch - activityDate.millisecondsSinceEpoch;
  final diffDays = (diffMs / Duration.millisecondsPerDay).floor();

  if (diffDays <= 7) {
    return AgentDateGroup.thisWeek;
  }
  if (diffDays <= 30) {
    return AgentDateGroup.thisMonth;
  }
  return AgentDateGroup.older;
}

/// The agent facts [groupAgents] reads.
///
/// Upstream's `AggregatedAgent` carries fifteen fields; the grouper inspects
/// seven, five of which are already on the protocol's [AgentSummary]. Composing
/// [AgentSummary] rather than restating its fields keeps this type honest about
/// where the data comes from, and matches how
/// `core/paseo_session_projection.dart` handles the same problem with its
/// `AgentStatusSnapshot`. The fields upstream carries but never groups by
/// (`serverId`, `serverLabel`, `title`, `provider`, `attentionReason`,
/// `attentionTimestamp`, `createdAt`, `labels`, `projectPlacement`,
/// `workspaceId`) are left out until a caller needs them; adding them would only
/// obscure that grouping is blind to them.
///
/// Overlaps with `state/agent_history_provider.dart`'s `AgentHistoryEntry`,
/// which is the same idea for the history screen. It is not reused because its
/// `activityAt` is *derived* (`updatedAt ?? createdAtMs`), whereas upstream's
/// `lastActivityAt` is an independently maintained store field fed by stream
/// traffic — a live agent can be active without its `updatedAt` moving, and
/// [AgentHistoryEntry] has no way to express that.
final class AggregatedAgent {
  const AggregatedAgent({
    required this.agent,
    required this.lastActivityAt,
    this.pendingPermissionCount,
  });

  /// Supplies `id` (as [AgentSummary.agentId]), `cwd`, `status` (as
  /// [AgentSummary.runState]), `requiresAttention` and `archivedAt`.
  final AgentSummary agent;

  /// When this agent last did anything, from the session store's activity
  /// index rather than from the agent snapshot.
  final DateTime lastActivityAt;

  /// Nullable to mirror upstream's optional `pendingPermissionCount?: number`;
  /// a missing count is read as zero.
  final int? pendingPermissionCount;

  /// Upstream `agent.id`.
  String get id => agent.agentId;

  /// Upstream `agent.cwd`.
  String get cwd => agent.cwd;
}

/// One project section of the active list.
final class ProjectGroup {
  const ProjectGroup({
    required this.projectKey,
    required this.projectName,
    required this.agents,
    required this.activeCount,
    required this.totalCount,
  });

  final String projectKey;
  final String projectName;

  /// The rows actually rendered — every truly active agent plus at most
  /// [maxInactiveAgentsPerProject] merely-recent ones.
  final List<AggregatedAgent> agents;

  /// Truly active agents (running, needs input, or requires attention).
  final int activeCount;

  /// Total agents in this project before the per-project limit was applied, so
  /// the UI can render an accurate "+N more".
  final int totalCount;
}

/// One recency section of the inactive list.
final class DateGroup {
  const DateGroup({required this.group, required this.agents});

  final AgentDateGroup group;
  final List<AggregatedAgent> agents;

  /// Upstream stores the header string directly on the group; it is derived
  /// from [group] here so the two can never disagree.
  String get label => group.label;
}

/// The two-section result of [groupAgents].
final class GroupedAgents {
  const GroupedAgents({
    required this.activeGroups,
    required this.inactiveGroups,
  });

  final List<ProjectGroup> activeGroups;
  final List<DateGroup> inactiveGroups;
}

/// How long an agent stays in the active section after it goes quiet.
///
/// Upstream's comment marks two days as "temporary for screenshots"; the value
/// is preserved verbatim because changing it would silently move rows between
/// sections.
const Duration activeGracePeriod = Duration(days: 2);

/// The cap on merely-recent agents shown per project. Truly active agents are
/// never capped — hiding one would hide a prompt the user has to answer.
const int maxInactiveAgentsPerProject = 5;

/// Whether an agent is demanding attention right now, as opposed to merely
/// having been touched recently.
bool _isAgentTrulyActive(AggregatedAgent agent) =>
    agent.agent.runState == AgentRunState.running ||
    agent.agent.requiresAttention ||
    (agent.pendingPermissionCount ?? 0) > 0;

/// JS truthiness on `agent.archivedAt`: the protocol carries it as an ISO
/// string, and the empty string is falsy upstream just as a missing value is.
bool _isArchived(AggregatedAgent agent) {
  final archivedAt = agent.agent.archivedAt;
  return archivedAt != null && archivedAt.isNotEmpty;
}

final class _ProjectActivityBucket {
  final List<AggregatedAgent> trulyActive = [];
  final List<AggregatedAgent> recentlyActive = [];
}

int _byLastActivityDescending(AggregatedAgent a, AggregatedAgent b) =>
    b.lastActivityAt.compareTo(a.lastActivityAt);

/// Splits agents into an active section grouped by project and an inactive
/// section grouped by recency.
///
/// "Active" is deliberately generous — running, needs input, requires attention,
/// *or* touched within [activeGracePeriod] — because a user who stepped away for
/// an hour should come back to their work still in place rather than filed under
/// a date header. Archived agents are always inactive regardless of timestamps.
///
/// Within a project group all truly active agents are shown, and the merely
/// recent ones are capped at [maxInactiveAgentsPerProject]; [ProjectGroup.totalCount]
/// reports what the cap hid. Groups are ordered by their own most recent agent,
/// so the project the user just touched floats to the top.
///
/// [getRemoteUrl] is upstream's `options.getRemoteUrl`. When it yields a URL that
/// [deriveRemoteProjectKey] can resolve, agents group by repository; otherwise
/// they fall back to [deriveProjectKey] on the cwd. Passing it as a plain
/// nullable callback replaces upstream's one-field `GroupAgentsOptions` object.
///
/// [now] is upstream's inline `Date.now()` / `new Date()`, injected so the grace
/// period and the date headers are testable.
GroupedAgents groupAgents({
  required List<AggregatedAgent> agents,
  required DateTime now,
  String? Function(AggregatedAgent agent)? getRemoteUrl,
}) {
  final nowMs = now.millisecondsSinceEpoch;
  final activeAgents = <AggregatedAgent>[];
  final inactiveAgents = <AggregatedAgent>[];

  for (final agent in agents) {
    if (_isArchived(agent)) {
      inactiveAgents.add(agent);
      continue;
    }

    final isRecentlyActive =
        nowMs - agent.lastActivityAt.millisecondsSinceEpoch <
        activeGracePeriod.inMilliseconds;
    if (_isAgentTrulyActive(agent) || isRecentlyActive) {
      activeAgents.add(agent);
    } else {
      inactiveAgents.add(agent);
    }
  }

  return GroupedAgents(
    activeGroups: _buildActiveProjectGroups(
      _buildProjectActivityMap(activeAgents, getRemoteUrl),
    ),
    inactiveGroups: _buildInactiveDateGroups(inactiveAgents, now),
  );
}

/// Insertion-ordered, matching JS `Map` iteration order, which the group sort
/// below relies on for its stability tiebreak.
Map<String, _ProjectActivityBucket> _buildProjectActivityMap(
  List<AggregatedAgent> activeAgents,
  String? Function(AggregatedAgent agent)? getRemoteUrl,
) {
  final projectMap = <String, _ProjectActivityBucket>{};
  for (final agent in activeAgents) {
    final remoteKey = deriveRemoteProjectKey(getRemoteUrl?.call(agent));
    final projectKey = remoteKey ?? deriveProjectKey(agent.cwd);
    final bucket = projectMap.putIfAbsent(
      projectKey,
      _ProjectActivityBucket.new,
    );
    if (_isAgentTrulyActive(agent)) {
      bucket.trulyActive.add(agent);
    } else {
      bucket.recentlyActive.add(agent);
    }
  }
  return projectMap;
}

List<ProjectGroup> _buildActiveProjectGroups(
  Map<String, _ProjectActivityBucket> projectMap,
) {
  final activeGroups = <ProjectGroup>[];
  for (final entry in projectMap.entries) {
    final trulyActive = _stableSorted(
      entry.value.trulyActive,
      _byLastActivityDescending,
    );
    final recentlyActive = _stableSorted(
      entry.value.recentlyActive,
      _byLastActivityDescending,
    );

    final limitedRecentlyActive = recentlyActive
        .take(maxInactiveAgentsPerProject)
        .toList();
    // Re-sorting the concatenation is what interleaves the two lists by time.
    // Stability matters: on a tie the truly-active agent stays ahead, because it
    // came first in the input to this sort.
    final combinedAgents = _stableSorted([
      ...trulyActive,
      ...limitedRecentlyActive,
    ], _byLastActivityDescending);

    activeGroups.add(
      ProjectGroup(
        projectKey: entry.key,
        projectName: deriveProjectName(entry.key),
        agents: combinedAgents,
        activeCount: trulyActive.length,
        totalCount: trulyActive.length + recentlyActive.length,
      ),
    );
  }

  return _stableSorted(activeGroups, (a, b) {
    // Upstream's `a.agents[0]?.lastActivityAt.getTime() ?? 0`. A group is never
    // actually empty — it exists because an agent was filed into it — but the
    // epoch fallback is kept so the comparator stays total.
    final aRecent = a.agents.isEmpty
        ? 0
        : a.agents.first.lastActivityAt.millisecondsSinceEpoch;
    final bRecent = b.agents.isEmpty
        ? 0
        : b.agents.first.lastActivityAt.millisecondsSinceEpoch;
    return bRecent.compareTo(aRecent);
  });
}

List<DateGroup> _buildInactiveDateGroups(
  List<AggregatedAgent> inactiveAgents,
  DateTime now,
) {
  final dateMap = <AgentDateGroup, List<AggregatedAgent>>{};
  for (final agent in inactiveAgents) {
    dateMap
        .putIfAbsent(deriveDateGroup(agent.lastActivityAt, now: now), () => [])
        .add(agent);
  }

  // Iterating the enum rather than the map is upstream's `dateOrder` walk: the
  // rendered order is fixed, and empty buckets are skipped entirely.
  final inactiveGroups = <DateGroup>[];
  for (final group in AgentDateGroup.values) {
    final dateAgents = dateMap[group];
    if (dateAgents == null || dateAgents.isEmpty) continue;
    inactiveGroups.add(
      DateGroup(
        group: group,
        agents: _stableSorted(dateAgents, _byLastActivityDescending),
      ),
    );
  }
  return inactiveGroups;
}

// ===========================================================================
// workspace/legacy-daemon-workspaces.ts
// ===========================================================================
//
// COMPAT(legacyWorkspaceDaemon): v0.1.97 app talking to <=v0.1.96 daemons.
// Older daemons expose agents by cwd but may have no workspace registry rows.
// Every cwd -> synthetic workspace rule is kept in this section so the shim is
// deleted by deleting the section and its call sites once the daemon floor is
// v0.1.97.

/// The sort a legacy directory fetch always asks for: newest activity first.
///
/// Upstream's `LEGACY_AGENT_DIRECTORY_SORT`, rebuilt from the protocol's own
/// sort types rather than a local literal.
const List<AgentDirectorySort> legacyAgentDirectorySort = [
  AgentDirectorySort(
    key: AgentDirectorySortKey.updatedAt,
    direction: AgentDirectorySortDirection.desc,
  ),
];

/// The agents and synthetic workspaces derived from one legacy directory fetch.
///
/// Agents are keyed by agent id in fetch order. Upstream's `agents` map holds
/// its store `Agent`; the ported map holds [AgentDirectoryEntry], which is this
/// repo's equivalent record (a decoded [AgentSummary] plus the raw project
/// placement payload).
final class LegacyDaemonWorkspaceSnapshot {
  const LegacyDaemonWorkspaceSnapshot({
    required this.agents,
    required this.workspaces,
  });

  final Map<String, AgentDirectoryEntry> agents;
  final Map<String, WorkspaceDescriptor> workspaces;
}

/// A [LegacyDaemonWorkspaceSnapshot] plus the subscription the fetch opened.
final class LegacyDaemonWorkspaceFetchResult
    extends LegacyDaemonWorkspaceSnapshot {
  const LegacyDaemonWorkspaceFetchResult({
    required super.agents,
    required super.workspaces,
    required this.subscriptionId,
  });

  final String? subscriptionId;
}

/// The raw pages a legacy directory read accumulated, before any store write.
final class LegacyDaemonWorkspaceDirectoryReadResult {
  const LegacyDaemonWorkspaceDirectoryReadResult({
    required this.entries,
    required this.subscriptionId,
  });

  final List<AgentDirectoryEntry> entries;
  final String? subscriptionId;
}

/// The subscribe request forwarded on the *first* page of a legacy read.
final class LegacyDaemonSubscribeOptions {
  const LegacyDaemonSubscribeOptions({this.subscriptionId});

  final String? subscriptionId;
}

/// Where a legacy read starts and how big its pages are.
final class LegacyDaemonPageOptions {
  const LegacyDaemonPageOptions({this.limit, this.cursor});

  /// Defaults to 200 when omitted, matching upstream.
  final int? limit;
  final String? cursor;
}

/// One page of a legacy `fetchAgents` call.
final class LegacyDaemonAgentsPage {
  const LegacyDaemonAgentsPage({
    required this.entries,
    required this.pageInfo,
    this.subscriptionId,
  });

  final List<AgentDirectoryEntry> entries;
  final LegacyDaemonPageInfo pageInfo;
  final String? subscriptionId;
}

/// Pagination cursors, as a *union of two spellings*.
///
/// Upstream casts `pageInfo` to a loose shape and probes for `hasMore` then
/// `hasMoreAfter`, and `nextCursor` then `afterCursor` — old and new daemons
/// disagree on the field names and the shim has to accept both. Modelling all
/// four as nullable fields reproduces that exactly: a JS field that is absent and
/// one that is explicitly `null` both fail `typeof x === "boolean"` / `=== "string"`
/// and fall through to the alternative spelling, which is precisely what `null`
/// does here.
final class LegacyDaemonPageInfo {
  const LegacyDaemonPageInfo({
    this.hasMore,
    this.hasMoreAfter,
    this.nextCursor,
    this.afterCursor,
  });

  /// Bridges the protocol's own page info, which only speaks the modern
  /// spelling, into the loose shape this shim probes.
  factory LegacyDaemonPageInfo.fromAgentDirectory(
    AgentDirectoryPageInfo pageInfo,
  ) => LegacyDaemonPageInfo(
    hasMore: pageInfo.hasMore,
    nextCursor: pageInfo.nextCursor,
  );

  final bool? hasMore;
  final bool? hasMoreAfter;
  final String? nextCursor;
  final String? afterCursor;
}

/// Upstream's `Pick<DaemonClient, "fetchAgents">`, narrowed to the one call the
/// shim makes so no caller has to hand over a whole client.
typedef LegacyDaemonFetchAgents =
    Future<LegacyDaemonAgentsPage> Function({
      required List<AgentDirectorySort> sort,
      required int limit,
      String? cursor,
      LegacyDaemonSubscribeOptions? subscribe,
    });

/// The session-store reads and writes the shim performs.
///
/// Upstream reaches `useSessionStore.getState()` directly from module scope.
/// This repo has no single session store — the equivalent state is spread across
/// Riverpod notifiers — so the four reads and four writes are declared as a port
/// the caller supplies. That also makes the store-touching functions testable
/// without standing up providers, which is how upstream's own suite has to work
/// around the global store.
///
/// Every read is total: upstream's `session?.agents.get(id)` treats a missing
/// session the same as an empty one, so an absent session returns an empty map
/// rather than null. [readServerInfo] is the exception, because
/// [shouldUseLegacyDaemonWorkspaceDirectory] and the backfill guard genuinely
/// disagree about what a missing server info means.
abstract interface class LegacyDaemonWorkspaceStore {
  /// Null when the session is unknown or has not received `server_info` yet.
  ServerInfoStatus? readServerInfo(String serverId);

  /// The agent directory replica for a host, keyed by agent id.
  Map<String, AgentDirectoryEntry> readAgents(String serverId);

  /// Detail records for agents opened individually, keyed by agent id. Consulted
  /// only as a fallback when the directory replica has not seen the agent.
  Map<String, AgentDirectoryEntry> readAgentDetails(String serverId);

  /// The workspace registry for a host, keyed by workspace id.
  Map<String, WorkspaceDescriptor> readWorkspaces(String serverId);

  /// Upstream `replaceFetchedAgentDirectory`: swap the whole replica.
  void replaceAgentDirectory({
    required String serverId,
    required Map<String, AgentDirectoryEntry> agents,
  });

  void setWorkspaces(
    String serverId,
    Map<String, WorkspaceDescriptor> workspaces,
  );

  void setEmptyProjects(
    String serverId,
    List<WorkspaceProjectDescriptor> emptyProjects,
  );

  void setHasHydratedWorkspaces(String serverId, bool hasHydrated);
}

/// Whether this host needs the legacy cwd -> workspace shim for its *directory
/// listing*.
///
/// A host we have heard nothing from yet answers false: there is no listing to
/// build, and guessing would strand real workspace rows behind synthetic ones.
/// Contrast [_shouldBackfillLegacyDaemonWorkspaceDirectory], which answers true
/// in that case — an unknown host is worth one speculative backfill, because the
/// alternative is an empty sidebar.
bool shouldUseLegacyDaemonWorkspaceDirectory(ServerInfoStatus? serverInfo) =>
    serverInfo != null && serverInfo.features['workspaceMultiplicity'] != true;

/// Upstream `shouldBackfillLegacyDaemonWorkspaceDirectory` — note the missing
/// null check relative to [shouldUseLegacyDaemonWorkspaceDirectory]. The
/// asymmetry is upstream's and is load-bearing; see that function's doc.
bool _shouldBackfillLegacyDaemonWorkspaceDirectory(
  ServerInfoStatus? serverInfo,
) => serverInfo?.features['workspaceMultiplicity'] != true;

/// Builds the agents and synthetic workspaces for a legacy directory payload,
/// without touching any store.
///
/// The entries are stamped first so both halves agree on which workspace id each
/// agent belongs to.
LegacyDaemonWorkspaceSnapshot buildLegacyDaemonWorkspaceSnapshot({
  required String serverId,
  required List<AgentDirectoryEntry> entries,
}) {
  final stamped = stampLegacyWorkspaceIds(entries);
  return LegacyDaemonWorkspaceSnapshot(
    agents: _indexAgentsById(stamped),
    workspaces: buildLegacyWorkspaces(stamped),
  );
}

/// Upstream `buildAgentDirectoryState(...).agents`.
///
/// That helper lives in `utils/agent-directory-sync.ts`, which is outside this
/// port's cluster; the parts of it this shim can observe are exactly "key the
/// entries by agent id, last write wins, insertion-ordered". Decoding and
/// snapshot normalization already happened in `PaseoAgentSnapshotCodec` by the
/// time an [AgentDirectoryEntry] exists, so there is nothing else to reproduce.
Map<String, AgentDirectoryEntry> _indexAgentsById(
  List<AgentDirectoryEntry> entries,
) {
  final agents = <String, AgentDirectoryEntry>{};
  for (final entry in entries) {
    agents[entry.agent.agentId] = entry;
  }
  return agents;
}

/// Reads the whole legacy directory and writes it to [store].
///
/// Throws when the read was cancelled, because a caller that did not pass an
/// `isCancelled` predicate has no way to handle a null and would otherwise
/// silently install an empty directory.
Future<LegacyDaemonWorkspaceFetchResult> fetchLegacyDaemonWorkspaceDirectory({
  required LegacyDaemonFetchAgents fetchAgents,
  required LegacyDaemonWorkspaceStore store,
  required String serverId,
  LegacyDaemonSubscribeOptions? subscribe,
  LegacyDaemonPageOptions? page,
}) async {
  final directory = await readLegacyDaemonWorkspaceDirectory(
    fetchAgents: fetchAgents,
    subscribe: subscribe,
    page: page,
  );
  if (directory == null) {
    throw StateError('Legacy daemon workspace directory fetch was cancelled.');
  }
  final snapshot = replaceLegacyDaemonWorkspaceDirectory(
    store: store,
    serverId: serverId,
    entries: directory.entries,
  );
  return LegacyDaemonWorkspaceFetchResult(
    agents: snapshot.agents,
    workspaces: snapshot.workspaces,
    subscriptionId: directory.subscriptionId,
  );
}

/// Synthesizes a workspace directory from the agent list, but only when there is
/// nothing to lose.
///
/// Returns whether the legacy path *claimed* this hydration — true even when the
/// read was cancelled or wrote nothing, so the caller does not then run the
/// modern path over the same host. Returns false only when the shim declined:
/// either the store already has rows, or the daemon is new enough to have a real
/// registry.
///
/// [workspaces] and [emptyProjects] are only counted, never read, which is why
/// upstream types them as `ReadonlyMap<unknown, unknown>`; `Map<String, Object?>`
/// is the Dart equivalent and accepts any string-keyed map by covariance.
Future<bool> backfillLegacyDaemonWorkspaceDirectoryIfEmpty({
  required LegacyDaemonFetchAgents fetchAgents,
  required LegacyDaemonWorkspaceStore store,
  required String serverId,
  required Map<String, Object?> workspaces,
  required Map<String, Object?> emptyProjects,
  bool Function()? isCancelled,
}) async {
  if (workspaces.isNotEmpty || emptyProjects.isNotEmpty) {
    return false;
  }
  if (!_shouldBackfillLegacyDaemonWorkspaceDirectory(
    store.readServerInfo(serverId),
  )) {
    return false;
  }
  if (isCancelled?.call() ?? false) {
    return true;
  }
  final directory = await readLegacyDaemonWorkspaceDirectory(
    fetchAgents: fetchAgents,
    isCancelled: isCancelled,
  );
  // Re-checked after the await: hydration may have been superseded while the
  // pages were in flight, and writing then would clobber the newer directory.
  if (directory == null || (isCancelled?.call() ?? false)) {
    return true;
  }
  replaceLegacyDaemonWorkspaceDirectory(
    store: store,
    serverId: serverId,
    entries: directory.entries,
  );
  return true;
}

/// Pages through the whole agent directory, or returns null if cancelled.
///
/// Subscription handling is why this cannot be a plain `for` loop: `subscribe` is
/// sent on the first request only, and the subscription id the daemon hands back
/// on that first page is the one kept — later pages either repeat it or omit it.
///
/// The loop stops on the first page that reports no more results *or* returns no
/// usable cursor, so a daemon that says "more" but cannot say where terminates
/// instead of refetching page one forever. An empty-string cursor counts as no
/// cursor, matching JS falsiness.
Future<LegacyDaemonWorkspaceDirectoryReadResult?>
readLegacyDaemonWorkspaceDirectory({
  required LegacyDaemonFetchAgents fetchAgents,
  LegacyDaemonSubscribeOptions? subscribe,
  LegacyDaemonPageOptions? page,
  bool Function()? isCancelled,
}) async {
  final entries = <AgentDirectoryEntry>[];
  var cursor = page?.cursor;
  var includeSubscribe = true;
  String? subscriptionId;
  final pageLimit = page?.limit ?? 200;

  while (true) {
    if (isCancelled?.call() ?? false) {
      return null;
    }

    final payload = await fetchAgents(
      sort: legacyAgentDirectorySort,
      limit: pageLimit,
      cursor: cursor,
      subscribe: includeSubscribe ? subscribe : null,
    );
    if (isCancelled?.call() ?? false) {
      return null;
    }

    entries.addAll(payload.entries);
    subscriptionId ??= payload.subscriptionId;
    includeSubscribe = false;
    if (!_readFetchAgentsHasMore(payload.pageInfo)) {
      break;
    }
    final nextCursor = _readFetchAgentsNextCursor(payload.pageInfo);
    if (nextCursor == null || nextCursor.isEmpty) {
      break;
    }
    cursor = nextCursor;
  }

  return LegacyDaemonWorkspaceDirectoryReadResult(
    entries: entries,
    subscriptionId: subscriptionId,
  );
}

/// Attaches a synthetic workspace id to an agent update that arrived without one.
///
/// Old daemons keep sending workspace-less agent updates after hydration, and an
/// unowned agent silently disappears from every workspace view. The id is taken
/// from whatever the client already believed about this agent, falling back to
/// matching its cwd against a known workspace.
///
/// Returns [entry] untouched when it already has an owner, when the daemon is new
/// enough to own agents itself, or when no id could be derived.
///
/// Deviation: upstream's store `Agent` carries an optional `projectPlacement`,
/// and the merge is `agent.projectPlacement ?? existingAgent?.projectPlacement`.
/// [AgentDirectoryEntry.project] is non-nullable here, so "absent" is spelled as
/// the empty map — the one value a real daemon never sends, since the placement
/// payload always carries at least a `projectKey`.
AgentDirectoryEntry applyLegacyDaemonWorkspaceOwnership({
  required LegacyDaemonWorkspaceStore store,
  required String serverId,
  required AgentDirectoryEntry entry,
}) {
  // JS truthiness: an empty-string workspaceId is treated as unowned.
  final existingOwner = entry.agent.workspaceId;
  if (existingOwner != null && existingOwner.isNotEmpty) {
    return entry;
  }

  if (!_shouldBackfillLegacyDaemonWorkspaceDirectory(
    store.readServerInfo(serverId),
  )) {
    return entry;
  }

  final agentId = entry.agent.agentId;
  final existingEntry =
      store.readAgents(serverId)[agentId] ??
      store.readAgentDetails(serverId)[agentId];
  // `??` here is nullish, not falsy: an existing empty-string workspaceId wins
  // the coalesce and then fails the guard below, leaving the entry unchanged.
  final workspaceId =
      existingEntry?.agent.workspaceId ??
      _resolveLegacyWorkspaceIdFromAgent(
        entry.agent,
        store.readWorkspaces(serverId),
      );
  if (workspaceId == null || workspaceId.isEmpty) {
    return entry;
  }

  return AgentDirectoryEntry(
    agent: entry.agent.copyWith(workspaceId: workspaceId),
    project: entry.project.isNotEmpty
        ? entry.project
        : (existingEntry?.project ?? entry.project),
    pendingPermissions: entry.pendingPermissions,
  );
}

/// Installs a freshly fetched legacy directory, replacing whatever was there.
///
/// The empty-projects list is cleared unconditionally: a legacy daemon has no
/// concept of a project without workspaces, so anything still in that list is
/// stale state from a previous connection.
LegacyDaemonWorkspaceSnapshot replaceLegacyDaemonWorkspaceDirectory({
  required LegacyDaemonWorkspaceStore store,
  required String serverId,
  required List<AgentDirectoryEntry> entries,
}) {
  final stamped = stampLegacyWorkspaceIds(entries);
  final agents = _indexAgentsById(stamped);
  final workspaces = buildLegacyWorkspaces(stamped);
  store.replaceAgentDirectory(serverId: serverId, agents: agents);
  store.setWorkspaces(serverId, workspaces);
  store.setEmptyProjects(serverId, const []);
  store.setHasHydratedWorkspaces(serverId, true);
  return LegacyDaemonWorkspaceSnapshot(agents: agents, workspaces: workspaces);
}

bool _readFetchAgentsHasMore(LegacyDaemonPageInfo pageInfo) {
  if (pageInfo.hasMore != null) {
    return pageInfo.hasMore!;
  }
  if (pageInfo.hasMoreAfter != null) {
    return pageInfo.hasMoreAfter!;
  }
  return false;
}

String? _readFetchAgentsNextCursor(LegacyDaemonPageInfo pageInfo) {
  if (pageInfo.nextCursor != null) {
    return pageInfo.nextCursor;
  }
  if (pageInfo.afterCursor != null) {
    return pageInfo.afterCursor;
  }
  return null;
}

/// Rewrites every entry's `workspaceId` to the id its checkout directory maps to.
///
/// Unconditional: an id the legacy daemon invented is not trustworthy, and the
/// whole point of the shim is that directory paths are the only stable identity
/// available.
List<AgentDirectoryEntry> stampLegacyWorkspaceIds(
  List<AgentDirectoryEntry> entries,
) => [
  for (final entry in entries)
    AgentDirectoryEntry(
      agent: entry.agent.copyWith(
        workspaceId: _resolveLegacyWorkspaceId(entry),
      ),
      project: entry.project,
      pendingPermissions: entry.pendingPermissions,
    ),
];

/// Collapses an agent list into one synthetic workspace row per checkout.
///
/// Several agents commonly share a directory, so the row has to pick one status
/// to show. It shows the most *demanding* one — the priority order in
/// [getWorkspaceStateBucketPriority] runs needs-input first — because a row that
/// reported "done" while one of its agents was blocked on a permission prompt
/// would hide the prompt entirely.
///
/// Only status and its timestamp are taken from the winning agent; the name,
/// project and git runtime stay with the first entry seen for that workspace, so
/// the row's identity does not flicker as statuses change.
Map<String, WorkspaceDescriptor> buildLegacyWorkspaces(
  List<AgentDirectoryEntry> entries,
) {
  final workspaces = <String, WorkspaceDescriptor>{};
  for (final entry in entries) {
    // Nullish, not falsy: an explicitly empty workspaceId keys its own row.
    final workspaceId =
        entry.agent.workspaceId ?? _resolveLegacyWorkspaceId(entry);
    final status = deriveAgentStateBucket(
      status: entry.agent.runState,
      pendingPermissionCount: entry.pendingPermissions.length,
      requiresAttention: entry.agent.requiresAttention,
      attentionReason: entry.agent.attentionReason,
    );
    final statusEnteredAt = _parseLegacyAgentTimestamp(entry);
    final existing = workspaces[workspaceId];
    if (existing == null) {
      workspaces[workspaceId] = _createLegacyWorkspace(
        entry,
        status,
        statusEnteredAt,
      );
      continue;
    }
    if (getWorkspaceStateBucketPriority(status) <
        getWorkspaceStateBucketPriority(existing.status)) {
      workspaces[workspaceId] = _copyWorkspaceStatus(
        existing,
        status,
        statusEnteredAt,
      );
    }
  }
  return workspaces;
}

/// Upstream's `{ ...existing, status, statusEnteredAt }` spread. Written out
/// because [WorkspaceDescriptor] has no `copyWith` and this port may not add one.
WorkspaceDescriptor _copyWorkspaceStatus(
  WorkspaceDescriptor existing,
  WorkspaceStateBucket status,
  String? statusEnteredAt,
) => WorkspaceDescriptor(
  id: existing.id,
  projectId: existing.projectId,
  projectDisplayName: existing.projectDisplayName,
  projectCustomName: existing.projectCustomName,
  projectRootPath: existing.projectRootPath,
  workspaceDirectory: existing.workspaceDirectory,
  projectKind: existing.projectKind,
  workspaceKind: existing.workspaceKind,
  name: existing.name,
  title: existing.title,
  pinnedAt: existing.pinnedAt,
  archivingAt: existing.archivingAt,
  status: status,
  statusEnteredAt: statusEnteredAt,
  activityAt: existing.activityAt,
  diffStat: existing.diffStat,
  scripts: existing.scripts,
  gitRuntime: existing.gitRuntime,
  githubRuntime: existing.githubRuntime,
  forge: existing.forge,
  project: existing.project,
);

WorkspaceDescriptor _createLegacyWorkspace(
  AgentDirectoryEntry entry,
  WorkspaceStateBucket status,
  String? statusEnteredAt,
) {
  final workspaceDirectory = _resolveLegacyWorkspaceId(entry);
  final checkout = _checkoutOf(entry);
  final isGit = _isTrue(checkout, 'isGit');
  final projectRootPath =
      _normalizeWorkspacePath(
        _string(checkout, 'mainRepoRoot') ??
            _string(checkout, 'worktreeRoot') ??
            _string(checkout, 'cwd'),
      ) ??
      workspaceDirectory;
  return WorkspaceDescriptor(
    id: workspaceDirectory,
    projectId: _requiredProjectString(entry, 'projectKey'),
    projectDisplayName: _requiredProjectString(entry, 'projectName'),
    projectCustomName: null,
    projectRootPath: projectRootPath,
    workspaceDirectory: workspaceDirectory,
    projectKind: isGit ? WorkspaceProjectKind.git : WorkspaceProjectKind.nonGit,
    workspaceKind: _resolveLegacyWorkspaceKind(checkout),
    name: _resolveLegacyWorkspaceName(entry, workspaceDirectory),
    title: null,
    status: status,
    statusEnteredAt: statusEnteredAt,
    // Upstream's object literal has no `activityAt`; the field is required by
    // this repo's descriptor, and `null` is the same absence.
    activityAt: null,
    archivingAt: null,
    diffStat: null,
    scripts: const [],
    gitRuntime: isGit
        ? WorkspaceGitRuntime(
            currentBranch: _string(checkout, 'currentBranch'),
            remoteUrl: _string(checkout, 'remoteUrl'),
            isPaseoOwnedWorktree: _nullableBool(
              checkout,
              'isPaseoOwnedWorktree',
            ),
            isDirty: null,
            aheadBehind: null,
            aheadOfOrigin: null,
            behindOfOrigin: null,
          )
        : null,
    githubRuntime: null,
    project: entry.project,
  );
}

/// A non-git checkout is a plain directory; a git one is a Paseo-owned worktree
/// or an ordinary checkout the user pointed us at.
WorkspaceKind _resolveLegacyWorkspaceKind(Map<String, Object?> checkout) {
  if (!_isTrue(checkout, 'isGit')) {
    return WorkspaceKind.directory;
  }
  if (_isTrue(checkout, 'isPaseoOwnedWorktree')) {
    return WorkspaceKind.worktree;
  }
  return WorkspaceKind.checkout;
}

/// The synthetic workspace id for an entry: its normalized checkout directory,
/// then its normalized agent cwd, then the raw cwd.
///
/// The raw-cwd fallback exists so a cwd that normalizes to nothing (whitespace)
/// still produces a key rather than dropping the agent on the floor.
String _resolveLegacyWorkspaceId(AgentDirectoryEntry entry) =>
    _normalizeWorkspacePath(_string(_checkoutOf(entry), 'cwd')) ??
    _normalizeWorkspacePath(entry.agent.cwd) ??
    entry.agent.cwd;

/// Finds the workspace an unowned agent belongs to by matching directories.
///
/// Falls back to the normalized cwd itself, because [buildLegacyWorkspaces] keys
/// its rows by exactly that — an agent in a directory we have not seen a row for
/// yet will match once the row appears.
String? _resolveLegacyWorkspaceIdFromAgent(
  AgentSummary agent,
  Map<String, WorkspaceDescriptor> workspaces,
) {
  final cwd = _normalizeWorkspacePath(agent.cwd);
  if (cwd == null) {
    return null;
  }

  for (final workspace in workspaces.values) {
    if (_normalizeWorkspacePath(workspace.workspaceDirectory) == cwd) {
      return workspace.id;
    }
  }

  return cwd;
}

/// The row label: the daemon's own workspace name, else the branch, else the
/// directory's last segment.
///
/// A detached HEAD is skipped explicitly — `"HEAD"` is a worse label than the
/// directory name it would replace.
String _resolveLegacyWorkspaceName(
  AgentDirectoryEntry entry,
  String workspaceDirectory,
) {
  final explicitName = _string(entry.project, 'workspaceName')?.trim();
  if (explicitName != null && explicitName.isNotEmpty) {
    return explicitName;
  }
  final branchName = _string(_checkoutOf(entry), 'currentBranch')?.trim();
  if (branchName != null && branchName.isNotEmpty && branchName != 'HEAD') {
    return branchName;
  }
  return _workspaceDirectoryName(workspaceDirectory);
}

/// The last path segment, tolerating either separator.
///
/// Only forward slashes are stripped from the tail, matching upstream's
/// `/[/]+$/g`; a Windows path ending in a backslash keeps it and yields the
/// empty string, exactly as upstream does.
String _workspaceDirectoryName(String directory) {
  final trimmed = directory.trim().replaceFirst(RegExp(r'/+$'), '');
  final separator = trimmed.lastIndexOf('/') > trimmed.lastIndexOf(r'\')
      ? trimmed.lastIndexOf('/')
      : trimmed.lastIndexOf(r'\');
  return separator >= 0 ? trimmed.substring(separator + 1) : trimmed;
}

/// When the winning agent entered its status: its attention timestamp if it has
/// one, else its last update. Unparseable values become null rather than
/// propagating an invalid instant into the row.
///
/// Deviation: upstream parses to a `Date`, but [WorkspaceDescriptor.statusEnteredAt]
/// is an ISO string in this repo, so the original text is kept once it has been
/// proven parseable. Two knock-on differences, both unreachable for daemon-emitted
/// payloads, which are always full ISO-8601: JavaScript's `new Date` accepts
/// looser formats than [DateTime.tryParse] (so `"Jun 18 2026"` becomes null
/// here), and a date-only string is UTC midnight in JavaScript but local midnight
/// when Dart later parses it back.
String? _parseLegacyAgentTimestamp(AgentDirectoryEntry entry) {
  final value = entry.agent.attentionTimestamp ?? entry.agent.updatedAt;
  // JS `!value` — the empty string is as absent as null.
  if (value == null || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value) == null ? null : value;
}

// --- Untyped project-payload readers ---------------------------------------
//
// Upstream reads `entry.project.checkout.cwd` and friends off a structurally
// typed object. This repo carries the agent-directory project payload as an
// untyped `Map<String, Object?>` (see `AgentDirectoryEntry.project`), so the
// same fields are read through these guards. A value of the wrong runtime type
// reads as absent instead of flowing through as JavaScript would; the daemon's
// `buildAgentProjectPlacement` is the only producer and always emits the
// declared shape, so the difference is unreachable in practice.

Map<String, Object?> _checkoutOf(AgentDirectoryEntry entry) {
  final checkout = entry.project['checkout'];
  return checkout is Map
      ? Map<String, Object?>.from(checkout)
      : const <String, Object?>{};
}

String? _string(Map<String, Object?> map, String key) {
  final value = map[key];
  return value is String ? value : null;
}

/// For fields upstream types as required strings but this repo's descriptor
/// needs non-null. The empty string stands in for a malformed payload.
String _requiredProjectString(AgentDirectoryEntry entry, String key) =>
    _string(entry.project, key) ?? '';

bool _isTrue(Map<String, Object?> map, String key) => map[key] == true;

bool? _nullableBool(Map<String, Object?> map, String key) {
  final value = map[key];
  return value is bool ? value : null;
}
