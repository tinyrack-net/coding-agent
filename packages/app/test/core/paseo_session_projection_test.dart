// Ports of the upstream test suites for Paseo's session/sidebar projection
// rules: session-status-tracking, session-workspace-upserts,
// workspace-directory-reconciliation, and sidebar-projection. Cases beyond the
// frozen upstream suite are marked `// extra:` and pin behavior the upstream
// tests leave implicit.
import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/paseo_session_projection.dart';
import 'package:flutter_test/flutter_test.dart';

AgentStatusSnapshot agent(AgentRunState status, {String id = 'agent-1'}) =>
    AgentStatusSnapshot(id: id, status: status);

WorkspaceDescriptor workspaceDescriptor({
  String id = '/repo/worktree',
  String? title,
  String? workspaceDirectory,
  String? archivingAt = '2026-04-30T00:00:00.000Z',
}) => WorkspaceDescriptor(
  id: id,
  projectId: 'project',
  projectDisplayName: 'Project',
  projectRootPath: '/repo',
  workspaceDirectory: workspaceDirectory ?? '/repo/$id',
  projectKind: WorkspaceProjectKind.git,
  workspaceKind: WorkspaceKind.worktree,
  name: id,
  title: title,
  status: WorkspaceStateBucket.done,
  statusEnteredAt: null,
  activityAt: null,
  archivingAt: archivingAt,
  diffStat: null,
  scripts: const [],
);

({SidebarWorkspacePlacement placement, SidebarWorkspaceEntry entry})
makeWorkspace(
  String id, {
  WorkspaceStateBucket statusBucket = WorkspaceStateBucket.done,
  DateTime? statusEnteredAt,
  String projectKey = 'project',
  String projectName = 'Project',
  String? name,
}) {
  final placement = SidebarWorkspacePlacement(
    workspaceKey: 'srv:$id',
    serverId: 'srv',
    workspaceId: id,
    projectKey: projectKey,
    projectName: projectName,
    projectKind: WorkspaceProjectKind.git,
    workspaceKind: WorkspaceKind.worktree,
    name: name ?? id,
  );
  final entry = SidebarWorkspaceEntry(
    workspaceKey: placement.workspaceKey,
    serverId: placement.serverId,
    workspaceId: placement.workspaceId,
    projectKey: placement.projectKey,
    projectName: placement.projectName,
    projectKind: placement.projectKind,
    workspaceKind: placement.workspaceKind,
    name: placement.name,
    statusBucket: statusBucket,
    statusEnteredAt: statusEnteredAt,
  );
  return (placement: placement, entry: entry);
}

SidebarWorkspaceProjectEntry makeProject(
  List<SidebarWorkspacePlacement> workspaces, {
  String projectKey = 'project',
  String projectName = 'Project',
}) => SidebarWorkspaceProjectEntry(
  projectKey: projectKey,
  projectName: projectName,
  projectKind: WorkspaceProjectKind.git,
  iconWorkingDir: '/repo',
  hosts: const [
    SidebarProjectHost(
      serverId: 'srv',
      iconWorkingDir: '/repo',
      canCreateWorktree: true,
    ),
  ],
  workspaces: workspaces,
);

SidebarProjection buildDefaultProjection({
  SidebarGroupMode groupMode = SidebarGroupMode.project,
  bool pinnedCollapsed = false,
  Set<String> collapsedProjectKeys = const {},
  Set<String> collapsedStatusGroupKeys = const {},
}) {
  final pinned = makeWorkspace(
    'pinned',
    statusBucket: WorkspaceStateBucket.running,
  );
  final unpinned = makeWorkspace(
    'unpinned',
    statusBucket: WorkspaceStateBucket.needsInput,
  );
  return buildSidebarProjection(
    projects: [
      makeProject([pinned.placement, unpinned.placement]),
    ],
    pinnedKeys: PinnedSidebarKeys(
      pinnedWorkspaceKeys: [pinned.placement.workspaceKey],
      pinnedAtByKey: {
        pinned.placement.workspaceKey: '2026-07-12T12:00:00.000Z',
      },
    ),
    workspaceEntriesByKey: {
      pinned.entry.workspaceKey: pinned.entry,
      unpinned.entry.workspaceKey: unpinned.entry,
    },
    projectNamesByKey: {'project': 'Project'},
    groupMode: groupMode,
    pinnedCollapsed: pinnedCollapsed,
    collapsedProjectKeys: collapsedProjectKeys,
    collapsedStatusGroupKeys: collapsedStatusGroupKeys,
  );
}

void main() {
  group('reconcilePreviousAgentStatuses', () {
    test('preserves previously seen status for existing agents', () {
      final result = reconcilePreviousAgentStatuses(
        previousStatuses: {'agent-1': AgentRunState.running},
        sessionAgents: {'agent-1': agent(AgentRunState.idle)},
      );

      expect(result, {'agent-1': AgentRunState.running});
    });

    test('seeds newly seen agents from the current snapshot', () {
      final result = reconcilePreviousAgentStatuses(
        previousStatuses: {},
        sessionAgents: {'agent-1': agent(AgentRunState.idle)},
      );

      expect(result, {'agent-1': AgentRunState.idle});
    });

    test('removes agents that are no longer present', () {
      final result = reconcilePreviousAgentStatuses(
        previousStatuses: {
          'agent-1': AgentRunState.running,
          'agent-2': AgentRunState.idle,
        },
        sessionAgents: {'agent-1': agent(AgentRunState.idle)},
      );

      expect(result, {'agent-1': AgentRunState.running});
    });

    test('clears all tracked statuses when the session is unavailable', () {
      final result = reconcilePreviousAgentStatuses(
        previousStatuses: {'agent-1': AgentRunState.running},
        sessionAgents: null,
      );

      expect(result, isEmpty);
    });

    // extra: an empty (but present) session is not the same as a missing one
    // for the caller, yet both end up clearing every tracked status.
    test('clears every tracked status for an empty session', () {
      final result = reconcilePreviousAgentStatuses(
        previousStatuses: {'agent-1': AgentRunState.running},
        sessionAgents: {},
      );

      expect(result, isEmpty);
    });

    // extra: upstream iterates `.values()` and keys off `agent.id`, so a map
    // keyed by anything else still tracks by the agent's own id.
    test('tracks by the agent id rather than the snapshot map key', () {
      final result = reconcilePreviousAgentStatuses(
        previousStatuses: {},
        sessionAgents: {
          'some-other-key': agent(AgentRunState.error, id: 'agent-7'),
        },
      );

      expect(result, {'agent-7': AgentRunState.error});
    });

    // extra: the caller keeps its own copy across renders, so the input must
    // survive untouched.
    test('does not mutate the previous status map', () {
      final previous = {
        'agent-1': AgentRunState.running,
        'agent-2': AgentRunState.idle,
      };

      final result = reconcilePreviousAgentStatuses(
        previousStatuses: previous,
        sessionAgents: {'agent-3': agent(AgentRunState.idle, id: 'agent-3')},
      );

      expect(previous, {
        'agent-1': AgentRunState.running,
        'agent-2': AgentRunState.idle,
      });
      expect(result, {'agent-3': AgentRunState.idle});
      expect(identical(result, previous), isFalse);
    });

    // extra: previously tracked agents keep their slot and newcomers append,
    // matching JS `Map` insertion order.
    test('keeps previous order and appends newly seen agents', () {
      final result = reconcilePreviousAgentStatuses(
        previousStatuses: {
          'agent-b': AgentRunState.running,
          'agent-a': AgentRunState.idle,
        },
        sessionAgents: {
          'agent-c': agent(AgentRunState.error, id: 'agent-c'),
          'agent-a': agent(AgentRunState.closed, id: 'agent-a'),
          'agent-b': agent(AgentRunState.closed, id: 'agent-b'),
        },
      );

      expect(result.keys, ['agent-b', 'agent-a', 'agent-c']);
      expect(result['agent-c'], AgentRunState.error);
    });

    // extra: an agent that vanished and came back is seeded fresh instead of
    // being compared against a status from before it disappeared.
    test('reseeds an agent that disappeared and returned', () {
      final afterDisappearing = reconcilePreviousAgentStatuses(
        previousStatuses: {'agent-1': AgentRunState.running},
        sessionAgents: {},
      );
      final afterReturning = reconcilePreviousAgentStatuses(
        previousStatuses: afterDisappearing,
        sessionAgents: {'agent-1': agent(AgentRunState.idle)},
      );

      expect(afterReturning, {'agent-1': AgentRunState.idle});
    });
  });

  group('workspace archive pending suppression', () {
    // The registry is module-global, exactly as upstream. Upstream clears
    // explicitly at the end of each case; this tear-down additionally guards
    // against a failing expectation leaking state into the next test.
    tearDown(() {
      for (final serverId in ['server-1', 'server-2', 'archiving-server']) {
        for (final workspaceId in ['/repo/worktree', 'sibling', 'other']) {
          clearWorkspaceArchivePending(
            serverId: serverId,
            workspaceId: workspaceId,
          );
        }
      }
    });

    test('tracks a locally pending workspace archive by id', () {
      markWorkspaceArchivePending(
        serverId: 'server-1',
        workspaceId: '/repo/worktree',
      );

      expect(
        isWorkspaceArchivePending(
          serverId: 'server-1',
          workspaceId: '/repo/worktree',
        ),
        isTrue,
      );
      expect(
        shouldSuppressWorkspaceForLocalArchive(
          serverId: 'server-1',
          workspace: workspaceDescriptor(archivingAt: null),
        ),
        isTrue,
      );

      clearWorkspaceArchivePending(
        serverId: 'server-1',
        workspaceId: '/repo/worktree',
      );

      expect(
        isWorkspaceArchivePending(
          serverId: 'server-1',
          workspaceId: '/repo/worktree',
        ),
        isFalse,
      );
    });

    test('suppresses upserts for a locally pending archive', () {
      markWorkspaceArchivePending(
        serverId: 'server-1',
        workspaceId: '/repo/worktree',
      );

      expect(
        shouldSuppressWorkspaceForLocalArchive(
          serverId: 'server-1',
          workspace: workspaceDescriptor(archivingAt: null),
        ),
        isTrue,
      );

      clearWorkspaceArchivePending(
        serverId: 'server-1',
        workspaceId: '/repo/worktree',
      );
    });

    test(
      'does not suppress a same-cwd sibling whose id is not the one archived',
      () {
        markWorkspaceArchivePending(
          serverId: 'server-1',
          workspaceId: '/repo/worktree',
        );

        expect(
          shouldSuppressWorkspaceForLocalArchive(
            serverId: 'server-1',
            workspace: workspaceDescriptor(
              id: 'sibling',
              workspaceDirectory: '/repo/worktree',
            ),
          ),
          isFalse,
        );

        clearWorkspaceArchivePending(
          serverId: 'server-1',
          workspaceId: '/repo/worktree',
        );
      },
    );

    test('allows upserts when this client did not start the archive', () {
      expect(
        shouldSuppressWorkspaceForLocalArchive(
          serverId: 'server-1',
          workspace: workspaceDescriptor(),
        ),
        isFalse,
      );
    });

    test(
      'suppresses stale normal upserts while a local archive is pending',
      () {
        markWorkspaceArchivePending(
          serverId: 'server-1',
          workspaceId: '/repo/worktree',
        );

        expect(
          shouldSuppressWorkspaceForLocalArchive(
            serverId: 'server-1',
            workspace: workspaceDescriptor(archivingAt: null),
          ),
          isTrue,
        );

        clearWorkspaceArchivePending(
          serverId: 'server-1',
          workspaceId: '/repo/worktree',
        );
      },
    );

    // extra: both sides trim, so padded ids from either the caller or the wire
    // still line up.
    test('matches across surrounding whitespace on both sides', () {
      markWorkspaceArchivePending(
        serverId: '  server-1  ',
        workspaceId: '  /repo/worktree  ',
      );

      expect(
        isWorkspaceArchivePending(
          serverId: 'server-1',
          workspaceId: '/repo/worktree',
        ),
        isTrue,
      );
      expect(
        shouldSuppressWorkspaceForLocalArchive(
          serverId: 'server-1',
          workspace: workspaceDescriptor(id: ' /repo/worktree '),
        ),
        isTrue,
      );

      clearWorkspaceArchivePending(
        serverId: ' server-1 ',
        workspaceId: ' /repo/worktree ',
      );

      expect(
        isWorkspaceArchivePending(
          serverId: 'server-1',
          workspaceId: '/repo/worktree',
        ),
        isFalse,
      );
    });

    // extra: a blank id can never match a real descriptor, so it is dropped
    // rather than stored.
    test('ignores blank server and workspace ids', () {
      markWorkspaceArchivePending(
        serverId: '   ',
        workspaceId: '/repo/worktree',
      );
      markWorkspaceArchivePending(serverId: 'server-1', workspaceId: '   ');

      expect(
        isWorkspaceArchivePending(
          serverId: '   ',
          workspaceId: '/repo/worktree',
        ),
        isFalse,
      );
      expect(
        isWorkspaceArchivePending(
          serverId: 'server-1',
          workspaceId: '/repo/worktree',
        ),
        isFalse,
      );
    });

    // extra: callers hand over an optional descriptor field, and a missing id
    // must not be treated as a wildcard match.
    test('never matches a null workspace id', () {
      markWorkspaceArchivePending(
        serverId: 'server-1',
        workspaceId: '/repo/worktree',
      );

      expect(
        isWorkspaceArchivePending(serverId: 'server-1', workspaceId: null),
        isFalse,
      );

      clearWorkspaceArchivePending(
        serverId: 'server-1',
        workspaceId: '/repo/worktree',
      );
    });

    // extra: two hosts can hold the same workspace id; archiving on one must
    // not hide the other.
    test('scopes pending archives per server', () {
      markWorkspaceArchivePending(
        serverId: 'server-1',
        workspaceId: '/repo/worktree',
      );

      expect(
        isWorkspaceArchivePending(
          serverId: 'server-2',
          workspaceId: '/repo/worktree',
        ),
        isFalse,
      );

      clearWorkspaceArchivePending(
        serverId: 'server-1',
        workspaceId: '/repo/worktree',
      );
    });

    // extra: clearing something never marked, or on an unknown server, is a
    // no-op rather than an error.
    test('clearing an unknown archive leaves the rest intact', () {
      markWorkspaceArchivePending(
        serverId: 'server-1',
        workspaceId: '/repo/worktree',
      );

      clearWorkspaceArchivePending(serverId: 'server-2', workspaceId: 'other');
      clearWorkspaceArchivePending(serverId: 'server-1', workspaceId: 'other');

      expect(
        isWorkspaceArchivePending(
          serverId: 'server-1',
          workspaceId: '/repo/worktree',
        ),
        isTrue,
      );

      clearWorkspaceArchivePending(
        serverId: 'server-1',
        workspaceId: '/repo/worktree',
      );
    });

    // extra: an unknown server short-circuits before the id is even looked at.
    test('reports false for a server with no pending archives', () {
      expect(
        isWorkspaceArchivePending(
          serverId: 'server-2',
          workspaceId: '/repo/worktree',
        ),
        isFalse,
      );
    });
  });

  group('reconcileWorkspaceDirectory', () {
    const serverId = 'workspace-directory-reconciliation';

    tearDown(() {
      for (final workspaceId in ['archiving', 'updated', 'padded']) {
        clearWorkspaceArchivePending(
          serverId: serverId,
          workspaceId: workspaceId,
        );
      }
    });

    test(
      'keeps workspace upserts and removals received during later pages',
      () {
        final result = reconcileWorkspaceDirectory(
          serverId: serverId,
          snapshot: {
            'updated': workspaceDescriptor(
              id: 'updated',
              title: 'snapshot',
              archivingAt: null,
            ),
            'removed': workspaceDescriptor(
              id: 'removed',
              title: 'snapshot',
              archivingAt: null,
            ),
          },
          deltas: [
            WorkspaceUpsertUpdate(
              workspaceDescriptor(
                id: 'updated',
                title: 'live',
                archivingAt: null,
              ),
            ),
            const WorkspaceRemoveUpdate(id: 'removed'),
          ],
        );

        expect(result.values.map((w) => [w.id, w.title]).toList(), [
          ['updated', 'live'],
        ]);
      },
    );

    test(
      'does not restore a locally archiving workspace from a buffered upsert',
      () {
        markWorkspaceArchivePending(
          serverId: serverId,
          workspaceId: 'archiving',
        );
        try {
          final result = reconcileWorkspaceDirectory(
            serverId: serverId,
            snapshot: {},
            deltas: [
              WorkspaceUpsertUpdate(
                workspaceDescriptor(
                  id: 'archiving',
                  title: 'live',
                  archivingAt: null,
                ),
              ),
            ],
          );

          expect(result.containsKey('archiving'), isFalse);
        } finally {
          clearWorkspaceArchivePending(
            serverId: serverId,
            workspaceId: 'archiving',
          );
        }
      },
    );

    // extra: a suppressed upsert actively evicts the stale snapshot row, rather
    // than merely being ignored.
    test('evicts an existing snapshot row when its upsert is suppressed', () {
      markWorkspaceArchivePending(serverId: serverId, workspaceId: 'archiving');
      try {
        final result = reconcileWorkspaceDirectory(
          serverId: serverId,
          snapshot: {
            'archiving': workspaceDescriptor(
              id: 'archiving',
              title: 'snapshot',
              archivingAt: null,
            ),
          },
          deltas: [
            WorkspaceUpsertUpdate(
              workspaceDescriptor(
                id: 'archiving',
                title: 'live',
                archivingAt: null,
              ),
            ),
          ],
        );

        expect(result, isEmpty);
      } finally {
        clearWorkspaceArchivePending(
          serverId: serverId,
          workspaceId: 'archiving',
        );
      }
    });

    // extra: arrival order is the whole point of the replay, so a re-upsert
    // after a remove must win.
    test('applies deltas strictly in arrival order', () {
      final result = reconcileWorkspaceDirectory(
        serverId: serverId,
        snapshot: {},
        deltas: [
          WorkspaceUpsertUpdate(
            workspaceDescriptor(id: 'a', title: 'first', archivingAt: null),
          ),
          const WorkspaceRemoveUpdate(id: 'a'),
          WorkspaceUpsertUpdate(
            workspaceDescriptor(id: 'a', title: 'second', archivingAt: null),
          ),
        ],
      );

      expect(result['a']?.title, 'second');

      final removedLast = reconcileWorkspaceDirectory(
        serverId: serverId,
        snapshot: {},
        deltas: [
          WorkspaceUpsertUpdate(
            workspaceDescriptor(id: 'a', title: 'first', archivingAt: null),
          ),
          const WorkspaceRemoveUpdate(id: 'a'),
        ],
      );

      expect(removedLast, isEmpty);
    });

    // extra: the caller holds the snapshot across the fetch, so it must come
    // back untouched.
    test('does not mutate the snapshot map', () {
      final snapshot = {
        'kept': workspaceDescriptor(
          id: 'kept',
          title: 'snapshot',
          archivingAt: null,
        ),
      };

      final result = reconcileWorkspaceDirectory(
        serverId: serverId,
        snapshot: snapshot,
        deltas: [const WorkspaceRemoveUpdate(id: 'kept')],
      );

      expect(snapshot.keys, ['kept']);
      expect(result, isEmpty);
    });

    // extra: the map key comes from the *normalized* id, so a padded wire id
    // lands under its trimmed form and canonicalizes its directory.
    test('keys upserts by the normalized descriptor id', () {
      final result = reconcileWorkspaceDirectory(
        serverId: serverId,
        snapshot: {},
        deltas: [
          WorkspaceUpsertUpdate(
            workspaceDescriptor(
              id: '  padded  ',
              title: 'live',
              workspaceDirectory: r'C:\repo\padded\\',
              archivingAt: null,
            ),
          ),
        ],
      );

      expect(result.keys, ['padded']);
      expect(result['padded']?.workspaceDirectory, 'C:/repo/padded');
    });

    // extra: an empty delta list is the common case (nothing arrived mid-fetch)
    // and must return the snapshot verbatim.
    test('returns a copy of the snapshot when nothing arrived mid-fetch', () {
      final snapshot = {
        'kept': workspaceDescriptor(
          id: 'kept',
          title: 'snapshot',
          archivingAt: null,
        ),
      };

      final result = reconcileWorkspaceDirectory(
        serverId: serverId,
        snapshot: snapshot,
        deltas: const [],
      );

      expect(result.keys, ['kept']);
      expect(identical(result, snapshot), isFalse);
    });

    // extra: a remove uses the raw wire id, and there is no normalization step
    // on that path upstream either.
    test('removes by the raw delta id', () {
      final result = reconcileWorkspaceDirectory(
        serverId: serverId,
        snapshot: {
          ' padded ': workspaceDescriptor(id: ' padded ', archivingAt: null),
        },
        deltas: [const WorkspaceRemoveUpdate(id: 'padded')],
      );

      expect(result.keys, [' padded ']);
    });
  });

  group('buildSidebarProjection', () {
    test(
      'uses one pin-aware projection for project rows and shortcut order',
      () {
        final projection = buildDefaultProjection();

        expect(
          projection.pinnedGroups.pinnedChats
              .map((e) => e.workspaceId)
              .toList(),
          ['pinned'],
        );
        final remainingProject = projection.pinnedGroups.unpinnedProjects.first;
        expect(remainingProject.workspaces.map((e) => e.workspaceId).toList(), [
          'unpinned',
        ]);
        expect(projection.shortcutModel.shortcutTargets, const [
          SidebarShortcutWorkspaceTarget(
            serverId: 'srv',
            workspaceId: 'pinned',
          ),
          SidebarShortcutWorkspaceTarget(
            serverId: 'srv',
            workspaceId: 'unpinned',
          ),
        ]);
      },
    );

    test(
      'keeps pinned chats above status groups and removes them from those groups',
      () {
        final projection = buildDefaultProjection(
          groupMode: SidebarGroupMode.status,
        );

        expect(projection.statusGroups.map((g) => g.bucket).toList(), [
          WorkspaceStateBucket.needsInput,
        ]);
        expect(
          projection.statusGroups.first.rows.map((e) => e.workspaceId).toList(),
          ['unpinned'],
        );
        expect(projection.shortcutModel.shortcutTargets, const [
          SidebarShortcutWorkspaceTarget(
            serverId: 'srv',
            workspaceId: 'pinned',
          ),
          SidebarShortcutWorkspaceTarget(
            serverId: 'srv',
            workspaceId: 'unpinned',
          ),
        ]);
      },
    );

    test(
      'does not number pinned chats while the pinned section is collapsed',
      () {
        final projection = buildDefaultProjection(
          groupMode: SidebarGroupMode.status,
          pinnedCollapsed: true,
        );

        expect(projection.shortcutModel.shortcutTargets, const [
          SidebarShortcutWorkspaceTarget(
            serverId: 'srv',
            workspaceId: 'unpinned',
          ),
        ]);
      },
    );

    // extra: status groups are only materialized in status mode.
    test('leaves status groups empty in project mode', () {
      expect(buildDefaultProjection().statusGroups, isEmpty);
    });

    // extra: the reverse lookup a row uses to draw its own number must agree
    // with the ordered target list.
    test('indexes shortcuts by workspace key, one-based', () {
      final projection = buildDefaultProjection();

      expect(projection.shortcutModel.shortcutIndexByWorkspaceKey, {
        'srv:pinned': 1,
        'srv:unpinned': 2,
      });
    });

    // extra: with nothing pinned the project list is handed back untouched, so
    // downstream identity checks still short-circuit.
    test('returns the original project list when nothing is pinned', () {
      final only = makeWorkspace('only');
      final projects = [
        makeProject([only.placement]),
      ];

      final projection = buildSidebarProjection(
        projects: projects,
        pinnedKeys: const PinnedSidebarKeys(
          pinnedWorkspaceKeys: [],
          pinnedAtByKey: {},
        ),
        workspaceEntriesByKey: {only.entry.workspaceKey: only.entry},
        projectNamesByKey: const {'project': 'Project'},
        groupMode: SidebarGroupMode.project,
        pinnedCollapsed: false,
        collapsedProjectKeys: const {},
        collapsedStatusGroupKeys: const {},
      );

      expect(projection.pinnedGroups.pinnedChats, isEmpty);
      expect(
        identical(projection.pinnedGroups.unpinnedProjects, projects),
        isTrue,
      );
      expect(
        identical(
          projection.pinnedGroups.unpinnedProjects.first,
          projects.first,
        ),
        isTrue,
      );
    });

    // extra: a project emptied entirely by pinning is dropped, but a project
    // that was already empty is kept so its "new workspace" row stays reachable.
    test('drops a fully pinned project but keeps an already-empty one', () {
      final pinned = makeWorkspace('pinned');
      final projects = [
        makeProject([pinned.placement], projectKey: 'full'),
        makeProject(const [], projectKey: 'empty', projectName: 'Empty'),
      ];

      final projection = buildSidebarProjection(
        projects: projects,
        pinnedKeys: PinnedSidebarKeys(
          pinnedWorkspaceKeys: [pinned.placement.workspaceKey],
          pinnedAtByKey: {
            pinned.placement.workspaceKey: '2026-07-12T12:00:00.000Z',
          },
        ),
        workspaceEntriesByKey: {pinned.entry.workspaceKey: pinned.entry},
        projectNamesByKey: const {},
        groupMode: SidebarGroupMode.project,
        pinnedCollapsed: false,
        collapsedProjectKeys: const {},
        collapsedStatusGroupKeys: const {},
      );

      expect(
        projection.pinnedGroups.unpinnedProjects
            .map((p) => p.projectKey)
            .toList(),
        ['empty'],
      );
    });

    // extra: pin recency drives the order; an unrecorded pin timestamp sinks to
    // the bottom in traversal order rather than throwing.
    test('orders pinned chats most recently pinned first', () {
      final older = makeWorkspace('older');
      final newer = makeWorkspace('newer');
      final untimed = makeWorkspace('untimed');

      final projection = buildSidebarProjection(
        projects: [
          makeProject([older.placement, newer.placement, untimed.placement]),
        ],
        pinnedKeys: PinnedSidebarKeys(
          pinnedWorkspaceKeys: [
            older.placement.workspaceKey,
            newer.placement.workspaceKey,
            untimed.placement.workspaceKey,
          ],
          pinnedAtByKey: {
            older.placement.workspaceKey: '2026-07-01T00:00:00.000Z',
            newer.placement.workspaceKey: '2026-07-12T00:00:00.000Z',
          },
        ),
        workspaceEntriesByKey: const {},
        projectNamesByKey: const {},
        groupMode: SidebarGroupMode.project,
        pinnedCollapsed: false,
        collapsedProjectKeys: const {},
        collapsedStatusGroupKeys: const {},
      );

      expect(
        projection.pinnedGroups.pinnedChats.map((e) => e.workspaceId).toList(),
        ['newer', 'older', 'untimed'],
      );
    });

    // extra: group order is the explicit bucket order, which differs from the
    // protocol enum's declaration order (running vs attention are swapped).
    test(
      'orders status groups needs_input, failed, attention, running, done',
      () {
        final entries = <String, SidebarWorkspaceEntry>{};
        for (final bucket in [
          WorkspaceStateBucket.done,
          WorkspaceStateBucket.running,
          WorkspaceStateBucket.attention,
          WorkspaceStateBucket.failed,
          WorkspaceStateBucket.needsInput,
        ]) {
          final made = makeWorkspace(bucket.wireName, statusBucket: bucket);
          entries[made.entry.workspaceKey] = made.entry;
        }

        final projection = buildSidebarProjection(
          projects: const [],
          pinnedKeys: const PinnedSidebarKeys(
            pinnedWorkspaceKeys: [],
            pinnedAtByKey: {},
          ),
          workspaceEntriesByKey: entries,
          projectNamesByKey: const {},
          groupMode: SidebarGroupMode.status,
          pinnedCollapsed: false,
          collapsedProjectKeys: const {},
          collapsedStatusGroupKeys: const {},
        );

        expect(projection.statusGroups.map((g) => g.bucket).toList(), [
          WorkspaceStateBucket.needsInput,
          WorkspaceStateBucket.failed,
          WorkspaceStateBucket.attention,
          WorkspaceStateBucket.running,
          WorkspaceStateBucket.done,
        ]);
        expect(projection.statusGroups.map((g) => g.label).toList(), [
          'Needs input',
          'Failed',
          'Ready to review',
          'Working',
          'Done',
        ]);
      },
    );

    // extra: within a group, newest transition first; rows with no transition
    // timestamp fall to the bottom and then order by project, name, key.
    test('sorts status rows by recency then project, name, and key', () {
      final untimedB = makeWorkspace(
        'b-untimed',
        projectKey: 'p2',
        name: 'zeta',
      );
      final untimedA = makeWorkspace(
        'a-untimed',
        projectKey: 'p1',
        name: 'alpha',
      );
      final older = makeWorkspace(
        'older',
        statusEnteredAt: DateTime.utc(2026, 7, 1),
      );
      final newer = makeWorkspace(
        'newer',
        statusEnteredAt: DateTime.utc(2026, 7, 12),
      );

      final projection = buildSidebarProjection(
        projects: const [],
        pinnedKeys: const PinnedSidebarKeys(
          pinnedWorkspaceKeys: [],
          pinnedAtByKey: {},
        ),
        workspaceEntriesByKey: {
          untimedB.entry.workspaceKey: untimedB.entry,
          untimedA.entry.workspaceKey: untimedA.entry,
          older.entry.workspaceKey: older.entry,
          newer.entry.workspaceKey: newer.entry,
        },
        projectNamesByKey: const {'p1': 'Alpha project', 'p2': 'Zeta project'},
        groupMode: SidebarGroupMode.status,
        pinnedCollapsed: false,
        collapsedProjectKeys: const {},
        collapsedStatusGroupKeys: const {},
      );

      expect(
        projection.statusGroups.single.rows.map((e) => e.workspaceId).toList(),
        ['newer', 'older', 'a-untimed', 'b-untimed'],
      );
    });

    // extra: a collapsed section is skipped whole, so its rows never consume a
    // shortcut number the user cannot press.
    test('skips collapsed project sections when numbering shortcuts', () {
      final hidden = makeWorkspace('hidden');
      final shown = makeWorkspace('shown');

      final projection = buildSidebarProjection(
        projects: [
          makeProject([hidden.placement], projectKey: 'hidden-project'),
          makeProject([shown.placement], projectKey: 'shown-project'),
        ],
        pinnedKeys: const PinnedSidebarKeys(
          pinnedWorkspaceKeys: [],
          pinnedAtByKey: {},
        ),
        workspaceEntriesByKey: const {},
        projectNamesByKey: const {},
        groupMode: SidebarGroupMode.project,
        pinnedCollapsed: false,
        collapsedProjectKeys: const {'hidden-project'},
        collapsedStatusGroupKeys: const {},
      );

      expect(projection.shortcutModel.shortcutTargets, const [
        SidebarShortcutWorkspaceTarget(serverId: 'srv', workspaceId: 'shown'),
      ]);
    });

    // extra: the same skip applies to collapsed status groups, keyed by the
    // bucket's wire name.
    test('skips collapsed status groups when numbering shortcuts', () {
      final blocked = makeWorkspace(
        'blocked',
        statusBucket: WorkspaceStateBucket.needsInput,
      );
      final finished = makeWorkspace(
        'finished',
        statusBucket: WorkspaceStateBucket.done,
      );

      final projection = buildSidebarProjection(
        projects: const [],
        pinnedKeys: const PinnedSidebarKeys(
          pinnedWorkspaceKeys: [],
          pinnedAtByKey: {},
        ),
        workspaceEntriesByKey: {
          blocked.entry.workspaceKey: blocked.entry,
          finished.entry.workspaceKey: finished.entry,
        },
        projectNamesByKey: const {},
        groupMode: SidebarGroupMode.status,
        pinnedCollapsed: false,
        collapsedProjectKeys: const {},
        collapsedStatusGroupKeys: const {'needs_input'},
      );

      expect(projection.statusGroups.map((g) => g.bucket).toList(), [
        WorkspaceStateBucket.needsInput,
        WorkspaceStateBucket.done,
      ]);
      expect(projection.shortcutModel.shortcutTargets, const [
        SidebarShortcutWorkspaceTarget(
          serverId: 'srv',
          workspaceId: 'finished',
        ),
      ]);
    });

    // extra: shortcuts are single digits, so numbering stops after nine rows
    // even though the rows themselves keep rendering.
    test('numbers at most nine rows', () {
      final made = [for (var i = 0; i < 12; i += 1) makeWorkspace('ws-$i')];

      final projection = buildSidebarProjection(
        projects: [
          makeProject([for (final w in made) w.placement]),
        ],
        pinnedKeys: const PinnedSidebarKeys(
          pinnedWorkspaceKeys: [],
          pinnedAtByKey: {},
        ),
        workspaceEntriesByKey: const {},
        projectNamesByKey: const {},
        groupMode: SidebarGroupMode.project,
        pinnedCollapsed: false,
        collapsedProjectKeys: const {},
        collapsedStatusGroupKeys: const {},
      );

      expect(projection.shortcutModel.shortcutTargets.length, 9);
      expect(projection.shortcutModel.shortcutTargets.last.workspaceId, 'ws-8');
      expect(
        projection.shortcutModel.shortcutIndexByWorkspaceKey.containsKey(
          'srv:ws-9',
        ),
        isFalse,
      );
    });

    // extra: the pinned section is numbered first even when it is the only
    // section, and pinned rows still count against the nine-row budget.
    test('spends the shortcut budget on pinned rows first', () {
      final made = [for (var i = 0; i < 10; i += 1) makeWorkspace('ws-$i')];
      final pinnedKeys = [for (var i = 0; i < 9; i += 1) 'srv:ws-$i'];

      final projection = buildSidebarProjection(
        projects: [
          makeProject([for (final w in made) w.placement]),
        ],
        pinnedKeys: PinnedSidebarKeys(
          pinnedWorkspaceKeys: pinnedKeys,
          pinnedAtByKey: {
            for (var i = 0; i < 9; i += 1)
              'srv:ws-$i': '2026-07-0${9 - i}T00:00:00.000Z',
          },
        ),
        workspaceEntriesByKey: const {},
        projectNamesByKey: const {},
        groupMode: SidebarGroupMode.project,
        pinnedCollapsed: false,
        collapsedProjectKeys: const {},
        collapsedStatusGroupKeys: const {},
      );

      expect(projection.shortcutModel.shortcutTargets.length, 9);
      expect(
        projection.shortcutModel.shortcutTargets.first.workspaceId,
        'ws-0',
      );
      expect(
        projection.shortcutModel.shortcutIndexByWorkspaceKey.containsKey(
          'srv:ws-9',
        ),
        isFalse,
      );
    });
  });
}
