/// Replaces a macOS or Linux home-directory prefix with `~`.
String shortenPath(String? path) {
  if (path == null || path.isEmpty) return '';
  return path.replaceFirst(RegExp(r'^/(?:Users|home)/[^/]+'), '~');
}
