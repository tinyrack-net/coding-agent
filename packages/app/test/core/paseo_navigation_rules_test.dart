import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/paseo_navigation_rules.dart';
import 'package:coding_agent_app/workspace/prepare_workspace_tab.dart';
import 'package:coding_agent_app/workspace/workspace_tab_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what the layout store would have been asked to do.
final class _FakeLayout {
  final openedTabs = <(String, WorkspaceTabTarget)>[];
  final pinnedAgents = <(String, String)>[];

  String? openTabFocused(String key, WorkspaceTabTarget target) {
    openedTabs.add((key, target));
    return target is WorkspaceAgentTabTarget ? target.agentId : null;
  }

  void pinAgent(String key, String agentId) => pinnedAgents.add((key, agentId));
}

void main() {
  group('prepareWorkspaceTabWithLayout', () {
    test('opens and focuses an agent tab', () {
      final layout = _FakeLayout();

      prepareWorkspaceTabWithLayout(
        const PrepareWorkspaceTabInput(
          serverId: 'server-1',
          workspaceId: '/repo/worktree',
          target: WorkspaceAgentTabTarget(agentId: 'agent-1'),
        ),
        openTabFocused: layout.openTabFocused,
        pinAgent: layout.pinAgent,
      );

      expect(layout.openedTabs, hasLength(1));
      expect(layout.openedTabs.single.$1, 'server-1:/repo/worktree');
      expect(
        layout.openedTabs.single.$2,
        isA<WorkspaceAgentTabTarget>().having(
          (target) => target.agentId,
          'agentId',
          'agent-1',
        ),
      );
      expect(layout.pinnedAgents, isEmpty);
    });

    test('pins the agent when the caller asks for it', () {
      final layout = _FakeLayout();

      prepareWorkspaceTabWithLayout(
        const PrepareWorkspaceTabInput(
          serverId: 'server-1',
          workspaceId: '/repo/worktree',
          target: WorkspaceAgentTabTarget(agentId: 'agent-1'),
          pin: true,
        ),
        openTabFocused: layout.openTabFocused,
        pinAgent: layout.pinAgent,
      );

      expect(layout.pinnedAgents, [('server-1:/repo/worktree', 'agent-1')]);
    });

    test('falls back to an empty workspace key when identity is blank', () {
      final layout = _FakeLayout();

      prepareWorkspaceTabWithLayout(
        const PrepareWorkspaceTabInput(
          serverId: '  ',
          workspaceId: '/repo/worktree',
          target: WorkspaceAgentTabTarget(agentId: 'agent-1'),
        ),
        openTabFocused: layout.openTabFocused,
        pinAgent: layout.pinAgent,
      );

      expect(layout.openedTabs.single.$1, '');
    });

    test('resolves the sentinel draft id into a fresh draft', () {
      final layout = _FakeLayout();

      prepareWorkspaceTabWithLayout(
        const PrepareWorkspaceTabInput(
          serverId: 'server-1',
          workspaceId: '/repo/worktree',
          target: WorkspaceDraftTabTarget(draftId: 'new'),
        ),
        openTabFocused: layout.openTabFocused,
        pinAgent: layout.pinAgent,
      );

      final target = layout.openedTabs.single.$2;
      expect(target, isA<WorkspaceDraftTabTarget>());
      expect((target as WorkspaceDraftTabTarget).draftId, isNot('new'));
      expect(target.draftId, isNotEmpty);
    });

    test('reads the layout mutations at call time, not at wiring time', () {
      final first = _FakeLayout();
      final second = _FakeLayout();
      var active = first;

      void open(String key, WorkspaceTabTarget target) =>
          active.openTabFocused(key, target);

      prepareWorkspaceTabWithLayout(
        const PrepareWorkspaceTabInput(
          serverId: 'server-1',
          workspaceId: '/repo/worktree',
          target: WorkspaceAgentTabTarget(agentId: 'agent-1'),
        ),
        openTabFocused: (key, target) {
          open(key, target);
          return null;
        },
        pinAgent: (key, agentId) => active.pinAgent(key, agentId),
      );
      active = second;
      prepareWorkspaceTabWithLayout(
        const PrepareWorkspaceTabInput(
          serverId: 'server-2',
          workspaceId: '/repo/other',
          target: WorkspaceAgentTabTarget(agentId: 'agent-2'),
        ),
        openTabFocused: (key, target) {
          open(key, target);
          return null;
        },
        pinAgent: (key, agentId) => active.pinAgent(key, agentId),
      );

      expect(first.openedTabs, hasLength(1));
      expect(second.openedTabs, hasLength(1));
      expect(second.openedTabs.single.$1, 'server-2:/repo/other');
    });
  });

  group('toggleDesktopSidebarsWithCheckoutIntent', () {
    ({
      List<String> calls,
      bool Function({required bool agentList, required bool fileExplorer}) run,
    })
    harness({bool focusedToggleResult = true}) {
      final calls = <String>[];
      bool run({required bool agentList, required bool fileExplorer}) =>
          toggleDesktopSidebarsWithCheckoutIntent(
            isAgentListOpen: agentList,
            isFileExplorerOpen: fileExplorer,
            openAgentList: () => calls.add('openAgentList'),
            closeAgentList: () => calls.add('closeAgentList'),
            closeFileExplorer: () => calls.add('closeFileExplorer'),
            toggleFocusedFileExplorer: () {
              calls.add('toggleFocusedFileExplorer');
              return focusedToggleResult;
            },
          );
      return (calls: calls, run: run);
    }

    test('closes both sidebars when either desktop sidebar is open', () {
      final h = harness();

      final handled = h.run(agentList: true, fileExplorer: false);

      expect(handled, isTrue);
      expect(h.calls, ['closeAgentList', 'closeFileExplorer']);
    });

    test('closes both sidebars when only the file explorer is open', () {
      final h = harness();

      expect(h.run(agentList: false, fileExplorer: true), isTrue);
      expect(h.calls, ['closeAgentList', 'closeFileExplorer']);
    });

    test('closes both sidebars when both are open', () {
      final h = harness();

      expect(h.run(agentList: true, fileExplorer: true), isTrue);
      expect(h.calls, ['closeAgentList', 'closeFileExplorer']);
    });

    test(
      'opens the right sidebar only through the focused checkout-aware handler',
      () {
        final h = harness(focusedToggleResult: false);

        final handled = h.run(agentList: false, fileExplorer: false);

        expect(handled, isTrue);
        expect(h.calls, ['openAgentList', 'toggleFocusedFileExplorer']);
      },
    );

    test('reports handled regardless of the focused handler result', () {
      final opened = harness(focusedToggleResult: true);

      expect(opened.run(agentList: false, fileExplorer: false), isTrue);
      expect(opened.calls, ['openAgentList', 'toggleFocusedFileExplorer']);
    });
  });

  group('nextCronCadence', () {
    test(
      'preserves an existing cron cadence timezone when editing the expression',
      () {
        final result = nextCronCadence(
          current: const CronScheduleCadence(
            expression: '0 9 * * *',
            timezone: 'America/New_York',
          ),
          expression: '30 9 * * *',
          deviceTimeZone: 'America/Los_Angeles',
        );

        expect(result.expression, '30 9 * * *');
        expect(result.timezone, 'America/New_York');
        expect(result.type, 'cron');
      },
    );

    test('emits UTC for legacy cron cadences without a timezone', () {
      final result = nextCronCadence(
        current: const CronScheduleCadence(expression: '0 9 * * *'),
        expression: '30 9 * * *',
        deviceTimeZone: 'America/Los_Angeles',
      );

      expect(result.expression, '30 9 * * *');
      expect(result.timezone, 'UTC');
    });

    test('uses the device timezone when switching from interval to cron', () {
      final result = nextCronCadence(
        current: const EveryScheduleCadence(everyMs: 60 * 60000),
        expression: '0 9 * * *',
        deviceTimeZone: 'America/Los_Angeles',
      );

      expect(result.expression, '0 9 * * *');
      expect(result.timezone, 'America/Los_Angeles');
    });

    test('lets callers preserve a remembered cron timezone when toggling back '
        'from interval', () {
      final result = nextCronCadence(
        current: const EveryScheduleCadence(everyMs: 60 * 60000),
        expression: '0 9 * * *',
        deviceTimeZone: 'America/New_York',
      );

      expect(result.expression, '0 9 * * *');
      expect(result.timezone, 'America/New_York');
    });

    test('keeps the expression verbatim without trimming', () {
      final result = nextCronCadence(
        current: const EveryScheduleCadence(everyMs: 1000),
        expression: '  0 9 * * *  ',
        deviceTimeZone: 'UTC',
      );

      expect(result.expression, '  0 9 * * *  ');
    });

    test('treats an empty stored timezone as present, not missing', () {
      final result = nextCronCadence(
        current: const CronScheduleCadence(
          expression: '0 9 * * *',
          timezone: '',
        ),
        expression: '30 9 * * *',
        deviceTimeZone: 'America/Los_Angeles',
      );

      expect(result.timezone, '');
    });

    test('round-trips through the protocol cadence encoding', () {
      final result = nextCronCadence(
        current: const EveryScheduleCadence(everyMs: 60000),
        expression: '0 9 * * *',
        deviceTimeZone: 'Asia/Seoul',
      );

      expect(result.toJson(), {
        'type': 'cron',
        'expression': '0 9 * * *',
        'timezone': 'Asia/Seoul',
      });
    });
  });
}
