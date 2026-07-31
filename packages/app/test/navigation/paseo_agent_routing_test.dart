// Ports of the upstream test suites for Paseo's agent-addressing rules:
// navigate-to-agent/resolve, new-agent-routing, notification-routing,
// agent-snapshots and client-id — plus the edge cases the upstream suites
// leave unpinned (JS truthiness fall-through, whitespace-only ids, worktree
// marker boundaries, non-string notification payload values, permission-key
// waterfall rungs, resolver caching and failure retries).
import 'dart:math';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/host_routes.dart';
import 'package:coding_agent_app/navigation/paseo_agent_routing.dart';
import 'package:coding_agent_app/workspace/workspace_tab_model.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// navigate-to-agent/resolve
// ---------------------------------------------------------------------------

/// One recorded `navigateToWorkspace` call.
final class _RecordedWorkspaceNav {
  const _RecordedWorkspaceNav({
    required this.serverId,
    required this.workspaceId,
    required this.target,
    required this.pin,
  });

  final String serverId;
  final String workspaceId;
  final WorkspaceTabTarget target;
  final bool? pin;
}

/// Fake router + store seams for [resolveNavigateToAgent].
final class _FakeAgentNavigators {
  _FakeAgentNavigators(this.target);

  final AgentNavTarget target;
  final List<String> hostNavigations = [];
  final List<_RecordedWorkspaceNav> workspaceNavigations = [];
  final List<HostAgentRoute> readTargets = [];

  NavigateToAgentDependencies get dependencies => NavigateToAgentDependencies(
    readAgentNavTarget: ({required serverId, required agentId}) {
      readTargets.add(HostAgentRoute(serverId: serverId, agentId: agentId));
      return target;
    },
    navigateToHostAgent: hostNavigations.add,
    navigateToWorkspace:
        ({required serverId, required workspaceId, required target, pin}) {
          workspaceNavigations.add(
            _RecordedWorkspaceNav(
              serverId: serverId,
              workspaceId: workspaceId,
              target: target,
              pin: pin,
            ),
          );
          return '/h/$serverId/workspace/$workspaceId';
        },
  );
}

// ---------------------------------------------------------------------------
// new-agent-routing
// ---------------------------------------------------------------------------

CheckoutStatusGitPaseo _paseoCheckout({
  required String cwd,
  required String mainRepoRoot,
}) => CheckoutStatusGitPaseo(
  cwd: cwd,
  repoRoot: cwd,
  mainRepoRoot: mainRepoRoot,
  currentBranch: 'feature',
  isDirty: false,
  baseRef: 'main',
  aheadBehind: null,
  aheadOfOrigin: null,
  behindOfOrigin: null,
  hasRemote: false,
  remoteUrl: null,
  error: null,
  requestId: 'req-1',
);

CheckoutStatusGitNonPaseo _plainCheckout({
  required String cwd,
  String? mainRepoRoot,
}) => CheckoutStatusGitNonPaseo(
  cwd: cwd,
  repoRoot: cwd,
  mainRepoRoot: mainRepoRoot,
  currentBranch: 'main',
  isDirty: false,
  baseRef: null,
  aheadBehind: null,
  aheadOfOrigin: null,
  behindOfOrigin: null,
  hasRemote: false,
  remoteUrl: null,
  error: null,
  requestId: 'req-2',
);

// ---------------------------------------------------------------------------
// agent-snapshots
// ---------------------------------------------------------------------------

AgentSummary _snapshot({
  String agentId = 'agent-1',
  int createdAtMs = 1000,
  String? updatedAt = '2026-04-20T00:01:00.000Z',
  String? lastUserMessageAt,
  String? attentionTimestamp,
  String? archivedAt,
  Map<String, String> labels = const {},
}) => AgentSummary(
  agentId: agentId,
  title: 'Agent',
  cwd: '/repo',
  provider: 'codex',
  model: '',
  mode: AgentMode.normal,
  runState: AgentRunState.idle,
  createdAtMs: createdAtMs,
  updatedAt: updatedAt,
  lastUserMessageAt: lastUserMessageAt,
  attentionTimestamp: attentionTimestamp,
  archivedAt: archivedAt,
  labels: labels,
);

// ---------------------------------------------------------------------------
// client-id
// ---------------------------------------------------------------------------

/// In-memory [ClientIdStorage] that counts writes and can fail on demand.
final class _InMemoryClientIdStorage implements ClientIdStorage {
  _InMemoryClientIdStorage([Map<String, String> initial = const {}])
    : items = Map.of(initial);

  final Map<String, String> items;
  int setCallCount = 0;
  int getCallCount = 0;
  Object? failNextGetWith;

  @override
  Future<String?> getItem(String key) async {
    getCallCount += 1;
    final failure = failNextGetWith;
    if (failure != null) {
      failNextGetWith = null;
      throw failure;
    }
    return items[key];
  }

  @override
  Future<void> setItem(String key, String value) async {
    setCallCount += 1;
    items[key] = value;
  }
}

void main() {
  group('resolveNavigateToAgent', () {
    test("opens the workspace tab carried by the agent's workspaceId", () {
      final navigators = _FakeAgentNavigators(
        const AgentNavTarget(agentWorkspaceId: 'workspace-1'),
      );

      final route = resolveNavigateToAgent(
        const NavigateToAgentInput(
          serverId: 'server-1',
          agentId: 'agent-1',
          pin: true,
        ),
        navigators.dependencies,
      );

      expect(route, '/h/server-1/workspace/workspace-1');
      expect(navigators.hostNavigations, isEmpty);
      expect(navigators.workspaceNavigations, hasLength(1));
      final recorded = navigators.workspaceNavigations.single;
      expect(recorded.serverId, 'server-1');
      expect(recorded.workspaceId, 'workspace-1');
      expect(recorded.pin, isTrue);
      expect(recorded.target, isA<WorkspaceAgentTabTarget>());
      expect((recorded.target as WorkspaceAgentTabTarget).agentId, 'agent-1');
    });

    test('uses the input workspaceId without reading the nav target', () {
      final navigators = _FakeAgentNavigators(
        const AgentNavTarget(agentWorkspaceId: null),
      );

      resolveNavigateToAgent(
        const NavigateToAgentInput(
          serverId: 'server-1',
          agentId: 'agent-1',
          workspaceId: 'workspace-1',
        ),
        navigators.dependencies,
      );

      expect(navigators.readTargets, isEmpty);
      expect(navigators.workspaceNavigations, hasLength(1));
      expect(navigators.workspaceNavigations.single.workspaceId, 'workspace-1');
      // `pin: undefined` is forwarded, not defaulted.
      expect(navigators.workspaceNavigations.single.pin, isNull);
    });

    test('falls back to the host agent route when the agent has no '
        'workspaceId', () {
      final navigators = _FakeAgentNavigators(
        const AgentNavTarget(agentWorkspaceId: null),
      );

      final route = resolveNavigateToAgent(
        const NavigateToAgentInput(
          serverId: 'server-1',
          agentId: 'missing-agent',
        ),
        navigators.dependencies,
      );

      expect(route, '/h/server-1/agent/missing-agent');
      expect(navigators.hostNavigations, ['/h/server-1/agent/missing-agent']);
      expect(navigators.workspaceNavigations, isEmpty);
      expect(navigators.readTargets, hasLength(1));
      expect(navigators.readTargets.single.serverId, 'server-1');
      expect(navigators.readTargets.single.agentId, 'missing-agent');
    });

    test('trims a padded workspace id from the store', () {
      final navigators = _FakeAgentNavigators(
        const AgentNavTarget(agentWorkspaceId: '  workspace-1\n'),
      );

      final route = resolveNavigateToAgent(
        const NavigateToAgentInput(serverId: 'server-1', agentId: 'agent-1'),
        navigators.dependencies,
      );

      expect(route, '/h/server-1/workspace/workspace-1');
      expect(navigators.workspaceNavigations.single.workspaceId, 'workspace-1');
    });

    test('treats a whitespace-only stored workspace id as absent', () {
      final navigators = _FakeAgentNavigators(
        const AgentNavTarget(agentWorkspaceId: '   '),
      );

      final route = resolveNavigateToAgent(
        const NavigateToAgentInput(serverId: 'server-1', agentId: 'agent-1'),
        navigators.dependencies,
      );

      expect(route, '/h/server-1/agent/agent-1');
      expect(navigators.workspaceNavigations, isEmpty);
    });

    test('an empty input workspaceId does not fall through to the store', () {
      // JS `??` only falls through null/undefined, so `""` short-circuits the
      // store read and is then rejected by normalization.
      final navigators = _FakeAgentNavigators(
        const AgentNavTarget(agentWorkspaceId: 'workspace-from-store'),
      );

      final route = resolveNavigateToAgent(
        const NavigateToAgentInput(
          serverId: 'server-1',
          agentId: 'agent-1',
          workspaceId: '',
        ),
        navigators.dependencies,
      );

      expect(navigators.readTargets, isEmpty);
      expect(route, '/h/server-1/agent/agent-1');
    });

    test('percent-encodes ids in the host agent fallback route', () {
      final navigators = _FakeAgentNavigators(
        const AgentNavTarget(agentWorkspaceId: null),
      );

      final route = resolveNavigateToAgent(
        const NavigateToAgentInput(
          serverId: 'srv/with/slash',
          agentId: 'agent one',
        ),
        navigators.dependencies,
      );

      expect(route, '/h/srv%2Fwith%2Fslash/agent/agent%20one');
    });

    test('falls back to the app root when the agent id is blank', () {
      final navigators = _FakeAgentNavigators(
        const AgentNavTarget(agentWorkspaceId: null),
      );

      final route = resolveNavigateToAgent(
        const NavigateToAgentInput(serverId: 'server-1', agentId: '   '),
        navigators.dependencies,
      );

      expect(route, '/');
      expect(navigators.hostNavigations, ['/']);
    });
  });

  group('parseAgentKey', () {
    test('parses server and agent ids from a combined key', () {
      final parsed = parseAgentKey('srv-1:agent-9');
      expect(parsed?.serverId, 'srv-1');
      expect(parsed?.agentId, 'agent-9');
    });

    test('uses the last separator to preserve server ids with colons', () {
      final parsed = parseAgentKey('localhost:6767:agent-9');
      expect(parsed?.serverId, 'localhost:6767');
      expect(parsed?.agentId, 'agent-9');
    });

    test('returns null for malformed keys', () {
      expect(parseAgentKey(''), isNull);
      expect(parseAgentKey('only-server'), isNull);
      expect(parseAgentKey(':agent-1'), isNull);
      expect(parseAgentKey('srv-1:'), isNull);
    });

    test('returns null for a null key', () {
      expect(parseAgentKey(null), isNull);
    });

    test('trims both halves', () {
      final parsed = parseAgentKey('  srv-1 : agent-9  ');
      expect(parsed?.serverId, 'srv-1');
      expect(parsed?.agentId, 'agent-9');
    });

    test('rejects halves that are blank once trimmed', () {
      expect(parseAgentKey('   :agent-1'), isNull);
      expect(parseAgentKey('srv-1:   '), isNull);
    });

    test('rejects a key that is only separators', () {
      // Trailing separator: `sep >= key.length - 1`.
      expect(parseAgentKey('::'), isNull);
      expect(parseAgentKey(':'), isNull);
    });

    test('keeps an interior colon on the server half', () {
      final parsed = parseAgentKey('a::b');
      expect(parsed?.serverId, 'a:');
      expect(parsed?.agentId, 'b');
    });
  });

  group('resolveSelectedAgentForNewAgent', () {
    test('prefers the agent in the current route', () {
      final resolved = resolveSelectedAgentForNewAgent(
        pathname: '/h/srv-1/workspace/L3JlcG8?open=agent%3Aagent-2',
        selectedAgentId: 'srv-9:agent-9',
      );
      expect(resolved?.serverId, 'srv-1');
      expect(resolved?.agentId, 'agent-2');
    });

    test('falls back to the selected agent key when the route has no '
        'agent', () {
      final resolved = resolveSelectedAgentForNewAgent(
        pathname: '/h/srv-1/settings',
        selectedAgentId: 'srv-1:agent-7',
      );
      expect(resolved?.serverId, 'srv-1');
      expect(resolved?.agentId, 'agent-7');
    });

    test('returns null when neither route nor selection has an agent', () {
      expect(
        resolveSelectedAgentForNewAgent(pathname: '/h/srv-1/settings'),
        isNull,
      );
    });

    test('a bare host agent route outranks the selected key', () {
      final resolved = resolveSelectedAgentForNewAgent(
        pathname: '/h/srv-1/agent/agent-3',
        selectedAgentId: 'srv-9:agent-9',
      );
      expect(resolved?.serverId, 'srv-1');
      expect(resolved?.agentId, 'agent-3');
    });

    test('a non-agent open intent does not claim the route', () {
      final resolved = resolveSelectedAgentForNewAgent(
        pathname: '/h/srv-1/workspace/L3JlcG8?open=terminal%3Aterm-1',
        selectedAgentId: 'srv-9:agent-9',
      );
      expect(resolved?.serverId, 'srv-9');
      expect(resolved?.agentId, 'agent-9');
    });

    test('an agent open intent needs a workspace route to apply', () {
      // The workspace-route branch requires both halves; here only the agent
      // route parses, so the path segment wins over the `open=` query.
      final resolved = resolveSelectedAgentForNewAgent(
        pathname: '/h/srv-1/agent/agent-1?open=agent%3Aagent-9',
      );
      expect(resolved?.serverId, 'srv-1');
      expect(resolved?.agentId, 'agent-1');
    });

    test('a malformed open intent falls through to the selected key', () {
      final resolved = resolveSelectedAgentForNewAgent(
        pathname: '/h/srv-1/workspace/L3JlcG8?open=agent%3A',
        selectedAgentId: 'srv-9:agent-9',
      );
      expect(resolved?.serverId, 'srv-9');
      expect(resolved?.agentId, 'agent-9');
    });

    test('returns null for a route outside the host tree with no '
        'selection', () {
      expect(resolveSelectedAgentForNewAgent(pathname: '/settings'), isNull);
    });
  });

  group('resolveNewAgentWorkingDir', () {
    test('returns the current cwd for regular checkouts', () {
      expect(resolveNewAgentWorkingDir('/repo/path', null), '/repo/path');
    });

    test('falls back to the repo root when checkout metadata is '
        'unavailable', () {
      expect(
        resolveNewAgentWorkingDir('/repo/.paseo/worktrees/feature', null),
        '/repo',
      );
    });

    test('supports windows-style paseo worktree paths without checkout '
        'metadata', () {
      expect(
        resolveNewAgentWorkingDir(
          r'C:\Users\me\repo\.paseo\worktrees\feature',
          null,
        ),
        r'C:\Users\me\repo',
      );
    });

    test('returns the main repo root for paseo-owned worktrees', () {
      final checkout = _paseoCheckout(
        cwd: '/repo/.paseo/worktrees/feature',
        mainRepoRoot: '/repo/main',
      );

      expect(
        resolveNewAgentWorkingDir('/repo/.paseo/worktrees/feature', checkout),
        '/repo/main',
      );
    });

    test('trims the reported main repo root', () {
      final checkout = _paseoCheckout(
        cwd: '/repo/.paseo/worktrees/feature',
        mainRepoRoot: '  /repo/main  ',
      );

      expect(
        resolveNewAgentWorkingDir('/repo/.paseo/worktrees/feature', checkout),
        '/repo/main',
      );
    });

    test('ignores a blank main repo root and infers from the path', () {
      final checkout = _paseoCheckout(
        cwd: '/repo/.paseo/worktrees/feature',
        mainRepoRoot: '   ',
      );

      expect(
        resolveNewAgentWorkingDir('/repo/.paseo/worktrees/feature', checkout),
        '/repo',
      );
    });

    test('ignores mainRepoRoot on a checkout paseo does not own', () {
      final checkout = _plainCheckout(
        cwd: '/repo/.paseo/worktrees/feature',
        mainRepoRoot: '/somewhere/else',
      );

      expect(
        resolveNewAgentWorkingDir('/repo/.paseo/worktrees/feature', checkout),
        '/repo',
      );
    });

    test('leaves a non-git checkout to path inference', () {
      expect(
        resolveNewAgentWorkingDir(
          '/plain/dir',
          const CheckoutStatusNotGit(
            cwd: '/plain/dir',
            error: null,
            requestId: 'req-3',
          ),
        ),
        '/plain/dir',
      );
    });

    test('requires the marker to be followed by a separator or the end', () {
      expect(
        resolveNewAgentWorkingDir('/repo/.paseo/worktrees-backup/x', null),
        '/repo/.paseo/worktrees-backup/x',
      );
      expect(
        resolveNewAgentWorkingDir('/repo/.paseo/worktrees', null),
        '/repo',
      );
    });

    test('requires the marker to be preceded by a repository root', () {
      // markerIndex == 0 leaves nothing to infer.
      expect(
        resolveNewAgentWorkingDir('/.paseo/worktrees/feature', null),
        '/.paseo/worktrees/feature',
      );
    });

    test('strips a trailing separator run from the inferred root', () {
      expect(
        resolveNewAgentWorkingDir('/repo//.paseo/worktrees/feature', null),
        '/repo',
      );
    });

    test('returns the cwd when stripping would leave nothing', () {
      // "//.paseo/worktrees/f" -> marker at index 1 -> prefix "/" -> stripped
      // to "" -> inference declines and the cwd is used unchanged.
      expect(
        resolveNewAgentWorkingDir('//.paseo/worktrees/f', null),
        '//.paseo/worktrees/f',
      );
    });

    test('uses the first marker occurrence for nested worktrees', () {
      expect(
        resolveNewAgentWorkingDir(
          '/repo/.paseo/worktrees/a/.paseo/worktrees/b',
          null,
        ),
        '/repo',
      );
    });
  });

  group('resolveNotificationTarget', () {
    test('extracts non-empty server and agent ids', () {
      expect(
        resolveNotificationTarget({
          'serverId': ' server-123 ',
          'agentId': ' agent-456 ',
        }),
        const NotificationTarget(
          serverId: 'server-123',
          agentId: 'agent-456',
          workspaceId: null,
          terminalId: null,
        ),
      );
    });

    test('returns null for missing and empty ids', () {
      const empty = NotificationTarget(
        serverId: null,
        agentId: null,
        workspaceId: null,
        terminalId: null,
      );
      expect(
        resolveNotificationTarget({'serverId': '', 'agentId': '   '}),
        empty,
      );
      expect(resolveNotificationTarget(null), empty);
      expect(resolveNotificationTarget(const {}), empty);
    });

    test('does not treat cwd as a workspace id alias', () {
      expect(
        resolveNotificationTarget({
          'serverId': 'srv-1',
          'agentId': 'agent-1',
          'cwd': '/tmp/repo',
        }),
        const NotificationTarget(
          serverId: 'srv-1',
          agentId: 'agent-1',
          workspaceId: null,
          terminalId: null,
        ),
      );
    });

    test('ignores non-string payload values', () {
      expect(
        resolveNotificationTarget({
          'serverId': 42,
          'agentId': const ['agent-1'],
          'workspaceId': null,
          'terminalId': 'term-1',
        }),
        const NotificationTarget(
          serverId: null,
          agentId: null,
          workspaceId: null,
          terminalId: 'term-1',
        ),
      );
    });
  });

  group('buildNotificationRoute', () {
    test('routes to the agent path when the workspace id is present', () {
      expect(
        buildNotificationRoute({
          'serverId': 'srv-1',
          'agentId': 'agent-1',
          'workspaceId': 'ws-main',
        }),
        '/h/srv-1/workspace/ws-main?open=agent%3Aagent-1',
      );
    });

    test('does not treat an incomplete notification as an agent URL', () {
      expect(
        buildNotificationRoute({'serverId': 'srv-1', 'agentId': 'agent-1'}),
        '/h/srv-1',
      );
    });

    test('routes to the workspace terminal tab when workspace and terminal '
        'ids are present', () {
      expect(
        buildNotificationRoute({
          'serverId': 'srv-1',
          'workspaceId': 'ws-main',
          'terminalId': 'term-1',
        }),
        '/h/srv-1/workspace/ws-main?open=terminal%3Aterm-1',
      );
    });

    test('falls back to the host root for a terminal without a workspace '
        'id', () {
      expect(
        buildNotificationRoute({
          'serverId': 'srv-1',
          'terminalId': 'term-1',
          'cwd': '/tmp/repo',
        }),
        '/h/srv-1',
      );
    });

    test('falls back to the host root when only serverId is present', () {
      expect(buildNotificationRoute({'serverId': 'srv-only'}), '/h/srv-only');
    });

    test('falls back to the app root when no server id is present', () {
      expect(buildNotificationRoute({'agentId': 'agent-legacy'}), '/');
      expect(buildNotificationRoute(null), '/');
      expect(
        buildNotificationRoute({'workspaceId': 'ws-main', 'agentId': 'a-1'}),
        '/',
      );
    });

    test('encodes path segments', () {
      expect(
        buildNotificationRoute({
          'serverId': 'srv/with/slash',
          'workspaceId': 'workspace-1',
          'agentId': 'agent with space',
        }),
        '/h/srv%2Fwith%2Fslash/workspace/workspace-1'
        '?open=agent%3Aagent%20with%20space',
      );
    });

    test('an agent id outranks a terminal id on the same payload', () {
      expect(
        buildNotificationRoute({
          'serverId': 'srv-1',
          'workspaceId': 'ws-main',
          'agentId': 'agent-1',
          'terminalId': 'term-1',
        }),
        '/h/srv-1/workspace/ws-main?open=agent%3Aagent-1',
      );
    });

    test('trims ids before building the route', () {
      expect(
        buildNotificationRoute({
          'serverId': '  srv-1  ',
          'workspaceId': ' ws-main ',
          'agentId': ' agent-1 ',
        }),
        '/h/srv-1/workspace/ws-main?open=agent%3Aagent-1',
      );
    });
  });

  group('derivePendingPermissionKey', () {
    test('prefers the request id', () {
      expect(
        derivePendingPermissionKey(
          'agent-1',
          const AgentPermissionRequest(
            id: 'req-1',
            name: 'Bash',
            kind: 'tool',
            metadata: {'id': 'meta-1'},
          ),
        ),
        'agent-1:req-1',
      );
    });

    test('falls through an empty id to the metadata id', () {
      expect(
        derivePendingPermissionKey(
          'agent-1',
          const AgentPermissionRequest(
            name: 'Bash',
            kind: 'tool',
            metadata: {'id': 'meta-1'},
          ),
        ),
        'agent-1:meta-1',
      );
    });

    test('ignores a non-string metadata id', () {
      expect(
        derivePendingPermissionKey(
          'agent-1',
          const AgentPermissionRequest(
            name: 'Bash',
            kind: 'tool',
            metadata: {'id': 42},
          ),
        ),
        'agent-1:Bash',
      );
    });

    test('ignores an empty metadata id', () {
      expect(
        derivePendingPermissionKey(
          'agent-1',
          const AgentPermissionRequest(
            name: 'Bash',
            kind: 'tool',
            metadata: {'id': ''},
          ),
        ),
        'agent-1:Bash',
      );
    });

    test('falls through a blank name to the title', () {
      expect(
        derivePendingPermissionKey(
          'agent-1',
          const AgentPermissionRequest(kind: 'plan', title: 'Approve plan'),
        ),
        'agent-1:Approve plan',
      );
    });

    test('synthesises a content key from the input when nothing is named', () {
      expect(
        derivePendingPermissionKey(
          'agent-1',
          const AgentPermissionRequest(
            kind: 'tool',
            input: {'command': 'ls', 'cwd': '/repo'},
          ),
        ),
        'agent-1:tool:{"command":"ls","cwd":"/repo"}',
      );
    });

    test('uses the metadata when there is no input', () {
      expect(
        derivePendingPermissionKey(
          'agent-1',
          const AgentPermissionRequest(kind: 'mode', metadata: {'to': 'plan'}),
        ),
        'agent-1:mode:{"to":"plan"}',
      );
    });

    test('falls back to an empty object when neither payload exists', () {
      expect(
        derivePendingPermissionKey(
          'agent-1',
          const AgentPermissionRequest(kind: 'other'),
        ),
        'agent-1:other:{}',
      );
    });

    test('an empty input map is used rather than the metadata', () {
      // `??` only falls through null, so `{}` short-circuits the metadata.
      expect(
        derivePendingPermissionKey(
          'agent-1',
          const AgentPermissionRequest(
            kind: 'tool',
            input: {},
            metadata: {'ignored': true},
          ),
        ),
        'agent-1:tool:{}',
      );
    });

    test('preserves insertion order in the synthesised key', () {
      expect(
        derivePendingPermissionKey(
          'agent-1',
          const AgentPermissionRequest(kind: 'tool', input: {'z': 1, 'a': 2}),
        ),
        'agent-1:tool:{"z":1,"a":2}',
      );
    });

    test('stringifies values json cannot encode', () {
      expect(
        derivePendingPermissionKey(
          'agent-1',
          AgentPermissionRequest(
            kind: 'tool',
            input: {'when': DateTime.utc(2026, 4, 20)},
          ),
        ),
        'agent-1:tool:{"when":"2026-04-20 00:00:00.000Z"}',
      );
    });

    test('scopes the key to the agent', () {
      const request = AgentPermissionRequest(id: 'req-1', kind: 'tool');
      expect(
        derivePendingPermissionKey('agent-1', request),
        isNot(derivePendingPermissionKey('agent-2', request)),
      );
    });
  });

  group('normalizeAgentSnapshot', () {
    test('derives parentAgentId from the parent label while preserving '
        'labels', () {
      const labels = {
        paseoParentAgentIdLabel: 'parent-1',
        'custom.label': 'still-here',
      };

      final agent = normalizeAgentSnapshot(
        snapshot: _snapshot(labels: labels),
        serverId: 'server-1',
      );

      expect(agent.parentAgentId, 'parent-1');
      expect(agent.agent.labels, labels);
      expect(agent.serverId, 'server-1');
    });

    test('trims whitespace around the parent label', () {
      final agent = normalizeAgentSnapshot(
        snapshot: _snapshot(
          labels: const {paseoParentAgentIdLabel: '  parent-1 \n'},
        ),
        serverId: 'server-1',
      );

      expect(agent.parentAgentId, 'parent-1');
    });

    test('maps missing and empty parent labels to null', () {
      expect(
        normalizeAgentSnapshot(
          snapshot: _snapshot(),
          serverId: 'server-1',
        ).parentAgentId,
        isNull,
      );
      expect(
        normalizeAgentSnapshot(
          snapshot: _snapshot(labels: const {paseoParentAgentIdLabel: '   '}),
          serverId: 'server-1',
        ).parentAgentId,
        isNull,
      );
    });

    test('maps a non-string parent label to null', () {
      // Deviation: `AgentSummary.labels` is `Map<String, String>`, so a
      // numeric label value is unrepresentable through `normalizeAgentSnapshot`
      // itself. The upstream case is pinned one level down, on the shared
      // protocol helper the rule delegates to.
      expect(
        parentAgentIdFromLabels(const <String, Object?>{
          paseoParentAgentIdLabel: 42,
        }),
        isNull,
      );
    });

    test('parses timestamps and aliases lastActivityAt to updatedAt', () {
      final agent = normalizeAgentSnapshot(
        snapshot: _snapshot(
          createdAtMs: DateTime.utc(2026, 4, 20).millisecondsSinceEpoch,
          updatedAt: '2026-04-20T00:01:00.000Z',
          lastUserMessageAt: '2026-04-20T00:02:00.000Z',
          attentionTimestamp: '2026-04-20T00:03:00.000Z',
          archivedAt: '2026-04-20T00:04:00.000Z',
        ),
        serverId: 'server-1',
      );

      expect(agent.createdAt, DateTime.utc(2026, 4, 20));
      expect(agent.updatedAt, DateTime.utc(2026, 4, 20, 0, 1));
      expect(agent.lastActivityAt, agent.updatedAt);
      expect(agent.lastUserMessageAt, DateTime.utc(2026, 4, 20, 0, 2));
      expect(agent.attentionTimestamp, DateTime.utc(2026, 4, 20, 0, 3));
      expect(agent.archivedAt, DateTime.utc(2026, 4, 20, 0, 4));
    });

    test('leaves absent optional timestamps null', () {
      final agent = normalizeAgentSnapshot(
        snapshot: _snapshot(),
        serverId: 'server-1',
      );

      expect(agent.lastUserMessageAt, isNull);
      expect(agent.attentionTimestamp, isNull);
      expect(agent.archivedAt, isNull);
    });

    test('treats blank optional timestamps as absent', () {
      final agent = normalizeAgentSnapshot(
        snapshot: _snapshot(lastUserMessageAt: '', attentionTimestamp: 'nope'),
        serverId: 'server-1',
      );

      expect(agent.lastUserMessageAt, isNull);
      expect(agent.attentionTimestamp, isNull);
    });

    test('falls back to createdAt when updatedAt is missing or unparsable', () {
      final created = DateTime.utc(2026, 4, 20).millisecondsSinceEpoch;

      expect(
        normalizeAgentSnapshot(
          snapshot: _snapshot(createdAtMs: created, updatedAt: null),
          serverId: 'server-1',
        ).updatedAt,
        DateTime.utc(2026, 4, 20),
      );
      expect(
        normalizeAgentSnapshot(
          snapshot: _snapshot(createdAtMs: created, updatedAt: 'not-a-date'),
          serverId: 'server-1',
        ).lastActivityAt,
        DateTime.utc(2026, 4, 20),
      );
    });

    test('keeps the decoded snapshot reachable', () {
      final snapshot = _snapshot(agentId: 'agent-42');
      final agent = normalizeAgentSnapshot(
        snapshot: snapshot,
        serverId: 'server-1',
      );

      expect(identical(agent.agent, snapshot), isTrue);
      expect(agent.agent.agentId, 'agent-42');
    });
  });

  group('ClientIdResolver', () {
    test('returns the stored client id and does not regenerate', () async {
      final storage = _InMemoryClientIdStorage({
        defaultClientIdStorageKey: 'cid_existing',
      });
      final resolver = ClientIdResolver(
        storage: storage,
        generateUuid: () => throw StateError(
          'generateUuid should not run when an id is stored',
        ),
      );

      expect(await resolver.getOrCreate(), 'cid_existing');
      expect(storage.setCallCount, 0);
    });

    test(
      'creates and persists a new client id when storage is empty',
      () async {
        final storage = _InMemoryClientIdStorage();
        final resolver = ClientIdResolver(
          storage: storage,
          generateUuid: () => '123456781234123412341234567890ab',
        );

        expect(
          await resolver.getOrCreate(),
          'cid_123456781234123412341234567890ab',
        );
        expect(
          storage.items[defaultClientIdStorageKey],
          'cid_123456781234123412341234567890ab',
        );
      },
    );

    test('dedupes concurrent callers behind a single storage write', () async {
      final storage = _InMemoryClientIdStorage();
      var uuidCalls = 0;
      final resolver = ClientIdResolver(
        storage: storage,
        generateUuid: () {
          uuidCalls += 1;
          return 'abcdef0123456789abcdef0123456789';
        },
      );

      final results = await Future.wait([
        resolver.getOrCreate(),
        resolver.getOrCreate(),
      ]);

      expect(results.first, 'cid_abcdef0123456789abcdef0123456789');
      expect(results.last, results.first);
      expect(uuidCalls, 1);
      expect(storage.setCallCount, 1);
    });

    test('ignores stored blank strings and treats them as missing', () async {
      final storage = _InMemoryClientIdStorage({
        defaultClientIdStorageKey: '   ',
      });
      final resolver = ClientIdResolver(
        storage: storage,
        generateUuid: () => 'newuuid',
      );

      expect(await resolver.getOrCreate(), 'cid_newuuid');
      expect(storage.items[defaultClientIdStorageKey], 'cid_newuuid');
    });

    test('trims a padded stored client id', () async {
      final storage = _InMemoryClientIdStorage({
        defaultClientIdStorageKey: '  cid_padded \n',
      });
      final resolver = ClientIdResolver(
        storage: storage,
        generateUuid: () => throw StateError('unreachable'),
      );

      expect(await resolver.getOrCreate(), 'cid_padded');
      expect(storage.setCallCount, 0);
    });

    test('caches the resolved id so storage is read once', () async {
      final storage = _InMemoryClientIdStorage({
        defaultClientIdStorageKey: 'cid_existing',
      });
      final resolver = ClientIdResolver(
        storage: storage,
        generateUuid: () => throw StateError('unreachable'),
      );

      expect(await resolver.getOrCreate(), 'cid_existing');
      expect(await resolver.getOrCreate(), 'cid_existing');
      expect(storage.getCallCount, 1);
    });

    test('honours a custom storage key', () async {
      final storage = _InMemoryClientIdStorage();
      final resolver = ClientIdResolver(
        storage: storage,
        generateUuid: () => 'uuid',
        storageKey: '@custom:client-id',
      );

      expect(await resolver.getOrCreate(), 'cid_uuid');
      expect(storage.items['@custom:client-id'], 'cid_uuid');
      expect(storage.items.containsKey(defaultClientIdStorageKey), isFalse);
    });

    test('retries after a failed storage read', () async {
      final storage = _InMemoryClientIdStorage()
        ..failNextGetWith = StateError('storage offline');
      final resolver = ClientIdResolver(
        storage: storage,
        generateUuid: () => 'uuid',
      );

      await expectLater(resolver.getOrCreate(), throwsStateError);
      expect(await resolver.getOrCreate(), 'cid_uuid');
      expect(storage.items[defaultClientIdStorageKey], 'cid_uuid');
    });
  });

  group('createRandomClientIdGenerator', () {
    test('emits 32 lowercase hex characters', () {
      final generate = createRandomClientIdGenerator(Random(7));
      final value = generate();

      expect(value, hasLength(32));
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(value), isTrue);
    });

    test('sets the version-4 and rfc-4122 variant nibbles', () {
      final generate = createRandomClientIdGenerator(Random(11));

      for (var i = 0; i < 32; i += 1) {
        final value = generate();
        // With dashes removed, `crypto.randomUUID()` puts the version nibble
        // at index 12 and the variant nibble at index 16.
        expect(value[12], '4');
        expect('89ab'.contains(value[16]), isTrue);
      }
    });

    test('is deterministic for a seeded Random', () {
      expect(
        createRandomClientIdGenerator(Random(3))(),
        createRandomClientIdGenerator(Random(3))(),
      );
    });

    test('does not repeat across draws', () {
      final generate = createRandomClientIdGenerator(Random(5));
      final drawn = {for (var i = 0; i < 50; i += 1) generate()};
      expect(drawn, hasLength(50));
    });
  });
}
