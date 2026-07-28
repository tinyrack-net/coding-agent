/// Frozen Paseo provider tool-name normalization.
library;

final _toolTokenPattern = RegExp(r'[a-z0-9]+');
final _standardNamespaceSeparatorPattern = RegExp(r'[.:/]');

String normalizeToolName(String name) => name.trim().toLowerCase();

List<String> tokenizeToolName(String name) => [
  for (final match in _toolTokenPattern.allMatches(normalizeToolName(name)))
    match.group(0)!,
];

String? getToolLeafName(String name) {
  final tokens = tokenizeToolName(name);
  return tokens.isEmpty ? null : tokens.last;
}

bool isSpeakToolName(String name) => getToolLeafName(name) == 'speak';

bool isLikelyNamespacedToolName(String name) {
  final normalized = normalizeToolName(name);
  if (_standardNamespaceSeparatorPattern.hasMatch(normalized)) return true;
  if (!normalized.contains('__')) return false;

  final segments = normalized
      .split('__')
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  if (segments.length >= 3) return true;
  return segments.length == 2 && segments[1].contains('_');
}

bool isPaseoToolName(String name) {
  final normalized = normalizeToolName(name);
  if (isSpeakToolName(normalized)) return false;
  if (normalized.contains('__')) {
    final segments = normalized
        .split('__')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    return segments.length >= 3 &&
        segments[0] == 'mcp' &&
        (segments[1] == 'paseo' || segments[1].startsWith('paseo_'));
  }
  if (normalized.contains('.')) {
    final firstSegment = normalized.split('.').first;
    return firstSegment == 'paseo' || firstSegment.startsWith('paseo_');
  }
  return false;
}

String? getPaseoToolLeafName(String name) {
  final normalized = normalizeToolName(name);
  if (normalized.contains('__')) {
    final segments = normalized
        .split('__')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.length >= 3 &&
        segments[0] == 'mcp' &&
        (segments[1] == 'paseo' || segments[1].startsWith('paseo_'))) {
      return segments.skip(2).join('__');
    }
    return null;
  }
  if (normalized.contains('.')) {
    final segments = normalized.split('.');
    final firstSegment = segments.first;
    if (firstSegment == 'paseo' || firstSegment.startsWith('paseo_')) {
      return segments.skip(1).join('.');
    }
  }
  return null;
}

bool isLikelyExternalToolName(String name) {
  final normalized = normalizeToolName(name);
  if (normalized.isEmpty) return false;
  return isSpeakToolName(normalized) || isLikelyNamespacedToolName(normalized);
}
