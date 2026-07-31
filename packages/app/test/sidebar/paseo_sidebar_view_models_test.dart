import 'package:agent_protocol/agent_protocol.dart'
    show
        WorkspaceDescriptor,
        WorkspaceKind,
        WorkspaceProjectKind,
        WorkspaceStateBucket;
import 'package:coding_agent_app/composer/create_agent_preferences.dart';
import 'package:coding_agent_app/sidebar/paseo_sidebar_view_models.dart';
import 'package:coding_agent_app/sidebar/workspace_agent_activity.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Builders — the Dart analogues of the upstream suites' `placement()`,
// `project()` and `ws()` fixtures.
// ---------------------------------------------------------------------------

SidebarWorkspacePlacement placement(
  String workspaceKey, {
  String serverId = 's1',
  String? workspaceId,
  String projectKey = 'p1',
  String projectName = 'Project 1',
  String? name,
}) => SidebarWorkspacePlacement(
  workspaceKey: workspaceKey,
  serverId: serverId,
  workspaceId: workspaceId ?? workspaceKey,
  projectKey: projectKey,
  projectName: projectName,
  projectKind: WorkspaceProjectKind.git,
  workspaceKind: WorkspaceKind.worktree,
  name: name ?? workspaceKey,
);

SidebarWorkspaceProjectEntry project(
  String projectKey,
  List<SidebarWorkspacePlacement> workspaces,
) => SidebarWorkspaceProjectEntry(
  projectKey: projectKey,
  projectName: projectKey,
  projectKind: WorkspaceProjectKind.git,
  iconWorkingDir: '',
  hosts: const [],
  workspaces: workspaces,
);

SidebarWorkspaceEntry ws(
  String workspaceKey, {
  String serverId = 'srv',
  String? workspaceId,
  String projectKey = 'proj',
  String projectName = 'Project',
  String name = 'main',
  WorkspaceStateBucket statusBucket = WorkspaceStateBucket.done,
  DateTime? statusEnteredAt,
}) => SidebarWorkspaceEntry(
  workspaceKey: workspaceKey,
  serverId: serverId,
  workspaceId:
      workspaceId ??
      (workspaceKey.contains(':') ? workspaceKey.split(':')[1] : 'ws'),
  projectKey: projectKey,
  projectName: projectName,
  projectKind: WorkspaceProjectKind.git,
  workspaceKind: WorkspaceKind.worktree,
  name: name,
  statusBucket: statusBucket,
  statusEnteredAt: statusEnteredAt,
);

DateTime d(String iso) => DateTime.parse(iso);

PinnedSidebarKeys keys(Map<String, String> pinnedAtByKey) => PinnedSidebarKeys(
  pinnedWorkspaceKeys: pinnedAtByKey.keys.toList(),
  pinnedAtByKey: pinnedAtByKey,
);

const emptyProjectNames = <String, String>{};

Map<String, WorkspaceDescriptor> workspaceMap() =>
    <String, WorkspaceDescriptor>{};

Map<String, WorkspaceAgentActivity> activityMap() =>
    <String, WorkspaceAgentActivity>{};

SidebarWorkspaceSessionSource sidebarSession({
  Map<String, WorkspaceDescriptor>? workspaces,
  Map<String, WorkspaceAgentActivity>? workspaceAgentActivity,
}) => SidebarWorkspaceSessionSource(
  workspaces: workspaces ?? workspaceMap(),
  workspaceAgentActivity: workspaceAgentActivity ?? activityMap(),
);

final class _MemoryStorage implements CreateAgentPreferenceStorage {
  _MemoryStorage({this.value, this.failReads = false});

  Object? value;
  bool failReads;
  int readCount = 0;
  final writes = <CreateAgentPreferences>[];

  @override
  Future<Object?> read() async {
    readCount += 1;
    if (failReads) throw StateError('storage unavailable');
    return value;
  }

  @override
  Future<void> write(CreateAgentPreferences preferences) async {
    writes.add(preferences);
    value = preferences.toJson();
  }
}

void main() {
  // -------------------------------------------------------------------------
  // use-sidebar-pins.ts — buildPinnedSidebarKeys
  // -------------------------------------------------------------------------

  group('buildPinnedSidebarKeys', () {
    test('collects pinned keys in project-then-workspace traversal order', () {
      final result = buildPinnedSidebarKeys(
        projects: [
          project('p1', [placement('w1'), placement('w2')]),
          project('p2', [placement('w3', projectKey: 'p2')]),
        ],
        pinnedAtByServerAndWorkspaceId: {
          's1': {'w1': '2026-01-01T00:00:00Z', 'w3': '2026-02-01T00:00:00Z'},
        },
      );

      expect(result.pinnedWorkspaceKeys, ['w1', 'w3']);
      expect(result.pinnedAtByKey, {
        'w1': '2026-01-01T00:00:00Z',
        'w3': '2026-02-01T00:00:00Z',
      });
    });

    test('treats a null pinnedAt as unpinned', () {
      final result = buildPinnedSidebarKeys(
        projects: [
          project('p1', [placement('w1')]),
        ],
        pinnedAtByServerAndWorkspaceId: {
          's1': {'w1': null},
        },
      );

      expect(result.pinnedWorkspaceKeys, isEmpty);
      expect(result.pinnedAtByKey, isEmpty);
    });

    test('treats an empty-string pinnedAt as unpinned (JS truthiness)', () {
      final result = buildPinnedSidebarKeys(
        projects: [
          project('p1', [placement('w1'), placement('w2')]),
        ],
        pinnedAtByServerAndWorkspaceId: {
          's1': {'w1': '', 'w2': '2026-01-01T00:00:00Z'},
        },
      );

      expect(result.pinnedWorkspaceKeys, ['w2']);
    });

    test('skips placements whose host or workspace is missing', () {
      final result = buildPinnedSidebarKeys(
        projects: [
          project('p1', [
            placement('w1', serverId: 'absent-host'),
            placement('w2'),
          ]),
        ],
        pinnedAtByServerAndWorkspaceId: {
          's1': {'other': '2026-01-01T00:00:00Z'},
        },
      );

      expect(result.pinnedWorkspaceKeys, isEmpty);
    });

    test('looks up by workspaceId, not by workspaceKey', () {
      final result = buildPinnedSidebarKeys(
        projects: [
          project('p1', [placement('s1:w1', workspaceId: 'w1')]),
        ],
        pinnedAtByServerAndWorkspaceId: {
          's1': {'w1': '2026-01-01T00:00:00Z'},
        },
      );

      expect(result.pinnedWorkspaceKeys, ['s1:w1']);
      expect(result.pinnedAtByKey['s1:w1'], '2026-01-01T00:00:00Z');
    });

    test('returns empty keys for no projects', () {
      final result = buildPinnedSidebarKeys(
        projects: const [],
        pinnedAtByServerAndWorkspaceId: const {},
      );

      expect(result.pinnedWorkspaceKeys, isEmpty);
      expect(result.pinnedAtByKey, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // use-sidebar-pins.ts — arePinnedSidebarKeysEqual
  // -------------------------------------------------------------------------

  group('arePinnedSidebarKeysEqual', () {
    test('equal for the same keys and timestamps', () {
      expect(
        arePinnedSidebarKeysEqual(
          keys({'w1': '2026-01-01T00:00:00Z', 'w2': '2026-02-01T00:00:00Z'}),
          keys({'w1': '2026-01-01T00:00:00Z', 'w2': '2026-02-01T00:00:00Z'}),
        ),
        isTrue,
      );
    });

    test('unequal when the key count differs', () {
      expect(
        arePinnedSidebarKeysEqual(
          keys({'w1': '2026-01-01T00:00:00Z'}),
          keys({'w1': '2026-01-01T00:00:00Z', 'w2': '2026-01-01T00:00:00Z'}),
        ),
        isFalse,
      );
    });

    test('unequal when a key moved position', () {
      expect(
        arePinnedSidebarKeysEqual(
          keys({'w1': '2026-01-01T00:00:00Z', 'w2': '2026-01-01T00:00:00Z'}),
          keys({'w2': '2026-01-01T00:00:00Z', 'w1': '2026-01-01T00:00:00Z'}),
        ),
        isFalse,
      );
    });

    test('unequal when a pin timestamp moved', () {
      expect(
        arePinnedSidebarKeysEqual(
          keys({'w1': '2026-01-01T00:00:00Z'}),
          keys({'w1': '2026-06-01T00:00:00Z'}),
        ),
        isFalse,
      );
    });

    test('an empty workspaceKey skips the timestamp comparison', () {
      // Upstream's `(workspaceKey && ...)` guard: a falsy key compares by
      // position only, so its pinnedAt change goes unnoticed.
      expect(
        arePinnedSidebarKeysEqual(
          keys({'': '2026-01-01T00:00:00Z'}),
          keys({'': '2026-06-01T00:00:00Z'}),
        ),
        isTrue,
      );
    });

    test('two empty snapshots are equal', () {
      expect(arePinnedSidebarKeysEqual(keys({}), keys({})), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // use-sidebar-pins.ts — PinnedSidebarKeysRetainer
  // -------------------------------------------------------------------------

  group('PinnedSidebarKeysRetainer', () {
    final projects = [
      project('p1', [placement('w1')]),
    ];

    test('starts on an empty snapshot', () {
      expect(PinnedSidebarKeysRetainer().current.pinnedWorkspaceKeys, isEmpty);
    });

    test('hands back the identical instance when nothing moved', () {
      final retainer = PinnedSidebarKeysRetainer();
      final first = retainer.update(
        projects: projects,
        pinnedAtByServerAndWorkspaceId: {
          's1': {'w1': '2026-01-01T00:00:00Z'},
        },
      );
      final second = retainer.update(
        projects: projects,
        // A fresh index object with the same content: exactly the case the
        // retention exists for.
        pinnedAtByServerAndWorkspaceId: {
          's1': {'w1': '2026-01-01T00:00:00Z'},
        },
      );

      expect(identical(first, second), isTrue);
    });

    test('publishes a new instance when a pin timestamp moves', () {
      final retainer = PinnedSidebarKeysRetainer();
      final first = retainer.update(
        projects: projects,
        pinnedAtByServerAndWorkspaceId: {
          's1': {'w1': '2026-01-01T00:00:00Z'},
        },
      );
      final second = retainer.update(
        projects: projects,
        pinnedAtByServerAndWorkspaceId: {
          's1': {'w1': '2026-06-01T00:00:00Z'},
        },
      );

      expect(identical(first, second), isFalse);
      expect(second.pinnedAtByKey['w1'], '2026-06-01T00:00:00Z');
      expect(identical(retainer.current, second), isTrue);
    });

    test('publishes a new instance when a pin is removed', () {
      final retainer = PinnedSidebarKeysRetainer();
      final first = retainer.update(
        projects: projects,
        pinnedAtByServerAndWorkspaceId: {
          's1': {'w1': '2026-01-01T00:00:00Z'},
        },
      );
      final second = retainer.update(
        projects: projects,
        pinnedAtByServerAndWorkspaceId: const {},
      );

      expect(identical(first, second), isFalse);
      expect(second.pinnedWorkspaceKeys, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // use-sidebar-pins.ts — splitPinnedSidebarGroups
  // -------------------------------------------------------------------------

  group('splitPinnedSidebarGroups', () {
    test('drops the empty shell when every chat of a project is pinned', () {
      final only = placement('w1');
      final result = splitPinnedSidebarGroups(
        projects: [
          project('p1', [only]),
        ],
        keys: keys({'w1': '2026-01-01T00:00:00Z'}),
      );

      expect(result.pinnedChats, hasLength(1));
      expect(result.unpinnedProjects, isEmpty);
    });

    test('keeps a genuinely empty project so its new-workspace row stays '
        'reachable', () {
      final result = splitPinnedSidebarGroups(
        projects: [project('p1', const [])],
        keys: const PinnedSidebarKeys(
          pinnedWorkspaceKeys: [],
          pinnedAtByKey: {},
        ),
      );

      expect(result.unpinnedProjects, hasLength(1));
    });

    test(
      'keeps a genuinely empty project even when other projects are pinned',
      () {
        // The `pinnedWorkspaceKeys.isEmpty` fast path is not what keeps it — the
        // real loop has to reach the same conclusion.
        final result = splitPinnedSidebarGroups(
          projects: [
            project('empty', const []),
            project('p1', [placement('w1')]),
          ],
          keys: keys({'w1': '2026-01-01T00:00:00Z'}),
        );

        expect(result.unpinnedProjects.map((project) => project.projectKey), [
          'empty',
        ]);
      },
    );

    test('keeps remaining chats when only some are pinned', () {
      final result = splitPinnedSidebarGroups(
        projects: [
          project('p1', [placement('w1'), placement('w2')]),
        ],
        keys: keys({'w1': '2026-01-01T00:00:00Z'}),
      );

      expect(result.pinnedChats.map((workspace) => workspace.workspaceKey), [
        'w1',
      ]);
      expect(
        result.unpinnedProjects.first.workspaces.map(
          (workspace) => workspace.workspaceKey,
        ),
        ['w2'],
      );
    });

    test('orders pinned chats by most-recently-pinned first', () {
      final result = splitPinnedSidebarGroups(
        projects: [
          project('p1', [placement('older'), placement('newer')]),
        ],
        keys: keys({
          'older': '2026-01-01T00:00:00Z',
          'newer': '2026-02-01T00:00:00Z',
        }),
      );

      expect(result.pinnedChats.map((workspace) => workspace.workspaceKey), [
        'newer',
        'older',
      ]);
    });

    test('orders pinned chats across projects by pin recency', () {
      final result = splitPinnedSidebarGroups(
        projects: [
          project('p1', [placement('a'), placement('b')]),
          project('p2', [placement('c', projectKey: 'p2')]),
        ],
        keys: keys({
          'a': '2026-01-01T00:00:00Z',
          'b': '2026-03-01T00:00:00Z',
          'c': '2026-02-01T00:00:00Z',
        }),
      );

      expect(result.pinnedChats.map((workspace) => workspace.workspaceKey), [
        'b',
        'c',
        'a',
      ]);
      expect(result.unpinnedProjects, isEmpty);
    });

    test('sinks pins with no recorded timestamp to the bottom in project '
        'order', () {
      // Dart's List.sort is not stable; this pins the stable-sort tiebreak.
      final result = splitPinnedSidebarGroups(
        projects: [
          project('p1', [
            placement('no-time-a'),
            placement('timed'),
            placement('no-time-b'),
          ]),
        ],
        keys: const PinnedSidebarKeys(
          pinnedWorkspaceKeys: ['no-time-a', 'timed', 'no-time-b'],
          pinnedAtByKey: {'timed': '2026-01-01T00:00:00Z'},
        ),
      );

      expect(result.pinnedChats.map((workspace) => workspace.workspaceKey), [
        'timed',
        'no-time-a',
        'no-time-b',
      ]);
    });

    test('keeps equal pin timestamps in project order', () {
      final result = splitPinnedSidebarGroups(
        projects: [
          project('p1', [placement('first'), placement('second')]),
        ],
        keys: keys({
          'first': '2026-01-01T00:00:00Z',
          'second': '2026-01-01T00:00:00Z',
        }),
      );

      expect(result.pinnedChats.map((workspace) => workspace.workspaceKey), [
        'first',
        'second',
      ]);
    });

    test('returns the caller\'s own project list when nothing is pinned', () {
      final projects = [
        project('p1', [placement('w1')]),
      ];
      final result = splitPinnedSidebarGroups(
        projects: projects,
        keys: const PinnedSidebarKeys(
          pinnedWorkspaceKeys: [],
          pinnedAtByKey: {},
        ),
      );

      expect(identical(result.unpinnedProjects, projects), isTrue);
      expect(result.pinnedChats, isEmpty);
    });

    test('reuses the project instance when none of its chats were pinned', () {
      final untouched = project('p2', [placement('w2', projectKey: 'p2')]);
      final result = splitPinnedSidebarGroups(
        projects: [
          project('p1', [placement('w1'), placement('w1b')]),
          untouched,
        ],
        keys: keys({'w1': '2026-01-01T00:00:00Z'}),
      );

      expect(identical(result.unpinnedProjects.last, untouched), isTrue);
    });

    test('ignores pinned keys that match no visible workspace', () {
      final result = splitPinnedSidebarGroups(
        projects: [
          project('p1', [placement('w1')]),
        ],
        keys: keys({'ghost': '2026-01-01T00:00:00Z'}),
      );

      expect(result.pinnedChats, isEmpty);
      expect(result.unpinnedProjects, hasLength(1));
      expect(result.unpinnedProjects.first.workspaces, hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  // sidebar-status-view-model.ts — buildStatusGroups
  // -------------------------------------------------------------------------

  group('buildStatusGroups', () {
    test('groups workspaces by status bucket in fixed order', () {
      final groups = buildStatusGroups([
        ws(
          'srv:done-ws',
          statusBucket: WorkspaceStateBucket.done,
          name: 'done-ws',
        ),
        ws(
          'srv:needs-input-ws',
          statusBucket: WorkspaceStateBucket.needsInput,
          name: 'needs-input-ws',
        ),
        ws(
          'srv:running-ws',
          statusBucket: WorkspaceStateBucket.running,
          name: 'running-ws',
        ),
      ], emptyProjectNames);

      expect(groups.map((group) => group.bucket), [
        WorkspaceStateBucket.needsInput,
        WorkspaceStateBucket.running,
        WorkspaceStateBucket.done,
      ]);
      expect(groups[0].label, 'Needs input');
      expect(groups[1].label, 'Working');
      expect(groups[2].label, 'Done');
    });

    test('omits empty buckets', () {
      final groups = buildStatusGroups([
        ws('srv:a', statusBucket: WorkspaceStateBucket.done),
        ws('srv:b', statusBucket: WorkspaceStateBucket.running),
      ], emptyProjectNames);

      expect(groups.map((group) => group.bucket), [
        WorkspaceStateBucket.running,
        WorkspaceStateBucket.done,
      ]);
    });

    test('sorts by statusEnteredAt desc within a bucket', () {
      final groups = buildStatusGroups([
        ws('srv:old', statusEnteredAt: d('2026-01-01T00:00:00Z')),
        ws('srv:new', statusEnteredAt: d('2026-06-01T00:00:00Z')),
        ws('srv:mid', statusEnteredAt: d('2026-03-01T00:00:00Z')),
      ], emptyProjectNames);

      expect(groups[0].rows.map((row) => row.workspaceKey), [
        'srv:new',
        'srv:mid',
        'srv:old',
      ]);
    });

    test('sorts null timestamps last within a bucket', () {
      final groups = buildStatusGroups([
        ws('srv:null-a'),
        ws('srv:ts', statusEnteredAt: d('2026-01-01T00:00:00Z')),
        ws('srv:null-b'),
      ], emptyProjectNames);

      expect(groups[0].rows.map((row) => row.workspaceKey), [
        'srv:ts',
        'srv:null-a',
        'srv:null-b',
      ]);
    });

    test('tie-breaks by project name, then workspace name, then '
        'workspaceKey', () {
      final groups = buildStatusGroups(
        [
          ws('srv:1', projectKey: 'proj-b', name: 'zebra'),
          ws('srv:2', projectKey: 'proj-a', name: 'alpha'),
          ws('srv:3', projectKey: 'proj-a', name: 'alpha'),
        ],
        const {'proj-b': 'Beta', 'proj-a': 'Alpha'},
      );

      expect(groups[0].rows.map((row) => row.workspaceKey), [
        'srv:2',
        'srv:3',
        'srv:1',
      ]);
    });

    test('falls through to the name tiebreak when timestamps are equal', () {
      final at = d('2026-01-01T00:00:00Z');
      final groups = buildStatusGroups([
        ws('srv:z', name: 'zebra', statusEnteredAt: at),
        ws('srv:a', name: 'alpha', statusEnteredAt: at),
      ], emptyProjectNames);

      expect(groups[0].rows.map((row) => row.workspaceKey), ['srv:a', 'srv:z']);
    });

    test('sorts an unknown projectKey ahead of every named project', () {
      // A missing entry reads as "", which is lexicographically smallest.
      final groups = buildStatusGroups(
        [
          ws('srv:named', projectKey: 'proj-a'),
          ws('srv:unknown', projectKey: 'proj-missing'),
        ],
        const {'proj-a': 'Alpha'},
      );

      expect(groups[0].rows.map((row) => row.workspaceKey), [
        'srv:unknown',
        'srv:named',
      ]);
    });

    test('keeps fully-tied rows in input order', () {
      // Every comparator field ties, so only the stable-sort tiebreak decides.
      final first = ws('srv:same', name: 'a');
      final second = ws('srv:same', name: 'a');
      final groups = buildStatusGroups([first, second], emptyProjectNames);

      expect(identical(groups[0].rows[0], first), isTrue);
      expect(identical(groups[0].rows[1], second), isTrue);
    });

    test('does not mutate the caller\'s workspace list', () {
      final workspaces = [
        ws('srv:old', statusEnteredAt: d('2026-01-01T00:00:00Z')),
        ws('srv:new', statusEnteredAt: d('2026-06-01T00:00:00Z')),
      ];
      buildStatusGroups(workspaces, emptyProjectNames);

      expect(workspaces.map((row) => row.workspaceKey), ['srv:old', 'srv:new']);
    });

    test('returns an empty list for no workspaces', () {
      expect(buildStatusGroups(const [], emptyProjectNames), isEmpty);
    });

    test('uses hydrated workspace entries with real status, not structural '
        'placeholders', () {
      final at = d('2026-01-01T00:00:00Z');
      final groups = buildStatusGroups([
        ws(
          'srv:ni',
          statusBucket: WorkspaceStateBucket.needsInput,
          statusEnteredAt: at,
        ),
        ws(
          'srv:fail',
          statusBucket: WorkspaceStateBucket.failed,
          statusEnteredAt: at,
        ),
        ws(
          'srv:att',
          statusBucket: WorkspaceStateBucket.attention,
          statusEnteredAt: at,
        ),
        ws(
          'srv:run',
          statusBucket: WorkspaceStateBucket.running,
          statusEnteredAt: at,
        ),
        ws('srv:dn', statusBucket: WorkspaceStateBucket.done),
      ], emptyProjectNames);

      expect(groups.map((group) => group.bucket), statusBucketOrder);
      expect(
        groups.map((group) => group.label),
        statusBucketOrder.map((bucket) => statusBucketLabels[bucket]),
      );
      for (final group in groups) {
        expect(group.rows, hasLength(1));
        expect(group.rows.first.statusBucket, group.bucket);
      }
    });

    test('orders attention ahead of running, unlike the protocol enum', () {
      // WorkspaceStateBucket declares running before attention; the sidebar
      // must not inherit that order.
      final groups = buildStatusGroups([
        ws('srv:run', statusBucket: WorkspaceStateBucket.running),
        ws('srv:att', statusBucket: WorkspaceStateBucket.attention),
      ], emptyProjectNames);

      expect(groups.map((group) => group.bucket), [
        WorkspaceStateBucket.attention,
        WorkspaceStateBucket.running,
      ]);
    });
  });

  // -------------------------------------------------------------------------
  // sidebar-status-view-model.ts — buildStatusShortcutIndex
  // -------------------------------------------------------------------------

  group('buildStatusShortcutIndex', () {
    test('assigns sequential numbers in status visual order', () {
      final index = buildStatusShortcutIndex([
        StatusGroup(
          bucket: WorkspaceStateBucket.needsInput,
          label: 'Needs input',
          rows: [ws('srv:ni')],
        ),
        StatusGroup(
          bucket: WorkspaceStateBucket.running,
          label: 'Working',
          rows: [ws('srv:run'), ws('srv:run2')],
        ),
        StatusGroup(
          bucket: WorkspaceStateBucket.done,
          label: 'Done',
          rows: [ws('srv:dn')],
        ),
      ]);

      expect(index['srv:ni'], 1);
      expect(index['srv:run'], 2);
      expect(index['srv:run2'], 3);
      expect(index['srv:dn'], 4);
    });

    test('stops at 9 shortcuts', () {
      final index = buildStatusShortcutIndex([
        StatusGroup(
          bucket: WorkspaceStateBucket.done,
          label: 'Done',
          rows: [for (var i = 0; i < 12; i += 1) ws('srv:ws$i')],
        ),
      ]);

      expect(index, hasLength(statusShortcutLimit));
      expect(index.containsKey('srv:ws8'), isTrue);
      expect(index.containsKey('srv:ws9'), isFalse);
    });

    test('stops mid-group, not at a group boundary', () {
      final index = buildStatusShortcutIndex([
        StatusGroup(
          bucket: WorkspaceStateBucket.needsInput,
          label: 'Needs input',
          rows: [for (var i = 0; i < 8; i += 1) ws('srv:a$i')],
        ),
        StatusGroup(
          bucket: WorkspaceStateBucket.done,
          label: 'Done',
          rows: [ws('srv:b0'), ws('srv:b1')],
        ),
      ]);

      expect(index['srv:b0'], 9);
      expect(index.containsKey('srv:b1'), isFalse);
    });

    test('a repeated workspaceKey still consumes its number', () {
      final index = buildStatusShortcutIndex([
        StatusGroup(
          bucket: WorkspaceStateBucket.done,
          label: 'Done',
          rows: [ws('srv:dup'), ws('srv:dup'), ws('srv:third')],
        ),
      ]);

      // The later write wins the entry, and the third row is still numbered 3.
      expect(index['srv:dup'], 2);
      expect(index['srv:third'], 3);
    });

    test('returns an empty map for empty groups', () {
      expect(buildStatusShortcutIndex(const []), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // use-sidebar-workspace-entries.ts — session selection
  // -------------------------------------------------------------------------

  group('sidebar workspace session selection', () {
    test('selects only sessions needed by sidebar placements', () {
      final hostA = sidebarSession();
      final hostB = sidebarSession();

      final selected = selectSidebarWorkspaceSessions(
        {'host-a': hostA, 'host-b': hostB, 'unused': sidebarSession()},
        ['host-b', 'missing', 'host-a'],
      );

      expect(selected.map((session) => session.serverId), ['host-b', 'host-a']);
      expect(identical(selected[0].workspaces, hostB.workspaces), isTrue);
      expect(
        identical(
          selected[0].workspaceAgentActivity,
          hostB.workspaceAgentActivity,
        ),
        isTrue,
      );
      expect(identical(selected[1].workspaces, hostA.workspaces), isTrue);
      expect(
        identical(
          selected[1].workspaceAgentActivity,
          hostA.workspaceAgentActivity,
        ),
        isTrue,
      );
    });

    test('skips an explicitly null session entry', () {
      final selected = selectSidebarWorkspaceSessions(
        {'host-a': null, 'host-b': sidebarSession()},
        ['host-a', 'host-b'],
      );

      expect(selected.map((session) => session.serverId), ['host-b']);
    });

    test('repeats a slice when a serverId repeats', () {
      final selected = selectSidebarWorkspaceSessions(
        {'host-a': sidebarSession()},
        ['host-a', 'host-a'],
      );

      expect(selected, hasLength(2));
    });

    test('returns nothing when no serverIds are requested', () {
      expect(
        selectSidebarWorkspaceSessions({'host-a': sidebarSession()}, const []),
        isEmpty,
      );
    });

    test('ignores high-frequency session changes outside the sidebar '
        'indexes', () {
      final workspaces = workspaceMap();
      final workspaceAgentActivity = activityMap();

      final previous = selectSidebarWorkspaceSessions(
        {
          'host-a': sidebarSession(
            workspaces: workspaces,
            workspaceAgentActivity: workspaceAgentActivity,
          ),
        },
        ['host-a'],
      );
      final next = selectSidebarWorkspaceSessions(
        {
          'host-a': sidebarSession(
            workspaces: workspaces,
            workspaceAgentActivity: workspaceAgentActivity,
          ),
        },
        ['host-a'],
      );

      expect(identical(previous, next), isFalse);
      expect(areSidebarWorkspaceSessionsEqual(previous, next), isTrue);
    });

    test('detects changes to a selected workspace or activity index', () {
      final workspaceAgentActivity = activityMap();
      final previous = selectSidebarWorkspaceSessions(
        {
          'host-a': sidebarSession(
            workspaces: workspaceMap(),
            workspaceAgentActivity: workspaceAgentActivity,
          ),
        },
        ['host-a'],
      );
      final next = selectSidebarWorkspaceSessions(
        {
          'host-a': sidebarSession(
            workspaces: workspaceMap(),
            workspaceAgentActivity: workspaceAgentActivity,
          ),
        },
        ['host-a'],
      );

      expect(areSidebarWorkspaceSessionsEqual(previous, next), isFalse);
    });

    test('detects a changed activity index alone', () {
      final workspaces = workspaceMap();
      final previous = selectSidebarWorkspaceSessions(
        {
          'host-a': sidebarSession(
            workspaces: workspaces,
            workspaceAgentActivity: activityMap(),
          ),
        },
        ['host-a'],
      );
      final next = selectSidebarWorkspaceSessions(
        {
          'host-a': sidebarSession(
            workspaces: workspaces,
            workspaceAgentActivity: activityMap(),
          ),
        },
        ['host-a'],
      );

      expect(areSidebarWorkspaceSessionsEqual(previous, next), isFalse);
    });

    test('unequal when the selection length differs', () {
      final session = sidebarSession();
      expect(
        areSidebarWorkspaceSessionsEqual(
          selectSidebarWorkspaceSessions({'host-a': session}, ['host-a']),
          selectSidebarWorkspaceSessions(
            {'host-a': session, 'host-b': session},
            ['host-a', 'host-b'],
          ),
        ),
        isFalse,
      );
    });

    test('unequal when the host order differs', () {
      final hostA = sidebarSession();
      final hostB = sidebarSession();
      final sessions = {'host-a': hostA, 'host-b': hostB};

      expect(
        areSidebarWorkspaceSessionsEqual(
          selectSidebarWorkspaceSessions(sessions, ['host-a', 'host-b']),
          selectSidebarWorkspaceSessions(sessions, ['host-b', 'host-a']),
        ),
        isFalse,
      );
    });

    test('two empty selections are equal', () {
      expect(areSidebarWorkspaceSessionsEqual(const [], const []), isTrue);
    });
  });

  group('sidebarPlacementServerIds', () {
    test('dedupes hosts, preserving first-seen order', () {
      expect(
        sidebarPlacementServerIds([
          placement('w1', serverId: 'b'),
          placement('w2', serverId: 'a'),
          placement('w3', serverId: 'b'),
        ]),
        ['b', 'a'],
      );
    });

    test('returns nothing for no placements', () {
      expect(sidebarPlacementServerIds(const []), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // use-sidebar-workspace-entries.ts — SidebarWorkspaceEntriesRetainer
  // -------------------------------------------------------------------------

  group('SidebarWorkspaceEntriesRetainer', () {
    final placements = [placement('s1:w1', workspaceId: 'w1')];
    final sessions = [
      SidebarWorkspaceSession(
        serverId: 's1',
        workspaces: workspaceMap(),
        workspaceAgentActivity: activityMap(),
      ),
    ];

    test('builds entries and remembers them', () {
      final retainer = SidebarWorkspaceEntriesRetainer(
        buildEntries:
            ({
              required placements,
              required sessions,
              required previousEntries,
            }) => {'s1:w1': ws('s1:w1')},
      );

      final entries = retainer.update(
        placements: placements,
        sessions: sessions,
      );

      expect(entries.keys, ['s1:w1']);
      expect(identical(retainer.current, entries), isTrue);
    });

    test('threads the previous build into the next one', () {
      final seen = <Map<String, SidebarWorkspaceEntry>>[];
      final retainer = SidebarWorkspaceEntriesRetainer(
        buildEntries:
            ({
              required placements,
              required sessions,
              required previousEntries,
            }) {
              seen.add(previousEntries);
              return {'s1:w1': ws('s1:w1')};
            },
      );

      final first = retainer.update(placements: placements, sessions: sessions);
      retainer.update(placements: placements, sessions: sessions);

      expect(seen[0], isEmpty);
      expect(identical(seen[1], first), isTrue);
    });

    test('a disabled sidebar retains its rows and never builds', () {
      var buildCount = 0;
      final retainer = SidebarWorkspaceEntriesRetainer(
        buildEntries:
            ({
              required placements,
              required sessions,
              required previousEntries,
            }) {
              buildCount += 1;
              return {'s1:w1': ws('s1:w1')};
            },
      );

      final first = retainer.update(placements: placements, sessions: sessions);
      final second = retainer.update(
        placements: placements,
        sessions: sessions,
        enabled: false,
      );

      expect(buildCount, 1);
      expect(identical(first, second), isTrue);
    });

    test('a disabled sidebar retains even when its inputs went empty', () {
      final retainer = SidebarWorkspaceEntriesRetainer(
        buildEntries:
            ({
              required placements,
              required sessions,
              required previousEntries,
            }) => {'s1:w1': ws('s1:w1')},
      );

      retainer.update(placements: placements, sessions: sessions);
      final retained = retainer.update(
        placements: const [],
        sessions: const [],
        enabled: false,
      );

      expect(retained, hasLength(1));
    });

    test('no placements clears to a reference-stable empty map', () {
      var buildCount = 0;
      final retainer = SidebarWorkspaceEntriesRetainer(
        buildEntries:
            ({
              required placements,
              required sessions,
              required previousEntries,
            }) {
              buildCount += 1;
              return {'s1:w1': ws('s1:w1')};
            },
      );

      retainer.update(placements: placements, sessions: sessions);
      final first = retainer.update(placements: const [], sessions: sessions);
      final second = retainer.update(placements: const [], sessions: sessions);

      expect(buildCount, 1);
      expect(first, isEmpty);
      expect(identical(first, second), isTrue);
    });

    test('no connected sessions clears to empty', () {
      final retainer = SidebarWorkspaceEntriesRetainer(
        buildEntries:
            ({
              required placements,
              required sessions,
              required previousEntries,
            }) => {'s1:w1': ws('s1:w1')},
      );

      retainer.update(placements: placements, sessions: sessions);
      final cleared = retainer.update(
        placements: placements,
        sessions: const [],
      );

      expect(cleared, isEmpty);
    });

    test('starts empty', () {
      expect(
        SidebarWorkspaceEntriesRetainer(
          buildEntries:
              ({
                required placements,
                required sessions,
                required previousEntries,
              }) => const {},
        ).current,
        isEmpty,
      );
    });
  });

  // -------------------------------------------------------------------------
  // use-form-preferences.ts — mergeProviderPreferences
  // -------------------------------------------------------------------------

  group('mergeProviderPreferences', () {
    test('stores the selected model for a provider', () {
      final merged = mergeProviderPreferences(
        preferences: const CreateAgentPreferences(),
        provider: 'claude',
        updates: const ProviderPreferenceUpdates(model: 'claude-opus-4-6'),
      );

      expect(merged.toJson(), {
        'provider': 'claude',
        'providerPreferences': {
          'claude': {'model': 'claude-opus-4-6'},
        },
      });
    });

    test('merges thinking preferences by model without dropping existing '
        'entries', () {
      final merged = mergeProviderPreferences(
        preferences: const CreateAgentPreferences(
          provider: 'claude',
          providerPreferences: {
            'claude': ProviderCreateAgentPreferences(
              model: 'claude-sonnet-4-6',
              thinkingByModel: {'claude-sonnet-4-6': 'medium'},
            ),
          },
        ),
        provider: 'claude',
        updates: const ProviderPreferenceUpdates(
          thinkingByModel: {'claude-opus-4-6': 'high'},
        ),
      );

      expect(merged.toJson(), {
        'provider': 'claude',
        'providerPreferences': {
          'claude': {
            'model': 'claude-sonnet-4-6',
            'thinkingByModel': {
              'claude-sonnet-4-6': 'medium',
              'claude-opus-4-6': 'high',
            },
          },
        },
      });
    });

    test('merges feature values without dropping existing entries', () {
      final merged = mergeProviderPreferences(
        preferences: const CreateAgentPreferences(
          provider: 'codex',
          providerPreferences: {
            'codex': ProviderCreateAgentPreferences(
              model: 'gpt-5.4',
              featureValues: {'fast_mode': true},
            ),
          },
        ),
        provider: 'codex',
        updates: const ProviderPreferenceUpdates(
          featureValues: {'plan_mode': true},
        ),
      );

      expect(merged.toJson(), {
        'provider': 'codex',
        'providerPreferences': {
          'codex': {
            'model': 'gpt-5.4',
            'featureValues': {'fast_mode': true, 'plan_mode': true},
          },
        },
      });
    });

    test('an absent field leaves the stored value alone', () {
      final merged = mergeProviderPreferences(
        preferences: const CreateAgentPreferences(
          providerPreferences: {
            'codex': ProviderCreateAgentPreferences(
              model: 'gpt-5.4',
              mode: 'plan',
            ),
          },
        ),
        provider: 'codex',
        updates: const ProviderPreferenceUpdates(),
      );

      expect(merged.providerPreferences['codex']?.model, 'gpt-5.4');
      expect(merged.providerPreferences['codex']?.mode, 'plan');
    });

    test('switches the active provider without dropping the other one', () {
      final merged = mergeProviderPreferences(
        preferences: const CreateAgentPreferences(
          provider: 'claude',
          providerPreferences: {
            'claude': ProviderCreateAgentPreferences(model: 'sonnet'),
          },
          favoriteModels: [
            FavoriteModelPreference(provider: 'codex', modelId: 'gpt-5.4'),
          ],
        ),
        provider: 'codex',
        updates: const ProviderPreferenceUpdates(model: 'gpt-5.4'),
      );

      expect(merged.provider, 'codex');
      expect(merged.providerPreferences['claude']?.model, 'sonnet');
      expect(merged.favoriteModels, hasLength(1));
    });
  });

  // -------------------------------------------------------------------------
  // use-form-preferences.ts — favorite models (re-exported by the hook)
  // -------------------------------------------------------------------------

  group('favorite model preferences', () {
    test('builds a stable favorite key from provider and model', () {
      expect(
        buildFavoriteModelKey(provider: 'claude', modelId: 'sonnet-4.6'),
        'claude:sonnet-4.6',
      );
    });

    test('adds a model to favorites without dropping other preferences', () {
      final toggled = toggleFavoriteModel(
        preferences: const CreateAgentPreferences(
          provider: 'claude',
          providerPreferences: {
            'claude': ProviderCreateAgentPreferences(
              model: 'claude-sonnet-4-6',
            ),
          },
        ),
        provider: 'codex',
        modelId: 'gpt-5.4',
      );

      expect(toggled.toJson(), {
        'provider': 'claude',
        'providerPreferences': {
          'claude': {'model': 'claude-sonnet-4-6'},
        },
        'favoriteModels': [
          {'provider': 'codex', 'modelId': 'gpt-5.4'},
        ],
      });
    });

    test('removes a model from favorites when toggled again', () {
      final toggled = toggleFavoriteModel(
        preferences: const CreateAgentPreferences(
          favoriteModels: [
            FavoriteModelPreference(provider: 'codex', modelId: 'gpt-5.4'),
          ],
        ),
        provider: 'codex',
        modelId: 'gpt-5.4',
      );

      expect(toggled.favoriteModels, isEmpty);
      expect(toggled.toJson(), <String, Object?>{});
    });

    test('reports whether a model is favorited', () {
      const preferences = CreateAgentPreferences(
        favoriteModels: [
          FavoriteModelPreference(provider: 'codex', modelId: 'gpt-5.4'),
        ],
      );

      expect(
        isFavoriteModel(
          preferences: preferences,
          provider: 'codex',
          modelId: 'gpt-5.4',
        ),
        isTrue,
      );
      expect(
        isFavoriteModel(
          preferences: preferences,
          provider: 'claude',
          modelId: 'sonnet-4.6',
        ),
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  // use-form-preferences.ts — FormPreferencesController
  // -------------------------------------------------------------------------

  group('FormPreferencesController', () {
    test('reports default preferences while the first read is in flight', () {
      final controller = FormPreferencesController(
        service: CreateAgentPreferencesService(_MemoryStorage()),
      );

      unawaited(controller.ensureLoaded());

      expect(controller.snapshot.isLoading, isTrue);
      expect(
        controller.snapshot.preferences.provider,
        defaultFormPreferences.provider,
      );
      expect(controller.snapshot.preferences.providerPreferences, isEmpty);
    });

    test('publishes the stored preferences once loaded', () async {
      var changes = 0;
      final controller = FormPreferencesController(
        service: CreateAgentPreferencesService(
          _MemoryStorage(value: {'provider': 'codex'}),
        ),
        onChanged: () => changes += 1,
      );

      await controller.ensureLoaded();

      expect(controller.snapshot.isLoading, isFalse);
      expect(controller.snapshot.preferences.provider, 'codex');
      expect(changes, 1);
    });

    test('reads storage once however often loading is requested', () async {
      final storage = _MemoryStorage(value: {'provider': 'codex'});
      final controller = FormPreferencesController(
        service: CreateAgentPreferencesService(storage),
      );

      await Future.wait([controller.ensureLoaded(), controller.ensureLoaded()]);
      await controller.ensureLoaded();

      expect(storage.readCount, 1);
    });

    test('falls back to defaults when the read fails', () async {
      final controller = FormPreferencesController(
        service: CreateAgentPreferencesService(_MemoryStorage(failReads: true)),
      );

      await controller.ensureLoaded();

      expect(controller.snapshot.isLoading, isFalse);
      expect(controller.snapshot.preferences.provider, isNull);
    });

    test('publishes the value the service actually stored', () async {
      final storage = _MemoryStorage();
      var changes = 0;
      final controller = FormPreferencesController(
        service: CreateAgentPreferencesService(storage),
        onChanged: () => changes += 1,
      );
      await controller.ensureLoaded();

      await controller.updatePreferences(
        (current) => mergeProviderPreferences(
          preferences: current,
          provider: 'claude',
          updates: const ProviderPreferenceUpdates(model: 'opus'),
        ),
      );

      expect(controller.snapshot.preferences.provider, 'claude');
      expect(
        controller.snapshot.preferences.providerPreferences['claude']?.model,
        'opus',
      );
      expect(storage.writes, hasLength(1));
      expect(changes, 2);
    });

    test(
      'a write resolves the loading state without a separate read',
      () async {
        final storage = _MemoryStorage();
        final controller = FormPreferencesController(
          service: CreateAgentPreferencesService(storage),
        );

        await controller.updatePreferences(
          (current) => current.copyWith(provider: 'codex'),
        );

        expect(controller.snapshot.isLoading, isFalse);
        expect(controller.snapshot.preferences.provider, 'codex');
      },
    );
  });
}

/// Local stand-in for `dart:async`'s `unawaited`, kept here so the test file
/// does not import an extra library for one call.
void unawaited(Future<void> future) {}
