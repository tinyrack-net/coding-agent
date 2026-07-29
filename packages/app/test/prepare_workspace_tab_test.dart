import 'package:coding_agent_app/workspace/prepare_workspace_tab.dart';
import 'package:coding_agent_app/workspace/workspace_tab_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('opens and focuses an agent with the canonical workspace key', () {
    final opened = <(String, WorkspaceTabTarget)>[];
    final pinned = <(String, String)>[];

    prepareWorkspaceTab(
      const PrepareWorkspaceTabInput(
        serverId: 'server-1',
        workspaceId: '/repo/worktree',
        target: WorkspaceAgentTabTarget(agentId: 'agent-1'),
      ),
      PrepareWorkspaceTabDependencies(
        openTabFocused: (key, target) {
          opened.add((key, target));
          return target is WorkspaceAgentTabTarget ? target.agentId : null;
        },
        pinAgent: (key, agentId) => pinned.add((key, agentId)),
      ),
    );

    expect(opened, hasLength(1));
    expect(opened.single.$1, 'server-1:/repo/worktree');
    expect(
      opened.single.$2,
      isA<WorkspaceAgentTabTarget>().having(
        (target) => target.agentId,
        'agentId',
        'agent-1',
      ),
    );
    expect(pinned, isEmpty);
  });

  test('pin applies only to agent targets and uses the same key', () {
    final pinned = <(String, String)>[];
    final dependencies = PrepareWorkspaceTabDependencies(
      openTabFocused: (_, _) => null,
      pinAgent: (key, agentId) => pinned.add((key, agentId)),
    );

    prepareWorkspaceTab(
      const PrepareWorkspaceTabInput(
        serverId: ' server ',
        workspaceId: ' workspace ',
        target: WorkspaceAgentTabTarget(agentId: ' agent '),
        pin: true,
      ),
      dependencies,
    );
    prepareWorkspaceTab(
      const PrepareWorkspaceTabInput(
        serverId: 'server',
        workspaceId: 'workspace',
        target: WorkspaceTerminalTabTarget(terminalId: 'terminal'),
        pin: true,
      ),
      dependencies,
    );

    expect(pinned, [('server:workspace', ' agent ')]);
  });

  test('draft:new is replaced with a fresh id before opening', () {
    final opened = <WorkspaceTabTarget>[];
    final dependencies = PrepareWorkspaceTabDependencies(
      openTabFocused: (_, target) {
        opened.add(target);
        return null;
      },
      pinAgent: (_, _) {},
    );

    prepareWorkspaceTab(
      const PrepareWorkspaceTabInput(
        serverId: 'server',
        workspaceId: 'workspace',
        target: WorkspaceDraftTabTarget(draftId: 'new'),
      ),
      dependencies,
    );

    expect(opened.single, isA<WorkspaceDraftTabTarget>());
    expect(
      (opened.single as WorkspaceDraftTabTarget).draftId,
      allOf(isNot('new'), isNotEmpty),
    );
  });
}
