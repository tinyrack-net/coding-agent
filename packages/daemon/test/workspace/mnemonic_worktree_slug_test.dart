import 'package:agent_daemon/src/workspace/mnemonic_worktree_slug.dart';
import 'package:test/test.dart';

void main() {
  test('generates mnemonic-id compatible adjective-animal slugs', () {
    for (var index = 0; index < 128; index++) {
      expect(
        generateMnemonicWorktreeSlug(),
        matches(RegExp(r'^[a-z]+-[a-z]+$')),
      );
    }
  });
}
