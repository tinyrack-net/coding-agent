import 'package:agent_daemon/src/server/create_agent_input_validator.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> canonical() => {
    'title': 'Implement strict create',
    'provider': 'codex/gpt-5.4',
    'initialPrompt': 'Implement the requested change',
  };

  test('accepts canonical top-level and agent-scoped arguments', () {
    expect(
      () => validateCreateAgentArguments({
        ...canonical(),
        'workspaceId': 'workspace-1',
        'labels': {'surface': 'automation'},
        'settings': {
          'modeId': 'plan',
          'thinkingOptionId': 'high',
          'features': {'fast_mode': true},
        },
        'background': true,
        'notifyOnFinish': false,
      }, agentScoped: false),
      returnsNormally,
    );
    expect(
      () => validateCreateAgentArguments({
        ...canonical(),
        'workspaceId': 'workspace-1',
        'notifyOnFinish': true,
      }, agentScoped: true),
      returnsNormally,
    );
  });

  test('accepts every hidden legacy placement variant', () {
    final placements = <Map<String, Object?>>[
      {
        'relationship': {'kind': 'subagent'},
        'workspace': {'kind': 'current', 'cwd': 'packages/app'},
      },
      {
        'relationship': {'kind': 'detached'},
        'workspace': {
          'kind': 'existing',
          'workspaceId': 'workspace-2',
          'cwd': 'packages/server',
        },
      },
      {
        'relationship': {'kind': 'detached'},
        'workspace': {
          'kind': 'create',
          'source': {'kind': 'directory', 'path': '/repo'},
        },
      },
      {
        'relationship': {'kind': 'detached'},
        'workspace': {
          'kind': 'create',
          'source': {
            'kind': 'worktree',
            'cwd': '/repo',
            'target': {
              'kind': 'branch-off',
              'worktreeSlug': 'feature',
              'branchName': 'feature/strict',
              'baseBranch': 'main',
            },
          },
        },
      },
      {
        'relationship': {'kind': 'detached'},
        'workspace': {
          'kind': 'create',
          'source': {
            'kind': 'worktree',
            'target': {'kind': 'checkout-branch', 'branch': 'existing'},
          },
        },
      },
      {
        'relationship': {'kind': 'detached'},
        'workspace': {
          'kind': 'create',
          'source': {
            'kind': 'worktree',
            'target': {'kind': 'checkout-pr', 'githubPrNumber': 42},
          },
        },
      },
    ];

    for (final placement in placements) {
      expect(
        () => validateCreateAgentArguments({
          ...canonical(),
          ...placement,
          'notifyOnFinish': false,
        }, agentScoped: true),
        returnsNormally,
      );
    }
    expect(
      () => validateCreateAgentArguments({
        ...canonical(),
        'cwd': '/repo',
        'mode': 'plan',
        'thinking': 'high',
        'features': {'fast_mode': true},
        'worktreeName': 'feature',
        'branchName': 'feature/strict',
        'baseBranch': 'main',
        'background': true,
      }, agentScoped: false),
      returnsNormally,
    );
  });

  test('rejects scope and nested unknown fields', () {
    final invalid = <({Map<String, Object?> input, bool scoped, String error})>[
      (
        input: {...canonical(), 'unexpected': true},
        scoped: false,
        error: 'create_agent contains unknown fields: unexpected',
      ),
      (
        input: {...canonical(), 'background': true},
        scoped: true,
        error: 'create_agent contains unknown fields: background',
      ),
      (
        input: {
          ...canonical(),
          'settings': {'modeId': 'plan', 'unexpected': true},
        },
        scoped: false,
        error: 'create_agent.settings contains unknown fields: unexpected',
      ),
      (
        input: {
          ...canonical(),
          'relationship': {'kind': 'detached', 'unexpected': true},
          'workspace': {'kind': 'current'},
        },
        scoped: true,
        error: 'create_agent.relationship contains unknown fields: unexpected',
      ),
      (
        input: {
          ...canonical(),
          'relationship': {'kind': 'detached'},
          'workspace': {
            'kind': 'existing',
            'workspaceId': 'workspace',
            'unexpected': true,
          },
        },
        scoped: true,
        error: 'create_agent.workspace contains unknown fields: unexpected',
      ),
      (
        input: {
          ...canonical(),
          'relationship': {'kind': 'detached'},
          'workspace': {
            'kind': 'create',
            'source': {
              'kind': 'worktree',
              'target': {'kind': 'branch-off', 'unexpected': true},
            },
          },
        },
        scoped: true,
        error:
            'create_agent.workspace.source.target contains unknown fields: '
            'unexpected',
      ),
    ];

    for (final entry in invalid) {
      expect(
        () => validateCreateAgentArguments(
          entry.input,
          agentScoped: entry.scoped,
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            entry.error,
          ),
        ),
      );
    }
  });

  test('rejects null, wrong-type, empty, and invalid discriminator values', () {
    final invalid = <({Map<String, Object?> input, bool scoped})>[
      (input: {...canonical(), 'workspaceId': null}, scoped: false),
      (input: {...canonical(), 'labels': null}, scoped: false),
      (input: {...canonical(), 'settings': null}, scoped: false),
      (input: {...canonical(), 'background': 'yes'}, scoped: false),
      (
        input: {
          ...canonical(),
          'relationship': {'kind': 'root'},
          'workspace': {'kind': 'current'},
        },
        scoped: true,
      ),
      (
        input: {
          ...canonical(),
          'relationship': {'kind': 'detached'},
          'workspace': {'kind': 'missing'},
        },
        scoped: true,
      ),
      (
        input: {
          ...canonical(),
          'relationship': {'kind': 'detached'},
          'workspace': {'kind': 'existing', 'workspaceId': ''},
        },
        scoped: true,
      ),
      (
        input: {
          ...canonical(),
          'relationship': {'kind': 'detached'},
          'workspace': {
            'kind': 'create',
            'source': {
              'kind': 'worktree',
              'target': {'kind': 'checkout-branch', 'branch': ''},
            },
          },
        },
        scoped: true,
      ),
      (
        input: {
          ...canonical(),
          'relationship': {'kind': 'detached'},
          'workspace': {
            'kind': 'create',
            'source': {
              'kind': 'worktree',
              'target': {'kind': 'checkout-pr', 'githubPrNumber': 0},
            },
          },
        },
        scoped: true,
      ),
    ];

    for (final entry in invalid) {
      expect(
        () => validateCreateAgentArguments(
          entry.input,
          agentScoped: entry.scoped,
        ),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('treats explicit null legacy keys as legacy input', () {
    expect(
      hasLegacyCreateAgentPlacement({...canonical(), 'workspace': null}),
      isTrue,
    );
    expect(
      () => validateCreateAgentArguments({
        ...canonical(),
        'workspace': null,
      }, agentScoped: false),
      throwsA(isA<FormatException>()),
    );
  });
}
