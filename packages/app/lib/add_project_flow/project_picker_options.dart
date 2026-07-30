enum ProjectPickerOptionKind { path, suggestion }

final class ProjectPickerOption {
  const ProjectPickerOption({required this.kind, required this.path});

  final ProjectPickerOptionKind kind;
  final String path;
}

List<String> buildWorkingDirectorySuggestions({
  required List<String> recommendedPaths,
  required List<String> serverPaths,
  required String query,
}) {
  final normalizedQuery = query.trim();
  final recommended = _uniquePaths(recommendedPaths);
  if (normalizedQuery.isEmpty) return recommended;
  final matchingRecommended = recommended
      .where((path) => _recommendedPathMatchesQuery(path, normalizedQuery))
      .toList(growable: false);
  return _uniquePaths([...matchingRecommended, ...serverPaths]);
}

bool isOpenableProjectPath(String query) {
  final trimmed = query.trim();
  return trimmed.startsWith('/') ||
      trimmed.startsWith('~') ||
      trimmed.startsWith(r'\\') ||
      RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(trimmed);
}

List<ProjectPickerOption> buildProjectPickerOptions({
  required List<String> recommendedPaths,
  required List<String> serverPaths,
  required String query,
}) {
  final suggestedPaths = buildWorkingDirectorySuggestions(
    recommendedPaths: recommendedPaths,
    serverPaths: serverPaths,
    query: query,
  );
  final suggestions = [
    for (final path in suggestedPaths)
      ProjectPickerOption(kind: ProjectPickerOptionKind.suggestion, path: path),
  ];
  final trimmed = query.trim();
  if (!isOpenableProjectPath(trimmed) || suggestedPaths.contains(trimmed)) {
    return suggestions;
  }
  return [
    ProjectPickerOption(kind: ProjectPickerOptionKind.path, path: trimmed),
    ...suggestions,
  ];
}

List<String> _uniquePaths(List<String> paths) {
  final seen = <String>{};
  return [
    for (final path in paths)
      if (path.trim() case final trimmed
          when trimmed.isNotEmpty && seen.add(trimmed))
        trimmed,
  ];
}

bool _recommendedPathMatchesQuery(String path, String query) {
  final candidate = _normalizePath(path);
  final normalizedQuery = _normalizePath(query);
  if (normalizedQuery == '~' || normalizedQuery == '~/') return true;
  if (normalizedQuery.contains('/') || normalizedQuery.startsWith('~')) {
    return false;
  }
  final basename = candidate.split('/').lastOrNull ?? '';
  return candidate.contains(normalizedQuery) ||
      _isSubsequence(normalizedQuery, basename);
}

String _normalizePath(String value) =>
    value.trim().replaceAll('\\', '/').toLowerCase();

bool _isSubsequence(String query, String text) {
  var queryIndex = 0;
  for (
    var index = 0;
    index < text.length && queryIndex < query.length;
    index += 1
  ) {
    if (text[index] == query[queryIndex]) queryIndex += 1;
  }
  return queryIndex == query.length;
}
