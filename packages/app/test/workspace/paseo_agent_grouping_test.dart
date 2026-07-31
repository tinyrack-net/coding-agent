// Port of the frozen Paseo 0.2.0 suites
// `packages/app/src/utils/agent-grouping.test.ts` and
// `packages/app/src/workspace/legacy-daemon-workspaces.test.ts`.
//
// Every upstream case appears below under the same public symbol. Cases marked
// `// extra:` are not in the upstream suites — they pin behavior the frozen
// modules have but never assert (JS truthiness vs. nullish coalescing, sort
// stability, the pageInfo field-name union, calendar-day boundaries, and the
// per-project cap).

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/workspace/paseo_agent_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Clock
// ---------------------------------------------------------------------------

/// Local (not UTC) so the calendar-day arithmetic under test is independent of
/// the machine's timezone. Mid-June is clear of every common DST transition, as
/// is the mid-May date the "older" cases reach back to.
final DateTime now = DateTime(2026, 6, 18, 12);

DateTime daysBefore(int days) => now.subtract(Duration(days: days));

DateTime hoursBefore(int hours) => now.subtract(Duration(hours: hours));

// ---------------------------------------------------------------------------
// Builders — the Dart analogues of the upstream suites' `makeAgent()` and
// `legacyAgent()` fixtures.
// ---------------------------------------------------------------------------

const String defaultUpdatedAt = '2026-06-18T10:00:00.000Z';

AgentSummary summary(
  String id, {
  String cwd = '/tmp/repo',
  AgentRunState runState = AgentRunState.running,
  bool requiresAttention = false,
  AgentAttentionReason? attentionReason,
  String? attentionTimestamp,
  String? archivedAt,
  String? workspaceId,
  String? updatedAt = defaultUpdatedAt,
}) => AgentSummary(
  agentId: id,
  title: '',
  cwd: cwd,
  provider: 'mock',
  model: '',
  mode: AgentMode.normal,
  runState: runState,
  createdAtMs: 0,
  updatedAt: updatedAt,
  workspaceId: workspaceId,
  requiresAttention: requiresAttention,
  attentionReason: attentionReason,
  attentionTimestamp: attentionTimestamp,
  archivedAt: archivedAt,
);

AggregatedAgent agent(
  String id, {
  String cwd = '/tmp/repo',
  AgentRunState status = AgentRunState.running,
  DateTime? lastActivityAt,
  bool requiresAttention = false,
  int? pendingPermissionCount,
  String? archivedAt,
}) => AggregatedAgent(
  agent: summary(
    id,
    cwd: cwd,
    runState: status,
    requiresAttention: requiresAttention,
    archivedAt: archivedAt,
  ),
  lastActivityAt: lastActivityAt ?? now,
  pendingPermissionCount: pendingPermissionCount,
);

/// Upstream's `legacyAgent()` fixture, including its `project` payload.
AgentDirectoryEntry legacyAgent({
  required String id,
  required String cwd,
  AgentRunState status = AgentRunState.idle,
  String? updatedAt = defaultUpdatedAt,
  String? attentionTimestamp,
  bool requiresAttention = false,
  AgentAttentionReason? attentionReason,
  String? workspaceId,
  String? projectKey = '/repo',
  String? projectName = 'repo',
  String? workspaceName = 'app',
  bool includeCheckout = true,
  bool isGit = true,
  String? currentBranch = 'main',
  String? remoteUrl = 'git@example.com:repo/app.git',
  String? worktreeRoot,
  bool isPaseoOwnedWorktree = false,
  String? mainRepoRoot = '/repo',
  List<Map<String, Object?>> pendingPermissions = const [],
}) => AgentDirectoryEntry(
  agent: summary(
    id,
    cwd: cwd,
    runState: status,
    updatedAt: updatedAt,
    attentionTimestamp: attentionTimestamp,
    requiresAttention: requiresAttention,
    attentionReason: attentionReason,
    workspaceId: workspaceId,
  ),
  project: {
    'projectKey': ?projectKey,
    'projectName': ?projectName,
    'workspaceName': ?workspaceName,
    if (includeCheckout)
      'checkout': {
        'cwd': cwd,
        'isGit': isGit,
        'currentBranch': currentBranch,
        'remoteUrl': remoteUrl,
        'worktreeRoot': worktreeRoot ?? cwd,
        'isPaseoOwnedWorktree': isPaseoOwnedWorktree,
        'mainRepoRoot': mainRepoRoot,
      },
  },
  pendingPermissions: pendingPermissions,
);

const String serverId = 'srv_legacy';

ServerInfoStatus serverInfo({Map<String, bool> features = const {}}) =>
    ServerInfoStatus(
      serverId: serverId,
      hostname: null,
      version: '0.1.96',
      desktopManaged: false,
      features: features,
    );

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Stands in for upstream's global `useSessionStore`. Single-host, because every
/// call site is already scoped to one server id; the ids it is handed are
/// recorded so a mis-scoped write would still be visible.
final class _FakeStore implements LegacyDaemonWorkspaceStore {
  ServerInfoStatus? serverInfoStatus;
  Map<String, AgentDirectoryEntry> agents = const {};
  Map<String, AgentDirectoryEntry> agentDetails = const {};
  Map<String, WorkspaceDescriptor> workspaces = const {};
  List<WorkspaceProjectDescriptor>? emptyProjects;
  bool? hasHydratedWorkspaces;
  final List<String> writtenServerIds = [];

  @override
  ServerInfoStatus? readServerInfo(String serverId) => serverInfoStatus;

  @override
  Map<String, AgentDirectoryEntry> readAgents(String serverId) => agents;

  @override
  Map<String, AgentDirectoryEntry> readAgentDetails(String serverId) =>
      agentDetails;

  @override
  Map<String, WorkspaceDescriptor> readWorkspaces(String serverId) =>
      workspaces;

  @override
  void replaceAgentDirectory({
    required String serverId,
    required Map<String, AgentDirectoryEntry> agents,
  }) {
    writtenServerIds.add(serverId);
    this.agents = agents;
  }

  @override
  void setWorkspaces(
    String serverId,
    Map<String, WorkspaceDescriptor> workspaces,
  ) {
    this.workspaces = workspaces;
  }

  @override
  void setEmptyProjects(
    String serverId,
    List<WorkspaceProjectDescriptor> emptyProjects,
  ) {
    this.emptyProjects = emptyProjects;
  }

  @override
  void setHasHydratedWorkspaces(String serverId, bool hasHydrated) {
    hasHydratedWorkspaces = hasHydrated;
  }
}

typedef _FetchCall = ({
  List<AgentDirectorySort> sort,
  int limit,
  String? cursor,
  LegacyDaemonSubscribeOptions? subscribe,
});

/// Replays a scripted list of pages, repeating the last one if asked for more.
final class _FakeFetchAgents {
  _FakeFetchAgents(this.pages, {this.onFetch});

  final List<LegacyDaemonAgentsPage> pages;
  final void Function()? onFetch;
  final List<_FetchCall> calls = [];

  Future<LegacyDaemonAgentsPage> call({
    required List<AgentDirectorySort> sort,
    required int limit,
    String? cursor,
    LegacyDaemonSubscribeOptions? subscribe,
  }) async {
    calls.add((sort: sort, limit: limit, cursor: cursor, subscribe: subscribe));
    onFetch?.call();
    final page =
        pages[calls.length - 1 < pages.length
            ? calls.length - 1
            : pages.length - 1];
    return page;
  }
}

LegacyDaemonAgentsPage page(
  List<AgentDirectoryEntry> entries, {
  bool? hasMore,
  bool? hasMoreAfter,
  String? nextCursor,
  String? afterCursor,
  String? subscriptionId,
}) => LegacyDaemonAgentsPage(
  entries: entries,
  subscriptionId: subscriptionId,
  pageInfo: LegacyDaemonPageInfo(
    hasMore: hasMore,
    hasMoreAfter: hasMoreAfter,
    nextCursor: nextCursor,
    afterCursor: afterCursor,
  ),
);

WorkspaceDescriptor workspaceDescriptor({
  required String id,
  required String workspaceDirectory,
}) => WorkspaceDescriptor(
  id: id,
  projectId: '/repo',
  projectDisplayName: 'repo',
  projectRootPath: '/repo',
  workspaceDirectory: workspaceDirectory,
  projectKind: WorkspaceProjectKind.git,
  workspaceKind: WorkspaceKind.checkout,
  name: 'app',
  status: WorkspaceStateBucket.done,
  activityAt: null,
);

void main() {
  // =========================================================================
  // utils/agent-grouping.ts
  // =========================================================================

  group('deriveProjectKey', () {
    // extra: the worktree collapse is the whole reason this function exists.
    test('returns the parent repo for a Paseo-owned worktree', () {
      expect(
        deriveProjectKey('/Users/me/dev/paseo/.paseo/worktrees/fix-1'),
        '/Users/me/dev/paseo',
      );
    });

    // extra: upstream's `/\/$/` is non-global, so only one slash comes off.
    test('strips exactly one trailing slash before the marker', () {
      expect(
        deriveProjectKey('/Users/me/dev/paseo//.paseo/worktrees/fix-1'),
        '/Users/me/dev/paseo/',
      );
    });

    // extra:
    test('returns the cwd unchanged when there is no worktree marker', () {
      expect(deriveProjectKey('/Users/me/dev/paseo'), '/Users/me/dev/paseo');
    });

    // extra: an empty prefix is preserved rather than becoming a slash.
    test('returns the empty string when the cwd starts with the marker', () {
      expect(deriveProjectKey('.paseo/worktrees/fix-1'), '');
    });
  });

  group('deriveRemoteProjectKey', () {
    test('normalizes GitHub SSH and HTTPS to the same key', () {
      expect(
        deriveRemoteProjectKey('git@github.com:owner/repo.git'),
        'remote:github.com/owner/repo',
      );
      expect(
        deriveRemoteProjectKey('https://github.com/owner/repo'),
        'remote:github.com/owner/repo',
      );
    });

    test('includes host for non-GitHub remotes', () {
      expect(
        deriveRemoteProjectKey('git@gitlab.example.com:group/repo.git'),
        'remote:gitlab.example.com/group/repo',
      );
    });

    // extra: `null` and `""` are both falsy upstream.
    test('returns null for a missing or blank remote', () {
      expect(deriveRemoteProjectKey(null), isNull);
      expect(deriveRemoteProjectKey(''), isNull);
      expect(deriveRemoteProjectKey('   '), isNull);
    });

    // extra:
    test('accepts the ssh:// URL spelling', () {
      expect(
        deriveRemoteProjectKey('ssh://git@github.com/owner/repo.git'),
        'remote:github.com/owner/repo',
      );
    });

    // extra: the scp-like branch is tried first, so a port becomes a path
    // segment. Preserved deliberately.
    test('reads an scp-style port as a leading path segment', () {
      expect(
        deriveRemoteProjectKey('ssh://git@github.com:22/owner/repo.git'),
        'remote:github.com/22/owner/repo',
      );
    });

    // extra:
    test('lowercases the host', () {
      expect(
        deriveRemoteProjectKey('HTTPS://GitHub.COM/Owner/Repo'),
        'remote:github.com/Owner/Repo',
      );
    });

    // extra: a bare repo name would collide across owners, so it is rejected.
    test('returns null when the path has no owner segment', () {
      expect(deriveRemoteProjectKey('https://github.com/repo'), isNull);
      expect(deriveRemoteProjectKey('https://github.com'), isNull);
      expect(deriveRemoteProjectKey('https://github.com/'), isNull);
    });

    // extra: an authority-less URL has a falsy hostname upstream.
    test('returns null when the URL carries no host', () {
      expect(deriveRemoteProjectKey('file:///owner/repo'), isNull);
      expect(deriveRemoteProjectKey('https:///owner/repo'), isNull);
    });

    // extra: no scheme and no `user@host:` shape means nothing to parse.
    test('returns null for a bare path', () {
      expect(deriveRemoteProjectKey('/Users/me/dev/paseo'), isNull);
    });

    // extra: any scheme is accepted; upstream never allowlists them.
    test('accepts an arbitrary scheme', () {
      expect(
        deriveRemoteProjectKey('git://host.example/owner/repo.git'),
        'remote:host.example/owner/repo',
      );
    });

    // extra: leading and trailing slashes are stripped, interior ones are not.
    test('trims surrounding slashes but keeps interior doubles', () {
      expect(
        deriveRemoteProjectKey('https://host.example//owner//repo//'),
        'remote:host.example/owner//repo',
      );
    });

    // extra: `.git` is only stripped from the tail.
    test('strips only a trailing .git', () {
      expect(
        deriveRemoteProjectKey('git@host.example:owner.git/repo'),
        'remote:host.example/owner.git/repo',
      );
    });
  });

  group('parseRepoNameFromRemoteUrl', () {
    // extra: upstream's doc-comment examples, none of which it asserts.
    test('extracts owner/repo from the documented spellings', () {
      expect(
        parseRepoNameFromRemoteUrl('git@github.com:anthropics/claude-code.git'),
        'anthropics/claude-code',
      );
      expect(
        parseRepoNameFromRemoteUrl(
          'https://github.com/anthropics/claude-code.git',
        ),
        'anthropics/claude-code',
      );
      expect(
        parseRepoNameFromRemoteUrl('https://github.com/anthropics/claude-code'),
        'anthropics/claude-code',
      );
    });

    // extra:
    test('returns null for a missing or unqualified remote', () {
      expect(parseRepoNameFromRemoteUrl(null), isNull);
      expect(parseRepoNameFromRemoteUrl(''), isNull);
      expect(parseRepoNameFromRemoteUrl('repo.git'), isNull);
    });

    // extra: unlike deriveRemoteProjectKey this never inspects the host, so a
    // non-git@ ssh user falls through the SSH branch entirely.
    test('does not strip an ssh user other than git@', () {
      expect(
        parseRepoNameFromRemoteUrl('deploy@github.com:owner/repo.git'),
        'deploy@github.com:owner/repo',
      );
    });

    // extra: deeper paths survive whole.
    test('keeps nested group paths', () {
      expect(
        parseRepoNameFromRemoteUrl('https://gitlab.example.com/a/b/c.git'),
        'a/b/c',
      );
    });
  });

  group('parseRepoShortNameFromRemoteUrl', () {
    // extra: upstream's doc-comment example.
    test('drops the owner', () {
      expect(
        parseRepoShortNameFromRemoteUrl(
          'git@github.com:anthropics/claude-code.git',
        ),
        'claude-code',
      );
    });

    // extra:
    test('returns null when the full name could not be parsed', () {
      expect(parseRepoShortNameFromRemoteUrl(null), isNull);
      expect(parseRepoShortNameFromRemoteUrl('repo'), isNull);
    });

    // extra: JS `parts[parts.length - 1] || null` — a trailing slash yields "".
    test('returns null when the last segment is empty', () {
      expect(parseRepoShortNameFromRemoteUrl('git@host:owner/'), isNull);
    });
  });

  group('deriveProjectName', () {
    // extra:
    test('returns owner/repo for a GitHub remote key', () {
      expect(
        deriveProjectName('remote:github.com/getpaseo/paseo'),
        'getpaseo/paseo',
      );
    });

    // extra: JS `|| projectKey` — an empty remainder falls back to the key.
    test('falls back to the key when the GitHub remainder is empty', () {
      expect(deriveProjectName('remote:github.com/'), 'remote:github.com/');
    });

    // extra: a non-GitHub remote key is treated as a path, so only the tail
    // survives — which is why deriveProjectDisplayName exists separately.
    test('returns the last segment for a path-like key', () {
      expect(deriveProjectName('/Users/me/dev/paseo'), 'paseo');
      expect(deriveProjectName('/Users/me/dev/paseo/'), 'paseo');
      expect(deriveProjectName('remote:gitlab.example.com/group/repo'), 'repo');
    });

    // extra:
    test('falls back to the key when there are no segments', () {
      expect(deriveProjectName('/'), '/');
      expect(deriveProjectName(''), '');
    });
  });

  group('deriveProjectDisplayName', () {
    test('shows owner/repo for GitHub remote keys', () {
      expect(
        deriveProjectDisplayName(
          projectKey: 'remote:github.com/getpaseo/paseo',
          projectName: 'paseo',
        ),
        'getpaseo/paseo',
      );
    });

    test('shows remote path for non-GitHub remote keys', () {
      expect(
        deriveProjectDisplayName(
          projectKey: 'remote:gitlab.example.com/group/repo',
          projectName: 'repo',
        ),
        'group/repo',
      );
    });

    test('falls back to projectName for local keys', () {
      expect(
        deriveProjectDisplayName(
          projectKey: '/Users/me/dev/paseo',
          projectName: 'paseo',
        ),
        'paseo',
      );
    });

    // extra: a remote key with no `/` keeps the whole remainder.
    test('keeps the whole remainder when a remote key has no path', () {
      expect(
        deriveProjectDisplayName(
          projectKey: 'remote:gitlab.example.com',
          projectName: 'ignored',
        ),
        'gitlab.example.com',
      );
    });

    // extra: a remote key whose path is blank also keeps the remainder.
    test('keeps the remainder when the remote path is blank', () {
      expect(
        deriveProjectDisplayName(
          projectKey: 'remote:gitlab.example.com/   ',
          projectName: 'ignored',
        ),
        'gitlab.example.com/   ',
      );
    });

    // extra: the cwd-tail fallback normalizes Windows separators.
    test('falls back to the cwd tail when the project name is blank', () {
      expect(
        deriveProjectDisplayName(
          projectKey: r'C:\Users\me\dev\paseo\',
          projectName: '   ',
        ),
        'paseo',
      );
    });

    // extra:
    test('falls back to the key when nothing else is usable', () {
      expect(deriveProjectDisplayName(projectKey: '/', projectName: ''), '/');
    });
  });

  group('deriveDateGroup', () {
    // extra: every bucket and both of its boundaries.
    test('files today and the future under Recent', () {
      expect(deriveDateGroup(now, now: now), AgentDateGroup.recent);
      expect(deriveDateGroup(hoursBefore(11), now: now), AgentDateGroup.recent);
      expect(
        deriveDateGroup(now.add(const Duration(days: 3)), now: now),
        AgentDateGroup.recent,
      );
    });

    // extra:
    test('files the previous calendar day under Yesterday', () {
      expect(
        deriveDateGroup(daysBefore(1), now: now),
        AgentDateGroup.yesterday,
      );
    });

    // extra: two through seven whole days.
    test('files two to seven days back under This week', () {
      expect(deriveDateGroup(daysBefore(2), now: now), AgentDateGroup.thisWeek);
      expect(deriveDateGroup(daysBefore(7), now: now), AgentDateGroup.thisWeek);
    });

    // extra: the 7/8 and 30/31 boundaries.
    test('files eight to thirty days back under This month', () {
      expect(
        deriveDateGroup(daysBefore(8), now: now),
        AgentDateGroup.thisMonth,
      );
      expect(
        deriveDateGroup(daysBefore(30), now: now),
        AgentDateGroup.thisMonth,
      );
    });

    // extra:
    test('files anything older under Older', () {
      expect(deriveDateGroup(daysBefore(31), now: now), AgentDateGroup.older);
      expect(deriveDateGroup(daysBefore(400), now: now), AgentDateGroup.older);
    });

    // extra: the enum order is upstream's `dateOrder` array, and the labels are
    // the strings upstream renders.
    test('exposes upstream labels in upstream render order', () {
      expect(AgentDateGroup.values.map((group) => group.label).toList(), [
        'Recent',
        'Yesterday',
        'This week',
        'This month',
        'Older',
      ]);
    });

    // extra: bucketing is by calendar day, not elapsed hours — one minute either
    // side of midnight changes the answer.
    test('buckets by calendar day rather than elapsed time', () {
      final midnight = DateTime(2026, 6, 18);
      expect(
        deriveDateGroup(
          midnight.subtract(const Duration(minutes: 1)),
          now: midnight.add(const Duration(minutes: 1)),
        ),
        AgentDateGroup.yesterday,
      );
    });
  });

  group('groupAgents', () {
    test('groups active agents by remote URL when available', () {
      final grouped = groupAgents(
        agents: [
          agent('a1', cwd: '/Users/me/dev/paseo'),
          agent('a2', cwd: '/Users/me/dev/paseo-fix/worktree'),
        ],
        now: now,
        getRemoteUrl: (_) => 'git@github.com:getpaseo/paseo.git',
      );

      expect(grouped.activeGroups, hasLength(1));
      expect(grouped.activeGroups[0].agents.map((a) => a.id).toList()..sort(), [
        'a1',
        'a2',
      ]);
    });

    test('falls back to cwd grouping when remote URL is unavailable', () {
      final grouped = groupAgents(
        agents: [
          agent('a1', cwd: '/Users/me/dev/paseo'),
          agent('a2', cwd: '/Users/me/dev/paseo-fix/worktree'),
        ],
        now: now,
        getRemoteUrl: (_) => null,
      );

      expect(grouped.activeGroups, hasLength(2));
    });

    // extra: no options at all is the same as an unavailable remote.
    test('falls back to cwd grouping when no remote reader is supplied', () {
      final grouped = groupAgents(
        agents: [
          agent('a1', cwd: '/Users/me/dev/paseo'),
          agent('a2', cwd: '/Users/me/dev/other'),
        ],
        now: now,
      );

      expect(grouped.activeGroups.map((group) => group.projectKey).toList(), [
        '/Users/me/dev/paseo',
        '/Users/me/dev/other',
      ]);
      expect(grouped.activeGroups[0].projectName, 'paseo');
    });

    // extra: an unresolvable remote falls back per agent, not per call.
    test('falls back to cwd for agents whose remote cannot be parsed', () {
      final grouped = groupAgents(
        agents: [
          agent('a1', cwd: '/Users/me/dev/paseo'),
          agent('a2', cwd: '/Users/me/dev/other'),
        ],
        now: now,
        getRemoteUrl: (a) =>
            a.id == 'a1' ? 'git@github.com:getpaseo/paseo.git' : 'not-a-remote',
      );

      expect(grouped.activeGroups.map((group) => group.projectKey).toList(), [
        'remote:github.com/getpaseo/paseo',
        '/Users/me/dev/other',
      ]);
    });

    // extra: worktrees of one repo collapse even with no remote at all.
    test('collapses Paseo worktrees onto the parent repo key', () {
      final grouped = groupAgents(
        agents: [
          agent('a1', cwd: '/dev/paseo'),
          agent('a2', cwd: '/dev/paseo/.paseo/worktrees/fix-1'),
        ],
        now: now,
      );

      expect(grouped.activeGroups, hasLength(1));
      expect(grouped.activeGroups[0].projectKey, '/dev/paseo');
    });

    // extra: archived agents skip the grace period entirely.
    test('files archived agents as inactive however recent they are', () {
      final grouped = groupAgents(
        agents: [
          agent('a1', archivedAt: '2026-06-18T09:00:00.000Z'),
          agent('a2'),
        ],
        now: now,
      );

      expect(grouped.activeGroups.single.agents.map((a) => a.id), ['a2']);
      expect(grouped.inactiveGroups.single.group, AgentDateGroup.recent);
      expect(grouped.inactiveGroups.single.agents.map((a) => a.id), ['a1']);
    });

    // extra: JS truthiness — an empty archivedAt is not archived.
    test('treats an empty archivedAt as not archived', () {
      final grouped = groupAgents(
        agents: [agent('a1', archivedAt: '')],
        now: now,
      );

      expect(grouped.activeGroups.single.agents.map((a) => a.id), ['a1']);
      expect(grouped.inactiveGroups, isEmpty);
    });

    // extra: the grace-period boundary is strict `<`.
    test('drops a quiet agent out of the active section at the grace edge', () {
      final justInside = groupAgents(
        agents: [
          agent(
            'a1',
            status: AgentRunState.idle,
            lastActivityAt: now.subtract(
              activeGracePeriod - const Duration(milliseconds: 1),
            ),
          ),
        ],
        now: now,
      );
      expect(justInside.activeGroups, hasLength(1));
      expect(justInside.inactiveGroups, isEmpty);

      final atEdge = groupAgents(
        agents: [
          agent(
            'a1',
            status: AgentRunState.idle,
            lastActivityAt: now.subtract(activeGracePeriod),
          ),
        ],
        now: now,
      );
      expect(atEdge.activeGroups, isEmpty);
      expect(atEdge.inactiveGroups.single.group, AgentDateGroup.thisWeek);
    });

    // extra: the three ways to be "truly active" all keep a stale agent visible.
    test('keeps stale but demanding agents in the active section', () {
      final grouped = groupAgents(
        agents: [
          agent('running', lastActivityAt: daysBefore(40), cwd: '/dev/a'),
          agent(
            'attention',
            status: AgentRunState.idle,
            requiresAttention: true,
            lastActivityAt: daysBefore(40),
            cwd: '/dev/b',
          ),
          agent(
            'permission',
            status: AgentRunState.idle,
            pendingPermissionCount: 1,
            lastActivityAt: daysBefore(40),
            cwd: '/dev/c',
          ),
          agent(
            'quiet',
            status: AgentRunState.idle,
            lastActivityAt: daysBefore(40),
            cwd: '/dev/d',
          ),
        ],
        now: now,
      );

      expect(
        grouped.activeGroups.map((group) => group.agents.single.id).toList()
          ..sort(),
        ['attention', 'permission', 'running'],
      );
      expect(grouped.inactiveGroups.single.agents.map((a) => a.id), ['quiet']);
    });

    // extra: a null pendingPermissionCount reads as zero.
    test('treats a missing pending-permission count as zero', () {
      final grouped = groupAgents(
        agents: [
          agent(
            'a1',
            status: AgentRunState.idle,
            lastActivityAt: daysBefore(40),
          ),
        ],
        now: now,
      );

      expect(grouped.activeGroups, isEmpty);
    });

    // extra: the per-project cap, and what totalCount/activeCount report.
    test('caps merely-recent agents per project but never active ones', () {
      final grouped = groupAgents(
        agents: [
          agent('run-1', lastActivityAt: hoursBefore(1)),
          agent('run-2', lastActivityAt: hoursBefore(2)),
          for (var i = 0; i < 7; i++)
            agent(
              'idle-$i',
              status: AgentRunState.idle,
              lastActivityAt: hoursBefore(10 + i),
            ),
        ],
        now: now,
      );

      final group = grouped.activeGroups.single;
      expect(group.agents, hasLength(2 + maxInactiveAgentsPerProject));
      expect(group.activeCount, 2);
      expect(group.totalCount, 9);
      expect(group.agents.map((a) => a.id).toList(), [
        'run-1',
        'run-2',
        'idle-0',
        'idle-1',
        'idle-2',
        'idle-3',
        'idle-4',
      ]);
    });

    // extra: within a group, rows interleave strictly by recency.
    test('interleaves active and recent agents by activity time', () {
      final grouped = groupAgents(
        agents: [
          agent('old-running', lastActivityAt: hoursBefore(5)),
          agent(
            'new-idle',
            status: AgentRunState.idle,
            lastActivityAt: hoursBefore(1),
          ),
        ],
        now: now,
      );

      expect(grouped.activeGroups.single.agents.map((a) => a.id), [
        'new-idle',
        'old-running',
      ]);
    });

    // extra: JS sort is stable, so ties keep input order — and a truly active
    // agent that ties with a recent one stays ahead of it.
    test('keeps ties in their original order', () {
      final tied = hoursBefore(3);
      final grouped = groupAgents(
        agents: [
          agent('idle-a', status: AgentRunState.idle, lastActivityAt: tied),
          agent('idle-b', status: AgentRunState.idle, lastActivityAt: tied),
          agent('running', lastActivityAt: tied),
        ],
        now: now,
      );

      expect(grouped.activeGroups.single.agents.map((a) => a.id), [
        'running',
        'idle-a',
        'idle-b',
      ]);
    });

    // extra: groups sort by their own most recent agent.
    test('orders project groups by their most recent agent', () {
      final grouped = groupAgents(
        agents: [
          agent('stale', cwd: '/dev/stale', lastActivityAt: hoursBefore(20)),
          agent('fresh', cwd: '/dev/fresh', lastActivityAt: hoursBefore(1)),
        ],
        now: now,
      );

      expect(grouped.activeGroups.map((group) => group.projectKey).toList(), [
        '/dev/fresh',
        '/dev/stale',
      ]);
    });

    // extra: inactive sections render in the fixed date order, skipping empties.
    test('renders inactive date groups in fixed order, newest agent first', () {
      final grouped = groupAgents(
        agents: [
          agent(
            'old',
            status: AgentRunState.idle,
            lastActivityAt: daysBefore(40),
          ),
          agent(
            'week-a',
            status: AgentRunState.idle,
            lastActivityAt: daysBefore(3),
          ),
          agent(
            'week-b',
            status: AgentRunState.idle,
            lastActivityAt: daysBefore(4),
          ),
          agent(
            'month',
            status: AgentRunState.idle,
            lastActivityAt: daysBefore(20),
          ),
        ],
        now: now,
      );

      expect(grouped.inactiveGroups.map((group) => group.label).toList(), [
        'This week',
        'This month',
        'Older',
      ]);
      expect(grouped.inactiveGroups.first.agents.map((a) => a.id), [
        'week-a',
        'week-b',
      ]);
    });

    // extra:
    test('returns empty sections for an empty agent list', () {
      final grouped = groupAgents(agents: const [], now: now);
      expect(grouped.activeGroups, isEmpty);
      expect(grouped.inactiveGroups, isEmpty);
    });
  });

  // =========================================================================
  // workspace/legacy-daemon-workspaces.ts
  // =========================================================================

  group('shouldUseLegacyDaemonWorkspaceDirectory', () {
    // extra: the null case is the one that differs from the backfill guard.
    test('declines a host we have heard nothing from', () {
      expect(shouldUseLegacyDaemonWorkspaceDirectory(null), isFalse);
    });

    // extra:
    test('accepts a host without the workspaceMultiplicity feature', () {
      expect(shouldUseLegacyDaemonWorkspaceDirectory(serverInfo()), isTrue);
      expect(
        shouldUseLegacyDaemonWorkspaceDirectory(
          serverInfo(features: {'workspaceMultiplicity': false}),
        ),
        isTrue,
      );
    });

    // extra:
    test('declines a host that owns its own workspace registry', () {
      expect(
        shouldUseLegacyDaemonWorkspaceDirectory(
          serverInfo(features: {'workspaceMultiplicity': true}),
        ),
        isFalse,
      );
    });
  });

  group('buildLegacyDaemonWorkspaceSnapshot', () {
    test(
      'creates path-backed workspace rows and stamps legacy agents with their '
      'workspace id',
      () {
        final snapshot = buildLegacyDaemonWorkspaceSnapshot(
          serverId: serverId,
          entries: [
            legacyAgent(
              id: 'agent-running',
              cwd: '/repo/app',
              status: AgentRunState.running,
            ),
            legacyAgent(
              id: 'agent-idle',
              cwd: '/repo/app',
              status: AgentRunState.idle,
            ),
          ],
        );

        final workspace = snapshot.workspaces.values.single;
        expect(workspace.id, '/repo/app');
        expect(workspace.projectId, '/repo');
        expect(workspace.projectDisplayName, 'repo');
        expect(workspace.projectRootPath, '/repo');
        expect(workspace.workspaceDirectory, '/repo/app');
        expect(workspace.projectKind, WorkspaceProjectKind.git);
        expect(workspace.workspaceKind, WorkspaceKind.checkout);
        expect(workspace.name, 'app');
        expect(workspace.status, WorkspaceStateBucket.running);
        expect(workspace.scripts, isEmpty);

        expect(
          snapshot.agents.values
              .map(
                (entry) => (
                  id: entry.agent.agentId,
                  cwd: entry.agent.cwd,
                  workspaceId: entry.agent.workspaceId,
                ),
              )
              .toList(),
          [
            (id: 'agent-running', cwd: '/repo/app', workspaceId: '/repo/app'),
            (id: 'agent-idle', cwd: '/repo/app', workspaceId: '/repo/app'),
          ],
        );
      },
    );

    // extra: the git runtime and the descriptor's retained project payload.
    test('carries the checkout git runtime onto the synthetic row', () {
      final snapshot = buildLegacyDaemonWorkspaceSnapshot(
        serverId: serverId,
        entries: [legacyAgent(id: 'a', cwd: '/repo/app')],
      );

      final workspace = snapshot.workspaces.values.single;
      expect(workspace.gitRuntime?.currentBranch, 'main');
      expect(workspace.gitRuntime?.remoteUrl, 'git@example.com:repo/app.git');
      expect(workspace.gitRuntime?.isPaseoOwnedWorktree, isFalse);
      expect(workspace.gitRuntime?.isDirty, isNull);
      expect(workspace.githubRuntime, isNull);
      expect(workspace.title, isNull);
      expect(workspace.archivingAt, isNull);
      expect(workspace.activityAt, isNull);
      expect(workspace.project?['projectKey'], '/repo');
    });

    // extra:
    test('marks a non-git checkout as a plain directory', () {
      final snapshot = buildLegacyDaemonWorkspaceSnapshot(
        serverId: serverId,
        entries: [
          legacyAgent(
            id: 'a',
            cwd: '/repo/app',
            isGit: false,
            currentBranch: null,
            mainRepoRoot: null,
            workspaceName: null,
          ),
        ],
      );

      final workspace = snapshot.workspaces.values.single;
      expect(workspace.projectKind, WorkspaceProjectKind.nonGit);
      expect(workspace.workspaceKind, WorkspaceKind.directory);
      expect(workspace.gitRuntime, isNull);
    });

    // extra:
    test('marks a Paseo-owned checkout as a worktree', () {
      final snapshot = buildLegacyDaemonWorkspaceSnapshot(
        serverId: serverId,
        entries: [
          legacyAgent(id: 'a', cwd: '/repo/wt', isPaseoOwnedWorktree: true),
        ],
      );

      expect(
        snapshot.workspaces.values.single.workspaceKind,
        WorkspaceKind.worktree,
      );
    });
  });

  group('buildLegacyWorkspaces', () {
    // extra: the whole reason the row picks a status rather than the last one.
    test(
      'shows the most demanding status among agents sharing a directory',
      () {
        final workspaces = buildLegacyWorkspaces([
          legacyAgent(
            id: 'idle',
            cwd: '/repo/app',
            updatedAt: '2026-06-18T10:00:00.000Z',
          ),
          legacyAgent(
            id: 'blocked',
            cwd: '/repo/app',
            status: AgentRunState.awaitingPermission,
            updatedAt: '2026-06-18T11:00:00.000Z',
          ),
          legacyAgent(
            id: 'running',
            cwd: '/repo/app',
            status: AgentRunState.running,
            updatedAt: '2026-06-18T12:00:00.000Z',
          ),
        ]);

        final workspace = workspaces.values.single;
        expect(workspace.status, WorkspaceStateBucket.needsInput);
        expect(workspace.statusEnteredAt, '2026-06-18T11:00:00.000Z');
        // Identity fields stay with the first entry seen.
        expect(workspace.id, '/repo/app');
      },
    );

    // extra: a later, less demanding agent must not overwrite the row.
    test('ignores a later agent with a weaker status', () {
      final workspaces = buildLegacyWorkspaces([
        legacyAgent(
          id: 'running',
          cwd: '/repo/app',
          status: AgentRunState.running,
        ),
        legacyAgent(
          id: 'idle',
          cwd: '/repo/app',
          updatedAt: '2026-06-19T00:00:00.000Z',
        ),
      ]);

      expect(workspaces.values.single.status, WorkspaceStateBucket.running);
      expect(workspaces.values.single.statusEnteredAt, defaultUpdatedAt);
    });

    // extra: pending permissions come off the entry, not the agent summary.
    test('reads pending permissions from the directory entry', () {
      final workspaces = buildLegacyWorkspaces([
        legacyAgent(
          id: 'a',
          cwd: '/repo/app',
          pendingPermissions: const [
            {'id': 'p1'},
          ],
        ),
      ]);

      expect(workspaces.values.single.status, WorkspaceStateBucket.needsInput);
    });

    // extra: the attention timestamp wins over updatedAt.
    test('prefers the attention timestamp for statusEnteredAt', () {
      final workspaces = buildLegacyWorkspaces([
        legacyAgent(
          id: 'a',
          cwd: '/repo/app',
          attentionTimestamp: '2026-06-18T13:00:00.000Z',
        ),
      ]);

      expect(
        workspaces.values.single.statusEnteredAt,
        '2026-06-18T13:00:00.000Z',
      );
    });

    // extra: an unparseable or blank timestamp becomes null.
    test('drops an unusable statusEnteredAt', () {
      expect(
        buildLegacyWorkspaces([
          legacyAgent(id: 'a', cwd: '/repo/app', updatedAt: 'not-a-date'),
        ]).values.single.statusEnteredAt,
        isNull,
      );
      expect(
        buildLegacyWorkspaces([
          legacyAgent(id: 'a', cwd: '/repo/app', updatedAt: ''),
        ]).values.single.statusEnteredAt,
        isNull,
      );
      expect(
        buildLegacyWorkspaces([
          legacyAgent(id: 'a', cwd: '/repo/app', updatedAt: null),
        ]).values.single.statusEnteredAt,
        isNull,
      );
    });

    // extra: the row-name waterfall.
    test('names a row from workspaceName, then branch, then directory', () {
      expect(
        buildLegacyWorkspaces([
          legacyAgent(id: 'a', cwd: '/repo/app', workspaceName: '  named  '),
        ]).values.single.name,
        'named',
      );
      expect(
        buildLegacyWorkspaces([
          legacyAgent(
            id: 'a',
            cwd: '/repo/app',
            workspaceName: '   ',
            currentBranch: 'feature/x',
          ),
        ]).values.single.name,
        'feature/x',
      );
      expect(
        buildLegacyWorkspaces([
          legacyAgent(
            id: 'a',
            cwd: '/repo/app',
            workspaceName: null,
            currentBranch: 'HEAD',
          ),
        ]).values.single.name,
        'app',
      );
      expect(
        buildLegacyWorkspaces([
          legacyAgent(
            id: 'a',
            cwd: r'C:\repo\app',
            workspaceName: null,
            currentBranch: null,
          ),
        ]).values.single.name,
        'app',
      );
    });

    // extra: normalization decides the row key, so two spellings share a row.
    test('collapses trailing-slash and backslash spellings onto one row', () {
      final workspaces = buildLegacyWorkspaces([
        legacyAgent(id: 'a', cwd: '/repo/app/'),
        legacyAgent(id: 'b', cwd: r'\repo\app'),
      ]);

      expect(workspaces.keys.toList(), ['/repo/app']);
    });

    // extra: the projectRootPath waterfall.
    test(
      'resolves projectRootPath from mainRepoRoot, worktreeRoot, then cwd',
      () {
        expect(
          buildLegacyWorkspaces([
            legacyAgent(id: 'a', cwd: '/repo/app'),
          ]).values.single.projectRootPath,
          '/repo',
        );
        expect(
          buildLegacyWorkspaces([
            legacyAgent(
              id: 'a',
              cwd: '/repo/app',
              mainRepoRoot: null,
              worktreeRoot: '/repo/wt',
            ),
          ]).values.single.projectRootPath,
          '/repo/wt',
        );
      },
    );

    // extra: an already-stamped workspaceId keys the row, even when it differs
    // from the directory the descriptor reports.
    test('keys off an existing agent workspaceId when present', () {
      final workspaces = buildLegacyWorkspaces([
        legacyAgent(id: 'a', cwd: '/repo/app', workspaceId: 'ws_opaque'),
      ]);

      expect(workspaces.keys.toList(), ['ws_opaque']);
      expect(workspaces['ws_opaque']?.id, '/repo/app');
    });

    // extra: a missing checkout falls back to the agent cwd rather than throwing.
    test('falls back to the agent cwd when the checkout is absent', () {
      final workspaces = buildLegacyWorkspaces([
        legacyAgent(
          id: 'a',
          cwd: '/repo/app',
          includeCheckout: false,
          workspaceName: null,
        ),
      ]);

      final workspace = workspaces.values.single;
      expect(workspace.id, '/repo/app');
      expect(workspace.projectRootPath, '/repo/app');
      expect(workspace.projectKind, WorkspaceProjectKind.nonGit);
      expect(workspace.name, 'app');
    });

    // extra: a cwd that normalizes to nothing still produces a key.
    test('keeps a whitespace-only cwd as its own raw key', () {
      final workspaces = buildLegacyWorkspaces([
        legacyAgent(
          id: 'a',
          cwd: '  ',
          workspaceName: null,
          currentBranch: null,
        ),
      ]);

      expect(workspaces.keys.toList(), ['  ']);
    });
  });

  group('stampLegacyWorkspaceIds', () {
    // extra: the rewrite is unconditional.
    test('overwrites an id the legacy daemon invented', () {
      final stamped = stampLegacyWorkspaceIds([
        legacyAgent(id: 'a', cwd: '/repo/app/', workspaceId: 'ws_stale'),
      ]);

      expect(stamped.single.agent.workspaceId, '/repo/app');
    });

    // extra: nothing else on the entry moves.
    test('leaves the project payload and permissions untouched', () {
      final entry = legacyAgent(
        id: 'a',
        cwd: '/repo/app',
        pendingPermissions: const [
          {'id': 'p1'},
        ],
      );
      final stamped = stampLegacyWorkspaceIds([entry]).single;

      expect(stamped.project, same(entry.project));
      expect(stamped.pendingPermissions, same(entry.pendingPermissions));
      expect(stamped.agent.cwd, entry.agent.cwd);
    });
  });

  group('applyLegacyDaemonWorkspaceOwnership', () {
    test(
      'keeps old-daemon agent updates attached to the path-backed workspace',
      () {
        final snapshot = buildLegacyDaemonWorkspaceSnapshot(
          serverId: serverId,
          entries: [
            legacyAgent(
              id: 'agent-running',
              cwd: '/repo/app',
              status: AgentRunState.running,
            ),
          ],
        );
        final store = _FakeStore()
          ..serverInfoStatus = serverInfo()
          ..workspaces = snapshot.workspaces
          ..agents = snapshot.agents;

        // The update an old daemon sends: same agent, no workspace id.
        final existing = snapshot.agents['agent-running']!;
        final oldDaemonUpdate = AgentDirectoryEntry(
          agent: existing.agent.copyWith(
            workspaceId: null,
            updatedAt: '2026-06-18T10:01:00.000Z',
          ),
          project: existing.project,
        );

        final stamped = applyLegacyDaemonWorkspaceOwnership(
          store: store,
          serverId: serverId,
          entry: oldDaemonUpdate,
        );

        expect(stamped.agent.workspaceId, '/repo/app');
      },
    );

    // extra: an agent that already knows its owner is returned untouched.
    test('returns the entry unchanged when it already has an owner', () {
      final store = _FakeStore()..serverInfoStatus = serverInfo();
      final entry = legacyAgent(
        id: 'a',
        cwd: '/repo/app',
        workspaceId: 'ws_real',
      );

      expect(
        applyLegacyDaemonWorkspaceOwnership(
          store: store,
          serverId: serverId,
          entry: entry,
        ),
        same(entry),
      );
    });

    // extra: JS truthiness — an empty workspaceId is unowned and gets stamped.
    test('treats an empty workspaceId as unowned', () {
      final store = _FakeStore()..serverInfoStatus = serverInfo();
      final stamped = applyLegacyDaemonWorkspaceOwnership(
        store: store,
        serverId: serverId,
        entry: legacyAgent(id: 'a', cwd: '/repo/app', workspaceId: ''),
      );

      expect(stamped.agent.workspaceId, '/repo/app');
    });

    // extra: the shim stands down for daemons that own agents themselves.
    test('does nothing for a modern daemon', () {
      final store = _FakeStore()
        ..serverInfoStatus = serverInfo(
          features: {'workspaceMultiplicity': true},
        );
      final entry = legacyAgent(id: 'a', cwd: '/repo/app');

      expect(
        applyLegacyDaemonWorkspaceOwnership(
          store: store,
          serverId: serverId,
          entry: entry,
        ),
        same(entry),
      );
    });

    // extra: unlike the directory guard, an unknown host still gets stamped.
    test('still stamps when the host has not reported server info', () {
      final store = _FakeStore();
      final stamped = applyLegacyDaemonWorkspaceOwnership(
        store: store,
        serverId: serverId,
        entry: legacyAgent(id: 'a', cwd: '/repo/app'),
      );

      expect(stamped.agent.workspaceId, '/repo/app');
    });

    // extra: the agentDetails map is the second place looked.
    test('falls back to the agent detail record for a remembered owner', () {
      final store = _FakeStore()
        ..serverInfoStatus = serverInfo()
        ..agentDetails = {
          'a': legacyAgent(id: 'a', cwd: '/elsewhere', workspaceId: 'ws_known'),
        };

      final stamped = applyLegacyDaemonWorkspaceOwnership(
        store: store,
        serverId: serverId,
        entry: legacyAgent(id: 'a', cwd: '/repo/app'),
      );

      expect(stamped.agent.workspaceId, 'ws_known');
    });

    // extra: `??` is nullish, so a remembered empty id wins and then fails the
    // guard, leaving the entry alone.
    test('bails when the remembered owner is an empty string', () {
      final store = _FakeStore()
        ..serverInfoStatus = serverInfo()
        ..agents = {
          'a': legacyAgent(id: 'a', cwd: '/repo/app', workspaceId: ''),
        };
      final entry = legacyAgent(id: 'a', cwd: '/repo/app');

      expect(
        applyLegacyDaemonWorkspaceOwnership(
          store: store,
          serverId: serverId,
          entry: entry,
        ),
        same(entry),
      );
    });

    // extra: matching by directory finds the opaque id of an existing row.
    test('matches an existing workspace row by directory', () {
      final store = _FakeStore()
        ..serverInfoStatus = serverInfo()
        ..workspaces = {
          'ws_opaque': workspaceDescriptor(
            id: 'ws_opaque',
            workspaceDirectory: '/repo/app/',
          ),
        };

      final stamped = applyLegacyDaemonWorkspaceOwnership(
        store: store,
        serverId: serverId,
        entry: legacyAgent(id: 'a', cwd: r'\repo\app'),
      );

      expect(stamped.agent.workspaceId, 'ws_opaque');
    });

    // extra: a cwd that normalizes to nothing cannot be stamped.
    test('bails when the cwd normalizes to nothing', () {
      final store = _FakeStore()..serverInfoStatus = serverInfo();
      final entry = legacyAgent(id: 'a', cwd: '   ');

      expect(
        applyLegacyDaemonWorkspaceOwnership(
          store: store,
          serverId: serverId,
          entry: entry,
        ),
        same(entry),
      );
    });

    // extra: an empty project payload inherits the remembered placement.
    test(
      'inherits the remembered project payload when the update omits one',
      () {
        final remembered = legacyAgent(
          id: 'a',
          cwd: '/repo/app',
          workspaceId: 'ws_known',
        );
        final store = _FakeStore()
          ..serverInfoStatus = serverInfo()
          ..agents = {'a': remembered};

        final stamped = applyLegacyDaemonWorkspaceOwnership(
          store: store,
          serverId: serverId,
          entry: const AgentDirectoryEntry(
            agent: AgentSummary(
              agentId: 'a',
              title: '',
              cwd: '/repo/app',
              provider: 'mock',
              model: '',
              mode: AgentMode.normal,
              runState: AgentRunState.idle,
              createdAtMs: 0,
            ),
            project: {},
          ),
        );

        expect(stamped.project, same(remembered.project));
      },
    );
  });

  group('readLegacyDaemonWorkspaceDirectory', () {
    // extra: the default page size and the constant sort.
    test(
      'asks for the newest-first sort and a 200-row page by default',
      () async {
        final fetch = _FakeFetchAgents([page(const [])]);
        await readLegacyDaemonWorkspaceDirectory(fetchAgents: fetch.call);

        expect(fetch.calls.single.limit, 200);
        expect(fetch.calls.single.cursor, isNull);
        expect(
          fetch.calls.single.sort.single.key,
          AgentDirectorySortKey.updatedAt,
        );
        expect(
          fetch.calls.single.sort.single.direction,
          AgentDirectorySortDirection.desc,
        );
      },
    );

    // extra: pagination, and subscribe only on the first request.
    test('pages until exhausted and subscribes only once', () async {
      final fetch = _FakeFetchAgents([
        page(
          [legacyAgent(id: 'a', cwd: '/repo/a')],
          hasMore: true,
          nextCursor: 'c1',
          subscriptionId: 'sub_1',
        ),
        page(
          [legacyAgent(id: 'b', cwd: '/repo/b')],
          hasMore: false,
          subscriptionId: 'sub_2',
        ),
      ]);

      final result = await readLegacyDaemonWorkspaceDirectory(
        fetchAgents: fetch.call,
        subscribe: const LegacyDaemonSubscribeOptions(subscriptionId: 'want'),
        page: const LegacyDaemonPageOptions(limit: 25, cursor: 'start'),
      );

      expect(result?.entries.map((e) => e.agent.agentId), ['a', 'b']);
      expect(result?.subscriptionId, 'sub_1');
      expect(fetch.calls.map((call) => call.cursor).toList(), ['start', 'c1']);
      expect(fetch.calls.map((call) => call.limit).toList(), [25, 25]);
      expect(fetch.calls[0].subscribe?.subscriptionId, 'want');
      expect(fetch.calls[1].subscribe, isNull);
    });

    // extra: the legacy field-name spellings.
    test('accepts the hasMoreAfter/afterCursor spellings', () async {
      final fetch = _FakeFetchAgents([
        page(
          [legacyAgent(id: 'a', cwd: '/repo/a')],
          hasMoreAfter: true,
          afterCursor: 'c1',
        ),
        page([legacyAgent(id: 'b', cwd: '/repo/b')], hasMoreAfter: false),
      ]);

      final result = await readLegacyDaemonWorkspaceDirectory(
        fetchAgents: fetch.call,
      );

      expect(result?.entries.map((e) => e.agent.agentId), ['a', 'b']);
      expect(fetch.calls.map((call) => call.cursor).toList(), [null, 'c1']);
    });

    // extra: the modern spelling wins when both are present.
    test('prefers hasMore and nextCursor over the legacy spellings', () async {
      final fetch = _FakeFetchAgents([
        page(
          const [],
          hasMore: false,
          hasMoreAfter: true,
          nextCursor: 'ignored',
          afterCursor: 'ignored-too',
        ),
      ]);

      await readLegacyDaemonWorkspaceDirectory(fetchAgents: fetch.call);
      expect(fetch.calls, hasLength(1));
    });

    // extra: absent means "no more", which stops the loop.
    test('stops when the page reports neither spelling', () async {
      final fetch = _FakeFetchAgents([page(const [], nextCursor: 'c1')]);
      await readLegacyDaemonWorkspaceDirectory(fetchAgents: fetch.call);
      expect(fetch.calls, hasLength(1));
    });

    // extra: "more, but no cursor" must terminate rather than loop forever. An
    // empty-string cursor is falsy upstream and counts as no cursor.
    test('stops when there is more but no usable cursor', () async {
      final missing = _FakeFetchAgents([page(const [], hasMore: true)]);
      await readLegacyDaemonWorkspaceDirectory(fetchAgents: missing.call);
      expect(missing.calls, hasLength(1));

      final blank = _FakeFetchAgents([
        page(const [], hasMore: true, nextCursor: ''),
      ]);
      await readLegacyDaemonWorkspaceDirectory(fetchAgents: blank.call);
      expect(blank.calls, hasLength(1));
    });

    // extra:
    test('returns null without fetching when cancelled up front', () async {
      final fetch = _FakeFetchAgents([page(const [])]);
      final result = await readLegacyDaemonWorkspaceDirectory(
        fetchAgents: fetch.call,
        isCancelled: () => true,
      );

      expect(result, isNull);
      expect(fetch.calls, isEmpty);
    });

    // extra: cancellation observed during the fetch discards the page.
    test('returns null when cancelled during a fetch', () async {
      var cancelled = false;
      final fetch = _FakeFetchAgents([
        page([legacyAgent(id: 'a', cwd: '/repo/a')], hasMore: false),
      ], onFetch: () => cancelled = true);

      final result = await readLegacyDaemonWorkspaceDirectory(
        fetchAgents: fetch.call,
        isCancelled: () => cancelled,
      );

      expect(result, isNull);
      expect(fetch.calls, hasLength(1));
    });
  });

  group('replaceLegacyDaemonWorkspaceDirectory', () {
    // extra: every store write the function performs.
    test('installs agents and workspaces and clears empty projects', () {
      final store = _FakeStore()..hasHydratedWorkspaces = false;

      final snapshot = replaceLegacyDaemonWorkspaceDirectory(
        store: store,
        serverId: serverId,
        entries: [legacyAgent(id: 'a', cwd: '/repo/app')],
      );

      expect(snapshot.agents.keys, ['a']);
      expect(snapshot.workspaces.keys, ['/repo/app']);
      expect(store.agents, same(snapshot.agents));
      expect(store.workspaces, same(snapshot.workspaces));
      expect(store.emptyProjects, isEmpty);
      expect(store.hasHydratedWorkspaces, isTrue);
      expect(store.writtenServerIds, [serverId]);
      expect(store.agents['a']?.agent.workspaceId, '/repo/app');
    });
  });

  group('fetchLegacyDaemonWorkspaceDirectory', () {
    // extra: the read/replace composition, including the subscription id.
    test(
      'reads the directory, installs it, and reports the subscription',
      () async {
        final store = _FakeStore();
        final fetch = _FakeFetchAgents([
          page(
            [legacyAgent(id: 'a', cwd: '/repo/app')],
            hasMore: false,
            subscriptionId: 'sub_1',
          ),
        ]);

        final result = await fetchLegacyDaemonWorkspaceDirectory(
          fetchAgents: fetch.call,
          store: store,
          serverId: serverId,
        );

        expect(result.subscriptionId, 'sub_1');
        expect(result.workspaces.keys, ['/repo/app']);
        expect(store.hasHydratedWorkspaces, isTrue);
      },
    );
  });

  group('backfillLegacyDaemonWorkspaceDirectoryIfEmpty', () {
    test(
      'does not backfill path-backed workspaces after hydration is cancelled',
      () async {
        final store = _FakeStore()..serverInfoStatus = serverInfo();
        var cancelled = false;
        final fetch = _FakeFetchAgents([
          page([
            legacyAgent(id: 'agent-cancelled', cwd: '/repo/app'),
          ], hasMore: false),
        ], onFetch: () => cancelled = true);

        final didBackfill = await backfillLegacyDaemonWorkspaceDirectoryIfEmpty(
          fetchAgents: fetch.call,
          store: store,
          serverId: serverId,
          workspaces: const {},
          emptyProjects: const {},
          isCancelled: () => cancelled,
        );

        expect(fetch.calls, hasLength(1));
        expect(didBackfill, isTrue);
        expect(store.agents, isEmpty);
        expect(store.workspaces, isEmpty);
        expect(store.hasHydratedWorkspaces, isNull);
      },
    );

    // extra: the happy path.
    test(
      'backfills when the store is empty and the daemon is legacy',
      () async {
        final store = _FakeStore()..serverInfoStatus = serverInfo();
        final fetch = _FakeFetchAgents([
          page([legacyAgent(id: 'a', cwd: '/repo/app')], hasMore: false),
        ]);

        final didBackfill = await backfillLegacyDaemonWorkspaceDirectoryIfEmpty(
          fetchAgents: fetch.call,
          store: store,
          serverId: serverId,
          workspaces: const {},
          emptyProjects: const {},
        );

        expect(didBackfill, isTrue);
        expect(store.workspaces.keys, ['/repo/app']);
        expect(store.hasHydratedWorkspaces, isTrue);
      },
    );

    // extra: an unknown host is still worth one speculative backfill — this is
    // where the guard deliberately differs from
    // shouldUseLegacyDaemonWorkspaceDirectory.
    test('backfills a host that has not reported server info', () async {
      final store = _FakeStore();
      final fetch = _FakeFetchAgents([
        page([legacyAgent(id: 'a', cwd: '/repo/app')], hasMore: false),
      ]);

      final didBackfill = await backfillLegacyDaemonWorkspaceDirectoryIfEmpty(
        fetchAgents: fetch.call,
        store: store,
        serverId: serverId,
        workspaces: const {},
        emptyProjects: const {},
      );

      expect(didBackfill, isTrue);
      expect(store.workspaces.keys, ['/repo/app']);
    });

    // extra: declines rather than claims, so the caller runs the modern path.
    test('declines when the store already has rows', () async {
      final store = _FakeStore()..serverInfoStatus = serverInfo();
      final fetch = _FakeFetchAgents([page(const [])]);

      expect(
        await backfillLegacyDaemonWorkspaceDirectoryIfEmpty(
          fetchAgents: fetch.call,
          store: store,
          serverId: serverId,
          workspaces: {
            'ws': workspaceDescriptor(
              id: 'ws',
              workspaceDirectory: '/repo/app',
            ),
          },
          emptyProjects: const {},
        ),
        isFalse,
      );
      expect(
        await backfillLegacyDaemonWorkspaceDirectoryIfEmpty(
          fetchAgents: fetch.call,
          store: store,
          serverId: serverId,
          workspaces: const {},
          emptyProjects: const {'p': 1},
        ),
        isFalse,
      );
      expect(fetch.calls, isEmpty);
    });

    // extra:
    test('declines for a modern daemon', () async {
      final store = _FakeStore()
        ..serverInfoStatus = serverInfo(
          features: {'workspaceMultiplicity': true},
        );
      final fetch = _FakeFetchAgents([page(const [])]);

      expect(
        await backfillLegacyDaemonWorkspaceDirectoryIfEmpty(
          fetchAgents: fetch.call,
          store: store,
          serverId: serverId,
          workspaces: const {},
          emptyProjects: const {},
        ),
        isFalse,
      );
      expect(fetch.calls, isEmpty);
    });

    // extra: claimed, but nothing fetched.
    test('claims hydration without fetching when cancelled up front', () async {
      final store = _FakeStore()..serverInfoStatus = serverInfo();
      final fetch = _FakeFetchAgents([page(const [])]);

      expect(
        await backfillLegacyDaemonWorkspaceDirectoryIfEmpty(
          fetchAgents: fetch.call,
          store: store,
          serverId: serverId,
          workspaces: const {},
          emptyProjects: const {},
          isCancelled: () => true,
        ),
        isTrue,
      );
      expect(fetch.calls, isEmpty);
      expect(store.hasHydratedWorkspaces, isNull);
    });
  });
}
