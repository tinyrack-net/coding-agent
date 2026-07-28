import 'package:coding_agent_app/workspace/workspace_tab_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('persistence keys require normalized server and workspace ids', () {
    expect(
      buildWorkspaceTabPersistenceKey(
        serverId: ' server ',
        workspaceId: ' workspace ',
      ),
      'server:workspace',
    );
    expect(
      buildWorkspaceTabPersistenceKey(serverId: ' ', workspaceId: 'workspace'),
      isNull,
    );
  });

  test('normalizes every frozen Paseo workspace target kind', () {
    expect(
      normalizeWorkspaceTabTarget(
        const WorkspaceDraftTabTarget(
          draftId: ' draft ',
          setup: WorkspaceDraftTabSetup(
            provider: ' codex ',
            cwd: ' C:/repo ',
            modeId: ' ',
            model: ' gpt ',
            thinkingOptionId: null,
            featureValues: {'fast': true},
          ),
        ),
      )?.toJson(),
      {
        'kind': 'draft',
        'draftId': 'draft',
        'setup': {
          'provider': 'codex',
          'cwd': 'C:/repo',
          'modeId': null,
          'model': 'gpt',
          'thinkingOptionId': null,
          'featureValues': {'fast': true},
        },
      },
    );
    expect(
      normalizeWorkspaceTabTarget(
        const WorkspaceProviderSubagentTabTarget(
          parentAgentId: ' parent ',
          subagentId: ' child ',
        ),
      )?.toJson(),
      {
        'kind': 'provider_subagent',
        'parentAgentId': 'parent',
        'subagentId': 'child',
      },
    );
    expect(
      normalizeWorkspaceTabTarget(
        const WorkspaceFileTabTarget(
          path: r' lib\main.dart ',
          lineStart: 8,
          lineEnd: 4,
        ),
      )?.toJson(),
      {'kind': 'file', 'path': 'lib/main.dart', 'lineStart': 8},
    );
    expect(
      normalizeWorkspaceTabTarget(
        const WorkspaceWorkingDiffTabTarget(
          focusPath: r' lib\main.dart ',
          focusRequestId: -1,
        ),
      )?.toJson(),
      {'kind': 'working_diff', 'focusPath': 'lib/main.dart'},
    );
    expect(
      normalizeWorkspaceTabTarget(
        const WorkspaceBrowserTabTarget(browserId: ' browser '),
      )?.toJson(),
      {'kind': 'browser', 'browserId': 'browser'},
    );
    expect(
      normalizeWorkspaceTabTarget(
        const WorkspaceSetupTabTarget(workspaceId: ' workspace '),
      )?.toJson(),
      {'kind': 'setup', 'workspaceId': 'workspace'},
    );
    expect(
      normalizeWorkspaceTabTarget(
        const WorkspaceCommitDiffTabTarget(sha: ' abc '),
      )?.toJson(),
      {'kind': 'commit_diff', 'sha': 'abc'},
    );
    expect(
      normalizeWorkspaceTabTarget(
        const WorkspaceTerminalTabTarget(terminalId: ' '),
      ),
      isNull,
    );
    expect(
      normalizeWorkspaceTabTarget(const WorkspaceAgentTabTarget(agentId: ' ')),
      isNull,
    );
  });

  test('target equality follows kind-specific Paseo identity', () {
    expect(
      workspaceTabTargetsEqual(
        const WorkspaceFileTabTarget(path: r'lib\main.dart', lineStart: 2),
        const WorkspaceFileTabTarget(path: 'lib/main.dart', lineStart: 2),
      ),
      isTrue,
    );
    expect(
      workspaceTabTargetsEqual(
        const WorkspaceWorkingDiffTabTarget(focusPath: 'a.dart'),
        const WorkspaceWorkingDiffTabTarget(focusPath: 'b.dart'),
      ),
      isFalse,
    );
    expect(
      workspaceTabTargetsEqual(
        const WorkspaceDraftTabTarget(
          draftId: 'draft',
          setup: WorkspaceDraftTabSetup(
            provider: 'codex',
            cwd: '/repo',
            modeId: null,
            model: null,
            thinkingOptionId: null,
            featureValues: {'mode': 'fast'},
          ),
        ),
        const WorkspaceDraftTabTarget(
          draftId: 'draft',
          setup: WorkspaceDraftTabSetup(
            provider: 'codex',
            cwd: '/repo',
            modeId: null,
            model: null,
            thinkingOptionId: null,
            featureValues: {'mode': 'fast'},
          ),
        ),
      ),
      isTrue,
    );
  });

  test('deterministic ids match the frozen source contract', () {
    expect(
      buildDeterministicWorkspaceTabId(
        const WorkspaceDraftTabTarget(draftId: 'draft'),
      ),
      'draft',
    );
    expect(
      buildDeterministicWorkspaceTabId(
        const WorkspaceAgentTabTarget(agentId: 'a1'),
      ),
      'agent_a1',
    );
    expect(
      buildDeterministicWorkspaceTabId(
        const WorkspaceProviderSubagentTabTarget(
          parentAgentId: 'ab',
          subagentId: 'xyz',
        ),
      ),
      'provider_subagent_2_ab_3_xyz',
    );
    expect(
      buildDeterministicWorkspaceTabId(
        const WorkspaceTerminalTabTarget(terminalId: 't1'),
      ),
      'terminal_t1',
    );
    expect(
      buildDeterministicWorkspaceTabId(const WorkspaceWorkingDiffTabTarget()),
      'working_diff',
    );
    expect(
      buildDeterministicWorkspaceTabId(
        const WorkspaceFileTabTarget(path: 'lib/main.dart'),
      ),
      'file_lib/main.dart',
    );
  });

  test('workspace tabs reject malformed wire values and round-trip', () {
    final tab = WorkspaceTab.fromJson({
      'tabId': ' tab ',
      'target': {'kind': 'agent', 'agentId': ' agent '},
      'createdAt': 42,
    });
    expect(tab?.tabId, 'tab');
    expect(tab?.target.toJson(), {'kind': 'agent', 'agentId': 'agent'});
    expect(WorkspaceTab.fromJson({'tabId': '', 'createdAt': 1}), isNull);
    expect(WorkspaceTabTarget.fromJson({'kind': 'unknown'}), isNull);
    expect(
      normalizeWorkspaceTabTarget(
        WorkspaceTabTarget.fromJson({
          'kind': 'file',
          'path': 42,
          'lineStart': double.infinity,
        }),
      ),
      isNull,
    );
    expect(
      WorkspaceTabTarget.fromJson({
        'kind': 'working_diff',
        'focusPath': 42,
        'focusRequestId': double.nan,
      })?.toJson(),
      {'kind': 'working_diff'},
    );
    expect(WorkspaceTab.fromJson(tab!.toJson())?.toJson(), tab.toJson());
  });

  test('draft setup hash is stable across feature insertion order', () {
    const left = WorkspaceDraftTabSetup(
      provider: 'codex',
      cwd: '/repo',
      modeId: null,
      model: null,
      thinkingOptionId: null,
      featureValues: {'a': 1, 'b': 2},
    );
    const right = WorkspaceDraftTabSetup(
      provider: 'codex',
      cwd: '/repo',
      modeId: null,
      model: null,
      thinkingOptionId: null,
      featureValues: {'b': 2, 'a': 1},
    );
    expect(left, right);
    expect(left.hashCode, right.hashCode);
  });
}
