import 'package:agent_protocol/agent_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('validateBranchSlug', () {
    test('accepts the frozen lowercase branch subset', () {
      for (final value in ['feature', 'feature/one', 'issue-42']) {
        expect(validateBranchSlug(value).valid, isTrue);
      }
    });

    test('returns the frozen validation errors', () {
      expect(validateBranchSlug('').error, 'Branch name cannot be empty');
      expect(
        validateBranchSlug('Feature').error,
        contains('only lowercase letters'),
      );
      expect(
        validateBranchSlug('-feature').error,
        'Branch name cannot start or end with a hyphen',
      );
      expect(
        validateBranchSlug('feature--one').error,
        'Branch name cannot have consecutive hyphens',
      );
      expect(
        validateBranchSlug('a' * 101).error,
        'Branch name too long (max 100 characters)',
      );
    });
  });

  group('slugify', () {
    test('normalizes arbitrary text to kebab case', () {
      expect(slugify('  Feature / Exact Name  '), 'feature-exact-name');
      expect(slugify('---'), isEmpty);
    });

    test('uses the frozen word-aware fifty-character truncation', () {
      expect(
        slugify('123456789012345678901234567890-abcdefghij-klmnopqrst'),
        '123456789012345678901234567890-abcdefghij',
      );
      expect(slugify('a' * 60), 'a' * 50);
    });
  });
}
