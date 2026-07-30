import 'package:agent_protocol/agent_protocol.dart';
import 'package:coding_agent_app/core/diff_order.dart';
import 'package:flutter_test/flutter_test.dart';

CheckoutDiffFile file(String path, [int additions = 0]) => CheckoutDiffFile(
  path: path,
  isNew: false,
  isDeleted: false,
  additions: additions,
  deletions: 0,
  hunks: const [],
);

void main() {
  test('compares paths deterministically', () {
    expect(compareCheckoutDiffPaths('a.ts', 'b.ts'), lessThan(0));
    expect(compareCheckoutDiffPaths('b.ts', 'a.ts'), greaterThan(0));
    expect(compareCheckoutDiffPaths('same.ts', 'same.ts'), 0);
  });

  test('sorts files by path without mutating the input', () {
    final input = [file('zeta.ts'), file('alpha.ts'), file('beta.ts')];
    final ordered = orderCheckoutDiffFiles(input);

    expect(ordered.map((entry) => entry.path), [
      'alpha.ts',
      'beta.ts',
      'zeta.ts',
    ]);
    expect(input.map((entry) => entry.path), [
      'zeta.ts',
      'alpha.ts',
      'beta.ts',
    ]);
  });

  test('preserves relative order for equal paths', () {
    final ordered = orderCheckoutDiffFiles([
      file('same.ts', 1),
      file('same.ts', 2),
      file('same.ts', 3),
    ]);

    expect(ordered.map((entry) => entry.additions), [1, 2, 3]);
  });

  test('returns the same list when sorting is unnecessary', () {
    final empty = <CheckoutDiffFile>[];
    final single = [file('only.ts')];

    expect(orderCheckoutDiffFiles(empty), same(empty));
    expect(orderCheckoutDiffFiles(single), same(single));
  });
}
