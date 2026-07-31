// Ports of the upstream Vitest suites for six frozen Paseo 0.2.0 `utils/`
// modules: confirm-dialog, assistant-message-height-estimate, sidebar-shortcuts,
// markdown-list, schedule-format and os-notifications.
//
// Every upstream case is reproduced. Cases the upstream suites leave unpinned —
// the `parseInt` shape of an ordered-list `start`, LRU eviction in the height
// cache, the double-blur a desktop bridge without `dialog.ask` causes, the
// permission-request coalescing in the notifier — were pinned by executing the
// frozen TypeScript under Node and recording its exact output, not by reasoning
// about it.
import 'dart:async';

import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/paseo_more_utils.dart';
import 'package:coding_agent_app/sidebar/paseo_sidebar_view_models.dart'
    show buildStatusGroups;
import 'package:coding_agent_app/sidebar/sidebar_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('confirmDialog', () {
    test('uses the desktop dialog bridge on web when available', () async {
      final host = _FakeConfirmDialogHost(
        desktopAsk: (message, options) async => true,
      );

      final confirmed = await confirmDialog(
        input: const ConfirmDialogInput(
          title: 'Restart host',
          message: 'This will restart the daemon.',
          confirmLabel: 'Restart',
          cancelLabel: 'Cancel',
          destructive: true,
        ),
        host: host,
      );

      expect(confirmed, isTrue);
      expect(host.nativeCalls, isEmpty);
      expect(host.browserConfirmCalls, isEmpty);
      expect(host.blurCount, 1);
      expect(host.desktopAskCalls, [
        const _DesktopAskCall(
          message: 'This will restart the daemon.',
          options: DesktopDialogAskOptions(
            title: 'Restart host',
            okLabel: 'Restart',
            cancelLabel: 'Cancel',
            kind: DesktopDialogKind.warning,
          ),
        ),
      ]);
    });

    test('returns the desktop bridge\'s decline verbatim', () async {
      final host = _FakeConfirmDialogHost(
        desktopAsk: (message, options) async => false,
      );

      expect(
        await confirmDialog(
          input: const ConfirmDialogInput(title: 'T', message: 'M'),
          host: host,
        ),
        isFalse,
      );
      expect(host.browserConfirmCalls, isEmpty);
    });

    test(
      'falls back to browser confirm on web when desktop APIs are unavailable',
      () async {
        final host = _FakeConfirmDialogHost(confirmBackend: (_) => true);

        final confirmed = await confirmDialog(
          input: const ConfirmDialogInput(
            title: 'Restart host',
            message: 'This will restart the daemon.',
          ),
          host: host,
        );

        expect(confirmed, isTrue);
        expect(host.blurCount, 1);
        expect(host.browserConfirmCalls, [
          'Restart host\n\nThis will restart the daemon.',
        ]);
      },
    );

    test('throws on web when no confirm backend exists', () async {
      final host = _FakeConfirmDialogHost();

      await expectLater(
        confirmDialog(
          input: const ConfirmDialogInput(
            title: 'Restart host',
            message: 'This will restart the daemon.',
          ),
          host: host,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            confirmDialogNoBackendMessage,
          ),
        ),
      );
    });

    test('uses native Alert on iOS/Android', () async {
      final host = _FakeConfirmDialogHost(
        isNative: true,
        nativeAnswer: true,
        // Present but unreachable: the native branch returns before either.
        desktopAsk: (message, options) async => false,
        confirmBackend: (_) => false,
      );

      final confirmed = await confirmDialog(
        input: const ConfirmDialogInput(
          title: 'Restart host',
          message: 'This will restart the daemon.',
          confirmLabel: 'Restart',
          cancelLabel: 'Cancel',
          destructive: true,
        ),
        host: host,
      );

      expect(confirmed, isTrue);
      expect(host.nativeCalls, [
        const _NativeConfirmCall(
          title: 'Restart host',
          message: 'This will restart the daemon.',
          labels: ConfirmButtonLabels(
            confirmLabel: 'Restart',
            cancelLabel: 'Cancel',
          ),
          destructive: true,
        ),
      ]);
      expect(host.desktopAskCalls, isEmpty);
      expect(host.browserConfirmCalls, isEmpty);
      // Native never blurs a web element.
      expect(host.blurCount, 0);
    });

    test('a native dismissal is a decline', () async {
      final host = _FakeConfirmDialogHost(isNative: true, nativeAnswer: false);

      expect(
        await confirmDialog(
          input: const ConfirmDialogInput(title: 'T', message: 'M'),
          host: host,
        ),
        isFalse,
      );
    });

    test('applies the default button labels and non-destructive kind', () {
      const input = ConfirmDialogInput(title: 'Title', message: 'Message');

      expect(
        resolveConfirmButtonLabels(input),
        const ConfirmButtonLabels(
          confirmLabel: 'Confirm',
          cancelLabel: 'Cancel',
        ),
      );
      expect(
        buildDesktopAskOptions(input),
        const DesktopDialogAskOptions(
          title: 'Title',
          okLabel: 'Confirm',
          cancelLabel: 'Cancel',
          kind: DesktopDialogKind.info,
        ),
      );
      // An explicit false is the same as omitting it.
      expect(
        buildDesktopAskOptions(
          const ConfirmDialogInput(
            title: 'Title',
            message: 'Message',
            destructive: false,
          ),
        ).kind,
        DesktopDialogKind.info,
      );
      // An empty label is a real label, not a missing one: `?? "Confirm"` only
      // fires on undefined.
      expect(
        resolveConfirmButtonLabels(
          const ConfirmDialogInput(
            title: 'T',
            message: 'M',
            confirmLabel: '',
            cancelLabel: '',
          ),
        ),
        const ConfirmButtonLabels(confirmLabel: '', cancelLabel: ''),
      );
    });

    test('joins title and message for the browser prompt', () {
      expect(
        buildWebConfirmPrompt(
          const ConfirmDialogInput(title: 'Title', message: 'Message'),
        ),
        'Title\n\nMessage',
      );
    });

    test(
      'a desktop bridge without dialog.ask falls through and blurs twice',
      () async {
        final host = _FakeConfirmDialogHost(
          hasDesktopBridge: true,
          confirmBackend: (_) => true,
        );

        expect(
          await confirmDialog(
            input: const ConfirmDialogInput(title: 'T', message: 'M'),
            host: host,
          ),
          isTrue,
        );
        // Upstream blurs the moment a bridge object exists, then again on the
        // browser-confirm path. Reproduced verbatim.
        expect(host.blurCount, 2);
        expect(host.browserConfirmCalls, ['T\n\nM']);
      },
    );

    test(
      'a desktop bridge without dialog.ask and no browser confirm throws',
      () async {
        final host = _FakeConfirmDialogHost(hasDesktopBridge: true);

        await expectLater(
          confirmDialog(
            input: const ConfirmDialogInput(title: 'T', message: 'M'),
            host: host,
          ),
          throwsA(isA<StateError>()),
        );
        expect(host.blurCount, 1);
      },
    );
  });

  group('assistant message height estimate', () {
    setUp(clearAssistantMessageHeightEstimateCache);

    test(
      'estimates assistant message height from measured markdown block heights',
      () {
        setAssistantMarkdownBlockHeight(
          block: 'First paragraph',
          width: 804,
          height: 18.2,
        );
        setAssistantMarkdownBlockHeight(
          block: 'Second paragraph',
          width: 804,
          height: 41.1,
        );

        // 24 padding + ceil(18.2) + ceil(41.1) + 12 gap.
        expect(
          estimateAssistantMessageHeightFromCache(
            'First paragraph\n\nSecond paragraph',
          ),
          97,
        );
      },
    );

    test('falls back to the injected image estimator', () {
      final cache = AssistantMessageHeightEstimateCache(
        imageFallback: (markdown) => markdown.contains('![') ? 320 : null,
      );

      expect(
        cache.estimateFromCache(
          'Here is the screenshot\n\n'
          '![Screenshot](https://example.com/landscape.png)',
        ),
        320,
      );
      // The fallback is consulted only when the markdown path yields nothing.
      cache.setMarkdownBlockHeight(block: 'Measured', width: 804, height: 30);
      expect(cache.estimateFromCache('Measured'), 54);
      // No fallback at all is the process-wide default.
      expect(
        estimateAssistantMessageHeightFromCache(
          '![Screenshot](https://example.com/landscape.png)',
        ),
        isNull,
      );
    });

    test('setAssistantMarkdownBlockHeight ceils and validates', () {
      expect(
        setAssistantMarkdownBlockHeight(block: 'a', width: 804, height: 18.2),
        19,
      );
      expect(
        setAssistantMarkdownBlockHeight(block: 'b', width: 804, height: 20),
        20,
      );
      expect(
        setAssistantMarkdownBlockHeight(block: 'c', width: 804, height: 0),
        isNull,
      );
      expect(
        setAssistantMarkdownBlockHeight(block: 'c', width: 804, height: -3),
        isNull,
      );
      expect(
        setAssistantMarkdownBlockHeight(
          block: 'c',
          width: 804,
          height: double.nan,
        ),
        isNull,
      );
      expect(
        setAssistantMarkdownBlockHeight(
          block: 'c',
          width: 804,
          height: double.infinity,
        ),
        isNull,
      );
      // An empty block would collide with every other empty block.
      expect(
        setAssistantMarkdownBlockHeight(block: '', width: 804, height: 10),
        isNull,
      );
      expect(
        setAssistantMarkdownBlockHeight(block: 'd', width: 0, height: 10),
        isNull,
      );
      expect(
        setAssistantMarkdownBlockHeight(block: 'd', width: -5, height: 10),
        isNull,
      );
      expect(
        setAssistantMarkdownBlockHeight(
          block: 'd',
          width: double.nan,
          height: 10,
        ),
        isNull,
      );
      // A sub-pixel width still keys at the rounded width.
      expect(
        setAssistantMarkdownBlockHeight(block: 'e', width: 803.6, height: 10),
        10,
      );
    });

    test('is all-or-nothing across blocks', () {
      expect(estimateAssistantMessageHeightFromCache(''), isNull);
      expect(estimateAssistantMessageHeightFromCache('hello'), isNull);

      setAssistantMarkdownBlockHeight(
        block: 'First paragraph',
        width: 804,
        height: 18.2,
      );
      expect(estimateAssistantMessageHeightFromCache('First paragraph'), 43);
      expect(
        estimateAssistantMessageHeightFromCache(
          'First paragraph\n\nSecond paragraph',
        ),
        isNull,
      );

      setAssistantMarkdownBlockHeight(
        block: 'Second paragraph',
        width: 804,
        height: 41.1,
      );
      expect(
        estimateAssistantMessageHeightFromCache(
          'First paragraph\n\nSecond paragraph',
        ),
        97,
      );
      expect(
        estimateAssistantMessageHeightFromCache(
          'First paragraph\n\nSecond paragraph\n\nThird',
        ),
        isNull,
      );
    });

    test('keys on the rounded estimate width only', () {
      setAssistantMarkdownBlockHeight(
        block: 'Rounded',
        width: 803.6,
        height: 30,
      );
      expect(estimateAssistantMessageHeightFromCache('Rounded'), 54);

      clearAssistantMessageHeightEstimateCache();
      setAssistantMarkdownBlockHeight(block: 'Rounded', width: 800, height: 30);
      expect(estimateAssistantMessageHeightFromCache('Rounded'), isNull);
    });

    test('a re-measure replaces the previous height', () {
      setAssistantMarkdownBlockHeight(block: 'Re', width: 804, height: 30);
      setAssistantMarkdownBlockHeight(block: 'Re', width: 804, height: 50);
      expect(estimateAssistantMessageHeightFromCache('Re'), 74);
    });

    test('a fenced code span stays one block', () {
      const fenced = '```js\nconst a = 1;\n\nconst b = 2;\n```';
      setAssistantMarkdownBlockHeight(block: fenced, width: 804, height: 100);
      // One block: 24 padding + 100, with no inter-block gap.
      expect(estimateAssistantMessageHeightFromCache(fenced), 124);
    });

    test('leading blank lines start no block', () {
      setAssistantMarkdownBlockHeight(block: 'Body', width: 804, height: 10);
      expect(estimateAssistantMessageHeightFromCache('\n\nBody'), 34);
    });

    test('evicts the least recently touched entry past the limit', () {
      for (var i = 0; i <= assistantMarkdownBlockHeightCacheLimit; i += 1) {
        setAssistantMarkdownBlockHeight(
          block: 'blk-$i',
          width: 804,
          height: 10,
        );
      }

      expect(estimateAssistantMessageHeightFromCache('blk-0'), isNull);
      expect(estimateAssistantMessageHeightFromCache('blk-1'), 34);
      expect(
        estimateAssistantMessageHeightFromCache(
          'blk-$assistantMarkdownBlockHeightCacheLimit',
        ),
        34,
      );
    });

    test('re-measuring refreshes an entry\'s recency', () {
      final cache = AssistantMessageHeightEstimateCache();
      for (var i = 0; i < assistantMarkdownBlockHeightCacheLimit; i += 1) {
        cache.setMarkdownBlockHeight(block: 'k-$i', width: 804, height: 10);
      }
      expect(cache.length, assistantMarkdownBlockHeightCacheLimit);

      cache.setMarkdownBlockHeight(block: 'k-0', width: 804, height: 10);
      cache.setMarkdownBlockHeight(block: 'extra', width: 804, height: 10);

      expect(cache.estimateFromCache('k-0'), 34);
      expect(cache.estimateFromCache('k-1'), isNull);
      expect(cache.length, assistantMarkdownBlockHeightCacheLimit);
    });

    test('clear empties the cache', () {
      final cache = AssistantMessageHeightEstimateCache();
      cache.setMarkdownBlockHeight(block: 'x', width: 804, height: 10);
      expect(cache.length, 1);
      cache.clear();
      expect(cache.length, 0);
      expect(cache.estimateFromCache('x'), isNull);
    });
  });

  group('buildSidebarShortcutModel', () {
    test(
      'builds shortcut targets in visual order and excludes collapsed projects',
      () {
        final projects = [
          _project('p1', [
            _workspace(
              serverId: 's1',
              workspaceId: 'ws-main',
              name: 'main',
              projectKey: 'p1',
            ),
            _workspace(
              serverId: 's1',
              workspaceId: 'ws-feat-a',
              name: 'feat-a',
              projectKey: 'p1',
            ),
          ]),
          _project('p2', [
            _workspace(
              serverId: 's1',
              workspaceId: 'ws-repo2-main',
              name: 'main',
              projectKey: 'p2',
            ),
            _workspace(
              serverId: 's1',
              workspaceId: 'ws-repo2-feat-a',
              name: 'feat-a',
              projectKey: 'p2',
            ),
          ]),
        ];

        final model = buildSidebarShortcutModel(
          projects: projects,
          collapsedProjectKeys: {'p2'},
        );

        expect(model.shortcutTargets, const [
          SidebarShortcutWorkspaceTarget(
            serverId: 's1',
            workspaceId: 'ws-main',
          ),
          SidebarShortcutWorkspaceTarget(
            serverId: 's1',
            workspaceId: 'ws-feat-a',
          ),
        ]);
        expect(model.shortcutIndexByWorkspaceKey['s1:ws-main'], 1);
        expect(model.shortcutIndexByWorkspaceKey['s1:ws-feat-a'], 2);
        expect(
          model.shortcutIndexByWorkspaceKey.containsKey('s1:ws-repo2-main'),
          isFalse,
        );
      },
    );

    test('limits shortcuts to 9', () {
      final workspaces = [
        for (var index = 1; index <= 20; index += 1)
          _workspace(serverId: 's', workspaceId: 'ws-$index', name: 'w$index'),
      ];

      final model = buildSidebarShortcutModel(
        projects: [_project('p', workspaces)],
        collapsedProjectKeys: const {},
      );

      expect(model.shortcutTargets, hasLength(9));
      expect(
        model.shortcutTargets.first,
        const SidebarShortcutWorkspaceTarget(
          serverId: 's',
          workspaceId: 'ws-1',
        ),
      );
      expect(
        model.shortcutTargets[8],
        const SidebarShortcutWorkspaceTarget(
          serverId: 's',
          workspaceId: 'ws-9',
        ),
      );
    });

    test(
      'excludes a collapsed project\'s workspaces regardless of project kind',
      () {
        final gitProject = _project('p1', [
          _workspace(serverId: 's1', workspaceId: 'ws-main', name: 'main'),
        ]);
        final directoryProject = _project(
          'p2',
          [
            _workspace(
              serverId: 's1',
              workspaceId: 'ws-script',
              name: 'scripts',
            ),
          ],
          projectKind: WorkspaceProjectKind.directory,
          canCreateWorktree: false,
        );

        final model = buildSidebarShortcutModel(
          projects: [gitProject, directoryProject],
          collapsedProjectKeys: {'p1', 'p2'},
        );

        expect(model.shortcutTargets, isEmpty);
        expect(model.shortcutIndexByWorkspaceKey, isEmpty);
      },
    );

    test('a zero or negative limit disables numbering entirely', () {
      final projects = [
        _project('p', [
          _workspace(serverId: 's', workspaceId: 'ws-1', name: 'w1'),
        ]),
      ];

      expect(
        buildSidebarShortcutModel(
          projects: projects,
          collapsedProjectKeys: const {},
          shortcutLimit: 0,
        ).shortcutTargets,
        isEmpty,
      );
      expect(
        buildSidebarShortcutModel(
          projects: projects,
          collapsedProjectKeys: const {},
          shortcutLimit: -4,
        ).shortcutTargets,
        isEmpty,
      );
    });

    test('a fractional limit floors', () {
      final projects = [
        _project('p', [
          for (var index = 1; index <= 5; index += 1)
            _workspace(
              serverId: 's',
              workspaceId: 'ws-$index',
              name: 'w$index',
            ),
        ]),
      ];

      expect(
        buildSidebarShortcutModel(
          projects: projects,
          collapsedProjectKeys: const {},
          shortcutLimit: 2.9,
        ).shortcutTargets,
        hasLength(2),
      );
    });
  });

  group('buildSidebarShortcutSections', () {
    test('a null collapsed flag is the same as not collapsed', () {
      final model = buildSidebarShortcutSections(
        sections: [
          SidebarShortcutSection(
            workspaces: [
              _workspace(serverId: 's', workspaceId: 'ws-1', name: 'w1'),
            ],
          ),
        ],
      );

      expect(model.shortcutTargets, hasLength(1));
    });

    test('numbering runs across sections, not within them', () {
      final model = buildSidebarShortcutSections(
        sections: [
          SidebarShortcutSection(
            workspaces: [
              _workspace(serverId: 's', workspaceId: 'a', name: 'a'),
            ],
          ),
          SidebarShortcutSection(
            workspaces: [
              _workspace(serverId: 's', workspaceId: 'b', name: 'b'),
            ],
            collapsed: true,
          ),
          SidebarShortcutSection(
            workspaces: [
              _workspace(serverId: 's', workspaceId: 'c', name: 'c'),
            ],
          ),
        ],
      );

      expect(model.shortcutIndexByWorkspaceKey, {'s:a': 1, 's:c': 2});
    });

    test('the limit is a total, not a per-section budget', () {
      final model = buildSidebarShortcutSections(
        sections: [
          SidebarShortcutSection(
            workspaces: [
              _workspace(serverId: 's', workspaceId: 'a', name: 'a'),
              _workspace(serverId: 's', workspaceId: 'b', name: 'b'),
            ],
          ),
          SidebarShortcutSection(
            workspaces: [
              _workspace(serverId: 's', workspaceId: 'c', name: 'c'),
            ],
          ),
        ],
        shortcutLimit: 2,
      );

      expect(model.shortcutIndexByWorkspaceKey, {'s:a': 1, 's:b': 2});
    });

    test('no sections yields an empty model', () {
      final model = buildSidebarShortcutSections(sections: const []);
      expect(model.shortcutTargets, isEmpty);
      expect(model.shortcutIndexByWorkspaceKey, isEmpty);
    });

    test('the default limit is nine', () {
      expect(defaultSidebarShortcutLimit, 9);
    });
  });

  group('buildStatusSidebarShortcutModel', () {
    test('builds shortcut targets in status visual order', () {
      final workspaces = [
        _workspace(
          serverId: 's1',
          workspaceId: 'done-old',
          name: 'done old',
          projectKey: 'p1',
          statusBucket: WorkspaceStateBucket.done,
          statusEnteredAt: DateTime.parse('2026-01-01T00:00:00.000Z'),
        ),
        _workspace(
          serverId: 's1',
          workspaceId: 'running-new',
          name: 'running new',
          projectKey: 'p2',
          statusBucket: WorkspaceStateBucket.running,
          statusEnteredAt: DateTime.parse('2026-03-01T00:00:00.000Z'),
        ),
        _workspace(
          serverId: 's1',
          workspaceId: 'needs-input',
          name: 'needs input',
          projectKey: 'p1',
          statusBucket: WorkspaceStateBucket.needsInput,
          statusEnteredAt: DateTime.parse('2026-02-01T00:00:00.000Z'),
        ),
        _workspace(
          serverId: 's1',
          workspaceId: 'running-old',
          name: 'running old',
          projectKey: 'p2',
          statusBucket: WorkspaceStateBucket.running,
          statusEnteredAt: DateTime.parse('2026-01-15T00:00:00.000Z'),
        ),
      ];

      final model = buildStatusSidebarShortcutModel(
        groups: buildStatusGroups(workspaces, const {
          'p1': 'Project 1',
          'p2': 'Project 2',
        }),
      );

      expect(model.shortcutTargets, const [
        SidebarShortcutWorkspaceTarget(
          serverId: 's1',
          workspaceId: 'needs-input',
        ),
        SidebarShortcutWorkspaceTarget(
          serverId: 's1',
          workspaceId: 'running-new',
        ),
        SidebarShortcutWorkspaceTarget(
          serverId: 's1',
          workspaceId: 'running-old',
        ),
        SidebarShortcutWorkspaceTarget(serverId: 's1', workspaceId: 'done-old'),
      ]);
      expect(model.shortcutIndexByWorkspaceKey['s1:needs-input'], 1);
      expect(model.shortcutIndexByWorkspaceKey['s1:running-new'], 2);
      expect(model.shortcutIndexByWorkspaceKey['s1:running-old'], 3);
      expect(model.shortcutIndexByWorkspaceKey['s1:done-old'], 4);
    });

    test('excludes collapsed status groups from shortcut targets', () {
      final workspaces = [
        _workspace(
          serverId: 's1',
          workspaceId: 'needs-input',
          name: 'needs input',
          projectKey: 'p1',
          statusBucket: WorkspaceStateBucket.needsInput,
        ),
        _workspace(
          serverId: 's1',
          workspaceId: 'running',
          name: 'running',
          projectKey: 'p1',
          statusBucket: WorkspaceStateBucket.running,
        ),
      ];

      final model = buildStatusSidebarShortcutModel(
        groups: buildStatusGroups(workspaces, const {'p1': 'Project 1'}),
        collapsedStatusGroupKeys: {WorkspaceStateBucket.needsInput.wireName},
      );

      expect(model.shortcutTargets, const [
        SidebarShortcutWorkspaceTarget(serverId: 's1', workspaceId: 'running'),
      ]);
      expect(
        model.shortcutIndexByWorkspaceKey.containsKey('s1:needs-input'),
        isFalse,
      );
      expect(model.shortcutIndexByWorkspaceKey['s1:running'], 1);
    });

    test('omitting the collapsed set numbers every group', () {
      final workspaces = [
        _workspace(
          serverId: 's1',
          workspaceId: 'needs-input',
          name: 'needs input',
          projectKey: 'p1',
          statusBucket: WorkspaceStateBucket.needsInput,
        ),
        _workspace(
          serverId: 's1',
          workspaceId: 'running',
          name: 'running',
          projectKey: 'p1',
          statusBucket: WorkspaceStateBucket.running,
        ),
      ];

      final model = buildStatusSidebarShortcutModel(
        groups: buildStatusGroups(workspaces, const {'p1': 'Project 1'}),
      );

      expect(model.shortcutTargets, hasLength(2));
    });
  });

  group('getRelativeSidebarShortcutTarget', () {
    const targets = [
      SidebarShortcutWorkspaceTarget(serverId: 's1', workspaceId: 'ws-1'),
      SidebarShortcutWorkspaceTarget(serverId: 's1', workspaceId: 'ws-2'),
      SidebarShortcutWorkspaceTarget(serverId: 's1', workspaceId: 'ws-3'),
    ];

    test(
      'moves backward and forward through the numbered shortcut target list',
      () {
        expect(
          getRelativeSidebarShortcutTarget(
            targets: targets,
            currentTarget: const SidebarShortcutWorkspaceTarget(
              serverId: 's1',
              workspaceId: 'ws-2',
            ),
            delta: SidebarShortcutDelta.previous,
          ),
          const SidebarShortcutWorkspaceTarget(
            serverId: 's1',
            workspaceId: 'ws-1',
          ),
        );
        expect(
          getRelativeSidebarShortcutTarget(
            targets: targets,
            currentTarget: const SidebarShortcutWorkspaceTarget(
              serverId: 's1',
              workspaceId: 'ws-2',
            ),
            delta: SidebarShortcutDelta.next,
          ),
          const SidebarShortcutWorkspaceTarget(
            serverId: 's1',
            workspaceId: 'ws-3',
          ),
        );
      },
    );

    test('wraps around the numbered shortcut target list', () {
      expect(
        getRelativeSidebarShortcutTarget(
          targets: targets,
          currentTarget: const SidebarShortcutWorkspaceTarget(
            serverId: 's1',
            workspaceId: 'ws-1',
          ),
          delta: SidebarShortcutDelta.previous,
        ),
        const SidebarShortcutWorkspaceTarget(
          serverId: 's1',
          workspaceId: 'ws-3',
        ),
      );
      expect(
        getRelativeSidebarShortcutTarget(
          targets: targets,
          currentTarget: const SidebarShortcutWorkspaceTarget(
            serverId: 's1',
            workspaceId: 'ws-3',
          ),
          delta: SidebarShortcutDelta.next,
        ),
        const SidebarShortcutWorkspaceTarget(
          serverId: 's1',
          workspaceId: 'ws-1',
        ),
      );
    });

    test('falls back to the nearest edge when the current route is not in the '
        'numbered list', () {
      expect(
        getRelativeSidebarShortcutTarget(
          targets: targets,
          currentTarget: const SidebarShortcutWorkspaceTarget(
            serverId: 's1',
            workspaceId: 'ws-hidden',
          ),
          delta: SidebarShortcutDelta.next,
        ),
        const SidebarShortcutWorkspaceTarget(
          serverId: 's1',
          workspaceId: 'ws-1',
        ),
      );
      expect(
        getRelativeSidebarShortcutTarget(
          targets: targets,
          currentTarget: const SidebarShortcutWorkspaceTarget(
            serverId: 's1',
            workspaceId: 'ws-hidden',
          ),
          delta: SidebarShortcutDelta.previous,
        ),
        const SidebarShortcutWorkspaceTarget(
          serverId: 's1',
          workspaceId: 'ws-3',
        ),
      );
    });

    test(
      'a null current target enters at the edge it is heading away from',
      () {
        expect(
          getRelativeSidebarShortcutTarget(
            targets: targets,
            currentTarget: null,
            delta: SidebarShortcutDelta.next,
          ),
          const SidebarShortcutWorkspaceTarget(
            serverId: 's1',
            workspaceId: 'ws-1',
          ),
        );
        expect(
          getRelativeSidebarShortcutTarget(
            targets: targets,
            currentTarget: null,
            delta: SidebarShortcutDelta.previous,
          ),
          const SidebarShortcutWorkspaceTarget(
            serverId: 's1',
            workspaceId: 'ws-3',
          ),
        );
      },
    );

    test('an empty target list has no relative target', () {
      expect(
        getRelativeSidebarShortcutTarget(
          targets: const [],
          currentTarget: null,
          delta: SidebarShortcutDelta.next,
        ),
        isNull,
      );
      expect(
        getRelativeSidebarShortcutTarget(
          targets: const [],
          currentTarget: const SidebarShortcutWorkspaceTarget(
            serverId: 's1',
            workspaceId: 'ws-1',
          ),
          delta: SidebarShortcutDelta.previous,
        ),
        isNull,
      );
    });

    test('a single target is its own neighbour in both directions', () {
      const one = [
        SidebarShortcutWorkspaceTarget(serverId: 's1', workspaceId: 'only'),
      ];
      for (final delta in SidebarShortcutDelta.values) {
        expect(
          getRelativeSidebarShortcutTarget(
            targets: one,
            currentTarget: one.first,
            delta: delta,
          ),
          one.first,
        );
      }
    });

    test('matching is on server plus workspace, not workspace alone', () {
      const mixed = [
        SidebarShortcutWorkspaceTarget(serverId: 's1', workspaceId: 'ws'),
        SidebarShortcutWorkspaceTarget(serverId: 's2', workspaceId: 'ws'),
      ];

      expect(
        getRelativeSidebarShortcutTarget(
          targets: mixed,
          currentTarget: const SidebarShortcutWorkspaceTarget(
            serverId: 's2',
            workspaceId: 'ws',
          ),
          delta: SidebarShortcutDelta.next,
        ),
        mixed.first,
      );
    });
  });

  group('getMarkdownListMarker', () {
    test('returns a bullet marker for unordered list items', () {
      expect(
        getMarkdownListMarker(const MarkdownListNode(index: 0), const [
          MarkdownListNode(type: 'bullet_list'),
        ]),
        const MarkdownListMarker(isOrdered: false, marker: '•'),
      );
    });

    test('returns numbered markers for ordered list items', () {
      expect(
        getMarkdownListMarker(
          const MarkdownListNode(index: 1, markup: '.'),
          const [MarkdownListNode(type: 'ordered_list')],
        ),
        const MarkdownListMarker(isOrdered: true, marker: '2.'),
      );
    });

    test('respects ordered list start attribute', () {
      expect(
        getMarkdownListMarker(
          const MarkdownListNode(index: 2, markup: ')'),
          const [
            MarkdownListNode(
              type: 'ordered_list',
              start: MarkdownOrderedListStart.text('5'),
            ),
          ],
        ),
        const MarkdownListMarker(isOrdered: true, marker: '7)'),
      );
      expect(
        getMarkdownListMarker(
          const MarkdownListNode(index: 0, markup: '.'),
          const [
            MarkdownListNode(
              type: 'ordered_list',
              start: MarkdownOrderedListStart.number(10),
            ),
          ],
        ),
        const MarkdownListMarker(isOrdered: true, marker: '10.'),
      );
    });

    test('prefers the nearest list ancestor in nested lists', () {
      expect(
        getMarkdownListMarker(
          const MarkdownListNode(index: 0, markup: '.'),
          const [
            MarkdownListNode(type: 'ordered_list'),
            MarkdownListNode(type: 'bullet_list'),
          ],
        ),
        const MarkdownListMarker(isOrdered: true, marker: '1.'),
      );
      // Index 0 is the nearest ancestor, so a bullet list there wins over an
      // ordered list further out.
      expect(
        getMarkdownListMarker(
          const MarkdownListNode(index: 0, markup: '.'),
          const [
            MarkdownListNode(type: 'bullet_list'),
            MarkdownListNode(type: 'ordered_list'),
          ],
        ),
        const MarkdownListMarker(isOrdered: false, marker: '•'),
      );
    });

    test('falls back to a bullet when no list ancestor is reachable', () {
      expect(
        getMarkdownListMarker(const MarkdownListNode(index: 0), null),
        const MarkdownListMarker(isOrdered: false, marker: '•'),
      );
      expect(
        getMarkdownListMarker(const MarkdownListNode(index: 0), const [
          MarkdownListNode(type: 'list_item'),
        ]),
        const MarkdownListMarker(isOrdered: false, marker: '•'),
      );
      expect(
        getMarkdownListMarker(const MarkdownListNode(index: 0), 'not a node'),
        const MarkdownListMarker(isOrdered: false, marker: '•'),
      );
    });

    test('accepts a bare ancestor node as well as a chain', () {
      expect(
        getMarkdownListMarker(
          const MarkdownListNode(index: 3),
          const MarkdownListNode(type: 'ordered_list'),
        ),
        const MarkdownListMarker(isOrdered: true, marker: '4.'),
      );
    });

    test('an empty markup falls back to the default delimiter', () {
      expect(
        getMarkdownListMarker(
          const MarkdownListNode(index: 0, markup: ''),
          const [MarkdownListNode(type: 'ordered_list')],
        ),
        const MarkdownListMarker(isOrdered: true, marker: '1.'),
      );
    });

    test('a negative index falls through to the positional fallback', () {
      expect(
        getMarkdownListMarker(
          const MarkdownListNode(index: -2, markup: '.'),
          const [MarkdownListNode(type: 'ordered_list')],
        ),
        const MarkdownListMarker(isOrdered: true, marker: '1.'),
      );
    });

    test('an absent index is recovered from the parent\'s children', () {
      const node = MarkdownListNode(markup: '.');
      expect(
        getMarkdownListMarker(node, const [
          MarkdownListNode(
            type: 'ordered_list',
            children: [
              MarkdownListNode(type: 'list_item'),
              MarkdownListNode(type: 'paragraph'),
              node,
            ],
          ),
        ]),
        const MarkdownListMarker(isOrdered: true, marker: '3.'),
      );
      // Not found among the children means "treat it as first".
      expect(
        getMarkdownListMarker(const MarkdownListNode(markup: '.'), const [
          MarkdownListNode(
            type: 'ordered_list',
            children: [
              MarkdownListNode(type: 'list_item'),
              MarkdownListNode(type: 'paragraph'),
            ],
          ),
        ]),
        const MarkdownListMarker(isOrdered: true, marker: '1.'),
      );
    });

    test('parses a textual start with JavaScript parseInt semantics', () {
      MarkdownListMarker markerForStart(String start) =>
          getMarkdownListMarker(const MarkdownListNode(index: 0, markup: '.'), [
            MarkdownListNode(
              type: 'ordered_list',
              start: MarkdownOrderedListStart.text(start),
            ),
          ]);

      // A non-numeric start is not a number at all, so the list counts from 1.
      expect(markerForStart('abc').marker, '1.');
      // parseInt takes the leading integer run, so "3.7" is 3.
      expect(markerForStart('3.7').marker, '3.');
      expect(markerForStart('-2').marker, '-2.');
      expect(markerForStart('+7').marker, '7.');
      expect(markerForStart('  5  ').marker, '5.');
      expect(markerForStart('').marker, '1.');
    });

    test('a non-finite numeric start counts from 1', () {
      expect(
        getMarkdownListMarker(
          const MarkdownListNode(index: 0, markup: '.'),
          const [
            MarkdownListNode(
              type: 'ordered_list',
              start: MarkdownOrderedListStart.number(double.nan),
            ),
          ],
        ),
        const MarkdownListMarker(isOrdered: true, marker: '1.'),
      );
    });

    test('a fractional index reaches the rendered marker', () {
      expect(
        getMarkdownListMarker(
          const MarkdownListNode(index: 1.5, markup: '.'),
          const [MarkdownListNode(type: 'ordered_list')],
        ),
        const MarkdownListMarker(isOrdered: true, marker: '2.5.'),
      );
      // A whole double must not print as "1.0.".
      expect(
        getMarkdownListMarker(
          const MarkdownListNode(index: 2.0, markup: '.'),
          const [MarkdownListNode(type: 'ordered_list')],
        ),
        const MarkdownListMarker(isOrdered: true, marker: '3.'),
      );
    });
  });

  group('getMarkdownListSpacing', () {
    test('keeps top-level list spacing as a section boundary', () {
      const list = MarkdownListNode(type: 'bullet_list');
      const body = MarkdownListNode(
        type: 'body',
        children: [
          list,
          MarkdownListNode(type: 'paragraph'),
        ],
      );

      expect(
        getMarkdownListSpacing(list, const [body]),
        const MarkdownListSpacing(marginTop: 4, marginBottom: 16),
      );
    });

    test(
      'does not add bottom spacing after a list at the end of a markdown block',
      () {
        const list = MarkdownListNode(type: 'bullet_list');
        const body = MarkdownListNode(type: 'body', children: [list]);

        expect(
          getMarkdownListSpacing(list, const [body]),
          const MarkdownListSpacing(marginTop: 4, marginBottom: 0),
        );
      },
    );

    test('uses a smaller gap between adjacent top-level lists', () {
      const list = MarkdownListNode(type: 'bullet_list');
      const body = MarkdownListNode(
        type: 'body',
        children: [
          list,
          MarkdownListNode(type: 'ordered_list'),
        ],
      );

      expect(
        getMarkdownListSpacing(list, const [body]),
        const MarkdownListSpacing(marginTop: 4, marginBottom: 8),
      );
    });

    test('does not add section spacing after a nested list', () {
      expect(
        getMarkdownListSpacing(
          const MarkdownListNode(type: 'bullet_list'),
          const [
            MarkdownListNode(type: 'list_item'),
            MarkdownListNode(type: 'bullet_list'),
            MarkdownListNode(type: 'body'),
          ],
        ),
        const MarkdownListSpacing(marginTop: 4, marginBottom: 0),
      );
      // The list-item ancestor wins wherever it sits in the chain.
      expect(
        getMarkdownListSpacing(
          const MarkdownListNode(type: 'bullet_list'),
          const [
            MarkdownListNode(type: 'body'),
            MarkdownListNode(type: 'list_item'),
          ],
        ),
        const MarkdownListSpacing(marginTop: 4, marginBottom: 0),
      );
    });

    test('an unreachable node gets terminal spacing', () {
      const list = MarkdownListNode(type: 'bullet_list');
      expect(
        getMarkdownListSpacing(list, null),
        const MarkdownListSpacing(marginTop: 4, marginBottom: 0),
      );
      expect(
        getMarkdownListSpacing(list, const [
          MarkdownListNode(
            type: 'body',
            children: [MarkdownListNode(type: 'paragraph')],
          ),
        ]),
        const MarkdownListSpacing(marginTop: 4, marginBottom: 0),
      );
    });

    test('the outermost ancestor that contains the node wins', () {
      const list = MarkdownListNode(type: 'bullet_list');
      const inner = MarkdownListNode(
        type: 'body',
        children: [
          list,
          MarkdownListNode(type: 'heading'),
        ],
      );
      const outer = MarkdownListNode(
        type: 'root',
        children: [
          list,
          MarkdownListNode(type: 'paragraph'),
        ],
      );

      // The chain is searched from the far end inward, so `inner` answers.
      expect(
        getMarkdownListSpacing(list, const [outer, inner]),
        const MarkdownListSpacing(marginTop: 4, marginBottom: 16),
      );
    });
  });

  group('getMarkdownNextSiblingType', () {
    test('finds the following sibling\'s type', () {
      const list = MarkdownListNode(type: 'bullet_list');
      const body = MarkdownListNode(
        type: 'body',
        children: [
          list,
          MarkdownListNode(type: 'paragraph'),
        ],
      );

      expect(getMarkdownNextSiblingType(list, const [body]), 'paragraph');
    });

    test('returns null at the end of a chain, or when unreachable', () {
      const list = MarkdownListNode(type: 'bullet_list');

      expect(getMarkdownNextSiblingType(list, null), isNull);
      expect(
        getMarkdownNextSiblingType(list, const [
          MarkdownListNode(type: 'body', children: [list]),
        ]),
        isNull,
      );
      expect(
        getMarkdownNextSiblingType(list, const [
          MarkdownListNode(type: 'body'),
        ]),
        isNull,
      );
    });
  });

  group('markdownListAncestors', () {
    test('normalizes the renderer\'s three shapes', () {
      const node = MarkdownListNode(type: 'body');

      expect(markdownListAncestors(const [node]), [node]);
      expect(markdownListAncestors(node), [node]);
      expect(markdownListAncestors(null), isEmpty);
      expect(markdownListAncestors(42), isEmpty);
    });
  });

  group('markdown list spacing constants', () {
    test('follow the 4px spacing scale', () {
      expect(markdownListMarginTop, 4);
      expect(markdownListMarginBottomToProse, 16);
      expect(markdownListMarginBottomToList, 8);
      expect(markdownNestedListMarginBottom, 0);
      expect(markdownTerminalListMarginBottom, 0);
    });
  });

  group('schedule title helpers', () {
    test('identifies new-agent schedules', () {
      expect(isNewAgentSchedule(_schedule()), isTrue);
      expect(
        isNewAgentSchedule(
          _schedule(
            target: const AgentScheduleTarget(
              agentId: '00000000-0000-4000-8000-000000000000',
            ),
          ),
        ),
        isFalse,
      );
    });

    test('labels engine records by product meaning', () {
      expect(scheduleProductName(_schedule()), 'Schedule');
      expect(
        scheduleProductName(
          _schedule(
            target: const AgentScheduleTarget(
              agentId: '00000000-0000-4000-8000-000000000000',
            ),
          ),
        ),
        'Heartbeat',
      );
    });

    test(
      'resolves display titles by name, config title, prompt, then fallback',
      () {
        expect(
          resolveScheduleTitle(
            _schedule(name: 'Morning run', configTitle: 'Config title'),
          ),
          'Morning run',
        );
        expect(
          resolveScheduleTitle(
            _schedule(name: ' ', configTitle: 'Config title'),
          ),
          'Config title',
        );
        expect(
          resolveScheduleTitle(
            _schedule(name: ' ', configTitle: ' ', prompt: '\nPrompt line'),
          ),
          'Prompt line',
        );
        expect(
          resolveScheduleTitle(
            _schedule(name: ' ', configTitle: ' ', prompt: '\n  '),
          ),
          'Untitled schedule',
        );
        expect(
          resolveScheduleTitle(
            _schedule(
              name: null,
              prompt: '   ',
              target: const AgentScheduleTarget(
                agentId: '00000000-0000-4000-8000-000000000000',
              ),
            ),
          ),
          'Untitled heartbeat',
        );
      },
    );
  });

  group('interval formatting', () {
    test('round-trips interval parts and formats cadence labels', () {
      expect(
        everyMsToParts(2 * 24 * 60 * 60000),
        const IntervalParts(value: 2, unit: IntervalUnit.days),
      );
      expect(
        everyMsToParts(3 * 60 * 60000),
        const IntervalParts(value: 3, unit: IntervalUnit.hours),
      );
      expect(
        everyMsToParts(90000),
        const IntervalParts(value: 2, unit: IntervalUnit.minutes),
      );
      expect(
        everyMsToParts(0),
        const IntervalParts(value: 1, unit: IntervalUnit.hours),
      );

      expect(partsToEveryMs(2, IntervalUnit.hours), 2 * 60 * 60000);
      expect(partsToEveryMs(0, IntervalUnit.minutes), 60000);
      expect(
        formatScheduleCadence(
          const EveryScheduleCadence(everyMs: 2 * 60 * 60000),
        ),
        'Every 2 hours',
      );
    });

    test('a non-positive or non-finite interval defaults to one hour', () {
      const oneHour = IntervalParts(value: 1, unit: IntervalUnit.hours);
      expect(everyMsToParts(-5), oneHour);
      expect(everyMsToParts(double.nan), oneHour);
      expect(everyMsToParts(double.infinity), oneHour);
    });

    test('picks the coarsest unit that divides evenly', () {
      expect(
        everyMsToParts(7 * 86400000),
        const IntervalParts(value: 7, unit: IntervalUnit.days),
      );
      expect(
        everyMsToParts(60000),
        const IntervalParts(value: 1, unit: IntervalUnit.minutes),
      );
      // One millisecond past an hour is no longer a whole hour.
      expect(
        everyMsToParts(3600000 + 1),
        const IntervalParts(value: 60, unit: IntervalUnit.minutes),
      );
    });

    test('a sub-minute interval floors at one minute', () {
      expect(
        everyMsToParts(1),
        const IntervalParts(value: 1, unit: IntervalUnit.minutes),
      );
      expect(
        everyMsToParts(30000),
        const IntervalParts(value: 1, unit: IntervalUnit.minutes),
      );
    });

    test('partsToEveryMs clamps and rounds its value', () {
      expect(partsToEveryMs(double.nan, IntervalUnit.days), 86400000);
      expect(partsToEveryMs(-3, IntervalUnit.hours), 3600000);
      expect(partsToEveryMs(2.6, IntervalUnit.minutes), 180000);
      expect(partsToEveryMs(2.5, IntervalUnit.minutes), 180000);
    });

    test('formats singular and plural cadence nouns', () {
      expect(
        formatScheduleCadence(const EveryScheduleCadence(everyMs: 60000)),
        'Every 1 minute',
      );
      expect(
        formatScheduleCadence(const EveryScheduleCadence(everyMs: 86400000)),
        'Every 1 day',
      );
    });

    test('interval units carry their millisecond size and noun', () {
      expect(IntervalUnit.minutes.milliseconds, 60000);
      expect(IntervalUnit.hours.milliseconds, 3600000);
      expect(IntervalUnit.days.milliseconds, 86400000);
      expect(IntervalUnit.values.map((unit) => unit.noun), [
        'minute',
        'hour',
        'day',
      ]);
    });
  });

  group('describeCron', () {
    test('humanizes common fixed-time cron shapes', () {
      expect(
        describeScheduleCron(
          const CronScheduleCadence(expression: '* * * * *'),
        ),
        'Every minute',
      );
      expect(
        describeScheduleCron(
          const CronScheduleCadence(expression: '0 * * * *'),
        ),
        'Every hour',
      );
      expect(
        describeScheduleCron(
          const CronScheduleCadence(expression: '15 * * * *'),
        ),
        'Every hour at :15',
      );
      expect(
        describeScheduleCron(
          const CronScheduleCadence(expression: '0 9 * * *'),
        ),
        'Daily at 09:00 UTC',
      );
      expect(
        describeScheduleCron(
          const CronScheduleCadence(expression: '0 9 * * 1-5'),
        ),
        'Weekdays at 09:00 UTC',
      );
      expect(
        describeScheduleCron(
          const CronScheduleCadence(expression: '0 9 * * 0,6'),
        ),
        'Weekends at 09:00 UTC',
      );
      expect(
        describeScheduleCron(
          const CronScheduleCadence(expression: '0 9 * * 1'),
        ),
        'Mondays at 09:00 UTC',
      );
    });

    test('labels fixed-time cron cadences with their stored timezone', () {
      expect(
        describeScheduleCron(
          const CronScheduleCadence(
            expression: '0 9 * * *',
            timezone: 'America/New_York',
          ),
        ),
        'Daily at 09:00 America/New_York',
      );
      expect(
        formatScheduleCadence(
          const CronScheduleCadence(
            expression: '0 9 * * 1-5',
            timezone: 'Europe/Madrid',
          ),
        ),
        'Weekdays at 09:00 Europe/Madrid',
      );
    });

    test('keeps timezone-less fixed-time cron cadences labeled as UTC', () {
      expect(
        formatScheduleCadence(
          const CronScheduleCadence(expression: '0 9 * * *'),
        ),
        'Daily at 09:00 UTC',
      );
    });

    test('returns null for invalid or unrecognized valid cron expressions', () {
      expect(
        describeScheduleCron(
          const CronScheduleCadence(expression: 'not a cron'),
        ),
        isNull,
      );
      expect(
        describeScheduleCron(
          const CronScheduleCadence(expression: '*/5 * * * *'),
        ),
        isNull,
      );
      // Unrecognized-but-valid falls back to the raw expression, not to null.
      expect(
        formatScheduleCadence(
          const CronScheduleCadence(expression: '*/5 * * * *'),
        ),
        '*/5 * * * *',
      );
      expect(
        formatScheduleCadence(
          const CronScheduleCadence(expression: 'not a cron'),
        ),
        'not a cron',
      );
    });

    test('names every single-digit day of week', () {
      const names = [
        'Sundays',
        'Mondays',
        'Tuesdays',
        'Wednesdays',
        'Thursdays',
        'Fridays',
        'Saturdays',
      ];
      for (var day = 0; day < names.length; day += 1) {
        expect(
          describeScheduleCron(CronScheduleCadence(expression: '0 9 * * $day')),
          '${names[day]} at 09:00 UTC',
        );
      }
      // Weekend order is accepted either way round.
      expect(
        describeScheduleCron(
          const CronScheduleCadence(expression: '0 9 * * 6,0'),
        ),
        'Weekends at 09:00 UTC',
      );
    });

    test('normalizes whitespace and zero-padded fields', () {
      expect(
        describeScheduleCron(
          const CronScheduleCadence(expression: '05 09 * * *'),
        ),
        'Daily at 09:05 UTC',
      );
      expect(
        describeScheduleCron(
          const CronScheduleCadence(expression: '  0   9  *  *  *  '),
        ),
        'Daily at 09:00 UTC',
      );
    });

    test('declines anything outside the fixed-time family', () {
      for (final expression in const [
        // An hourly cadence constrained to one weekday is not describable.
        '0 * * * 1',
        // A day-of-month or month constraint is outside the family.
        '0 9 1 * *',
        '0 9 * 1 *',
        // A non-literal minute is outside the family.
        '0-5 9 * * *',
        // A day-of-week range other than the two named ones.
        '0 9 * * 1-3',
      ]) {
        expect(
          describeScheduleCron(CronScheduleCadence(expression: expression)),
          isNull,
          reason: expression,
        );
      }
    });

    test('an empty timezone is a real timezone, not a missing one', () {
      // Upstream's `?? "UTC"` fires on nullish only, so "" survives to the
      // label and leaves a trailing space. Reproduced.
      expect(
        describeScheduleCron(
          const CronScheduleCadence(expression: '0 9 * * *', timezone: ''),
        ),
        'Daily at 09:00 ',
      );
    });

    test('the timezone is irrelevant to the hourly and minutely shapes', () {
      expect(
        describeScheduleCron(
          const CronScheduleCadence(
            expression: '* * * * *',
            timezone: 'Asia/Seoul',
          ),
        ),
        'Every minute',
      );
      expect(
        describeScheduleCron(
          const CronScheduleCadence(
            expression: '15 * * * *',
            timezone: 'Asia/Seoul',
          ),
        ),
        'Every hour at :15',
      );
    });
  });

  group('validateCron', () {
    test('accepts structurally valid cron expressions', () {
      expect(validateScheduleCron('*/5 9-17 * 1,6 1-5'), isNull);
      expect(validateScheduleCron(' 0 9 * * 1 '), isNull);
    });

    test('rejects step fields with extra slash tokens', () {
      expect(validateScheduleCron('*/5/2 * * * *'), 'Invalid minute step');
    });

    test('rejects malformed fields with targeted messages', () {
      expect(validateScheduleCron(''), 'Enter a cron expression');
      expect(validateScheduleCron('   '), 'Enter a cron expression');
      expect(
        validateScheduleCron('* * *'),
        'Cron expressions must have 5 fields',
      );
      expect(
        validateScheduleCron('* * * * * *'),
        'Cron expressions must have 5 fields',
      );
      expect(validateScheduleCron('60 * * * *'), 'Invalid minute value');
      expect(validateScheduleCron('* 24 * * *'), 'Invalid hour value');
      expect(
        validateScheduleCron('* * 31-1 * *'),
        'Invalid day-of-month range',
      );
      expect(validateScheduleCron('* * * */0 *'), 'Invalid month step');
      expect(validateScheduleCron('* * * * mon'), 'Invalid day-of-week value');
      expect(validateScheduleCron('* * * * 7'), 'Invalid day-of-week value');
      expect(validateScheduleCron('* * 0 * *'), 'Invalid day-of-month value');
      expect(validateScheduleCron('*/0 * * * *'), 'Invalid minute step');
      expect(validateScheduleCron('-1 * * * *'), 'Invalid minute value');
    });
  });

  group('formatNextRun', () {
    test('formats next-run distance from the injected clock', () {
      final now = DateTime.parse('2026-01-01T00:00:00.000Z');

      expect(formatScheduleNextRun(null, now: now), '');
      expect(formatScheduleNextRun('not-a-date', now: now), '');
      expect(
        formatScheduleNextRun('2026-01-01T00:00:15.000Z', now: now),
        'soon',
      );
      expect(
        formatScheduleNextRun('2026-01-01T00:30:00.000Z', now: now),
        'in 30m',
      );
      expect(
        formatScheduleNextRun('2026-01-01T03:00:00.000Z', now: now),
        'in 3h',
      );
      expect(
        formatScheduleNextRun('2026-01-03T00:00:00.000Z', now: now),
        'in 2d',
      );
    });

    test('a run already due reads as soon', () {
      final now = DateTime.parse('2026-01-01T00:00:00.000Z');
      expect(
        formatScheduleNextRun('2025-12-31T23:00:00.000Z', now: now),
        'soon',
      );
      expect(
        formatScheduleNextRun('2026-01-01T00:00:00.000Z', now: now),
        'soon',
      );
    });
  });

  group('sendOsNotification', () {
    test('dispatches a click event that the app can handle', () async {
      final host = _FakeNotificationHost(
        webNotifications: _FakeWebNotificationBackend(),
        // A listener called preventDefault: DOM dispatchEvent returns false.
        dispatchResult: false,
      );
      final notifier = OsNotifier(host);

      final sent = await notifier.send(
        const OsNotificationPayload(
          title: 'Agent finished',
          body: 'Done',
          data: {'serverId': 'srv-1', 'agentId': 'agent-1'},
        ),
      );

      expect(sent, isTrue);
      final backend = host.webNotifications! as _FakeWebNotificationBackend;
      expect(backend.created, hasLength(1));

      final clicked = backend.created.single;
      expect(clicked.clickListeners, hasLength(1));
      clicked.clickListeners.single();

      expect(host.dispatchedDetails, [
        const WebNotificationClickDetail(
          data: {'serverId': 'srv-1', 'agentId': 'agent-1'},
        ),
      ]);
      expect(host.navigations, isEmpty);
    });

    test(
      'falls back to route navigation when no listener handles the click',
      () async {
        final host = _FakeNotificationHost(
          webNotifications: _FakeWebNotificationBackend(),
          dispatchResult: true,
        );
        final notifier = OsNotifier(host);

        await notifier.send(
          const OsNotificationPayload(
            title: 'Agent finished',
            data: {
              'serverId': 'srv with space',
              'workspaceId': 'workspace-1',
              'agentId': 'agent/1',
            },
          ),
        );

        final backend = host.webNotifications! as _FakeWebNotificationBackend;
        final clicked = backend.created.single;
        expect(clicked.clickListeners, hasLength(1));
        clicked.clickListeners.single();

        expect(host.navigations, [
          '/h/srv%20with%20space/workspace/workspace-1?open=agent%3Aagent%2F1',
        ]);
      },
    );

    test('no event bus at all counts as unhandled', () async {
      final host = _FakeNotificationHost(
        webNotifications: _FakeWebNotificationBackend(),
        dispatchResult: null,
      );
      final notifier = OsNotifier(host);

      await notifier.send(
        const OsNotificationPayload(
          title: 'Agent finished',
          data: {'serverId': 'srv-1'},
        ),
      );

      final backend = host.webNotifications! as _FakeWebNotificationBackend;
      backend.created.single.clickListeners.single();

      expect(host.navigations, ['/h/srv-1']);
    });

    test('returns false when the Notification API is unavailable', () async {
      final host = _FakeNotificationHost();
      final notifier = OsNotifier(host);

      expect(
        await notifier.send(
          const OsNotificationPayload(
            title: 'Agent finished',
            body: 'Done',
            data: {'serverId': 'srv-1', 'agentId': 'agent-1'},
          ),
        ),
        isFalse,
      );
    });

    test(
      'does not attach a click handler when there is no route target',
      () async {
        final host = _FakeNotificationHost(
          webNotifications: _FakeWebNotificationBackend(),
          dispatchResult: true,
        );
        final notifier = OsNotifier(host);

        final sent = await notifier.send(
          const OsNotificationPayload(
            title: 'Paseo notification test',
            body: 'If you can see this, desktop notifications work.',
          ),
        );

        expect(sent, isTrue);
        final backend = host.webNotifications! as _FakeWebNotificationBackend;
        expect(backend.created, hasLength(1));
        expect(backend.created.single.clickListeners, isEmpty);
      },
    );

    test('uses the desktop notification bridge when available', () async {
      final sent = <OsNotificationPayload>[];
      final host = _FakeNotificationHost(
        desktopSender: (payload) async {
          sent.add(payload);
          return true;
        },
        // Present but unreachable: the desktop bridge wins.
        webNotifications: _FakeWebNotificationBackend(),
      );
      final notifier = OsNotifier(host);

      const payload = OsNotificationPayload(
        title: 'Paseo notification test',
        body: 'If you can see this, desktop notifications work.',
        data: {'serverId': 'srv-1'},
      );
      expect(await notifier.send(payload), isTrue);
      expect(sent, [payload]);
      expect(
        (host.webNotifications! as _FakeWebNotificationBackend).created,
        isEmpty,
      );
    });

    test('propagates a desktop bridge failure verbatim', () async {
      final host = _FakeNotificationHost(desktopSender: (_) async => false);
      expect(
        await OsNotifier(host).send(const OsNotificationPayload(title: 'T')),
        isFalse,
      );
    });

    test('never posts locally on native', () async {
      final host = _FakeNotificationHost(
        isNative: true,
        desktopSender: (_) async => true,
        webNotifications: _FakeWebNotificationBackend(),
      );
      final notifier = OsNotifier(host);

      expect(
        await notifier.send(const OsNotificationPayload(title: 'T')),
        isFalse,
      );
      expect(await notifier.ensureOsNotificationPermission(), isFalse);
      expect(
        (host.webNotifications! as _FakeWebNotificationBackend).created,
        isEmpty,
      );
    });

    test('passes the host icon through to the notification', () async {
      final host = _FakeNotificationHost(
        webNotifications: _FakeWebNotificationBackend(),
        dispatchResult: true,
        notificationIconUrl: 'http://localhost:8081/notification-icon.png',
      );

      await OsNotifier(host).send(
        const OsNotificationPayload(title: 'T', body: 'B', data: {'k': 'v'}),
      );

      final created = (host.webNotifications! as _FakeWebNotificationBackend)
          .created
          .single;
      expect(created.title, 'T');
      expect(created.body, 'B');
      expect(created.data, {'k': 'v'});
      expect(created.icon, 'http://localhost:8081/notification-icon.png');
    });

    test('a workspace-only payload still gets a click handler', () async {
      final host = _FakeNotificationHost(
        webNotifications: _FakeWebNotificationBackend(),
        dispatchResult: true,
      );

      await OsNotifier(host).send(
        const OsNotificationPayload(title: 'T', data: {'workspaceId': 'ws-1'}),
      );

      final backend = host.webNotifications! as _FakeWebNotificationBackend;
      expect(backend.created.single.clickListeners, hasLength(1));
      backend.created.single.clickListeners.single();
      // No server id, so the route degrades to the app root.
      expect(host.navigations, ['/']);
    });

    test('a terminal-only payload gets no click handler', () async {
      // Upstream's target check omits terminalId even though the route builder
      // understands it. Reproduced rather than widened.
      final host = _FakeNotificationHost(
        webNotifications: _FakeWebNotificationBackend(),
        dispatchResult: true,
      );

      await OsNotifier(host).send(
        const OsNotificationPayload(title: 'T', data: {'terminalId': 'term-1'}),
      );

      expect(
        (host.webNotifications! as _FakeWebNotificationBackend)
            .created
            .single
            .clickListeners,
        isEmpty,
      );
      expect(hasNotificationClickTarget(const {'terminalId': 't'}), isFalse);
      expect(hasNotificationClickTarget(const {'serverId': 's'}), isTrue);
      expect(hasNotificationClickTarget(const {'agentId': 'a'}), isTrue);
      expect(hasNotificationClickTarget(const {'workspaceId': 'w'}), isTrue);
      expect(hasNotificationClickTarget(null), isFalse);
      // A blank id is not an id.
      expect(hasNotificationClickTarget(const {'serverId': '  '}), isFalse);
    });

    test('the click event name is the frozen one', () {
      expect(webNotificationClickEvent, 'paseo:web-notification-click');
    });
  });

  group('ensureOsNotificationPermission', () {
    test('short-circuits on an already-decided permission', () async {
      final granted = _FakeWebNotificationBackend(
        permission: WebNotificationPermission.granted,
      );
      final denied = _FakeWebNotificationBackend(
        permission: WebNotificationPermission.denied,
      );

      expect(
        await OsNotifier(
          _FakeNotificationHost(webNotifications: granted),
        ).ensureOsNotificationPermission(),
        isTrue,
      );
      expect(granted.requestCount, 0);
      expect(
        await OsNotifier(
          _FakeNotificationHost(webNotifications: denied),
        ).ensureOsNotificationPermission(),
        isFalse,
      );
      expect(denied.requestCount, 0);
    });

    test('prompts once and honours the answer', () async {
      final backend = _FakeWebNotificationBackend(
        permission: WebNotificationPermission.prompt,
        requestAnswer: WebNotificationPermission.granted,
      );

      expect(
        await OsNotifier(
          _FakeNotificationHost(webNotifications: backend),
        ).ensureOsNotificationPermission(),
        isTrue,
      );
      expect(backend.requestCount, 1);
    });

    test('a prompt that is declined resolves false', () async {
      final backend = _FakeWebNotificationBackend(
        permission: WebNotificationPermission.prompt,
        requestAnswer: WebNotificationPermission.denied,
      );

      expect(
        await OsNotifier(
          _FakeNotificationHost(webNotifications: backend),
        ).ensureOsNotificationPermission(),
        isFalse,
      );
    });

    test('a backend with no requestPermission resolves denied', () async {
      final backend = _FakeWebNotificationBackend(
        permission: WebNotificationPermission.prompt,
        canRequest: false,
      );

      expect(
        await OsNotifier(
          _FakeNotificationHost(webNotifications: backend),
        ).ensureOsNotificationPermission(),
        isFalse,
      );
      expect(backend.requestCount, 0);
    });

    test('coalesces concurrent prompts into one browser request', () async {
      final completer = Completer<WebNotificationPermission>();
      final backend = _FakeWebNotificationBackend(
        permission: WebNotificationPermission.prompt,
        pending: completer.future,
      );
      final notifier = OsNotifier(
        _FakeNotificationHost(webNotifications: backend),
      );

      final first = notifier.ensureOsNotificationPermission();
      final second = notifier.ensureOsNotificationPermission();
      completer.complete(WebNotificationPermission.granted);

      expect(await Future.wait([first, second]), [true, true]);
      expect(backend.requestCount, 1);
    });

    test('no backend means no permission', () async {
      expect(
        await OsNotifier(
          _FakeNotificationHost(),
        ).ensureOsNotificationPermission(),
        isFalse,
      );
    });

    test(
      'a denied permission stops the send before it creates anything',
      () async {
        final backend = _FakeWebNotificationBackend(
          permission: WebNotificationPermission.denied,
        );
        final host = _FakeNotificationHost(webNotifications: backend);

        expect(
          await OsNotifier(host).send(const OsNotificationPayload(title: 'T')),
          isFalse,
        );
        expect(backend.created, isEmpty);
      },
    );
  });

  group('payload value semantics', () {
    test('payloads and click details compare by value', () {
      expect(
        const OsNotificationPayload(title: 'T', body: 'B', data: {'a': 1}),
        const OsNotificationPayload(title: 'T', body: 'B', data: {'a': 1}),
      );
      expect(
        const OsNotificationPayload(title: 'T', data: {'a': 1}),
        isNot(const OsNotificationPayload(title: 'T', data: {'a': 2})),
      );
      expect(
        const OsNotificationPayload(title: 'T'),
        isNot(const OsNotificationPayload(title: 'T', data: {})),
      );
      expect(
        const WebNotificationClickDetail(data: {'a': 1}).hashCode,
        const WebNotificationClickDetail(data: {'a': 1}).hashCode,
      );
      expect(
        const OsNotificationPayload(title: 'T', body: 'B').hashCode,
        const OsNotificationPayload(title: 'T', body: 'B').hashCode,
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Fakes and fixtures
// ---------------------------------------------------------------------------

final class _NativeConfirmCall {
  const _NativeConfirmCall({
    required this.title,
    required this.message,
    required this.labels,
    required this.destructive,
  });

  final String title;
  final String message;
  final ConfirmButtonLabels labels;
  final bool destructive;

  @override
  bool operator ==(Object other) =>
      other is _NativeConfirmCall &&
      title == other.title &&
      message == other.message &&
      labels == other.labels &&
      destructive == other.destructive;

  @override
  int get hashCode => Object.hash(title, message, labels, destructive);

  @override
  String toString() =>
      '_NativeConfirmCall($title, $message, $labels, $destructive)';
}

final class _DesktopAskCall {
  const _DesktopAskCall({required this.message, required this.options});

  final String message;
  final DesktopDialogAskOptions options;

  @override
  bool operator ==(Object other) =>
      other is _DesktopAskCall &&
      message == other.message &&
      options == other.options;

  @override
  int get hashCode => Object.hash(message, options);

  @override
  String toString() => '_DesktopAskCall($message, $options)';
}

/// A [ConfirmDialogHost] whose every branch can be present or absent
/// independently, standing in for upstream's `vi.doMock` of `react-native`,
/// `@/desktop/host` and `globalThis.confirm`.
final class _FakeConfirmDialogHost implements ConfirmDialogHost {
  _FakeConfirmDialogHost({
    this.isNative = false,
    this.nativeAnswer = false,
    DesktopDialogAsk? desktopAsk,
    this.confirmBackend,
    bool? hasDesktopBridge,
  }) : _desktopAsk = desktopAsk,
       hasDesktopBridge = hasDesktopBridge ?? desktopAsk != null;

  @override
  final bool isNative;

  final bool nativeAnswer;

  final DesktopDialogAsk? _desktopAsk;

  /// The unwrapped backend; [browserConfirm] wraps it to record calls.
  final BrowserConfirm? confirmBackend;

  @override
  final bool hasDesktopBridge;

  /// Wrapped at read time so the call is recorded, standing in for upstream's
  /// `vi.fn()` around `globalThis.confirm`.
  @override
  BrowserConfirm? get browserConfirm {
    final confirm = confirmBackend;
    if (confirm == null) return null;
    return (message) {
      browserConfirmCalls.add(message);
      return confirm(message);
    };
  }

  final List<_NativeConfirmCall> nativeCalls = [];
  final List<_DesktopAskCall> desktopAskCalls = [];
  final List<String> browserConfirmCalls = [];
  int blurCount = 0;

  @override
  DesktopDialogAsk? get desktopAsk {
    final ask = _desktopAsk;
    if (ask == null) return null;
    return (message, options) {
      desktopAskCalls.add(_DesktopAskCall(message: message, options: options));
      return ask(message, options);
    };
  }

  @override
  Future<bool> showNativeConfirm({
    required String title,
    required String message,
    required ConfirmButtonLabels labels,
    required bool destructive,
  }) async {
    nativeCalls.add(
      _NativeConfirmCall(
        title: title,
        message: message,
        labels: labels,
        destructive: destructive,
      ),
    );
    return nativeAnswer;
  }

  @override
  void blurActiveWebElement() {
    if (isNative) return;
    blurCount += 1;
  }
}

final class _FakeWebNotification implements WebNotificationHandle {
  _FakeWebNotification({
    required this.title,
    required this.body,
    required this.data,
    required this.icon,
  });

  final String title;
  final String? body;
  final Map<String, Object?>? data;
  final String? icon;
  final List<void Function()> clickListeners = [];

  @override
  void addClickListener(void Function() listener) =>
      clickListeners.add(listener);
}

final class _FakeWebNotificationBackend implements WebNotificationBackend {
  _FakeWebNotificationBackend({
    this.permission = WebNotificationPermission.granted,
    this.requestAnswer = WebNotificationPermission.granted,
    this.canRequest = true,
    this.pending,
  });

  @override
  final WebNotificationPermission permission;

  final WebNotificationPermission requestAnswer;
  final bool canRequest;

  /// When set, the prompt resolves from this future instead of immediately —
  /// which is how the concurrent-prompt case keeps a request in flight.
  final Future<WebNotificationPermission>? pending;

  final List<_FakeWebNotification> created = [];
  int requestCount = 0;

  @override
  Future<WebNotificationPermission> Function()? get requestPermission {
    if (!canRequest) return null;
    return () {
      requestCount += 1;
      return pending ?? Future.value(requestAnswer);
    };
  }

  @override
  WebNotificationHandle create({
    required String title,
    String? body,
    Map<String, Object?>? data,
    String? icon,
  }) {
    final notification = _FakeWebNotification(
      title: title,
      body: body,
      data: data,
      icon: icon,
    );
    created.add(notification);
    return notification;
  }
}

final class _FakeNotificationHost implements OsNotificationHost {
  _FakeNotificationHost({
    this.isNative = false,
    this.desktopSender,
    this.webNotifications,
    this.notificationIconUrl,
    this.dispatchResult,
  });

  @override
  final bool isNative;

  @override
  final Future<bool> Function(OsNotificationPayload payload)? desktopSender;

  @override
  final WebNotificationBackend? webNotifications;

  @override
  final String? notificationIconUrl;

  /// Mirrors DOM `dispatchEvent`: null for no event bus, true for un-prevented,
  /// false for a listener that called `preventDefault`.
  final bool? dispatchResult;

  final List<WebNotificationClickDetail> dispatchedDetails = [];
  final List<String> navigations = [];

  @override
  bool? dispatchWebNotificationClick(WebNotificationClickDetail detail) {
    dispatchedDetails.add(detail);
    return dispatchResult;
  }

  @override
  void navigateToRoute(String route) => navigations.add(route);
}

SidebarWorkspaceEntry _workspace({
  required String serverId,
  required String workspaceId,
  required String name,
  String projectKey = 'project-default',
  WorkspaceStateBucket statusBucket = WorkspaceStateBucket.done,
  DateTime? statusEnteredAt,
}) => SidebarWorkspaceEntry(
  workspaceKey: '$serverId:$workspaceId',
  serverId: serverId,
  workspaceId: workspaceId,
  projectKey: projectKey,
  projectName: projectKey,
  projectKind: WorkspaceProjectKind.git,
  workspaceKind: WorkspaceKind.checkout,
  name: name,
  statusBucket: statusBucket,
  statusEnteredAt: statusEnteredAt,
);

SidebarWorkspaceProjectEntry _project(
  String projectKey,
  List<SidebarWorkspacePlacement> workspaces, {
  WorkspaceProjectKind projectKind = WorkspaceProjectKind.git,
  bool canCreateWorktree = true,
}) => SidebarWorkspaceProjectEntry(
  projectKey: projectKey,
  projectName: projectKey,
  projectKind: projectKind,
  iconWorkingDir: workspaces.isEmpty ? '' : '/repo/${workspaces.first.name}',
  hosts: [
    SidebarProjectHost(
      serverId: workspaces.isEmpty ? 's1' : workspaces.first.serverId,
      iconWorkingDir: workspaces.isEmpty
          ? ''
          : '/repo/${workspaces.first.name}',
      canCreateWorktree: canCreateWorktree,
    ),
  ],
  workspaces: workspaces,
);

ScheduleSummary _schedule({
  String? name,
  String prompt = 'Run the task',
  String? configTitle,
  ScheduleTarget? target,
}) => ScheduleSummary(
  id: 'schedule-1',
  name: name,
  prompt: prompt,
  cadence: const EveryScheduleCadence(everyMs: 60000),
  target:
      target ??
      NewAgentScheduleTarget(
        config: ScheduleNewAgentConfig(
          provider: 'codex',
          cwd: '/tmp/project',
          title: configTitle,
        ),
      ),
  status: ScheduleStatus.active,
  createdAt: '2026-01-01T00:00:00.000Z',
  updatedAt: '2026-01-01T00:00:00.000Z',
  nextRunAt: null,
  lastRunAt: null,
  pausedAt: null,
  expiresAt: null,
  maxRuns: null,
);
