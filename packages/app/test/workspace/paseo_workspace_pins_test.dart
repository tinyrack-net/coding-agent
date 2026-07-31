// Port of the frozen Paseo 0.2.0 suites
// `packages/app/src/screens/workspace/visible-agent-ids.test.ts`,
// `packages/app/src/screens/workspace/workspace-tab-model.test.ts`,
// `packages/app/src/workspace-pins/target.test.ts`,
// `packages/app/src/workspace-pins/run.test.ts`,
// `packages/app/src/workspace/project-workspace-archive.test.ts`, and
// `packages/app/src/stores/last-workspace-selection.test.ts`.
//
// Every upstream case appears below under the same public symbol. Cases marked
// `// extra:` are not in the upstream suites — they pin behavior the frozen
// modules have but never assert (null layouts, non-agent tabs, sort order
// independent of pane order, list immutability, the hydration-revision race in
// both directions, and the JSON shapes `parseStoredWorkspaceSelection` rejects).

import 'dart:async';
import 'dart:convert';

import 'package:agent_protocol/agent_protocol.dart'
    show TerminalProfile, WorkspaceKind;
import 'package:coding_agent_app/core/host_routes.dart' show HostWorkspaceRoute;
import 'package:coding_agent_app/workspace/paseo_workspace_pins.dart';
import 'package:coding_agent_app/workspace/workspace_pane_layout.dart';
import 'package:coding_agent_app/workspace/workspace_tab_model.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

WorkspaceTab tab(
  String tabId,
  WorkspaceTabTarget target, {
  int createdAt = 1,
}) => WorkspaceTab(tabId: tabId, target: target, createdAt: createdAt);

WorkspaceTabTarget agent(String agentId) =>
    WorkspaceAgentTabTarget(agentId: agentId);

WorkspacePane pane(String id, List<String> tabIds, {String? focusedTabId}) =>
    WorkspacePane(id: id, tabIds: tabIds, focusedTabId: focusedTabId);

WorkspacePaneLayout splitLayout({
  required String focusedPaneId,
  required WorkspacePane left,
  required WorkspacePane right,
}) => WorkspacePaneLayout(
  focusedPaneId: focusedPaneId,
  root: WorkspacePaneGroup(
    id: 'root',
    direction: WorkspaceSplitDirection.horizontal,
    sizes: const [0.5, 0.5],
    children: [left, right],
  ),
);

/// Upstream asserts on target *objects*; `toJson` is the Dart equivalent of the
/// literal a `toEqual` compares against, so the assertions stay readable.
Map<String, Object?> json(WorkspaceTabTarget? target) =>
    target == null ? const {} : target.toJson();

Matcher isSelection(String serverId, String workspaceId) =>
    isA<HostWorkspaceRoute>()
        .having((value) => value.serverId, 'serverId', serverId)
        .having((value) => value.workspaceId, 'workspaceId', workspaceId);

void main() {
  // -------------------------------------------------------------------------
  // visible-agent-ids.ts
  // -------------------------------------------------------------------------

  group('selectVisibleAgentIds', () {
    test('selects only the active agent tab in every visible pane', () {
      final layout = splitLayout(
        focusedPaneId: 'left',
        left: pane('left', ['a', 'hidden'], focusedTabId: 'a'),
        right: pane('right', ['b'], focusedTabId: 'b'),
      );
      final tabs = [
        tab('a', agent('agent-a'), createdAt: 1),
        tab('hidden', agent('agent-hidden'), createdAt: 2),
        tab('b', agent('agent-b'), createdAt: 3),
      ];

      expect(
        selectVisibleAgentIds(
          layout: layout,
          tabs: tabs,
          routeFocused: true,
          focusedPaneOnly: false,
        ),
        ['agent-a', 'agent-b'],
      );
    });

    test('route blur publishes no viewed agents', () {
      final layout = WorkspacePaneLayout(
        focusedPaneId: 'main',
        root: pane('main', ['a'], focusedTabId: 'a'),
      );

      expect(
        selectVisibleAgentIds(
          layout: layout,
          tabs: [tab('a', agent('agent-a'))],
          routeFocused: false,
          focusedPaneOnly: false,
        ),
        isEmpty,
      );
    });

    test('compact and focus modes contribute only the focused pane', () {
      final layout = splitLayout(
        focusedPaneId: 'right',
        left: pane('left', ['a'], focusedTabId: 'a'),
        right: pane('right', ['b'], focusedTabId: 'b'),
      );
      final tabs = [
        tab('a', agent('agent-a'), createdAt: 1),
        tab('b', agent('agent-b'), createdAt: 2),
      ];

      expect(
        selectVisibleAgentIds(
          layout: layout,
          tabs: tabs,
          routeFocused: true,
          focusedPaneOnly: true,
        ),
        ['agent-b'],
      );
    });

    test(
      'pane retargeting replaces the viewed agent and duplicate panes collapse '
      'to one ID',
      () {
        final layout = splitLayout(
          focusedPaneId: 'left',
          left: pane('left', ['active'], focusedTabId: 'active'),
          right: pane('right', ['duplicate'], focusedTabId: 'duplicate'),
        );
        final duplicateTabs = [
          tab('active', agent('agent-a'), createdAt: 1),
          tab('duplicate', agent('agent-a'), createdAt: 2),
        ];
        final retargetedTabs = [
          tab('active', agent('agent-b'), createdAt: 1),
          tab('duplicate', agent('agent-a'), createdAt: 2),
        ];

        expect(
          selectVisibleAgentIds(
            layout: layout,
            tabs: duplicateTabs,
            routeFocused: true,
            focusedPaneOnly: false,
          ),
          ['agent-a'],
        );
        expect(
          selectVisibleAgentIds(
            layout: layout,
            tabs: retargetedTabs,
            routeFocused: true,
            focusedPaneOnly: false,
          ),
          ['agent-a', 'agent-b'],
        );
      },
    );

    // extra: a route may be focused before its layout has been restored.
    test('a null layout publishes no viewed agents even when focused', () {
      expect(
        selectVisibleAgentIds(
          layout: null,
          tabs: [tab('a', agent('agent-a'))],
          routeFocused: true,
          focusedPaneOnly: false,
        ),
        isEmpty,
      );
    });

    // extra: upstream compares `pane.id === layout?.focusedPaneId`, which no
    // pane can satisfy when nothing is focused.
    test('compact mode with no focused pane publishes nothing', () {
      final layout = splitLayout(
        focusedPaneId: 'left',
        left: pane('left', ['a'], focusedTabId: 'a'),
        right: pane('right', ['b'], focusedTabId: 'b'),
      );
      final unfocused = WorkspacePaneLayout(
        root: layout.root,
        focusedPaneId: null,
      );
      final tabs = [
        tab('a', agent('agent-a')),
        tab('b', agent('agent-b'), createdAt: 2),
      ];

      expect(
        selectVisibleAgentIds(
          layout: unfocused,
          tabs: tabs,
          routeFocused: true,
          focusedPaneOnly: true,
        ),
        isEmpty,
      );
      // ...while the same layout in split mode still reports both panes.
      expect(
        selectVisibleAgentIds(
          layout: unfocused,
          tabs: tabs,
          routeFocused: true,
          focusedPaneOnly: false,
        ),
        ['agent-a', 'agent-b'],
      );
    });

    // extra: a stale focusedPaneId (pane closed) must not resurrect a pane.
    test('compact mode with an unknown focused pane publishes nothing', () {
      final layout = splitLayout(
        focusedPaneId: 'closed',
        left: pane('left', ['a'], focusedTabId: 'a'),
        right: pane('right', ['b'], focusedTabId: 'b'),
      );

      expect(
        selectVisibleAgentIds(
          layout: layout,
          tabs: [tab('a', agent('agent-a'))],
          routeFocused: true,
          focusedPaneOnly: true,
        ),
        isEmpty,
      );
    });

    // extra: only agent tabs are agent views.
    test('panes showing non-agent tabs contribute no agent ids', () {
      final layout = splitLayout(
        focusedPaneId: 'left',
        left: pane('left', ['term'], focusedTabId: 'term'),
        right: pane('right', ['file'], focusedTabId: 'file'),
      );

      expect(
        selectVisibleAgentIds(
          layout: layout,
          tabs: [
            tab('term', const WorkspaceTerminalTabTarget(terminalId: 't-1')),
            tab(
              'file',
              const WorkspaceFileTabTarget(path: '/repo/README.md'),
              createdAt: 2,
            ),
          ],
          routeFocused: true,
          focusedPaneOnly: false,
        ),
        isEmpty,
      );
    });

    // extra: the result is sorted, not in pane order.
    test(
      'ids are sorted regardless of the order the panes are laid out in',
      () {
        final layout = splitLayout(
          focusedPaneId: 'left',
          left: pane('left', ['z'], focusedTabId: 'z'),
          right: pane('right', ['a'], focusedTabId: 'a'),
        );

        expect(
          selectVisibleAgentIds(
            layout: layout,
            tabs: [
              tab('z', agent('agent-z')),
              tab('a', agent('agent-a'), createdAt: 2),
            ],
            routeFocused: true,
            focusedPaneOnly: false,
          ),
          ['agent-a', 'agent-z'],
        );
      },
    );

    // extra: a pane referencing tabs the workspace no longer has is empty, and
    // a pane with no focused tab falls back to its first tab.
    test('missing tabs drop out and an unfocused pane shows its first tab', () {
      final layout = splitLayout(
        focusedPaneId: 'left',
        left: pane('left', ['gone'], focusedTabId: 'gone'),
        right: pane('right', ['first', 'second']),
      );

      expect(
        selectVisibleAgentIds(
          layout: layout,
          tabs: [
            tab('first', agent('agent-first')),
            tab('second', agent('agent-second'), createdAt: 2),
          ],
          routeFocused: true,
          focusedPaneOnly: false,
        ),
        ['agent-first'],
      );
    });
  });

  // -------------------------------------------------------------------------
  // workspace-tab-model.ts
  // -------------------------------------------------------------------------

  group('deriveWorkspaceTabModel', () {
    test('keeps normalized tabs in stored order and preserves targets', () {
      final uiTabs = [
        tab(
          'draft_123',
          const WorkspaceDraftTabTarget(draftId: 'draft_123'),
          createdAt: 1,
        ),
        tab(
          'file_/repo/worktree/README.md',
          const WorkspaceFileTabTarget(path: '/repo/worktree/README.md'),
          createdAt: 2,
        ),
        tab('agent_agent-a', agent('agent-a'), createdAt: 3),
      ];

      final model = deriveWorkspaceTabModel(
        tabs: [uiTabs[0], uiTabs[2], uiTabs[1]],
      );

      expect(model.tabs.map((tab) => tab.descriptor.tabId), [
        'draft_123',
        'agent_agent-a',
        'file_/repo/worktree/README.md',
      ]);
      expect(json(model.tabs[0].descriptor.target), {
        'kind': 'draft',
        'draftId': 'draft_123',
      });
      expect(json(model.tabs[1].descriptor.target), {
        'kind': 'agent',
        'agentId': 'agent-a',
      });
      expect(json(model.tabs[2].descriptor.target), {
        'kind': 'file',
        'path': '/repo/worktree/README.md',
      });
    });

    test(
      'applies stored order and appends unordered tabs deterministically',
      () {
        final model = deriveWorkspaceTabModel(
          tabs: [
            tab(
              'terminal_term-1',
              const WorkspaceTerminalTabTarget(terminalId: 'term-1'),
              createdAt: 3,
            ),
            tab('agent_agent-b', agent('agent-b'), createdAt: 2),
            tab('agent_agent-a', agent('agent-a'), createdAt: 1),
          ],
        );

        expect(model.tabs.map((tab) => tab.descriptor.tabId), [
          'terminal_term-1',
          'agent_agent-b',
          'agent_agent-a',
        ]);
      },
    );

    test(
      'uses focused tab when present, otherwise falls back to first tab',
      () {
        final tabs = [
          tab('agent_agent-a', agent('agent-a'), createdAt: 1),
          tab('agent_agent-b', agent('agent-b'), createdAt: 2),
        ];

        expect(
          deriveWorkspaceTabModel(
            tabs: tabs,
            focusedTabId: 'agent_agent-b',
          ).activeTabId,
          'agent_agent-b',
        );
        expect(
          deriveWorkspaceTabModel(tabs: tabs).activeTabId,
          'agent_agent-a',
        );
      },
    );

    test('prefers the route-selected target over stale focused tab state', () {
      final model = deriveWorkspaceTabModel(
        tabs: [
          tab('agent_agent-a', agent('agent-a'), createdAt: 1),
          tab('agent_agent-b', agent('agent-b'), createdAt: 2),
        ],
        focusedTabId: 'agent_agent-a',
        preferredTarget: agent('agent-b'),
      );

      expect(model.activeTabId, 'agent_agent-b');
      expect(json(model.activeTab?.descriptor.target), {
        'kind': 'agent',
        'agentId': 'agent-b',
      });
    });

    test(
      'normalizes preferredTarget before overriding focused tab selection',
      () {
        final model = deriveWorkspaceTabModel(
          tabs: [
            tab(
              'file_/repo/worktree/README.md',
              const WorkspaceFileTabTarget(path: '/repo/worktree/README.md'),
              createdAt: 1,
            ),
            tab('agent_agent-a', agent('agent-a'), createdAt: 2),
          ],
          focusedTabId: 'agent_agent-a',
          preferredTarget: const WorkspaceFileTabTarget(
            path: r'\repo\worktree\README.md',
          ),
        );

        expect(model.activeTabId, 'file_/repo/worktree/README.md');
        expect(json(model.activeTab?.descriptor.target), {
          'kind': 'file',
          'path': '/repo/worktree/README.md',
        });
      },
    );

    test('keeps retargeted tab ids stable while matching upgraded targets', () {
      final model = deriveWorkspaceTabModel(
        tabs: [tab('draft_abc', agent('agent-1'), createdAt: 1)],
        preferredTarget: agent('agent-1'),
      );

      expect(model.activeTabId, 'draft_abc');
      expect(model.activeTab?.descriptor.tabId, 'draft_abc');
      expect(json(model.activeTab?.descriptor.target), {
        'kind': 'agent',
        'agentId': 'agent-1',
      });
    });

    test('normalizes file paths and discards invalid tabs', () {
      final model = deriveWorkspaceTabModel(
        tabs: [
          tab(
            'file_path',
            const WorkspaceFileTabTarget(path: r'\repo\worktree\README.md'),
            createdAt: 1,
          ),
          tab('', agent('agent-a'), createdAt: 2),
        ],
      );

      expect(model.tabs, hasLength(1));
      expect(json(model.tabs[0].descriptor.target), {
        'kind': 'file',
        'path': '/repo/worktree/README.md',
      });
    });

    // extra: the facade must not invent its own id scheme.
    test('buildWorkspaceTabId matches the deterministic tab id', () {
      final targets = <WorkspaceTabTarget>[
        const WorkspaceDraftTabTarget(draftId: 'draft_1'),
        agent('agent-a'),
        const WorkspaceProviderSubagentTabTarget(
          parentAgentId: 'parent',
          subagentId: 'sub',
        ),
        const WorkspaceTerminalTabTarget(terminalId: 't-1'),
        const WorkspaceBrowserTabTarget(browserId: 'b-1'),
        const WorkspaceFileTabTarget(path: '/repo/a.txt'),
        const WorkspaceWorkingDiffTabTarget(),
        const WorkspaceSetupTabTarget(workspaceId: 'ws-1'),
        const WorkspaceCommitDiffTabTarget(sha: 'abc123'),
      ];

      for (final target in targets) {
        expect(
          buildWorkspaceTabId(target),
          buildDeterministicWorkspaceTabId(target),
          reason: target.kind,
        );
      }
      expect(buildWorkspaceTabId(agent('agent-a')), 'agent_agent-a');
    });

    // extra: an empty workspace has no active tab at all.
    test('an empty tab list yields a null active tab', () {
      final model = deriveWorkspaceTabModel(tabs: const []);

      expect(model.tabs, isEmpty);
      expect(model.activeTabId, isNull);
      expect(model.activeTab, isNull);
    });

    // extra: duplicate ids collapse to the first occurrence.
    test('duplicate tab ids collapse to the first occurrence', () {
      final model = deriveWorkspaceTabModel(
        tabs: [
          tab('agent_agent-a', agent('agent-a'), createdAt: 1),
          tab('agent_agent-a', agent('agent-b'), createdAt: 2),
        ],
      );

      expect(model.tabs, hasLength(1));
      expect(json(model.tabs[0].descriptor.target), {
        'kind': 'agent',
        'agentId': 'agent-a',
      });
    });

    // extra: a preferred target for a tab that is not open loses to the
    // focused tab rather than blanking the selection.
    test(
      'a preferred target with no open tab falls back to the focused tab',
      () {
        final model = deriveWorkspaceTabModel(
          tabs: [
            tab('agent_agent-a', agent('agent-a'), createdAt: 1),
            tab('agent_agent-b', agent('agent-b'), createdAt: 2),
          ],
          focusedTabId: 'agent_agent-b',
          preferredTarget: agent('agent-missing'),
        );

        expect(model.activeTabId, 'agent_agent-b');
      },
    );

    // extra: a blank focused id is not a focused id.
    test('a whitespace-only focused tab id falls back to the first tab', () {
      final model = deriveWorkspaceTabModel(
        tabs: [
          tab('agent_agent-a', agent('agent-a'), createdAt: 1),
          tab('agent_agent-b', agent('agent-b'), createdAt: 2),
        ],
        focusedTabId: '   ',
      );

      expect(model.activeTabId, 'agent_agent-a');
    });

    // extra: a preferred target that normalizes away is ignored entirely.
    test('a preferred target that normalizes away leaves the focus alone', () {
      final model = deriveWorkspaceTabModel(
        tabs: [
          tab('agent_agent-a', agent('agent-a'), createdAt: 1),
          tab('agent_agent-b', agent('agent-b'), createdAt: 2),
        ],
        focusedTabId: 'agent_agent-b',
        preferredTarget: agent('   '),
      );

      expect(model.activeTabId, 'agent_agent-b');
    });
  });

  // -------------------------------------------------------------------------
  // workspace-pins/target.ts
  // -------------------------------------------------------------------------

  group('isPinnedTargetAvailable', () {
    test('only offers browser targets in Electron', () {
      const browser = PinnedBrowserTarget();

      expect(
        isPinnedTargetAvailable(
          browser,
          const PinnedTargetEnvironment(isElectron: true),
        ),
        isTrue,
      );
      expect(
        isPinnedTargetAvailable(
          browser,
          const PinnedTargetEnvironment(isElectron: false),
        ),
        isFalse,
      );
    });

    test('offers cross-platform targets outside Electron', () {
      const environment = PinnedTargetEnvironment(isElectron: false);

      expect(
        isPinnedTargetAvailable(const PinnedDraftTarget(), environment),
        isTrue,
      );
      expect(
        isPinnedTargetAvailable(const PinnedTerminalTarget(), environment),
        isTrue,
      );
      expect(
        isPinnedTargetAvailable(
          const PinnedProfileTarget('claude'),
          environment,
        ),
        isTrue,
      );
    });
  });

  group('pinnedTargetKey', () {
    test('uses the bare kind as the key for non-profile targets', () {
      expect(pinnedTargetKey(const PinnedDraftTarget()), 'draft');
      expect(pinnedTargetKey(const PinnedTerminalTarget()), 'terminal');
      expect(pinnedTargetKey(const PinnedBrowserTarget()), 'browser');
    });

    test('namespaces a profile target by its profile id', () {
      expect(
        pinnedTargetKey(const PinnedProfileTarget('claude')),
        'profile:claude',
      );
    });

    test('gives two profiles with different ids different keys', () {
      expect(
        pinnedTargetKey(const PinnedProfileTarget('claude')),
        isNot(pinnedTargetKey(const PinnedProfileTarget('codex'))),
      );
    });

    // extra: the namespace is what keeps a profile from shadowing a builtin.
    test('a profile named like a builtin does not collide with it', () {
      expect(
        pinnedTargetKey(const PinnedProfileTarget('terminal')),
        isNot(pinnedTargetKey(const PinnedTerminalTarget())),
      );
    });
  });

  group('togglePinnedTarget / isTargetPinned', () {
    test('pins a target that is not yet pinned', () {
      final pinned = togglePinnedTarget(const [], const PinnedTerminalTarget());

      expect(isTargetPinned(pinned, const PinnedTerminalTarget()), isTrue);
    });

    test('unpins a target that is already pinned', () {
      final pinned = togglePinnedTarget(const [
        PinnedBrowserTarget(),
      ], const PinnedBrowserTarget());

      expect(isTargetPinned(pinned, const PinnedBrowserTarget()), isFalse);
    });

    test('treats profiles with different ids as independent pins', () {
      final pinned = togglePinnedTarget(
        const [],
        const PinnedProfileTarget('claude'),
      );

      expect(
        isTargetPinned(pinned, const PinnedProfileTarget('claude')),
        isTrue,
      );
      expect(
        isTargetPinned(pinned, const PinnedProfileTarget('codex')),
        isFalse,
      );
    });

    test('unpins only the matching profile id', () {
      var pinned = togglePinnedTarget(
        const [],
        const PinnedProfileTarget('claude'),
      );
      pinned = togglePinnedTarget(pinned, const PinnedProfileTarget('codex'));
      pinned = togglePinnedTarget(pinned, const PinnedProfileTarget('claude'));

      expect(
        isTargetPinned(pinned, const PinnedProfileTarget('claude')),
        isFalse,
      );
      expect(
        isTargetPinned(pinned, const PinnedProfileTarget('codex')),
        isTrue,
      );
    });

    // extra: the caller's list is often the persisted state.
    test('never mutates the list it is given', () {
      final original = <PinnedTabTarget>[const PinnedDraftTarget()];

      final added = togglePinnedTarget(original, const PinnedTerminalTarget());
      final removed = togglePinnedTarget(original, const PinnedDraftTarget());

      expect(original, [const PinnedDraftTarget()]);
      expect(added, [const PinnedDraftTarget(), const PinnedTerminalTarget()]);
      expect(removed, isEmpty);
    });

    // extra: pin order is the order the user pinned things.
    test('appends new pins and preserves the order of the rest', () {
      var pinned = togglePinnedTarget(const [], const PinnedDraftTarget());
      pinned = togglePinnedTarget(pinned, const PinnedTerminalTarget());
      pinned = togglePinnedTarget(pinned, const PinnedProfileTarget('claude'));

      expect(pinned, [
        const PinnedDraftTarget(),
        const PinnedTerminalTarget(),
        const PinnedProfileTarget('claude'),
      ]);

      expect(togglePinnedTarget(pinned, const PinnedTerminalTarget()), [
        const PinnedDraftTarget(),
        const PinnedProfileTarget('claude'),
      ]);
    });

    // extra: identity is by key, not by instance.
    test('unpins an equivalent target built from a different instance', () {
      final pinned = <PinnedTabTarget>[PinnedProfileTarget('cla${'ude'}')];

      expect(
        togglePinnedTarget(pinned, const PinnedProfileTarget('claude')),
        isEmpty,
      );
    });

    // extra: nothing is pinned in an empty list.
    test('reports nothing pinned for an empty list', () {
      expect(isTargetPinned(const [], const PinnedDraftTarget()), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // workspace-pins/run.ts
  // -------------------------------------------------------------------------

  group('runPinnedTabTarget', () {
    const profiles = [
      TerminalProfile(id: 'claude', name: 'Claude Code', command: 'claude'),
    ];

    test('creates a draft agent for the draft target', () {
      final recorder = LaunchRecorder();

      runPinnedTabTarget(
        const PinnedDraftTarget(),
        profiles,
        recorder.handlers,
      );

      expect(recorder.launches, [const RecordedLaunch(LaunchAction.draft)]);
    });

    test('creates a terminal for the terminal target', () {
      final recorder = LaunchRecorder();

      runPinnedTabTarget(
        const PinnedTerminalTarget(),
        profiles,
        recorder.handlers,
      );

      expect(recorder.launches, [const RecordedLaunch(LaunchAction.terminal)]);
    });

    test('creates a browser for the browser target', () {
      final recorder = LaunchRecorder();

      runPinnedTabTarget(
        const PinnedBrowserTarget(),
        profiles,
        recorder.handlers,
      );

      expect(recorder.launches, [const RecordedLaunch(LaunchAction.browser)]);
    });

    test(
      'launches the resolved profile command for a known profile target',
      () {
        final recorder = LaunchRecorder();

        runPinnedTabTarget(
          const PinnedProfileTarget('claude'),
          profiles,
          recorder.handlers,
        );

        expect(recorder.launches, [
          const RecordedLaunch(
            LaunchAction.profile,
            profile: TerminalProfileInput(
              name: 'Claude Code',
              command: 'claude',
            ),
          ),
        ]);
      },
    );

    test('does nothing when the profile id is absent from the host', () {
      final recorder = LaunchRecorder();

      runPinnedTabTarget(
        const PinnedProfileTarget('missing'),
        profiles,
        recorder.handlers,
      );

      expect(recorder.launches, isEmpty);
    });

    // extra: profile args must survive the trip to the terminal.
    test('forwards the profile arguments when it has them', () {
      final recorder = LaunchRecorder();

      runPinnedTabTarget(const PinnedProfileTarget('codex'), const [
        TerminalProfile(
          id: 'codex',
          name: 'Codex',
          command: 'codex',
          args: ['--resume', 'last'],
          icon: 'terminal',
        ),
      ], recorder.handlers);

      expect(recorder.launches, [
        const RecordedLaunch(
          LaunchAction.profile,
          profile: TerminalProfileInput(
            name: 'Codex',
            command: 'codex',
            args: ['--resume', 'last'],
          ),
        ),
      ]);
    });

    // extra: `Array.prototype.find` takes the first match.
    test('uses the first profile when two share an id', () {
      final recorder = LaunchRecorder();

      runPinnedTabTarget(const PinnedProfileTarget('dup'), const [
        TerminalProfile(id: 'dup', name: 'First', command: 'first'),
        TerminalProfile(id: 'dup', name: 'Second', command: 'second'),
      ], recorder.handlers);

      expect(recorder.launches, [
        const RecordedLaunch(
          LaunchAction.profile,
          profile: TerminalProfileInput(name: 'First', command: 'first'),
        ),
      ]);
    });

    // extra: a host with no profiles at all is not a crash.
    test('does nothing when the host has no profiles', () {
      final recorder = LaunchRecorder();

      runPinnedTabTarget(
        const PinnedProfileTarget('claude'),
        const [],
        recorder.handlers,
      );

      expect(recorder.launches, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // project-workspace-archive.ts
  // -------------------------------------------------------------------------

  group('selectProjectWorkspacesToArchive', () {
    List<ProjectWorkspaceArchiveEntry> riskyProject() => const [
      ProjectWorkspaceArchiveEntry(
        serverId: 'server-1',
        workspaceId: 'workspace-worktree',
        workspaceKind: WorkspaceKind.worktree,
        name: 'feature/risky',
        archiveHasUncommittedChanges: true,
        archiveUnpushedCommitCount: 2,
        diffStat: WorktreeArchiveDiffStat(additions: 5, deletions: 1),
      ),
      ProjectWorkspaceArchiveEntry(
        serverId: 'server-1',
        workspaceId: 'workspace-checkout',
        workspaceKind: WorkspaceKind.localCheckout,
        name: 'main',
      ),
    ];

    const expectedRisk = WorktreeArchiveRisk(
      isDirty: true,
      aheadOfOrigin: 2,
      diffStat: WorktreeArchiveDiffStat(additions: 5, deletions: 1),
    );

    test('skips archiving a dirty and unpushed worktree when the risky archive '
        'confirmation is canceled', () async {
      final confirmations = <WorktreeArchiveConfirmationInput>[];

      final targets = await selectProjectWorkspacesToArchive(
        riskyProject(),
        confirmWorktreeArchive: (input) async {
          confirmations.add(input);
          return false;
        },
      );

      expect(confirmations, hasLength(1));
      expect(confirmations.single.workspaceName, 'feature/risky');
      expect(confirmations.single.risk, expectedRisk);
      expect(targets, [
        const WorkspaceArchiveTarget(
          serverId: 'server-1',
          workspaceId: 'workspace-checkout',
        ),
      ]);
    });

    test('includes a dirty and unpushed worktree when the risky archive '
        'confirmation is accepted', () async {
      final confirmations = <WorktreeArchiveConfirmationInput>[];

      final targets = await selectProjectWorkspacesToArchive(
        riskyProject(),
        confirmWorktreeArchive: (input) async {
          confirmations.add(input);
          return true;
        },
      );

      expect(confirmations, hasLength(1));
      expect(confirmations.single.workspaceName, 'feature/risky');
      expect(confirmations.single.risk, expectedRisk);
      expect(targets, [
        const WorkspaceArchiveTarget(
          serverId: 'server-1',
          workspaceId: 'workspace-worktree',
        ),
        const WorkspaceArchiveTarget(
          serverId: 'server-1',
          workspaceId: 'workspace-checkout',
        ),
      ]);
    });

    // extra: nothing to decide, nothing to ask.
    test('an empty project archives nothing and prompts nobody', () async {
      var prompts = 0;

      final targets = await selectProjectWorkspacesToArchive(
        const [],
        confirmWorktreeArchive: (_) async {
          prompts += 1;
          return true;
        },
      );

      expect(targets, isEmpty);
      expect(prompts, 0);
    });

    // extra: only worktrees can lose work.
    test('never prompts for non-worktree workspace kinds', () async {
      var prompts = 0;

      final targets = await selectProjectWorkspacesToArchive(
        const [
          ProjectWorkspaceArchiveEntry(
            serverId: 'server-1',
            workspaceId: 'ws-directory',
            workspaceKind: WorkspaceKind.directory,
            name: 'scratch',
            archiveHasUncommittedChanges: true,
            archiveUnpushedCommitCount: 9,
          ),
          ProjectWorkspaceArchiveEntry(
            serverId: 'server-1',
            workspaceId: 'ws-checkout',
            workspaceKind: WorkspaceKind.checkout,
            name: 'main',
          ),
          ProjectWorkspaceArchiveEntry(
            serverId: 'server-1',
            workspaceId: 'ws-local',
            workspaceKind: WorkspaceKind.localCheckout,
            name: 'local',
          ),
        ],
        confirmWorktreeArchive: (_) async {
          prompts += 1;
          return false;
        },
      );

      expect(prompts, 0);
      expect(targets.map((target) => target.workspaceId), [
        'ws-directory',
        'ws-checkout',
        'ws-local',
      ]);
    });

    // extra: a risk-free worktree is still offered to the hook — the "no risk
    // means no dialog" decision lives inside confirmRiskyWorktreeArchive.
    test('offers even a risk-free worktree to the confirmation hook', () async {
      final confirmations = <WorktreeArchiveConfirmationInput>[];

      final targets = await selectProjectWorkspacesToArchive(
        const [
          ProjectWorkspaceArchiveEntry(
            serverId: 'server-1',
            workspaceId: 'ws-clean',
            workspaceKind: WorkspaceKind.worktree,
            name: 'feature/clean',
          ),
        ],
        confirmWorktreeArchive: (input) async {
          confirmations.add(input);
          return true;
        },
      );

      expect(confirmations, hasLength(1));
      expect(
        confirmations.single.risk,
        const WorktreeArchiveRisk(
          isDirty: null,
          aheadOfOrigin: null,
          diffStat: null,
        ),
      );
      expect(targets, hasLength(1));
    });

    // extra: prompts are sequential and in list order, so a project of
    // worktrees never stacks dialogs.
    test('prompts one worktree at a time, in list order', () async {
      final order = <String>[];
      var inFlight = 0;

      final targets = await selectProjectWorkspacesToArchive(
        const [
          ProjectWorkspaceArchiveEntry(
            serverId: 's',
            workspaceId: 'ws-a',
            workspaceKind: WorkspaceKind.worktree,
            name: 'a',
          ),
          ProjectWorkspaceArchiveEntry(
            serverId: 's',
            workspaceId: 'ws-b',
            workspaceKind: WorkspaceKind.worktree,
            name: 'b',
          ),
          ProjectWorkspaceArchiveEntry(
            serverId: 's',
            workspaceId: 'ws-c',
            workspaceKind: WorkspaceKind.worktree,
            name: 'c',
          ),
        ],
        confirmWorktreeArchive: (input) async {
          inFlight += 1;
          expect(inFlight, 1);
          order.add(input.workspaceName);
          await Future<void>.delayed(Duration.zero);
          inFlight -= 1;
          return input.workspaceName != 'b';
        },
      );

      expect(order, ['a', 'b', 'c']);
      expect(targets.map((target) => target.workspaceId), ['ws-a', 'ws-c']);
    });
  });

  // -------------------------------------------------------------------------
  // last-workspace-selection.ts
  // -------------------------------------------------------------------------

  group('last workspace selection', () {
    test('hydrates the saved workspace selection', () async {
      final storage = DelayedWorkspaceSelectionStorage();
      final store = LastWorkspaceSelectionStore(storage);
      final hydration = store.hydrate();

      storage.finishHydrationWith(
        const HostWorkspaceRoute(
          serverId: 'server-saved',
          workspaceId: 'workspace-saved',
        ),
      );
      await hydration;

      expect(
        store.getSelection(),
        isSelection('server-saved', 'workspace-saved'),
      );
      expect(store.isHydrated(), isTrue);
    });

    test('keeps a newer workspace selection when storage hydration finishes '
        'late', () async {
      final storage = DelayedWorkspaceSelectionStorage();
      final store = LastWorkspaceSelectionStore(storage);
      final hydration = store.hydrate();

      store.remember(
        const HostWorkspaceRoute(
          serverId: 'server-new',
          workspaceId: 'workspace-new',
        ),
      );
      storage.finishHydrationWith(
        const HostWorkspaceRoute(
          serverId: 'server-old',
          workspaceId: 'workspace-old',
        ),
      );
      await hydration;

      expect(store.getSelection(), isSelection('server-new', 'workspace-new'));
      expect(storage.savedSelection(), {
        'serverId': 'server-new',
        'workspaceId': 'workspace-new',
      });
    });

    // extra: the revision guard is captured when hydrate() is called, so a
    // selection remembered *before* hydration starts is still overwritten.
    test(
      'a selection remembered before hydrate starts loses to storage',
      () async {
        final storage = DelayedWorkspaceSelectionStorage();
        final store = LastWorkspaceSelectionStore(storage);

        store.remember(
          const HostWorkspaceRoute(serverId: 'early', workspaceId: 'early-ws'),
        );
        final hydration = store.hydrate();
        storage.finishHydrationWith(
          const HostWorkspaceRoute(
            serverId: 'stored',
            workspaceId: 'stored-ws',
          ),
        );
        await hydration;

        expect(store.getSelection(), isSelection('stored', 'stored-ws'));
      },
    );

    // extra: a broken preferences file must not wedge the app in "loading".
    test('a failed read leaves an empty but hydrated store', () async {
      final storage = DelayedWorkspaceSelectionStorage();
      final store = LastWorkspaceSelectionStore(storage);
      final hydration = store.hydrate();

      storage.failHydration(StateError('disk is on fire'));
      await hydration;

      expect(store.getSelection(), isNull);
      expect(store.isHydrated(), isTrue);
    });

    // extra: a synchronous throw is a failure like any other.
    test('a synchronously throwing read is caught', () async {
      final store = LastWorkspaceSelectionStore(ThrowingStorage());

      await store.hydrate();

      expect(store.getSelection(), isNull);
      expect(store.isHydrated(), isTrue);
    });

    // extra: several widgets may await hydration; only one read may happen.
    test('hydrate is memoized across concurrent and repeat callers', () async {
      final storage = DelayedWorkspaceSelectionStorage();
      final store = LastWorkspaceSelectionStore(storage);

      final first = store.hydrate();
      final second = store.hydrate();
      expect(identical(first, second), isTrue);

      storage.finishHydrationWith(
        const HostWorkspaceRoute(serverId: 's', workspaceId: 'w'),
      );
      await Future.wait([first, second]);
      await store.hydrate();

      expect(storage.readCount, 1);
      expect(store.getSelection(), isSelection('s', 'w'));
    });

    // extra: payloads the parser rejects all mean "nothing remembered".
    test(
      'rejects stored payloads that are not a workspace selection',
      () async {
        for (final stored in <String?>[
          null,
          '',
          'not json',
          'null',
          '[]',
          '{}',
          '{"serverId":"s"}',
          '{"workspaceId":"w"}',
          '{"serverId":"  ","workspaceId":"w"}',
          '{"serverId":"s","workspaceId":"   "}',
          '{"serverId":1,"workspaceId":"w"}',
        ]) {
          final storage = DelayedWorkspaceSelectionStorage();
          final store = LastWorkspaceSelectionStore(storage);
          final hydration = store.hydrate();

          storage.finishHydrationWithRaw(stored);
          await hydration;

          expect(store.getSelection(), isNull, reason: 'stored: $stored');
          expect(store.isHydrated(), isTrue, reason: 'stored: $stored');
        }
      },
    );

    // extra: the stored payload is trimmed on the way in.
    test('trims whitespace out of a stored selection', () async {
      final storage = DelayedWorkspaceSelectionStorage();
      final store = LastWorkspaceSelectionStore(storage);
      final hydration = store.hydrate();

      storage.finishHydrationWithRaw(
        '{"serverId":"  server  ","workspaceId":"  workspace  "}',
      );
      await hydration;

      expect(store.getSelection(), isSelection('server', 'workspace'));
    });

    // extra: remember normalizes before it stores.
    test('remember trims and rejects blank selections', () {
      final storage = DelayedWorkspaceSelectionStorage();
      final store = LastWorkspaceSelectionStore(storage);

      store.remember(
        const HostWorkspaceRoute(serverId: '   ', workspaceId: 'workspace'),
      );
      expect(store.getSelection(), isNull);
      expect(storage.writeCount, 0);

      store.remember(
        const HostWorkspaceRoute(serverId: 'server', workspaceId: '   '),
      );
      expect(store.getSelection(), isNull);
      expect(storage.writeCount, 0);

      store.remember(
        const HostWorkspaceRoute(
          serverId: '  server  ',
          workspaceId: '  workspace  ',
        ),
      );
      expect(store.getSelection(), isSelection('server', 'workspace'));
    });

    // extra: a route that rebuilds every frame must not churn disk or UI.
    test('remembering the same selection twice is a no-op', () async {
      final storage = DelayedWorkspaceSelectionStorage();
      final store = LastWorkspaceSelectionStore(storage);
      var notifications = 0;
      store.subscribe(() => notifications += 1);

      const selection = HostWorkspaceRoute(
        serverId: 'server',
        workspaceId: 'workspace',
      );
      store.remember(selection);
      store.remember(selection);
      store.remember(
        const HostWorkspaceRoute(
          serverId: '  server ',
          workspaceId: ' workspace  ',
        ),
      );
      await pumpMicrotasks();

      expect(notifications, 1);
      expect(storage.writeCount, 1);
    });

    // extra: listeners see both the remember and the hydration settle.
    test('notifies subscribers on remember and on hydration, until '
        'unsubscribed', () async {
      final storage = DelayedWorkspaceSelectionStorage();
      final store = LastWorkspaceSelectionStore(storage);
      var notifications = 0;
      final unsubscribe = store.subscribe(() => notifications += 1);

      final hydration = store.hydrate();
      store.remember(const HostWorkspaceRoute(serverId: 'a', workspaceId: 'b'));
      expect(notifications, 1);

      storage.finishHydrationWithRaw(null);
      await hydration;
      expect(notifications, 2);

      unsubscribe();
      store.remember(const HostWorkspaceRoute(serverId: 'c', workspaceId: 'd'));
      expect(notifications, 2);
    });

    // extra: losing the memory is not worth surfacing to the user.
    test('a failing write keeps the in-memory selection', () async {
      final store = LastWorkspaceSelectionStore(ThrowingStorage());

      store.remember(
        const HostWorkspaceRoute(serverId: 'server', workspaceId: 'workspace'),
      );
      await pumpMicrotasks();

      expect(store.getSelection(), isSelection('server', 'workspace'));
    });

    // extra: the app-wide storage key both this store and the Riverpod
    // notifier read.
    test('exposes the shared storage key', () {
      expect(
        lastWorkspaceRouteSelectionStorageKey,
        'tinyrack:last-workspace-route-selection',
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

enum LaunchAction { draft, terminal, browser, profile }

final class RecordedLaunch {
  const RecordedLaunch(this.action, {this.profile});

  final LaunchAction action;
  final TerminalProfileInput? profile;

  @override
  bool operator ==(Object other) =>
      other is RecordedLaunch &&
      other.action == action &&
      other.profile == profile;

  @override
  int get hashCode => Object.hash(action, profile);

  @override
  String toString() => 'RecordedLaunch($action, profile: $profile)';
}

final class LaunchRecorder {
  final List<RecordedLaunch> launches = [];

  late final TabTargetHandlers handlers = TabTargetHandlers(
    createDraft: () => launches.add(const RecordedLaunch(LaunchAction.draft)),
    createTerminal: () =>
        launches.add(const RecordedLaunch(LaunchAction.terminal)),
    createBrowser: () =>
        launches.add(const RecordedLaunch(LaunchAction.browser)),
    createTerminalWithProfile: (profile) =>
        launches.add(RecordedLaunch(LaunchAction.profile, profile: profile)),
  );
}

/// Upstream's `DelayedWorkspaceSelectionStorage`: the read is held open until
/// the test decides, which is the only way to exercise the hydration race.
final class DelayedWorkspaceSelectionStorage
    implements LastWorkspaceSelectionStorage {
  final Completer<String?> _pendingRead = Completer<String?>();

  int readCount = 0;
  int writeCount = 0;
  String? saved;

  @override
  Future<String?> read() {
    readCount += 1;
    return _pendingRead.future;
  }

  @override
  Future<void> write(String value) async {
    writeCount += 1;
    saved = value;
  }

  void finishHydrationWith(HostWorkspaceRoute? selection) =>
      finishHydrationWithRaw(
        selection == null
            ? null
            : jsonEncode({
                'serverId': selection.serverId,
                'workspaceId': selection.workspaceId,
              }),
      );

  void finishHydrationWithRaw(String? stored) => _pendingRead.complete(stored);

  void failHydration(Object error) => _pendingRead.completeError(error);

  Map<String, Object?>? savedSelection() {
    final value = saved;
    return value == null ? null : jsonDecode(value) as Map<String, Object?>;
  }
}

/// Fails synchronously on both sides, which JS `Promise` rejection and a Dart
/// synchronous `throw` must be handled identically for.
final class ThrowingStorage implements LastWorkspaceSelectionStorage {
  @override
  Future<String?> read() => throw StateError('read failed');

  @override
  Future<void> write(String value) => throw StateError('write failed');
}

/// Lets every already-scheduled microtask (the fire-and-forget write) run.
Future<void> pumpMicrotasks() => Future<void>.delayed(Duration.zero);
