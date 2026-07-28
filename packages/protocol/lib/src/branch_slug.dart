/// Result of validating a Paseo branch slug.
final class BranchSlugValidation {
  const BranchSlugValidation.valid() : valid = true, error = null;

  const BranchSlugValidation.invalid(this.error) : valid = false;

  final bool valid;
  final String? error;
}

const int maxSlugLength = 50;

/// Validates the frozen lowercase branch-name subset used by Paseo.
BranchSlugValidation validateBranchSlug(String slug) {
  if (slug.isEmpty) {
    return const BranchSlugValidation.invalid('Branch name cannot be empty');
  }
  if (slug.length > 100) {
    return const BranchSlugValidation.invalid(
      'Branch name too long (max 100 characters)',
    );
  }
  if (!RegExp(r'^[a-z0-9-/]+$').hasMatch(slug)) {
    return const BranchSlugValidation.invalid(
      'Branch name must contain only lowercase letters, numbers, hyphens, '
      'and forward slashes',
    );
  }
  if (slug.startsWith('-') || slug.endsWith('-')) {
    return const BranchSlugValidation.invalid(
      'Branch name cannot start or end with a hyphen',
    );
  }
  if (slug.contains('--')) {
    return const BranchSlugValidation.invalid(
      'Branch name cannot have consecutive hyphens',
    );
  }
  return const BranchSlugValidation.valid();
}

/// Converts arbitrary text to Paseo's kebab-case worktree slug.
String slugify(String input) {
  var slug = input
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length <= maxSlugLength) return slug;

  final truncated = slug.substring(0, maxSlugLength);
  final lastHyphen = truncated.lastIndexOf('-');
  slug = lastHyphen > maxSlugLength / 2
      ? truncated.substring(0, lastHyphen)
      : truncated.replaceAll(RegExp(r'-+$'), '');
  return slug;
}
