import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('accepts optional branch-off worktree and autoArchive', () {
    final fields = CreateAgentLifecycleFields.fromJson(const {
      'worktree': {
        'mode': 'branch-off',
        'newBranch': 'agent-lifecycle-dispatch',
        'base': 'main',
      },
      'autoArchive': true,
    });

    expect(
      fields.worktree,
      isA<BranchOffCreateAgentWorktreeTarget>()
          .having(
            (target) => target.newBranch,
            'newBranch',
            'agent-lifecycle-dispatch',
          )
          .having((target) => target.base, 'base', 'main'),
    );
    expect(fields.autoArchive, isTrue);
    expect(fields.toJson(), {
      'worktree': {
        'mode': 'branch-off',
        'newBranch': 'agent-lifecycle-dispatch',
        'base': 'main',
      },
      'autoArchive': true,
    });
  });

  test('keeps legacy lifecycle defaults unchanged', () {
    final fields = CreateAgentLifecycleFields.fromJson(const {});
    expect(fields.worktree, isNull);
    expect(fields.autoArchive, isNull);
    expect(fields.toJson(), isEmpty);
  });

  test('parses checkout branch and pull request targets', () {
    expect(
      CreateAgentLifecycleFields.fromJson(const {
        'worktree': {'mode': 'checkout-branch', 'branch': 'existing'},
      }).worktree,
      isA<CheckoutBranchCreateAgentWorktreeTarget>().having(
        (target) => target.branch,
        'branch',
        'existing',
      ),
    );
    expect(
      CreateAgentLifecycleFields.fromJson(const {
        'worktree': {'mode': 'checkout-pr', 'prNumber': 42},
      }).worktree,
      isA<CheckoutPrCreateAgentWorktreeTarget>().having(
        (target) => target.prNumber,
        'prNumber',
        42,
      ),
    );
  });

  test('rejects malformed lifecycle fields', () {
    expect(
      () => CreateAgentLifecycleFields.fromJson(const {'worktree': 'bad'}),
      throwsFormatException,
    );
    expect(
      () => CreateAgentLifecycleFields.fromJson(const {'autoArchive': 'yes'}),
      throwsFormatException,
    );
    expect(
      () => CreateAgentLifecycleFields.fromJson(const {'worktree': null}),
      throwsFormatException,
    );
    expect(
      () => CreateAgentLifecycleFields.fromJson(const {'autoArchive': null}),
      throwsFormatException,
    );
    expect(
      () => CreateAgentLifecycleFields.fromJson(const {
        'worktree': {'mode': 'checkout-pr', 'prNumber': 0},
      }),
      throwsFormatException,
    );
  });
}
