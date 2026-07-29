/// Returns whether [candidatePath] is [basePath] or one of its descendants.
///
/// Both path separators are accepted. When either path has a Windows drive
/// prefix, comparison is case-insensitive to match Windows filesystem
/// semantics.
bool isSameOrDescendantPath(String basePath, String candidatePath) {
  var base = basePath.replaceAll(r'\', '/').replaceFirst(RegExp(r'/$'), '');
  var candidate = candidatePath
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp(r'/$'), '');
  final windowsPath =
      RegExp(r'^[a-zA-Z]:/').hasMatch(base) ||
      RegExp(r'^[a-zA-Z]:/').hasMatch(candidate);
  if (windowsPath) {
    base = base.toLowerCase();
    candidate = candidate.toLowerCase();
  }
  return candidate == base || candidate.startsWith('$base/');
}
